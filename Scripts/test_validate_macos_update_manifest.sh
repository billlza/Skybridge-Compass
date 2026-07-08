#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${ROOT_DIR}/Scripts/validate_macos_update_manifest.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-update-manifest-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

APP_PATH="${TMP_DIR}/SkyBridge Compass Pro.app"
CONTENTS_PATH="${APP_PATH}/Contents"
DMG_PATH="${TMP_DIR}/SkyBridgeCompassPro-1.0.0.dmg"
MANIFEST_PATH="${TMP_DIR}/macos-stable.json"
NOW="2026-07-08T00:00:00Z"

mkdir -p "${CONTENTS_PATH}"
printf 'fake dmg payload\n' >"${DMG_PATH}"

python3 - "${CONTENTS_PATH}/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

plist = {
    "CFBundleIdentifier": "com.skybridge.compass.pro",
    "CFBundleShortVersionString": "1.0.0",
    "CFBundleVersion": "20260707181915",
    "LSMinimumSystemVersion": "14.0",
}
with Path(sys.argv[1]).open("wb") as handle:
    plistlib.dump(plist, handle)
PY

write_manifest() {
  local variant="$1"

  python3 - "${MANIFEST_PATH}" "${DMG_PATH}" "${variant}" <<'PY'
import base64
import hashlib
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
dmg_path = Path(sys.argv[2])
variant = sys.argv[3]
signature = base64.b64encode(bytes([7]) * 64).decode("ascii")
manifest = {
    "schema_version": 1,
    "bundle_id": "com.skybridge.compass.pro",
    "platform": "macos",
    "channel": "stable",
    "version": "1.0.0",
    "build": "20260707181915",
    "sequence": 20260707181915,
    "published_at": "2026-07-07T00:00:00Z",
    "expires_at": "2026-08-07T00:00:00Z",
    "minimum_system_version": "14.0",
    "release_notes_url": "https://github.com/billlza/Skybridge-Compass/releases/tag/stable",
    "download_url": "https://github.com/billlza/Skybridge-Compass/releases/download/stable/SkyBridgeCompassPro-1.0.0.dmg",
    "sha256": hashlib.sha256(dmg_path.read_bytes()).hexdigest(),
    "package_format": "dmg",
    "distribution": "developer-id",
    "notarized": True,
    "size_bytes": dmg_path.stat().st_size,
    "apple_pqc_sdk_build": {
        "compiled_with_has_apple_pqc_sdk": True,
        "compile_marker": "skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk",
        "probe_mode": "symbol_probe",
        "sdk_name": "macosx",
        "sdk_version": "26.5",
        "swift_target": "arm64-apple-macosx26.0",
        "secure_enclave_symbols_included": True,
        "symbol_set": "cryptokit-pqc-v1",
        "signature": {
            "algorithm": "ed25519",
            "key_id": "skybridge-stable-test",
            "value": signature,
        },
    },
    "signature": {
        "algorithm": "ed25519",
        "key_id": "skybridge-stable-test",
        "value": signature,
    },
}
if variant == "expired":
    manifest["expires_at"] = "2026-07-05T00:00:00Z"
elif variant == "sha-mismatch":
    manifest["sha256"] = "0" * 64
elif variant == "missing-apple-pqc":
    del manifest["apple_pqc_sdk_build"]
elif variant == "download-mismatch":
    manifest["download_url"] = "https://github.com/billlza/Skybridge-Compass/releases/download/stable/Other.dmg"
elif variant != "valid":
    raise SystemExit(f"unknown manifest variant: {variant}")
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

expect_failure_contains() {
  local description="$1"
  local expected_fragment="$2"
  shift 2

  local output=""
  local status=0
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    echo "${description}: expected failure but command succeeded" >&2
    exit 1
  fi
  if [[ "${output}" != *"${expected_fragment}"* ]]; then
    printf '%s\n' "${output}" >&2
    echo "${description}: expected output to contain '${expected_fragment}'" >&2
    exit 1
  fi
}

write_manifest valid
bash "${TARGET}" \
  --manifest-path "${MANIFEST_PATH}" \
  --app-path "${APP_PATH}" \
  --dmg-path "${DMG_PATH}" \
  --require-apple-pqc-sdk-build \
  --now "${NOW}" >/dev/null

write_manifest expired
expect_failure_contains \
  "expired manifest rejected" \
  "expires_at" \
  bash "${TARGET}" \
    --manifest-path "${MANIFEST_PATH}" \
    --app-path "${APP_PATH}" \
    --dmg-path "${DMG_PATH}" \
    --require-apple-pqc-sdk-build \
    --now "${NOW}"

write_manifest sha-mismatch
expect_failure_contains \
  "sha mismatch rejected" \
  "does not match DMG sha256" \
  bash "${TARGET}" \
    --manifest-path "${MANIFEST_PATH}" \
    --app-path "${APP_PATH}" \
    --dmg-path "${DMG_PATH}" \
    --require-apple-pqc-sdk-build \
    --now "${NOW}"

write_manifest missing-apple-pqc
expect_failure_contains \
  "missing Apple PQC SDK build provenance rejected" \
  "apple_pqc_sdk_build must be present" \
  bash "${TARGET}" \
    --manifest-path "${MANIFEST_PATH}" \
    --app-path "${APP_PATH}" \
    --dmg-path "${DMG_PATH}" \
    --require-apple-pqc-sdk-build \
    --now "${NOW}"

write_manifest download-mismatch
expect_failure_contains \
  "download URL asset mismatch rejected" \
  "does not match DMG" \
  bash "${TARGET}" \
    --manifest-path "${MANIFEST_PATH}" \
    --app-path "${APP_PATH}" \
    --dmg-path "${DMG_PATH}" \
    --require-apple-pqc-sdk-build \
    --now "${NOW}"

echo "[test-validate-macos-update-manifest] passed"
