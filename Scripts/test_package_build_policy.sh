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

echo "[test] package build policy passed"
