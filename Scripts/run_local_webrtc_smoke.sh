#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/local_webrtc_smoke_$(date +%Y%m%d_%H%M%S)}"
SIGNALING_PORT="${SKYBRIDGE_SMOKE_SIGNALING_PORT:-18443}"
SMOKE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-120}"
SMOKE_ROUNDS="${SKYBRIDGE_SMOKE_ROUNDS:-3}"
SMOKE_SCENARIO="${SKYBRIDGE_SMOKE_SCENARIO:-bootstrap-rekey}"
IOS_BUNDLE_ID="com.skybridge.compass.ios"
MAC_DEVICE_ID="${SKYBRIDGE_SMOKE_MAC_DEVICE_ID:-smoke-mac-device-0001}"
IOS_DEVICE_ID="${SKYBRIDGE_SMOKE_IOS_DEVICE_ID:-smoke-ios-device-0001}"

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
AUTH_SESSION_FILE=""

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

kill_listener_on_port() {
  local port="$1"
  local pids
  pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -z "$pids" ]]; then
    return 0
  fi

  echo "==> Reclaiming TCP port ${port} from stale listener(s): ${pids}"
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done <<< "$pids"
  sleep 1
}

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

resolve_ios_status_path() {
  local basename="$1"
  local root="$HOME/Library/Developer/CoreSimulator/Devices/${SIM_ID}/data/Containers/Data/Application"
  find "$root" -name "$basename" -print 2>/dev/null | tail -n 1
}

wait_for_ios_status_pattern() {
  local basename="$1"
  local pattern="$2"
  local timeout_seconds="$3"
  local label="$4"
  local started_at
  started_at="$(date +%s)"
  while true; do
    local resolved_path
    resolved_path="$(resolve_ios_status_path "$basename" || true)"
    if [[ -n "$resolved_path" && -f "$resolved_path" ]] && grep -qE "$pattern" "$resolved_path"; then
      IOS_STATUS_PATH="$resolved_path"
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${resolved_path:-<unresolved>}" >&2
      return 1
    fi
    sleep 1
  done
}

require_file_pattern() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  if [[ ! -f "$path" ]] || ! grep -qE "$pattern" "$path"; then
    echo "Missing expected pattern for ${label}: ${pattern} (${path})" >&2
    return 1
  fi
}

require_file_absent_pattern() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  if [[ -f "$path" ]] && grep -qE "$pattern" "$path"; then
    echo "Unexpected pattern for ${label}: ${pattern} (${path})" >&2
    return 1
  fi
}

load_pqc_report() {
  local report_path="$1"
  local parsed
  parsed="$(python3 - "$report_path" <<'PY'
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

  MAC_PQC_DEVICE_ID="$(printf '%s\n' "$parsed" | sed -n '1p')"
  MAC_PQC_XWING_PUBLIC_KEY_BASE64="$(printf '%s\n' "$parsed" | sed -n '2p')"
  MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64="$(printf '%s\n' "$parsed" | sed -n '3p')"
  MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64="$(printf '%s\n' "$parsed" | sed -n '4p')"

  if [[ -z "$MAC_PQC_DEVICE_ID" || -z "$MAC_PQC_XWING_PUBLIC_KEY_BASE64" ]]; then
    echo "PQC report is missing required deviceId/X-Wing key: ${report_path}" >&2
    return 1
  fi
}

require_registry_env() {
  local missing=()
  local key
  for key in SUPABASE_URL SUPABASE_ANON_KEY; do
    if [[ -z "${!key:-}" ]]; then
      missing+=("$key")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Missing required Supabase auth env for local signaling smoke: ${missing[*]}" >&2
    exit 1
  fi
}

export_smoke_auth_session() {
  AUTH_SESSION_FILE="$ARTIFACT_DIR/smoke_auth_session.json"
  local cache_path="$ROOT_DIR/Artifacts/local_webrtc_smoke_auth_cache.json"
  python3 - "$AUTH_SESSION_FILE" "$cache_path" <<'PY'
import json
import pathlib
import subprocess
import sys
import base64
import os
import time
import urllib.request

output_path = pathlib.Path(sys.argv[1])
cache_path = pathlib.Path(sys.argv[2])

def token_is_fresh(session):
    token = str(session.get("accessToken") or "").strip()
    if not token:
        return False
    try:
        payload = token.split(".")[1]
        payload += "=" * ((4 - len(payload) % 4) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return False
    exp = claims.get("exp")
    if not isinstance(exp, (int, float)):
        return False
    return float(exp) - time.time() > 600

cached_session = None
for candidate in (output_path, cache_path):
    if candidate.exists():
        try:
            cached = json.loads(candidate.read_text(encoding="utf-8"))
        except Exception:
            continue
        if cached_session is None:
            cached_session = cached
        if token_is_fresh(cached):
            output_path.write_text(json.dumps(cached), encoding="utf-8")
            raise SystemExit(0)

cmd = [
    "security",
    "find-generic-password",
    "-s", "com.skybridge.compass.authsession",
    "-a", "primary",
    "-w",
]
try:
    raw = subprocess.check_output(cmd, timeout=65).strip()
except subprocess.TimeoutExpired:
    if cached_session is None:
        raise SystemExit("Timed out reading auth session from macOS keychain.")
    session = cached_session
except subprocess.CalledProcessError as exc:
    if cached_session is None:
        raise SystemExit(f"Unable to read auth session from macOS keychain (exit {exc.returncode}).")
    session = cached_session
else:
    try:
        payload = bytes.fromhex(raw.decode())
    except Exception:
        payload = raw

    try:
        session = json.loads(payload)
    except Exception as exc:
        raise SystemExit(f"Unable to decode auth session JSON: {exc}")

access_token = str(session.get("accessToken") or "").strip()
if not access_token:
    raise SystemExit("Auth session is missing accessToken.")

supabase_url = str(os.environ.get("SUPABASE_URL") or "").strip().rstrip("/")
supabase_anon_key = str(os.environ.get("SUPABASE_ANON_KEY") or "").strip()
refresh_token = str(session.get("refreshToken") or "").strip()
if refresh_token and supabase_url and supabase_anon_key:
    request = urllib.request.Request(
        f"{supabase_url}/auth/v1/token?grant_type=refresh_token",
        data=json.dumps({"refresh_token": refresh_token}).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {supabase_anon_key}",
            "apikey": supabase_anon_key,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8"))
            refreshed_access_token = str(payload.get("access_token") or "").strip()
            if refreshed_access_token:
                session["accessToken"] = refreshed_access_token
                refreshed_refresh_token = str(payload.get("refresh_token") or "").strip()
                if refreshed_refresh_token:
                    session["refreshToken"] = refreshed_refresh_token
    except Exception as exc:
        print(
            f"Warning: failed to refresh smoke auth session; using stored access token ({exc}).",
            file=sys.stderr,
        )

output_path.write_text(json.dumps(session), encoding="utf-8")
cache_path.write_text(json.dumps(session), encoding="utf-8")
PY
}

validate_scenario() {
  case "$SMOKE_SCENARIO" in
    bootstrap-rekey|xwing-only)
      ;;
    *)
      echo "Unsupported smoke scenario: ${SMOKE_SCENARIO}" >&2
      exit 1
      ;;
  esac
}

validate_scenario

echo "==> Artifacts: ${ARTIFACT_DIR}"
echo "==> Simulator: ${SIM_ID}"
echo "==> Scenario: ${SMOKE_SCENARIO}"

echo "==> Building macOS smoke host"
MAC_BUILD_LOG="$ARTIFACT_DIR/macos-build.log"
SMOKE_BUILD_DIR="$ARTIFACT_DIR/SwiftPMBuild"
(
  cd "$ROOT_DIR"
  swift build --build-path "$SMOKE_BUILD_DIR" --product LocalWebRTCSmokeHost
) >"$MAC_BUILD_LOG"

MAC_APP_BIN="$SMOKE_BUILD_DIR/debug/LocalWebRTCSmokeHost"
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

echo "==> Exporting smoke auth session"
if ! export_smoke_auth_session; then
  echo "Warning: failed to export smoke auth session; falling back to host-side session lookup." >&2
  AUTH_SESSION_FILE=""
fi

echo "==> Starting local signaling server"
kill_listener_on_port "$SIGNALING_PORT"
pushd "$ROOT_DIR/Server/skybridge-signaling" >/dev/null
HOST=127.0.0.1 \
PORT="$SIGNALING_PORT" \
TURN_ENFORCE_API_KEY=false \
SUPABASE_TIMEOUT_MS=20000 \
TURN_SHARED_SECRET=skybridge-local-smoke \
TURN_URIS="turn:127.0.0.1:3478?transport=udp" \
REQUIRE_SHARED_STATE_FOR_PUBLIC_CAPABILITIES=false \
SIGNALING_ALLOW_BOOTSTRAP_TENANT_POLICY=1 \
SIGNALING_ALLOW_BOOTSTRAP_DEVICE_AUTH=1 \
SIGNALING_BOOTSTRAP_TENANT_MODE=user_id \
node server.js >"$ARTIFACT_DIR/signaling.log" 2>&1 &
SIGNALING_PID="$!"
popd >/dev/null
wait_for_http_ok "${SIGNALING_SERVER_URL}/healthz" 20

for round in $(seq 1 "$SMOKE_ROUNDS"); do
  echo "==> Smoke round ${round}/${SMOKE_ROUNDS}"

  MAC_STATUS="$ARTIFACT_DIR/mac_round_${round}.status.log"
  MAC_CODE="$ARTIFACT_DIR/mac_round_${round}.code"
  MAC_TOKEN="$ARTIFACT_DIR/mac_round_${round}.token"
  MAC_TENANT="$ARTIFACT_DIR/mac_round_${round}.tenant"
  MAC_PQC_REPORT="$ARTIFACT_DIR/mac_round_${round}.pqc.json"
  MAC_STDOUT="$ARTIFACT_DIR/mac_round_${round}.stdout.log"
  IOS_STATUS_BASENAME="ios_round_${round}.status.log"
  IOS_STATUS_PATH=""
  IOS_STDOUT="$ARTIFACT_DIR/ios_round_${round}.stdout.log"
  IOS_STDERR="$ARTIFACT_DIR/ios_round_${round}.stderr.log"
  ROUND_MAC_DEVICE_ID="${MAC_DEVICE_ID}-${round}"
  ROUND_IOS_DEVICE_ID="${IOS_DEVICE_ID}-${round}"

  rm -f "$MAC_STATUS" "$MAC_CODE" "$MAC_TOKEN" "$MAC_TENANT" "$MAC_PQC_REPORT" "$MAC_STDOUT" "$IOS_STATUS_PATH" "$IOS_STDOUT" "$IOS_STDERR"

  xcrun simctl terminate "$SIM_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -n "${MAC_PID}" ]]; then
    kill "${MAC_PID}" >/dev/null 2>&1 || true
    wait "${MAC_PID}" >/dev/null 2>&1 || true
    MAC_PID=""
  fi
  pkill -x LocalWebRTCSmokeHost >/dev/null 2>&1 || true

  if [[ "$SMOKE_SCENARIO" == "bootstrap-rekey" ]]; then
    SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
    SKYBRIDGE_AUTH_SESSION_FILE="$AUTH_SESSION_FILE" \
    SKYBRIDGE_DEVICE_ID="$ROUND_MAC_DEVICE_ID" \
    SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
    SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
    SKYBRIDGE_SMOKE_SUPABASE_URL="$SUPABASE_URL" \
    SKYBRIDGE_SMOKE_SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
    SKYBRIDGE_STUN_URL="" \
    SKYBRIDGE_TURN_URLS="" \
    SKYBRIDGE_SMOKE_ROLE=mac-host \
    SKYBRIDGE_SMOKE_STATUS_FILE="$MAC_STATUS" \
    SKYBRIDGE_SMOKE_CODE_FILE="$MAC_CODE" \
    SKYBRIDGE_SMOKE_TOKEN_FILE="$MAC_TOKEN" \
    SKYBRIDGE_SMOKE_TENANT_FILE="$MAC_TENANT" \
    SKYBRIDGE_SMOKE_SKIP_AUTH_REFRESH=1 \
    SKYBRIDGE_SMOKE_REQUIRE_STREAM=1 \
    SKYBRIDGE_SMOKE_SYNTHETIC_SCREEN=1 \
    SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1 \
    SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS=20 \
    SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1 \
    SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
    "$MAC_APP_BIN" >"$MAC_STDOUT" 2>&1 &
  else
    SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
    SKYBRIDGE_AUTH_SESSION_FILE="$AUTH_SESSION_FILE" \
    SB_PQC_PREFERRED_SUITE=xwing \
    SKYBRIDGE_DEVICE_ID="$ROUND_MAC_DEVICE_ID" \
    SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
    SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
    SKYBRIDGE_SMOKE_SUPABASE_URL="$SUPABASE_URL" \
    SKYBRIDGE_SMOKE_SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
    SKYBRIDGE_STUN_URL="" \
    SKYBRIDGE_TURN_URLS="" \
    SKYBRIDGE_SMOKE_ROLE=mac-host \
    SKYBRIDGE_SMOKE_STATUS_FILE="$MAC_STATUS" \
    SKYBRIDGE_SMOKE_CODE_FILE="$MAC_CODE" \
    SKYBRIDGE_SMOKE_TOKEN_FILE="$MAC_TOKEN" \
    SKYBRIDGE_SMOKE_TENANT_FILE="$MAC_TENANT" \
    SKYBRIDGE_SMOKE_SKIP_AUTH_REFRESH=1 \
    SKYBRIDGE_SMOKE_PQC_REPORT_FILE="$MAC_PQC_REPORT" \
    SKYBRIDGE_SMOKE_SYNTHETIC_SCREEN=1 \
    SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1 \
    SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS=10 \
    SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
    "$MAC_APP_BIN" >"$MAC_STDOUT" 2>&1 &
  fi
  MAC_PID="$!"

  wait_for_file_nonempty "$MAC_CODE" 60 "macOS connection code"
  wait_for_file_nonempty "$MAC_TOKEN" 60 "macOS access token"
  wait_for_file_nonempty "$MAC_TENANT" 60 "macOS tenant id"
  if [[ "$SMOKE_SCENARIO" == "xwing-only" ]]; then
    wait_for_file_nonempty "$MAC_PQC_REPORT" 60 "macOS PQC report"
    load_pqc_report "$MAC_PQC_REPORT"
  fi
  CONNECTION_CODE="$(tr -d '\r\n' < "$MAC_CODE")"
  ACCESS_TOKEN="$(tr -d '\r\n' < "$MAC_TOKEN")"
  TENANT_ID="$(tr -d '\r\n' < "$MAC_TENANT")"
  if [[ -z "$CONNECTION_CODE" ]]; then
    echo "macOS smoke produced an empty connection code" >&2
    exit 1
  fi
  if [[ -z "$ACCESS_TOKEN" ]]; then
    echo "macOS smoke produced an empty access token" >&2
    exit 1
  fi
  if [[ -z "$TENANT_ID" ]]; then
    echo "macOS smoke produced an empty tenant id" >&2
    exit 1
  fi

  if [[ "$SMOKE_SCENARIO" == "bootstrap-rekey" ]]; then
    SIMCTL_CHILD_SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
    SIMCTL_CHILD_SKYBRIDGE_DEVICE_ID="$ROUND_IOS_DEVICE_ID" \
    SIMCTL_CHILD_SKYBRIDGE_ACCESS_TOKEN="$ACCESS_TOKEN" \
    SIMCTL_CHILD_SKYBRIDGE_TENANT_ID="$TENANT_ID" \
    SIMCTL_CHILD_SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
    SIMCTL_CHILD_SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
    SIMCTL_CHILD_SKYBRIDGE_STUN_URL="" \
    SIMCTL_CHILD_SKYBRIDGE_TURN_URLS="" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_ROLE=ios-client \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_CONNECT_CODE="$CONNECTION_CODE" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_BASENAME" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1 \
    xcrun simctl launch \
      --terminate-running-process \
      --stdout="$IOS_STDOUT" \
      --stderr="$IOS_STDERR" \
      "$SIM_ID" \
      "$IOS_BUNDLE_ID" >/dev/null
  else
    SIMCTL_CHILD_SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
    SIMCTL_CHILD_SB_PQC_PREFERRED_SUITE=xwing \
    SIMCTL_CHILD_SKYBRIDGE_DEVICE_ID="$ROUND_IOS_DEVICE_ID" \
    SIMCTL_CHILD_SKYBRIDGE_ACCESS_TOKEN="$ACCESS_TOKEN" \
    SIMCTL_CHILD_SKYBRIDGE_TENANT_ID="$TENANT_ID" \
    SIMCTL_CHILD_SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
    SIMCTL_CHILD_SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
    SIMCTL_CHILD_SKYBRIDGE_STUN_URL="" \
    SIMCTL_CHILD_SKYBRIDGE_TURN_URLS="" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_ROLE=ios-client \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_CONNECT_CODE="$CONNECTION_CODE" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_BASENAME" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_HANDSHAKE_ONLY=1 \
    SIMCTL_CHILD_SKYBRIDGE_PQC_PEER_DEVICE_ID="$MAC_PQC_DEVICE_ID" \
    SIMCTL_CHILD_SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64="$MAC_PQC_XWING_PUBLIC_KEY_BASE64" \
    SIMCTL_CHILD_SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64" \
    SIMCTL_CHILD_SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64" \
    xcrun simctl launch \
      --terminate-running-process \
      --stdout="$IOS_STDOUT" \
      --stderr="$IOS_STDERR" \
      "$SIM_ID" \
      "$IOS_BUNDLE_ID" >/dev/null
  fi

  IOS_STATUS_PATH=""

  if [[ "$SMOKE_SCENARIO" == "bootstrap-rekey" ]]; then
    wait_for_file_pattern "$MAC_STATUS" 'success session=' "$SMOKE_TIMEOUT_SECONDS" "macOS success"
    wait_for_file_pattern "$IOS_STDOUT" 'success session=.*suite=X-Wing bootstrapRekey=1|success frame=' "$SMOKE_TIMEOUT_SECONDS" "iOS bootstrap rekey success"
    require_file_pattern "$IOS_STDOUT" 'handshake session=.*suite=X25519(-Ed25519)?' "iOS classic bootstrap"
    require_file_pattern "$MAC_STATUS" 'rekey complete suite=X-Wing' "macOS rekey completion"
    require_file_pattern "$IOS_STDOUT" 'rekey complete suite=X-Wing' "iOS rekey completion"
  else
    wait_for_file_pattern "$MAC_STATUS" 'success session=.*suite=X-Wing' "$SMOKE_TIMEOUT_SECONDS" "macOS X-Wing success"
    wait_for_file_pattern "$IOS_STDOUT" 'success session=.*suite=X-Wing handshakeOnly=1' "$SMOKE_TIMEOUT_SECONDS" "iOS X-Wing success"
    require_file_pattern "$MAC_STATUS" 'handshake session=.*suite=X-Wing' "macOS X-Wing handshake"
    require_file_pattern "$IOS_STDOUT" 'handshake session=.*suite=X-Wing' "iOS X-Wing handshake"
    require_file_absent_pattern "$MAC_STATUS" 'suite=X25519' "macOS unexpected classic suite"
    require_file_absent_pattern "$IOS_STDOUT" 'suite=X25519' "iOS unexpected classic suite"
  fi

  echo "   macOS: $(tail -n 1 "$MAC_STATUS")"
  echo "   iOS:   $(tail -n 1 "$IOS_STDOUT")"
done

echo "==> Smoke completed successfully"
echo "    signaling log: $ARTIFACT_DIR/signaling.log"
echo "    mac logs:      $ARTIFACT_DIR/mac_round_*.stdout.log"
echo "    ios logs:      $ARTIFACT_DIR/ios_round_*.stdout.log"
