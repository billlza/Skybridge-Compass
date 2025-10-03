#!/bin/bash
echo "=== CodeX 专用离线构建脚本 ==="
echo ""

# 读取配置文件
if [ -f "codex-build.properties" ]; then
    source codex-build.properties
    echo "已加载配置文件"
else
    echo "警告: 未找到 codex-build.properties 文件"
fi

# 设置环境变量
export JAVA_HOME=${java.home:-/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home}
export ANDROID_HOME=${android.sdk.path:-/Users/macbookpro/Library/Android/sdk}

echo "Java Home: $JAVA_HOME"
echo "Android SDK: $ANDROID_HOME"

# 检查环境
if [ ! -d "$JAVA_HOME" ]; then
    echo "错误: Java 环境未找到: $JAVA_HOME"
    exit 1
fi

if [ ! -d "$ANDROID_HOME" ]; then
    echo "错误: Android SDK 未找到: $ANDROID_HOME"
    exit 1
fi

echo ""
echo "=== 开始 CodeX 离线构建 ==="

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
