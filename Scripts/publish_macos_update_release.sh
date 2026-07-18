#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate and upload the macOS update manifest to GitHub Releases.

Usage:
  publish_macos_update_release.sh [options]

Options:
  --repository <owner/repo>      GitHub repository (default: GITHUB_REPOSITORY or billlza/Skybridge-Compass)
  --tag <tag>                    Stable channel release tag that owns macos-stable.json (default: stable)
  --artifact-tag <tag>           Immutable release tag that owns the DMG (default: macos-v<version>-build-<build>)
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
  --release-provenance-path <path>
                                Validated six-artifact run provenance from the official release workflow
  --skip-upload                  Generate and locally verify only; no upload/read-back release proof
  -h, --help                     Show this help

Without --skip-upload, the DMG is uploaded to an immutable version/build
release and read back before macos-stable.json is switched on the channel tag.
The manifest private key is never accepted as a command-line value.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_ROOT}/Scripts/package_build_policy.sh"
MANIFEST_VALIDATOR="${PROJECT_ROOT}/Scripts/validate_macos_update_manifest.sh"

REPOSITORY="${GITHUB_REPOSITORY:-billlza/Skybridge-Compass}"
TAG_NAME="stable"
ARTIFACT_TAG_NAME=""
REMOTE_SEQUENCE=""
ARTIFACT_RELEASE_IS_PRERELEASE=0
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
RELEASE_PROVENANCE_PATH=""
SKIP_UPLOAD=0

parse_arguments() {
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
    --artifact-tag)
      ARTIFACT_TAG_NAME="${2:-}"
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
    --release-provenance-path)
      RELEASE_PROVENANCE_PATH="${2:-}"
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
}

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

release_asset_exists() {
  local release_tag="$1"
  local asset_name="$2"
  local asset_names=""

  asset_names="$(
    gh release view "$release_tag" \
      --repo "$REPOSITORY" \
      --json assets \
      --jq '.assets[].name'
  )" || fail "could not inspect release assets for ${REPOSITORY}@${release_tag}"
  grep -Fqx -- "$asset_name" <<<"$asset_names"
}

download_release_asset() {
  local release_tag="$1"
  local asset_name="$2"
  local destination_dir="$3"

  mkdir -p "$destination_dir"
  gh release download "$release_tag" \
    --repo "$REPOSITORY" \
    --pattern "$asset_name" \
    --dir "$destination_dir" \
    --clobber
}

read_manifest_sequence() {
  local manifest_path="$1"

  python3 - "$manifest_path" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
sequence = manifest.get("sequence")
if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence <= 0:
    raise SystemExit(1)
print(sequence)
PY
}

require_remote_sequence_monotonic() {
  local proposed_sequence="$1"
  local inspection_dir="$2"
  local remote_manifest="${inspection_dir}/macos-stable.json"
  local remote_sequence=""

  if ! release_asset_exists "$TAG_NAME" "macos-stable.json"; then
    REMOTE_SEQUENCE=""
    echo "[publish-update] no existing stable manifest; accepting initial sequence ${proposed_sequence}"
    return 0
  fi

  download_release_asset "$TAG_NAME" "macos-stable.json" "$inspection_dir"
  remote_sequence="$(read_manifest_sequence "$remote_manifest")" \
    || fail "existing remote stable manifest has an invalid sequence"

  [[ "$proposed_sequence" -gt "$remote_sequence" ]] \
    || fail "manifest sequence ${proposed_sequence} must be greater than remote stable sequence ${remote_sequence}"
  REMOTE_SEQUENCE="$remote_sequence"
  echo "[publish-update] sequence monotonicity verified: remote=${remote_sequence} proposed=${proposed_sequence}"
}

require_remote_sequence_unchanged() {
  local expected_sequence="$1"
  local inspection_dir="$2"
  local remote_manifest="${inspection_dir}/macos-stable.json"
  local current_sequence=""

  if [[ -z "$expected_sequence" ]]; then
    if release_asset_exists "$TAG_NAME" "macos-stable.json"; then
      fail "stable manifest appeared after the initial sequence check; refusing a concurrent channel switch"
    fi
    return 0
  fi

  release_asset_exists "$TAG_NAME" "macos-stable.json" \
    || fail "stable manifest disappeared after the initial sequence check"
  download_release_asset "$TAG_NAME" "macos-stable.json" "$inspection_dir"
  current_sequence="$(read_manifest_sequence "$remote_manifest")" \
    || fail "current remote stable manifest has an invalid sequence"
  [[ "$current_sequence" == "$expected_sequence" ]] \
    || fail "stable manifest sequence changed concurrently from ${expected_sequence} to ${current_sequence}"
}

ensure_unique_dmg_uploaded() {
  local verification_dir="$1"
  local expected_sha="$2"
  local downloaded_dmg="${verification_dir}/${DMG_ASSET_NAME}"

  if release_asset_exists "$ARTIFACT_TAG_NAME" "$DMG_ASSET_NAME"; then
    download_release_asset "$ARTIFACT_TAG_NAME" "$DMG_ASSET_NAME" "$verification_dir"
    [[ "$(sha256_file "$downloaded_dmg")" == "$expected_sha" ]] \
      || fail "release already contains ${DMG_ASSET_NAME} with different bytes; refusing to overwrite immutable version asset"
    echo "[publish-update] reusing byte-identical existing DMG asset: ${DMG_ASSET_NAME}"
    return 0
  fi

  gh release upload "$ARTIFACT_TAG_NAME" \
    "$DMG_PATH" \
    --repo "$REPOSITORY"

  download_release_asset "$ARTIFACT_TAG_NAME" "$DMG_ASSET_NAME" "$verification_dir"
  [[ "$(sha256_file "$downloaded_dmg")" == "$expected_sha" ]] \
    || fail "uploaded DMG sha256 does not match the local release artifact"
  echo "[publish-update] unique DMG uploaded and verified before stable manifest switch"
}

ensure_artifact_release() {
  local expected_commit=""
  local remote_commit=""
  local is_draft=""
  local is_prerelease=""

  expected_commit="$(git -C "$PROJECT_ROOT" rev-parse HEAD)" \
    || fail "could not resolve the release source commit"

  if gh release view "$ARTIFACT_TAG_NAME" --repo "$REPOSITORY" >/dev/null 2>&1; then
    remote_commit="$(gh api "repos/${REPOSITORY}/commits/${ARTIFACT_TAG_NAME}" --jq '.sha')" \
      || fail "could not resolve existing artifact tag ${ARTIFACT_TAG_NAME}"
    [[ "$remote_commit" == "$expected_commit" ]] \
      || fail "artifact tag ${ARTIFACT_TAG_NAME} points to ${remote_commit}, expected release commit ${expected_commit}"
    is_draft="$(gh release view "$ARTIFACT_TAG_NAME" --repo "$REPOSITORY" --json isDraft --jq '.isDraft')"
    [[ "$is_draft" == "false" ]] \
      || fail "artifact release ${ARTIFACT_TAG_NAME} is still a draft and cannot back a public stable manifest"
    is_prerelease="$(gh release view "$ARTIFACT_TAG_NAME" --repo "$REPOSITORY" --json isPrerelease --jq '.isPrerelease')"
    if [[ "$is_prerelease" == "true" ]]; then
      ARTIFACT_RELEASE_IS_PRERELEASE=1
    fi
    return 0
  fi

  gh release create "$ARTIFACT_TAG_NAME" \
    --repo "$REPOSITORY" \
    --target "$expected_commit" \
    --title "SkyBridge Compass ${APP_VERSION} for macOS" \
    --notes "Signed and notarized SkyBridge Compass ${APP_VERSION} for macOS." \
    --prerelease \
    --latest=false
  ARTIFACT_RELEASE_IS_PRERELEASE=1
}

promote_artifact_release_if_needed() {
  if [[ "$ARTIFACT_RELEASE_IS_PRERELEASE" != "1" ]]; then
    return 0
  fi

  gh release edit "$ARTIFACT_TAG_NAME" \
    --repo "$REPOSITORY" \
    --prerelease=false \
    --latest=false
  ARTIFACT_RELEASE_IS_PRERELEASE=0
}

validate_packaged_source_provenance() {
  local app_git_commit=""
  local app_git_dirty_state=""
  local source_git_commit=""
  local source_dirty_state=""

  app_git_commit="$(plist_read_value "$APP_INFO_PLIST" "SkyBridgePackagingGitCommit" 2>/dev/null)" \
    || fail "app bundle is missing SkyBridgePackagingGitCommit"
  app_git_dirty_state="$(plist_read_value "$APP_INFO_PLIST" "SkyBridgePackagingGitDirtyState" 2>/dev/null)" \
    || fail "app bundle is missing SkyBridgePackagingGitDirtyState"
  source_git_commit="$(git -C "$PROJECT_ROOT" rev-parse HEAD)" \
    || fail "could not resolve publisher source commit"
  source_dirty_state="$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)" \
    || fail "could not inspect publisher source worktree"

  [[ "$app_git_commit" == "$source_git_commit" ]] \
    || fail "packaged app commit ${app_git_commit} does not match publisher source commit ${source_git_commit}"
  [[ "$app_git_dirty_state" == "clean" ]] \
    || fail "packaged app provenance is not clean: ${app_git_dirty_state}"
  [[ -z "$source_dirty_state" ]] \
    || fail "publisher source worktree is dirty; publish only the exact committed source used by the packaged app"
}

validate_release_execution_context() {
  local source_git_commit=""

  [[ "${GITHUB_ACTIONS:-}" == "true" ]] \
    || fail "stable channel publication is restricted to the official GitHub Actions release workflow"
  [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]] \
    || fail "stable channel publication requires a workflow_dispatch release run"
  [[ "${GITHUB_REF:-}" == "refs/heads/main" ]] \
    || fail "stable channel publication is restricted to refs/heads/main"
  [[ "${GITHUB_WORKFLOW_REF:-}" == */.github/workflows/macos-release-readiness.yml@* ]] \
    || fail "stable channel publication requires macos-release-readiness.yml"
  [[ "${GITHUB_REPOSITORY:-}" == "$REPOSITORY" ]] \
    || fail "GitHub Actions repository does not match --repository"
  source_git_commit="$(git -C "$PROJECT_ROOT" rev-parse HEAD)" \
    || fail "could not resolve stable publication source commit"
  [[ "${GITHUB_SHA:-}" == "$source_git_commit" ]] \
    || fail "GitHub Actions SHA does not match the publisher source commit"
  [[ -n "$RELEASE_PROVENANCE_PATH" && -f "$RELEASE_PROVENANCE_PATH" ]] \
    || fail "--release-provenance-path must name the validated six-artifact run provenance"

  python3 - "$RELEASE_PROVENANCE_PATH" "$REPOSITORY" "$source_git_commit" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected_repository = sys.argv[2]
expected_sha = sys.argv[3]
try:
    value = json.loads(path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid release artifact provenance: {exc}")

errors = []
if not isinstance(value, dict):
    errors.append("root must be an object")
else:
    if value.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    if value.get("repository") != expected_repository:
        errors.append("repository does not match the publish target")
    if value.get("status") != "completed" or value.get("conclusion") != "success":
        errors.append("producer run must be completed successfully")
    if value.get("head_sha") != expected_sha:
        errors.append("producer run head_sha does not match the publish commit")
    if not isinstance(value.get("run_id"), int) or value["run_id"] <= 0:
        errors.append("run_id must be positive")
    if not isinstance(value.get("run_attempt"), int) or value["run_attempt"] <= 0:
        errors.append("run_attempt must be positive")

    artifacts = value.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != 6:
        errors.append("exactly six validated release artifacts are required")
    else:
        names = []
        for index, artifact in enumerate(artifacts):
            if not isinstance(artifact, dict):
                errors.append(f"artifact[{index}] must be an object")
                continue
            name = artifact.get("name")
            if not isinstance(name, str) or not name.strip():
                errors.append(f"artifact[{index}].name must be non-empty")
            else:
                names.append(name)
            if artifact.get("expired") is not False:
                errors.append(f"artifact[{index}] must not be expired")
            digest = artifact.get("digest")
            if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
                errors.append(f"artifact[{index}].digest must be sha256")
            size = artifact.get("size_in_bytes")
            if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
                errors.append(f"artifact[{index}].size_in_bytes must be positive")
        if len(names) != len(set(names)):
            errors.append("release artifact names must be unique")

if errors:
    for error in errors:
        print(f"[publish-update] release provenance: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

preserve_previous_manifest() {
  local previous_manifest="$1"
  local remote_sequence="$2"
  local verification_dir="$3"
  local backup_asset_name="previous-macos-stable-sequence-${remote_sequence}.json"
  local backup_path="${verification_dir}/${backup_asset_name}"
  local downloaded_backup="${verification_dir}/downloaded/${backup_asset_name}"

  [[ -f "$previous_manifest" ]] || return 0
  mkdir -p "$verification_dir"
  cp "$previous_manifest" "$backup_path"

  if release_asset_exists "$ARTIFACT_TAG_NAME" "$backup_asset_name"; then
    download_release_asset "$ARTIFACT_TAG_NAME" "$backup_asset_name" "${verification_dir}/downloaded"
    cmp -s "$backup_path" "$downloaded_backup" \
      || fail "artifact release contains a different ${backup_asset_name}; refusing to overwrite release recovery evidence"
    return 0
  fi

  gh release upload "$ARTIFACT_TAG_NAME" \
    "$backup_path" \
    --repo "$REPOSITORY"
  download_release_asset "$ARTIFACT_TAG_NAME" "$backup_asset_name" "${verification_dir}/downloaded"
  cmp -s "$backup_path" "$downloaded_backup" \
    || fail "previous stable manifest backup could not be read back byte-for-byte"
}

write_publish_proof_summary() {
  local status="$1"
  local uploaded="$2"
  local remote_verified="$3"
  local release_proof="$4"
  local proof_summary_path="$5"

  [[ -n "$proof_summary_path" ]] || return 0

  python3 - \
    "$proof_summary_path" \
    "$status" \
    "$uploaded" \
    "$remote_verified" \
    "$release_proof" \
    "$REPOSITORY" \
    "$TAG_NAME" \
    "$ARTIFACT_TAG_NAME" \
    "$(basename "$APP_PATH")" \
    "$DMG_ASSET_NAME" \
    "$(basename "$MANIFEST_PATH")" \
    "$EXPECTED_DMG_SHA" <<'PY'
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
    repository,
    tag_name,
    artifact_tag_name,
    app_bundle_name,
    dmg_asset_name,
    manifest_asset_name,
    expected_dmg_sha,
) = sys.argv[1:]

summary = {
    "profile": "macos-update-release-publish-proof",
    "status": status,
    "generated_at_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "repository": repository,
    "tag": tag_name,
    "artifact_tag": artifact_tag_name,
    "app_bundle_name": app_bundle_name,
    "dmg_asset_name": dmg_asset_name,
    "dmg_sha256": expected_dmg_sha,
    "manifest_asset_name": manifest_asset_name,
    "local_manifest_validated": True,
    "uploaded": uploaded == "true",
    "remote_verified": remote_verified == "true",
    "release_proof": release_proof == "true",
}
path = pathlib.Path(proof_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  echo "[publish-update] proof summary: $proof_summary_path"
}

resolve_default_sequence() {
  local app_info_plist="$1"
  local build=""

  build="$(plist_read_value "$app_info_plist" "CFBundleVersion" 2>/dev/null || true)"
  if [[ "$build" =~ ^[0-9]+$ && "$build" -gt 0 ]]; then
    printf '%s\n' "$build"
    return 0
  fi

  date -u '+%Y%m%d%H%M%S'
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

verify_uploaded_release_assets() {
  local verify_dir="$1"
  local dmg_asset_name="$2"
  local expected_dmg_sha="$3"
  local manifest_path="$4"
  local app_path="$5"
  local downloaded_dmg="${verify_dir}/artifact/${dmg_asset_name}"
  local downloaded_manifest="${verify_dir}/channel/macos-stable.json"
  local manifest_sha=""

  download_release_asset "$ARTIFACT_TAG_NAME" "$dmg_asset_name" "${verify_dir}/artifact"
  download_release_asset "$TAG_NAME" "macos-stable.json" "${verify_dir}/channel"

  [[ -f "$downloaded_dmg" ]] || fail "uploaded DMG asset could not be downloaded back: $dmg_asset_name"
  [[ -f "$downloaded_manifest" ]] || fail "uploaded stable manifest could not be downloaded back"
  [[ "$(sha256_file "$downloaded_dmg")" == "$expected_dmg_sha" ]] \
    || fail "downloaded DMG sha256 does not match the uploaded local DMG"
  cmp -s "$manifest_path" "$downloaded_manifest" \
    || fail "downloaded macos-stable.json does not match the generated manifest"

  manifest_sha="$(
    python3 - "$downloaded_manifest" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(manifest.get("sha256", ""))
PY
  )"
  [[ "$manifest_sha" == "$expected_dmg_sha" ]] \
    || fail "manifest sha256 (${manifest_sha:-missing}) does not match uploaded DMG sha256"

  bash "$MANIFEST_VALIDATOR" \
    --manifest-path "$downloaded_manifest" \
    --app-path "$app_path" \
    --dmg-path "$downloaded_dmg" \
    --require-apple-pqc-sdk-build

  if ! python3 - "$downloaded_manifest" <<'PY'
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
    fail "uploaded manifest is missing release-grade signed Apple PQC SDK build provenance"
  fi
}

publish_release_assets() {
  validate_release_execution_context
  command -v gh >/dev/null 2>&1 || fail "gh CLI is required for upload"
  gh auth status >/dev/null || fail "gh CLI is not authenticated"

  if ! gh release view "$TAG_NAME" --repo "$REPOSITORY" >/dev/null 2>&1; then
    gh release create "$TAG_NAME" \
      --repo "$REPOSITORY" \
      --title "SkyBridge Compass stable macOS updates" \
      --notes "Stable macOS update channel assets for SkyBridge Compass." \
      --latest=false
  fi

  require_remote_sequence_monotonic "$SEQUENCE" "$VERIFY_DIR/previous"
  ensure_artifact_release
  if [[ -n "$REMOTE_SEQUENCE" ]]; then
    preserve_previous_manifest \
      "$VERIFY_DIR/previous/macos-stable.json" \
      "$REMOTE_SEQUENCE" \
      "$VERIFY_DIR/recovery"
  fi
  ensure_unique_dmg_uploaded "$VERIFY_DIR/dmg" "$EXPECTED_DMG_SHA"
  promote_artifact_release_if_needed
  require_remote_sequence_unchanged "$REMOTE_SEQUENCE" "$VERIFY_DIR/pre-switch"

  # The stable manifest is the channel switch. Keep the previous manifest live
  # while the immutable, versioned DMG is uploaded and read back. Replace only
  # the manifest after the new package bytes are proven available.
  gh release upload "$TAG_NAME" \
    "$MANIFEST_PATH" \
    --repo "$REPOSITORY" \
    --clobber

  verify_uploaded_release_assets \
    "$VERIFY_DIR/final" \
    "$DMG_ASSET_NAME" \
    "$EXPECTED_DMG_SHA" \
    "$MANIFEST_PATH" \
    "$APP_PATH"
  write_publish_proof_summary "uploaded-and-verified" "true" "true" "true" "$PROOF_SUMMARY_PATH"

  echo "[publish-update] uploaded $DMG_ASSET_NAME to ${REPOSITORY}@${ARTIFACT_TAG_NAME} and switched macos-stable.json at ${TAG_NAME}"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

parse_arguments "$@"
[[ -d "$APP_PATH" ]] || fail "app bundle does not exist: $APP_PATH"
APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$APP_INFO_PLIST" ]] || fail "app Info.plist does not exist: $APP_INFO_PLIST"
APP_VERSION="$(plist_read_value "$APP_INFO_PLIST" "CFBundleShortVersionString" 2>/dev/null)" \
  || fail "app Info.plist is missing CFBundleShortVersionString"
APP_BUILD="$(plist_read_value "$APP_INFO_PLIST" "CFBundleVersion" 2>/dev/null)" \
  || fail "app Info.plist is missing CFBundleVersion"
if [[ -z "$ARTIFACT_TAG_NAME" ]]; then
  ARTIFACT_TAG_NAME="macos-v${APP_VERSION}-build-${APP_BUILD}"
fi
skybridge_assert_bundle_has_apple_pqc_compile_marker "$APP_PATH" "update manifest source app bundle" \
  || fail "app bundle is missing the Apple PQC SDK compile marker"
if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="$(resolve_default_dmg_path "$APP_INFO_PLIST")"
fi
[[ -f "$DMG_PATH" ]] || fail "DMG does not exist: $DMG_PATH"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "repository must be owner/repo"
[[ "$TAG_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "release tag is invalid"
[[ "$ARTIFACT_TAG_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "artifact release tag is invalid"
[[ "$ARTIFACT_TAG_NAME" != "$TAG_NAME" ]] \
  || fail "artifact release tag must differ from the mutable channel tag"
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

DMG_DIR="$(cd "$(dirname "$DMG_PATH")" && pwd)"
DMG_PATH="${DMG_DIR}/$(basename "$DMG_PATH")"

if [[ -z "$PUBLISHED_AT" ]]; then
  PUBLISHED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi
if [[ -z "$EXPIRES_AT" ]]; then
  EXPIRES_AT="$(date -u -v+30d '+%Y-%m-%dT%H:%M:%SZ')"
fi
if [[ -z "$RELEASE_NOTES_URL" ]]; then
  RELEASE_NOTES_URL="https://github.com/${REPOSITORY}/releases/tag/${ARTIFACT_TAG_NAME}"
fi

DMG_ASSET_NAME="$(basename "$DMG_PATH")"
MANIFEST_ASSET_PATH="$(dirname "$MANIFEST_PATH")/macos-stable.json"
if [[ "$MANIFEST_PATH" != "$MANIFEST_ASSET_PATH" ]]; then
  MANIFEST_PATH="$MANIFEST_ASSET_PATH"
fi
if [[ -z "$PROOF_SUMMARY_PATH" ]]; then
  PROOF_SUMMARY_PATH="${MANIFEST_PATH%.json}.publish-proof.json"
fi
DOWNLOAD_URL="https://github.com/${REPOSITORY}/releases/download/${ARTIFACT_TAG_NAME}/${DMG_ASSET_NAME}"
EXPECTED_DMG_SHA="$(sha256_file "$DMG_PATH")"
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-update-publish.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT

validate_packaged_source_provenance
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

if [[ "$SKIP_UPLOAD" == "1" ]]; then
  write_publish_proof_summary "local-manifest-only" "false" "false" "false" "$PROOF_SUMMARY_PATH"
  echo "[publish-update] local manifest only: manifest=$MANIFEST_PATH uploaded=false remote_verified=false release_proof=false"
  exit 0
fi

validate_packaged_source_provenance
publish_release_assets
