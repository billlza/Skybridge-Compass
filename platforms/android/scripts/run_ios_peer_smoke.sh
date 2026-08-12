#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/repository_layout.sh"
RELEASE_REPO_ROOT="$(skybridge_canonical_release_root "$ROOT_DIR")"
DEFAULT_IOS_PROJECT_DIR="$RELEASE_REPO_ROOT/SkyBridge Compass iOS"
IOS_PROJECT_DIR="$DEFAULT_IOS_PROJECT_DIR"
SCHEME="SkyBridgeCompass-iOS"
DESTINATION="${SKYBRIDGE_IOS_DESTINATION:-}"
DESTINATION_SOURCE="$(if [[ -n "$DESTINATION" ]]; then echo environment; else echo auto_simulator; fi)"
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

require_boolean() {
  local name="$1"
  local value="$2"
  case "$value" in
    true|false) ;;
    *)
      echo "Unsupported $name value: $value (expected true|false)" >&2
      exit 1
      ;;
  esac
}

require_option_value() {
  local option="$1"
  local value="${2-}"
  if [[ -z "$value" ]]; then
    echo "Missing value for $option" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  if [[ "$1" == --* && "$1" != "--help" ]]; then
    require_option_value "$1" "${2-}"
  fi
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
      DESTINATION_SOURCE="argument"
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

require_boolean "--only-ui" "$ONLY_UI"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found in PATH" >&2
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun not found in PATH" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found in PATH" >&2
  exit 1
fi

IOS_PROJECT_DIR="$(skybridge_require_ios_project_dir "$IOS_PROJECT_DIR")"
PROJECT_FILE="$IOS_PROJECT_DIR/SkyBridgeCompass-iOS.xcodeproj"

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$ROOT_DIR/build/interop/ios-peer-smoke/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR"

LOG_FILE="$RUN_DIR/xcodebuild.log"
RESULT_BUNDLE="$RUN_DIR/SkyBridgeCompass-iOS.xcresult"
ENV_FILE="$RUN_DIR/environment.txt"
COMMAND_FILE="$RUN_DIR/command.txt"
SUMMARY_FILE="$RUN_DIR/summary.txt"
DESTINATION_LOG="$RUN_DIR/destination-resolution.log"
TEST_RESULTS_SUMMARY_FILE="$RUN_DIR/test-results-summary.json"
BUILD_RESULTS_FILE="$RUN_DIR/build-results.json"
ONLY_UI_EFFECTIVE="$ONLY_UI"
ONLY_UI_FALLBACK="false"
: >"$DESTINATION_LOG"

fail_destination_resolution() {
  local reason="$1"
  local exit_code="$2"
  printf '%s\n' "$reason" >>"$DESTINATION_LOG"
  {
    echo "xcodebuild_ok=false"
    echo "xcodebuild_exit=$exit_code"
    echo "failure_stage=destination_resolution"
    echo "failure_reason=$reason"
    echo "result_bundle_exists=false"
    echo "destination_source=$DESTINATION_SOURCE"
    echo "only_ui_requested=$ONLY_UI"
    echo "only_ui_effective=$ONLY_UI"
    echo "only_ui_fallback=false"
  } >"$SUMMARY_FILE"
  echo "Unable to resolve iOS destination: $reason" >&2
  echo "See $SUMMARY_FILE" >&2
  exit "$exit_code"
}

if [[ -z "$DESTINATION" ]]; then
  set +e
  DESTINATION="$(
    xcrun simctl list devices available -j 2>>"$DESTINATION_LOG" |
      python3 "$ROOT_DIR/scripts/resolve_ios_simulator_destination.py" 2>>"$DESTINATION_LOG"
  )"
  DESTINATION_EXIT=$?
  set -e
  if [[ "$DESTINATION_EXIT" -ne 0 || -z "$DESTINATION" ]]; then
    if [[ "$DESTINATION_EXIT" -eq 0 ]]; then
      DESTINATION_EXIT=1
    fi
    fail_destination_resolution "automatic_simulator_resolution_failed" "$DESTINATION_EXIT"
  fi
fi

cat >"$COMMAND_FILE" <<EOF
script=scripts/run_ios_peer_smoke.sh
ios_project_dir=$IOS_PROJECT_DIR
scheme=$SCHEME
destination=$DESTINATION
destination_source=$DESTINATION_SOURCE
only_ui=$ONLY_UI
run_dir=$RUN_DIR
EOF

{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "xcodebuild=$(xcodebuild -version 2>/dev/null | tr '\n' '; ')"
  echo "project_file=$PROJECT_FILE"
  echo "destination=$DESTINATION"
  echo "destination_source=$DESTINATION_SOURCE"
} >"$ENV_FILE"
skybridge_append_git_source_binding "$ENV_FILE" android "$RELEASE_REPO_ROOT"
skybridge_append_git_source_binding "$ENV_FILE" apple "$IOS_PROJECT_DIR"

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

collect_xcresult_results() {
  command -v xcrun >/dev/null 2>&1 || return 1
  xcrun xcresulttool get test-results summary \
    --path "$RESULT_BUNDLE" \
    --compact >"$TEST_RESULTS_SUMMARY_FILE" || return 1
  xcrun xcresulttool get build-results \
    --path "$RESULT_BUNDLE" \
    --compact >"$BUILD_RESULTS_FILE" || return 1
}

: >"$LOG_FILE"
set +e
run_xcodebuild "$ONLY_UI"
XCODE_EXIT=$?
set -e

if [[ "$XCODE_EXIT" -ne 0 && "$ONLY_UI" == "true" ]] && grep -Eq "isn't a member of the specified test plan or scheme|isn’t a member of the specified test plan or scheme" "$LOG_FILE"; then
  echo "UI-only target is not part of the active scheme; retrying full smoke." | tee -a "$LOG_FILE"
  ONLY_UI_EFFECTIVE="false"
  ONLY_UI_FALLBACK="true"
  rm -rf "$RESULT_BUNDLE"
  set +e
  run_xcodebuild "false"
  XCODE_EXIT=$?
  set -e
fi

RESULT_BUNDLE_EXISTS="false"
if [[ -d "$RESULT_BUNDLE" ]]; then
  RESULT_BUNDLE_EXISTS="true"
elif [[ "$XCODE_EXIT" -eq 0 ]]; then
  echo "xcodebuild exited successfully but did not create the required result bundle" | tee -a "$LOG_FILE" >&2
  XCODE_EXIT=1
fi

XCRESULT_RESULTS_OK="false"
if [[ "$RESULT_BUNDLE_EXISTS" == "true" ]]; then
  if collect_xcresult_results; then
    XCRESULT_RESULTS_OK="true"
  elif [[ "$XCODE_EXIT" -eq 0 ]]; then
    echo "xcodebuild succeeded but xcresult test/build summaries could not be parsed" | tee -a "$LOG_FILE" >&2
    XCODE_EXIT=1
  fi
fi

TEST_RESULT_FIELDS=""
BUILD_RESULT_FIELDS=""
if [[ "$XCRESULT_RESULTS_OK" == "true" ]]; then
  TEST_RESULT_FIELDS="$(python3 - "$TEST_RESULTS_SUMMARY_FILE" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("result", "totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"):
    print(f"{key}={data.get(key, '')}")
PY
)"
  BUILD_RESULT_FIELDS="$(python3 - "$BUILD_RESULTS_FILE" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("status", "warningCount", "analyzerWarningCount", "errorCount"):
    print(f"{key}={data.get(key, '')}")
PY
)"
fi

XCRESULT_VALIDATION_OK="false"
if [[ "$XCRESULT_RESULTS_OK" == "true" ]]; then
  test_result="$(printf '%s\n' "$TEST_RESULT_FIELDS" | awk -F= '$1 == "result" { print $2 }')"
  failed_tests="$(printf '%s\n' "$TEST_RESULT_FIELDS" | awk -F= '$1 == "failedTests" { print $2 }')"
  build_status="$(printf '%s\n' "$BUILD_RESULT_FIELDS" | awk -F= '$1 == "status" { print $2 }')"
  build_errors="$(printf '%s\n' "$BUILD_RESULT_FIELDS" | awk -F= '$1 == "errorCount" { print $2 }')"
  build_warnings="$(printf '%s\n' "$BUILD_RESULT_FIELDS" | awk -F= '$1 == "warningCount" { print $2 }')"
  analyzer_warnings="$(printf '%s\n' "$BUILD_RESULT_FIELDS" | awk -F= '$1 == "analyzerWarningCount" { print $2 }')"
  if [[ "$test_result" == "Passed" && "$failed_tests" == "0" &&
        "$build_status" == "succeeded" && "$build_errors" == "0" &&
        "$build_warnings" == "0" && "$analyzer_warnings" == "0" ]]; then
    XCRESULT_VALIDATION_OK="true"
  elif [[ "$XCODE_EXIT" -eq 0 ]]; then
    echo "xcresult reports a failed test/build despite xcodebuild exit 0" | tee -a "$LOG_FILE" >&2
    XCODE_EXIT=1
  fi
fi

{
  echo "xcodebuild_ok=$(if [[ "$XCODE_EXIT" -eq 0 && "$XCRESULT_VALIDATION_OK" == "true" ]]; then echo true; else echo false; fi)"
  echo "xcodebuild_exit=$XCODE_EXIT"
  echo "result_bundle_exists=$RESULT_BUNDLE_EXISTS"
  echo "destination_resolution_log=$DESTINATION_LOG"
  if [[ -f "$TEST_RESULTS_SUMMARY_FILE" ]]; then
    echo "test_results_summary=$TEST_RESULTS_SUMMARY_FILE"
  fi
  if [[ -f "$BUILD_RESULTS_FILE" ]]; then
    echo "build_results=$BUILD_RESULTS_FILE"
  fi
  echo "xcresult_results_ok=$XCRESULT_RESULTS_OK"
  if [[ -n "$TEST_RESULT_FIELDS" ]]; then
    echo "$TEST_RESULT_FIELDS"
  fi
  if [[ -n "$BUILD_RESULT_FIELDS" ]]; then
    echo "$BUILD_RESULT_FIELDS"
  fi
  echo "destination=$DESTINATION"
  echo "destination_source=$DESTINATION_SOURCE"
  echo "only_ui_requested=$ONLY_UI"
  echo "only_ui_effective=$ONLY_UI_EFFECTIVE"
  echo "only_ui_fallback=$ONLY_UI_FALLBACK"
} >"$SUMMARY_FILE"

echo "Artifacts:"
echo "  environment: $ENV_FILE"
echo "  command: $COMMAND_FILE"
echo "  log: $LOG_FILE"
echo "  result bundle: $RESULT_BUNDLE"
echo "  destination resolution: $DESTINATION_LOG"
if [[ -f "$TEST_RESULTS_SUMMARY_FILE" ]]; then
  echo "  test results summary: $TEST_RESULTS_SUMMARY_FILE"
fi
if [[ -f "$BUILD_RESULTS_FILE" ]]; then
  echo "  build results: $BUILD_RESULTS_FILE"
fi
echo "  summary: $SUMMARY_FILE"

if [[ "$XCODE_EXIT" -ne 0 ]]; then
  exit "$XCODE_EXIT"
fi
