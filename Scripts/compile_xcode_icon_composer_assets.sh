#!/usr/bin/env bash
set -euo pipefail

srcroot="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
target_build_dir="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}"
resources_folder="${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH is required}"
resources_dir="${target_build_dir}/${resources_folder}"
icon_doc_dir="${srcroot}/Sources/SkyBridgeCompassApp/Resources/AppIcon.icon"
canonical_png="${srcroot}/Sources/SkyBridgeCompassApp/Resources/AppIcon.png"
brand_icon_png="${srcroot}/Sources/SkyBridgeCompassApp/Resources/BrandIcon.png"
sidebar_brand_icon_png="${srcroot}/Sources/SkyBridgeCompassApp/Resources/SidebarBrandIcon.png"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-xcode-iconcomposer.XXXXXX")"
actool_log="${tmp_dir}/actool.log"
partial_info_plist="${tmp_dir}/assetcatalog_generated_info.plist"

cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

if [[ ! -f "${icon_doc_dir}/icon.json" || ! -f "${icon_doc_dir}/Assets/Image.png" ]]; then
  echo "AppIcon.icon is incomplete: ${icon_doc_dir}" >&2
  exit 1
fi

if [[ ! -f "${canonical_png}" ]]; then
  echo "canonical AppIcon.png is missing: ${canonical_png}" >&2
  exit 1
fi

canonical_png_hash="$(shasum -a 256 "${canonical_png}" | awk '{print $1}')"
iconcomposer_png_hash="$(shasum -a 256 "${icon_doc_dir}/Assets/Image.png" | awk '{print $1}')"
if [[ "${canonical_png_hash}" != "${iconcomposer_png_hash}" ]]; then
  echo "AppIcon.icon/Assets/Image.png must match canonical AppIcon.png" >&2
  echo "AppIcon.png=${canonical_png_hash} IconComposerImage=${iconcomposer_png_hash}" >&2
  exit 1
fi

if [[ ! -f "${brand_icon_png}" ]]; then
  echo "runtime BrandIcon.png is missing: ${brand_icon_png}" >&2
  exit 1
fi

brand_icon_png_hash="$(shasum -a 256 "${brand_icon_png}" | awk '{print $1}')"
if [[ "${canonical_png_hash}" != "${brand_icon_png_hash}" ]]; then
  echo "BrandIcon.png must match canonical AppIcon.png" >&2
  echo "AppIcon.png=${canonical_png_hash} BrandIcon=${brand_icon_png_hash}" >&2
  exit 1
fi

if [[ ! -f "${sidebar_brand_icon_png}" ]]; then
  echo "runtime SidebarBrandIcon.png is missing: ${sidebar_brand_icon_png}" >&2
  exit 1
fi

sidebar_brand_icon_png_hash="$(shasum -a 256 "${sidebar_brand_icon_png}" | awk '{print $1}')"
if [[ "${canonical_png_hash}" == "${sidebar_brand_icon_png_hash}" ]]; then
  echo "SidebarBrandIcon.png must be a small-size optimized derivative, not a duplicate of AppIcon.png" >&2
  exit 1
fi

generate_full_size_icns() {
  local source_png="$1"
  local output_icns="$2"
  local iconset_dir="${tmp_dir}/AppIcon.iconset"

  if ! command -v iconutil >/dev/null 2>&1; then
    echo "iconutil is required to generate the full-size AppIcon.icns" >&2
    exit 1
  fi

  rm -rf "${iconset_dir}"
  mkdir -p "${iconset_dir}"
  sips -z 16 16 "${source_png}" --out "${iconset_dir}/icon_16x16.png" >/dev/null
  sips -z 32 32 "${source_png}" --out "${iconset_dir}/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "${source_png}" --out "${iconset_dir}/icon_32x32.png" >/dev/null
  sips -z 64 64 "${source_png}" --out "${iconset_dir}/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "${source_png}" --out "${iconset_dir}/icon_128x128.png" >/dev/null
  sips -z 256 256 "${source_png}" --out "${iconset_dir}/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "${source_png}" --out "${iconset_dir}/icon_256x256.png" >/dev/null
  sips -z 512 512 "${source_png}" --out "${iconset_dir}/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "${source_png}" --out "${iconset_dir}/icon_512x512.png" >/dev/null
  cp "${source_png}" "${iconset_dir}/icon_512x512@2x.png"
  iconutil -c icns "${iconset_dir}" -o "${output_icns}"
}

mkdir -p "${resources_dir}"

if ! xcrun actool \
    "${icon_doc_dir}" \
    --compile "${tmp_dir}" \
    --output-format human-readable-text \
    --notices \
    --warnings \
    --output-partial-info-plist "${partial_info_plist}" \
    --app-icon AppIcon \
    --enable-on-demand-resources NO \
    --development-region "${DEVELOPMENT_LANGUAGE:-en}" \
    --target-device mac \
    --minimum-deployment-target "${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    --platform macosx \
    --bundle-identifier "${PRODUCT_BUNDLE_IDENTIFIER:-com.skybridge.compass.pro}" \
    >"${actool_log}" 2>&1; then
  cat "${actool_log}" >&2
  exit 1
fi

if grep -qi 'warning:' "${actool_log}"; then
  cat "${actool_log}" >&2
  exit 1
fi

if [[ ! -f "${tmp_dir}/Assets.car" || ! -f "${tmp_dir}/AppIcon.icns" ]]; then
  cat "${actool_log}" >&2
  echo "actool did not produce Assets.car and AppIcon.icns from AppIcon.icon" >&2
  exit 1
fi

generate_full_size_icns "${canonical_png}" "${tmp_dir}/AppIcon.full-size.icns"

cp "${tmp_dir}/Assets.car" "${resources_dir}/Assets.car"
cp "${tmp_dir}/AppIcon.full-size.icns" "${resources_dir}/AppIcon.icns"
cp "${brand_icon_png}" "${resources_dir}/BrandIcon.png"
cp "${sidebar_brand_icon_png}" "${resources_dir}/SidebarBrandIcon.png"

rm -f \
  "${resources_dir}/icon.json" \
  "${resources_dir}/Image.png" \
  "${resources_dir}/AppIcon.png" \
  "${resources_dir}/AppIconDock.icns" \
  "${resources_dir}/AppIconDock.png" \
  "${resources_dir}/app_icon.png" \
  "${resources_dir}/AppIconMaster.png" \
  "${resources_dir}/AppIconMaster.svg" \
  "${resources_dir}/app-icon.svg"
rm -rf "${resources_dir}/AppIcon.icon" "${resources_dir}/Assets.xcassets" "${resources_dir}/Icons"
