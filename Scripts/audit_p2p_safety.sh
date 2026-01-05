#!/bin/bash
# Scripts/audit_p2p_safety.sh
# P2P 目录静态审计脚本
# 
# 用途：CI gate，确保 P2P 目录不包含 precondition/fatalError（避免远程 DoS）
# 以及 signatureProvider: 只在白名单注入点使用
#
# Requirements: 7.4, 7.5

set -e

P2P_DIR="Sources/SkyBridgeCore/P2P"
FAILED=0

echo "=== P2P Safety Audit ==="
echo ""

# 1. precondition/fatalError 必须为 0
echo "1. Checking for precondition/fatalError in P2P directory..."
PRECONDITION_COUNT=$(grep -rE "precondition\(|fatalError\(" "$P2P_DIR" 2>/dev/null | grep -v "// ALLOWED" | wc -l | tr -d ' ')

if [ "$PRECONDITION_COUNT" -gt 0 ]; then
    echo "   FAIL: Found $PRECONDITION_COUNT precondition/fatalError in P2P directory"
    echo "   Details:"
    grep -rE "precondition\(|fatalError\(" "$P2P_DIR" 2>/dev/null | grep -v "// ALLOWED" | sed 's/^/      /'
    FAILED=1
else
    echo "   PASS: No precondition/fatalError in P2P directory"
fi

echo ""

# 2. signatureProvider: 只允许白名单注入点
echo "2. Checking for non-whitelisted signatureProvider: usage..."
# 白名单模式：
# - Tests 目录允许
# - 带 // ALLOWED 注释的允许
# - HandshakeDriver init 参数定义允许
SIGNATURE_PROVIDER_VIOLATIONS=$(grep -rn "signatureProvider:" Sources 2>/dev/null | grep -v "Tests/" | grep -v "// ALLOWED" | grep -v "protocolSignatureProvider:" | grep -v "sePoPSignatureProvider:" || true)

if [ -n "$SIGNATURE_PROVIDER_VIOLATIONS" ]; then
    echo "   FAIL: Found non-whitelisted signatureProvider: usage"
    echo "   Details:"
    echo "$SIGNATURE_PROVIDER_VIOLATIONS" | sed 's/^/      /'
    FAILED=1
else
    echo "   PASS: All signatureProvider: usages are whitelisted or use new naming"
fi

echo ""

# 3. 检查 CryptoProvider 被传给签名参数的情况
echo "3. Checking for CryptoProvider used as signature provider..."
CRYPTO_AS_SIG=$(grep -rn "protocolSignatureProvider:.*CryptoProvider\|sePoPSignatureProvider:.*CryptoProvider" Sources 2>/dev/null | grep -v "Tests/" | grep -v "// ALLOWED" || true)

if [ -n "$CRYPTO_AS_SIG" ]; then
    echo "   FAIL: Found CryptoProvider used as signature provider"
    echo "   Details:"
    echo "$CRYPTO_AS_SIG" | sed 's/^/      /'
    FAILED=1
else
    echo "   PASS: No CryptoProvider used as signature provider"
fi

echo ""
echo "=== Audit Complete ==="

if [ "$FAILED" -eq 1 ]; then
    echo "RESULT: FAILED - Fix the issues above before merging"
    exit 1
else
    echo "RESULT: PASSED - All P2P safety checks passed"
    exit 0
fi
