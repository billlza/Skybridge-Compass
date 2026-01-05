#!/usr/bin/env zsh
set -euo pipefail

# 中文注释：
# 该脚本用于对已打包的 macOS 应用（.app）进行“正式签名”配置。
# 优先使用 Developer ID Application 证书，并开启 Hardened Runtime 与时间戳，满足后续 Notarization 要求。
# 如果未安装 Developer ID，则回退到 Apple Development 用于本机开发签名。
#
# 使用方法：
#   1) 确保已生成 .app：dist/SkyBridge Compass Pro.app
#   2) 执行：
#        zsh Scripts/sign_app.sh
#      或指定证书：
#        IDENTITY="Developer ID Application: Zi ang Li (YKUPL7Z869)" zsh Scripts/sign_app.sh
#
# 参数说明：
#   APP_PATH   要签名的 .app 路径，默认 dist/SkyBridge Compass Pro.app
#   IDENTITY   签名证书名称（可选，默认自动选择）

function log() {
  echo "[sign] $1"
}

ROOT_DIR=$(pwd)
APP_PATH=${APP_PATH:-"${ROOT_DIR}/dist/SkyBridge Compass Pro.app"}

if [[ ! -d "${APP_PATH}" ]]; then
  echo "错误：未找到 .app：${APP_PATH}。请先运行 Scripts/package_app.sh 完成打包。" >&2
  exit 1
fi

# 自动选择证书：优先 Developer ID，其次 Apple Development
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
    echo ""  # 未找到有效证书
  fi
}

IDENTITY=${IDENTITY:-"$(select_identity)"}
if [[ -z "${IDENTITY}" ]]; then
  echo "错误：未检测到有效的代码签名证书。请在钥匙串中安装 Developer ID 或 Apple Development 证书。" >&2
  exit 1
fi

log "使用证书：${IDENTITY}"

# 针对 Developer ID 开启 Hardened Runtime 与时间戳；开发证书也可使用这些选项
log "开始签名（深度签名，启用 Hardened Runtime）"
codesign --force --deep --sign "${IDENTITY}" --options runtime --timestamp "${APP_PATH}"

# 验证签名
log "验证签名完整性（codesign --verify --deep --strict）"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
log "签名信息："
codesign --display --verbose=2 "${APP_PATH}" | sed -n '1,20p'

# Gatekeeper 评估（未 notarize 的情况下可能显示被拒绝，但本机运行不受影响）
log "Gatekeeper 评估（spctl --assess）"
if spctl --assess --type execute --verbose "${APP_PATH}" >/dev/null 2>&1; then
  log "Gatekeeper 评估通过"
else
  log "Gatekeeper 评估未通过（通常需要 Notarization），开发阶段可忽略"
fi

log "已完成正式签名配置：${APP_PATH}"