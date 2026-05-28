#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/xcodebuild_helpers.sh
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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${TMP_DIR}/ArmOnly.xcframework/macos-arm64"
printf 'int skybridge_arch_probe(void) { return 0; }\n' > "${TMP_DIR}/arch_probe.c"
xcrun clang -arch arm64 -mmacosx-version-min=14.0 -c "${TMP_DIR}/arch_probe.c" -o "${TMP_DIR}/arch_probe.o"
xcrun libtool -static -o "${TMP_DIR}/ArmOnly.xcframework/macos-arm64/libArmOnly.a" "${TMP_DIR}/arch_probe.o"

cat > "${TMP_DIR}/ArmOnly.xcframework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>LibraryIdentifier</key>
            <string>macos-arm64</string>
            <key>LibraryPath</key>
            <string>libArmOnly.a</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>macos</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

default_destination="$(skybridge_default_macos_build_destination)"
assert_eq "${default_destination}" "generic/platform=macOS" "default macOS build destination"

override_destination="$(
    SKYBRIDGE_MACOS_BUILD_DESTINATION="platform=macOS,arch=x86_64" \
        skybridge_default_macos_build_destination
)"
assert_eq "${override_destination}" "platform=macOS,arch=x86_64" "explicit destination override"

arch_override_destination="$(
    SKYBRIDGE_MACOS_BUILD_ARCH="x86_64" \
        skybridge_default_macos_build_destination
)"
assert_eq "${arch_override_destination}" "generic/platform=macOS" "build arch override destination"

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

skybridge_assert_xcframeworks_support_macos_arch "arm64" "${TMP_DIR}/ArmOnly.xcframework"

set +e
unsupported_output="$(
    skybridge_assert_xcframeworks_support_macos_arch "x86_64" "${TMP_DIR}/ArmOnly.xcframework" 2>&1
)"
unsupported_status=$?
set -e

if [[ "${unsupported_status}" -eq 0 ]]; then
    fail "unsupported XCFramework arch should fail"
fi
if [[ "${unsupported_output}" != *"不包含可由 lipo 验证的 macOS x86_64 slice"* ]]; then
    fail "unsupported XCFramework arch should explain missing slice"
fi

set +e
missing_output="$(
    skybridge_assert_xcframeworks_support_macos_arch "arm64" "${TMP_DIR}/Missing.xcframework" 2>&1
)"
missing_status=$?
set -e

if [[ "${missing_status}" -eq 0 ]]; then
    fail "missing XCFramework should fail"
fi
if [[ "${missing_output}" != *"${TMP_DIR}/Missing.xcframework"* ]]; then
    fail "missing XCFramework failure should include the missing path"
fi

mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${SKYBRIDGE_FAKE_XCODEBUILD_ARGS}"
SH
chmod +x "${TMP_DIR}/bin/xcodebuild"

SKYBRIDGE_FAKE_XCODEBUILD_ARGS="${TMP_DIR}/xcodebuild-args.txt" \
    PATH="${TMP_DIR}/bin:${PATH}" \
    skybridge_run_xcodebuild -project Test.xcodeproj build

if ! grep -Fxq "SWIFT_SUPPRESS_WARNINGS=NO" "${TMP_DIR}/xcodebuild-args.txt"; then
    fail "skybridge_run_xcodebuild should disable Swift warning suppression by default"
fi

SKYBRIDGE_FAKE_XCODEBUILD_ARGS="${TMP_DIR}/xcodebuild-args-strict.txt" \
    SKYBRIDGE_XCODE_WARNINGS_AS_ERRORS=1 \
    PATH="${TMP_DIR}/bin:${PATH}" \
    skybridge_run_xcodebuild -project Test.xcodeproj test

for expected_arg in \
    "SWIFT_SUPPRESS_WARNINGS=NO" \
    "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" \
    "GCC_TREAT_WARNINGS_AS_ERRORS=YES"; do
    if ! grep -Fxq "${expected_arg}" "${TMP_DIR}/xcodebuild-args-strict.txt"; then
        fail "skybridge_run_xcodebuild strict mode should pass ${expected_arg}"
    fi
done

set +e
suppress_output="$(
    SKYBRIDGE_FAKE_XCODEBUILD_ARGS="${TMP_DIR}/xcodebuild-args-suppress.txt" \
        PATH="${TMP_DIR}/bin:${PATH}" \
        skybridge_run_xcodebuild SWIFT_SUPPRESS_WARNINGS=YES build 2>&1
)"
suppress_status=$?
set -e

if [[ "${suppress_status}" -eq 0 ]]; then
    fail "skybridge_run_xcodebuild should reject explicit Swift warning suppression"
fi
if [[ "${suppress_output}" != *"禁止使用 SWIFT_SUPPRESS_WARNINGS=YES"* ]]; then
    fail "suppression rejection should explain the forbidden build setting"
fi

echo "[test-xcodebuild-helpers] all checks passed"
