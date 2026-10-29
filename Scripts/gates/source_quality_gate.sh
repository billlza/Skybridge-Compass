#!/usr/bin/env bash
set -euo pipefail

GATE_NAME="source_quality"
GATE_DOMAIN="source-quality"
export GATE_NAME GATE_DOMAIN
source "$(cd "$(dirname "$0")" && pwd)/_gate_common.sh"
source "${ROOT_DIR}/Scripts/apple_pqc_sdk_probe.sh"

XCODE_SWIFT_BIN="$(xcrun --find swift)"
[[ -x "${XCODE_SWIFT_BIN}" ]] || {
  echo "[source-quality] Xcode Swift toolchain executable is unavailable" >&2
  exit 1
}

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
  "ios-release-version-configuration" \
  "release" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/check_ios_release_version.sh"

run_check_strict_no_warnings \
  "ios-release-version-guardrail" \
  "release" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_ios_release_version.sh"

run_check_strict_no_warnings \
  "ios-distribution-product-verifier" \
  "security" \
  "source-quality" \
  python3 "${ROOT_DIR}/Scripts/test_verify_ios_distribution_product.py"

run_check_strict_no_warnings \
  "devicectl-device-selection" \
  "security" \
  "source-quality" \
  env PYTHONPATH="${ROOT_DIR}/Scripts" \
    python3 "${ROOT_DIR}/Scripts/test_devicectl_device_selection.py"

run_check_strict_no_warnings \
  "release-output-directory-policy" \
  "security" \
  "source-quality" \
  env PYTHONPATH="${ROOT_DIR}/Scripts" \
    python3 "${ROOT_DIR}/Scripts/test_validate_release_output_directory.py"

run_check_strict_no_warnings \
  "gate-log-scanner-selftest" \
  "security" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_gate_common.sh"

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
  "protocol-parity-checker-guardrail" \
  "code" \
  "source-quality" \
  python3 "${ROOT_DIR}/Scripts/test_check_protocol_parity.py"

run_check_strict_no_warnings \
  "ios-simulator-selection" \
  "code" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_ios_simulator_helpers.sh"

run_check_strict_no_warnings \
  "swift-test-filter-guardrail" \
  "code" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_run_swift_test_filter.sh"

run_check_strict_no_warnings \
  "release-acceptance-manifest-finalizer-guardrail" \
  "code" \
  "source-quality" \
  python3 "${ROOT_DIR}/Scripts/test_finalize_release_acceptance_manifests.py"

run_check_strict_no_warnings \
  "ios-same-archive-release-transaction" \
  "release" \
  "source-quality" \
  python3 "${ROOT_DIR}/Scripts/test_ios_app_store_release_transaction.py"

run_check_strict_no_warnings \
  "real-device-release-acceptance-artifact-guardrail" \
  "code" \
  "source-quality" \
  python3 -W error "${ROOT_DIR}/Scripts/test_validate_real_device_release_acceptance_artifact.py"

run_check_strict_no_warnings \
  "normal-product-release-evidence-log" \
  "release" \
  "source-quality" \
  python3 -W error "${ROOT_DIR}/Scripts/test_validate_product_release_evidence_log.py"

run_check_strict_no_warnings \
  "ios-product-installation-transaction" \
  "release" \
  "source-quality" \
  python3 -W error "${ROOT_DIR}/Scripts/test_ios_product_installation.py"

run_check_strict_no_warnings \
  "ios-product-evidence-extraction" \
  "release" \
  "source-quality" \
  python3 -W error "${ROOT_DIR}/Scripts/test_extract_ios_product_release_evidence.py"

run_check_strict_no_warnings \
  "formal-product-evidence-manifest" \
  "release" \
  "source-quality" \
  python3 -W error "${ROOT_DIR}/Scripts/test_formal_product_evidence_manifest.py"

run_check_strict_no_warnings \
  "formal-product-evidence-session-contract" \
  "release" \
  "source-quality" \
  python3 -W error "${ROOT_DIR}/Scripts/test_formal_product_evidence_session_contract.py"

run_check_strict_no_warnings \
  "release-environment-protection" \
  "release" \
  "source-quality" \
  python3 "${ROOT_DIR}/Scripts/test_validate_release_environment_protection.py"

run_check_strict_no_warnings \
  "macos-release-candidate-identity" \
  "release" \
  "source-quality" \
  python3 "${ROOT_DIR}/Scripts/test_macos_release_candidate_identity.py"

run_check_strict_no_warnings \
  "macos-release-candidate-handoff" \
  "security" \
  "source-quality" \
  python3 "${ROOT_DIR}/Scripts/test_extract_macos_release_handoff.py"

run_check_strict_no_warnings \
  "real-device-evidence-file-set" \
  "security" \
  "source-quality" \
  python3 -W error "${ROOT_DIR}/Scripts/test_stage_real_device_release_evidence.py"

run_check_strict_no_warnings \
  "release-workflow-transaction" \
  "release" \
  "source-quality" \
  python3 -W error "${ROOT_DIR}/Scripts/test_real_device_release_workflow_contract.py"

run_check_strict_no_warnings \
  "real-device-public-artifact-redaction" \
  "security" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_real_device_smoke_redaction.sh"

run_check_strict_no_warnings \
  "real-device-smoke-performance-contract" \
  "code" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_real_device_smoke_performance_gate.sh"

run_check_strict_no_warnings \
  "ios-ipa-safe-extraction" \
  "security" \
  "source-quality" \
  python3 "${ROOT_DIR}/Scripts/test_extract_ios_ipa.py"

run_check_strict_no_warnings \
  "ios-distribution-signing-helper" \
  "security" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_ios_distribution_signing_helpers.sh"

run_check_strict_no_warnings \
  "real-device-p2p-preflight" \
  "security" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_real_device_p2p_remote_smoke_preflight.sh"

run_check_strict_no_warnings \
  "ios-runtime-diagnostic-validator" \
  "code" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_validate_ios_simulator_runtime_diagnostics.sh"

run_check_strict_no_warnings \
  "macos-update-manifest-signature-validator" \
  "security" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_validate_macos_update_manifest.sh"

run_check_strict_no_warnings \
  "macos-update-publish-transaction" \
  "security" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_publish_macos_update_release.sh"

run_check_strict_no_warnings \
  "swift-build" \
  "code" \
  "source-quality" \
  "${XCODE_SWIFT_BIN}" build --disable-automatic-resolution --disable-prefetching -Xswiftc -warnings-as-errors

run_check_strict_no_warnings \
  "swift-test-localization-notification-isolation" \
  "code" \
  "source-quality" \
  env HOME="${SOURCE_QUALITY_TEST_HOME}" CFFIXED_USER_HOME="${SOURCE_QUALITY_TEST_HOME}" SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 SKYBRIDGE_SWIFT_EXECUTABLE="${XCODE_SWIFT_BIN}" bash "${ROOT_DIR}/Scripts/run_swift_test_filter.sh" SkyBridgeCoreTests.LocalizationManagerNotificationIsolationTests --disable-automatic-resolution --disable-prefetching -Xswiftc -warnings-as-errors

run_check_strict_no_warnings \
  "swift-test" \
  "code" \
  "source-quality" \
  env HOME="${SOURCE_QUALITY_TEST_HOME}" CFFIXED_USER_HOME="${SOURCE_QUALITY_TEST_HOME}" SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 SKYBRIDGE_SWIFT_EXECUTABLE="${XCODE_SWIFT_BIN}" bash "${ROOT_DIR}/Scripts/run_swift_test_filter.sh" '.*' --disable-automatic-resolution --disable-prefetching -Xswiftc -warnings-as-errors

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
