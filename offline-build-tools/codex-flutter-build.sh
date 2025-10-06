#!/bin/bash
echo "=== CodeX Flutter 构建脚本 ==="
echo ""

# 检测环境
echo "=== 环境检测 ==="
if command -v flutter >/dev/null 2>&1; then
    echo "✅ Flutter 环境可用"
    flutter --version
else
    echo "❌ Flutter 环境不可用"
    exit 1
fi

if command -v xcodebuild >/dev/null 2>&1; then
    echo "✅ Xcode 环境可用"
    BUILD_IOS=true
else
    echo "⚠️  Xcode 环境不可用 (CodeX 环境)"
    BUILD_IOS=false
fi

# 进入 Flutter 项目目录
if [ -d "flutter_app" ]; then
    cd flutter_app
    echo "📁 进入 Flutter 项目目录"
else
    echo "❌ 未找到 flutter_app 目录"
    exit 1
fi

# 安装依赖
echo ""
echo "=== 安装 Flutter 依赖 ==="
flutter pub get

# 根据环境选择构建方式
echo ""
echo "=== 开始构建 ==="
if [ "$BUILD_IOS" = "true" ]; then
    echo "📱 构建全平台版本"
    
    # 构建 Android APK
    echo "🔨 构建 Android APK..."
    flutter build apk --release
    
    # 构建 iOS (需要 Xcode)
    echo "🔨 构建 iOS..."
    flutter build ios --no-codesign
    
    echo "✅ 全平台构建完成"
else
    echo "📱 构建 Android 版本 (CodeX 环境)"
    
    # 仅构建 Android
    echo "🔨 构建 Android APK..."
    flutter build apk --release --no-ios
    
    echo "✅ Android 构建完成"
    echo "ℹ️  iOS 构建在 CodeX 环境中不可用"
fi

# 检查构建结果
echo ""
echo "=== 构建结果 ==="
if [ -d "build/app/outputs/flutter-apk" ]; then
    echo "✅ Android APK 构建成功"
    ls -la build/app/outputs/flutter-apk/
else
    echo "❌ Android APK 构建失败"
fi

if [ "$BUILD_IOS" = "true" ] && [ -d "build/ios" ]; then
    echo "✅ iOS 构建成功"
    ls -la build/ios/
else
    echo "ℹ️  iOS 构建跳过 (CodeX 环境)"
fi

echo ""
echo "=== 构建完成 ==="
