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

    # Build-only invocations should avoid physical device discovery.  The ARCHS
    # build setting still carries the requested architecture.
    printf '%s\n' "generic/platform=macOS"
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

skybridge_run_xcodebuild() {
    xcodebuild "$@"
}
