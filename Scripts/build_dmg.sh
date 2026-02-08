#!/usr/bin/env bash
#
# SkyBridge Compass DMG Builder
#
# 功能：
# 1. 构建 Release 版本应用（Xcode + SwiftPM）
# 2. 复用 package_app.sh 生成兼容 SMAppService 的 .app（含 PowerMetricsHelper）
# 3. （可选）重新签名
# 4. 创建 DMG 磁盘映像（带背景与 Applications 快捷方式）
#
# 使用方法：
#   ./Scripts/build_dmg.sh [--skip-build] [--skip-sign] [--identity "Developer ID"] [--use-existing-app]
#

set -euo pipefail

APP_NAME="SkyBridge Compass Pro"
DMG_NAME="SkyBridgeCompassPro"
VOLUME_NAME="SkyBridge Compass Pro"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INFO_PLIST_PATH="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST_PATH" 2>/dev/null || echo "0.0.0")"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/${DMG_NAME}-${VERSION}.dmg"
TEMP_DMG="$DIST_DIR/temp_${DMG_NAME}.dmg"
STAGE_DIR="$DIST_DIR/dmg_stage"
BG_SRC_PNG="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/Resources/AppIcon.png"
BG_NAME="background.png"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

SKIP_BUILD=false
SKIP_SIGN=false
USE_EXISTING_APP=false

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
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --skip-build         跳过构建步骤"
            echo "  --skip-sign          跳过签名步骤（将保留 package_app.sh 产物签名）"
            echo "  --use-existing-app   复用 dist/ 下已存在的 .app"
            echo "  --identity ID        指定签名身份（Developer ID / Apple Development）"
            echo "  --help, -h           显示帮助信息"
            exit 0
            ;;
        *)
            echo "未知选项: $1" >&2
            exit 1
            ;;
    esac
done

log_info() {
    echo "ℹ️  $1"
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

select_identity() {
    local dev_id
    local apple_dev
    dev_id=$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ {print $2; exit}')
    apple_dev=$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development/ {print $2; exit}')

    if [[ -n "$dev_id" ]]; then
        echo "$dev_id"
    elif [[ -n "$apple_dev" ]]; then
        echo "$apple_dev"
    else
        echo ""
    fi
}

cleanup() {
    log_info "清理临时文件..."
    hdiutil detach "/Volumes/$VOLUME_NAME" >/dev/null 2>&1 || true
}

trap cleanup EXIT

if [[ "$SKIP_BUILD" == false ]]; then
    log_step "步骤 1: 构建 Release 版本"

    cd "$PROJECT_ROOT"

    log_info "检测 Apple PQC SDK 可用性（用于 HAS_APPLE_PQC_SDK）..."
    SDK_VER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "")"
    SDK_MAJOR="$(echo "$SDK_VER" | awk -F. '{print $1}')"
    if [[ -n "$SDK_MAJOR" && "$SDK_MAJOR" -ge 26 ]]; then
        export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
        log_info "检测到 macOS SDK ${SDK_VER}（>=26），启用 Apple PQC 编译条件"
    else
        unset SKYBRIDGE_ENABLE_APPLE_PQC_SDK
        log_info "未检测到 macOS SDK 26+（当前: ${SDK_VER:-unknown}），禁用 Apple PQC 编译条件"
    fi

    log_info "使用 Xcode Release 构建..."
    xcodebuild -workspace .swiftpm/xcode/package.xcworkspace \
        -scheme SkyBridgeCompassApp \
        -configuration Release \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath .build/xcode \
        build

    log_success "Release 构建完成"
else
    log_info "跳过构建步骤"
fi

log_step "步骤 2: 准备 App Bundle"
mkdir -p "$DIST_DIR"

if [[ "$USE_EXISTING_APP" == true ]]; then
    if [[ -d "$APP_BUNDLE" && -f "$APP_BUNDLE/Contents/Info.plist" && -d "$APP_BUNDLE/Contents/MacOS" ]]; then
        log_info "复用已存在 App Bundle: $APP_BUNDLE"
    else
        log_error "指定了 --use-existing-app，但未找到可用 App Bundle: $APP_BUNDLE"
        log_error "请先运行 Scripts/package_app.sh 或不带 --use-existing-app 重新执行。"
        exit 1
    fi
else
    if [[ "$SKIP_SIGN" == true ]]; then
        log_info "按 --skip-sign 要求，以 ad-hoc 模式打包 App Bundle"
        IDENTITY="-" "$PROJECT_ROOT/Scripts/package_app.sh"
    elif [[ -n "$SIGNING_IDENTITY" ]]; then
        log_info "使用指定签名身份执行 package_app.sh: $SIGNING_IDENTITY"
        IDENTITY="$SIGNING_IDENTITY" "$PROJECT_ROOT/Scripts/package_app.sh"
    else
        "$PROJECT_ROOT/Scripts/package_app.sh"
    fi
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
    log_error "App Bundle 不存在：$APP_BUNDLE"
    exit 1
fi

HELPER_PLIST="$APP_BUNDLE/Contents/Library/LaunchDaemons/com.skybridge.PowerMetricsHelper.plist"
HELPER_BIN="$APP_BUNDLE/Contents/Library/LaunchDaemons/com.skybridge.PowerMetricsHelper/com.skybridge.PowerMetricsHelper"
if [[ -f "$HELPER_PLIST" && -x "$HELPER_BIN" ]]; then
    log_success "检测到 PowerMetricsHelper 与 launchd plist"
else
    log_info "未检测到完整 PowerMetricsHelper（高级监控功能可能不可用）"
fi

log_success "App Bundle 已就绪: $APP_BUNDLE"

if [[ "$SKIP_SIGN" == false ]]; then
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="$(select_identity)"
    fi

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        if [[ "$USE_EXISTING_APP" == true ]]; then
            log_step "步骤 3: 对现有 App 重新签名"
            APP_PATH="$APP_BUNDLE" IDENTITY="$SIGNING_IDENTITY" "$PROJECT_ROOT/Scripts/sign_app.sh"
        else
            log_step "步骤 3: 签名检查"
            if codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null 2>&1; then
                log_success "签名校验通过（使用 package_app.sh 产物）"
            else
                log_info "签名校验未通过，尝试补签名..."
                APP_PATH="$APP_BUNDLE" IDENTITY="$SIGNING_IDENTITY" "$PROJECT_ROOT/Scripts/sign_app.sh"
            fi
        fi
    else
        log_info "未检测到可用签名证书，保持当前签名状态（可能为 ad-hoc）"
    fi
else
    log_info "按 --skip-sign 要求，跳过签名步骤"
fi

log_step "步骤 4: 创建 DMG"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "$VERSION")"
DMG_PATH="$DIST_DIR/${DMG_NAME}-${APP_VERSION}.dmg"

rm -f "$DMG_PATH" "$TEMP_DMG"
rm -rf "$STAGE_DIR"

log_info "准备 DMG staging 目录..."
mkdir -p "$STAGE_DIR"
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
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

APP_SIZE=$(du -sm "$STAGE_DIR" | cut -f1)
DMG_SIZE=$((APP_SIZE + 50))

log_info "创建临时 DMG (${DMG_SIZE}MB)..."
hdiutil create -srcfolder "$STAGE_DIR" \
    -volname "$VOLUME_NAME" \
    -fs APFS \
    -format UDRW \
    -size "${DMG_SIZE}m" \
    "$TEMP_DMG"

log_info "挂载 DMG..."
if [[ -d "/Volumes/$VOLUME_NAME" ]]; then
    hdiutil detach "/Volumes/$VOLUME_NAME" >/dev/null 2>&1 || true
fi
ATTACH_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG")
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
    tell disk "$DMG_DISPLAY_NAME"
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
end tell
OSA

sync
hdiutil detach "$MOUNT_DIR"

log_info "压缩 DMG..."
if [[ ! -f "$TEMP_DMG" ]]; then
    log_error "找不到临时 DMG: $TEMP_DMG"
    ls -lah "$DIST_DIR" || true
    exit 1
fi
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"

rm -f "$TEMP_DMG"

log_success "DMG 创建完成: $DMG_PATH"

log_step "构建完成"

echo ""
echo "📦 App Bundle: $APP_BUNDLE"
echo "💿 DMG 文件:   $DMG_PATH"
echo ""
echo "📊 DMG 大小: $(du -h "$DMG_PATH" | cut -f1)"

echo ""
echo "🔐 签名摘要:"
codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "(Authority|Identifier|TeamIdentifier|Signature)" || true

echo ""
log_success "所有步骤完成！"
