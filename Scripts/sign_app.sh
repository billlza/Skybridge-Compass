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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "${ROOT_DIR}/Scripts/notarytool_helpers.sh"
source "${ROOT_DIR}/Scripts/signing_entitlements_helpers.sh"
APP_PATH=${APP_PATH:-"${ROOT_DIR}/dist/SkyBridge Compass Pro.app"}
APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-"${ROOT_DIR}/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements"}
WIDGET_ENTITLEMENTS=${WIDGET_ENTITLEMENTS:-"${ROOT_DIR}/Sources/SkyBridgeCompassWidgets/SkyBridgeCompassWidgetsExtension.entitlements"}
NOTARIZE_APP=${NOTARIZE_APP:-0}
REQUIRE_NOTARIZATION=${REQUIRE_NOTARIZATION:-0}

if [[ ! -d "${APP_PATH}" ]]; then
  echo "错误：未找到 .app：${APP_PATH}。请先运行 Scripts/package_app.sh 完成打包。" >&2
  exit 1
fi

# 自动选择证书：优先 Developer ID，其次 Apple Development
function select_identity() {
  local dev_id
  local apple_dev
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  dev_id="$(printf '%s\n' "${identities}" | awk -F '"' '/Developer ID Application/ {print $2; exit}')"
  apple_dev="$(printf '%s\n' "${identities}" | awk -F '"' '/Apple Development/ {print $2; exit}')"
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

if [[ "${IDENTITY}" == "-" ]]; then
  log "使用 ad-hoc 签名"
else
  log "使用证书：${IDENTITY}"
fi

if [[ ! -f "${APP_ENTITLEMENTS}" ]]; then
  echo "错误：未找到主应用打包 entitlements：${APP_ENTITLEMENTS}" >&2
  exit 1
fi

SIGN_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-sign.XXXXXX")"
APP_INFO_PLIST="${APP_PATH}/Contents/Info.plist"
EMBEDDED_PROFILE_PATH="${APP_PATH}/Contents/embedded.provisionprofile"
ACTIVE_APP_ENTITLEMENTS="${SIGN_TMP_DIR}/SkyBridgeCompassApp.packaging.entitlements"

cleanup_sign_tmp() {
  rm -rf "${SIGN_TMP_DIR}"
}

trap cleanup_sign_tmp EXIT

skybridge_prepare_signing_entitlements \
  "${APP_ENTITLEMENTS}" \
  "${ACTIVE_APP_ENTITLEMENTS}" \
  "${APP_INFO_PLIST}" \
  "${EMBEDDED_PROFILE_PATH}"

APPLE_SIGN_IN_FEATURE_FLAG="$(skybridge_read_plist_bool "${APP_INFO_PLIST}" "SKYBRIDGE_ENABLE_APPLE_SIGN_IN" 2>/dev/null || echo "unknown")"
if [[ "${APPLE_SIGN_IN_FEATURE_FLAG}" == "1" ]]; then
  log "Apple 登录产品开关（SKYBRIDGE_ENABLE_APPLE_SIGN_IN）：开启"
elif [[ "${APPLE_SIGN_IN_FEATURE_FLAG}" == "0" ]]; then
  log "Apple 登录产品开关（SKYBRIDGE_ENABLE_APPLE_SIGN_IN）：关闭"
else
  log "Apple 登录产品开关（SKYBRIDGE_ENABLE_APPLE_SIGN_IN）：未配置"
fi

if [[ "${SKYBRIDGE_SIGNING_EFFECTIVE_NATIVE_APPLE_SIGN_IN:-0}" == "1" ]]; then
  log "原生 Apple 登录可用性（SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN）：可用"
else
  log "原生 Apple 登录可用性（SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN）：不可用"
fi

if [[ "${APPLE_SIGN_IN_FEATURE_FLAG}" == "1" && "${SKYBRIDGE_SIGNING_EFFECTIVE_NATIVE_APPLE_SIGN_IN:-0}" != "1" ]]; then
  log "Apple 登录产品功能仍保持开启，但当前签名产物不具备原生 Apple Sign In entitlement；运行时应走非原生方案"
fi

function codesign_target() {
  local target="$1"
  local entitlements="${2:-}"
  local -a args=(--force --sign "${IDENTITY}")

  if [[ "${IDENTITY}" != "-" ]]; then
    args+=(--options runtime --timestamp)
  fi
  if [[ -n "${entitlements}" ]]; then
    args+=(--entitlements "${entitlements}")
  fi

  codesign "${args[@]}" "${target}"
}

function sign_nested_code() {
  local frameworks_dir="${APP_PATH}/Contents/Frameworks"
  local plugins_dir="${APP_PATH}/Contents/PlugIns"
  local helpers_dir="${APP_PATH}/Contents/Library/LaunchDaemons"

  if [[ -d "${frameworks_dir}" ]]; then
    while IFS= read -r -d '' dylib; do
      codesign_target "${dylib}"
    done < <(find "${frameworks_dir}" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)

    while IFS= read -r -d '' framework; do
      codesign_target "${framework}"
    done < <(find "${frameworks_dir}" -type d -name "*.framework" -print0)
  fi

  if [[ -d "${helpers_dir}" ]]; then
    while IFS= read -r -d '' helper_bin; do
      codesign_target "${helper_bin}"
    done < <(find "${helpers_dir}" -type f -perm -111 -print0)
  fi

  if [[ -d "${plugins_dir}" ]]; then
    while IFS= read -r -d '' appex; do
      local appex_entitlements=""
      if [[ -f "${WIDGET_ENTITLEMENTS}" && "$(basename "${appex}")" == "SkyBridgeCompassWidgetsExtension.appex" ]]; then
        appex_entitlements="${WIDGET_ENTITLEMENTS}"
      fi
      codesign_target "${appex}" "${appex_entitlements}"
    done < <(find "${plugins_dir}" -type d -name "*.appex" -print0)
  fi
}

function notarize_app_bundle() {
  local temp_dir
  local zip_path

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-notary.XXXXXX")"
  zip_path="${temp_dir}/$(basename "${APP_PATH}").zip"

  log "打包 .app 为 notarization zip 归档"
  ditto -c -k --keepParent "${APP_PATH}" "${zip_path}"
  log "提交应用到 Apple notarization（notarytool）"
  skybridge_notarytool_submit_and_wait "${zip_path}"
  log "为应用附加 notarization ticket（stapler）"
  skybridge_staple_artifact "${APP_PATH}"
  rm -rf "${temp_dir}"
}

log "开始签名嵌入式代码"
sign_nested_code

log "开始签名主应用"
codesign_target "${APP_PATH}" "${ACTIVE_APP_ENTITLEMENTS}"

# 验证签名
log "验证签名完整性（codesign --verify --deep --strict）"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
log "签名信息："
codesign --display --verbose=2 "${APP_PATH}" | sed -n '1,20p'

if [[ "${NOTARIZE_APP}" == "1" ]]; then
  notarize_app_bundle
fi

log "Gatekeeper 评估（spctl --assess）"
GATEKEEPER_OUTPUT=""
if GATEKEEPER_OUTPUT="$(skybridge_assess_gatekeeper "${APP_PATH}" execute)"; then
  if skybridge_gatekeeper_is_notarized "${GATEKEEPER_OUTPUT}"; then
    log "Gatekeeper 评估通过（已 notarized）: ${GATEKEEPER_OUTPUT//$'\n'/ | }"
  else
    log "Gatekeeper 评估通过（已签名但未显式显示 notarized）: ${GATEKEEPER_OUTPUT//$'\n'/ | }"
  fi
else
  log "Gatekeeper 评估未通过: ${GATEKEEPER_OUTPUT//$'\n'/ | }"
fi

if [[ "${REQUIRE_NOTARIZATION}" == "1" ]] && ! skybridge_gatekeeper_is_notarized "${GATEKEEPER_OUTPUT}"; then
  echo "错误：当前签名产物尚未通过 notarization/stapling，无法满足 REQUIRE_NOTARIZATION=1。" >&2
  exit 1
fi

log "已完成正式签名配置：${APP_PATH}"
