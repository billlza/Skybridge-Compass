#!/usr/bin/env bash
# iOS 真机测试 lane（与模拟器 lane test_lane_ios.sh 互补）：
# - 模拟器 lane：覆盖“源码形状断言”类测试 + 运行时行为测试（仓库文件系统可见）。
# - 真机 lane：在真实 OS（如 iOS 27 beta）上覆盖运行时行为测试；
#   源码形状断言类测试在真机沙箱内无仓库文件，按设计 XCTSkip（见 SourceShapeTestSupport.swift）。
#
# 用法：
#   SKYBRIDGE_IOS_DEVICE_ID=<devicectl-identifier> bash test_lane_ios_device.sh
#   不指定时自动选择第一台 available (paired) 的真机。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_PROJECT="${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompassiOSTests"

pick_device_id() {
  local payload_file
  payload_file="$(mktemp -d)/devices.json"
  xcrun devicectl list devices --json-output "${payload_file}" >/dev/null
  python3 - "${payload_file}" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
devices = payload.get("result", {}).get("devices", [])
for device in devices:
    props = device.get("deviceProperties", {})
    conn = device.get("connectionProperties", {})
    hw = device.get("hardwareProperties", {})
    if conn.get("pairingState") != "paired":
        continue
    if conn.get("tunnelState") == "unavailable":
        continue
    if hw.get("platform") != "iOS":
        continue
    print(device["identifier"])
    break
else:
    raise SystemExit("No available paired iOS physical device found.")
PY
}

DEVICE_ID="${SKYBRIDGE_IOS_DEVICE_ID:-$(pick_device_id)}"
DERIVED_DATA_PATH="$(mktemp -d)"
trap 'rm -rf "${DERIVED_DATA_PATH}"' EXIT

echo "[iOS device lane] device=${DEVICE_ID}"
echo "[iOS device lane] building for testing"

xcodebuild \
  -project "${IOS_PROJECT}" \
  -scheme "${IOS_SCHEME}" \
  -destination "platform=iOS,id=${DEVICE_ID}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -allowProvisioningUpdates \
  build-for-testing

echo "[iOS device lane] running full ${IOS_SCHEME} suite on device"

xcodebuild \
  -project "${IOS_PROJECT}" \
  -scheme "${IOS_SCHEME}" \
  -destination "platform=iOS,id=${DEVICE_ID}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  test-without-building

echo "[iOS device lane] full suite passed on device"
