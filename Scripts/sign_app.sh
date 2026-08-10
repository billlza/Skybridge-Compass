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
APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-""}
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

SIGN_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-sign.XXXXXX")"
APP_INFO_PLIST="${APP_PATH}/Contents/Info.plist"
EMBEDDED_PROFILE_PATH="${APP_PATH}/Contents/embedded.provisionprofile"
ACTIVE_APP_ENTITLEMENTS="${SIGN_TMP_DIR}/SkyBridgeCompassApp.packaging.entitlements"
PLUGINS_DIR="${APP_PATH}/Contents/PlugIns"
WIDGET_APPEX_PATH="${PLUGINS_DIR}/SkyBridgeCompassWidgetsExtension.appex"
WIDGET_INFO_PLIST="${WIDGET_APPEX_PATH}/Contents/Info.plist"
WIDGET_PROFILE_PATH="${WIDGET_APPEX_PATH}/Contents/embedded.provisionprofile"
ACTIVE_WIDGET_ENTITLEMENTS="${SIGN_TMP_DIR}/SkyBridgeCompassWidgetsExtension.entitlements"

cleanup_sign_tmp() {
  rm -rf "${SIGN_TMP_DIR}"
}

trap cleanup_sign_tmp EXIT

if [[ -z "${APP_ENTITLEMENTS}" ]]; then
  REQUIRED_APPLE_SIGN_IN_MODE="$(skybridge_resolve_required_apple_sign_in_mode 2>/dev/null || echo auto)"
  BUNDLED_APPLE_SIGN_IN_MODE="$(skybridge_read_plist_string "${APP_INFO_PLIST}" "SKYBRIDGE_APPLE_SIGN_IN_MODE" 2>/dev/null || true)"

  if [[ "${REQUIRED_APPLE_SIGN_IN_MODE}" == "auto" && -n "${BUNDLED_APPLE_SIGN_IN_MODE}" ]]; then
    REQUIRED_APPLE_SIGN_IN_MODE="${BUNDLED_APPLE_SIGN_IN_MODE}"
  fi

  APP_ENTITLEMENTS="$(skybridge_default_app_packaging_entitlements_path "${ROOT_DIR}" "${REQUIRED_APPLE_SIGN_IN_MODE}")"
fi

if [[ ! -f "${APP_ENTITLEMENTS}" ]]; then
  echo "错误：未找到主应用打包 entitlements：${APP_ENTITLEMENTS}" >&2
  exit 1
fi

if skybridge_entitlements_request_application_groups "${APP_ENTITLEMENTS}" && \
   [[ -z "${SKYBRIDGE_REQUIRE_APP_GROUPS+x}" ]]; then
  export SKYBRIDGE_REQUIRE_APP_GROUPS=1
  log "正式签名默认要求 App Groups entitlement 被 provisioning profile 覆盖；如需显式允许降级，请设置 SKYBRIDGE_REQUIRE_APP_GROUPS=0"
fi

skybridge_prepare_signing_entitlements \
  "${APP_ENTITLEMENTS}" \
  "${ACTIVE_APP_ENTITLEMENTS}" \
  "${APP_INFO_PLIST}" \
  "${EMBEDDED_PROFILE_PATH}"

if [[ -f "${EMBEDDED_PROFILE_PATH}" ]] && \
   ! skybridge_profile_supports_requested_profile_backed_entitlements \
     "${EMBEDDED_PROFILE_PATH}" \
     "${ACTIVE_APP_ENTITLEMENTS}"; then
  echo "错误：embedded.provisionprofile 不覆盖最终签名 entitlements，禁止生成会被 AMFI 拒绝启动的 App。" >&2
  exit 1
fi

APPLE_SIGN_IN_FEATURE_FLAG="$(skybridge_read_plist_bool "${APP_INFO_PLIST}" "SKYBRIDGE_ENABLE_APPLE_SIGN_IN" 2>/dev/null || echo "unknown")"
APPLE_SIGN_IN_MODE="$(skybridge_read_plist_string "${APP_INFO_PLIST}" "SKYBRIDGE_APPLE_SIGN_IN_MODE" 2>/dev/null || echo "unknown")"
if [[ "${APPLE_SIGN_IN_FEATURE_FLAG}" == "1" ]]; then
  log "Apple 登录产品开关（SKYBRIDGE_ENABLE_APPLE_SIGN_IN）：开启"
elif [[ "${APPLE_SIGN_IN_FEATURE_FLAG}" == "0" ]]; then
  log "Apple 登录产品开关（SKYBRIDGE_ENABLE_APPLE_SIGN_IN）：关闭"
else
  log "Apple 登录产品开关（SKYBRIDGE_ENABLE_APPLE_SIGN_IN）：未配置"
fi

case "${APPLE_SIGN_IN_MODE}" in
  native)
    log "Apple 登录运行模式：native（AuthenticationServices 原生授权）"
    ;;
  web_session)
    log "Apple 登录运行模式：web_session（ASWebAuthenticationSession 安全网页授权）"
    ;;
  disabled)
    log "Apple 登录运行模式：disabled（登录入口关闭）"
    ;;
  *)
    log "Apple 登录运行模式：未知"
    ;;
esac

function prepare_widget_signing_inputs() {
  local widget_bundle_identifier=""
  local widget_team_identifier=""

  if [[ ! -d "${WIDGET_APPEX_PATH}" ]]; then
    if [[ "${SKYBRIDGE_REQUIRE_WIDGET_EXTENSION:-0}" == "1" ]]; then
      echo "错误：签名前缺少必需的 Widget Extension：${WIDGET_APPEX_PATH}" >&2
      exit 1
    fi
    return 0
  fi

  if [[ ! -f "${WIDGET_ENTITLEMENTS}" ]]; then
    echo "错误：未找到 Widget Extension entitlements：${WIDGET_ENTITLEMENTS}" >&2
    exit 1
  fi

  cp "${WIDGET_ENTITLEMENTS}" "${ACTIVE_WIDGET_ENTITLEMENTS}"

  [[ -f "${WIDGET_INFO_PLIST}" ]] || {
    echo "错误：Widget Extension 缺少 Info.plist：${WIDGET_INFO_PLIST}" >&2
    exit 1
  }

  widget_bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${WIDGET_INFO_PLIST}" 2>/dev/null || true)
  if [[ -z "${widget_bundle_identifier}" ]]; then
    echo "错误：无法读取 Widget Extension bundle identifier：${WIDGET_INFO_PLIST}" >&2
    exit 1
  fi

  widget_team_identifier="$(printf '%s' "${IDENTITY}" | sed -n 's/.*(\([^)]*\)).*/\1/p')"
  if [[ -z "${widget_team_identifier}" ]]; then
    echo "错误：无法从签名身份解析 Team ID：${IDENTITY}" >&2
    exit 1
  fi

  if [[ -f "${WIDGET_PROFILE_PATH}" ]]; then
    skybridge_validate_provisionprofile_app_identity \
      "${WIDGET_PROFILE_PATH}" \
      "${widget_bundle_identifier}" \
      "${widget_team_identifier}" \
      || {
        echo "错误：嵌入的 Widget Extension provisioning profile 与签名团队或 bundle identifier 不匹配。" >&2
        exit 1
      }

    if ! skybridge_profile_supports_requested_profile_backed_entitlements \
      "${WIDGET_PROFILE_PATH}" \
      "${ACTIVE_WIDGET_ENTITLEMENTS}"; then
      echo "错误：Widget Extension provisioning profile 不覆盖请求的 App Groups entitlement。" >&2
      exit 1
    fi
  elif [[ "${SKYBRIDGE_REQUIRE_WIDGET_EXTENSION:-0}" == "1" || "${SKYBRIDGE_REQUIRE_APP_GROUPS:-0}" == "1" ]]; then
    echo "错误：Widget Extension 缺少 embedded.provisionprofile：${WIDGET_PROFILE_PATH}" >&2
    exit 1
  fi
}

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

  # Xcode's debug-dylib build mode places loadable code beside the main app and
  # extension executables, not only under Contents/Frameworks. Sign every
  # nested dylib/so before signing its containing framework, extension, and app
  # so hardened-runtime library validation sees one Team ID throughout.
  while IFS= read -r -d '' dylib; do
    codesign_target "${dylib}"
  done < <(find "${APP_PATH}" -type f \( -name "*.dylib" -o -name "*.so" \) -print0)

  if [[ -d "${frameworks_dir}" ]]; then
    while IFS= read -r -d '' framework; do
      codesign_target "${framework}"
    done < <(find "${frameworks_dir}" -type d -name "*.framework" -print0)
  fi

  if [[ -d "${helpers_dir}" ]]; then
    while IFS= read -r -d '' helper_bin; do
      codesign_target "${helper_bin}"
    done < <(find "${helpers_dir}" -type f -perm -u+x -print0)
  fi

  if [[ -d "${plugins_dir}" ]]; then
    while IFS= read -r -d '' appex; do
      local appex_entitlements=""
      if [[ -f "${ACTIVE_WIDGET_ENTITLEMENTS}" && "$(basename "${appex}")" == "SkyBridgeCompassWidgetsExtension.appex" ]]; then
        appex_entitlements="${ACTIVE_WIDGET_ENTITLEMENTS}"
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

function app_has_stapled_ticket() {
  xcrun stapler validate "${APP_PATH}" >/dev/null 2>&1
}

prepare_widget_signing_inputs

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

if [[ "${REQUIRE_NOTARIZATION}" == "1" ]] && \
   ! skybridge_gatekeeper_is_notarized "${GATEKEEPER_OUTPUT}" && \
   ! app_has_stapled_ticket; then
  echo "错误：当前签名产物尚未通过 notarization/stapling，无法满足 REQUIRE_NOTARIZATION=1。" >&2
  exit 1
fi

log "已完成正式签名配置：${APP_PATH}"
