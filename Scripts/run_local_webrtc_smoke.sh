#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/local_webrtc_smoke_$(date +%Y%m%d_%H%M%S)}"
if [[ "$ARTIFACT_DIR" != /* ]]; then
  ARTIFACT_DIR="$PWD/$ARTIFACT_DIR"
fi
SIGNALING_PORT="${SKYBRIDGE_SMOKE_SIGNALING_PORT:-18443}"
SMOKE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-120}"
SMOKE_ROUNDS="${SKYBRIDGE_SMOKE_ROUNDS:-3}"
SMOKE_SCENARIO="${SKYBRIDGE_SMOKE_SCENARIO:-bootstrap-rekey}"
SMOKE_SIGNALING_FLAVOR="${SKYBRIDGE_SMOKE_SIGNALING_FLAVOR:-registry}"
SMOKE_REQUIRE_AUDIO="${SKYBRIDGE_SMOKE_REQUIRE_AUDIO:-0}"
SMOKE_MIN_FPS="${SKYBRIDGE_SMOKE_MIN_FPS:-0}"
SMOKE_AUTH_SESSION_SOURCE_FILE="${SKYBRIDGE_SMOKE_AUTH_SESSION_FILE:-${SKYBRIDGE_AUTH_SESSION_FILE:-}}"
SMOKE_SYNTHETIC_OPUS_TONE="${SKYBRIDGE_SMOKE_SYNTHETIC_OPUS_TONE:-0}"
SMOKE_HOLD_AFTER_SUCCESS_SECONDS="${SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS:-0}"
if [[ "${SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE:-0}" == "1" && "$SMOKE_HOLD_AFTER_SUCCESS_SECONDS" == "0" ]]; then
  SMOKE_HOLD_AFTER_SUCCESS_SECONDS=5
fi
SMOKE_EXTREME_MEDIA=0
if [[ "${SKYBRIDGE_SMOKE_EXTREME_MEDIA:-0}" == "1" \
   || "${SKYBRIDGE_WEBRTC_EXTREME_MEDIA:-0}" == "1" \
   || "${SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK:-0}" == "1" ]]; then
  SMOKE_EXTREME_MEDIA=1
fi
SMOKE_MEDIA_GATE=0
if [[ "$SMOKE_REQUIRE_AUDIO" == "1" || "$SMOKE_MIN_FPS" != "0" || "$SMOKE_EXTREME_MEDIA" == "1" ]]; then
  SMOKE_MEDIA_GATE=1
fi
SMOKE_SYNTHETIC_SCREEN=1
if [[ "$SMOKE_EXTREME_MEDIA" == "1" ]]; then
  SMOKE_SYNTHETIC_SCREEN=0
fi
SMOKE_SKIP_SUPABASE_AUTH=0
if [[ "$SMOKE_SIGNALING_FLAVOR" == "compat" ]]; then
  SMOKE_SKIP_SUPABASE_AUTH=1
fi
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

copy_round_diagnostics() {
  copy_recent_media_diagnostics
  if [[ -n "${IOS_STATUS_BASENAME:-}" ]]; then
    copy_ios_smoke_diagnostics "$IOS_STATUS_BASENAME"
  fi
}

cleanup() {
  copy_round_diagnostics
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
    if [[ -n "${MAC_STATUS:-}" && -f "$MAC_STATUS" ]] && grep -q 'failed stage=' "$MAC_STATUS"; then
      echo "macOS smoke failed while waiting for ${label}: $(tail -n 1 "$MAC_STATUS")" >&2
      return 1
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
    if [[ "$path" == "${MAC_STATUS:-}" && -f "$path" ]] && grep -q 'failed stage=' "$path"; then
      echo "macOS smoke failed while waiting for ${label}: $(tail -n 1 "$path")" >&2
      return 1
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

resolve_ios_artifact_path() {
  local basename="$1"
  local root="$HOME/Library/Developer/CoreSimulator/Devices/${SIM_ID}/data/Containers/Data/Application"
  find "$root" -name "$basename" -print 2>/dev/null | tail -n 1
}

copy_ios_artifact_file() {
  local basename="$1"
  local destination="$2"
  local source_path
  source_path="$(resolve_ios_artifact_path "$basename" || true)"
  if [[ -z "$source_path" || ! -f "$source_path" ]]; then
    echo "Unable to resolve iOS artifact ${basename}" >&2
    return 1
  fi
  cp "$source_path" "$destination"
}

copy_recent_media_diagnostics() {
  local media_log_dir="$HOME/Library/Logs/SkyBridge"
  if [[ -d "$media_log_dir" ]]; then
    find "$media_log_dir" -maxdepth 1 -name 'webrtc-media-*.jsonl' -print0 2>/dev/null \
      | xargs -0 -I{} cp "{}" "$ARTIFACT_DIR/" 2>/dev/null || true
  fi
}

copy_ios_smoke_diagnostics() {
  local basename="$1"
  local root="$HOME/Library/Developer/CoreSimulator/Devices/${SIM_ID}/data/Containers/Data/Application"
  find "$root" \( -name "${basename}" -o -name "${basename}.trace.log" -o -name "${basename}.webrtc-media.jsonl" \) -print0 2>/dev/null \
    | xargs -0 -I{} cp "{}" "$ARTIFACT_DIR/" 2>/dev/null || true
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
    if [[ -n "$resolved_path" && -f "$resolved_path" ]] && grep -q 'failed stage=' "$resolved_path"; then
      echo "iOS smoke failed while waiting for ${label}: $(tail -n 1 "$resolved_path")" >&2
      IOS_STATUS_PATH="$resolved_path"
      return 1
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${resolved_path:-<unresolved>}" >&2
      return 1
    fi
    sleep 1
  done
}

run_webrtc_media_doctor() {
  local round="$1"
  local session_id="$2"
  local output="$ARTIFACT_DIR/webrtc_media_doctor_round_${round}.json"
  local last_error="$ARTIFACT_DIR/webrtc_media_doctor_round_${round}.stderr.log"
  local require_audio_arg=false
  local min_fps_arg="$SMOKE_MIN_FPS"
  if [[ "$SMOKE_REQUIRE_AUDIO" == "1" ]]; then
    require_audio_arg=true
  fi
  if [[ "$min_fps_arg" == "0" ]]; then
    if [[ "$SMOKE_EXTREME_MEDIA" == "1" ]]; then
      min_fps_arg="59.01"
    else
      min_fps_arg="1"
    fi
  fi
  if [[ -z "$session_id" ]]; then
    echo "Missing session id for WebRTC media doctor" >&2
    return 1
  fi
  local started_at
  started_at="$(date +%s)"
  while true; do
    copy_round_diagnostics
    if cargo run --quiet --manifest-path "$ROOT_DIR/rust/Cargo.toml" -p skybridge -- \
      doctor webrtc-media \
      --session-id "$session_id" \
      --artifact-dir "$ARTIFACT_DIR" \
      --min-fps "$min_fps_arg" \
      --require-audio "$require_audio_arg" \
      --json > "$output" 2>"$last_error" && python3 - "$output" >"$last_error" 2>&1 <<'PY'
import json, sys
report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
warnings = [
    c for c in report.get("checks", [])
    if not c.get("ok") and c.get("severity") != "error"
]
for check in warnings:
    print(f"WebRTC media doctor warning: {check.get('name')}: {check.get('detail')}", file=sys.stderr)
failed = [
    c for c in report.get("checks", [])
    if not c.get("ok") and c.get("severity") == "error"
]
if failed:
    for check in failed:
        print(f"WebRTC media doctor failed: {check.get('name')}: {check.get('detail')}", file=sys.stderr)
    raise SystemExit(1)
PY
    then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= SMOKE_TIMEOUT_SECONDS )); then
      echo "WebRTC media doctor did not pass within ${SMOKE_TIMEOUT_SECONDS}s (session=${session_id}, min_fps=${min_fps_arg}, require_audio=${require_audio_arg})" >&2
      cat "$last_error" >&2 || true
      return 1
    fi
    sleep 2
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

load_ios_pqc_report() {
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

  IOS_PQC_DEVICE_ID="$(printf '%s\n' "$parsed" | sed -n '1p')"
  IOS_PQC_XWING_PUBLIC_KEY_BASE64="$(printf '%s\n' "$parsed" | sed -n '2p')"
  IOS_PQC_MLKEM768_PUBLIC_KEY_BASE64="$(printf '%s\n' "$parsed" | sed -n '3p')"
  IOS_PQC_MLKEM768FS_PUBLIC_KEY_BASE64="$(printf '%s\n' "$parsed" | sed -n '4p')"

  if [[ -z "$IOS_PQC_DEVICE_ID" || -z "$IOS_PQC_XWING_PUBLIC_KEY_BASE64" ]]; then
    echo "iOS PQC report is missing required deviceId/X-Wing key: ${report_path}" >&2
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
  python3 - "$AUTH_SESSION_FILE" "$cache_path" "$SMOKE_AUTH_SESSION_SOURCE_FILE" <<'PY'
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
source_path_raw = str(sys.argv[3] or "").strip()
source_path = pathlib.Path(source_path_raw).expanduser() if source_path_raw else None
minimum_lifetime_seconds = 300

def decode_b64url_json(segment, label):
    try:
        padded = segment + "=" * ((4 - len(segment) % 4) % 4)
        decoded = base64.urlsafe_b64decode(padded)
    except Exception as exc:
        return None, f"{label} segment is not valid base64url ({exc})"
    try:
        value = json.loads(decoded)
    except Exception as exc:
        return None, f"{label} segment is not JSON ({exc})"
    if not isinstance(value, dict):
        return None, f"{label} segment is not a JSON object"
    return value, None

def jwt_validation_error(token, require_fresh):
    parts = str(token or "").strip().split(".")
    if len(parts) != 3:
        return f"expected 3 JWT segments, found {len(parts)}"
    for label, segment in zip(("header", "payload", "signature"), parts):
        if not segment:
            return f"{label} segment is empty"
    header, header_error = decode_b64url_json(parts[0], "header")
    if header_error:
        return header_error
    payload, payload_error = decode_b64url_json(parts[1], "payload")
    if payload_error:
        return payload_error
    alg = str(header.get("alg") or "").strip()
    if not alg:
        return "JWT header is missing alg"
    if alg.lower() == "none":
        return "JWT header alg=none is a compatibility smoke token, not a signed Supabase JWT"
    if require_fresh:
        exp = payload.get("exp")
        if not isinstance(exp, (int, float)) or isinstance(exp, bool):
            return "JWT payload is missing numeric exp"
        seconds_remaining = float(exp) - time.time()
        if seconds_remaining <= minimum_lifetime_seconds:
            return (
                "JWT expires too soon for registry smoke "
                f"({seconds_remaining:.0f}s remaining, need >{minimum_lifetime_seconds}s)"
            )
    return None

def token_is_fresh(session):
    token = str(session.get("accessToken") or "").strip()
    return bool(token) and jwt_validation_error(token, require_fresh=True) is None

def decoded_jwt_payload(token):
    parts = str(token or "").strip().split(".")
    if len(parts) < 2:
        return {}
    payload, error = decode_b64url_json(parts[1], "payload")
    return {} if error else payload

def first_claim(payload, *paths):
    for path in paths:
        value = payload
        for key in path:
            if not isinstance(value, dict):
                value = None
                break
            value = value.get(key)
        candidate = str(value or "").strip()
        if candidate and candidate != "None":
            return candidate
    return ""

def load_environment_session():
    token = (
        str(os.environ.get("SKYBRIDGE_BEARER_TOKEN") or "").strip()
        or str(os.environ.get("SKYBRIDGE_ACCESS_TOKEN") or "").strip()
    )
    if not token:
        return None
    jwt_error = jwt_validation_error(token, require_fresh=False)
    if jwt_error:
        raise SystemExit(
            "Environment Supabase access token is not a signed Supabase JWT: "
            f"{jwt_error}"
        )
    payload = decoded_jwt_payload(token)
    user_id = (
        str(os.environ.get("SKYBRIDGE_USER_ID") or "").strip()
        or first_claim(payload, ("sub",))
        or first_claim(payload, ("user_id",), ("userId",))
        or "smoke-user"
    )
    nebula_id = (
        str(os.environ.get("SKYBRIDGE_NEBULA_ID") or "").strip()
        or first_claim(
            payload,
            ("app_metadata", "tenant_id"),
            ("app_metadata", "tenantId"),
            ("user_metadata", "tenant_id"),
            ("user_metadata", "tenantId"),
            ("tenant_id",),
            ("tenantId",),
            ("sub",),
        )
    )
    display_name = str(os.environ.get("SKYBRIDGE_DISPLAY_NAME") or "").strip() or "Smoke Host"
    refresh_token = str(os.environ.get("SKYBRIDGE_REFRESH_TOKEN") or "").strip()
    return {
        "accessToken": token,
        "refreshToken": refresh_token,
        "userIdentifier": user_id,
        "nebulaId": nebula_id,
        "displayName": display_name,
        "issuedAt": time.time(),
    }

def load_candidate(path, label, fatal_invalid=False):
    if path is None:
        return None
    if not path.exists():
        message = f"{label} auth session file does not exist: {path}"
        if fatal_invalid:
            raise SystemExit(message)
        return None
    try:
        session = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        message = f"{label} auth session is not readable JSON: {exc}"
        if fatal_invalid:
            raise SystemExit(message)
        print(f"Warning: ignoring {message}", file=sys.stderr)
        return None
    jwt_error = jwt_validation_error(str(session.get("accessToken") or ""), require_fresh=False)
    if jwt_error:
        message = f"{label} auth session is not a signed Supabase JWT: {jwt_error}"
        if fatal_invalid:
            raise SystemExit(message)
        print(f"Warning: ignoring {message}", file=sys.stderr)
        return None
    return session

cached_session = None
if source_path is not None:
    cached_session = load_candidate(source_path, f"explicit source file {source_path}", fatal_invalid=True)
    if cached_session is not None and token_is_fresh(cached_session):
        output_path.write_text(json.dumps(cached_session), encoding="utf-8")
        raise SystemExit(0)
else:
    env_session = load_environment_session()
    if env_session is not None:
        cached_session = env_session
        if token_is_fresh(env_session):
            output_path.write_text(json.dumps(env_session), encoding="utf-8")
            raise SystemExit(0)
    for candidate, label in ((output_path, "artifact"), (cache_path, "cache")):
        cached = load_candidate(candidate, label)
        if cached is None:
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

access_token = str(session.get("accessToken") or "").strip()
jwt_error = jwt_validation_error(access_token, require_fresh=True)
if jwt_error:
    raise SystemExit(
        "Auth session accessToken is not a usable signed Supabase JWT for registry smoke: "
        f"{jwt_error}. Refresh or log in before running local WebRTC smoke."
    )

output_path.write_text(json.dumps(session), encoding="utf-8")
cache_path.write_text(json.dumps(session), encoding="utf-8")
PY
}

export_compat_smoke_auth_session() {
  AUTH_SESSION_FILE="$ARTIFACT_DIR/smoke_auth_session.json"
  python3 - "$AUTH_SESSION_FILE" <<'PY'
import base64
import json
import pathlib
import sys
import time

output_path = pathlib.Path(sys.argv[1])

def b64url_json(value):
    return base64.urlsafe_b64encode(
        json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")
    ).rstrip(b"=").decode("ascii")

tenant_id = "local-smoke-tenant"
user_id = "local-smoke-user"
header = b64url_json({"alg": "none", "typ": "JWT"})
payload = b64url_json({
    "sub": user_id,
    "tenant_id": tenant_id,
    "app_metadata": {"tenant_id": tenant_id},
    "user_metadata": {"tenant_id": tenant_id},
    "iat": int(time.time()),
    "exp": int(time.time()) + 3600,
})
signature = base64.urlsafe_b64encode(b"local-smoke").rstrip(b"=").decode("ascii")
session = {
    "accessToken": f"{header}.{payload}.{signature}",
    "refreshToken": "",
    "userIdentifier": user_id,
    "nebulaId": tenant_id,
    "displayName": "Local Smoke",
    "issuedAt": time.time(),
}
output_path.write_text(json.dumps(session), encoding="utf-8")
PY
}

validate_signaling_flavor() {
  case "$SMOKE_SIGNALING_FLAVOR" in
    registry|compat)
      ;;
    *)
      echo "Unsupported smoke signaling flavor: ${SMOKE_SIGNALING_FLAVOR}" >&2
      exit 1
      ;;
  esac
  if [[ "$SMOKE_SIGNALING_FLAVOR" == "compat" && "$SMOKE_REQUIRE_AUDIO" == "1" ]]; then
    echo "Compat signaling smoke cannot validate realtime audio relay; use registry mode with valid auth for audio." >&2
    exit 1
  fi
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
validate_signaling_flavor

echo "==> Artifacts: ${ARTIFACT_DIR}"
echo "==> Simulator: ${SIM_ID}"
echo "==> Scenario: ${SMOKE_SCENARIO}"
echo "==> Signaling: ${SMOKE_SIGNALING_FLAVOR}"
echo "==> Extreme media: ${SMOKE_EXTREME_MEDIA} syntheticScreen=${SMOKE_SYNTHETIC_SCREEN}"

echo "==> Exporting smoke auth session"
if [[ "$SMOKE_SIGNALING_FLAVOR" == "compat" ]]; then
  export_compat_smoke_auth_session
else
  require_registry_env
  if ! export_smoke_auth_session; then
    if [[ "$SMOKE_MEDIA_GATE" == "1" ]]; then
      echo "Failed to export a valid smoke auth session for media-gated WebRTC smoke." >&2
      echo "Registry media smoke requires a signed Supabase user JWT; log in to the macOS app, set SKYBRIDGE_SMOKE_AUTH_SESSION_FILE to an AuthSession JSON, or provide SKYBRIDGE_ACCESS_TOKEN/SKYBRIDGE_REFRESH_TOKEN. Compat alg=none tokens are rejected." >&2
      exit 1
    fi
    echo "Warning: failed to export smoke auth session; falling back to host-side session lookup." >&2
    AUTH_SESSION_FILE=""
  fi
fi

echo "==> Building macOS smoke host"
MAC_BUILD_LOG="$ARTIFACT_DIR/macos-build.log"
SMOKE_BUILD_DIR="${SKYBRIDGE_SMOKE_BUILD_DIR:-$ROOT_DIR/.build/local-webrtc-smoke}"
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

echo "==> Starting local signaling server"
kill_listener_on_port "$SIGNALING_PORT"
pushd "$ROOT_DIR/Server/skybridge-signaling" >/dev/null
if [[ "$SMOKE_SIGNALING_FLAVOR" == "compat" ]]; then
  HOST=127.0.0.1 \
  PORT="$SIGNALING_PORT" \
  PUBLIC_HOST="127.0.0.1:${SIGNALING_PORT}" \
  TURN_URIS="turn:127.0.0.1:3478?transport=udp" \
  node local_compat_server.js >"$ARTIFACT_DIR/signaling.log" 2>&1 &
else
  HOST=127.0.0.1 \
  PORT="$SIGNALING_PORT" \
  TURN_ENFORCE_API_KEY=false \
  SUPABASE_TIMEOUT_MS=20000 \
  TURN_SHARED_SECRET=skybridge-local-smoke \
  TURN_URIS="turn:127.0.0.1:3478?transport=udp" \
  MEDIA_RELAY_ENABLED=1 \
  MEDIA_RELAY_HOST=127.0.0.1 \
  MEDIA_RELAY_PUBLIC_HOST=127.0.0.1 \
  MEDIA_RELAY_UDP_PORT=0 \
  MEDIA_RELAY_TOKEN_SECRET=skybridge-local-smoke-media-relay \
  REQUIRE_SHARED_STATE_FOR_PUBLIC_CAPABILITIES=false \
  SIGNALING_ALLOW_BOOTSTRAP_TENANT_POLICY=1 \
  SIGNALING_ALLOW_BOOTSTRAP_DEVICE_AUTH=1 \
  SIGNALING_BOOTSTRAP_TENANT_MODE=user_id \
  node server.js >"$ARTIFACT_DIR/signaling.log" 2>&1 &
fi
SIGNALING_PID="$!"
popd >/dev/null
if [[ "$SMOKE_SIGNALING_FLAVOR" == "compat" ]]; then
  wait_for_http_ok "${SIGNALING_SERVER_URL}/health" 20
else
  wait_for_http_ok "${SIGNALING_SERVER_URL}/healthz" 20
fi

for round in $(seq 1 "$SMOKE_ROUNDS"); do
  echo "==> Smoke round ${round}/${SMOKE_ROUNDS}"

  MAC_STATUS="$ARTIFACT_DIR/mac_round_${round}.status.log"
  MAC_CODE="$ARTIFACT_DIR/mac_round_${round}.code"
  MAC_TOKEN="$ARTIFACT_DIR/mac_round_${round}.token"
  MAC_TENANT="$ARTIFACT_DIR/mac_round_${round}.tenant"
  MAC_PQC_REPORT="$ARTIFACT_DIR/mac_round_${round}.pqc.json"
  MAC_STDOUT="$ARTIFACT_DIR/mac_round_${round}.stdout.log"
  IOS_STATUS_BASENAME="ios_round_${round}.status.log"
  IOS_PREFLIGHT_STATUS_BASENAME="ios_round_${round}.preflight.status.log"
  IOS_PQC_REPORT_BASENAME="ios_round_${round}.pqc.json"
  IOS_PQC_REPORT="$ARTIFACT_DIR/$IOS_PQC_REPORT_BASENAME"
  IOS_PREFLIGHT_STDOUT="$ARTIFACT_DIR/ios_round_${round}.preflight.stdout.log"
  IOS_PREFLIGHT_STDERR="$ARTIFACT_DIR/ios_round_${round}.preflight.stderr.log"
  IOS_STATUS_PATH=""
  IOS_STDOUT="$ARTIFACT_DIR/ios_round_${round}.stdout.log"
  IOS_STDERR="$ARTIFACT_DIR/ios_round_${round}.stderr.log"
  ROUND_MAC_DEVICE_ID="${MAC_DEVICE_ID}-${round}"
  ROUND_IOS_DEVICE_ID="${IOS_DEVICE_ID}-${round}"

  rm -f "$MAC_STATUS" "$MAC_CODE" "$MAC_TOKEN" "$MAC_TENANT" "$MAC_PQC_REPORT" "$MAC_STDOUT" \
    "$IOS_STATUS_PATH" "$ARTIFACT_DIR/$IOS_PREFLIGHT_STATUS_BASENAME" \
    "$ARTIFACT_DIR/$IOS_PREFLIGHT_STATUS_BASENAME.trace.log" \
    "$IOS_PQC_REPORT" "$IOS_PREFLIGHT_STDOUT" "$IOS_PREFLIGHT_STDERR" "$IOS_STDOUT" "$IOS_STDERR"

  xcrun simctl terminate "$SIM_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -n "${MAC_PID}" ]]; then
    kill "${MAC_PID}" >/dev/null 2>&1 || true
    wait "${MAC_PID}" >/dev/null 2>&1 || true
    MAC_PID=""
  fi
  pkill -x LocalWebRTCSmokeHost >/dev/null 2>&1 || true

  if [[ "$SMOKE_SCENARIO" == "xwing-only" ]]; then
    SIMCTL_CHILD_SKYBRIDGE_DEVICE_ID="$ROUND_IOS_DEVICE_ID" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_ROLE=ios-client \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_PREFLIGHT_STATUS_BASENAME" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_PQC_REPORT_BASENAME="$IOS_PQC_REPORT_BASENAME" \
    xcrun simctl launch \
      --terminate-running-process \
      --stdout="$IOS_PREFLIGHT_STDOUT" \
      --stderr="$IOS_PREFLIGHT_STDERR" \
      "$SIM_ID" \
      "$IOS_BUNDLE_ID" >/dev/null
    wait_for_ios_status_pattern "$IOS_PREFLIGHT_STATUS_BASENAME" 'pqc-report device=.* keys=' 60 "iOS PQC preflight report"
    copy_ios_smoke_diagnostics "$IOS_PREFLIGHT_STATUS_BASENAME"
    copy_ios_artifact_file "$IOS_PQC_REPORT_BASENAME" "$IOS_PQC_REPORT"
    xcrun simctl terminate "$SIM_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
    load_ios_pqc_report "$IOS_PQC_REPORT"
  fi

  if [[ "$SMOKE_SCENARIO" == "bootstrap-rekey" ]]; then
    SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
    SKYBRIDGE_AUTH_SESSION_FILE="$AUTH_SESSION_FILE" \
    SKYBRIDGE_DEVICE_ID="$ROUND_MAC_DEVICE_ID" \
    SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
    SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
    SKYBRIDGE_SMOKE_SUPABASE_URL="${SUPABASE_URL:-}" \
    SKYBRIDGE_SMOKE_SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}" \
    SKYBRIDGE_SMOKE_SKIP_SUPABASE_AUTH="$SMOKE_SKIP_SUPABASE_AUTH" \
    SKYBRIDGE_STUN_URL="" \
    SKYBRIDGE_TURN_URLS="" \
    SKYBRIDGE_SMOKE_ROLE=mac-host \
    SKYBRIDGE_SMOKE_STATUS_FILE="$MAC_STATUS" \
    SKYBRIDGE_SMOKE_CODE_FILE="$MAC_CODE" \
    SKYBRIDGE_SMOKE_TOKEN_FILE="$MAC_TOKEN" \
    SKYBRIDGE_SMOKE_TENANT_FILE="$MAC_TENANT" \
    SKYBRIDGE_SMOKE_SKIP_AUTH_REFRESH=1 \
    SKYBRIDGE_SMOKE_REQUIRE_STREAM=1 \
    SKYBRIDGE_SMOKE_SYNTHETIC_SCREEN="$SMOKE_SYNTHETIC_SCREEN" \
    SKYBRIDGE_SMOKE_SYNTHETIC_OPUS_TONE="$SMOKE_SYNTHETIC_OPUS_TONE" \
    SKYBRIDGE_SMOKE_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
    SKYBRIDGE_WEBRTC_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
    SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK="$SMOKE_EXTREME_MEDIA" \
    SKYBRIDGE_SMOKE_ALLOW_CLASSIC_MEDIA_SUCCESS="$SMOKE_MEDIA_GATE" \
    SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1 \
    SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS="${SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS:-20}" \
    SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1 \
    SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
    "$MAC_APP_BIN" >"$MAC_STDOUT" 2>&1 &
  else
    SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
    SKYBRIDGE_AUTH_SESSION_FILE="$AUTH_SESSION_FILE" \
    SB_PQC_PREFERRED_SUITE=xwing \
    SKYBRIDGE_DEVICE_ID="$ROUND_MAC_DEVICE_ID" \
    SKYBRIDGE_PQC_PEER_DEVICE_ID="$IOS_PQC_DEVICE_ID" \
    SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64="$IOS_PQC_XWING_PUBLIC_KEY_BASE64" \
    SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64="$IOS_PQC_MLKEM768_PUBLIC_KEY_BASE64" \
    SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64="$IOS_PQC_MLKEM768FS_PUBLIC_KEY_BASE64" \
    SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
    SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
    SKYBRIDGE_SMOKE_SUPABASE_URL="${SUPABASE_URL:-}" \
    SKYBRIDGE_SMOKE_SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-}" \
    SKYBRIDGE_SMOKE_SKIP_SUPABASE_AUTH="$SMOKE_SKIP_SUPABASE_AUTH" \
    SKYBRIDGE_STUN_URL="" \
    SKYBRIDGE_TURN_URLS="" \
    SKYBRIDGE_SMOKE_ROLE=mac-host \
    SKYBRIDGE_SMOKE_STATUS_FILE="$MAC_STATUS" \
    SKYBRIDGE_SMOKE_CODE_FILE="$MAC_CODE" \
    SKYBRIDGE_SMOKE_TOKEN_FILE="$MAC_TOKEN" \
    SKYBRIDGE_SMOKE_TENANT_FILE="$MAC_TENANT" \
    SKYBRIDGE_SMOKE_SKIP_AUTH_REFRESH=1 \
    SKYBRIDGE_SMOKE_PQC_REPORT_FILE="$MAC_PQC_REPORT" \
    SKYBRIDGE_SMOKE_SYNTHETIC_SCREEN="$SMOKE_SYNTHETIC_SCREEN" \
    SKYBRIDGE_SMOKE_SYNTHETIC_OPUS_TONE="$SMOKE_SYNTHETIC_OPUS_TONE" \
    SKYBRIDGE_SMOKE_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
    SKYBRIDGE_WEBRTC_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
    SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK="$SMOKE_EXTREME_MEDIA" \
    SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1 \
    SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS="$SMOKE_HOLD_AFTER_SUCCESS_SECONDS" \
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
	    SIMCTL_CHILD_SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME="${SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME:-Smoke Remote Viewer}" \
	    SIMCTL_CHILD_SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID="$TENANT_ID" \
	    SIMCTL_CHILD_SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
	    SIMCTL_CHILD_SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
	    SIMCTL_CHILD_SKYBRIDGE_STUN_URL="" \
    SIMCTL_CHILD_SKYBRIDGE_TURN_URLS="" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_ROLE=ios-client \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_CONNECT_CODE="$CONNECTION_CODE" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_BASENAME" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_REQUIRE_AUDIO="$SMOKE_REQUIRE_AUDIO" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_REQUIRE_NATIVE_VIDEO="$SMOKE_MEDIA_GATE" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
    SIMCTL_CHILD_SKYBRIDGE_WEBRTC_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
    SIMCTL_CHILD_SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK="$SMOKE_EXTREME_MEDIA" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1 \
    xcrun simctl launch \
      --terminate-running-process \
      --stdout="$IOS_STDOUT" \
      --stderr="$IOS_STDERR" \
      "$SIM_ID" \
      "$IOS_BUNDLE_ID" >/dev/null
  else
    SIMCTL_CHILD_SB_PQC_PREFERRED_SUITE=xwing \
	    SIMCTL_CHILD_SKYBRIDGE_DEVICE_ID="$ROUND_IOS_DEVICE_ID" \
	    SIMCTL_CHILD_SKYBRIDGE_ACCESS_TOKEN="$ACCESS_TOKEN" \
	    SIMCTL_CHILD_SKYBRIDGE_TENANT_ID="$TENANT_ID" \
	    SIMCTL_CHILD_SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME="${SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME:-Smoke Remote Viewer}" \
	    SIMCTL_CHILD_SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID="$TENANT_ID" \
	    SIMCTL_CHILD_SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
	    SIMCTL_CHILD_SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
	    SIMCTL_CHILD_SKYBRIDGE_STUN_URL="" \
    SIMCTL_CHILD_SKYBRIDGE_TURN_URLS="" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_ROLE=ios-client \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_CONNECT_CODE="$CONNECTION_CODE" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_BASENAME" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_REQUIRE_AUDIO="$SMOKE_REQUIRE_AUDIO" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
    SIMCTL_CHILD_SKYBRIDGE_WEBRTC_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
    SIMCTL_CHILD_SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK="$SMOKE_EXTREME_MEDIA" \
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
    if [[ "$SMOKE_MEDIA_GATE" == "1" ]]; then
      wait_for_ios_status_pattern "$IOS_STATUS_BASENAME" 'success frame=.*transport=webrtc-native|native-receiver-frame' "$SMOKE_TIMEOUT_SECONDS" "iOS native media frame success"
      wait_for_ios_status_pattern "$IOS_STATUS_BASENAME" 'handshake session=.*suite=X25519(-Ed25519)?' "$SMOKE_TIMEOUT_SECONDS" "iOS classic bootstrap"
      require_file_pattern "$MAC_STATUS" 'success session=.*stream=true' "macOS media stream evidence"
    else
      wait_for_file_pattern "$IOS_STDOUT" 'success session=.*suite=X-Wing bootstrapRekey=1|success frame=' "$SMOKE_TIMEOUT_SECONDS" "iOS bootstrap rekey success"
      require_file_pattern "$IOS_STDOUT" 'handshake session=.*suite=X25519(-Ed25519)?' "iOS classic bootstrap"
      require_file_pattern "$MAC_STATUS" 'rekey complete suite=X-Wing' "macOS rekey completion"
      require_file_pattern "$IOS_STDOUT" 'rekey complete suite=X-Wing' "iOS rekey completion"
    fi
  else
    wait_for_file_pattern "$MAC_STATUS" 'success session=.*suite=X-Wing' "$SMOKE_TIMEOUT_SECONDS" "macOS X-Wing success"
    wait_for_file_pattern "$IOS_STDOUT" 'success session=.*suite=X-Wing handshakeOnly=1' "$SMOKE_TIMEOUT_SECONDS" "iOS X-Wing success"
    require_file_pattern "$MAC_STATUS" 'handshake session=.*suite=X-Wing' "macOS X-Wing handshake"
    require_file_pattern "$IOS_STDOUT" 'handshake session=.*suite=X-Wing' "iOS X-Wing handshake"
    require_file_absent_pattern "$MAC_STATUS" 'suite=X25519' "macOS unexpected classic suite"
    require_file_absent_pattern "$IOS_STDOUT" 'suite=X25519' "iOS unexpected classic suite"
  fi

  if [[ "${SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE:-0}" == "1" ]]; then
    wait_for_file_pattern "$MAC_STATUS" 'remoteControlNoticeDisconnected .*transport=webrtc' 15 "macOS remote-control notice disconnect"
    if [[ -n "${MAC_PID}" ]]; then
      wait "${MAC_PID}"
      MAC_PID=""
    fi
  fi

  ROUND_SESSION_ID="$(grep -Eo 'success session=[^ ]+' "$MAC_STATUS" 2>/dev/null | tail -n 1 | cut -d= -f2 || true)"
  if [[ "$SMOKE_REQUIRE_AUDIO" == "1" ]]; then
    wait_for_ios_status_pattern "$IOS_STATUS_BASENAME.trace.log" 'audio-rx .*audioRxPlayed=[1-9][0-9]*' "$SMOKE_TIMEOUT_SECONDS" "iOS Opus audio playback"
  fi
  copy_round_diagnostics
  if [[ "$SMOKE_SCENARIO" == "bootstrap-rekey" && ( "$SMOKE_REQUIRE_AUDIO" == "1" || "$SMOKE_MIN_FPS" != "0" || "$SMOKE_EXTREME_MEDIA" == "1" ) ]]; then
    run_webrtc_media_doctor "$round" "$ROUND_SESSION_ID"
  fi

  echo "   macOS: $(tail -n 1 "$MAC_STATUS")"
  echo "   iOS:   $(tail -n 1 "$IOS_STDOUT")"
done

echo "==> Smoke completed successfully"
echo "    signaling log: $ARTIFACT_DIR/signaling.log"
echo "    mac logs:      $ARTIFACT_DIR/mac_round_*.stdout.log"
echo "    ios logs:      $ARTIFACT_DIR/ios_round_*.stdout.log"
