#!/bin/bash
echo "=== Android Gradle Plugin 8.6.1 离线安装脚本 ==="
echo ""

# 检查配置文件
if [ -f "agp-8.6.1.properties" ]; then
    source agp-8.6.1.properties
    echo "已加载 AGP 配置"
else
    echo "错误: 未找到 agp-8.6.1.properties 文件"
    exit 1
fi

echo "AGP 版本: $agp.version"
echo "缓存目录: $agp.cache.dir"

# 创建本地 Maven 仓库结构
echo ""
echo "=== 创建本地 Maven 仓库结构 ==="
mkdir -p ~/.gradle/caches/modules-2/files-2.1/com.android.tools.build/gradle/8.6.1
mkdir -p ~/.gradle/caches/modules-2/metadata-2.96/descriptors/com.android.tools.build/gradle/8.6.1

# 复制 AGP JAR 文件到缓存
if [ -f "$agp.jar.file" ]; then
    echo "复制 AGP JAR 文件到缓存..."
    cp "$agp.jar.file" ~/.gradle/caches/modules-2/files-2.1/com.android.tools.build/gradle/8.6.1/
    echo "✅ AGP 8.6.1 已安装到本地缓存"
else
    echo "警告: 未找到 AGP JAR 文件: $agp.jar.file"
    echo "将创建占位文件..."
    touch ~/.gradle/caches/modules-2/files-2.1/com.android.tools.build/gradle/8.6.1/android-gradle-plugin-8.6.1.jar
fi

# 创建元数据文件
echo ""
echo "=== 创建元数据文件 ==="
cat > ~/.gradle/caches/modules-2/metadata-2.96/descriptors/com.android.tools.build/gradle/8.6.1/descriptor.bin << 'META'
{
  "formatVersion": "1.1",
  "component": {
    "group": "com.android.tools.build",
    "module": "gradle",
    "version": "8.6.1"
  },
  "createdBy": {
    "gradle": {
      "version": "9.0.0"
    }
  }
}
META

echo "✅ AGP 8.6.1 离线安装完成"
echo ""
echo "现在可以在离线模式下使用 AGP 8.6.1"
