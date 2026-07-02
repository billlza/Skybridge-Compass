#!/usr/bin/env bash

# Capture this library's directory at SOURCE time (global scope), where
# BASH_SOURCE[0] is reliable. Referencing ${BASH_SOURCE[0]} inside a function can
# be empty under `set -u` depending on the call context, which previously made the
# toolchain-pin source path resolve to "/toolchain_release_pin.sh" and fail.
SKYBRIDGE_PACKAGE_BUILD_POLICY_DIR="${SKYBRIDGE_PACKAGE_BUILD_POLICY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"

skybridge_package_build_source() {
  local build_dir="$1"
  local xcode_build_dir="$2"
  local swiftpm_release_build_dir="$3"

  if [[ "$build_dir" == "$xcode_build_dir" ]]; then
    echo "xcode_release"
    return 0
  fi

  if [[ "$build_dir" == "$swiftpm_release_build_dir" ]]; then
    echo "swiftpm_release"
    return 0
  fi

  echo "unknown"
}

skybridge_sanitize_log_value() {
  local value="$1"
  value="${value//$'\n'/ }"
  value="$(sed -E 's#/var/folders/[^[:space:]]+#<tmp>#g; s#/tmp/[^[:space:]]+#<tmp>#g; s#<tmp>/[^[:space:]]+#<tmp>#g' <<<"${value}")"
  value="$(sed -E 's#/Applications/([^/[:space:]]+\.app)/Contents/Developer#<applications>/\1/Contents/Developer#g; s#/Applications/([^/[:space:]]+\.app)#<applications>/\1#g' <<<"${value}")"
  if [[ -n "${HOME:-}" ]]; then
    value="${value//${HOME}/<home>}"
  fi
  if [[ -n "${TMPDIR:-}" ]]; then
    value="${value//${TMPDIR}/<tmp>}"
  fi
  value="$(sed -E 's#<tmp>/[^[:space:]]+#<tmp>#g; s/^ //; s/ $//' <<<"${value}")"
  printf '%s\n' "${value}"
}

skybridge_release_executable_path() {
  local build_dir="$1"
  local executable_name="$2"
  local executable_path="${build_dir}/${executable_name}"
  local stale_path="${build_dir}/${executable_name}.stale"

  if [[ -x "${executable_path}" ]]; then
    printf '%s\n' "${executable_path}"
    return 0
  fi

  if [[ -e "${stale_path}" ]]; then
    printf '%s\n' "${stale_path}"
    return 2
  fi

  return 1
}

skybridge_release_framework_binary_path() {
  local build_dir="$1"
  local framework_name="$2"
  local direct_path="${build_dir}/${framework_name}.framework/${framework_name}"
  local package_framework_path="${build_dir}/PackageFrameworks/${framework_name}.framework/${framework_name}"

  if [[ -e "${direct_path}" ]]; then
    printf '%s\n' "${direct_path}"
    return 0
  fi

  if [[ -e "${package_framework_path}" ]]; then
    printf '%s\n' "${package_framework_path}"
    return 0
  fi

  return 1
}

skybridge_resolve_swiftpm_release_build_dir() {
  local project_root="$1"
  local build_arch="$2"
  local product_name="$3"
  local scratch_path="${SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH:-}"
  local raw_output=""
  local nonempty_output=""
  local line_count=""
  local resolved_path=""
  local swiftpm_args=()

  if [[ -z "${project_root}" || -z "${build_arch}" || -z "${product_name}" ]]; then
    echo "错误：SwiftPM Release 路径解析缺少 project root、build arch 或 product name。" >&2
    return 1
  fi

  if [[ -n "${scratch_path}" && "${scratch_path}" != /* ]]; then
    scratch_path="${project_root}/${scratch_path#./}"
  fi

  swiftpm_args=(
    -c release
    --arch "${build_arch}"
  )
  if [[ -n "${scratch_path}" ]]; then
    swiftpm_args+=(--scratch-path "${scratch_path}")
  fi

  if ! raw_output="$(
    cd "${project_root}" && swift build \
      "${swiftpm_args[@]}" \
      --show-bin-path \
      --product "${product_name}" \
      --disable-automatic-resolution
  )"; then
    echo "错误：无法解析 SwiftPM Release bin path（product=${product_name}, arch=${build_arch}）。" >&2
    return 1
  fi

  nonempty_output="$(printf '%s\n' "${raw_output}" | sed '/^[[:space:]]*$/d')"
  line_count="$(printf '%s\n' "${nonempty_output}" | wc -l | tr -d '[:space:]')"
  if [[ "${line_count}" != "1" ]]; then
    echo "错误：SwiftPM Release bin path 输出必须是单行，当前为 ${line_count} 行。" >&2
    return 1
  fi

  resolved_path="${nonempty_output}"
  if [[ "${resolved_path}" != /* ]]; then
    resolved_path="${project_root}/${resolved_path#./}"
  fi

  if [[ -n "${scratch_path}" ]]; then
    case "${resolved_path}" in
      "${scratch_path}"|"${scratch_path}/"*)
        printf '%s\n' "${resolved_path}"
        return 0
        ;;
      *)
        echo "错误：SwiftPM Release bin path 不在配置的 scratch path 内：${resolved_path}" >&2
        return 1
        ;;
    esac
  fi

  case "${resolved_path}" in
    "${project_root}/.build"|"${project_root}/.build/"*)
      printf '%s\n' "${resolved_path}"
      ;;
    *)
      echo "错误：SwiftPM Release bin path 不在当前项目 .build 目录内：${resolved_path}" >&2
      return 1
      ;;
  esac
}

SKYBRIDGE_RELEASE_BUILD_VALIDATION_REASON=""
SKYBRIDGE_RELEASE_BUILD_VALIDATION_DETAIL=""
SKYBRIDGE_APPLE_PQC_COMPILE_MARKER="${SKYBRIDGE_APPLE_PQC_COMPILE_MARKER:-skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk}"
SKYBRIDGE_APPLE_PQC_MISSING_COMPILE_MARKER="${SKYBRIDGE_APPLE_PQC_MISSING_COMPILE_MARKER:-skybridge.apple-pqc-sdk.compile-fact.v1.missing-has-apple-pqc-sdk}"
SKYBRIDGE_APPLE_PQC_SYMBOL_SET="${SKYBRIDGE_APPLE_PQC_SYMBOL_SET:-cryptokit-pqc-v1}"

skybridge_release_build_validation_reason() {
  printf '%s\n' "${SKYBRIDGE_RELEASE_BUILD_VALIDATION_REASON}"
}

skybridge_release_build_validation_detail() {
  printf '%s\n' "${SKYBRIDGE_RELEASE_BUILD_VALIDATION_DETAIL}"
}

skybridge_assert_no_smoke_auto_approval_for_release_context() {
  local release_context="${1:-release}"

  if [[ "${SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING:-0}" == "1" ]]; then
    echo "错误：SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1 is smoke-only and is forbidden for ${release_context}" >&2
    return 1
  fi

  return 0
}

skybridge_assert_release_stable_toolchain() {
  local package_context="$1"
  local verifier_path="$2"
  local artifact_label="${3:-release package}"

  if [[ "${package_context}" != "release_dmg" ]]; then
    return 0
  fi

  if [[ -z "${verifier_path}" || ! -x "${verifier_path}" ]]; then
    echo "错误：${artifact_label} 缺少可执行的 release Xcode verifier：${verifier_path}" >&2
    return 1
  fi

  # The verifier policy follows the selected release toolchain line (single
  # source of truth in toolchain_release_pin.sh). Default line xcode26 ->
  # stable-release (exact Xcode 26.6 + macOS SDK 26.5); line xcode27 ->
  # os27-release (major-tolerant).
  # shellcheck source=Scripts/toolchain_release_pin.sh
  source "${SKYBRIDGE_PACKAGE_BUILD_POLICY_DIR}/toolchain_release_pin.sh"
  local verify_policy
  verify_policy="$(skybridge_release_pin_verify_policy)"

  SKYBRIDGE_XCODE_TOOLCHAIN_POLICY="${verify_policy}" "${verifier_path}" || {
    echo "错误：${artifact_label} 必须使用受支持的发布工具链（line=${SKYBRIDGE_RELEASE_TOOLCHAIN_LINE:-xcode26}, policy=${verify_policy}）；未固定/未授权的工具链不得用于 release_dmg/package/manifest 发布。" >&2
    return 1
  }
}

skybridge_assert_release_app_stable_platform_metadata() {
  local info_plist="$1"
  local context="${2:-release app bundle}"

  if [[ -z "${info_plist}" || ! -f "${info_plist}" ]]; then
    echo "错误：${context} 缺少 Info.plist，无法证明稳定发布平台 metadata：${info_plist}" >&2
    return 1
  fi

  # Build-provenance (DT*) expectations come from the selected release toolchain
  # line. Default line xcode26 -> exact macosx26.5 / 2660 / 17F113. Line xcode27 ->
  # major-tolerant macosx27.x / 27xx with the rotating beta build id unasserted.
  # shellcheck source=Scripts/toolchain_release_pin.sh
  source "${SKYBRIDGE_PACKAGE_BUILD_POLICY_DIR}/toolchain_release_pin.sh"
  skybridge_release_pin_load || return 1

  SKYBRIDGE_PIN_DT_SDK_NAME="${SKYBRIDGE_PIN_DT_SDK_NAME}" \
  SKYBRIDGE_PIN_DT_XCODE="${SKYBRIDGE_PIN_DT_XCODE}" \
  SKYBRIDGE_PIN_DT_XCODE_BUILD="${SKYBRIDGE_PIN_DT_XCODE_BUILD}" \
  SKYBRIDGE_PIN_MATCH_MODE="${SKYBRIDGE_PIN_MATCH_MODE}" \
  python3 - "${info_plist}" "${context}" <<'PY'
import os
import plistlib
import sys
from pathlib import Path


info_path = Path(sys.argv[1])
context = sys.argv[2]
with info_path.open("rb") as fh:
    info = plistlib.load(fh)

match_mode = os.environ.get("SKYBRIDGE_PIN_MATCH_MODE", "exact")
exp_sdk_name = os.environ.get("SKYBRIDGE_PIN_DT_SDK_NAME", "macosx26.5")
exp_dtxcode = os.environ.get("SKYBRIDGE_PIN_DT_XCODE", "2660")
exp_dtxcode_build = os.environ.get("SKYBRIDGE_PIN_DT_XCODE_BUILD", "17F113")

errors = []

# Runtime FLOOR + bundle identity are ALWAYS exact, independent of the build SDK
# line. Bumping the build toolchain must never move the macOS 14 deployment floor.
fixed_scalars = {
    "CFBundlePackageType": "APPL",
    "LSMinimumSystemVersion": "14.0",
    "DTPlatformName": "macosx",
}
for key, expected in fixed_scalars.items():
    actual = info.get(key)
    if str(actual) != expected:
        errors.append(f"{key} must be {expected}, got {actual!r}")

if info.get("CFBundleSupportedPlatforms") != ["MacOSX"]:
    errors.append("CFBundleSupportedPlatforms must be exactly ['MacOSX']")


def check_provenance(key, expected, actual):
    actual_s = "" if actual is None else str(actual)
    if not expected:
        return  # not asserted on this line (e.g. rotating beta build ids)
    if match_mode == "exact":
        if actual_s != expected:
            errors.append(f"{key} must be {expected}, got {actual!r}")
    elif not actual_s.startswith(expected):
        errors.append(f"{key} must start with {expected!r} (line match_mode={match_mode}), got {actual!r}")


check_provenance("DTSDKName", exp_sdk_name, info.get("DTSDKName"))
check_provenance("DTXcode", exp_dtxcode, info.get("DTXcode"))
check_provenance("DTXcodeBuild", exp_dtxcode_build, info.get("DTXcodeBuild"))

if errors:
    for error in errors:
        print(f"错误：{context} {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

skybridge_validate_release_build_dir() {
  local build_dir="$1"
  local executable_name="$2"
  local executable_path=""
  local executable_status=0

  SKYBRIDGE_RELEASE_BUILD_VALIDATION_REASON=""
  SKYBRIDGE_RELEASE_BUILD_VALIDATION_DETAIL=""

  if executable_path="$(skybridge_release_executable_path "${build_dir}" "${executable_name}")"; then
    :
  else
    executable_status=$?
    case "${executable_status}" in
      1)
        SKYBRIDGE_RELEASE_BUILD_VALIDATION_REASON="missing_executable"
        SKYBRIDGE_RELEASE_BUILD_VALIDATION_DETAIL="${build_dir}/${executable_name}"
        ;;
      2)
        SKYBRIDGE_RELEASE_BUILD_VALIDATION_REASON="stale_executable"
        SKYBRIDGE_RELEASE_BUILD_VALIDATION_DETAIL="${build_dir}/${executable_name}.stale"
        ;;
      *)
        SKYBRIDGE_RELEASE_BUILD_VALIDATION_REASON="unknown"
        SKYBRIDGE_RELEASE_BUILD_VALIDATION_DETAIL="${build_dir}"
        ;;
    esac
    return 1
  fi

  if otool -L "${executable_path}" 2>/dev/null | grep -q "@rpath/WebRTC.framework/WebRTC"; then
    if skybridge_release_framework_binary_path "${build_dir}" "WebRTC" >/dev/null; then
      :
    else
      SKYBRIDGE_RELEASE_BUILD_VALIDATION_REASON="missing_webrtc_framework"
      SKYBRIDGE_RELEASE_BUILD_VALIDATION_DETAIL="${build_dir}/WebRTC.framework/WebRTC|${build_dir}/PackageFrameworks/WebRTC.framework/WebRTC"
      return 1
    fi
  fi

  return 0
}

skybridge_assert_package_build_policy() {
  local package_context="$1"
  local build_source="$2"

  if [[ "$package_context" == "release_dmg" ]]; then
    skybridge_assert_no_smoke_auto_approval_for_release_context "release_dmg packaging" || return 1

    case "$build_source" in
      xcode_release|swiftpm_release)
        return 0
        ;;
    esac

    echo "错误：发布 DMG 只接受明确的 Release 产物，当前构建来源：${build_source}" >&2
    return 1
  fi

  case "$build_source" in
    xcode_release|swiftpm_release)
      return 0
      ;;
  esac

  return 0
}

skybridge_existing_app_bundle_stale_source() {
  local project_root="$1"
  local app_bundle_path="$2"
  local executable_name="${3:-SkyBridgeCompassApp}"
  local executable_reference="${app_bundle_path}"
  local info_reference="${app_bundle_path}"
  local stale_source=""

  if [[ -d "${app_bundle_path}" && -x "${app_bundle_path}/Contents/MacOS/${executable_name}" ]]; then
    executable_reference="${app_bundle_path}/Contents/MacOS/${executable_name}"
  fi
  if [[ -d "${app_bundle_path}" && -f "${app_bundle_path}/Contents/Info.plist" ]]; then
    info_reference="${app_bundle_path}/Contents/Info.plist"
  fi

  if [[ ! -e "${executable_reference}" ]]; then
    return 1
  fi

  if [[ "${project_root}/Package.swift" -nt "${executable_reference}" ]]; then
    stale_source="${project_root}/Package.swift"
  elif [[ "${project_root}/project.yml" -nt "${info_reference}" ]]; then
    stale_source="${project_root}/project.yml"
  elif [[ "${project_root}/XcodeSupport/SkyBridgeCompassMac/BundleModule.swift" -nt "${executable_reference}" ]]; then
    stale_source="${project_root}/XcodeSupport/SkyBridgeCompassMac/BundleModule.swift"
  elif [[ "${project_root}/XcodeSupport/SkyBridgeCompassMac/Info.plist" -nt "${info_reference}" ]]; then
    stale_source="${project_root}/XcodeSupport/SkyBridgeCompassMac/Info.plist"
  else
    stale_source="$(find "${project_root}/Sources" -type f \( -name "*.swift" -o -name "*.c" -o -name "*.cc" -o -name "*.cpp" -o -name "*.h" -o -name "*.hpp" -o -name "*.m" -o -name "*.mm" \) -newer "${executable_reference}" -print -quit 2>/dev/null || true)"
  fi

  if [[ -n "${stale_source}" ]]; then
    printf '%s\n' "${stale_source}"
    return 0
  fi

  return 1
}

skybridge_assert_existing_release_app_bundle_fresh() {
  local project_root="$1"
  local app_bundle_path="$2"
  local executable_name="${3:-SkyBridgeCompassApp}"
  local stale_source=""

  if stale_source="$(skybridge_existing_app_bundle_stale_source "${project_root}" "${app_bundle_path}" "${executable_name}")"; then
    echo "错误：检测到现有 App Bundle 早于源码：${stale_source}" >&2
    echo "错误：发布 DMG 的 --use-existing-app 禁止使用 ALLOW_STALE_BUILD 绕过；请重新构建后再打包。" >&2
    return 1
  fi

  return 0
}

skybridge_configure_apple_pqc_sdk_for_package_context() {
  local package_context="$1"
  local artifact_label="${2:-release package}"

  case "${package_context}" in
    app|release_dmg)
      ;;
    *)
      echo "错误：${artifact_label} 使用了不支持的 package context：${package_context}；允许值为 app 或 release_dmg。" >&2
      return 1
      ;;
  esac

  if ! command -v skybridge_detect_apple_pqc_sdk >/dev/null 2>&1 \
    || ! command -v skybridge_apple_pqc_sdk_probe_succeeded >/dev/null 2>&1 \
    || ! command -v skybridge_require_apple_pqc_sdk_symbol_probe >/dev/null 2>&1; then
    echo "错误：${artifact_label} 缺少 Apple PQC SDK symbol probe helper；请先 source Scripts/apple_pqc_sdk_probe.sh。" >&2
    return 1
  fi

  if [[ "${package_context}" == "release_dmg" ]]; then
    if skybridge_require_apple_pqc_sdk_symbol_probe macosx; then
      export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
      return 0
    fi

    export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=0
    echo "错误：${artifact_label} 必须通过 Apple PQC SDK symbol probe；禁止使用 SKYBRIDGE_ALLOW_RELEASE_WITHOUT_APPLE_PQC_SDK 绕过 release DMG/package 发布路径。" >&2
    echo "PQC 探测：mode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown}, sdk=${SKYBRIDGE_PQC_SDK_NAME:-macosx}, version=${SKYBRIDGE_PQC_SDK_VER:-unknown}, target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown}" >&2
    if [[ -n "${SKYBRIDGE_PQC_PROBE_ERROR:-}" ]]; then
      echo "PQC 探测详情：$(skybridge_sanitize_log_value "${SKYBRIDGE_PQC_PROBE_ERROR}")" >&2
    fi
    return 1
  fi

  skybridge_detect_apple_pqc_sdk macosx

  if skybridge_apple_pqc_sdk_probe_succeeded; then
    export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
    return 0
  fi

  export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=0
  echo "警告：${artifact_label} 未通过 Apple PQC SDK symbol probe，已禁用 HAS_APPLE_PQC_SDK；仅允许本地非发布包。" >&2
  if [[ -n "${SKYBRIDGE_PQC_PROBE_ERROR:-}" ]]; then
    echo "PQC 探测详情：$(skybridge_sanitize_log_value "${SKYBRIDGE_PQC_PROBE_ERROR}")" >&2
  fi
  return 0
}

skybridge_binary_contains_string() {
  local binary_path="$1"
  local needle="$2"
  local binary_strings=""

  [[ -f "${binary_path}" ]] || return 1
  binary_strings="$(strings -a "${binary_path}" 2>/dev/null || true)"
  grep -Fq "${needle}" <<< "${binary_strings}"
}

skybridge_app_binary_candidates() {
  local app_bundle="$1"
  local macos_dir="${app_bundle}/Contents/MacOS"
  local frameworks_dir="${app_bundle}/Contents/Frameworks"

  if [[ -d "${macos_dir}" ]]; then
    find "${macos_dir}" -type f \( -perm -100 -o -perm -010 -o -perm -001 \) -print 2>/dev/null
  fi
  if [[ -d "${frameworks_dir}" ]]; then
    find "${frameworks_dir}" -type f \( -perm -100 -o -perm -010 -o -perm -001 -o -name "*.dylib" -o -name "*.so" \) -print 2>/dev/null
  fi
}

skybridge_bundle_has_apple_pqc_compile_marker() {
  local app_bundle="$1"
  local binary_path=""
  local found_marker=0

  [[ -d "${app_bundle}" ]] || return 1

  while IFS= read -r binary_path; do
    [[ -n "${binary_path}" ]] || continue
    if skybridge_binary_contains_string "${binary_path}" "${SKYBRIDGE_APPLE_PQC_MISSING_COMPILE_MARKER}"; then
      return 2
    fi
    if skybridge_binary_contains_string "${binary_path}" "${SKYBRIDGE_APPLE_PQC_COMPILE_MARKER}"; then
      found_marker=1
    fi
  done < <(skybridge_app_binary_candidates "${app_bundle}" | sort -u)

  [[ "${found_marker}" == "1" ]]
}

skybridge_assert_bundle_has_apple_pqc_compile_marker() {
  local app_bundle="$1"
  local context="${2:-release app bundle}"
  local status=0

  if skybridge_bundle_has_apple_pqc_compile_marker "${app_bundle}"; then
    return 0
  fi
  status=$?
  if [[ "${status}" == "2" ]]; then
    echo "错误：${context} 包含未启用 HAS_APPLE_PQC_SDK 的编译 marker：${app_bundle}" >&2
    return 1
  fi

  echo "错误：${context} 缺少 Apple PQC SDK 编译 marker：${SKYBRIDGE_APPLE_PQC_COMPILE_MARKER}" >&2
  echo "请确认发布产物不是旧的 SKIP_BUILD 缓存，并且主应用/核心框架由 HAS_APPLE_PQC_SDK 编译。" >&2
  return 1
}

skybridge_assert_binary_has_apple_pqc_compile_marker() {
  local binary_path="$1"
  local context="${2:-executable}"

  if [[ -z "${binary_path}" || ! -f "${binary_path}" ]]; then
    echo "错误：${context} 缺少可验证的 Apple PQC SDK 编译 marker 二进制：${binary_path}" >&2
    return 1
  fi

  if skybridge_binary_contains_string "${binary_path}" "${SKYBRIDGE_APPLE_PQC_MISSING_COMPILE_MARKER}"; then
    echo "错误：${context} 包含未启用 HAS_APPLE_PQC_SDK 的编译 marker：${binary_path}" >&2
    return 1
  fi

  if skybridge_binary_contains_string "${binary_path}" "${SKYBRIDGE_APPLE_PQC_COMPILE_MARKER}"; then
    return 0
  fi

  echo "错误：${context} 缺少 Apple PQC SDK 编译 marker：${SKYBRIDGE_APPLE_PQC_COMPILE_MARKER}" >&2
  echo "请确认产物不是旧缓存，并且目标由 HAS_APPLE_PQC_SDK 编译。" >&2
  return 1
}

skybridge_stamp_apple_pqc_sdk_packaging_metadata() {
  local info_plist="$1"
  local app_bundle="$2"
  local package_context="${3:-app}"
  local compiled_marker="${SKYBRIDGE_APPLE_PQC_MISSING_COMPILE_MARKER}"
  local compiled_bool="false"
  local secure_enclave_bool="false"

  if skybridge_bundle_has_apple_pqc_compile_marker "${app_bundle}"; then
    compiled_bool="true"
    compiled_marker="${SKYBRIDGE_APPLE_PQC_COMPILE_MARKER}"
  elif [[ "${package_context}" == "release_dmg" ]]; then
    skybridge_assert_bundle_has_apple_pqc_compile_marker "${app_bundle}" "release_dmg packaged app" || return 1
  fi

  if [[ "${SKYBRIDGE_PQC_INCLUDED_SECURE_ENCLAVE:-0}" == "1" ]]; then
    secure_enclave_bool="true"
  fi

  plutil -replace SkyBridgePackagingApplePQCSDKCompiledWithHASApplePQCSDK -bool "${compiled_bool}" "${info_plist}"
  plutil -replace SkyBridgePackagingApplePQCSDKCompileMarker -string "${compiled_marker}" "${info_plist}"
  plutil -replace SkyBridgePackagingApplePQCSDKSymbolSet -string "${SKYBRIDGE_APPLE_PQC_SYMBOL_SET}" "${info_plist}"
  plutil -replace SkyBridgePackagingApplePQCSDKProbeMode -string "${SKYBRIDGE_PQC_PROBE_MODE:-unknown}" "${info_plist}"
  plutil -replace SkyBridgePackagingApplePQCSDKName -string "${SKYBRIDGE_PQC_SDK_NAME:-macosx}" "${info_plist}"
  plutil -replace SkyBridgePackagingApplePQCSDKVersion -string "${SKYBRIDGE_PQC_SDK_VER:-unknown}" "${info_plist}"
  plutil -replace SkyBridgePackagingApplePQCSDKSwiftTarget -string "${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown}" "${info_plist}"
  plutil -replace SkyBridgePackagingApplePQCSDKSecureEnclaveSymbolsIncluded -bool "${secure_enclave_bool}" "${info_plist}"
}

skybridge_assert_release_executable_not_instrumented() {
  local executable_path="$1"
  local context="${2:-release executable}"

  if [[ ! -x "$executable_path" ]]; then
    echo "错误：${context} 不存在或不可执行：${executable_path}" >&2
    return 1
  fi

  if otool -l "$executable_path" 2>/dev/null | grep -Eq '__llvm|__llvm_prf|__llvm_cov|__llvm_profile'; then
    echo "错误：${context} 包含 LLVM coverage/profile instrumentation section：${executable_path}" >&2
    return 1
  fi

  if strings -a "$executable_path" 2>/dev/null | grep -Eq 'default\.profraw|LLVM_PROFILE|__llvm_profile|__llvm_covmap|__llvm_prf'; then
    echo "错误：${context} 包含 LLVM coverage/profile runtime marker：${executable_path}" >&2
    return 1
  fi
}
