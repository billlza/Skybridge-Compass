#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS_DIR="$ROOT_DIR/Artifacts/runs"
EXPECTED_DATE="2026-01-23"

artifact_date="${ARTIFACT_DATE:-$EXPECTED_DATE}"
bench_batches="${SKYBRIDGE_BENCH_BATCHES:-3}"
bench_scope="${SKYBRIDGE_BENCH_SCOPE:-core}"
bench_stability_require_apple="${SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE:-0}"
bench_apple_iterations="${SKYBRIDGE_BENCH_APPLE_ITERATIONS:-5000}"
max_attempts="${SKYBRIDGE_STABILITY_MAX_ATTEMPTS:-3}"
max_drift="${SKYBRIDGE_STABILITY_MAX_DRIFT:-0.07}"
flagship_threshold="${SKYBRIDGE_FLAGSHIP_THRESHOLD:-0.03}"
bench_disable_handshake_padding="${SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING:-1}"
bench_deterministic_nonce="${SKYBRIDGE_BENCH_DETERMINISTIC_NONCE:-1}"
first_run_id=""
poll_seconds=30

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--first-run-id <run_id>] [--poll-seconds <n>] [--max-attempts <n>]

Environment:
  ARTIFACT_DATE                     default: ${EXPECTED_DATE}
  SKYBRIDGE_BENCH_BATCHES           default: 3
  SKYBRIDGE_BENCH_SCOPE             default: core
  SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE default: 0
  SKYBRIDGE_BENCH_APPLE_ITERATIONS  default: 5000
  SKYBRIDGE_STABILITY_MAX_ATTEMPTS  default: 3
  SKYBRIDGE_STABILITY_MAX_DRIFT     default: 0.07
  SKYBRIDGE_FLAGSHIP_THRESHOLD      default: 0.03
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --first-run-id)
      [[ $# -ge 2 ]] || { echo "--first-run-id requires a value" >&2; exit 2; }
      first_run_id="$2"
      shift 2
      ;;
    --poll-seconds)
      [[ $# -ge 2 ]] || { echo "--poll-seconds requires a value" >&2; exit 2; }
      poll_seconds="$2"
      shift 2
      ;;
    --max-attempts)
      [[ $# -ge 2 ]] || { echo "--max-attempts requires a value" >&2; exit 2; }
      max_attempts="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unexpected argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$artifact_date" != "$EXPECTED_DATE" ]]; then
  echo "ARTIFACT_DATE must be ${EXPECTED_DATE}, got ${artifact_date}" >&2
  exit 2
fi

if ! [[ "$bench_batches" =~ ^[0-9]+$ ]] || [[ "$bench_batches" -lt 1 ]]; then
  echo "SKYBRIDGE_BENCH_BATCHES must be integer >= 1 (got ${bench_batches})" >&2
  exit 2
fi
if [[ "$bench_scope" != "core" && "$bench_scope" != "full" ]]; then
  echo "SKYBRIDGE_BENCH_SCOPE must be 'core' or 'full' (got ${bench_scope})" >&2
  exit 2
fi
if ! [[ "$bench_apple_iterations" =~ ^[0-9]+$ ]] || [[ "$bench_apple_iterations" -lt 1 ]]; then
  echo "SKYBRIDGE_BENCH_APPLE_ITERATIONS must be integer >= 1 (got ${bench_apple_iterations})" >&2
  exit 2
fi
if [[ "$bench_stability_require_apple" != "0" && "$bench_stability_require_apple" != "1" ]]; then
  echo "SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE must be 0 or 1 (got ${bench_stability_require_apple})" >&2
  exit 2
fi
if ! [[ "$max_attempts" =~ ^[0-9]+$ ]] || [[ "$max_attempts" -lt 1 || "$max_attempts" -gt 3 ]]; then
  echo "max attempts must be integer in [1,3] (got ${max_attempts})" >&2
  exit 2
fi
if [[ "$bench_disable_handshake_padding" != "0" && "$bench_disable_handshake_padding" != "1" ]]; then
  echo "SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING must be 0 or 1 (got ${bench_disable_handshake_padding})" >&2
  exit 2
fi
if [[ "$bench_deterministic_nonce" != "0" && "$bench_deterministic_nonce" != "1" ]]; then
  echo "SKYBRIDGE_BENCH_DETERMINISTIC_NONCE must be 0 or 1 (got ${bench_deterministic_nonce})" >&2
  exit 2
fi
if ! [[ "$poll_seconds" =~ ^[0-9]+$ ]] || [[ "$poll_seconds" -lt 1 ]]; then
  echo "--poll-seconds must be integer >= 1 (got ${poll_seconds})" >&2
  exit 2
fi

mkdir -p "$RUNS_DIR"

LAST_STATE=""
LAST_LAUNCHED_RUN_ID=""

ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[TWO-RUN][%s] %s\n' "$(ts)" "$*"
}

status_json_for() {
  local run_id="$1"
  local status_json="$RUNS_DIR/$run_id/status.json"
  if [[ -f "$status_json" ]]; then
    printf '%s\n' "$status_json"
    return 0
  fi

  local latest_env="$RUNS_DIR/latest.status"
  if [[ -f "$latest_env" ]]; then
    local latest_run
    latest_run="$(awk -F= '$1=="RUN_ID"{print $2}' "$latest_env" | tail -n1 | tr -d '[:space:]')"
    if [[ "$latest_run" == "$run_id" && -f "$RUNS_DIR/$latest_run/status.json" ]]; then
      printf '%s\n' "$RUNS_DIR/$latest_run/status.json"
      return 0
    fi
  fi

  return 1
}

state_for() {
  local run_id="$1"
  local status_json
  if ! status_json="$(status_json_for "$run_id")"; then
    echo "unknown"
    return 0
  fi
  python3 - "$status_json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
print(data.get("state", "unknown"))
PY
}

stage_for() {
  local run_id="$1"
  local status_json
  if ! status_json="$(status_json_for "$run_id")"; then
    echo "unknown"
    return 0
  fi
  python3 - "$status_json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
stage = data.get("stage", "unknown")
message = data.get("message", "")
print(f"{stage} ({message})" if message else stage)
PY
}

wait_for_terminal() {
  local run_id="$1"
  while true; do
    local state stage
    state="$(state_for "$run_id")"
    stage="$(stage_for "$run_id")"
    log "run=${run_id} state=${state} stage=${stage}"
    case "$state" in
      succeeded|failed)
        LAST_STATE="$state"
        return 0
        ;;
    esac
    sleep "$poll_seconds"
  done
}

launch_full_eval() {
  local launch_output
  launch_output="$(ARTIFACT_DATE="$artifact_date" SKYBRIDGE_BENCH_BATCHES="$bench_batches" SKYBRIDGE_BENCH_SCOPE="$bench_scope" SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE="$bench_stability_require_apple" SKYBRIDGE_BENCH_APPLE_ITERATIONS="$bench_apple_iterations" SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING="$bench_disable_handshake_padding" SKYBRIDGE_BENCH_DETERMINISTIC_NONCE="$bench_deterministic_nonce" bash "$ROOT_DIR/Scripts/run_paper_eval_full.sh" --no-follow)"
  printf '%s\n' "$launch_output"

  local run_id
  run_id="$(printf '%s\n' "$launch_output" | sed -n 's/.*Launched run_id=\([^ ]*\) .*/\1/p' | tail -n1)"
  if [[ -z "$run_id" && -f "$RUNS_DIR/latest.status" ]]; then
    run_id="$(awk -F= '$1=="RUN_ID"{print $2}' "$RUNS_DIR/latest.status" | tail -n1 | tr -d '[:space:]')"
  fi
  if [[ -z "$run_id" ]]; then
    echo "unable to determine launched run_id" >&2
    exit 1
  fi
  LAST_LAUNCHED_RUN_ID="$run_id"
}

ensure_run_succeeded() {
  local run_id="$1"
  wait_for_terminal "$run_id"
  if [[ "$LAST_STATE" != "succeeded" ]]; then
    log "run ${run_id} finished with state=${LAST_STATE}; aborting."
    return 1
  fi
  return 0
}

run_gate_with_tee() {
  local output_file="$1"
  shift

  set +e
  "$@" | tee "$output_file"
  local cmd_rc=${PIPESTATUS[0]}
  set -e
  return "$cmd_rc"
}

retry_summary_path="$RUNS_DIR/retry_summary.md"
{
  echo "# Two-Round Stability Retry Summary"
  echo
  echo "- Started: $(ts)"
  echo "- Artifact date: ${artifact_date}"
  echo "- Bench batches: ${bench_batches}"
  echo "- Bench scope: ${bench_scope}"
  echo "- Bench stability require Apple: ${bench_stability_require_apple}"
  echo "- Bench Apple iterations: ${bench_apple_iterations}"
  echo "- Max attempts: ${max_attempts}"
  echo "- Stability threshold: ${max_drift}"
  echo "- Flagship threshold: ${flagship_threshold}"
  echo "- Disable handshake padding: ${bench_disable_handshake_padding}"
  echo "- Deterministic nonce mode: ${bench_deterministic_nonce}"
  echo
} > "$retry_summary_path"

current_run_a="$first_run_id"
if [[ -z "$current_run_a" ]]; then
  log "Launching initial baseline run"
  launch_full_eval
  current_run_a="$LAST_LAUNCHED_RUN_ID"
fi

if ! ensure_run_succeeded "$current_run_a"; then
  {
    echo "- Baseline run ${current_run_a} failed before pair attempts."
    echo
    echo "## Final Verdict"
    echo "- FAIL"
    echo "- first failure bundle: ${RUNS_DIR}/${current_run_a}/final_report.md"
    echo "- completed at: $(ts)"
  } >> "$retry_summary_path"
  exit 1
fi

attempt=1
while (( attempt <= max_attempts )); do
  log "Pair attempt ${attempt}/${max_attempts}: baseline=${current_run_a}"

  launch_full_eval
  current_run_b="$LAST_LAUNCHED_RUN_ID"
  if ! ensure_run_succeeded "$current_run_b"; then
    {
      echo "## Attempt ${attempt}"
      echo "- baseline: ${current_run_a}"
      echo "- candidate: ${current_run_b}"
      echo "- full eval: FAIL (candidate run failed)"
      echo
      echo "## Final Verdict"
      echo "- FAIL"
      echo "- first failure bundle: ${RUNS_DIR}/${current_run_b}/final_report.md"
      echo "- completed at: $(ts)"
    } >> "$retry_summary_path"
    exit 1
  fi

  stability_txt="$RUNS_DIR/stability_${current_run_a}_vs_${current_run_b}.txt"
  stability_md="$RUNS_DIR/stability_${current_run_a}_vs_${current_run_b}.md"
  flagship_txt="$RUNS_DIR/flagship_${current_run_a}_vs_${current_run_b}.txt"
  flagship_md="$RUNS_DIR/${current_run_b}/flagship_report.md"
  ios_txt="$RUNS_DIR/ios_minor_matrix_${current_run_a}_vs_${current_run_b}.txt"
  ios_md="$ROOT_DIR/Artifacts/ios_minor_matrix_${artifact_date}.md"

  stability_rc=0
  flagship_rc=0
  ios_rc=0

  log "Running stability gate for ${current_run_a} vs ${current_run_b}"
  set +e
  run_gate_with_tee "$stability_txt" \
    python3 "$ROOT_DIR/Scripts/check_stability.py" \
      --run-a "$current_run_a" \
      --run-b "$current_run_b" \
      --artifact-date "$artifact_date" \
      --max-drift "$max_drift" \
      --output "$stability_md"
  stability_rc=$?
  set -e

  log "Running flagship-performance gate for ${current_run_a} vs ${current_run_b}"
  set +e
  run_gate_with_tee "$flagship_txt" \
    python3 "$ROOT_DIR/Scripts/check_flagship_performance.py" \
      --run-a "$current_run_a" \
      --run-b "$current_run_b" \
      --artifact-date "$artifact_date" \
      --threshold "$flagship_threshold" \
      --output "$flagship_md"
  flagship_rc=$?
  set -e

  log "Running iOS minor-version matrix gate"
  set +e
  run_gate_with_tee "$ios_txt" \
    python3 "$ROOT_DIR/Scripts/check_ios_minor_matrix.py" \
      --artifact-date "$artifact_date" \
      --output "$ios_md"
  ios_rc=$?
  set -e

  pair_ok=1
  if [[ "$stability_rc" -ne 0 || "$flagship_rc" -ne 0 || "$ios_rc" -ne 0 ]]; then
    pair_ok=0
  fi

  {
    echo "## Attempt ${attempt}"
    echo "- baseline: ${current_run_a}"
    echo "- candidate: ${current_run_b}"
    echo "- stability gate: $([[ "$stability_rc" -eq 0 ]] && echo PASS || echo FAIL) (${stability_txt})"
    echo "- flagship gate: $([[ "$flagship_rc" -eq 0 ]] && echo PASS || echo FAIL) (${flagship_txt})"
    echo "- iOS minor matrix gate: $([[ "$ios_rc" -eq 0 ]] && echo PASS || echo FAIL) (${ios_txt})"
    echo "- flagship report: ${flagship_md}"
    echo "- stability report: ${stability_md}"
    echo
  } >> "$retry_summary_path"

  if [[ "$pair_ok" -eq 1 ]]; then
    log "Pair attempt ${attempt} passed all hard gates."
    {
      echo "## Final Verdict"
      echo "- PASS"
      echo "- final baseline: ${current_run_a}"
      echo "- final candidate: ${current_run_b}"
      echo "- completed at: $(ts)"
    } >> "$retry_summary_path"
    log "Retry summary: $retry_summary_path"
    exit 0
  fi

  if (( attempt == max_attempts )); then
    log "Reached max attempts (${max_attempts}) without stable passing pair."
    {
      echo "## Final Verdict"
      echo "- FAIL"
      echo "- first failure bundle:"
      echo "  - stability: ${stability_txt}"
      echo "  - flagship: ${flagship_txt}"
      echo "  - ios matrix: ${ios_txt}"
      echo "- completed at: $(ts)"
    } >> "$retry_summary_path"
    log "Retry summary: $retry_summary_path"
    exit 1
  fi

  log "Pair attempt ${attempt} failed; sliding window (next baseline=${current_run_b})"
  current_run_a="$current_run_b"
  attempt=$(( attempt + 1 ))
done

exit 1
