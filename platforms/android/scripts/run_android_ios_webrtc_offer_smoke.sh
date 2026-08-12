#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/repository_layout.sh"
RELEASE_REPO_ROOT="$(skybridge_canonical_release_root "$ROOT_DIR")"
source "$ROOT_DIR/scripts/lib/android_env.sh"
source "$ROOT_DIR/scripts/lib/source_provenance.sh"
source "$ROOT_DIR/scripts/lib/strict_gradle_output.sh"

DEFAULT_IOS_PROJECT_DIR="$RELEASE_REPO_ROOT/SkyBridge Compass iOS"
DEFAULT_SIGNALING_DIR="$RELEASE_REPO_ROOT/Server/skybridge-signaling"
DEFAULT_APP_CLASS="com.skybridge.compass.android.webrtc.AppleReleaseInteropOffererAppInstrumentationTest"
SIMULATOR_RUNNER="com.skybridge.compass.debug.test/com.skybridge.compass.android.HiltTestRunner"
PHYSICAL_TEST_PACKAGE="com.skybridge.compass.debug.ioswebrtc.test"
PHYSICAL_RUNNER="$PHYSICAL_TEST_PACKAGE/com.skybridge.compass.android.HiltTestRunner"
IOS_BUNDLE_ID="com.skybridge.compass.ios"
IOS_COPY_ABSENCE_VALIDATOR="$ROOT_DIR/scripts/validate_ios_copy_absence.py"

DEVICE_SERIAL=""
WS_URL=""
IOS_PROJECT_DIR="$DEFAULT_IOS_PROJECT_DIR"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_TARGET="simulator"
IOS_DESTINATION="${SKYBRIDGE_IOS_DESTINATION:-}"
IOS_DESTINATION_SOURCE="$(if [[ -n "$IOS_DESTINATION" ]]; then echo environment; else echo auto_simulator; fi)"
IOS_SIM_ID=""
IOS_DEVICE_ID=""
IOS_DEVICE_UDID=""
EXPECTED_SOURCE_COMMIT=""
DEVICECTL_TIMEOUT_SECONDS="${SKYBRIDGE_DEVICECTL_TIMEOUT_SECONDS:-120}"
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
    [--ios-target simulator|physical] \
    [--ios-destination <xcodebuild-destination>] \
    [--ios-sim-id <udid>] \
    [--ios-device-id <exact-devicectl-identifier>] \
    [--ios-device-udid <exact-xcdevice-udid>] \
    [--expected-source-commit <40-lowercase-hex>] \
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

Physical mode is diagnostic-only. It requires explicit CoreDevice and xcdevice
identities, performs an overlay install without uninstalling or clearing app
data, and requires the installed Apple identity and peer trust without allowing
persistent identity/trust mutation. It never falls back to a simulator or
another physical device.
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

require_short_lived_bearer_token() {
  python3 -c '
import base64
import json
import math
import sys
import time

token = sys.stdin.read().strip()
parts = token.split(".")
if len(parts) != 3:
    raise SystemExit("physical smoke bearer token must be a JWT")
payload = parts[1] + "=" * (-len(parts[1]) % 4)
try:
    claims = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))
except Exception as exc:
    raise SystemExit(f"physical smoke bearer token has invalid claims: {type(exc).__name__}")
issued_at = claims.get("iat")
expires_at = claims.get("exp")
if (
    isinstance(issued_at, bool)
    or isinstance(expires_at, bool)
    or not isinstance(issued_at, (int, float))
    or not isinstance(expires_at, (int, float))
    or not math.isfinite(float(issued_at))
    or not math.isfinite(float(expires_at))
):
    raise SystemExit("physical smoke bearer token requires numeric iat and exp claims")
now = time.time()
if issued_at > now + 30 or expires_at <= now + 30:
    raise SystemExit("physical smoke bearer token is not currently usable with a 30-second margin")
if expires_at - issued_at > 900 or expires_at - issued_at <= 0:
    raise SystemExit("physical smoke bearer token lifetime must be at most 15 minutes")
' || return 1
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
    --ios-target) IOS_TARGET="${2:-}"; shift 2 ;;
    --ios-destination)
      IOS_DESTINATION="${2:-}"
      IOS_DESTINATION_SOURCE="argument"
      shift 2
      ;;
    --ios-sim-id) IOS_SIM_ID="${2:-}"; shift 2 ;;
    --ios-device-id) IOS_DEVICE_ID="${2:-}"; shift 2 ;;
    --ios-device-udid) IOS_DEVICE_UDID="${2:-}"; shift 2 ;;
    --expected-source-commit) EXPECTED_SOURCE_COMMIT="${2:-}"; shift 2 ;;
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
case "$IOS_TARGET" in
  simulator|physical) ;;
  *) echo "Unsupported --ios-target value: $IOS_TARGET (expected simulator|physical)" >&2; exit 1 ;;
esac
if ! [[ "$FILE_TRANSFER_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$FILE_TRANSFER_TIMEOUT_SECONDS" -le 0 ]]; then
  echo "Unsupported --file-transfer-timeout-seconds value: $FILE_TRANSFER_TIMEOUT_SECONDS" >&2
  exit 1
fi
if [[ "$START_LOCAL_COMPAT_SIGNALING" == "true" && "$START_LOCAL_TURN" != "true" ]]; then
  echo "Local compat Android -> iOS smoke requires --start-local-turn true because TURN admission is fail-closed." >&2
  exit 1
fi
if [[ "$IOS_TARGET" == "physical" ]]; then
  if [[ "$CLASS_NAME" != "$DEFAULT_APP_CLASS" ]]; then
    echo "Physical iOS smoke requires the fixed formal instrumentation class: $DEFAULT_APP_CLASS" >&2
    exit 1
  fi
  if [[ "$EXPECT_FILE_TRANSFER" != "true" ]]; then
    echo "Physical iOS formal smoke requires --expect-file-transfer true" >&2
    exit 1
  fi
  if [[ -z "$IOS_DEVICE_ID" || -z "$IOS_DEVICE_UDID" ]]; then
    echo "Physical iOS smoke requires both --ios-device-id and --ios-device-udid" >&2
    exit 1
  fi
  if [[ ! "$IOS_DEVICE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$ ]] \
    || [[ ! "$IOS_DEVICE_UDID" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,127}$ ]]; then
    echo "Physical iOS smoke device identifiers are not canonical" >&2
    exit 1
  fi
  if [[ -n "$IOS_DESTINATION" || -n "$IOS_SIM_ID" ]]; then
    echo "Physical iOS smoke forbids simulator destination options" >&2
    exit 1
  fi
  if [[ "$START_LOCAL_COMPAT_SIGNALING" == "true" || "$START_LOCAL_TURN" == "true" ]]; then
    echo "Physical iOS smoke requires an explicitly reachable signaling/TURN deployment; local simulator services are unsupported" >&2
    exit 1
  fi
  if [[ "$(is_loopback_ws_url "$WS_URL")" == "true" ]]; then
    echo "Physical iOS smoke rejects loopback signaling; configure one endpoint reachable by both devices" >&2
    exit 1
  fi
  if [[ "$WS_URL" != wss://* ]]; then
    echo "Physical iOS smoke requires wss signaling so the bearer token is not sent in plaintext" >&2
    exit 1
  fi
  if [[ ! "$EXPECTED_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Physical iOS smoke requires --expected-source-commit as a full lowercase Git revision" >&2
    exit 1
  fi
fi
for numeric_option in \
  "$ANDROID_TIMEOUT_SECONDS" \
  "$IOS_TIMEOUT_SECONDS" \
  "$POST_SUCCESS_HOLD_MILLIS"; do
  if [[ ! "$numeric_option" =~ ^[1-9][0-9]*$ ]]; then
    echo "Android/iOS smoke timeouts and hold durations must be positive integers" >&2
    exit 1
  fi
done
if (( ANDROID_TIMEOUT_SECONDS > 1800 || IOS_TIMEOUT_SECONDS > 1800 || POST_SUCCESS_HOLD_MILLIS > 600000 )); then
  echo "Android/iOS smoke timeout or hold duration exceeds its safety bound" >&2
  exit 1
fi
if [[ ! "$DEVICECTL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || (( DEVICECTL_TIMEOUT_SECONDS > 1800 )); then
  echo "SKYBRIDGE_DEVICECTL_TIMEOUT_SECONDS must be an integer from 1 through 1800" >&2
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
if [[ "$IOS_TARGET" == "physical" ]]; then
  EXPECTED_NEGOTIATED_SUITE="${EXPECTED_NEGOTIATED_SUITE:-MLKEM_768}"
  if [[ "$PQC_ENABLED" != "true" ]] \
      || [[ "$PQC_MINIMUM_TIER" != "nativePQC" ]] \
      || [[ "$EXPECT_QPERIAPT" != "false" ]] \
      || [[ "$EXPECTED_NEGOTIATED_SUITE" != "MLKEM_768" ]]; then
    echo "Physical iOS formal smoke requires exact ML-KEM-768 PQC policy" >&2
    exit 1
  fi
fi

ADB_BIN="$(resolve_adb_bin "$ROOT_DIR" || true)"
if [[ -z "$ADB_BIN" ]]; then
  echo "adb not found; checked PATH, local.properties, and common Android SDK locations" >&2
  exit 1
fi
android_require_exact_device "$ADB_BIN" "$DEVICE_SERIAL"

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

PHYSICAL_EVIDENCE_VALIDATOR="$ROOT_DIR/scripts/validate_android_ios_physical_evidence.py"
PROCESS_OWNERSHIP_HELPER=""
PROCESS_OWNERSHIP_SHELL=""
if [[ "$IOS_TARGET" == "simulator" ]]; then
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
else
  IOS_DESTINATION="platform=iOS,id=$IOS_DEVICE_UDID"
  IOS_DESTINATION_SOURCE="physical_device_arguments"
  PROCESS_OWNERSHIP_HELPER="$ROOT_DIR/scripts/lib/webrtc_smoke_process_ownership.py"
  PROCESS_OWNERSHIP_SHELL="$ROOT_DIR/scripts/lib/real_device_ios_process_ownership.sh"
  for helper in \
    "$PHYSICAL_EVIDENCE_VALIDATOR" \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$PROCESS_OWNERSHIP_SHELL"; do
    if [[ ! -f "$helper" || -L "$helper" ]]; then
      echo "Physical iOS smoke helper is missing or unsafe: $helper" >&2
      exit 1
    fi
  done
  # shellcheck source=/dev/null
  source "$PROCESS_OWNERSHIP_SHELL"
fi

if [[ "$START_LOCAL_COMPAT_SIGNALING" == "true" && ! -f "$SIGNALING_DIR/local_compat_server.js" ]]; then
  echo "local compat signaling server not found: $SIGNALING_DIR/local_compat_server.js" >&2
  exit 1
fi

if [[ -z "$RUN_DIR" ]]; then
  RUN_PARENT="$ROOT_DIR/build/interop/android-ios-webrtc-offer-smoke"
  mkdir -p "$RUN_PARENT"
  RUN_DIR="$(mktemp -d "$RUN_PARENT/run.XXXXXX")"
elif [[ -e "$RUN_DIR" || -L "$RUN_DIR" ]]; then
  echo "Run directory must be a new, non-symbolic path: $RUN_DIR" >&2
  exit 1
else
  RUN_PARENT="$(dirname "$RUN_DIR")"
  [[ -d "$RUN_PARENT" && ! -L "$RUN_PARENT" ]] || {
    echo "Run directory parent must be an existing non-symbolic directory: $RUN_PARENT" >&2
    exit 1
  }
  mkdir "$RUN_DIR"
fi
chmod 700 "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"

ENV_FILE="$RUN_DIR/environment.txt"
COMMAND_FILE="$RUN_DIR/command.txt"
SUMMARY_FILE="$RUN_DIR/summary.txt"
PUBLIC_ARTIFACT_DIR="$RUN_DIR/public-redacted"
PROVENANCE_DIR="$RUN_DIR/source-provenance"
PROVENANCE_FILE="$RUN_DIR/source-provenance.txt"
ANDROID_INSTALL_LOG="$RUN_DIR/android-install.log"
ANDROID_BUILD_LOG="$RUN_DIR/android-build.log"
ANDROID_INSTRUMENTATION_LOG="$RUN_DIR/android-instrumentation.log"
ANDROID_LOGCAT_LOG="$RUN_DIR/android-logcat.txt"
ANDROID_HANDSHAKE_LOG="$RUN_DIR/android-handshake.log"
ANDROID_CODE_POLL_LOG="$RUN_DIR/android-code-poll.log"
IOS_BUILD_LOG="$RUN_DIR/ios-build.log"
IOS_STDOUT="$RUN_DIR/ios-stdout.log"
IOS_STDERR="$RUN_DIR/ios-stderr.log"
SMOKE_RUN_NONCE="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
SMOKE_RUN_REF="$(python3 - "$SMOKE_RUN_NONCE" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PY
)"
ANDROID_TO_PEER_TRANSFER_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
PEER_TO_ANDROID_TRANSFER_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
IOS_STATUS_BASENAME="android-ios-offer-${IOS_TARGET}-${SMOKE_RUN_REF}.status.log"
IOS_STATUS_LOCAL="$RUN_DIR/$IOS_STATUS_BASENAME"
IOS_TRACE_BASENAME="${IOS_STATUS_BASENAME}.trace.log"
IOS_TRACE_LOCAL="$RUN_DIR/$IOS_TRACE_BASENAME"
IOS_DEVICE_LIST_RAW=""
IOS_XCDEVICE_LIST_RAW=""
IOS_INSTALL_RESULT_RAW=""
IOS_APPS_RESULT_RAW=""
IOS_LAUNCH_RESULT_RAW=""
IOS_APP_PROVENANCE="$RUN_DIR/ios-app-provenance.txt"
APP_APK_PROVENANCE="$RUN_DIR/app-apk-provenance.txt"
TEST_APK_PROVENANCE="$RUN_DIR/test-apk-provenance.txt"
SOURCE_BINDING_BEFORE="$RUN_DIR/source-binding-before.properties"
SOURCE_BINDING_AFTER="$RUN_DIR/source-binding-after.properties"
PHYSICAL_RECEIPT="$RUN_DIR/physical-evidence-receipt.json"
SIGNALING_LOG="$RUN_DIR/signaling.log"
TURN_LOG="$RUN_DIR/turnserver.log"
ADB_REVERSE_LOG="$RUN_DIR/adb-reverse.log"
AUTH_CONTEXT_FILE_NAME="android-ios-offer-auth-${SMOKE_RUN_REF}.json"
CODE_FILE_NAME="android-ios-offer-code-${SMOKE_RUN_REF}.txt"
ANDROID_CONTEXT_PACKAGE="com.skybridge.compass.debug"
if [[ "$IOS_TARGET" == "physical" ]]; then
  ANDROID_CONTEXT_PACKAGE="$PHYSICAL_TEST_PACKAGE"
fi

ANDROID_PID=""
ANDROID_INSTRUMENTATION_STARTED="false"
ANDROID_APP_EXIT_VERIFIED="false"
SIGNALING_PID=""
TURN_PID=""
ADB_REVERSE_PORT=""
DEVICE_PROXY_RESTORE_NEEDED="0"
ORIGINAL_HTTP_PROXY=""
ORIGINAL_GLOBAL_HTTP_PROXY_HOST=""
ORIGINAL_GLOBAL_HTTP_PROXY_PORT=""
ORIGINAL_GLOBAL_HTTP_PROXY_EXCLUSION_LIST=""
IOS_ARTIFACT_REDACTION_FAILED="false"
ANDROID_DEVICE_LOCK=""
IOS_DEVICE_LOCK=""
ANDROID_CONTEXT_PREPARED="false"
ANDROID_CONTEXT_CLEANUP_VERIFIED="false"
ANDROID_AUTH_CONTEXT_STAGED="false"
ANDROID_CODE_CONTEXT_STAGED="false"
ANDROID_TEST_PACKAGE_STATE="untouched"
ANDROID_TEST_PACKAGE_CLEANUP_VERIFIED="false"
APP_APK_SHA256=""
TEST_APK_SHA256=""
IOS_APP_PATH=""
PHYSICAL_PRIVATE_DIR=""
IOS_DEVICE_BINDING=""
IOS_INSTALLATION_BINDING=""
IOS_LAUNCH_PERSISTENT_IDENTIFIER=""
IOS_CONSOLE_PID=""
IOS_CONSOLE_HANDLE_IDENTITY=""
IOS_PROCESS_IDENTITY=""
IOS_CONSOLE_CAPTURE_DIAGNOSTIC=""
IOS_STATUS_PRIVATE=""
IOS_TRACE_PRIVATE=""
IOS_SENSITIVE_STATE_BEFORE=""
IOS_SENSITIVE_STATE_AFTER=""
ANDROID_DEVICE_BINDING_BEFORE=""
ANDROID_DEVICE_BINDING_AFTER=""
ANDROID_INSTALLED_APPS_BEFORE=""
ANDROID_INSTALLED_APPS_AFTER=""
ANDROID_LOGCAT_START=""
IOS_CONSOLE_HANDLE_STARTED="false"
IOS_CONSOLE_HANDLE_CAPTURED="false"
IOS_CONSOLE_CLEANUP_VERIFIED="false"
IOS_APP_EXIT_VERIFIED="false"
ANDROID_SENSITIVE_STATE_UNCHANGED="false"
IOS_REQUIRED_IDENTITY_AND_CONTAINER_STATE_UNCHANGED="false"

remove_android_context_files() {
  [[ "$ANDROID_CONTEXT_PREPARED" == "true" ]] || return 0
  local remote_command=""
  case "$ANDROID_AUTH_CONTEXT_STAGED:$ANDROID_CODE_CONTEXT_STAGED" in
    true:true)
      remote_command="rm -f files/$AUTH_CONTEXT_FILE_NAME files/$CODE_FILE_NAME && test ! -e files/$AUTH_CONTEXT_FILE_NAME && test ! -e files/$CODE_FILE_NAME"
      ;;
    true:false)
      remote_command="rm -f files/$AUTH_CONTEXT_FILE_NAME && test ! -e files/$AUTH_CONTEXT_FILE_NAME"
      ;;
    false:true)
      remote_command="rm -f files/$CODE_FILE_NAME && test ! -e files/$CODE_FILE_NAME"
      ;;
    false:false)
      ANDROID_CONTEXT_PREPARED="false"
      ANDROID_CONTEXT_CLEANUP_VERIFIED="true"
      return 0
      ;;
    *)
      echo "Android context ownership state is invalid" >&2
      return 1
      ;;
  esac
  if ! "$ADB_BIN" -s "$DEVICE_SERIAL" shell run-as "$ANDROID_CONTEXT_PACKAGE" sh -c \
    "$remote_command" \
    >/dev/null 2>&1; then
    echo "Unable to prove Android auth/code context cleanup" >&2
    return 1
  fi
  ANDROID_CONTEXT_PREPARED="false"
  ANDROID_AUTH_CONTEXT_STAGED="false"
  ANDROID_CODE_CONTEXT_STAGED="false"
  ANDROID_CONTEXT_CLEANUP_VERIFIED="true"
}

remove_owned_android_test_package() {
  local query_status=0
  [[ "$IOS_TARGET" == "physical" ]] || return 0
  case "$ANDROID_TEST_PACKAGE_STATE" in
    untouched|cleaned) return 0 ;;
    install_attempted)
      if android_installed_package_path \
        "$ADB_BIN" "$DEVICE_SERIAL" "$PHYSICAL_TEST_PACKAGE" >/dev/null; then
        echo "Test package appeared after an ambiguous install attempt; refusing uninstall" >&2
        return 1
      else
        query_status=$?
        if (( query_status == 2 )); then
          ANDROID_TEST_PACKAGE_STATE="cleaned"
          ANDROID_TEST_PACKAGE_CLEANUP_VERIFIED="true"
          return 0
        fi
      fi
      echo "Unable to prove test-package absence after an ambiguous install attempt" >&2
      return 1
      ;;
    owned_installed) ;;
    *)
      echo "Android test package ownership state is invalid" >&2
      return 1
      ;;
  esac
  if android_installed_package_path "$ADB_BIN" "$DEVICE_SERIAL" "$PHYSICAL_TEST_PACKAGE" >/dev/null; then
    android_remove_owned_package \
      "$ADB_BIN" "$DEVICE_SERIAL" "$PHYSICAL_TEST_PACKAGE" "$TEST_APK_SHA256" || return 1
  else
    query_status=$?
    if (( query_status != 2 )) || [[ "$ANDROID_TEST_PACKAGE_STATE" == "owned_installed" ]]; then
      echo "Android test package ownership became ambiguous during cleanup" >&2
      return 1
    fi
  fi
  ANDROID_TEST_PACKAGE_STATE="cleaned"
  ANDROID_TEST_PACKAGE_CLEANUP_VERIFIED="true"
}

finish_physical_ios_process() {
  local handle_status=0
  [[ "$IOS_CONSOLE_HANDLE_STARTED" == "true" ]] || return 0
  if [[ "$IOS_CONSOLE_HANDLE_CAPTURED" != "true" ]]; then
    echo "Refusing physical iOS process cleanup because exact console ownership was not captured" >&2
    return 1
  fi
  if skybridge_ios_console_handle_status \
    "$PROCESS_OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$IOS_CONSOLE_HANDLE_IDENTITY"; then
    skybridge_ios_signal_console_handle \
      "$PROCESS_OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$IOS_CONSOLE_HANDLE_IDENTITY" || return 1
    skybridge_ios_wait_console_handle_exit \
      "$PROCESS_OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$IOS_CONSOLE_HANDLE_IDENTITY" 30 || return 1
  else
    handle_status=$?
    if (( handle_status != 1 )); then
      echo "Physical iOS console ownership became unverifiable" >&2
      return 1
    fi
    wait "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
  fi
  skybridge_ios_capture_exited_console_identity \
    "$PROCESS_OWNERSHIP_HELPER" "$IOS_LAUNCH_RESULT_RAW" "$IOS_APP_PATH" "$IOS_PROCESS_IDENTITY" || return 1
  skybridge_ios_require_app_absent_after_handle_exit \
    "$PROCESS_OWNERSHIP_HELPER" "$IOS_DEVICE_ID" "$IOS_APP_PATH" "$PHYSICAL_PRIVATE_DIR" \
    "$DEVICECTL_TIMEOUT_SECONDS" || return 1
  IOS_CONSOLE_HANDLE_STARTED="false"
  IOS_CONSOLE_HANDLE_CAPTURED="false"
  IOS_CONSOLE_PID=""
  IOS_CONSOLE_CLEANUP_VERIFIED="true"
  IOS_APP_EXIT_VERIFIED="true"
}

finish_physical_android_instrumentation() {
  [[ "$IOS_TARGET" == "physical" ]] || return 0
  if [[ "$ANDROID_INSTRUMENTATION_STARTED" != "true" ]]; then
    android_require_package_process_absent \
      "$ADB_BIN" "$DEVICE_SERIAL" "com.skybridge.compass.debug" || return 1
    ANDROID_APP_EXIT_VERIFIED="true"
    return 0
  fi
  if [[ -n "$ANDROID_PID" ]]; then
    for _ in $(seq 1 60); do
      if ! kill -0 "$ANDROID_PID" >/dev/null 2>&1; then
        break
      fi
      sleep 0.5
    done
    if kill -0 "$ANDROID_PID" >/dev/null 2>&1; then
      echo "Android instrumentation is still active; refusing force-stop and concurrent cleanup" >&2
      return 1
    fi
    wait "$ANDROID_PID" >/dev/null 2>&1 || true
    ANDROID_PID=""
  fi
  if ! android_require_package_process_absent \
      "$ADB_BIN" "$DEVICE_SERIAL" "com.skybridge.compass.debug"; then
    echo "Android main app process is active or unverifiable after instrumentation" >&2
    return 1
  fi
  ANDROID_APP_EXIT_VERIFIED="true"
}

cleanup() {
  local original_status=$?
  local cleanup_status=0
  local android_quiescent="true"
  trap - EXIT INT TERM
  if [[ "$IOS_TARGET" == "physical" ]] && ! finish_physical_ios_process; then
    cleanup_status=1
  fi
  if [[ "$IOS_TARGET" == "physical" ]] && ! finish_physical_android_instrumentation; then
    android_quiescent="false"
    cleanup_status=1
  fi
  if [[ "$android_quiescent" == "true" ]]; then
    if ! remove_android_context_files; then
      cleanup_status=1
    fi
    if ! remove_owned_android_test_package; then
      cleanup_status=1
    fi
  else
    echo "Android context and test package were preserved because target-process quiescence is unproven" >&2
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
  if [[ "$IOS_TARGET" != "physical" && -n "$ANDROID_PID" ]] \
      && kill -0 "$ANDROID_PID" >/dev/null 2>&1; then
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
  if [[ -n "$IOS_DEVICE_LOCK" ]] && ! skybridge_release_device_lock "$IOS_DEVICE_LOCK"; then
    echo "Unable to release the iOS device lock" >&2
    cleanup_status=1
  fi
  IOS_DEVICE_LOCK=""
  if [[ -n "$ANDROID_DEVICE_LOCK" ]] && ! skybridge_release_device_lock "$ANDROID_DEVICE_LOCK"; then
    echo "Unable to release the Android device lock" >&2
    cleanup_status=1
  fi
  ANDROID_DEVICE_LOCK=""
  if [[ -n "$PHYSICAL_PRIVATE_DIR" && -d "$PHYSICAL_PRIVATE_DIR" ]]; then
    if (( cleanup_status == 0 )); then
      rm -rf -- "$PHYSICAL_PRIVATE_DIR"
      PHYSICAL_PRIVATE_DIR=""
    else
      echo "Private physical-iOS ownership evidence preserved: $PHYSICAL_PRIVATE_DIR" >&2
    fi
  fi
  if (( original_status == 0 && cleanup_status != 0 )); then
    original_status=$cleanup_status
  fi
  exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ANDROID_DEVICE_LOCK="$(skybridge_acquire_device_lock "$RELEASE_REPO_ROOT" android "$DEVICE_SERIAL")"
if [[ "$IOS_TARGET" == "physical" ]]; then
  IOS_DEVICE_LOCK="$(skybridge_acquire_device_lock "$RELEASE_REPO_ROOT" ios-physical "$IOS_DEVICE_ID")"
  PHYSICAL_PRIVATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-android-ios-physical.XXXXXX")"
  chmod 0700 "$PHYSICAL_PRIVATE_DIR"
  IOS_DEVICE_BINDING="$PHYSICAL_PRIVATE_DIR/device-binding.json"
  IOS_INSTALLATION_BINDING="$PHYSICAL_PRIVATE_DIR/installation-binding.json"
  IOS_CONSOLE_HANDLE_IDENTITY="$PHYSICAL_PRIVATE_DIR/ios-console-handle.json"
  IOS_PROCESS_IDENTITY="$PHYSICAL_PRIVATE_DIR/ios-process.json"
  IOS_CONSOLE_CAPTURE_DIAGNOSTIC="$PHYSICAL_PRIVATE_DIR/ios-console-capture.log"
  IOS_STATUS_PRIVATE="$PHYSICAL_PRIVATE_DIR/$IOS_STATUS_BASENAME"
  IOS_TRACE_PRIVATE="$PHYSICAL_PRIVATE_DIR/$IOS_TRACE_BASENAME"
  IOS_SENSITIVE_STATE_BEFORE="$PHYSICAL_PRIVATE_DIR/ios-sensitive-state-before.properties"
  IOS_SENSITIVE_STATE_AFTER="$PHYSICAL_PRIVATE_DIR/ios-sensitive-state-after.properties"
  ANDROID_DEVICE_BINDING_BEFORE="$PHYSICAL_PRIVATE_DIR/android-device-before.properties"
  ANDROID_DEVICE_BINDING_AFTER="$PHYSICAL_PRIVATE_DIR/android-device-after.properties"
  ANDROID_INSTALLED_APPS_BEFORE="$PHYSICAL_PRIVATE_DIR/android-installed-apks-before.properties"
  ANDROID_INSTALLED_APPS_AFTER="$PHYSICAL_PRIVATE_DIR/android-installed-apks-after.properties"
  IOS_DEVICE_LIST_RAW="$PHYSICAL_PRIVATE_DIR/ios-device-list.json"
  IOS_XCDEVICE_LIST_RAW="$PHYSICAL_PRIVATE_DIR/ios-xcdevice-list.json"
  IOS_INSTALL_RESULT_RAW="$PHYSICAL_PRIVATE_DIR/ios-install-result.json"
  IOS_APPS_RESULT_RAW="$PHYSICAL_PRIVATE_DIR/ios-installed-apps.json"
  IOS_LAUNCH_RESULT_RAW="$PHYSICAL_PRIVATE_DIR/ios-launch-result.json"
  skybridge_require_frozen_git_source \
    "$RELEASE_REPO_ROOT" "$EXPECTED_SOURCE_COMMIT" "physical smoke pre-build verification"
  skybridge_collect_frozen_git_binding \
    "$RELEASE_REPO_ROOT" "$EXPECTED_SOURCE_COMMIT" before >"$SOURCE_BINDING_BEFORE"
else
  IOS_DEVICE_LOCK="$(skybridge_acquire_device_lock "$RELEASE_REPO_ROOT" ios-simulator "$IOS_SIM_ID")"
fi

collect_ios_sensitive_state_snapshot() {
  local output_path="$1"
  local snapshot_dir="${output_path}.files"
  local -a labels=(user_defaults trusted_devices pairing_policy transfer_history)
  local -a sources=(
    "Library/Preferences/$IOS_BUNDLE_ID.plist"
    "Library/Application Support/$IOS_BUNDLE_ID/SkyBridgeState/Trust/trusted-devices.json"
    "Library/Application Support/$IOS_BUNDLE_ID/SkyBridgeState/P2P/pairing-policy.json"
    "Library/Application Support/$IOS_BUNDLE_ID/SkyBridgeState/FileTransfer/history.json"
  )
  local index=""
  local destination=""
  local copy_json=""
  local copy_log=""
  local copy_stdout=""
  local copy_stderr=""
  local copy_status=0

  [[ "$IOS_TARGET" == "physical" && -n "$IOS_DEVICE_ID" ]] || return 2
  [[ ! -e "$output_path" && ! -L "$output_path" ]] || return 2
  mkdir -m 0700 "$snapshot_dir"
  for index in "${!sources[@]}"; do
    destination="$snapshot_dir/${labels[$index]}"
    copy_json="$snapshot_dir/.${labels[$index]}.copy.json"
    copy_log="$snapshot_dir/.${labels[$index]}.copy.log"
    copy_stdout="$snapshot_dir/.${labels[$index]}.copy.stdout"
    copy_stderr="$snapshot_dir/.${labels[$index]}.copy.stderr"
    set +e
    xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device copy from \
      --device "$IOS_DEVICE_ID" \
      --domain-type appDataContainer \
      --domain-identifier "$IOS_BUNDLE_ID" \
      --source "${sources[$index]}" \
      --destination "$destination" \
      --json-output "$copy_json" \
      --log-output "$copy_log" >"$copy_stdout" 2>"$copy_stderr"
    copy_status=$?
    set -e
    if [[ "$copy_status" -ne 0 ]]; then
      if [[ "${labels[$index]}" == "transfer_history" ]] && \
        python3 -W error -B "$IOS_COPY_ABSENCE_VALIDATOR" \
          "$copy_json" "${sources[$index]}"
      then
        printf '%s' "absent" >"$destination"
      else
        echo "Unable to copy required existing iOS sensitive state: ${labels[$index]}" >&2
        return 1
      fi
    fi
    rm -f -- "$copy_json" "$copy_log" "$copy_stdout" "$copy_stderr"
    if [[ ! -s "$destination" || -L "$destination" ]]; then
      echo "Existing iOS sensitive-state artifact is missing or unsafe: ${labels[$index]}" >&2
      return 1
    fi
    chmod 0600 "$destination"
  done
  python3 - "$output_path" "$snapshot_dir" "${labels[@]}" <<'PY'
import hashlib
import os
import stat
import sys

output, root, *labels = sys.argv[1:]
lines = ["schema_version=1"]
for label in labels:
    path = os.path.join(root, label)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size < 1:
            raise SystemExit(f"unsafe sensitive state: {label}")
        content = b""
        while len(content) < before.st_size:
            chunk = os.read(descriptor, before.st_size - len(content))
            if not chunk:
                raise SystemExit(f"truncated sensitive state: {label}")
            content += chunk
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ):
            raise SystemExit(f"changed sensitive state: {label}")
    finally:
        os.close(descriptor)
    lines.append(f"{label}_bytes={len(content)}")
    lines.append(f"{label}_sha256={hashlib.sha256(content).hexdigest()}")

flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(output, flags, 0o600)
try:
    payload = ("\n".join(lines) + "\n").encode("ascii")
    offset = 0
    while offset < len(payload):
        offset += os.write(descriptor, payload[offset:])
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
  rm -rf -- "$snapshot_dir"
}

copy_ios_smoke_artifact() {
  local basename="$1"
  local local_path="$2"
  local container_root=""
  local artifact_path=""

  if [[ "$IOS_TARGET" == "physical" ]]; then
    local private_path=""
    local temporary_path=""
    case "$basename" in
      "$IOS_STATUS_BASENAME") private_path="$IOS_STATUS_PRIVATE" ;;
      "$IOS_TRACE_BASENAME") private_path="$IOS_TRACE_PRIVATE" ;;
      *) echo "Unsupported physical iOS artifact basename: $basename" >&2; return 1 ;;
    esac
    temporary_path="${private_path}.pending"
    rm -f -- "$temporary_path"
    if ! xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device copy from \
      --device "$IOS_DEVICE_ID" \
      --domain-type appDataContainer \
      --domain-identifier "$IOS_BUNDLE_ID" \
      --source "Library/Caches/$basename" \
      --destination "$temporary_path" >/dev/null 2>&1; then
      rm -f -- "$temporary_path"
      return 2
    fi
    if [[ ! -s "$temporary_path" || -L "$temporary_path" ]]; then
      rm -f -- "$temporary_path"
      echo "Physical iOS artifact copy produced no regular content: $basename" >&2
      return 1
    fi
    mv -f -- "$temporary_path" "$private_path"
    chmod 0600 "$private_path"
    if ! redact_ios_smoke_artifact_file_to "$private_path" "$local_path"; then
      IOS_ARTIFACT_REDACTION_FAILED="true"
      printf '%s\n' "redaction_failed" >"$local_path"
      return 1
    fi
    return 0
  fi

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

redact_ios_smoke_artifact_file_to() {
  local source_path="$1"
  local destination_path="$2"
  local temporary_path="${destination_path}.redacting"

  [[ -f "$source_path" && ! -L "$source_path" ]] || return 1
  rm -f -- "$temporary_path"
  if redact_smoke_artifact_stream <"$source_path" >"$temporary_path"; then
    mv -f -- "$temporary_path" "$destination_path"
    chmod 0600 "$destination_path"
  else
    rm -f -- "$temporary_path"
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
    "${ANDROID_HANDSHAKE_LOG:-}" \
    "${ANDROID_LOGCAT_START:-}" || true
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
ios_target=$IOS_TARGET
ios_destination=$(if [[ "$IOS_TARGET" == "physical" ]]; then echo '<physical-device>'; else echo "$IOS_DESTINATION"; fi)
ios_destination_source=$IOS_DESTINATION_SOURCE
ios_sim_id=$IOS_SIM_ID
ios_device_id=$(if [[ -n "$IOS_DEVICE_ID" ]]; then smoke_artifact_sensitive_value "$IOS_DEVICE_ID"; else echo none; fi)
ios_device_udid=$(if [[ -n "$IOS_DEVICE_UDID" ]]; then smoke_artifact_sensitive_value "$IOS_DEVICE_UDID"; else echo none; fi)
expected_source_commit=${EXPECTED_SOURCE_COMMIT:-none}
smoke_run_ref=$SMOKE_RUN_REF
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
  echo "ios_target=$IOS_TARGET"
  echo "ios_destination=$(if [[ "$IOS_TARGET" == "physical" ]]; then echo '<physical-device>'; else echo "$IOS_DESTINATION"; fi)"
  echo "ios_destination_source=$IOS_DESTINATION_SOURCE"
  echo "ios_sim_id=$IOS_SIM_ID"
  echo "ios_device_id=$(if [[ -n "$IOS_DEVICE_ID" ]]; then smoke_artifact_sensitive_value "$IOS_DEVICE_ID"; else echo none; fi)"
  echo "ios_device_udid=$(if [[ -n "$IOS_DEVICE_UDID" ]]; then smoke_artifact_sensitive_value "$IOS_DEVICE_UDID"; else echo none; fi)"
  echo "apple_identity_mode=$(if [[ "$IOS_TARGET" == "physical" ]]; then echo existing-persistent-read-only; else echo simulator-in-memory; fi)"
  echo "apple_persistent_identity_write_authorized=false"
  echo "apple_persistent_trust_write_authorized=false"
  echo "ios_installation_mode=$(if [[ "$IOS_TARGET" == "physical" ]]; then echo overlay-preserve-data; else echo simulator-replace; fi)"
  echo "smoke_run_ref=$SMOKE_RUN_REF"
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
unset SKYBRIDGE_BEARER_TOKEN SKYBRIDGE_ACCESS_TOKEN
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
if [[ "$IOS_TARGET" == "physical" ]]; then
  printf '%s' "$HOST_BEARER_TOKEN" | require_short_lived_bearer_token \
    || fail_summary "auth_context" "physical_bearer_token_not_short_lived"
fi

echo "Building Android debug + androidTest APKs..."
APP_APK="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"
if [[ "$IOS_TARGET" == "physical" ]]; then
  TEST_APK="$ROOT_DIR/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
  for output_apk in "$APP_APK" "$TEST_APK"; do
    if [[ -e "$output_apk" || -L "$output_apk" ]]; then
      [[ ! -d "$output_apk" ]] || fail_summary "android_build" "canonical_apk_output_is_directory"
      rm -f -- "$output_apk"
    fi
  done
  if ! "$ROOT_DIR/gradlew" \
    -p "$ROOT_DIR" \
    --no-daemon \
    --no-parallel \
    --max-workers=2 \
    --rerun-tasks \
    --warning-mode all \
    -PskybridgeIosWebRtcSmokeTestApplicationId="$PHYSICAL_TEST_PACKAGE" \
    :app:assembleDebug \
    :app:assembleDebugAndroidTest >"$ANDROID_BUILD_LOG" 2>&1; then
    fail_summary "android_build" "gradle_build_failed"
  fi
  skybridge_require_zero_warning_tool_log "$ANDROID_BUILD_LOG" \
    || fail_summary "android_build" "gradle_build_warning"
  skybridge_require_frozen_git_source \
    "$RELEASE_REPO_ROOT" "$EXPECTED_SOURCE_COMMIT" "physical smoke post-Android-build verification" \
    || fail_summary "source_freeze" "source_changed_after_android_build"
else
  "$ROOT_DIR/gradlew" -p "$ROOT_DIR" :app:assembleDebug :app:assembleDebugAndroidTest \
    >"$ANDROID_BUILD_LOG" 2>&1
  TEST_APK="$(find "$ROOT_DIR/app/build/outputs/apk" -path '*androidTest*' -name '*.apk' | head -n 1)"
fi
[[ -f "$APP_APK" ]] || fail_summary "android_build" "app_debug_apk_missing"
[[ -n "$TEST_APK" && -f "$TEST_APK" ]] || fail_summary "android_build" "android_test_apk_missing"
android_collect_source_provenance "$ROOT_DIR" "$PROVENANCE_DIR" >"$PROVENANCE_FILE"
android_collect_apk_provenance "$APP_APK" "app_debug_apk" >"$APP_APK_PROVENANCE"
android_collect_apk_provenance "$TEST_APK" "android_test_apk" >"$TEST_APK_PROVENANCE"
cat "$APP_APK_PROVENANCE" "$TEST_APK_PROVENANCE" >>"$PROVENANCE_FILE"
cat "$PROVENANCE_FILE" >>"$ENV_FILE"
APP_APK_SHA256="$(sed -n 's/^app_debug_apk_sha256=//p' "$APP_APK_PROVENANCE")"
TEST_APK_SHA256="$(sed -n 's/^android_test_apk_sha256=//p' "$TEST_APK_PROVENANCE")"
if [[ ! "$APP_APK_SHA256" =~ ^[0-9a-f]{64}$ || ! "$TEST_APK_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  fail_summary "android_build" "apk_provenance_malformed"
fi

if [[ "$IOS_TARGET" == "physical" ]]; then
  android_collect_samsung_4k_device_binding "$ADB_BIN" "$DEVICE_SERIAL" \
    >"$ANDROID_DEVICE_BINDING_BEFORE" \
    || fail_summary "android_device" "samsung_4k_device_preflight_failed"
  android_require_package_process_absent \
    "$ADB_BIN" "$DEVICE_SERIAL" "com.skybridge.compass.debug" \
    || fail_summary "android_process" "preexisting_android_app_process_before_install"
  android_require_package_absent "$ADB_BIN" "$DEVICE_SERIAL" "$PHYSICAL_TEST_PACKAGE" \
    || fail_summary "android_install" "dedicated_test_package_preexisted"
  {
    "$ADB_BIN" -s "$DEVICE_SERIAL" wait-for-device
    "$ADB_BIN" -s "$DEVICE_SERIAL" install --no-streaming -r -t "$APP_APK"
  } >"$ANDROID_INSTALL_LOG" 2>&1 || fail_summary "android_install" "app_install_failed"
  ANDROID_TEST_PACKAGE_STATE="install_attempted"
  TEST_INSTALL_OUTPUT=""
  TEST_INSTALL_STATUS=0
  set +e
  TEST_INSTALL_OUTPUT="$(
    "$ADB_BIN" -s "$DEVICE_SERIAL" install --no-streaming -t "$TEST_APK" 2>&1
  )"
  TEST_INSTALL_STATUS=$?
  set -e
  printf '%s\n' "$TEST_INSTALL_OUTPUT" >>"$ANDROID_INSTALL_LOG"
  if (( TEST_INSTALL_STATUS != 0 )) \
    || ! android_require_exact_success_output \
      "$TEST_INSTALL_OUTPUT" "dedicated Android test-package install"; then
    fail_summary "android_install" "test_install_failed_or_ambiguous"
  fi
  unset TEST_INSTALL_OUTPUT TEST_INSTALL_STATUS
  ANDROID_TEST_PACKAGE_STATE="owned_installed"
  android_require_installed_apk_digest \
    "$ADB_BIN" "$DEVICE_SERIAL" "com.skybridge.compass.debug" "$APP_APK_SHA256" \
    || fail_summary "android_install" "installed_app_digest_mismatch"
  android_require_installed_apk_digest \
    "$ADB_BIN" "$DEVICE_SERIAL" "$PHYSICAL_TEST_PACKAGE" "$TEST_APK_SHA256" \
    || fail_summary "android_install" "installed_test_digest_mismatch"
  {
    android_collect_installed_apk_binding \
      "$ADB_BIN" "$DEVICE_SERIAL" "com.skybridge.compass.debug" "$APP_APK_SHA256" app
    android_collect_installed_apk_binding \
      "$ADB_BIN" "$DEVICE_SERIAL" "$PHYSICAL_TEST_PACKAGE" "$TEST_APK_SHA256" test
  } >"$ANDROID_INSTALLED_APPS_BEFORE" \
    || fail_summary "android_install" "installed_apk_binding_failed"
else
  {
    "$ADB_BIN" -s "$DEVICE_SERIAL" wait-for-device
    "$ADB_BIN" -s "$DEVICE_SERIAL" install -r "$APP_APK"
    "$ADB_BIN" -s "$DEVICE_SERIAL" install -r -t "$TEST_APK"
  } >"$ANDROID_INSTALL_LOG" 2>&1 || fail_summary "android_install" "install_failed"
fi

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
if [[ "$IOS_TARGET" == "physical" ]]; then
  if "$ADB_BIN" -s "$DEVICE_SERIAL" shell run-as "$ANDROID_CONTEXT_PACKAGE" sh -c \
    "test ! -e files/$AUTH_CONTEXT_FILE_NAME && test ! -e files/$CODE_FILE_NAME" \
    >/dev/null 2>&1; then
    :
  else
    fail_summary "auth_context" "android_context_preexisted"
  fi
fi
ANDROID_CONTEXT_PREPARED="true"
ANDROID_AUTH_CONTEXT_STAGED="true"
printf '%s' "$AUTH_CONTEXT_PAYLOAD" |
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "run-as $ANDROID_CONTEXT_PACKAGE sh -c 'mkdir -p files && umask 077 && cat > files/$AUTH_CONTEXT_FILE_NAME'"
STAGED_AUTH_CONTEXT_PAYLOAD="$(
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell run-as "$ANDROID_CONTEXT_PACKAGE" \
    cat "files/$AUTH_CONTEXT_FILE_NAME" | tr -d '\r'
)"
if [[ "$STAGED_AUTH_CONTEXT_PAYLOAD" != "$AUTH_CONTEXT_PAYLOAD" ]]; then
  unset STAGED_AUTH_CONTEXT_PAYLOAD AUTH_CONTEXT_PAYLOAD
  fail_summary "auth_context" "android_auth_context_round_trip_mismatch"
fi
unset STAGED_AUTH_CONTEXT_PAYLOAD
unset AUTH_CONTEXT_PAYLOAD

if [[ "$IOS_TARGET" == "physical" ]]; then
  android_require_package_process_absent \
    "$ADB_BIN" "$DEVICE_SERIAL" "com.skybridge.compass.debug" \
    || fail_summary "android_process" "android_app_process_present_after_install"
  echo "Validating the exact physical iOS target..."
  xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" list devices \
    --json-output "$IOS_DEVICE_LIST_RAW" >/dev/null \
    || fail_summary "ios_device" "devicectl_list_failed"
  xcrun xcdevice list --timeout "$DEVICECTL_TIMEOUT_SECONDS" >"$IOS_XCDEVICE_LIST_RAW" \
    || fail_summary "ios_device" "xcdevice_list_failed"
  chmod 0600 "$IOS_DEVICE_LIST_RAW" "$IOS_XCDEVICE_LIST_RAW"
  python3 "$PHYSICAL_EVIDENCE_VALIDATOR" device \
    --devicectl-json "$IOS_DEVICE_LIST_RAW" \
    --xcdevice-json "$IOS_XCDEVICE_LIST_RAW" \
    --device-id "$IOS_DEVICE_ID" \
    --device-udid "$IOS_DEVICE_UDID" \
    --output "$IOS_DEVICE_BINDING" \
    || fail_summary "ios_device" "exact_physical_device_binding_failed"

  android_collect_apk_provenance \
    "$PROCESS_OWNERSHIP_HELPER" process_ownership_helper \
    >"$PHYSICAL_PRIVATE_DIR/process-ownership-helper.properties"
  android_collect_apk_provenance \
    "$PROCESS_OWNERSHIP_SHELL" process_ownership_shell \
    >"$PHYSICAL_PRIVATE_DIR/process-ownership-shell.properties"

  echo "Building the physical iOS diagnostic app..."
  if ! xcodebuild \
    -project "$IOS_PROJECT_FILE" \
    -scheme "$IOS_SCHEME" \
    -configuration Debug \
    -destination "$IOS_DESTINATION" \
    -derivedDataPath "$RUN_DIR/DerivedData-ios" \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    build >"$IOS_BUILD_LOG" 2>&1; then
    fail_summary "ios_build" "physical_xcodebuild_failed"
  fi
  if rg -n '(?i)(^|[[:space:]])warning:' "$IOS_BUILD_LOG" >/dev/null; then
    fail_summary "ios_build" "physical_xcodebuild_warning"
  fi
  IOS_APP_PATH="$RUN_DIR/DerivedData-ios/Build/Products/Debug-iphoneos/SkyBridgeCompass-iOS.app"
  if [[ ! -d "$IOS_APP_PATH" || -L "$IOS_APP_PATH" ]]; then
    fail_summary "ios_build" "physical_ios_app_bundle_missing_or_unsafe"
  fi
  skybridge_collect_ios_app_provenance \
    "$IOS_APP_PATH" ios_physical_app "$IOS_BUNDLE_ID" >"$IOS_APP_PROVENANCE" \
    || fail_summary "ios_build" "physical_ios_app_provenance_failed"
  skybridge_require_frozen_git_source \
    "$RELEASE_REPO_ROOT" "$EXPECTED_SOURCE_COMMIT" "physical smoke post-iOS-build verification" \
    || fail_summary "source_freeze" "source_changed_after_ios_build"

  skybridge_ios_require_fresh_app_launch \
    "$PROCESS_OWNERSHIP_HELPER" "$IOS_DEVICE_ID" "$IOS_APP_PATH" \
    "$PHYSICAL_PRIVATE_DIR" "$DEVICECTL_TIMEOUT_SECONDS" \
    || fail_summary "ios_install" "preexisting_ios_process"

  echo "Overlay-installing the exact physical iOS app without uninstalling or clearing data..."
  xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device install app \
    --device "$IOS_DEVICE_ID" \
    --json-output "$IOS_INSTALL_RESULT_RAW" \
    "$IOS_APP_PATH" >/dev/null \
    || fail_summary "ios_install" "devicectl_overlay_install_failed"
  chmod 0600 "$IOS_INSTALL_RESULT_RAW"
  xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device info apps \
    --device "$IOS_DEVICE_ID" \
    --bundle-id "$IOS_BUNDLE_ID" \
    --columns '*' \
    --json-output "$IOS_APPS_RESULT_RAW" >/dev/null \
    || fail_summary "ios_install" "devicectl_installed_app_query_failed"
  chmod 0600 "$IOS_APPS_RESULT_RAW"
  python3 "$PHYSICAL_EVIDENCE_VALIDATOR" installation \
    --device-binding "$IOS_DEVICE_BINDING" \
    --install-result "$IOS_INSTALL_RESULT_RAW" \
    --apps-result "$IOS_APPS_RESULT_RAW" \
    --app-provenance "$IOS_APP_PROVENANCE" \
    --output "$IOS_INSTALLATION_BINDING" \
    || fail_summary "ios_install" "physical_installation_binding_failed"
  IOS_LAUNCH_PERSISTENT_IDENTIFIER="$(
    python3 - "$IOS_INSTALLATION_BINDING" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
value = payload.get("launchServicesIdentifier")
if not isinstance(value, str) or not value:
    raise SystemExit("installation binding omitted launchServicesIdentifier")
print(value)
PY
  )" || fail_summary "ios_install" "launch_persistent_identifier_missing"
  skybridge_require_ios_app_provenance_unchanged \
    "$IOS_APP_PATH" ios_physical_app "$IOS_BUNDLE_ID" "$IOS_APP_PROVENANCE" \
    || fail_summary "ios_install" "ios_app_changed_after_install"
  skybridge_ios_require_fresh_app_launch \
    "$PROCESS_OWNERSHIP_HELPER" "$IOS_DEVICE_ID" "$IOS_APP_PATH" \
    "$PHYSICAL_PRIVATE_DIR" "$DEVICECTL_TIMEOUT_SECONDS" \
    || fail_summary "ios_install" "post_install_ios_process_present"
  collect_ios_sensitive_state_snapshot "$IOS_SENSITIVE_STATE_BEFORE" \
    || fail_summary "state_freeze" "ios_sensitive_state_preflight_failed"
fi

ANDROID_LOGCAT_START="$(
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell "date '+%m-%d %H:%M:%S.000'" | tr -d '\r\n'
)" || fail_summary "android_logcat" "logcat_start_time_unavailable"
if [[ ! "$ANDROID_LOGCAT_START" =~ ^[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}$ ]]; then
  fail_summary "android_logcat" "logcat_start_time_invalid"
fi

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
  -e skybridgeSmokeRunRef "$SMOKE_RUN_REF"
)
if [[ -n "$EXPECTED_NEGOTIATED_SUITE" ]]; then
  ANDROID_INSTRUMENT_ARGS+=(-e skybridgeExpectedNegotiatedSuite "$EXPECTED_NEGOTIATED_SUITE")
fi
if [[ "$IOS_TARGET" == "physical" ]]; then
  ANDROID_INSTRUMENT_ARGS+=(
    -e skybridgeUseDedicatedTestStorage true
    -e skybridgeExpectedStoragePackage "$PHYSICAL_TEST_PACKAGE"
    -e skybridgeExpectBidirectionalFileTransfer true
    -e skybridgeAndroidToPeerTransferId "$ANDROID_TO_PEER_TRANSFER_ID"
    -e skybridgePeerToAndroidTransferId "$PEER_TO_ANDROID_TRANSFER_ID"
    "$PHYSICAL_RUNNER"
  )
else
  ANDROID_INSTRUMENT_ARGS+=("$SIMULATOR_RUNNER")
fi
ANDROID_CONTEXT_PREPARED="true"
ANDROID_CODE_CONTEXT_STAGED="true"
(
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell "${ANDROID_INSTRUMENT_ARGS[@]}"
) >"$ANDROID_INSTRUMENTATION_LOG" 2>&1 &
ANDROID_PID=$!
ANDROID_INSTRUMENTATION_STARTED="true"

CONNECTION_CODE=""
for _ in $(seq 1 $(( ANDROID_TIMEOUT_SECONDS * 2 ))); do
  if ! kill -0 "$ANDROID_PID" >/dev/null 2>&1; then
    wait "$ANDROID_PID" || true
    ANDROID_PID=""
    fail_summary "android_offer_code" "android_instrumentation_exited_before_code"
  fi
  set +e
  CONNECTION_CODE="$(
    "$ADB_BIN" -s "$DEVICE_SERIAL" shell run-as "$ANDROID_CONTEXT_PACKAGE" \
      cat "files/$CODE_FILE_NAME" 2>>"$ANDROID_CODE_POLL_LOG" | tr -d '\r\n'
  )"
  READ_CODE_EXIT=$?
  set -e
  if [[ "$READ_CODE_EXIT" -eq 0 && -n "$CONNECTION_CODE" ]]; then
    break
  fi
  sleep 0.5
done
[[ -n "$CONNECTION_CODE" ]] || fail_summary "android_offer_code" "connection_code_timeout"
echo "Android connection code: <redacted>"

IOS_SUCCESS_HOLD_SECONDS="2"
if [[ "$EXPECT_FILE_TRANSFER" == "true" ]]; then
  IOS_SUCCESS_HOLD_SECONDS=$(( FILE_TRANSFER_TIMEOUT_SECONDS + 5 ))
fi

echo "Launching iOS client responder..."
IOS_STATUS_EVIDENCE_PATH=""
if [[ "$IOS_TARGET" == "simulator" ]]; then
  echo "iOS simulator: $IOS_SIM_ID" >>"$ENV_FILE"
  echo "Building iOS simulator app..."
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
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_RUN_REF="$SMOKE_RUN_REF" \
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
  IOS_STATUS_EVIDENCE_PATH="$IOS_STATUS_LOCAL"
else
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_EXISTING_TRUST_ONLY=1 \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_REQUIRE_PQC="$(if [[ "$PQC_ENABLED" == "true" ]]; then echo 1; else echo 0; fi)" \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_EXPECTED_SUITE_WIRE_ID="0x0101" \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=0 \
  DEVICECTL_CHILD_SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE=0 \
  DEVICECTL_CHILD_SKYBRIDGE_ACCESS_TOKEN="$HOST_BEARER_TOKEN" \
  DEVICECTL_CHILD_SKYBRIDGE_TENANT_ID="$HOST_TENANT_ID" \
  DEVICECTL_CHILD_SKYBRIDGE_USER_ID="${HOST_USER_ID:-android-ios-physical-smoke-user}" \
  DEVICECTL_CHILD_SKYBRIDGE_DISPLAY_NAME="$HOST_DISPLAY_NAME" \
  DEVICECTL_CHILD_SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_ORIGIN" \
  DEVICECTL_CHILD_SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$WS_URL" \
  DEVICECTL_CHILD_SKYBRIDGE_STUN_URL="" \
  DEVICECTL_CHILD_SKYBRIDGE_TURN_URLS="" \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_ROLE=ios-client \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_CONNECT_CODE="$CONNECTION_CODE" \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_RUN_REF="$SMOKE_RUN_REF" \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_BIDIRECTIONAL_FILE_TRANSFER=1 \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_ANDROID_TO_PEER_TRANSFER_ID="$ANDROID_TO_PEER_TRANSFER_ID" \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_PEER_TO_ANDROID_TRANSFER_ID="$PEER_TO_ANDROID_TRANSFER_ID" \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_BASENAME" \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$IOS_TIMEOUT_SECONDS" \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_HANDSHAKE_ONLY=0 \
  DEVICECTL_CHILD_SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS=6 \
  DEVICECTL_CHILD_SB_ENABLE_QPERIAPT="$(if [[ "$EXPECT_QPERIAPT" == "true" ]]; then echo 1; else echo 0; fi)" \
  DEVICECTL_CHILD_SB_PQC_PREFERRED_SUITE="mlkem" \
  DEVICECTL_CHILD_SKYBRIDGE_PQC_PREFERRED_SUITE="mlkem" \
  skybridge_ios_start_console_launch \
    "$IOS_DEVICE_ID" "$IOS_BUNDLE_ID" "$IOS_LAUNCH_PERSISTENT_IDENTIFIER" \
    "$((IOS_TIMEOUT_SECONDS + 120))" "$IOS_LAUNCH_RESULT_RAW" \
    "$IOS_STDOUT" "$IOS_STDERR" IOS_CONSOLE_PID 0 \
    || fail_summary "ios_launch" "devicectl_console_launch_failed"
  unset HOST_BEARER_TOKEN
  CONNECTION_CODE=""
  IOS_CONSOLE_HANDLE_STARTED="true"
  skybridge_ios_capture_console_handle \
    "$PROCESS_OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$IOS_CONSOLE_HANDLE_IDENTITY" \
    "$IOS_CONSOLE_CAPTURE_DIAGNOSTIC" 20 \
    || fail_summary "ios_launch" "exact_console_handle_capture_failed"
  IOS_CONSOLE_HANDLE_CAPTURED="true"

  for _ in $(seq 1 $(( IOS_TIMEOUT_SECONDS * 2 ))); do
    if ! skybridge_ios_console_handle_status \
      "$PROCESS_OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$IOS_CONSOLE_HANDLE_IDENTITY"; then
      fail_summary "ios_launch" "exact_console_handle_exited_before_terminal_status"
    fi
    set +e
    copy_ios_smoke_artifact "$IOS_STATUS_BASENAME" "$IOS_STATUS_LOCAL"
    IOS_COPY_STATUS=$?
    set -e
    if (( IOS_COPY_STATUS == 0 )); then
      if grep -q 'failed stage=' "$IOS_STATUS_PRIVATE"; then
        fail_summary "ios_client_join" "physical_ios_status_failed"
      fi
      if grep -Eq 'success (session|session_ref)=' "$IOS_STATUS_PRIVATE"; then
        break
      fi
    elif (( IOS_COPY_STATUS != 2 )); then
      fail_summary "ios_artifact_copy" "physical_ios_status_copy_failed"
    fi
    sleep 0.5
  done
  copy_ios_smoke_artifact "$IOS_STATUS_BASENAME" "$IOS_STATUS_LOCAL" \
    || fail_summary "ios_artifact_copy" "physical_ios_status_final_copy_failed"
  copy_ios_smoke_artifact "$IOS_TRACE_BASENAME" "$IOS_TRACE_LOCAL" || true
  IOS_STATUS_EVIDENCE_PATH="$IOS_STATUS_PRIVATE"
fi
[[ -s "$IOS_STATUS_LOCAL" ]] || fail_summary "ios_client_join" "ios_status_missing"
grep -Eq 'success (session|session_ref)=' "$IOS_STATUS_EVIDENCE_PATH" \
  || fail_summary "ios_client_join" "ios_success_timeout"

set +e
wait "$ANDROID_PID"
ANDROID_EXIT=$?
set -e
ANDROID_PID=""
if [[ "$IOS_TARGET" == "physical" ]]; then
  android_require_package_process_absent \
    "$ADB_BIN" "$DEVICE_SERIAL" "com.skybridge.compass.debug" \
    || fail_summary "android_process" "android_app_process_remained_after_instrumentation"
  ANDROID_APP_EXIT_VERIFIED="true"
fi

if ! android_capture_redacted_logcat \
  "$ADB_BIN" "$DEVICE_SERIAL" "$ANDROID_LOGCAT_LOG" "$ANDROID_HANDSHAKE_LOG" "$ANDROID_LOGCAT_START"; then
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
ANDROID_BIDIRECTIONAL_FILE_TRANSFER_ASSERTED="$(
  printf '%s\n' "$ANDROID_SUCCESS_LINE" |
    sed -n 's/.* bidirectionalFileTransfer=\([^ ]*\).*/\1/p'
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
  if [[ "$IOS_TARGET" == "physical" && "$ANDROID_BIDIRECTIONAL_FILE_TRANSFER_ASSERTED" != "true" ]]; then
    FILE_TRANSFER_ASSERTION_OK="false"
    FILE_TRANSFER_ASSERTION_FAILURE="android_bidirectional_file_transfer_asserted=$ANDROID_BIDIRECTIONAL_FILE_TRANSFER_ASSERTED"
  elif [[ "$ANDROID_FILE_TRANSFER_ASSERTED" != "true" ]]; then
    FILE_TRANSFER_ASSERTION_OK="false"
    FILE_TRANSFER_ASSERTION_FAILURE="android_file_transfer_asserted=$ANDROID_FILE_TRANSFER_ASSERTED"
  elif [[ "$IOS_TARGET" == "physical" ]]; then
    :
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

if [[ "$FILE_TRANSFER_ASSERTION_OK" != "true" ]]; then
  fail_summary "file_transfer" "$FILE_TRANSFER_ASSERTION_FAILURE"
fi
if [[ "$QPERIAPT_ASSERTION_OK" != "true" ]]; then
  fail_summary "qperiapt" "$QPERIAPT_ASSERTION_FAILURE"
fi

if [[ "$IOS_TARGET" == "physical" ]]; then
  android_require_exact_device "$ADB_BIN" "$DEVICE_SERIAL" \
    || fail_summary "post_device_freeze" "android_serial_identity_changed"
  android_collect_samsung_4k_device_binding "$ADB_BIN" "$DEVICE_SERIAL" \
    >"$ANDROID_DEVICE_BINDING_AFTER" \
    || fail_summary "post_device_freeze" "android_device_binding_unavailable"
  cmp -s -- "$ANDROID_DEVICE_BINDING_BEFORE" "$ANDROID_DEVICE_BINDING_AFTER" \
    || fail_summary "post_device_freeze" "android_device_binding_changed"
  android_require_apk_provenance_unchanged \
    "$APP_APK" app_debug_apk "$APP_APK_PROVENANCE" \
    || fail_summary "post_device_freeze" "app_apk_changed"
  android_require_apk_provenance_unchanged \
    "$TEST_APK" android_test_apk "$TEST_APK_PROVENANCE" \
    || fail_summary "post_device_freeze" "test_apk_changed"
  android_require_installed_apk_digest \
    "$ADB_BIN" "$DEVICE_SERIAL" "com.skybridge.compass.debug" "$APP_APK_SHA256" \
    || fail_summary "post_device_freeze" "installed_app_digest_changed"
  android_require_installed_apk_digest \
    "$ADB_BIN" "$DEVICE_SERIAL" "$PHYSICAL_TEST_PACKAGE" "$TEST_APK_SHA256" \
    || fail_summary "post_device_freeze" "installed_test_digest_changed"
  skybridge_require_ios_app_provenance_unchanged \
    "$IOS_APP_PATH" ios_physical_app "$IOS_BUNDLE_ID" "$IOS_APP_PROVENANCE" \
    || fail_summary "post_device_freeze" "ios_app_changed"
  android_require_apk_provenance_unchanged \
    "$PROCESS_OWNERSHIP_HELPER" process_ownership_helper \
    "$PHYSICAL_PRIVATE_DIR/process-ownership-helper.properties" \
    || fail_summary "post_device_freeze" "process_ownership_helper_changed"
  android_require_apk_provenance_unchanged \
    "$PROCESS_OWNERSHIP_SHELL" process_ownership_shell \
    "$PHYSICAL_PRIVATE_DIR/process-ownership-shell.properties" \
    || fail_summary "post_device_freeze" "process_ownership_shell_changed"
  skybridge_require_frozen_git_source \
    "$RELEASE_REPO_ROOT" "$EXPECTED_SOURCE_COMMIT" "physical smoke post-device verification" \
    || fail_summary "post_device_freeze" "source_changed_after_device_run"
  skybridge_collect_frozen_git_binding \
    "$RELEASE_REPO_ROOT" "$EXPECTED_SOURCE_COMMIT" after >"$SOURCE_BINDING_AFTER" \
    || fail_summary "post_device_freeze" "source_binding_unavailable"
  {
    android_collect_installed_apk_binding \
      "$ADB_BIN" "$DEVICE_SERIAL" "com.skybridge.compass.debug" "$APP_APK_SHA256" app
    android_collect_installed_apk_binding \
      "$ADB_BIN" "$DEVICE_SERIAL" "$PHYSICAL_TEST_PACKAGE" "$TEST_APK_SHA256" test
  } >"$ANDROID_INSTALLED_APPS_AFTER" \
    || fail_summary "post_device_freeze" "installed_apk_binding_unavailable"
  cmp -s -- "$ANDROID_INSTALLED_APPS_BEFORE" "$ANDROID_INSTALLED_APPS_AFTER" \
    || fail_summary "post_device_freeze" "installed_apk_binding_changed"
  finish_physical_ios_process \
    || fail_summary "cleanup" "physical_ios_exact_process_cleanup_failed"
  collect_ios_sensitive_state_snapshot "$IOS_SENSITIVE_STATE_AFTER" \
    || fail_summary "state_freeze" "ios_sensitive_state_postflight_failed"
  remove_android_context_files \
    || fail_summary "cleanup" "android_context_cleanup_failed"
  remove_owned_android_test_package \
    || fail_summary "cleanup" "android_test_package_cleanup_failed"
  if python3 "$PHYSICAL_EVIDENCE_VALIDATOR" state-freeze \
    --android-instrumentation "$ANDROID_INSTRUMENTATION_LOG" \
    --ios-status "$IOS_STATUS_PRIVATE" \
    --ios-container-before "$IOS_SENSITIVE_STATE_BEFORE" \
    --ios-container-after "$IOS_SENSITIVE_STATE_AFTER"; then
    ANDROID_SENSITIVE_STATE_UNCHANGED="true"
    IOS_REQUIRED_IDENTITY_AND_CONTAINER_STATE_UNCHANGED="true"
  else
    fail_summary "state_freeze" "persistent_identity_or_trust_state_changed"
  fi
  python3 "$PHYSICAL_EVIDENCE_VALIDATOR" receipt \
    --source-commit "$EXPECTED_SOURCE_COMMIT" \
    --run-ref "$SMOKE_RUN_REF" \
    --installation-binding "$IOS_INSTALLATION_BINDING" \
    --launch-result "$IOS_LAUNCH_RESULT_RAW" \
    --ios-status "$IOS_STATUS_PRIVATE" \
    --ios-stdout "$IOS_STDOUT" \
    --ios-process-identity "$IOS_PROCESS_IDENTITY" \
    --app-apk-provenance "$APP_APK_PROVENANCE" \
    --test-apk-provenance "$TEST_APK_PROVENANCE" \
    --android-instrumentation "$ANDROID_INSTRUMENTATION_LOG" \
    --android-device-before "$ANDROID_DEVICE_BINDING_BEFORE" \
    --android-device-after "$ANDROID_DEVICE_BINDING_AFTER" \
    --android-installed-before "$ANDROID_INSTALLED_APPS_BEFORE" \
    --android-installed-after "$ANDROID_INSTALLED_APPS_AFTER" \
    --source-binding-before "$SOURCE_BINDING_BEFORE" \
    --source-binding-after "$SOURCE_BINDING_AFTER" \
    --console-cleanup-verified "$IOS_CONSOLE_CLEANUP_VERIFIED" \
    --app-exit-verified "$IOS_APP_EXIT_VERIFIED" \
    --android-app-exit-verified "$ANDROID_APP_EXIT_VERIFIED" \
    --test-package-cleanup-verified "$ANDROID_TEST_PACKAGE_CLEANUP_VERIFIED" \
    --android-context-cleanup-verified "$ANDROID_CONTEXT_CLEANUP_VERIFIED" \
    --expect-file-transfer "$EXPECT_FILE_TRANSFER" \
    --android-sensitive-state-unchanged "$ANDROID_SENSITIVE_STATE_UNCHANGED" \
    --ios-required-identity-and-container-state-unchanged \
      "$IOS_REQUIRED_IDENTITY_AND_CONTAINER_STATE_UNCHANGED" \
    --ios-container-before "$IOS_SENSITIVE_STATE_BEFORE" \
    --ios-container-after "$IOS_SENSITIVE_STATE_AFTER" \
    --output "$PHYSICAL_RECEIPT" \
    || fail_summary "evidence_receipt" "physical_receipt_validation_failed"
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
  echo "android_bidirectional_file_transfer_asserted=$ANDROID_BIDIRECTIONAL_FILE_TRANSFER_ASSERTED"
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
  echo "ios_target=$IOS_TARGET"
  echo "source_freeze_verified=$(if [[ "$IOS_TARGET" == "physical" ]]; then echo true; else echo not_required; fi)"
  echo "android_context_cleanup_verified=$ANDROID_CONTEXT_CLEANUP_VERIFIED"
  echo "android_test_package_cleanup_verified=$ANDROID_TEST_PACKAGE_CLEANUP_VERIFIED"
  echo "ios_console_cleanup_verified=$IOS_CONSOLE_CLEANUP_VERIFIED"
  echo "ios_app_exit_verified=$IOS_APP_EXIT_VERIFIED"
  echo "physical_evidence_receipt=$(if [[ "$IOS_TARGET" == "physical" ]]; then echo "$PHYSICAL_RECEIPT"; else echo none; fi)"
  echo "android_logcat=$ANDROID_LOGCAT_LOG"
  cat "$PROVENANCE_FILE"
} >"$SUMMARY_FILE"

if [[ "$IOS_ARTIFACT_REDACTION_FAILED" == "true" ]]; then
  echo "Android -> iOS iOS artifact redaction failed; evidence bundle rejected." >&2
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
