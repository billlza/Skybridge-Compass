#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-mild}"
PROFILES_JSON="${PROFILES_JSON:-Scripts/netem_profiles.json}"
IFACE="${IFACE:-lo}"
SEED="${SEED:-20260211}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --profiles-json) PROFILES_JSON="$2"; shift 2 ;;
    --iface) IFACE="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
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

cmd=(sudo tc qdisc replace dev "$IFACE" root netem delay "${DELAY_MS}ms" "${JITTER_MS}ms" loss "${LOSS_PCT}%")
if [[ "$REORDER_PCT" != "0.0" && "$REORDER_PCT" != "0" ]]; then
  cmd+=(reorder "${REORDER_PCT}%" 50%)
fi
cmd+=(seed "$SEED")
"${cmd[@]}"

echo "Applied netem profile=$PROFILE iface=$IFACE delay=${DELAY_MS}ms jitter=${JITTER_MS}ms loss=${LOSS_PCT}% reorder=${REORDER_PCT}% seed=$SEED"
