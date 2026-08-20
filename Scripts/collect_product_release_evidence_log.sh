#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$ROOT_DIR/Scripts/validate_product_release_evidence_log.py"
PROCESS_OWNERSHIP_HELPER="$ROOT_DIR/Scripts/webrtc_smoke_process_ownership.py"

usage() {
  cat <<'USAGE'
Collect privacy-safe release evidence from one exact running candidate process.

Usage:
  collect_product_release_evidence_log.sh \
    --pid <SkyBridgeCompassApp pid> \
    --candidate-manifest <macos-release-candidate.json> \
    --candidate-app <SkyBridge Compass Pro.app> \
    --candidate-dmg <SkyBridgeCompassPro-<version>.dmg> \
    --timeout-seconds <seconds> \
    [--stop-file <private operator checkpoint file>] \
    --artifact-dir <existing evidence directory>

The caller starts the normal candidate through its ordinary UI, starts this
collector, performs the externally observed UI session, and waits for capture
completion. Raw unified-log metadata stays in a private temporary directory;
only the fixed public message schema and process-binding manifest are retained.
USAGE
}

PID=""
CANDIDATE_MANIFEST=""
CANDIDATE_APP=""
CANDIDATE_DMG=""
TIMEOUT_SECONDS=""
ARTIFACT_DIR=""
STOP_FILE=""

while (( $# > 0 )); do
  case "$1" in
    --pid)
      PID="${2:-}"
      shift 2
      ;;
    --candidate-manifest)
      CANDIDATE_MANIFEST="${2:-}"
      shift 2
      ;;
    --candidate-app)
      CANDIDATE_APP="${2:-}"
      shift 2
      ;;
    --candidate-dmg)
      CANDIDATE_DMG="${2:-}"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --artifact-dir)
      ARTIFACT_DIR="${2:-}"
      shift 2
      ;;
    --stop-file)
      STOP_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$PID" =~ ^[1-9][0-9]*$ ]] || (( PID <= 1 )); then
  echo "--pid must be an integer greater than one" >&2
  exit 2
fi
if [[ ! "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || (( TIMEOUT_SECONDS < 5 || TIMEOUT_SECONDS > 1800 )); then
    echo "--timeout-seconds must be an integer from 5 through 1800" >&2
    exit 2
fi
for candidate_path in "$CANDIDATE_MANIFEST" "$CANDIDATE_APP" "$CANDIDATE_DMG" "$ARTIFACT_DIR"; do
  [[ "$candidate_path" == /* ]] || {
    echo "candidate and artifact paths must be absolute" >&2
    exit 2
  }
done
[[ -f "$CANDIDATE_MANIFEST" && ! -L "$CANDIDATE_MANIFEST" ]] || {
  echo "candidate manifest must be a real file" >&2
  exit 2
}
[[ -d "$CANDIDATE_APP" && ! -L "$CANDIDATE_APP" ]] || {
  echo "candidate app must be a real directory" >&2
  exit 2
}
[[ -f "$CANDIDATE_DMG" && ! -L "$CANDIDATE_DMG" ]] || {
  echo "candidate DMG must be a real file" >&2
  exit 2
}
[[ -d "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" ]] || {
  echo "artifact directory must be a real directory" >&2
  exit 2
}
if [[ -n "$STOP_FILE" ]]; then
  [[ "$STOP_FILE" == /* && ! -e "$STOP_FILE" && ! -L "$STOP_FILE" ]] || {
    echo "stop-file must be a new absolute path" >&2
    exit 2
  }
  [[ -d "$(dirname "$STOP_FILE")" && ! -L "$(dirname "$STOP_FILE")" ]] || {
    echo "stop-file parent must be a real directory" >&2
    exit 2
  }
fi

CANDIDATE_EXECUTABLE="$CANDIDATE_APP/Contents/MacOS/SkyBridgeCompassApp"
[[ -f "$CANDIDATE_EXECUTABLE" && ! -L "$CANDIDATE_EXECUTABLE" && -x "$CANDIDATE_EXECUTABLE" ]] || {
  echo "candidate app is missing the normal SkyBridgeCompassApp executable" >&2
  exit 1
}
python3 "$ROOT_DIR/Scripts/macos_release_candidate_identity.py" verify \
  --identity "$CANDIDATE_MANIFEST" \
  --app "$CANDIDATE_APP" \
  --dmg "$CANDIDATE_DMG"

EXPECTED_EXECUTABLE="$(cd "$(dirname "$CANDIDATE_EXECUTABLE")" && pwd -P)/$(basename "$CANDIDATE_EXECUTABLE")"

OUTPUT_LOG="$ARTIFACT_DIR/mac-product-session.log"
OUTPUT_CAPTURE="$ARTIFACT_DIR/mac-product-session-capture.json"
[[ ! -e "$OUTPUT_LOG" && ! -L "$OUTPUT_LOG" && ! -e "$OUTPUT_CAPTURE" && ! -L "$OUTPUT_CAPTURE" ]] || {
  echo "product release evidence outputs already exist" >&2
  exit 1
}

PRIVATE_CAPTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-product-evidence.XXXXXX")"
chmod 0700 "$PRIVATE_CAPTURE_DIR"
LOG_STREAM_PID=""
cleanup() {
  if [[ -n "$LOG_STREAM_PID" ]] && kill -0 "$LOG_STREAM_PID" >/dev/null 2>&1; then
    kill -TERM "$LOG_STREAM_PID" >/dev/null 2>&1 || true
    wait "$LOG_STREAM_PID" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$PRIVATE_CAPTURE_DIR"
}
trap cleanup EXIT
RAW_OSLOG="$PRIVATE_CAPTURE_DIR/product-session.ndjson"
OWNERSHIP_RECORD="$PRIVATE_CAPTURE_DIR/candidate-process-ownership.json"

python3 "$PROCESS_OWNERSHIP_HELPER" mac-capture \
  --pid "$PID" \
  --expected-executable "$EXPECTED_EXECUTABLE" \
  --output "$OWNERSHIP_RECORD"
if python3 "$PROCESS_OWNERSHIP_HELPER" mac-status --identity "$OWNERSHIP_RECORD"; then
  :
else
  status=$?
  echo "candidate process ownership is not current before evidence capture (status=$status)" >&2
  exit 1
fi

if [[ -z "$STOP_FILE" ]]; then
  /usr/bin/log stream \
    --style ndjson \
    --process "$PID" \
    --predicate 'subsystem == "com.skybridge.compass.release-evidence" AND category == "ProductSession"' \
    --timeout "${TIMEOUT_SECONDS}s" \
    >"$RAW_OSLOG"
else
  /usr/bin/log stream \
    --style ndjson \
    --process "$PID" \
    --predicate 'subsystem == "com.skybridge.compass.release-evidence" AND category == "ProductSession"' \
    --timeout "${TIMEOUT_SECONDS}s" \
    >"$RAW_OSLOG" &
  LOG_STREAM_PID="$!"
  started_at="$(date +%s)"
  while [[ ! -e "$STOP_FILE" ]]; do
    if ! kill -0 "$LOG_STREAM_PID" >/dev/null 2>&1; then
      wait "$LOG_STREAM_PID" >/dev/null 2>&1 || true
      LOG_STREAM_PID=""
      echo "product log stream exited before the operator checkpoint" >&2
      exit 1
    fi
    if ! python3 "$PROCESS_OWNERSHIP_HELPER" mac-status --identity "$OWNERSHIP_RECORD"; then
      echo "candidate ownership changed before the operator checkpoint" >&2
      exit 1
    fi
    if (( "$(date +%s)" - started_at >= TIMEOUT_SECONDS )); then
      echo "timed out waiting for the product evidence operator checkpoint" >&2
      exit 1
    fi
    sleep 0.25
  done
  [[ -f "$STOP_FILE" && ! -L "$STOP_FILE" ]] || {
    echo "product evidence stop-file is not a regular file" >&2
    exit 1
  }
  kill -TERM "$LOG_STREAM_PID"
  set +e
  wait "$LOG_STREAM_PID"
  stream_status="$?"
  set -e
  LOG_STREAM_PID=""
  case "$stream_status" in
    0|143) ;;
    *)
      echo "product log stream stopped unexpectedly (status=$stream_status)" >&2
      exit 1
      ;;
  esac
fi

if python3 "$PROCESS_OWNERSHIP_HELPER" mac-status --identity "$OWNERSHIP_RECORD"; then
  :
else
  status=$?
  echo "candidate PID/start-time/audit-token ownership changed during evidence capture (status=$status)" >&2
  exit 1
fi

python3 "$VALIDATOR" extract-oslog \
  --input "$RAW_OSLOG" \
  --expected-pid "$PID" \
  --expected-process-image-path "$EXPECTED_EXECUTABLE" \
  --ownership-record "$OWNERSHIP_RECORD" \
  --output "$OUTPUT_LOG" \
  --capture-output "$OUTPUT_CAPTURE"

echo "product release evidence captured: $OUTPUT_LOG"
