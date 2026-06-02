#!/usr/bin/env bash
set -euo pipefail

# 中文注释：
# 该脚本用于在本机（Apple Silicon，macOS 14.0–26.0）从源码构建 FreeRDP 3.x 静态库，
# 并打包为 XCFramework，放置到 Sources/Vendor 目录，供 SwiftPM 作为二进制依赖引用。
# 构建完成后，可运行 enable_freerdp_xcframework_in_spm.sh 脚本切换 Package.swift 到二进制依赖。

# 默认参数（可根据需要调整）：
FREERDP_GIT_URL="https://github.com/FreeRDP/FreeRDP.git"
FREERDP_BRANCH="3.26.0"
DEPLOYMENT_TARGET="14.0"
ARCH="arm64"
BUILD_TYPE="Release"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$ROOT_DIR/Build/FreeRDP-xcframework"
SRC_DIR="$WORK_DIR/src"
BUILD_DIR_ARM64="$WORK_DIR/build-arm64"
VENDOR_DIR="$ROOT_DIR/Sources/Vendor"

echo "📦 准备构建 FreeRDP XCFramework (目标: macOS ${DEPLOYMENT_TARGET}, 架构: ${ARCH})"
echo "🔧 工作目录: $WORK_DIR"

# 依赖检查（尽量使用系统/本机已有工具）
command -v cmake >/dev/null 2>&1 || { echo "❌ 未找到 cmake，请先通过 Homebrew 安装：brew install cmake"; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "❌ 未找到 ninja，请先安装：brew install ninja"; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "❌ 未找到 xcodebuild，请安装 Xcode 或命令行工具"; exit 1; }

mkdir -p "$WORK_DIR" "$SRC_DIR" "$VENDOR_DIR"
rm -rf "$BUILD_DIR_ARM64"
mkdir -p "$BUILD_DIR_ARM64"
INC_DIR_FREERDP="$WORK_DIR/headers-freerdp"
INC_DIR_WINPR="$WORK_DIR/headers-winpr"
INC_DIR_FREERDP_CLIENT="$WORK_DIR/headers-freerdp-client"
rm -rf "$INC_DIR_FREERDP" "$INC_DIR_WINPR" "$INC_DIR_FREERDP_CLIENT"
mkdir -p "$INC_DIR_FREERDP" "$INC_DIR_WINPR" "$INC_DIR_FREERDP_CLIENT"
touch "$INC_DIR_FREERDP/freerdp_placeholder.h"
touch "$INC_DIR_WINPR/winpr_placeholder.h"
touch "$INC_DIR_FREERDP_CLIENT/freerdp_client_placeholder.h"

if [ ! -d "$SRC_DIR/FreeRDP" ]; then
  echo "⬇️ 克隆 FreeRDP 源码 (${FREERDP_BRANCH})"
  git clone --depth 1 --branch "$FREERDP_BRANCH" "$FREERDP_GIT_URL" "$SRC_DIR/FreeRDP"
else
  echo "🔁 已存在源码目录，跳过克隆"
fi

pushd "$SRC_DIR/FreeRDP" >/dev/null

echo "🏗️ 配置 CMake（静态库构建）"
cmake -S . -B "$BUILD_DIR_ARM64" -G Ninja \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
  -DCMAKE_C_FLAGS="-O3 -fno-lto" \
  -DCMAKE_CXX_FLAGS="-O3 -fno-lto" \
  -DBUILD_SHARED_LIBS=OFF \
  -DWITH_CLIENT=ON \
  -DWITH_CLIENT_SDL=OFF \
  -DWITH_CLIENT_MAC=OFF \
  -DWITH_SAMPLE=OFF \
  -DWITH_SERVER=OFF \
  -DWITH_X11=OFF \
  -DWITH_SDL=OFF \
  -DWITH_SDL2=OFF \
  -DWITH_SDL2_TTF=OFF \
  -DWITH_SDL_IMAGE_DIALOGS=OFF \
  -DWITH_ALSA=OFF \
  -DWITH_PULSE=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_OPENSSL=ON

echo "🔨 构建静态库"
cmake --build "$BUILD_DIR_ARM64" -j$(sysctl -n hw.ncpu)

LIB_FREERDP="$BUILD_DIR_ARM64/libfreerdp/libfreerdp3.a"
LIB_WINPR="$BUILD_DIR_ARM64/winpr/libwinpr/libwinpr3.a"
LIB_FREERDP_CLIENT="$BUILD_DIR_ARM64/client/common/libfreerdp-client3.a"

echo "🧱 发现产物："
ls -al "$BUILD_DIR_ARM64/libfreerdp" "$BUILD_DIR_ARM64/winpr/libwinpr" "$BUILD_DIR_ARM64/client/common" | sed -E 's/^/    /'

# 校验关键静态库是否存在
for f in "$LIB_FREERDP" "$LIB_WINPR" "$LIB_FREERDP_CLIENT"; do
  if [ ! -f "$f" ]; then
    echo "❌ 缺少 $(basename "$f")，请检查 CMake 选项或依赖是否完整"
    exit 1
  fi
done

echo "📚 生成 XCFramework（FreeRDP/WinPR/FreeRDPClient）"
rm -rf "$VENDOR_DIR/FreeRDP.xcframework" "$VENDOR_DIR/WinPR.xcframework" "$VENDOR_DIR/FreeRDPClient.xcframework"

# FreeRDP
xcodebuild -create-xcframework \
  -library "$LIB_FREERDP" -headers "$INC_DIR_FREERDP" \
  -output "$VENDOR_DIR/FreeRDP.xcframework"

# WinPR
xcodebuild -create-xcframework \
  -library "$LIB_WINPR" -headers "$INC_DIR_WINPR" \
  -output "$VENDOR_DIR/WinPR.xcframework"

# FreeRDPClient
xcodebuild -create-xcframework \
  -library "$LIB_FREERDP_CLIENT" -headers "$INC_DIR_FREERDP_CLIENT" \
  -output "$VENDOR_DIR/FreeRDPClient.xcframework"

echo "✅ XCFramework 已生成到：$VENDOR_DIR"
ls -al "$VENDOR_DIR" | sed -E 's/^/    /'

popd >/dev/null

cat <<EOF

使用说明：
- 1) 若你希望立即切换到 XCFramework 依赖，请执行：
     bash Scripts/enable_freerdp_xcframework_in_spm.sh

- 2) 切换完成后，运行：
     swift build

备注：
- 构建目标已锁定为 macOS ${DEPLOYMENT_TARGET} / ${ARCH}，不会影响运行时性能；
- 仍可在 macOS 26.x 上运行，避免“链接到更高版本构建”告警；
- 该脚本仅构建客户端所需的三大静态库，其他可选特性已关闭以缩短构建时间。
EOF
