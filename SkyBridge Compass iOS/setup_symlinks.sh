#!/bin/bash

# SkyBridge Compass iOS - 符号链接设置脚本
# 创建到 macOS 项目 SkyBridgeCore 的符号链接

set -e

echo "🔗 SkyBridge Compass iOS - 设置符号链接"
echo "========================================="

# 项目根目录
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

# macOS 项目路径
MACOS_PROJECT="../SkyBridge Compass Pro release"

# 检查 macOS 项目是否存在
if [ ! -d "$MACOS_PROJECT" ]; then
    echo "❌ 错误: 找不到 macOS 项目"
    echo "   预期位置: $MACOS_PROJECT"
    echo ""
    echo "请确保 macOS 版本在正确的位置，或修改此脚本中的路径。"
    exit 1
fi

echo "✅ 找到 macOS 项目: $MACOS_PROJECT"

# 创建 Shared 目录
mkdir -p Shared

# 删除旧的符号链接（如果存在）
if [ -L "Shared/SkyBridgeCore" ] || [ -d "Shared/SkyBridgeCore" ]; then
    echo "🗑️  删除旧的 SkyBridgeCore 链接..."
    rm -rf Shared/SkyBridgeCore
fi

# 创建符号链接
echo "🔗 创建符号链接到 SkyBridgeCore..."
ln -s "../../SkyBridge Compass Pro release/Sources/SkyBridgeCore" "Shared/SkyBridgeCore"

# 验证符号链接
if [ -L "Shared/SkyBridgeCore" ]; then
    echo "✅ 符号链接创建成功!"
    echo ""
    echo "链接详情:"
    ls -lh Shared/SkyBridgeCore
    echo ""
    echo "✨ 设置完成！现在可以在 Xcode 中打开项目了。"
    echo ""
    echo "下一步:"
    echo "  1. 运行: open Package.swift"
    echo "  2. 或者: open SkyBridgeCompassiOS.xcodeproj (如果已生成)"
else
    echo "❌ 错误: 符号链接创建失败"
    exit 1
fi
