#!/usr/bin/env bash

skybridge_validate_macos_arch() {
    local build_arch="${1:-}"
    case "${build_arch}" in
        arm64|x86_64)
            ;;
        *)
            echo "错误：不支持的 macOS 构建架构=${build_arch}；允许值为 arm64 或 x86_64。" >&2
            return 1
            ;;
    esac
}

skybridge_default_macos_build_arch() {
    local build_arch="${SKYBRIDGE_MACOS_BUILD_ARCH:-arm64}"
    skybridge_validate_macos_arch "${build_arch}" >/dev/null || return 1
    printf '%s\n' "${build_arch}"
}

skybridge_default_macos_run_destination() {
    if [[ -n "${SKYBRIDGE_MACOS_RUN_DESTINATION:-}" ]]; then
        printf '%s\n' "${SKYBRIDGE_MACOS_RUN_DESTINATION}"
        return 0
    fi

    local run_arch="${SKYBRIDGE_MACOS_RUN_ARCH:-arm64}"
    skybridge_validate_macos_arch "${run_arch}" >/dev/null || return 1

    if command -v xcrun >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        local resolved_destination

        resolved_destination="$(
            xcrun xcdevice list 2>/dev/null | python3 -c '
import json
import os
import sys

run_arch = os.environ.get("SKYBRIDGE_MACOS_RUN_ARCH", "arm64").strip() or "arm64"

try:
    devices = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

for device in devices:
    if device.get("platform") != "com.apple.platform.macosx":
        continue
    if device.get("simulator"):
        continue
    if not device.get("available", False):
        continue
    identifier = str(device.get("identifier", "")).strip()
    if identifier:
        print(f"platform=macOS,arch={run_arch},id={identifier}")
        raise SystemExit(0)

raise SystemExit(1)
' 2>/dev/null
        )" || true

        if [[ -n "${resolved_destination}" ]]; then
            printf '%s\n' "${resolved_destination}"
            return 0
        fi
    fi

    printf '%s\n' "platform=macOS,arch=${run_arch}"
}

skybridge_default_macos_build_destination() {
    if [[ -n "${SKYBRIDGE_MACOS_BUILD_DESTINATION:-}" ]]; then
        printf '%s\n' "${SKYBRIDGE_MACOS_BUILD_DESTINATION}"
        return 0
    fi

    local build_arch
    build_arch="$(skybridge_default_macos_build_arch)" || return 1

    # Swift package xcodebuild 的 build 动作依然要求显式 destination。
    # 多匹配目的地告警由下方 allowlist 过滤器精准移除，避免掩盖其他真实 warning。
    printf '%s\n' "platform=macOS,arch=${build_arch}"
}

skybridge_default_macos_destination() {
    skybridge_default_macos_run_destination
}

skybridge_default_xcode_derived_data_path() {
    if [[ -n "${SKYBRIDGE_XCODE_DERIVED_DATA_PATH:-}" ]]; then
        printf '%s\n' "${SKYBRIDGE_XCODE_DERIVED_DATA_PATH}"
        return 0
    fi

    printf '%s\n' "${HOME}/Library/Developer/Xcode/DerivedData/SkyBridgeCompassPro-Release"
}

skybridge_filter_xcodebuild_output() {
    awk '
        BEGIN {
            skip_matching_destinations = 0
        }

        /IDERunDestination: Supported platforms for the buildables in the current scheme is empty\./ {
            next
        }

        /^--- xcodebuild: WARNING: Using the first of multiple matching destinations:/ {
            skip_matching_destinations = 1
            next
        }

        skip_matching_destinations && /^\{ platform:/ {
            next
        }

        skip_matching_destinations && /^$/ {
            skip_matching_destinations = 0
            next
        }

        {
            skip_matching_destinations = 0
            print
        }
    '
}

skybridge_run_xcodebuild() {
    local temp_dir
    local fifo_path
    local filter_pid
    local command_status

    if [[ "${SKYBRIDGE_XCODEBUILD_KEEP_NOISE:-0}" == "1" ]]; then
        xcodebuild "$@" 2>&1 | skybridge_filter_xcodebuild_output
        return $?
    fi

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-xcodebuild.XXXXXX")"
    fifo_path="${temp_dir}/output.fifo"
    mkfifo "${fifo_path}"

    skybridge_filter_xcodebuild_output < "${fifo_path}" &
    filter_pid=$!

    xcodebuild "$@" > "${fifo_path}" 2>&1
    command_status=$?

    wait "${filter_pid}" || true
    rm -rf "${temp_dir}"

    return "${command_status}"
}
