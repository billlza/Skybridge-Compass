#!/bin/bash
#
# SkyBridge Compass DMG Builder
# 
# 功能：
# 1. 构建 Release 版本应用
# 2. 代码签名
# 3. 创建 DMG 磁盘映像
# 4. 添加背景图片和 Applications 快捷方式
#
# Requirements: 5.1, 5.2, 5.3, 5.4
#
# 使用方法：
#   ./Scripts/build_dmg.sh [--skip-build] [--skip-sign] [--identity "Developer ID"]
#

set -e

# ============================================================================
# 配置
# ============================================================================

APP_NAME="SkyBridge Compass Pro"
BUNDLE_ID="com.skybridge.compass"
DMG_NAME="SkyBridgeCompassPro"
VOLUME_NAME="SkyBridge Compass Pro"
VERSION="1.0.0"

# 目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/.build/release"
DIST_DIR="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/${DMG_NAME}-${VERSION}.dmg"
TEMP_DMG="$DIST_DIR/temp_${DMG_NAME}.dmg"

# 签名身份（可通过参数覆盖）
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"

# 选项
SKIP_BUILD=false
SKIP_SIGN=false

# ============================================================================
# 参数解析
# ============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-sign)
            SKIP_SIGN=true
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
            echo "  --skip-build    跳过构建步骤"
            echo "  --skip-sign     跳过代码签名"
            echo "  --identity ID   指定签名身份"
            echo "  --help, -h      显示帮助信息"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            exit 1
            ;;
    esac
done

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

cleanup() {
    log_info "清理临时文件..."
    rm -f "$TEMP_DMG"
    # 卸载可能挂载的卷
    hdiutil detach "/Volumes/$VOLUME_NAME" 2>/dev/null || true
}

trap cleanup EXIT

# ============================================================================
# 步骤 1: 构建 Release 版本
# Requirements: 5.1
# ============================================================================

if [ "$SKIP_BUILD" = false ]; then
    log_step "步骤 1: 构建 Release 版本"
    
    cd "$PROJECT_ROOT"
    
    log_info "清理旧构建..."
    swift package clean 2>/dev/null || true
    
    log_info "构建 Release 版本..."
    swift build -c release
    
    log_success "构建完成"
else
    log_info "跳过构建步骤"
fi

# ============================================================================
# 步骤 2: 创建 App Bundle
# Requirements: 5.1
# ============================================================================

log_step "步骤 2: 创建 App Bundle"

# 创建目录结构
mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 复制可执行文件
EXECUTABLE="$BUILD_DIR/SkyBridgeCompassApp"
if [ ! -f "$EXECUTABLE" ]; then
    log_error "找不到可执行文件: $EXECUTABLE"
    exit 1
fi

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 创建 Info.plist
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
    <string>$BUNDLE_ID</string>
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

# 复制图标（如果存在）
ICON_SOURCE="$PROJECT_ROOT/Sources/SkyBridgeCompassApp/Resources/AppIcon.icns"
if [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    log_info "已复制应用图标"
else
    log_info "未找到应用图标，将使用系统默认图标"
fi

# 复制其他资源
if [ -d "$PROJECT_ROOT/Sources/SkyBridgeCore/Resources" ]; then
    cp -r "$PROJECT_ROOT/Sources/SkyBridgeCore/Resources/"* "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
fi

# 复制 SPM 生成的资源 bundle（包含各模块的本地化文件）
# 这些 bundle 对于 LocalizationManager 正确加载本地化字符串至关重要
log_info "复制 SPM 资源 bundle..."
for bundle in "$BUILD_DIR"/*.bundle; do
    if [ -d "$bundle" ]; then
        bundle_name=$(basename "$bundle")
        log_info "  复制 $bundle_name"
        cp -r "$bundle" "$APP_BUNDLE/Contents/Resources/"
    fi
done

log_success "App Bundle 创建完成: $APP_BUNDLE"

# ============================================================================
# 步骤 3: 代码签名
# Requirements: 5.1
# ============================================================================

if [ "$SKIP_SIGN" = false ] && [ -n "$SIGNING_IDENTITY" ]; then
    log_step "步骤 3: 代码签名"
    
    log_info "使用身份签名: $SIGNING_IDENTITY"
    
    # 签名应用
    codesign --force --deep --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --entitlements "$PROJECT_ROOT/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.entitlements" \
        "$APP_BUNDLE" 2>/dev/null || {
            log_info "未找到 entitlements 文件，使用默认签名"
            codesign --force --deep --sign "$SIGNING_IDENTITY" \
                --options runtime \
                "$APP_BUNDLE"
        }
    
    # 验证签名
    log_info "验证签名..."
    codesign --verify --verbose "$APP_BUNDLE"
    
    log_success "代码签名完成"
else
    if [ "$SKIP_SIGN" = true ]; then
        log_info "跳过代码签名"
    else
        log_info "未指定签名身份，跳过代码签名"
        log_info "提示: 使用 --identity 参数指定签名身份"
    fi
fi

# ============================================================================
# 步骤 4: 创建 DMG
# Requirements: 5.2, 5.3, 5.4
# ============================================================================

log_step "步骤 4: 创建 DMG"

# 删除旧的 DMG
rm -f "$DMG_PATH" "$TEMP_DMG"

# 计算所需大小（应用大小 + 50MB 余量）
APP_SIZE=$(du -sm "$APP_BUNDLE" | cut -f1)
DMG_SIZE=$((APP_SIZE + 50))

log_info "创建临时 DMG (${DMG_SIZE}MB)..."

# 创建临时 DMG
hdiutil create -srcfolder "$APP_BUNDLE" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size ${DMG_SIZE}m \
    "$TEMP_DMG"

# 挂载临时 DMG
log_info "挂载 DMG..."
if [ -d "/Volumes/$VOLUME_NAME" ]; then
    hdiutil detach "/Volumes/$VOLUME_NAME" >/dev/null 2>&1 || true
fi
ATTACH_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG")
MOUNT_DIR=$(echo "$ATTACH_INFO" | grep "/Volumes/" | sed 's/.*\(\/Volumes\/.*\)/\1/')
DMG_DISPLAY_NAME=$(basename "$MOUNT_DIR")

if [ -z "$MOUNT_DIR" ]; then
    log_error "无法挂载 DMG"
    exit 1
fi

log_info "DMG 已挂载到: $MOUNT_DIR"

# 创建 Applications 快捷方式
# Requirements: 5.2, 5.3
ln -sf /Applications "$MOUNT_DIR/Applications"

# 创建背景目录
mkdir -p "$MOUNT_DIR/.background"

log_info "创建 DMG 背景..."
export BG_PNG="$MOUNT_DIR/.background/background.png"
SKYBRIDGE_DMG_BG_PATH="$BG_PNG" \
SKYBRIDGE_DMG_BG_SIZE="2000x1200" \
SKYBRIDGE_DMG_BG_DELAY="2.2" \
"$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [ ! -f "$BG_PNG" ]; then
    log_error "DMG 背景渲染失败: $BG_PNG"
    exit 1
fi

# 设置 DMG 窗口属性
log_info "配置 DMG 窗口..."

# 使用 AppleScript 设置窗口属性
osascript << EOF || true
tell application "Finder"
    tell disk "$DMG_DISPLAY_NAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 980, 680}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 120
        
        -- 设置图标位置
        set position of item "$APP_NAME.app" of container window to {240, 300}
        set position of item "Applications" of container window to {680, 300}
        
        -- 设置背景（如果存在）
        try
            set background picture of theViewOptions to file ".background:background.png"
        end try
        
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

# 同步并卸载
sync
hdiutil detach "$MOUNT_DIR"

# 转换为压缩的只读 DMG
log_info "压缩 DMG..."
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"

# 清理临时文件
rm -f "$TEMP_DMG"

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

# 如果已签名，显示签名信息
if [ "$SKIP_SIGN" = false ] && [ -n "$SIGNING_IDENTITY" ]; then
    echo ""
    echo "🔐 签名信息:"
    codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "(Authority|Identifier|TeamIdentifier)" || true
fi

echo ""
log_success "所有步骤完成！"
