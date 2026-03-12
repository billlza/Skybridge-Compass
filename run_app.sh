#!/bin/zsh
# 使用 Xcode 构建并运行带图标的应用

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/Scripts/xcodebuild_helpers.sh"
BUILD_DESTINATION="${BUILD_DESTINATION:-$(skybridge_default_macos_destination)}"

echo "🔎 检测 Apple PQC SDK（用于编译期开关 HAS_APPLE_PQC_SDK）..."
SDK_VER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "")"
SDK_MAJOR="$(echo "$SDK_VER" | awk -F. '{print $1}')"
if [ -n "$SDK_MAJOR" ] && [ "$SDK_MAJOR" -ge 26 ]; then
  export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
  echo "✅ macOS SDK ${SDK_VER}（>=26）：启用 Apple PQC 编译条件"
else
  unset SKYBRIDGE_ENABLE_APPLE_PQC_SDK
  echo "ℹ️ macOS SDK ${SDK_VER:-unknown}：禁用 Apple PQC 编译条件"
fi

echo "🔨 使用 Xcode 构建 Release 版本..."
skybridge_run_xcodebuild -workspace .swiftpm/xcode/package.xcworkspace \
                         -scheme SkyBridgeCompassApp \
                         -configuration Release \
                         -destination "$BUILD_DESTINATION" \
                         -derivedDataPath .build/xcode \
                         build

echo "📦 打包应用..."
Scripts/package_app.sh

echo "🚀 启动应用..."
open "dist/SkyBridge Compass Pro.app"
