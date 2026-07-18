#!/usr/bin/env bash
set -euo pipefail

GATE_NAME="source_quality"
GATE_DOMAIN="source-quality"
export GATE_NAME GATE_DOMAIN
source "$(cd "$(dirname "$0")" && pwd)/_gate_common.sh"
source "${ROOT_DIR}/Scripts/apple_pqc_sdk_probe.sh"

IOS_PROJECT="${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_TEST_LANE="${ROOT_DIR}/SkyBridge Compass iOS/Scripts/test_lane_ios.sh"
SOURCE_QUALITY_TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-source-quality-home.XXXXXX")"

cleanup_source_quality_tmp() {
  rm -rf "${SOURCE_QUALITY_TEST_HOME}"
  cleanup_gate_tmp
}
trap cleanup_source_quality_tmp EXIT

if ! skybridge_require_apple_pqc_sdk_symbol_probe macosx; then
  echo "[source-quality] Apple PQC macOS symbol probe failed: mode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown}, ${SKYBRIDGE_PQC_PROBE_ERROR:-unknown}" >&2
  exit 1
fi
echo "[source-quality] Apple PQC macOS symbols verified: sdk=${SKYBRIDGE_PQC_SDK_VER} target=${SKYBRIDGE_PQC_SWIFT_TARGET}"
export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1

if ! skybridge_require_apple_pqc_sdk_symbol_probe iphoneos; then
  echo "[source-quality] Apple PQC iPhoneOS symbol probe failed: mode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown}, ${SKYBRIDGE_PQC_PROBE_ERROR:-unknown}" >&2
  exit 1
fi
echo "[source-quality] Apple PQC iPhoneOS symbols verified: sdk=${SKYBRIDGE_PQC_SDK_VER} target=${SKYBRIDGE_PQC_SWIFT_TARGET}"

run_check_strict_no_warnings \
  "release-no-print-guard" \
  "code" \
  "source-quality" \
  env SRCROOT="${ROOT_DIR}" zsh "${ROOT_DIR}/Scripts/release_no_print_guard.zsh"

run_check_strict_no_warnings \
  "sensitive-artifact-policy" \
  "security" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/check_sensitive_artifacts.sh" "${ROOT_DIR}"

run_check_strict_no_warnings \
  "loopback-benchmark-fixture-policy" \
  "security" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_loopback_benchmark_fixture_policy.sh"

run_check_strict_no_warnings \
  "qperiapt-rust-abi1-feature-policy" \
  "security" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_qperiapt_rust_feature_policy.sh"

run_check_strict_no_warnings \
  "ios-simulator-selection" \
  "code" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_ios_simulator_helpers.sh"

run_check_strict_no_warnings \
  "ios-runtime-diagnostic-validator" \
  "code" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_validate_ios_simulator_runtime_diagnostics.sh"

run_check_strict_no_warnings \
  "swift-build" \
  "code" \
  "source-quality" \
  swift build --disable-automatic-resolution --disable-prefetching -Xswiftc -warnings-as-errors

run_check_strict_no_warnings \
  "swift-test-localization-notification-isolation" \
  "code" \
  "source-quality" \
  env HOME="${SOURCE_QUALITY_TEST_HOME}" CFFIXED_USER_HOME="${SOURCE_QUALITY_TEST_HOME}" SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 bash "${ROOT_DIR}/Scripts/run_swift_test_filter.sh" SkyBridgeCoreTests.LocalizationManagerNotificationIsolationTests --disable-automatic-resolution --disable-prefetching -Xswiftc -warnings-as-errors

run_check_strict_no_warnings \
  "swift-test" \
  "code" \
  "source-quality" \
  env HOME="${SOURCE_QUALITY_TEST_HOME}" CFFIXED_USER_HOME="${SOURCE_QUALITY_TEST_HOME}" SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 bash "${ROOT_DIR}/Scripts/run_swift_test_filter.sh" '.*' --disable-automatic-resolution --disable-prefetching -Xswiftc -warnings-as-errors

run_check_strict_no_warnings \
  "loopback-connection-teardown-stress" \
  "code" \
  "source-quality" \
  env HOME="${SOURCE_QUALITY_TEST_HOME}" CFFIXED_USER_HOME="${SOURCE_QUALITY_TEST_HOME}" SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 BASELINE_RUN_BENCH=1 bash "${ROOT_DIR}/Scripts/run_swift_test_filter.sh" --require-no-skips SkyBridgeBenchTests.BaselineLoopbackBenchTests/testLoopbackConnectionTeardownStress --disable-automatic-resolution --disable-prefetching -Xswiftc -warnings-as-errors

run_check_strict_no_warnings \
  "ios-debug-build" \
  "code" \
  "source-quality" \
  xcodebuild -project "${IOS_PROJECT}" -scheme "${IOS_SCHEME}" -configuration Debug -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK build

run_check_strict_no_warnings \
  "ios-release-build" \
  "code" \
  "source-quality" \
  xcodebuild -project "${IOS_PROJECT}" -scheme "${IOS_SCHEME}" -configuration Release -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK build

run_check_strict_no_warnings \
  "ios-test-lane" \
  "code" \
  "source-quality" \
  bash "${IOS_TEST_LANE}"

finalize_gate_report
