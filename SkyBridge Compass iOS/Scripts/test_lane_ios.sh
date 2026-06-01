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

bash "${ROOT_DIR}/Scripts/check_ios_test_configuration.sh"

pick_simulator_id() {
  local payload_file
  local error_file
  payload_file="$(mktemp)"
  error_file="$(mktemp)"

  local attempt
  for attempt in 1 2; do
    if xcrun simctl list devices available -j >"${payload_file}" 2>"${error_file}" && [[ -s "${payload_file}" ]]; then
      if python3 - "${payload_file}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
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
PY
      then
        rm -f "${payload_file}" "${error_file}"
        return
      fi
    fi

    sleep 2
  done

  echo "[iOS test lane] simctl did not return a non-empty simulator device list." >&2
  if [[ -s "${error_file}" ]]; then
    cat "${error_file}" >&2
  fi
  rm -f "${payload_file}" "${error_file}"
  return 1
}

SIM_ID="$(pick_simulator_id)"
SIM_ARCH="${SIM_ARCH:-$(uname -m)}"
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

echo "[iOS test lane] running full ${IOS_TEST_TARGET} suite"

run_xcodebuild_with_retry \
  -project "${IOS_PROJECT}" \
  -scheme "${IOS_SCHEME}" \
  -destination "platform=iOS Simulator,id=${SIM_ID},arch=${SIM_ARCH}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build-for-testing

run_xcodebuild_with_retry \
  -project "${IOS_PROJECT}" \
  -scheme "${IOS_SCHEME}" \
  -destination "platform=iOS Simulator,id=${SIM_ID},arch=${SIM_ARCH}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  test-without-building

echo "[iOS test lane] full suite passed"
