#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/real_device_smoke_redaction.sh"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/real_device_webrtc_smoke_$(date +%Y%m%d_%H%M%S)}"
if [[ "$ARTIFACT_DIR" != /* ]]; then
  ARTIFACT_DIR="$PWD/$ARTIFACT_DIR"
fi
PUBLIC_ARTIFACT_DIR="${SKYBRIDGE_SMOKE_PUBLIC_ARTIFACT_DIR:-${ARTIFACT_DIR}-public-redacted}"

IOS_PROJECT="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_BUNDLE_ID="com.skybridge.compass.ios"
SMOKE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-240}"
SMOKE_SOAK_SECONDS="${SKYBRIDGE_SMOKE_SOAK_SECONDS:-0}"
SMOKE_MIN_FPS="${SKYBRIDGE_SMOKE_MIN_FPS:-30.00}"
SMOKE_REQUIRE_AUDIO="${SKYBRIDGE_SMOKE_REQUIRE_AUDIO:-1}"
SMOKE_AUDIO_BOOTSTRAP_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_AUDIO_BOOTSTRAP_TIMEOUT_SECONDS:-90}"
SMOKE_SYNTHETIC_OPUS_TONE="${SKYBRIDGE_SMOKE_SYNTHETIC_OPUS_TONE:-0}"
SMOKE_EXTREME_MEDIA=1
SMOKE_SYNTHETIC_SCREEN=0
SMOKE_FORCE_RELAY_ICE="${SKYBRIDGE_SMOKE_FORCE_RELAY_ICE:-1}"
MEDIA_RELAY_PREFLIGHT_HOST="${SKYBRIDGE_SMOKE_MEDIA_RELAY_PREFLIGHT_HOST:-82.156.225.30}"
MEDIA_RELAY_PREFLIGHT_PORT="${SKYBRIDGE_SMOKE_MEDIA_RELAY_PREFLIGHT_PORT:-3478}"
MEDIA_RELAY_PREFLIGHT_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_MEDIA_RELAY_PREFLIGHT_TIMEOUT_SECONDS:-3}"
SKIP_MEDIA_RELAY_PREFLIGHT="${SKYBRIDGE_SMOKE_SKIP_MEDIA_RELAY_PREFLIGHT:-0}"
SMOKE_VIDEO_WIDTH="${SKYBRIDGE_SMOKE_VIDEO_WIDTH:-2056}"
SMOKE_VIDEO_HEIGHT="${SKYBRIDGE_SMOKE_VIDEO_HEIGHT:-1329}"
if [[ -n "${SKYBRIDGE_SMOKE_TARGET_FPS:-}" ]]; then
  SMOKE_TARGET_FPS="$SKYBRIDGE_SMOKE_TARGET_FPS"
elif [[ "$SMOKE_MIN_FPS" =~ ^(59|[6-9][0-9]|1[0-1][0-9]|120)(\.|$) ]]; then
  SMOKE_TARGET_FPS=60
else
  SMOKE_TARGET_FPS=32
fi
if [[ "$SMOKE_SOAK_SECONDS" =~ ^[0-9]+$ && "$SMOKE_TIMEOUT_SECONDS" =~ ^[0-9]+$ && "$SMOKE_SOAK_SECONDS" -gt 0 && "$SMOKE_TIMEOUT_SECONDS" -le "$SMOKE_SOAK_SECONDS" ]]; then
  SMOKE_TIMEOUT_SECONDS=$((SMOKE_SOAK_SECONDS + 240))
fi
if [[ "$SMOKE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  DEFAULT_SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS=$((SMOKE_TIMEOUT_SECONDS + 60))
else
  DEFAULT_SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS=300
fi
SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS="${SKYBRIDGE_SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS:-$DEFAULT_SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS}"
PRESERVE_INSTALL="${SKYBRIDGE_SMOKE_PRESERVE_INSTALL:-1}"
ALLOW_PRIVATE_SIGNALING="${SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_PRIVATE_SIGNALING:-0}"
ALLOW_LOCALHOST_SIGNALING="${SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_LOCALHOST_SIGNALING:-0}"
ALLOW_INSECURE_SIGNALING="${SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_INSECURE_SIGNALING:-0}"
ALLOW_UNRESOLVED_SIGNALING="${SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_UNRESOLVED_SIGNALING:-0}"
LAB_RUN="${SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN:-0}"
DEVICECTL_TIMEOUT_SECONDS="${SKYBRIDGE_DEVICECTL_TIMEOUT_SECONDS:-60}"
IOS_COPY_TIMEOUT_SECONDS="${SKYBRIDGE_DEVICECTL_COPY_TIMEOUT_SECONDS:-12}"
IOS_COPY_HARD_TIMEOUT_SECONDS="${SKYBRIDGE_DEVICECTL_COPY_HARD_TIMEOUT_SECONDS:-18}"
RUN_ID="${SKYBRIDGE_SMOKE_WEBRTC_RUN_ID:-$(date +%Y%m%d%H%M%S)}"

DEFAULT_SIGNALING_SERVER_URL="https://api.nebula-technologies.net"
DEFAULT_SIGNALING_WS_URL="wss://api.nebula-technologies.net/ws"
SIGNALING_SERVER_URL="${SKYBRIDGE_SMOKE_SIGNALING_SERVER_URL:-${SKYBRIDGE_SIGNALING_SERVER_URL:-$DEFAULT_SIGNALING_SERVER_URL}}"
SIGNALING_WS_URL="${SKYBRIDGE_SMOKE_SIGNALING_WEBSOCKET_URL:-${SKYBRIDGE_SIGNALING_WEBSOCKET_URL:-$DEFAULT_SIGNALING_WS_URL}}"
STUN_URL="${SKYBRIDGE_STUN_URL:-}"
TURN_URLS="${SKYBRIDGE_TURN_URLS:-}"
CLIENT_VERSION="${SKYBRIDGE_CLIENT_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Sources/SkyBridgeCompassApp/Info.plist" 2>/dev/null || echo "1.0.0")}"
PROTOCOL_VERSION="${SKYBRIDGE_PROTOCOL_VERSION:-1}"

mkdir -p "$ARTIFACT_DIR"

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 1
  fi
}

pick_real_device_id() {
  python3 - <<'PY'
import re
import subprocess

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
    if not stripped or "Mac" in stripped or stripped.endswith("(Simulator)"):
        continue
    match = re.search(r"\(([0-9A-Fa-f-]{20,})\)$", stripped)
    if match:
        print(match.group(1))
        raise SystemExit(0)

raise SystemExit("No connected real iOS device found.")
PY
}

IOS_DEVICE_ID="${SKYBRIDGE_REAL_DEVICE_ID:-}"
MAC_DEVICE_ID="${SKYBRIDGE_SMOKE_MAC_DEVICE_ID:-real-webrtc-mac-${RUN_ID}}"
IOS_LOGICAL_DEVICE_ID="${SKYBRIDGE_SMOKE_IOS_DEVICE_ID:-real-webrtc-ios-${RUN_ID}}"
MAC_TARGET_NAME="${SKYBRIDGE_SMOKE_MAC_TARGET_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"

AUTH_SESSION_SOURCE_FILE="${SKYBRIDGE_SMOKE_AUTH_SESSION_FILE:-${SKYBRIDGE_AUTH_SESSION_FILE:-}}"
AUTH_SESSION_FILE=""
MAC_STATUS="$ARTIFACT_DIR/mac.status.log"
MAC_CODE="$ARTIFACT_DIR/mac.code"
MAC_TOKEN="$ARTIFACT_DIR/mac.token"
MAC_TENANT="$ARTIFACT_DIR/mac.tenant"
MAC_PQC_REPORT="$ARTIFACT_DIR/mac.pqc.json"
MAC_STDOUT="$ARTIFACT_DIR/mac.stdout.log"
MAC_BUILD_LOG="$ARTIFACT_DIR/macos-build.log"
IOS_BUILD_LOG="$ARTIFACT_DIR/ios-build.log"
IOS_STATUS_NAME="ios-real-webrtc-${RUN_ID}.status.log"
IOS_STATUS_LOCAL="$ARTIFACT_DIR/$IOS_STATUS_NAME"
IOS_TRACE_LOCAL="$ARTIFACT_DIR/$IOS_STATUS_NAME.trace.log"
IOS_MEDIA_LOCAL="$ARTIFACT_DIR/$IOS_STATUS_NAME.webrtc-media.jsonl"
IOS_DEVICE_INFO_JSON="$ARTIFACT_DIR/device-info.json"
IOS_LAUNCH_JSON="$ARTIFACT_DIR/ios-launch.json"
MAC_PID=""
IOS_PID=""
DID_LAUNCH_IOS=0
MAC_PQC_DEVICE_ID=""
MAC_PQC_XWING_PUBLIC_KEY_BASE64=""
MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64=""
MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64=""

cleanup() {
  if [[ "$DID_LAUNCH_IOS" == "1" ]]; then
    copy_round_diagnostics || true
    terminate_ios_app || true
  else
    copy_mac_media_diagnostics || true
  fi
  terminate_mac_host || true
}
trap cleanup EXIT

terminate_mac_host() {
  if [[ -z "$MAC_PID" ]]; then
    return 0
  fi
  kill "$MAC_PID" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! kill -0 "$MAC_PID" >/dev/null 2>&1; then
      wait "$MAC_PID" >/dev/null 2>&1 || true
      MAC_PID=""
      return 0
    fi
    sleep 0.25
  done
  kill -KILL "$MAC_PID" >/dev/null 2>&1 || true
  wait "$MAC_PID" >/dev/null 2>&1 || true
  MAC_PID=""
}

terminate_ios_app() {
  if [[ -z "$IOS_PID" ]]; then
    return 0
  fi
  xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device process terminate \
    --device "$IOS_DEVICE_ID" \
    --pid "$IOS_PID" >/dev/null 2>&1 || true
  IOS_PID=""
}

regex_escape() {
  python3 - "$1" <<'PY'
import re
import sys

print(re.escape(sys.argv[1]))
PY
}

validate_remote_signaling_urls() {
  if [[ "$LAB_RUN" != "1" ]]; then
    if [[ "$ALLOW_PRIVATE_SIGNALING" == "1" || "$ALLOW_LOCALHOST_SIGNALING" == "1" || "$ALLOW_INSECURE_SIGNALING" == "1" || "$ALLOW_UNRESOLVED_SIGNALING" == "1" ]]; then
      cat >&2 <<'EOF'
Real-device WebRTC acceptance forbids local/private/insecure/unresolved signaling overrides.

Set SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN=1 only for non-acceptance diagnostics.
Lab runs are intentionally reported as non-acceptance and do not produce a successful
performance gate result.
EOF
      exit 1
    fi
  fi

  if [[ -z "$SIGNALING_SERVER_URL" || -z "$SIGNALING_WS_URL" ]]; then
    cat >&2 <<EOF
Missing real-device WebRTC signaling URLs.

Set SKYBRIDGE_SIGNALING_SERVER_URL and SKYBRIDGE_SIGNALING_WEBSOCKET_URL
to the remote registry/signaling service used by the cross-network test.
Defaults are:
  SKYBRIDGE_SIGNALING_SERVER_URL=$DEFAULT_SIGNALING_SERVER_URL
  SKYBRIDGE_SIGNALING_WEBSOCKET_URL=$DEFAULT_SIGNALING_WS_URL
This script intentionally does not start localhost signaling for the default
real-device performance gate, because localhost/LAN signaling would be a proxy
for the user's cross-network scenario.
EOF
    exit 1
  fi

  python3 - "$SIGNALING_SERVER_URL" "$SIGNALING_WS_URL" "$ALLOW_PRIVATE_SIGNALING" "$ALLOW_LOCALHOST_SIGNALING" "$ALLOW_INSECURE_SIGNALING" "$ALLOW_UNRESOLVED_SIGNALING" "$LAB_RUN" <<'PY'
import json
import ipaddress
import socket
import sys
import urllib.parse
import urllib.request
from urllib.parse import urlparse

http_url, ws_url, allow_private, allow_localhost, allow_insecure, allow_unresolved, lab_run = sys.argv[1:8]
allow_private = allow_private == "1"
allow_localhost = allow_localhost == "1"
allow_insecure = allow_insecure == "1"
allow_unresolved = allow_unresolved == "1"
lab_run = lab_run == "1"

def reject(message):
    raise SystemExit(message)

def public_dns_addresses(host):
    addresses = []
    for rrtype in ("A", "AAAA"):
        query = urllib.parse.urlencode({"name": host, "type": rrtype})
        request = urllib.request.Request(
            f"https://cloudflare-dns.com/dns-query?{query}",
            headers={"Accept": "application/dns-json"},
        )
        with urllib.request.urlopen(request, timeout=8) as response:
            payload = json.loads(response.read().decode("utf-8"))
        for answer in payload.get("Answer", []) or []:
            data = str(answer.get("data") or "").strip()
            if not data:
                continue
            try:
                addresses.append(ipaddress.ip_address(data))
            except ValueError:
                pass
    return addresses

def validate(url, label, secure_scheme):
    parsed = urlparse(url)
    supported = {"http", "https"} if secure_scheme == "https" else {"ws", "wss"}
    if parsed.scheme not in supported:
        reject(f"{label} has unsupported scheme: {url}")
    if parsed.scheme != secure_scheme and not allow_insecure:
        reject(
            f"{label} must use {secure_scheme} for real-device acceptance: {url}. "
            "Set SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_INSECURE_SIGNALING=1 only for non-acceptance lab runs."
        )
    host = parsed.hostname
    if not host:
        reject(f"{label} is missing host: {url}")
    if host in {"localhost", "127.0.0.1", "::1"} and not allow_localhost:
        reject(
            f"{label} points to localhost ({host}); set "
            "SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_LOCALHOST_SIGNALING=1 only for non-acceptance lab runs."
        )
    host_is_literal = False
    public_dns_error = None
    try:
        addresses = [ipaddress.ip_address(host)]
        host_is_literal = True
    except ValueError:
        addresses = []
        try:
            for family, _, _, _, sockaddr in socket.getaddrinfo(host, None):
                address = sockaddr[0]
                try:
                    addresses.append(ipaddress.ip_address(address))
                except ValueError:
                    pass
        except socket.gaierror as exc:
            if allow_unresolved:
                return
            reject(
                f"{label} host does not resolve ({host}): {exc}. "
                "Set SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_UNRESOLVED_SIGNALING=1 only for DNS lab runs."
            )
    if not host_is_literal:
        try:
            public_addresses = public_dns_addresses(host)
        except Exception as exc:
            public_addresses = []
            public_dns_error = str(exc)
        if public_addresses:
            addresses = public_addresses
    for address in addresses:
        if address.is_loopback and not allow_localhost:
            reject(f"{label} resolves to loopback address {address}")
        if (address.is_private or address.is_link_local) and not allow_private:
            reject(
                f"{label} resolves to private/link-local address {address}; set "
                "SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_PRIVATE_SIGNALING=1 only when this is an explicit lab run, "
                "not final cross-network acceptance."
            )
        if not lab_run and not address.is_global:
            suffix = f" Public DNS probe failed: {public_dns_error}" if public_dns_error else ""
            reject(
                f"{label} resolves to non-global address {address}; real-device cross-network "
                f"acceptance requires a globally routable signaling endpoint.{suffix}"
            )

validate(http_url, "SKYBRIDGE_SIGNALING_SERVER_URL", "https")
validate(ws_url, "SKYBRIDGE_SIGNALING_WEBSOCKET_URL", "wss")
PY
}

prepare_auth_session() {
  local output="$ARTIFACT_DIR/host.auth-session.json"
  python3 - "$AUTH_SESSION_SOURCE_FILE" "$output" <<'PY'
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

source_path, output_path = sys.argv[1:3]

def fail(message):
    raise SystemExit(message)

def decode_segment(segment):
    padded = segment + "=" * ((4 - len(segment) % 4) % 4)
    return json.loads(base64.urlsafe_b64decode(padded.encode("ascii")))

def validate_jwt(token):
    token = (token or "").strip()
    parts = token.split(".")
    if len(parts) != 3:
        fail(f"Auth token must have 3 JWT segments; found {len(parts)}")
    if any(not part for part in parts):
        fail("Auth token has an empty JWT segment")
    try:
        header = decode_segment(parts[0])
        payload = decode_segment(parts[1])
    except Exception as exc:
        fail(f"Auth token is not valid base64url JSON: {exc}")
    alg = str(header.get("alg", "")).strip()
    if not alg:
        fail("Auth token JWT header is missing alg")
    if alg.lower() == "none":
        fail("Auth token JWT header alg=none is a compatibility token, not a signed Supabase user JWT")
    exp = payload.get("exp")
    if isinstance(exp, bool) or not isinstance(exp, (int, float)):
        fail("Auth token JWT payload is missing numeric exp")
    remaining = float(exp) - time.time()
    if remaining <= 300:
        fail(f"Auth token expires too soon for real-device WebRTC smoke ({int(remaining)}s remaining)")
    subject = str(payload.get("sub") or "").strip()
    if not subject:
        fail("Auth token JWT payload is missing non-empty sub")
    role = str(payload.get("role") or "").strip()
    if role != "authenticated":
        fail(f"Auth token JWT payload role must be authenticated; found {role or '<missing>'}")
    audience = payload.get("aud")
    if isinstance(audience, list):
        audiences = {str(item) for item in audience}
    elif audience is None:
        audiences = set()
    else:
        audiences = {str(audience)}
    if "authenticated" not in audiences:
        found = ",".join(sorted(audiences)) if audiences else "<missing>"
        fail(f"Auth token JWT payload aud must include authenticated; found {found}")
    forbidden = {"anon", "service_role"}
    if role in forbidden or audiences.intersection(forbidden):
        fail("Auth token appears to be an anon/service_role JWT, not a signed Supabase user JWT")
    return payload

def verify_supabase_user(token, subject):
    supabase_url = (os.environ.get("SUPABASE_URL") or "").strip().rstrip("/")
    anon_key = (os.environ.get("SUPABASE_ANON_KEY") or "").strip()
    if not supabase_url or not anon_key:
        fail("SUPABASE_URL and SUPABASE_ANON_KEY are required for real-device WebRTC acceptance")
    request = urllib.request.Request(
        f"{supabase_url}/auth/v1/user",
        headers={
            "Authorization": f"Bearer {token}",
            "apikey": anon_key,
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            body = response.read()
            status = response.status
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:400]
        fail(f"Supabase /auth/v1/user rejected auth token (HTTP {exc.code}): {detail}")
    except Exception as exc:
        fail(f"Unable to verify auth token with Supabase /auth/v1/user: {exc}")
    if not 200 <= status < 300:
        fail(f"Supabase /auth/v1/user rejected auth token (HTTP {status})")
    try:
        user = json.loads(body.decode("utf-8"))
    except Exception as exc:
        fail(f"Supabase /auth/v1/user returned invalid JSON: {exc}")
    user_id = str(user.get("id") or user.get("sub") or "").strip()
    if user_id and user_id != subject:
        fail(f"Supabase user id mismatch: token sub={subject} user id={user_id}")
    return supabase_url

def refresh_supabase_session(session):
    supabase_url = (os.environ.get("SUPABASE_URL") or "").strip().rstrip("/")
    anon_key = (os.environ.get("SUPABASE_ANON_KEY") or "").strip()
    refresh_token = str(session.get("refreshToken") or session.get("refresh_token") or "").strip()
    if not refresh_token or not supabase_url or not anon_key:
        return session
    request = urllib.request.Request(
        f"{supabase_url}/auth/v1/token?grant_type=refresh_token",
        data=json.dumps({"refresh_token": refresh_token}).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {anon_key}",
            "apikey": anon_key,
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception as exc:
        print(f"Warning: failed to refresh real-device smoke auth session ({exc}).", file=sys.stderr)
        return session
    refreshed_access = str(payload.get("access_token") or "").strip()
    if refreshed_access:
        session["accessToken"] = refreshed_access
    refreshed_refresh = str(payload.get("refresh_token") or "").strip()
    if refreshed_refresh:
        session["refreshToken"] = refreshed_refresh
    return session

session = None
if source_path:
    try:
        with open(source_path, "r", encoding="utf-8") as handle:
            session = json.load(handle)
    except Exception as exc:
        fail(f"Unable to read auth session file {source_path}: {exc}")
else:
    token = (
        os.environ.get("SKYBRIDGE_BEARER_TOKEN")
        or os.environ.get("SKYBRIDGE_ACCESS_TOKEN")
        or ""
    ).strip()
    if token:
        refresh = (os.environ.get("SKYBRIDGE_REFRESH_TOKEN") or "").strip()
        payload = validate_jwt(token)
        session = {
            "accessToken": token,
            "refreshToken": refresh,
            "userIdentifier": (
                os.environ.get("SKYBRIDGE_USER_ID")
                or str(payload["sub"])
            ),
            "nebulaId": (
                os.environ.get("SKYBRIDGE_NEBULA_ID")
                or os.environ.get("SKYBRIDGE_TENANT_ID")
                or str(
                    payload.get("tenant_id")
                    or payload.get("app_metadata", {}).get("tenant_id")
                    or payload.get("user_metadata", {}).get("tenant_id")
                    or ""
                )
                or None
            ),
            "displayName": os.environ.get("SKYBRIDGE_DISPLAY_NAME") or "Real Device WebRTC Smoke",
            "issuedAt": time.time(),
        }

if not session:
    fail(
        "Missing signed Supabase auth session. Provide SKYBRIDGE_SMOKE_AUTH_SESSION_FILE, "
        "SKYBRIDGE_AUTH_SESSION_FILE, SKYBRIDGE_ACCESS_TOKEN, or SKYBRIDGE_BEARER_TOKEN."
    )

session = refresh_supabase_session(session)
token = (
    session.get("accessToken")
    or session.get("access_token")
    or session.get("access-token")
    or ""
)
payload = validate_jwt(token)
supabase_url = verify_supabase_user(token, str(payload["sub"]))
issuer = str(payload.get("iss") or "").strip().rstrip("/")
expected_issuer = f"{supabase_url}/auth/v1"
if issuer != expected_issuer:
    fail(f"Auth token issuer mismatch: iss={issuer or '<missing>'} expected={expected_issuer}")
session["accessToken"] = token
subject = str(payload["sub"])
session_user = str(session.get("userIdentifier") or "").strip()
if session_user and session_user != subject:
    fail(f"Auth session userIdentifier mismatch: session={session_user} token_sub={subject}")
session["userIdentifier"] = subject
if not session.get("nebulaId"):
    tenant = (
        payload.get("tenant_id")
        or payload.get("app_metadata", {}).get("tenant_id")
        or payload.get("user_metadata", {}).get("tenant_id")
    )
    if tenant:
        session["nebulaId"] = str(tenant)
session.setdefault("displayName", "Real Device WebRTC Smoke")
session.setdefault("issuedAt", time.time())

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(session, handle, separators=(",", ":"), sort_keys=True)
print(output_path)
PY
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
    if [[ -f "$MAC_STATUS" ]] && grep -q 'failed stage=' "$MAC_STATUS"; then
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
    if [[ -f "$path" ]] && grep -q 'failed stage=' "$path"; then
      echo "Smoke failed while waiting for ${label}: $(tail -n 1 "$path")" >&2
      return 1
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${path}" >&2
      return 1
    fi
    sleep 1
  done
}

run_with_hard_timeout() {
  local timeout_seconds="$1"
  shift
  local pid
  local started_at
  "$@" &
  pid="$!"
  started_at="$(date +%s)"
  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 0.25
  done
  set +e
  wait "$pid"
  local status="$?"
  set -e
  return "$status"
}

copy_ios_file() {
  local remote="$1"
  local local_path="$2"
  local tmp_path="${local_path}.tmp.${BASHPID:-$$}"
  rm -f "$tmp_path"
  if run_with_hard_timeout "$IOS_COPY_HARD_TIMEOUT_SECONDS" \
    xcrun devicectl --timeout "$IOS_COPY_TIMEOUT_SECONDS" device copy from \
    --device "$IOS_DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$IOS_BUNDLE_ID" \
    --source "Library/Caches/$remote" \
    --destination "$tmp_path" >/dev/null 2>&1; then
    if [[ -s "$tmp_path" || ! -s "$local_path" ]]; then
      mv -f "$tmp_path" "$local_path"
    else
      rm -f "$tmp_path"
    fi
  else
    rm -f "$tmp_path"
    [[ -f "$local_path" ]] || : > "$local_path"
  fi
}

copy_mac_media_diagnostics() {
  local media_log_dir="$HOME/Library/Logs/SkyBridge"
  local session_id="${SESSION_ID:-}"
  if [[ -d "$media_log_dir" && -n "$session_id" ]]; then
    local session_log="$media_log_dir/webrtc-media-${session_id}.jsonl"
    if [[ -f "$session_log" ]]; then
      local target="$ARTIFACT_DIR/webrtc-media-${session_id}.jsonl"
      local tmp="$ARTIFACT_DIR/.webrtc-media-${session_id}.jsonl.tmp"
      if cp "$session_log" "$tmp" 2>/dev/null; then
        mv "$tmp" "$target" 2>/dev/null || true
      else
        rm -f "$tmp" 2>/dev/null || true
      fi
    fi
  fi
}

copy_round_diagnostics() {
  copy_mac_media_diagnostics
  copy_ios_file "$IOS_STATUS_NAME" "$IOS_STATUS_LOCAL"
  copy_ios_file "$IOS_STATUS_NAME.webrtc-media.jsonl" "$IOS_MEDIA_LOCAL"
  copy_ios_file "$IOS_STATUS_NAME.trace.log" "$IOS_TRACE_LOCAL"
}

wait_for_ios_pattern() {
  local local_path="$1"
  local remote="$2"
  local pattern="$3"
  local timeout_seconds="$4"
  local label="$5"
  local failure_pattern='failed stage=|fallback-frame|transport=fallback-screen|strict-media-failed|screen-drop .*fallback|screenFallbackDrop|stream-native-warmup-fallback-main|fallbackProducerSwitch|uiSurface=smokeOverlay|nativePromotionState=smoke-hold'
  local started_at
  started_at="$(date +%s)"
  while true; do
    copy_ios_file "$remote" "$local_path"
    if [[ -f "$local_path" ]] && grep -qE "$failure_pattern" "$local_path"; then
      echo "iOS smoke failed while waiting for ${label}: $(tail -n 1 "$local_path")" >&2
      return 1
    fi
    if [[ -f "$MAC_STATUS" ]] && grep -qE "$failure_pattern|failed stage=" "$MAC_STATUS"; then
      echo "macOS smoke failed while waiting for ${label}: $(tail -n 1 "$MAC_STATUS")" >&2
      return 1
    fi
    if [[ -f "$local_path" ]] && grep -qE "$pattern" "$local_path"; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${local_path}" >&2
      return 1
    fi
    sleep 2
  done
}

run_webrtc_media_doctor() {
  local session_id="$1"
  local output="$ARTIFACT_DIR/webrtc_media_doctor.json"
  local last_error="$ARTIFACT_DIR/webrtc_media_doctor.stderr.log"
  local copier_pid=""
  copy_round_diagnostics
  (
    while true; do
      copy_round_diagnostics || true
      sleep 2
    done
  ) &
  copier_pid="$!"

  set +e
  cargo run --quiet --manifest-path "$ROOT_DIR/rust/Cargo.toml" -p skybridge -- \
    smoke webrtc gate \
    --session-id "$session_id" \
    --artifact-dir "$ARTIFACT_DIR" \
    --since-seconds "$SMOKE_TIMEOUT_SECONDS" \
    --timeout-seconds "$SMOKE_TIMEOUT_SECONDS" \
    --min-pass-seconds "$SMOKE_SOAK_SECONDS" \
    --poll-interval-seconds 2 \
    --min-fps "$SMOKE_MIN_FPS" \
    --min-width "$SMOKE_VIDEO_WIDTH" \
    --min-height "$SMOKE_VIDEO_HEIGHT" \
    --exact-video-size \
    --require-audio "$([[ "$SMOKE_REQUIRE_AUDIO" == "1" ]] && echo true || echo false)" \
    --json > "$output" 2>"$last_error"
  local status="$?"
  set -e

  kill "$copier_pid" >/dev/null 2>&1 || true
  wait "$copier_pid" >/dev/null 2>&1 || true

  if [[ "$status" == "0" ]]; then
    return 0
  fi

  echo "WebRTC media smoke gate failed (session=${session_id}, min_fps=${SMOKE_MIN_FPS}, require_audio=${SMOKE_REQUIRE_AUDIO})" >&2
  cat "$last_error" >&2 || true
  return "$status"
}

preflight_media_relay_udp() {
  if [[ "$SKIP_MEDIA_RELAY_PREFLIGHT" == "1" || "$SMOKE_REQUIRE_AUDIO" != "1" || "$SMOKE_FORCE_RELAY_ICE" != "1" ]]; then
    return 0
  fi

  local log="$ARTIFACT_DIR/media-relay-preflight.log"
  echo "==> Preflighting media relay UDP: ${MEDIA_RELAY_PREFLIGHT_HOST}:${MEDIA_RELAY_PREFLIGHT_PORT}"
  if python3 - "$MEDIA_RELAY_PREFLIGHT_HOST" "$MEDIA_RELAY_PREFLIGHT_PORT" "$MEDIA_RELAY_PREFLIGHT_TIMEOUT_SECONDS" "$log" <<'PY'
import ipaddress
import json
import re
import socket
import subprocess
import sys
import time

host, port_raw, timeout_raw, log_path = sys.argv[1:5]
port = int(port_raw)
timeout = float(timeout_raw)

def log(line):
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")

def parse_route_destination(value):
    if value == "default":
        return ipaddress.ip_network("0.0.0.0/0")
    match = re.fullmatch(r"(\d+(?:\.\d+){0,3})(?:/(\d+))?", value)
    if not match:
        return None
    parts = [int(part) for part in match.group(1).split(".")]
    if any(part < 0 or part > 255 for part in parts):
        return None
    prefix = int(match.group(2)) if match.group(2) is not None else len(parts) * 8
    while len(parts) < 4:
        parts.append(0)
    try:
        return ipaddress.ip_network((".".join(str(part) for part in parts), prefix), strict=False)
    except ValueError:
        return None

target_ip = ipaddress.ip_address(socket.gethostbyname(host))
log(f"target={host}:{port} resolved={target_ip}")

try:
    routes = subprocess.check_output(["netstat", "-rn", "-f", "inet"], text=True, stderr=subprocess.STDOUT)
except Exception as exc:
    log(f"route_probe_error={exc}")
else:
    best = None
    for line in routes.splitlines():
        columns = line.split()
        if len(columns) < 4:
            continue
        network = parse_route_destination(columns[0])
        if network is None or target_ip not in network:
            continue
        if best is None or network.prefixlen > best[0].prefixlen:
            best = (network, columns[0], columns[3])
    if best is not None:
        network, label, netif = best
        log(f"route_match={label} network={network} netif={netif}")
        if netif.startswith("utun"):
            log("route_warning=media relay target currently matches a utun/TUN route; UDP relay may be intercepted by VPN/proxy")

payload = json.dumps({"type": "bind", "leaseToken": "invalid-preflight-token"}).encode("utf-8")
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(timeout)
try:
    started = time.time()
    sock.sendto(payload, (host, port))
    data, addr = sock.recvfrom(2048)
    elapsed_ms = int(round((time.time() - started) * 1000))
    body = data.decode("utf-8", "replace")
    log(f"udp_bind_probe=ok from={addr[0]}:{addr[1]} bytes={len(data)} rttMs={elapsed_ms} bodyPrefix={body[:120]}")
except Exception as exc:
    log(f"udp_bind_probe=failed error={type(exc).__name__}:{exc}")
    raise SystemExit(78)
finally:
    sock.close()
PY
  then
    return 0
  fi

  echo "Media relay UDP preflight failed: ${MEDIA_RELAY_PREFLIGHT_HOST}:${MEDIA_RELAY_PREFLIGHT_PORT}" >&2
  echo "    log: $log" >&2
  echo "    For acceptance, disable TUN/VPN/proxy interception or route this UDP endpoint DIRECT, then rerun." >&2
  tail -n 12 "$log" >&2 || true
  return 1
}

require_command python3
require_command xcrun
require_command swift
require_command xcodebuild
require_command cargo
validate_remote_signaling_urls
preflight_media_relay_udp
AUTH_SESSION_FILE="$(prepare_auth_session)"
if [[ -z "$IOS_DEVICE_ID" ]]; then
  IOS_DEVICE_ID="$(pick_real_device_id)"
fi
IOS_DEVICE_LABEL="$(skybridge_smoke_hash_label "$IOS_DEVICE_ID")"
if [[ "$PRESERVE_INSTALL" != "1" && -z "${SKYBRIDGE_REAL_DEVICE_ID:-}" ]]; then
  echo "SKYBRIDGE_SMOKE_PRESERVE_INSTALL=0 requires explicit SKYBRIDGE_REAL_DEVICE_ID to avoid uninstalling from the wrong device." >&2
  exit 1
fi

echo "==> Artifacts: $ARTIFACT_DIR"
echo "==> Real device: $IOS_DEVICE_ID"
echo "==> Run ID: $RUN_ID"
echo "==> Signaling HTTP: $SIGNALING_SERVER_URL"
echo "==> Signaling WS: $SIGNALING_WS_URL"
echo "==> Extreme media: $SMOKE_EXTREME_MEDIA syntheticScreen=$SMOKE_SYNTHETIC_SCREEN forceRelayIce=$SMOKE_FORCE_RELAY_ICE minFps=$SMOKE_MIN_FPS targetFps=$SMOKE_TARGET_FPS requireAudio=$SMOKE_REQUIRE_AUDIO hostHold=$SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS"
echo "==> Strict video target: ${SMOKE_VIDEO_WIDTH}x${SMOKE_VIDEO_HEIGHT}"

echo "==> Inspecting connected device"
xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" list devices --json-output "$IOS_DEVICE_INFO_JSON" >/dev/null

echo "==> Building macOS WebRTC smoke host"
SMOKE_BUILD_DIR="${SKYBRIDGE_SMOKE_BUILD_DIR:-$ROOT_DIR/.build/real-device-webrtc-smoke}"
(
  cd "$ROOT_DIR"
  swift build --build-path "$SMOKE_BUILD_DIR" --product LocalWebRTCSmokeHost
) >"$MAC_BUILD_LOG"

MAC_APP_BIN="$SMOKE_BUILD_DIR/debug/LocalWebRTCSmokeHost"
if [[ ! -x "$MAC_APP_BIN" ]]; then
  echo "macOS smoke host executable not found: $MAC_APP_BIN" >&2
  exit 1
fi

echo "==> Building iOS app for real device"
IOS_BUILD_DESTINATION="${SKYBRIDGE_IOS_BUILD_DESTINATION:-generic/platform=iOS}"
echo "    build destination: $IOS_BUILD_DESTINATION"
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
  xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device uninstall app --device "$IOS_DEVICE_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
else
  echo "    preserving existing install to keep Local Network/TCC grants when possible"
fi
xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device install app --device "$IOS_DEVICE_ID" "$IOS_APP_PATH" >/dev/null

echo "==> Starting macOS WebRTC host"
MAC_HOST_ENV=(
  "SKYBRIDGE_KEYCHAIN_IN_MEMORY=1"
  "SKYBRIDGE_AUTH_SESSION_FILE=$AUTH_SESSION_FILE"
  "SB_PQC_PREFERRED_SUITE=xwing"
  "SKYBRIDGE_DEVICE_ID=$MAC_DEVICE_ID"
  "SKYBRIDGE_SIGNALING_SERVER_URL=$SIGNALING_SERVER_URL"
  "SKYBRIDGE_SIGNALING_WEBSOCKET_URL=$SIGNALING_WS_URL"
  "SKYBRIDGE_CLIENT_VERSION=$CLIENT_VERSION"
  "SKYBRIDGE_PROTOCOL_VERSION=$PROTOCOL_VERSION"
  "SKYBRIDGE_SMOKE_SUPABASE_URL=${SUPABASE_URL:-}"
  "SKYBRIDGE_SMOKE_SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY:-}"
  "SKYBRIDGE_SMOKE_SKIP_SUPABASE_AUTH=0"
  "SKYBRIDGE_SMOKE_ROLE=mac-host"
  "SKYBRIDGE_SMOKE_STATUS_FILE=$MAC_STATUS"
  "SKYBRIDGE_SMOKE_CODE_FILE=$MAC_CODE"
  "SKYBRIDGE_SMOKE_TOKEN_FILE=$MAC_TOKEN"
  "SKYBRIDGE_SMOKE_TENANT_FILE=$MAC_TENANT"
  "SKYBRIDGE_SMOKE_PQC_REPORT_FILE=$MAC_PQC_REPORT"
  "SKYBRIDGE_SMOKE_SKIP_AUTH_REFRESH=1"
  "SKYBRIDGE_SMOKE_REQUIRE_STREAM=1"
  "SKYBRIDGE_SMOKE_SYNTHETIC_SCREEN=$SMOKE_SYNTHETIC_SCREEN"
  "SKYBRIDGE_SMOKE_SYNTHETIC_OPUS_TONE=$SMOKE_SYNTHETIC_OPUS_TONE"
  "SKYBRIDGE_SMOKE_EXTREME_MEDIA=$SMOKE_EXTREME_MEDIA"
  "SKYBRIDGE_SMOKE_FORCE_RELAY_ICE=$SMOKE_FORCE_RELAY_ICE"
  "SKYBRIDGE_WEBRTC_EXTREME_MEDIA=$SMOKE_EXTREME_MEDIA"
  "SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK=$SMOKE_EXTREME_MEDIA"
  "SKYBRIDGE_SMOKE_ALLOW_CLASSIC_MEDIA_SUCCESS=0"
  "SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1"
  "SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS=$SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS"
  "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1"
  "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS=$SMOKE_TIMEOUT_SECONDS"
)
if [[ -n "$STUN_URL" ]]; then
  MAC_HOST_ENV+=("SKYBRIDGE_STUN_URL=$STUN_URL")
fi
if [[ -n "$TURN_URLS" ]]; then
  MAC_HOST_ENV+=("SKYBRIDGE_TURN_URLS=$TURN_URLS")
fi
env "${MAC_HOST_ENV[@]}" "$MAC_APP_BIN" >"$MAC_STDOUT" 2>&1 &
MAC_PID="$!"

wait_for_file_nonempty "$MAC_CODE" 90 "macOS connection code"
wait_for_file_nonempty "$MAC_TOKEN" 90 "macOS access token"
wait_for_file_nonempty "$MAC_TENANT" 90 "macOS tenant id"
wait_for_file_nonempty "$MAC_PQC_REPORT" 90 "macOS PQC report"
load_pqc_report "$MAC_PQC_REPORT"

CONNECTION_CODE="$(tr -d '\r\n' < "$MAC_CODE")"
ACCESS_TOKEN="$(tr -d '\r\n' < "$MAC_TOKEN")"
TENANT_ID="$(tr -d '\r\n' < "$MAC_TENANT")"
if [[ -z "$CONNECTION_CODE" || -z "$ACCESS_TOKEN" || -z "$TENANT_ID" ]]; then
  echo "macOS smoke did not produce connection code, access token, and tenant id" >&2
  exit 1
fi

echo "==> Launching iOS WebRTC smoke client"
echo "    if the iPad shows a Local Network permission alert, tap Allow"
IOS_ENV_JSON="$(
  SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
  SB_PQC_PREFERRED_SUITE=xwing \
  SKYBRIDGE_DEVICE_ID="$IOS_LOGICAL_DEVICE_ID" \
  SKYBRIDGE_SMOKE_ALLOW_IDENTITY_OVERRIDE=1 \
  SKYBRIDGE_ACCESS_TOKEN="$ACCESS_TOKEN" \
  SKYBRIDGE_TENANT_ID="$TENANT_ID" \
  SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
  SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
  SKYBRIDGE_CLIENT_VERSION="$CLIENT_VERSION" \
  SKYBRIDGE_PROTOCOL_VERSION="$PROTOCOL_VERSION" \
  SKYBRIDGE_STUN_URL="$STUN_URL" \
  SKYBRIDGE_TURN_URLS="$TURN_URLS" \
  SKYBRIDGE_SMOKE_ROLE=ios-client \
  SKYBRIDGE_SMOKE_CONNECT_CODE="$CONNECTION_CODE" \
  SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_NAME" \
  SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
  SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS="$SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS" \
  SKYBRIDGE_SMOKE_REQUIRE_AUDIO="$SMOKE_REQUIRE_AUDIO" \
  SKYBRIDGE_SMOKE_REQUIRE_NATIVE_VIDEO=1 \
  SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB=1 \
  SKYBRIDGE_SMOKE_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
  SKYBRIDGE_SMOKE_VIDEO_WIDTH="$SMOKE_VIDEO_WIDTH" \
  SKYBRIDGE_SMOKE_VIDEO_HEIGHT="$SMOKE_VIDEO_HEIGHT" \
  SKYBRIDGE_SMOKE_TARGET_FPS="$SMOKE_TARGET_FPS" \
  SKYBRIDGE_SMOKE_FORCE_RELAY_ICE="$SMOKE_FORCE_RELAY_ICE" \
  SKYBRIDGE_WEBRTC_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
  SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK="$SMOKE_EXTREME_MEDIA" \
  SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1 \
  SKYBRIDGE_PQC_PEER_DEVICE_ID="$MAC_PQC_DEVICE_ID" \
  SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64="$MAC_PQC_XWING_PUBLIC_KEY_BASE64" \
  SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64" \
  SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64" \
  python3 - <<'PY'
import json
import os

keys = [
    "SKYBRIDGE_KEYCHAIN_IN_MEMORY",
    "SB_PQC_PREFERRED_SUITE",
    "SKYBRIDGE_DEVICE_ID",
    "SKYBRIDGE_ACCESS_TOKEN",
    "SKYBRIDGE_TENANT_ID",
    "SKYBRIDGE_SIGNALING_SERVER_URL",
    "SKYBRIDGE_SIGNALING_WEBSOCKET_URL",
    "SKYBRIDGE_CLIENT_VERSION",
    "SKYBRIDGE_PROTOCOL_VERSION",
    "SKYBRIDGE_STUN_URL",
    "SKYBRIDGE_TURN_URLS",
    "SKYBRIDGE_SMOKE_ROLE",
    "SKYBRIDGE_SMOKE_CONNECT_CODE",
    "SKYBRIDGE_SMOKE_STATUS_BASENAME",
    "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS",
    "SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS",
    "SKYBRIDGE_SMOKE_REQUIRE_AUDIO",
    "SKYBRIDGE_SMOKE_REQUIRE_NATIVE_VIDEO",
    "SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB",
    "SKYBRIDGE_SMOKE_EXTREME_MEDIA",
    "SKYBRIDGE_SMOKE_VIDEO_WIDTH",
    "SKYBRIDGE_SMOKE_VIDEO_HEIGHT",
    "SKYBRIDGE_SMOKE_TARGET_FPS",
    "SKYBRIDGE_SMOKE_FORCE_RELAY_ICE",
    "SKYBRIDGE_WEBRTC_EXTREME_MEDIA",
    "SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK",
    "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY",
    "SKYBRIDGE_PQC_PEER_DEVICE_ID",
    "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64",
]
env = {}
for key in keys:
    value = os.environ.get(key)
    if value is not None and value != "":
        env[key] = value
print(json.dumps(env, ensure_ascii=False))
PY
)"

xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device process launch \
  --device "$IOS_DEVICE_ID" \
  --terminate-existing \
  --environment-variables "$IOS_ENV_JSON" \
  --json-output "$IOS_LAUNCH_JSON" \
  "$IOS_BUNDLE_ID" >/dev/null
DID_LAUNCH_IOS=1
IOS_PID="$(python3 - "$IOS_LAUNCH_JSON" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    value = payload.get("result", {}).get("process", {}).get("processIdentifier")
    print("" if value is None else str(value))
except Exception:
    print("")
PY
)"

wait_for_file_pattern "$MAC_STATUS" 'rekey complete suite=X-Wing' "$SMOKE_TIMEOUT_SECONDS" "macOS X-Wing rekey"
wait_for_file_pattern "$MAC_STATUS" 'success session=.*suite=X-Wing.*stream=true' "$SMOKE_TIMEOUT_SECONDS" "macOS WebRTC success"
SESSION_ID="$(grep -Eo 'success session=[^ ]+' "$MAC_STATUS" 2>/dev/null | tail -n 1 | cut -d= -f2 || true)"
if [[ -z "$SESSION_ID" ]]; then
  echo "Unable to extract WebRTC session id from mac status: $MAC_STATUS" >&2
  exit 1
fi
SESSION_REGEX="$(regex_escape "$SESSION_ID")"

wait_for_ios_pattern \
  "$IOS_STATUS_LOCAL" \
  "$IOS_STATUS_NAME" \
  "handshake session=${SESSION_REGEX} suite=(X25519(-Ed25519)?|X-Wing)" \
  "$SMOKE_TIMEOUT_SECONDS" \
  "iOS bootstrap handshake"
wait_for_ios_pattern \
  "$IOS_STATUS_LOCAL" \
  "$IOS_STATUS_NAME" \
  'rekey complete suite=X-Wing' \
  "$SMOKE_TIMEOUT_SECONDS" \
  "iOS X-Wing rekey"

if [[ "$SMOKE_REQUIRE_AUDIO" == "1" ]]; then
  echo "==> Waiting for iOS audio receive evidence"
  if ! wait_for_ios_pattern \
    "$IOS_TRACE_LOCAL" \
    "$IOS_STATUS_NAME.trace.log" \
    "audio-rx .*audioRxRecv=[1-9][0-9]* .*audioRxPlayed=[1-9][0-9]*" \
    "$SMOKE_AUDIO_BOOTSTRAP_TIMEOUT_SECONDS" \
    "iOS audio receive evidence"; then
    echo "==> Running WebRTC media doctor after audio bootstrap timeout" >&2
    run_webrtc_media_doctor "$SESSION_ID" || true
    exit 1
  fi
fi

echo "==> Running WebRTC media doctor"
run_webrtc_media_doctor "$SESSION_ID"
echo "==> Materializing redacted public WebRTC smoke artifacts"
skybridge_smoke_materialize_public_artifacts "$IOS_DEVICE_LABEL" "$ARTIFACT_DIR" "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID" "$MAC_DEVICE_ID" "$IOS_LOGICAL_DEVICE_ID" "$MAC_PQC_DEVICE_ID"
skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID" "$MAC_DEVICE_ID" "$IOS_LOGICAL_DEVICE_ID" "$MAC_PQC_DEVICE_ID"
echo "==> Redacted public artifacts: $PUBLIC_ARTIFACT_DIR"

if [[ "$LAB_RUN" == "1" ]]; then
  echo "Lab run completed, but this is not an acceptance pass because SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN=1." >&2
  echo "    session: $SESSION_ID" >&2
  echo "    mac status: $MAC_STATUS" >&2
  echo "    ios status: $IOS_STATUS_LOCAL" >&2
  echo "    ios trace:  $IOS_TRACE_LOCAL" >&2
  echo "    doctor:     $ARTIFACT_DIR/webrtc_media_doctor.json" >&2
  exit 2
fi

echo "==> Real-device WebRTC smoke succeeded"
echo "    session: $SESSION_ID"
echo "    mac status: $MAC_STATUS"
echo "    ios status: $IOS_STATUS_LOCAL"
echo "    ios trace:  $IOS_TRACE_LOCAL"
echo "    doctor:     $ARTIFACT_DIR/webrtc_media_doctor.json"
