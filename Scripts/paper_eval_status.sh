#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS_DIR="$ROOT_DIR/Artifacts/runs"
DEFAULT_STATUS_FILE="$RUNS_DIR/latest.status"
TAIL_LINES="${SKYBRIDGE_STATUS_TAIL_LINES:-20}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [run_id|pid|status_file]

Examples:
  bash Scripts/paper_eval_status.sh
  bash Scripts/paper_eval_status.sh 20260214_193000
  bash Scripts/paper_eval_status.sh 12345
  bash Scripts/paper_eval_status.sh Artifacts/runs/latest.status
USAGE
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
  local target="${1:-}"

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

  if [[ -f "$DEFAULT_STATUS_FILE" ]]; then
    printf '%s\n' "$DEFAULT_STATUS_FILE"
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

  RUN_ID=""
  PID_VALUE=""
  RUN_DIR=""
  LOG_FILE=""
  STATUS_JSON=""
  STATE=""
  STAGE=""
  UPDATED_AT=""
  ARTIFACT_DATE_VALUE=""
  BENCH_BATCHES=""

  while IFS='=' read -r key value; do
    case "$key" in
      RUN_ID) RUN_ID="$value" ;;
      PID) PID_VALUE="$value" ;;
      RUN_DIR) RUN_DIR="$value" ;;
      LOG_FILE) LOG_FILE="$value" ;;
      STATUS_JSON) STATUS_JSON="$value" ;;
      STATE) STATE="$value" ;;
      STAGE) STAGE="$value" ;;
      UPDATED_AT) UPDATED_AT="$value" ;;
      ARTIFACT_DATE) ARTIFACT_DATE_VALUE="$value" ;;
      BENCH_BATCHES) BENCH_BATCHES="$value" ;;
    esac
  done <"$status_file"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  local target="${1:-}"
  local status_file
  if ! status_file="$(resolve_status_file "$target")"; then
    echo "No matching run status found." >&2
    exit 1
  fi

  parse_status_env "$status_file"

  local alive="no"
  if [[ -n "$PID_VALUE" && "$PID_VALUE" =~ ^[0-9]+$ ]] && kill -0 "$PID_VALUE" >/dev/null 2>&1; then
    alive="yes"
  fi

  local health="unknown"
  if [[ "$alive" == "yes" && "$STATE" == "running" ]]; then
    health="healthy"
  elif [[ "$STATE" == "succeeded" ]]; then
    health="completed"
  elif [[ "$STATE" == "failed" ]]; then
    health="failed"
  elif [[ "$alive" == "yes" ]]; then
    health="running"
  else
    health="stale"
  fi

  echo "Run ID      : ${RUN_ID:-unknown}"
  echo "PID         : ${PID_VALUE:-unknown} (alive=${alive})"
  echo "State       : ${STATE:-unknown}"
  echo "Health      : ${health}"
  echo "Stage       : ${STAGE:-unknown}"
  echo "Updated At  : ${UPDATED_AT:-unknown}"
  echo "ArtifactDate: ${ARTIFACT_DATE_VALUE:-unknown}"
  echo "Batches     : ${BENCH_BATCHES:-unknown}"
  echo "Run Dir     : ${RUN_DIR:-unknown}"
  echo "Log File    : ${LOG_FILE:-unknown}"
  echo "Status File : ${status_file}"

  if [[ -n "$STATUS_JSON" && -f "$STATUS_JSON" ]]; then
    echo "Status JSON : ${STATUS_JSON}"
    python3 - "$STATUS_JSON" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

message = data.get("message")
if message:
    print(f"Message     : {message}")

error_stage = data.get("error_stage")
error_cmd = data.get("error_command")
if error_stage:
    print(f"Error Stage : {error_stage}")
if error_cmd:
    print(f"Error Cmd   : {error_cmd}")
PY
  fi

  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    echo
    echo "Last ${TAIL_LINES} log lines:"
    tail -n "$TAIL_LINES" "$LOG_FILE"
  fi
}

main "$@"
