#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-mild}"
PROFILES_JSON="${PROFILES_JSON:-Scripts/netem_profiles.json}"
PORT="${PORT:-44444}"
PIPE_ID="${PIPE_ID:-1}"
ANCHOR="${ANCHOR:-skybridge_kernel_emu}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --profiles-json) PROFILES_JSON="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --pipe-id) PIPE_ID="$2"; shift 2 ;;
    --anchor) ANCHOR="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$PROFILES_JSON" ]]; then
  echo "profiles file not found: $PROFILES_JSON" >&2
  exit 1
fi

read -r DELAY_MS JITTER_MS LOSS_PCT REORDER_PCT < <(
  python3 - "$PROFILES_JSON" "$PROFILE" <<'PY'
import json,sys
path,profile=sys.argv[1],sys.argv[2]
doc=json.load(open(path,'r',encoding='utf-8'))
for item in doc.get("profiles",[]):
    if item.get("id")==profile:
        print(int(item.get("delay_ms",0)),int(item.get("jitter_ms",0)),float(item.get("loss_pct",0.0)),float(item.get("reorder_pct",0.0)))
        break
else:
    raise SystemExit(f"profile not found: {profile}")
PY
)

if [[ "$REORDER_PCT" != "0.0" && "$REORDER_PCT" != "0" ]]; then
  echo "warning: dummynet does not provide netem-style packet reorder controls; reorder profile will be marked n/a" >&2
fi

PLR="$(python3 - "$LOSS_PCT" <<'PY'
import sys
loss=float(sys.argv[1])
print(f"{max(0.0,min(100.0,loss))/100.0:.6f}")
PY
)"

sudo pfctl -E >/dev/null 2>&1 || true
sudo dnctl -q pipe "$PIPE_ID" config delay "${DELAY_MS}ms" plr "$PLR"

cat <<RULES | sudo pfctl -a "$ANCHOR" -f -
dummynet in proto tcp from any to any port $PORT pipe $PIPE_ID
dummynet in proto tcp from any port $PORT to any pipe $PIPE_ID
dummynet out proto tcp from any to any port $PORT pipe $PIPE_ID
dummynet out proto tcp from any port $PORT to any pipe $PIPE_ID
RULES

echo "Applied dummynet profile=$PROFILE delay=${DELAY_MS}ms jitter=${JITTER_MS}ms(loss-only approximation) loss=${LOSS_PCT}% port=$PORT pipe=$PIPE_ID anchor=$ANCHOR"
