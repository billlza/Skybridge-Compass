#!/usr/bin/env zsh
set -euo pipefail

# 中文注释：
# 该脚本用于将 SwiftPM/Xcode 构建得到的可执行产物与资源封装为标准的 macOS 应用（.app）。
# 满足最低系统版本 macOS 14.0，针对 Apple Silicon（ARM64）进行优化，并使用最新 API。
#
# 使用方法：
# 1) 先确保在项目根目录运行过 Release 构建：
#    xcodebuild -workspace .swiftpm/xcode/package.xcworkspace \
#               -scheme SkyBridgeCompassApp \
#               -configuration Release -destination 'platform=macOS,arch=arm64' \
#               -derivedDataPath .build/xcode build
# 2) 运行本脚本：
#    Scripts/package_app.sh
# 3) 生成的 .app 会位于 dist/SkyBridge\ Compass\ Pro.app
#
# 注意：脚本优先使用 Developer ID / Apple Development 证书签名；
# 若本机无可用证书则回退 ad-hoc（此时特权 Helper 安装可能失败）。

function log() {
  echo "[package] $1"
}

function select_identity() {
  local dev_id
  local apple_dev
  dev_id=$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ {print $2; exit}')
  apple_dev=$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development/ {print $2; exit}')
  if [[ -n "${dev_id}" ]]; then
    echo "${dev_id}"
  elif [[ -n "${apple_dev}" ]]; then
    echo "${apple_dev}"
  else
    echo ""
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${ROOT_DIR}/.build/xcode/Build/Products/Release"
APP_NAME="SkyBridge Compass Pro.app"
APP_DIR="${ROOT_DIR}/dist/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RES_DIR="${CONTENTS_DIR}/Resources"
FW_DIR="${CONTENTS_DIR}/Frameworks"
SIGN_IDENTITY="${IDENTITY:-$(select_identity)}"
SKIP_BUILD="${SKIP_BUILD:-0}"
BUILD_DESTINATION="${BUILD_DESTINATION:-platform=macOS,arch=arm64}"

# 中文注释：可执行文件与资源 bundle 名称（来自 Xcode 构建输出）
EXECUTABLE="SkyBridgeCompassApp"

if [[ "${SKIP_BUILD}" != "1" ]]; then
  log "执行 Release 构建，确保打包包含最新代码"
  SDK_VER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "")"
  SDK_MAJOR="$(echo "$SDK_VER" | awk -F. '{print $1}')"
  if [[ -n "$SDK_MAJOR" && "$SDK_MAJOR" -ge 26 ]]; then
    export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
    log "检测到 macOS SDK ${SDK_VER}（>=26），启用 Apple PQC 编译条件"
  else
    unset SKYBRIDGE_ENABLE_APPLE_PQC_SDK
    log "未检测到 macOS SDK 26+（当前: ${SDK_VER:-unknown}），禁用 Apple PQC 编译条件"
  fi

  xcodebuild -workspace "${ROOT_DIR}/.swiftpm/xcode/package.xcworkspace" \
             -scheme SkyBridgeCompassApp \
             -configuration Release \
             -destination "${BUILD_DESTINATION}" \
             -derivedDataPath "${ROOT_DIR}/.build/xcode" \
             build
else
  log "按 SKIP_BUILD=1 跳过构建，直接复用已有产物"
fi

# 校验构建产物是否存在
if [[ ! -x "${BUILD_DIR}/${EXECUTABLE}" ]]; then
  echo "错误：未找到可执行文件 ${BUILD_DIR}/${EXECUTABLE}。请先完成 Release 构建。" >&2
  exit 1
fi

log "清理旧的 dist 目录并创建 .app 结构"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}" "${FW_DIR}"

log "拷贝 Info.plist 到 .app/Contents/"
INFO_PLIST_SRC="${ROOT_DIR}/Sources/SkyBridgeCompassApp/Info.plist"
INFO_PLIST_DST="${CONTENTS_DIR}/Info.plist"
cp "${INFO_PLIST_SRC}" "${INFO_PLIST_DST}"

log "拷贝可执行文件到 .app/Contents/MacOS/"
cp "${BUILD_DIR}/${EXECUTABLE}" "${MACOS_DIR}/${EXECUTABLE}"
chmod +x "${MACOS_DIR}/${EXECUTABLE}"

log "拷贝运行时 Frameworks 到 .app/Contents/Frameworks/"
found_framework=0
for framework in "${BUILD_DIR}"/*.framework; do
  [[ -d "${framework}" ]] || continue
  found_framework=1
  name="$(basename "${framework}")"
  rm -rf "${FW_DIR}/${name}"
  cp -R "${framework}" "${FW_DIR}/"
done
if [[ "${found_framework}" -eq 0 ]]; then
  log "未找到 .framework 产物（若运行时报 dyld 缺失，请检查构建产物）"
fi

# 确保可执行文件包含 Frameworks rpath（用于加载 @rpath/*.framework）
APP_BIN="${MACOS_DIR}/${EXECUTABLE}"
if otool -l "${APP_BIN}" 2>/dev/null | grep -q "@executable_path/../Frameworks"; then
  log "已存在 rpath: @executable_path/../Frameworks"
else
  log "注入 rpath: @executable_path/../Frameworks"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP_BIN}" 2>/dev/null || true
fi

log "拷贝 Swift 运行时 dylib 到 .app/Contents/Frameworks/（Xcode 26+/Swift 6.2 工具链）"
# 说明：在部分 Xcode/toolchain 下 --unsigned-destination 行为异常，这里使用 --destination。
if xcrun -f swift-stdlib-tool >/dev/null 2>&1; then
  xcrun swift-stdlib-tool --copy --verbose \
    --platform macosx \
    --scan-executable "${APP_BIN}" \
    --destination "${FW_DIR}" \
    >/dev/null 2>&1 || {
      log "swift-stdlib-tool 执行失败（开发阶段可忽略，但发布包可能缺 Swift dylib）"
    }
else
  log "未找到 swift-stdlib-tool，跳过 Swift dylib 拷贝"
fi

log "拷贝构建产物中的资源 bundle 到 .app/Contents/Resources/"
found_bundle=0
for bundle in "${BUILD_DIR}"/*.bundle; do
  [[ -d "${bundle}" ]] || continue
  found_bundle=1
  cp -R "${bundle}" "${RES_DIR}/"
done
if [[ "${found_bundle}" -eq 0 ]]; then
  log "未发现 .bundle 资源产物"
fi

# 额外拷贝源资源目录（如 AppIcon），以确保非打进 bundle 的静态资源也可用
SRC_RES_DIR="${ROOT_DIR}/Sources/SkyBridgeCompassApp/Resources"
if [[ -d "${SRC_RES_DIR}" ]]; then
  log "拷贝源资源目录 Resources 到 .app/Contents/Resources/"
  cp -R "${SRC_RES_DIR}/"* "${RES_DIR}/" 2>/dev/null || true
fi

# 使用 plutil 注入/修正必要的关键键值
log "校验并修正 Info.plist 关键键值"
plutil -replace CFBundleExecutable -string "${EXECUTABLE}" "${INFO_PLIST_DST}"
plutil -replace CFBundlePackageType -string "APPL" "${INFO_PLIST_DST}"
plutil -replace LSMinimumSystemVersion -string "14.0" "${INFO_PLIST_DST}"

# 移除可能不需要的主 storyboard 键（SwiftUI App 生命周期无需该键）
if /usr/libexec/PlistBuddy -c 'Print :NSMainStoryboardFile' "${INFO_PLIST_DST}" >/dev/null 2>&1; then
  log "移除 NSMainStoryboardFile（SwiftUI App 不使用 storyboard）"
  /usr/libexec/PlistBuddy -c 'Delete :NSMainStoryboardFile' "${INFO_PLIST_DST}" || true
fi

# 生成 PkgInfo（现代系统可选，但保留兼容性）
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# ========== PowerMetricsHelper 打包 ==========
# SMAppService.daemon 需要 plist 文件位于 Contents/Library/LaunchDaemons/
HELPER_NAME="com.skybridge.PowerMetricsHelper"
HELPER_EXECUTABLE="PowerMetricsHelper"
HELPER_SRC_DIR="${ROOT_DIR}/Sources/PowerMetricsHelper"
HELPER_DST_DIR="${CONTENTS_DIR}/Library/LaunchDaemons/${HELPER_NAME}"
HELPER_BIN_PATH="${BUILD_DIR}/${HELPER_EXECUTABLE}"

# 某些构建路径只会产出主 App，可在这里补构建 Helper
if [[ ! -x "${HELPER_BIN_PATH}" ]]; then
  log "未检测到 PowerMetricsHelper，尝试单独构建..."
  if xcodebuild -workspace .swiftpm/xcode/package.xcworkspace \
                -scheme "${HELPER_EXECUTABLE}" \
                -configuration Release \
                -destination 'platform=macOS' \
                -derivedDataPath "${ROOT_DIR}/.build/xcode" \
                build >/dev/null 2>&1; then
    log "PowerMetricsHelper 构建完成"
  else
    log "PowerMetricsHelper 构建失败，将继续打包主应用（高级监控功能不可用）"
  fi
fi

# 检查 Helper 可执行文件是否存在
if [[ -x "${HELPER_BIN_PATH}" ]]; then
  log "打包 PowerMetricsHelper 到 .app/Contents/Library/LaunchDaemons/"
  mkdir -p "${HELPER_DST_DIR}"
  
  # 拷贝 Helper 可执行文件（重命名为 plist 中指定的名称）
  cp "${HELPER_BIN_PATH}" "${HELPER_DST_DIR}/${HELPER_NAME}"
  chmod +x "${HELPER_DST_DIR}/${HELPER_NAME}"
  
  # 拷贝 launchd plist 文件到 LaunchDaemons 目录
  cp "${HELPER_SRC_DIR}/${HELPER_NAME}.plist" "${CONTENTS_DIR}/Library/LaunchDaemons/"
  
  # 拷贝 Info.plist 到 Helper bundle 目录
  cp "${HELPER_SRC_DIR}/Info.plist" "${HELPER_DST_DIR}/"

  # Helper bundle 在 LaunchDaemons 目录，需显式签名，否则主 App 深度签名可能不会覆盖到它
  if [[ -n "${SIGN_IDENTITY}" ]]; then
    codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${HELPER_DST_DIR}" >/dev/null 2>&1 || {
      log "警告：Helper 显式签名失败，后续将依赖主 App 深度签名"
    }
  fi
  
  log "PowerMetricsHelper 打包完成"
else
  log "跳过 PowerMetricsHelper（未找到可执行文件：${HELPER_BIN_PATH}）"
fi

# 优先使用正式证书签名；未配置证书时回退 ad-hoc
if [[ -n "${SIGN_IDENTITY}" ]]; then
  log "使用证书签名：${SIGN_IDENTITY}"
  codesign --force --deep --sign "${SIGN_IDENTITY}" --options runtime --timestamp "${APP_DIR}" >/dev/null 2>&1 || {
    echo "警告：证书签名失败，回退 ad-hoc 签名。" >&2
    codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || {
      echo "警告：codesign 签名失败，但可在开发机上运行（未 notarize）。" >&2
    }
  }
else
  log "未检测到可用证书，使用 ad-hoc 签名"
  codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || {
    echo "警告：codesign 签名失败，但可在开发机上运行（未 notarize）。" >&2
  }
fi

# 验证签名（非强制）
if codesign --verify --deep --strict --verbose=2 "${APP_DIR}" >/dev/null 2>&1; then
  log "签名验证通过"
else
  log "签名验证未通过（开发阶段可忽略）"
fi

log "完成打包：${APP_DIR}"
log "可直接双击运行或使用：open '${APP_DIR}'"
