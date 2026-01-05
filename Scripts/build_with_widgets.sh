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
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
WIDGET_EXT_NAME="SkyBridgeCompassWidgetsExtension"

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

# 复制可执行文件
EXECUTABLE="$BUILD_DIR/SkyBridgeCompassApp"
if [ ! -f "$EXECUTABLE" ]; then
    log_error "找不到可执行文件: $EXECUTABLE"
    exit 1
fi

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 创建 Info.plist
VERSION="1.0.0"
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.skybridge.compass</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>SkyBridge 需要访问本地网络以发现和连接附近设备。</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>SkyBridge 需要蓝牙权限以发现和连接附近设备。</string>
    <key>NSCameraUsageDescription</key>
    <string>SkyBridge 需要摄像头权限以进行屏幕共享。</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>SkyBridge 需要麦克风权限以进行音频传输。</string>
</dict>
</plist>
EOF

# 复制图标
ICON_SOURCE="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/Resources/AppIcon.icns"
if [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    log_info "已复制应用图标"
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
    --entitlements "$PROJECT_ROOT/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.entitlements" \
    "$APP_BUNDLE" 2>/dev/null || \
codesign --force --sign - \
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

SKYBRIDGE_DMG_BG_PATH="$BG_PNG" \
SKYBRIDGE_DMG_BG_SIZE="2000x1200" \
SKYBRIDGE_DMG_BG_DELAY="2.2" \
"$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [ ! -f "$BG_PNG" ]; then
    log_error "DMG 背景渲染失败: $BG_PNG"
    exit 1
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
