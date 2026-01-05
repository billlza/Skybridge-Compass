#!/bin/zsh
# 使用 Xcode 构建并运行带图标的应用

set -e

echo "🔨 使用 Xcode 构建 Release 版本..."
xcodebuild -workspace .swiftpm/xcode/package.xcworkspace \
           -scheme SkyBridgeCompassApp \
           -configuration Release \
           -destination 'platform=macOS' \
           -derivedDataPath .build/xcode \
           build

echo "📦 打包应用..."
Scripts/package_app.sh

echo "🚀 启动应用..."
open "dist/SkyBridge Compass Pro.app"
