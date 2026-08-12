#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/android_env.sh"
source "$ROOT_DIR/scripts/lib/keychain_smoke.sh"
source "$ROOT_DIR/scripts/lib/source_provenance.sh"
source "$ROOT_DIR/scripts/lib/repository_layout.sh"
RELEASE_REPO_ROOT="$(skybridge_canonical_release_root "$ROOT_DIR")"
DEFAULT_MAC_PACKAGE_PATH="$RELEASE_REPO_ROOT"
DEFAULT_APP_CLASS="com.skybridge.compass.android.webrtc.AppleReleaseInteropAppInstrumentationTest"
DEFAULT_RUNNER="com.skybridge.compass.debug.test/com.skybridge.compass.android.HiltTestRunner"

DEVICE_SERIAL=""
WS_URL=""
MAC_PACKAGE_PATH="$DEFAULT_MAC_PACKAGE_PATH"
START_LOCAL_COMPAT_SIGNALING="false"
START_LOCAL_TURN="false"
PQC_ENABLED="true"
PQC_MINIMUM_TIER="${SKYBRIDGE_SMOKE_PQC_MINIMUM_TIER:-nativePQC}"
EXPECT_QPERIAPT="${SKYBRIDGE_SMOKE_EXPECT_QPERIAPT:-}"
EXPECTED_NEGOTIATED_SUITE="${SKYBRIDGE_SMOKE_EXPECTED_NEGOTIATED_SUITE:-}"
REQUIRE_DIRECT_ROUTE="${SKYBRIDGE_SMOKE_REQUIRE_DIRECT_ROUTE:-false}"
ANDROID_TIMEOUT_SECONDS="120"
MAC_TIMEOUT_SECONDS="120"
MAC_HOLD_AFTER_SUCCESS_SECONDS="3"
CLASS_NAME="$DEFAULT_APP_CLASS"
RUN_DIR=""
CODE_WAIT_SECONDS="${SKYBRIDGE_SMOKE_CODE_WAIT_SECONDS:-240}"
KEYCHAIN_READ_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_KEYCHAIN_TIMEOUT_SECONDS:-${SKYBRIDGE_KEYCHAIN_READ_TIMEOUT_SECONDS:-15}}"
CLIENT_VERSION="${SKYBRIDGE_CLIENT_VERSION:-1.0.0}"
PROTOCOL_VERSION="${SKYBRIDGE_PROTOCOL_VERSION:-1}"

usage() {
  cat <<'EOF'
Usage:
  scripts/run_android_apple_webrtc_smoke.sh \
    --device <adb-serial> \
    --ws-url <wss://host:port/ws> \
    [--mac-package-path <path>] \
    [--start-local-compat-signaling true|false] \
    [--start-local-turn true|false] \
    [--pqc true|false] \
    [--pqc-minimum-tier nativePQC|liboqsPQC|qperiaptPQC|classic] \
    [--expect-qperiapt true|false] \
    [--expected-negotiated-suite <suite-name-or-wire-id>] \
    [--require-direct-route true|false] \
    [--android-timeout-seconds <n>] \
    [--mac-timeout-seconds <n>] \
    [--mac-hold-after-success-seconds <n>] \
    [--class <instrumentation-test-class>] \
    [--run-dir <path>]
EOF
}

require_boolean() {
  local name="$1"
  local value="$2"
  case "$value" in
    true|false) ;;
    *)
      echo "Unsupported $name value: $value (expected true|false)" >&2
      exit 1
      ;;
  esac
}

ws_port() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1].strip())
print(parsed.port or "")
PY
}

ws_http_origin() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1].strip())
scheme = "https" if parsed.scheme.lower() == "wss" else "http"
host = parsed.hostname or ""
if ":" in host and not host.startswith("["):
    host = f"[{host}]"
port = f":{parsed.port}" if parsed.port else ""
print(f"{scheme}://{host}{port}")
PY
}

json_field_from_payload() {
  local field_name="$1"
  python3 -c '
import binascii
import json
import string
import sys

field = sys.argv[1]
raw = sys.stdin.read().strip()
if raw and all(ch in string.hexdigits for ch in raw) and len(raw) % 2 == 0:
    raw = binascii.unhexlify(raw).decode("utf-8")
obj = json.loads(raw)
print(obj.get(field) or "")
' "$field_name"
}

refresh_supabase_session() {
  local supabase_url="$1"
  local anon_key="$2"
  local output_file="$3"
  python3 -c '
import json
import pathlib
import sys
import urllib.error
import urllib.request

supabase_url, anon_key, output_file = sys.argv[1:4]
refresh_token = sys.stdin.read().strip()
if not refresh_token:
    raise SystemExit("missing refresh token")
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
    print(f"refresh failed http={exc.code}", file=sys.stderr)
    raise

if output_file != "-":
    pathlib.Path(output_file).write_text(body)
print(body)
' "$supabase_url" "$anon_key" "$output_file"
}

jwt_is_expired() {
  python3 -c '
import base64
import json
import sys
import time

token = sys.stdin.read().strip()
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
'
}

derive_tenant_identifier() {
  python3 -c '
import base64
import json
import sys

token = sys.stdin.read().strip()
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
'
}

adb_reverse_port_for_ws_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1].strip())
host = (parsed.hostname or "").lower()
if parsed.scheme.lower() in {"ws", "wss"} and host in {"127.0.0.1", "localhost", "::1"} and parsed.port:
    print(parsed.port)
else:
    print("")
PY
}

is_loopback_ws_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1].strip())
host = (parsed.hostname or "").lower()
print("true" if parsed.scheme.lower() in {"ws", "wss"} and host in {"127.0.0.1", "localhost", "::1"} else "false")
PY
}

adb_global_setting_get() {
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell settings get global "$1" | tr -d '\r'
}

adb_global_setting_restore() {
  local key="$1"
  local value="$2"
  if [[ "$value" == "null" || -z "$value" ]]; then
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell settings delete global "$key" >/dev/null 2>&1 || true
  else
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell settings put global "$key" "$value" >/dev/null
  fi
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
    --start-local-compat-signaling)
      START_LOCAL_COMPAT_SIGNALING="${2:-}"
      shift 2
      ;;
    --start-local-turn)
      START_LOCAL_TURN="${2:-}"
      shift 2
      ;;
    --pqc)
      PQC_ENABLED="${2:-}"
      shift 2
      ;;
    --pqc-minimum-tier)
      PQC_MINIMUM_TIER="${2:-}"
      shift 2
      ;;
    --expect-qperiapt)
      EXPECT_QPERIAPT="${2:-}"
      shift 2
      ;;
    --expected-negotiated-suite)
      EXPECTED_NEGOTIATED_SUITE="${2:-}"
      shift 2
      ;;
    --require-direct-route)
      REQUIRE_DIRECT_ROUTE="${2:-}"
      shift 2
      ;;
    --allow-static-ed25519-fallback)
      echo "--allow-static-ed25519-fallback was removed; smoke runs must use generated device identity keys" >&2
      exit 1
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

require_boolean "--start-local-compat-signaling" "$START_LOCAL_COMPAT_SIGNALING"
require_boolean "--start-local-turn" "$START_LOCAL_TURN"
require_boolean "--require-direct-route" "$REQUIRE_DIRECT_ROUTE"

case "$PQC_ENABLED" in
  true|false) ;;
  *)
    echo "Unsupported --pqc value: $PQC_ENABLED (expected true|false)" >&2
    exit 1
    ;;
esac

case "$PQC_MINIMUM_TIER" in
  nativePQC|liboqsPQC|qperiaptPQC|classic) ;;
  *)
    echo "Unsupported --pqc-minimum-tier value: $PQC_MINIMUM_TIER" >&2
    exit 1
    ;;
esac

if [[ -z "$EXPECT_QPERIAPT" ]]; then
  if [[ "$PQC_MINIMUM_TIER" == "qperiaptPQC" ]]; then
    EXPECT_QPERIAPT="true"
  else
    EXPECT_QPERIAPT="false"
  fi
fi

case "$EXPECT_QPERIAPT" in
  true|false) ;;
  *)
    echo "Unsupported --expect-qperiapt value: $EXPECT_QPERIAPT (expected true|false)" >&2
    exit 1
    ;;
esac

if [[ "$EXPECT_QPERIAPT" == "true" ]]; then
  if [[ "$PQC_ENABLED" != "true" ]]; then
    echo "Q-Periapt smoke requires --pqc true" >&2
    exit 1
  fi
  if [[ "$PQC_MINIMUM_TIER" != "qperiaptPQC" ]]; then
    echo "Q-Periapt smoke requires --pqc-minimum-tier qperiaptPQC" >&2
    exit 1
  fi
  if [[ -z "$EXPECTED_NEGOTIATED_SUITE" ]]; then
    EXPECTED_NEGOTIATED_SUITE="Q_PERIAPT_CONTEXT_BOUND"
  fi
  case "$EXPECTED_NEGOTIATED_SUITE" in
    Q_PERIAPT_CONTEXT_BOUND|0x0011|0X0011|17) ;;
    *)
      echo "Q-Periapt smoke requires --expected-negotiated-suite Q_PERIAPT_CONTEXT_BOUND, 0x0011, or 17" >&2
      exit 1
      ;;
  esac
fi

ADB_BIN="$(resolve_adb_bin "$ROOT_DIR" || true)"
if [[ -z "$ADB_BIN" ]]; then
  echo "adb not found; checked PATH, local.properties, and common Android SDK locations" >&2
  exit 1
fi

ANDROID_DEVICE_RELEASE="$(android_device_prop "$ADB_BIN" "$DEVICE_SERIAL" ro.build.version.release)"
ANDROID_DEVICE_SDK="$(android_device_prop "$ADB_BIN" "$DEVICE_SERIAL" ro.build.version.sdk)"
require_android16_device "$ANDROID_DEVICE_RELEASE" "$ANDROID_DEVICE_SDK"
ANDROID_USER_ID="$(android_current_user_id "$ADB_BIN" "$DEVICE_SERIAL")"

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found in PATH" >&2
  exit 1
fi

if [[ "$EXPECT_QPERIAPT" == "true" ]]; then
  require_macos26_host
fi

MAC_PACKAGE_PATH="$(skybridge_require_release_repo_root "$MAC_PACKAGE_PATH")"
SIGNALING_DIR="$MAC_PACKAGE_PATH/Server/skybridge-signaling"
if [[ "$START_LOCAL_COMPAT_SIGNALING" == "true" && ! -f "$SIGNALING_DIR/local_compat_server.js" ]]; then
  echo "local compat signaling server not found: $SIGNALING_DIR/local_compat_server.js" >&2
  exit 1
fi

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$ROOT_DIR/build/interop/android-apple-webrtc-smoke/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR"

HOST_CODE_FILE="$RUN_DIR/connection-code.txt"
HOST_STATUS_FILE="$RUN_DIR/mac-host.status.log"
HOST_STDOUT_FILE="$RUN_DIR/mac-host.stdout.log"
ANDROID_INSTRUMENTATION_LOG="$RUN_DIR/android-instrumentation.log"
ANDROID_LOGCAT_LOG="$RUN_DIR/android-logcat.txt"
ANDROID_HANDSHAKE_LOG="$RUN_DIR/android-handshake.log"
INSTALL_LOG="$RUN_DIR/android-install.log"
ADB_REVERSE_LOG="$RUN_DIR/adb-reverse.log"
ENV_FILE="$RUN_DIR/environment.txt"
COMMAND_FILE="$RUN_DIR/command.txt"
SUMMARY_FILE="$RUN_DIR/summary.txt"
PUBLIC_ARTIFACT_DIR="$RUN_DIR/public-redacted"
PROVENANCE_DIR="$RUN_DIR/source-provenance"
PROVENANCE_FILE="$RUN_DIR/source-provenance.txt"
SIGNALING_LOG="$RUN_DIR/signaling.log"
TURN_LOG="$RUN_DIR/turnserver.log"
AUTH_CONTEXT_FILE_NAME="android-apple-webrtc-smoke-auth.json"
CODE_CONTEXT_FILE_NAME="android-apple-webrtc-smoke-code.txt"

HOST_PID=""
SIGNALING_PID=""
TURN_PID=""
ADB_REVERSE_PORT=""
DEVICE_PROXY_RESTORE_NEEDED="0"
ORIGINAL_HTTP_PROXY=""
ORIGINAL_GLOBAL_HTTP_PROXY_HOST=""
ORIGINAL_GLOBAL_HTTP_PROXY_PORT=""
ORIGINAL_GLOBAL_HTTP_PROXY_EXCLUSION_LIST=""
cleanup() {
  if [[ -n "${ADB_BIN:-}" && -n "$DEVICE_SERIAL" && -n "${AUTH_CONTEXT_FILE_NAME:-}" ]]; then
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell run-as com.skybridge.compass.debug \
      rm -f "files/$AUTH_CONTEXT_FILE_NAME" "files/$CODE_CONTEXT_FILE_NAME" >/dev/null 2>&1 || true
  fi
  if [[ "$DEVICE_PROXY_RESTORE_NEEDED" == "1" && -n "${ADB_BIN:-}" && -n "$DEVICE_SERIAL" ]]; then
    adb_global_setting_restore http_proxy "$ORIGINAL_HTTP_PROXY" || true
    adb_global_setting_restore global_http_proxy_host "$ORIGINAL_GLOBAL_HTTP_PROXY_HOST" || true
    adb_global_setting_restore global_http_proxy_port "$ORIGINAL_GLOBAL_HTTP_PROXY_PORT" || true
    adb_global_setting_restore global_http_proxy_exclusion_list "$ORIGINAL_GLOBAL_HTTP_PROXY_EXCLUSION_LIST" || true
  fi
  if [[ -n "${ADB_BIN:-}" && -n "$DEVICE_SERIAL" && -n "${ADB_REVERSE_PORT:-}" ]]; then
    "$ADB_BIN" -s "$DEVICE_SERIAL" reverse --remove "tcp:$ADB_REVERSE_PORT" >/dev/null 2>&1 || true
  fi
  if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" >/dev/null 2>&1; then
    kill "$HOST_PID" >/dev/null 2>&1 || true
    wait "$HOST_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SIGNALING_PID" ]] && kill -0 "$SIGNALING_PID" >/dev/null 2>&1; then
    kill "$SIGNALING_PID" >/dev/null 2>&1 || true
    wait "$SIGNALING_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TURN_PID" ]] && kill -0 "$TURN_PID" >/dev/null 2>&1; then
    kill "$TURN_PID" >/dev/null 2>&1 || true
    wait "$TURN_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

fail_local_service_start() {
  local stage="$1"
  local reason="$2"
  local artifact="$3"
  local message="$4"
  {
    echo "status=failed"
    echo "failure_stage=$stage"
    echo "failure_reason=$reason"
    echo "failure_artifact=$artifact"
    echo "start_local_compat_signaling=$START_LOCAL_COMPAT_SIGNALING"
    echo "start_local_turn=$START_LOCAL_TURN"
    echo "command=$COMMAND_FILE"
    echo "environment=$ENV_FILE"
  } >"$SUMMARY_FILE"
  echo "$message; see $artifact" >&2
  exit 1
}

fail_keychain_read() {
  local stage="$1"
  local reason="$2"
  local err_file="$3"
  local message="$4"
  {
    echo "status=failed"
    echo "failure_stage=$stage"
    echo "failure_reason=$reason"
    echo "failure_artifact=$err_file"
    echo "host_auth_source=$HOST_AUTH_SOURCE"
    echo "keychain_read_timeout_seconds=$KEYCHAIN_READ_TIMEOUT_SECONDS"
  } >"$SUMMARY_FILE"
  echo "$message; see $err_file" >&2
  exit 1
}

mac_host_last_status() {
  if [[ -s "$HOST_STATUS_FILE" ]]; then
    tail -n 1 "$HOST_STATUS_FILE"
  else
    echo "none"
  fi
}

fail_mac_host_pre_connection_code() {
  local reason="$1"
  local host_exit="$2"
  local message="$3"
  {
    echo "status=failed"
    echo "failure_stage=mac_host_pre_connection_code"
    echo "failure_reason=$reason"
    echo "mac_host_exit=$host_exit"
    echo "mac_host_last_status=$(mac_host_last_status)"
    echo "instrumentation_started=false"
    echo "connection_code_seen=false"
    echo "pqc_enabled=$PQC_ENABLED"
    echo "pqc_minimum_tier=$PQC_MINIMUM_TIER"
    echo "expected_qperiapt=$EXPECT_QPERIAPT"
    echo "expected_negotiated_suite=$EXPECTED_NEGOTIATED_SUITE"
    echo "mac_host_stdout=$HOST_STDOUT_FILE"
    echo "mac_host_status=$HOST_STATUS_FILE"
    echo "command=$COMMAND_FILE"
    echo "environment=$ENV_FILE"
  } >"$SUMMARY_FILE"
  echo "$message; last mac host status: $(mac_host_last_status)" >&2
  echo "See $SUMMARY_FILE, $HOST_STDOUT_FILE, and $HOST_STATUS_FILE" >&2
  exit 1
}

echo "Run directory: $RUN_DIR"
cat >"$COMMAND_FILE" <<EOF
script=scripts/run_android_apple_webrtc_smoke.sh
device=$DEVICE_SERIAL
android_user_id=$ANDROID_USER_ID
ws_url=$(redact_smoke_artifact_url "$WS_URL")
mac_package_path=$MAC_PACKAGE_PATH
start_local_compat_signaling=$START_LOCAL_COMPAT_SIGNALING
start_local_turn=$START_LOCAL_TURN
pqc_enabled=$PQC_ENABLED
pqc_minimum_tier=$PQC_MINIMUM_TIER
expect_qperiapt=$EXPECT_QPERIAPT
expected_negotiated_suite=$EXPECTED_NEGOTIATED_SUITE
require_direct_route=$REQUIRE_DIRECT_ROUTE
android_timeout_seconds=$ANDROID_TIMEOUT_SECONDS
mac_timeout_seconds=$MAC_TIMEOUT_SECONDS
mac_hold_after_success_seconds=$MAC_HOLD_AFTER_SUCCESS_SECONDS
keychain_read_timeout_seconds=$KEYCHAIN_READ_TIMEOUT_SECONDS
signaling_log=$SIGNALING_LOG
turn_log=$TURN_LOG
class_name=$CLASS_NAME
run_dir=$RUN_DIR
EOF
{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "swift=$(swift --version 2>/dev/null | head -n 1)"
  if command -v sw_vers >/dev/null 2>&1; then
    echo "macos_product_version=$(sw_vers -productVersion 2>/dev/null | tr -d '\r\n')"
  fi
  echo "adb=$("$ADB_BIN" version 2>/dev/null | head -n 1)"
  echo "device_model=$(android_device_prop "$ADB_BIN" "$DEVICE_SERIAL" ro.product.model)"
  echo "device_release=$ANDROID_DEVICE_RELEASE"
  echo "device_sdk=$ANDROID_DEVICE_SDK"
  echo "android_user_id=$ANDROID_USER_ID"
  echo "start_local_compat_signaling=$START_LOCAL_COMPAT_SIGNALING"
  echo "start_local_turn=$START_LOCAL_TURN"
} >"$ENV_FILE"
skybridge_append_git_source_binding "$ENV_FILE" android "$RELEASE_REPO_ROOT"
skybridge_append_git_source_binding "$ENV_FILE" apple "$MAC_PACKAGE_PATH"

SIGNALING_PORT="$(ws_port "$WS_URL")"
if [[ "$START_LOCAL_TURN" == "true" ]]; then
  command -v turnserver >/dev/null 2>&1 \
    || fail_local_service_start "local_turn_start" "turnserver_not_found" "$TURN_LOG" "turnserver not found in PATH"
  turnserver \
    -n \
    -L 127.0.0.1 \
    -E 127.0.0.1 \
    -p 3478 \
    --no-tls \
    --no-dtls \
    --no-tcp \
    --allow-loopback-peers \
    --min-port 50000 \
    --max-port 50020 \
    --pidfile "$RUN_DIR/turnserver.pid" \
    -a \
    -u local:local \
    -r skybridge-local-smoke \
    --log-file stdout \
    --simple-log \
    --no-software-attribute >"$TURN_LOG" 2>&1 &
  TURN_PID=$!
  sleep 1
  kill -0 "$TURN_PID" >/dev/null 2>&1 \
    || fail_local_service_start "local_turn_start" "turnserver_exited" "$TURN_LOG" "local turnserver exited before smoke start"
fi

if [[ "$START_LOCAL_COMPAT_SIGNALING" == "true" ]]; then
  [[ -n "$SIGNALING_PORT" ]] \
    || fail_local_service_start "local_signaling_start" "ws_url_missing_port" "$SIGNALING_LOG" "loopback compat signaling requires a ws-url with a port"
  (
    cd "$SIGNALING_DIR"
    HOST=127.0.0.1 \
      PORT="$SIGNALING_PORT" \
      PUBLIC_HOST="127.0.0.1:$SIGNALING_PORT" \
      TURN_URIS="turn:127.0.0.1:3478?transport=udp,turn:10.0.2.2:3478?transport=udp" \
      node local_compat_server.js
  ) >"$SIGNALING_LOG" 2>&1 &
  SIGNALING_PID=$!
  sleep 1
  kill -0 "$SIGNALING_PID" >/dev/null 2>&1 \
    || fail_local_service_start "local_signaling_start" "local_compat_server_exited" "$SIGNALING_LOG" "local compat signaling exited before smoke start"
  SIGNALING_ORIGIN="$(ws_http_origin "$WS_URL")"
  for _ in $(seq 1 40); do
    if curl -fsS "$SIGNALING_ORIGIN/health" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  curl -fsS "$SIGNALING_ORIGIN/health" >/dev/null 2>&1 \
    || fail_local_service_start "local_signaling_start" "local_compat_server_unhealthy" "$SIGNALING_LOG" "local compat signaling health check failed"
fi

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
  if ! KEYCHAIN_AUTH_PAYLOAD="$(
    read_keychain_generic_password \
      "com.skybridge.compass.authsession" \
      "primary" \
      "$RUN_DIR/mac-authsession.keychain.err" \
      "$KEYCHAIN_READ_TIMEOUT_SECONDS"
  )"; then
    fail_keychain_read \
      "mac_auth_keychain_read" \
      "keychain_read_failed" \
      "$RUN_DIR/mac-authsession.keychain.err" \
      "Unable to read mac auth session from keychain"
  fi

  HOST_BEARER_TOKEN="$(printf '%s' "$KEYCHAIN_AUTH_PAYLOAD" | json_field_from_payload accessToken)"
  HOST_REFRESH_TOKEN="$(printf '%s' "$KEYCHAIN_AUTH_PAYLOAD" | json_field_from_payload refreshToken)"
  HOST_USER_ID="$(printf '%s' "$KEYCHAIN_AUTH_PAYLOAD" | json_field_from_payload userIdentifier)"
  HOST_DISPLAY_NAME="$(printf '%s' "$KEYCHAIN_AUTH_PAYLOAD" | json_field_from_payload displayName)"
  HOST_NEBULA_ID="$(printf '%s' "$KEYCHAIN_AUTH_PAYLOAD" | json_field_from_payload nebulaId)"
  unset KEYCHAIN_AUTH_PAYLOAD
fi

if [[ -z "$SUPABASE_URL" ]]; then
  if ! SUPABASE_URL="$(
    read_keychain_generic_password \
      "SkyBridge.Supabase" \
      "URL" \
      "$RUN_DIR/mac-supabase-url.keychain.err" \
      "$KEYCHAIN_READ_TIMEOUT_SECONDS" | tr -d '\r\n'
  )"; then
    fail_keychain_read \
      "supabase_url_keychain_read" \
      "keychain_read_failed" \
      "$RUN_DIR/mac-supabase-url.keychain.err" \
      "Unable to read Supabase URL from keychain"
  fi
fi
if [[ -z "$SUPABASE_ANON_KEY" ]]; then
  if ! SUPABASE_ANON_KEY="$(
    read_keychain_generic_password \
      "SkyBridge.Supabase" \
      "AnonKey" \
      "$RUN_DIR/mac-supabase-anon.keychain.err" \
      "$KEYCHAIN_READ_TIMEOUT_SECONDS" | tr -d '\r\n'
  )"; then
    fail_keychain_read \
      "supabase_anon_key_keychain_read" \
      "keychain_read_failed" \
      "$RUN_DIR/mac-supabase-anon.keychain.err" \
      "Unable to read Supabase anon key from keychain"
  fi
fi
if [[ -z "$HOST_BEARER_TOKEN" || -z "$SUPABASE_URL" || -z "$SUPABASE_ANON_KEY" ]]; then
  echo "Unable to prepare mac smoke auth context from keychain" >&2
  exit 1
fi

if [[ -z "$HOST_TENANT_ID" && -n "$HOST_BEARER_TOKEN" ]]; then
  HOST_TENANT_ID="$(printf '%s' "$HOST_BEARER_TOKEN" | derive_tenant_identifier)"
fi
if [[ -z "$HOST_TENANT_ID" ]]; then
  echo "Unable to derive tenant id for Android cross-network smoke" >&2
  exit 1
fi
ANDROID_SMOKE_DISPLAY_NAME="${SKYBRIDGE_ANDROID_SMOKE_DISPLAY_NAME:-$HOST_DISPLAY_NAME}"
ANDROID_SMOKE_NEBULA_ID="${SKYBRIDGE_ANDROID_SMOKE_NEBULA_ID:-$HOST_NEBULA_ID}"

MAC_SIGNALING_WS_URL="$WS_URL"
MAC_SIGNALING_SERVER_URL="$(printf '%s' "$WS_URL" | sed -E 's#^ws://#http://#; s#^wss://#https://#; s#/ws([/?].*)?$##')"
USE_IN_MEMORY_IDENTITY="${SKYBRIDGE_SMOKE_USE_IN_MEMORY_IDENTITY:-0}"
INCLUDE_REFRESH_TOKEN="${SKYBRIDGE_SMOKE_INCLUDE_REFRESH_TOKEN:-0}"
REQUESTED_HOST_AUTH_MODE="${SKYBRIDGE_SMOKE_HOST_AUTH_MODE:-auto}"
TOKEN_EXPIRY_STATE="unknown"

if [[ -n "$HOST_BEARER_TOKEN" ]]; then
  TOKEN_EXPIRY_STATE="$(printf '%s' "$HOST_BEARER_TOKEN" | jwt_is_expired)"
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
  echo "android_smoke_business_identity_present=$(if [[ -n "$ANDROID_SMOKE_DISPLAY_NAME" && -n "$ANDROID_SMOKE_NEBULA_ID" ]]; then echo true; else echo false; fi)"
} >>"$ENV_FILE"

ADB_REVERSE_PORT="$(adb_reverse_port_for_ws_url "$WS_URL")"
if [[ -n "$ADB_REVERSE_PORT" ]]; then
  if ! "$ADB_BIN" -s "$DEVICE_SERIAL" reverse "tcp:$ADB_REVERSE_PORT" "tcp:$ADB_REVERSE_PORT" >"$ADB_REVERSE_LOG" 2>&1; then
    echo "Unable to configure adb reverse for loopback WebRTC smoke; see $ADB_REVERSE_LOG" >&2
    exit 1
  fi
fi

DEVICE_PROXY_CLEARED_FOR_LOOPBACK="false"
if [[ "$(is_loopback_ws_url "$WS_URL")" == "true" ]]; then
  ORIGINAL_HTTP_PROXY="$(adb_global_setting_get http_proxy)"
  ORIGINAL_GLOBAL_HTTP_PROXY_HOST="$(adb_global_setting_get global_http_proxy_host)"
  ORIGINAL_GLOBAL_HTTP_PROXY_PORT="$(adb_global_setting_get global_http_proxy_port)"
  ORIGINAL_GLOBAL_HTTP_PROXY_EXCLUSION_LIST="$(adb_global_setting_get global_http_proxy_exclusion_list)"
  if [[ "$ORIGINAL_HTTP_PROXY" != "null" ||
        "$ORIGINAL_GLOBAL_HTTP_PROXY_HOST" != "null" ||
        "$ORIGINAL_GLOBAL_HTTP_PROXY_PORT" != "null" ]]; then
    DEVICE_PROXY_RESTORE_NEEDED="1"
    DEVICE_PROXY_CLEARED_FOR_LOOPBACK="true"
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell settings delete global http_proxy >/dev/null 2>&1 || true
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell settings delete global global_http_proxy_host >/dev/null 2>&1 || true
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell settings delete global global_http_proxy_port >/dev/null 2>&1 || true
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell settings delete global global_http_proxy_exclusion_list >/dev/null 2>&1 || true
    if [[ "$(adb_global_setting_get http_proxy)" != "null" ||
          "$(adb_global_setting_get global_http_proxy_host)" != "null" ||
          "$(adb_global_setting_get global_http_proxy_port)" != "null" ]]; then
      echo "Unable to clear device HTTP proxy for loopback smoke; aborting before instrumentation." >&2
      exit 1
    fi
  fi
fi
{
  echo "adb_reverse_port=${ADB_REVERSE_PORT:-none}"
  echo "adb_reverse_log=$ADB_REVERSE_LOG"
  echo "device_proxy_cleared_for_loopback=$DEVICE_PROXY_CLEARED_FOR_LOOPBACK"
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
HOST_ACCESS_TOKEN_REFRESHED="false"

if [[ "$TOKEN_EXPIRY_STATE" == "true" && -n "$HOST_REFRESH_TOKEN" ]]; then
  if REFRESHED_SESSION_PAYLOAD="$(printf '%s' "$HOST_REFRESH_TOKEN" | refresh_supabase_session "$SUPABASE_URL" "$SUPABASE_ANON_KEY" - 2>"$RUN_DIR/mac-authsession.refresh.err")"; then
    REFRESHED_BEARER_TOKEN="$(printf '%s' "$REFRESHED_SESSION_PAYLOAD" | json_field_from_payload access_token)"
    REFRESHED_REFRESH_TOKEN="$(printf '%s' "$REFRESHED_SESSION_PAYLOAD" | json_field_from_payload refresh_token)"
    if [[ -n "$REFRESHED_BEARER_TOKEN" ]]; then
      HOST_BEARER_TOKEN="$REFRESHED_BEARER_TOKEN"
      if [[ -n "$REFRESHED_REFRESH_TOKEN" ]]; then
        HOST_REFRESH_TOKEN="$REFRESHED_REFRESH_TOKEN"
      fi
      TOKEN_EXPIRY_STATE="$(printf '%s' "$HOST_BEARER_TOKEN" | jwt_is_expired)"
      HOST_ACCESS_TOKEN_REFRESHED="true"
    fi
    unset REFRESHED_SESSION_PAYLOAD
  else
    echo "Mac auth session access token is expired and refresh failed; see $RUN_DIR/mac-authsession.refresh.err" >&2
    exit 1
  fi
fi

if [[ "$TOKEN_EXPIRY_STATE" == "true" ]]; then
  echo "Mac auth session access token is still expired after refresh." >&2
  exit 1
fi

echo "Building Android debug + androidTest APKs before launching mac smoke host..."
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
  echo "android_prebuild_ok=true"
  echo "app_apk=$APP_APK"
  echo "test_apk=$TEST_APK"
} >>"$ENV_FILE"
android_collect_source_provenance "$ROOT_DIR" "$PROVENANCE_DIR" >"$PROVENANCE_FILE"
android_collect_apk_provenance "$APP_APK" "app_debug_apk" >>"$PROVENANCE_FILE"
android_collect_apk_provenance "$TEST_APK" "android_test_apk" >>"$PROVENANCE_FILE"
cat "$PROVENANCE_FILE" >>"$ENV_FILE"

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
  export SKYBRIDGE_CLIENT_VERSION="$CLIENT_VERSION"
  export SKYBRIDGE_PROTOCOL_VERSION="$PROTOCOL_VERSION"
  export SKYBRIDGE_SIGNALING_SERVER_URL="$HOST_SIGNALING_SERVER_URL"
  export SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$HOST_SIGNALING_WS_URL"
  if [[ "$PQC_ENABLED" == "true" ]]; then
    export SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY="1"
  else
    unset SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY || true
  fi
  if [[ "$EXPECT_QPERIAPT" == "true" ]]; then
    export SB_ENABLE_QPERIAPT="1"
    export SKYBRIDGE_PQC_PREFERRED_SUITE="q-periapt"
    export SKYBRIDGE_SMOKE_EXPECT_QPERIAPT="1"
  else
    unset SB_ENABLE_QPERIAPT || true
    unset SKYBRIDGE_PQC_PREFERRED_SUITE || true
    unset SKYBRIDGE_SMOKE_EXPECT_QPERIAPT || true
  fi
  swift run \
    --package-path "$MAC_PACKAGE_PATH" \
    --scratch-path "$RUN_DIR/mac-swiftpm" \
    --disable-automatic-resolution \
    LocalWebRTCSmokeHost
) >"$HOST_STDOUT_FILE" 2>&1 &
HOST_PID=$!

for _ in $(seq 1 $(( CODE_WAIT_SECONDS * 2 ))); do
  if [[ -s "$HOST_CODE_FILE" ]]; then
    break
  fi
  if ! kill -0 "$HOST_PID" >/dev/null 2>&1; then
    set +e
    wait "$HOST_PID"
    HOST_EXIT="$?"
    set -e
    HOST_PID=""
    fail_mac_host_pre_connection_code \
      "mac_host_exited_before_connection_code" \
      "$HOST_EXIT" \
      "mac smoke host exited before producing a connection code"
  fi
  sleep 0.5
done

if [[ ! -s "$HOST_CODE_FILE" ]]; then
  fail_mac_host_pre_connection_code \
    "connection_code_timeout" \
    "still_running" \
    "Timed out waiting for connection code from mac smoke host"
fi

CONNECTION_CODE="$(tr -d '\r\n' < "$HOST_CODE_FILE")"
if [[ -z "$CONNECTION_CODE" ]]; then
  fail_mac_host_pre_connection_code \
    "connection_code_empty" \
    "still_running" \
    "Connection code file was empty"
fi
rm -f "$HOST_CODE_FILE"

echo "Connection code: <redacted>"
{
  "$ADB_BIN" -s "$DEVICE_SERIAL" wait-for-device
  "$ADB_BIN" -s "$DEVICE_SERIAL" install -r "$APP_APK"
  "$ADB_BIN" -s "$DEVICE_SERIAL" install -r -t "$TEST_APK"
} >"$INSTALL_LOG" 2>&1

AUTH_CONTEXT_PAYLOAD="$(
  {
    printf '%s\n' "$HOST_BEARER_TOKEN"
    printf '%s\n' "$HOST_TENANT_ID"
    printf '%s\n' "$ANDROID_SMOKE_DISPLAY_NAME"
    printf '%s\n' "$ANDROID_SMOKE_NEBULA_ID"
  } | python3 -c '
import json
import sys

bearer = sys.stdin.readline().rstrip("\n")
tenant = sys.stdin.readline().rstrip("\n")
display_name = sys.stdin.readline().rstrip("\n")
nebula_id = sys.stdin.readline().rstrip("\n")
if not bearer or not tenant:
    raise SystemExit("missing auth context")
payload = {"bearerToken": bearer, "tenantId": tenant}
if display_name:
    payload["accountDisplayName"] = display_name
if nebula_id:
    payload["nebulaId"] = nebula_id
print(json.dumps(payload, separators=(",", ":")))
'
)"
printf '%s' "$AUTH_CONTEXT_PAYLOAD" |
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "run-as com.skybridge.compass.debug sh -c 'mkdir -p files && umask 077 && cat > files/$AUTH_CONTEXT_FILE_NAME'"
unset AUTH_CONTEXT_PAYLOAD
printf '%s' "$CONNECTION_CODE" |
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "run-as com.skybridge.compass.debug sh -c 'mkdir -p files && umask 077 && cat > files/$CODE_CONTEXT_FILE_NAME'"
unset CONNECTION_CODE

"$ADB_BIN" -s "$DEVICE_SERIAL" logcat -c >/dev/null 2>&1 || true

echo "Running instrumentation smoke on device $DEVICE_SERIAL..."
ANDROID_POST_SUCCESS_HOLD_MILLIS="$(( (MAC_HOLD_AFTER_SUCCESS_SECONDS + 1) * 1000 ))"
ANDROID_INSTRUMENT_ARGS=(
  am instrument -w --user "$ANDROID_USER_ID"
  -e class "$CLASS_NAME"
  -e skybridgeCodeFile "$CODE_CONTEXT_FILE_NAME"
  -e skybridgeWsUrl "$WS_URL"
  -e skybridgeTimeoutSeconds "$ANDROID_TIMEOUT_SECONDS"
  -e skybridgePqcEnabled "$PQC_ENABLED"
  -e skybridgePqcMinimumTier "$PQC_MINIMUM_TIER"
  -e skybridgeExpectQPeriapt "$EXPECT_QPERIAPT"
  -e skybridgePostSuccessHoldMillis "$ANDROID_POST_SUCCESS_HOLD_MILLIS"
  -e skybridgeAuthContextFile "$AUTH_CONTEXT_FILE_NAME"
  -e skybridgeClientVersion "$CLIENT_VERSION"
  -e skybridgeProtocolVersion "$PROTOCOL_VERSION"
  -e skybridgeRequireDirectRoute "$REQUIRE_DIRECT_ROUTE"
)
if [[ -n "$EXPECTED_NEGOTIATED_SUITE" ]]; then
  ANDROID_INSTRUMENT_ARGS+=(-e skybridgeExpectedNegotiatedSuite "$EXPECTED_NEGOTIATED_SUITE")
fi
ANDROID_INSTRUMENT_ARGS+=("$DEFAULT_RUNNER")
set +e
"$ADB_BIN" -s "$DEVICE_SERIAL" shell "${ANDROID_INSTRUMENT_ARGS[@]}" | tee "$ANDROID_INSTRUMENTATION_LOG"
INSTRUMENT_EXIT="${PIPESTATUS[0]}"
set -e

"$ADB_BIN" -s "$DEVICE_SERIAL" shell run-as com.skybridge.compass.debug \
  rm -f "files/$AUTH_CONTEXT_FILE_NAME" "files/$CODE_CONTEXT_FILE_NAME" >/dev/null 2>&1 || true

ANDROID_LOGCAT_CAPTURE_OK="true"
if ! android_capture_redacted_logcat "$ADB_BIN" "$DEVICE_SERIAL" "$ANDROID_LOGCAT_LOG" "$ANDROID_HANDSHAKE_LOG"; then
  ANDROID_LOGCAT_CAPTURE_OK="false"
fi

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

ANDROID_SMOKE_SUCCESS_LINE="$(
  grep -h 'SB-ANDROID-APP-SMOKE success\|SB-ANDROID-APP-OFFER success\|SB-ANDROID-SMOKE success' \
    "$ANDROID_INSTRUMENTATION_LOG" "$ANDROID_HANDSHAKE_LOG" 2>/dev/null |
    head -n 1 || true
)"
if [[ -z "$ANDROID_SMOKE_SUCCESS_LINE" ]]; then
  echo "Instrumentation passed but no Android smoke success line was emitted" >&2
  exit 1
fi
MAC_HOST_SUCCESS_LINE="$(grep -m 1 'success session=' "$HOST_STATUS_FILE" || true)"
ANDROID_NEGOTIATED_SUITE="$(
  printf '%s\n' "$ANDROID_SMOKE_SUCCESS_LINE" |
    sed -n 's/.* suite=\([^ ]*\).*/\1/p'
)"
ANDROID_SELECTED_ROUTE="$(
  printf '%s\n' "$ANDROID_SMOKE_SUCCESS_LINE" |
    sed -n 's/.* route=\([^ ]*\).*/\1/p'
)"
if [[ "$REQUIRE_DIRECT_ROUTE" == "true" && "$ANDROID_SELECTED_ROUTE" != "direct" ]]; then
  echo "Direct-route smoke did not produce route=direct (actual=${ANDROID_SELECTED_ROUTE:-missing})" >&2
  exit 1
fi
ANDROID_QPERIAPT_ASSERTED="$(
  printf '%s\n' "$ANDROID_SMOKE_SUCCESS_LINE" |
    sed -n 's/.* qperiapt=\([^ ]*\).*/\1/p'
)"
ANDROID_BOOTSTRAP_QPERIAPT="$(
  printf '%s\n' "$ANDROID_SMOKE_SUCCESS_LINE" |
    sed -n 's/.* bootstrapQPeriapt=\([^ ]*\).*/\1/p'
)"
ANDROID_FILE_TRANSFER_ASSERTED="$(
  printf '%s\n' "$ANDROID_SMOKE_SUCCESS_LINE" |
    sed -n 's/.* fileTransfer=\([^ ]*\).*/\1/p'
)"
ANDROID_FILE_TRANSFER_BYTES="$(
  printf '%s\n' "$ANDROID_SMOKE_SUCCESS_LINE" |
    sed -n 's/.* transferBytes=\([^ ]*\).*/\1/p'
)"
ANDROID_FILE_TRANSFER_SHA256="$(
  printf '%s\n' "$ANDROID_SMOKE_SUCCESS_LINE" |
    sed -n 's/.* payloadSha256=\([^ ]*\).*/\1/p'
)"
ANDROID_FILE_TRANSFER_OUTBOUND_OPS="$(
  printf '%s\n' "$ANDROID_SMOKE_SUCCESS_LINE" |
    sed -n 's/.* outboundOps=\([^ ]*\).*/\1/p'
)"
ANDROID_FILE_TRANSFER_INBOUND_ACKS="$(
  printf '%s\n' "$ANDROID_SMOKE_SUCCESS_LINE" |
    sed -n 's/.* inboundAcks=\([^ ]*\).*/\1/p'
)"
MAC_NEGOTIATED_SUITE="$(
  printf '%s\n' "$MAC_HOST_SUCCESS_LINE" |
    sed -n 's/.* suite=\([^ ]*\).*/\1/p'
)"
FILE_TRANSFER_ASSERTION_OK="true"
FILE_TRANSFER_ASSERTION_FAILURE=""
if [[ "$CLASS_NAME" == *FileTransfer* ]]; then
  if [[ "$ANDROID_FILE_TRANSFER_ASSERTED" != "true" ]]; then
    FILE_TRANSFER_ASSERTION_OK="false"
    FILE_TRANSFER_ASSERTION_FAILURE="android_file_transfer_asserted=$ANDROID_FILE_TRANSFER_ASSERTED"
  elif ! [[ "$ANDROID_FILE_TRANSFER_BYTES" =~ ^[0-9]+$ ]] || [[ "$ANDROID_FILE_TRANSFER_BYTES" -le 0 ]]; then
    FILE_TRANSFER_ASSERTION_OK="false"
    FILE_TRANSFER_ASSERTION_FAILURE="android_file_transfer_bytes=$ANDROID_FILE_TRANSFER_BYTES"
  elif ! [[ "$ANDROID_FILE_TRANSFER_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    FILE_TRANSFER_ASSERTION_OK="false"
    FILE_TRANSFER_ASSERTION_FAILURE="android_file_transfer_payload_sha256=$ANDROID_FILE_TRANSFER_SHA256"
  elif [[ "$ANDROID_FILE_TRANSFER_OUTBOUND_OPS" != "metadata,chunk,complete" ]]; then
    FILE_TRANSFER_ASSERTION_OK="false"
    FILE_TRANSFER_ASSERTION_FAILURE="android_file_transfer_outbound_ops=$ANDROID_FILE_TRANSFER_OUTBOUND_OPS"
  elif [[ "$ANDROID_FILE_TRANSFER_INBOUND_ACKS" != "metadataAck,chunkAck,completeAck" ]]; then
    FILE_TRANSFER_ASSERTION_OK="false"
    FILE_TRANSFER_ASSERTION_FAILURE="android_file_transfer_inbound_acks=$ANDROID_FILE_TRANSFER_INBOUND_ACKS"
  fi
fi
QPERIAPT_ASSERTION_OK="true"
QPERIAPT_ASSERTION_FAILURE=""
if [[ "$EXPECT_QPERIAPT" == "true" ]]; then
  EXPECTED_ANDROID_QPERIAPT_SUITE="Q_PERIAPT_CONTEXT_BOUND/0x0011"
  EXPECTED_MAC_QPERIAPT_SUITE="Q-Periapt-ContextBound"
  if [[ "$ANDROID_QPERIAPT_ASSERTED" != "true" ]]; then
    QPERIAPT_ASSERTION_OK="false"
    QPERIAPT_ASSERTION_FAILURE="android_qperiapt_asserted=$ANDROID_QPERIAPT_ASSERTED"
  elif [[ "$ANDROID_BOOTSTRAP_QPERIAPT" != "true" ]]; then
    QPERIAPT_ASSERTION_OK="false"
    QPERIAPT_ASSERTION_FAILURE="android_bootstrap_qperiapt=$ANDROID_BOOTSTRAP_QPERIAPT"
  elif [[ "$ANDROID_NEGOTIATED_SUITE" != "$EXPECTED_ANDROID_QPERIAPT_SUITE" ]]; then
    QPERIAPT_ASSERTION_OK="false"
    QPERIAPT_ASSERTION_FAILURE="android_negotiated_suite=$ANDROID_NEGOTIATED_SUITE expected=$EXPECTED_ANDROID_QPERIAPT_SUITE"
  elif [[ "$MAC_NEGOTIATED_SUITE" != "$EXPECTED_MAC_QPERIAPT_SUITE" ]]; then
    QPERIAPT_ASSERTION_OK="false"
    QPERIAPT_ASSERTION_FAILURE="mac_negotiated_suite=$MAC_NEGOTIATED_SUITE expected=$EXPECTED_MAC_QPERIAPT_SUITE"
  fi
fi

{
  echo "instrumentation_ok=true"
  echo "mac_host_ok=true"
  echo "session_keys_asserted_by_test=true"
  echo "android_logcat_capture_ok=$ANDROID_LOGCAT_CAPTURE_OK"
  echo "handshake_log_present=$(if [[ -s "$ANDROID_HANDSHAKE_LOG" ]]; then echo true; else echo false; fi)"
  echo "pqc_enabled=$PQC_ENABLED"
  echo "pqc_minimum_tier=$PQC_MINIMUM_TIER"
  echo "expected_qperiapt=$EXPECT_QPERIAPT"
  echo "expected_negotiated_suite=$EXPECTED_NEGOTIATED_SUITE"
  echo "require_direct_route=$REQUIRE_DIRECT_ROUTE"
  echo "android_selected_route=$ANDROID_SELECTED_ROUTE"
  echo "android_negotiated_suite=$ANDROID_NEGOTIATED_SUITE"
  echo "android_qperiapt_asserted=$ANDROID_QPERIAPT_ASSERTED"
  echo "android_bootstrap_qperiapt=$ANDROID_BOOTSTRAP_QPERIAPT"
  echo "android_file_transfer_asserted=$ANDROID_FILE_TRANSFER_ASSERTED"
  echo "android_file_transfer_bytes=$ANDROID_FILE_TRANSFER_BYTES"
  echo "android_file_transfer_payload_sha256=$ANDROID_FILE_TRANSFER_SHA256"
  echo "android_file_transfer_outbound_ops=$ANDROID_FILE_TRANSFER_OUTBOUND_OPS"
  echo "android_file_transfer_inbound_acks=$ANDROID_FILE_TRANSFER_INBOUND_ACKS"
  echo "file_transfer_assertion_ok=$FILE_TRANSFER_ASSERTION_OK"
  echo "file_transfer_assertion_failure=$FILE_TRANSFER_ASSERTION_FAILURE"
  echo "mac_negotiated_suite=$MAC_NEGOTIATED_SUITE"
  echo "qperiapt_assertion_ok=$QPERIAPT_ASSERTION_OK"
  echo "qperiapt_assertion_failure=$QPERIAPT_ASSERTION_FAILURE"
  echo "mac_host_success_seen=true"
  echo "android_smoke_success_seen=true"
  cat "$PROVENANCE_FILE"
} >"$SUMMARY_FILE"

if [[ "$ANDROID_LOGCAT_CAPTURE_OK" != "true" ]]; then
  echo "Android logcat capture/redaction failed; evidence bundle rejected." >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi

if [[ "$FILE_TRANSFER_ASSERTION_OK" != "true" ]]; then
  echo "File-transfer smoke assertion failed: $FILE_TRANSFER_ASSERTION_FAILURE" >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi

if [[ "$QPERIAPT_ASSERTION_OK" != "true" ]]; then
  echo "Q-Periapt exact-suite smoke assertion failed: $QPERIAPT_ASSERTION_FAILURE" >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi

echo "public_artifacts=$PUBLIC_ARTIFACT_DIR" >>"$SUMMARY_FILE"
if ! android_smoke_materialize_public_artifacts "$RUN_DIR" "$PUBLIC_ARTIFACT_DIR"; then
  echo "Android ↔ Apple public artifact materialization failed; evidence bundle rejected." >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi
if ! android_smoke_check_public_artifacts \
  "$PUBLIC_ARTIFACT_DIR" \
  "$DEVICE_SERIAL" \
  "$(tr -d '\r\n' < "$HOST_CODE_FILE" 2>/dev/null || true)" \
  "$HOST_TENANT_ID" \
  "$HOST_USER_ID"; then
  echo "Android ↔ Apple public artifact scan failed; evidence bundle rejected." >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi

echo "Android ↔ Apple WebRTC smoke passed."
echo "Artifacts:"
echo "  environment: $ENV_FILE"
echo "  provenance: $PROVENANCE_FILE"
echo "  command: $COMMAND_FILE"
echo "  mac host stdout: $HOST_STDOUT_FILE"
echo "  mac host status: $HOST_STATUS_FILE"
echo "  connection code: $HOST_CODE_FILE"
echo "  instrumentation: $ANDROID_INSTRUMENTATION_LOG"
echo "  logcat: $ANDROID_LOGCAT_LOG"
echo "  handshake log: $ANDROID_HANDSHAKE_LOG"
echo "  install log: $INSTALL_LOG"
echo "  public artifacts: $PUBLIC_ARTIFACT_DIR"
echo "  summary: $SUMMARY_FILE"
