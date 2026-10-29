#!/usr/bin/env bash
# Two-agent loopback smoke for the native Rust runtime.
#
# Proves, on one machine with no external services:
#   skybridge code create  -> real server-issued connection code
#   skybridge connect      -> real WebRTC + handshake + selected-ICE-route
#   skybridge file send    -> real transfer with inbound approval
#   skybridge file receive -> approval registered, file landed, SHA256 verified
#
# Uses Server/skybridge-signaling/local_compat_server.js as the control plane
# and plants unsigned (alg:none) tenant tokens, which that server accepts by
# design. Everything runs under a scratch directory and is torn down on exit.
#
# Usage: Scripts/run_native_loopback_smoke.sh [scratch-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${1:-$(mktemp -d /tmp/skybridge-loopback.XXXXXX)}"
PORT="${SKYBRIDGE_LOOPBACK_PORT:-18771}"
BIN="$ROOT/rust/target/debug/skybridge"

[[ -x "$BIN" ]] || { echo "build first: (cd rust && cargo build --workspace)" >&2; exit 1; }
command -v node >/dev/null || { echo "node is required" >&2; exit 1; }

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
cleanup() {
  pkill -f "skybridge --state-dir $SCRATCH" 2>/dev/null || true
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$SCRATCH/state-a/identity" "$SCRATCH/state-b/identity"
python3 - "$SCRATCH" <<'PY'
import base64, json, sys, time, pathlib
scratch = pathlib.Path(sys.argv[1])
def b64url(data): return base64.urlsafe_b64encode(data).rstrip(b"=").decode()
def token(tenant):
    return f"{b64url(json.dumps({'alg':'none'}).encode())}.{b64url(json.dumps({'tenant_id':tenant,'sub':'user-'+tenant,'exp':int(time.time())+3600}).encode())}.signature"
for name, user in (("state-a","operator-a"),("state-b","operator-b")):
    (scratch/name/"identity"/"auth-session.json").write_text(json.dumps({
        "access_token": token("loopback-tenant"), "refresh_token": None,
        "user_identifier": user, "nebula_id": None,
        "display_name": f"Loopback {user}", "issued_at": "2026-08-25T12:00:00Z"}))
PY

PORT="$PORT" HOST=127.0.0.1 node "$ROOT/Server/skybridge-signaling/local_compat_server.js" \
  > "$SCRATCH/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 20); do
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/turn/credentials" && break
  sleep 0.5
done

export SKYBRIDGE_SIGNALING_SERVER_URL="http://127.0.0.1:$PORT"
export SKYBRIDGE_ALLOW_INSECURE_LOOPBACK_TRANSPORT=1

"$BIN" --state-dir "$SCRATCH/state-a" agent run > "$SCRATCH/agent-a.log" 2>&1 &
"$BIN" --state-dir "$SCRATCH/state-b" agent run > "$SCRATCH/agent-b.log" 2>&1 &
for side in state-a state-b; do
  for _ in $(seq 1 30); do
    "$BIN" --state-dir "$SCRATCH/$side" device status --json 2>/dev/null \
      | grep -q '"status": "healthy"' && break
    sleep 1
  done
done

CODE=$("$BIN" --state-dir "$SCRATCH/state-a" code create --json \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['code'])")
echo "issued code: $CODE"

"$BIN" --state-dir "$SCRATCH/state-b" connect "$CODE" --timeout-seconds 90 --json \
  > "$SCRATCH/connect.json"
grep -q '"success": true' "$SCRATCH/connect.json" \
  || { echo "connect failed:"; cat "$SCRATCH/connect.json"; exit 1; }
SESSION=$(python3 -c "import json; print(json.load(open('$SCRATCH/connect.json'))['session_id'])")
PEER=$(python3 -c "import json; print(json.load(open('$SCRATCH/connect.json'))['peer']['device_id'])")
echo "connected: session=$SESSION"

head -c 262144 /dev/urandom > "$SCRATCH/payload.bin"
SENT_SHA=$(shasum -a 256 "$SCRATCH/payload.bin" | awk '{print $1}')
"$BIN" --state-dir "$SCRATCH/state-b" file send "$SCRATCH/payload.bin" \
  --to "$PEER" --session-id "$SESSION" --detach --json > /dev/null

TRANSFER=""
for _ in $(seq 1 30); do
  TRANSFER=$("$BIN" --state-dir "$SCRATCH/state-a" file receive --list --json 2>/dev/null \
    | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    pending=[r for r in d.get('requests',[]) if r.get('status')=='pending_decision']
    print(pending[0]['transfer_id'] if pending else '')
except Exception: print('')
")
  [[ -n "$TRANSFER" ]] && break
  sleep 1
done
[[ -n "$TRANSFER" ]] || { echo "no inbound approval appeared" >&2; exit 1; }
"$BIN" --state-dir "$SCRATCH/state-a" file receive --session-id "$SESSION" \
  --accept "$TRANSFER" --json > /dev/null

for _ in $(seq 1 60); do
  RECEIVED="$SCRATCH/state-a/received/payload.bin"
  if [[ -f "$RECEIVED" ]]; then
    RECV_SHA=$(shasum -a 256 "$RECEIVED" | awk '{print $1}')
    [[ "$RECV_SHA" == "$SENT_SHA" ]] && { echo "PASS: loopback transfer verified (sha256 $RECV_SHA)"; exit 0; }
  fi
  sleep 1
done
echo "transfer did not complete" >&2
exit 1
