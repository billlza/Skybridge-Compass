#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")"/.. && pwd)"
RES_DIR="$ROOT_DIR/macos/SkyBridgeCompassApp/Sources/SkyBridgeCompassApp/Resources"
OUT_PNG="$RES_DIR/AppIcon.png"

echo "[icon] Saving clipboard image -> $OUT_PNG"
if ! osascript -l JavaScript "$ROOT_DIR/scripts/save-clipboard-app-icon.jxa" "$OUT_PNG"; then
  echo "[icon] JXA 保存失败，尝试 AppleScript 方式"
  osascript <<APPLESCRIPT
on writeBytes(f, bytes)
  set fh to open for access f with write permission
  set eof of fh to 0
  write bytes to fh
  close access fh
end writeBytes

try
  set outPng to POSIX file "$OUT_PNG"
  set theData to the clipboard as «class PNGf»
  my writeBytes(outPng, theData)
on error
  try
    set outPng to POSIX file "$OUT_PNG"
    set theData to the clipboard as «class TIFF»
    my writeBytes(outPng, theData)
  on error errMsg
    display dialog "剪贴板中未检测到图片：" & errMsg buttons {"确定"}
    error errMsg
  end try
end try
APPLESCRIPT
fi

echo "[icon] Ensuring 1024x1024 with sips"
sips -s format png -z 1024 1024 "$OUT_PNG" --out "$OUT_PNG" >/dev/null

echo "[icon] Done: $OUT_PNG"