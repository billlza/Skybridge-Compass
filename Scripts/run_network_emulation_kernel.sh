#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PROFILES_JSON="${PROFILES_JSON:-Scripts/netem_profiles.json}"
TOOL="${TOOL:-auto}"                      # auto|dummynet|netem|all
ARTIFACT_DATE="${ARTIFACT_DATE:-${SKYBRIDGE_ARTIFACT_DATE:-$(date +%F)}}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-44444}"
SAMPLES="${SAMPLES:-200}"
TIMEOUT_MS="${TIMEOUT_MS:-6000}"
IFACE="${IFACE:-}"
NETEM_SEED="${NETEM_SEED:-20260211}"
START_SERVER="${START_SERVER:-1}"
APPEND_OUTPUT="${APPEND_OUTPUT:-0}"

if [[ "$(uname -s)" == "Linux" ]]; then
  REALNET_E2E_CMD=(python3 Scripts/run_real_network_e2e_linux.py)
else
  REALNET_E2E_CMD=(swift Scripts/run_real_network_e2e.swift)
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool) TOOL="$2"; shift 2 ;;
    --profiles-json) PROFILES_JSON="$2"; shift 2 ;;
    --artifact-date) ARTIFACT_DATE="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    --timeout-ms) TIMEOUT_MS="$2"; shift 2 ;;
    --iface) IFACE="$2"; shift 2 ;;
    --netem-seed) NETEM_SEED="$2"; shift 2 ;;
    --start-server) START_SERVER="$2"; shift 2 ;;
    --append) APPEND_OUTPUT="$2"; shift 2 ;;
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

if [[ -z "$IFACE" ]]; then
  case "$(uname -s)" in
    Darwin) IFACE="lo0" ;;
    Linux) IFACE="lo" ;;
    *) IFACE="lo" ;;
  esac
fi

if [[ "$(uname -s)" == "Darwin" && "$TOOL" != "netem" ]]; then
  if [[ "$HOST" == "127.0.0.1" || "$HOST" == "localhost" ]]; then
    echo "WARN: dummynet + localhost may under-shape traffic on some macOS setups; prefer HOST=<remote-ip> with START_SERVER=0 for publishable data." >&2
  fi
fi

OUTPUT_CSV="Artifacts/network_emulation_kernel_${ARTIFACT_DATE}.csv"
if [[ "$APPEND_OUTPUT" != "1" || ! -f "$OUTPUT_CSV" ]]; then
  cat > "$OUTPUT_CSV" <<'CSV'
tool,os,profile,seed,suite,n_total,n_success,completion,p50,p95,p99,notes
CSV
fi

SUITE_PAYLOADS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && SUITE_PAYLOADS+=("$line")
done < <(
  python3 - "$PROFILES_JSON" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1],'r',encoding='utf-8'))
for suite,payload in (doc.get("suite_payload_bytes") or {}).items():
    print(f"{suite},{int(payload)}")
PY
)

if [[ ${#SUITE_PAYLOADS[@]} -eq 0 ]]; then
  echo "suite_payload_bytes missing in $PROFILES_JSON" >&2
  exit 1
fi

SERVER_PID=""

cleanup() {
  set +e
  if [[ "$(uname -s)" == "Darwin" ]]; then
    bash Scripts/netem/macos_dummynet_clear.sh --pipe-id 1 --anchor skybridge_kernel_emu >/dev/null 2>&1
  fi
  if [[ "$(uname -s)" == "Linux" ]]; then
    bash Scripts/netem/linux_netem_clear.sh --iface "$IFACE" >/dev/null 2>&1
  fi
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "$START_SERVER" == "1" ]]; then
  "${REALNET_E2E_CMD[@]}" server --bind "0.0.0.0:${PORT}" >/tmp/skybridge_kernel_server.log 2>&1 &
  SERVER_PID="$!"
  sleep 2
fi

append_row() {
  echo "$1,$2,$3,$4,$5,$6,$7,$8,$9,${10},${11},${12}" >> "$OUTPUT_CSV"
}

collect_summary_row() {
  local summary_csv="$1"
  python3 - "$summary_csv" <<'PY'
import csv,sys
path=sys.argv[1]
rows=list(csv.DictReader(open(path,'r',encoding='utf-8')))
if not rows:
    print("0,0,0,,,,")
    raise SystemExit(0)
r=rows[0]
samples=r.get("samples","0") or "0"
ok=r.get("ok_count","0") or "0"
completion=r.get("ok_rate","0") or "0"
p50=r.get("total_p50_ms","")
p95=r.get("total_p95_ms","")
p99=r.get("total_p99_ms","")
print(f"{samples},{ok},{completion},{p50},{p95},{p99}")
PY
}

run_client_suite() {
  local tool="$1"
  local profile="$2"
  local suite="$3"
  local payload="$4"
  local seed="$5"

  local label="kernel_${tool}_${profile}_${suite}"

  if [[ "$tool" == "dummynet" ]]; then
    bash Scripts/netem/macos_dummynet_apply.sh \
      --profile "$profile" \
      --profiles-json "$PROFILES_JSON" \
      --port "$PORT" \
      --pipe-id 1 \
      --anchor skybridge_kernel_emu
  else
    bash Scripts/netem/linux_netem_apply.sh \
      --profile "$profile" \
      --profiles-json "$PROFILES_JSON" \
      --iface "$IFACE" \
      --seed "$seed"
  fi

  ARTIFACT_DATE="$ARTIFACT_DATE" "${REALNET_E2E_CMD[@]}" client \
    --label "$label" \
    --connect "${HOST}:${PORT}" \
    --samples "$SAMPLES" \
    --timeout-ms "$TIMEOUT_MS" \
    --bytes "$payload" \
    --out-dir "Artifacts"

  local summary_csv="Artifacts/realnet_e2e_summary_${ARTIFACT_DATE}_${label}.csv"
  if [[ ! -f "$summary_csv" ]]; then
    append_row "$tool" "$(uname -s)" "$profile" "$seed" "$suite" "0" "0" "0" "" "" "" "summary_missing"
  else
    IFS=',' read -r n_total n_success completion p50 p95 p99 <<<"$(collect_summary_row "$summary_csv")"
    append_row "$tool" "$(uname -s)" "$profile" "$seed" "$suite" "$n_total" "$n_success" "$completion" "$p50" "$p95" "$p99" ""
  fi

  if [[ "$tool" == "dummynet" ]]; then
    bash Scripts/netem/macos_dummynet_clear.sh --pipe-id 1 --anchor skybridge_kernel_emu
  else
    bash Scripts/netem/linux_netem_clear.sh --iface "$IFACE"
  fi
}

select_tools() {
  case "$TOOL" in
    auto)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "dummynet"
      elif [[ "$(uname -s)" == "Linux" ]]; then
        echo "netem"
      else
        echo ""
      fi
      ;;
    dummynet|netem)
      echo "$TOOL"
      ;;
    all)
      echo "dummynet netem"
      ;;
    *)
      echo "invalid tool: $TOOL" >&2
      exit 2
      ;;
  esac
}

TOOLS_TO_RUN="$(select_tools)"
if [[ -z "$TOOLS_TO_RUN" ]]; then
  echo "No supported tool for this OS/tool selection." >&2
  exit 1
fi

COMMON_PROFILES=(mild moderate severe)
REORDER_PROFILE="reorder"

for tool_name in $TOOLS_TO_RUN; do
  if [[ "$tool_name" == "dummynet" && "$(uname -s)" != "Darwin" ]]; then
    for profile in "${COMMON_PROFILES[@]}" "$REORDER_PROFILE"; do
      for item in "${SUITE_PAYLOADS[@]}"; do
        suite="${item%%,*}"
        append_row "$tool_name" "$(uname -s)" "$profile" "n/a" "$suite" "0" "" "" "" "" "" "unsupported_on_this_os"
      done
    done
    continue
  fi
  if [[ "$tool_name" == "netem" && "$(uname -s)" != "Linux" ]]; then
    for profile in "${COMMON_PROFILES[@]}" "$REORDER_PROFILE"; do
      for item in "${SUITE_PAYLOADS[@]}"; do
        suite="${item%%,*}"
        append_row "$tool_name" "$(uname -s)" "$profile" "n/a" "$suite" "0" "" "" "" "" "" "unsupported_on_this_os"
      done
    done
    continue
  fi

  for profile in "${COMMON_PROFILES[@]}"; do
    seed="$NETEM_SEED"
    if [[ "$tool_name" == "netem" ]]; then
      seed="$(python3 - "$NETEM_SEED" "$profile" <<'PY'
import sys
base=int(sys.argv[1])
profile=sys.argv[2]
delta={"mild":1,"moderate":2,"severe":3,"reorder":4}.get(profile,0)
print(base+delta)
PY
)"
    else
      seed="n/a"
    fi
    for item in "${SUITE_PAYLOADS[@]}"; do
      suite="${item%%,*}"
      payload="${item##*,}"
      run_client_suite "$tool_name" "$profile" "$suite" "$payload" "$seed"
    done
  done

  for item in "${SUITE_PAYLOADS[@]}"; do
    suite="${item%%,*}"
    payload="${item##*,}"
    if [[ "$tool_name" == "netem" ]]; then
      run_client_suite "$tool_name" "$REORDER_PROFILE" "$suite" "$payload" "$((NETEM_SEED + 4))"
    else
      append_row "$tool_name" "$(uname -s)" "$REORDER_PROFILE" "n/a" "$suite" "0" "" "" "" "" "" "n/a_dummynet_no_reorder"
    fi
  done
done

echo "Wrote kernel emulation CSV: $OUTPUT_CSV"
