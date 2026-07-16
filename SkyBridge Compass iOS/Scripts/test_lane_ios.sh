#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "${ROOT_DIR}/Scripts/ios_simulator_helpers.sh"
source "${ROOT_DIR}/Scripts/apple_pqc_sdk_probe.sh"
IOS_PROJECT="${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompassiOSTests"
IOS_TEST_TARGET="SkyBridgeCompassiOSTests"
IOS_APP_BUNDLE_ID="com.skybridge.compass.ios"
EXPECTED_ARTIFACT_DATE="2026-01-23"
ARTIFACT_DATE="${ARTIFACT_DATE:-${SKYBRIDGE_ARTIFACT_DATE:-$EXPECTED_ARTIFACT_DATE}}"

if [[ "${ARTIFACT_DATE}" != "${EXPECTED_ARTIFACT_DATE}" ]]; then
  echo "ARTIFACT_DATE must be ${EXPECTED_ARTIFACT_DATE}, got ${ARTIFACT_DATE}" >&2
  exit 2
fi

bash "${ROOT_DIR}/Scripts/check_ios_test_configuration.sh"

if ! skybridge_require_apple_pqc_sdk_symbol_probe iphonesimulator; then
  echo "[iOS test lane] Apple PQC SDK symbol probe failed: mode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown}, ${SKYBRIDGE_PQC_PROBE_ERROR:-unknown}" >&2
  exit 1
fi
echo "[iOS test lane] Apple PQC symbols verified: sdk=${SKYBRIDGE_PQC_SDK_NAME} version=${SKYBRIDGE_PQC_SDK_VER} target=${SKYBRIDGE_PQC_SWIFT_TARGET}"

SIM_ID="$(
  skybridge_pick_bootable_ios_simulator_id \
    "${SKYBRIDGE_IOS_SIMULATOR_ID:-}" \
    "[iOS test lane]"
)"
SIM_ARCH="${SIM_ARCH:-$(uname -m)}"
DERIVED_DATA_PATH="$(mktemp -d)"
BUILD_LOG="${DERIVED_DATA_PATH}/build-for-testing.log"
TEST_LOG="${DERIVED_DATA_PATH}/test-without-building.log"
trap 'rm -rf "${DERIVED_DATA_PATH}"' EXIT

echo "[iOS test lane] resetting selected simulator test host"
xcrun simctl terminate "${SIM_ID}" "${IOS_APP_BUNDLE_ID}" >/dev/null 2>&1 || true
xcrun simctl uninstall "${SIM_ID}" "${IOS_APP_BUNDLE_ID}" >/dev/null 2>&1 || true
xcrun simctl shutdown "${SIM_ID}" >/dev/null 2>&1 || true
xcrun simctl boot "${SIM_ID}" >/dev/null
xcrun simctl bootstatus "${SIM_ID}" -b >/dev/null

run_xcodebuild_with_retry() {
  local log_file="$1"
  shift
  local max_attempts=2
  local attempt=1

  log_has_busy_pattern() {
    local target_log="$1"
    if command -v rg >/dev/null 2>&1; then
      rg -n "Application failed preflight checks|reason: Busy" "${target_log}" >/dev/null
    else
      grep -nE "Application failed preflight checks|reason: Busy" "${target_log}" >/dev/null
    fi
  }

  while [[ "${attempt}" -le "${max_attempts}" ]]; do
    : >"${log_file}"
    if xcodebuild "$@" 2>&1 | tee "${log_file}"; then
      return 0
    fi

    if [[ "${attempt}" -lt "${max_attempts}" ]] && log_has_busy_pattern "${log_file}"; then
      echo "[iOS test lane] simulator busy preflight; resetting simulator and retrying..."
      xcrun simctl terminate "${SIM_ID}" "${IOS_APP_BUNDLE_ID}" >/dev/null 2>&1 || true
      xcrun simctl uninstall "${SIM_ID}" "${IOS_APP_BUNDLE_ID}" >/dev/null 2>&1 || true
      xcrun simctl shutdown "${SIM_ID}" >/dev/null 2>&1 || true
      xcrun simctl boot "${SIM_ID}" >/dev/null 2>&1 || true
      xcrun simctl bootstatus "${SIM_ID}" -b >/dev/null 2>&1 || true
      attempt=$((attempt + 1))
      continue
    fi

    return 1
  done

  return 1
}

echo "[iOS test lane] running full ${IOS_TEST_TARGET} suite"

run_xcodebuild_with_retry \
  "${BUILD_LOG}" \
  -project "${IOS_PROJECT}" \
  -scheme "${IOS_SCHEME}" \
  -destination "platform=iOS Simulator,id=${SIM_ID},arch=${SIM_ARCH}" \
  -destination-timeout 120 \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK \
  build-for-testing

run_xcodebuild_with_retry \
  "${TEST_LOG}" \
  -project "${IOS_PROJECT}" \
  -scheme "${IOS_SCHEME}" \
  -destination "platform=iOS Simulator,id=${SIM_ID},arch=${SIM_ARCH}" \
  -destination-timeout 120 \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK \
  test-without-building

bash "${ROOT_DIR}/Scripts/validate_ios_simulator_runtime_diagnostics.sh" \
  "${BUILD_LOG}" \
  "${TEST_LOG}"

echo "[iOS test lane] full suite passed"
