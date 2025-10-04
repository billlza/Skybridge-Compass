#!/bin/bash
echo "=== CodeX 终极离线构建脚本 ==="
echo ""

# 完全清除所有可能的环境变量
unset JAVA_HOME
unset ANDROID_HOME
unset GRADLE_OPTS
unset GRADLE_USER_HOME

# 检查 Java 环境
if command -v java >/dev/null 2>&1; then
    echo "Java 版本:"
    java -version
    echo "Java 路径: $(which java)"
else
    echo "错误: 未找到 Java 环境"
    exit 1
fi

# 创建完全干净的 gradle.properties
echo ""
echo "=== 创建完全干净的 gradle.properties ==="
cat > gradle.properties << 'PROPERTIES'
# CodeX 专用 Gradle 配置
# 完全离线，无硬编码路径

# JVM 配置
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8

# 构建配置
org.gradle.parallel=false
org.gradle.daemon=false
org.gradle.configureondemand=false
org.gradle.caching=false

# Android 配置
android.useAndroidX=true
android.nonTransitiveRClass=true
kotlin.code.style=official

# 离线配置
org.gradle.offline=true

# 注意: 不设置任何 Java 路径
# 让 Gradle 自动检测
PROPERTIES

echo "已创建干净的 gradle.properties"

# 安装 AGP 8.7.3 到离线缓存
echo ""
echo "=== 安装 AGP 8.7.3 到离线缓存 ==="
if [ -f "agp-cache-8.7.3/install-agp-8.7.3.sh" ]; then
    cd agp-cache-8.7.3
    ./install-agp-8.7.3.sh
    cd ..
    echo "✅ AGP 8.7.3 安装完成"
else
    echo "警告: 未找到 AGP 8.7.3 安装脚本"
fi

echo ""
echo "=== 开始 CodeX 终极离线构建 ==="

# 执行构建，使用最简化的参数
./gradlew assembleDebug \
    --offline \
    --no-daemon \
    --console=plain \
    --stacktrace \
    --no-build-cache \
    --no-configuration-cache

# 检查构建结果
if [ $? -eq 0 ]; then
    echo ""
    echo "✅ 构建成功!"
    echo "APK 位置:"
    ls -la app/build/outputs/apk/debug/
else
    echo ""
    echo "❌ 构建失败!"
    echo "检查构建日志..."
    exit 1
fi

# 检测 Xcode 工具链可用性
echo "=== 检测 Xcode 工具链 ==="
if command -v xcodebuild >/dev/null 2>&1; then
    echo "✅ Xcode 环境可用，支持全平台构建"
    BUILD_IOS=true
    xcodebuild -version
else
    echo "⚠️  CodeX 环境，Xcode 工具链不可用"
    echo "    - xcodebuild: 不可用"
    echo "    - iOS SDK: 不可用"
    echo "    - 仅支持 Android 构建"
    BUILD_IOS=false
fi

# 检测 Flutter 环境
echo ""
echo "=== 检测 Flutter 环境 ==="
if command -v flutter >/dev/null 2>&1; then
    echo "✅ Flutter 环境可用"
    flutter --version
    
    # 根据 Xcode 可用性选择构建方式
    if [ "$BUILD_IOS" = "true" ]; then
        echo "📱 构建全平台版本 (Android + iOS)"
        cd flutter_app
        flutter build apk
        flutter build ios --no-codesign
        cd ..
    else
        echo "📱 构建 Android 版本 (CodeX 环境)"
        cd flutter_app
        flutter build apk --no-ios
        cd ..
    fi
else
    echo "⚠️  Flutter 环境不可用，跳过 Flutter 构建"
fi

# 构建 Android 主项目
echo ""
echo "=== 构建 Android 主项目 ==="
if [ -f "app/build.gradle.kts" ]; then
    echo "✅ 构建 Android Kotlin/Compose 应用"
    ./gradlew assembleDebug --no-daemon --offline
else
    echo "⚠️  未找到 Android 项目文件"
fi
