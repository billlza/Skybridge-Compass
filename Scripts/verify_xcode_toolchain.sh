#!/usr/bin/env bash
set -euo pipefail

EXPECTED_XCODE_VERSION="${SKYBRIDGE_REQUIRED_XCODE_VERSION:-26.5}"
EXPECTED_XCODE_BUILD="${SKYBRIDGE_REQUIRED_XCODE_BUILD:-17F42}"
EXPECTED_SWIFT_VERSION="${SKYBRIDGE_REQUIRED_APPLE_SWIFT_VERSION:-6.3.2}"

fail() {
  echo "[verify-xcode-toolchain] ERROR: $1" >&2
  exit 1
}

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild is required"
command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"

if [[ -n "${DEVELOPER_DIR:-}" && ! -d "${DEVELOPER_DIR}" ]]; then
  fail "DEVELOPER_DIR does not exist: ${DEVELOPER_DIR}"
fi

xcode_output="$(xcodebuild -version 2>/dev/null || true)"
swift_output="$(xcrun swift --version 2>/dev/null || true)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"

xcode_version="$(awk '/^Xcode / { print $2; exit }' <<<"${xcode_output}")"
xcode_build="$(awk '/^Build version / { print $3; exit }' <<<"${xcode_output}")"

[[ "${xcode_version}" == "${EXPECTED_XCODE_VERSION}" ]] \
  || fail "expected Xcode ${EXPECTED_XCODE_VERSION}, actual: ${xcode_version:-missing}"
[[ "${xcode_build}" == "${EXPECTED_XCODE_BUILD}" ]] \
  || fail "expected Xcode build ${EXPECTED_XCODE_BUILD}, actual: ${xcode_build:-missing}"
[[ "${swift_output}" == *"Apple Swift version ${EXPECTED_SWIFT_VERSION}"* ]] \
  || fail "expected Apple Swift ${EXPECTED_SWIFT_VERSION}, actual: ${swift_output:-missing}"

echo "[verify-xcode-toolchain] Xcode ${xcode_version} (${xcode_build})"
echo "[verify-xcode-toolchain] $(head -n 1 <<<"${swift_output}")"
echo "[verify-xcode-toolchain] macOS SDK ${sdk_version:-unknown}"
