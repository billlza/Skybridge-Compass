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
# 注意：脚本使用临时 ad-hoc 签名用于本机验证。后续可替换为正式团队证书并进行 Notarization。

function log() {
  echo "[package] $1"
}

ROOT_DIR=$(pwd)
BUILD_DIR="${ROOT_DIR}/.build/xcode/Build/Products/Release"
APP_NAME="SkyBridge Compass Pro.app"
APP_DIR="${ROOT_DIR}/dist/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RES_DIR="${CONTENTS_DIR}/Resources"
FW_DIR="${CONTENTS_DIR}/Frameworks"

# 中文注释：可执行文件与资源 bundle 名称（来自 Xcode 构建输出）
EXECUTABLE="SkyBridgeCompassApp"
SPM_RES_APP_BUNDLE="SkyBridgeCompassApp_SkyBridgeCompassApp.bundle"
SPM_RES_CORE_BUNDLE="SkyBridgeCompassApp_SkyBridgeCore.bundle"
CRYPTO_BUNDLE="swift-crypto_Crypto.bundle"
NIOPOSIX_BUNDLE="swift-nio_NIOPosix.bundle"

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

log "拷贝运行时 Frameworks（例如 WebRTC.framework）到 .app/Contents/Frameworks/"
if [[ -d "${BUILD_DIR}/WebRTC.framework" ]]; then
  rm -rf "${FW_DIR}/WebRTC.framework"
  cp -R "${BUILD_DIR}/WebRTC.framework" "${FW_DIR}/"
else
  log "未找到 WebRTC.framework（若运行时报 dyld 缺失，请检查构建产物）"
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

log "拷贝 SwiftPM 资源 bundle 到 .app/Contents/Resources/"
for bundle in "${SPM_RES_APP_BUNDLE}" "${SPM_RES_CORE_BUNDLE}" "${CRYPTO_BUNDLE}" "${NIOPOSIX_BUNDLE}"; do
  if [[ -d "${BUILD_DIR}/${bundle}" ]]; then
    cp -R "${BUILD_DIR}/${bundle}" "${RES_DIR}/"
  else
    log "跳过不存在的资源：${bundle}"
  fi
done

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

# 检查 Helper 可执行文件是否存在
if [[ -x "${BUILD_DIR}/${HELPER_EXECUTABLE}" ]]; then
  log "打包 PowerMetricsHelper 到 .app/Contents/Library/LaunchDaemons/"
  mkdir -p "${HELPER_DST_DIR}"
  
  # 拷贝 Helper 可执行文件（重命名为 plist 中指定的名称）
  cp "${BUILD_DIR}/${HELPER_EXECUTABLE}" "${HELPER_DST_DIR}/${HELPER_NAME}"
  chmod +x "${HELPER_DST_DIR}/${HELPER_NAME}"
  
  # 拷贝 launchd plist 文件到 LaunchDaemons 目录
  cp "${HELPER_SRC_DIR}/${HELPER_NAME}.plist" "${CONTENTS_DIR}/Library/LaunchDaemons/"
  
  # 拷贝 Info.plist 到 Helper bundle 目录
  cp "${HELPER_SRC_DIR}/Info.plist" "${HELPER_DST_DIR}/"
  
  log "PowerMetricsHelper 打包完成"
else
  log "跳过 PowerMetricsHelper（未找到可执行文件：${BUILD_DIR}/${HELPER_EXECUTABLE}）"
fi

# 临时 ad-hoc 签名（包含深度资源）
log "进行 ad-hoc 签名（深度签名）"
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || {
  echo "警告：codesign 签名失败，但可在开发机上运行（未 notarize）。" >&2
}

# 验证签名（非强制）
if codesign --verify --deep --strict --verbose=2 "${APP_DIR}" >/dev/null 2>&1; then
  log "签名验证通过"
else
  log "签名验证未通过（开发阶段可忽略）"
fi

log "完成打包：${APP_DIR}"
log "可直接双击运行或使用：open '${APP_DIR}'"
