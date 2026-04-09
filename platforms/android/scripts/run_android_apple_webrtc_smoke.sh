#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/android_env.sh"
DEFAULT_MAC_PACKAGE_PATH="/Users/bill/Desktop/SkyBridge Compass Pro release"
DEFAULT_APP_CLASS="com.skybridge.compass.android.webrtc.AppleReleaseInteropAppInstrumentationTest"
DEFAULT_RUNNER="com.skybridge.compass.debug.test/com.skybridge.compass.android.HiltTestRunner"

DEVICE_SERIAL=""
WS_URL=""
MAC_PACKAGE_PATH="$DEFAULT_MAC_PACKAGE_PATH"
PQC_ENABLED="true"
ALLOW_STATIC_FALLBACK="false"
ANDROID_TIMEOUT_SECONDS="120"
MAC_TIMEOUT_SECONDS="120"
MAC_HOLD_AFTER_SUCCESS_SECONDS="3"
CLASS_NAME="$DEFAULT_APP_CLASS"
RUN_DIR=""
CODE_WAIT_SECONDS="${SKYBRIDGE_SMOKE_CODE_WAIT_SECONDS:-240}"

usage() {
  cat <<'EOF'
Usage:
  scripts/run_android_apple_webrtc_smoke.sh \
    --device <adb-serial> \
    --ws-url <wss://host:port/ws> \
    [--mac-package-path <path>] \
    [--pqc true|false] \
    [--allow-static-ed25519-fallback true|false] \
    [--android-timeout-seconds <n>] \
    [--mac-timeout-seconds <n>] \
    [--mac-hold-after-success-seconds <n>] \
    [--class <instrumentation-test-class>] \
    [--run-dir <path>]
EOF
}

json_field_from_keychain_export() {
  local file_path="$1"
  local field_name="$2"
  python3 - <<'PY' "$file_path" "$field_name"
import binascii
import json
import pathlib
import string
import sys

path = pathlib.Path(sys.argv[1])
field = sys.argv[2]
raw = path.read_text().strip()
if raw and all(ch in string.hexdigits for ch in raw) and len(raw) % 2 == 0:
    raw = binascii.unhexlify(raw).decode("utf-8")
obj = json.loads(raw)
print(obj.get(field) or "")
PY
}

refresh_supabase_session() {
  local supabase_url="$1"
  local anon_key="$2"
  local refresh_token="$3"
  local output_file="$4"
  python3 - <<'PY' "$supabase_url" "$anon_key" "$refresh_token" "$output_file"
import json
import pathlib
import sys
import urllib.error
import urllib.request

supabase_url, anon_key, refresh_token, output_file = sys.argv[1:5]
url = supabase_url.rstrip("/") + "/auth/v1/token?grant_type=refresh_token"
payload = json.dumps({"refresh_token": refresh_token}).encode("utf-8")
request = urllib.request.Request(
    url,
    data=payload,
    headers={
        "apikey": anon_key,
        "Content-Type": "application/json",
    },
    method="POST",
)

try:
    with urllib.request.urlopen(request, timeout=20) as response:
        body = response.read().decode("utf-8")
except urllib.error.HTTPError as exc:
    body = exc.read().decode("utf-8", errors="replace")
    print(body, file=sys.stderr)
    raise

pathlib.Path(output_file).write_text(body)
print(body)
PY
}

jwt_is_expired() {
  local token="$1"
  python3 - <<'PY' "$token"
import base64
import json
import sys
import time

token = sys.argv[1].strip()
parts = token.split(".")
if len(parts) < 2:
    print("unknown")
    raise SystemExit(0)

payload = parts[1]
padding = "=" * (-len(payload) % 4)
try:
    decoded = base64.urlsafe_b64decode(payload + padding)
    obj = json.loads(decoded.decode("utf-8"))
except Exception:
    print("unknown")
    raise SystemExit(0)

exp = obj.get("exp")
if not isinstance(exp, (int, float)):
    print("unknown")
    raise SystemExit(0)

print("true" if time.time() >= float(exp) else "false")
PY
}

derive_tenant_identifier() {
  local token="$1"
  python3 - <<'PY' "$token"
import base64
import json
import sys

token = sys.argv[1].strip()
parts = token.split(".")
if len(parts) < 2:
    print("")
    raise SystemExit(0)

payload = parts[1]
payload += "=" * (-len(payload) % 4)
try:
    obj = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))
except Exception:
    print("")
    raise SystemExit(0)

app_metadata = obj.get("app_metadata") or {}
user_metadata = obj.get("user_metadata") or {}
candidates = [
    app_metadata.get("tenant_id"),
    app_metadata.get("tenantId"),
    app_metadata.get("org_id"),
    app_metadata.get("workspace_id"),
    user_metadata.get("tenant_id"),
    user_metadata.get("tenantId"),
    user_metadata.get("org_id"),
    user_metadata.get("workspace_id"),
    obj.get("tenant_id"),
    obj.get("tenantId"),
    obj.get("sub"),
]
for candidate in candidates:
    value = str(candidate or "").strip()
    if value and value != "None":
        print(value)
        break
else:
    print("")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      DEVICE_SERIAL="${2:-}"
      shift 2
      ;;
    --ws-url)
      WS_URL="${2:-}"
      shift 2
      ;;
    --mac-package-path)
      MAC_PACKAGE_PATH="${2:-}"
      shift 2
      ;;
    --pqc)
      PQC_ENABLED="${2:-}"
      shift 2
      ;;
    --allow-static-ed25519-fallback)
      ALLOW_STATIC_FALLBACK="${2:-}"
      shift 2
      ;;
    --android-timeout-seconds)
      ANDROID_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --mac-timeout-seconds)
      MAC_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --mac-hold-after-success-seconds)
      MAC_HOLD_AFTER_SUCCESS_SECONDS="${2:-}"
      shift 2
      ;;
    --class)
      CLASS_NAME="${2:-}"
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

if [[ -z "$DEVICE_SERIAL" || -z "$WS_URL" ]]; then
  usage >&2
  exit 1
fi

ADB_BIN="$(resolve_adb_bin "$ROOT_DIR" || true)"
if [[ -z "$ADB_BIN" ]]; then
  echo "adb not found; checked PATH, local.properties, and common Android SDK locations" >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found in PATH" >&2
  exit 1
fi

if [[ ! -d "$MAC_PACKAGE_PATH" ]]; then
  echo "mac package path not found: $MAC_PACKAGE_PATH" >&2
  exit 1
fi

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$ROOT_DIR/build/interop/android-apple-webrtc-smoke/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$RUN_DIR"

HOST_CODE_FILE="$RUN_DIR/connection-code.txt"
HOST_STATUS_FILE="$RUN_DIR/mac-host.status.log"
HOST_STDOUT_FILE="$RUN_DIR/mac-host.stdout.log"
HOST_AUTH_SESSION_FILE="$RUN_DIR/mac-authsession.json"
ANDROID_INSTRUMENTATION_LOG="$RUN_DIR/android-instrumentation.log"
ANDROID_LOGCAT_LOG="$RUN_DIR/android-logcat.txt"
ANDROID_HANDSHAKE_LOG="$RUN_DIR/android-handshake.log"
INSTALL_LOG="$RUN_DIR/android-install.log"
ENV_FILE="$RUN_DIR/environment.txt"
COMMAND_FILE="$RUN_DIR/command.txt"
SUMMARY_FILE="$RUN_DIR/summary.txt"

HOST_PID=""
cleanup() {
  if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" >/dev/null 2>&1; then
    kill "$HOST_PID" >/dev/null 2>&1 || true
    wait "$HOST_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Run directory: $RUN_DIR"
cat >"$COMMAND_FILE" <<EOF
script=scripts/run_android_apple_webrtc_smoke.sh
device=$DEVICE_SERIAL
ws_url=$WS_URL
mac_package_path=$MAC_PACKAGE_PATH
pqc_enabled=$PQC_ENABLED
allow_static_ed25519_fallback=$ALLOW_STATIC_FALLBACK
android_timeout_seconds=$ANDROID_TIMEOUT_SECONDS
mac_timeout_seconds=$MAC_TIMEOUT_SECONDS
mac_hold_after_success_seconds=$MAC_HOLD_AFTER_SUCCESS_SECONDS
class_name=$CLASS_NAME
run_dir=$RUN_DIR
EOF
{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "swift=$(swift --version 2>/dev/null | head -n 1)"
  echo "adb=$("$ADB_BIN" version 2>/dev/null | head -n 1)"
  echo "device_model=$("$ADB_BIN" -s "$DEVICE_SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  echo "device_release=$("$ADB_BIN" -s "$DEVICE_SERIAL" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
  echo "device_sdk=$("$ADB_BIN" -s "$DEVICE_SERIAL" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
} >"$ENV_FILE"

HOST_BEARER_TOKEN="${SKYBRIDGE_BEARER_TOKEN:-}"
HOST_REFRESH_TOKEN="${SKYBRIDGE_REFRESH_TOKEN:-}"
HOST_USER_ID="${SKYBRIDGE_USER_ID:-}"
HOST_TENANT_ID="${SKYBRIDGE_TENANT_ID:-}"
HOST_DISPLAY_NAME="${SKYBRIDGE_DISPLAY_NAME:-}"
HOST_NEBULA_ID="${SKYBRIDGE_NEBULA_ID:-}"
SUPABASE_URL="${SKYBRIDGE_SMOKE_SUPABASE_URL:-}"
SUPABASE_ANON_KEY="${SKYBRIDGE_SMOKE_SUPABASE_ANON_KEY:-}"
HOST_AUTH_SOURCE="environment"

if [[ -z "$HOST_BEARER_TOKEN" ]]; then
  HOST_AUTH_SOURCE="keychain"
  if ! security find-generic-password -s com.skybridge.compass.authsession -a primary -w >"$HOST_AUTH_SESSION_FILE" 2>"$RUN_DIR/mac-authsession.keychain.err"; then
    echo "Unable to read mac auth session from keychain; see $RUN_DIR/mac-authsession.keychain.err" >&2
    exit 1
  fi

  HOST_BEARER_TOKEN="$(json_field_from_keychain_export "$HOST_AUTH_SESSION_FILE" accessToken)"
  HOST_REFRESH_TOKEN="$(json_field_from_keychain_export "$HOST_AUTH_SESSION_FILE" refreshToken)"
  HOST_USER_ID="$(json_field_from_keychain_export "$HOST_AUTH_SESSION_FILE" userIdentifier)"
  HOST_DISPLAY_NAME="$(json_field_from_keychain_export "$HOST_AUTH_SESSION_FILE" displayName)"
  HOST_NEBULA_ID="$(json_field_from_keychain_export "$HOST_AUTH_SESSION_FILE" nebulaId)"
fi

if [[ -z "$SUPABASE_URL" ]]; then
  SUPABASE_URL="$(security find-generic-password -s SkyBridge.Supabase -a URL -w 2>"$RUN_DIR/mac-supabase-url.keychain.err" | tr -d '\r\n')"
fi
if [[ -z "$SUPABASE_ANON_KEY" ]]; then
  SUPABASE_ANON_KEY="$(security find-generic-password -s SkyBridge.Supabase -a AnonKey -w 2>"$RUN_DIR/mac-supabase-anon.keychain.err" | tr -d '\r\n')"
fi
if [[ -z "$HOST_BEARER_TOKEN" || -z "$SUPABASE_URL" || -z "$SUPABASE_ANON_KEY" ]]; then
  echo "Unable to prepare mac smoke auth context from keychain" >&2
  exit 1
fi

if [[ -z "$HOST_TENANT_ID" && -n "$HOST_BEARER_TOKEN" ]]; then
  HOST_TENANT_ID="$(derive_tenant_identifier "$HOST_BEARER_TOKEN")"
fi
if [[ -z "$HOST_TENANT_ID" ]]; then
  echo "Unable to derive tenant id for Android cross-network smoke" >&2
  exit 1
fi

MAC_SIGNALING_WS_URL="$WS_URL"
MAC_SIGNALING_SERVER_URL="$(printf '%s' "$WS_URL" | sed -E 's#^ws://#http://#; s#^wss://#https://#; s#/ws([/?].*)?$##')"
USE_IN_MEMORY_IDENTITY="${SKYBRIDGE_SMOKE_USE_IN_MEMORY_IDENTITY:-0}"
INCLUDE_REFRESH_TOKEN="${SKYBRIDGE_SMOKE_INCLUDE_REFRESH_TOKEN:-0}"
REQUESTED_HOST_AUTH_MODE="${SKYBRIDGE_SMOKE_HOST_AUTH_MODE:-auto}"
TOKEN_EXPIRY_STATE="unknown"

if [[ -n "$HOST_BEARER_TOKEN" ]]; then
  TOKEN_EXPIRY_STATE="$(jwt_is_expired "$HOST_BEARER_TOKEN")"
fi

case "$REQUESTED_HOST_AUTH_MODE" in
  auto)
    EFFECTIVE_HOST_AUTH_MODE="injected"
    if [[ "$HOST_AUTH_SOURCE" == "keychain" && "$TOKEN_EXPIRY_STATE" == "true" ]]; then
      if [[ -n "$HOST_REFRESH_TOKEN" ]]; then
        EFFECTIVE_HOST_AUTH_MODE="keychain"
      else
        echo "Mac auth session in keychain has an expired access token and no refresh token." >&2
        echo "Re-authenticate the macOS app before running cross-network smoke." >&2
        exit 1
      fi
    fi
    ;;
  injected|keychain)
    EFFECTIVE_HOST_AUTH_MODE="$REQUESTED_HOST_AUTH_MODE"
    ;;
  *)
    echo "Unsupported SKYBRIDGE_SMOKE_HOST_AUTH_MODE: $REQUESTED_HOST_AUTH_MODE" >&2
    exit 1
    ;;
esac

{
  echo "host_auth_source=$HOST_AUTH_SOURCE"
  echo "host_auth_mode_requested=$REQUESTED_HOST_AUTH_MODE"
  echo "host_auth_mode_effective=$EFFECTIVE_HOST_AUTH_MODE"
  echo "host_access_token_expired=$TOKEN_EXPIRY_STATE"
  echo "host_tenant_id=$HOST_TENANT_ID"
} >>"$ENV_FILE"

HOST_SIGNALING_SERVER_URL="${SKYBRIDGE_SMOKE_HOST_SIGNALING_SERVER_URL:-}"
HOST_SIGNALING_WS_URL="${SKYBRIDGE_SMOKE_HOST_SIGNALING_WS_URL:-}"
if [[ -z "$HOST_SIGNALING_SERVER_URL" || -z "$HOST_SIGNALING_WS_URL" ]]; then
  LOOPBACK_DERIVED="$(
    python3 - <<'PY' "$WS_URL"
import sys
from urllib.parse import urlparse, urlunparse

ws_url = sys.argv[1].strip()
parsed = urlparse(ws_url)
scheme = parsed.scheme.lower()
host = (parsed.hostname or "").lower()
port = parsed.port
path = parsed.path or "/ws"

is_loopback = host in {"127.0.0.1", "localhost", "::1"}
if scheme in {"ws", "wss"} and host and not is_loopback and port:
    host_ws = urlunparse(("ws" if scheme == "ws" else "wss", f"127.0.0.1:{port}", path, "", parsed.query, ""))
    host_http = urlunparse(("http" if scheme == "ws" else "https", f"127.0.0.1:{port}", path[:-3] if path.endswith('/ws') else "", "", "", ""))
    print(host_http)
    print(host_ws)
PY
  )"
  if [[ -n "$LOOPBACK_DERIVED" ]]; then
    if [[ -z "$HOST_SIGNALING_SERVER_URL" ]]; then
      HOST_SIGNALING_SERVER_URL="$(printf '%s\n' "$LOOPBACK_DERIVED" | sed -n '1p')"
    fi
    if [[ -z "$HOST_SIGNALING_WS_URL" ]]; then
      HOST_SIGNALING_WS_URL="$(printf '%s\n' "$LOOPBACK_DERIVED" | sed -n '2p')"
    fi
  fi
fi
HOST_SIGNALING_SERVER_URL="${HOST_SIGNALING_SERVER_URL:-$MAC_SIGNALING_SERVER_URL}"
HOST_SIGNALING_WS_URL="${HOST_SIGNALING_WS_URL:-$MAC_SIGNALING_WS_URL}"
HOST_REFRESHED_SESSION_FILE="$RUN_DIR/mac-authsession.refreshed.json"
HOST_ACCESS_TOKEN_REFRESHED="false"

if [[ "$TOKEN_EXPIRY_STATE" == "true" && -n "$HOST_REFRESH_TOKEN" ]]; then
  if refresh_supabase_session "$SUPABASE_URL" "$SUPABASE_ANON_KEY" "$HOST_REFRESH_TOKEN" "$HOST_REFRESHED_SESSION_FILE" >/dev/null 2>"$RUN_DIR/mac-authsession.refresh.err"; then
    REFRESHED_BEARER_TOKEN="$(json_field_from_keychain_export "$HOST_REFRESHED_SESSION_FILE" access_token)"
    REFRESHED_REFRESH_TOKEN="$(json_field_from_keychain_export "$HOST_REFRESHED_SESSION_FILE" refresh_token)"
    if [[ -n "$REFRESHED_BEARER_TOKEN" ]]; then
      HOST_BEARER_TOKEN="$REFRESHED_BEARER_TOKEN"
      if [[ -n "$REFRESHED_REFRESH_TOKEN" ]]; then
        HOST_REFRESH_TOKEN="$REFRESHED_REFRESH_TOKEN"
      fi
      TOKEN_EXPIRY_STATE="$(jwt_is_expired "$HOST_BEARER_TOKEN")"
      HOST_ACCESS_TOKEN_REFRESHED="true"
    fi
  fi
fi

echo "Launching mac smoke host..."

{
  echo "host_access_token_expired_after_refresh=$TOKEN_EXPIRY_STATE"
  echo "host_access_token_refreshed=$HOST_ACCESS_TOKEN_REFRESHED"
} >>"$ENV_FILE"

(
  export SKYBRIDGE_SMOKE_CODE_FILE="$HOST_CODE_FILE"
  export SKYBRIDGE_SMOKE_STATUS_FILE="$HOST_STATUS_FILE"
  export SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$MAC_TIMEOUT_SECONDS"
  export SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS="$MAC_HOLD_AFTER_SUCCESS_SECONDS"
  export SKYBRIDGE_SMOKE_ROLE="mac-host"
  # Default to the persistent Apple device identity so WebRTC bootstrap material
  # lands under the same deviceId that LAN strict-PQC validation uses later.
  if [[ "$USE_IN_MEMORY_IDENTITY" == "1" ]]; then
    export SKYBRIDGE_KEYCHAIN_IN_MEMORY="1"
  else
    unset SKYBRIDGE_KEYCHAIN_IN_MEMORY
  fi
  if [[ "$EFFECTIVE_HOST_AUTH_MODE" == "injected" ]]; then
    export SKYBRIDGE_BEARER_TOKEN="$HOST_BEARER_TOKEN"
    if [[ "$INCLUDE_REFRESH_TOKEN" == "1" ]]; then
      export SKYBRIDGE_REFRESH_TOKEN="$HOST_REFRESH_TOKEN"
    else
      unset SKYBRIDGE_REFRESH_TOKEN
    fi
    export SKYBRIDGE_USER_ID="$HOST_USER_ID"
    export SKYBRIDGE_DISPLAY_NAME="$HOST_DISPLAY_NAME"
    export SKYBRIDGE_NEBULA_ID="$HOST_NEBULA_ID"
  else
    unset SKYBRIDGE_BEARER_TOKEN
    unset SKYBRIDGE_REFRESH_TOKEN
    unset SKYBRIDGE_USER_ID
    unset SKYBRIDGE_DISPLAY_NAME
    unset SKYBRIDGE_NEBULA_ID
  fi
  export SKYBRIDGE_SMOKE_SUPABASE_URL="$SUPABASE_URL"
  export SKYBRIDGE_SMOKE_SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"
  export SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING="1"
  export SKYBRIDGE_CLIENT_VERSION="${SKYBRIDGE_CLIENT_VERSION:-1.0.0}"
  export SKYBRIDGE_PROTOCOL_VERSION="${SKYBRIDGE_PROTOCOL_VERSION:-1}"
  export SKYBRIDGE_SIGNALING_SERVER_URL="$HOST_SIGNALING_SERVER_URL"
  export SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$HOST_SIGNALING_WS_URL"
  if [[ "$PQC_ENABLED" == "true" ]]; then
    export SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY="1"
  else
    unset SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY || true
  fi
  swift run --package-path "$MAC_PACKAGE_PATH" LocalWebRTCSmokeHost
) >"$HOST_STDOUT_FILE" 2>&1 &
HOST_PID=$!

for _ in $(seq 1 $(( CODE_WAIT_SECONDS * 2 ))); do
  if [[ -s "$HOST_CODE_FILE" ]]; then
    break
  fi
  if ! kill -0 "$HOST_PID" >/dev/null 2>&1; then
    echo "mac smoke host exited before producing a connection code" >&2
    cat "$HOST_STDOUT_FILE" >&2 || true
    exit 1
  fi
  sleep 0.5
done

if [[ ! -s "$HOST_CODE_FILE" ]]; then
  echo "Timed out waiting for connection code from mac smoke host" >&2
  exit 1
fi

CONNECTION_CODE="$(tr -d '\r\n' < "$HOST_CODE_FILE")"
if [[ -z "$CONNECTION_CODE" ]]; then
  echo "Connection code file was empty" >&2
  exit 1
fi

echo "Connection code: $CONNECTION_CODE"
echo "Building Android debug + androidTest APKs..."
"$ROOT_DIR/gradlew" -p "$ROOT_DIR" :app:assembleDebug :app:assembleDebugAndroidTest >/dev/null

APP_APK="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"
TEST_APK="$(find "$ROOT_DIR/app/build/outputs/apk" -path '*androidTest*' -name '*.apk' | head -n 1)"

if [[ ! -f "$APP_APK" ]]; then
  echo "App APK not found: $APP_APK" >&2
  exit 1
fi

if [[ -z "$TEST_APK" || ! -f "$TEST_APK" ]]; then
  echo "Android test APK not found under app/build/outputs/apk" >&2
  exit 1
fi

{
  "$ADB_BIN" -s "$DEVICE_SERIAL" wait-for-device
  "$ADB_BIN" -s "$DEVICE_SERIAL" install -r "$APP_APK"
  "$ADB_BIN" -s "$DEVICE_SERIAL" install -r -t "$TEST_APK"
} >"$INSTALL_LOG" 2>&1

"$ADB_BIN" -s "$DEVICE_SERIAL" logcat -c >/dev/null 2>&1 || true

echo "Running instrumentation smoke on device $DEVICE_SERIAL..."
set +e
"$ADB_BIN" -s "$DEVICE_SERIAL" shell am instrument -w \
  -e class "$CLASS_NAME" \
  -e skybridgeCode "$CONNECTION_CODE" \
  -e skybridgeWsUrl "$WS_URL" \
  -e skybridgeTimeoutSeconds "$ANDROID_TIMEOUT_SECONDS" \
  -e skybridgePqcEnabled "$PQC_ENABLED" \
  -e skybridgeAllowStaticEd25519Fallback "$ALLOW_STATIC_FALLBACK" \
  -e skybridgeBearerToken "$HOST_BEARER_TOKEN" \
  -e skybridgeTenantId "$HOST_TENANT_ID" \
  -e skybridgeClientVersion "${SKYBRIDGE_CLIENT_VERSION:-1.0.0}" \
  -e skybridgeProtocolVersion "${SKYBRIDGE_PROTOCOL_VERSION:-1}" \
  "$DEFAULT_RUNNER" | tee "$ANDROID_INSTRUMENTATION_LOG"
INSTRUMENT_EXIT="${PIPESTATUS[0]}"
set -e

"$ADB_BIN" -s "$DEVICE_SERIAL" logcat -d -v threadtime >"$ANDROID_LOGCAT_LOG" || true
grep -E 'SB-HANDSHAKE|SB-WEBRTC|SB-ANDROID|SB-DEBUG-SMOKE' "$ANDROID_LOGCAT_LOG" >"$ANDROID_HANDSHAKE_LOG" || true

set +e
wait "$HOST_PID"
HOST_EXIT=$?
set -e
HOST_PID=""

if [[ "$INSTRUMENT_EXIT" -ne 0 ]]; then
  echo "Instrumentation failed; see $ANDROID_INSTRUMENTATION_LOG" >&2
  exit "$INSTRUMENT_EXIT"
fi

if [[ "$HOST_EXIT" -ne 0 ]]; then
  echo "Mac smoke host failed; see $HOST_STDOUT_FILE and $HOST_STATUS_FILE" >&2
  exit "$HOST_EXIT"
fi

if ! grep -q 'OK (1 test)' "$ANDROID_INSTRUMENTATION_LOG"; then
  echo "Instrumentation output did not report a passing test" >&2
  exit 1
fi

if ! grep -q 'success session=' "$HOST_STATUS_FILE"; then
  echo "Mac host status log does not contain a success record" >&2
  exit 1
fi

{
  echo "instrumentation_ok=true"
  echo "mac_host_ok=true"
  echo "session_keys_asserted_by_test=true"
  echo "handshake_log_present=$(if [[ -s "$ANDROID_HANDSHAKE_LOG" ]]; then echo true; else echo false; fi)"
  echo "pqc_enabled=$PQC_ENABLED"
  echo "allow_static_ed25519_fallback=$ALLOW_STATIC_FALLBACK"
  echo "mac_host_success_line=$(grep -m 1 'success session=' "$HOST_STATUS_FILE" || true)"
  echo "android_smoke_success_line=$(grep -m 1 'SB-ANDROID-APP-SMOKE success\\|SB-ANDROID-SMOKE success' "$ANDROID_INSTRUMENTATION_LOG" || true)"
} >"$SUMMARY_FILE"

echo "Android ↔ Apple WebRTC smoke passed."
echo "Artifacts:"
echo "  environment: $ENV_FILE"
echo "  command: $COMMAND_FILE"
echo "  mac host stdout: $HOST_STDOUT_FILE"
echo "  mac host status: $HOST_STATUS_FILE"
echo "  connection code: $HOST_CODE_FILE"
echo "  instrumentation: $ANDROID_INSTRUMENTATION_LOG"
echo "  logcat: $ANDROID_LOGCAT_LOG"
echo "  handshake log: $ANDROID_HANDSHAKE_LOG"
echo "  install log: $INSTALL_LOG"
echo "  summary: $SUMMARY_FILE"
