#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BASELINE_VIDEO=""
ACTUAL_VIDEO=""
OUTPUT_DIR="artifacts/video-diff"
FPS="30"
PIXEL_TOLERANCE="0"
MAX_FRAME_DIFF_RATIO="0.0"
MAX_FRAME_MEAN_DELTA="0.0"
MAX_FRAME_CHANNEL_DELTA="0"
MAX_FRAME_COUNT_DELTA="0"
MAX_SPEED_DELTA="0.015"
MAX_DENSITY_DELTA="0.010"
MAX_OPACITY_DELTA="0.010"
MAX_DIFF_IMAGES="180"

usage() {
  cat <<'EOF'
Usage: scripts/video_frame_diff_gate.sh --baseline-video <file> --actual-video <file> [options]

Required:
  --baseline-video <file>      Baseline iOS/mac video
  --actual-video <file>        Actual Android video

Options:
  --output-dir <dir>           Report output root (default: artifacts/video-diff)
  --fps <int>                  Frame extraction FPS (default: 30)
  --pixel-tolerance <int>      Ignore per-channel pixel deltas <= this value (default: 0)
  --max-frame-diff-ratio <f>   Per-frame max differing-pixel ratio (default: 0.0)
  --max-frame-mean-delta <f>   Per-frame max mean channel delta (default: 0.0)
  --max-frame-channel-delta <i>Per-frame max channel delta (default: 0)
  --max-frame-count-delta <i>  Max allowed extracted frame count delta (default: 0)
  --max-speed-delta <f>        Max allowed speed_index delta (default: 0.015)
  --max-density-delta <f>      Max allowed density_index delta (default: 0.010)
  --max-opacity-delta <f>      Max allowed opacity_index delta (default: 0.010)
  --max-diff-images <int>      Max diff images to emit (default: 180)
  -h, --help                   Show help

Examples:
  scripts/video_frame_diff_gate.sh \
    --baseline-video artifacts/video/ios/dashboard_clear.mp4 \
    --actual-video artifacts/video/android/dashboard_clear.mp4

  scripts/video_frame_diff_gate.sh \
    --baseline-video artifacts/video/ios/dashboard_rainy.mp4 \
    --actual-video artifacts/video/android/dashboard_rainy.mp4 \
    --fps 60 --max-speed-delta 0.008 --max-density-delta 0.005 --max-opacity-delta 0.005
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline-video) BASELINE_VIDEO="$2"; shift 2 ;;
    --actual-video) ACTUAL_VIDEO="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    --pixel-tolerance) PIXEL_TOLERANCE="$2"; shift 2 ;;
    --max-frame-diff-ratio) MAX_FRAME_DIFF_RATIO="$2"; shift 2 ;;
    --max-frame-mean-delta) MAX_FRAME_MEAN_DELTA="$2"; shift 2 ;;
    --max-frame-channel-delta) MAX_FRAME_CHANNEL_DELTA="$2"; shift 2 ;;
    --max-frame-count-delta) MAX_FRAME_COUNT_DELTA="$2"; shift 2 ;;
    --max-speed-delta) MAX_SPEED_DELTA="$2"; shift 2 ;;
    --max-density-delta) MAX_DENSITY_DELTA="$2"; shift 2 ;;
    --max-opacity-delta) MAX_OPACITY_DELTA="$2"; shift 2 ;;
    --max-diff-images) MAX_DIFF_IMAGES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$BASELINE_VIDEO" || -z "$ACTUAL_VIDEO" ]]; then
  echo "--baseline-video and --actual-video are required" >&2
  usage
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found in PATH" >&2
  exit 1
fi

python3 scripts/video_frame_diff.py \
  --baseline-video "$BASELINE_VIDEO" \
  --actual-video "$ACTUAL_VIDEO" \
  --output-dir "$OUTPUT_DIR" \
  --fps "$FPS" \
  --pixel-tolerance "$PIXEL_TOLERANCE" \
  --max-frame-diff-ratio "$MAX_FRAME_DIFF_RATIO" \
  --max-frame-mean-delta "$MAX_FRAME_MEAN_DELTA" \
  --max-frame-channel-delta "$MAX_FRAME_CHANNEL_DELTA" \
  --max-frame-count-delta "$MAX_FRAME_COUNT_DELTA" \
  --max-speed-delta "$MAX_SPEED_DELTA" \
  --max-density-delta "$MAX_DENSITY_DELTA" \
  --max-opacity-delta "$MAX_OPACITY_DELTA" \
  --max-diff-images "$MAX_DIFF_IMAGES"
