#!/usr/bin/env bash
#
# SkyBridge Compass DMG Builder
#
# 功能：
# 1. 构建 Release 版本应用（默认使用 SwiftPM Release 主可执行文件，避免 Xcode Package scheme 的 destination 歧义）
# 2. 复用 package_app.sh 生成兼容 SMAppService 的 .app（含 PowerMetricsHelper）
# 3. （可选）重新签名
# 4. 创建 DMG 磁盘映像（带背景与 Applications 快捷方式）
#
# 使用方法：
#   ./Scripts/build_dmg.sh [--skip-build] [--skip-sign] [--identity "Developer ID"] [--use-existing-app]
#
# 发布策略：
# - build_dmg.sh 会强制 package_app.sh 进入 release_dmg 上下文
# - release_dmg 上下文只接受明确 Release 构建产物
# - 复用已有 .app 时也必须带有可验证的 release provenance
#

set -euo pipefail

APP_NAME="SkyBridge Compass Pro"
DMG_NAME="SkyBridgeCompassPro"
VOLUME_NAME="SkyBridge Compass Pro"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_ROOT/Scripts/apple_pqc_sdk_probe.sh"
source "$PROJECT_ROOT/Scripts/framework_artifact_helpers.sh"
source "$PROJECT_ROOT/Scripts/notarytool_helpers.sh"
source "$PROJECT_ROOT/Scripts/package_build_policy.sh"
source "$PROJECT_ROOT/Scripts/xcodebuild_helpers.sh"
XCODE_DERIVED_DATA_PATH="${SKYBRIDGE_XCODE_DERIVED_DATA_PATH:-$(skybridge_default_xcode_derived_data_path)}"
INFO_PLIST_PATH="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_PATH" 2>/dev/null || echo "0.0.0")"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/${DMG_NAME}-${VERSION}.dmg"
TEMP_DMG="$DIST_DIR/temp_${DMG_NAME}.sparsebundle"
STAGE_DIR="$DIST_DIR/dmg_stage"
BG_SRC_PNG="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/Resources/AppIcon.png"
BG_NAME="background.png"
BUILD_DESTINATION="${BUILD_DESTINATION:-$(skybridge_default_macos_build_destination)}"
BUILD_ARCH="${BUILD_ARCH:-$(skybridge_default_macos_build_arch)}"
XCODE_PROJECT="$PROJECT_ROOT/SkyBridgeWidgets.xcodeproj"
XCODE_MAC_SCHEME="${SKYBRIDGE_MACOS_APP_SCHEME:-SkyBridgeCompassMac}"
XCODE_PACKAGE_SCHEME="${SKYBRIDGE_MACOS_PACKAGE_SCHEME:-SkyBridgeCompassApp}"
XCODE_APP_BUNDLE="${SKYBRIDGE_XCODE_APP_BUNDLE:-$XCODE_DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app}"
XCODE_PACKAGE_WORKSPACE="$PROJECT_ROOT/.swiftpm/xcode/package.xcworkspace"
XCODE_PACKAGE_EXECUTABLE="$XCODE_DERIVED_DATA_PATH/Build/Products/Release/SkyBridgeCompassApp"
SWIFTPM_RELEASE_BUILD_DIR=""
SWIFTPM_PACKAGE_EXECUTABLE=""
MAIN_BUILD_SYSTEM="${SKYBRIDGE_DMG_MAIN_BUILD_SYSTEM:-swiftpm}"
if [[ "$MAIN_BUILD_SYSTEM" == "swiftpm" && -z "${SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH:-}" ]]; then
    export SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH="/tmp/skybridge-swiftpm-release-${BUILD_ARCH}"
fi
VENDOR_XCFRAMEWORKS=(
    "$PROJECT_ROOT/Sources/Vendor/liboqs.xcframework"
    "$PROJECT_ROOT/Sources/Vendor/libopus.xcframework"
)

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARIZE_APP="${NOTARIZE_APP:-0}"
NOTARIZE_DMG="${NOTARIZE_DMG:-0}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
NOTARYTOOL_KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
ENSURE_DEVELOPER_ID_PROFILES="${SKYBRIDGE_ENSURE_DEVELOPER_ID_PROFILES:-1}"
ASSOCIATE_DEVELOPER_ID_APP_GROUPS="${SKYBRIDGE_ASSOCIATE_DEVELOPER_ID_APP_GROUPS:-0}"

SKIP_BUILD=false
SKIP_SIGN=false
USE_EXISTING_APP=false
JUST_BUILT_RELEASE=false
FINAL_SOURCE_MOUNT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-sign)
            SKIP_SIGN=true
            shift
            ;;
        --use-existing-app|--use-packaged-app)
            USE_EXISTING_APP=true
            shift
            ;;
        --identity)
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --notarize-dmg)
            NOTARIZE_DMG="1"
            shift
            ;;
        --notarize-app)
            NOTARIZE_APP="1"
            shift
            ;;
        --require-notarization)
            REQUIRE_NOTARIZATION="1"
            shift
            ;;
        --notarytool-keychain-profile)
            NOTARYTOOL_KEYCHAIN_PROFILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --skip-build         跳过构建步骤"
            echo "  --skip-sign          仅配合 --use-existing-app 跳过重签名（新构建发布包仍必须签名）"
            echo "  --use-existing-app   复用 dist/ 下已存在的 .app"
            echo "  --identity ID        指定签名身份（Developer ID / Apple Development）"
            echo "  --notarize-app       对 .app 执行 Apple notarization 并 staple"
            echo "  --notarize-dmg       生成 DMG 后提交 Apple notarization 并 staple"
            echo "  --require-notarization  若产物未 notarized，则以失败退出"
            echo "  --notarytool-keychain-profile <profile>  使用指定 notarytool keychain profile"
            echo "  SKYBRIDGE_ENSURE_DEVELOPER_ID_PROFILES=0 可跳过发布前 provisioning profile 自检"
            echo "  SKYBRIDGE_ASSOCIATE_DEVELOPER_ID_APP_GROUPS=1 允许首次配置时交互式关联 App Groups"
            echo "  --help, -h           显示帮助信息"
            exit 0
            ;;
        *)
            echo "未知选项: $1" >&2
            exit 1
            ;;
    esac
done

if [[ "$SKIP_SIGN" == true && "$USE_EXISTING_APP" != true ]]; then
    echo "❌ --skip-sign 只允许配合 --use-existing-app 使用；新构建的 release_dmg 必须经过 Developer ID 签名。" >&2
    exit 1
fi

case "$MAIN_BUILD_SYSTEM" in
    swiftpm|xcode)
        ;;
    *)
        echo "❌ 不支持的 SKYBRIDGE_DMG_MAIN_BUILD_SYSTEM=${MAIN_BUILD_SYSTEM}；允许值为 swiftpm 或 xcode" >&2
        exit 1
        ;;
esac

skybridge_assert_no_smoke_auto_approval_for_release_context "release_dmg build" || exit 1
skybridge_assert_release_stable_toolchain "release_dmg" "$PROJECT_ROOT/Scripts/verify_xcode_toolchain.sh" "Release DMG build" || exit 1

if [[ "$MAIN_BUILD_SYSTEM" == "swiftpm" ]]; then
    SWIFTPM_RELEASE_BUILD_DIR="$(skybridge_resolve_swiftpm_release_build_dir "$PROJECT_ROOT" "$BUILD_ARCH" "$XCODE_PACKAGE_SCHEME")" || exit 1
    SWIFTPM_PACKAGE_EXECUTABLE="$SWIFTPM_RELEASE_BUILD_DIR/SkyBridgeCompassApp"
fi

if [[ "$USE_EXISTING_APP" != true ]]; then
    skybridge_assert_xcframeworks_support_macos_arch "$BUILD_ARCH" "${VENDOR_XCFRAMEWORKS[@]}"
fi

if [[ -z "${SKYBRIDGE_REQUIRE_APP_GROUPS+x}" ]]; then
    export SKYBRIDGE_REQUIRE_APP_GROUPS=1
fi
if [[ -z "${SKYBRIDGE_REQUIRE_WIDGET_EXTENSION+x}" ]]; then
    export SKYBRIDGE_REQUIRE_WIDGET_EXTENSION=1
fi
if [[ -z "${SKYBRIDGE_REQUIRE_APPLE_SIGN_IN_MODE+x}" ]]; then
    export SKYBRIDGE_REQUIRE_APPLE_SIGN_IN_MODE=web_session
fi
# The shipping production app must never link the testing-only SkyBridgeSmokeSupport
# module. Exclude it from the production library/app targets for every sub-build
# (SwiftPM main executable + Xcode Widget/app target) unless a caller has
# explicitly overridden the flag. Smoke-host executables keep the module.
if [[ -z "${SKYBRIDGE_RELEASE_EXCLUDE_SMOKE_SUPPORT+x}" ]]; then
    export SKYBRIDGE_RELEASE_EXCLUDE_SMOKE_SUPPORT=1
fi

log_info() {
    echo "ℹ️  $1"
}

log_info_path() {
    local label="$1"
    local path_value="$2"
    log_info "${label}: $(skybridge_sanitize_log_value "${path_value}")"
}

log_success() {
    echo "✅ $1"
}

log_error() {
    echo "❌ $1" >&2
}

log_step() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

assess_and_report_gatekeeper() {
    local target="$1"
    local target_type="$2"
    local label="$3"
    local output=""

    if output="$(skybridge_assess_gatekeeper "$target" "$target_type")"; then
        if skybridge_gatekeeper_is_notarized "$output"; then
            echo "✅ ${label} Gatekeeper 评估通过（已 notarized）" >&2
        else
            echo "ℹ️  ${label} Gatekeeper 评估通过（未显式显示 notarized）" >&2
        fi
    else
        echo "ℹ️  ${label} Gatekeeper 评估未通过" >&2
    fi

    printf '%s\n' "$output"
}

artifact_has_stapled_ticket() {
    local artifact="$1"
    local attempt

    for _ in {1..5}; do
        if xcrun stapler validate "$artifact" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

verify_app_bundle_build_source() {
    local app_bundle="$1"
    local info_plist="$app_bundle/Contents/Info.plist"
    local build_source=""
    local build_scheme=""
    local build_configuration=""
    local git_commit=""
    local git_branch=""
    local git_dirty_state=""

    skybridge_assert_release_app_stable_platform_metadata "$info_plist" "Release DMG App Bundle" || exit 1

    if [[ -f "$info_plist" ]]; then
        build_source=$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingBuildSource' "$info_plist" 2>/dev/null || true)
        build_scheme=$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingBuildScheme' "$info_plist" 2>/dev/null || true)
        build_configuration=$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingBuildConfiguration' "$info_plist" 2>/dev/null || true)
        git_commit=$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingGitCommit' "$info_plist" 2>/dev/null || true)
        git_branch=$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingGitBranch' "$info_plist" 2>/dev/null || true)
        git_dirty_state=$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingGitDirtyState' "$info_plist" 2>/dev/null || true)
    fi

    case "$build_source" in
        xcode_release|swiftpm_release)
            if [[ "$build_scheme" == "$XCODE_PACKAGE_SCHEME" \
                && "$build_configuration" == "Release" \
                && -n "$git_commit" \
                && "$git_commit" != "unknown" \
                && -n "$git_branch" \
                && "$git_branch" != "unknown" \
                && "$git_dirty_state" == "clean" ]]; then
                return 0
            fi
            ;;
    esac

    log_error "发布 DMG 仅允许使用明确 Release 产物打包。当前 App Bundle 构建来源: ${build_source:-missing}"
    log_error "期望 scheme/config: ${XCODE_PACKAGE_SCHEME}/Release；当前: ${build_scheme:-missing}/${build_configuration:-missing}"
    log_error "期望 Git provenance: explicit commit, explicit branch state, clean worktree；当前: commit=${git_commit:-missing} branch=${git_branch:-missing} dirty=${git_dirty_state:-missing}"
    log_error "请重新执行 build_dmg.sh（不要复用未知来源生成的 .app）。"
    exit 1
}

verify_release_executable_runtime_inputs() {
    local executable_path="$1"
    local build_dir
    build_dir="$(dirname "$executable_path")"

    if [[ ! -x "$executable_path" ]]; then
        log_error "Xcode workspace 未产出主可执行文件：$executable_path"
        exit 1
    fi

    if otool -L "$executable_path" 2>/dev/null | grep -q "@rpath/WebRTC.framework/WebRTC"; then
        local framework_source=""
        if ! framework_source="$(skybridge_resolve_framework_source_dir "WebRTC" "$BUILD_ARCH" "$build_dir" "$XCODE_DERIVED_DATA_PATH" "$PROJECT_ROOT")"; then
            log_error "主可执行文件依赖 WebRTC.framework，但 Release 构建目录和 SwiftPM artifacts 都缺少 macOS $BUILD_ARCH slice"
            exit 1
        fi
        if ! skybridge_assert_webrtc_m150_framework "$framework_source"; then
            log_error "Release WebRTC.framework 不是审核通过的 exact M150 macOS 原始二进制"
            exit 1
        fi
        log_info "Release executable 校验通过: WebRTC.framework exact M150 source=$framework_source"
    fi
}

verify_app_runtime_layout() {
    local app_bundle="$1"
    local app_bin="$app_bundle/Contents/MacOS/SkyBridgeCompassApp"
    local frameworks_webrtc="$app_bundle/Contents/Frameworks/WebRTC.framework/WebRTC"

    if [[ ! -x "$app_bin" ]]; then
        log_error "主可执行文件不存在或不可执行: $app_bin"
        exit 1
    fi
    skybridge_assert_bundle_has_apple_pqc_compile_marker "$app_bundle" "release DMG app bundle" || exit 1

    if otool -L "$app_bin" 2>/dev/null | grep -q "@rpath/WebRTC.framework/WebRTC"; then
        if [[ ! -e "$frameworks_webrtc" ]]; then
            log_error "App 依赖 WebRTC.framework，但 Frameworks 内缺少: $frameworks_webrtc"
            exit 1
        fi
        if otool -l "$app_bin" 2>/dev/null | grep -q "@executable_path/../Frameworks"; then
            log_info "运行时校验通过: 主二进制包含 Frameworks rpath，且 WebRTC 位于标准 Frameworks 目录"
        else
            log_error "App 依赖 WebRTC.framework，但主二进制缺少 @executable_path/../Frameworks rpath"
            exit 1
        fi
    fi
}

verify_icns_has_full_size_reps() {
    local icns_path="$1"
    local label="$2"
    local tmp_dir=""
    local iconset_dir=""
    local required_rep=""

    if ! command -v iconutil >/dev/null 2>&1; then
        log_error "iconutil 不可用，无法校验 ${label} 图标表示"
        exit 1
    fi

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-dmg-icon.XXXXXX")"
    iconset_dir="$tmp_dir/${label}.iconset"
    if ! iconutil -c iconset "$icns_path" -o "$iconset_dir" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        log_error "${label} 不是有效 icns 文件：$icns_path"
        exit 1
    fi

    for required_rep in icon_512x512.png icon_512x512@2x.png; do
        if [[ ! -f "$iconset_dir/$required_rep" ]]; then
            rm -rf "$tmp_dir"
            log_error "${label} 缺少 full-size 图标表示：$required_rep"
            exit 1
        fi
    done

    rm -rf "$tmp_dir"
}

verify_file_matches_source_icon() {
    local app_resource="$1"
    local source_resource="$2"
    local label="$3"
    local app_hash=""
    local source_hash=""

    if [[ ! -f "$app_resource" ]]; then
        log_error "App Bundle 缺少图标资源：$label"
        exit 1
    fi
    if [[ ! -f "$source_resource" ]]; then
        log_error "源码缺少 canonical 图标资源：$source_resource"
        exit 1
    fi

    app_hash="$(shasum -a 256 "$app_resource" | awk '{print $1}')"
    source_hash="$(shasum -a 256 "$source_resource" | awk '{print $1}')"
    if [[ "$app_hash" != "$source_hash" ]]; then
        log_error "App Bundle 图标资源已过期或被回退：$label"
        log_error "app=${app_hash} source=${source_hash}"
        exit 1
    fi
}

verify_iconcomposer_source_matches_canonical_icon() {
    local source_resources_dir="$1"
    local canonical_png="$source_resources_dir/AppIcon.png"
    local iconcomposer_png="$source_resources_dir/AppIcon.icon/Assets/Image.png"

    verify_file_matches_source_icon "$iconcomposer_png" "$canonical_png" "AppIcon.icon/Assets/Image.png"
}

verify_packaged_app_does_not_override_system_icon() {
    local app_source="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift"
    local icon_loader_source="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/SVGEmbeddedImageView.swift"
    local icon_function=""
    local brand_loader=""

    [[ -f "$app_source" ]] || {
        log_error "缺少应用入口源码，无法校验运行态图标 ownership：$app_source"
        exit 1
    }
    [[ -f "$icon_loader_source" ]] || {
        log_error "缺少品牌图标源码，无法校验运行态图标 ownership：$icon_loader_source"
        exit 1
    }

    icon_function="$(python3 - "$app_source" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start_marker = "private static func applyAppIconIfAvailable() -> Bool"
end_marker = "func resolveDevelopmentIconURL() -> URL?"
start = source.find(start_marker)
end = source.find(end_marker, start)
if start == -1 or end == -1:
    raise SystemExit(2)
print(source[start:end])
PY
)" || {
        log_error "无法定位 applyAppIconIfAvailable packaged 图标路径"
        exit 1
    }

    if [[ "$icon_function" != *"if isRunningFromPackagedApp"* ]]; then
        log_error "packaged app 图标必须由 Info.plist + LaunchServices 接管，缺少 isRunningFromPackagedApp 早返回"
        exit 1
    fi
    if [[ "$icon_function" == *"NSApplication.shared.applicationIconImage ="* ]]; then
        log_error "packaged app 启动路径禁止手动覆盖 applicationIconImage；这会导致启动后图标回退"
        exit 1
    fi
    if grep -q "resolvePackagedIconURL" "$app_source"; then
        log_error "packaged app 禁止从 raw AppIcon PNG/ICNS 手动覆盖 Dock 图标；请使用 Info.plist 声明的 AppIcon.icns"
        exit 1
    fi

    brand_loader="$(python3 - "$icon_loader_source" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start_marker = "private enum BrandIconAssetLoader"
end_marker = "private extension View"
start = source.find(start_marker)
end = source.find(end_marker, start)
if start == -1 or end == -1:
    raise SystemExit(2)
print(source[start:end])
PY
)" || {
        log_error "无法定位 BrandIconAssetLoader"
        exit 1
    }

    if [[ "$brand_loader" != *"loadImageResource(named: preferredResourceName, withExtension: \"png\", bundle: .main)"* ]]; then
        log_error "packaged 品牌图标必须优先读取调用方指定的主包资源，侧边栏应使用 SidebarBrandIcon.png"
        exit 1
    fi
    if [[ "$brand_loader" != *"loadImageResource(named: \"BrandIcon\", withExtension: \"png\", bundle: .main)"* ]]; then
        log_error "packaged 品牌图标必须读取包内 canonical BrandIcon.png，避免侧边栏图标由 AppIcon.icns 小尺寸 representation 漂移"
        exit 1
    fi
    if [[ "$brand_loader" == *"packagedResourceIconURLs"* || "$brand_loader" == *"NSApplication.shared.applicationIconImage"* ]]; then
        log_error "packaged 品牌图标禁止读取旧资源列表或系统缓存图标；必须使用 BrandIcon.png"
        exit 1
    fi
}

verify_app_icon_contract() {
    local app_bundle="$1"
    local info_plist="$app_bundle/Contents/Info.plist"
    local resources_dir="$app_bundle/Contents/Resources"
    local source_resources_dir="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/Resources"
    local icon_file=""
    local icon_name=""

    [[ -f "$info_plist" ]] || {
        log_error "缺少主应用 Info.plist，无法校验图标 contract：$info_plist"
        exit 1
    }

    icon_file=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist" 2>/dev/null || true)
    icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$info_plist" 2>/dev/null || true)
    if [[ "$icon_file" != "AppIcon.icns" ]]; then
        log_error "CFBundleIconFile 必须指向预合成 AppIcon.icns，当前为：${icon_file:-missing}"
        exit 1
    fi
    if [[ -n "$icon_name" ]]; then
        log_error "CFBundleIconName 必须保持为空，避免 Icon Composer iconstack 二次套壳，当前为：${icon_name}"
        exit 1
    fi

    if [[ ! -f "$resources_dir/AppIcon.icns" || ! -f "$resources_dir/BrandIcon.png" || ! -f "$resources_dir/SidebarBrandIcon.png" ]]; then
        log_error "App Bundle 必须包含预合成 AppIcon.icns、BrandIcon.png 与 SidebarBrandIcon.png 图标产物"
        exit 1
    fi
    verify_iconcomposer_source_matches_canonical_icon "$source_resources_dir"
    verify_file_matches_source_icon "$resources_dir/AppIcon.icns" "$source_resources_dir/AppIcon.icns" "AppIcon.icns"
    verify_file_matches_source_icon "$resources_dir/BrandIcon.png" "$source_resources_dir/AppIcon.png" "BrandIcon.png"
    verify_file_matches_source_icon "$resources_dir/SidebarBrandIcon.png" "$source_resources_dir/SidebarBrandIcon.png" "SidebarBrandIcon.png"
    verify_icns_has_full_size_reps "$resources_dir/AppIcon.icns" "AppIcon.icns"
    verify_packaged_app_does_not_override_system_icon

    if [[ -e "$resources_dir/icon.json" || -e "$resources_dir/Image.png" || -e "$resources_dir/AppIcon.icon" || -e "$resources_dir/Assets.xcassets" || -e "$resources_dir/AppIcon.png" || -e "$resources_dir/AppIconDock.icns" || -e "$resources_dir/AppIconDock.png" || -e "$resources_dir/app_icon.png" || -e "$resources_dir/AppIconMaster.png" || -e "$resources_dir/AppIconMaster.svg" || -e "$resources_dir/app-icon.svg" || -e "$resources_dir/Icons" ]]; then
        log_error "App Bundle 包含 Icon Composer 输入或旧图标别名，图标来源不明确"
        exit 1
    fi

    log_info "App 图标 contract 校验通过：系统图标使用 canonical AppIcon.icns，运行态品牌 UI 使用 BrandIcon.png/SidebarBrandIcon.png"
}

verify_app_embedded_privacy_info_plist() {
    local app_bundle="$1"
    local app_info_plist="$app_bundle/Contents/Info.plist"
    local app_bin="$app_bundle/Contents/MacOS/SkyBridgeCompassApp"
    local embedded_info_plist

    embedded_info_plist="$(mktemp "${TMPDIR:-/tmp}/skybridge-embedded-info.XXXXXX")"
    python3 - "$app_bin" "$embedded_info_plist" "$app_info_plist" <<'PY'
import plistlib
import re
import subprocess
import sys
from pathlib import Path

app_bin = Path(sys.argv[1])
embedded_path = Path(sys.argv[2])
app_info_path = Path(sys.argv[3])

required_keys = [
    "NSBluetoothAlwaysUsageDescription",
    "NSLocalNetworkUsageDescription",
    "NSCameraUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSAudioCaptureUsageDescription",
    "NSLocationUsageDescription",
    "NSLocationWhenInUseUsageDescription",
    "NSUSBUsageDescription",
]

with app_info_path.open("rb") as fh:
    app_info = plistlib.load(fh)


def validate_bundle_privacy_keys():
    for key in required_keys:
        app_value = app_info.get(key)
        if not isinstance(app_value, str) or not app_value.strip():
            print(f"bundle Info.plist missing required privacy usage description: {key}", file=sys.stderr)
            raise SystemExit(1)


proc = subprocess.run(
    ["otool", "-X", "-s", "__TEXT", "__info_plist", str(app_bin)],
    check=False,
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    validate_bundle_privacy_keys()
    raise SystemExit(0)

section_bytes = bytearray()
for line in proc.stdout.splitlines():
    parts = line.split()
    if len(parts) < 2:
        continue
    for word in parts[1:]:
        if not re.fullmatch(r"[0-9a-fA-F]{2,8}", word) or len(word) % 2 != 0:
            continue
        raw = bytes.fromhex(word)
        if len(raw) == 4:
            # otool prints full 32-bit words in target byte order.
            section_bytes.extend(raw[::-1])
        else:
            # The final partial word is printed as byte-sized chunks on newer
            # Xcode toolchains; keep those bytes in display order.
            section_bytes.extend(raw)

payload = bytes(section_bytes).rstrip(b"\x00")
if not payload:
    validate_bundle_privacy_keys()
    raise SystemExit(0)

start = payload.find(b"<?xml")
if start == -1:
    start = payload.find(b"<plist")
if start > 0:
    payload = payload[start:]

embedded = plistlib.loads(payload)

for key in required_keys:
    app_value = app_info.get(key)
    embedded_value = embedded.get(key)
    if not isinstance(embedded_value, str) or not embedded_value.strip():
        print(f"embedded Info.plist missing required privacy usage description: {key}", file=sys.stderr)
        raise SystemExit(1)
    if app_value != embedded_value:
        print(
            f"embedded Info.plist privacy usage description mismatch for {key}: "
            f"bundle={app_value!r} embedded={embedded_value!r}",
            file=sys.stderr,
        )
        raise SystemExit(1)

embedded_path.write_bytes(payload)
PY
    rm -f "$embedded_info_plist"
    log_info "隐私用途说明校验通过: App Bundle Info.plist 覆盖必需用途说明"
}

verify_app_release_features() {
    local app_bundle="$1"
    local info_plist="$app_bundle/Contents/Info.plist"
    local widget_appex="$app_bundle/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex"
    local apple_sign_in_enabled=""
    local apple_sign_in_mode=""

    [[ -f "$info_plist" ]] || {
        log_error "缺少主应用 Info.plist: $info_plist"
        exit 1
    }

    if [[ ! -d "$widget_appex" ]]; then
        log_error "发布产物缺少 Widget Extension：$widget_appex"
        exit 1
    fi

    if [[ ! -f "$widget_appex/Contents/embedded.provisionprofile" ]]; then
        log_error "Widget Extension 缺少 embedded.provisionprofile：$widget_appex/Contents/embedded.provisionprofile"
        exit 1
    fi

    apple_sign_in_enabled=$(/usr/libexec/PlistBuddy -c 'Print :SKYBRIDGE_ENABLE_APPLE_SIGN_IN' "$info_plist" 2>/dev/null || true)
    apple_sign_in_mode=$(/usr/libexec/PlistBuddy -c 'Print :SKYBRIDGE_APPLE_SIGN_IN_MODE' "$info_plist" 2>/dev/null || true)
    if [[ "$apple_sign_in_enabled" == "true" && "$apple_sign_in_mode" != "web_session" ]]; then
        log_error "Developer ID DMG 发布要求 Apple 登录采用 web_session，当前模式为：${apple_sign_in_mode:-missing}"
        exit 1
    fi

    verify_app_icon_contract "$app_bundle"
}

ensure_release_developer_id_profiles() {
    local app_bundle="$1"
    local identity="$2"
    local app_info_plist="$app_bundle/Contents/Info.plist"
    local widget_info_plist="$app_bundle/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex/Contents/Info.plist"
    local app_bundle_identifier=""
    local widget_bundle_identifier=""
    local -a ensure_args=()

    if [[ "$ENSURE_DEVELOPER_ID_PROFILES" != "1" ]]; then
        log_info "按 SKYBRIDGE_ENSURE_DEVELOPER_ID_PROFILES=0 跳过 Developer ID provisioning profile 自检"
        return 0
    fi

    [[ -f "$app_info_plist" ]] || {
        log_error "无法读取 App Info.plist 以自检 provisioning profile: $app_info_plist"
        exit 1
    }
    [[ -f "$widget_info_plist" ]] || {
        log_error "无法读取 Widget Info.plist 以自检 provisioning profile: $widget_info_plist"
        exit 1
    }

    app_bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_info_plist" 2>/dev/null || true)
    widget_bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$widget_info_plist" 2>/dev/null || true)
    [[ -n "$app_bundle_identifier" ]] || {
        log_error "App Info.plist 缺少 CFBundleIdentifier"
        exit 1
    }
    [[ -n "$widget_bundle_identifier" ]] || {
        log_error "Widget Info.plist 缺少 CFBundleIdentifier"
        exit 1
    }

    ensure_args=(
        --create
        --app-bundle-id "$app_bundle_identifier"
        --widget-bundle-id "$widget_bundle_identifier"
    )
    if [[ -n "$identity" ]]; then
        ensure_args+=(--identity "$identity")
    fi
    if [[ "$ASSOCIATE_DEVELOPER_ID_APP_GROUPS" == "1" ]]; then
        ensure_args+=(--associate-app-groups)
    fi

    log_info "自检 Developer ID provisioning profiles（App=${app_bundle_identifier}, Widget=${widget_bundle_identifier}）"
    "$PROJECT_ROOT/Scripts/ensure_developer_id_profiles.sh" "${ensure_args[@]}"
}

scrub_bundle_custom_icon() {
    local bundle_path="$1"
    local bundle_icon_path
    bundle_icon_path="$bundle_path/Icon"$'\r'

    if [[ -e "$bundle_icon_path" ]]; then
        rm -f "$bundle_icon_path" || true
    fi

    xattr -d com.apple.FinderInfo "$bundle_path" >/dev/null 2>&1 || true
    xattr -d com.apple.FinderInfo "$bundle_icon_path" >/dev/null 2>&1 || true
}

extract_helper_version() {
    local bin_path="$1"
    if [[ -x "$bin_path" ]]; then
        strings "$bin_path" 2>/dev/null | grep -m1 'SKYBRIDGE_HELPER_VERSION=' | cut -d= -f2 || true
    fi
}

extract_source_helper_version() {
    local source_path="$PROJECT_ROOT/Sources/PowerMetricsHelper/main.swift"
    if [[ -f "$source_path" ]]; then
        awk -F '"' '/private static let helperVersion =/ { print $2; exit }' "$source_path" 2>/dev/null || true
    fi
}

select_identity() {
    # 修复：keychain 中可能同时存在多个 "Developer ID Application" 证书（例如开发者同时是
    # 个人 "Ziang Li" 团队和某组织/企业团队的成员）。旧逻辑用 `awk ... exit` 盲取第一个，
    # 可能签上错误团队的证书，导致 Gatekeeper 打开 DMG 时显示错误的发布者（如 "WeChat"）。
    # 现在：
    #   1) 若设置了 SKYBRIDGE_PREFERRED_SIGNING_IDENTITY（子串，如 "Ziang Li" 或完整团队 ID），
    #      在候选中做子串匹配；匹配唯一则用之，匹配为空/多义则报错列出候选。
    #   2) 未设偏好且只有一个 Developer ID Application → 直接使用。
    #   3) 未设偏好且存在多个 → 拒绝盲选，列出全部并失败（fail-loud）。
    #   4) 没有 Developer ID Application → 回退 Apple Development（保持旧行为）。
    local identities preferred apple_dev id line
    preferred="${SKYBRIDGE_PREFERRED_SIGNING_IDENTITY:-}"
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    local -a dev_ids=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && dev_ids+=("$line")
    done < <(printf '%s\n' "$identities" | awk -F '"' '/Developer ID Application/ {print $2}')

    if [[ -n "$preferred" && ${#dev_ids[@]} -gt 0 ]]; then
        local -a matched=()
        for id in "${dev_ids[@]}"; do
            [[ "$id" == *"$preferred"* ]] && matched+=("$id")
        done
        if [[ ${#matched[@]} -eq 1 ]]; then
            echo "${matched[0]}"
            return 0
        elif [[ ${#matched[@]} -eq 0 ]]; then
            log_error "未找到匹配 SKYBRIDGE_PREFERRED_SIGNING_IDENTITY='${preferred}' 的 Developer ID Application 证书。可用候选：" >&2
            printf '   - %s\n' "${dev_ids[@]}" >&2
            return 1
        else
            log_error "SKYBRIDGE_PREFERRED_SIGNING_IDENTITY='${preferred}' 匹配到多个 Developer ID Application 证书，请写得更精确（可用完整团队 ID）：" >&2
            printf '   - %s\n' "${matched[@]}" >&2
            return 1
        fi
    fi

    if [[ ${#dev_ids[@]} -gt 1 ]]; then
        log_error "检测到多个 Developer ID Application 证书，拒绝盲选（避免签到错误团队，导致 Gatekeeper 显示错误发布者）。" >&2
        log_error "请用 --identity \"<完整身份>\" 或设置 SKYBRIDGE_PREFERRED_SIGNING_IDENTITY=\"<子串，如 Ziang Li>\" 指定。候选：" >&2
        printf '   - %s\n' "${dev_ids[@]}" >&2
        return 1
    fi
    if [[ ${#dev_ids[@]} -eq 1 ]]; then
        echo "${dev_ids[0]}"
        return 0
    fi

    apple_dev="$(printf '%s\n' "$identities" | awk -F '"' '/Apple Development/ {print $2; exit}')"
    if [[ -n "$apple_dev" ]]; then
        echo "$apple_dev"
        return 0
    fi
    echo ""
    return 0
}

sign_dmg_artifact() {
    local dmg_path="$1"
    local identity="$2"

    if [[ -z "$identity" || "$identity" == "-" ]]; then
        if [[ "$NOTARIZE_DMG" == "1" || "$REQUIRE_NOTARIZATION" == "1" ]]; then
            log_error "DMG notarization requires a Developer ID Application signing identity"
            exit 1
        fi

        log_info "未检测到 DMG 签名身份，跳过 DMG 本体签名"
        return 0
    fi

    if [[ "$identity" != Developer\ ID\ Application:* ]]; then
        if [[ "$NOTARIZE_DMG" == "1" || "$REQUIRE_NOTARIZATION" == "1" ]]; then
            log_error "DMG notarization requires Developer ID Application identity; got: $identity"
            exit 1
        fi

        log_info "签名身份不是 Developer ID Application，跳过 DMG 本体签名: $identity"
        return 0
    fi

    log_step "步骤 5: 签名 DMG"
    codesign --force --sign "$identity" --timestamp "$dmg_path"
    codesign --verify --verbose=2 "$dmg_path" >/dev/null
    log_success "DMG 本体签名完成"
}

assert_existing_app_bundle_is_fresh() {
    local app_bundle_path="$1"
    if ! skybridge_assert_existing_release_app_bundle_fresh "$PROJECT_ROOT" "$app_bundle_path" "SkyBridgeCompassApp"; then
        exit 1
    fi
}

cleanup() {
    log_info "清理临时文件..."
    if [[ -n "${FINAL_SOURCE_MOUNT_DIR:-}" ]]; then
        diskutil eject "$FINAL_SOURCE_MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    if [[ -n "${MOUNT_DIR:-}" ]]; then
        diskutil eject "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    diskutil eject "/Volumes/$VOLUME_NAME" >/dev/null 2>&1 || true
    rm -rf "$STAGE_DIR" "$TEMP_DMG"
}

trap cleanup EXIT

# 避免旧的 dmg_stage/Applications -> /Applications 符号链接污染新的 xcodebuild 扫描范围。
# 否则 SwiftPM/Xcode 可能穿透到系统应用内的历史工程引用，产生无关 warning 并显著拖慢发布构建。
rm -rf "$STAGE_DIR" "$TEMP_DMG"

log_info "检测 Apple PQC SDK 可用性（release DMG 必须启用 HAS_APPLE_PQC_SDK）..."
skybridge_configure_apple_pqc_sdk_for_package_context "release_dmg" "Release DMG" || exit 1
log_info "Host macOS 版本: ${SKYBRIDGE_PQC_HOST_OS_VER:-unknown}"
log_info "Xcode macOS SDK 版本: ${SKYBRIDGE_PQC_SDK_VER:-unknown}"
log_info_path "Xcode macOS SDK 路径" "${SKYBRIDGE_PQC_SDK_PATH:-unknown}"
log_info "Apple PQC SDK 探测通过（mode=${SKYBRIDGE_PQC_PROBE_MODE}, target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown}），启用 Apple PQC 编译条件"
if [[ -n "$SKYBRIDGE_PQC_HOST_OS_VER" && -n "$SKYBRIDGE_PQC_SDK_VER" && "$SKYBRIDGE_PQC_HOST_OS_VER" != "$SKYBRIDGE_PQC_SDK_VER" ]]; then
    log_info "提示：Host 与 SDK 版本不同是常见情况（例如 Host 26.3 + SDK 26.2）。编译能力按 SDK 判定。"
fi

if [[ "$SKIP_BUILD" == false ]]; then
    log_step "步骤 1: 构建 Release 版本"

    cd "$PROJECT_ROOT"
    log_info_path "Xcode DerivedData 路径" "$XCODE_DERIVED_DATA_PATH"

    if [[ ! -d "$XCODE_PROJECT" ]]; then
        log_error "缺少 Xcode 工程：$XCODE_PROJECT"
        exit 1
    fi

    if [[ "$MAIN_BUILD_SYSTEM" == "swiftpm" ]]; then
        log_info "使用 SwiftPM Release executable 构建主应用（product=${XCODE_PACKAGE_SCHEME}, arch=${BUILD_ARCH}）..."
        SWIFTPM_BUILD_ARGS=(
            -c release
            --arch "$BUILD_ARCH"
        )
        if [[ -n "${SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH:-}" ]]; then
            SWIFTPM_BUILD_ARGS+=(--scratch-path "$SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH")
        fi
        swift build \
            "${SWIFTPM_BUILD_ARGS[@]}" \
            --product "$XCODE_PACKAGE_SCHEME" \
            --disable-automatic-resolution

        verify_release_executable_runtime_inputs "$SWIFTPM_PACKAGE_EXECUTABLE"
        skybridge_assert_release_executable_not_instrumented "$SWIFTPM_PACKAGE_EXECUTABLE" "SwiftPM Release 主可执行文件"
    else
        if [[ ! -d "$XCODE_PACKAGE_WORKSPACE" ]]; then
            log_error "缺少 SwiftPM Xcode workspace：$XCODE_PACKAGE_WORKSPACE"
            exit 1
        fi

        log_info "使用 Xcode workspace Release executable 构建主应用（scheme=${XCODE_PACKAGE_SCHEME}, arch=${BUILD_ARCH}）..."
        skybridge_run_xcodebuild -workspace "$XCODE_PACKAGE_WORKSPACE" \
            -scheme "$XCODE_PACKAGE_SCHEME" \
            -configuration Release \
            -destination "$BUILD_DESTINATION" \
            -derivedDataPath "$XCODE_DERIVED_DATA_PATH" \
            -skipPackageUpdates \
            -disableAutomaticPackageResolution \
            CODE_SIGNING_ALLOWED=NO \
            COMPILER_INDEX_STORE_ENABLE=NO \
            ENABLE_CODE_COVERAGE=NO \
            CLANG_ENABLE_CODE_COVERAGE=NO \
            GCC_GENERATE_TEST_COVERAGE_FILES=NO \
            GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO \
            ARCHS="$BUILD_ARCH" \
            ONLY_ACTIVE_ARCH=YES \
            build

        verify_release_executable_runtime_inputs "$XCODE_PACKAGE_EXECUTABLE"
        skybridge_assert_release_executable_not_instrumented "$XCODE_PACKAGE_EXECUTABLE" "Xcode Release 主可执行文件"
    fi

    log_info "构建原生 Xcode app target 以产出 Widget Extension（scheme=${XCODE_MAC_SCHEME}, arch=${BUILD_ARCH}）..."
    skybridge_run_xcodebuild -project "$XCODE_PROJECT" \
        -scheme "$XCODE_MAC_SCHEME" \
        -configuration Release \
        -destination "$BUILD_DESTINATION" \
        -derivedDataPath "$XCODE_DERIVED_DATA_PATH" \
        -skipPackageUpdates \
        -disableAutomaticPackageResolution \
        CODE_SIGNING_ALLOWED=NO \
        COMPILER_INDEX_STORE_ENABLE=NO \
        ENABLE_CODE_COVERAGE=NO \
        CLANG_ENABLE_CODE_COVERAGE=NO \
        GCC_GENERATE_TEST_COVERAGE_FILES=NO \
        GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO \
        ARCHS="$BUILD_ARCH" \
        ONLY_ACTIVE_ARCH=YES \
        build

    if [[ "$MAIN_BUILD_SYSTEM" == "xcode" && -x "$XCODE_APP_BUNDLE/Contents/MacOS/SkyBridgeCompassApp" ]]; then
        verify_app_runtime_layout "$XCODE_APP_BUNDLE"
    elif [[ "$MAIN_BUILD_SYSTEM" == "swiftpm" ]]; then
        log_info "SwiftPM 主构建模式：Xcode app target 仅提供 Widget/资源，中间 app runtime marker 校验推迟到 package_app.sh 产物"
    fi

    log_success "Release 构建完成"
    JUST_BUILT_RELEASE=true
else
    log_info "跳过构建步骤"
fi

log_step "步骤 2: 准备 App Bundle"
mkdir -p "$DIST_DIR"

if [[ "$USE_EXISTING_APP" == true ]]; then
    if [[ -d "$APP_BUNDLE" && -f "$APP_BUNDLE/Contents/Info.plist" && -d "$APP_BUNDLE/Contents/MacOS" ]]; then
        assert_existing_app_bundle_is_fresh "$APP_BUNDLE"
        verify_app_bundle_build_source "$APP_BUNDLE"
        log_info "复用已存在 App Bundle: $APP_BUNDLE"
    else
        log_error "指定了 --use-existing-app，但未找到可用 App Bundle: $APP_BUNDLE"
        log_error "请先运行 Scripts/package_app.sh 或不带 --use-existing-app 重新执行。"
        exit 1
    fi
else
    PACKAGE_APP_ALLOW_STALE_BUILD=0
    if [[ "$JUST_BUILT_RELEASE" == true ]]; then
        PACKAGE_APP_ALLOW_STALE_BUILD=1
    fi

    ensure_release_developer_id_profiles "$XCODE_APP_BUNDLE" "$SIGNING_IDENTITY"

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        log_info "使用指定签名身份执行 package_app.sh: $SIGNING_IDENTITY"
        SKYBRIDGE_XCODE_APP_BUNDLE="$XCODE_APP_BUNDLE" \
            SKYBRIDGE_PACKAGE_MAIN_BUILD_SYSTEM="$MAIN_BUILD_SYSTEM" \
            SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH="${SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH:-}" \
            SKYBRIDGE_PACKAGE_OUTPUT_DIR="$DIST_DIR" \
            SKIP_BUILD=1 \
            ALLOW_STALE_BUILD="$PACKAGE_APP_ALLOW_STALE_BUILD" \
            SKYBRIDGE_PACKAGE_CONTEXT=release_dmg \
            IDENTITY="$SIGNING_IDENTITY" \
            "$PROJECT_ROOT/Scripts/package_app.sh"
    else
        SKYBRIDGE_XCODE_APP_BUNDLE="$XCODE_APP_BUNDLE" \
            SKYBRIDGE_PACKAGE_MAIN_BUILD_SYSTEM="$MAIN_BUILD_SYSTEM" \
            SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH="${SKYBRIDGE_SWIFTPM_RELEASE_SCRATCH_PATH:-}" \
            SKYBRIDGE_PACKAGE_OUTPUT_DIR="$DIST_DIR" \
            SKIP_BUILD=1 \
            ALLOW_STALE_BUILD="$PACKAGE_APP_ALLOW_STALE_BUILD" \
            SKYBRIDGE_PACKAGE_CONTEXT=release_dmg \
            "$PROJECT_ROOT/Scripts/package_app.sh"
    fi
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
    log_error "App Bundle 不存在：$APP_BUNDLE"
    exit 1
fi

verify_app_bundle_build_source "$APP_BUNDLE"

HELPER_PLIST="$APP_BUNDLE/Contents/Library/LaunchDaemons/com.skybridge.PowerMetricsHelper.plist"
HELPER_BIN="$APP_BUNDLE/Contents/Library/LaunchDaemons/com.skybridge.PowerMetricsHelper/com.skybridge.PowerMetricsHelper"
if [[ -f "$HELPER_PLIST" && -x "$HELPER_BIN" ]]; then
    log_success "检测到 PowerMetricsHelper 与 launchd plist"
    APP_HELPER_VERSION="$(extract_helper_version "$HELPER_BIN")"
    if [[ -z "${APP_HELPER_VERSION:-}" ]]; then
        log_error "App 内 PowerMetricsHelper 版本 marker 缺失，禁止发布 version unknown 的 DMG"
        exit 1
    fi
    SOURCE_HELPER_VERSION="$(extract_source_helper_version)"
    if [[ -n "${SOURCE_HELPER_VERSION:-}" && "${APP_HELPER_VERSION}" != "${SOURCE_HELPER_VERSION}" ]]; then
        log_error "App 内 PowerMetricsHelper 版本与源码不一致：app=${APP_HELPER_VERSION}, source=${SOURCE_HELPER_VERSION}"
        exit 1
    fi
    log_info "App 内 Helper 版本: ${APP_HELPER_VERSION}"
else
    log_error "未检测到完整 PowerMetricsHelper（高级监控功能不可用），禁止发布"
    exit 1
fi

log_success "App Bundle 已就绪: $APP_BUNDLE"
verify_app_runtime_layout "$APP_BUNDLE"
verify_app_embedded_privacy_info_plist "$APP_BUNDLE"
verify_app_release_features "$APP_BUNDLE"

if [[ "$SKIP_SIGN" == false ]]; then
    # Strip debug symbol stabs (OSO/SO) from our first-party Mach-O binaries before
    # the hardened-runtime re-sign, so the shipping release carries no build-time
    # object map or source-file names (e.g. RemoteControlSmokeStatusWriter.swift) in
    # its symbol table. The release readiness binary-surface gate scans `nm -a` and
    # rejects such markers. Debug info stays in the .o files for optional dSYM
    # extraction. Only first-party executables are stripped; vendor frameworks/dylibs
    # are left untouched. sign_app.sh re-signs everything afterwards.
    log_step "步骤 2.5: 去除发布二进制调试符号表 (strip -S)"
    strip -S "$APP_BUNDLE/Contents/MacOS/"* 2>/dev/null || true
    while IFS= read -r -d '' stripped_macho; do
        strip -S "$stripped_macho" 2>/dev/null || true
    done < <(
        find "$APP_BUNDLE/Contents/PlugIns" "$APP_BUNDLE/Contents/Library/LaunchDaemons" \
            -type f -perm -111 -print0 2>/dev/null
    )
    log_success "发布二进制调试符号表已去除"

    if [[ -z "$SIGNING_IDENTITY" ]]; then
        if ! SIGNING_IDENTITY="$(select_identity)"; then
            log_error "无法确定唯一的签名身份，已停止发布（见上方候选列表）。"
            exit 1
        fi
    fi

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        SIGN_APP_REQUIRE_NOTARIZATION="0"
        if [[ "$NOTARIZE_APP" == "1" && "$REQUIRE_NOTARIZATION" == "1" ]]; then
            SIGN_APP_REQUIRE_NOTARIZATION="1"
        fi
        log_step "步骤 3: 规范化重签名"
        APP_PATH="$APP_BUNDLE" \
        IDENTITY="$SIGNING_IDENTITY" \
        NOTARIZE_APP="$NOTARIZE_APP" \
        REQUIRE_NOTARIZATION="$SIGN_APP_REQUIRE_NOTARIZATION" \
        NOTARYTOOL_KEYCHAIN_PROFILE="$NOTARYTOOL_KEYCHAIN_PROFILE" \
        "$PROJECT_ROOT/Scripts/sign_app.sh"
    else
        log_info "未检测到可用签名证书，保持当前签名状态（可能为 ad-hoc）"
    fi
else
    log_info "按 --skip-sign 要求，跳过签名步骤"
fi

verify_app_runtime_layout "$APP_BUNDLE"
verify_app_embedded_privacy_info_plist "$APP_BUNDLE"
verify_app_release_features "$APP_BUNDLE"

log_step "步骤 4: 创建 DMG"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "$VERSION")"
DMG_PATH="$DIST_DIR/${DMG_NAME}-${APP_VERSION}.dmg"

rm -f "$DMG_PATH"
rm -rf "$TEMP_DMG"
rm -rf "$STAGE_DIR"

log_info "准备 DMG staging 目录..."
mkdir -p "$STAGE_DIR"
ditto "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
scrub_bundle_custom_icon "$STAGE_DIR/$APP_NAME.app"
ln -sf /Applications "$STAGE_DIR/Applications"
mkdir -p "$STAGE_DIR/.background"

if [[ -f "$BG_SRC_PNG" ]]; then
    log_info "生成 DMG 背景图（基于 AppIcon.png）..."
    cp "$BG_SRC_PNG" "$STAGE_DIR/.background/$BG_NAME"
    sips -Z 1600 "$STAGE_DIR/.background/$BG_NAME" >/dev/null 2>&1 || true
    chflags hidden "$STAGE_DIR/.background" >/dev/null 2>&1 || true
else
    log_info "未找到背景源图：$BG_SRC_PNG（将使用默认白底）"
fi

log_info "创建临时 sparsebundle..."
diskutil image create from \
    --format UDSB \
    --volumeName "$VOLUME_NAME" \
    "$STAGE_DIR" \
    "$TEMP_DMG"

log_info "挂载 DMG..."
if [[ -d "/Volumes/$VOLUME_NAME" ]]; then
    diskutil eject "/Volumes/$VOLUME_NAME" >/dev/null 2>&1 || true
fi
ATTACH_INFO=$(diskutil image attach "$TEMP_DMG")
MOUNT_DIR=$(echo "$ATTACH_INFO" | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/')
DMG_DISPLAY_NAME=$(basename "$MOUNT_DIR")

if [[ -z "$MOUNT_DIR" ]]; then
    log_error "无法挂载 DMG"
    exit 1
fi

log_info "DMG 已挂载到: $MOUNT_DIR"
log_info "配置 DMG 窗口..."

osascript <<OSA || true
tell application "Finder"
    set targetDisk to missing value
    repeat with attemptIndex from 1 to 20
        try
            set targetDisk to disk "$DMG_DISPLAY_NAME"
            exit repeat
        on error
            delay 0.25
        end try
    end repeat

    if targetDisk is not missing value then
    tell targetDisk
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {140, 120, 940, 620}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set text size of theViewOptions to 12

        set position of item "$APP_NAME.app" of container window to {240, 300}
        set position of item "Applications" of container window to {680, 300}

        try
            set background picture of theViewOptions to file ".background:$BG_NAME"
        end try

        update without registering applications
        delay 2
        close
    end tell
    end if
end tell
OSA

scrub_bundle_custom_icon "$MOUNT_DIR/$APP_NAME.app"

sync
diskutil eject "$MOUNT_DIR"

log_info "压缩 DMG..."
if [[ ! -e "$TEMP_DMG" ]]; then
    log_error "找不到临时 DMG: $TEMP_DMG"
    ls -lah "$DIST_DIR" || true
    exit 1
fi

rm -f "$DMG_PATH"
READONLY_ATTACH_INFO=$(diskutil image attach --readOnly --nobrowse "$TEMP_DMG")
FINAL_SOURCE_MOUNT_DIR=$(echo "$READONLY_ATTACH_INFO" | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/')

if [[ -z "$FINAL_SOURCE_MOUNT_DIR" ]]; then
    log_error "无法重新挂载临时 DMG 以生成最终压缩镜像"
    echo "$READONLY_ATTACH_INFO" >&2
    exit 1
fi

diskutil image create from \
    --format UDZO \
    --volumeName "$VOLUME_NAME" \
    "$FINAL_SOURCE_MOUNT_DIR" \
    "$DMG_PATH"

diskutil eject "$FINAL_SOURCE_MOUNT_DIR"
FINAL_SOURCE_MOUNT_DIR=""

if [[ ! -f "$DMG_PATH" ]]; then
    log_error "压缩 DMG 后未找到目标文件: $DMG_PATH"
    ls -lah "$DIST_DIR" || true
    exit 1
fi

rm -rf "$TEMP_DMG"

log_success "DMG 创建完成: $DMG_PATH"

if [[ -z "$SIGNING_IDENTITY" ]]; then
    if ! SIGNING_IDENTITY="$(select_identity)"; then
        log_error "无法确定唯一的 DMG 签名身份，已停止发布（见上方候选列表）。"
        exit 1
    fi
fi
sign_dmg_artifact "$DMG_PATH" "$SIGNING_IDENTITY"

if [[ "$NOTARIZE_DMG" == "1" ]]; then
    log_step "步骤 6: 提交 DMG 公证"
    skybridge_notarytool_submit_and_wait "$DMG_PATH"
    skybridge_staple_artifact "$DMG_PATH"
    log_success "DMG notarization 与 stapling 完成"
fi

DESKTOP_DMG_PATH="$HOME/Desktop/${DMG_NAME}-${APP_VERSION}.dmg"
cp -f "$DMG_PATH" "$DESKTOP_DMG_PATH"
log_success "桌面 DMG 已覆盖更新: $DESKTOP_DMG_PATH"

log_step "构建完成"

echo ""
echo "📦 App Bundle: $APP_BUNDLE"
echo "💿 DMG 文件:   $DMG_PATH"
echo ""
echo "📊 DMG 大小: $(du -h "$DMG_PATH" | cut -f1)"

echo ""
echo "🔐 签名摘要:"
codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "(Authority|Identifier|TeamIdentifier|Signature)" || true
codesign -dvv "$DMG_PATH" 2>&1 | grep -E "(Authority|Identifier|TeamIdentifier|Signature)" || true

echo ""
echo "🛡️ Gatekeeper 摘要:"
APP_GATEKEEPER_OUTPUT="$(assess_and_report_gatekeeper "$APP_BUNDLE" "execute" "App Bundle")"
DMG_GATEKEEPER_OUTPUT="$(assess_and_report_gatekeeper "$DMG_PATH" "open" "DMG")"

if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
    if [[ "$NOTARIZE_APP" == "1" ]] && \
       ! skybridge_gatekeeper_is_notarized "$APP_GATEKEEPER_OUTPUT" && \
       ! artifact_has_stapled_ticket "$APP_BUNDLE"; then
        log_error "REQUIRE_NOTARIZATION=1，但 App Bundle 尚未显示为 notarized"
        exit 1
    fi
    if [[ "$NOTARIZE_DMG" == "1" ]] && \
       ! skybridge_gatekeeper_is_notarized "$DMG_GATEKEEPER_OUTPUT" && \
       ! artifact_has_stapled_ticket "$DMG_PATH"; then
        log_error "REQUIRE_NOTARIZATION=1，但 DMG 尚未显示为 notarized"
        exit 1
    fi
    if [[ "$NOTARIZE_APP" != "1" && "$NOTARIZE_DMG" != "1" ]]; then
        log_error "REQUIRE_NOTARIZATION=1，但未请求 --notarize-app 或 --notarize-dmg"
        exit 1
    fi
fi

echo ""
log_success "所有步骤完成！"

echo ""
echo "🧩 Helper 版本摘要:"
APP_HELPER_VERSION="$(extract_helper_version "$HELPER_BIN")"
if [[ -n "${APP_HELPER_VERSION:-}" ]]; then
    echo "  - App Bundle Helper: ${APP_HELPER_VERSION}"
else
    echo "  - App Bundle Helper: unknown"
fi

INSTALLED_HELPER_BIN="/Library/PrivilegedHelperTools/com.skybridge.PowerMetricsHelper"
INSTALLED_HELPER_VERSION="$(extract_helper_version "$INSTALLED_HELPER_BIN")"
if [[ -n "$INSTALLED_HELPER_VERSION" ]]; then
    echo "  - Installed Helper (/Library): ${INSTALLED_HELPER_VERSION}"
fi

RUNNING_INFO="$(launchctl print system/com.skybridge.PowerMetricsHelper 2>/dev/null || true)"
RUNNING_PATH="$(echo "$RUNNING_INFO" | awk -F'= ' '/path =/{print $2; exit}')"
RUNNING_PID="$(echo "$RUNNING_INFO" | awk -F'= ' '/pid =/{print $2; exit}')"
if [[ -n "$RUNNING_PATH" ]]; then
    RUNNING_VERSION="$(extract_helper_version "$RUNNING_PATH")"
    echo "  - Running Helper: pid=${RUNNING_PID:-unknown} path=$RUNNING_PATH version=${RUNNING_VERSION:-unknown}"
fi
