#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_IOS_PROJECT_DIR="$ROOT_DIR/../../SkyBridge Compass iOS"
IOS_PROJECT_DIR="$DEFAULT_IOS_PROJECT_DIR"
SCHEME="SkyBridgeCompass-iOS"
DESTINATION="platform=iOS Simulator,name=iPhone 17,OS=26.2"
ONLY_UI="false"
RUN_DIR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/run_ios_peer_smoke.sh \
    [--ios-project-dir <path>] \
    [--scheme <name>] \
    [--destination <xcodebuild-destination>] \
    [--only-ui true|false] \
    [--run-dir <path>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ios-project-dir)
      IOS_PROJECT_DIR="${2:-}"
      shift 2
      ;;
    --scheme)
      SCHEME="${2:-}"
      shift 2
      ;;
    --destination)
      DESTINATION="${2:-}"
      shift 2
      ;;
    --only-ui)
      ONLY_UI="${2:-}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found in PATH" >&2
  exit 1
fi

PROJECT_FILE="$IOS_PROJECT_DIR/SkyBridgeCompass-iOS.xcodeproj"
if [[ ! -d "$PROJECT_FILE" ]]; then
  echo "iOS project not found: $PROJECT_FILE" >&2
  exit 1
fi

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$ROOT_DIR/build/interop/ios-peer-smoke/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$RUN_DIR"

LOG_FILE="$RUN_DIR/xcodebuild.log"
RESULT_BUNDLE="$RUN_DIR/SkyBridgeCompass-iOS.xcresult"
ENV_FILE="$RUN_DIR/environment.txt"
COMMAND_FILE="$RUN_DIR/command.txt"
SUMMARY_FILE="$RUN_DIR/summary.txt"
ONLY_UI_EFFECTIVE="$ONLY_UI"
ONLY_UI_FALLBACK="false"

cat >"$COMMAND_FILE" <<EOF
script=scripts/run_ios_peer_smoke.sh
ios_project_dir=$IOS_PROJECT_DIR
scheme=$SCHEME
destination=$DESTINATION
only_ui=$ONLY_UI
run_dir=$RUN_DIR
EOF

{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "xcodebuild=$(xcodebuild -version 2>/dev/null | tr '\n' '; ')"
  echo "project_file=$PROJECT_FILE"
} >"$ENV_FILE"

echo "Running iOS peer smoke..."
echo "Log file: $LOG_FILE"
echo "Result bundle: $RESULT_BUNDLE"

run_xcodebuild() {
  local mode="$1"
  local -a cmd=(
    xcodebuild test
    -project "$PROJECT_FILE"
    -scheme "$SCHEME"
    -destination "$DESTINATION"
    -resultBundlePath "$RESULT_BUNDLE"
  )

  if [[ "$mode" == "true" ]]; then
    cmd+=(-only-testing:SkyBridgeCompassiOSUITests)
  fi

  "${cmd[@]}" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

: >"$LOG_FILE"
set +e
run_xcodebuild "$ONLY_UI"
XCODE_EXIT=$?
set -e

if [[ "$XCODE_EXIT" -ne 0 && "$ONLY_UI" == "true" ]] && rg -q "isn't a member of the specified test plan or scheme|isn’t a member of the specified test plan or scheme" "$LOG_FILE"; then
  echo "UI-only target is not part of the active scheme; retrying full smoke." | tee -a "$LOG_FILE"
  ONLY_UI_EFFECTIVE="false"
  ONLY_UI_FALLBACK="true"
  rm -rf "$RESULT_BUNDLE"
  set +e
  run_xcodebuild "false"
  XCODE_EXIT=$?
  set -e
fi

if [[ "$XCODE_EXIT" -ne 0 ]]; then
  exit "$XCODE_EXIT"
fi

{
  echo "xcodebuild_ok=true"
  echo "result_bundle_exists=$(if [[ -d "$RESULT_BUNDLE" ]]; then echo true; else echo false; fi)"
  echo "only_ui_requested=$ONLY_UI"
  echo "only_ui_effective=$ONLY_UI_EFFECTIVE"
  echo "only_ui_fallback=$ONLY_UI_FALLBACK"
} >"$SUMMARY_FILE"

echo "Artifacts:"
echo "  environment: $ENV_FILE"
echo "  command: $COMMAND_FILE"
echo "  log: $LOG_FILE"
echo "  result bundle: $RESULT_BUNDLE"
echo "  summary: $SUMMARY_FILE"
