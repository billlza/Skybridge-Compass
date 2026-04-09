#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BASELINE_DIR=""
ACTUAL_DIR="artifacts/screenshots/android/actual"
REPORT_DIR="artifacts/screenshots/android/diff"
CAPTURE_FIRST=0
MAX_DIFF_RATIO="0.0"
MAX_MEAN_DELTA="0.0"
MAX_CHANNEL_DELTA="0"
PIXEL_TOLERANCE="0"
ALLOW_EXTRA_ACTUAL=0

usage() {
  cat <<'EOF'
Usage: scripts/screenshot_diff_gate.sh --baseline-dir <dir> [options]

Options:
  --baseline-dir <dir>       Baseline PNG root (required)
  --actual-dir <dir>         Actual PNG root (default: artifacts/screenshots/android/actual)
  --report-dir <dir>         Diff report output (default: artifacts/screenshots/android/diff)
  --capture-first            Capture fresh screenshots before diff
  --max-diff-ratio <float>   Max allowed differing-pixel ratio (default: 0.0)
  --max-mean-delta <float>   Max allowed mean channel delta (default: 0.0)
  --max-channel-delta <int>  Max allowed channel delta per pixel (default: 0)
  --pixel-tolerance <int>    Ignore per-channel diffs <= tolerance (default: 0)
  --allow-extra-actual       Do not fail on unexpected extra actual images
  -h, --help                 Show this help

Examples:
  scripts/screenshot_diff_gate.sh --baseline-dir artifacts/screenshots/android/baseline
  scripts/screenshot_diff_gate.sh --baseline-dir artifacts/screenshots/android/baseline --capture-first
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline-dir) BASELINE_DIR="$2"; shift 2 ;;
    --actual-dir) ACTUAL_DIR="$2"; shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --capture-first) CAPTURE_FIRST=1; shift 1 ;;
    --max-diff-ratio) MAX_DIFF_RATIO="$2"; shift 2 ;;
    --max-mean-delta) MAX_MEAN_DELTA="$2"; shift 2 ;;
    --max-channel-delta) MAX_CHANNEL_DELTA="$2"; shift 2 ;;
    --pixel-tolerance) PIXEL_TOLERANCE="$2"; shift 2 ;;
    --allow-extra-actual) ALLOW_EXTRA_ACTUAL=1; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$BASELINE_DIR" ]]; then
  echo "--baseline-dir is required" >&2
  usage
  exit 1
fi

if [[ "$CAPTURE_FIRST" -eq 1 ]]; then
  echo "==> Capturing screenshots from connected Android devices"
  bash scripts/android_device_matrix_capture.sh --output-dir "$ACTUAL_DIR"
fi

echo "==> Running pixel diff gate"
PY_ARGS=(
  "--baseline-dir" "$BASELINE_DIR"
  "--actual-dir" "$ACTUAL_DIR"
  "--output-dir" "$REPORT_DIR"
  "--max-diff-ratio" "$MAX_DIFF_RATIO"
  "--max-mean-delta" "$MAX_MEAN_DELTA"
  "--max-channel-delta" "$MAX_CHANNEL_DELTA"
  "--pixel-tolerance" "$PIXEL_TOLERANCE"
)
if [[ "$ALLOW_EXTRA_ACTUAL" -eq 1 ]]; then
  PY_ARGS+=("--allow-extra-actual")
fi

python3 scripts/visual_diff_gate.py "${PY_ARGS[@]}"
