#!/bin/bash
echo "=== Java 25 LTS 环境配置 ==="
export JAVA_HOME=$(/usr/libexec/java_home -v 21)
echo "JAVA_HOME: $JAVA_HOME"
echo "Java 版本:"
java -version
echo "=== 测试 Gradle 9.0.0 ==="
./gradlew --version
echo "=== 构建项目 ==="
./gradlew clean build
