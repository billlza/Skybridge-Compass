#!/usr/bin/env zsh
set -euo pipefail

# =============================================================================
# CI Deprecation Check Script
# SkyBridge Compass - Tech Debt Cleanup
# =============================================================================
#
# 该脚本用于 CI 环境中检查内部模块对 deprecated API 的使用情况。
# 
# 功能：
# 1. 扫描源代码中的 @available(*, deprecated) 标记
# 2. 检查内部模块是否调用了 deprecated API
# 3. 可选：将 deprecated warnings 视为 errors（--strict 模式）
#
# 使用方法：
#   Scripts/ci_deprecation_check.sh [--strict]
#
# 参数：
#   --strict    将 deprecated warnings 视为 errors，发现使用则返回非零退出码
#
# Requirements: 11.2
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
STRICT_MODE=false

# 解析参数
for arg in "$@"; do
    case $arg in
        --strict)
            STRICT_MODE=true
            shift
            ;;
        *)
            ;;
    esac
done

function log_info() {
    echo "[INFO] $1"
}

function log_warn() {
    echo "[WARN] ⚠️  $1"
}

function log_error() {
    echo "[ERROR] ❌ $1"
}

function log_success() {
    echo "[OK] ✅ $1"
}

# =============================================================================
# 1. 收集所有 deprecated API 声明
# =============================================================================

log_info "扫描 deprecated API 声明..."

DEPRECATED_APIS=()

# 扫描 @available(*, deprecated) 标记
while IFS= read -r line; do
    # 提取文件路径和行号
    file_path=$(echo "$line" | cut -d: -f1)
    line_num=$(echo "$line" | cut -d: -f2)
    
    # 获取下一行（通常是函数/类型声明）
    next_line=$(sed -n "$((line_num + 1))p" "$file_path" 2>/dev/null || echo "")
    
    # 提取 API 名称（简化处理）
    api_name=$(echo "$next_line" | grep -oE '(func|class|struct|enum|var|let|typealias)\s+\w+' | head -1 || echo "unknown")
    
    if [[ -n "$api_name" ]]; then
        DEPRECATED_APIS+=("$file_path:$line_num - $api_name")
    fi
done < <(grep -rn '@available.*deprecated' "$ROOT_DIR/Sources" 2>/dev/null || true)

log_info "发现 ${#DEPRECATED_APIS[@]} 个 deprecated API 声明"

# =============================================================================
# 2. 检查内部模块对 deprecated API 的调用
# =============================================================================

log_info "检查内部模块对 deprecated API 的调用..."

# 已知的 deprecated API 列表（从 DeviceTypes.swift 兼容桥）
KNOWN_DEPRECATED_APIS=(
    "EnhancedDeviceDiscovery"
    "DeviceTypesHardwareRemoteController"
    "DeviceTypesSecurityManager"
    "parseBonjourTXT"
    "parseTXTRecord"
    "RuleEngineBackend"
    "CoreMLBackend"
)

VIOLATIONS=()
VIOLATION_COUNT=0

for api in "${KNOWN_DEPRECATED_APIS[@]}"; do
    # 搜索内部模块中的使用（排除声明文件本身和测试文件）
    while IFS= read -r usage; do
        # 排除 deprecated 声明本身
        if echo "$usage" | grep -q '@available.*deprecated'; then
            continue
        fi
        # 排除注释（包括中文注释）
        if echo "$usage" | grep -qE '^\s*//|已弃用|已废弃'; then
            continue
        fi
        # 排除 DeprecationTracker 记录调用
        if echo "$usage" | grep -q 'DeprecationTracker'; then
            continue
        fi
        # 排除 struct/class/func 声明行（这些是定义，不是使用）
        if echo "$usage" | grep -qE '(struct|class|func|typealias)\s+'"${api}"; then
            continue
        fi
        # 排除 api: "xxx" 字符串字面量（DeprecationTracker 参数）
        if echo "$usage" | grep -qE 'api:\s*"'"${api}"'"'; then
            continue
        fi
        
        VIOLATIONS+=("$usage")
        ((VIOLATION_COUNT++))
    done < <(grep -rn "\b${api}\b" "$ROOT_DIR/Sources/SkyBridgeCore" 2>/dev/null | grep -v 'DeviceTypes.swift' | grep -v 'DeprecationTracker.swift' || true)
done

# =============================================================================
# 3. 输出结果
# =============================================================================

echo ""
echo "=============================================="
echo "  Deprecated API Usage Report"
echo "=============================================="
echo ""

if [[ ${#DEPRECATED_APIS[@]} -gt 0 ]]; then
    echo "📋 Deprecated API 声明:"
    for api in "${DEPRECATED_APIS[@]}"; do
        echo "   - $api"
    done
    echo ""
fi

if [[ $VIOLATION_COUNT -gt 0 ]]; then
    log_warn "发现 $VIOLATION_COUNT 处内部模块对 deprecated API 的调用:"
    echo ""
    for violation in "${VIOLATIONS[@]}"; do
        echo "   ⚠️  $violation"
    done
    echo ""
    
    if [[ "$STRICT_MODE" == "true" ]]; then
        log_error "Strict 模式：deprecated API 使用被视为错误"
        echo ""
        echo "请迁移到新 API："
        echo "  - EnhancedDeviceDiscovery → DeviceDiscoveryService.shared"
        echo "  - DeviceTypesHardwareRemoteController → HardwareRemoteController"
        echo "  - DeviceTypesSecurityManager → DeviceSecurityManager"
        echo "  - parseBonjourTXT/parseTXTRecord → BonjourTXTParser"
        echo "  - RuleEngineBackend → EnhancedRuleEngineBackend"
        echo "  - CoreMLBackend → CoreMLWeatherBackend"
        echo ""
        exit 1
    fi
else
    log_success "内部模块未发现 deprecated API 调用"
fi

echo ""
echo "=============================================="
echo "  检查完成"
echo "=============================================="

exit 0
