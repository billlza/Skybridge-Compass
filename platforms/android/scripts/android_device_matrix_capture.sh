#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/android_env.sh"

OUTPUT_DIR="artifacts/screenshots/android/actual"
APP_PACKAGE="com.skybridge.compass.debug"
APP_ACTIVITY="com.skybridge.compass.android.MainActivity"
WAIT_SECONDS="2.2"
SHOULD_BUILD_AND_INSTALL=1
APK_PATH=""
DEVICE_FILTER=""
ROUTES_CSV="dashboard,device_discovery,file_transfer,remote_control,settings,settings/device_auth,settings/encryption,settings/access_control,settings/privacy,settings/webrtc,settings/help,settings/feedback,settings/licenses,settings/version"

usage() {
  cat <<'EOF'
Usage: scripts/android_device_matrix_capture.sh [options]

Options:
  --output-dir <dir>         Screenshot output root (default: artifacts/screenshots/android/actual)
  --package <package>        Android package name (default: com.skybridge.compass.debug)
  --activity <activity>      Activity class name (default: com.skybridge.compass.android.MainActivity)
  --routes <csv>             Route list, comma-separated
  --devices <csv>            Restrict to specific adb serials (comma-separated)
  --wait-seconds <float>     Wait after launch before screenshot (default: 2.2)
  --apk-path <path>          Prebuilt APK path; skips auto-discovery
  --no-build                 Skip :app:assembleDebug and install
  -h, --help                 Show this help

Examples:
  scripts/android_device_matrix_capture.sh
  scripts/android_device_matrix_capture.sh --devices "R5CX91...,emulator-5554"
  scripts/android_device_matrix_capture.sh --routes "dashboard,settings,settings/privacy"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --package) APP_PACKAGE="$2"; shift 2 ;;
    --activity) APP_ACTIVITY="$2"; shift 2 ;;
    --routes) ROUTES_CSV="$2"; shift 2 ;;
    --devices) DEVICE_FILTER="$2"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
    --apk-path) APK_PATH="$2"; shift 2 ;;
    --no-build) SHOULD_BUILD_AND_INSTALL=0; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

ADB_BIN="$(resolve_adb_bin "$ROOT_DIR" || true)"
if [[ -z "$ADB_BIN" ]]; then
  echo "adb not found; checked PATH, local.properties, and common Android SDK locations" >&2
  exit 1
fi

IFS=',' read -r -a ROUTES <<<"$ROUTES_CSV"

mapfile -t CONNECTED_DEVICES < <("$ADB_BIN" devices | awk 'NR>1 && $2=="device" {print $1}')
if [[ ${#CONNECTED_DEVICES[@]} -eq 0 ]]; then
  echo "No connected Android devices (adb devices)" >&2
  exit 1
fi

TARGET_DEVICES=()
if [[ -n "$DEVICE_FILTER" ]]; then
  IFS=',' read -r -a FILTERED <<<"$DEVICE_FILTER"
  for dev in "${FILTERED[@]}"; do
    dev="$(echo "$dev" | xargs)"
    if printf '%s\n' "${CONNECTED_DEVICES[@]}" | grep -qx "$dev"; then
      TARGET_DEVICES+=("$dev")
    else
      echo "Warning: requested device not connected: $dev" >&2
    fi
  done
else
  TARGET_DEVICES=("${CONNECTED_DEVICES[@]}")
fi

if [[ ${#TARGET_DEVICES[@]} -eq 0 ]]; then
  echo "No valid target devices found" >&2
  exit 1
fi

if [[ "$SHOULD_BUILD_AND_INSTALL" -eq 1 ]]; then
  echo "==> Building debug APK"
  ./gradlew :app:assembleDebug --no-daemon

  if [[ -z "$APK_PATH" ]]; then
    APK_PATH="$(find app/build/outputs/apk/debug -type f -name "*.apk" | head -n 1 || true)"
  fi
  if [[ -z "$APK_PATH" || ! -f "$APK_PATH" ]]; then
    echo "Could not find debug APK; pass --apk-path explicitly" >&2
    exit 1
  fi

  echo "==> Installing APK to target devices: $APK_PATH"
  for serial in "${TARGET_DEVICES[@]}"; do
    "$ADB_BIN" -s "$serial" install -r "$APK_PATH" >/dev/null
  done
fi

mkdir -p "$OUTPUT_DIR"
MATRIX_CSV="$OUTPUT_DIR/matrix.csv"
ROUTES_TXT="$OUTPUT_DIR/routes.txt"
echo "serial,model,api_level,android_release,wm_size,wm_density" >"$MATRIX_CSV"
printf "%s\n" "${ROUTES[@]}" >"$ROUTES_TXT"

sanitize_route() {
  echo "$1" | sed -E 's#[^A-Za-z0-9._-]+#_#g' | sed -E 's#_+#_#g' | sed -E 's#^_|_$##g'
}

for serial in "${TARGET_DEVICES[@]}"; do
  echo "==> Capturing device: $serial"
  "$ADB_BIN" -s "$serial" wait-for-device

  model="$("$ADB_BIN" -s "$serial" shell getprop ro.product.model | tr -d '\r')"
  api_level="$("$ADB_BIN" -s "$serial" shell getprop ro.build.version.sdk | tr -d '\r')"
  android_release="$("$ADB_BIN" -s "$serial" shell getprop ro.build.version.release | tr -d '\r')"
  wm_size="$("$ADB_BIN" -s "$serial" shell wm size | tr -d '\r' | sed 's/.*: //')"
  wm_density="$("$ADB_BIN" -s "$serial" shell wm density | tr -d '\r' | sed 's/.*: //')"
  echo "\"$serial\",\"$model\",\"$api_level\",\"$android_release\",\"$wm_size\",\"$wm_density\"" >>"$MATRIX_CSV"

  "$ADB_BIN" -s "$serial" shell settings put system font_scale 1.0 >/dev/null || true
  "$ADB_BIN" -s "$serial" shell settings put global window_animation_scale 0 >/dev/null || true
  "$ADB_BIN" -s "$serial" shell settings put global transition_animation_scale 0 >/dev/null || true
  "$ADB_BIN" -s "$serial" shell settings put global animator_duration_scale 0 >/dev/null || true

  device_dir="$OUTPUT_DIR/$serial"
  mkdir -p "$device_dir"

  for route in "${ROUTES[@]}"; do
    route="$(echo "$route" | xargs)"
    [[ -z "$route" ]] && continue
    route_file="$(sanitize_route "$route")"
    out_png="$device_dir/${route_file}.png"

    "$ADB_BIN" -s "$serial" shell am start -W -S \
      -n "${APP_PACKAGE}/${APP_ACTIVITY}" \
      --ez skybridge.force_visual_test_mode true \
      --ez skybridge.bypass_auth true \
      --es skybridge.nav_route "$route" >/dev/null

    sleep "$WAIT_SECONDS"
    "$ADB_BIN" -s "$serial" exec-out screencap -p >"$out_png"
    echo "  - $route -> $out_png"
  done
done

echo "Done. Screenshots in: $OUTPUT_DIR"
echo "Matrix metadata: $MATRIX_CSV"
