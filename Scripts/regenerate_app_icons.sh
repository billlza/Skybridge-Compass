#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES_DIR="$ROOT_DIR/Sources/SkyBridgeCompassApp/Resources"
MASTER_SVG="$RES_DIR/AppIconMaster.svg"
ICON_DOC_DIR="$RES_DIR/AppIcon.icon"
ICON_DOC_ASSETS_DIR="$ICON_DOC_DIR/Assets"
ASSET_CATALOG_DIR="$RES_DIR/Assets.xcassets"
MAC_BRAND_IMAGESET_DIR="$ASSET_CATALOG_DIR/BrandIcon.imageset"
IOS_ASSET_CATALOG_DIR="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/Assets.xcassets"
IOS_APPICONSET_DIR="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/Assets.xcassets/AppIcon.appiconset"
IOS_BRAND_IMAGESET_DIR="$IOS_ASSET_CATALOG_DIR/BrandIcon.imageset"

if [[ ! -f "$MASTER_SVG" ]]; then
  echo "missing master svg: $MASTER_SVG" >&2
  exit 1
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert not found" >&2
  exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
  echo "iconutil not found" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RAW_PNG="$TMP_DIR/raw.png"
rsvg-convert -w 1024 -h 1024 "$MASTER_SVG" > "$RAW_PNG"

python3 - "$RAW_PNG" "$RES_DIR" "$IOS_APPICONSET_DIR" "$MAC_BRAND_IMAGESET_DIR" "$IOS_BRAND_IMAGESET_DIR" <<'PY'
from pathlib import Path
from PIL import Image, ImageDraw
import json
import sys

raw_png = Path(sys.argv[1])
res_dir = Path(sys.argv[2])
ios_appiconset_dir = Path(sys.argv[3])
mac_brand_imageset_dir = Path(sys.argv[4])
ios_brand_imageset_dir = Path(sys.argv[5])
img = Image.open(raw_png).convert("RGBA")

# Preserve the blue ring from the source artwork while trimming square corners
# that visually fight with macOS 26's icon framing.
mask = Image.new("L", img.size, 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, 1023, 1023], radius=180, fill=255)

rounded = Image.new("RGBA", img.size, (0, 0, 0, 0))
rounded.paste(img, (0, 0), mask)

for name in ("AppIcon.png", "AppIconDock.png", "BrandIcon.png", "app_icon.png"):
    rounded.save(res_dir / name)

for imageset_dir in (mac_brand_imageset_dir, ios_brand_imageset_dir):
    imageset_dir.mkdir(parents=True, exist_ok=True)
    rounded.save(imageset_dir / "BrandIcon.png")

contents_path = ios_appiconset_dir / "Contents.json"
if contents_path.exists():
    ios_appiconset_dir.mkdir(parents=True, exist_ok=True)
    ios_base = rounded.convert("RGB")
    contents = json.loads(contents_path.read_text())
    generated = set()
    for entry in contents.get("images", []):
        filename = entry.get("filename")
        if not filename or filename in generated:
            continue
        size = float(entry["size"].split("x")[0])
        scale = int(entry["scale"].rstrip("x"))
        px = int(round(size * scale))
        resized = ios_base.resize((px, px), Image.Resampling.LANCZOS)
        resized.save(ios_appiconset_dir / filename)
        generated.add(filename)
PY

mkdir -p "$ICON_DOC_ASSETS_DIR" "$ASSET_CATALOG_DIR" "$MAC_BRAND_IMAGESET_DIR" "$IOS_BRAND_IMAGESET_DIR"
cp "$RES_DIR/AppIcon.png" "$ICON_DOC_ASSETS_DIR/Image.png"

for base in AppIcon AppIconDock; do
  ICONSET="$TMP_DIR/${base}.iconset"
  mkdir -p "$ICONSET"
  SRC="$RES_DIR/${base}.png"
  sips -z 16 16 "$SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
  cp "$SRC" "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o "$RES_DIR/${base}.icns"
done

echo "regenerated app icons from $MASTER_SVG"
