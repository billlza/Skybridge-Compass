#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/real_device_file_smoke_$(date +%Y%m%d_%H%M%S)}"
IOS_PROJECT="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_BUNDLE_ID="com.skybridge.compass.ios"
SMOKE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-180}"
RUN_ID="${SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID:-$(date +%Y%m%d%H%M%S)}"
PREFERRED_SUITE="${SB_PQC_PREFERRED_SUITE:-xwing}"
HOST_PREFERRED_SUITE="${SB_PQC_HOST_PREFERRED_SUITE:-$PREFERRED_SUITE}"
IOS_PREFERRED_SUITE="${SB_PQC_IOS_PREFERRED_SUITE:-$PREFERRED_SUITE}"
EXPECTED_TARGET_SUITE="${SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE:-}"
EXPECT_PQC_REKEY="${SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY:-1}"
PRESERVE_INSTALL="${SKYBRIDGE_SMOKE_PRESERVE_INSTALL:-1}"
SWIFTPM_CACHE_DIR="${SKYBRIDGE_SWIFTPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"
SWIFT_MODULE_CACHE_DIR="${SKYBRIDGE_SWIFT_MODULE_CACHE_DIR:-$ROOT_DIR/.swiftpm-module-cache}"

mkdir -p "$ARTIFACT_DIR"
mkdir -p "$SWIFTPM_CACHE_DIR" "$SWIFT_MODULE_CACHE_DIR"

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
        if not in_devices:
            continue
        if not stripped or "Mac" in stripped:
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
        if not match:
            continue
        priority = 0 if "iPad" in line else 1
        candidates.append((priority, match.group(1)))

    for _, identifier in sorted(candidates):
        try:
            details = subprocess.check_output(
                ["xcrun", "devicectl", "device", "info", "details", "--device", identifier],
                stderr=subprocess.STDOUT,
                text=True,
                timeout=30,
            )
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            continue
        udid = re.search(r"udid:\s*([0-9A-Fa-f-]{20,})", details)
        print(udid.group(1) if udid else identifier)
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
IOS_STATUS_NAME="ios-real-device-${RUN_ID}.status.log"
IOS_STATUS_LOCAL="$ARTIFACT_DIR/$IOS_STATUS_NAME"
IOS_BUILD_LOG="$ARTIFACT_DIR/ios-build.log"
DEVICE_INFO_JSON="$ARTIFACT_DIR/device-info.json"
LAUNCH_RESULT_JSON="$ARTIFACT_DIR/ios-launch.json"
HOST_PID=""

cleanup() {
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
    if [[ -f "$path" ]] && grep -qE "$pattern" "$path"; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${path}" >&2
      return 1
    fi
    sleep 1
  done
}

copy_ios_status() {
  rm -f "$IOS_STATUS_LOCAL"
  xcrun devicectl device copy from \
    --device "$IOS_DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$IOS_BUNDLE_ID" \
    --source "Library/Caches/$IOS_STATUS_NAME" \
    --destination "$IOS_STATUS_LOCAL" >/dev/null 2>&1 || true
}

wait_for_ios_status_pattern() {
  local pattern="$1"
  local timeout_seconds="$2"
  local label="$3"
  local started_at
  started_at="$(date +%s)"
  while true; do
    copy_ios_status
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE "$pattern" "$IOS_STATUS_LOCAL"; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      return 1
    fi
    sleep 2
  done
}

capture_device_info() {
  local attempts="${SKYBRIDGE_SMOKE_DEVICE_INFO_ATTEMPTS:-3}"
  local attempt
  for attempt in $(seq 1 "$attempts"); do
    if xcrun devicectl list devices --json-output "$DEVICE_INFO_JSON" >/dev/null; then
      return 0
    fi
    echo "    devicectl JSON device list failed (${attempt}/${attempts})" >&2
    sleep 2
  done

  echo "    warning: continuing after devicectl JSON device list failed" >&2
  xcrun devicectl list devices >"$ARTIFACT_DIR/device-info.txt" 2>&1 || true
  python3 - "$DEVICE_INFO_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"deviceInfoCapture": "failed"}, handle)
PY
}

ensure_ios_classic_fallback_pref() {
  local plist_path="$ARTIFACT_DIR/device-preferences.plist"
  python3 - "$plist_path" <<'PY'
import plistlib
import sys

path = sys.argv[1]
payload = {"pqc_allow_classic_fallback": True}
with open(path, "wb") as handle:
    plistlib.dump(payload, handle)
PY

  xcrun devicectl device copy to \
    --device "$IOS_DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$IOS_BUNDLE_ID" \
    --source "$plist_path" \
    --destination "Library/Preferences/com.skybridge.compass.ios.plist" >/dev/null
}

echo "==> Artifacts: $ARTIFACT_DIR"
echo "==> Real device: $IOS_DEVICE_ID"
echo "==> Run ID: $RUN_ID"
echo "==> Host preferred suite: $HOST_PREFERRED_SUITE"
echo "==> iOS preferred suite: $IOS_PREFERRED_SUITE"
if [[ -n "$EXPECTED_TARGET_SUITE" ]]; then
  echo "==> Expected negotiated suite: $EXPECTED_TARGET_SUITE"
fi
echo "==> Expect PQC rekey: $EXPECT_PQC_REKEY"
echo "==> Preserve installed app: $PRESERVE_INSTALL"

echo "==> Inspecting connected device"
capture_device_info

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
SKYBRIDGE_SMOKE_ENABLE_COMPATIBILITY_MODE=1 \
SKYBRIDGE_SMOKE_STATUS_FILE="$HOST_STATUS" \
SKYBRIDGE_SMOKE_PQC_REPORT_FILE="$HOST_PQC_REPORT" \
SKYBRIDGE_SMOKE_EXPECT_FILE_TRANSFER=1 \
SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY="$EXPECT_PQC_REKEY" \
SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE="$EXPECTED_TARGET_SUITE" \
SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID="$RUN_ID" \
"$MAC_APP_BIN" >"$HOST_STDOUT" 2>&1 &
HOST_PID="$!"

wait_for_file_pattern "$HOST_STATUS" 'ready discovery=_skybridge._tcp' 60 "macOS host ready"
wait_for_file_pattern "$HOST_PQC_REPORT" '"deviceId"' 60 "macOS PQC report"

echo "==> Parsing macOS PQC report"
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

if [[ -z "$MAC_PQC_DEVICE_ID" ]]; then
  echo "PQC report is missing deviceId: $HOST_PQC_REPORT" >&2
  exit 1
fi

echo "==> Building iOS app for real device"
xcodebuild \
  -project "$IOS_PROJECT" \
  -scheme "$IOS_SCHEME" \
  -configuration Debug \
  -destination "id=$IOS_DEVICE_ID" \
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

if [[ "$EXPECT_PQC_REKEY" == "1" ]]; then
  echo "==> Enabling classic bootstrap fallback for smoke"
  ensure_ios_classic_fallback_pref
fi

echo "==> Launching iOS smoke app"
echo "    if the iPad shows a Local Network permission alert, tap Allow"
IOS_ENV_JSON="$(
  SKYBRIDGE_SMOKE_TARGET_DEVICE_ID="$MAC_PQC_DEVICE_ID" \
  SKYBRIDGE_SMOKE_TARGET_NAME="$MAC_TARGET_NAME" \
  SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
  SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_NAME" \
  SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID="$RUN_ID" \
  SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY="$EXPECT_PQC_REKEY" \
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
    "SKYBRIDGE_SMOKE_STATUS_BASENAME",
    "SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID",
    "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY",
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
    "SKYBRIDGE_SMOKE_EXPECT_FILE_TRANSFER": "1",
}
for key in keys:
    value = os.environ.get(key)
    if value:
        env[key] = value

if env.get("SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY") == "1":
    for key in [
        "SKYBRIDGE_PQC_PEER_DEVICE_ID",
        "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64",
        "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64",
        "SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64",
    ]:
        env.pop(key, None)

print(json.dumps(env, ensure_ascii=False))
PY
)"

xcrun devicectl device process launch \
  --device "$IOS_DEVICE_ID" \
  --terminate-existing \
  --environment-variables "$IOS_ENV_JSON" \
  --json-output "$LAUNCH_RESULT_JSON" \
  "$IOS_BUNDLE_ID" >/dev/null

echo "==> Waiting for macOS inbound transfer"
wait_for_file_pattern "$HOST_STATUS" 'file-transfer inbound-complete name=ios-smoke-'"$RUN_ID"'.txt' "$SMOKE_TIMEOUT_SECONDS" "macOS inbound transfer"

echo "==> Waiting for iOS inbound transfer"
wait_for_ios_status_pattern 'file-transfer inbound-complete name=mac-smoke-'"$RUN_ID"'.txt' "$SMOKE_TIMEOUT_SECONDS" "iOS inbound transfer"

echo "==> Waiting for smoke success markers"
if [[ -n "$EXPECTED_TARGET_SUITE" ]]; then
  wait_for_file_pattern "$HOST_STATUS" "success .*suite=${EXPECTED_TARGET_SUITE} .*fileTransfer=1" "$SMOKE_TIMEOUT_SECONDS" "macOS file-transfer success"
  wait_for_ios_status_pattern "success .*suite=${EXPECTED_TARGET_SUITE} .*fileTransfer=1" "$SMOKE_TIMEOUT_SECONDS" "iOS file-transfer success"
else
  wait_for_file_pattern "$HOST_STATUS" 'success .*fileTransfer=1' "$SMOKE_TIMEOUT_SECONDS" "macOS file-transfer success"
  wait_for_ios_status_pattern 'success .*fileTransfer=1' "$SMOKE_TIMEOUT_SECONDS" "iOS file-transfer success"
fi

echo "==> Real-device bidirectional file transfer smoke succeeded"
echo "    mac status: $HOST_STATUS"
echo "    ios status: $IOS_STATUS_LOCAL"
echo "    host stdout: $HOST_STDOUT"
