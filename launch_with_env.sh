#!/bin/bash

# SkyBridge Compass 启动脚本
# 确保环境变量正确加载

echo "🚀 启动 SkyBridge Compass Pro..."

# 加载环境变量
source ~/.zprofile

# 验证环境变量（不输出明文密钥）
echo "📡 Supabase 配置检查:"
echo "   URL: ${SUPABASE_URL:-<unset>}"
if [ -n "$SUPABASE_ANON_KEY" ]; then
  echo "   Key: <set>"
else
  echo "   Key: <unset>"
fi

# 切换到项目目录（脚本所在路径）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 清理旧的构建
echo "🧹 清理旧构建..."
rm -rf .build

# 使用环境变量运行应用（避免在脚本中硬编码密钥）
echo "▶️  启动应用..."
swift run SkyBridgeCompassApp
