#!/usr/bin/env zsh
set -euo pipefail

# 中文注释：
# 该脚本用于将 Xcode workspace Release app executable 产物封装为标准的 macOS 应用（.app）。
# 满足最低系统版本 macOS 14.0，针对 Apple Silicon（ARM64）进行优化，并使用最新 API。
#
# 使用方法：
# 1) 先确保在项目根目录运行过 Release 构建：
#    xcodebuild -workspace .swiftpm/xcode/package.xcworkspace -scheme SkyBridgeCompassApp -configuration Release -destination 'platform=macOS,arch=arm64' build
# 2) 运行本脚本：
#    Scripts/package_app.sh
# 3) 生成的 .app 会位于 dist/SkyBridge\ Compass\ Pro.app
#
# 注意：
# - 脚本优先使用 Developer ID / Apple Development 证书签名；
# - 若本机无可用证书则回退 ad-hoc（此时特权 Helper 安装可能失败）；
# - 当 SKYBRIDGE_PACKAGE_CONTEXT=release_dmg 时，脚本只接受明确的 Release 构建产物。

function log() {
  echo "[package] $1"
}

function codesign_target() {
  local target="$1"
  if [[ ! -e "${target}" ]]; then
    return 0
  fi

  if [[ "${IS_ADHOC_SIGNING}" -eq 0 ]]; then
    codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp "${target}" >/dev/null 2>&1
  else
    # 对 ad-hoc 场景：直接强制覆盖签名，清除任何现有签名（包括 runtime/library validation 标志），
    # 避免加载第三方 Framework 时触发 Team ID 校验失败。
    # 使用 --deep 确保 framework 内部的所有组件都被重签名
    codesign --force --sign - --deep "${target}" >/dev/null 2>&1 || {
      # 如果 --deep 失败，尝试先移除签名再重签
      codesign --remove-signature "${target}" >/dev/null 2>&1 || true
      codesign --force --sign - "${target}" >/dev/null 2>&1
    }
  fi
}

function codesign_target_or_fail() {
  local target="$1"
  if codesign_target "${target}"; then
    return 0
  fi

  if is_release_distribution_context; then
    echo "错误：release_dmg 打包中嵌入代码签名失败：${target}" >&2
    exit 1
  fi

  log "警告：嵌入代码签名失败，稍后由整体签名验证兜底：${target}"
  return 0
}

function resign_embedded_code() {
  log "统一重签名嵌入式代码（避免 Team ID 不一致导致 dyld 拒载）"

  if [[ -d "${FW_DIR}" ]]; then
    while IFS= read -r -d '' bin; do
      codesign_target_or_fail "${bin}"
    done < <(find "${FW_DIR}" -type f \( -name "*.dylib" -o -name "*.so" -o -perm -111 \) -print0)

    while IFS= read -r -d '' framework; do
      codesign_target_or_fail "${framework}"
    done < <(find "${FW_DIR}" -type d -name "*.framework" -print0)
  fi

  if [[ -d "${RES_DIR}" ]]; then
    while IFS= read -r -d '' bundle; do
      codesign_target_or_fail "${bundle}"
    done < <(find "${RES_DIR}" -type d -name "*.bundle" -print0)
  fi

  if [[ -d "${CONTENTS_DIR}/Library/LaunchDaemons" ]]; then
    while IFS= read -r -d '' helper_bin; do
      codesign_target_or_fail "${helper_bin}"
    done < <(find "${CONTENTS_DIR}/Library/LaunchDaemons" -type f -perm -111 -print0)
  fi

  if [[ -d "${PLUGINS_DIR}" ]]; then
    while IFS= read -r -d '' appex; do
      if [[ "${IS_ADHOC_SIGNING}" -eq 0 && "$(basename "${appex}")" == "${WIDGET_EXT_NAME}.appex" ]]; then
        if ! codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp \
          --entitlements "${WIDGET_ENTITLEMENTS}" \
          "${appex}" >/dev/null 2>&1; then
          if is_release_distribution_context; then
            echo "错误：release_dmg 打包中 Widget Extension 签名失败：${appex}" >&2
            exit 1
          fi
          log "警告：Widget Extension 签名失败，稍后由整体签名验证兜底：${appex}"
        fi
      else
        codesign_target_or_fail "${appex}"
      fi
    done < <(find "${PLUGINS_DIR}" -type d -name "*.appex" -print0)
  fi

  if [[ -d "${MACOS_DIR}" ]]; then
    while IFS= read -r -d '' app_bin; do
      codesign_target_or_fail "${app_bin}"
    done < <(find "${MACOS_DIR}" -type f -perm -111 -print0)
  fi
}

function stamp_macos_platform_metadata() {
  local info_plist="$1"
  local sdk_version=""
  local sdk_build=""
  local xcode_version=""
  local xcode_build=""
  local xcode_marker=""

  sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  sdk_build="$(xcrun --sdk macosx --show-sdk-build-version 2>/dev/null || true)"
  xcode_version="$(xcodebuild -version 2>/dev/null | awk '/^Xcode / { print $2; exit }' || true)"
  xcode_build="$(xcodebuild -version 2>/dev/null | awk '/^Build version / { print $3; exit }' || true)"

  plutil -replace CFBundleSupportedPlatforms -json '["MacOSX"]' "${info_plist}"
  plutil -replace DTPlatformName -string "macosx" "${info_plist}"

  if [[ -n "${sdk_version}" ]]; then
    plutil -replace DTPlatformVersion -string "${sdk_version}" "${info_plist}"
    plutil -replace DTSDKName -string "macosx${sdk_version}" "${info_plist}"
  fi
  if [[ -n "${sdk_build}" ]]; then
    plutil -replace DTSDKBuild -string "${sdk_build}" "${info_plist}"
  fi
  if [[ -n "${xcode_version}" ]]; then
    xcode_marker="$(awk -F. '
      {
        major = ($1 == "" ? 0 : $1)
        minor = ($2 == "" ? 0 : $2)
        printf "%d%02d", major, minor * 10
      }
    ' <<< "${xcode_version}")"
    plutil -replace DTXcode -string "${xcode_marker}" "${info_plist}"
  fi
  if [[ -n "${xcode_build}" ]]; then
    plutil -replace DTXcodeBuild -string "${xcode_build}" "${info_plist}"
  fi
}

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
    echo ""
  fi
}

function is_release_distribution_context() {
  [[ "${PACKAGE_CONTEXT}" == "release_dmg" ]]
}

function require_release_distribution_identity() {
  if ! is_release_distribution_context; then
    return 0
  fi

  if [[ -z "${SIGN_IDENTITY}" || "${SIGN_IDENTITY}" == "-" || "${SIGN_IDENTITY}" != Developer\ ID\ Application:* ]]; then
    echo "错误：release_dmg 打包必须使用有效的 Developer ID Application 证书，当前签名身份：${SIGN_IDENTITY:-(missing)}" >&2
    exit 1
  fi
}

function provisionprofile_matches_app_identity() {
  local profile_path="$1"
  local bundle_identifier="$2"
  local team_id="$3"

  python3 - "${profile_path}" "${bundle_identifier}" "${team_id}" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path


def load_profile(path: Path):
    payload = path.read_bytes()
    try:
        return plistlib.loads(payload)
    except Exception:
        pass
    for command in (
        ["security", "cms", "-D", "-i", str(path)],
        ["openssl", "smime", "-inform", "DER", "-verify", "-noverify", "-in", str(path)],
    ):
        completed = subprocess.run(command, check=False, capture_output=True)
        if completed.returncode == 0 and completed.stdout:
            return plistlib.loads(completed.stdout)
    raise SystemExit(1)


profile_path = Path(sys.argv[1])
bundle_id = sys.argv[2].strip()
team_id = sys.argv[3].strip()

if not profile_path.exists() or not bundle_id or not team_id:
    raise SystemExit(1)

profile = load_profile(profile_path)
platforms = profile.get("Platform", [])
entitlements = profile.get("Entitlements", {})
app_id = entitlements.get("com.apple.application-identifier", "")
profile_team = (profile.get("TeamIdentifier") or [""])[0]

if "OSX" not in platforms:
    raise SystemExit(1)
if app_id != f"{team_id}.{bundle_id}":
    raise SystemExit(1)
if profile_team != team_id:
    raise SystemExit(1)
PY
}

function resolve_macos_provisionprofile() {
  local bundle_identifier="$1"
  local entitlements_path="${2:-}"
  local team_id
  team_id="$(printf '%s' "${SIGN_IDENTITY}" | sed -n 's/.*(\([^)]*\)).*/\1/p')"
  local profile_dirs=(
    "${HOME}/Library/MobileDevice/Provisioning Profiles"
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
  )
  local profile_dir
  local candidate

  if [[ -n "${MACOS_PROVISION_PROFILE_PATH:-}" ]]; then
    [[ -f "${MACOS_PROVISION_PROFILE_PATH}" ]] || {
      echo "错误：指定的 macOS provisioning profile 不存在：${MACOS_PROVISION_PROFILE_PATH}" >&2
      return 1
    }
    if provisionprofile_matches_app_identity "${MACOS_PROVISION_PROFILE_PATH}" "${bundle_identifier}" "${team_id}" \
      && { [[ -z "${entitlements_path}" ]] || skybridge_profile_supports_requested_restricted_entitlements "${MACOS_PROVISION_PROFILE_PATH}" "${entitlements_path}"; }; then
      echo "${MACOS_PROVISION_PROFILE_PATH}"
      return 0
    fi
    echo "错误：指定的 macOS provisioning profile 不匹配 bundle/team 或不覆盖请求的 entitlements：${MACOS_PROVISION_PROFILE_PATH}" >&2
    return 1
  fi

  for profile_dir in "${profile_dirs[@]}"; do
    [[ -d "${profile_dir}" ]] || continue
    while IFS= read -r -d '' candidate; do
      if provisionprofile_matches_app_identity "${candidate}" "${bundle_identifier}" "${team_id}"
      then
        if [[ -z "${entitlements_path}" ]] || skybridge_profile_supports_requested_restricted_entitlements "${candidate}" "${entitlements_path}"; then
          echo "${candidate}"
          return 0
        fi
      fi
    done < <(find "${profile_dir}" -type f \( -name "*.provisionprofile" -o -name "*.mobileprovision" \) -print0)
  done

  return 1
}

function embed_macos_provisionprofile_if_available() {
  local bundle_identifier="$1"
  local entitlements_path="${2:-}"
  local destination="${CONTENTS_DIR}/embedded.provisionprofile"
  local resolved_profile=""

  SKYBRIDGE_RESOLVED_MACOS_PROVISIONPROFILE=""

  if resolved_profile="$(resolve_macos_provisionprofile "${bundle_identifier}" "${entitlements_path}")"; then
    SKYBRIDGE_RESOLVED_MACOS_PROVISIONPROFILE="${resolved_profile}"
    cp "${resolved_profile}" "${destination}"
    log "已嵌入 macOS provisioning profile: ${resolved_profile}"
    return 0
  fi

  if [[ -n "${MACOS_PROVISION_PROFILE_PATH:-}" ]]; then
    exit 1
  fi

  if is_release_distribution_context; then
    echo "错误：release_dmg 打包未找到匹配的 macOS Developer ID provisioning profile。" >&2
    echo "请先安装 profile 到 ~/Library/MobileDevice/Provisioning Profiles/，或设置 SKYBRIDGE_MACOS_PROVISIONPROFILE_PATH。" >&2
    exit 1
  fi

  log "未找到匹配的 macOS provisioning profile，继续生成不含 embedded.provisionprofile 的开发包"
}

function compile_icon_composer_assets() {
  local source_resources_dir="$1"
  local app_resources_dir="$2"
  local info_plist_path="$3"
  local icon_doc_dir="${source_resources_dir}/AppIcon.icon"
  local asset_catalog_dir="${source_resources_dir}/Assets.xcassets"
  local bundle_identifier=""
  local tmp_dir=""
  local actool_log=""
  local partial_info_plist=""
  local icon_file=""
  local icon_name=""
  local actool_inputs=()

  if [[ "${SKYBRIDGE_ENABLE_ICON_COMPOSER:-1}" == "0" ]]; then
    log "使用静态 AppIcon.icns，跳过 Icon Composer 编译（SKYBRIDGE_ENABLE_ICON_COMPOSER=0）"
    return 0
  fi

  if [[ ! -d "${icon_doc_dir}" || ! -f "${icon_doc_dir}/icon.json" || ! -f "${icon_doc_dir}/Assets/Image.png" ]]; then
    if is_release_distribution_context; then
      echo "错误：release_dmg 打包缺少 AppIcon.icon 图标源，无法生成现代 app 图标。" >&2
      exit 1
    fi
    log "未检测到完整 AppIcon.icon 图标源，沿用静态 AppIcon.icns"
    return 0
  fi

  if ! xcrun -f actool >/dev/null 2>&1; then
    if is_release_distribution_context; then
      echo "错误：release_dmg 打包需要 actool 来编译 AppIcon.icon。" >&2
      exit 1
    fi
    log "未找到 actool，沿用静态 AppIcon.icns"
    return 0
  fi

  bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist_path}" 2>/dev/null || echo "com.skybridge.compass.pro")
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-iconcomposer.XXXXXX")"
  actool_log="${tmp_dir}/actool.log"

  if [[ -d "${asset_catalog_dir}" ]]; then
    actool_inputs=("${asset_catalog_dir}" "${icon_doc_dir}")
  else
    actool_inputs=("${icon_doc_dir}")
  fi

  partial_info_plist="${tmp_dir}/assetcatalog_generated_info.plist"

  log "编译 Icon Composer 应用图标（AppIcon.icon）"
  if ! xcrun actool \
      "${actool_inputs[@]}" \
      --compile "${tmp_dir}" \
      --output-format human-readable-text \
      --notices \
      --warnings \
      --output-partial-info-plist "${partial_info_plist}" \
      --app-icon AppIcon \
      --enable-on-demand-resources NO \
      --development-region en \
      --target-device mac \
      --minimum-deployment-target 14.0 \
      --platform macosx \
      --bundle-identifier "${bundle_identifier}" \
      >"${actool_log}" 2>&1; then
    cat "${actool_log}" >&2
    rm -rf "${tmp_dir}"
    echo "错误：Icon Composer 图标编译失败。" >&2
    exit 1
  fi

  if grep -qi 'warning:' "${actool_log}"; then
    cat "${actool_log}" >&2
    rm -rf "${tmp_dir}"
    echo "错误：Icon Composer 图标编译出现 warning，不满足 0-warning 发布要求。" >&2
    exit 1
  fi

  if [[ ! -f "${tmp_dir}/AppIcon.icns" || ! -f "${tmp_dir}/Assets.car" ]]; then
    rm -rf "${tmp_dir}"
    echo "错误：actool 未生成 AppIcon.icns/Assets.car。" >&2
    exit 1
  fi

  mkdir -p "${app_resources_dir}"
  cp "${tmp_dir}/AppIcon.icns" "${app_resources_dir}/AppIcon.icns"
  cp "${tmp_dir}/Assets.car" "${app_resources_dir}/Assets.car"
  if [[ -f "${source_resources_dir}/AppIconDock.icns" ]]; then
    cp "${source_resources_dir}/AppIconDock.icns" "${app_resources_dir}/AppIconDock.icns"
  fi

  icon_file=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${partial_info_plist}" 2>/dev/null || true)
  icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "${partial_info_plist}" 2>/dev/null || true)
  plutil -replace CFBundleIconFile -string "${icon_file:-AppIcon}" "${info_plist_path}"
  plutil -replace CFBundleIconName -string "${icon_name:-AppIcon}" "${info_plist_path}"
  rm -f "${app_resources_dir}/icon.json" "${app_resources_dir}/Image.png"
  rm -rf "${tmp_dir}"
}

function resolve_widget_provisionprofile() {
  local bundle_identifier="$1"
  local entitlements_path="$2"
  local team_id
  team_id="$(printf '%s' "${SIGN_IDENTITY}" | sed -n 's/.*(\([^)]*\)).*/\1/p')"
  local profile_dirs=(
    "${HOME}/Library/MobileDevice/Provisioning Profiles"
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
  )
  local profile_dir
  local candidate

  if [[ -n "${WIDGET_PROVISION_PROFILE_PATH:-}" ]]; then
    [[ -f "${WIDGET_PROVISION_PROFILE_PATH}" ]] || {
      echo "错误：指定的 Widget provisioning profile 不存在：${WIDGET_PROVISION_PROFILE_PATH}" >&2
      return 1
    }
    if provisionprofile_matches_app_identity "${WIDGET_PROVISION_PROFILE_PATH}" "${bundle_identifier}" "${team_id}" \
      && skybridge_profile_supports_requested_restricted_entitlements "${WIDGET_PROVISION_PROFILE_PATH}" "${entitlements_path}"; then
      echo "${WIDGET_PROVISION_PROFILE_PATH}"
      return 0
    fi
    echo "错误：指定的 Widget provisioning profile 不匹配 bundle/team 或不覆盖请求的 entitlements：${WIDGET_PROVISION_PROFILE_PATH}" >&2
    return 1
  fi

  for profile_dir in "${profile_dirs[@]}"; do
    [[ -d "${profile_dir}" ]] || continue
    while IFS= read -r -d '' candidate; do
      if provisionprofile_matches_app_identity "${candidate}" "${bundle_identifier}" "${team_id}"
      then
        if skybridge_profile_supports_requested_restricted_entitlements "${candidate}" "${entitlements_path}"; then
          echo "${candidate}"
          return 0
        fi
      fi
    done < <(find "${profile_dir}" -type f \( -name "*.provisionprofile" -o -name "*.mobileprovision" \) -print0)
  done

  return 1
}

function build_and_embed_widget_extension() {
  local widget_project="${ROOT_DIR}/SkyBridgeWidgets.xcodeproj"
  local widget_appex_src="${XCODE_BUILD_DIR}/${WIDGET_EXT_NAME}.appex"
  local embedded_widget_appex_src="${XCODE_APP_BUNDLE}/Contents/PlugIns/${WIDGET_EXT_NAME}.appex"
  local widget_appex_dst="${PLUGINS_DIR}/${WIDGET_EXT_NAME}.appex"
  local widget_info_plist=""
  local widget_bundle_identifier=""
  local widget_profile=""

  if [[ ! -d "${widget_appex_src}" && -d "${embedded_widget_appex_src}" ]]; then
    widget_appex_src="${embedded_widget_appex_src}"
  fi

  if [[ ! -d "${widget_appex_src}" ]]; then
    if [[ "${SKYBRIDGE_REQUIRE_WIDGET_EXTENSION:-0}" == "1" ]] || is_release_distribution_context; then
      if [[ ! -d "${widget_project}" ]]; then
        echo "错误：发布包要求 Widget Extension，但缺少 Xcode 项目：${widget_project}" >&2
        exit 1
      fi
      log "构建 Widget Extension（scheme=${WIDGET_EXT_NAME}）"
      skybridge_run_xcodebuild -project "${widget_project}" \
        -scheme "${WIDGET_EXT_NAME}" \
        -configuration Release \
        -destination "${BUILD_DESTINATION}" \
        -derivedDataPath "${XCODE_DERIVED_DATA_PATH}" \
        -skipPackageUpdates \
        -disableAutomaticPackageResolution \
        CODE_SIGNING_ALLOWED=NO \
        COMPILER_INDEX_STORE_ENABLE=NO \
        ARCHS="${BUILD_ARCH}" \
        ONLY_ACTIVE_ARCH=YES \
        build
      if [[ ! -d "${widget_appex_src}" && -d "${embedded_widget_appex_src}" ]]; then
        widget_appex_src="${embedded_widget_appex_src}"
      fi
      if [[ ! -d "${widget_appex_src}" ]]; then
        echo "错误：Widget Extension 构建后仍未找到：${widget_appex_src}" >&2
        exit 1
      fi
    else
      log "未找到 Widget Extension，跳过 Widget 处理"
      return 0
    fi
  fi

  mkdir -p "${PLUGINS_DIR}"
  rm -rf "${widget_appex_dst}"
  cp -R "${widget_appex_src}" "${widget_appex_dst}"
  log "已嵌入 Widget Extension: ${widget_appex_dst}"

  widget_info_plist="${widget_appex_dst}/Contents/Info.plist"
  if [[ -n "${SKYBRIDGE_PACKAGE_BUILD_ID:-}" ]]; then
    plutil -replace CFBundleVersion -string "${SKYBRIDGE_PACKAGE_BUILD_ID}" "${widget_info_plist}"
  fi
  widget_bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${widget_info_plist}" 2>/dev/null || true)
  if [[ -z "${widget_bundle_identifier}" ]]; then
    echo "错误：无法读取 Widget Extension bundle identifier：${widget_info_plist}" >&2
    exit 1
  fi

  if widget_profile="$(resolve_widget_provisionprofile "${widget_bundle_identifier}" "${WIDGET_ENTITLEMENTS}")"; then
    cp "${widget_profile}" "${widget_appex_dst}/Contents/embedded.provisionprofile"
    log "已嵌入 Widget provisioning profile: ${widget_profile}"
  elif [[ -n "${WIDGET_PROVISION_PROFILE_PATH:-}" ]]; then
    exit 1
  elif [[ "${SKYBRIDGE_REQUIRE_WIDGET_EXTENSION:-0}" == "1" || "${SKYBRIDGE_REQUIRE_APP_GROUPS:-0}" == "1" ]] || is_release_distribution_context; then
    echo "错误：发布包未找到匹配的 Widget Extension provisioning profile：${widget_bundle_identifier}" >&2
    echo "请安装 profile 到 ~/Library/MobileDevice/Provisioning Profiles/，或设置 SKYBRIDGE_WIDGET_PROVISIONPROFILE_PATH。" >&2
    exit 1
  fi
}

function assert_release_product_is_fresh() {
  local build_artifact="$1"
  local executable_reference="$1"
  local info_reference="$1"
  local stale_source=""

  if [[ ! -e "${build_artifact}" ]]; then
    return 0
  fi
  if [[ -d "${build_artifact}" && -x "${build_artifact}/Contents/MacOS/SkyBridgeCompassApp" ]]; then
    executable_reference="${build_artifact}/Contents/MacOS/SkyBridgeCompassApp"
  fi
  if [[ -d "${build_artifact}" && -f "${build_artifact}/Contents/Info.plist" ]]; then
    info_reference="${build_artifact}/Contents/Info.plist"
  fi

  if [[ "${ROOT_DIR}/Package.swift" -nt "${executable_reference}" ]]; then
    stale_source="${ROOT_DIR}/Package.swift"
  elif [[ "${ROOT_DIR}/Sources/SkyBridgeCompassApp/Info.plist" -nt "${executable_reference}" ]]; then
    stale_source="${ROOT_DIR}/Sources/SkyBridgeCompassApp/Info.plist"
  elif [[ "${ROOT_DIR}/project.yml" -nt "${info_reference}" ]]; then
    stale_source="${ROOT_DIR}/project.yml"
  elif [[ "${ROOT_DIR}/XcodeSupport/SkyBridgeCompassMac/BundleModule.swift" -nt "${executable_reference}" ]]; then
    stale_source="${ROOT_DIR}/XcodeSupport/SkyBridgeCompassMac/BundleModule.swift"
  elif [[ "${ROOT_DIR}/XcodeSupport/SkyBridgeCompassMac/Info.plist" -nt "${info_reference}" ]]; then
    stale_source="${ROOT_DIR}/XcodeSupport/SkyBridgeCompassMac/Info.plist"
  fi
  if [[ -z "${stale_source}" ]]; then
    stale_source="$(find "${ROOT_DIR}/Sources" -type f \( -name "*.swift" -o -name "*.c" -o -name "*.cc" -o -name "*.cpp" -o -name "*.h" -o -name "*.hpp" -o -name "*.m" -o -name "*.mm" \) -newer "${executable_reference}" -print -quit 2>/dev/null || true)"
  fi

  if [[ -n "${stale_source}" && "${ALLOW_STALE_BUILD:-0}" != "1" ]]; then
    echo "错误：检测到 Release 产物早于源码：${stale_source}" >&2
    echo "请先重新构建，或显式设置 ALLOW_STALE_BUILD=1 后再跳过构建。" >&2
    exit 1
  fi
}

function select_release_build_dir() {
  local xcode_product="${XCODE_BUILD_DIR}/${EXECUTABLE}"
  local swiftpm_product="${SWIFTPM_RELEASE_BUILD_DIR}/${EXECUTABLE}"

  if [[ -x "${xcode_product}" ]]; then
    echo "${XCODE_BUILD_DIR}"
    return
  fi

  if [[ "${SKYBRIDGE_PACKAGE_ALLOW_SWIFTPM_RELEASE_FALLBACK:-0}" == "1" && -x "${swiftpm_product}" ]]; then
    echo "${SWIFTPM_RELEASE_BUILD_DIR}"
    return
  fi

  echo "${XCODE_BUILD_DIR}"
}

function assert_executable_embeds_privacy_usage_descriptions() {
  local executable_path="$1"
  local missing=()
  local executable_strings
  local key

  # Avoid `strings | grep -q` here: with pipefail enabled, grep's early exit can
  # SIGPIPE strings and turn a real match into a false negative.
  executable_strings="$(strings -a "${executable_path}")"

  for key in \
    NSBluetoothAlwaysUsageDescription \
    NSLocalNetworkUsageDescription \
    NSCameraUsageDescription \
    NSMicrophoneUsageDescription \
    NSLocationWhenInUseUsageDescription; do
    if ! grep -Fq "${key}" <<< "${executable_strings}"; then
      missing+=("${key}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "错误：主二进制内嵌 Info.plist 缺少隐私用途说明：${missing[*]}" >&2
    echo "请重新构建 SkyBridgeCompassApp；只修外层 Contents/Info.plist 会被 TCC 直接杀进程。" >&2
    exit 1
  fi
}

function canonical_filesystem_path() {
  local input_path="$1"
  local parent
  parent="$(cd "$(dirname "${input_path}")" && pwd -P)"
  printf '%s/%s\n' "${parent}" "$(basename "${input_path}")"
}

function assert_xcode_app_bundle_is_release_product() {
  local app_bundle="$1"
  local expected_bundle="${XCODE_BUILD_DIR}/${APP_NAME}"
  local canonical_app=""
  local canonical_expected=""

  if ! canonical_app="$(canonical_filesystem_path "${app_bundle}")"; then
    echo "错误：无法解析 Xcode app bundle 路径：${app_bundle}" >&2
    exit 1
  fi
  if ! canonical_expected="$(canonical_filesystem_path "${expected_bundle}")"; then
    echo "错误：无法解析期望的 Xcode Release 产物路径：${expected_bundle}" >&2
    exit 1
  fi

  if is_release_distribution_context && [[ "${canonical_app}" != "${canonical_expected}" ]]; then
    echo "错误：release_dmg 只能打包当前 DerivedData 的原生 Xcode Release 产物。" >&2
    echo "当前: ${canonical_app}" >&2
    echo "期望: ${canonical_expected}" >&2
    exit 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "${ROOT_DIR}/Scripts/apple_pqc_sdk_probe.sh"
source "${ROOT_DIR}/Scripts/package_build_policy.sh"
source "${ROOT_DIR}/Scripts/signing_entitlements_helpers.sh"
source "${ROOT_DIR}/Scripts/xcodebuild_helpers.sh"
XCODE_DERIVED_DATA_PATH="${SKYBRIDGE_XCODE_DERIVED_DATA_PATH:-$(skybridge_default_xcode_derived_data_path)}"
XCODE_BUILD_DIR="${XCODE_DERIVED_DATA_PATH}/Build/Products/Release"
BUILD_ARCH="${BUILD_ARCH:-$(skybridge_default_macos_build_arch)}"
SWIFTPM_RELEASE_BUILD_DIR="${ROOT_DIR}/.build/${BUILD_ARCH}-apple-macosx/release"
BUILD_DIR="${XCODE_BUILD_DIR}"
APP_NAME="SkyBridge Compass Pro.app"
APP_DIR="${ROOT_DIR}/dist/${APP_NAME}"
XCODE_PROJECT="${ROOT_DIR}/SkyBridgeWidgets.xcodeproj"
XCODE_MAC_SCHEME="${SKYBRIDGE_MACOS_APP_SCHEME:-SkyBridgeCompassMac}"
XCODE_APP_BUNDLE="${SKYBRIDGE_XCODE_APP_BUNDLE:-${XCODE_BUILD_DIR}/${APP_NAME}}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RES_DIR="${CONTENTS_DIR}/Resources"
FW_DIR="${CONTENTS_DIR}/Frameworks"
LEGACY_FW_LINK="${CONTENTS_DIR}/lib"
PLUGINS_DIR="${CONTENTS_DIR}/PlugIns"
SIGN_IDENTITY="${IDENTITY:-$(select_identity)}"
APP_PACKAGING_ENTITLEMENTS="${ROOT_DIR}/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements"
WIDGET_EXT_NAME="SkyBridgeCompassWidgetsExtension"
WIDGET_ENTITLEMENTS="${ROOT_DIR}/Sources/SkyBridgeCompassWidgets/SkyBridgeCompassWidgetsExtension.entitlements"
MACOS_PROVISION_PROFILE_PATH="${SKYBRIDGE_MACOS_PROVISIONPROFILE_PATH:-}"
WIDGET_PROVISION_PROFILE_PATH="${SKYBRIDGE_WIDGET_PROVISIONPROFILE_PATH:-}"
PACKAGING_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-package.XXXXXX")"
ACTIVE_APP_PACKAGING_ENTITLEMENTS="${PACKAGING_TMP_DIR}/SkyBridgeCompassApp.packaging.entitlements"
SKIP_BUILD="${SKIP_BUILD:-0}"
PACKAGE_CONTEXT="${SKYBRIDGE_PACKAGE_CONTEXT:-app}"
BUILD_DESTINATION="${BUILD_DESTINATION:-$(skybridge_default_macos_build_destination)}"
XCODE_WORKSPACE="${ROOT_DIR}/.swiftpm/xcode/package.xcworkspace"
USE_XCODE_WORKSPACE=0

if [[ -d "${XCODE_WORKSPACE}" ]]; then
  USE_XCODE_WORKSPACE=1
fi

cleanup_packaging_tmp() {
  rm -rf "${PACKAGING_TMP_DIR}"
}

trap cleanup_packaging_tmp EXIT

IS_ADHOC_SIGNING=0
if [[ -z "${SIGN_IDENTITY}" || "${SIGN_IDENTITY}" == "-" ]]; then
  IS_ADHOC_SIGNING=1
fi

require_release_distribution_identity

if [[ "${IS_ADHOC_SIGNING}" -eq 1 ]]; then
  log "签名模式: ad-hoc"
else
  log "签名模式: certificate (${SIGN_IDENTITY})"
fi

# 中文注释：可执行文件与资源 bundle 名称（来自 Xcode 构建输出）
EXECUTABLE="SkyBridgeCompassApp"
BUILD_DIR="$(select_release_build_dir)"
BUILD_SOURCE="$(skybridge_package_build_source "${BUILD_DIR}" "${XCODE_BUILD_DIR}" "${SWIFTPM_RELEASE_BUILD_DIR}")"
skybridge_assert_package_build_policy "${PACKAGE_CONTEXT}" "${BUILD_SOURCE}"

if [[ "${SKIP_BUILD}" != "1" ]]; then
  log "执行 Release 构建，确保打包包含最新代码"
  log "Xcode DerivedData 路径: ${XCODE_DERIVED_DATA_PATH}"
  cd "${ROOT_DIR}"
  skybridge_detect_apple_pqc_sdk
  log "Host macOS 版本: ${SKYBRIDGE_PQC_HOST_OS_VER:-unknown}"
  log "Xcode macOS SDK 版本: ${SKYBRIDGE_PQC_SDK_VER:-unknown}"
  log "Xcode macOS SDK 路径: ${SKYBRIDGE_PQC_SDK_PATH:-unknown}"
  if [[ "${SKYBRIDGE_PQC_SDK_AVAILABLE:-0}" == "1" ]]; then
    export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
    log "Apple PQC SDK 探测通过（mode=${SKYBRIDGE_PQC_PROBE_MODE}），启用 Apple PQC 编译条件"
  else
    export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=0
    log "Apple PQC SDK 探测未通过（mode=${SKYBRIDGE_PQC_PROBE_MODE}），禁用 Apple PQC 编译条件"
    if [[ -n "${SKYBRIDGE_PQC_PROBE_ERROR:-}" ]]; then
      log "PQC 探测详情: ${SKYBRIDGE_PQC_PROBE_ERROR}"
    fi
  fi

  if [[ "${USE_XCODE_WORKSPACE}" -eq 0 ]]; then
    log "未找到 package.xcworkspace，直接从 Swift package 根目录构建"
  fi
  if [[ "${USE_XCODE_WORKSPACE}" -eq 1 ]]; then
    skybridge_run_xcodebuild -workspace "${XCODE_WORKSPACE}" \
      -scheme SkyBridgeCompassApp \
      -configuration Release \
      -destination "${BUILD_DESTINATION}" \
      -derivedDataPath "${XCODE_DERIVED_DATA_PATH}" \
      -skipPackageUpdates \
      -disableAutomaticPackageResolution \
      CODE_SIGNING_ALLOWED=NO \
      COMPILER_INDEX_STORE_ENABLE=NO \
      build
  else
    skybridge_run_xcodebuild \
      -scheme SkyBridgeCompassApp \
      -configuration Release \
      -destination "${BUILD_DESTINATION}" \
      -derivedDataPath "${XCODE_DERIVED_DATA_PATH}" \
      -skipPackageUpdates \
      -disableAutomaticPackageResolution \
      CODE_SIGNING_ALLOWED=NO \
      COMPILER_INDEX_STORE_ENABLE=NO \
      build
  fi
  BUILD_DIR="$(select_release_build_dir)"
  BUILD_SOURCE="$(skybridge_package_build_source "${BUILD_DIR}" "${XCODE_BUILD_DIR}" "${SWIFTPM_RELEASE_BUILD_DIR}")"
  skybridge_assert_package_build_policy "${PACKAGE_CONTEXT}" "${BUILD_SOURCE}"
else
  log "按 SKIP_BUILD=1 跳过构建，直接复用已有产物"
  assert_release_product_is_fresh "${BUILD_DIR}/${EXECUTABLE}"
fi

# 校验构建产物是否存在
if [[ ! -x "${BUILD_DIR}/${EXECUTABLE}" ]]; then
  echo "错误：未找到可执行文件 ${BUILD_DIR}/${EXECUTABLE}。请先完成 Release 构建。" >&2
  if [[ "${SKYBRIDGE_PACKAGE_ALLOW_SWIFTPM_RELEASE_FALLBACK:-0}" != "1" ]]; then
    echo "提示：如需明确允许回退到 SwiftPM release 产物，请设置 SKYBRIDGE_PACKAGE_ALLOW_SWIFTPM_RELEASE_FALLBACK=1。" >&2
  fi
  exit 1
fi

log "本次打包使用构建目录: ${BUILD_DIR}"

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
APP_BIN="${MACOS_DIR}/${EXECUTABLE}"
assert_executable_embeds_privacy_usage_descriptions "${APP_BIN}"

log "拷贝运行时 Frameworks 到 .app/Contents/Frameworks/"
found_framework=0
for framework_parent in "${BUILD_DIR}" "${BUILD_DIR}/PackageFrameworks"; do
  [[ -d "${framework_parent}" ]] || continue
  for framework in "${framework_parent}"/*.framework(N); do
    [[ -d "${framework}" ]] || continue
    found_framework=1
    name="$(basename "${framework}")"
    rm -rf "${FW_DIR}/${name}"
    cp -R "${framework}" "${FW_DIR}/"
  done
done
if [[ "${found_framework}" -eq 0 ]]; then
  log "未找到 .framework 产物（若运行时报 dyld 缺失，请检查构建产物）"
fi

# 兼容历史 rpath（@executable_path/../lib），同时保留标准 Frameworks 布局。
if [[ -L "${LEGACY_FW_LINK}" || -e "${LEGACY_FW_LINK}" ]]; then
  rm -rf "${LEGACY_FW_LINK}"
fi
ln -s "Frameworks" "${LEGACY_FW_LINK}"
log "已创建兼容链接: ${LEGACY_FW_LINK} -> Frameworks"

if otool -l "${APP_BIN}" 2>/dev/null | grep -q "@executable_path/../Frameworks"; then
  log "已存在 rpath: @executable_path/../Frameworks"
else
  log "注入 rpath: @executable_path/../Frameworks"
  if install_name_tool -add_rpath "@executable_path/../Frameworks" "${APP_BIN}" >/dev/null 2>&1; then
    log "Frameworks rpath 注入成功"
  elif is_release_distribution_context; then
    echo "错误：release_dmg 打包中 Frameworks rpath 注入失败。" >&2
    exit 1
  else
    log "警告：Frameworks rpath 注入失败，将依赖 Contents/lib 兼容链接"
  fi
fi
if otool -l "${APP_BIN}" 2>/dev/null | grep -q "@executable_path/../Frameworks"; then
  log "校验通过：主二进制已包含 Frameworks rpath"
else
  echo "错误：主二进制缺少 @executable_path/../Frameworks rpath。" >&2
  exit 1
fi

if otool -L "${APP_BIN}" 2>/dev/null | grep -q "@rpath/WebRTC.framework/WebRTC"; then
  if [[ ! -e "${FW_DIR}/WebRTC.framework/WebRTC" ]]; then
    echo "错误：主二进制依赖 WebRTC.framework，但 ${FW_DIR}/WebRTC.framework/WebRTC 不存在。" >&2
    exit 1
  fi
  if [[ ! -e "${LEGACY_FW_LINK}/WebRTC.framework/WebRTC" ]]; then
    echo "错误：主二进制依赖 WebRTC.framework，但兼容路径 ${LEGACY_FW_LINK}/WebRTC.framework/WebRTC 不存在。" >&2
    exit 1
  fi
  log "校验通过：WebRTC.framework 可通过 Frameworks/lib 双路径定位"
fi

log "拷贝 Swift 运行时 dylib 到 .app/Contents/Frameworks/"
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
for bundle in "${BUILD_DIR}"/*.bundle(N); do
  [[ -d "${bundle}" ]] || continue
  found_bundle=1
  rm -rf "${RES_DIR}/$(basename "${bundle}")"
  cp -R "${bundle}" "${RES_DIR}/"
done
if [[ "${found_bundle}" -eq 0 ]]; then
  echo "错误：未发现构建产物资源 bundle；缺少 Bundle.module 资源会导致发布包功能缺失。" >&2
  exit 1
fi

if [[ ! -d "${RES_DIR}/SkyBridgeCompassApp_SkyBridgeCompassApp.bundle" ]]; then
  echo "错误：缺少 SkyBridgeCompassApp_SkyBridgeCompassApp.bundle；禁止发布缺失 app target 资源的包。" >&2
  exit 1
fi

# 额外拷贝源资源目录，供 LaunchServices app icon 与运行态 Dock 图标按主 bundle 解析。
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
stamp_macos_platform_metadata "${INFO_PLIST_DST}"
plutil -replace SkyBridgePackagingBuildSource -string "${BUILD_SOURCE}" "${INFO_PLIST_DST}"
plutil -replace SkyBridgePackagingBuildScheme -string "SkyBridgeCompassApp" "${INFO_PLIST_DST}"
plutil -replace SkyBridgePackagingBuildConfiguration -string "Release" "${INFO_PLIST_DST}"
plutil -replace SkyBridgePackagingBuildProductPath -string "${BUILD_DIR}/${EXECUTABLE}" "${INFO_PLIST_DST}"
log "记录打包构建来源: ${BUILD_SOURCE}"
if [[ -z "${SKYBRIDGE_PACKAGE_BUILD_ID:-}" ]]; then
  SKYBRIDGE_PACKAGE_BUILD_ID="$(date +%Y%m%d%H%M%S)"
fi
plutil -replace CFBundleVersion -string "${SKYBRIDGE_PACKAGE_BUILD_ID}" "${INFO_PLIST_DST}"
log "设置打包 Build ID: ${SKYBRIDGE_PACKAGE_BUILD_ID}"

compile_icon_composer_assets "${SRC_RES_DIR}" "${RES_DIR}" "${INFO_PLIST_DST}"

# 移除可能不需要的主 storyboard 键（SwiftUI App 生命周期无需该键）
if /usr/libexec/PlistBuddy -c 'Print :NSMainStoryboardFile' "${INFO_PLIST_DST}" >/dev/null 2>&1; then
  log "移除 NSMainStoryboardFile（SwiftUI App 不使用 storyboard）"
  /usr/libexec/PlistBuddy -c 'Delete :NSMainStoryboardFile' "${INFO_PLIST_DST}" || true
fi

BUNDLE_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST_DST}" 2>/dev/null || true)
if [[ -n "${BUNDLE_IDENTIFIER}" ]]; then
  embed_macos_provisionprofile_if_available "${BUNDLE_IDENTIFIER}" "${APP_PACKAGING_ENTITLEMENTS}"
fi

skybridge_prepare_signing_entitlements \
  "${APP_PACKAGING_ENTITLEMENTS}" \
  "${ACTIVE_APP_PACKAGING_ENTITLEMENTS}" \
  "${INFO_PLIST_DST}" \
  "${SKYBRIDGE_RESOLVED_MACOS_PROVISIONPROFILE:-}"

APPLE_SIGN_IN_FEATURE_FLAG="$(skybridge_read_plist_bool "${INFO_PLIST_DST}" "SKYBRIDGE_ENABLE_APPLE_SIGN_IN" 2>/dev/null || echo "unknown")"
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
  log "Apple 登录产品功能仍保持开启，但当前打包产物不具备原生 Apple Sign In entitlement；运行时应走非原生方案"
fi

# 生成 PkgInfo（现代系统可选，但保留兼容性）
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# ========== Widget Extension 打包 ==========
build_and_embed_widget_extension

# ========== PowerMetricsHelper 打包 ==========
# SMAppService.daemon 需要 plist 文件位于 Contents/Library/LaunchDaemons/
HELPER_NAME="com.skybridge.PowerMetricsHelper"
HELPER_EXECUTABLE="PowerMetricsHelper"
HELPER_SRC_DIR="${ROOT_DIR}/Sources/PowerMetricsHelper"
HELPER_DST_DIR="${CONTENTS_DIR}/Library/LaunchDaemons/${HELPER_NAME}"
HELPER_BIN_PATH="${BUILD_DIR}/${HELPER_EXECUTABLE}"

resolve_helper_bin_path() {
  local candidate
  local selected_candidate=""
  local selected_mtime=0
  local candidate_mtime=0
  for candidate in \
    "${XCODE_BUILD_DIR}/${HELPER_EXECUTABLE}" \
    "${ROOT_DIR}/.build/xcode/Build/Products/Release/${HELPER_EXECUTABLE}" \
    "${SWIFTPM_RELEASE_BUILD_DIR}/${HELPER_EXECUTABLE}"; do
    if [[ -x "${candidate}" ]]; then
      if ! helper_binary_needs_rebuild "${candidate}"; then
        printf '%s\n' "${candidate}"
        return 0
      fi

      candidate_mtime="$(stat -f "%m" "${candidate}" 2>/dev/null || echo 0)"
      if [[ -z "${selected_candidate}" || "${candidate_mtime}" -gt "${selected_mtime}" ]]; then
        selected_candidate="${candidate}"
        selected_mtime="${candidate_mtime}"
      fi
    fi
  done
  if [[ -n "${selected_candidate}" ]]; then
    printf '%s\n' "${selected_candidate}"
  else
    printf '%s\n' "${SWIFTPM_RELEASE_BUILD_DIR}/${HELPER_EXECUTABLE}"
  fi
}

helper_binary_needs_rebuild() {
  local candidate="$1"
  local stale_source=""
  local source_dir=""

  if [[ ! -x "${candidate}" ]]; then
    return 0
  fi

  for source_dir in \
    "${ROOT_DIR}/Sources/PowerMetricsHelper" \
    "${ROOT_DIR}/Sources/PrivateSensorBridge" \
    "${ROOT_DIR}/Sources/PrivateSensorBridgeC"; do
    [[ -d "${source_dir}" ]] || continue
    stale_source="$(find "${source_dir}" -type f -newer "${candidate}" -print -quit 2>/dev/null || true)"
    if [[ -n "${stale_source}" ]]; then
      return 0
    fi
  done

  return 1
}

build_power_metrics_helper() {
  cd "${ROOT_DIR}"
  swift build -c release --arch "${BUILD_ARCH}" --product "${HELPER_EXECUTABLE}"
}

HELPER_BIN_PATH="$(resolve_helper_bin_path)"

# 某些构建路径只会产出主 App；如果 Helper 缺失或早于源码，必须补构建。
# release_dmg 下始终让 SwiftPM 校验一次 Helper product，避免发布旧 Helper。
if is_release_distribution_context || helper_binary_needs_rebuild "${HELPER_BIN_PATH}"; then
  if [[ -x "${HELPER_BIN_PATH}" ]]; then
    if is_release_distribution_context; then
      log "发布打包校验 PowerMetricsHelper，执行 Release 构建..."
    else
      log "检测到 PowerMetricsHelper 早于源码，重新构建..."
    fi
  else
    log "未检测到 PowerMetricsHelper，尝试单独构建..."
  fi

  if build_power_metrics_helper; then
    log "PowerMetricsHelper 构建完成"
  elif is_release_distribution_context; then
    echo "错误：release_dmg 打包中 PowerMetricsHelper 构建失败，禁止继续使用旧 Helper。" >&2
    exit 1
  else
    log "PowerMetricsHelper 构建失败，将继续打包主应用（高级监控功能不可用）"
  fi

  HELPER_BIN_PATH="$(resolve_helper_bin_path)"
fi

if is_release_distribution_context && helper_binary_needs_rebuild "${HELPER_BIN_PATH}"; then
  echo "错误：release_dmg 打包中的 PowerMetricsHelper 仍早于源码或缺失：${HELPER_BIN_PATH}" >&2
  exit 1
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
  HELPER_PLIST_PATH="${CONTENTS_DIR}/Library/LaunchDaemons/${HELPER_NAME}.plist"
  
  # 拷贝 Info.plist 到 Helper bundle 目录
  cp "${HELPER_SRC_DIR}/Info.plist" "${HELPER_DST_DIR}/"

  # fail-fast：校验 launchd plist 至少包含 Program / ProgramArguments / BundleProgram 之一
  HELPER_PROGRAM_VALUE=$(/usr/libexec/PlistBuddy -c 'Print :Program' "${HELPER_PLIST_PATH}" 2>/dev/null || true)
  HELPER_PROGRAM_ARG0=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "${HELPER_PLIST_PATH}" 2>/dev/null || true)
  HELPER_BUNDLE_PROGRAM_VALUE=$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "${HELPER_PLIST_PATH}" 2>/dev/null || true)

  if [[ -z "${HELPER_PROGRAM_VALUE}" && -z "${HELPER_PROGRAM_ARG0}" && -z "${HELPER_BUNDLE_PROGRAM_VALUE}" ]]; then
    echo "错误：${HELPER_PLIST_PATH} 缺少 Program/ProgramArguments/BundleProgram，SMAppService 将无法注册 Helper。" >&2
    exit 1
  fi

  # 如果使用 BundleProgram，校验其对应的 app 内可执行文件存在且可执行
  if [[ -n "${HELPER_BUNDLE_PROGRAM_VALUE}" ]]; then
    HELPER_BUNDLE_PROGRAM_PATH="${APP_DIR}/${HELPER_BUNDLE_PROGRAM_VALUE#/}"
    if [[ ! -e "${HELPER_BUNDLE_PROGRAM_PATH}" ]]; then
      echo "错误：BundleProgram 指向的文件不存在：${HELPER_BUNDLE_PROGRAM_PATH}" >&2
      exit 1
    fi
    if [[ ! -x "${HELPER_BUNDLE_PROGRAM_PATH}" ]]; then
      echo "错误：BundleProgram 指向的文件不可执行：${HELPER_BUNDLE_PROGRAM_PATH}" >&2
      exit 1
    fi
  fi

  # Helper bundle 在 LaunchDaemons 目录，需显式签名，否则主 App 深度签名可能不会覆盖到它
  if [[ "${IS_ADHOC_SIGNING}" -eq 0 ]]; then
    codesign --force --sign "${SIGN_IDENTITY}" --timestamp "${HELPER_DST_DIR}" >/dev/null 2>&1 || {
      if is_release_distribution_context; then
        echo "错误：release_dmg 打包中 Helper 显式签名失败：${HELPER_DST_DIR}" >&2
        exit 1
      fi
      log "警告：Helper 显式签名失败，后续将依赖主 App 深度签名"
    }
  fi
  
  log "PowerMetricsHelper 打包完成"
else
  if is_release_distribution_context; then
    echo "错误：release_dmg 打包未找到 PowerMetricsHelper 可执行文件，禁止发布缺失高级监控 Helper 的 DMG。" >&2
    exit 1
  fi
  log "跳过 PowerMetricsHelper（未找到可执行文件：${HELPER_BIN_PATH}）"
fi

# 优先使用正式证书签名；未配置证书时回退 ad-hoc
if [[ "${IS_ADHOC_SIGNING}" -eq 0 ]]; then
  log "使用证书签名：${SIGN_IDENTITY}"
  resign_embedded_code
  codesign --force --sign "${SIGN_IDENTITY}" --options runtime --timestamp \
    --entitlements "${ACTIVE_APP_PACKAGING_ENTITLEMENTS}" \
    "${APP_DIR}" >/dev/null 2>&1 || {
    if is_release_distribution_context; then
      echo "错误：release_dmg 打包中的 Developer ID 签名失败，已停止，禁止回退 ad-hoc。" >&2
      exit 1
    fi
    echo "警告：证书签名失败，回退 ad-hoc 签名。" >&2
    SIGN_IDENTITY="-"
    IS_ADHOC_SIGNING=1
    resign_embedded_code
    codesign --force --sign - --entitlements "${ACTIVE_APP_PACKAGING_ENTITLEMENTS}" "${APP_DIR}" >/dev/null 2>&1 || {
      echo "警告：codesign 签名失败，但可在开发机上运行（未 notarize）。" >&2
    }
  }
else
  if is_release_distribution_context; then
    echo "错误：release_dmg 打包禁止使用 ad-hoc 签名。" >&2
    exit 1
  fi
  log "未检测到可用证书，使用 ad-hoc 签名"
  resign_embedded_code
  codesign --force --sign - --entitlements "${ACTIVE_APP_PACKAGING_ENTITLEMENTS}" "${APP_DIR}" >/dev/null 2>&1 || {
    echo "警告：codesign 签名失败，但可在开发机上运行（未 notarize）。" >&2
  }
fi

# 验证签名（非强制）
if codesign --verify --deep --strict --verbose=2 "${APP_DIR}" >/dev/null 2>&1; then
  log "签名验证通过"
else
  if is_release_distribution_context; then
    echo "错误：release_dmg 打包的签名验证失败。" >&2
    exit 1
  fi
  log "签名验证未通过（开发阶段可忽略）"
fi

# 标记 App Bundle 为最新打包产物，便于后续 DMG 流程做 freshness 校验。
touch "${APP_DIR}"

log "完成打包：${APP_DIR}"
log "可直接双击运行或使用：open '${APP_DIR}'"
