#!/usr/bin/env bash
set -euo pipefail

GATE_NAME="source_quality"
GATE_DOMAIN="source-quality"
source "$(cd "$(dirname "$0")" && pwd)/_gate_common.sh"

IOS_PROJECT="${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_TEST_LANE="${ROOT_DIR}/SkyBridge Compass iOS/Scripts/test_lane_ios.sh"

run_check_strict_no_warnings \
  "swift-build" \
  "code" \
  "source-quality" \
  swift build

run_check_strict_no_warnings \
  "swift-test" \
  "code" \
  "source-quality" \
  swift test

run_check_strict_no_warnings \
  "ios-debug-build" \
  "code" \
  "source-quality" \
  xcodebuild -project "${IOS_PROJECT}" -scheme "${IOS_SCHEME}" -configuration Debug -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build

run_check_strict_no_warnings \
  "ios-release-build" \
  "code" \
  "source-quality" \
  xcodebuild -project "${IOS_PROJECT}" -scheme "${IOS_SCHEME}" -configuration Release -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build

run_check_strict_no_warnings \
  "ios-test-lane" \
  "code" \
  "source-quality" \
  bash "${IOS_TEST_LANE}"

finalize_gate_report
