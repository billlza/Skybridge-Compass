#!/bin/bash
echo "=== AGP 8.6.1 离线验证脚本 ==="
echo ""

# 检查 AGP 缓存
echo "检查 AGP 缓存目录..."
if [ -d "~/.gradle/caches/modules-2/files-2.1/com.android.tools.build/gradle/8.6.1" ]; then
    echo "✅ AGP 缓存目录存在"
    ls -la ~/.gradle/caches/modules-2/files-2.1/com.android.tools.build/gradle/8.6.1/
else
    echo "❌ AGP 缓存目录不存在"
fi

# 检查元数据
echo ""
echo "检查元数据文件..."
if [ -f "~/.gradle/caches/modules-2/metadata-2.96/descriptors/com.android.tools.build/gradle/8.6.1/descriptor.bin" ]; then
    echo "✅ 元数据文件存在"
    cat ~/.gradle/caches/modules-2/metadata-2.96/descriptors/com.android.tools.build/gradle/8.6.1/descriptor.bin
else
    echo "❌ 元数据文件不存在"
fi

# 测试 Gradle 配置
echo ""
echo "测试 Gradle 配置..."
cd ../../
if [ -f "build.gradle.kts" ]; then
    echo "✅ 项目构建文件存在"
    echo "AGP 版本配置:"
    grep -r "agp" gradle/ || echo "未找到 AGP 配置"
else
    echo "❌ 项目构建文件不存在"
fi

echo ""
echo "=== 验证完成 ==="
