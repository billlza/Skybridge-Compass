#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/real_device_p2p_remote_smoke_$(date +%Y%m%d_%H%M%S)}"
IOS_PROJECT="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_BUNDLE_ID="com.skybridge.compass.ios"
IOS_BUILD_DESTINATION="${SKYBRIDGE_IOS_BUILD_DESTINATION:-generic/platform=iOS}"
SMOKE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-240}"
IOS_LAUNCH_TIMEOUT_SECONDS="$((SMOKE_TIMEOUT_SECONDS + 60))"
SMOKE_REMOTE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_REMOTE_DESKTOP_TIMEOUT_SECONDS:-$SMOKE_TIMEOUT_SECONDS}"
SMOKE_MIN_FPS="${SKYBRIDGE_SMOKE_MIN_FPS:-30}"
SMOKE_TARGET_FPS="${SKYBRIDGE_SMOKE_TARGET_FPS:-60}"
SMOKE_SOAK_SECONDS="${SKYBRIDGE_SMOKE_SOAK_SECONDS:-10}"
SMOKE_VIDEO_WIDTH="${SKYBRIDGE_SMOKE_VIDEO_WIDTH:-2056}"
SMOKE_VIDEO_HEIGHT="${SKYBRIDGE_SMOKE_VIDEO_HEIGHT:-1329}"
SMOKE_EXPECT_RENDER_ORIENTATION="${SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION:-upright}"
RUN_ID="${SKYBRIDGE_SMOKE_P2P_REMOTE_RUN_ID:-$(date +%Y%m%d%H%M%S)}"
PREFERRED_SUITE="${SB_PQC_PREFERRED_SUITE:-xwing}"
HOST_PREFERRED_SUITE="${SB_PQC_HOST_PREFERRED_SUITE:-$PREFERRED_SUITE}"
IOS_PREFERRED_SUITE="${SB_PQC_IOS_PREFERRED_SUITE:-$PREFERRED_SUITE}"
EXPECTED_TARGET_SUITE="${SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE:-X-Wing}"
PRESERVE_INSTALL="${SKYBRIDGE_SMOKE_PRESERVE_INSTALL:-1}"
SWIFTPM_CACHE_DIR="${SKYBRIDGE_SWIFTPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"
SWIFT_MODULE_CACHE_DIR="${SKYBRIDGE_SWIFT_MODULE_CACHE_DIR:-$ROOT_DIR/.swiftpm-module-cache}"

mkdir -p "$ARTIFACT_DIR" "$SWIFTPM_CACHE_DIR" "$SWIFT_MODULE_CACHE_DIR"

pick_real_device_id() {
  python3 - <<'PY'
import re
import subprocess

def pick_from_xctrace():
    output = subprocess.check_output(["xcrun", "xctrace", "list", "devices"], text=True)
    in_devices = False
    for line in output.splitlines():
        stripped = line.strip()
        if stripped == "== Devices ==":
            in_devices = True
            continue
        if stripped.startswith("== ") and stripped != "== Devices ==":
            in_devices = False
        if not in_devices or not stripped or "Mac" in stripped:
            continue
        match = re.search(r"\(([0-9A-Fa-f-]{20,})\)$", stripped)
        if match:
            print(match.group(1))
            return True
    return False

def pick_from_devicectl():
    try:
        output = subprocess.check_output(
            ["xcrun", "devicectl", "list", "devices"],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False

    candidates = []
    for line in output.splitlines():
        if "available" not in line or "paired" not in line:
            continue
        match = re.search(r"([0-9A-Fa-f-]{8}(?:-[0-9A-Fa-f-]{4}){3}-[0-9A-Fa-f-]{12})", line)
        if match:
            candidates.append((0 if "iPad" in line else 1, match.group(1)))

    for _, identifier in sorted(candidates):
        print(identifier)
        return True
    return False

if pick_from_xctrace() or pick_from_devicectl():
    raise SystemExit(0)
raise SystemExit("No connected real iOS device found.")
PY
}

IOS_DEVICE_ID="${SKYBRIDGE_REAL_DEVICE_ID:-$(pick_real_device_id)}"
MAC_TARGET_NAME="${SKYBRIDGE_SMOKE_MAC_TARGET_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"
HOST_STATUS="$ARTIFACT_DIR/mac.status.log"
HOST_PQC_REPORT="$ARTIFACT_DIR/mac.pqc.json"
HOST_STDOUT="$ARTIFACT_DIR/mac.stdout.log"
IOS_STATUS_NAME="ios-p2p-remote-${RUN_ID}.status.log"
IOS_STATUS_LOCAL="$ARTIFACT_DIR/$IOS_STATUS_NAME"
IOS_CONSOLE_STDERR="$ARTIFACT_DIR/ios-console.stderr.log"
IOS_BUILD_LOG="$ARTIFACT_DIR/ios-build.log"
LAUNCH_RESULT_JSON="$ARTIFACT_DIR/ios-launch.json"
DEVICE_INFO_TXT="$ARTIFACT_DIR/device-info.txt"
HOST_PID=""
IOS_CONSOLE_PID=""

cleanup() {
  if [[ -n "$IOS_CONSOLE_PID" ]]; then
    kill "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
    wait "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$HOST_PID" ]]; then
    kill "$HOST_PID" >/dev/null 2>&1 || true
    wait "$HOST_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_file_pattern() {
  local path="$1"
  local pattern="$2"
  local timeout_seconds="$3"
  local label="$4"
  local started_at
  started_at="$(date +%s)"
  while true; do
    if [[ -f "$path" ]] && grep -qE 'failed stage=|classic fallback|compatibility fallback|fallback=true|legacyFallback=true|pipeline=stillImageFallback|orientation=verticalFlip|orientation=horizontalFlip|orientation=inverted|renderOrientation=verticalFlip|renderOrientation=horizontalFlip|renderOrientation=inverted|视频解码队列拥塞|已立即回退|已回退到|fallback producer' "$path"; then
      echo "Detected failure while waiting for ${label}: ${path}" >&2
      tail -n 40 "$path" >&2 || true
      return 1
    fi
    if [[ -f "$path" ]] && grep -qE "$pattern" "$path"; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${path}" >&2
      tail -n 40 "$path" >&2 || true
      return 1
    fi
    sleep 1
  done
}

copy_ios_status() {
  python3 - "$IOS_DEVICE_ID" "$IOS_BUNDLE_ID" "Library/Caches/$IOS_STATUS_NAME" "$IOS_STATUS_LOCAL" <<'PY'
import os
import subprocess
import sys

device_id, bundle_id, source, destination = sys.argv[1:]
temporary_destination = f"{destination}.tmp"
try:
    os.remove(temporary_destination)
except FileNotFoundError:
    pass
command = [
    "xcrun",
    "devicectl",
    "device",
    "copy",
    "from",
    "--device",
    device_id,
    "--domain-type",
    "appDataContainer",
    "--domain-identifier",
    bundle_id,
    "--source",
    source,
    "--destination",
    temporary_destination,
]
try:
    completed = subprocess.run(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=15,
        check=False,
    )
    if completed.returncode == 0 and os.path.exists(temporary_destination):
        os.replace(temporary_destination, destination)
    else:
        try:
            os.remove(temporary_destination)
        except FileNotFoundError:
            pass
except subprocess.TimeoutExpired:
    try:
        os.remove(temporary_destination)
    except FileNotFoundError:
        pass
    pass
PY
}

wait_for_ios_status_pattern() {
  local pattern="$1"
  local timeout_seconds="$2"
  local label="$3"
  local started_at
  local last_status_mtime=0
  local last_status_update_at=0
  started_at="$(date +%s)"
  last_status_update_at="$started_at"
  while true; do
    local now
    now="$(date +%s)"
    if [[ -f "$IOS_STATUS_LOCAL" ]]; then
      local current_status_mtime
      current_status_mtime="$(stat -f %m "$IOS_STATUS_LOCAL" 2>/dev/null || echo 0)"
      if (( current_status_mtime > last_status_mtime )); then
        last_status_mtime="$current_status_mtime"
        last_status_update_at="$now"
      elif (( now - last_status_update_at >= 60 )); then
        echo "Timed out waiting for fresh iOS status while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
        tail -n 80 "$IOS_STATUS_LOCAL" >&2 || true
        tail -n 40 "$IOS_CONSOLE_STDERR" >&2 || true
        return 1
      fi
    fi
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE 'failed stage=|classic fallback|compatibility fallback|fallback=true|legacyFallback=true|crossNetwork=1|pipeline=stillImageFallback|orientation=verticalFlip|orientation=horizontalFlip|orientation=inverted|renderOrientation=verticalFlip|renderOrientation=horizontalFlip|renderOrientation=inverted|视频解码队列拥塞|已立即回退|已回退到|fallback producer' "$IOS_STATUS_LOCAL"; then
      echo "Detected failure while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 80 "$IOS_STATUS_LOCAL" >&2 || true
      tail -n 40 "$IOS_CONSOLE_STDERR" >&2 || true
      return 1
    fi
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE "$pattern" "$IOS_STATUS_LOCAL"; then
      return 0
    fi
    if [[ -n "$IOS_CONSOLE_PID" ]] && ! kill -0 "$IOS_CONSOLE_PID" >/dev/null 2>&1; then
      echo "iOS console process exited while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 80 "$IOS_STATUS_LOCAL" >&2 || true
      tail -n 80 "$IOS_CONSOLE_STDERR" >&2 || true
      return 1
    fi
    if (( now - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 80 "$IOS_STATUS_LOCAL" >&2 || true
      tail -n 40 "$IOS_CONSOLE_STDERR" >&2 || true
      return 1
    fi
    sleep 2
  done
}

echo "==> Artifacts: $ARTIFACT_DIR"
echo "==> Real device: $IOS_DEVICE_ID"
echo "==> Build destination: $IOS_BUILD_DESTINATION"
echo "==> Target: ${SMOKE_VIDEO_WIDTH}x${SMOKE_VIDEO_HEIGHT}@${SMOKE_TARGET_FPS} minFps=${SMOKE_MIN_FPS}"
echo "==> Expected render orientation: $SMOKE_EXPECT_RENDER_ORIENTATION"
echo "==> Expected suite: $EXPECTED_TARGET_SUITE"

xcrun devicectl list devices >"$DEVICE_INFO_TXT" 2>&1 || true

echo "==> Building macOS LAN host"
(
  cd "$ROOT_DIR"
  SWIFTPM_CACHE_PATH="$SWIFTPM_CACHE_DIR" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
  swift build --product LocalLanInteropHost
) >"$ARTIFACT_DIR/macos-build.log"

MAC_APP_BIN="$ROOT_DIR/.build/debug/LocalLanInteropHost"
if [[ ! -x "$MAC_APP_BIN" ]]; then
  echo "macOS LAN host executable not found: $MAC_APP_BIN" >&2
  exit 1
fi

echo "==> Starting macOS LAN host"
SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
SB_PQC_PREFERRED_SUITE="$HOST_PREFERRED_SUITE" \
SKYBRIDGE_SMOKE_ROLE=mac-host \
SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1 \
SKYBRIDGE_SMOKE_STATUS_FILE="$HOST_STATUS" \
SKYBRIDGE_SMOKE_PQC_REPORT_FILE="$HOST_PQC_REPORT" \
SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE="$EXPECTED_TARGET_SUITE" \
"$MAC_APP_BIN" >"$HOST_STDOUT" 2>&1 &
HOST_PID="$!"

wait_for_file_pattern "$HOST_STATUS" 'ready discovery=_skybridge._tcp' 60 "macOS host ready"
wait_for_file_pattern "$HOST_PQC_REPORT" '"deviceId"' 60 "macOS PQC report"

REPORT_DATA="$(python3 - "$HOST_PQC_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
keys = {
    int(entry.get("suiteWireId", -1)): entry.get("publicKeyBase64", "")
    for entry in report.get("keys", [])
}
print(report.get("deviceId", ""))
print(keys.get(0x0001, ""))
print(keys.get(0x0101, ""))
print(keys.get(0x0102, ""))
PY
)"

MAC_PQC_DEVICE_ID="$(printf '%s\n' "$REPORT_DATA" | sed -n '1p')"
MAC_PQC_XWING_PUBLIC_KEY_BASE64="$(printf '%s\n' "$REPORT_DATA" | sed -n '2p')"
MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64="$(printf '%s\n' "$REPORT_DATA" | sed -n '3p')"
MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64="$(printf '%s\n' "$REPORT_DATA" | sed -n '4p')"

if [[ -z "$MAC_PQC_DEVICE_ID" || -z "$MAC_PQC_XWING_PUBLIC_KEY_BASE64" ]]; then
  echo "PQC report is missing required X-Wing identity: $HOST_PQC_REPORT" >&2
  exit 1
fi

echo "==> Building iOS app for real device"
xcodebuild \
  -project "$IOS_PROJECT" \
  -scheme "$IOS_SCHEME" \
  -configuration Debug \
  -destination "$IOS_BUILD_DESTINATION" \
  -derivedDataPath "$ARTIFACT_DIR/DerivedData-ios" \
  build >"$IOS_BUILD_LOG"

IOS_APP_PATH="$ARTIFACT_DIR/DerivedData-ios/Build/Products/Debug-iphoneos/SkyBridgeCompass-iOS.app"
if [[ ! -d "$IOS_APP_PATH" ]]; then
  echo "iOS app bundle not found: $IOS_APP_PATH" >&2
  exit 1
fi

echo "==> Installing iOS app on real device"
if [[ "$PRESERVE_INSTALL" != "1" ]]; then
  xcrun devicectl device uninstall app --device "$IOS_DEVICE_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
else
  echo "    preserving existing install to keep Local Network/TCC grants when possible"
fi
xcrun devicectl device install app --device "$IOS_DEVICE_ID" "$IOS_APP_PATH" >/dev/null

echo "==> Launching iOS P2P remote smoke"
IOS_ENV_JSON="$(
  SKYBRIDGE_SMOKE_TARGET_DEVICE_ID="$MAC_PQC_DEVICE_ID" \
  SKYBRIDGE_SMOKE_TARGET_NAME="$MAC_TARGET_NAME" \
  SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
  SKYBRIDGE_SMOKE_REMOTE_DESKTOP_TIMEOUT_SECONDS="$SMOKE_REMOTE_TIMEOUT_SECONDS" \
  SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_NAME" \
  SKYBRIDGE_SMOKE_MIN_FPS="$SMOKE_MIN_FPS" \
  SKYBRIDGE_SMOKE_TARGET_FPS="$SMOKE_TARGET_FPS" \
  SKYBRIDGE_SMOKE_SOAK_SECONDS="$SMOKE_SOAK_SECONDS" \
  SKYBRIDGE_SMOKE_VIDEO_WIDTH="$SMOKE_VIDEO_WIDTH" \
  SKYBRIDGE_SMOKE_VIDEO_HEIGHT="$SMOKE_VIDEO_HEIGHT" \
  SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION="$SMOKE_EXPECT_RENDER_ORIENTATION" \
  SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE="$EXPECTED_TARGET_SUITE" \
  SB_PQC_PREFERRED_SUITE="$IOS_PREFERRED_SUITE" \
  SKYBRIDGE_PQC_PEER_DEVICE_ID="$MAC_PQC_DEVICE_ID" \
  SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64="$MAC_PQC_XWING_PUBLIC_KEY_BASE64" \
  SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64" \
  SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64" \
  python3 - <<'PY'
import json
import os

keys = [
    "SKYBRIDGE_SMOKE_TARGET_DEVICE_ID",
    "SKYBRIDGE_SMOKE_TARGET_NAME",
    "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS",
    "SKYBRIDGE_SMOKE_REMOTE_DESKTOP_TIMEOUT_SECONDS",
    "SKYBRIDGE_SMOKE_STATUS_BASENAME",
    "SKYBRIDGE_SMOKE_MIN_FPS",
    "SKYBRIDGE_SMOKE_TARGET_FPS",
    "SKYBRIDGE_SMOKE_SOAK_SECONDS",
    "SKYBRIDGE_SMOKE_VIDEO_WIDTH",
    "SKYBRIDGE_SMOKE_VIDEO_HEIGHT",
    "SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION",
    "SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE",
    "SB_PQC_PREFERRED_SUITE",
    "SKYBRIDGE_PQC_PEER_DEVICE_ID",
    "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64",
]
env = {
    "SKYBRIDGE_KEYCHAIN_IN_MEMORY": "1",
    "SKYBRIDGE_SMOKE_ROLE": "ios-p2p-client",
    "SKYBRIDGE_SMOKE_EXPECT_REMOTE_DESKTOP": "1",
    "SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB": "1",
    "SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW": "1",
    "SKYBRIDGE_SMOKE_REQUIRE_AUDIO": "1",
    "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY": "0",
    "SKYBRIDGE_SMOKE_EXTREME_MEDIA": "1",
    "SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK": "1",
}
for key in keys:
    value = os.environ.get(key)
    if value:
        env[key] = value
print(json.dumps(env, ensure_ascii=False))
PY
)"

xcrun devicectl device process launch \
  --device "$IOS_DEVICE_ID" \
  --terminate-existing \
  --console \
  --timeout "$IOS_LAUNCH_TIMEOUT_SECONDS" \
  --environment-variables "$IOS_ENV_JSON" \
  --json-output "$LAUNCH_RESULT_JSON" \
  "$IOS_BUNDLE_ID" >"$IOS_STATUS_LOCAL" 2>"$IOS_CONSOLE_STDERR" &
IOS_CONSOLE_PID="$!"

echo "==> Waiting for P2P handshake"
wait_for_file_pattern "$HOST_STATUS" "success .*suite=${EXPECTED_TARGET_SUITE} .*handshakeOnly=1" "$SMOKE_TIMEOUT_SECONDS" "macOS P2P handshake"
wait_for_ios_status_pattern "success .*suite=${EXPECTED_TARGET_SUITE} .*handshakeOnly=1 .*remoteDesktop=1" "$SMOKE_TIMEOUT_SECONDS" "iOS P2P remote desktop success"
wait_for_ios_status_pattern "remote-desktop-pass .*renderOrientation=${SMOKE_EXPECT_RENDER_ORIENTATION}" "$SMOKE_TIMEOUT_SECONDS" "P2P remote desktop pass window"

echo "==> Real-device P2P remote desktop smoke succeeded"
echo "    mac status: $HOST_STATUS"
echo "    ios status: $IOS_STATUS_LOCAL"
echo "    host stdout: $HOST_STDOUT"
