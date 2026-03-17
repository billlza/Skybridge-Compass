#!/bin/zsh
# 使用 Xcode 构建并运行带图标的应用

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/Scripts/xcodebuild_helpers.sh"
BUILD_DESTINATION="${BUILD_DESTINATION:-$(skybridge_default_macos_destination)}"
XCODE_WORKSPACE="$SCRIPT_DIR/.swiftpm/xcode/package.xcworkspace"
USE_XCODE_WORKSPACE=0

if [[ -d "$XCODE_WORKSPACE" ]]; then
  USE_XCODE_WORKSPACE=1
fi

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
if [[ "${USE_XCODE_WORKSPACE}" -eq 0 ]]; then
  echo "ℹ️ 未找到 package.xcworkspace，直接从 Swift package 根目录构建"
fi
if [[ "${USE_XCODE_WORKSPACE}" -eq 1 ]]; then
  skybridge_run_xcodebuild -workspace "$XCODE_WORKSPACE" \
                           -scheme SkyBridgeCompassApp \
                           -configuration Release \
                           -destination "$BUILD_DESTINATION" \
                           -derivedDataPath .build/xcode \
                           build
else
  skybridge_run_xcodebuild \
                           -scheme SkyBridgeCompassApp \
                           -configuration Release \
                           -destination "$BUILD_DESTINATION" \
                           -derivedDataPath .build/xcode \
                           build
fi

echo "📦 打包应用..."
Scripts/package_app.sh

echo "🚀 启动应用..."
open "dist/SkyBridge Compass Pro.app"
