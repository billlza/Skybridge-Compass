#!/bin/bash
echo "=== 云桥司南离线构建工具 ==="
echo ""

# 设置环境变量
export JAVA_HOME=${JAVA_HOME:-$(dirname $(dirname $(readlink -f $(which java))))}
export ANDROID_HOME=/Users/macbookpro/Library/Android/sdk

echo "Java 版本:"
java -version

echo ""
echo "Android SDK 路径: $ANDROID_HOME"

echo ""
echo "=== 开始离线构建 ==="
./gradlew assembleDebug --offline --console=plain

echo ""
echo "=== 构建完成 ==="
ls -la app/build/outputs/apk/debug/
