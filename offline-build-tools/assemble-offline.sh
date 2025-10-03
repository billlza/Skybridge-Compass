#!/bin/bash
echo "=== 云桥司南离线构建脚本 ==="
echo ""

# 设置环境变量（自动检测 Java 路径）
export JAVA_HOME=${JAVA_HOME:-$(dirname $(dirname $(readlink -f $(which java))))}
export ANDROID_HOME=${ANDROID_HOME:-/Users/macbookpro/Library/Android/sdk}

echo "Java Home: $JAVA_HOME"
echo "Android SDK: $ANDROID_HOME"

# 检查 Java 环境
if command -v java >/dev/null 2>&1; then
    echo "Java 版本:"
    java -version
else
    echo "错误: 未找到 Java 环境"
    exit 1
fi

# 检查 Android SDK（可选）
if [ ! -d "$ANDROID_HOME" ]; then
    echo "警告: Android SDK 未找到: $ANDROID_HOME"
    echo "将尝试使用系统默认路径"
    export ANDROID_HOME=""
fi

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
echo "=== 开始离线构建 ==="

# 执行构建
./gradlew assembleDebug \
    --offline \
    --no-daemon \
    --console=plain \
    --stacktrace

# 检查构建结果
if [ $? -eq 0 ]; then
    echo ""
    echo "✅ 构建成功!"
    echo "APK 位置:"
    ls -la app/build/outputs/apk/debug/
else
    echo ""
    echo "❌ 构建失败!"
    exit 1
fi
