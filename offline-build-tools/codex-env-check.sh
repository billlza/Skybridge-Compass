#!/bin/bash
echo "=== CodeX 环境检测脚本 ==="
echo ""

echo "1. 检查 Java 环境:"
if command -v java >/dev/null 2>&1; then
    echo "✅ Java 已安装"
    java -version
    echo "Java 路径: $(which java)"
else
    echo "❌ Java 未安装"
fi

echo ""
echo "2. 检查环境变量:"
echo "JAVA_HOME: ${JAVA_HOME:-未设置}"
echo "ANDROID_HOME: ${ANDROID_HOME:-未设置}"
echo "GRADLE_OPTS: ${GRADLE_OPTS:-未设置}"

echo ""
echo "3. 检查 Gradle 配置:"
if [ -f "gradle.properties" ]; then
    echo "✅ gradle.properties 存在"
    echo "内容:"
    cat gradle.properties
else
    echo "❌ gradle.properties 不存在"
fi

echo ""
echo "4. 检查 Gradle Wrapper:"
if [ -f "gradlew" ]; then
    echo "✅ gradlew 存在"
    ls -la gradlew
else
    echo "❌ gradlew 不存在"
fi

echo ""
echo "5. 检查 AGP 缓存:"
if [ -d "agp-cache-8.7.3" ]; then
    echo "✅ AGP 8.7.3 缓存存在"
    ls -la agp-cache-8.7.3/
else
    echo "❌ AGP 8.7.3 缓存不存在"
fi

echo ""
echo "=== 环境检测完成 ==="
