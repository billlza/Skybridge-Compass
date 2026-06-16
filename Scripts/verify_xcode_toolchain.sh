#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/toolchain_release_pin.sh
source "${SCRIPT_DIR}/toolchain_release_pin.sh"

TOOLCHAIN_POLICY="${SKYBRIDGE_XCODE_TOOLCHAIN_POLICY:-stable-release}"

case "${TOOLCHAIN_POLICY}" in
  stable-release)
    # Established shipping line. Exact-match all four facts, reject beta dirs.
    # These constants are intentionally pinned verbatim here (defense-in-depth)
    # and enforced as literals by AppUpdateManifestTests' source-contract check.
    EXPECTED_XCODE_VERSION="26.5"
    EXPECTED_XCODE_BUILD="17F42"
    EXPECTED_SWIFT_VERSION="6.3.2"
    EXPECTED_MACOS_SDK_VERSION="26.5"
    MATCH_MODE="exact"
    ALLOW_BETA_TOOLCHAIN=0
    ;;
  os27-release)
    # OS 27 shipping line (additive). Major-tolerant within the 27 series so 27.x
    # point releases / rotating beta build ids do not require re-pinning; beta
    # developer dir allowed while Xcode 27 is beta. Deployment floors (macOS 14 /
    # iOS 17) are enforced separately by the caller and never relaxed here.
    EXPECTED_XCODE_VERSION="27"
    EXPECTED_XCODE_BUILD=""
    EXPECTED_SWIFT_VERSION="6.4"
    EXPECTED_MACOS_SDK_VERSION="27"
    MATCH_MODE="major"
    ALLOW_BETA_TOOLCHAIN="${SKYBRIDGE_OS27_ALLOW_BETA_TOOLCHAIN:-1}"
    ;;
  custom-diagnostic)
    EXPECTED_XCODE_VERSION="${SKYBRIDGE_REQUIRED_XCODE_VERSION:-26.5}"
    EXPECTED_XCODE_BUILD="${SKYBRIDGE_REQUIRED_XCODE_BUILD:-17F42}"
    EXPECTED_SWIFT_VERSION="${SKYBRIDGE_REQUIRED_APPLE_SWIFT_VERSION:-6.3.2}"
    EXPECTED_MACOS_SDK_VERSION="${SKYBRIDGE_REQUIRED_MACOS_SDK_VERSION:-26.5}"
    MATCH_MODE="${SKYBRIDGE_REQUIRED_TOOLCHAIN_MATCH_MODE:-exact}"
    ALLOW_BETA_TOOLCHAIN="${SKYBRIDGE_ALLOW_BETA_XCODE_TOOLCHAIN:-0}"
    ;;
  *)
    echo "[verify-xcode-toolchain] ERROR: unknown SKYBRIDGE_XCODE_TOOLCHAIN_POLICY=${TOOLCHAIN_POLICY}" >&2
    exit 64
    ;;
esac

fail() {
  echo "[verify-xcode-toolchain] ERROR: $1" >&2
  exit 1
}

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"

if [[ -n "${DEVELOPER_DIR:-}" && ! -d "${DEVELOPER_DIR}" ]]; then
  fail "DEVELOPER_DIR does not exist: ${DEVELOPER_DIR}"
fi

developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ "${ALLOW_BETA_TOOLCHAIN}" != "1" ]]; then
  developer_dir_lower="$(tr '[:upper:]' '[:lower:]' <<<"${developer_dir}")"
  if [[ "${developer_dir_lower}" == *"xcode"*beta* ]]; then
    fail "stable release toolchain must not use beta Xcode developer directory: ${developer_dir}"
  fi
fi

xcode_output="$(xcodebuild -version 2>/dev/null || true)"
swift_output="$(xcrun swift --version 2>/dev/null || true)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"

xcode_version="$(awk '/^Xcode / { print $2; exit }' <<<"${xcode_output}")"
xcode_build="$(awk '/^Build version / { print $3; exit }' <<<"${xcode_output}")"

# Xcode marketing version (exact, or major-tolerant for the OS 27 line).
skybridge_release_pin_match_version "${EXPECTED_XCODE_VERSION}" "${xcode_version}" "${MATCH_MODE}" \
  || fail "expected Xcode ${EXPECTED_XCODE_VERSION}, actual: ${xcode_version:-missing}"

# Build id is only asserted in exact mode — beta build ids rotate per beta.
if [[ "${MATCH_MODE}" == "exact" ]]; then
  [[ "${xcode_build}" == "${EXPECTED_XCODE_BUILD}" ]] \
    || fail "expected Xcode build ${EXPECTED_XCODE_BUILD}, actual: ${xcode_build:-missing}"
fi

# Swift version: exact in exact mode; presence-only in major mode (the Swift
# version is implied by the pinned Xcode major and tracks it, not the SDK major).
if [[ "${MATCH_MODE}" == "exact" ]]; then
  [[ "${swift_output}" == *"Apple Swift version ${EXPECTED_SWIFT_VERSION}"* ]] \
    || fail "expected Apple Swift ${EXPECTED_SWIFT_VERSION}, actual: ${swift_output:-missing}"
else
  [[ "${swift_output}" == *"Apple Swift version"* ]] \
    || fail "expected an Apple Swift toolchain, actual: ${swift_output:-missing}"
fi

# macOS SDK (exact, or major-tolerant for the OS 27 line).
skybridge_release_pin_match_version "${EXPECTED_MACOS_SDK_VERSION}" "${sdk_version}" "${MATCH_MODE}" \
  || fail "expected macOS SDK ${EXPECTED_MACOS_SDK_VERSION}, actual: ${sdk_version:-missing}"

echo "[verify-xcode-toolchain] policy=${TOOLCHAIN_POLICY} match=${MATCH_MODE}"
echo "[verify-xcode-toolchain] Xcode ${xcode_version} (${xcode_build})"
echo "[verify-xcode-toolchain] $(head -n 1 <<<"${swift_output}")"
echo "[verify-xcode-toolchain] macOS SDK ${sdk_version:-unknown}"
