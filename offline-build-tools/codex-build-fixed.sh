#!/bin/bash
echo "=== CodeX 专用离线构建脚本 (修复版) ==="
echo ""

# 强制设置环境变量
unset JAVA_HOME
unset ANDROID_HOME

# 让系统自动检测 Java
if command -v java >/dev/null 2>&1; then
    echo "Java 版本:"
    java -version
    echo "Java 路径: $(which java)"
else
    echo "错误: 未找到 Java 环境"
    exit 1
fi

# 复制 CodeX 专用配置
echo ""
echo "=== 应用 CodeX 专用配置 ==="
if [ -f "gradle.properties" ]; then
    cp gradle.properties gradle.properties.backup
    echo "已备份原始配置"
fi

# 使用 CodeX 专用配置
cp offline-build-tools/gradle.properties gradle.properties
echo "已应用 CodeX 专用配置"

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
    echo "恢复原始配置..."
    if [ -f "gradle.properties.backup" ]; then
        cp gradle.properties.backup gradle.properties
        rm gradle.properties.backup
    fi
    exit 1
fi
