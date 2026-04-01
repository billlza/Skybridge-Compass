#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRYPTO_MODE="${1:-xwing}"
KEEP_FLAG="${KEEP_FLAG:-1}"

case "$CRYPTO_MODE" in
  auto|xwing|mlkem|classic) ;;
  *)
    echo "usage: run_code_smoke_from_gui_auth.sh [auto|xwing|mlkem|classic]" >&2
    exit 1
    ;;
esac

TMP_DIR="$(mktemp -d /tmp/skybridge-gui-auth.XXXXXX)"
RAW_SESSION="$TMP_DIR/gui-auth-session.raw"
DECODED_SESSION="$TMP_DIR/gui-auth-session.decoded.json"
REFRESHED_SESSION="$TMP_DIR/gui-auth-session.refreshed.json"

cleanup() {
  if [[ "$KEEP_FLAG" != "1" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

security find-generic-password -s com.skybridge.compass.authsession -a primary -w > "$RAW_SESSION"

python3 - <<'PY' "$RAW_SESSION" "$DECODED_SESSION"
import json, sys
from pathlib import Path

raw_path = Path(sys.argv[1])
decoded_path = Path(sys.argv[2])
raw = raw_path.read_text().strip()
if raw.startswith('{'):
    body = raw
else:
    body = bytes.fromhex(raw).decode('utf-8')
json.loads(body)
decoded_path.write_text(body)
print(decoded_path)
PY

python3 - <<'PY' "$DECODED_SESSION" "$REFRESHED_SESSION"
import json, subprocess, sys, urllib.request
from datetime import datetime, timezone
from pathlib import Path

decoded_path = Path(sys.argv[1])
refreshed_path = Path(sys.argv[2])
session = json.loads(decoded_path.read_text())
url = subprocess.check_output(
    ['security', 'find-generic-password', '-s', 'SkyBridge.Supabase', '-a', 'URL', '-w'],
    text=True,
).strip()
anon = subprocess.check_output(
    ['security', 'find-generic-password', '-s', 'SkyBridge.Supabase', '-a', 'AnonKey', '-w'],
    text=True,
).strip()

endpoint = url.rstrip('/') + '/auth/v1/token?grant_type=refresh_token'
payload = json.dumps({'refresh_token': session['refreshToken']}).encode()
request = urllib.request.Request(
    endpoint,
    data=payload,
    method='POST',
    headers={
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + anon,
        'apikey': anon,
    },
)
with urllib.request.urlopen(request, timeout=30) as response:
    data = json.loads(response.read())

refreshed = {
    'access_token': data['access_token'],
    'refresh_token': data.get('refresh_token'),
    'user_identifier': data['user']['id'],
    'nebula_id': session.get('nebulaId') or session.get('nebula_id'),
    'display_name': data['user'].get('email') or session.get('displayName') or 'User',
    'issued_at': datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
}
refreshed_path.write_text(json.dumps(refreshed))
print(refreshed_path)
PY

ARGS=(
  cargo run --manifest-path "$ROOT_DIR/Cargo.toml" -p skybridge --
  test --mode code --crypto "$CRYPTO_MODE"
  --auth-session-file "$REFRESHED_SESSION"
  --json
)

if [[ "$KEEP_FLAG" == "1" ]]; then
  ARGS+=(--keep-temp-dir)
fi

"${ARGS[@]}"
