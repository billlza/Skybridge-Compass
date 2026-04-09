#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BASELINE_DIR=""
ACTUAL_DIR=""
OUTPUT_DIR="artifacts/video-diff/matrix"
FPS="30"
SCENARIOS_CSV="dashboard_clear,dashboard_cloudy,dashboard_rainy,dashboard_snowy,dashboard_foggy,dashboard_haze,dashboard_stormy"
MAX_FRAME_DIFF_RATIO="0.0"
MAX_FRAME_MEAN_DELTA="0.0"
MAX_FRAME_CHANNEL_DELTA="0"
MAX_FRAME_COUNT_DELTA="0"
PIXEL_TOLERANCE="0"
MAX_SPEED_DELTA="0.015"
MAX_DENSITY_DELTA="0.010"
MAX_OPACITY_DELTA="0.010"
MAX_DIFF_IMAGES="180"
VIDEO_EXT="mp4"

usage() {
  cat <<'EOF'
Usage: scripts/video_frame_diff_matrix.sh --baseline-dir <dir> --actual-dir <dir> [options]

Required:
  --baseline-dir <dir>      Baseline video root (iOS/mac)
  --actual-dir <dir>        Actual video root (Android)

Options:
  --output-dir <dir>        Matrix report root (default: artifacts/video-diff/matrix)
  --scenarios <csv>         Scenario names (default:
                            dashboard_clear,dashboard_cloudy,dashboard_rainy,dashboard_snowy,
                            dashboard_foggy,dashboard_haze,dashboard_stormy)
  --video-ext <ext>         Video extension without dot (default: mp4)
  --fps <int>               Frame extraction FPS (default: 30)
  --pixel-tolerance <int>   Ignore per-channel pixel deltas <= value (default: 0)
  --max-frame-diff-ratio <f>
  --max-frame-mean-delta <f>
  --max-frame-channel-delta <i>
  --max-frame-count-delta <i>
  --max-speed-delta <f>
  --max-density-delta <f>
  --max-opacity-delta <f>
  --max-diff-images <int>
  -h, --help                Show help

Expected input layout:
  <baseline-dir>/<scenario>.<ext>
  <actual-dir>/<scenario>.<ext>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline-dir) BASELINE_DIR="$2"; shift 2 ;;
    --actual-dir) ACTUAL_DIR="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --scenarios) SCENARIOS_CSV="$2"; shift 2 ;;
    --video-ext) VIDEO_EXT="$2"; shift 2 ;;
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

if [[ -z "$BASELINE_DIR" || -z "$ACTUAL_DIR" ]]; then
  echo "--baseline-dir and --actual-dir are required" >&2
  usage
  exit 1
fi

if [[ ! -d "$BASELINE_DIR" ]]; then
  echo "baseline dir not found: $BASELINE_DIR" >&2
  exit 1
fi

if [[ ! -d "$ACTUAL_DIR" ]]; then
  echo "actual dir not found: $ACTUAL_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
SUMMARY_CSV="$OUTPUT_DIR/summary.csv"
SUMMARY_MD="$OUTPUT_DIR/report.md"
echo "scenario,gate_result,frames_compared,failed_frames,speed_delta,density_delta,opacity_delta,report_path" > "$SUMMARY_CSV"

IFS=',' read -r -a SCENARIOS <<<"$SCENARIOS_CSV"
TOTAL=0
PASSED=0

for scenario in "${SCENARIOS[@]}"; do
  scenario="$(echo "$scenario" | xargs)"
  [[ -z "$scenario" ]] && continue
  TOTAL=$((TOTAL + 1))

  baseline_video="$BASELINE_DIR/${scenario}.${VIDEO_EXT}"
  actual_video="$ACTUAL_DIR/${scenario}.${VIDEO_EXT}"
  scenario_output="$OUTPUT_DIR/$scenario"

  if [[ ! -f "$baseline_video" || ! -f "$actual_video" ]]; then
    echo "$scenario,FAIL,0,0,0,0,0,missing_video" >> "$SUMMARY_CSV"
    continue
  fi

  set +e
  scripts/video_frame_diff_gate.sh \
    --baseline-video "$baseline_video" \
    --actual-video "$actual_video" \
    --output-dir "$scenario_output" \
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
  exit_code=$?
  set -e

  summary_json="$scenario_output/summary.json"
  if [[ ! -f "$summary_json" ]]; then
    echo "$scenario,FAIL,0,0,0,0,0,missing_summary" >> "$SUMMARY_CSV"
    continue
  fi

  values="$(python3 - <<'PY' "$summary_json"
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
s = data.get("summary", {})
print(
    f"{int(bool(s.get('passed')))}|"
    f"{s.get('frames_compared', 0)}|"
    f"{s.get('failed_frames', 0)}|"
    f"{s.get('speed_delta', 0)}|"
    f"{s.get('density_delta', 0)}|"
    f"{s.get('opacity_delta', 0)}"
)
PY
)"

  gate_pass="$(echo "$values" | cut -d'|' -f1)"
  frames_compared="$(echo "$values" | cut -d'|' -f2)"
  failed_frames="$(echo "$values" | cut -d'|' -f3)"
  speed_delta="$(echo "$values" | cut -d'|' -f4)"
  density_delta="$(echo "$values" | cut -d'|' -f5)"
  opacity_delta="$(echo "$values" | cut -d'|' -f6)"

  gate_label="FAIL"
  if [[ "$gate_pass" == "1" && "$exit_code" -eq 0 ]]; then
    gate_label="PASS"
    PASSED=$((PASSED + 1))
  fi

  report_rel="$(python3 - <<'PY' "$scenario_output/report.md" "$OUTPUT_DIR"
from pathlib import Path
import sys
report = Path(sys.argv[1])
root = Path(sys.argv[2])
try:
    print(report.relative_to(root).as_posix())
except Exception:
    print(report.as_posix())
PY
)"

  echo "$scenario,$gate_label,$frames_compared,$failed_frames,$speed_delta,$density_delta,$opacity_delta,$report_rel" >> "$SUMMARY_CSV"
done

{
  echo "# Video Frame Diff Matrix Report"
  echo
  echo "- scenarios: \`$TOTAL\`"
  echo "- passed: \`$PASSED\`"
  echo "- failed: \`$((TOTAL - PASSED))\`"
  echo
  echo "## Per Scenario"
  echo
  tail -n +2 "$SUMMARY_CSV" | while IFS=',' read -r scenario gate frames failed speed density opacity report; do
    echo "- \`$scenario\` | gate=\`$gate\` | frames=\`$frames\` | failed=\`$failed\` | speed=\`$speed\` | density=\`$density\` | opacity=\`$opacity\` | report=\`$report\`"
  done
} > "$SUMMARY_MD"

echo "Matrix report: $SUMMARY_MD"
echo "Summary CSV: $SUMMARY_CSV"

if [[ "$PASSED" -eq "$TOTAL" ]]; then
  exit 0
fi
exit 1
