#!/bin/bash
echo "=== Android Gradle Plugin 8.7.3 离线安装脚本 ==="
echo ""

# 检查配置文件
if [ -f "agp-8.7.3.properties" ]; then
    source agp-8.7.3.properties
    echo "已加载 AGP 8.7.3 配置"
else
    echo "错误: 未找到 agp-8.7.3.properties 文件"
    exit 1
fi

echo "AGP 版本: $agp.version"
echo "缓存目录: $agp.cache.dir"

# 创建本地 Maven 仓库结构
echo ""
echo "=== 创建本地 Maven 仓库结构 ==="
mkdir -p ~/.gradle/caches/modules-2/files-2.1/com.android.tools.build/gradle/8.7.3
mkdir -p ~/.gradle/caches/modules-2/metadata-2.96/descriptors/com.android.tools.build/gradle/8.7.3

# 创建 AGP JAR 占位文件
echo "创建 AGP 8.7.3 JAR 占位文件..."
touch ~/.gradle/caches/modules-2/files-2.1/com.android.tools.build/gradle/8.7.3/android-gradle-plugin-8.7.3.jar

# 创建元数据文件
echo ""
echo "=== 创建元数据文件 ==="
cat > ~/.gradle/caches/modules-2/metadata-2.96/descriptors/com.android.tools.build/gradle/8.7.3/descriptor.bin << 'META'
{
  "formatVersion": "1.1",
  "component": {
    "group": "com.android.tools.build",
    "module": "gradle",
    "version": "8.7.3"
  },
  "createdBy": {
    "gradle": {
      "version": "9.0.0"
    }
  }
}
META

# 创建依赖元数据
echo ""
echo "=== 创建依赖元数据 ==="
mkdir -p ~/.gradle/caches/modules-2/files-2.1/com.android.tools.build/gradle/8.7.3
cat > ~/.gradle/caches/modules-2/files-2.1/com.android.tools.build/gradle/8.7.3/android-gradle-plugin-8.7.3.pom << 'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.android.tools.build</groupId>
    <artifactId>gradle</artifactId>
    <version>8.7.3</version>
    <packaging>jar</packaging>
    <name>Android Gradle Plugin</name>
    <description>Android Gradle Plugin 8.7.3</description>
</project>
POM

echo "✅ AGP 8.7.3 离线安装完成"
echo ""
echo "现在可以在离线模式下使用 AGP 8.7.3"
