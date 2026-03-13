#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_PROJECT="${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompassiOSTests"
IOS_TEST_TARGET="SkyBridgeCompassiOSTests"
IOS_APP_BUNDLE_ID="com.skybridge.compass.ios"
EXPECTED_ARTIFACT_DATE="2026-01-23"
ARTIFACT_DATE="${ARTIFACT_DATE:-${SKYBRIDGE_ARTIFACT_DATE:-$EXPECTED_ARTIFACT_DATE}}"

if [[ "${ARTIFACT_DATE}" != "${EXPECTED_ARTIFACT_DATE}" ]]; then
  echo "ARTIFACT_DATE must be ${EXPECTED_ARTIFACT_DATE}, got ${ARTIFACT_DATE}" >&2
  exit 2
fi

pick_simulator_id() {
  xcrun simctl list devices available -j | python3 -c '
import json
import re
import sys

payload = json.load(sys.stdin)
best = None
for runtime, devices in payload.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    m = re.search(r"iOS[- ](\d+)[.-](\d+)", runtime)
    if not m:
        continue
    major = int(m.group(1))
    minor = int(m.group(2))
    for device in devices:
        if not device.get("isAvailable"):
            continue
        if device.get("name", "").startswith("iPhone"):
            rank = (major, minor)
            if best is None or rank > best[0]:
                best = (rank, device["udid"])
if best is None:
    raise SystemExit("No available iOS simulator device found.")
print(best[1])
'
}

SIM_ID="$(pick_simulator_id)"
DERIVED_DATA_PATH="$(mktemp -d)"
trap 'rm -rf "${DERIVED_DATA_PATH}"' EXIT

run_xcodebuild_with_retry() {
  local max_attempts=2
  local attempt=1
  local log_file
  log_file="$(mktemp)"

  log_has_busy_pattern() {
    local target_log="$1"
    if command -v rg >/dev/null 2>&1; then
      rg -n "Application failed preflight checks|reason: Busy" "${target_log}" >/dev/null
    else
      grep -nE "Application failed preflight checks|reason: Busy" "${target_log}" >/dev/null
    fi
  }

  while [[ "${attempt}" -le "${max_attempts}" ]]; do
    if xcodebuild "$@" 2>&1 | tee "${log_file}"; then
      rm -f "${log_file}"
      return 0
    fi

    if [[ "${attempt}" -lt "${max_attempts}" ]] && log_has_busy_pattern "${log_file}"; then
      echo "[iOS test lane] simulator busy preflight; resetting simulator and retrying..."
      xcrun simctl terminate "${SIM_ID}" "${IOS_APP_BUNDLE_ID}" >/dev/null 2>&1 || true
      xcrun simctl uninstall "${SIM_ID}" "${IOS_APP_BUNDLE_ID}" >/dev/null 2>&1 || true
      xcrun simctl shutdown "${SIM_ID}" >/dev/null 2>&1 || true
      xcrun simctl boot "${SIM_ID}" >/dev/null 2>&1 || true
      xcrun simctl bootstatus "${SIM_ID}" -b >/dev/null 2>&1 || true
      attempt=$((attempt + 1))
      continue
    fi

    rm -f "${log_file}"
    return 1
  done

  rm -f "${log_file}"
  return 1
}

# Ensure simulator is ready before invoking xcodebuild.
xcrun simctl boot "${SIM_ID}" >/dev/null 2>&1 || true
xcrun simctl bootstatus "${SIM_ID}" -b >/dev/null 2>&1 || true

echo "[iOS test lane] A(Unit): KEMTrustStoreTests, CapabilityResolutionParityTests, CurrentPathTrustedDeviceStoreTests"
echo "[iOS test lane] B(Integration): PolicyDecisionParityTests, FallbackSemanticsParityTests"
echo "[iOS test lane] C(Observability): ObservabilityContractTests"

run_xcodebuild_with_retry \
  -project "${IOS_PROJECT}" \
  -scheme "${IOS_SCHEME}" \
  -destination "platform=iOS Simulator,id=${SIM_ID}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build-for-testing

run_xcodebuild_with_retry \
  -project "${IOS_PROJECT}" \
  -scheme "${IOS_SCHEME}" \
  -destination "platform=iOS Simulator,id=${SIM_ID}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -only-testing:"${IOS_TEST_TARGET}/KEMTrustStoreTests" \
  -only-testing:"${IOS_TEST_TARGET}/CapabilityResolutionParityTests" \
  -only-testing:"${IOS_TEST_TARGET}/CurrentPathTrustedDeviceStoreTests" \
  -only-testing:"${IOS_TEST_TARGET}/PolicyDecisionParityTests" \
  -only-testing:"${IOS_TEST_TARGET}/FallbackSemanticsParityTests" \
  -only-testing:"${IOS_TEST_TARGET}/ObservabilityContractTests" \
  test-without-building

echo "[iOS test lane] all groups passed"
