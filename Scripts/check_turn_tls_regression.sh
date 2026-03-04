#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-${BASE_URL:-https://api.nebula-technologies.net}}"
API_KEY="${TURN_CLIENT_API_KEY:-${SKYBRIDGE_CLIENT_API_KEY:-}}"
DEVICE_ID="${TURN_DEVICE_ID:-turn-regression-$(hostname)}"
ALLOW_STATIC_MODE="${ALLOW_STATIC_MODE:-0}"
CHECK_WS="${CHECK_WS:-1}"
CHECK_STUN="${CHECK_STUN:-1}"
STUN_TIMEOUT_SECONDS="${STUN_TIMEOUT_SECONDS:-2.5}"

if [[ -z "${API_KEY}" ]]; then
  echo "[FAIL] Missing TURN client API key." >&2
  echo "Set TURN_CLIENT_API_KEY (or SKYBRIDGE_CLIENT_API_KEY) and retry." >&2
  exit 2
fi

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[FAIL] Missing required command: ${cmd}" >&2
    exit 2
  fi
}

require_cmd curl
require_cmd openssl
require_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

echo "[INFO] Base URL: ${BASE_URL}"
echo "[STEP] Health check"
health_code="$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/health")"
if [[ "${health_code}" != "200" ]]; then
  echo "[FAIL] GET /health expected 200, got ${health_code}" >&2
  exit 1
fi
echo "[OK] /health => 200"

echo "[STEP] TURN credential endpoint check"
turn_body="${tmp_dir}/turn_credentials.json"
turn_code="$(
  curl -sS -o "${turn_body}" -w "%{http_code}" \
    -H "Accept: application/json" \
    -H "X-API-Key: ${API_KEY}" \
    -H "X-Device-Id: ${DEVICE_ID}" \
    "${BASE_URL}/api/turn/credentials"
)"
if [[ "${turn_code}" != "200" ]]; then
  echo "[FAIL] GET /api/turn/credentials expected 200, got ${turn_code}" >&2
  echo "[FAIL] Response body:" >&2
  cat "${turn_body}" >&2 || true
  exit 1
fi

eval "$(
  python3 - "${turn_body}" "${ALLOW_STATIC_MODE}" <<'PY'
import json
import re
import shlex
import sys

path = sys.argv[1]
allow_static = sys.argv[2] == "1"

with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)

errors = []
username = str(payload.get("username", "")).strip()
password = str(payload.get("password", "")).strip()
ttl = payload.get("ttl")
mode = str(payload.get("mode", "")).strip()
uris = payload.get("uris")

if not username:
    errors.append("username is empty")
if not password:
    errors.append("password is empty")
if not isinstance(ttl, int) or ttl <= 0:
    errors.append("ttl must be a positive integer")
if not isinstance(uris, list) or not uris:
    errors.append("uris must be a non-empty array")

if mode != "shared_secret_hmac":
    if not (allow_static and mode == "static_fallback"):
        errors.append(f"unexpected mode={mode!r}, expect 'shared_secret_hmac'")

turn_uris = []
turns_uris = []
for item in uris if isinstance(uris, list) else []:
    value = str(item).strip()
    lower = value.lower()
    if lower.startswith("turns:"):
        turns_uris.append(value)
        turn_uris.append(value)
    elif lower.startswith("turn:"):
        turn_uris.append(value)

if not turn_uris:
    errors.append("no valid turn:/turns: URI found")

tls_uri = None
tls_host = ""
tls_port = 0
for uri in turns_uris:
    match = re.match(r"^turns:([^:/?#]+):(\d+)(?:[/?#].*)?$", uri, re.IGNORECASE)
    if match:
        tls_uri = uri
        tls_host = match.group(1).strip()
        tls_port = int(match.group(2))
        if tls_port == 5349:
            break

if not tls_uri:
    errors.append("no turns: URI is present")
elif tls_port != 5349:
    errors.append(f"turns URI port should be 5349, got {tls_port}")

if errors:
    print("CHECK_STATUS=FAIL")
    print(f"CHECK_ERRORS={shlex.quote('; '.join(errors))}")
    print("TURN_MODE=" + shlex.quote(mode))
    sys.exit(0)

print("CHECK_STATUS=OK")
print("CHECK_ERRORS=''")
print("TURN_MODE=" + shlex.quote(mode))
print("TURN_TLS_URI=" + shlex.quote(tls_uri or ""))
print("TURN_TLS_HOST=" + shlex.quote(tls_host))
print(f"TURN_TLS_PORT={tls_port}")
PY
)"

if [[ "${CHECK_STATUS}" != "OK" ]]; then
  echo "[FAIL] TURN credential semantic check failed: ${CHECK_ERRORS}" >&2
  echo "[FAIL] Raw payload:" >&2
  cat "${turn_body}" >&2 || true
  exit 1
fi
echo "[OK] /api/turn/credentials semantic check passed (mode=${TURN_MODE})"

echo "[STEP] TURN TLS reachability (${TURN_TLS_HOST}:${TURN_TLS_PORT})"
tls_log="${tmp_dir}/tls_probe.log"
if ! openssl s_client -connect "${TURN_TLS_HOST}:${TURN_TLS_PORT}" -servername "${TURN_TLS_HOST}" -tls1_2 < /dev/null >"${tls_log}" 2>&1; then
  echo "[FAIL] openssl s_client failed for ${TURN_TLS_HOST}:${TURN_TLS_PORT}" >&2
  tail -n 60 "${tls_log}" >&2 || true
  exit 1
fi

if ! grep -Eq "Protocol\\s*:" "${tls_log}"; then
  echo "[FAIL] TLS handshake output missing protocol marker." >&2
  tail -n 60 "${tls_log}" >&2 || true
  exit 1
fi
echo "[OK] TLS handshake succeeded on ${TURN_TLS_HOST}:${TURN_TLS_PORT}"

if [[ "${CHECK_WS}" == "1" ]]; then
  echo "[STEP] WebSocket upgrade check"
  ws_code="$(
    curl -sS -o /dev/null -w "%{http_code}" \
      -H "Connection: Upgrade" \
      -H "Upgrade: websocket" \
      -H "Sec-WebSocket-Version: 13" \
      -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
      "${BASE_URL}/ws"
  )"
  if [[ "${ws_code}" != "101" ]]; then
    echo "[FAIL] GET /ws upgrade expected 101, got ${ws_code}" >&2
    exit 1
  fi
  echo "[OK] /ws upgrade => 101"
fi

if [[ "${CHECK_STUN}" == "1" ]]; then
  echo "[STEP] STUN binding probe (UDP 3478)"
  python3 - "${TURN_TLS_HOST}" "${STUN_TIMEOUT_SECONDS}" <<'PY'
import os
import random
import socket
import struct
import sys

host = sys.argv[1]
timeout_s = float(sys.argv[2])
port = int(os.environ.get("STUN_PORT", "3478"))

txid = bytes(random.getrandbits(8) for _ in range(12))
request = struct.pack("!HHI", 0x0001, 0, 0x2112A442) + txid

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(timeout_s)
try:
    sock.sendto(request, (host, port))
    data, _ = sock.recvfrom(2048)
except Exception as exc:
    print(f"[FAIL] STUN probe failed: {exc}", file=sys.stderr)
    sys.exit(1)
finally:
    sock.close()

if len(data) < 20:
    print("[FAIL] STUN response too short", file=sys.stderr)
    sys.exit(1)

msg_type, msg_len, magic = struct.unpack("!HHI", data[:8])
resp_txid = data[8:20]
if msg_type != 0x0101 or magic != 0x2112A442 or resp_txid != txid:
    print("[FAIL] STUN response header mismatch", file=sys.stderr)
    sys.exit(1)

print("[OK] STUN binding response received")
PY
fi

echo "[PASS] TURN 5349/TLS regression checks completed."
