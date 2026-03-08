#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/local_webrtc_smoke_$(date +%Y%m%d_%H%M%S)}"
SIGNALING_PORT="${SKYBRIDGE_SMOKE_SIGNALING_PORT:-18443}"
SMOKE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-120}"
SMOKE_ROUNDS="${SKYBRIDGE_SMOKE_ROUNDS:-3}"
IOS_BUNDLE_ID="com.skybridge.compass.ios"
MAC_DEVICE_ID="${SKYBRIDGE_SMOKE_MAC_DEVICE_ID:-smoke-mac}"
IOS_DEVICE_ID="${SKYBRIDGE_SMOKE_IOS_DEVICE_ID:-smoke-ios}"

mkdir -p "$ARTIFACT_DIR"

pick_simulator_id() {
  local payload
  payload="$(xcrun simctl list devices available -j)"
  python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
preferred = ["iPhone 16e", "iPhone 16", "iPhone 15", "iPhone 14"]
devices = []
for runtime_devices in payload.get("devices", {}).values():
    for device in runtime_devices:
        if device.get("isAvailable"):
            devices.append(device)

for name in preferred:
    for device in devices:
        if device.get("name") == name:
            print(device["udid"])
            raise SystemExit(0)

for device in devices:
    if "iPhone" in device.get("name", ""):
        print(device["udid"])
        raise SystemExit(0)

raise SystemExit("No available iPhone simulator found.")
' "$payload"
}

SIM_ID="${SKYBRIDGE_SMOKE_SIMULATOR_ID:-$(pick_simulator_id)}"

SIGNALING_SERVER_URL="http://127.0.0.1:${SIGNALING_PORT}"
SIGNALING_WS_URL="ws://127.0.0.1:${SIGNALING_PORT}/ws"

SIGNALING_PID=""
MAC_PID=""
IOS_STATUS_PATH=""
MAC_STDOUT=""
IOS_STDOUT=""
IOS_STDERR=""

cleanup() {
  if [[ -n "${MAC_PID}" ]]; then
    kill "${MAC_PID}" >/dev/null 2>&1 || true
    wait "${MAC_PID}" >/dev/null 2>&1 || true
  fi
  xcrun simctl terminate "${SIM_ID}" "${IOS_BUNDLE_ID}" >/dev/null 2>&1 || true
  if [[ -n "${SIGNALING_PID}" ]]; then
    kill "${SIGNALING_PID}" >/dev/null 2>&1 || true
    wait "${SIGNALING_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_http_ok() {
  local url="$1"
  local timeout_seconds="$2"
  local started_at
  started_at="$(date +%s)"
  while true; do
    if curl --silent --fail "$url" >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${url}" >&2
      return 1
    fi
    sleep 1
  done
}

wait_for_file_nonempty() {
  local path="$1"
  local timeout_seconds="$2"
  local label="$3"
  local started_at
  started_at="$(date +%s)"
  while true; do
    if [[ -s "$path" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${path}" >&2
      return 1
    fi
    sleep 1
  done
}

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

echo "==> Artifacts: ${ARTIFACT_DIR}"
echo "==> Simulator: ${SIM_ID}"

echo "==> Building macOS smoke host"
MAC_BUILD_LOG="$ARTIFACT_DIR/macos-build.log"
(
  cd "$ROOT_DIR"
  swift build --product LocalWebRTCSmokeHost
) >"$MAC_BUILD_LOG"

MAC_APP_BIN="$ROOT_DIR/.build/debug/LocalWebRTCSmokeHost"
if [[ ! -x "$MAC_APP_BIN" ]]; then
  echo "macOS smoke host executable not found: $MAC_APP_BIN" >&2
  exit 1
fi

echo "==> Booting simulator"
xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_ID" -b

echo "==> Building iOS app"
IOS_BUILD_LOG="$ARTIFACT_DIR/ios-build.log"
xcodebuild \
  -project "$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" \
  -scheme 'SkyBridgeCompass-iOS' \
  -configuration Debug \
  -destination "id=${SIM_ID}" \
  -derivedDataPath "$ARTIFACT_DIR/DerivedData-ios" \
  build >"$IOS_BUILD_LOG"

IOS_APP_PATH="$ARTIFACT_DIR/DerivedData-ios/Build/Products/Debug-iphonesimulator/SkyBridgeCompass-iOS.app"
if [[ ! -d "$IOS_APP_PATH" ]]; then
  echo "iOS app bundle not found: $IOS_APP_PATH" >&2
  exit 1
fi

echo "==> Installing iOS app"
xcrun simctl uninstall "$SIM_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM_ID" "$IOS_APP_PATH"
IOS_CONTAINER="$(xcrun simctl get_app_container "$SIM_ID" "$IOS_BUNDLE_ID" data)"

echo "==> Starting local signaling server"
pushd "$ROOT_DIR/Server/skybridge-signaling" >/dev/null
HOST=127.0.0.1 \
PORT="$SIGNALING_PORT" \
TURN_ENFORCE_API_KEY=false \
node server.js >"$ARTIFACT_DIR/signaling.log" 2>&1 &
SIGNALING_PID="$!"
popd >/dev/null
wait_for_http_ok "${SIGNALING_SERVER_URL}/healthz" 20

for round in $(seq 1 "$SMOKE_ROUNDS"); do
  echo "==> Smoke round ${round}/${SMOKE_ROUNDS}"

  MAC_STATUS="$ARTIFACT_DIR/mac_round_${round}.status.log"
  MAC_CODE="$ARTIFACT_DIR/mac_round_${round}.code"
  MAC_STDOUT="$ARTIFACT_DIR/mac_round_${round}.stdout.log"
  IOS_STATUS_BASENAME="ios_round_${round}.status.log"
  IOS_STATUS_PATH="$IOS_CONTAINER/Library/Caches/${IOS_STATUS_BASENAME}"
  IOS_STDOUT="$ARTIFACT_DIR/ios_round_${round}.stdout.log"
  IOS_STDERR="$ARTIFACT_DIR/ios_round_${round}.stderr.log"
  ROUND_MAC_DEVICE_ID="${MAC_DEVICE_ID}-${round}"
  ROUND_IOS_DEVICE_ID="${IOS_DEVICE_ID}-${round}"

  rm -f "$MAC_STATUS" "$MAC_CODE" "$MAC_STDOUT" "$IOS_STATUS_PATH" "$IOS_STDOUT" "$IOS_STDERR"

  xcrun simctl terminate "$SIM_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -n "${MAC_PID}" ]]; then
    kill "${MAC_PID}" >/dev/null 2>&1 || true
    wait "${MAC_PID}" >/dev/null 2>&1 || true
    MAC_PID=""
  fi
  pkill -x LocalWebRTCSmokeHost >/dev/null 2>&1 || true

  SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
  SKYBRIDGE_DEVICE_ID="$ROUND_MAC_DEVICE_ID" \
  SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
  SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
  SKYBRIDGE_STUN_URL="" \
  SKYBRIDGE_TURN_URLS="" \
  SKYBRIDGE_SMOKE_ROLE=mac-host \
  SKYBRIDGE_SMOKE_STATUS_FILE="$MAC_STATUS" \
  SKYBRIDGE_SMOKE_CODE_FILE="$MAC_CODE" \
  SKYBRIDGE_SMOKE_SYNTHETIC_SCREEN=1 \
  SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1 \
  SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1 \
  SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
  "$MAC_APP_BIN" >"$MAC_STDOUT" 2>&1 &
  MAC_PID="$!"

  wait_for_file_nonempty "$MAC_CODE" 60 "macOS connection code"
  CONNECTION_CODE="$(tr -d '\r\n' < "$MAC_CODE")"
  if [[ -z "$CONNECTION_CODE" ]]; then
    echo "macOS smoke produced an empty connection code" >&2
    exit 1
  fi

  SIMCTL_CHILD_SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
  SIMCTL_CHILD_SKYBRIDGE_DEVICE_ID="$ROUND_IOS_DEVICE_ID" \
  SIMCTL_CHILD_SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
  SIMCTL_CHILD_SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
  SIMCTL_CHILD_SKYBRIDGE_STUN_URL="" \
  SIMCTL_CHILD_SKYBRIDGE_TURN_URLS="" \
  SIMCTL_CHILD_SKYBRIDGE_SMOKE_ROLE=ios-client \
  SIMCTL_CHILD_SKYBRIDGE_SMOKE_CONNECT_CODE="$CONNECTION_CODE" \
  SIMCTL_CHILD_SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_BASENAME" \
  SIMCTL_CHILD_SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
  xcrun simctl launch \
    --terminate-running-process \
    --stdout="$IOS_STDOUT" \
    --stderr="$IOS_STDERR" \
    "$SIM_ID" \
    "$IOS_BUNDLE_ID" >/dev/null

  wait_for_file_pattern "$MAC_STATUS" 'success session=' "$SMOKE_TIMEOUT_SECONDS" "macOS success"
  wait_for_file_pattern "$IOS_STATUS_PATH" 'success frame=' "$SMOKE_TIMEOUT_SECONDS" "iOS success"

  echo "   macOS: $(tail -n 1 "$MAC_STATUS")"
  echo "   iOS:   $(tail -n 1 "$IOS_STATUS_PATH")"
done

echo "==> Smoke completed successfully"
echo "    signaling log: $ARTIFACT_DIR/signaling.log"
echo "    mac logs:      $ARTIFACT_DIR/mac_round_*.stdout.log"
echo "    ios logs:      $ARTIFACT_DIR/ios_round_*.stdout.log"
