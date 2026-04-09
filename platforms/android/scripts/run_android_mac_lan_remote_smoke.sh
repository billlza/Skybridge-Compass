#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/android_env.sh"
DEFAULT_MAC_PACKAGE_PATH="/Users/bill/Desktop/SkyBridge Compass Pro release"
DEFAULT_ACTIVITY="com.skybridge.compass.debug/com.skybridge.compass.android.debug.DebugLanInteropSmokeActivity"

DEVICE_SERIAL=""
MAC_PACKAGE_PATH="$DEFAULT_MAC_PACKAGE_PATH"
EXPECTED_SERVICE_NAME=""
EXPECTED_DEVICE_ID=""
EXPECTED_FINGERPRINT=""
DIRECT_HOST=""
DIRECT_PORT="5901"
TIMEOUT_SECONDS="120"
REQUIRE_SECURE="true"
ALLOW_PLAINTEXT_FALLBACK="false"
START_MAC_HOST="true"
RUN_DIR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/run_android_mac_lan_remote_smoke.sh \
    --device <adb-serial> \
    [--mac-package-path <path>] \
    [--expected-service-name <name>] \
    [--expected-device-id <device-id>] \
    [--expected-fingerprint <pubkey-fingerprint>] \
    [--host <ip-or-hostname>] \
    [--port <tcp-port>] \
    [--timeout-seconds <n>] \
    [--require-secure true|false] \
    [--allow-plaintext-fallback true|false] \
    [--start-mac-host true|false] \
    [--run-dir <path>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      DEVICE_SERIAL="${2:-}"
      shift 2
      ;;
    --mac-package-path)
      MAC_PACKAGE_PATH="${2:-}"
      shift 2
      ;;
    --expected-service-name)
      EXPECTED_SERVICE_NAME="${2:-}"
      shift 2
      ;;
    --expected-device-id)
      EXPECTED_DEVICE_ID="${2:-}"
      shift 2
      ;;
    --expected-fingerprint)
      EXPECTED_FINGERPRINT="${2:-}"
      shift 2
      ;;
    --host)
      DIRECT_HOST="${2:-}"
      shift 2
      ;;
    --port)
      DIRECT_PORT="${2:-}"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --require-secure)
      REQUIRE_SECURE="${2:-}"
      shift 2
      ;;
    --allow-plaintext-fallback)
      ALLOW_PLAINTEXT_FALLBACK="${2:-}"
      shift 2
      ;;
    --start-mac-host)
      START_MAC_HOST="${2:-}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$DEVICE_SERIAL" ]]; then
  usage >&2
  exit 1
fi

ADB_BIN="$(resolve_adb_bin "$ROOT_DIR" || true)"
if [[ -z "$ADB_BIN" ]]; then
  echo "adb not found; checked PATH, local.properties, and common Android SDK locations" >&2
  exit 1
fi

if [[ "$START_MAC_HOST" == "true" ]] && ! command -v swift >/dev/null 2>&1; then
  echo "swift not found in PATH" >&2
  exit 1
fi

if [[ "$START_MAC_HOST" == "true" && ! -d "$MAC_PACKAGE_PATH" ]]; then
  echo "mac package path not found: $MAC_PACKAGE_PATH" >&2
  exit 1
fi

IDENTITY_SOURCE="manual"
if [[ -z "$EXPECTED_DEVICE_ID" ]]; then
  EXPECTED_DEVICE_ID="$(
    security find-generic-password -s 'SkyBridge.SelfIdentity' -a 'deviceId' -w 2>/dev/null \
      | tr -d '\r\n'
  )"
  if [[ -n "$EXPECTED_DEVICE_ID" ]]; then
    IDENTITY_SOURCE="self_identity"
  fi
fi

if [[ -z "$EXPECTED_DEVICE_ID" || ( -z "$EXPECTED_FINGERPRINT" && "$IDENTITY_SOURCE" != "self_identity" ) ]]; then
  SETTINGS_JSON="$HOME/Library/Application Support/com.SkyBridge.Compass/settings.json"
  if [[ -f "$SETTINGS_JSON" ]]; then
    if [[ -z "$EXPECTED_DEVICE_ID" ]]; then
      EXPECTED_DEVICE_ID="$(plutil -extract device.device_id raw -o - "$SETTINGS_JSON" 2>/dev/null || true)"
      if [[ -n "$EXPECTED_DEVICE_ID" ]]; then
        IDENTITY_SOURCE="settings_json"
      fi
    fi
    if [[ -z "$EXPECTED_FINGERPRINT" && "$IDENTITY_SOURCE" == "settings_json" ]]; then
      EXPECTED_FINGERPRINT="$(plutil -extract device.public_key_fingerprint raw -o - "$SETTINGS_JSON" 2>/dev/null || true)"
    fi
  fi
fi

if [[ -z "$EXPECTED_FINGERPRINT" ]]; then
  MLDSA_PUBLIC_KEY_HEX="$(
    security find-generic-password -s 'com.skybridge.p2p.identity.mldsa65' -a 'mldsa65_publicKey' -w 2>/dev/null \
      | tr -d '\r\n'
  )"
  if [[ -n "$MLDSA_PUBLIC_KEY_HEX" ]]; then
    EXPECTED_FINGERPRINT="$(
      python3 - "$MLDSA_PUBLIC_KEY_HEX" <<'PY'
import hashlib
import sys

hex_key = sys.argv[1].strip()
raw = bytes.fromhex(hex_key)
encoded = bytes([0x02]) + len(raw).to_bytes(2, "little") + raw + bytes([0x00])
print(hashlib.sha256(encoded).hexdigest())
PY
    )"
    if [[ -n "$EXPECTED_FINGERPRINT" ]]; then
      IDENTITY_SOURCE="${IDENTITY_SOURCE}+mldsa65_fingerprint"
    fi
  fi
fi

PEER_MLKEM_PUBLIC_B64=""
PEER_XWING_PUBLIC_B64=""
PEER_MLKEM_ACCOUNT=""
PEER_XWING_ACCOUNT=""

extract_kem_public_key_b64() {
  local result_var="$1"
  local account_var="$2"
  shift 2

  local candidate=""
  local account=""
  local raw_json=""
  local public_key_b64=""

  for candidate in "$@"; do
    raw_json="$(
      security find-generic-password -s 'com.skybridge.p2p.identity.kem' -a "$candidate" -w 2>/dev/null \
        | tr -d '\r\n'
    )"
    if [[ -z "$raw_json" ]]; then
      continue
    fi
    public_key_b64="$(python3 - "$raw_json" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(payload.get("publicKey", ""))
PY
)"
    if [[ -n "$public_key_b64" ]]; then
      account="$candidate"
      break
    fi
  done

  printf -v "$result_var" '%s' "$public_key_b64"
  printf -v "$account_var" '%s' "$account"
}

extract_kem_public_key_b64 \
  PEER_MLKEM_PUBLIC_B64 \
  PEER_MLKEM_ACCOUNT \
  'kem_key_257-liboqsPQC' \
  'kem_key_257-nativePQC' \
  'kem_key_257'
extract_kem_public_key_b64 \
  PEER_XWING_PUBLIC_B64 \
  PEER_XWING_ACCOUNT \
  'kem_key_1-nativePQC' \
  'kem_key_1'

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$ROOT_DIR/build/interop/android-mac-lan-smoke/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$RUN_DIR"

ENV_FILE="$RUN_DIR/environment.txt"
COMMAND_FILE="$RUN_DIR/command.txt"
INSTALL_LOG="$RUN_DIR/android-install.log"
ANDROID_LOGCAT_LOG="$RUN_DIR/android-logcat.txt"
STATUS_LOG="$RUN_DIR/android-status.log"
SUMMARY_FILE="$RUN_DIR/summary.txt"
HOST_LOG="$RUN_DIR/mac-host.log"
HOST_PID=""

cleanup() {
  if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" >/dev/null 2>&1; then
    kill "$HOST_PID" >/dev/null 2>&1 || true
    wait "$HOST_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cat >"$COMMAND_FILE" <<EOF
script=scripts/run_android_mac_lan_remote_smoke.sh
device=$DEVICE_SERIAL
mac_package_path=$MAC_PACKAGE_PATH
expected_service_name=$EXPECTED_SERVICE_NAME
expected_device_id=$EXPECTED_DEVICE_ID
expected_fingerprint=$EXPECTED_FINGERPRINT
identity_source=$IDENTITY_SOURCE
peer_mlkem_public_b64_length=${#PEER_MLKEM_PUBLIC_B64}
peer_xwing_public_b64_length=${#PEER_XWING_PUBLIC_B64}
peer_mlkem_account=${PEER_MLKEM_ACCOUNT:-missing}
peer_xwing_account=${PEER_XWING_ACCOUNT:-missing}
direct_host=$DIRECT_HOST
direct_port=$DIRECT_PORT
timeout_seconds=$TIMEOUT_SECONDS
require_secure=$REQUIRE_SECURE
allow_plaintext_fallback=$ALLOW_PLAINTEXT_FALLBACK
start_mac_host=$START_MAC_HOST
run_dir=$RUN_DIR
EOF

{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "adb=$("$ADB_BIN" version 2>/dev/null | head -n 1)"
  echo "device_model=$("$ADB_BIN" -s "$DEVICE_SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  echo "device_release=$("$ADB_BIN" -s "$DEVICE_SERIAL" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
  echo "device_sdk=$("$ADB_BIN" -s "$DEVICE_SERIAL" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
  if command -v swift >/dev/null 2>&1; then
    echo "swift=$(swift --version 2>/dev/null | head -n 1)"
  fi
} >"$ENV_FILE"

if [[ "$START_MAC_HOST" == "true" ]]; then
  (
    SKYBRIDGE_SMOKE_ROLE=mac-host swift run --package-path "$MAC_PACKAGE_PATH" LocalLanInteropHost
  ) >"$HOST_LOG" 2>&1 &
  HOST_PID=$!

  for _ in $(seq 1 60); do
    if [[ -s "$HOST_LOG" ]] && grep -q 'LocalLanInteropHost ready\.' "$HOST_LOG"; then
      break
    fi
    if ! kill -0 "$HOST_PID" >/dev/null 2>&1; then
      echo "mac LAN host exited before becoming ready" >&2
      cat "$HOST_LOG" >&2 || true
      exit 1
    fi
    sleep 1
  done

  if ! grep -q 'LocalLanInteropHost ready\.' "$HOST_LOG"; then
    echo "Timed out waiting for mac LAN host readiness" >&2
    exit 1
  fi

  DETECTED_REMOTE_PORT="$(sed -n 's/^Remote desktop: //p' "$HOST_LOG" | tail -n 1 | tr -d '\r\n')"
  if [[ -n "$DETECTED_REMOTE_PORT" && "$DETECTED_REMOTE_PORT" =~ ^[0-9]+$ ]]; then
    DIRECT_PORT="$DETECTED_REMOTE_PORT"
  fi
fi

if [[ -z "$DIRECT_HOST" && "$DEVICE_SERIAL" == emulator-* ]]; then
  DIRECT_HOST="10.0.2.2"
fi

echo "Building Android debug APK..."
"$ROOT_DIR/gradlew" :app:assembleDebug >/dev/null

APP_APK="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"
if [[ ! -f "$APP_APK" ]]; then
  echo "App APK not found: $APP_APK" >&2
  exit 1
fi

{
  "$ADB_BIN" -s "$DEVICE_SERIAL" wait-for-device
  "$ADB_BIN" -s "$DEVICE_SERIAL" install -r "$APP_APK"
} >"$INSTALL_LOG" 2>&1

"$ADB_BIN" -s "$DEVICE_SERIAL" logcat -c >/dev/null 2>&1 || true
"$ADB_BIN" -s "$DEVICE_SERIAL" shell am force-stop com.skybridge.compass.debug >/dev/null 2>&1 || true
"$ADB_BIN" -s "$DEVICE_SERIAL" shell run-as com.skybridge.compass.debug rm -f files/debug-lan-interop-smoke-status.log >/dev/null 2>&1 || true

ACTIVITY_ARGS=(
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell am start -W
  -n "$DEFAULT_ACTIVITY"
  --ez skybridgeRequireSecure "$REQUIRE_SECURE"
  --ez skybridgeAllowPlaintextFallback "$ALLOW_PLAINTEXT_FALLBACK"
  --es skybridgeTimeoutSeconds "$TIMEOUT_SECONDS"
  --ez skybridgeAutoFinish true
)

if [[ -n "$PEER_MLKEM_PUBLIC_B64" ]]; then
  ACTIVITY_ARGS+=(--es skybridgePeerMlkemPublicB64 "$PEER_MLKEM_PUBLIC_B64")
fi
if [[ -n "$PEER_XWING_PUBLIC_B64" ]]; then
  ACTIVITY_ARGS+=(--es skybridgePeerXwingPublicB64 "$PEER_XWING_PUBLIC_B64")
fi

if [[ -n "$EXPECTED_SERVICE_NAME" ]]; then
  ACTIVITY_ARGS+=(--es skybridgeExpectedServiceName "$EXPECTED_SERVICE_NAME")
fi
if [[ -n "$EXPECTED_DEVICE_ID" ]]; then
  ACTIVITY_ARGS+=(--es skybridgeExpectedDeviceId "$EXPECTED_DEVICE_ID")
fi
if [[ -n "$EXPECTED_FINGERPRINT" ]]; then
  ACTIVITY_ARGS+=(--es skybridgeExpectedFingerprint "$EXPECTED_FINGERPRINT")
fi
if [[ -n "$DIRECT_HOST" ]]; then
  ACTIVITY_ARGS+=(--es skybridgeDirectHost "$DIRECT_HOST")
  ACTIVITY_ARGS+=(--es skybridgeDirectPort "$DIRECT_PORT")
fi

"${ACTIVITY_ARGS[@]}" >/dev/null

start_epoch="$(date +%s)"
while true; do
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell run-as com.skybridge.compass.debug cat files/debug-lan-interop-smoke-status.log \
    >"$STATUS_LOG" 2>/dev/null || true

  if [[ -s "$STATUS_LOG" ]]; then
    if grep -q 'success reason=' "$STATUS_LOG"; then
      break
    fi
    if grep -q 'failure reason=' "$STATUS_LOG"; then
      echo "Android LAN smoke reported failure" >&2
      break
    fi
  fi

  now_epoch="$(date +%s)"
  if (( now_epoch - start_epoch > TIMEOUT_SECONDS )); then
    echo "Timed out waiting for Android LAN smoke result" >&2
    break
  fi
  sleep 1
done

"$ADB_BIN" -s "$DEVICE_SERIAL" logcat -d -v threadtime >"$ANDROID_LOGCAT_LOG" || true

if [[ ! -s "$STATUS_LOG" ]]; then
  echo "Android status log was not produced" >&2
  exit 1
fi

if grep -q 'failure reason=' "$STATUS_LOG"; then
  exit 1
fi

if ! grep -q 'success reason=secure_frame_received\|success reason=plaintext_frame_received' "$STATUS_LOG"; then
  echo "Android LAN smoke did not report success" >&2
  exit 1
fi

{
  echo "android_status_ok=true"
  echo "connection_mode=$(if [[ -n "$DIRECT_HOST" ]]; then echo direct; else echo discovery; fi)"
  echo "require_secure=$REQUIRE_SECURE"
  echo "allow_plaintext_fallback=$ALLOW_PLAINTEXT_FALLBACK"
  echo "success_line=$(grep -m 1 'success reason=' "$STATUS_LOG" || true)"
  if [[ -s "$HOST_LOG" ]]; then
    echo "mac_host_ready=$(grep -m 1 'LocalLanInteropHost ready\\.' "$HOST_LOG" || true)"
    echo "mac_remote_port=$(grep -m 1 'Remote desktop:' "$HOST_LOG" || true)"
  fi
} >"$SUMMARY_FILE"

echo "Android ↔ macOS LAN remote smoke passed."
echo "Artifacts:"
echo "  environment: $ENV_FILE"
echo "  command: $COMMAND_FILE"
echo "  install log: $INSTALL_LOG"
echo "  android status: $STATUS_LOG"
echo "  android logcat: $ANDROID_LOGCAT_LOG"
if [[ -s "$HOST_LOG" ]]; then
  echo "  mac host log: $HOST_LOG"
fi
echo "  summary: $SUMMARY_FILE"
