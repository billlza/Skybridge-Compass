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

skybridge_xcframework_supports_macos_arch() {
    local xcframework_path="${1:-}"
    local build_arch="${2:-}"
    local info_plist="${xcframework_path}/Info.plist"
    local candidate_binaries=""
    local binary_path=""

    if [[ ! -f "${info_plist}" ]]; then
        return 1
    fi

    candidate_binaries="$(
        python3 - "${xcframework_path}" "${build_arch}" <<'PY'
import plistlib
import sys
from pathlib import Path

xcframework_path = Path(sys.argv[1])
build_arch = sys.argv[2]
info_plist = xcframework_path / "Info.plist"


def resolve_binary_path(library_root: Path, library_path: str) -> Path:
    artifact = library_root / library_path
    if artifact.suffix == ".framework" and artifact.is_dir():
        binary_name = artifact.stem
        versioned_binary = artifact / "Versions" / "A" / binary_name
        if versioned_binary.exists():
            return versioned_binary
        return artifact / binary_name
    return artifact

with info_plist.open("rb") as handle:
    plist = plistlib.load(handle)

found = False
for library in plist.get("AvailableLibraries", []):
    if library.get("SupportedPlatform") != "macos":
        continue
    if build_arch in library.get("SupportedArchitectures", []):
        library_identifier = str(library.get("LibraryIdentifier", "")).strip()
        library_path = str(library.get("LibraryPath") or library.get("BinaryPath") or "").strip()
        if not library_identifier or not library_path:
            continue
        print(resolve_binary_path(xcframework_path / library_identifier, library_path))
        found = True

raise SystemExit(0 if found else 1)
PY
    )" || return 1

    if [[ -z "${candidate_binaries}" ]]; then
        return 1
    fi

    while IFS= read -r binary_path; do
        if [[ -z "${binary_path}" || ! -f "${binary_path}" ]]; then
            return 1
        fi
        if ! lipo "${binary_path}" -verify_arch "${build_arch}" >/dev/null 2>&1; then
            return 1
        fi
    done <<< "${candidate_binaries}"
}

skybridge_assert_xcframeworks_support_macos_arch() {
    local build_arch="${1:-}"
    shift || true

    skybridge_validate_macos_arch "${build_arch}" >/dev/null || return 1

    local unsupported=()
    local xcframework_path
    for xcframework_path in "$@"; do
        if ! skybridge_xcframework_supports_macos_arch "${xcframework_path}" "${build_arch}"; then
            unsupported+=("${xcframework_path}")
        fi
    done

    if [[ "${#unsupported[@]}" -eq 0 ]]; then
        return 0
    fi

    echo "错误：macOS 构建架构=${build_arch} 与供应商 XCFramework 不匹配。" >&2
    echo "以下依赖缺失，或不包含可由 lipo 验证的 macOS ${build_arch} slice，不能生成该架构的发布包：" >&2
    for xcframework_path in "${unsupported[@]}"; do
        echo "  - ${xcframework_path}" >&2
    done
    echo "请改用 SKYBRIDGE_MACOS_BUILD_ARCH=arm64，或先补齐这些 XCFramework 的 macOS ${build_arch} 产物。" >&2
    return 1
}

skybridge_resolve_local_macos_destination() {
    local target_arch="${1:-}"
    skybridge_validate_macos_arch "${target_arch}" >/dev/null || return 1

    if command -v xcrun >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        local resolved_destination

        resolved_destination="$(
            xcrun xcdevice list 2>/dev/null | python3 -c '
import json
import sys

target_arch = sys.argv[1]

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
        print(f"platform=macOS,arch={target_arch},id={identifier}")
        raise SystemExit(0)

raise SystemExit(1)
' "${target_arch}" 2>/dev/null
        )" || true

        if [[ -n "${resolved_destination}" ]]; then
            printf '%s\n' "${resolved_destination}"
            return 0
        fi
    fi

    return 1
}

skybridge_default_macos_run_destination() {
    if [[ -n "${SKYBRIDGE_MACOS_RUN_DESTINATION:-}" ]]; then
        printf '%s\n' "${SKYBRIDGE_MACOS_RUN_DESTINATION}"
        return 0
    fi

    local run_arch="${SKYBRIDGE_MACOS_RUN_ARCH:-arm64}"
    local resolved_destination=""
    skybridge_validate_macos_arch "${run_arch}" >/dev/null || return 1

    if resolved_destination="$(skybridge_resolve_local_macos_destination "${run_arch}")"; then
        printf '%s\n' "${resolved_destination}"
        return 0
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

    # Build actions should not bind to the local Mac device id. On Xcode 26 a
    # physical Mac id also matches Catalyst, DriverKit, and iOS-on-Mac variants,
    # which makes xcodebuild warn and pick an arbitrary first match. The build
    # scripts still pin the architecture through ARCHS/ONLY_ACTIVE_ARCH.
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
    local arg
    for arg in "$@"; do
        case "${arg}" in
            SWIFT_SUPPRESS_WARNINGS=YES|SWIFT_SUPPRESS_WARNINGS=yes|SWIFT_SUPPRESS_WARNINGS=1|SWIFT_SUPPRESS_WARNINGS=true|SWIFT_SUPPRESS_WARNINGS=TRUE)
                echo "错误：禁止使用 SWIFT_SUPPRESS_WARNINGS=${arg#*=} 掩盖 Swift warning；请修复 warning 本身。" >&2
                return 1
                ;;
        esac
    done

    local xcodebuild_warning_settings=(
        "SWIFT_SUPPRESS_WARNINGS=NO"
    )
    case "${SKYBRIDGE_XCODE_WARNINGS_AS_ERRORS:-0}" in
        1|true|TRUE|yes|YES)
            xcodebuild_warning_settings+=(
                "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES"
                "GCC_TREAT_WARNINGS_AS_ERRORS=YES"
            )
            ;;
        0|false|FALSE|no|NO|"")
            ;;
        *)
            echo "错误：不支持的 SKYBRIDGE_XCODE_WARNINGS_AS_ERRORS=${SKYBRIDGE_XCODE_WARNINGS_AS_ERRORS}；允许值为 0/1。" >&2
            return 1
            ;;
    esac

    xcodebuild "${xcodebuild_warning_settings[@]}" "$@"
}
