#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS_DIR="$ROOT_DIR/Artifacts/runs"
EXPECTED_ARTIFACT_DATE="2026-01-23"

mkdir -p "$RUNS_DIR"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[FULL-EVAL][%s] %s\n' "$(timestamp)" "$*"
}

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--status-file <path>] [--no-follow] [--resume] [run_id|pid|status_file]

Default behavior:
  - Start a full evaluation pipeline in background
  - Stream real-time logs in foreground
  - Ctrl-C stops log streaming only (background run keeps running)

Options:
  --status-file <path>  Status pointer file (default: Artifacts/runs/latest.status)
  --no-follow           Do not stream logs after launch/resume
  --resume              Resume from an existing status pointer/run id/pid
  -h, --help            Show this help
USAGE
}

list_swiftpm_conflicts() {
  python3 - <<'PY'
import re
import subprocess

pattern = re.compile(
    r'(^|/)(swift-test|swift-build|swift-package)(\s|$)|\bswift\s+(test|build|package)\b',
    re.IGNORECASE,
)

output = subprocess.check_output(
    ["ps", "-ax", "-o", "pid=", "-o", "command="],
    text=True,
)

for raw in output.splitlines():
    line = raw.strip()
    if not line:
        continue
    parts = line.split(None, 1)
    if len(parts) < 2:
        continue
    pid, command = parts
    if pattern.search(command):
        print(f"{pid} {command}")
PY
}

resolve_by_pid() {
  local target_pid="$1"
  local candidate
  for candidate in "$RUNS_DIR"/*/status.env "$RUNS_DIR"/*.status "$RUNS_DIR"/latest.status; do
    [[ -f "$candidate" ]] || continue
    local pid
    pid="$(awk -F= '$1=="PID" {print $2}' "$candidate" | tail -n 1 | tr -d '[:space:]')"
    if [[ "$pid" == "$target_pid" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

resolve_status_file() {
  local target="$1"
  local configured_status_file="$2"

  if [[ -n "$target" ]]; then
    if [[ -f "$target" ]]; then
      printf '%s\n' "$target"
      return 0
    fi
    if [[ "$target" =~ ^[0-9]+$ ]]; then
      resolve_by_pid "$target"
      return $?
    fi
    if [[ -f "$RUNS_DIR/$target/status.env" ]]; then
      printf '%s\n' "$RUNS_DIR/$target/status.env"
      return 0
    fi
    if [[ -f "$RUNS_DIR/$target.status" ]]; then
      printf '%s\n' "$RUNS_DIR/$target.status"
      return 0
    fi
    return 1
  fi

  if [[ -f "$configured_status_file" ]]; then
    printf '%s\n' "$configured_status_file"
    return 0
  fi

  if [[ -f "$RUNS_DIR/latest.status" ]]; then
    printf '%s\n' "$RUNS_DIR/latest.status"
    return 0
  fi

  local latest
  latest="$(ls -1t "$RUNS_DIR"/*/status.env 2>/dev/null | head -n 1 || true)"
  if [[ -n "$latest" ]]; then
    printf '%s\n' "$latest"
    return 0
  fi

  return 1
}

parse_status_env() {
  local status_file="$1"

  RESUME_RUN_ID=""
  RESUME_PID=""
  RESUME_RUN_DIR=""
  RESUME_LOG_FILE=""
  RESUME_STATUS_JSON=""
  RESUME_STATE=""
  RESUME_STAGE=""
  RESUME_UPDATED_AT=""

  while IFS='=' read -r key value; do
    case "$key" in
      RUN_ID) RESUME_RUN_ID="$value" ;;
      PID) RESUME_PID="$value" ;;
      RUN_DIR) RESUME_RUN_DIR="$value" ;;
      LOG_FILE) RESUME_LOG_FILE="$value" ;;
      STATUS_JSON) RESUME_STATUS_JSON="$value" ;;
      STATE) RESUME_STATE="$value" ;;
      STAGE) RESUME_STAGE="$value" ;;
      UPDATED_AT) RESUME_UPDATED_AT="$value" ;;
    esac
  done <"$status_file"
}

follow_worker_log() {
  local worker_pid="$1"
  local log_file="$2"

  mkdir -p "$(dirname "$log_file")"
  touch "$log_file"

  log "Streaming log: ${log_file}"
  tail -n 60 -F "$log_file" &
  local tail_pid=$!

  trap 'echo; log "Log streaming interrupted by user; background run continues."; kill "$tail_pid" 2>/dev/null || true; wait "$tail_pid" 2>/dev/null || true; exit 0' INT

  while kill -0 "$worker_pid" >/dev/null 2>&1; do
    sleep 2
  done

  sleep 1
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
  trap - INT
}

worker_main() {
  local run_id="$1"
  local status_file="$2"

  local run_dir="$RUNS_DIR/$run_id"
  local log_file="$run_dir/run.log"
  local status_json="$run_dir/status.json"
  local status_env="$run_dir/status.env"
  local stage_summary="$run_dir/stage_summary.tsv"
  local final_report="$run_dir/final_report.md"
  local gate_report="$run_dir/gate_report.md"
  local issue_report="$run_dir/issue_report.md"
  local snapshot_dir="$run_dir/snapshot"

  local artifact_date_value="${ARTIFACT_DATE:-}"
  local bench_batches="${SKYBRIDGE_BENCH_BATCHES:-3}"
  local bench_scope="${SKYBRIDGE_BENCH_SCOPE:-core}"
  local bench_stability_require_apple="${SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE:-0}"
  local bench_apple_iterations="${SKYBRIDGE_BENCH_APPLE_ITERATIONS:-5000}"
  local bench_cooldown_seconds="${SKYBRIDGE_BENCH_COOLDOWN_SECONDS:-5}"
  local bench_max_load_ratio="${SKYBRIDGE_BENCH_MAX_LOAD_RATIO:-0.70}"
  local bench_load_wait_seconds="${SKYBRIDGE_BENCH_LOAD_WAIT_SECONDS:-120}"
  local bench_deterministic_transport="${SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT:-1}"
  local bench_disable_handshake_padding="${SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING:-1}"
  local bench_deterministic_nonce="${SKYBRIDGE_BENCH_DETERMINISTIC_NONCE:-1}"
  local swiftpm_wait_seconds="${SKYBRIDGE_SWIFTPM_WAIT_SECONDS:-900}"
  local heartbeat_seconds="${SKYBRIDGE_HEARTBEAT_SECONDS:-30}"

  local state_value="running"
  local stage_value="bootstrap"
  local message_value="worker booting"
  local updated_at
  updated_at="$(timestamp)"

  local first_error_stage=""
  local first_error_command=""
  local first_error_code=""
  local current_stage_command=""

  write_status_files() {
    updated_at="$(timestamp)"

    mkdir -p "$(dirname "$status_file")"

    {
      echo "RUN_ID=${run_id}"
      echo "PID=$$"
      echo "RUN_DIR=${run_dir}"
      echo "LOG_FILE=${log_file}"
      echo "STATUS_JSON=${status_json}"
      echo "STATE=${state_value}"
      echo "STAGE=${stage_value}"
      echo "UPDATED_AT=${updated_at}"
      echo "ARTIFACT_DATE=${artifact_date_value}"
      echo "BENCH_BATCHES=${bench_batches}"
      echo "BENCH_SCOPE=${bench_scope}"
      echo "BENCH_STABILITY_REQUIRE_APPLE=${bench_stability_require_apple}"
      echo "BENCH_APPLE_ITERATIONS=${bench_apple_iterations}"
      echo "BENCH_COOLDOWN_SECONDS=${bench_cooldown_seconds}"
      echo "BENCH_MAX_LOAD_RATIO=${bench_max_load_ratio}"
      echo "BENCH_LOAD_WAIT_SECONDS=${bench_load_wait_seconds}"
      echo "BENCH_DETERMINISTIC_TRANSPORT=${bench_deterministic_transport}"
      echo "BENCH_DISABLE_HANDSHAKE_PADDING=${bench_disable_handshake_padding}"
      echo "BENCH_DETERMINISTIC_NONCE=${bench_deterministic_nonce}"
    } >"$status_env"

    cp "$status_env" "$status_file"

    SB_RUN_ID="$run_id" \
    SB_PID="$$" \
    SB_RUN_DIR="$run_dir" \
    SB_LOG_FILE="$log_file" \
    SB_STATUS_FILE="$status_file" \
    SB_STATE="$state_value" \
    SB_STAGE="$stage_value" \
    SB_MESSAGE="$message_value" \
    SB_UPDATED_AT="$updated_at" \
    SB_STARTED_AT="${STARTED_AT}" \
    SB_ARTIFACT_DATE="$artifact_date_value" \
    SB_BENCH_BATCHES="$bench_batches" \
    SB_BENCH_SCOPE="$bench_scope" \
    SB_BENCH_STABILITY_REQUIRE_APPLE="$bench_stability_require_apple" \
    SB_BENCH_APPLE_ITERATIONS="$bench_apple_iterations" \
    SB_BENCH_COOLDOWN_SECONDS="$bench_cooldown_seconds" \
    SB_BENCH_MAX_LOAD_RATIO="$bench_max_load_ratio" \
    SB_BENCH_LOAD_WAIT_SECONDS="$bench_load_wait_seconds" \
    SB_BENCH_DETERMINISTIC_TRANSPORT="$bench_deterministic_transport" \
    SB_BENCH_DISABLE_HANDSHAKE_PADDING="$bench_disable_handshake_padding" \
    SB_BENCH_DETERMINISTIC_NONCE="$bench_deterministic_nonce" \
    SB_SWIFTPM_WAIT="$swiftpm_wait_seconds" \
    SB_HEARTBEAT="$heartbeat_seconds" \
    SB_ERROR_STAGE="$first_error_stage" \
    SB_ERROR_COMMAND="$first_error_command" \
    SB_ERROR_CODE="$first_error_code" \
    python3 - "$status_json" <<'PY'
import json
import os
import sys

path = sys.argv[1]

def to_int(value: str):
    try:
        return int(value)
    except Exception:
        return None

data = {
    "run_id": os.environ.get("SB_RUN_ID", ""),
    "pid": to_int(os.environ.get("SB_PID", "")),
    "run_dir": os.environ.get("SB_RUN_DIR", ""),
    "log_file": os.environ.get("SB_LOG_FILE", ""),
    "status_file": os.environ.get("SB_STATUS_FILE", ""),
    "state": os.environ.get("SB_STATE", ""),
    "stage": os.environ.get("SB_STAGE", ""),
    "message": os.environ.get("SB_MESSAGE", ""),
    "started_at": os.environ.get("SB_STARTED_AT", ""),
    "updated_at": os.environ.get("SB_UPDATED_AT", ""),
    "artifact_date": os.environ.get("SB_ARTIFACT_DATE", ""),
    "bench_batches": to_int(os.environ.get("SB_BENCH_BATCHES", "")),
    "bench_scope": os.environ.get("SB_BENCH_SCOPE", ""),
    "bench_stability_require_apple": to_int(os.environ.get("SB_BENCH_STABILITY_REQUIRE_APPLE", "")),
    "bench_apple_iterations": to_int(os.environ.get("SB_BENCH_APPLE_ITERATIONS", "")),
    "bench_cooldown_seconds": to_int(os.environ.get("SB_BENCH_COOLDOWN_SECONDS", "")),
    "bench_max_load_ratio": os.environ.get("SB_BENCH_MAX_LOAD_RATIO", ""),
    "bench_load_wait_seconds": to_int(os.environ.get("SB_BENCH_LOAD_WAIT_SECONDS", "")),
    "bench_deterministic_transport": to_int(os.environ.get("SB_BENCH_DETERMINISTIC_TRANSPORT", "")),
    "bench_disable_handshake_padding": to_int(os.environ.get("SB_BENCH_DISABLE_HANDSHAKE_PADDING", "")),
    "bench_deterministic_nonce": to_int(os.environ.get("SB_BENCH_DETERMINISTIC_NONCE", "")),
    "swiftpm_wait_seconds": to_int(os.environ.get("SB_SWIFTPM_WAIT", "")),
    "heartbeat_seconds": to_int(os.environ.get("SB_HEARTBEAT", "")),
    "error_stage": os.environ.get("SB_ERROR_STAGE", ""),
    "error_command": os.environ.get("SB_ERROR_COMMAND", ""),
    "error_code": to_int(os.environ.get("SB_ERROR_CODE", "")),
}

with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=True, indent=2, sort_keys=True)
PY
  }

  update_status() {
    state_value="$1"
    stage_value="$2"
    message_value="$3"
    write_status_files
  }

  mark_stage_done() {
    local stage_name="$1"
    local done_file="$run_dir/stage_${stage_name}.done"
    : >"$done_file"
  }

  wait_for_swiftpm_idle_worker() {
    local timeout="$swiftpm_wait_seconds"
    local poll_seconds=5
    local start_epoch
    start_epoch="$(date +%s)"

    while true; do
      local conflicts
      conflicts="$(list_swiftpm_conflicts || true)"
      if [[ -z "$conflicts" ]]; then
        return 0
      fi

      local now_epoch elapsed
      now_epoch="$(date +%s)"
      elapsed=$(( now_epoch - start_epoch ))
      if (( elapsed >= timeout )); then
        echo "Timed out waiting for SwiftPM lock holders after ${elapsed}s (limit ${timeout}s)." >&2
        echo "Conflicting SwiftPM processes:" >&2
        echo "$conflicts" >&2
        return 1
      fi

      log "SwiftPM busy before pipeline start (${elapsed}s/${timeout}s); waiting..."
      echo "$conflicts"
      sleep "$poll_seconds"
    done
  }

  run_stage() {
    local stage_name="$1"
    shift

    local stage_start_iso stage_start_epoch
    stage_start_iso="$(timestamp)"
    stage_start_epoch="$(date +%s)"

    stage_value="$stage_name"
    current_stage_command="$*"
    update_status "running" "$stage_name" "running"

    log "STAGE_START ${stage_name}"

    "$@" &
    local stage_pid=$!
    local last_heartbeat_epoch="$stage_start_epoch"
    while kill -0 "$stage_pid" >/dev/null 2>&1; do
      sleep 1
      local now_epoch heartbeat_elapsed
      now_epoch="$(date +%s)"
      if (( now_epoch - last_heartbeat_epoch >= heartbeat_seconds )); then
        heartbeat_elapsed=$(( now_epoch - stage_start_epoch ))
        update_status "running" "$stage_name" "heartbeat ${heartbeat_elapsed}s"
        log "STAGE_HEARTBEAT ${stage_name} elapsed=${heartbeat_elapsed}s"
        last_heartbeat_epoch="$now_epoch"
      fi
    done
    set +e
    wait "$stage_pid"
    local stage_rc=$?
    set -e
    if (( stage_rc != 0 )); then
      return "$stage_rc"
    fi

    local stage_end_iso stage_end_epoch elapsed
    stage_end_iso="$(timestamp)"
    stage_end_epoch="$(date +%s)"
    elapsed=$(( stage_end_epoch - stage_start_epoch ))

    printf '%s\tPASS\t%s\t%s\t%s\n' "$stage_name" "$elapsed" "$stage_start_iso" "$stage_end_iso" >>"$stage_summary"
    mark_stage_done "$stage_name"
    update_status "running" "$stage_name" "completed in ${elapsed}s"
    current_stage_command=""
    log "STAGE_END ${stage_name} elapsed=${elapsed}s"
  }

  write_issue_report() {
    local final_state="$1"
    {
      echo "# Issue Report"
      echo
      echo "- Run ID: ${run_id}"
      echo "- Artifact date: ${artifact_date_value}"
      echo "- Final state: ${final_state}"
      echo
      echo "## P0 (must-fix)"
      if [[ "${final_state}" == "SUCCEEDED" ]]; then
        echo "- [ ] none"
      else
        echo "- [x] stage=${first_error_stage:-unknown} exit=${first_error_code:-unknown} cmd=${first_error_command:-unknown}"
      fi
      echo
      echo "## P1 (quality)"
      echo "- [ ] verify claims/macros/table narrative consistency by reviewer pass"
      echo
      echo "## P2 (wording)"
      echo "- [ ] optional wording and readability polish"
    } >"$issue_report"
    log "Issue report written to ${issue_report}"
  }

  snapshot_stage() {
    mkdir -p "$snapshot_dir"
    local files_to_copy=(
      "$ROOT_DIR/Artifacts/claims_${artifact_date_value}.json"
      "$ROOT_DIR/Artifacts/tamarin_skybridge_v2_proof_${artifact_date_value}.txt"
      "$ROOT_DIR/Artifacts/tamarin_skybridge_v2_summary_${artifact_date_value}.txt"
      "$ROOT_DIR/Artifacts/tamarin_skybridge_v2_summary_${artifact_date_value}.png"
      "$ROOT_DIR/Artifacts/tamarin_skybridge_v2_report_${artifact_date_value}.md"
      "$ROOT_DIR/Artifacts/handshake_bench_${artifact_date_value}.csv"
      "$ROOT_DIR/Artifacts/handshake_rtt_${artifact_date_value}.csv"
      "$ROOT_DIR/Artifacts/message_sizes_${artifact_date_value}.csv"
      "$ROOT_DIR/Artifacts/bench_stability_window_${artifact_date_value}.json"
      "$ROOT_DIR/Artifacts/ios_minor_matrix_${artifact_date_value}.md"
      "$ROOT_DIR/Docs/generated/claims_macros.tex"
      "$ROOT_DIR/Docs/tables/perf_summary.tex"
      "$ROOT_DIR/Docs/supp_tables/s12_v2_v1_compare.tex"
      "$ROOT_DIR/Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.pdf"
      "$ROOT_DIR/Docs/TDSC-2026-01-0318_supplementary.pdf"
    )
    local file_path
    for file_path in "${files_to_copy[@]}"; do
      [[ -f "$file_path" ]] || continue
      cp -f "$file_path" "$snapshot_dir/"
    done
  }

  write_final_report() {
    local final_state="$1"
    local completed_at
    completed_at="$(timestamp)"

    {
      echo "# Full Evaluation Report"
      echo
      echo "- Run ID: ${run_id}"
      echo "- Final state: ${final_state}"
      echo "- Started at: ${STARTED_AT}"
      echo "- Completed at: ${completed_at}"
      echo "- Artifact date: ${artifact_date_value}"
      echo "- Bench batches: ${bench_batches}"
      echo "- Bench scope: ${bench_scope}"
      echo "- Bench stability require Apple: ${bench_stability_require_apple}"
      echo "- Bench Apple iterations: ${bench_apple_iterations}"
      echo "- Bench cooldown seconds: ${bench_cooldown_seconds}"
      echo "- Bench max load ratio: ${bench_max_load_ratio}"
      echo "- Bench load wait seconds: ${bench_load_wait_seconds}"
      echo "- Bench deterministic transport: ${bench_deterministic_transport}"
      echo "- Bench disable handshake padding: ${bench_disable_handshake_padding}"
      echo "- Bench deterministic nonce: ${bench_deterministic_nonce}"
      echo
      echo "## Stage Durations"
      if [[ -f "$stage_summary" ]]; then
        echo
        echo "| Stage | Status | Elapsed (s) | Started | Ended |"
        echo "|---|---:|---:|---|---|"
        while IFS=$'\t' read -r stage_name stage_status stage_seconds stage_started stage_ended; do
          echo "| ${stage_name} | ${stage_status} | ${stage_seconds} | ${stage_started} | ${stage_ended} |"
        done <"$stage_summary"
      else
        echo
        echo "- No stage summary available."
      fi
      echo
      echo "## Key Artifacts"
      echo "- ${ROOT_DIR}/Artifacts/claims_${artifact_date_value}.json"
      echo "- ${ROOT_DIR}/Artifacts/tamarin_skybridge_v2_proof_${artifact_date_value}.txt"
      echo "- ${ROOT_DIR}/Artifacts/tamarin_skybridge_v2_summary_${artifact_date_value}.txt"
      echo "- ${ROOT_DIR}/Artifacts/tamarin_skybridge_v2_summary_${artifact_date_value}.png"
      echo "- ${ROOT_DIR}/Artifacts/bench_stability_window_${artifact_date_value}.json"
      echo "- ${ROOT_DIR}/Artifacts/ios_minor_matrix_${artifact_date_value}.md"
      echo "- ${ROOT_DIR}/Docs/supp_tables/s12_v2_v1_compare.tex"
      echo "- ${ROOT_DIR}/Docs/TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.pdf"
      echo "- ${ROOT_DIR}/Docs/TDSC-2026-01-0318_supplementary.pdf"
      echo "- ${gate_report}"
      echo "- ${issue_report}"
      echo "- ${snapshot_dir}"
      echo
      if [[ "$final_state" != "SUCCEEDED" ]]; then
        echo "## First Failure"
        echo "- Stage: ${first_error_stage:-unknown}"
        echo "- Exit code: ${first_error_code:-unknown}"
        echo "- Command: ${first_error_command:-unknown}"
        echo
      fi
      echo "## Paths"
      echo "- Run dir: ${run_dir}"
      echo "- Status json: ${status_json}"
      echo "- Log file: ${log_file}"
    } >"$final_report"

    log "Final report written to ${final_report}"
  }

  on_error() {
    local exit_code="$?"
    set +e

    if [[ -z "$first_error_stage" ]]; then
      first_error_stage="$stage_value"
    fi
    if [[ -z "$first_error_command" ]]; then
      if [[ -n "$current_stage_command" ]]; then
        first_error_command="$current_stage_command"
      else
        first_error_command="$BASH_COMMAND"
      fi
    fi
    if [[ -z "$first_error_code" ]]; then
      first_error_code="$exit_code"
    fi

    log "ERROR stage=${first_error_stage} exit=${first_error_code} command=${first_error_command}"

    printf '%s\tFAIL\t0\t%s\t%s\n' "${first_error_stage:-unknown}" "$(timestamp)" "$(timestamp)" >>"$stage_summary"
    update_status "failed" "${first_error_stage:-unknown}" "failed with exit ${first_error_code}"
    write_issue_report "FAILED"
    write_final_report "FAILED"
    exit "$exit_code"
  }

  trap 'on_error' ERR

  STARTED_AT="$(timestamp)"
  : >"$stage_summary"
  update_status "running" "bootstrap" "worker started"

  preflight_stage() {
    if [[ -z "$artifact_date_value" ]]; then
      echo "ARTIFACT_DATE is required (expected ${EXPECTED_ARTIFACT_DATE})." >&2
      return 1
    fi

    if [[ "$artifact_date_value" != "$EXPECTED_ARTIFACT_DATE" ]]; then
      echo "ARTIFACT_DATE must be ${EXPECTED_ARTIFACT_DATE}, got ${artifact_date_value}." >&2
      return 1
    fi

    if ! [[ "$swiftpm_wait_seconds" =~ ^[0-9]+$ ]] || [[ "$swiftpm_wait_seconds" -lt 1 ]]; then
      echo "SKYBRIDGE_SWIFTPM_WAIT_SECONDS must be an integer >= 1 (got ${swiftpm_wait_seconds})." >&2
      return 1
    fi
    if ! [[ "$heartbeat_seconds" =~ ^[0-9]+$ ]] || [[ "$heartbeat_seconds" -lt 1 ]]; then
      echo "SKYBRIDGE_HEARTBEAT_SECONDS must be an integer >= 1 (got ${heartbeat_seconds})." >&2
      return 1
    fi
    if [[ "$bench_scope" != "core" && "$bench_scope" != "full" ]]; then
      echo "SKYBRIDGE_BENCH_SCOPE must be 'core' or 'full' (got ${bench_scope})." >&2
      return 1
    fi
    if [[ "$bench_stability_require_apple" != "0" && "$bench_stability_require_apple" != "1" ]]; then
      echo "SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE must be 0 or 1 (got ${bench_stability_require_apple})." >&2
      return 1
    fi
    if ! [[ "$bench_apple_iterations" =~ ^[0-9]+$ ]] || [[ "$bench_apple_iterations" -lt 1 ]]; then
      echo "SKYBRIDGE_BENCH_APPLE_ITERATIONS must be an integer >= 1 (got ${bench_apple_iterations})." >&2
      return 1
    fi
    if ! [[ "$bench_cooldown_seconds" =~ ^[0-9]+$ ]]; then
      echo "SKYBRIDGE_BENCH_COOLDOWN_SECONDS must be an integer >= 0 (got ${bench_cooldown_seconds})." >&2
      return 1
    fi
    if ! [[ "$bench_load_wait_seconds" =~ ^[0-9]+$ ]] || [[ "$bench_load_wait_seconds" -lt 1 ]]; then
      echo "SKYBRIDGE_BENCH_LOAD_WAIT_SECONDS must be an integer >= 1 (got ${bench_load_wait_seconds})." >&2
      return 1
    fi
    if [[ "$bench_deterministic_transport" != "0" && "$bench_deterministic_transport" != "1" ]]; then
      echo "SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT must be 0 or 1 (got ${bench_deterministic_transport})." >&2
      return 1
    fi
    if [[ "$bench_disable_handshake_padding" != "0" && "$bench_disable_handshake_padding" != "1" ]]; then
      echo "SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING must be 0 or 1 (got ${bench_disable_handshake_padding})." >&2
      return 1
    fi
    if [[ "$bench_deterministic_nonce" != "0" && "$bench_deterministic_nonce" != "1" ]]; then
      echo "SKYBRIDGE_BENCH_DETERMINISTIC_NONCE must be 0 or 1 (got ${bench_deterministic_nonce})." >&2
      return 1
    fi
    if ! python3 - "$bench_max_load_ratio" <<'PY'
import sys
value = float(sys.argv[1])
if value <= 0:
    raise SystemExit(1)
PY
    then
      echo "SKYBRIDGE_BENCH_MAX_LOAD_RATIO must be float > 0 (got ${bench_max_load_ratio})." >&2
      return 1
    fi

    for dep in tamarin-prover swift python3 pdflatex pdffonts pdftotext; do
      command -v "$dep" >/dev/null 2>&1 || {
        echo "Missing dependency: ${dep}" >&2
        return 1
      }
    done

    [[ -x "$ROOT_DIR/Scripts/run_paper_eval.sh" ]] || {
      echo "Missing executable script: $ROOT_DIR/Scripts/run_paper_eval.sh" >&2
      return 1
    }
    [[ -x "$ROOT_DIR/Scripts/clean_artifacts_for_date.sh" ]] || {
      echo "Missing executable script: $ROOT_DIR/Scripts/clean_artifacts_for_date.sh" >&2
      return 1
    }
    [[ -x "$ROOT_DIR/Scripts/check_top_tier_gate.sh" ]] || {
      echo "Missing executable script: $ROOT_DIR/Scripts/check_top_tier_gate.sh" >&2
      return 1
    }
    [[ -f "$ROOT_DIR/Scripts/check_ios_minor_matrix.py" ]] || {
      echo "Missing script: $ROOT_DIR/Scripts/check_ios_minor_matrix.py" >&2
      return 1
    }
    [[ -f "$ROOT_DIR/Scripts/collect_claims.py" ]] || {
      echo "Missing script: $ROOT_DIR/Scripts/collect_claims.py" >&2
      return 1
    }
    [[ -f "$ROOT_DIR/Scripts/check_numeric_consistency.py" ]] || {
      echo "Missing script: $ROOT_DIR/Scripts/check_numeric_consistency.py" >&2
      return 1
    }
    [[ -x "$ROOT_DIR/Scripts/check_paper_consistency.sh" ]] || {
      echo "Missing executable script: $ROOT_DIR/Scripts/check_paper_consistency.sh" >&2
      return 1
    }
    [[ -f "$ROOT_DIR/Scripts/make_tables.py" ]] || {
      echo "Missing script: $ROOT_DIR/Scripts/make_tables.py" >&2
      return 1
    }
    [[ -x "$ROOT_DIR/compile_paper.sh" ]] || {
      echo "Missing executable script: $ROOT_DIR/compile_paper.sh" >&2
      return 1
    }

    ARTIFACT_DATE="$artifact_date_value" \
      python3 "$ROOT_DIR/Scripts/check_ios_minor_matrix.py" \
      --artifact-date "$artifact_date_value" \
      --output "$ROOT_DIR/Artifacts/ios_minor_matrix_${artifact_date_value}.md"

    wait_for_swiftpm_idle_worker
  }

  formal_stage() {
    ARTIFACT_DATE="$artifact_date_value" bash "$ROOT_DIR/formal/run_tamarin.sh"

    [[ -f "$ROOT_DIR/Artifacts/tamarin_skybridge_v2_proof_${artifact_date_value}.txt" ]]
    [[ -f "$ROOT_DIR/Artifacts/tamarin_skybridge_v2_summary_${artifact_date_value}.txt" ]]
    [[ -f "$ROOT_DIR/Artifacts/tamarin_skybridge_v2_summary_${artifact_date_value}.png" ]]
    [[ -f "$ROOT_DIR/Artifacts/tamarin_skybridge_v2_report_${artifact_date_value}.md" ]]
  }

  clean_stage() {
    ARTIFACT_DATE="$artifact_date_value" bash "$ROOT_DIR/Scripts/clean_artifacts_for_date.sh"
  }

  core_eval_stage() {
    ARTIFACT_DATE="$artifact_date_value" \
    SKYBRIDGE_BENCH_BATCHES="$bench_batches" \
    SKYBRIDGE_BENCH_SCOPE="$bench_scope" \
    SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE="$bench_stability_require_apple" \
    SKYBRIDGE_BENCH_APPLE_ITERATIONS="$bench_apple_iterations" \
    SKYBRIDGE_BENCH_COOLDOWN_SECONDS="$bench_cooldown_seconds" \
    SKYBRIDGE_BENCH_MAX_LOAD_RATIO="$bench_max_load_ratio" \
    SKYBRIDGE_BENCH_LOAD_WAIT_SECONDS="$bench_load_wait_seconds" \
    SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT="$bench_deterministic_transport" \
    SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING="$bench_disable_handshake_padding" \
    SKYBRIDGE_BENCH_DETERMINISTIC_NONCE="$bench_deterministic_nonce" \
    SKYBRIDGE_SWIFTPM_WAIT_SECONDS="$swiftpm_wait_seconds" \
    SKYBRIDGE_HEARTBEAT_SECONDS="$heartbeat_seconds" \
    SKYBRIDGE_WAIT_FOR_SWIFTPM_IDLE=1 \
    SKYBRIDGE_SKIP_POSTPROCESS=1 \
      bash "$ROOT_DIR/Scripts/run_paper_eval.sh"
  }

  claims_stage() {
    ARTIFACT_DATE="$artifact_date_value" \
      python3 "$ROOT_DIR/Scripts/collect_claims.py"
    [[ -f "$ROOT_DIR/Artifacts/claims_${artifact_date_value}.json" ]]
    [[ -f "$ROOT_DIR/Docs/generated/claims_macros.tex" ]]
  }

  tables_and_figures_stage() {
    ARTIFACT_DATE="$artifact_date_value" \
      python3 "$ROOT_DIR/Scripts/make_tables.py"
    ARTIFACT_DATE="$artifact_date_value" \
      python3 "$ROOT_DIR/Scripts/derive_audit_signal_fidelity.py"
    ARTIFACT_DATE="$artifact_date_value" \
      python3 "$ROOT_DIR/Scripts/plot_handshake_latency.py"
    ARTIFACT_DATE="$artifact_date_value" \
      python3 "$ROOT_DIR/Scripts/plot_policy_downgrade.py"
    ARTIFACT_DATE="$artifact_date_value" \
      python3 "$ROOT_DIR/Scripts/plot_failure_histogram.py"
    ARTIFACT_DATE="$artifact_date_value" \
      python3 "$ROOT_DIR/Scripts/generate_ieee_figures.py"
  }

  consistency_stage() {
    ARTIFACT_DATE="$artifact_date_value" \
      bash "$ROOT_DIR/Scripts/check_paper_consistency.sh"
    ARTIFACT_DATE="$artifact_date_value" \
      python3 "$ROOT_DIR/Scripts/check_numeric_consistency.py"
  }

  compile_stage() {
    ARTIFACT_DATE="$artifact_date_value" \
      bash "$ROOT_DIR/compile_paper.sh" --skip-figures
  }

  hard_gate_stage() {
    ARTIFACT_DATE="$artifact_date_value" \
    SKYBRIDGE_GATE_SKIP_COMPILE=1 \
    SKYBRIDGE_GATE_REPORT="$gate_report" \
      bash "$ROOT_DIR/Scripts/check_top_tier_gate.sh"
  }

  run_stage "preflight" preflight_stage
  run_stage "clean" clean_stage
  run_stage "formal" formal_stage
  run_stage "core_eval" core_eval_stage
  run_stage "claims" claims_stage
  run_stage "tables_figures" tables_and_figures_stage
  run_stage "consistency" consistency_stage
  run_stage "compile" compile_stage
  run_stage "top_tier_gate" hard_gate_stage
  run_stage "snapshot" snapshot_stage

  mark_stage_done "finalize"
  update_status "succeeded" "finalize" "all stages completed"
  write_issue_report "SUCCEEDED"
  write_final_report "SUCCEEDED"

  trap - ERR
  log "Pipeline completed successfully"
}

main() {
  local status_file="$RUNS_DIR/latest.status"
  local follow_logs=1
  local resume_mode=0
  local target=""

  if [[ "${1:-}" == "__worker" ]]; then
    shift
    local worker_run_id="${1:-}"
    local worker_status_file="${2:-$status_file}"
    if [[ -z "$worker_run_id" ]]; then
      echo "worker mode requires run_id" >&2
      exit 2
    fi
    worker_main "$worker_run_id" "$worker_status_file"
    exit 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status-file)
        [[ $# -ge 2 ]] || { echo "--status-file requires a path" >&2; exit 2; }
        status_file="$2"
        shift 2
        ;;
      --no-follow)
        follow_logs=0
        shift
        ;;
      --resume)
        resume_mode=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [[ -z "$target" ]]; then
          target="$1"
          shift
        else
          echo "Unexpected argument: $1" >&2
          exit 2
        fi
        ;;
    esac
  done

  if [[ "$resume_mode" -eq 1 ]]; then
    local resume_status
    if ! resume_status="$(resolve_status_file "$target" "$status_file")"; then
      echo "Unable to resolve status for resume target '${target:-<default>}'" >&2
      exit 1
    fi

    parse_status_env "$resume_status"
    [[ -n "$RESUME_RUN_ID" ]] || { echo "Malformed status file: $resume_status" >&2; exit 1; }

    log "Resuming run ${RESUME_RUN_ID} (state=${RESUME_STATE:-unknown}, stage=${RESUME_STAGE:-unknown})"

    if [[ "$follow_logs" -eq 1 && -n "$RESUME_LOG_FILE" && -n "$RESUME_PID" && "$RESUME_PID" =~ ^[0-9]+$ ]]; then
      if kill -0 "$RESUME_PID" >/dev/null 2>&1; then
        follow_worker_log "$RESUME_PID" "$RESUME_LOG_FILE"
      else
        log "Run process is not alive; showing latest log tail"
        tail -n 60 "$RESUME_LOG_FILE" 2>/dev/null || true
      fi
    fi

    log "Status: ${RESUME_STATE:-unknown} (updated=${RESUME_UPDATED_AT:-unknown})"
    if [[ -f "$RESUME_RUN_DIR/final_report.md" ]]; then
      log "Final report: $RESUME_RUN_DIR/final_report.md"
    fi

    if [[ "$RESUME_STATE" == "failed" ]]; then
      exit 1
    fi
    exit 0
  fi

  if [[ -z "${ARTIFACT_DATE:-}" ]]; then
    echo "ARTIFACT_DATE is required and must be ${EXPECTED_ARTIFACT_DATE}." >&2
    exit 2
  fi
  if [[ "${ARTIFACT_DATE}" != "${EXPECTED_ARTIFACT_DATE}" ]]; then
    echo "ARTIFACT_DATE must be ${EXPECTED_ARTIFACT_DATE}, got ${ARTIFACT_DATE}." >&2
    exit 2
  fi

  if ! [[ "${SKYBRIDGE_BENCH_BATCHES:-3}" =~ ^[0-9]+$ ]] || [[ "${SKYBRIDGE_BENCH_BATCHES:-3}" -lt 1 ]]; then
    echo "SKYBRIDGE_BENCH_BATCHES must be an integer >= 1 (got '${SKYBRIDGE_BENCH_BATCHES:-3}')." >&2
    exit 2
  fi
  if ! [[ "${SKYBRIDGE_BENCH_APPLE_ITERATIONS:-5000}" =~ ^[0-9]+$ ]] || [[ "${SKYBRIDGE_BENCH_APPLE_ITERATIONS:-5000}" -lt 1 ]]; then
    echo "SKYBRIDGE_BENCH_APPLE_ITERATIONS must be an integer >= 1 (got '${SKYBRIDGE_BENCH_APPLE_ITERATIONS:-5000}')." >&2
    exit 2
  fi
  if [[ "${SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE:-0}" != "0" && "${SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE:-0}" != "1" ]]; then
    echo "SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE must be 0 or 1 (got '${SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE:-0}')." >&2
    exit 2
  fi
  if [[ "${SKYBRIDGE_BENCH_SCOPE:-core}" != "core" && "${SKYBRIDGE_BENCH_SCOPE:-core}" != "full" ]]; then
    echo "SKYBRIDGE_BENCH_SCOPE must be 'core' or 'full' (got '${SKYBRIDGE_BENCH_SCOPE:-core}')." >&2
    exit 2
  fi

  if [[ -f "$status_file" ]]; then
    parse_status_env "$status_file"
    if [[ -n "${RESUME_PID}" && "${RESUME_PID}" =~ ^[0-9]+$ ]] && kill -0 "${RESUME_PID}" >/dev/null 2>&1; then
      echo "Active full-eval run detected (run_id=${RESUME_RUN_ID:-unknown}, pid=${RESUME_PID}). Use --resume to attach." >&2
      exit 1
    fi
  fi

  local run_id
  run_id="${SKYBRIDGE_RUN_ID:-$(date -u +%Y%m%d_%H%M%S)}"

  local run_dir="$RUNS_DIR/$run_id"
  if [[ -e "$run_dir" ]]; then
    local suffix=1
    while [[ -e "${run_dir}_${suffix}" ]]; do
      suffix=$(( suffix + 1 ))
    done
    run_id="${run_id}_${suffix}"
    run_dir="$RUNS_DIR/$run_id"
  fi

  mkdir -p "$run_dir"

  local log_file="$run_dir/run.log"
  local run_status_env="$run_dir/status.env"
  local run_status_json="$run_dir/status.json"

  nohup bash "$0" __worker "$run_id" "$status_file" >"$log_file" 2>&1 &
  local worker_pid=$!

  {
    echo "RUN_ID=${run_id}"
    echo "PID=${worker_pid}"
    echo "RUN_DIR=${run_dir}"
    echo "LOG_FILE=${log_file}"
    echo "STATUS_JSON=${run_status_json}"
    echo "STATE=launching"
    echo "STAGE=launch"
    echo "UPDATED_AT=$(timestamp)"
    echo "ARTIFACT_DATE=${ARTIFACT_DATE:-unset}"
    echo "BENCH_BATCHES=${SKYBRIDGE_BENCH_BATCHES:-3}"
    echo "BENCH_SCOPE=${SKYBRIDGE_BENCH_SCOPE:-core}"
    echo "BENCH_STABILITY_REQUIRE_APPLE=${SKYBRIDGE_BENCH_STABILITY_REQUIRE_APPLE:-0}"
    echo "BENCH_APPLE_ITERATIONS=${SKYBRIDGE_BENCH_APPLE_ITERATIONS:-5000}"
    echo "BENCH_COOLDOWN_SECONDS=${SKYBRIDGE_BENCH_COOLDOWN_SECONDS:-5}"
    echo "BENCH_MAX_LOAD_RATIO=${SKYBRIDGE_BENCH_MAX_LOAD_RATIO:-0.70}"
    echo "BENCH_LOAD_WAIT_SECONDS=${SKYBRIDGE_BENCH_LOAD_WAIT_SECONDS:-120}"
    echo "BENCH_DETERMINISTIC_TRANSPORT=${SKYBRIDGE_BENCH_DETERMINISTIC_TRANSPORT:-1}"
    echo "BENCH_DISABLE_HANDSHAKE_PADDING=${SKYBRIDGE_BENCH_DISABLE_HANDSHAKE_PADDING:-1}"
    echo "BENCH_DETERMINISTIC_NONCE=${SKYBRIDGE_BENCH_DETERMINISTIC_NONCE:-1}"
  } >"$run_status_env"

  mkdir -p "$(dirname "$status_file")"
  cp "$run_status_env" "$status_file"

  log "Launched run_id=${run_id} pid=${worker_pid}"
  log "Run dir: ${run_dir}"
  log "Log file: ${log_file}"
  log "Status file: ${status_file}"

  if [[ "$follow_logs" -eq 1 ]]; then
    follow_worker_log "$worker_pid" "$log_file"

    if [[ -f "$run_status_env" ]]; then
      parse_status_env "$run_status_env"
      log "Run finished with state=${RESUME_STATE:-unknown}"
      if [[ -f "$run_dir/final_report.md" ]]; then
        log "Final report: $run_dir/final_report.md"
      fi
      if [[ "${RESUME_STATE:-}" == "failed" ]]; then
        exit 1
      fi
    fi
  fi
}

main "$@"
