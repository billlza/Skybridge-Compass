#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/package_build_policy.sh"

fail() {
  echo "[test] $1" >&2
  exit 1
}

xcode_dir="/tmp/skybridge-xcode-release"
swiftpm_dir="/tmp/skybridge-swiftpm-release"
rm -rf "${xcode_dir}" "${swiftpm_dir}"
mkdir -p "${xcode_dir}/PackageFrameworks" "${swiftpm_dir}/PackageFrameworks"

[[ "$(skybridge_package_build_source "$xcode_dir" "$xcode_dir" "$swiftpm_dir")" == "xcode_release" ]] \
  || fail "xcode build dir should map to xcode_release"

[[ "$(skybridge_package_build_source "$swiftpm_dir" "$xcode_dir" "$swiftpm_dir")" == "swiftpm_release" ]] \
  || fail "swiftpm build dir should map to swiftpm_release"

skybridge_assert_package_build_policy "app" "swiftpm_release" \
  || fail "non-DMG packaging should not reject swiftpm fallback"

if skybridge_assert_package_build_policy "release_dmg" "swiftpm_release"; then
  fail "release_dmg packaging must reject swiftpm fallback"
fi

skybridge_assert_package_build_policy "release_dmg" "xcode_release" \
  || fail "release_dmg packaging should allow xcode_release"

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

mkdir -p "${xcode_dir}/PackageFrameworks/WebRTC.framework"
printf '' > "${xcode_dir}/PackageFrameworks/WebRTC.framework/WebRTC"
[[ "$(skybridge_release_framework_binary_path "${xcode_dir}" "WebRTC")" == "${xcode_dir}/PackageFrameworks/WebRTC.framework/WebRTC" ]] \
  || fail "framework helper should resolve PackageFrameworks fallback"

echo "[test] package build policy passed"
