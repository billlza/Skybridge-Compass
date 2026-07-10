#!/usr/bin/env bash
set -euo pipefail

GATE_NAME="source_quality"
GATE_DOMAIN="source-quality"
source "$(cd "$(dirname "$0")" && pwd)/_gate_common.sh"

IOS_PROJECT="${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_TEST_LANE="${ROOT_DIR}/SkyBridge Compass iOS/Scripts/test_lane_ios.sh"
SOURCE_QUALITY_TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-source-quality-home.XXXXXX")"

cleanup_source_quality_tmp() {
  rm -rf "${SOURCE_QUALITY_TEST_HOME}"
  cleanup_gate_tmp
}
trap cleanup_source_quality_tmp EXIT

run_check_strict_no_warnings \
  "release-no-print-guard" \
  "code" \
  "source-quality" \
  env SRCROOT="${ROOT_DIR}" zsh "${ROOT_DIR}/Scripts/release_no_print_guard.zsh"

run_check_strict_no_warnings \
  "ios-simulator-selection" \
  "code" \
  "source-quality" \
  bash "${ROOT_DIR}/Scripts/test_ios_simulator_helpers.sh"

run_check_strict_no_warnings \
  "swift-build" \
  "code" \
  "source-quality" \
  swift build

run_check_strict_no_warnings \
  "swift-test-localization-notification-isolation" \
  "code" \
  "source-quality" \
  env HOME="${SOURCE_QUALITY_TEST_HOME}" CFFIXED_USER_HOME="${SOURCE_QUALITY_TEST_HOME}" SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 swift test --filter SkyBridgeCoreTests.LocalizationManagerNotificationIsolationTests

run_check_strict_no_warnings \
  "swift-test" \
  "code" \
  "source-quality" \
  env HOME="${SOURCE_QUALITY_TEST_HOME}" CFFIXED_USER_HOME="${SOURCE_QUALITY_TEST_HOME}" SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 swift test --filter '.*'

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
