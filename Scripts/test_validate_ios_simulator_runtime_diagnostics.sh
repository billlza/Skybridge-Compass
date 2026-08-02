#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VALIDATOR="${ROOT_DIR}/Scripts/validate_ios_simulator_runtime_diagnostics.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-ios-diagnostics-test.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

BUILD_LOG="${TMP_ROOT}/build.log"
TEST_LOG="${TMP_ROOT}/test.log"

expect_failure() {
  if "${VALIDATOR}" "${BUILD_LOG}" "${TEST_LOG}" >/dev/null 2>&1; then
    echo "expected simulator diagnostic validation failure" >&2
    exit 1
  fi
}

printf '%s\n' "SwiftExplicitDependencyGeneratePcm IOSurface-ABCDE.pcm" >"${BUILD_LOG}"
printf '%s\n' "Test Suite 'All tests' started" >"${TEST_LOG}"
"${VALIDATOR}" "${BUILD_LOG}" "${TEST_LOG}" >/dev/null

printf '%s\n' \
  "objc[4242]: Class UIAccessibilityLoaderWebShared is implemented in both /System/Library/AccessibilityBundles/WebCore.axbundle/WebCore and /System/Library/AccessibilityBundles/WebKit.axbundle/WebKit. This may cause spurious casting failures and mysterious crashes. One of the duplicates must be removed or renamed." \
  "Test Suite 'All tests' started" >"${TEST_LOG}"
"${VALIDATOR}" "${BUILD_LOG}" "${TEST_LOG}" >/dev/null

printf '%s\n' \
  "objc[4242]: Class UnknownRuntimeClass is implemented in both /System/Library/Frameworks/First.framework/First and /System/Library/Frameworks/Second.framework/Second." \
  "Test Suite 'All tests' started" >"${TEST_LOG}"
expect_failure

printf '%s\n' \
  "objc[4242]: Class UIAccessibilityLoaderWebShared is implemented in both /System/Library/AccessibilityBundles/WebCore.axbundle/WebCore and /System/Library/AccessibilityBundles/WebKit.axbundle/WebKit." \
  "objc[4242]: Class UIAccessibilityLoaderWebShared is implemented in both /System/Library/AccessibilityBundles/WebCore.axbundle/WebCore and /System/Library/AccessibilityBundles/WebKit.axbundle/WebKit." \
  "Test Suite 'All tests' started" >"${TEST_LOG}"
expect_failure

printf '%s\n' \
  "Test Suite 'All tests' started" \
  "[plugin] AddInstanceForFactory: No factory registered for id F8BB1C28" >"${TEST_LOG}"
expect_failure

printf '%s\n' \
  "Test Suite 'All tests' started" \
  "[ddagg] AggregateDevice.mm:912 couldn't get default output device, ID = 0, err = 0!" >"${TEST_LOG}"
expect_failure

printf '%s\n' \
  "[plugin] AddInstanceForFactory: No factory registered for id F8BB1C28" >"${BUILD_LOG}"
printf '%s\n' "Test Suite 'All tests' started" >"${TEST_LOG}"
expect_failure

printf '%s\n' "SwiftExplicitDependencyGeneratePcm IOSurface-ABCDE.pcm" >"${BUILD_LOG}"

printf '%s\n' \
  "objc[4242]: Class _TtC21SkyBridgeProtocolCore11SecureBytes is implemented in both /tmp/SkyBridgeAppleRuntime.framework/SkyBridgeAppleRuntime and /tmp/SkyBridgeCompass-iOS.app/SkyBridgeCompass-iOS." \
  "This may cause spurious casting failures and mysterious crashes. One of the duplicates must be removed or renamed." \
  "Test Suite 'All tests' started" >"${TEST_LOG}"
expect_failure

printf '%s\n' "Test Suite 'All tests' started" >"${TEST_LOG}"
"${VALIDATOR}" "${BUILD_LOG}" "${TEST_LOG}" >/dev/null

printf '%s\n' \
  "IOSurfaceClientSetSurfaceNotify failed e00002c7" \
  "Test Suite 'All tests' started" >"${TEST_LOG}"
"${VALIDATOR}" "${BUILD_LOG}" "${TEST_LOG}" >/dev/null

printf '%s\n' \
  "IOSurfaceClientSetSurfaceNotify failed e00002c7" \
  "IOSurfaceClientSetSurfaceNotify failed e00002c7" \
  "Test Suite 'All tests' started" >"${TEST_LOG}"
expect_failure

printf '%s\n' \
  "Test Suite 'All tests' started" \
  "IOSurfaceClientSetSurfaceNotify failed e00002c7" >"${TEST_LOG}"
expect_failure

printf '%s\n' \
  "IOSurfaceClientSetSurfaceNotify failed deadbeef" \
  "Test Suite 'All tests' started" >"${TEST_LOG}"
expect_failure

printf '%s\n' "IOSurfaceClientSetSurfaceNotify failed e00002c7" >"${BUILD_LOG}"
printf '%s\n' "Test Suite 'All tests' started" >"${TEST_LOG}"
expect_failure

echo "iOS simulator runtime diagnostic validator tests passed"
