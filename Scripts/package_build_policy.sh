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

skybridge_validate_release_build_dir() {
  local build_dir="$1"
  local executable_name="$2"
  local executable_path=""
  local framework_path=""
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
    if framework_path="$(skybridge_release_framework_binary_path "${build_dir}" "WebRTC")"; then
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

  if [[ "$package_context" == "release_dmg" && "$build_source" == "swiftpm_release" ]]; then
    cat >&2 <<'EOF'
错误：发布 DMG 禁止使用 SwiftPM release fallback 产物打包。
请先完成 Xcode Release 构建，再重新运行 package_app.sh / build_dmg.sh。
EOF
    return 1
  fi

  return 0
}
