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

# 1. precondition/fatalError 必须为 0（允许已评审的局部类型不变量）
echo "1. Checking for precondition/fatalError in P2P directory..."
PRECONDITION_VIOLATIONS=$(grep -rE "precondition\(|fatalError\(" "$P2P_DIR" 2>/dev/null | grep -v "// ALLOWED" || true)
PRECONDITION_VIOLATIONS=$(echo "$PRECONDITION_VIOLATIONS" | grep -vE "CryptoProviderProtocol\\.swift:.*precondition\\(publicKey\\.(suite|usage) == privateKey\\.(suite|usage)," || true)
PRECONDITION_COUNT=$(echo "$PRECONDITION_VIOLATIONS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')

if [ "$PRECONDITION_COUNT" -gt 0 ]; then
    echo "   FAIL: Found $PRECONDITION_COUNT precondition/fatalError in P2P directory"
    echo "   Details:"
    echo "$PRECONDITION_VIOLATIONS" | sed '/^[[:space:]]*$/d' | sed 's/^/      /'
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
SIGNATURE_PROVIDER_VIOLATIONS=$(echo "$SIGNATURE_PROVIDER_VIOLATIONS" | grep -vE "Sources/SkyBridgeCore/P2P/(HandshakeDriver|HandshakeContext|TwoAttemptHandshakeManager)\\.swift:" || true)
SIGNATURE_PROVIDER_VIOLATIONS=$(echo "$SIGNATURE_PROVIDER_VIOLATIONS" | grep -vE ":[[:digit:]]+:[[:space:]]*(public|private|internal)?[[:space:]]*(let|var)[[:space:]]+signatureProvider:" || true)
SIGNATURE_PROVIDER_VIOLATIONS=$(echo "$SIGNATURE_PROVIDER_VIOLATIONS" | grep -vE ":[[:digit:]]+:[[:space:]]*///" || true)

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
echo "4. Checking unknown/unsupported suite fallback deny gate..."
if ! python3 Scripts/check_unknown_suite_fallback_gate.py; then
    echo "   FAIL: unknown/unsupported suite fallback deny gate failed"
    FAILED=1
else
    echo "   PASS: unknown/unsupported suite fallback deny gate passed"
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
