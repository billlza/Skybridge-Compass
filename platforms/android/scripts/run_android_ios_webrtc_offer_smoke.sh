#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/repository_layout.sh"
RELEASE_REPO_ROOT="$(skybridge_canonical_release_root "$ROOT_DIR")"
source "$ROOT_DIR/scripts/lib/android_env.sh"
source "$ROOT_DIR/scripts/lib/source_provenance.sh"

DEFAULT_IOS_PROJECT_DIR="$RELEASE_REPO_ROOT/SkyBridge Compass iOS"
DEFAULT_SIGNALING_DIR="$RELEASE_REPO_ROOT/Server/skybridge-signaling"
DEFAULT_APP_CLASS="com.skybridge.compass.android.webrtc.AppleReleaseInteropOffererAppInstrumentationTest"
DEFAULT_RUNNER="com.skybridge.compass.debug.test/com.skybridge.compass.android.HiltTestRunner"
IOS_BUNDLE_ID="com.skybridge.compass.ios"

DEVICE_SERIAL=""
WS_URL=""
IOS_PROJECT_DIR="$DEFAULT_IOS_PROJECT_DIR"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_DESTINATION="${SKYBRIDGE_IOS_DESTINATION:-}"
IOS_DESTINATION_SOURCE="$(if [[ -n "$IOS_DESTINATION" ]]; then echo environment; else echo auto_simulator; fi)"
IOS_SIM_ID=""
SIGNALING_DIR="$DEFAULT_SIGNALING_DIR"
START_LOCAL_COMPAT_SIGNALING="false"
START_LOCAL_TURN="false"
PQC_ENABLED="true"
PQC_MINIMUM_TIER="${SKYBRIDGE_SMOKE_PQC_MINIMUM_TIER:-nativePQC}"
EXPECT_QPERIAPT="${SKYBRIDGE_SMOKE_EXPECT_QPERIAPT:-}"
EXPECTED_NEGOTIATED_SUITE="${SKYBRIDGE_SMOKE_EXPECTED_NEGOTIATED_SUITE:-}"
REQUIRE_DIRECT_ROUTE="${SKYBRIDGE_SMOKE_REQUIRE_DIRECT_ROUTE:-false}"
EXPECT_FILE_TRANSFER="${SKYBRIDGE_SMOKE_EXPECT_FILE_TRANSFER:-false}"
FILE_TRANSFER_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_FILE_TRANSFER_TIMEOUT_SECONDS:-30}"
ANDROID_TIMEOUT_SECONDS="180"
IOS_TIMEOUT_SECONDS="180"
POST_SUCCESS_HOLD_MILLIS="4000"
CLASS_NAME="$DEFAULT_APP_CLASS"
RUN_DIR=""
CLIENT_VERSION="${SKYBRIDGE_CLIENT_VERSION:-1.0.0}"
PROTOCOL_VERSION="${SKYBRIDGE_PROTOCOL_VERSION:-1}"

usage() {
  cat <<'EOF'
Usage:
  scripts/run_android_ios_webrtc_offer_smoke.sh \
    --device <adb-serial> \
    --ws-url <ws://host:port/ws> \
    [--ios-project-dir <path>] \
    [--ios-scheme <name>] \
    [--ios-destination <xcodebuild-destination>] \
    [--ios-sim-id <udid>] \
    [--start-local-compat-signaling true|false] \
    [--start-local-turn true|false] \
    [--pqc true|false] \
    [--pqc-minimum-tier nativePQC|liboqsPQC|qperiaptPQC|classic] \
    [--expect-qperiapt true|false] \
    [--expected-negotiated-suite <suite-name-or-wire-id>] \
    [--require-direct-route true|false] \
    [--expect-file-transfer true|false] \
    [--file-transfer-timeout-seconds <n>] \
    [--android-timeout-seconds <n>] \
    [--ios-timeout-seconds <n>] \
    [--post-success-hold-millis <n>] \
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

require_option_value() {
  local option="$1"
  local value="${2-}"
  if [[ -z "$value" ]]; then
    echo "Missing value for $option" >&2
    exit 1
  fi
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
from urllib.parse import urlparse, urlunparse

parsed = urlparse(sys.argv[1].strip())
scheme = parsed.scheme.lower()
if scheme == "ws":
    http_scheme = "http"
elif scheme == "wss":
    http_scheme = "https"
else:
    raise SystemExit("unsupported websocket URL scheme")
authority = parsed.netloc
path = parsed.path or ""
if path.endswith("/ws"):
    path = path[:-3]
else:
    path = ""
print(urlunparse((http_scheme, authority, path, "", "", "")))
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
    user_metadata.get("tenant_id"),
    user_metadata.get("tenantId"),
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

make_compat_token() {
  python3 - <<'PY'
import base64
import json
import time

def b64url_json(value):
    return base64.urlsafe_b64encode(
        json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")
    ).rstrip(b"=").decode("ascii")

tenant_id = "android-ios-emulator-smoke-tenant"
user_id = "android-ios-emulator-smoke-user"
header = b64url_json({"alg": "none", "typ": "JWT"})
payload = b64url_json({
    "sub": user_id,
    "tenant_id": tenant_id,
    "app_metadata": {"tenant_id": tenant_id},
    "user_metadata": {"tenant_id": tenant_id},
    "iat": int(time.time()),
    "exp": int(time.time()) + 3600,
})
signature = base64.urlsafe_b64encode(b"android-ios-emulator-smoke").rstrip(b"=").decode("ascii")
print(f"{header}.{payload}.{signature}")
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
  if [[ "$1" == --* && "$1" != "--help" && "$1" != "--allow-static-ed25519-fallback" ]]; then
    require_option_value "$1" "${2-}"
  fi
  case "$1" in
    --device) DEVICE_SERIAL="${2:-}"; shift 2 ;;
    --ws-url) WS_URL="${2:-}"; shift 2 ;;
    --ios-project-dir) IOS_PROJECT_DIR="${2:-}"; shift 2 ;;
    --ios-scheme) IOS_SCHEME="${2:-}"; shift 2 ;;
    --ios-destination)
      IOS_DESTINATION="${2:-}"
      IOS_DESTINATION_SOURCE="argument"
      shift 2
      ;;
    --ios-sim-id) IOS_SIM_ID="${2:-}"; shift 2 ;;
    --signaling-dir) SIGNALING_DIR="${2:-}"; shift 2 ;;
    --start-local-compat-signaling) START_LOCAL_COMPAT_SIGNALING="${2:-}"; shift 2 ;;
    --start-local-turn) START_LOCAL_TURN="${2:-}"; shift 2 ;;
    --pqc) PQC_ENABLED="${2:-}"; shift 2 ;;
    --pqc-minimum-tier) PQC_MINIMUM_TIER="${2:-}"; shift 2 ;;
    --expect-qperiapt) EXPECT_QPERIAPT="${2:-}"; shift 2 ;;
    --expected-negotiated-suite) EXPECTED_NEGOTIATED_SUITE="${2:-}"; shift 2 ;;
    --require-direct-route) REQUIRE_DIRECT_ROUTE="${2:-}"; shift 2 ;;
    --expect-file-transfer) EXPECT_FILE_TRANSFER="${2:-}"; shift 2 ;;
    --file-transfer-timeout-seconds) FILE_TRANSFER_TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --allow-static-ed25519-fallback)
      echo "--allow-static-ed25519-fallback was removed; smoke runs must use generated device identity keys" >&2
      exit 1
      ;;
    --android-timeout-seconds) ANDROID_TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --ios-timeout-seconds) IOS_TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --post-success-hold-millis) POST_SUCCESS_HOLD_MILLIS="${2:-}"; shift 2 ;;
    --class) CLASS_NAME="${2:-}"; shift 2 ;;
    --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$DEVICE_SERIAL" || -z "$WS_URL" ]]; then
  usage >&2
  exit 1
fi

require_boolean "--start-local-compat-signaling" "$START_LOCAL_COMPAT_SIGNALING"
require_boolean "--start-local-turn" "$START_LOCAL_TURN"
require_boolean "--pqc" "$PQC_ENABLED"
require_boolean "--expect-file-transfer" "$EXPECT_FILE_TRANSFER"
require_boolean "--require-direct-route" "$REQUIRE_DIRECT_ROUTE"
if ! [[ "$FILE_TRANSFER_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$FILE_TRANSFER_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "Unsupported --file-transfer-timeout-seconds value: $FILE_TRANSFER_TIMEOUT_SECONDS" >&2
  exit 1
fi
if [[ "$START_LOCAL_COMPAT_SIGNALING" == "true" && "$START_LOCAL_TURN" != "true" ]]; then
  echo "Local compat Android -> iOS smoke requires --start-local-turn true because TURN admission is fail-closed." >&2
  exit 1
fi

case "$PQC_MINIMUM_TIER" in
  nativePQC|liboqsPQC|qperiaptPQC|classic) ;;
  *) echo "Unsupported --pqc-minimum-tier value: $PQC_MINIMUM_TIER" >&2; exit 1 ;;
esac

if [[ -z "$EXPECT_QPERIAPT" ]]; then
  if [[ "$PQC_MINIMUM_TIER" == "qperiaptPQC" ]]; then
    EXPECT_QPERIAPT="true"
  else
    EXPECT_QPERIAPT="false"
  fi
fi
require_boolean "--expect-qperiapt" "$EXPECT_QPERIAPT"
if [[ "$EXPECT_QPERIAPT" == "true" ]]; then
  if [[ "$PQC_ENABLED" != "true" || "$PQC_MINIMUM_TIER" != "qperiaptPQC" ]]; then
    echo "Q-Periapt smoke requires --pqc true and --pqc-minimum-tier qperiaptPQC" >&2
    exit 1
  fi
  EXPECTED_NEGOTIATED_SUITE="${EXPECTED_NEGOTIATED_SUITE:-Q_PERIAPT_CONTEXT_BOUND}"
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

if [[ "$EXPECT_QPERIAPT" == "true" ]]; then
  require_macos26_host
fi
command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild not found in PATH" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "xcrun not found in PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found in PATH" >&2; exit 1; }

IOS_PROJECT_DIR="$(skybridge_require_ios_project_dir "$IOS_PROJECT_DIR")"
IOS_PROJECT_FILE="$IOS_PROJECT_DIR/SkyBridgeCompass-iOS.xcodeproj"

if [[ -n "$IOS_SIM_ID" && -z "$IOS_DESTINATION" ]]; then
  IOS_DESTINATION="platform=iOS Simulator,id=$IOS_SIM_ID"
  IOS_DESTINATION_SOURCE="sim_id_argument"
fi

if [[ -z "$IOS_DESTINATION" ]]; then
  IOS_DESTINATION="$(
    xcrun simctl list devices available -j |
      python3 "$ROOT_DIR/scripts/resolve_ios_simulator_destination.py"
  )"
fi

RESOLVED_IOS_SIM_ID="$(
  xcrun simctl list devices available -j |
    python3 "$ROOT_DIR/scripts/resolve_ios_simulator_destination.py" \
      --udid-from-destination "$IOS_DESTINATION"
)"
if [[ -n "$IOS_SIM_ID" && "$IOS_SIM_ID" != "$RESOLVED_IOS_SIM_ID" ]]; then
  echo "--ios-sim-id ($IOS_SIM_ID) does not match --ios-destination ($RESOLVED_IOS_SIM_ID)" >&2
  exit 1
fi
IOS_SIM_ID="$RESOLVED_IOS_SIM_ID"

if [[ "$START_LOCAL_COMPAT_SIGNALING" == "true" && ! -f "$SIGNALING_DIR/local_compat_server.js" ]]; then
  echo "local compat signaling server not found: $SIGNALING_DIR/local_compat_server.js" >&2
  exit 1
fi

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$ROOT_DIR/build/interop/android-ios-webrtc-offer-smoke/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"

ENV_FILE="$RUN_DIR/environment.txt"
COMMAND_FILE="$RUN_DIR/command.txt"
SUMMARY_FILE="$RUN_DIR/summary.txt"
PUBLIC_ARTIFACT_DIR="$RUN_DIR/public-redacted"
PROVENANCE_DIR="$RUN_DIR/source-provenance"
PROVENANCE_FILE="$RUN_DIR/source-provenance.txt"
ANDROID_INSTALL_LOG="$RUN_DIR/android-install.log"
ANDROID_INSTRUMENTATION_LOG="$RUN_DIR/android-instrumentation.log"
ANDROID_LOGCAT_LOG="$RUN_DIR/android-logcat.txt"
ANDROID_HANDSHAKE_LOG="$RUN_DIR/android-handshake.log"
ANDROID_CODE_POLL_LOG="$RUN_DIR/android-code-poll.log"
IOS_BUILD_LOG="$RUN_DIR/ios-build.log"
IOS_STDOUT="$RUN_DIR/ios-stdout.log"
IOS_STDERR="$RUN_DIR/ios-stderr.log"
IOS_STATUS_BASENAME="android-ios-offer-ios.status.log"
IOS_STATUS_LOCAL="$RUN_DIR/$IOS_STATUS_BASENAME"
IOS_TRACE_BASENAME="${IOS_STATUS_BASENAME}.trace.log"
IOS_TRACE_LOCAL="$RUN_DIR/$IOS_TRACE_BASENAME"
SIGNALING_LOG="$RUN_DIR/signaling.log"
TURN_LOG="$RUN_DIR/turnserver.log"
ADB_REVERSE_LOG="$RUN_DIR/adb-reverse.log"
AUTH_CONTEXT_FILE_NAME="android-ios-offer-auth.json"
CODE_FILE_NAME="android-ios-offer-code.txt"

ANDROID_PID=""
SIGNALING_PID=""
TURN_PID=""
ADB_REVERSE_PORT=""
DEVICE_PROXY_RESTORE_NEEDED="0"
ORIGINAL_HTTP_PROXY=""
ORIGINAL_GLOBAL_HTTP_PROXY_HOST=""
ORIGINAL_GLOBAL_HTTP_PROXY_PORT=""
ORIGINAL_GLOBAL_HTTP_PROXY_EXCLUSION_LIST=""
IOS_ARTIFACT_REDACTION_FAILED="false"

cleanup() {
  if [[ -n "${ADB_BIN:-}" && -n "$DEVICE_SERIAL" ]]; then
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell run-as com.skybridge.compass.debug \
      rm -f "files/$AUTH_CONTEXT_FILE_NAME" "files/$CODE_FILE_NAME" >/dev/null 2>&1 || true
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
  if [[ -n "$ANDROID_PID" ]] && kill -0 "$ANDROID_PID" >/dev/null 2>&1; then
    kill "$ANDROID_PID" >/dev/null 2>&1 || true
    wait "$ANDROID_PID" >/dev/null 2>&1 || true
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

copy_ios_smoke_artifact() {
  local basename="$1"
  local local_path="$2"
  local container_root=""
  local artifact_path=""

  [[ -n "${IOS_SIM_ID:-}" ]] || return 0
  container_root="$HOME/Library/Developer/CoreSimulator/Devices/${IOS_SIM_ID}/data/Containers/Data/Application"
  [[ -d "$container_root" ]] || return 0

  artifact_path="$(find "$container_root" -name "$basename" -print 2>/dev/null | tail -n 1 || true)"
  if [[ -n "$artifact_path" && -f "$artifact_path" ]]; then
    if cp "$artifact_path" "$local_path" 2>/dev/null; then
      if ! redact_ios_smoke_artifact_file "$local_path"; then
        IOS_ARTIFACT_REDACTION_FAILED="true"
        printf '%s\n' "redaction_failed" >"$local_path"
        return 1
      fi
    fi
  fi
}

copy_ios_smoke_artifacts() {
  local redaction_failed="false"
  copy_ios_smoke_artifact "$IOS_STATUS_BASENAME" "$IOS_STATUS_LOCAL" || redaction_failed="true"
  copy_ios_smoke_artifact "$IOS_TRACE_BASENAME" "$IOS_TRACE_LOCAL" || redaction_failed="true"
  [[ "$redaction_failed" != "true" ]]
}

redact_ios_smoke_artifact_file() {
  local path="$1"
  local tmp_path="${path}.redacting"

  [[ -f "$path" ]] || return 0
  if redact_smoke_artifact_stream <"$path" | python3 -c '
import re
import sys

sessionish = re.compile(r"\b(session|shard)=\\?\"?[A-Za-z0-9._:-]{4,}\\?\"?")
session_id = re.compile(r"sessionId: \\?\"[A-Za-z0-9._:-]{4,}\\?\"")
connect_code = re.compile(r"\bconnect\s+(?!backend\b|shard\b|session\b|role\b|url\b)[A-Z0-9]{4,}\b")
key_value_identity = re.compile(r"\b(from|to|remoteId|remoteName|trackId)=([^\s]+)")
uuid_value = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")

for line in sys.stdin:
    line = uuid_value.sub("<redacted-uuid>", line)
    line = session_id.sub("sessionId: \"<redacted>\"", line)
    line = sessionish.sub(lambda m: f"{m.group(1)}=<redacted>", line)
    line = connect_code.sub("connect <redacted-code>", line)
    def replace_identity(match):
        key, value = match.group(1), match.group(2)
        if value in {"-", "0", "1"}:
            return match.group(0)
        return f"{key}=<redacted>"
    line = key_value_identity.sub(replace_identity, line)
    sys.stdout.write(line)
' >"$tmp_path"; then
    mv "$tmp_path" "$path"
  else
    rm -f "$tmp_path"
    return 1
  fi
}

fail_summary() {
  local stage="$1"
  local reason="$2"
  copy_ios_smoke_artifacts || true
  android_capture_redacted_logcat \
    "${ADB_BIN:-}" \
    "${DEVICE_SERIAL:-}" \
    "${ANDROID_LOGCAT_LOG:-}" \
    "${ANDROID_HANDSHAKE_LOG:-}" || true
  {
    echo "status=failed"
    echo "failure_stage=$stage"
    echo "failure_reason=$reason"
    echo "pqc_enabled=$PQC_ENABLED"
    echo "pqc_minimum_tier=$PQC_MINIMUM_TIER"
    echo "expected_qperiapt=$EXPECT_QPERIAPT"
    echo "expected_negotiated_suite=$EXPECTED_NEGOTIATED_SUITE"
    echo "expect_file_transfer=$EXPECT_FILE_TRANSFER"
    echo "android_instrumentation=$ANDROID_INSTRUMENTATION_LOG"
    echo "ios_status=$IOS_STATUS_LOCAL"
    echo "ios_trace=$IOS_TRACE_LOCAL"
    echo "ios_artifact_redaction_failed=$IOS_ARTIFACT_REDACTION_FAILED"
    echo "android_logcat=$ANDROID_LOGCAT_LOG"
    echo "command=$COMMAND_FILE"
    echo "environment=$ENV_FILE"
  } >"$SUMMARY_FILE"
  echo "Android -> iOS WebRTC offer smoke failed at $stage: $reason" >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
}

cat >"$COMMAND_FILE" <<EOF
script=scripts/run_android_ios_webrtc_offer_smoke.sh
device=$DEVICE_SERIAL
android_user_id=$ANDROID_USER_ID
ws_url=$(redact_smoke_artifact_url "$WS_URL")
ios_project_dir=$IOS_PROJECT_DIR
ios_scheme=$IOS_SCHEME
ios_destination=$IOS_DESTINATION
ios_destination_source=$IOS_DESTINATION_SOURCE
ios_sim_id=$IOS_SIM_ID
start_local_compat_signaling=$START_LOCAL_COMPAT_SIGNALING
start_local_turn=$START_LOCAL_TURN
pqc_enabled=$PQC_ENABLED
pqc_minimum_tier=$PQC_MINIMUM_TIER
expect_qperiapt=$EXPECT_QPERIAPT
expected_negotiated_suite=$EXPECTED_NEGOTIATED_SUITE
require_direct_route=$REQUIRE_DIRECT_ROUTE
expect_file_transfer=$EXPECT_FILE_TRANSFER
file_transfer_timeout_seconds=$FILE_TRANSFER_TIMEOUT_SECONDS
android_timeout_seconds=$ANDROID_TIMEOUT_SECONDS
ios_timeout_seconds=$IOS_TIMEOUT_SECONDS
post_success_hold_millis=$POST_SUCCESS_HOLD_MILLIS
run_dir=$RUN_DIR
EOF

{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "adb=$("$ADB_BIN" version 2>/dev/null | head -n 1)"
  echo "device_model=$(android_device_prop "$ADB_BIN" "$DEVICE_SERIAL" ro.product.model)"
  echo "device_release=$ANDROID_DEVICE_RELEASE"
  echo "device_sdk=$ANDROID_DEVICE_SDK"
  echo "android_user_id=$ANDROID_USER_ID"
  echo "xcodebuild=$(xcodebuild -version 2>/dev/null | tr '\n' '; ')"
  echo "ios_project=$IOS_PROJECT_FILE"
  echo "ios_destination=$IOS_DESTINATION"
  echo "ios_destination_source=$IOS_DESTINATION_SOURCE"
  echo "ios_sim_id=$IOS_SIM_ID"
} >"$ENV_FILE"
skybridge_append_git_source_binding "$ENV_FILE" android "$RELEASE_REPO_ROOT"
skybridge_append_git_source_binding "$ENV_FILE" apple "$IOS_PROJECT_DIR"

SIGNALING_PORT="$(ws_port "$WS_URL")"
if [[ "$START_LOCAL_TURN" == "true" ]]; then
  command -v turnserver >/dev/null 2>&1 || fail_summary "local_turn_start" "turnserver_not_found"
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
    --allowed-peer-ip=169.254.0.0-169.254.255.255 \
    --pidfile "$RUN_DIR/turnserver.pid" \
    -a \
    -u local:local \
    -r skybridge-local-smoke \
    --log-file stdout \
    --simple-log \
    --no-software-attribute >"$TURN_LOG" 2>&1 &
  TURN_PID=$!
  sleep 1
  kill -0 "$TURN_PID" >/dev/null 2>&1 || fail_summary "local_turn_start" "turnserver_exited"
fi

if [[ "$START_LOCAL_COMPAT_SIGNALING" == "true" ]]; then
  [[ -n "$SIGNALING_PORT" ]] || fail_summary "local_signaling_start" "ws_url_missing_port"
  LOCAL_COMPAT_TURN_URIS=""
  if [[ "$START_LOCAL_TURN" == "true" ]]; then
    LOCAL_COMPAT_TURN_URIS="turn:127.0.0.1:3478?transport=udp,turn:10.0.2.2:3478?transport=udp"
  fi
  (
    cd "$SIGNALING_DIR"
    HOST=127.0.0.1 \
      PORT="$SIGNALING_PORT" \
      PUBLIC_HOST="127.0.0.1:$SIGNALING_PORT" \
      TURN_URIS="$LOCAL_COMPAT_TURN_URIS" \
      node local_compat_server.js
  ) >"$SIGNALING_LOG" 2>&1 &
  SIGNALING_PID=$!
fi

SIGNALING_ORIGIN="$(ws_http_origin "$WS_URL")"
if [[ "$START_LOCAL_COMPAT_SIGNALING" == "true" ]]; then
  for _ in $(seq 1 40); do
    if curl -fsS "$SIGNALING_ORIGIN/health" >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$SIGNALING_PID" >/dev/null 2>&1; then
      fail_summary "local_signaling_start" "local_compat_server_exited"
    fi
    sleep 0.5
  done
  curl -fsS "$SIGNALING_ORIGIN/health" >/dev/null 2>&1 ||
    fail_summary "local_signaling_start" "local_compat_server_health_timeout"
fi

if [[ "$(is_loopback_ws_url "$WS_URL")" == "true" ]]; then
  [[ -n "$SIGNALING_PORT" ]] || fail_summary "adb_reverse" "loopback_ws_url_missing_port"
  ADB_REVERSE_PORT="$SIGNALING_PORT"
  if ! "$ADB_BIN" -s "$DEVICE_SERIAL" reverse "tcp:$ADB_REVERSE_PORT" "tcp:$ADB_REVERSE_PORT" >"$ADB_REVERSE_LOG" 2>&1; then
    fail_summary "adb_reverse" "adb_reverse_failed"
  fi
  ORIGINAL_HTTP_PROXY="$(adb_global_setting_get http_proxy)"
  ORIGINAL_GLOBAL_HTTP_PROXY_HOST="$(adb_global_setting_get global_http_proxy_host)"
  ORIGINAL_GLOBAL_HTTP_PROXY_PORT="$(adb_global_setting_get global_http_proxy_port)"
  ORIGINAL_GLOBAL_HTTP_PROXY_EXCLUSION_LIST="$(adb_global_setting_get global_http_proxy_exclusion_list)"
  if [[ "$ORIGINAL_HTTP_PROXY" != "null" ||
        "$ORIGINAL_GLOBAL_HTTP_PROXY_HOST" != "null" ||
        "$ORIGINAL_GLOBAL_HTTP_PROXY_PORT" != "null" ]]; then
    DEVICE_PROXY_RESTORE_NEEDED="1"
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell settings delete global http_proxy >/dev/null 2>&1 || true
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell settings delete global global_http_proxy_host >/dev/null 2>&1 || true
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell settings delete global global_http_proxy_port >/dev/null 2>&1 || true
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell settings delete global global_http_proxy_exclusion_list >/dev/null 2>&1 || true
  fi
fi

HOST_BEARER_TOKEN="${SKYBRIDGE_BEARER_TOKEN:-${SKYBRIDGE_ACCESS_TOKEN:-}}"
HOST_TENANT_ID="${SKYBRIDGE_TENANT_ID:-}"
HOST_USER_ID="${SKYBRIDGE_USER_ID:-}"
HOST_DISPLAY_NAME="${SKYBRIDGE_DISPLAY_NAME:-Android iOS Offer Smoke}"
if [[ -z "$HOST_BEARER_TOKEN" ]]; then
  if [[ "$(is_loopback_ws_url "$WS_URL")" != "true" ]]; then
    fail_summary "auth_context" "missing_bearer_token_for_non_loopback_smoke"
  fi
  HOST_BEARER_TOKEN="$(make_compat_token)"
  HOST_USER_ID="android-ios-emulator-smoke-user"
  HOST_TENANT_ID="android-ios-emulator-smoke-tenant"
fi
if [[ -z "$HOST_TENANT_ID" ]]; then
  HOST_TENANT_ID="$(printf '%s' "$HOST_BEARER_TOKEN" | derive_tenant_identifier)"
fi
[[ -n "$HOST_TENANT_ID" ]] || fail_summary "auth_context" "tenant_id_missing"

echo "Building Android debug + androidTest APKs..."
"$ROOT_DIR/gradlew" -p "$ROOT_DIR" :app:assembleDebug :app:assembleDebugAndroidTest >/dev/null
APP_APK="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"
TEST_APK="$(find "$ROOT_DIR/app/build/outputs/apk" -path '*androidTest*' -name '*.apk' | head -n 1)"
[[ -f "$APP_APK" ]] || fail_summary "android_build" "app_debug_apk_missing"
[[ -n "$TEST_APK" && -f "$TEST_APK" ]] || fail_summary "android_build" "android_test_apk_missing"
android_collect_source_provenance "$ROOT_DIR" "$PROVENANCE_DIR" >"$PROVENANCE_FILE"
android_collect_apk_provenance "$APP_APK" "app_debug_apk" >>"$PROVENANCE_FILE"
android_collect_apk_provenance "$TEST_APK" "android_test_apk" >>"$PROVENANCE_FILE"
cat "$PROVENANCE_FILE" >>"$ENV_FILE"

{
  "$ADB_BIN" -s "$DEVICE_SERIAL" wait-for-device
  "$ADB_BIN" -s "$DEVICE_SERIAL" install -r "$APP_APK"
  "$ADB_BIN" -s "$DEVICE_SERIAL" install -r -t "$TEST_APK"
} >"$ANDROID_INSTALL_LOG" 2>&1 || fail_summary "android_install" "install_failed"

AUTH_CONTEXT_PAYLOAD="$(
  {
    printf '%s\n' "$HOST_BEARER_TOKEN"
    printf '%s\n' "$HOST_TENANT_ID"
  } | python3 -c '
import json
import sys

bearer = sys.stdin.readline().rstrip("\n")
tenant = sys.stdin.readline().rstrip("\n")
if not bearer or not tenant:
    raise SystemExit("missing auth context")
print(json.dumps({"bearerToken": bearer, "tenantId": tenant}, separators=(",", ":")))
'
)"
printf '%s' "$AUTH_CONTEXT_PAYLOAD" |
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "run-as com.skybridge.compass.debug sh -c 'mkdir -p files && umask 077 && cat > files/$AUTH_CONTEXT_FILE_NAME'"
unset AUTH_CONTEXT_PAYLOAD

"$ADB_BIN" -s "$DEVICE_SERIAL" logcat -c >/dev/null 2>&1 || true

echo "Starting Android offerer instrumentation..."
ANDROID_INSTRUMENT_ARGS=(
  am instrument -w --user "$ANDROID_USER_ID"
  -e class "$CLASS_NAME"
  -e skybridgeWsUrl "$WS_URL"
  -e skybridgeTimeoutSeconds "$ANDROID_TIMEOUT_SECONDS"
  -e skybridgePqcEnabled "$PQC_ENABLED"
  -e skybridgePqcMinimumTier "$PQC_MINIMUM_TIER"
  -e skybridgeExpectQPeriapt "$EXPECT_QPERIAPT"
  -e skybridgeExpectFileTransfer "$EXPECT_FILE_TRANSFER"
  -e skybridgeFileTransferTimeoutSeconds "$FILE_TRANSFER_TIMEOUT_SECONDS"
  -e skybridgePostSuccessHoldMillis "$POST_SUCCESS_HOLD_MILLIS"
  -e skybridgeAuthContextFile "$AUTH_CONTEXT_FILE_NAME"
  -e skybridgeCodeOutputFile "$CODE_FILE_NAME"
  -e skybridgeClientVersion "$CLIENT_VERSION"
  -e skybridgeProtocolVersion "$PROTOCOL_VERSION"
  -e skybridgeRequireDirectRoute "$REQUIRE_DIRECT_ROUTE"
)
if [[ -n "$EXPECTED_NEGOTIATED_SUITE" ]]; then
  ANDROID_INSTRUMENT_ARGS+=(-e skybridgeExpectedNegotiatedSuite "$EXPECTED_NEGOTIATED_SUITE")
fi
ANDROID_INSTRUMENT_ARGS+=("$DEFAULT_RUNNER")
(
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell "${ANDROID_INSTRUMENT_ARGS[@]}"
) >"$ANDROID_INSTRUMENTATION_LOG" 2>&1 &
ANDROID_PID=$!

CONNECTION_CODE=""
for _ in $(seq 1 $(( ANDROID_TIMEOUT_SECONDS * 2 ))); do
  if ! kill -0 "$ANDROID_PID" >/dev/null 2>&1; then
    wait "$ANDROID_PID" || true
    ANDROID_PID=""
    fail_summary "android_offer_code" "android_instrumentation_exited_before_code"
  fi
  set +e
  CONNECTION_CODE="$(
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell run-as com.skybridge.compass.debug \
      cat "files/$CODE_FILE_NAME" 2>>"$ANDROID_CODE_POLL_LOG" | tr -d '\r\n'
  )"
  READ_CODE_EXIT=$?
  set -e
  if [[ "$READ_CODE_EXIT" -eq 0 && -n "$CONNECTION_CODE" ]]; then
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell run-as com.skybridge.compass.debug \
      rm -f "files/$CODE_FILE_NAME" >/dev/null 2>&1 || true
    break
  fi
  sleep 0.5
done
[[ -n "$CONNECTION_CODE" ]] || fail_summary "android_offer_code" "connection_code_timeout"
echo "Android connection code: <redacted>"

echo "iOS simulator: $IOS_SIM_ID" >>"$ENV_FILE"

echo "Building iOS app..."
xcrun simctl boot "$IOS_SIM_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$IOS_SIM_ID" -b
xcodebuild \
  -project "$IOS_PROJECT_FILE" \
  -scheme "$IOS_SCHEME" \
  -configuration Debug \
  -destination "id=${IOS_SIM_ID}" \
  -derivedDataPath "$RUN_DIR/DerivedData-ios" \
  CODE_SIGNING_ALLOWED=NO \
  build >"$IOS_BUILD_LOG" || fail_summary "ios_build" "xcodebuild_failed"

IOS_APP_PATH="$(find "$RUN_DIR/DerivedData-ios/Build/Products" -path '*Debug-iphonesimulator/*.app' -name 'SkyBridgeCompass-iOS.app' | head -n 1)"
[[ -d "$IOS_APP_PATH" ]] || fail_summary "ios_build" "ios_app_bundle_missing"
xcrun simctl boot "$IOS_SIM_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$IOS_SIM_ID" -b
xcrun simctl uninstall "$IOS_SIM_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$IOS_SIM_ID" "$IOS_APP_PATH" || fail_summary "ios_install" "simctl_install_failed"

IOS_SUCCESS_HOLD_SECONDS="2"
if [[ "$EXPECT_FILE_TRANSFER" == "true" ]]; then
  IOS_SUCCESS_HOLD_SECONDS=$(( FILE_TRANSFER_TIMEOUT_SECONDS + 5 ))
fi

echo "Launching iOS client responder..."
xcrun simctl boot "$IOS_SIM_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$IOS_SIM_ID" -b
xcrun simctl terminate "$IOS_SIM_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
(
  SIMCTL_CHILD_SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
  SIMCTL_CHILD_SKYBRIDGE_DEVICE_ID="ios-client-$RANDOM-$(date +%s)" \
  SIMCTL_CHILD_SKYBRIDGE_ACCESS_TOKEN="$HOST_BEARER_TOKEN" \
  SIMCTL_CHILD_SKYBRIDGE_TENANT_ID="$HOST_TENANT_ID" \
  SIMCTL_CHILD_SKYBRIDGE_USER_ID="${HOST_USER_ID:-android-ios-emulator-smoke-user}" \
  SIMCTL_CHILD_SKYBRIDGE_DISPLAY_NAME="$HOST_DISPLAY_NAME" \
  SIMCTL_CHILD_SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_ORIGIN" \
  SIMCTL_CHILD_SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$WS_URL" \
  SIMCTL_CHILD_SKYBRIDGE_STUN_URL="" \
  SIMCTL_CHILD_SKYBRIDGE_TURN_URLS="" \
  SIMCTL_CHILD_SKYBRIDGE_SMOKE_ROLE=ios-client \
  SIMCTL_CHILD_SKYBRIDGE_SMOKE_CONNECT_CODE="$CONNECTION_CODE" \
  SIMCTL_CHILD_SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_BASENAME" \
  SIMCTL_CHILD_SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$IOS_TIMEOUT_SECONDS" \
  SIMCTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_HANDSHAKE_ONLY=1 \
  SIMCTL_CHILD_SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS="$IOS_SUCCESS_HOLD_SECONDS" \
  SIMCTL_CHILD_SB_ENABLE_QPERIAPT="$(if [[ "$EXPECT_QPERIAPT" == "true" ]]; then echo 1; else echo 0; fi)" \
  SIMCTL_CHILD_SB_PQC_PREFERRED_SUITE="$(if [[ "$EXPECT_QPERIAPT" == "true" ]]; then echo q-periapt; else echo ''; fi)" \
  SIMCTL_CHILD_SKYBRIDGE_PQC_PREFERRED_SUITE="$(if [[ "$EXPECT_QPERIAPT" == "true" ]]; then echo q-periapt; else echo ''; fi)" \
  xcrun simctl launch \
    --stdout="$IOS_STDOUT" \
    --stderr="$IOS_STDERR" \
    "$IOS_SIM_ID" \
    "$IOS_BUNDLE_ID" >/dev/null
) || fail_summary "ios_launch" "simctl_launch_failed"

IOS_STATUS_PATH=""
for _ in $(seq 1 $(( IOS_TIMEOUT_SECONDS * 2 ))); do
  IOS_STATUS_PATH="$(
    find "$HOME/Library/Developer/CoreSimulator/Devices/${IOS_SIM_ID}/data/Containers/Data/Application" \
      -name "$IOS_STATUS_BASENAME" -print 2>/dev/null | tail -n 1
  )"
  if [[ -n "$IOS_STATUS_PATH" && -f "$IOS_STATUS_PATH" ]]; then
    copy_ios_smoke_artifacts || fail_summary "ios_artifact_redaction" "ios_artifact_redaction_failed"
    if grep -q 'failed stage=' "$IOS_STATUS_PATH"; then
      fail_summary "ios_client_join" "ios_status_failed"
    fi
    if grep -Eq 'success (session|session_ref)=' "$IOS_STATUS_PATH"; then
      break
    fi
  fi
  sleep 0.5
done
copy_ios_smoke_artifacts || fail_summary "ios_artifact_redaction" "ios_artifact_redaction_failed"
[[ -s "$IOS_STATUS_LOCAL" ]] || fail_summary "ios_client_join" "ios_status_missing"
grep -Eq 'success (session|session_ref)=' "$IOS_STATUS_LOCAL" || fail_summary "ios_client_join" "ios_success_timeout"

set +e
wait "$ANDROID_PID"
ANDROID_EXIT=$?
set -e
ANDROID_PID=""

if ! android_capture_redacted_logcat "$ADB_BIN" "$DEVICE_SERIAL" "$ANDROID_LOGCAT_LOG" "$ANDROID_HANDSHAKE_LOG"; then
  fail_summary "android_logcat" "logcat_capture_or_redaction_failed"
fi

if [[ "$ANDROID_EXIT" -ne 0 ]]; then
  fail_summary "android_offer_success" "android_instrumentation_failed"
fi
grep -q 'OK (1 test)' "$ANDROID_INSTRUMENTATION_LOG" ||
  fail_summary "android_offer_success" "instrumentation_missing_ok"
ANDROID_SUCCESS_LINE="$(
  grep -h 'SB-ANDROID-APP-OFFER success' "$ANDROID_INSTRUMENTATION_LOG" "$ANDROID_HANDSHAKE_LOG" 2>/dev/null |
    head -n 1 || true
)"
[[ -n "$ANDROID_SUCCESS_LINE" ]] || fail_summary "android_offer_success" "android_success_line_missing"

ANDROID_NEGOTIATED_SUITE="$(
  printf '%s\n' "$ANDROID_SUCCESS_LINE" |
    sed -n 's/.* suite=\([^ ]*\).*/\1/p'
)"
ANDROID_SELECTED_ROUTE="$(
  printf '%s\n' "$ANDROID_SUCCESS_LINE" |
    sed -n 's/.* route=\([^ ]*\).*/\1/p'
)"
if [[ "$REQUIRE_DIRECT_ROUTE" == "true" && "$ANDROID_SELECTED_ROUTE" != "direct" ]]; then
  fail_summary "android_offer_route" "direct_route_required_actual_${ANDROID_SELECTED_ROUTE:-missing}"
fi
ANDROID_QPERIAPT_ASSERTED="$(
  printf '%s\n' "$ANDROID_SUCCESS_LINE" |
    sed -n 's/.* qperiapt=\([^ ]*\).*/\1/p'
)"
ANDROID_BOOTSTRAP_QPERIAPT="$(
  printf '%s\n' "$ANDROID_SUCCESS_LINE" |
    sed -n 's/.* bootstrapQPeriapt=\([^ ]*\).*/\1/p'
)"
ANDROID_FILE_TRANSFER_ASSERTED="$(
  printf '%s\n' "$ANDROID_SUCCESS_LINE" |
    sed -n 's/.* fileTransfer=\([^ ]*\).*/\1/p'
)"
ANDROID_FILE_TRANSFER_BYTES="$(
  printf '%s\n' "$ANDROID_SUCCESS_LINE" |
    sed -n 's/.* transferBytes=\([^ ]*\).*/\1/p'
)"
ANDROID_FILE_TRANSFER_SHA256="$(
  printf '%s\n' "$ANDROID_SUCCESS_LINE" |
    sed -n 's/.* payloadSha256=\([^ ]*\).*/\1/p'
)"
ANDROID_FILE_TRANSFER_OUTBOUND_OPS="$(
  printf '%s\n' "$ANDROID_SUCCESS_LINE" |
    sed -n 's/.* outboundOps=\([^ ]*\).*/\1/p'
)"
ANDROID_FILE_TRANSFER_INBOUND_ACKS="$(
  printf '%s\n' "$ANDROID_SUCCESS_LINE" |
    sed -n 's/.* inboundAcks=\([^ ]*\).*/\1/p'
)"
IOS_SUCCESS_LINE="$(grep -Em 1 'success (session|session_ref)=' "$IOS_STATUS_LOCAL" || true)"
IOS_NEGOTIATED_SUITE="$(
  printf '%s\n' "$IOS_SUCCESS_LINE" |
    sed -n 's/.* suite=\([^ ]*\).*/\1/p'
)"

FILE_TRANSFER_ASSERTION_OK="true"
FILE_TRANSFER_ASSERTION_FAILURE=""
if [[ "$EXPECT_FILE_TRANSFER" == "true" ]]; then
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
  if [[ "$ANDROID_QPERIAPT_ASSERTED" != "true" ]]; then
    QPERIAPT_ASSERTION_OK="false"
    QPERIAPT_ASSERTION_FAILURE="android_qperiapt_asserted=$ANDROID_QPERIAPT_ASSERTED"
  elif [[ "$ANDROID_BOOTSTRAP_QPERIAPT" != "true" ]]; then
    QPERIAPT_ASSERTION_OK="false"
    QPERIAPT_ASSERTION_FAILURE="android_bootstrap_qperiapt=$ANDROID_BOOTSTRAP_QPERIAPT"
  elif [[ "$ANDROID_NEGOTIATED_SUITE" != "Q_PERIAPT_CONTEXT_BOUND/0x0011" ]]; then
    QPERIAPT_ASSERTION_OK="false"
    QPERIAPT_ASSERTION_FAILURE="android_negotiated_suite=$ANDROID_NEGOTIATED_SUITE"
  elif [[ "$IOS_NEGOTIATED_SUITE" != "Q-Periapt-ContextBound" ]]; then
    QPERIAPT_ASSERTION_OK="false"
    QPERIAPT_ASSERTION_FAILURE="ios_negotiated_suite=$IOS_NEGOTIATED_SUITE"
  fi
fi

{
  echo "instrumentation_ok=true"
  echo "ios_client_ok=true"
  echo "android_offer_success_seen=true"
  echo "ios_success_seen=true"
  echo "handshake_log_present=$(if [[ -s "$ANDROID_HANDSHAKE_LOG" ]]; then echo true; else echo false; fi)"
  echo "pqc_enabled=$PQC_ENABLED"
  echo "pqc_minimum_tier=$PQC_MINIMUM_TIER"
  echo "expected_qperiapt=$EXPECT_QPERIAPT"
  echo "expected_negotiated_suite=$EXPECTED_NEGOTIATED_SUITE"
  echo "require_direct_route=$REQUIRE_DIRECT_ROUTE"
  echo "android_selected_route=$ANDROID_SELECTED_ROUTE"
  echo "expect_file_transfer=$EXPECT_FILE_TRANSFER"
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
  echo "ios_negotiated_suite=$IOS_NEGOTIATED_SUITE"
  echo "qperiapt_assertion_ok=$QPERIAPT_ASSERTION_OK"
  echo "qperiapt_assertion_failure=$QPERIAPT_ASSERTION_FAILURE"
  echo "android_instrumentation=$ANDROID_INSTRUMENTATION_LOG"
  echo "ios_status=$IOS_STATUS_LOCAL"
  echo "ios_trace=$IOS_TRACE_LOCAL"
  echo "ios_artifact_redaction_failed=$IOS_ARTIFACT_REDACTION_FAILED"
  echo "android_logcat=$ANDROID_LOGCAT_LOG"
  cat "$PROVENANCE_FILE"
} >"$SUMMARY_FILE"

if [[ "$IOS_ARTIFACT_REDACTION_FAILED" == "true" ]]; then
  echo "Android -> iOS iOS artifact redaction failed; evidence bundle rejected." >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi

if [[ "$FILE_TRANSFER_ASSERTION_OK" != "true" ]]; then
  echo "Android -> iOS file-transfer assertion failed: $FILE_TRANSFER_ASSERTION_FAILURE" >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi

if [[ "$QPERIAPT_ASSERTION_OK" != "true" ]]; then
  echo "Android -> iOS Q-Periapt assertion failed: $QPERIAPT_ASSERTION_FAILURE" >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi

echo "public_artifacts=$PUBLIC_ARTIFACT_DIR" >>"$SUMMARY_FILE"
if ! android_smoke_materialize_public_artifacts "$RUN_DIR" "$PUBLIC_ARTIFACT_DIR"; then
  echo "Android -> iOS public artifact materialization failed; evidence bundle rejected." >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi
if ! android_smoke_check_public_artifacts \
  "$PUBLIC_ARTIFACT_DIR" \
  "$DEVICE_SERIAL" \
  "$CONNECTION_CODE" \
  "$HOST_TENANT_ID" \
  "${HOST_USER_ID:-}"; then
  echo "Android -> iOS public artifact scan failed; evidence bundle rejected." >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi

echo "Android -> iOS WebRTC offer smoke passed."
echo "Artifacts:"
echo "  environment: $ENV_FILE"
echo "  provenance: $PROVENANCE_FILE"
echo "  command: $COMMAND_FILE"
echo "  android instrumentation: $ANDROID_INSTRUMENTATION_LOG"
echo "  android logcat: $ANDROID_LOGCAT_LOG"
echo "  android handshake log: $ANDROID_HANDSHAKE_LOG"
echo "  iOS build log: $IOS_BUILD_LOG"
echo "  iOS status: $IOS_STATUS_LOCAL"
echo "  iOS trace: $IOS_TRACE_LOCAL"
echo "  public artifacts: $PUBLIC_ARTIFACT_DIR"
echo "  summary: $SUMMARY_FILE"
