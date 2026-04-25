#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/xcodebuild_helpers.sh"

fail() {
    echo "[test-xcodebuild-helpers] $1" >&2
    exit 1
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    if [[ "${actual}" != "${expected}" ]]; then
        fail "${label}: expected '${expected}', got '${actual}'"
    fi
}

default_destination="$(skybridge_default_macos_build_destination)"
assert_eq "${default_destination}" "platform=macOS,arch=arm64" "default macOS build destination"

override_destination="$(
    SKYBRIDGE_MACOS_BUILD_DESTINATION="platform=macOS,arch=x86_64" \
        skybridge_default_macos_build_destination
)"
assert_eq "${override_destination}" "platform=macOS,arch=x86_64" "explicit destination override"

arch_override_destination="$(
    SKYBRIDGE_MACOS_BUILD_ARCH="x86_64" \
        skybridge_default_macos_build_destination
)"
assert_eq "${arch_override_destination}" "platform=macOS,arch=x86_64" "build arch override"

run_override_destination="$(
    SKYBRIDGE_MACOS_RUN_DESTINATION="platform=macOS,arch=arm64,id=TEST-ID" \
        skybridge_default_macos_destination
)"
assert_eq "${run_override_destination}" "platform=macOS,arch=arm64,id=TEST-ID" "run destination override"

set +e
invalid_output="$(
    SKYBRIDGE_MACOS_BUILD_ARCH="sparc" \
        skybridge_default_macos_build_destination 2>&1
)"
invalid_status=$?
set -e

if [[ "${invalid_status}" -eq 0 ]]; then
    fail "invalid build arch should fail"
fi
if [[ "${invalid_output}" != *"不支持的 macOS 构建架构=sparc"* ]]; then
    fail "invalid build arch should explain the unsupported value"
fi

warning_sample=$'first line\n--- xcodebuild: WARNING: Using the first of multiple matching destinations:\n{ platform:macOS, arch:arm64, id:0000, name:My Mac }\n2026-04-19 06:17:16.547 xcodebuild[12267:18547545] [MT] IDERunDestination: Supported platforms for the buildables in the current scheme is empty.\nlast line'
filtered_sample="$(printf '%s' "${warning_sample}" | skybridge_filter_xcodebuild_output)"
expected_filtered_sample=$'first line\nlast line'
assert_eq "${filtered_sample}" "${expected_filtered_sample}" "xcodebuild allowlisted destination warnings should be filtered"

echo "[test-xcodebuild-helpers] all checks passed"
