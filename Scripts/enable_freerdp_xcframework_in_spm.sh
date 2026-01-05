#!/usr/bin/env bash
set -euo pipefail

# 中文注释：
# 该脚本会在检测到 Sources/Vendor 下已存在 FreeRDP/WinPR/FreeRDPClient.xcframework 后，
# 自动修改 Package.swift，将原本通过 Homebrew 动态库链接的配置切换为二进制 XCFramework 依赖。
# 变更是可逆的（会备份原始 Package.swift 到 Package.swift.bak）。

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PKG_FILE="$ROOT_DIR/Package.swift"
BACKUP_FILE="$ROOT_DIR/Package.swift.bak"
VENDOR_DIR="$ROOT_DIR/Sources/Vendor"

for f in FreeRDP.xcframework WinPR.xcframework FreeRDPClient.xcframework; do
  if [ ! -d "$VENDOR_DIR/$f" ]; then
    echo "❌ 未检测到 $f，请先运行 Scripts/build_freerdp_xcframework.sh"
    exit 1
  fi
done

echo "📝 备份 Package.swift -> $BACKUP_FILE"
cp "$PKG_FILE" "$BACKUP_FILE"

echo "🔧 注入 XCFramework 二进制目标定义"

# 在 targets 数组中追加三个 binaryTarget 定义（若已存在则跳过）
if ! grep -q 'name: "FreeRDP"' "$PKG_FILE"; then
  perl -0777 -pe "s/targets:\s*\[/targets: [\n        .binaryTarget(\n            name: \"FreeRDP\",\n            path: \"Sources\/Vendor\/FreeRDP.xcframework\"\n        ),\n        .binaryTarget(\n            name: \"WinPR\",\n            path: \"Sources\/Vendor\/WinPR.xcframework\"\n        ),\n        .binaryTarget(\n            name: \"FreeRDPClient\",\n            path: \"Sources\/Vendor\/FreeRDPClient.xcframework\"\n        ),\n/" -i "$PKG_FILE"
fi

echo "🔧 切换 FreeRDPBridge 目标到二进制依赖"

# 替换 FreeRDPBridge 目标的链接设置：移除 -L/-l 选项，改为依赖 XCFramework
perl -0777 -pe 's/(name:\s*"FreeRDPBridge"[\s\S]*?dependencies:\s*\[)[\s\S]*?(\],)/$1 WinPR, FreeRDP, FreeRDPClient $2/;' -i "$PKG_FILE"
perl -0777 -pe 's/(name:\s*"FreeRDPBridge"[\s\S]*?linkerSettings:\s*\[)[\s\S]*?(\],)/$1 .linkedFramework("CoreGraphics"), .linkedFramework("CoreVideo"), .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia") $2/;' -i "$PKG_FILE"

# 移除原先的 unsafeFlags -L/-l 配置（只删除 FreeRDPBridge 区域内）
perl -0777 -pe 's/\s*\.unsafeFlags\([\s\S]*?\)\s*\n//g' -i "$PKG_FILE"

echo "✅ Package.swift 已切换为 XCFramework 依赖。你可以运行：swift build"