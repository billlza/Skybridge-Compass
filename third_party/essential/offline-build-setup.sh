#!/bin/bash
# 离线构建环境设置脚本

echo "=== 离线构建环境设置 ==="

# 检查环境变量
if [ -z "$ANDROID_SDK_ROOT" ] && [ -z "$ANDROID_HOME" ]; then
    echo "错误: 请设置 ANDROID_SDK_ROOT 或 ANDROID_HOME 环境变量"
    exit 1
fi

# 设置 Android SDK 路径
if [ -n "$ANDROID_SDK_ROOT" ]; then
    ANDROID_SDK="$ANDROID_SDK_ROOT"
elif [ -n "$ANDROID_HOME" ]; then
    ANDROID_SDK="$ANDROID_HOME"
fi

echo "Android SDK: $ANDROID_SDK"

# 检查 aapt2
AAPT2_PATH="$ANDROID_SDK/build-tools/35.0.0/aapt2"
if [ ! -f "$AAPT2_PATH" ]; then
    echo "警告: aapt2 未找到，尝试查找其他版本..."
    find "$ANDROID_SDK/build-tools" -name "aapt2" 2>/dev/null | head -1
fi

# 设置 Gradle 属性
export ANDROID_SDK_ROOT="$ANDROID_SDK"
export ANDROID_HOME="$ANDROID_SDK"

# 设置 aapt2 路径
if [ -f "$AAPT2_PATH" ]; then
    export GRADLE_OPTS="-Dandroid.aapt2FromMavenOverride=$AAPT2_PATH"
    echo "aapt2 路径: $AAPT2_PATH"
fi

echo "=== 环境设置完成 ==="
echo "现在可以运行: ./scripts/codex-build-offline.sh assembleDebug"
