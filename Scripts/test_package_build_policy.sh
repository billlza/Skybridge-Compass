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

test_package_output_policy() {
  (
    set -euo pipefail

    policy_sandbox="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-package-output-policy.XXXXXX")"
    trap '/bin/rm -rf -- "${policy_sandbox}"' EXIT

    policy_project_root="${policy_sandbox}/project"
    policy_defaultless_root="${policy_sandbox}/default project"
    policy_custom_output="${policy_sandbox}/output with spaces"
    policy_wrong_mode_output="${policy_sandbox}/wrong-mode-output"
    policy_output_link="${policy_sandbox}/output-link"
    policy_victim_dir="${policy_sandbox}/must-survive"
    mkdir -p \
      "${policy_project_root}/dist" \
      "${policy_defaultless_root}" \
      "${policy_custom_output}" \
      "${policy_wrong_mode_output}" \
      "${policy_victim_dir}"
    chmod 0700 \
      "${policy_project_root}" \
      "${policy_project_root}/dist" \
      "${policy_defaultless_root}" \
      "${policy_custom_output}" \
      "${policy_victim_dir}"
    chmod 0755 "${policy_wrong_mode_output}"
    ln -s "${policy_custom_output}" "${policy_output_link}"

    canonical_defaultless_root="$(cd "${policy_defaultless_root}" && pwd -P)"
    expected_default_path="${canonical_defaultless_root}/dist/${SKYBRIDGE_PACKAGE_APP_BUNDLE_NAME}"
    resolved_default_path="$(skybridge_resolve_package_app_path \
      "${policy_defaultless_root}" \
      "app" \
      "")"
    [[ "${resolved_default_path}" == "${expected_default_path}" ]] \
      || fail "default app packaging path must remain project dist even before dist exists"
    skybridge_remove_package_app_bundle_for_replacement \
      "${policy_defaultless_root}" \
      "app" \
      "" \
      "${resolved_default_path}" \
      || fail "missing default dist should require no replacement removal"
    [[ ! -e "${canonical_defaultless_root}/dist" && ! -L "${canonical_defaultless_root}/dist" ]] \
      || fail "replacement policy must not create a missing default dist"

    canonical_custom_output="$(cd "${policy_custom_output}" && pwd -P)"
    expected_custom_path="${canonical_custom_output}/${SKYBRIDGE_PACKAGE_APP_BUNDLE_NAME}"
    resolved_custom_path="$(skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "${policy_custom_output}")"
    [[ "${resolved_custom_path}" == "${expected_custom_path}" ]] \
      || fail "custom app output with spaces must resolve to the fixed bundle child"

    mkdir -p "${expected_custom_path}"
    printf 'sibling-must-survive\n' > "${canonical_custom_output}/sibling.txt"
    skybridge_remove_package_app_bundle_for_replacement \
      "${policy_project_root}" \
      "app" \
      "${policy_custom_output}" \
      "${resolved_custom_path}" \
      || fail "validated custom App Bundle should be replaceable"
    [[ ! -e "${expected_custom_path}" && ! -L "${expected_custom_path}" ]] \
      || fail "replacement must remove only the fixed App Bundle target"
    [[ "$(<"${canonical_custom_output}/sibling.txt")" == "sibling-must-survive" ]] \
      || fail "replacement must not modify an output-directory sibling"

    mkdir -p "${expected_custom_path}"
    chmod 0755 "${canonical_custom_output}"
    if skybridge_remove_package_app_bundle_for_replacement \
      "${policy_project_root}" \
      "app" \
      "${policy_custom_output}" \
      "${resolved_custom_path}" >/dev/null 2>&1; then
      fail "replacement must revalidate output permissions immediately before removal"
    fi
    [[ -d "${expected_custom_path}" ]] \
      || fail "failed permission revalidation must preserve the existing App Bundle"
    chmod 0700 "${canonical_custom_output}"
    /bin/rm -rf -- "${expected_custom_path}"

    printf 'victim-must-survive\n' > "${policy_victim_dir}/marker.txt"
    ln -s "${policy_victim_dir}" "${expected_custom_path}"
    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "${policy_custom_output}" >/dev/null 2>&1; then
      fail "custom packaging must reject a symlink final App Bundle target"
    fi
    if skybridge_remove_package_app_bundle_for_replacement \
      "${policy_project_root}" \
      "app" \
      "${policy_custom_output}" \
      "${resolved_custom_path}" >/dev/null 2>&1; then
      fail "replacement revalidation must reject a symlink target introduced after resolution"
    fi
    [[ -L "${expected_custom_path}" ]] \
      || fail "failed target revalidation must leave the symlink in place"
    [[ "$(<"${policy_victim_dir}/marker.txt")" == "victim-must-survive" ]] \
      || fail "failed target revalidation must not touch the symlink destination"
    /bin/rm -- "${expected_custom_path}"

    (
      set -euo pipefail

      policy_race_original_output="${policy_sandbox}/output-before-parent-swap"
      policy_race_ready_fifo="${policy_sandbox}/parent-swap-ready.fifo"
      policy_race_swapped_fifo="${policy_sandbox}/parent-swap-complete.fifo"
      policy_race_victim_app="${policy_victim_dir}/${SKYBRIDGE_PACKAGE_APP_BUNDLE_NAME}"
      policy_race_expected_status="swapped"
      mkdir -p "${expected_custom_path}" "${policy_race_victim_app}"
      printf 'original-app-must-survive\n' > "${expected_custom_path}/marker.txt"
      printf 'victim-app-must-survive\n' > "${policy_race_victim_app}/marker.txt"
      mkfifo "${policy_race_ready_fifo}" "${policy_race_swapped_fifo}"

      eval "$(declare -f skybridge_resolve_package_app_path | \
        sed '1s/^skybridge_resolve_package_app_path /skybridge_resolve_package_app_path_without_parent_swap /')"
      skybridge_resolve_package_app_path() {
        local resolver_status=0
        local swap_status

        skybridge_resolve_package_app_path_without_parent_swap "$@" || resolver_status=$?
        if [[ "${resolver_status}" != "0" ]]; then
          return "${resolver_status}"
        fi

        printf 'ready\n' > "${policy_race_ready_fifo}"
        IFS= read -r swap_status < "${policy_race_swapped_fifo}"
        [[ "${swap_status}" == "${policy_race_expected_status}" ]]
      }

      (
        swap_status="failed"
        trap 'printf "%s\n" "${swap_status}" > "${policy_race_swapped_fifo}"' EXIT
        IFS= read -r ready_status < "${policy_race_ready_fifo}"
        [[ "${ready_status}" == "ready" ]]
        mv "${policy_custom_output}" "${policy_race_original_output}"
        ln -s "${policy_victim_dir}" "${policy_custom_output}"
        swap_status="swapped"
      ) &
      policy_race_pid=$!

      if skybridge_remove_package_app_bundle_for_replacement \
        "${policy_project_root}" \
        "app" \
        "${policy_custom_output}" \
        "${resolved_custom_path}" >/dev/null 2>&1; then
        fail "replacement must fail closed when the validated parent is swapped for a symlink"
      fi
      wait "${policy_race_pid}"

      [[ -L "${policy_custom_output}" ]] \
        || fail "parent-swap rejection must leave the replacement symlink in place"
      [[ "$(<"${policy_race_victim_app}/marker.txt")" == "victim-app-must-survive" ]] \
        || fail "parent-swap rejection must not delete the victim's fixed bundle child"
      [[ "$(<"${policy_race_original_output}/${SKYBRIDGE_PACKAGE_APP_BUNDLE_NAME}/marker.txt")" == "original-app-must-survive" ]] \
        || fail "parent-swap rejection must preserve the originally validated bundle"

      /bin/rm -- "${policy_custom_output}"
      mv "${policy_race_original_output}" "${policy_custom_output}"
      /bin/rm -rf -- "${expected_custom_path}"

      policy_race_disappeared_output="${policy_sandbox}/output-before-disappear"
      policy_race_expected_status="disappeared"
      mkdir -p "${expected_custom_path}"
      printf 'disappeared-parent-app-must-survive\n' > "${expected_custom_path}/marker.txt"
      (
        swap_status="failed"
        trap 'printf "%s\n" "${swap_status}" > "${policy_race_swapped_fifo}"' EXIT
        IFS= read -r ready_status < "${policy_race_ready_fifo}"
        [[ "${ready_status}" == "ready" ]]
        mv "${policy_custom_output}" "${policy_race_disappeared_output}"
        swap_status="disappeared"
      ) &
      policy_race_pid=$!

      if skybridge_remove_package_app_bundle_for_replacement \
        "${policy_project_root}" \
        "app" \
        "${policy_custom_output}" \
        "${resolved_custom_path}" >/dev/null 2>&1; then
        fail "replacement must fail closed when an explicit output disappears after validation"
      fi
      wait "${policy_race_pid}"

      [[ ! -e "${policy_custom_output}" && ! -L "${policy_custom_output}" ]] \
        || fail "disappear-after-resolve regression must leave the original output path absent"
      [[ "$(<"${policy_race_disappeared_output}/${SKYBRIDGE_PACKAGE_APP_BUNDLE_NAME}/marker.txt")" == "disappeared-parent-app-must-survive" ]] \
        || fail "disappear-after-resolve rejection must preserve the validated bundle"

      mv "${policy_race_disappeared_output}" "${policy_custom_output}"
      /bin/rm -rf -- "${expected_custom_path}"
      /bin/rm -- "${policy_race_ready_fifo}" "${policy_race_swapped_fifo}"
    )

    printf 'not-a-directory\n' > "${expected_custom_path}"
    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "${policy_custom_output}" >/dev/null 2>&1; then
      fail "custom packaging must reject a non-directory final target"
    fi
    /bin/rm -- "${expected_custom_path}"

    canonical_project_root="$(cd "${policy_project_root}" && pwd -P)"
    canonical_dist="$(cd "${policy_project_root}/dist" && pwd -P)"
    resolved_release_path="$(skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "release_dmg" \
      "${canonical_dist}")"
    [[ "${resolved_release_path}" == "${canonical_dist}/${SKYBRIDGE_PACKAGE_APP_BUNDLE_NAME}" ]] \
      || fail "release_dmg must accept build_dmg's explicit pin to project dist"

    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "release_dmg" \
      "${policy_custom_output}" >/dev/null 2>&1; then
      fail "release_dmg must reject a redirected output directory"
    fi
    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "${canonical_dist}" >/dev/null 2>&1; then
      fail "app context must not treat explicit project dist as a custom output"
    fi
    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "${canonical_project_root}" >/dev/null 2>&1; then
      fail "custom app output must reject the project root"
    fi
    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "${HOME}" >/dev/null 2>&1; then
      fail "custom app output must reject HOME"
    fi
    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "/" >/dev/null 2>&1; then
      fail "custom app output must reject the filesystem root"
    fi
    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "relative-output" >/dev/null 2>&1; then
      fail "custom app output must reject relative paths"
    fi
    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "${policy_sandbox}/missing-output" >/dev/null 2>&1; then
      fail "custom app output must already exist"
    fi
    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "${policy_wrong_mode_output}" >/dev/null 2>&1; then
      fail "custom app output must have exact 0700 permissions"
    fi
    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "${policy_output_link}" >/dev/null 2>&1; then
      fail "custom app output must reject a symlink directory"
    fi

    policy_newline_output="${policy_sandbox}/newline"$'\n'"output"
    mkdir -p "${policy_newline_output}"
    chmod 0700 "${policy_newline_output}"
    if skybridge_resolve_package_app_path \
      "${policy_project_root}" \
      "app" \
      "${policy_newline_output}" >/dev/null 2>&1; then
      fail "custom app output must reject newline control characters"
    fi
  )
}

test_package_output_policy \
  || fail "package output policy regression suite failed"

package_app_script="${SCRIPT_DIR}/package_app.sh"
sign_app_script="${SCRIPT_DIR}/sign_app.sh"
build_dmg_script="${SCRIPT_DIR}/build_dmg.sh"
build_with_widgets_script="${SCRIPT_DIR}/build_with_widgets.sh"
[[ "$(grep -c 'skybridge_resolve_package_app_path' "${package_app_script}")" == "1" ]] \
  || fail "package_app must resolve its App Bundle output through package build policy exactly once"
[[ "$(grep -c 'skybridge_remove_package_app_bundle_for_replacement' "${package_app_script}")" == "1" ]] \
  || fail "package_app must replace its App Bundle through the revalidating policy helper"
if grep -F 'rm -rf "${APP_DIR}"' "${package_app_script}" >/dev/null 2>&1; then
  fail "package_app must not bypass output-policy revalidation with direct App Bundle removal"
fi
[[ "$(grep -Fc 'SKYBRIDGE_PACKAGE_OUTPUT_DIR="$DIST_DIR"' "${build_dmg_script}")" == "2" ]] \
  || fail "both build_dmg package_app invocations must pin output to project dist"
[[ "$(grep -Fc "SKYBRIDGE_PACKAGE_BUILD_ID=\"\$BUILD_ID\"" "${build_dmg_script}")" == "2" ]] \
  || fail "both build_dmg package_app invocations must carry the explicit release build id"
grep -Fq '正式 DMG 构建不得使用时间或隐式构建号' "${build_dmg_script}" \
  || fail "build_dmg must reject an omitted release build id"
grep -Fq 'release_dmg 打包要求显式 SKYBRIDGE_PACKAGE_BUILD_ID' "${package_app_script}" \
  || fail "package_app must reject time-derived build ids in release_dmg context"
grep -Fq 'VERSION="$(bash "$PROJECT_ROOT/Scripts/check_macos_release_version.sh")"' "${build_with_widgets_script}" \
  || fail "legacy widget build must resolve version through the validated release version source"
grep -Fq 'if ! codesign --verify --verbose "$APP_BUNDLE"; then' "${build_with_widgets_script}" \
  || fail "legacy widget build must fail closed when final bundle signature verification fails"
if grep -Fq '|| echo "1.0.0"' "${build_with_widgets_script}"; then
  fail "legacy widget build must not hide missing release version metadata behind 1.0.0"
fi
if grep -Fq '签名验证警告（ad-hoc 签名正常）' "${build_with_widgets_script}"; then
  fail "legacy widget build must not downgrade signature verification failure to a warning"
fi

if missing_build_id_output="$(bash "${build_dmg_script}" 2>&1)"; then
  fail "build_dmg must fail when --build-id is omitted"
fi
grep -Fq '正式 DMG 构建不得使用时间或隐式构建号' <<<"${missing_build_id_output}" \
  || fail "build_dmg omitted-build-id failure must explain the explicit transaction requirement"

if invalid_build_id_output="$(bash "${build_dmg_script}" --build-id 1.0.2 2>&1)"; then
  fail "build_dmg must reject non-numeric --build-id values"
fi
grep -Fq -- '--build-id 必须是正整数' <<<"${invalid_build_id_output}" \
  || fail "build_dmg invalid-build-id failure must identify the numeric requirement"

if missing_package_build_id_output="$(
  SKYBRIDGE_PACKAGE_CONTEXT=release_dmg zsh "${package_app_script}" 2>&1
)"; then
  fail "package_app release_dmg must reject a missing SKYBRIDGE_PACKAGE_BUILD_ID"
fi
grep -Fq '要求显式 SKYBRIDGE_PACKAGE_BUILD_ID' <<<"${missing_package_build_id_output}" \
  || fail "package_app release_dmg must explain the missing explicit build id"

test_owner_executable_signing_policy() {
  (
    set -euo pipefail

    executable_sandbox="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-owner-executable.XXXXXX")"
    trap '/bin/rm -rf -- "${executable_sandbox}"' EXIT
    owner_executable="${executable_sandbox}/owner-executable"
    other_executable="${executable_sandbox}/other-executable"
    printf 'owner\n' > "${owner_executable}"
    printf 'other\n' > "${other_executable}"
    chmod 0700 "${owner_executable}"
    chmod 0001 "${other_executable}"

    matched_executables="$(find "${executable_sandbox}" -type f -perm -u+x -print)"
    [[ "${matched_executables}" == "${owner_executable}" ]] \
      || fail "owner-executable signing predicate must select 0700 files and reject files without owner execute"
  )
}

test_owner_executable_signing_policy \
  || fail "owner-executable signing predicate regression suite failed"

grep -Fq -- 'find "${bundle}/Contents/MacOS" -type f -perm -u+x' "${package_app_script}" \
  || fail "package_app resource-bundle signing must include 0700 owner-executable files"
grep -Fq -- '-name "*.so" -o -perm -u+x' "${package_app_script}" \
  || fail "package_app framework signing must include 0700 owner-executable files"
grep -Fq -- 'find "${CONTENTS_DIR}/Library/LaunchDaemons" -type f -perm -u+x' "${package_app_script}" \
  || fail "package_app helper signing must include 0700 owner-executable files"
grep -Fq -- 'find "${MACOS_DIR}" -type f -perm -u+x' "${package_app_script}" \
  || fail "package_app main-executable signing must include 0700 owner-executable files"
grep -Fq -- 'find "${helpers_dir}" -type f -perm -u+x' "${sign_app_script}" \
  || fail "sign_app helper signing must include 0700 owner-executable files"
if grep -Fq -- '-perm -111' "${package_app_script}" "${sign_app_script}"; then
  fail "packaging signers must not require group/other execute bits when selecting owner-executable files"
fi
grep -Fq -- 'codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp "${HELPER_DST_DIR}"' "${package_app_script}" \
  || fail "package_app must apply hardened runtime when explicitly signing PowerMetricsHelper"

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
  export SKYBRIDGE_PQC_SDK_NAME="${1:-macosx}"
  export SKYBRIDGE_PQC_SDK_VER="26.5"
  export SKYBRIDGE_PQC_SWIFT_TARGET="arm64-apple-macosx26.0"
  SKYBRIDGE_PQC_PROBE_MODE="${pqc_probe_mode}"
  export SKYBRIDGE_PQC_PROBE_ERROR="${pqc_probe_error}"
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
