#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_PATH="${ROOT_DIR}/Scripts/macos_keychain_persistent_ref_probe.swift"
SOURCE_ENTITLEMENTS="${ROOT_DIR}/Scripts/macos_keychain_persistent_ref_probe.entitlements"
SIGNING_IDENTITY="${SKYBRIDGE_KEYCHAIN_PROBE_SIGNING_IDENTITY:-}"
PROFILE_PATH="${SKYBRIDGE_KEYCHAIN_PROBE_PROFILE:-}"
BUNDLE_IDENTIFIER="com.skybridge.compass.pro"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-keychain-probe.XXXXXX")"
APP_PATH="${TEMP_ROOT}/SkyBridgeKeychainProbe.app"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/SkyBridgeKeychainProbe"
ENTITLEMENTS_PATH="${TEMP_ROOT}/probe.entitlements"
trap 'rm -rf "${TEMP_ROOT}"' EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[test-macos-keychain-persistent-ref] macOS is required" >&2
  exit 1
fi
if [[ -z "${SIGNING_IDENTITY}" || -z "${PROFILE_PATH}" ]]; then
  echo "[test-macos-keychain-persistent-ref] signed Data Protection Keychain proof requires both SKYBRIDGE_KEYCHAIN_PROBE_SIGNING_IDENTITY and SKYBRIDGE_KEYCHAIN_PROBE_PROFILE" >&2
  exit 1
fi
if [[ ! -f "${PROFILE_PATH}" ]]; then
  echo "[test-macos-keychain-persistent-ref] provisioning profile does not exist: ${PROFILE_PATH}" >&2
  exit 1
fi

# Reuse the release signing policy's profile-aware placeholder expansion and
# entitlement coverage validation. This keeps the probe aligned with the app
# and prevents an ad-hoc or over-entitled binary from masquerading as proof.
# shellcheck source=Scripts/signing_entitlements_helpers.sh
source "${ROOT_DIR}/Scripts/signing_entitlements_helpers.sh"
mkdir -p "${APP_PATH}/Contents/MacOS"
cp "${PROFILE_PATH}" "${APP_PATH}/Contents/embedded.provisionprofile"
cp "${SOURCE_ENTITLEMENTS}" "${ENTITLEMENTS_PATH}"
skybridge_expand_build_setting_entitlements \
  "${ENTITLEMENTS_PATH}" \
  "${PROFILE_PATH}"
if ! skybridge_profile_supports_requested_restricted_entitlements \
  "${PROFILE_PATH}" \
  "${ENTITLEMENTS_PATH}"; then
  echo "[test-macos-keychain-persistent-ref] provisioning profile does not cover the probe entitlements" >&2
  exit 1
fi

plutil -create xml1 "${APP_PATH}/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c 'Add :CFBundleExecutable string SkyBridgeKeychainProbe' \
  -c "Add :CFBundleIdentifier string ${BUNDLE_IDENTIFIER}" \
  -c 'Add :CFBundleName string SkyBridgeKeychainProbe' \
  -c 'Add :CFBundlePackageType string APPL' \
  -c 'Add :CFBundleVersion string 1' \
  "${APP_PATH}/Contents/Info.plist"

xcrun swiftc \
  -warnings-as-errors \
  -framework LocalAuthentication \
  -framework Security \
  "${SOURCE_PATH}" \
  -o "${EXECUTABLE_PATH}"
codesign \
  --force \
  --timestamp=none \
  --options runtime \
  --entitlements "${ENTITLEMENTS_PATH}" \
  --sign "${SIGNING_IDENTITY}" \
  "${APP_PATH}"
codesign --verify --strict --verbose=2 "${APP_PATH}"
"${EXECUTABLE_PATH}"

echo "[test-macos-keychain-persistent-ref] passed"
