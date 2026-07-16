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
