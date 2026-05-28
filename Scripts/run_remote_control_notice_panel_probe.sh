#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/local_macos_security_notice_panel}"
if [[ "$ARTIFACT_DIR" != /* ]]; then
  ARTIFACT_DIR="$PWD/$ARTIFACT_DIR"
fi

BUILD_DIR="${SKYBRIDGE_SMOKE_BUILD_DIR:-$ROOT_DIR/.build/remote-control-notice-panel-probe}"
STATUS_FILE="$ARTIFACT_DIR/panel_probe.status.log"
STDOUT_FILE="$ARTIFACT_DIR/panel_probe.stdout.log"
BUILD_LOG="$ARTIFACT_DIR/panel_probe.build.log"
TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-30}"
APP_BUNDLE="$BUILD_DIR/SkyBridgeCompassAppPanelProbe.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

mkdir -p "$ARTIFACT_DIR"
rm -f "$STATUS_FILE" "$STDOUT_FILE" "$BUILD_LOG"

echo "==> Building SkyBridgeCompassApp panel probe host"
swift build \
  --build-path "$BUILD_DIR" \
  --product SkyBridgeCompassApp >"$BUILD_LOG" 2>&1

APP_BIN="$BUILD_DIR/debug/SkyBridgeCompassApp"
if [[ ! -x "$APP_BIN" ]]; then
  echo "SkyBridgeCompassApp executable not found: $APP_BIN" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$APP_BIN" "$APP_MACOS/SkyBridgeCompassApp"
cp "$ROOT_DIR/Sources/SkyBridgeCompassApp/Info.plist" "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable SkyBridgeCompassApp" "$APP_CONTENTS/Info.plist" >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string SkyBridgeCompassApp" "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$APP_CONTENTS/Info.plist" >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_CONTENTS/Info.plist"
find "$BUILD_DIR" -path "$APP_BUNDLE" -prune -o -maxdepth 5 -type d -name '*.bundle' -exec cp -R {} "$APP_RESOURCES/" \;
find "$BUILD_DIR" -path "$APP_BUNDLE" -prune -o -maxdepth 5 -type d -name '*.bundle' -exec cp -R {} "$APP_BUNDLE/" \;
find "$BUILD_DIR" -path "$APP_BUNDLE" -prune -o -maxdepth 5 -type d -name '*.framework' -exec cp -R {} "$APP_MACOS/" \;

echo "==> Running remote-control notice AppKit panel probe"
/usr/bin/open \
  -n \
  --wait-apps \
  --stdout "$STDOUT_FILE" \
  --stderr "$STDOUT_FILE" \
  --env "SKYBRIDGE_SMOKE_ROLE=mac-panel-probe" \
  --env "SKYBRIDGE_SMOKE_PANEL_PROBE=1" \
  --env "SKYBRIDGE_SMOKE_STATUS_FILE=$STATUS_FILE" \
  "$APP_BUNDLE" &
PROBE_PID="$!"

deadline=$((SECONDS + TIMEOUT_SECONDS))
while kill -0 "$PROBE_PID" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    kill "$PROBE_PID" >/dev/null 2>&1 || true
    wait "$PROBE_PID" >/dev/null 2>&1 || true
    pkill -f "$APP_BUNDLE" >/dev/null 2>&1 || true
    echo "remote-control notice panel probe timed out after ${TIMEOUT_SECONDS}s" >&2
    tail -n 80 "$STDOUT_FILE" >&2 || true
    exit 1
  fi
  sleep 1
done

wait "$PROBE_PID"

if ! grep -q 'remoteControlNoticePanelPresented' "$STATUS_FILE"; then
  echo "remote-control notice panel probe did not emit panel evidence" >&2
  tail -n 80 "$STATUS_FILE" >&2 || true
  tail -n 80 "$STDOUT_FILE" >&2 || true
  exit 1
fi

echo "==> Panel probe completed successfully"
echo "    status: $STATUS_FILE"
echo "    stdout: $STDOUT_FILE"
