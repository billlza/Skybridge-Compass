#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES_DIR="$ROOT_DIR/Sources/SkyBridgeCompassApp/Resources"
MASTER_PNG="$RES_DIR/AppIconMaster.png"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ ! -f "$MASTER_PNG" ]]; then
  echo "icon verification failed: missing master png: $MASTER_PNG" >&2
  exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
  echo "icon verification failed: iconutil not found" >&2
  exit 1
fi

RAW_PNG="$MASTER_PNG"

python3 - "$ROOT_DIR" "$RAW_PNG" <<'PY'
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

from PIL import Image, ImageEnhance, ImageFilter, ImageOps

root = Path(sys.argv[1])
raw_png = Path(sys.argv[2])
res_dir = root / "Sources/SkyBridgeCompassApp/Resources"
canonical_path = res_dir / "AppIcon.png"
app_icon_dock_path = res_dir / "AppIconDock.png"
brand_icon_path = res_dir / "BrandIcon.png"
app_icon_alias_path = res_dir / "app_icon.png"
sidebar_brand_icon_path = res_dir / "SidebarBrandIcon.png"
icon_composer_path = res_dir / "AppIcon.icon/Assets/Image.png"
mac_brand_path = res_dir / "Assets.xcassets/BrandIcon.imageset/BrandIcon.png"
ios_assets = root / "SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/Assets.xcassets"
ios_appiconset = ios_assets / "AppIcon.appiconset"
ios_contents_path = ios_appiconset / "Contents.json"
ios_brand_path = ios_assets / "BrandIcon.imageset/BrandIcon.png"


def fail(message: str) -> None:
    raise SystemExit(f"icon verification failed: {message}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_file(path: Path) -> None:
    if not path.is_file():
        fail(f"missing file: {path}")


for path in (
    canonical_path,
    app_icon_dock_path,
    brand_icon_path,
    app_icon_alias_path,
    sidebar_brand_icon_path,
    icon_composer_path,
    mac_brand_path,
    ios_contents_path,
    ios_brand_path,
):
    require_file(path)

raw = Image.open(raw_png).convert("RGBA")
if raw.size != (1024, 1024):
    fail(f"AppIconMaster.png must be 1024x1024, got {raw.size}")

expected_canonical = raw.copy()


def ios_icon_background_color(image: Image.Image) -> tuple[int, int, int]:
    width, height = image.size
    edge_band = max(1, round(min(width, height) * 0.175))
    samples: list[tuple[int, int, int]] = []
    for y in range(height):
        for x in range(width):
            r, g, b, a = image.getpixel((x, y))
            if a < 240:
                continue
            if x < edge_band or y < edge_band or x >= width - edge_band or y >= height - edge_band:
                samples.append((r, g, b))
    if not samples:
        fail("AppIconMaster.png has no opaque edge pixels for iOS background synthesis")

    midpoint = len(samples) // 2
    return tuple(sorted(pixel[channel] for pixel in samples)[midpoint] for channel in range(3))


def ios_app_icon_rgb(image: Image.Image) -> Image.Image:
    alpha_bbox = image.getchannel("A").getbbox()
    if alpha_bbox is None:
        fail("AppIconMaster.png has no visible pixels")

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

canonical = Image.open(canonical_path).convert("RGBA")
if canonical.size != (1024, 1024):
    fail(f"canonical AppIcon.png must be 1024x1024, got {canonical.size}")
if canonical.tobytes() != expected_canonical.tobytes():
    fail("canonical AppIcon.png drifted from AppIconMaster.png")

canonical_hash = sha256(canonical_path)
for path in (
    app_icon_dock_path,
    brand_icon_path,
    app_icon_alias_path,
    icon_composer_path,
    mac_brand_path,
    ios_brand_path,
):
    if sha256(path) != canonical_hash:
        fail(f"{path} must exactly match canonical AppIcon.png")

alpha_bbox = canonical.getchannel("A").getbbox()
if alpha_bbox is None:
    fail("canonical AppIcon.png has no visible pixels")

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
expected_sidebar = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
sidebar_resized = sidebar_crop.resize(sidebar_size, Image.Resampling.LANCZOS)
sidebar_origin = (
    (canvas_size - sidebar_size[0]) // 2,
    (canvas_size - sidebar_size[1]) // 2,
)
expected_sidebar.alpha_composite(sidebar_resized, sidebar_origin)
actual_sidebar = Image.open(sidebar_brand_icon_path).convert("RGBA")
if actual_sidebar.size != (canvas_size, canvas_size):
    fail(f"SidebarBrandIcon.png must be 1024x1024, got {actual_sidebar.size}")
if actual_sidebar.tobytes() != expected_sidebar.tobytes():
    fail("SidebarBrandIcon.png drifted from the small-size brand icon transform")
actual_sidebar_bbox = actual_sidebar.getchannel("A").point(lambda alpha: 255 if alpha >= 8 else 0).getbbox()
if actual_sidebar_bbox is None:
    fail("SidebarBrandIcon.png has no visible pixels")
left, top, right, bottom = actual_sidebar_bbox
actual_sidebar_margins = (
    left,
    top,
    canvas_size - right,
    canvas_size - bottom,
)
minimum_sidebar_margin = 56
if min(actual_sidebar_margins) < minimum_sidebar_margin:
    fail(
        "SidebarBrandIcon.png optical safe area is too small: "
        f"margins={actual_sidebar_margins}, minimum={minimum_sidebar_margin}"
    )

ios_base = ios_app_icon_rgb(raw)
contents = json.loads(ios_contents_path.read_text())
expected_pngs: set[str] = set()
pixel_sizes_by_filename: dict[str, int] = {}

for entry in contents.get("images", []):
    filename = entry.get("filename")
    if not filename:
        continue

    try:
        size = float(entry["size"].split("x", maxsplit=1)[0])
        scale = int(entry["scale"].rstrip("x"))
    except (KeyError, ValueError) as error:
        fail(f"invalid iOS AppIcon entry for {filename}: {error}")

    pixel_size = int(round(size * scale))
    existing_pixel_size = pixel_sizes_by_filename.get(filename)
    if existing_pixel_size is not None:
        if existing_pixel_size != pixel_size:
            fail(
                f"iOS AppIcon filename {filename} is reused for "
                f"{existing_pixel_size}px and {pixel_size}px slots"
            )
        continue

    expected_path = ios_appiconset / filename
    require_file(expected_path)

    actual = Image.open(expected_path)
    if actual.size != (pixel_size, pixel_size):
        fail(f"{expected_path} must be {pixel_size}x{pixel_size}, got {actual.size}")
    if actual.mode not in ("RGB", "P"):
        fail(f"{expected_path} must not contain alpha, got mode {actual.mode}")

    expected = ios_base.resize((pixel_size, pixel_size), Image.Resampling.LANCZOS)
    if actual.convert("RGB").tobytes() != expected.tobytes():
        fail(f"{expected_path} drifted from canonical AppIcon.png")

    expected_pngs.add(filename)
    pixel_sizes_by_filename[filename] = pixel_size

if not expected_pngs:
    fail(f"no iOS AppIcon PNG filenames declared in {ios_contents_path}")

extra_pngs = sorted(
    path.name for path in ios_appiconset.glob("*.png")
    if path.name not in expected_pngs
)
if extra_pngs:
    fail(
        "iOS AppIcon.appiconset contains PNGs not referenced by Contents.json: "
        + ", ".join(extra_pngs)
    )

print("app icon verification passed")
PY

generate_full_size_icns() {
  local base="$1"
  local iconset="$TMP_DIR/${base}.iconset"
  local src="$RES_DIR/${base}.png"
  local generated="$TMP_DIR/${base}.icns"
  local expected="$RES_DIR/${base}.icns"

  if [[ ! -f "$src" ]]; then
    echo "icon verification failed: missing source png for $base: $src" >&2
    exit 1
  fi
  if [[ ! -f "$expected" ]]; then
    echo "icon verification failed: missing source icns for $base: $expected" >&2
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
  iconutil -c icns "$iconset" -o "$generated"

  generated_hash="$(shasum -a 256 "$generated" | awk '{print $1}')"
  expected_hash="$(shasum -a 256 "$expected" | awk '{print $1}')"
  if [[ "$generated_hash" != "$expected_hash" ]]; then
    echo "icon verification failed: ${base}.icns drifted from ${base}.png" >&2
    echo "generated=$generated_hash source=$expected_hash" >&2
    exit 1
  fi
}

generate_full_size_icns AppIcon
generate_full_size_icns AppIconDock
