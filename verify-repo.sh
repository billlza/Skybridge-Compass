#!/bin/bash
echo "=== 仓库根目录文件列表 ==="
ls -la

echo -e "\n=== Gradle Wrapper 文件 ==="
ls -la gradlew* 2>/dev/null || echo "gradlew 文件不存在"
ls -la gradle/wrapper/ 2>/dev/null || echo "gradle/wrapper 目录不存在"

echo -e "\n=== 测试 Gradle Wrapper ==="
./gradlew --version 2>/dev/null && echo "Gradle Wrapper 工作正常" || echo "Gradle Wrapper 无法执行"

echo -e "\n=== Git 文件状态 ==="
git ls-files | grep -E '^(gradlew|gradle/)' | sort
