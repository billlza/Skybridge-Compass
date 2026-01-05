#!/bin/bash

# SkyBridge Compass 启动脚本
# 确保环境变量正确加载

echo "🚀 启动 SkyBridge Compass Pro..."

# 加载环境变量
source ~/.zprofile

# 验证环境变量
echo "📡 Supabase 配置检查:"
echo "   URL: $SUPABASE_URL"
echo "   Key: ${SUPABASE_ANON_KEY:0:50}..."

# 切换到项目目录
cd "/Users/bill/Desktop/SkyBridge Compass Pro release"

# 清理旧的构建
echo "🧹 清理旧构建..."
rm -rf .build

# 使用环境变量运行应用
echo "▶️  启动应用..."
SUPABASE_URL="https://hloqytmhjludmuhwyyzb.supabase.co" \
SUPABASE_ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb3F5dG1oamx1ZG11aHd5eXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUzNTE3ODUsImV4cCI6MjA3MDkyNzc4NX0.xmDCgBo5IpDlzIerIz7y2jruh34MEYrtcepeK3x_HT0" \
swift run SkyBridgeCompassApp
