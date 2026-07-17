#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/ios_simulator_helpers.sh"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/local_p2p_smoke_$(date +%Y%m%d_%H%M%S)}"
SMOKE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-120}"
SMOKE_ROUNDS="${SKYBRIDGE_SMOKE_ROUNDS:-1}"
SMOKE_SCENARIO="${SKYBRIDGE_SMOKE_SCENARIO:-bootstrap-rekey}"
IOS_BUNDLE_ID="com.skybridge.compass.ios"
IOS_DEVICE_ID="${SKYBRIDGE_SMOKE_IOS_DEVICE_ID:-smoke-ios}"
MAC_TARGET_NAME="${SKYBRIDGE_SMOKE_MAC_TARGET_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"
PREFERRED_SUITE="${SB_PQC_PREFERRED_SUITE:-xwing}"
HOST_PREFERRED_SUITE="${SB_PQC_HOST_PREFERRED_SUITE:-$PREFERRED_SUITE}"
IOS_PREFERRED_SUITE="${SB_PQC_IOS_PREFERRED_SUITE:-$PREFERRED_SUITE}"
EXPECTED_TARGET_SUITE="${SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE:-}"
SWIFTPM_CACHE_DIR="${SKYBRIDGE_SWIFTPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"
SWIFT_MODULE_CACHE_DIR="${SKYBRIDGE_SWIFT_MODULE_CACHE_DIR:-$ROOT_DIR/.swiftpm-module-cache}"

mkdir -p "$ARTIFACT_DIR"
mkdir -p "$SWIFTPM_CACHE_DIR" "$SWIFT_MODULE_CACHE_DIR"

SIM_ID="$(
  skybridge_pick_bootable_ios_simulator_id \
    "${SKYBRIDGE_SMOKE_SIMULATOR_ID:-}" \
    "[local P2P smoke]"
)"
MAC_PID=""
IOS_STATUS_PATH=""
MAC_STDOUT=""
IOS_STDOUT=""
IOS_STDERR=""

cleanup() {
  if [[ -n "${MAC_PID}" ]]; then
    kill "${MAC_PID}" >/dev/null 2>&1 || true
    wait "${MAC_PID}" >/dev/null 2>&1 || true
  fi
  xcrun simctl terminate "${SIM_ID}" "${IOS_BUNDLE_ID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_file_nonempty() {
  local path="$1"
  local timeout_seconds="$2"
  local label="$3"
  local started_at
  started_at="$(date +%s)"
  while true; do
    if [[ -s "$path" ]]; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${path}" >&2
      return 1
    fi
    sleep 1
  done
}

wait_for_file_pattern() {
  local path="$1"
  local pattern="$2"
  local timeout_seconds="$3"
  local label="$4"
  local started_at
  started_at="$(date +%s)"
  while true; do
    if [[ -f "$path" ]] && grep -qE "$pattern" "$path"; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${path}" >&2
      return 1
    fi
    sleep 1
  done
}

require_file_pattern() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  if [[ ! -f "$path" ]] || ! grep -qE "$pattern" "$path"; then
    echo "Missing expected pattern for ${label}: ${pattern} (${path})" >&2
    return 1
  fi
}

require_file_absent_pattern() {
  local path="$1"
  local pattern="$2"
  local label="$3"
  if [[ -f "$path" ]] && grep -qE "$pattern" "$path"; then
    echo "Unexpected pattern for ${label}: ${pattern} (${path})" >&2
    return 1
  fi
}

load_pqc_report() {
  local report_path="$1"
  local parsed
  parsed="$(python3 - "$report_path" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
keys = {
    int(entry.get("suiteWireId", -1)): entry.get("publicKeyBase64", "")
    for entry in report.get("keys", [])
}
print(report.get("deviceId", ""))
print(keys.get(0x0001, ""))
print(keys.get(0x0101, ""))
print(keys.get(0x0102, ""))
PY
)"

  MAC_PQC_DEVICE_ID="$(printf '%s\n' "$parsed" | sed -n '1p')"
  MAC_PQC_XWING_PUBLIC_KEY_BASE64="$(printf '%s\n' "$parsed" | sed -n '2p')"
  MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64="$(printf '%s\n' "$parsed" | sed -n '3p')"
  MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64="$(printf '%s\n' "$parsed" | sed -n '4p')"

  if [[ -z "$MAC_PQC_DEVICE_ID" ]]; then
    echo "PQC report is missing deviceId: ${report_path}" >&2
    return 1
  fi
}

validate_scenario() {
  case "$SMOKE_SCENARIO" in
    bootstrap-rekey|xwing-only|compat-pure-pqc)
      ;;
    *)
      echo "Unsupported smoke scenario: ${SMOKE_SCENARIO}" >&2
      exit 1
      ;;
  esac
}

validate_scenario

if [[ -z "$EXPECTED_TARGET_SUITE" ]]; then
  case "$SMOKE_SCENARIO" in
    bootstrap-rekey|xwing-only)
      EXPECTED_TARGET_SUITE="X-Wing"
      ;;
    compat-pure-pqc)
      EXPECTED_TARGET_SUITE="ML-KEM-768"
      ;;
  esac
fi

echo "==> Artifacts: ${ARTIFACT_DIR}"
echo "==> Simulator: ${SIM_ID}"
echo "==> Scenario: ${SMOKE_SCENARIO}"
echo "==> Target name: ${MAC_TARGET_NAME}"
echo "==> Host preferred suite: ${HOST_PREFERRED_SUITE}"
echo "==> iOS preferred suite: ${IOS_PREFERRED_SUITE}"
echo "==> Expected negotiated suite: ${EXPECTED_TARGET_SUITE}"

echo "==> Building macOS LAN host"
MAC_BUILD_LOG="$ARTIFACT_DIR/macos-build.log"
(
  cd "$ROOT_DIR"
  SWIFTPM_CACHE_PATH="$SWIFTPM_CACHE_DIR" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
  swift build --product LocalLanInteropHost
) >"$MAC_BUILD_LOG"

MAC_APP_BIN="$ROOT_DIR/.build/debug/LocalLanInteropHost"
if [[ ! -x "$MAC_APP_BIN" ]]; then
  echo "macOS LAN host executable not found: $MAC_APP_BIN" >&2
  exit 1
fi

echo "==> Booting simulator"
xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIM_ID" -b

echo "==> Building iOS app"
IOS_BUILD_LOG="$ARTIFACT_DIR/ios-build.log"
xcodebuild \
  -project "$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" \
  -scheme 'SkyBridgeCompass-iOS' \
  -configuration Debug \
  -destination "id=${SIM_ID}" \
  -derivedDataPath "$ARTIFACT_DIR/DerivedData-ios" \
  build >"$IOS_BUILD_LOG"

IOS_APP_PATH="$ARTIFACT_DIR/DerivedData-ios/Build/Products/Debug-iphonesimulator/SkyBridgeCompass-iOS.app"
if [[ ! -d "$IOS_APP_PATH" ]]; then
  echo "iOS app bundle not found: $IOS_APP_PATH" >&2
  exit 1
fi

echo "==> Installing iOS app"
xcrun simctl uninstall "$SIM_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM_ID" "$IOS_APP_PATH"
xcrun simctl privacy "$SIM_ID" grant local-network "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
IOS_CONTAINER="$(xcrun simctl get_app_container "$SIM_ID" "$IOS_BUNDLE_ID" data)"

for round in $(seq 1 "$SMOKE_ROUNDS"); do
  echo "==> Smoke round ${round}/${SMOKE_ROUNDS}"

  MAC_STATUS="$ARTIFACT_DIR/mac_round_${round}.status.log"
  MAC_PQC_REPORT="$ARTIFACT_DIR/mac_round_${round}.pqc.json"
  MAC_STDOUT="$ARTIFACT_DIR/mac_round_${round}.stdout.log"
  IOS_STATUS_BASENAME="ios_round_${round}.status.log"
  IOS_STATUS_PATH="$IOS_CONTAINER/Library/Caches/${IOS_STATUS_BASENAME}"
  IOS_STDOUT="$ARTIFACT_DIR/ios_round_${round}.stdout.log"
  IOS_STDERR="$ARTIFACT_DIR/ios_round_${round}.stderr.log"
  ROUND_IOS_DEVICE_ID="${IOS_DEVICE_ID}-${round}"

  rm -f "$MAC_STATUS" "$MAC_PQC_REPORT" "$MAC_STDOUT" "$IOS_STATUS_PATH" "$IOS_STDOUT" "$IOS_STDERR"

  xcrun simctl terminate "$SIM_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
  if [[ -n "${MAC_PID}" ]]; then
    kill "${MAC_PID}" >/dev/null 2>&1 || true
    wait "${MAC_PID}" >/dev/null 2>&1 || true
    MAC_PID=""
  fi
  pkill -x LocalLanInteropHost >/dev/null 2>&1 || true

  if [[ "$SMOKE_SCENARIO" == "bootstrap-rekey" ]]; then
    SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
    SB_PQC_PREFERRED_SUITE="$HOST_PREFERRED_SUITE" \
    SKYBRIDGE_SMOKE_ROLE=mac-host \
    SKYBRIDGE_SMOKE_STATUS_FILE="$MAC_STATUS" \
    SKYBRIDGE_SMOKE_PQC_REPORT_FILE="$MAC_PQC_REPORT" \
    SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1 \
    SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1 \
    "$MAC_APP_BIN" >"$MAC_STDOUT" 2>&1 &
  else
    SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
    SB_PQC_PREFERRED_SUITE="$HOST_PREFERRED_SUITE" \
    SKYBRIDGE_SMOKE_ROLE=mac-host \
    SKYBRIDGE_SMOKE_STATUS_FILE="$MAC_STATUS" \
    SKYBRIDGE_SMOKE_PQC_REPORT_FILE="$MAC_PQC_REPORT" \
    SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1 \
    SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE="$EXPECTED_TARGET_SUITE" \
    "$MAC_APP_BIN" >"$MAC_STDOUT" 2>&1 &
  fi
  MAC_PID="$!"

  wait_for_file_nonempty "$MAC_PQC_REPORT" 60 "macOS PQC report"
  wait_for_file_pattern "$MAC_STATUS" 'ready discovery=_skybridge._tcp' 60 "macOS ready"
  load_pqc_report "$MAC_PQC_REPORT"

  if [[ "$SMOKE_SCENARIO" == "bootstrap-rekey" ]]; then
    SIMCTL_CHILD_SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
    SIMCTL_CHILD_SKYBRIDGE_DEVICE_ID="$ROUND_IOS_DEVICE_ID" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_ALLOW_IDENTITY_OVERRIDE=1 \
    SIMCTL_CHILD_SB_PQC_PREFERRED_SUITE="$IOS_PREFERRED_SUITE" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_ROLE=ios-p2p-client \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_TARGET_DEVICE_ID="$MAC_PQC_DEVICE_ID" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_TARGET_NAME="$MAC_TARGET_NAME" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_BASENAME" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1 \
    xcrun simctl launch \
      --terminate-running-process \
      --stdout="$IOS_STDOUT" \
      --stderr="$IOS_STDERR" \
      "$SIM_ID" \
      "$IOS_BUNDLE_ID" >/dev/null
  else
    SIMCTL_CHILD_SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 \
    SIMCTL_CHILD_SKYBRIDGE_DEVICE_ID="$ROUND_IOS_DEVICE_ID" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_ALLOW_IDENTITY_OVERRIDE=1 \
    SIMCTL_CHILD_SB_PQC_PREFERRED_SUITE="$IOS_PREFERRED_SUITE" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_ROLE=ios-p2p-client \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_TARGET_DEVICE_ID="$MAC_PQC_DEVICE_ID" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_TARGET_NAME="$MAC_TARGET_NAME" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_BASENAME" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
    SIMCTL_CHILD_SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE="$EXPECTED_TARGET_SUITE" \
    SIMCTL_CHILD_SKYBRIDGE_PQC_PEER_DEVICE_ID="$MAC_PQC_DEVICE_ID" \
    SIMCTL_CHILD_SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64="$MAC_PQC_XWING_PUBLIC_KEY_BASE64" \
    SIMCTL_CHILD_SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64" \
    SIMCTL_CHILD_SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64" \
    xcrun simctl launch \
      --terminate-running-process \
      --stdout="$IOS_STDOUT" \
      --stderr="$IOS_STDERR" \
      "$SIM_ID" \
      "$IOS_BUNDLE_ID" >/dev/null
  fi

  if [[ "$SMOKE_SCENARIO" == "bootstrap-rekey" ]]; then
    wait_for_file_pattern "$IOS_STATUS_PATH" 'success suite=X-Wing bootstrapRekey=1' "$SMOKE_TIMEOUT_SECONDS" "iOS success"
    require_file_pattern "$IOS_STATUS_PATH" 'suite X25519-Ed25519' "iOS classic bootstrap"
    require_file_pattern "$IOS_STATUS_PATH" 'rekey X25519-Ed25519 -> X-Wing' "iOS rekey"
  else
    wait_for_file_pattern "$MAC_STATUS" "success .*suite=${EXPECTED_TARGET_SUITE} handshakeOnly=1" "$SMOKE_TIMEOUT_SECONDS" "macOS handshake success"
    wait_for_file_pattern "$IOS_STATUS_PATH" "success suite=${EXPECTED_TARGET_SUITE} handshakeOnly=1" "$SMOKE_TIMEOUT_SECONDS" "iOS handshake success"
    require_file_pattern "$IOS_STATUS_PATH" "suite ${EXPECTED_TARGET_SUITE}" "iOS negotiated suite"
    require_file_absent_pattern "$IOS_STATUS_PATH" 'rekey ' "iOS unexpected rekey"
    require_file_absent_pattern "$IOS_STATUS_PATH" 'X25519' "iOS unexpected classic suite"
  fi

  echo "   macOS: $(tail -n 1 "$MAC_STATUS")"
  echo "   iOS:   $(tail -n 1 "$IOS_STATUS_PATH")"
done

echo "==> Local P2P smoke completed successfully"
echo "    mac logs: $ARTIFACT_DIR/mac_round_*.stdout.log"
echo "    ios logs: $ARTIFACT_DIR/ios_round_*.stdout.log"
