#!/usr/bin/env bash

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

SKYBRIDGE_RELEASE_BUILD_VALIDATION_REASON=""
SKYBRIDGE_RELEASE_BUILD_VALIDATION_DETAIL=""

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
