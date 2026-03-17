#!/bin/bash
#
# SkyBridge Compass 构建脚本（包含 Widget Extension）
#
# 由于 SwiftPM 不支持构建 App Extensions，此脚本：
# 1. 使用 SwiftPM 构建主应用
# 2. 使用 xcodebuild 构建 Widget Extension
# 3. 将 Widget Extension 嵌入主应用
#

set -e

# ============================================================================
# 配置
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/.build/release"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="SkyBridge Compass Pro"
APP_EXECUTABLE="SkyBridgeCompassApp"
APP_INFO_PLIST_SOURCE="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/Info.plist"
APP_PACKAGING_ENTITLEMENTS="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
WIDGET_EXT_NAME="SkyBridgeCompassWidgetsExtension"
BG_SRC_PNG="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/Resources/AppIcon.png"

# ============================================================================
# 辅助函数
# ============================================================================

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

# ============================================================================
# 步骤 1: 使用 SwiftPM 构建主应用
# ============================================================================

log_step "步骤 1: 构建主应用 (SwiftPM)"

cd "$PROJECT_ROOT"

log_info "清理旧构建..."
swift package clean 2>/dev/null || true

log_info "检测 Apple PQC SDK 可用性（用于编译期开关 HAS_APPLE_PQC_SDK）..."
SDK_VER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "")"
SDK_MAJOR="$(echo "$SDK_VER" | awk -F. '{print $1}')"
if [ -n "$SDK_MAJOR" ] && [ "$SDK_MAJOR" -ge 26 ]; then
    export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
    log_info "✅ 检测到 macOS SDK ${SDK_VER}（>=26），启用 Apple PQC 编译条件"
else
    unset SKYBRIDGE_ENABLE_APPLE_PQC_SDK
    log_info "ℹ️ 未检测到 macOS SDK 26+（当前: ${SDK_VER:-unknown}），禁用 Apple PQC 编译条件（运行仍可使用 classic/liboqs）"
fi

log_info "构建 Release 版本..."
swift build -c release

log_success "主应用构建完成"

# ============================================================================
# 步骤 2: 创建 App Bundle
# ============================================================================

log_step "步骤 2: 创建 App Bundle"

# 运行现有的 DMG 构建脚本的 App Bundle 部分
mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/PlugIns"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# 复制可执行文件
EXECUTABLE="$BUILD_DIR/$APP_EXECUTABLE"
if [ ! -f "$EXECUTABLE" ]; then
    log_error "找不到可执行文件: $EXECUTABLE"
    exit 1
fi

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"

# 复制真实主应用 Info.plist，保持 bundle id / executable / entitlements 契约一致
if [ ! -f "$APP_INFO_PLIST_SOURCE" ]; then
    log_error "找不到主应用 Info.plist: $APP_INFO_PLIST_SOURCE"
    exit 1
fi
cp "$APP_INFO_PLIST_SOURCE" "$APP_BUNDLE/Contents/Info.plist"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "1.0.0")

# 复制图标
ICON_SOURCE="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/Resources/AppIcon.icns"
if [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    log_info "已复制应用图标"
fi

# 复制 Frameworks（例如 WebRTC.framework）
log_info "复制嵌入式 Frameworks..."
for framework in "$BUILD_DIR"/*.framework; do
    if [ -d "$framework" ]; then
        framework_name=$(basename "$framework")
        log_info "  复制 $framework_name"
        cp -R "$framework" "$APP_BUNDLE/Contents/Frameworks/"
    fi
done

# 确保主可执行文件可以从 Frameworks 目录加载动态框架
APP_EXECUTABLE_PATH="$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"
if ! otool -l "$APP_EXECUTABLE_PATH" 2>/dev/null | grep -q "@executable_path/../Frameworks"; then
    log_info "注入 Frameworks rpath..."
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_EXECUTABLE_PATH" 2>/dev/null || true
fi

# 复制 SPM 资源 bundle
log_info "复制 SPM 资源 bundle..."
for bundle in "$BUILD_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        bundle_name=$(basename "$bundle")
        log_info "  复制 $bundle_name"
        cp -r "$bundle" "$APP_BUNDLE/Contents/Resources/"
    fi
done

log_success "App Bundle 创建完成"

# ============================================================================
# 步骤 2.5: FreeRDP 依赖处理（XCFramework）
# ============================================================================

log_step "步骤 2.5: FreeRDP 依赖处理（XCFramework）"

# 说明：
# 已切换到 Sources/Vendor 下的 FreeRDP/WinPR/FreeRDPClient XCFramework（静态库）
# 不需要再嵌入 Homebrew dylib，避免 macOS 版本不匹配告警。
log_info "已使用 XCFramework（静态库），无需嵌入 Homebrew dylib"

# ============================================================================
# 步骤 3: 构建 Widget Extension
# ============================================================================

log_step "步骤 3: 构建 Widget Extension"

# 检查是否有 Xcode 项目（支持两种项目名称）
XCODE_PROJECT=""
if [ -d "$PROJECT_ROOT/SkyBridgeWidgets.xcodeproj" ]; then
    XCODE_PROJECT="$PROJECT_ROOT/SkyBridgeWidgets.xcodeproj"
elif [ -d "$PROJECT_ROOT/SkyBridgeCompass.xcodeproj" ]; then
    XCODE_PROJECT="$PROJECT_ROOT/SkyBridgeCompass.xcodeproj"
fi

if [ -z "$XCODE_PROJECT" ]; then
    log_info "未找到 Xcode 项目，跳过 Widget Extension 构建"
    log_info "提示：Widget Extension 需要通过 Xcode 项目构建"
    log_info "请参考 Docs/Widget_Extension_Setup.md 手动配置"
else
    log_info "尝试构建 Widget Extension..."
    log_info "使用项目: $XCODE_PROJECT"

    # 尝试构建 Widget Extension
    WIDGET_BUILD_DIR="$PROJECT_ROOT/.build/widget-release"
    mkdir -p "$WIDGET_BUILD_DIR"

    # 使用 xcodebuild 构建 Widget Extension
    xcodebuild -project "$XCODE_PROJECT" \
        -target SkyBridgeCompassWidgetsExtension \
        -configuration Release \
        -arch arm64 \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        CONFIGURATION_BUILD_DIR="$WIDGET_BUILD_DIR" \
        build 2>&1 | tail -20 || {
            log_info "Widget Extension 构建失败，跳过嵌入"
            log_info "Widget 功能将不可用，但主应用仍可正常使用"
        }

    # 如果构建成功，嵌入 Widget Extension
    WIDGET_APPEX="$WIDGET_BUILD_DIR/$WIDGET_EXT_NAME.appex"
    if [ -d "$WIDGET_APPEX" ]; then
        log_info "嵌入 Widget Extension..."
        cp -r "$WIDGET_APPEX" "$APP_BUNDLE/Contents/PlugIns/"
        log_success "Widget Extension 已嵌入"
    fi
fi

# ============================================================================
# 步骤 4: 代码签名
# ============================================================================

log_step "步骤 4: 代码签名"

# 检测签名身份
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
if [ -z "$SIGNING_IDENTITY" ]; then
    log_info "未找到 Developer ID 证书，使用 ad-hoc 签名"
    SIGNING_IDENTITY="-"
else
    log_info "使用签名身份: $SIGNING_IDENTITY"
fi

# 签名嵌入的库（必须先签名库，再签名应用）
log_info "签名嵌入的库..."
if [ -d "$APP_BUNDLE/Contents/Frameworks" ]; then
    for framework in "$APP_BUNDLE/Contents/Frameworks"/*.framework; do
        if [ -d "$framework" ]; then
            log_info "  签名 $(basename "$framework")..."
            codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$framework" 2>/dev/null || \
            codesign --force --sign - "$framework"
        fi
    done
    for lib in "$APP_BUNDLE/Contents/Frameworks"/*.dylib; do
        if [ -f "$lib" ]; then
            log_info "  签名 $(basename "$lib")..."
            codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$lib" 2>/dev/null || \
            codesign --force --sign - "$lib"
        fi
    done
    log_success "嵌入库签名完成"
fi

# 签名 Widget Extension
log_info "签名 Widget Extension..."
if [ -d "$APP_BUNDLE/Contents/PlugIns/$WIDGET_EXT_NAME.appex" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime \
        --entitlements "$PROJECT_ROOT/Sources/SkyBridgeCompassWidgets/SkyBridgeCompassWidgetsExtension.entitlements" \
        "$APP_BUNDLE/Contents/PlugIns/$WIDGET_EXT_NAME.appex" 2>/dev/null || \
    codesign --force --sign - \
        "$APP_BUNDLE/Contents/PlugIns/$WIDGET_EXT_NAME.appex"
    log_success "Widget Extension 已签名"
fi

# 签名主应用
log_info "签名主应用..."
codesign --force --sign "$SIGNING_IDENTITY" --options runtime \
    --entitlements "$APP_PACKAGING_ENTITLEMENTS" \
    "$APP_BUNDLE" 2>/dev/null || \
codesign --force --sign - --entitlements "$APP_PACKAGING_ENTITLEMENTS" \
    "$APP_BUNDLE"
log_success "主应用已签名"

# 验证签名
log_info "验证签名..."
codesign --verify --verbose "$APP_BUNDLE" && log_success "签名验证通过" || log_info "签名验证警告（ad-hoc 签名正常）"

# ============================================================================
# 步骤 5: 创建 DMG
# ============================================================================

log_step "步骤 5: 创建 DMG"

DMG_NAME="SkyBridgeCompassPro"
DMG_PATH="$DIST_DIR/${DMG_NAME}-${VERSION}.dmg"
TEMP_DMG="$DIST_DIR/${DMG_NAME}.rw.dmg"
VOLUME_NAME="SkyBridge Compass Pro"
STAGING_DIR="$DIST_DIR/.dmg_staging"
BG_DIR="$STAGING_DIR/.background"
BG_PNG="$BG_DIR/background.png"

# 删除旧的 DMG
rm -f "$DMG_PATH" "$TEMP_DMG"

log_info "创建 DMG（带背景与 Applications 快捷方式）..."

if [ -d "/Volumes/$VOLUME_NAME" ]; then
    hdiutil detach "/Volumes/$VOLUME_NAME" >/dev/null 2>&1 || true
fi

rm -rf "$STAGING_DIR"
mkdir -p "$BG_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
if [ -f "$BG_SRC_PNG" ]; then
    cp "$BG_SRC_PNG" "$BG_PNG"
    sips -Z 1600 "$BG_PNG" >/dev/null 2>&1 || true
else
    log_info "未找到背景源图：$BG_SRC_PNG（将使用默认白底）"
fi

hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDRW "$TEMP_DMG" >/dev/null

ATTACH_PLIST=$(hdiutil attach -readwrite -noverify -noautoopen -plist "$TEMP_DMG")
ATTACH_PLIST_FILE="$DIST_DIR/.dmg_attach.plist"
printf "%s" "$ATTACH_PLIST" > "$ATTACH_PLIST_FILE"
export ATTACH_PLIST_FILE
DEVICE=$(python3 - <<'PY'
import os, plistlib
with open(os.environ["ATTACH_PLIST_FILE"], "rb") as f:
    plist = plistlib.load(f)
for ent in plist.get("system-entities", []):
    if "dev-entry" in ent:
        print(ent["dev-entry"])
        break
PY
)
MOUNT_POINT=$(python3 - <<'PY'
import os, plistlib
with open(os.environ["ATTACH_PLIST_FILE"], "rb") as f:
    plist = plistlib.load(f)
for ent in plist.get("system-entities", []):
    mp = ent.get("mount-point")
    if mp:
        print(mp)
        break
PY
)
rm -f "$ATTACH_PLIST_FILE"

if [ -z "$MOUNT_POINT" ]; then
    log_error "无法获取 DMG 挂载路径"
    if [ -n "$DEVICE" ]; then
        hdiutil detach "$DEVICE" >/dev/null 2>&1 || true
    fi
    exit 1
fi
DMG_DISPLAY_NAME=$(basename "$MOUNT_POINT")

mkdir -p "$MOUNT_POINT/.background"
cp "$BG_PNG" "$MOUNT_POINT/.background/background.png"

/usr/bin/osascript <<OSA
set dmgName to "$DMG_DISPLAY_NAME"
set appName to "$APP_NAME.app"
set bgPath to POSIX file "$MOUNT_POINT/.background/background.png"

tell application "Finder"
    tell disk dmgName
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 980, 680}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 120
        set background picture of viewOptions to bgPath
        set position of item appName to {240, 300}
        set position of item "Applications" to {680, 300}
        update without registering applications
        delay 2
        close
    end tell
end tell
OSA

hdiutil detach "$DEVICE" >/dev/null || true
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

rm -rf "$STAGING_DIR" "$TEMP_DMG"

log_success "DMG 创建完成: $DMG_PATH"

# ============================================================================
# 完成
# ============================================================================

log_step "构建完成"

echo ""
echo "📦 App Bundle: $APP_BUNDLE"
echo "💿 DMG 文件:   $DMG_PATH"
echo ""

# 显示文件大小
DMG_SIZE_MB=$(du -h "$DMG_PATH" | cut -f1)
echo "📊 DMG 大小: $DMG_SIZE_MB"

# 检查 Widget Extension
if [ -d "$APP_BUNDLE/Contents/PlugIns/$WIDGET_EXT_NAME.appex" ]; then
    echo "🧩 Widget Extension: 已嵌入"
else
    echo "🧩 Widget Extension: 未嵌入（需要手动配置 Xcode 项目）"
    echo "   请参考: Docs/Widget_Extension_Setup.md"
fi

echo ""
log_success "所有步骤完成！"
