#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Scripts/package_build_policy.sh
source "${SCRIPT_DIR}/package_build_policy.sh"
# shellcheck source=Scripts/framework_artifact_helpers.sh
source "${SCRIPT_DIR}/framework_artifact_helpers.sh"

fail() {
  echo "[test] $1" >&2
  exit 1
}

write_release_platform_metadata_plist() {
  local plist_path="$1"
  local sdk_name="${2:-macosx26.5}"
  local dtxcode="${3:-2660}"
  local dtxcode_build="${4:-17F113}"
  local min_system="${5:-14.0}"
  local platform_name="${6:-macosx}"

  cat > "${plist_path}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>DTPlatformName</key>
  <string>${platform_name}</string>
  <key>DTSDKName</key>
  <string>${sdk_name}</string>
  <key>DTXcode</key>
  <string>${dtxcode}</string>
  <key>DTXcodeBuild</key>
  <string>${dtxcode_build}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${min_system}</string>
</dict>
</plist>
PLIST
}

pqc_probe_available=1
pqc_probe_mode="symbol_probe"
pqc_probe_error=""

skybridge_detect_apple_pqc_sdk() {
  SKYBRIDGE_PQC_SDK_NAME="${1:-macosx}"
  SKYBRIDGE_PQC_SDK_VER="26.5"
  SKYBRIDGE_PQC_SWIFT_TARGET="arm64-apple-macosx26.0"
  SKYBRIDGE_PQC_PROBE_MODE="${pqc_probe_mode}"
  SKYBRIDGE_PQC_PROBE_ERROR="${pqc_probe_error}"
  SKYBRIDGE_PQC_SDK_AVAILABLE="${pqc_probe_available}"
}

skybridge_apple_pqc_sdk_probe_succeeded() {
  [[ "${SKYBRIDGE_PQC_SDK_AVAILABLE:-0}" == "1" && "${SKYBRIDGE_PQC_PROBE_MODE:-}" == "symbol_probe" ]]
}

skybridge_require_apple_pqc_sdk_symbol_probe() {
  skybridge_detect_apple_pqc_sdk "${1:-macosx}"
  skybridge_apple_pqc_sdk_probe_succeeded
}

xcode_dir="/tmp/skybridge-xcode-release"
swiftpm_dir="/tmp/skybridge-swiftpm-release"
verifier_log="/tmp/skybridge-toolchain-verifier.log"
verifier_path="/tmp/skybridge-toolchain-verifier.sh"
rm -rf "${xcode_dir}" "${swiftpm_dir}"
mkdir -p "${xcode_dir}/PackageFrameworks" "${swiftpm_dir}/PackageFrameworks"
rm -f "${verifier_log}" "${verifier_path}"
cat >"${verifier_path}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${SKYBRIDGE_XCODE_TOOLCHAIN_POLICY:-missing}" >>"${SKYBRIDGE_TEST_VERIFIER_LOG:?missing verifier log}"
if [[ "${SKYBRIDGE_TEST_VERIFIER_FAIL:-0}" == "1" ]]; then
  exit 1
fi
SH
chmod +x "${verifier_path}"

framework_layout_dir="/tmp/skybridge-framework-layout-test/WebRTC.framework"
rm -rf "/tmp/skybridge-framework-layout-test"
mkdir -p "${framework_layout_dir}/Versions/A/Versions/A/Resources"
printf '<plist version="1.0"><dict/></plist>\n' > "${framework_layout_dir}/Versions/A/Versions/A/Resources/PrivacyInfo.xcprivacy"
skybridge_normalize_versioned_framework_layout "${framework_layout_dir}" \
  || fail "framework layout normalizer should accept a versioned framework"
[[ -f "${framework_layout_dir}/Versions/A/Resources/PrivacyInfo.xcprivacy" ]] \
  || fail "framework layout normalizer must move nested PrivacyInfo.xcprivacy into Versions/A/Resources"
[[ ! -e "${framework_layout_dir}/Versions/A/Versions" ]] \
  || fail "framework layout normalizer must remove nested Versions payloads"
skybridge_assert_no_nested_framework_versions_payload "${framework_layout_dir}" \
  || fail "framework layout verifier should accept normalized versioned frameworks"

mkdir -p "${framework_layout_dir}/Versions/A"
printf 'reviewed-webrtc-fixture' >"${framework_layout_dir}/Versions/A/WebRTC"
original_webrtc_sha256="${SKYBRIDGE_WEBRTC_M150_MACOS_BINARY_SHA256}"
SKYBRIDGE_WEBRTC_M150_MACOS_BINARY_SHA256="$(shasum -a 256 "${framework_layout_dir}/Versions/A/WebRTC" | awk '{print $1}')"
skybridge_assert_webrtc_m150_framework "${framework_layout_dir}" \
  || fail "WebRTC gate should accept the exact approved binary hash"
SKYBRIDGE_WEBRTC_M150_MACOS_BINARY_SHA256="${original_webrtc_sha256}"
if skybridge_assert_webrtc_m150_framework "${framework_layout_dir}" >/dev/null 2>&1; then
  fail "WebRTC gate must reject an unapproved binary hash"
fi

[[ "$(skybridge_package_build_source "$xcode_dir" "$xcode_dir" "$swiftpm_dir")" == "xcode_release" ]] \
  || fail "xcode build dir should map to xcode_release"

[[ "$(skybridge_package_build_source "$swiftpm_dir" "$xcode_dir" "$swiftpm_dir")" == "swiftpm_release" ]] \
  || fail "swiftpm build dir should map to swiftpm_release"

skybridge_assert_package_build_policy "app" "swiftpm_release" \
  || fail "non-DMG packaging should allow swiftpm_release"

skybridge_assert_package_build_policy "release_dmg" "swiftpm_release" \
  || fail "release_dmg packaging should allow swiftpm_release"

skybridge_assert_package_build_policy "release_dmg" "xcode_release" \
  || fail "release_dmg packaging should allow xcode_release"

if SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1 skybridge_assert_package_build_policy "release_dmg" "xcode_release" >/dev/null 2>&1; then
  fail "release_dmg packaging must reject smoke auto-approve trust"
fi

if skybridge_assert_package_build_policy "release_dmg" "unknown" >/dev/null 2>&1; then
  fail "release_dmg packaging must reject unknown build source"
fi

SKYBRIDGE_TEST_VERIFIER_LOG="${verifier_log}" \
  skybridge_assert_release_stable_toolchain "app" "${verifier_path}" "test local app" \
  || fail "non-release packaging should not require stable release toolchain"
[[ ! -f "${verifier_log}" ]] \
  || fail "non-release packaging must not invoke the stable release toolchain verifier"

SKYBRIDGE_TEST_VERIFIER_LOG="${verifier_log}" \
  skybridge_assert_release_stable_toolchain "release_dmg" "${verifier_path}" "test release" \
  || fail "release_dmg packaging should accept stable release toolchain verifier success"
[[ "$(tail -n 1 "${verifier_log}")" == "stable-release" ]] \
  || fail "release_dmg packaging must invoke verifier with stable-release policy"

if SKYBRIDGE_TEST_VERIFIER_LOG="${verifier_log}" SKYBRIDGE_TEST_VERIFIER_FAIL=1 \
  skybridge_assert_release_stable_toolchain "release_dmg" "${verifier_path}" "test release" >/dev/null 2>&1; then
  fail "release_dmg packaging must reject stable release toolchain verifier failure"
fi

if skybridge_assert_release_stable_toolchain "release_dmg" "/tmp/skybridge-missing-toolchain-verifier" "test release" >/dev/null 2>&1; then
  fail "release_dmg packaging must reject a missing stable release toolchain verifier"
fi

non_executable_verifier="/tmp/skybridge-toolchain-verifier-not-executable.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "${non_executable_verifier}"
chmod 0644 "${non_executable_verifier}"
if skybridge_assert_release_stable_toolchain "release_dmg" "${non_executable_verifier}" "test release" >/dev/null 2>&1; then
  fail "release_dmg packaging must reject a non-executable stable release toolchain verifier"
fi

SKYBRIDGE_ENABLE_APPLE_PQC_SDK=0
pqc_probe_available=1
pqc_probe_mode="symbol_probe"
skybridge_configure_apple_pqc_sdk_for_package_context "release_dmg" "test release" \
  || fail "release_dmg packaging should accept a successful Apple PQC symbol probe"
[[ "${SKYBRIDGE_ENABLE_APPLE_PQC_SDK}" == "1" ]] \
  || fail "successful release Apple PQC probe should enable HAS_APPLE_PQC_SDK"

if (
  pqc_probe_available=1
  pqc_probe_mode="version_fallback"
  pqc_probe_error="fake unproven pqc mode"
  skybridge_configure_apple_pqc_sdk_for_package_context "release_dmg" "test release" >/dev/null 2>&1
); then
  fail "release_dmg packaging must reject Apple PQC availability not proven by symbol_probe"
fi

if (
  SKYBRIDGE_ALLOW_RELEASE_WITHOUT_APPLE_PQC_SDK=1
  pqc_probe_available=0
  pqc_probe_mode="symbol_probe_failed"
  pqc_probe_error="fake pqc probe failure"
  [[ "${SKYBRIDGE_ALLOW_RELEASE_WITHOUT_APPLE_PQC_SDK}" == "1" ]]
  skybridge_configure_apple_pqc_sdk_for_package_context "release_dmg" "test release" >/dev/null 2>&1
); then
  fail "release_dmg packaging must reject Apple PQC probe failure even when diagnostic override is set"
fi

pqc_private_probe_path="/tmp/skybridge-private-pqc-probe/probe.swift"
pqc_private_probe_output="/tmp/skybridge-private-pqc-probe.out"
if (
  pqc_probe_available=0
  pqc_probe_mode="symbol_probe_failed"
  pqc_probe_error="${pqc_private_probe_path}:1:1: error: fake private pqc probe failure"
  skybridge_configure_apple_pqc_sdk_for_package_context "release_dmg" "test release"
) >"${pqc_private_probe_output}" 2>&1; then
  fail "release_dmg packaging must reject failed Apple PQC probe with private paths"
fi
grep -Fq "PQC 探测详情：<tmp> error: fake private pqc probe failure" "${pqc_private_probe_output}" \
  || fail "release Apple PQC probe output must keep a sanitized error summary"
if grep -Fq "${pqc_private_probe_path}" "${pqc_private_probe_output}"; then
  cat "${pqc_private_probe_output}" >&2
  fail "release Apple PQC probe output must not leak raw local probe paths"
fi

pqc_probe_available=0
pqc_probe_mode="symbol_probe_failed"
pqc_probe_error="fake local package probe failure"
SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
skybridge_configure_apple_pqc_sdk_for_package_context "app" "test local app" >/dev/null 2>&1 \
  || fail "non-release packaging should allow local diagnostics without Apple PQC SDK"
[[ "${SKYBRIDGE_ENABLE_APPLE_PQC_SDK}" == "0" ]] \
  || fail "failed non-release Apple PQC probe should disable HAS_APPLE_PQC_SDK"
pqc_probe_available=1
pqc_probe_mode="symbol_probe"
pqc_probe_error=""

if skybridge_configure_apple_pqc_sdk_for_package_context "release-dmg" "typo package context" >/dev/null 2>&1; then
  fail "Apple PQC package policy must reject unknown package contexts instead of treating them as local diagnostics"
fi

if bash -c 'source "$1"; skybridge_configure_apple_pqc_sdk_for_package_context release_dmg "missing detector"' _ "${SCRIPT_DIR}/package_build_policy.sh" >/dev/null 2>&1; then
  fail "release Apple PQC policy must fail when the probe helper is not sourced"
fi

skybridge_assert_release_executable_not_instrumented "/bin/ls" "system executable" \
  || fail "non-instrumented executable should pass release instrumentation guard"

if skybridge_assert_release_executable_not_instrumented "/missing/SkyBridgeCompassApp" >/dev/null 2>&1; then
  fail "instrumentation guard must reject missing executables"
fi

platform_metadata_plist="/tmp/skybridge-release-platform-metadata-test.plist"
write_release_platform_metadata_plist "${platform_metadata_plist}"
skybridge_assert_release_app_stable_platform_metadata "${platform_metadata_plist}" "test release app" \
  || fail "release platform metadata helper should accept stable Xcode 26.6 app metadata"

write_release_platform_metadata_plist "${platform_metadata_plist}" "macosx27.0"
if skybridge_assert_release_app_stable_platform_metadata "${platform_metadata_plist}" "test release app" >/dev/null 2>&1; then
  fail "release platform metadata helper must reject Xcode 27 beta SDK metadata"
fi

write_release_platform_metadata_plist "${platform_metadata_plist}" "macosx26.5" "2660" "27A5194q"
if skybridge_assert_release_app_stable_platform_metadata "${platform_metadata_plist}" "test release app" >/dev/null 2>&1; then
  fail "release platform metadata helper must reject Xcode 27 beta build metadata"
fi

write_release_platform_metadata_plist "${platform_metadata_plist}" "macosx26.5" "2660" "17F113" "15.0"
if skybridge_assert_release_app_stable_platform_metadata "${platform_metadata_plist}" "test release app" >/dev/null 2>&1; then
  fail "release platform metadata helper must reject deployment target drift"
fi

cat > "${platform_metadata_plist}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
</dict>
</plist>
PLIST
if skybridge_assert_release_app_stable_platform_metadata "${platform_metadata_plist}" "test release app" >/dev/null 2>&1; then
  fail "release platform metadata helper must reject missing stable platform metadata"
fi

printf '#!/bin/sh\nexit 0\n' > "${xcode_dir}/SkyBridgeCompassApp"
chmod +x "${xcode_dir}/SkyBridgeCompassApp"

[[ "$(skybridge_release_executable_path "${xcode_dir}" "SkyBridgeCompassApp")" == "${xcode_dir}/SkyBridgeCompassApp" ]] \
  || fail "release executable helper should resolve the normal executable path"

rm -f "${xcode_dir}/SkyBridgeCompassApp"
printf '' > "${xcode_dir}/SkyBridgeCompassApp.stale"
if skybridge_release_executable_path "${xcode_dir}" "SkyBridgeCompassApp" >/dev/null 2>&1; then
  fail "release executable helper should not treat stale product as a valid executable"
fi
[[ "$(skybridge_release_executable_path "${xcode_dir}" "SkyBridgeCompassApp" 2>/dev/null || true)" == "${xcode_dir}/SkyBridgeCompassApp.stale" ]] \
  || fail "release executable helper should expose stale product path"
if skybridge_validate_release_build_dir "${xcode_dir}" "SkyBridgeCompassApp"; then
  fail "stale release output should not validate as packagable"
fi
[[ "${SKYBRIDGE_RELEASE_BUILD_VALIDATION_REASON}" == "stale_executable" ]] \
  || fail "stale release output should report stale_executable"
[[ "${SKYBRIDGE_RELEASE_BUILD_VALIDATION_DETAIL}" == "${xcode_dir}/SkyBridgeCompassApp.stale" ]] \
  || fail "stale release output should report the stale artifact path"

existing_app_policy_root="/tmp/skybridge-existing-app-release-policy"
existing_app_bundle="${existing_app_policy_root}/dist/SkyBridge Compass Pro.app"
existing_app_policy_err="${existing_app_policy_root}/existing-app-policy.err"
rm -rf "${existing_app_policy_root}"
mkdir -p \
  "${existing_app_policy_root}/Sources" \
  "${existing_app_policy_root}/XcodeSupport/SkyBridgeCompassMac" \
  "${existing_app_bundle}/Contents/MacOS"
printf '// package\n' > "${existing_app_policy_root}/Package.swift"
printf 'name: SkyBridge\n' > "${existing_app_policy_root}/project.yml"
printf '// bundle module\n' > "${existing_app_policy_root}/XcodeSupport/SkyBridgeCompassMac/BundleModule.swift"
printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n' > "${existing_app_policy_root}/XcodeSupport/SkyBridgeCompassMac/Info.plist"
printf 'import Foundation\n' > "${existing_app_policy_root}/Sources/App.swift"
printf '#!/bin/sh\nexit 0\n' > "${existing_app_bundle}/Contents/MacOS/SkyBridgeCompassApp"
chmod +x "${existing_app_bundle}/Contents/MacOS/SkyBridgeCompassApp"
printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n' > "${existing_app_bundle}/Contents/Info.plist"
touch -t 202601010000 \
  "${existing_app_policy_root}/Package.swift" \
  "${existing_app_policy_root}/project.yml" \
  "${existing_app_policy_root}/XcodeSupport/SkyBridgeCompassMac/BundleModule.swift" \
  "${existing_app_policy_root}/XcodeSupport/SkyBridgeCompassMac/Info.plist" \
  "${existing_app_policy_root}/Sources/App.swift"
touch -t 202601020000 \
  "${existing_app_bundle}/Contents/MacOS/SkyBridgeCompassApp" \
  "${existing_app_bundle}/Contents/Info.plist"

skybridge_assert_existing_release_app_bundle_fresh "${existing_app_policy_root}" "${existing_app_bundle}" "SkyBridgeCompassApp" \
  || fail "fresh existing release app bundle should pass freshness policy"

touch -t 202601030000 "${existing_app_policy_root}/Sources/App.swift"
if ALLOW_STALE_BUILD=1 skybridge_assert_existing_release_app_bundle_fresh "${existing_app_policy_root}" "${existing_app_bundle}" "SkyBridgeCompassApp" >"${existing_app_policy_err}" 2>&1; then
  fail "release existing-app policy must reject stale bundles even when ALLOW_STALE_BUILD=1"
fi
grep -q "禁止使用 ALLOW_STALE_BUILD" "${existing_app_policy_err}" \
  || fail "release existing-app policy should explain that ALLOW_STALE_BUILD cannot bypass --use-existing-app"
[[ "$(skybridge_existing_app_bundle_stale_source "${existing_app_policy_root}" "${existing_app_bundle}" "SkyBridgeCompassApp")" == "${existing_app_policy_root}/Sources/App.swift" ]] \
  || fail "existing app stale source helper should report the newer source path"

mkdir -p "${xcode_dir}/PackageFrameworks/WebRTC.framework"
printf '' > "${xcode_dir}/PackageFrameworks/WebRTC.framework/WebRTC"
[[ "$(skybridge_release_framework_binary_path "${xcode_dir}" "WebRTC")" == "${xcode_dir}/PackageFrameworks/WebRTC.framework/WebRTC" ]] \
  || fail "framework helper should resolve PackageFrameworks fallback"

swiftpm_bin_path_test_root="/tmp/skybridge-swiftpm-bin-path-test"
swiftpm_bin_path_project="${swiftpm_bin_path_test_root}/project"
swiftpm_bin_path_mock_dir="${swiftpm_bin_path_test_root}/bin"
rm -rf "${swiftpm_bin_path_test_root}"
mkdir -p "${swiftpm_bin_path_project}" "${swiftpm_bin_path_mock_dir}"
cat > "${swiftpm_bin_path_mock_dir}/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
expected_args="build -c release --arch arm64 --show-bin-path --product SkyBridgeCompassApp --disable-automatic-resolution"
if [[ "$*" != "${expected_args}" ]]; then
  echo "unexpected swift arguments: $*" >&2
  exit 64
fi
printf '%s\n' "${SKYBRIDGE_TEST_SWIFTPM_BIN_PATH:-${PWD}/.build/out/Products/Release}"
SH
chmod +x "${swiftpm_bin_path_mock_dir}/swift"
resolved_swiftpm_bin_path="$(
  PATH="${swiftpm_bin_path_mock_dir}:${PATH}" \
    skybridge_resolve_swiftpm_release_build_dir "${swiftpm_bin_path_project}" "arm64" "SkyBridgeCompassApp"
)" || fail "SwiftPM release bin path helper should accept SwiftPM's reported .build/out/Products/Release path"
[[ "${resolved_swiftpm_bin_path}" == "${swiftpm_bin_path_project}/.build/out/Products/Release" ]] \
  || fail "SwiftPM release bin path helper should return SwiftPM's reported release bin path"
export SKYBRIDGE_TEST_SWIFTPM_BIN_PATH=".build/release"
resolved_swiftpm_bin_path="$(
  PATH="${swiftpm_bin_path_mock_dir}:${PATH}" \
    skybridge_resolve_swiftpm_release_build_dir "${swiftpm_bin_path_project}" "arm64" "SkyBridgeCompassApp"
)" || fail "SwiftPM release bin path helper should normalize relative SwiftPM bin paths"
[[ "${resolved_swiftpm_bin_path}" == "${swiftpm_bin_path_project}/.build/release" ]] \
  || fail "SwiftPM release bin path helper should normalize relative paths under the project .build directory"
export SKYBRIDGE_TEST_SWIFTPM_BIN_PATH="/tmp/outside-swiftpm-release"
if PATH="${swiftpm_bin_path_mock_dir}:${PATH}" \
  skybridge_resolve_swiftpm_release_build_dir "${swiftpm_bin_path_project}" "arm64" "SkyBridgeCompassApp" >/dev/null 2>&1; then
  fail "SwiftPM release bin path helper must reject paths outside the current project .build directory"
fi
export SKYBRIDGE_TEST_SWIFTPM_BIN_PATH=$'.build/release\n.build/other-release'
if PATH="${swiftpm_bin_path_mock_dir}:${PATH}" \
  skybridge_resolve_swiftpm_release_build_dir "${swiftpm_bin_path_project}" "arm64" "SkyBridgeCompassApp" >/dev/null 2>&1; then
  fail "SwiftPM release bin path helper must reject ambiguous multi-line SwiftPM output"
fi
unset SKYBRIDGE_TEST_SWIFTPM_BIN_PATH

app_bundle="/tmp/skybridge-pqc-marker-test.app"
rm -rf "${app_bundle}"
mkdir -p "${app_bundle}/Contents/MacOS"
printf '#!/bin/sh\n# %s\nexit 0\n' "${SKYBRIDGE_APPLE_PQC_COMPILE_MARKER}" > "${app_bundle}/Contents/MacOS/SkyBridgeCompassApp"
chmod 700 "${app_bundle}/Contents/MacOS/SkyBridgeCompassApp"
skybridge_assert_bundle_has_apple_pqc_compile_marker "${app_bundle}" "test app" \
  || fail "Apple PQC compile marker helper should accept owner-executable marker-bearing app bundles"

printf '#!/bin/sh\n# %s\nexit 0\n' "${SKYBRIDGE_APPLE_PQC_MISSING_COMPILE_MARKER}" > "${app_bundle}/Contents/MacOS/SkyBridgeCompassApp"
if skybridge_assert_bundle_has_apple_pqc_compile_marker "${app_bundle}" "test app" >/dev/null 2>&1; then
  fail "Apple PQC compile marker helper must reject missing-HAS marker bundles"
fi

printf '#!/bin/sh\nexit 0\n' > "${app_bundle}/Contents/MacOS/SkyBridgeCompassApp"
if skybridge_assert_bundle_has_apple_pqc_compile_marker "${app_bundle}" "test app" >/dev/null 2>&1; then
  fail "Apple PQC compile marker helper must reject bundles with no compile marker"
fi

mkdir -p "${app_bundle}/Contents/Frameworks/SkyBridgeCore.framework"
printf '#!/bin/sh\n# %s\nexit 0\n' "${SKYBRIDGE_APPLE_PQC_COMPILE_MARKER}" > "${app_bundle}/Contents/MacOS/SkyBridgeCompassApp"
printf '# %s\n' "${SKYBRIDGE_APPLE_PQC_MISSING_COMPILE_MARKER}" > "${app_bundle}/Contents/Frameworks/SkyBridgeCore.framework/SkyBridgeCore.dylib"
if skybridge_assert_bundle_has_apple_pqc_compile_marker "${app_bundle}" "test app" >/dev/null 2>&1; then
  fail "Apple PQC compile marker helper must reject mixed HAS and missing-HAS marker bundles"
fi

marker_binary="/tmp/skybridge-pqc-marker-binary-test"
printf '#!/bin/sh\n# %s\nexit 0\n' "${SKYBRIDGE_APPLE_PQC_COMPILE_MARKER}" > "${marker_binary}"
chmod +x "${marker_binary}"
skybridge_assert_binary_has_apple_pqc_compile_marker "${marker_binary}" "test SwiftPM executable" \
  || fail "Apple PQC binary marker helper should accept marker-bearing SwiftPM executables"

printf '#!/bin/sh\n# %s\nexit 0\n' "${SKYBRIDGE_APPLE_PQC_MISSING_COMPILE_MARKER}" > "${marker_binary}"
if skybridge_assert_binary_has_apple_pqc_compile_marker "${marker_binary}" "test SwiftPM executable" >/dev/null 2>&1; then
  fail "Apple PQC binary marker helper must reject missing-HAS SwiftPM executables"
fi

printf '#!/bin/sh\nexit 0\n' > "${marker_binary}"
if skybridge_assert_binary_has_apple_pqc_compile_marker "${marker_binary}" "test SwiftPM executable" >/dev/null 2>&1; then
  fail "Apple PQC binary marker helper must reject SwiftPM executables with no compile marker"
fi

metadata_plist="/tmp/skybridge-pqc-metadata-test.plist"
metadata_app="/tmp/skybridge-pqc-metadata-test.app"
rm -rf "${metadata_app}"
mkdir -p "${metadata_app}/Contents/MacOS"
cat > "${metadata_plist}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
printf '#!/bin/sh\nexit 0\n' > "${metadata_app}/Contents/MacOS/SkyBridgeCompassApp"
chmod +x "${metadata_app}/Contents/MacOS/SkyBridgeCompassApp"
if skybridge_stamp_apple_pqc_sdk_packaging_metadata "${metadata_plist}" "${metadata_app}" "release_dmg" >/dev/null 2>&1; then
  fail "release_dmg metadata stamping must reject bundles without a HAS Apple PQC marker"
fi
if /usr/libexec/PlistBuddy -c "Print :SkyBridgePackagingApplePQCSDKCompiledWithHASApplePQCSDK" "${metadata_plist}" >/dev/null 2>&1; then
  fail "failed release_dmg metadata stamping must not write compiled=false release attestation"
fi

skybridge_stamp_apple_pqc_sdk_packaging_metadata "${metadata_plist}" "${metadata_app}" "app" \
  || fail "local app metadata stamping should record diagnostic non-HAS Apple PQC metadata"
[[ "$(/usr/libexec/PlistBuddy -c "Print :SkyBridgePackagingApplePQCSDKCompiledWithHASApplePQCSDK" "${metadata_plist}")" == "false" ]] \
  || fail "local diagnostic metadata should record compiled=false for non-HAS app bundles"

# --- OS 27 release line: major-tolerant build provenance, floors stay exact ---
write_release_platform_metadata_plist "${platform_metadata_plist}" "macosx27.0" "2700" "27A5194q"
( export SKYBRIDGE_RELEASE_TOOLCHAIN_LINE=xcode27
  skybridge_assert_release_app_stable_platform_metadata "${platform_metadata_plist}" "test os27 release app" ) \
  || fail "xcode27 line should accept macOS 27.0 SDK provenance"

write_release_platform_metadata_plist "${platform_metadata_plist}" "macosx27.3" "2731" "27C5031e"
( export SKYBRIDGE_RELEASE_TOOLCHAIN_LINE=xcode27
  skybridge_assert_release_app_stable_platform_metadata "${platform_metadata_plist}" "test os27 point release app" ) \
  || fail "xcode27 line should accept 27.x point-release provenance without re-pinning"

write_release_platform_metadata_plist "${platform_metadata_plist}" "macosx26.5" "2660" "17F113"
if ( export SKYBRIDGE_RELEASE_TOOLCHAIN_LINE=xcode27
     skybridge_assert_release_app_stable_platform_metadata "${platform_metadata_plist}" "test os27 wrong major" ) >/dev/null 2>&1; then
  fail "xcode27 line must reject macOS 26.5 build provenance"
fi

write_release_platform_metadata_plist "${platform_metadata_plist}" "macosx27.0" "2700" "27A5194q" "15.0"
if ( export SKYBRIDGE_RELEASE_TOOLCHAIN_LINE=xcode27
     skybridge_assert_release_app_stable_platform_metadata "${platform_metadata_plist}" "test os27 floor drift" ) >/dev/null 2>&1; then
  fail "xcode27 line must still reject macOS deployment floor drift (LSMinimumSystemVersion!=14.0)"
fi

# Default (xcode26) line must keep rejecting OS 27 build provenance.
write_release_platform_metadata_plist "${platform_metadata_plist}" "macosx27.0" "2700" "27A5194q"
if skybridge_assert_release_app_stable_platform_metadata "${platform_metadata_plist}" "test default rejects 27" >/dev/null 2>&1; then
  fail "default (xcode26) line must keep rejecting macOS 27 build provenance"
fi

echo "[test] package build policy passed"
