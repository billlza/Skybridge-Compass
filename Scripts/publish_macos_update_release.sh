#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate and transactionally publish an immutable macOS update release.

Usage:
  publish_macos_update_release.sh [options]

Options:
  --repository <owner/repo>      GitHub repository (default: GITHUB_REPOSITORY or billlza/Skybridge-Compass)
  --tag <tag>                    Existing tag in macos-v<semver>-build-<build> form
  --expected-source-sha <sha>    Exact 40-character source commit for the remote tag
  --app-path <path>              App bundle used to read bundle id/version/build
  --dmg-path <path>              Notarized DMG to upload
  --manifest-path <path>         Output manifest path (default: dist/macos-stable.json)
  --key-id <id>                  Ed25519 manifest signing key id
  --private-key-file <path>      Base64 raw Ed25519 private seed; alternatively use SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64
  --sequence <int64>             Monotonic manifest sequence (default: app CFBundleVersion)
  --published-at <iso8601>       Publication timestamp (default: current UTC)
  --expires-at <iso8601>         Expiration timestamp (default: published_at + 30 days)
  --release-notes-url <url>      Release notes URL (default: GitHub release URL)
  --proof-summary-path <path>    Machine-readable publish proof summary
  --evidence-provenance-path <path>
                                Validated producer-run provenance JSON
  --evidence-asset <path>        Validated release evidence file to publish; repeatable
  --skip-upload                  Generate and locally verify only; no upload/read-back release proof
  -h, --help                     Show this help

Without --skip-upload, the remote tag must already exist and resolve to the
expected source commit. The publisher creates one draft containing the DMG,
macos-stable.json, and every evidence asset, verifies the complete draft, then
publishes it exactly once and verifies GitHub's immutable release attestation.
It never creates or moves tags and never replaces assets. The manifest private
key is never accepted as a command-line value.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_ROOT}/Scripts/package_build_policy.sh"
MANIFEST_VALIDATOR="${PROJECT_ROOT}/Scripts/validate_macos_update_manifest.sh"

REPOSITORY="${GITHUB_REPOSITORY:-billlza/Skybridge-Compass}"
TAG_NAME=""
EXPECTED_SOURCE_SHA=""
APP_PATH="${PROJECT_ROOT}/dist/SkyBridge Compass Pro.app"
DMG_PATH=""
MANIFEST_PATH="${PROJECT_ROOT}/dist/macos-stable.json"
KEY_ID=""
PRIVATE_KEY_FILE=""
SEQUENCE=""
PUBLISHED_AT=""
EXPIRES_AT=""
RELEASE_NOTES_URL=""
PROOF_SUMMARY_PATH=""
SKIP_UPLOAD=0
EVIDENCE_ASSET_PATHS=()
EVIDENCE_ASSET_COUNT=0
EVIDENCE_PROVENANCE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      REPOSITORY="${2:-}"
      shift 2
      ;;
    --tag)
      TAG_NAME="${2:-}"
      shift 2
      ;;
    --expected-source-sha)
      EXPECTED_SOURCE_SHA="${2:-}"
      shift 2
      ;;
    --app-path)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --dmg-path)
      DMG_PATH="${2:-}"
      shift 2
      ;;
    --manifest-path)
      MANIFEST_PATH="${2:-}"
      shift 2
      ;;
    --key-id)
      KEY_ID="${2:-}"
      shift 2
      ;;
    --private-key-file)
      PRIVATE_KEY_FILE="${2:-}"
      shift 2
      ;;
    --sequence)
      SEQUENCE="${2:-}"
      shift 2
      ;;
    --published-at)
      PUBLISHED_AT="${2:-}"
      shift 2
      ;;
    --expires-at)
      EXPIRES_AT="${2:-}"
      shift 2
      ;;
    --release-notes-url)
      RELEASE_NOTES_URL="${2:-}"
      shift 2
      ;;
    --proof-summary-path)
      PROOF_SUMMARY_PATH="${2:-}"
      shift 2
      ;;
    --evidence-asset)
      EVIDENCE_ASSET_PATHS+=("${2:-}")
      EVIDENCE_ASSET_COUNT=$((EVIDENCE_ASSET_COUNT + 1))
      shift 2
      ;;
    --evidence-provenance-path)
      EVIDENCE_PROVENANCE_PATH="${2:-}"
      shift 2
      ;;
    --skip-upload)
      SKIP_UPLOAD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[publish-update] unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

fail() {
  echo "[publish-update] ERROR: $1" >&2
  exit 1
}

plist_read_value() {
  local plist_path="$1"
  local key_path="$2"

  python3 - "${plist_path}" "${key_path}" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
key_path = sys.argv[2].split(".")

if not plist_path.exists():
    raise SystemExit(1)

with plist_path.open("rb") as handle:
    value = plistlib.load(handle)

for key in key_path:
    if isinstance(value, dict) and key in value:
        value = value[key]
    else:
        raise SystemExit(1)

if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    raise SystemExit(1)
else:
    print(value)
PY
}

sha256_file() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

write_publish_proof_summary() {
  local status="$1"
  local uploaded="$2"
  local remote_verified="$3"
  local release_proof="$4"
  local proof_summary_path="$5"
  local immutable="$6"
  local attestation_verified="$7"

  [[ -n "$proof_summary_path" ]] || return 0

  python3 - \
    "$proof_summary_path" \
    "$status" \
    "$uploaded" \
    "$remote_verified" \
    "$release_proof" \
    "$immutable" \
    "$attestation_verified" \
    "$REPOSITORY" \
    "$TAG_NAME" \
    "$EXPECTED_SOURCE_SHA" \
    "$(basename "$APP_PATH")" \
    "$DMG_ASSET_NAME" \
    "$(basename "$MANIFEST_PATH")" \
    "$EXPECTED_DMG_SHA" \
    "$ASSET_HASHES_PATH" <<'PY'
import json
import pathlib
import sys
from datetime import datetime, timezone

(
    proof_path,
    status,
    uploaded,
    remote_verified,
    release_proof,
    immutable,
    attestation_verified,
    repository,
    tag_name,
    source_sha,
    app_bundle_name,
    dmg_asset_name,
    manifest_asset_name,
    expected_dmg_sha,
    asset_hashes_path,
) = sys.argv[1:]

assets = []
for line in pathlib.Path(asset_hashes_path).read_text(encoding="utf-8").splitlines():
    digest, name = line.split("\t", 1)
    assets.append({"name": name, "sha256": digest})

summary = {
    "profile": "macos-update-release-publish-proof",
    "status": status,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "repository": repository,
    "tag": tag_name,
    "source_sha": source_sha or None,
    "app_bundle_name": app_bundle_name,
    "dmg_asset_name": dmg_asset_name,
    "dmg_sha256": expected_dmg_sha,
    "manifest_asset_name": manifest_asset_name,
    "local_manifest_validated": True,
    "uploaded": uploaded == "true",
    "remote_verified": remote_verified == "true",
    "immutable": immutable == "true",
    "attestation_verified": attestation_verified == "true",
    "release_proof": release_proof == "true",
    "assets": assets,
}
path = pathlib.Path(proof_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  echo "[publish-update] proof summary: $proof_summary_path"
}

canonical_regular_asset_path() {
  local asset_path="$1"
  local label="$2"
  local asset_dir=""
  local asset_name=""

  [[ -n "$asset_path" ]] || fail "$label path is empty"
  [[ "$asset_path" != *$'\n'* && "$asset_path" != *$'\t'* ]] \
    || fail "$label path contains a forbidden control character"
  [[ -f "$asset_path" && ! -L "$asset_path" ]] \
    || fail "$label must be a regular file and not a symbolic link: $asset_path"
  [[ -s "$asset_path" ]] || fail "$label must not be empty: $asset_path"

  asset_dir="$(cd "$(dirname "$asset_path")" && pwd -P)"
  asset_name="$(basename "$asset_path")"
  [[ "$asset_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
    || fail "$label asset name is not release-safe: $asset_name"
  printf '%s/%s\n' "$asset_dir" "$asset_name"
}

asset_name_is_staged() {
  local expected_name="$1"

  [[ -f "$ASSET_HASHES_PATH" ]] || return 1
  cut -f2 "$ASSET_HASHES_PATH" | grep -Fxq "$expected_name"
}

stage_release_asset() {
  local source_path="$1"
  local label="$2"
  local canonical_path=""
  local asset_name=""
  local staged_path=""
  local source_sha_before=""
  local source_sha_after=""
  local staged_sha=""

  canonical_path="$(canonical_regular_asset_path "$source_path" "$label")"
  asset_name="$(basename "$canonical_path")"
  asset_name_is_staged "$asset_name" \
    && fail "release asset names must be unique: $asset_name"

  source_sha_before="$(sha256_file "$canonical_path")"
  staged_path="${STAGING_DIR}/${asset_name}"
  cp -p "$canonical_path" "$staged_path"
  chmod a-w "$staged_path"
  source_sha_after="$(sha256_file "$canonical_path")"
  staged_sha="$(sha256_file "$staged_path")"
  [[ "$source_sha_before" == "$source_sha_after" && "$source_sha_before" == "$staged_sha" ]] \
    || fail "$label changed while it was staged: $canonical_path"

  STAGED_ASSET_PATHS+=("$staged_path")
  printf '%s\t%s\n' "$staged_sha" "$asset_name" >>"$ASSET_HASHES_PATH"
}

prepare_staged_release_assets() {
  local evidence_path=""

  : >"$ASSET_HASHES_PATH"
  stage_release_asset "$DMG_PATH" "DMG"
  stage_release_asset "$MANIFEST_PATH" "update manifest"
  if [[ -n "$EVIDENCE_PROVENANCE_PATH" ]]; then
    stage_release_asset "$EVIDENCE_PROVENANCE_PATH" "release evidence provenance"
  fi
  if (( EVIDENCE_ASSET_COUNT > 0 )); then
    for evidence_path in "${EVIDENCE_ASSET_PATHS[@]}"; do
      stage_release_asset "$evidence_path" "release evidence"
    done
  fi
}

validate_proof_summary_destination() {
  local proof_absolute=""
  local asset_path=""
  local asset_absolute=""

  [[ "$PROOF_SUMMARY_PATH" != *$'\n'* && "$PROOF_SUMMARY_PATH" != *$'\t'* ]] \
    || fail "proof summary path contains a forbidden control character"
  [[ ! -L "$PROOF_SUMMARY_PATH" ]] \
    || fail "proof summary path must not be a symbolic link: $PROOF_SUMMARY_PATH"
  proof_absolute="$(python3 - "$PROOF_SUMMARY_PATH" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
)"

  for asset_path in "$DMG_PATH" "$MANIFEST_PATH"; do
    asset_absolute="$(canonical_regular_asset_path "$asset_path" "release asset")"
    [[ "$proof_absolute" != "$asset_absolute" ]] \
      || fail "proof summary path must not overwrite a release asset: $asset_absolute"
  done
  if [[ -n "$EVIDENCE_PROVENANCE_PATH" ]]; then
    asset_absolute="$(canonical_regular_asset_path "$EVIDENCE_PROVENANCE_PATH" "release evidence provenance")"
    [[ "$proof_absolute" != "$asset_absolute" ]] \
      || fail "proof summary path must not overwrite release evidence provenance: $asset_absolute"
  fi
  if (( EVIDENCE_ASSET_COUNT > 0 )); then
    for asset_path in "${EVIDENCE_ASSET_PATHS[@]}"; do
      asset_absolute="$(canonical_regular_asset_path "$asset_path" "release evidence")"
      [[ "$proof_absolute" != "$asset_absolute" ]] \
        || fail "proof summary path must not overwrite a release evidence asset: $asset_absolute"
    done
  fi
}

validate_release_evidence_provenance() {
  local provenance_path=""

  [[ "$EXPECTED_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] \
    || fail "--expected-source-sha must be a full lowercase Git commit"
  provenance_path="$(canonical_regular_asset_path "$EVIDENCE_PROVENANCE_PATH" "release evidence provenance")"
  EVIDENCE_PROVENANCE_PATH="$provenance_path"

  python3 - "$provenance_path" "$REPOSITORY" "$EXPECTED_SOURCE_SHA" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected_repository = sys.argv[2]
expected_source_sha = sys.argv[3]
expected_names = {
    "real-device-connectivity-matrix-public-redacted",
    "real-device-p2p-remote-smoke-public-redacted",
    "real-device-webrtc-smoke-public-redacted",
    "real-device-file-transfer-smoke-public-redacted",
}

try:
    if path.stat().st_size > 2 * 1024 * 1024:
        raise ValueError("file exceeds 2 MiB")
    payload = json.loads(path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
    raise SystemExit(f"invalid release evidence provenance: {exc}")

if not isinstance(payload, dict):
    raise SystemExit("release evidence provenance must be a JSON object")
required_scalars = {
    "schema_version": 1,
    "repository": expected_repository,
    "workflow_path": ".github/workflows/real-device-release-gate.yml",
    "event": "workflow_dispatch",
    "status": "completed",
    "conclusion": "success",
    "head_sha": expected_source_sha,
}
for key, expected in required_scalars.items():
    if payload.get(key) != expected:
        raise SystemExit(
            f"release evidence provenance {key} mismatch: "
            f"expected {expected!r}, got {payload.get(key)!r}"
        )
for key in ("run_id", "run_attempt"):
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise SystemExit(f"release evidence provenance {key} must be a positive integer")
head_branch = payload.get("head_branch")
if not isinstance(head_branch, str) or not head_branch.strip():
    raise SystemExit("release evidence provenance head_branch must be a non-empty string")

artifacts = payload.get("artifacts")
if not isinstance(artifacts, list):
    raise SystemExit("release evidence provenance artifacts must be an array")
names = [item.get("name") for item in artifacts if isinstance(item, dict)]
if len(names) != len(artifacts) or len(names) != len(set(names)) or set(names) != expected_names:
    raise SystemExit("release evidence provenance artifact names do not match the fixed release contract")
for artifact in artifacts:
    name = artifact["name"]
    size = artifact.get("size_in_bytes")
    digest = artifact.get("digest")
    if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
        raise SystemExit(f"release evidence artifact {name} has invalid size_in_bytes")
    if not isinstance(digest, str) or re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is None:
        raise SystemExit(f"release evidence artifact {name} has invalid digest")
    if artifact.get("expired") is not False:
        raise SystemExit(f"release evidence artifact {name} is expired")

print("[publish-update] release evidence provenance validated")
PY
}

resolve_default_sequence() {
  local app_info_plist="$1"
  local build=""

  build="$(plist_read_value "$app_info_plist" "CFBundleVersion" 2>/dev/null)" \
    || fail "app Info.plist is missing CFBundleVersion"
  [[ "$build" =~ ^[0-9]+$ && "$build" -gt 0 ]] \
    || fail "CFBundleVersion must be a positive integer for immutable release sequencing"
  printf '%s\n' "$build"
}

resolve_default_dmg_path() {
  local app_info_plist="$1"
  local version=""
  local candidate=""

  version="$(plist_read_value "${app_info_plist}" "CFBundleShortVersionString" 2>/dev/null || true)"
  [[ -n "${version}" ]] || fail "app Info.plist is missing CFBundleShortVersionString"

  candidate="${PROJECT_ROOT}/dist/SkyBridgeCompassPro-${version}.dmg"
  [[ -f "${candidate}" ]] || fail "default DMG does not exist for app version ${version}: ${candidate}"
  printf '%s\n' "${candidate}"
}

validate_notarized_dmg_before_publish() {
  local dmg_path="$1"

  command -v xcrun >/dev/null 2>&1 || fail "xcrun is required for notarization verification"
  command -v spctl >/dev/null 2>&1 || fail "spctl is required for Gatekeeper verification"
  xcrun stapler validate "$dmg_path" \
    || fail "DMG does not have a valid stapled notarization ticket: $dmg_path"
  spctl --assess --type open --verbose=4 "$dmg_path" >/dev/null \
    || fail "Gatekeeper rejects the notarized DMG: $dmg_path"
}

verify_release_grade_manifest_provenance() {
  local manifest_path="$1"

  if ! python3 - "$manifest_path" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
attestation = manifest.get("apple_pqc_sdk_build")
if not isinstance(attestation, dict):
    raise SystemExit(1)
expected = {
    "compiled_with_has_apple_pqc_sdk": True,
    "compile_marker": "skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk",
    "probe_mode": "symbol_probe",
    "sdk_name": "macosx",
    "sdk_version": "26.5",
    "swift_target": "arm64-apple-macosx26.0",
    "secure_enclave_symbols_included": True,
    "symbol_set": "cryptokit-pqc-v1",
}
for key, value in expected.items():
    if attestation.get(key) != value:
        print(f"unexpected apple_pqc_sdk_build.{key}: {attestation.get(key)!r}", file=sys.stderr)
        raise SystemExit(1)
if not isinstance(attestation.get("signature"), dict):
    raise SystemExit(1)
PY
  then
    fail "manifest is missing release-grade signed Apple PQC SDK build provenance: $manifest_path"
  fi
}

validate_release_identity() {
  local app_version="$1"
  local app_build="$2"
  local required_tag=""

  [[ "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "official update releases require a numeric three-component app version, got: $app_version"
  [[ "$app_build" =~ ^[0-9]+$ && "$app_build" -gt 0 ]] \
    || fail "official update releases require a positive numeric CFBundleVersion, got: $app_build"
  [[ "$SEQUENCE" == "$app_build" ]] \
    || fail "manifest sequence must equal CFBundleVersion for an immutable update release"

  required_tag="macos-v${app_version}-build-${app_build}"
  [[ "$TAG_NAME" != "stable" ]] || fail "the mutable stable tag is forbidden for official publishing"
  [[ "$TAG_NAME" =~ ^macos-v[0-9]+\.[0-9]+\.[0-9]+-build-[0-9]+$ ]] \
    || fail "release tag must match macos-v<semver>-build-<build>: $TAG_NAME"
  [[ "$TAG_NAME" == "$required_tag" ]] \
    || fail "release tag must exactly match app version/build: expected $required_tag, got $TAG_NAME"
}

validate_local_source_checkout() {
  local local_head=""
  local dirty_paths=""

  [[ "$EXPECTED_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] \
    || fail "--expected-source-sha must be a full lowercase Git commit"
  local_head="$(git -C "$PROJECT_ROOT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    || fail "unable to resolve the local source commit"
  [[ "$local_head" == "$EXPECTED_SOURCE_SHA" ]] \
    || fail "local source commit does not match --expected-source-sha: $local_head"
  dirty_paths="$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)"
  [[ -z "$dirty_paths" ]] \
    || fail "official update publishing requires a clean source checkout"
}

remote_tag_commit_sha() {
  local object_type=""
  local object_sha=""
  local object_line=""
  local depth=0

  object_line="$(gh api "repos/${REPOSITORY}/git/ref/tags/${TAG_NAME}" --jq '[.object.type, .object.sha] | @tsv')" \
    || fail "remote release tag does not exist: $TAG_NAME"
  IFS=$'\t' read -r object_type object_sha <<<"$object_line"

  while [[ "$object_type" == "tag" ]]; do
    depth=$((depth + 1))
    (( depth <= 8 )) || fail "remote tag annotation chain is unexpectedly deep: $TAG_NAME"
    [[ "$object_sha" =~ ^[0-9a-f]{40}$ ]] \
      || fail "remote annotated tag object has an invalid SHA: $object_sha"
    object_line="$(gh api "repos/${REPOSITORY}/git/tags/${object_sha}" --jq '[.object.type, .object.sha] | @tsv')" \
      || fail "unable to dereference annotated remote tag object: $object_sha"
    IFS=$'\t' read -r object_type object_sha <<<"$object_line"
  done

  [[ "$object_type" == "commit" && "$object_sha" =~ ^[0-9a-f]{40}$ ]] \
    || fail "remote tag must ultimately reference a Git commit"
  printf '%s\n' "$object_sha"
}

assert_remote_tag_source() {
  local remote_tag_sha=""

  remote_tag_sha="$(remote_tag_commit_sha)"
  [[ "$remote_tag_sha" == "$EXPECTED_SOURCE_SHA" ]] \
    || fail "remote tag $TAG_NAME resolves to $remote_tag_sha, expected $EXPECTED_SOURCE_SHA"
}

assert_repository_immutable_releases_enabled() {
  local enabled=""

  enabled="$(gh api \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/${REPOSITORY}/immutable-releases" \
    --jq '.enabled')" \
    || fail "unable to prove immutable releases are enabled for $REPOSITORY"
  [[ "$enabled" == "true" ]] \
    || fail "immutable releases must be enabled before official publication"
}

assert_release_absent() {
  local release_tags=""

  release_tags="$(gh api --paginate "repos/${REPOSITORY}/releases?per_page=100" --jq '.[].tag_name')" \
    || fail "unable to enumerate existing GitHub Releases"
  if grep -Fxq "$TAG_NAME" <<<"$release_tags"; then
    fail "a GitHub Release already exists for tag $TAG_NAME; immutable releases are never reused"
  fi
}

expected_asset_names() {
  cut -f2 "$ASSET_HASHES_PATH" | LC_ALL=C sort
}

verify_remote_release_state() {
  local expected_draft="$1"
  local expected_immutable="$2"
  local state_line=""
  local actual_tag=""
  local actual_draft=""
  local actual_immutable=""
  local expected_names_path="${VERIFY_ROOT}/expected-assets.txt"
  local actual_names_path="${VERIFY_ROOT}/actual-assets.txt"

  state_line="$(gh release view "$TAG_NAME" \
    --repo "$REPOSITORY" \
    --json tagName,isDraft,isImmutable \
    --jq '[.tagName, .isDraft, .isImmutable] | @tsv')" \
    || fail "unable to inspect release state for $TAG_NAME"
  IFS=$'\t' read -r actual_tag actual_draft actual_immutable <<<"$state_line"
  [[ "$actual_tag" == "$TAG_NAME" ]] || fail "remote release tag changed during publication"
  [[ "$actual_draft" == "$expected_draft" ]] \
    || fail "unexpected release draft state: expected $expected_draft, got $actual_draft"
  [[ "$actual_immutable" == "$expected_immutable" ]] \
    || fail "unexpected release immutability state: expected $expected_immutable, got $actual_immutable"

  expected_asset_names >"$expected_names_path"
  gh release view "$TAG_NAME" \
    --repo "$REPOSITORY" \
    --json assets \
    --jq '.assets[].name' \
    | LC_ALL=C sort >"$actual_names_path" \
    || fail "unable to inspect release assets for $TAG_NAME"
  cmp -s "$expected_names_path" "$actual_names_path" \
    || fail "remote release asset set does not exactly match the staged asset set"
}

verify_remote_release_asset_bytes() {
  local verify_dir="$1"
  local expected_sha=""
  local asset_name=""
  local downloaded_path=""
  local downloaded_count=""

  rm -rf "$verify_dir"
  mkdir -p "$verify_dir"
  gh release download "$TAG_NAME" \
    --repo "$REPOSITORY" \
    --dir "$verify_dir" \
    || fail "unable to download the complete release asset set for verification"

  if find "$verify_dir" -mindepth 1 -type l -print -quit | grep -q .; then
    fail "downloaded release assets unexpectedly contain a symbolic link"
  fi
  downloaded_count="$(find "$verify_dir" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"
  [[ "$downloaded_count" == "${#STAGED_ASSET_PATHS[@]}" ]] \
    || fail "downloaded release asset count does not match the staged asset count"

  while IFS=$'\t' read -r expected_sha asset_name; do
    downloaded_path="${verify_dir}/${asset_name}"
    [[ -f "$downloaded_path" && ! -L "$downloaded_path" ]] \
      || fail "release asset could not be downloaded back: $asset_name"
    [[ "$(sha256_file "$downloaded_path")" == "$expected_sha" ]] \
      || fail "downloaded release asset sha256 mismatch: $asset_name"
  done <"$ASSET_HASHES_PATH"

  bash "$MANIFEST_VALIDATOR" \
    --manifest-path "${verify_dir}/macos-stable.json" \
    --app-path "$APP_PATH" \
    --dmg-path "${verify_dir}/${DMG_ASSET_NAME}" \
    --require-apple-pqc-sdk-build
  verify_release_grade_manifest_provenance "${verify_dir}/macos-stable.json"
}

[[ -d "$APP_PATH" ]] || fail "app bundle does not exist: $APP_PATH"
APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$APP_INFO_PLIST" ]] || fail "app Info.plist does not exist: $APP_INFO_PLIST"
skybridge_assert_bundle_has_apple_pqc_compile_marker "$APP_PATH" "update manifest source app bundle" \
  || fail "app bundle is missing the Apple PQC SDK compile marker"
if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="$(resolve_default_dmg_path "$APP_INFO_PLIST")"
fi
[[ -f "$DMG_PATH" ]] || fail "DMG does not exist: $DMG_PATH"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail "repository must be a release-safe owner/repo value"
[[ -n "$TAG_NAME" ]] || fail "release tag is required"
[[ -n "$KEY_ID" ]] || fail "--key-id is required"
if [[ -n "$PRIVATE_KEY_FILE" && ! -f "$PRIVATE_KEY_FILE" ]]; then
  fail "private key file does not exist: $PRIVATE_KEY_FILE"
fi
if [[ -z "$PRIVATE_KEY_FILE" && -z "${SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64:-}" ]]; then
  fail "provide --private-key-file or SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64"
fi

if [[ -z "$SEQUENCE" ]]; then
  SEQUENCE="$(resolve_default_sequence "$APP_INFO_PLIST")"
fi
[[ "$SEQUENCE" =~ ^[0-9]+$ && "$SEQUENCE" -gt 0 ]] || fail "manifest sequence must be a positive integer"
APP_VERSION="$(plist_read_value "$APP_INFO_PLIST" "CFBundleShortVersionString" 2>/dev/null)" \
  || fail "app Info.plist is missing CFBundleShortVersionString"
APP_BUILD="$(plist_read_value "$APP_INFO_PLIST" "CFBundleVersion" 2>/dev/null)" \
  || fail "app Info.plist is missing CFBundleVersion"
validate_release_identity "$APP_VERSION" "$APP_BUILD"

DMG_DIR="$(cd "$(dirname "$DMG_PATH")" && pwd)"
DMG_PATH="${DMG_DIR}/$(basename "$DMG_PATH")"

if [[ -z "$PUBLISHED_AT" ]]; then
  PUBLISHED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi
if [[ -z "$EXPIRES_AT" ]]; then
  EXPIRES_AT="$(date -u -v+30d '+%Y-%m-%dT%H:%M:%SZ')"
fi
if [[ -z "$RELEASE_NOTES_URL" ]]; then
  RELEASE_NOTES_URL="https://github.com/${REPOSITORY}/releases/tag/${TAG_NAME}"
fi

DMG_ASSET_NAME="$(basename "$DMG_PATH")"
MANIFEST_ASSET_PATH="$(dirname "$MANIFEST_PATH")/macos-stable.json"
if [[ "$MANIFEST_PATH" != "$MANIFEST_ASSET_PATH" ]]; then
  MANIFEST_PATH="$MANIFEST_ASSET_PATH"
fi
if [[ -z "$PROOF_SUMMARY_PATH" ]]; then
  PROOF_SUMMARY_PATH="${MANIFEST_PATH%.json}.publish-proof.json"
fi
DOWNLOAD_URL="https://github.com/${REPOSITORY}/releases/download/${TAG_NAME}/${DMG_ASSET_NAME}"
EXPECTED_DMG_SHA="$(sha256_file "$DMG_PATH")"
VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-update-publish.XXXXXX")"
STAGING_DIR="${VERIFY_ROOT}/staged"
ASSET_HASHES_PATH="${VERIFY_ROOT}/asset-sha256.tsv"
DRAFT_READBACK_DIR="${VERIFY_ROOT}/draft-readback"
PUBLISHED_READBACK_DIR="${VERIFY_ROOT}/published-readback"
STAGED_ASSET_PATHS=()
DRAFT_CREATED=0
RELEASE_PUBLISHED=0
mkdir -p "$STAGING_DIR"

cleanup() {
  local exit_status=$?
  if [[ "$exit_status" != "0" && "$DRAFT_CREATED" == "1" && "$RELEASE_PUBLISHED" == "0" ]]; then
    echo "[publish-update] NOTICE: pre-publication verification failed; draft ${REPOSITORY}@${TAG_NAME} was intentionally left unpublished for audit and must not be reused" >&2
  fi
  rm -rf "$VERIFY_ROOT"
  exit "$exit_status"
}
trap cleanup EXIT

skybridge_assert_release_stable_toolchain "release_dmg" "${PROJECT_ROOT}/Scripts/verify_xcode_toolchain.sh" "macOS update publishing" || exit 1
validate_notarized_dmg_before_publish "$DMG_PATH"

GENERATOR_ARGS=(
  "$PROJECT_ROOT/Scripts/generate_macos_update_manifest.swift"
  --app-path "$APP_PATH"
  --package-path "$DMG_PATH"
  --download-url "$DOWNLOAD_URL"
  --release-notes-url "$RELEASE_NOTES_URL"
  --key-id "$KEY_ID"
  --sequence "$SEQUENCE"
  --published-at "$PUBLISHED_AT"
  --expires-at "$EXPIRES_AT"
  --output "$MANIFEST_PATH"
  --notarized
)
if [[ -n "$PRIVATE_KEY_FILE" ]]; then
  GENERATOR_ARGS+=(--private-key-file "$PRIVATE_KEY_FILE")
fi

swift "${GENERATOR_ARGS[@]}"

bash "$MANIFEST_VALIDATOR" \
  --manifest-path "$MANIFEST_PATH" \
  --app-path "$APP_PATH" \
  --dmg-path "$DMG_PATH" \
  --require-apple-pqc-sdk-build
verify_release_grade_manifest_provenance "$MANIFEST_PATH"
if [[ "$SKIP_UPLOAD" == "0" ]]; then
  (( EVIDENCE_ASSET_COUNT > 0 )) \
    || fail "at least one --evidence-asset is required for official publishing"
  [[ -n "$EVIDENCE_PROVENANCE_PATH" ]] \
    || fail "--evidence-provenance-path is required for official publishing"
  validate_release_evidence_provenance
fi
validate_proof_summary_destination
prepare_staged_release_assets

# Revalidate the exact read-only bytes that will be passed to gh, rather than
# relying only on the mutable source paths that were used during generation.
bash "$MANIFEST_VALIDATOR" \
  --manifest-path "${STAGING_DIR}/macos-stable.json" \
  --app-path "$APP_PATH" \
  --dmg-path "${STAGING_DIR}/${DMG_ASSET_NAME}" \
  --require-apple-pqc-sdk-build
verify_release_grade_manifest_provenance "${STAGING_DIR}/macos-stable.json"

if [[ "$SKIP_UPLOAD" == "1" ]]; then
  write_publish_proof_summary \
    "local-manifest-only" "false" "false" "false" "$PROOF_SUMMARY_PATH" "false" "false"
  echo "[publish-update] local manifest only: manifest=$MANIFEST_PATH uploaded=false remote_verified=false release_proof=false"
  exit 0
fi

command -v gh >/dev/null 2>&1 || fail "gh CLI is required for upload"
gh auth status >/dev/null || fail "gh CLI is not authenticated"
gh release verify --help >/dev/null \
  || fail "gh CLI does not support immutable release attestation verification"
gh release verify-asset --help >/dev/null \
  || fail "gh CLI does not support immutable release asset verification"
validate_local_source_checkout

assert_repository_immutable_releases_enabled
assert_remote_tag_source
assert_release_absent

if ! gh release create "$TAG_NAME" \
  "${STAGED_ASSET_PATHS[@]}" \
  --repo "$REPOSITORY" \
  --title "SkyBridge Compass Pro ${APP_VERSION} (${APP_BUILD})" \
  --notes "Immutable macOS update release for source ${EXPECTED_SOURCE_SHA}." \
  --draft \
  --latest=false \
  --verify-tag
then
  fail "draft creation or asset attachment failed; no publication was attempted, and any partial draft must be audited and deleted rather than reused"
fi
DRAFT_CREATED=1

verify_remote_release_state "true" "false"
verify_remote_release_asset_bytes "$DRAFT_READBACK_DIR"
assert_remote_tag_source

# Publication is the only transition that makes the already-complete draft
# visible as an official update release. No asset mutation occurs afterward.
if ! gh release edit "$TAG_NAME" \
  --repo "$REPOSITORY" \
  --draft=false \
  --latest \
  --verify-tag
then
  publication_state="$(gh release view "$TAG_NAME" \
    --repo "$REPOSITORY" \
    --json isDraft,isImmutable \
    --jq '[.isDraft, .isImmutable] | @tsv' 2>/dev/null || true)"
  if [[ "$publication_state" == $'false\ttrue' ]]; then
    RELEASE_PUBLISHED=1
    fail "publication command returned failure after GitHub made the complete release immutable; treat this as a publication incident and finish independent attestation verification"
  fi
  fail "publication transition failed; the verified release remains an unpublished draft and must not be reused"
fi
RELEASE_PUBLISHED=1

assert_remote_tag_source
verify_remote_release_state "false" "true"
verify_remote_release_asset_bytes "$PUBLISHED_READBACK_DIR"
gh release verify "$TAG_NAME" --repo "$REPOSITORY"
for staged_asset in "${STAGED_ASSET_PATHS[@]}"; do
  gh release verify-asset "$TAG_NAME" "$staged_asset" --repo "$REPOSITORY"
done

write_publish_proof_summary \
  "published-immutable-and-verified" "true" "true" "true" "$PROOF_SUMMARY_PATH" "true" "true"

echo "[publish-update] published immutable release ${REPOSITORY}@${TAG_NAME} with ${#STAGED_ASSET_PATHS[@]} verified assets"
