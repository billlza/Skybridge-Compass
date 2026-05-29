#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/signing_entitlements_helpers.sh"
source "$ROOT_DIR/Scripts/xcodebuild_helpers.sh"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/real_device_file_smoke_$(date +%Y%m%d_%H%M%S)}"
IOS_PROJECT="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_DEBUG_ENTITLEMENTS="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOSDebug.entitlements"
IOS_BUNDLE_ID="com.skybridge.compass.ios"
SMOKE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-180}"
HOST_STARTUP_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_HOST_STARTUP_TIMEOUT_SECONDS:-45}"
IOS_LAUNCH_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_IOS_LAUNCH_TIMEOUT_SECONDS:-$SMOKE_TIMEOUT_SECONDS}"
HOST_TOTAL_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_MAC_HOST_TIMEOUT_SECONDS:-}"
if [[ -z "$HOST_TOTAL_TIMEOUT_SECONDS" ]]; then
  HOST_TOTAL_TIMEOUT_SECONDS=$((IOS_LAUNCH_TIMEOUT_SECONDS + SMOKE_TIMEOUT_SECONDS + HOST_STARTUP_TIMEOUT_SECONDS + 30))
fi
RUN_ID="${SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID:-$(date +%Y%m%d%H%M%S)}"
USER_REALISTIC="${SKYBRIDGE_SMOKE_USER_REALISTIC:-0}"
MAC_HOST_MODE="${SKYBRIDGE_SMOKE_MAC_HOST_MODE:-}"
USE_OOB_QR_BOOTSTRAP="${SKYBRIDGE_SMOKE_USE_OOB_QR_BOOTSTRAP:-0}"
REQUIRE_SIGNED_KEM_REFRESH="${SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH:-$USER_REALISTIC}"
FORCE_SIGNED_KEM_REFRESH="${SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH:-$REQUIRE_SIGNED_KEM_REFRESH}"
ALLOW_UNNOTARIZED_DMG_FOR_LAB="${SKYBRIDGE_SMOKE_ALLOW_UNNOTARIZED_DMG_FOR_LAB:-0}"
PIB_APPROVAL_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_PIB_APPROVAL_TIMEOUT_SECONDS:-$SMOKE_TIMEOUT_SECONDS}"
PREFERRED_SUITE="${SB_PQC_PREFERRED_SUITE:-xwing}"
HOST_PREFERRED_SUITE="${SB_PQC_HOST_PREFERRED_SUITE:-$PREFERRED_SUITE}"
IOS_PREFERRED_SUITE="${SB_PQC_IOS_PREFERRED_SUITE:-$PREFERRED_SUITE}"
EXPECTED_TARGET_SUITE="${SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE:-X-Wing}"
DEFAULT_EXPECT_PQC_REKEY="0"
EXPECT_PQC_REKEY="${SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY:-$DEFAULT_EXPECT_PQC_REKEY}"
PRESERVE_INSTALL="${SKYBRIDGE_SMOKE_PRESERVE_INSTALL:-1}"
REQUIRE_MAC_INITIATED_RECONNECT="${SKYBRIDGE_SMOKE_REQUIRE_MAC_INITIATED_RECONNECT:-0}"
SWIFTPM_CACHE_DIR="${SKYBRIDGE_SWIFTPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"
SWIFT_MODULE_CACHE_DIR="${SKYBRIDGE_SWIFT_MODULE_CACHE_DIR:-$ROOT_DIR/.swiftpm-module-cache}"

if [[ -z "$MAC_HOST_MODE" ]]; then
  if [[ "$USER_REALISTIC" == "1" ]]; then
    MAC_HOST_MODE="signed-app"
  else
    MAC_HOST_MODE="swiftpm-host"
  fi
fi

case "$USER_REALISTIC" in
  0|1) ;;
  *)
    echo "Unsupported SKYBRIDGE_SMOKE_USER_REALISTIC=$USER_REALISTIC (expected 0 or 1)" >&2
    exit 2
    ;;
esac

case "$MAC_HOST_MODE" in
  signed-app|swiftpm-host) ;;
  *)
    echo "Unsupported SKYBRIDGE_SMOKE_MAC_HOST_MODE=$MAC_HOST_MODE (expected signed-app or swiftpm-host)" >&2
    exit 2
    ;;
esac

case "$USE_OOB_QR_BOOTSTRAP" in
  0|1) ;;
  *)
    echo "Unsupported SKYBRIDGE_SMOKE_USE_OOB_QR_BOOTSTRAP=$USE_OOB_QR_BOOTSTRAP (expected 0 or 1)" >&2
    exit 2
    ;;
esac

if [[ "$USE_OOB_QR_BOOTSTRAP" == "1" ]]; then
  echo "SKYBRIDGE_SMOKE_USE_OOB_QR_BOOTSTRAP has been removed: P2P KEM recovery must use PIB-1 SAS binding followed by SKR-1 signed LAN KEM refresh, not QR bootstrap." >&2
  exit 2
fi

case "$REQUIRE_SIGNED_KEM_REFRESH" in
  0|1) ;;
  *)
    echo "Unsupported SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH=$REQUIRE_SIGNED_KEM_REFRESH (expected 0 or 1)" >&2
    exit 2
    ;;
esac

case "$FORCE_SIGNED_KEM_REFRESH" in
  0|1) ;;
  *)
    echo "Unsupported SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH=$FORCE_SIGNED_KEM_REFRESH (expected 0 or 1)" >&2
    exit 2
    ;;
esac

case "$ALLOW_UNNOTARIZED_DMG_FOR_LAB" in
  0|1) ;;
  *)
    echo "Unsupported SKYBRIDGE_SMOKE_ALLOW_UNNOTARIZED_DMG_FOR_LAB=$ALLOW_UNNOTARIZED_DMG_FOR_LAB (expected 0 or 1)" >&2
    exit 2
    ;;
esac

if [[ "$EXPECT_PQC_REKEY" == "1" ]]; then
  echo "Real-device file-transfer smoke no longer supports SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1 because strict PQC forbids classic bootstrap fallback/rekey as a success path." >&2
  echo "Use the default direct PQC path with injected lab trust, or SKYBRIDGE_SMOKE_USER_REALISTIC=1 with existing persisted user trust." >&2
  exit 2
fi

if [[ "$USER_REALISTIC" == "1" ]]; then
  if [[ "$MAC_HOST_MODE" != "signed-app" ]]; then
    echo "Realistic file-transfer smoke requires SKYBRIDGE_SMOKE_MAC_HOST_MODE=signed-app; use non-realistic mode for SwiftPM host diagnostics." >&2
    exit 2
  fi
  if [[ "$REQUIRE_SIGNED_KEM_REFRESH" != "1" ]]; then
    echo "Realistic file-transfer smoke requires SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH=1 so KEM recovery is proven by signed refresh evidence." >&2
    exit 2
  fi
  if [[ "$PRESERVE_INSTALL" != "1" ]]; then
    echo "Realistic file-transfer smoke requires SKYBRIDGE_SMOKE_PRESERVE_INSTALL=1 so Local Network/TCC and user trust state are not reset." >&2
    exit 2
  fi
fi

mkdir -p "$ARTIFACT_DIR"
mkdir -p "$SWIFTPM_CACHE_DIR" "$SWIFT_MODULE_CACHE_DIR"

pick_real_device_id() {
  python3 - <<'PY'
import re
import subprocess

def pick_from_xctrace():
    output = subprocess.check_output(["xcrun", "xctrace", "list", "devices"], text=True)
    in_devices = False
    for line in output.splitlines():
        stripped = line.strip()
        if stripped == "== Devices ==":
            in_devices = True
            continue
        if stripped.startswith("== ") and stripped != "== Devices ==":
            in_devices = False
        if not in_devices:
            continue
        if not stripped or "Mac" in stripped:
            continue
        match = re.search(r"\(([0-9A-Fa-f-]{20,})\)$", stripped)
        if match:
            print(match.group(1))
            return True
    return False

def pick_from_devicectl():
    try:
        output = subprocess.check_output(
            ["xcrun", "devicectl", "list", "devices"],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False

    candidates = []
    for line in output.splitlines():
        if "available" not in line or "paired" not in line:
            continue
        match = re.search(r"([0-9A-Fa-f-]{8}(?:-[0-9A-Fa-f-]{4}){3}-[0-9A-Fa-f-]{12})", line)
        if not match:
            continue
        priority = 0 if "iPad" in line else 1
        candidates.append((priority, match.group(1)))

    for _, identifier in sorted(candidates):
        try:
            details = subprocess.check_output(
                ["xcrun", "devicectl", "device", "info", "details", "--device", identifier],
                stderr=subprocess.STDOUT,
                text=True,
                timeout=30,
            )
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            continue
        udid = re.search(r"udid:\s*([0-9A-Fa-f-]{20,})", details)
        print(udid.group(1) if udid else identifier)
        return True

    return False

if pick_from_xctrace() or pick_from_devicectl():
    raise SystemExit(0)

raise SystemExit("No connected real iOS device found.")
PY
}

IOS_DEVICE_ID="${SKYBRIDGE_REAL_DEVICE_ID:-$(pick_real_device_id)}"
MAC_TARGET_NAME="${SKYBRIDGE_SMOKE_MAC_TARGET_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"
HOST_STATUS="$ARTIFACT_DIR/mac.status.log"
HOST_PQC_REPORT="$ARTIFACT_DIR/mac.pqc.json"
HOST_STDOUT="$ARTIFACT_DIR/mac.stdout.log"
HOST_STDERR="$ARTIFACT_DIR/mac.stderr.log"
IOS_STATUS_NAME="ios-real-device-${RUN_ID}.status.log"
IOS_STATUS_LOCAL="$ARTIFACT_DIR/$IOS_STATUS_NAME"
IOS_BUILD_LOG="$ARTIFACT_DIR/ios-build.log"
DEVICE_INFO_JSON="$ARTIFACT_DIR/device-info.json"
LAUNCH_RESULT_JSON="$ARTIFACT_DIR/ios-launch.json"
HOST_PID=""

cleanup() {
  if [[ -n "$HOST_PID" ]]; then
    kill "$HOST_PID" >/dev/null 2>&1 || true
    wait "$HOST_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

capture_host_context() {
  local label="$1"
  local safe_label
  safe_label="$(printf '%s' "$label" | tr -cs 'A-Za-z0-9_.-' '_')"

  echo "---- macOS host status tail ($HOST_STATUS) ----" >&2
  tail -n 120 "$HOST_STATUS" >&2 2>/dev/null || true
  echo "---- macOS host stdout tail ($HOST_STDOUT) ----" >&2
  tail -n 120 "$HOST_STDOUT" >&2 2>/dev/null || true
  echo "---- macOS host stderr tail ($HOST_STDERR) ----" >&2
  tail -n 120 "$HOST_STDERR" >&2 2>/dev/null || true

  if command -v log >/dev/null 2>&1; then
    local log_path="$ARTIFACT_DIR/mac-host-${safe_label}.system.log"
    local process_name="LocalLanInteropHost"
    if [[ "$MAC_HOST_MODE" == "signed-app" ]]; then
      process_name="SkyBridgeCompassApp"
    fi
    log show --style compact --last 2m --predicate "process == \"${process_name}\" || subsystem == \"com.skybridge.transfer\" || subsystem == \"com.skybridge.compass\"" >"$log_path" 2>/dev/null || true
    echo "---- macOS host system log tail ($log_path) ----" >&2
    tail -n 80 "$log_path" >&2 2>/dev/null || true
  fi

  if [[ -n "${HOST_PID:-}" ]] && kill -0 "$HOST_PID" >/dev/null 2>&1; then
    local sample_path="$ARTIFACT_DIR/mac-host-${safe_label}.sample.txt"
    sample "$HOST_PID" 2 -file "$sample_path" >/dev/null 2>&1 || true
    echo "    macOS host sample: $sample_path" >&2
  fi
}

host_process_running() {
  if [[ -z "${HOST_PID:-}" ]]; then
    return 0
  fi
  if ! kill -0 "$HOST_PID" >/dev/null 2>&1; then
    return 1
  fi

  local state
  state="$(ps -p "$HOST_PID" -o stat= 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$state" && "$state" != Z* ]]
}

host_completed_file_transfer_smoke() {
  [[ -f "$HOST_STATUS" ]] || return 1
  if [[ "$REQUIRE_MAC_INITIATED_RECONNECT" == "1" ]]; then
    grep -qE 'success .*fileTransfer=1 .*macInitiatedTransfer=1 .*macReconnectRoute=(control:[^[:space:]]+|bonjour-transfer)' "$HOST_STATUS"
  else
    grep -qE 'success .*fileTransfer=1' "$HOST_STATUS"
  fi
}

collect_named_pids() {
  local executable_name="$1"
  pgrep -x "$executable_name" 2>/dev/null || true
}

open_supports_env() {
  local help_text
  help_text="$(open -h 2>&1 || true)"
  grep -q -- '--env' <<<"$help_text"
}

pid_in_list() {
  local target_pid="$1"
  local pid_list="$2"
  local existing_pid

  for existing_pid in $pid_list; do
    if [[ "$existing_pid" == "$target_pid" ]]; then
      return 0
    fi
  done

  return 1
}

wait_for_new_named_pid() {
  local executable_name="$1"
  local before_pids="$2"
  local timeout_seconds="$3"
  local started_at
  local pid
  local current_pids

  started_at="$(date +%s)"
  while true; do
    current_pids="$(collect_named_pids "$executable_name")"
    for pid in $current_pids; do
      if ! pid_in_list "$pid" "$before_pids"; then
        printf '%s\n' "$pid"
        return 0
      fi
    done

    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      return 1
    fi
    sleep 0.2
  done
}

has_file_transfer_failure_without_phase() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  awk '/failed stage=file-transfer/ && $0 !~ /phase=/ { found=1 } END { exit found ? 0 : 1 }' "$path"
}

wait_for_file_pattern() {
  local path="$1"
  local pattern="$2"
  local timeout_seconds="$3"
  local label="$4"
  local started_at
  started_at="$(date +%s)"
  while true; do
    copy_ios_status
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE 'failed stage=file-transfer phase=unknown' "$IOS_STATUS_LOCAL"; then
      echo "Detected file-transfer instrumentation gap while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    if has_file_transfer_failure_without_phase "$IOS_STATUS_LOCAL"; then
      echo "Detected file-transfer missing phase while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE 'failed stage=' "$IOS_STATUS_LOCAL"; then
      echo "Detected iOS failure while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    if [[ -f "$path" ]] && grep -qE 'failed stage=file-transfer phase=unknown' "$path"; then
      echo "Detected file-transfer instrumentation gap while waiting for ${label}: ${path}" >&2
      echo "---- iOS status tail ($IOS_STATUS_LOCAL) ----" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    if has_file_transfer_failure_without_phase "$path"; then
      echo "Detected file-transfer missing phase while waiting for ${label}: ${path}" >&2
      echo "---- iOS status tail ($IOS_STATUS_LOCAL) ----" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    if [[ -f "$path" ]] && grep -qE 'failed stage=' "$path"; then
      echo "Detected failure while waiting for ${label}: ${path}" >&2
      echo "---- iOS status tail ($IOS_STATUS_LOCAL) ----" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    if [[ -f "$path" ]] && grep -qE "$pattern" "$path"; then
      return 0
    fi
    if ! host_process_running; then
      echo "macOS host exited before ${label}: ${path}" >&2
      copy_ios_status
      echo "---- iOS status tail ($IOS_STATUS_LOCAL) ----" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${path}" >&2
      copy_ios_status
      echo "---- iOS status tail ($IOS_STATUS_LOCAL) ----" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    sleep 1
  done
}

copy_ios_status() {
  rm -f "$IOS_STATUS_LOCAL"
  xcrun devicectl device copy from \
    --device "$IOS_DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$IOS_BUNDLE_ID" \
    --source "Library/Caches/$IOS_STATUS_NAME" \
    --destination "$IOS_STATUS_LOCAL" >/dev/null 2>&1 || true
}

wait_for_ios_status_pattern() {
  local pattern="$1"
  local timeout_seconds="$2"
  local label="$3"
  local started_at
  started_at="$(date +%s)"
  while true; do
    copy_ios_status
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE 'failed stage=file-transfer phase=unknown' "$IOS_STATUS_LOCAL"; then
      echo "Detected file-transfer instrumentation gap while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    if has_file_transfer_failure_without_phase "$IOS_STATUS_LOCAL"; then
      echo "Detected file-transfer missing phase while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE 'failed stage=' "$IOS_STATUS_LOCAL"; then
      echo "Detected iOS failure while waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE "$pattern" "$IOS_STATUS_LOCAL"; then
      return 0
    fi
    if ! host_process_running; then
      if host_completed_file_transfer_smoke; then
        if (( "$(date +%s)" - started_at >= timeout_seconds )); then
          echo "Timed out waiting for ${label} after macOS host completed file-transfer smoke: ${IOS_STATUS_LOCAL}" >&2
          tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
          capture_host_context "$label"
          return 1
        fi
        sleep 2
        continue
      fi
      echo "macOS host exited before ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "$label"
      return 1
    fi
    sleep 2
  done
}

print_pib1_operator_code() {
  local ios_line=""
  local host_line=""
  local code=""
  local fingerprint=""

  if [[ -f "$IOS_STATUS_LOCAL" ]]; then
    ios_line="$(grep -E 'PIB-1 protocol identity binding signature verified: .*code=[0-9]{6}' "$IOS_STATUS_LOCAL" 2>/dev/null | tail -n 1 || true)"
  fi
  if [[ -f "$HOST_STATUS" ]]; then
    host_line="$(grep -E 'PIB-1 (requester protocol identity approval required|requester protocol identity pinned|protocol identity binding served): .*code=[0-9]{6}' "$HOST_STATUS" 2>/dev/null | tail -n 1 || true)"
  fi

  code="$(printf '%s\n%s\n' "$ios_line" "$host_line" | sed -nE 's/.*code=([0-9]{6}).*/\1/p' | head -n 1)"
  fingerprint="$(printf '%s\n%s\n' "$ios_line" "$host_line" | sed -nE 's/.*fingerprint=([0-9A-Fa-f]+).*/\1/p' | head -n 1)"

  if [[ -n "$code" ]]; then
    echo "==> PIB-1 SAS code: ${code}. Compare the same six digits on Mac and iOS; approve on Mac first if prompted, then approve on iOS within ${PIB_APPROVAL_TIMEOUT_SECONDS}s."
    if [[ -n "$fingerprint" ]]; then
      echo "==> PIB-1 protocol identity fingerprint: ${fingerprint}"
    fi
  fi
}

wait_for_optional_protocol_identity_binding() {
  local timeout_seconds="$1"
  local started_at
  started_at="$(date +%s)"
  while true; do
    copy_ios_status
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE 'failed stage=file-transfer phase=unknown' "$IOS_STATUS_LOCAL"; then
      echo "Detected file-transfer instrumentation gap while waiting for SKR-1 or PIB-1: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "SKR-1 or PIB-1"
      return 1
    fi
    if has_file_transfer_failure_without_phase "$IOS_STATUS_LOCAL"; then
      echo "Detected file-transfer missing phase while waiting for SKR-1 or PIB-1: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "SKR-1 or PIB-1"
      return 1
    fi
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE 'failed stage=' "$IOS_STATUS_LOCAL"; then
      echo "Detected iOS failure while waiting for SKR-1 or PIB-1: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "SKR-1 or PIB-1"
      return 1
    fi
    if [[ -f "$IOS_STATUS_LOCAL" ]] && grep -qE 'PIB-1 protocol identity binding request: .*lifecycle=identity-oob>request' "$IOS_STATUS_LOCAL"; then
      echo "==> PIB-1 protocol identity binding required; waiting for Mac requester pin, SAS verification, and iOS protocol identity pin"
      wait_for_file_pattern "$HOST_STATUS" 'PIB-1 (requester protocol identity approval required: .*lifecycle=identity-oob>awaiting-requester-approval|requester protocol identity pinned: .*lifecycle=identity-oob>requester-pinned|protocol identity binding served: .*lifecycle=identity-oob>served)' "$timeout_seconds" "macOS PIB-1 requester approval prompt"
      copy_ios_status
      print_pib1_operator_code
      wait_for_file_pattern "$HOST_STATUS" 'PIB-1 requester protocol identity pinned: .*lifecycle=identity-oob>requester-pinned' "$timeout_seconds" "macOS PIB-1 requester pinned"
      wait_for_file_pattern "$HOST_STATUS" 'PIB-1 protocol identity binding served: .*lifecycle=identity-oob>served' "$timeout_seconds" "macOS PIB-1 served"
      wait_for_ios_status_pattern 'PIB-1 protocol identity binding signature verified: .*lifecycle=identity-oob>verified' "$timeout_seconds" "iOS PIB-1 signature verified"
      copy_ios_status
      print_pib1_operator_code
      wait_for_ios_status_pattern 'PIB-1 protocol identity binding (pinned|operator approved): .*lifecycle=identity-oob>pinned' "$timeout_seconds" "iOS PIB-1 pinned"
      return 0
    fi
    if [[ -f "$IOS_STATUS_LOCAL" ]] \
      && grep -qE 'SKR-1 signed LAN KEM refresh request: .*lifecycle=missing-kem>request' "$IOS_STATUS_LOCAL" \
      && [[ -f "$HOST_STATUS" ]] \
      && grep -qE 'SKR-1 signed LAN KEM refresh served: .*lifecycle=request>served' "$HOST_STATUS"; then
      return 0
    fi
    if ! host_process_running; then
      echo "macOS host exited before SKR-1 or PIB-1 evidence: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "SKR-1 or PIB-1"
      return 1
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for SKR-1 or PIB-1 evidence: ${IOS_STATUS_LOCAL}" >&2
      tail -n 120 "$IOS_STATUS_LOCAL" >&2 2>/dev/null || true
      capture_host_context "SKR-1 or PIB-1"
      return 1
    fi
    sleep 2
  done
}

launch_result_indicates_ios_profile_trust_failure() {
  [[ -f "$LAUNCH_RESULT_JSON" ]] \
    && grep -qE 'invalid code signature|inadequate entitlements|profile has not been explicitly trusted' "$LAUNCH_RESULT_JSON"
}

launch_result_indicates_locked_device() {
  [[ -f "$LAUNCH_RESULT_JSON" ]] \
    && grep -qE 'Locked|could not be unlocked|device.*locked|Device.*locked' "$LAUNCH_RESULT_JSON"
}

launch_ios_smoke_app() {
  local started_at
  local attempt=1

  started_at="$(date +%s)"
  while true; do
    rm -f "$LAUNCH_RESULT_JSON"
    if xcrun devicectl device process launch \
      --device "$IOS_DEVICE_ID" \
      --terminate-existing \
      --environment-variables "$IOS_ENV_JSON" \
      --json-output "$LAUNCH_RESULT_JSON" \
      "$IOS_BUNDLE_ID" >/dev/null; then
      return 0
    fi

    if launch_result_indicates_ios_profile_trust_failure; then
      echo "iOS smoke app launch failed at launch stage: code signature/profile/trust rejected by device." >&2
      echo "This is a real-device precondition failure, not a file-transfer/network pass." >&2
      cat "$LAUNCH_RESULT_JSON" >&2 2>/dev/null || true
      capture_host_context "iOS app launch signing"
      return 1
    fi

    if launch_result_indicates_locked_device; then
      if (( "$(date +%s)" - started_at >= IOS_LAUNCH_TIMEOUT_SECONDS )); then
        echo "Timed out launching iOS smoke app because the real device stayed locked for ${IOS_LAUNCH_TIMEOUT_SECONDS}s." >&2
        echo "Unlock the iPad/iPhone and rerun the same CLI command; this is a real-device precondition, not a transfer pass." >&2
        cat "$LAUNCH_RESULT_JSON" >&2 2>/dev/null || true
        capture_host_context "iOS app launch locked"
        return 1
      fi

      echo "    iOS launch attempt ${attempt} was denied because the device is locked; unlock the device, keeping it on the home screen, and waiting..." >&2
      attempt=$((attempt + 1))
      sleep 5
      continue
    fi

    echo "iOS smoke app launch failed before transfer validation." >&2
    cat "$LAUNCH_RESULT_JSON" >&2 2>/dev/null || true
    capture_host_context "iOS app launch"
    return 1
  done
}

capture_device_info() {
  local attempts="${SKYBRIDGE_SMOKE_DEVICE_INFO_ATTEMPTS:-3}"
  local attempt
  for attempt in $(seq 1 "$attempts"); do
    if xcrun devicectl list devices --json-output "$DEVICE_INFO_JSON" >/dev/null; then
      return 0
    fi
    echo "    devicectl JSON device list failed (${attempt}/${attempts})" >&2
    sleep 2
  done

  echo "    warning: continuing after devicectl JSON device list failed" >&2
  xcrun devicectl list devices >"$ARTIFACT_DIR/device-info.txt" 2>&1 || true
  python3 - "$DEVICE_INFO_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"deviceInfoCapture": "failed"}, handle)
PY
}

echo "==> Artifacts: $ARTIFACT_DIR"
echo "==> Real device: $IOS_DEVICE_ID"
echo "==> Run ID: $RUN_ID"
echo "==> Host preferred suite: $HOST_PREFERRED_SUITE"
echo "==> iOS preferred suite: $IOS_PREFERRED_SUITE"
echo "==> Mac host mode: $MAC_HOST_MODE"
if [[ "$USER_REALISTIC" == "1" ]]; then
  echo "==> Mode: user-realistic (persistent keychain, SKR-1 signed LAN KEM refresh, no raw peer trust injection, no auto-approval, no compatibility preference mutation)"
else
  echo "==> Mode: lab smoke (in-memory keychain, injected/auto-approved trust allowed)"
fi
echo "==> Signed KEM refresh required: $REQUIRE_SIGNED_KEM_REFRESH"
echo "==> Force signed KEM refresh by clearing KEM cache: $FORCE_SIGNED_KEM_REFRESH"
echo "==> OOB QR KEM bootstrap: removed (PIB-1 SAS + SKR-1 only)"
if [[ -n "$EXPECTED_TARGET_SUITE" ]]; then
  echo "==> Expected negotiated suite: $EXPECTED_TARGET_SUITE"
fi
echo "==> Expect PQC rekey: $EXPECT_PQC_REKEY"
echo "==> Require macOS-initiated reconnect: $REQUIRE_MAC_INITIATED_RECONNECT"
echo "==> Preserve installed app: $PRESERVE_INSTALL"
echo "==> Allow unnotarized DMG for lab diagnostics: $ALLOW_UNNOTARIZED_DMG_FOR_LAB"
echo "==> Host startup timeout: ${HOST_STARTUP_TIMEOUT_SECONDS}s"
echo "==> iOS launch timeout: ${IOS_LAUNCH_TIMEOUT_SECONDS}s"
echo "==> Mac host total timeout: ${HOST_TOTAL_TIMEOUT_SECONDS}s"

echo "==> Inspecting connected device"
capture_device_info

if [[ "$MAC_HOST_MODE" == "swiftpm-host" ]]; then
  echo "==> Building macOS LAN host"
  (
    cd "$ROOT_DIR"
    SWIFTPM_CACHE_PATH="$SWIFTPM_CACHE_DIR" \
    CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
    SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
    swift build --product LocalLanInteropHost
  ) >"$ARTIFACT_DIR/macos-build.log"

  MAC_APP_BIN="$ROOT_DIR/.build/debug/LocalLanInteropHost"
  if [[ ! -x "$MAC_APP_BIN" ]]; then
    echo "macOS LAN host executable not found: $MAC_APP_BIN" >&2
    exit 1
  fi
else
  MAC_APP_BUNDLE="${SKYBRIDGE_SMOKE_MAC_APP_PATH:-$ROOT_DIR/dist/SkyBridge Compass Pro.app}"
  MAC_APP_BIN="$MAC_APP_BUNDLE/Contents/MacOS/SkyBridgeCompassApp"
  if [[ ! -x "$MAC_APP_BIN" ]]; then
    echo "Signed macOS app host not found: $MAC_APP_BIN" >&2
    echo "Build and notarize the DMG first, or set SKYBRIDGE_SMOKE_MAC_HOST_MODE=swiftpm-host for lab diagnostics." >&2
    exit 2
  fi
  echo "==> Verifying signed macOS app host"
  codesign --verify --strict --deep --verbose=2 "$MAC_APP_BUNDLE" >"$ARTIFACT_DIR/macos-host-codesign.log" 2>&1
  if [[ "$USER_REALISTIC" == "1" ]]; then
    echo "==> Verifying signed macOS app host against release DMG"
    readiness_args=(
      --app-path "$MAC_APP_BUNDLE"
      --package-integrity-only
    )
    if [[ "$ALLOW_UNNOTARIZED_DMG_FOR_LAB" != "1" ]]; then
      readiness_args+=(--require-notarization)
    fi
    if [[ -n "${SKYBRIDGE_SMOKE_MAC_DMG_PATH:-}" ]]; then
      readiness_args+=(--dmg-path "$SKYBRIDGE_SMOKE_MAC_DMG_PATH")
    fi
    if [[ "$ALLOW_UNNOTARIZED_DMG_FOR_LAB" == "1" ]]; then
      echo "    release readiness notarization failure is allowed for this lab run only"
    fi
    "$ROOT_DIR/Scripts/check_macos_release_readiness.sh" "${readiness_args[@]}" >"$ARTIFACT_DIR/macos-release-readiness.log" 2>&1
  fi
fi

echo "==> Starting macOS LAN host"
HOST_ROLE="mac-host"
if [[ "$MAC_HOST_MODE" == "signed-app" ]]; then
  HOST_ROLE="mac-p2p-host"
fi
HOST_ENV=(
  "SB_PQC_PREFERRED_SUITE=$HOST_PREFERRED_SUITE"
  "SKYBRIDGE_SMOKE_ROLE=$HOST_ROLE"
  "SKYBRIDGE_SMOKE_STATUS_FILE=$HOST_STATUS"
  "SKYBRIDGE_SMOKE_PQC_REPORT_FILE=$HOST_PQC_REPORT"
  "SKYBRIDGE_SMOKE_EXPECT_FILE_TRANSFER=1"
  "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=$EXPECT_PQC_REKEY"
  "SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE=$EXPECTED_TARGET_SUITE"
  "SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID=$RUN_ID"
  "SKYBRIDGE_SMOKE_REQUIRE_MAC_INITIATED_RECONNECT=$REQUIRE_MAC_INITIATED_RECONNECT"
  "SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH=$REQUIRE_SIGNED_KEM_REFRESH"
  "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS=$HOST_TOTAL_TIMEOUT_SECONDS"
  "LLVM_PROFILE_FILE=$ARTIFACT_DIR/mac-host-%p.profraw"
)
if [[ "$MAC_HOST_MODE" == "signed-app" ]]; then
  HOST_ENV+=(
    "SKYBRIDGE_SMOKE_AUTO_EXIT=1"
  )
fi
if [[ "$USER_REALISTIC" != "1" ]]; then
  HOST_ENV+=(
    "SKYBRIDGE_KEYCHAIN_IN_MEMORY=1"
    "SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=1"
    "SKYBRIDGE_SMOKE_ENABLE_COMPATIBILITY_MODE=1"
  )
fi
if [[ "$MAC_HOST_MODE" == "signed-app" ]]; then
  echo "    launching signed app bundle through LaunchServices"
  printf 'launch signed-app method=LaunchServices bundle=%s\n' "$MAC_APP_BUNDLE" >>"$HOST_STATUS"
  EXISTING_HOST_PIDS="$(collect_named_pids "SkyBridgeCompassApp")"
  if ! open_supports_env; then
    echo "This macOS open(1) does not support --env, so signed-app smoke cannot launch through LaunchServices with a realistic environment." >&2
    echo "Use a newer macOS/Xcode toolchain or add an app-level smoke config file reader before running signed-app smoke." >&2
    exit 2
  fi
  if [[ "$USER_REALISTIC" == "1" && "${SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING:-0}" != "1" ]]; then
    echo "    foregrounding signed app so PIB-1 requester approval is visible"
    printf 'launch signed-app approvalSurface=foreground\n' >>"$HOST_STATUS"
    OPEN_ARGS=(-n --stdout "$HOST_STDOUT" --stderr "$HOST_STDERR")
  else
    OPEN_ARGS=(-n -g --stdout "$HOST_STDOUT" --stderr "$HOST_STDERR")
  fi
  for pair in "${HOST_ENV[@]}"; do
    OPEN_ARGS+=(--env "$pair")
  done
  OPEN_ARGS+=("$MAC_APP_BUNDLE")
  if ! open "${OPEN_ARGS[@]}"; then
    echo "LaunchServices failed to open signed macOS app host: $MAC_APP_BUNDLE" >&2
    capture_host_context "macOS host LaunchServices start"
    exit 1
  fi
  if ! HOST_PID="$(wait_for_new_named_pid "SkyBridgeCompassApp" "$EXISTING_HOST_PIDS" "$HOST_STARTUP_TIMEOUT_SECONDS")"; then
    echo "Timed out waiting for signed macOS app host process after LaunchServices open" >&2
    capture_host_context "macOS host process start"
    exit 1
  fi
  echo "    signed app host pid: $HOST_PID"
else
  env "${HOST_ENV[@]}" "$MAC_APP_BIN" >"$HOST_STDOUT" 2>"$HOST_STDERR" &
  HOST_PID="$!"
fi

wait_for_file_pattern "$HOST_STATUS" 'identity ready device=' "$HOST_STARTUP_TIMEOUT_SECONDS" "macOS host identity"
wait_for_file_pattern "$HOST_STATUS" 'ready discovery=_skybridge._tcp' "$HOST_STARTUP_TIMEOUT_SECONDS" "macOS host ready"
wait_for_file_pattern "$HOST_PQC_REPORT" '"deviceId"' "$HOST_STARTUP_TIMEOUT_SECONDS" "macOS PQC report"
MAC_QR_CONNECT_LINK=""

echo "==> Parsing macOS PQC report"
REPORT_DATA="$(python3 - "$HOST_PQC_REPORT" <<'PY'
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

MAC_PQC_DEVICE_ID="$(printf '%s\n' "$REPORT_DATA" | sed -n '1p')"
MAC_PQC_XWING_PUBLIC_KEY_BASE64="$(printf '%s\n' "$REPORT_DATA" | sed -n '2p')"
MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64="$(printf '%s\n' "$REPORT_DATA" | sed -n '3p')"
MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64="$(printf '%s\n' "$REPORT_DATA" | sed -n '4p')"

if [[ -z "$MAC_PQC_DEVICE_ID" ]]; then
  echo "PQC report is missing deviceId: $HOST_PQC_REPORT" >&2
  exit 1
fi

if [[ -z "$MAC_PQC_XWING_PUBLIC_KEY_BASE64" && -z "$MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64" && -z "$MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64" ]]; then
  echo "PQC report has no KEM public keys; refusing a fake pass: $HOST_PQC_REPORT" >&2
  exit 1
fi

case "$(printf '%s' "$HOST_PREFERRED_SUITE" | tr '[:upper:]' '[:lower:]')" in
  xwing|x-wing|hybrid|x-wing+mldsa65|x-wing+ml-dsa-65)
    if [[ -z "$MAC_PQC_XWING_PUBLIC_KEY_BASE64" ]]; then
      echo "Host preferred suite is X-Wing, but macOS PQC report is missing suite 0x0001 key: $HOST_PQC_REPORT" >&2
      exit 1
    fi
    ;;
  mlkem|ml-kem|ml-kem-768|mlkem768)
    if [[ -z "$MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64" && -z "$MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64" ]]; then
      echo "Host preferred suite is ML-KEM, but macOS PQC report is missing suite 0x0101/0x0102 key: $HOST_PQC_REPORT" >&2
      exit 1
    fi
    ;;
esac

echo "==> Building iOS app for real device"
SKYBRIDGE_XCODE_WARNINGS_AS_ERRORS=1 skybridge_run_xcodebuild \
  -project "$IOS_PROJECT" \
  -scheme "$IOS_SCHEME" \
  -configuration Debug \
  -destination "id=$IOS_DEVICE_ID" \
  -derivedDataPath "$ARTIFACT_DIR/DerivedData-ios" \
  build >"$IOS_BUILD_LOG"

IOS_APP_PATH="$ARTIFACT_DIR/DerivedData-ios/Build/Products/Debug-iphoneos/SkyBridgeCompass-iOS.app"
if [[ ! -d "$IOS_APP_PATH" ]]; then
  echo "iOS app bundle not found: $IOS_APP_PATH" >&2
  exit 1
fi

IOS_EMBEDDED_PROFILE="$IOS_APP_PATH/embedded.mobileprovision"
if ! skybridge_profile_supports_requested_profile_backed_entitlements \
  "$IOS_EMBEDDED_PROFILE" \
  "$IOS_DEBUG_ENTITLEMENTS"; then
  echo "iOS app provisioning profile does not cover requested Debug entitlements; refusing a smoke run that would hide a signing mismatch." >&2
  echo "profile=$IOS_EMBEDDED_PROFILE entitlements=$IOS_DEBUG_ENTITLEMENTS" >&2
  exit 1
fi

echo "==> Installing iOS app on real device"
if [[ "$PRESERVE_INSTALL" != "1" ]]; then
  xcrun devicectl device uninstall app --device "$IOS_DEVICE_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
else
  echo "    preserving existing install to keep Local Network/TCC grants when possible"
fi
xcrun devicectl device install app --device "$IOS_DEVICE_ID" "$IOS_APP_PATH" >/dev/null

echo "==> Launching iOS smoke app"
echo "    if the iPad shows a Local Network permission alert, tap Allow"
IOS_PQC_PEER_DEVICE_ID="$MAC_PQC_DEVICE_ID"
IOS_PQC_PEER_XWING_PUBLIC_KEY_BASE64="$MAC_PQC_XWING_PUBLIC_KEY_BASE64"
IOS_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64"
IOS_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64"
if [[ "$USER_REALISTIC" == "1" ]]; then
  IOS_PQC_PEER_DEVICE_ID=""
  IOS_PQC_PEER_XWING_PUBLIC_KEY_BASE64=""
  IOS_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64=""
  IOS_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64=""
fi
IOS_ENV_JSON="$(
  SKYBRIDGE_SMOKE_TARGET_DEVICE_ID="$MAC_PQC_DEVICE_ID" \
  SKYBRIDGE_SMOKE_TARGET_NAME="$MAC_TARGET_NAME" \
  SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
  SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_NAME" \
	  SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID="$RUN_ID" \
	  SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY="$EXPECT_PQC_REKEY" \
	  SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE="$EXPECTED_TARGET_SUITE" \
	  SKYBRIDGE_SMOKE_EXPECT_MAC_INITIATED_RECONNECT="$REQUIRE_MAC_INITIATED_RECONNECT" \
	  SKYBRIDGE_SMOKE_USER_REALISTIC="$USER_REALISTIC" \
	  SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH="$REQUIRE_SIGNED_KEM_REFRESH" \
	  SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH="$FORCE_SIGNED_KEM_REFRESH" \
	  SKYBRIDGE_SMOKE_USE_OOB_QR_BOOTSTRAP="$USE_OOB_QR_BOOTSTRAP" \
	  SKYBRIDGE_PIB_APPROVAL_TIMEOUT_SECONDS="$PIB_APPROVAL_TIMEOUT_SECONDS" \
	  SKYBRIDGE_SMOKE_CONNECT_LINK="$MAC_QR_CONNECT_LINK" \
	  SB_PQC_PREFERRED_SUITE="$IOS_PREFERRED_SUITE" \
  SKYBRIDGE_PQC_PEER_DEVICE_ID="$IOS_PQC_PEER_DEVICE_ID" \
  SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64="$IOS_PQC_PEER_XWING_PUBLIC_KEY_BASE64" \
  SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64="$IOS_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64" \
  SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64="$IOS_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64" \
  python3 - <<'PY'
import json
import os

keys = [
    "SKYBRIDGE_SMOKE_TARGET_DEVICE_ID",
    "SKYBRIDGE_SMOKE_TARGET_NAME",
    "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS",
    "SKYBRIDGE_SMOKE_STATUS_BASENAME",
    "SKYBRIDGE_SMOKE_FILE_TRANSFER_RUN_ID",
	    "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY",
	    "SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE",
	    "SKYBRIDGE_SMOKE_EXPECT_MAC_INITIATED_RECONNECT",
	    "SKYBRIDGE_SMOKE_USER_REALISTIC",
	    "SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH",
	    "SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH",
	    "SKYBRIDGE_SMOKE_USE_OOB_QR_BOOTSTRAP",
	    "SKYBRIDGE_PIB_APPROVAL_TIMEOUT_SECONDS",
	    "SKYBRIDGE_SMOKE_CONNECT_LINK",
	    "SB_PQC_PREFERRED_SUITE",
    "SKYBRIDGE_PQC_PEER_DEVICE_ID",
    "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64",
]

env = {
    "SKYBRIDGE_SMOKE_ROLE": "ios-p2p-client",
    "SKYBRIDGE_SMOKE_EXPECT_FILE_TRANSFER": "1",
}
if os.environ.get("SKYBRIDGE_SMOKE_USER_REALISTIC") != "1":
    env["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] = "1"
for key in keys:
    value = os.environ.get(key)
    if value:
        env[key] = value

if env.get("SKYBRIDGE_SMOKE_USER_REALISTIC") == "1":
    for key in [
        "SKYBRIDGE_PQC_PEER_DEVICE_ID",
        "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64",
        "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64",
        "SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64",
    ]:
        env.pop(key, None)

print(json.dumps(env, ensure_ascii=False))
PY
)"

launch_ios_smoke_app

echo "==> Waiting for iOS smoke status"
wait_for_ios_status_pattern 'boot role=ios-p2p-client' "$IOS_LAUNCH_TIMEOUT_SECONDS" "iOS smoke boot status"

if [[ "$REQUIRE_SIGNED_KEM_REFRESH" == "1" ]]; then
  echo "==> Waiting for PIB-1/SKR-1 signed trust refresh evidence"
  wait_for_optional_protocol_identity_binding "$SMOKE_TIMEOUT_SECONDS"
  echo "==> Waiting for SKR-1 signed KEM refresh evidence"
  wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh request: .*lifecycle=missing-kem>request' "$SMOKE_TIMEOUT_SECONDS" "iOS SKR-1 request"
  wait_for_file_pattern "$HOST_STATUS" 'SKR-1 signed LAN KEM refresh served: .*lifecycle=request>served' "$SMOKE_TIMEOUT_SECONDS" "macOS SKR-1 served"
  wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh verified and imported: .*signature=verified .*requestHash=bound .*lifecycle=served>verified' "$SMOKE_TIMEOUT_SECONDS" "iOS SKR-1 verified import"
fi

echo "==> Waiting for macOS inbound transfer"
wait_for_file_pattern "$HOST_STATUS" 'file-transfer inbound-complete name=ios-smoke-'"$RUN_ID"'.txt' "$SMOKE_TIMEOUT_SECONDS" "macOS inbound transfer"

echo "==> Waiting for iOS inbound transfer"
wait_for_ios_status_pattern 'file-transfer inbound-complete name=mac-smoke-'"$RUN_ID"'.txt' "$SMOKE_TIMEOUT_SECONDS" "iOS inbound transfer"

if [[ "$REQUIRE_MAC_INITIATED_RECONNECT" == "1" ]]; then
  echo "==> Waiting for macOS-initiated reconnect transfer"
  wait_for_file_pattern "$HOST_STATUS" 'mac-reconnect outbound-complete name=mac-reconnect-smoke-'"$RUN_ID"'.txt' "$SMOKE_TIMEOUT_SECONDS" "macOS reconnect outbound transfer"
  wait_for_ios_status_pattern 'mac-reconnect inbound-complete name=mac-reconnect-smoke-'"$RUN_ID"'.txt' "$SMOKE_TIMEOUT_SECONDS" "iOS reconnect inbound transfer"
fi

if [[ "$REQUIRE_SIGNED_KEM_REFRESH" == "1" ]]; then
  echo "==> Waiting for SKR-1 signed KEM refresh smoke proof"
  wait_for_ios_status_pattern 'SKR-1 signed LAN KEM refresh smoke-evidence: .*source=signed_lan_kem_refresh .*signature=verified .*requestHash=bound .*strictXWingEstablished=1' "$SMOKE_TIMEOUT_SECONDS" "iOS SKR-1 smoke evidence"
fi

echo "==> Waiting for smoke success markers"
if [[ -z "$EXPECTED_TARGET_SUITE" ]]; then
  echo "Strict file-transfer smoke requires SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE to resolve to a concrete suite." >&2
  exit 2
fi
if [[ "$REQUIRE_MAC_INITIATED_RECONNECT" == "1" ]]; then
  wait_for_file_pattern "$HOST_STATUS" "success .*suite=${EXPECTED_TARGET_SUITE} .*fileTransfer=1 .*macInitiatedTransfer=1 .*macReconnectRoute=(control:[^[:space:]]+|bonjour-transfer)" "$SMOKE_TIMEOUT_SECONDS" "macOS file-transfer reconnect success"
  wait_for_ios_status_pattern "success .*suite=${EXPECTED_TARGET_SUITE} .*fileTransfer=1 .*macReconnect=1" "$SMOKE_TIMEOUT_SECONDS" "iOS file-transfer reconnect success"
else
  wait_for_file_pattern "$HOST_STATUS" "success .*suite=${EXPECTED_TARGET_SUITE} .*fileTransfer=1" "$SMOKE_TIMEOUT_SECONDS" "macOS file-transfer success"
  wait_for_ios_status_pattern "success .*suite=${EXPECTED_TARGET_SUITE} .*fileTransfer=1" "$SMOKE_TIMEOUT_SECONDS" "iOS file-transfer success"
fi

echo "==> Real-device bidirectional file transfer smoke succeeded"
echo "    mac status: $HOST_STATUS"
echo "    ios status: $IOS_STATUS_LOCAL"
echo "    host stdout: $HOST_STDOUT"
echo "    host stderr: $HOST_STDERR"
