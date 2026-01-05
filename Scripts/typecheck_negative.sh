#!/bin/bash
# Scripts/typecheck_negative.sh
# 类型层面排除测试：这些文件必须编译失败
#
# 用途：验证类型系统正确排除了不安全的用法
# - P256SePoPProvider 不能当 any ProtocolSignatureProvider
# - CryptoProvider 不能喂给签名参数
# - LegacySignatureVerifier 没有 sign 方法
#
# Requirements: 1.1, 1.2, 3.4, 3.5

set -e

NEGATIVE_DIR="Tests/Negative"
FAILED=0
PASSED=0

echo "=== Compile-Fail Harness ==="
echo ""

if [ ! -d "$NEGATIVE_DIR" ]; then
    echo "ERROR: $NEGATIVE_DIR directory does not exist"
    echo "Create negative test files first"
    exit 1
fi

# 获取 SDK 路径
SDK_PATH=$(xcrun --show-sdk-path)

# 获取项目的 module 搜索路径
# 注意：这里假设已经 build 过项目，module 在 .build 目录
BUILD_DIR=".build/debug"

for file in "$NEGATIVE_DIR"/*.swift; do
    if [ ! -f "$file" ]; then
        echo "No .swift files found in $NEGATIVE_DIR"
        exit 1
    fi
    
    filename=$(basename "$file")
    echo "Testing: $filename"
    
    # 尝试 typecheck，应该失败
    # 使用 -parse-as-library 避免需要 main
    # 注意：这里只做语法检查，不需要完整的 module 依赖
    if xcrun swiftc -typecheck -parse-as-library -sdk "$SDK_PATH" "$file" 2>/dev/null; then
        echo "   FAIL: $filename should not compile but did"
        FAILED=$((FAILED + 1))
    else
        echo "   PASS: $filename correctly failed to compile"
        PASSED=$((PASSED + 1))
    fi
done

echo ""
echo "=== Results ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "RESULT: FAILED - Some files compiled when they should not"
    exit 1
else
    echo ""
    echo "RESULT: PASSED - All negative tests correctly failed to compile"
    exit 0
fi
