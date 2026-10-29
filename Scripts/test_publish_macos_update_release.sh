#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${ROOT_DIR}/Scripts/publish_macos_update_release.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-immutable-publisher-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

PROJECT_ROOT="${TEST_ROOT}/project"
FAKE_BIN="${TEST_ROOT}/bin"
REMOTE_ROOT="${TEST_ROOT}/remote"
mkdir -p "$PROJECT_ROOT/Scripts" "$PROJECT_ROOT/dist" "$FAKE_BIN" "$REMOTE_ROOT"

cp "$TARGET" "$PROJECT_ROOT/Scripts/"
cp "$ROOT_DIR/Scripts/package_build_policy.sh" "$PROJECT_ROOT/Scripts/"
cp "$ROOT_DIR/Scripts/toolchain_release_pin.sh" "$PROJECT_ROOT/Scripts/"
cp "$ROOT_DIR/Scripts/verify_xcode_toolchain.sh" "$PROJECT_ROOT/Scripts/"
cp "$ROOT_DIR/Scripts/generate_macos_update_manifest.swift" "$PROJECT_ROOT/Scripts/"
cp "$ROOT_DIR/Scripts/validate_macos_update_manifest.sh" "$PROJECT_ROOT/Scripts/"
chmod +x "$PROJECT_ROOT/Scripts/"*.sh

APP_PATH="$PROJECT_ROOT/dist/SkyBridge Compass Pro.app"
DMG_PATH="$PROJECT_ROOT/dist/SkyBridgeCompassPro-1.2.3.dmg"
EVIDENCE_PATH="$PROJECT_ROOT/dist/macos-release-evidence.tar.gz"
PROVENANCE_PATH="$PROJECT_ROOT/dist/release-artifact-run-provenance.json"
KEY_PATH="$PROJECT_ROOT/dist/update-key.txt"
PROOF_PATH="$PROJECT_ROOT/dist/macos-stable.publish-proof.json"
TAG_NAME="macos-v1.2.3-build-20260719010101"
mkdir -p "$APP_PATH/Contents/MacOS"
python3 - "$APP_PATH/Contents/Info.plist" <<'PY'
import plistlib
import sys

payload = {
    "CFBundleIdentifier": "com.skybridge.compass.pro",
    "CFBundleShortVersionString": "1.2.3",
    "CFBundleVersion": "20260719010101",
    "LSMinimumSystemVersion": "14.0",
}
with open(sys.argv[1], "wb") as handle:
    plistlib.dump(payload, handle)
PY
printf '%s\n' 'skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk' >"$APP_PATH/Contents/MacOS/SkyBridgeCompassApp"
chmod +x "$APP_PATH/Contents/MacOS/SkyBridgeCompassApp"
printf '%s\n' 'notarized-dmg-fixture' >"$DMG_PATH"
printf '%s\n' 'public-redacted-release-evidence' >"$EVIDENCE_PATH"
printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' >"$KEY_PATH"
printf '%s\n' 'dist/' >"$PROJECT_ROOT/.gitignore"

(
  cd "$PROJECT_ROOT"
  git init -q
  git config user.name "Release Test"
  git config user.email "release-test@example.invalid"
  git add .
  git commit -qm "publisher fixture"
)
SOURCE_SHA="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
python3 - "$PROVENANCE_PATH" "$SOURCE_SHA" <<'PY'
import json
import sys
from pathlib import Path

names = [
    "real-device-connectivity-matrix-public-redacted",
    "real-device-p2p-remote-smoke-public-redacted",
    "real-device-webrtc-smoke-public-redacted",
    "real-device-file-transfer-smoke-public-redacted",
]
payload = {
    "schema_version": 1,
    "repository": "example/skybridge",
    "run_id": 123456,
    "run_attempt": 1,
    "workflow_path": ".github/workflows/real-device-release-gate.yml",
    "event": "workflow_dispatch",
    "status": "completed",
    "conclusion": "success",
    "head_sha": sys.argv[2],
    "head_branch": "release/1.2.3",
    "artifacts": [
        {
            "name": name,
            "size_in_bytes": 1024 + index,
            "digest": "sha256:" + f"{index:064x}",
            "expired": False,
        }
        for index, name in enumerate(names, start=1)
    ],
}
Path(sys.argv[1]).write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
PY

cat >"$FAKE_BIN/bash" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == */validate_macos_update_manifest.sh ]]; then
  [[ "${FAKE_FAIL_STAGE:-}" != "manifest" ]]
  exit $?
fi
exec /bin/bash "$@"
SH

cat >"$FAKE_BIN/xcodebuild" <<'SH'
#!/bin/bash
printf '%s\n' 'Xcode 26.6' 'Build version 17F113'
SH

cat >"$FAKE_BIN/xcrun" <<'SH'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "stapler" ]]; then
  [[ "${FAKE_FAIL_STAGE:-}" != "notarization" ]]
  exit $?
fi
if [[ "${1:-}" == "swift" && "${2:-}" == "--version" ]]; then
  echo 'Apple Swift version 6.3.3 (swiftlang-test clang-test)'
  exit 0
fi
if [[ "${1:-}" == "--sdk" && "${2:-}" == "macosx" && "${3:-}" == "--show-sdk-version" ]]; then
  echo '26.5'
  exit 0
fi
echo "unexpected fake xcrun invocation: $*" >&2
exit 64
SH

cat >"$FAKE_BIN/spctl" <<'SH'
#!/bin/bash
set -euo pipefail
[[ "${FAKE_FAIL_STAGE:-}" != "gatekeeper" ]]
SH

cat >"$FAKE_BIN/swift" <<'SH'
#!/bin/bash
set -euo pipefail
python3 - "$@" <<'PY'
import base64
import hashlib
import json
import plistlib
import sys
from pathlib import Path

args = sys.argv[2:]
values = {}
index = 0
while index < len(args):
    key = args[index]
    if key == "--notarized":
        index += 1
        continue
    values[key] = args[index + 1]
    index += 2

with (Path(values["--app-path"]) / "Contents" / "Info.plist").open("rb") as handle:
    info = plistlib.load(handle)
package = Path(values["--package-path"])
signature = {
    "algorithm": "ed25519",
    "key_id": values["--key-id"],
    "value": base64.b64encode(bytes(64)).decode("ascii"),
}
manifest = {
    "schema_version": 1,
    "bundle_id": info["CFBundleIdentifier"],
    "platform": "macos",
    "channel": "stable",
    "version": info["CFBundleShortVersionString"],
    "build": info["CFBundleVersion"],
    "sequence": int(values["--sequence"]),
    "published_at": values["--published-at"],
    "expires_at": values["--expires-at"],
    "minimum_system_version": info["LSMinimumSystemVersion"],
    "release_notes_url": values["--release-notes-url"],
    "download_url": values["--download-url"],
    "sha256": hashlib.sha256(package.read_bytes()).hexdigest(),
    "package_format": "dmg",
    "distribution": "developer-id",
    "notarized": True,
    "size_bytes": package.stat().st_size,
    "apple_pqc_sdk_build": {
        "compiled_with_has_apple_pqc_sdk": True,
        "compile_marker": "skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk",
        "probe_mode": "symbol_probe",
        "sdk_name": "macosx",
        "sdk_version": "26.5",
        "swift_target": "arm64-apple-macosx26.0",
        "secure_enclave_symbols_included": True,
        "symbol_set": "cryptokit-pqc-v1",
        "signature": signature,
    },
    "signature": signature,
}
output = Path(values["--output"])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
PY
SH

cat >"$FAKE_BIN/gh" <<'SH'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_GH_LOG}"
remote_dir="${FAKE_REMOTE_ROOT}/assets"
state_path="${FAKE_REMOTE_ROOT}/state"
tag_name="${FAKE_TAG_NAME}"

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  exit 0
fi

if [[ "${1:-}" == "api" ]]; then
  endpoint=""
  for argument in "$@"; do
    case "$argument" in
      repos/*/git/ref/tags/*|repos/*/git/tags/*|repos/*/releases\?*|repos/*/immutable-releases) endpoint="$argument" ;;
    esac
  done
  case "$endpoint" in
    repos/*/git/ref/tags/*)
      [[ "${FAKE_FAIL_STAGE:-}" != "missing_tag" ]] || exit 1
      tag_query_count_path="${FAKE_REMOTE_ROOT}/tag-query-count"
      tag_query_count=0
      [[ ! -f "$tag_query_count_path" ]] || tag_query_count="$(cat "$tag_query_count_path")"
      tag_query_count=$((tag_query_count + 1))
      printf '%s\n' "$tag_query_count" >"$tag_query_count_path"
      target_sha="${FAKE_SOURCE_SHA}"
      [[ "${FAKE_FAIL_STAGE:-}" != "remote_tag_mismatch" ]] || target_sha="0000000000000000000000000000000000000000"
      if [[ "${FAKE_FAIL_STAGE:-}" == "tag_moved_before_publish" && "$tag_query_count" -ge 2 ]]; then
        target_sha="0000000000000000000000000000000000000000"
      fi
      if [[ "${FAKE_TAG_MODE:-lightweight}" == "annotated" ]]; then
        printf 'tag\t1111111111111111111111111111111111111111\n'
      else
        printf 'commit\t%s\n' "$target_sha"
      fi
      ;;
    repos/*/git/tags/*)
      target_sha="${FAKE_SOURCE_SHA}"
      [[ "${FAKE_FAIL_STAGE:-}" != "remote_tag_mismatch" ]] || target_sha="0000000000000000000000000000000000000000"
      printf 'commit\t%s\n' "$target_sha"
      ;;
    repos/*/releases\?*)
      [[ "${FAKE_FAIL_STAGE:-}" != "release_list" ]] || exit 1
      [[ "${FAKE_FAIL_STAGE:-}" != "existing_release" ]] || printf '%s\n' "$tag_name"
      ;;
    repos/*/immutable-releases)
      [[ "${FAKE_FAIL_STAGE:-}" != "immutability_lookup" ]] || exit 1
      if [[ "${FAKE_FAIL_STAGE:-}" == "immutability_disabled" ]]; then
        echo 'false'
      else
        echo 'true'
      fi
      ;;
    *)
      echo "unexpected fake gh api invocation: $*" >&2
      exit 64
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "release" && "${2:-}" == "create" ]]; then
  [[ "${FAKE_FAIL_STAGE:-}" != "create" ]] || exit 1
  rm -rf "$remote_dir"
  mkdir -p "$remote_dir"
  shift 3
  while [[ "$#" -gt 0 && "$1" != --* ]]; do
    cp "$1" "$remote_dir/$(basename "$1")"
    shift
  done
  printf '%s\n' 'draft=true' 'immutable=false' >"$state_path"
  exit 0
fi

if [[ "${1:-}" == "release" && "${2:-}" == "view" ]]; then
  [[ -f "$state_path" ]] || exit 1
  if [[ "$*" == *"--json assets"* ]]; then
    find "$remote_dir" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort
    [[ "${FAKE_FAIL_STAGE:-}" != "draft_asset_set" ]] || echo 'unexpected.asset'
  else
    # shellcheck disable=SC1090
    source "$state_path"
    printf '%s\t%s\t%s\n' "$tag_name" "$draft" "$immutable"
  fi
  exit 0
fi

if [[ "${1:-}" == "release" && "${2:-}" == "download" ]]; then
  destination=""
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "--dir" ]]; then
      destination="$2"
      break
    fi
    shift
  done
  [[ -n "$destination" ]] || exit 64
  cp "$remote_dir/"* "$destination/"
  # shellcheck disable=SC1090
  source "$state_path"
  if [[ "${FAKE_FAIL_STAGE:-}" == "draft_readback" && "$draft" == "true" ]]; then
    printf '%s\n' 'corrupt' >>"$destination/SkyBridgeCompassPro-1.2.3.dmg"
  fi
  if [[ "${FAKE_FAIL_STAGE:-}" == "published_readback" && "$draft" == "false" ]]; then
    printf '%s\n' 'corrupt' >>"$destination/SkyBridgeCompassPro-1.2.3.dmg"
  fi
  exit 0
fi

if [[ "${1:-}" == "release" && "${2:-}" == "edit" ]]; then
  [[ "${FAKE_FAIL_STAGE:-}" != "publish" ]] || exit 1
  printf '%s\n' 'draft=false' 'immutable=true' >"$state_path"
  exit 0
fi

if [[ "${1:-}" == "release" && "${2:-}" == "verify" ]]; then
  [[ "$*" != *"--help"* ]] || exit 0
  [[ "${FAKE_FAIL_STAGE:-}" != "release_verify" ]]
  exit $?
fi

if [[ "${1:-}" == "release" && "${2:-}" == "verify-asset" ]]; then
  [[ "$*" != *"--help"* ]] || exit 0
  [[ "${FAKE_FAIL_STAGE:-}" != "asset_verify" ]]
  exit $?
fi

echo "unexpected fake gh invocation: $*" >&2
exit 64
SH

chmod +x "$FAKE_BIN/"*

run_publisher() {
  local failure_stage="$1"
  local output_path="$2"

  rm -rf "$REMOTE_ROOT"
  mkdir -p "$REMOTE_ROOT"
  : >"$TEST_ROOT/gh.log"
  rm -f "$PROOF_PATH"
  FAKE_FAIL_STAGE="$failure_stage" \
  FAKE_SOURCE_SHA="$SOURCE_SHA" \
  FAKE_TAG_NAME="$TAG_NAME" \
  FAKE_REMOTE_ROOT="$REMOTE_ROOT" \
  FAKE_GH_LOG="$TEST_ROOT/gh.log" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash "$PROJECT_ROOT/Scripts/publish_macos_update_release.sh" \
      --repository example/skybridge \
      --tag "$TAG_NAME" \
      --expected-source-sha "$SOURCE_SHA" \
      --app-path "$APP_PATH" \
      --dmg-path "$DMG_PATH" \
      --manifest-path "$PROJECT_ROOT/dist/macos-stable.json" \
      --key-id test-release-key \
      --private-key-file "$KEY_PATH" \
      --evidence-provenance-path "$PROVENANCE_PATH" \
      --evidence-asset "$EVIDENCE_PATH" \
      --sequence 20260719010101 \
      --published-at 2026-07-19T00:00:00Z \
      --expires-at 2026-08-18T00:00:00Z \
      --proof-summary-path "$PROOF_PATH" >"$output_path" 2>&1
}

expect_failure_before_create() {
  local stage="$1"
  if run_publisher "$stage" "$TEST_ROOT/${stage}.log"; then
    echo "expected publisher failure at stage $stage" >&2
    cat "$TEST_ROOT/${stage}.log" >&2
    cat "$TEST_ROOT/gh.log" >&2
    exit 1
  fi
  if grep -q '^release create ' "$TEST_ROOT/gh.log"; then
    echo "publisher mutated GitHub before rejecting stage $stage" >&2
    exit 1
  fi
}

expect_unpublished_draft_failure() {
  local stage="$1"
  if run_publisher "$stage" "$TEST_ROOT/${stage}.log"; then
    echo "expected publisher failure at stage $stage" >&2
    exit 1
  fi
  grep -q '^release create ' "$TEST_ROOT/gh.log"
  if grep -q '^release edit ' "$TEST_ROOT/gh.log" && [[ "$stage" != "publish" ]]; then
    echo "publisher attempted publication after pre-publication failure at stage $stage" >&2
    exit 1
  fi
  grep -Fxq 'draft=true' "$REMOTE_ROOT/state"
  grep -Fxq 'immutable=false' "$REMOTE_ROOT/state"
}

run_without_evidence() {
  local mode="$1"
  local output_path="$2"
  local command_args=(
    --repository example/skybridge
    --tag "$TAG_NAME"
    --expected-source-sha "$SOURCE_SHA"
    --app-path "$APP_PATH"
    --dmg-path "$DMG_PATH"
    --manifest-path "$PROJECT_ROOT/dist/macos-stable.json"
    --key-id test-release-key
    --private-key-file "$KEY_PATH"
    --sequence 20260719010101
    --published-at 2026-07-19T00:00:00Z
    --expires-at 2026-08-18T00:00:00Z
    --proof-summary-path "$PROOF_PATH"
  )

  [[ "$mode" != "local" ]] || command_args+=(--skip-upload)
  rm -rf "$REMOTE_ROOT"
  mkdir -p "$REMOTE_ROOT"
  : >"$TEST_ROOT/gh.log"
  rm -f "$PROOF_PATH"
  FAKE_FAIL_STAGE="" \
  FAKE_SOURCE_SHA="$SOURCE_SHA" \
  FAKE_TAG_NAME="$TAG_NAME" \
  FAKE_REMOTE_ROOT="$REMOTE_ROOT" \
  FAKE_GH_LOG="$TEST_ROOT/gh.log" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash "$PROJECT_ROOT/Scripts/publish_macos_update_release.sh" \
      "${command_args[@]}" >"$output_path" 2>&1
}

expect_provenance_failure() {
  local mode="$1"
  local backup_path="$TEST_ROOT/provenance-${mode}.backup.json"

  cp "$PROVENANCE_PATH" "$backup_path"
  python3 - "$PROVENANCE_PATH" "$mode" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
mode = sys.argv[2]
payload = json.loads(path.read_text(encoding="utf-8"))
if mode == "source-sha":
    payload["head_sha"] = "0" * 40
elif mode == "workflow":
    payload["workflow_path"] = ".github/workflows/untrusted.yml"
elif mode == "artifact-set":
    payload["artifacts"] = payload["artifacts"][:-1]
else:
    raise SystemExit(f"unknown provenance mutation: {mode}")
path.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
PY
  if run_publisher "" "$TEST_ROOT/provenance-${mode}.log"; then
    echo "publisher accepted invalid evidence provenance: $mode" >&2
    exit 1
  fi
  [[ ! -s "$TEST_ROOT/gh.log" ]]
  mv "$backup_path" "$PROVENANCE_PATH"
}

run_without_evidence local "$TEST_ROOT/local-without-evidence.log"
grep -q 'release_proof=false' "$TEST_ROOT/local-without-evidence.log"
if run_without_evidence publish "$TEST_ROOT/publish-without-evidence.log"; then
  echo "publisher accepted an official release without evidence" >&2
  exit 1
fi
[[ ! -s "$TEST_ROOT/gh.log" ]]
expect_provenance_failure source-sha
expect_provenance_failure workflow
expect_provenance_failure artifact-set

expect_failure_before_create notarization
expect_failure_before_create gatekeeper
expect_failure_before_create manifest
expect_failure_before_create immutability_lookup
expect_failure_before_create immutability_disabled
expect_failure_before_create missing_tag
expect_failure_before_create remote_tag_mismatch
expect_failure_before_create release_list
expect_failure_before_create existing_release
if run_publisher create "$TEST_ROOT/create.log"; then
  echo "expected publisher failure while creating the draft" >&2
  exit 1
fi
[[ ! -e "$REMOTE_ROOT/state" ]]
expect_unpublished_draft_failure draft_asset_set
expect_unpublished_draft_failure draft_readback
expect_unpublished_draft_failure tag_moved_before_publish
expect_unpublished_draft_failure publish

FAKE_TAG_MODE=annotated run_publisher "" "$TEST_ROOT/success.log"
grep -q '^release create ' "$TEST_ROOT/gh.log"
grep -q '^release edit ' "$TEST_ROOT/gh.log"
grep -q '^release verify ' "$TEST_ROOT/gh.log"
grep -q '^release verify-asset ' "$TEST_ROOT/gh.log"
if grep -Eq 'release upload|--clobber' "$TEST_ROOT/gh.log"; then
  echo "publisher used a mutable asset operation" >&2
  exit 1
fi
grep -Fxq 'draft=false' "$REMOTE_ROOT/state"
grep -Fxq 'immutable=true' "$REMOTE_ROOT/state"
python3 - "$PROOF_PATH" <<'PY'
import json
import sys
from pathlib import Path

proof = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert proof["status"] == "published-immutable-and-verified"
assert proof["release_proof"] is True
assert proof["immutable"] is True
assert proof["attestation_verified"] is True
assert len(proof["assets"]) == 4
PY

for stage in published_readback release_verify asset_verify; do
  if run_publisher "$stage" "$TEST_ROOT/${stage}.log"; then
    echo "expected post-publication proof failure at stage $stage" >&2
    exit 1
  fi
  grep -Fxq 'draft=false' "$REMOTE_ROOT/state"
  grep -Fxq 'immutable=true' "$REMOTE_ROOT/state"
  [[ "$(find "$REMOTE_ROOT/assets" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d '[:space:]')" == "4" ]]
done

echo "[test-publish-update] immutable publisher transaction tests passed"
