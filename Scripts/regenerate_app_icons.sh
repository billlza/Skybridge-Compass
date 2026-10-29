#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES_DIR="$ROOT_DIR/Sources/SkyBridgeCompassApp/Resources"
MASTER_PNG="$RES_DIR/AppIconMaster.png"
ICON_DOC_DIR="$RES_DIR/AppIcon.icon"
ICON_DOC_ASSETS_DIR="$ICON_DOC_DIR/Assets"
ASSET_CATALOG_DIR="$RES_DIR/Assets.xcassets"
MAC_BRAND_IMAGESET_DIR="$ASSET_CATALOG_DIR/BrandIcon.imageset"
IOS_ASSET_CATALOG_DIR="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/Assets.xcassets"
IOS_APPICONSET_DIR="$IOS_ASSET_CATALOG_DIR/AppIcon.appiconset"
IOS_BRAND_IMAGESET_DIR="$IOS_ASSET_CATALOG_DIR/BrandIcon.imageset"

if [[ ! -f "$MASTER_PNG" ]]; then
  echo "missing master png: $MASTER_PNG" >&2
  exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
  echo "iconutil not found" >&2
  exit 1
fi

if ! xcrun -f actool >/dev/null 2>&1; then
  echo "actool not found" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RAW_PNG="$MASTER_PNG"

python3 - "$RAW_PNG" "$RES_DIR" "$IOS_APPICONSET_DIR" "$MAC_BRAND_IMAGESET_DIR" "$IOS_BRAND_IMAGESET_DIR" <<'PY'
from pathlib import Path
from PIL import Image, ImageEnhance, ImageFilter, ImageOps
import json
import sys

raw_png = Path(sys.argv[1])
res_dir = Path(sys.argv[2])
ios_appiconset_dir = Path(sys.argv[3])
mac_brand_imageset_dir = Path(sys.argv[4])
ios_brand_imageset_dir = Path(sys.argv[5])

img = Image.open(raw_png).convert("RGBA")
if img.size != (1024, 1024):
    raise SystemExit(f"AppIconMaster.png must be 1024x1024, got {img.size}")

canonical = img.copy()


def ios_icon_background_color(image):
    width, height = image.size
    edge_band = max(1, round(min(width, height) * 0.175))
    samples = []
    for y in range(height):
        for x in range(width):
            r, g, b, a = image.getpixel((x, y))
            if a < 240:
                continue
            if x < edge_band or y < edge_band or x >= width - edge_band or y >= height - edge_band:
                samples.append((r, g, b))
    if not samples:
        raise SystemExit("AppIconMaster.png has no opaque edge pixels for iOS background synthesis")

    midpoint = len(samples) // 2
    return tuple(sorted(pixel[channel] for pixel in samples)[midpoint] for channel in range(3))


def ios_app_icon_rgb(image):
    alpha_bbox = image.getchannel("A").getbbox()
    if alpha_bbox is None:
        raise SystemExit("AppIconMaster.png has no visible pixels")

    cropped = image.crop(alpha_bbox)
    fitted = ImageOps.fit(
        cropped,
        image.size,
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    )
    opaque = Image.new("RGB", image.size, ios_icon_background_color(fitted))
    opaque.paste(fitted, (0, 0), fitted.getchannel("A"))
    return opaque

for name in ("AppIcon.png", "AppIconDock.png", "BrandIcon.png", "app_icon.png"):
    canonical.save(res_dir / name)

alpha_bbox = canonical.getchannel("A").getbbox()
if alpha_bbox is None:
    raise SystemExit("AppIconMaster.png has no visible pixels")

sidebar_crop = canonical.crop(alpha_bbox)
sidebar_crop = ImageEnhance.Color(sidebar_crop).enhance(1.18)
sidebar_crop = ImageEnhance.Contrast(sidebar_crop).enhance(1.10)
sidebar_crop = ImageEnhance.Brightness(sidebar_crop).enhance(1.02)
sidebar_crop = sidebar_crop.filter(ImageFilter.UnsharpMask(radius=1.1, percent=125, threshold=3))
canvas_size = 1024
sidebar_safe_area_padding = 64
scale = min(
    (canvas_size - sidebar_safe_area_padding * 2) / sidebar_crop.width,
    (canvas_size - sidebar_safe_area_padding * 2) / sidebar_crop.height,
)
sidebar_size = (
    round(sidebar_crop.width * scale),
    round(sidebar_crop.height * scale),
)
sidebar_icon = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
sidebar_resized = sidebar_crop.resize(sidebar_size, Image.Resampling.LANCZOS)
sidebar_origin = (
    (canvas_size - sidebar_size[0]) // 2,
    (canvas_size - sidebar_size[1]) // 2,
)
sidebar_icon.alpha_composite(sidebar_resized, sidebar_origin)
sidebar_icon.save(res_dir / "SidebarBrandIcon.png")

for imageset_dir in (mac_brand_imageset_dir, ios_brand_imageset_dir):
    imageset_dir.mkdir(parents=True, exist_ok=True)
    canonical.save(imageset_dir / "BrandIcon.png")

contents_path = ios_appiconset_dir / "Contents.json"
if not contents_path.exists():
    raise SystemExit(f"missing iOS AppIcon Contents.json: {contents_path}")

ios_appiconset_dir.mkdir(parents=True, exist_ok=True)
# iOS app icons must be full-square and opaque; the system applies the
# rounded mask. Use the Mac artwork as the visual source, but crop away
# its transparent pre-rounded padding so iOS does not render a tile inside
# another tile.
ios_base = ios_app_icon_rgb(img)
contents = json.loads(contents_path.read_text())
generated = set()
pixel_sizes_by_filename = {}
for entry in contents.get("images", []):
    filename = entry.get("filename")
    if not filename:
        continue
    size = float(entry["size"].split("x")[0])
    scale = int(entry["scale"].rstrip("x"))
    px = int(round(size * scale))
    existing_px = pixel_sizes_by_filename.get(filename)
    if existing_px is not None:
        if existing_px != px:
            raise SystemExit(
                f"iOS AppIcon filename {filename} is reused for "
                f"{existing_px}px and {px}px slots"
            )
        continue
    resized = ios_base.resize((px, px), Image.Resampling.LANCZOS)
    resized.save(ios_appiconset_dir / filename)
    generated.add(filename)
    pixel_sizes_by_filename[filename] = px

extra_pngs = sorted(
    path.name for path in ios_appiconset_dir.glob("*.png")
    if path.name not in generated
)
if extra_pngs:
    raise SystemExit(
        "iOS AppIcon.appiconset contains PNGs not referenced by Contents.json: "
        + ", ".join(extra_pngs)
    )
PY

mkdir -p "$ICON_DOC_ASSETS_DIR" "$ASSET_CATALOG_DIR" "$MAC_BRAND_IMAGESET_DIR" "$IOS_BRAND_IMAGESET_DIR"
cp "$RES_DIR/AppIcon.png" "$ICON_DOC_ASSETS_DIR/Image.png"

ICON_COMPOSER_OUT="$TMP_DIR/icon-composer-output"
ICON_COMPOSER_LOG="$TMP_DIR/icon-composer-actool.log"
mkdir -p "$ICON_COMPOSER_OUT"

if ! xcrun actool \
  "$ASSET_CATALOG_DIR" \
  "$ICON_DOC_DIR" \
  --compile "$ICON_COMPOSER_OUT" \
  --output-format human-readable-text \
  --notices \
  --warnings \
  --output-partial-info-plist "$ICON_COMPOSER_OUT/assetcatalog_generated_info.plist" \
  --app-icon AppIcon \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --minimum-deployment-target 14.0 \
  --platform macosx \
  --bundle-identifier com.skybridge.compass.pro \
  >"$ICON_COMPOSER_LOG" 2>&1; then
  cat "$ICON_COMPOSER_LOG" >&2
  echo "failed to compile AppIcon.icon" >&2
  exit 1
fi

if grep -qi 'warning:' "$ICON_COMPOSER_LOG"; then
  cat "$ICON_COMPOSER_LOG" >&2
  echo "Icon Composer compilation emitted warnings" >&2
  exit 1
fi

if [[ ! -f "$ICON_COMPOSER_OUT/AppIcon.icns" || ! -f "$ICON_COMPOSER_OUT/Assets.car" ]]; then
  echo "actool did not produce AppIcon.icns/Assets.car" >&2
  exit 1
fi

generate_full_size_icns() {
  local base="$1"
  local iconset="$TMP_DIR/${base}.iconset"
  local src="$RES_DIR/${base}.png"

  if [[ ! -f "$src" ]]; then
    echo "missing source png for $base: $src" >&2
    exit 1
  fi

  rm -rf "$iconset"
  mkdir -p "$iconset"
  sips -z 16 16 "$src" --out "$iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$src" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$src" --out "$iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$src" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$src" --out "$iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$src" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$src" --out "$iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$src" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$src" --out "$iconset/icon_512x512.png" >/dev/null
  cp "$src" "$iconset/icon_512x512@2x.png"
  iconutil -c icns "$iconset" -o "$RES_DIR/${base}.icns"
}

for base in AppIcon AppIconDock; do
  generate_full_size_icns "$base"
done

echo "regenerated app icons from $MASTER_PNG with Icon Composer validation and full-size icns files"
