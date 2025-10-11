#!/usr/bin/env bash
set -euo pipefail

# Generate .icns from a source PNG for the macOS app.
# Usage: scripts/generate-app-icon.sh [source_png]

ROOT_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
RES_DIR="$ROOT_DIR/macos/SkyBridgeCompassApp/Sources/SkyBridgeCompassApp/Resources"
SRC_PNG="${1:-$RES_DIR/AppIcon.png}"
ICONSET_DIR="$RES_DIR/AppIcon.iconset"
OUT_ICNS="$RES_DIR/AppIcon.icns"

echo "[icon] Resources dir: $RES_DIR"
echo "[icon] Source PNG:    $SRC_PNG"

if [[ ! -f "$SRC_PNG" ]]; then
  echo "[icon] Source PNG not found. Skipping generation."
  exit 0
fi

mkdir -p "$ICONSET_DIR"

# Sizes required by macOS iconutil
declare -a SIZES=(16 32 64 128 256 512 1024)
for SZ in "${SIZES[@]}"; do
  echo "[icon] Generating ${SZ}x${SZ}"
  sips -z "$SZ" "$SZ" "$SRC_PNG" --out "$ICONSET_DIR/icon_${SZ}x${SZ}.png" >/dev/null
  if [[ "$SZ" -lt 1024 ]]; then
    DBL=$((SZ*2))
    sips -z "$DBL" "$DBL" "$SRC_PNG" --out "$ICONSET_DIR/icon_${SZ}x${SZ}@2x.png" >/dev/null
  fi
done

echo "[icon] Packing .icns -> $OUT_ICNS"
iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"

echo "[icon] Cleanup iconset"
rm -rf "$ICONSET_DIR"

echo "[icon] Done. Generated: $OUT_ICNS"