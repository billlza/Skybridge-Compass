#!/usr/bin/env bash
set -euo pipefail

if [[ "${SKYBRIDGE_SIMCTL_FAKE_MODE:-0}" == "1" ]]; then
  if [[ "${1:-}" != "simctl" ]]; then
    exit 64
  fi
  shift
  case "${1:-}" in
    list)
      cat "${SKYBRIDGE_SIMCTL_FIXTURE:?}"
      ;;
    boot)
      printf 'boot %s\n' "${2:-}" >>"${SKYBRIDGE_SIMCTL_CALL_LOG:?}"
      ;;
    bootstatus)
      candidate_id="${2:-}"
      printf 'bootstatus %s\n' "$candidate_id" >>"${SKYBRIDGE_SIMCTL_CALL_LOG:?}"
      case ":${SKYBRIDGE_SIMCTL_BOOTABLE_IDS:-}:" in
        *":${candidate_id}:"*) exit 0 ;;
        *) exit 1 ;;
      esac
      ;;
    *)
      exit 64
      ;;
  esac
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/Scripts/ios_simulator_helpers.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FIXTURE="$TMP_DIR/devices.json"
CALL_LOG="$TMP_DIR/calls.log"
READY_DATA="$TMP_DIR/ready-device-data"
mkdir -p "$READY_DATA"

write_fixture() {
  local mode="$1"
  python3 - "$FIXTURE" "$READY_DATA" "$mode" <<'PY'
import json
import sys

fixture, ready_data, mode = sys.argv[1:]
if mode == "ranked":
    devices = {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {
                "udid": "NEWER-BROKEN",
                "name": "iPhone 17 Pro",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "state": "Shutdown",
                "isAvailable": True,
                "dataPath": "/missing/newer/data",
            }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {
                "udid": "CUSTOM-READY",
                "name": "SkyBridge Test iPhone 17 Pro",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "state": "Shutdown",
                "isAvailable": True,
                "dataPath": ready_data,
            }
        ],
    }
elif mode == "fallback":
    devices = {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {
                "udid": "FIRST-BROKEN",
                "name": "iPhone 17 Pro",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "state": "Shutdown",
                "isAvailable": True,
                "dataPath": "/missing/first/data",
            }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {
                "udid": "SECOND-GOOD",
                "name": "iPhone 16",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
                "state": "Shutdown",
                "isAvailable": True,
                "dataPath": "/missing/second/data",
            }
        ],
    }
else:
    devices = {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {
                "udid": "IPAD-ONLY",
                "name": "iPad Pro",
                "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro",
                "state": "Shutdown",
                "isAvailable": True,
            }
        ]
    }

with open(fixture, "w", encoding="utf-8") as handle:
    json.dump({"devices": devices}, handle)
PY
}

pick_with_fake_simctl() {
  SKYBRIDGE_SIMCTL_FAKE_MODE=1 \
  SKYBRIDGE_XCRUN_BIN="$0" \
  SKYBRIDGE_SIMCTL_FIXTURE="$FIXTURE" \
  SKYBRIDGE_SIMCTL_CALL_LOG="$CALL_LOG" \
  SKYBRIDGE_SIMCTL_BOOTABLE_IDS="${SKYBRIDGE_TEST_BOOTABLE_IDS:-}" \
  SKYBRIDGE_SIMCTL_BOOT_TIMEOUT_SECONDS=2 \
    skybridge_pick_bootable_ios_simulator_id "${1:-}" "[simulator-helper-test]"
}

write_fixture ranked
: >"$CALL_LOG"
SKYBRIDGE_TEST_BOOTABLE_IDS="CUSTOM-READY:NEWER-BROKEN"
selected="$(pick_with_fake_simctl)"
[[ "$selected" == "CUSTOM-READY" ]] || {
  echo "initialized custom iPhone simulator was not preferred: $selected" >&2
  exit 1
}

write_fixture fallback
: >"$CALL_LOG"
SKYBRIDGE_TEST_BOOTABLE_IDS="SECOND-GOOD"
selected="$(pick_with_fake_simctl)"
[[ "$selected" == "SECOND-GOOD" ]] || {
  echo "selection did not fall through to the next bootable simulator: $selected" >&2
  exit 1
}
grep -q '^bootstatus FIRST-BROKEN$' "$CALL_LOG"
grep -q '^bootstatus SECOND-GOOD$' "$CALL_LOG"

if SKYBRIDGE_TEST_BOOTABLE_IDS="SECOND-GOOD" pick_with_fake_simctl "EXPLICIT-BROKEN" >/dev/null 2>&1; then
  echo "explicit unbootable simulator unexpectedly fell back" >&2
  exit 1
fi

write_fixture empty
if SKYBRIDGE_TEST_BOOTABLE_IDS="" pick_with_fake_simctl >/dev/null 2>&1; then
  echo "empty iPhone candidate list unexpectedly succeeded" >&2
  exit 1
fi

echo "iOS simulator helper tests passed"
