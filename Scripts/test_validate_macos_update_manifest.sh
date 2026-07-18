#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${ROOT_DIR}/Scripts/validate_macos_update_manifest.sh"
GENERATOR="${ROOT_DIR}/Scripts/generate_macos_update_manifest.swift"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-update-manifest-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

APP_PATH="${TMP_DIR}/SkyBridge Compass Pro.app"
CONTENTS_PATH="${APP_PATH}/Contents"
APP_EXECUTABLE_PATH="${CONTENTS_PATH}/MacOS/SkyBridgeCompassApp"
DMG_PATH="${TMP_DIR}/SkyBridgeCompassPro-1.0.0.dmg"
MANIFEST_PATH="${TMP_DIR}/macos-stable.json"
VALID_MANIFEST_PATH="${TMP_DIR}/valid-macos-stable.json"
SIGNING_SEED_PATH="${TMP_DIR}/manifest-signing.seed"
WRONG_SIGNING_SEED_PATH="${TMP_DIR}/wrong-manifest-signing.seed"
SIGNING_KEY_ID="skybridge-stable-test"
WRONG_SIGNING_KEY_ID="skybridge-stable-wrong-test"
NOW="2026-07-08T00:00:00Z"

mkdir -p "${CONTENTS_PATH}/MacOS"
printf 'fake dmg payload\n' >"${DMG_PATH}"
printf '#!/usr/bin/env bash\n# skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk\nexit 0\n' \
  >"${APP_EXECUTABLE_PATH}"
chmod 755 "${APP_EXECUTABLE_PATH}"

python3 - "${SIGNING_SEED_PATH}" "${WRONG_SIGNING_SEED_PATH}" <<'PY'
import base64
import os
import sys
from pathlib import Path

for path, byte in ((Path(sys.argv[1]), 0x11), (Path(sys.argv[2]), 0x22)):
    path.write_text(base64.b64encode(bytes([byte]) * 32).decode("ascii") + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
PY

derive_public_key() {
  local seed_path="$1"
  xcrun swift -warnings-as-errors - "${seed_path}" <<'SWIFT'
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("expected seed path")
}
let encodedSeed = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
guard let seed = Data(base64Encoded: encodedSeed.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32 else {
    fatalError("invalid test seed")
}
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(privateKey.publicKey.rawRepresentation.base64EncodedString())
SWIFT
}

SIGNING_PUBLIC_KEY="$(derive_public_key "${SIGNING_SEED_PATH}")"
WRONG_SIGNING_PUBLIC_KEY="$(derive_public_key "${WRONG_SIGNING_SEED_PATH}")"

python3 - \
  "${CONTENTS_PATH}/Info.plist" \
  "${SIGNING_KEY_ID}" \
  "${SIGNING_PUBLIC_KEY}" \
  "${WRONG_SIGNING_KEY_ID}" \
  "${WRONG_SIGNING_PUBLIC_KEY}" <<'PY'
import plistlib
import sys
from pathlib import Path

plist = {
    "CFBundleIdentifier": "com.skybridge.compass.pro",
    "CFBundleShortVersionString": "1.0.0",
    "CFBundleVersion": "20260707181915",
    "LSMinimumSystemVersion": "14.0",
    "SKYBRIDGE_UPDATE_MANIFEST_ED25519_PUBLIC_KEYS": (
        f"{sys.argv[2]}:{sys.argv[3]};{sys.argv[4]}:{sys.argv[5]}"
    ),
    "SkyBridgePackagingApplePQCSDKCompiledWithHASApplePQCSDK": True,
    "SkyBridgePackagingApplePQCSDKCompileMarker": (
        "skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk"
    ),
    "SkyBridgePackagingApplePQCSDKProbeMode": "symbol_probe",
    "SkyBridgePackagingApplePQCSDKName": "macosx",
    "SkyBridgePackagingApplePQCSDKVersion": "26.5",
    "SkyBridgePackagingApplePQCSDKSwiftTarget": "arm64-apple-macosx26.0",
    "SkyBridgePackagingApplePQCSDKSecureEnclaveSymbolsIncluded": True,
    "SkyBridgePackagingApplePQCSDKSymbolSet": "cryptokit-pqc-v1",
}
with Path(sys.argv[1]).open("wb") as handle:
    plistlib.dump(plist, handle)
PY

xcrun swift -warnings-as-errors "${GENERATOR}" \
  --app-path "${APP_PATH}" \
  --package-path "${DMG_PATH}" \
  --download-url "https://github.com/billlza/Skybridge-Compass/releases/download/stable/SkyBridgeCompassPro-1.0.0.dmg" \
  --release-notes-url "https://github.com/billlza/Skybridge-Compass/releases/tag/stable" \
  --key-id "${SIGNING_KEY_ID}" \
  --private-key-file "${SIGNING_SEED_PATH}" \
  --sequence 20260707181915 \
  --published-at "2026-07-07T00:00:00Z" \
  --expires-at "2026-08-07T00:00:00Z" \
  --output "${VALID_MANIFEST_PATH}" \
  --notarized \
  >/dev/null 2>&1

write_manifest() {
  local variant="$1"

  python3 - \
    "${VALID_MANIFEST_PATH}" \
    "${MANIFEST_PATH}" \
    "${variant}" \
    "${WRONG_SIGNING_KEY_ID}" <<'PY'
import json
import sys
from pathlib import Path

valid_manifest_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
variant = sys.argv[3]
wrong_signing_key_id = sys.argv[4]
manifest = json.loads(valid_manifest_path.read_text(encoding="utf-8"))
if variant == "expired":
    manifest["expires_at"] = "2026-07-05T00:00:00Z"
elif variant == "sha-mismatch":
    manifest["sha256"] = "0" * 64
elif variant == "missing-apple-pqc":
    del manifest["apple_pqc_sdk_build"]
elif variant == "download-mismatch":
    manifest["download_url"] = "https://github.com/billlza/Skybridge-Compass/releases/download/stable/Other.dmg"
elif variant == "manifest-payload-tamper":
    manifest["release_notes_url"] = "https://github.com/billlza/Skybridge-Compass/releases/tag/tampered"
elif variant == "apple-pqc-payload-tamper":
    manifest["apple_pqc_sdk_build"]["probe_mode"] = "symbol_probe_tampered"
elif variant == "manifest-unknown-key":
    manifest["signature"]["key_id"] = "unknown-test-key"
elif variant == "manifest-wrong-key":
    manifest["signature"]["key_id"] = wrong_signing_key_id
elif variant == "apple-pqc-unknown-key":
    manifest["apple_pqc_sdk_build"]["signature"]["key_id"] = "unknown-test-key"
elif variant == "apple-pqc-wrong-key":
    manifest["apple_pqc_sdk_build"]["signature"]["key_id"] = wrong_signing_key_id
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

write_manifest manifest-payload-tamper
expect_failure_contains \
  "tampered manifest canonical payload rejected" \
  "manifest signature verification failed" \
  bash "${TARGET}" \
    --manifest-path "${MANIFEST_PATH}" \
    --app-path "${APP_PATH}" \
    --dmg-path "${DMG_PATH}" \
    --require-apple-pqc-sdk-build \
    --now "${NOW}"

write_manifest apple-pqc-payload-tamper
expect_failure_contains \
  "tampered Apple PQC canonical payload rejected" \
  "apple_pqc_sdk_build signature verification failed" \
  bash "${TARGET}" \
    --manifest-path "${MANIFEST_PATH}" \
    --app-path "${APP_PATH}" \
    --dmg-path "${DMG_PATH}" \
    --require-apple-pqc-sdk-build \
    --now "${NOW}"

write_manifest manifest-unknown-key
expect_failure_contains \
  "unknown manifest signing key rejected" \
  "manifest signature key is not trusted: unknown-test-key" \
  bash "${TARGET}" \
    --manifest-path "${MANIFEST_PATH}" \
    --app-path "${APP_PATH}" \
    --dmg-path "${DMG_PATH}" \
    --require-apple-pqc-sdk-build \
    --now "${NOW}"

write_manifest manifest-wrong-key
expect_failure_contains \
  "wrong trusted manifest signing key rejected" \
  "manifest signature verification failed" \
  bash "${TARGET}" \
    --manifest-path "${MANIFEST_PATH}" \
    --app-path "${APP_PATH}" \
    --dmg-path "${DMG_PATH}" \
    --require-apple-pqc-sdk-build \
    --now "${NOW}"

write_manifest apple-pqc-unknown-key
expect_failure_contains \
  "unknown Apple PQC signing key rejected" \
  "apple_pqc_sdk_build signature key is not trusted: unknown-test-key" \
  bash "${TARGET}" \
    --manifest-path "${MANIFEST_PATH}" \
    --app-path "${APP_PATH}" \
    --dmg-path "${DMG_PATH}" \
    --require-apple-pqc-sdk-build \
    --now "${NOW}"

write_manifest apple-pqc-wrong-key
expect_failure_contains \
  "wrong trusted Apple PQC signing key rejected" \
  "apple_pqc_sdk_build signature verification failed" \
  bash "${TARGET}" \
    --manifest-path "${MANIFEST_PATH}" \
    --app-path "${APP_PATH}" \
    --dmg-path "${DMG_PATH}" \
    --require-apple-pqc-sdk-build \
    --now "${NOW}"

echo "[test-validate-macos-update-manifest] passed"
