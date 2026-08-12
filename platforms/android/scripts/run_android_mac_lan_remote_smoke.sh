#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/repository_layout.sh"
RELEASE_REPO_ROOT="$(skybridge_canonical_release_root "$ROOT_DIR")"
# shellcheck source=scripts/lib/android_env.sh
source "$ROOT_DIR/scripts/lib/android_env.sh"
# shellcheck source=scripts/lib/keychain_smoke.sh
source "$ROOT_DIR/scripts/lib/keychain_smoke.sh"
DEFAULT_MAC_PACKAGE_PATH="$RELEASE_REPO_ROOT"
DEFAULT_ACTIVITY="com.skybridge.compass.debug/com.skybridge.compass.android.debug.DebugLanInteropSmokeActivity"
STATUS_VALIDATOR="$ROOT_DIR/scripts/validate_android_mac_lan_status.py"

DEVICE_SERIAL=""
MAC_PACKAGE_PATH="$DEFAULT_MAC_PACKAGE_PATH"
EXPECTED_SERVICE_NAME=""
EXPECTED_DEVICE_ID=""
EXPECTED_FINGERPRINT=""
EXPECTED_DEVICE_ID_SUPPLIED="false"
EXPECTED_FINGERPRINT_SUPPLIED="false"
DIRECT_HOST=""
DIRECT_PORT="5901"
TIMEOUT_SECONDS="120"
REQUIRE_SECURE="true"
ALLOW_PLAINTEXT_FALLBACK="false"
ALLOW_TOFU="false"
START_MAC_HOST="true"
ENABLE_PREPAIRING="${SKYBRIDGE_ANDROID_MAC_LAN_PREPAIR:-false}"
ALLOW_DIAGNOSTIC_TRUST_INJECTION="${SKYBRIDGE_ANDROID_MAC_LAN_DIAGNOSTIC_TRUST_INJECTION:-false}"
NORMAL_PRODUCT_PAIRING_WRITE_AUTHORIZED="${SKYBRIDGE_ANDROID_MAC_LAN_NORMAL_PRODUCT_PAIRING_WRITE_AUTHORIZED:-false}"
RUN_DIR=""
KEYCHAIN_READ_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_KEYCHAIN_TIMEOUT_SECONDS:-${SKYBRIDGE_KEYCHAIN_READ_TIMEOUT_SECONDS:-15}}"
MAC_HOST_READY_TIMEOUT_SECONDS="${SKYBRIDGE_ANDROID_MAC_LAN_HOST_READY_TIMEOUT_SECONDS:-600}"
SMOKE_REMOTE_NOTICE_ACCOUNT_DISPLAY_NAME="${SKYBRIDGE_ANDROID_MAC_LAN_REMOTE_NOTICE_ACCOUNT_DISPLAY_NAME:-SkyBridge Android LAN Smoke}"
SMOKE_REMOTE_NOTICE_NEBULA_ID="${SKYBRIDGE_ANDROID_MAC_LAN_REMOTE_NOTICE_NEBULA_ID:-NEBULA-2026-ABCDEF123456}"
MAC_HOST_AUTO_APPROVE_PAIRING="0"
MAC_HOST_REMOTE_CONTROL_NOTICE_AUTO_APPROVE="${SKYBRIDGE_ANDROID_MAC_LAN_REMOTE_NOTICE_AUTO_APPROVE:-0}"

remote_shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

remote_shell_join() {
  local joined=""
  local arg
  for arg in "$@"; do
    if [[ -n "$joined" ]]; then
      joined+=" "
    fi
    joined+="$(remote_shell_quote "$arg")"
  done
  printf '%s' "$joined"
}

usage() {
  cat <<'EOF'
Usage:
  scripts/run_android_mac_lan_remote_smoke.sh \
    --device <adb-serial> \
    [--mac-package-path <path>] \
    [--expected-service-name <name>] \
    [--expected-device-id <device-id>] \
    [--expected-fingerprint <pubkey-fingerprint>] \
    [--host <ip-or-hostname>] \
    [--port <tcp-port>] \
    [--timeout-seconds <n>] \
    [--require-secure true|false] \
    [--allow-plaintext-fallback true|false] \
    [--allow-tofu true|false] \
    [--start-mac-host true|false] \
    [--prepair true|false] \
    [--diagnostic-trust-injection true|false] \
    [--normal-product-pairing-write-authorized true|false] \
    [--run-dir <path>]

The DebugLanInteropSmokeActivity and its scripted path consume existing trust read-only.
The separate normal-product PIB-1/SAS flow may persist peer trust after manual approval.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      DEVICE_SERIAL="${2:-}"
      shift 2
      ;;
    --mac-package-path)
      MAC_PACKAGE_PATH="${2:-}"
      shift 2
      ;;
    --expected-service-name)
      EXPECTED_SERVICE_NAME="${2:-}"
      shift 2
      ;;
    --expected-device-id)
      EXPECTED_DEVICE_ID="${2:-}"
      EXPECTED_DEVICE_ID_SUPPLIED="true"
      shift 2
      ;;
    --expected-fingerprint)
      EXPECTED_FINGERPRINT="${2:-}"
      EXPECTED_FINGERPRINT_SUPPLIED="true"
      shift 2
      ;;
    --host)
      DIRECT_HOST="${2:-}"
      shift 2
      ;;
    --port)
      DIRECT_PORT="${2:-}"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --require-secure)
      REQUIRE_SECURE="${2:-}"
      shift 2
      ;;
    --allow-plaintext-fallback)
      ALLOW_PLAINTEXT_FALLBACK="${2:-}"
      shift 2
      ;;
    --allow-tofu)
      ALLOW_TOFU="${2:-}"
      shift 2
      ;;
    --start-mac-host)
      START_MAC_HOST="${2:-}"
      shift 2
      ;;
    --prepair)
      ENABLE_PREPAIRING="${2:-}"
      shift 2
      ;;
    --diagnostic-trust-injection)
      ALLOW_DIAGNOSTIC_TRUST_INJECTION="${2:-}"
      shift 2
      ;;
    --normal-product-pairing-write-authorized)
      NORMAL_PRODUCT_PAIRING_WRITE_AUTHORIZED="${2:-}"
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

if [[ -z "$DEVICE_SERIAL" ]]; then
  usage >&2
  exit 1
fi

case "$REQUIRE_SECURE" in
  true|false) ;;
  *)
    echo "Unsupported --require-secure value: $REQUIRE_SECURE (expected true|false)" >&2
    exit 1
    ;;
esac

case "$ALLOW_PLAINTEXT_FALLBACK" in
  true|false) ;;
  *)
    echo "Unsupported --allow-plaintext-fallback value: $ALLOW_PLAINTEXT_FALLBACK (expected true|false)" >&2
    exit 1
    ;;
esac

case "$ALLOW_TOFU" in
  true|false) ;;
  *)
    echo "Unsupported --allow-tofu value: $ALLOW_TOFU (expected true|false)" >&2
    exit 1
    ;;
esac

case "$START_MAC_HOST" in
  true|false) ;;
  *)
    echo "Unsupported --start-mac-host value: $START_MAC_HOST (expected true|false)" >&2
    exit 1
    ;;
esac

case "$ENABLE_PREPAIRING" in
  true|false) ;;
  *)
    echo "Unsupported --prepair value: $ENABLE_PREPAIRING (expected true|false)" >&2
    exit 1
    ;;
esac

case "$ALLOW_DIAGNOSTIC_TRUST_INJECTION" in
  true|false) ;;
  *)
    echo "Unsupported --diagnostic-trust-injection value: $ALLOW_DIAGNOSTIC_TRUST_INJECTION (expected true|false)" >&2
    exit 1
    ;;
esac

case "$NORMAL_PRODUCT_PAIRING_WRITE_AUTHORIZED" in
  true|false) ;;
  *)
    echo "Unsupported --normal-product-pairing-write-authorized value: $NORMAL_PRODUCT_PAIRING_WRITE_AUTHORIZED (expected true|false)" >&2
    exit 1
    ;;
esac

case "$MAC_HOST_REMOTE_CONTROL_NOTICE_AUTO_APPROVE" in
  0|1) ;;
  *)
    echo "SKYBRIDGE_ANDROID_MAC_LAN_REMOTE_NOTICE_AUTO_APPROVE must be 0 or 1" >&2
    exit 1
    ;;
esac

if [[ ! "$MAC_HOST_READY_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] \
  || (( MAC_HOST_READY_TIMEOUT_SECONDS < 30 || MAC_HOST_READY_TIMEOUT_SECONDS > 1800 )); then
  echo "SKYBRIDGE_ANDROID_MAC_LAN_HOST_READY_TIMEOUT_SECONDS must be an integer from 30 through 1800" >&2
  exit 1
fi

if [[ "$ENABLE_PREPAIRING" == "true" ]]; then
  echo "--prepair true is no longer supported; use the product PIB flow and confirm its SAS manually" >&2
  exit 1
fi

if [[ "$ALLOW_TOFU" == "true" && "$ALLOW_DIAGNOSTIC_TRUST_INJECTION" != "true" ]]; then
  echo "--allow-tofu true requires --diagnostic-trust-injection true so the pin stays ephemeral" >&2
  exit 1
fi

if [[ "$START_MAC_HOST" == "true" ]]; then
  if [[ "$REQUIRE_SECURE" != "true" || "$ALLOW_PLAINTEXT_FALLBACK" != "false" ]]; then
    echo "The signed current-source macOS host requires secure transport with plaintext fallback disabled" >&2
    exit 1
  fi
  if [[ "$ALLOW_TOFU" != "false" || "$ALLOW_DIAGNOSTIC_TRUST_INJECTION" != "false" ]]; then
    echo "The signed current-source macOS host forbids TOFU and diagnostic trust injection" >&2
    exit 1
  fi
  if [[ "$MAC_HOST_AUTO_APPROVE_PAIRING" != "0" || "$MAC_HOST_REMOTE_CONTROL_NOTICE_AUTO_APPROVE" != "0" ]]; then
    echo "The signed current-source macOS host requires manual pairing and remote-control approval" >&2
    exit 1
  fi
  if [[ "$NORMAL_PRODUCT_PAIRING_WRITE_AUTHORIZED" != "true" ]]; then
    echo "The signed current-source macOS host requires explicit authorization for normal product pairing trust writes" >&2
    exit 1
  fi
  if [[ "${SKYBRIDGE_KEYCHAIN_IN_MEMORY:-0}" != "0" ]]; then
    echo "The signed current-source macOS host requires the persistent system Keychain view" >&2
    exit 1
  fi
fi

ADB_BIN="$(resolve_adb_bin "$ROOT_DIR" || true)"
if [[ -z "$ADB_BIN" ]]; then
  echo "adb not found; checked PATH, local.properties, and common Android SDK locations" >&2
  exit 1
fi

ANDROID_DEVICE_RELEASE="$(android_device_prop "$ADB_BIN" "$DEVICE_SERIAL" ro.build.version.release)"
ANDROID_DEVICE_SDK="$(android_device_prop "$ADB_BIN" "$DEVICE_SERIAL" ro.build.version.sdk)"
require_android16_device "$ANDROID_DEVICE_RELEASE" "$ANDROID_DEVICE_SDK"

MAC_PACKAGE_PATH="$(skybridge_require_release_repo_root "$MAC_PACKAGE_PATH")"

MAC_HOST_RUNNER="$MAC_PACKAGE_PATH/Scripts/run_real_device_p2p_remote_smoke.sh"
if [[ "$START_MAC_HOST" == "true" \
  && ( ! -f "$MAC_HOST_RUNNER" || -L "$MAC_HOST_RUNNER" ) ]]; then
  echo "signed current-source macOS host runner is missing or unsafe: $MAC_HOST_RUNNER" >&2
  exit 1
fi

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$ROOT_DIR/build/interop/android-mac-lan-smoke/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$RUN_DIR"
chmod 0700 "$RUN_DIR"

ENV_FILE="$RUN_DIR/environment.txt"
COMMAND_FILE="$RUN_DIR/command.txt"
INSTALL_LOG="$RUN_DIR/android-install.log"
ANDROID_LOGCAT_LOG="$RUN_DIR/android-logcat.txt"
STATUS_LOG="$RUN_DIR/android-status.log"
SUMMARY_FILE="$RUN_DIR/summary.txt"
PUBLIC_ARTIFACT_DIR="$RUN_DIR/public-redacted"
HOST_LOG="$RUN_DIR/mac-host.log"
MAC_HOST_ARTIFACT_DIR="$RUN_DIR/mac-host-artifacts"
MAC_HOST_READY_FILE="$MAC_HOST_ARTIFACT_DIR/mac-host-ready.json"
HOST_BUILD_LOG="$MAC_HOST_ARTIFACT_DIR/macos-build.log"
HOST_STATUS="$RUN_DIR/mac-host.status.log"
HOST_PQC_REPORT="$RUN_DIR/mac-host.pqc.json"
SMOKE_NONCE_FILE_NAME="debug-lan-interop-smoke-nonce"
SMOKE_STATUS_FILE_NAME=""
SMOKE_RUN_REF=""
REMOTE_SMOKE_SCOPE_PREPARED="false"
HOST_RUNNER_PID=""
HOST_PROCESS_PID=""
HOST_RUNNER_SHUTDOWN_REQUESTED="false"
HOST_PERSISTENT_IDENTITY_MUTATION_DENIED="false"
MAC_HOST_MODE="$(if [[ "$START_MAC_HOST" == "true" ]]; then echo current-source-signed-packaged-host; else echo external; fi)"
ANDROID_LOGCAT_START=""
DETECTED_CONTROL_PORT=""
if [[ "$MAC_HOST_REMOTE_CONTROL_NOTICE_AUTO_APPROVE" == "1" && "$ALLOW_DIAGNOSTIC_TRUST_INJECTION" != "true" ]]; then
  echo "automatic remote-control approval is diagnostic-only and requires --diagnostic-trust-injection true" >&2
  exit 1
fi
if [[ ! -f "$STATUS_VALIDATOR" || -L "$STATUS_VALIDATOR" ]]; then
  echo "Android LAN status validator is missing or unsafe: $STATUS_VALIDATOR" >&2
  exit 1
fi

ACCEPTANCE_ELIGIBLE="true"
if [[ "$ALLOW_DIAGNOSTIC_TRUST_INJECTION" == "true" ||
      "$ALLOW_TOFU" == "true" ||
      "$ALLOW_PLAINTEXT_FALLBACK" == "true" ||
      "$REQUIRE_SECURE" != "true" ||
      "$START_MAC_HOST" == "true" ]]; then
  ACCEPTANCE_ELIGIBLE="false"
fi

read_optional_keychain_password() {
  local service="$1"
  local account="$2"
  local err_basename="$3"
  read_keychain_generic_password \
    "$service" \
    "$account" \
    "$RUN_DIR/$err_basename" \
    "$KEYCHAIN_READ_TIMEOUT_SECONDS"
}

IDENTITY_SOURCE="manual"
AUTO_DISCOVER_EXPECTED_IDENTITY="false"
IDENTITY_VERIFIED="false"
REQUIRE_EXISTING_PRODUCT_TRUST="false"
if [[ "$REQUIRE_SECURE" == "true" &&
      "$ALLOW_TOFU" == "false" &&
      "$ALLOW_DIAGNOSTIC_TRUST_INJECTION" == "false" ]]; then
  REQUIRE_EXISTING_PRODUCT_TRUST="true"
  IDENTITY_SOURCE="android_authenticated_product_v1_pending"
fi

if [[ "$REQUIRE_EXISTING_PRODUCT_TRUST" == "true" &&
      "$START_MAC_HOST" == "false" &&
      -z "$EXPECTED_DEVICE_ID" ]]; then
  {
    echo "android_status_ok=false"
    echo "failure_stage=android_product_trust_preflight"
    echo "failure_reason=lookup_candidate_missing"
    echo "identity_source=$IDENTITY_SOURCE"
    echo "expected_device_id_present=$(if [[ -n "$EXPECTED_DEVICE_ID" ]]; then echo true; else echo false; fi)"
    echo "expected_fingerprint_present=$(if [[ -n "$EXPECTED_FINGERPRINT" ]]; then echo true; else echo false; fi)"
  } >"$SUMMARY_FILE"
  echo "Secure external-host LAN smoke requires an explicit device id lookup candidate for existing Android product trust" >&2
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi

if [[ "$REQUIRE_EXISTING_PRODUCT_TRUST" == "false" &&
      "$REQUIRE_SECURE" == "true" &&
      "$ALLOW_TOFU" == "false" &&
      ( -z "$EXPECTED_DEVICE_ID" || -z "$EXPECTED_FINGERPRINT" ) ]]; then
  echo "Secure diagnostic LAN smoke requires explicit device id and fingerprint when existing product trust is not required" >&2
  exit 1
fi

PEER_MLKEM_PUBLIC_B64=""
PEER_XWING_PUBLIC_B64=""
PEER_MLKEM_ACCOUNT=""
PEER_XWING_ACCOUNT=""
AUTO_DISCOVER_PERSISTENT_KEM="false"
if [[ "$ALLOW_DIAGNOSTIC_TRUST_INJECTION" == "true" &&
      ( "$EXPECTED_DEVICE_ID_SUPPLIED" == "true" || "$EXPECTED_FINGERPRINT_SUPPLIED" == "true" ) ]]; then
  AUTO_DISCOVER_PERSISTENT_KEM="true"
fi

extract_kem_public_key_b64() {
  local result_var="$1"
  local account_var="$2"
  shift 2

  local candidate=""
  local account=""
  local raw_json=""
  local public_key_b64=""

  for candidate in "$@"; do
    raw_json="$(read_optional_keychain_password \
      'com.skybridge.p2p.identity.kem' \
      "$candidate" \
      "mac-kem-${candidate}.keychain.err" \
      | tr -d '\r\n' || true)"
    if [[ -z "$raw_json" ]]; then
      continue
    fi
    public_key_b64="$(python3 - "$raw_json" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(payload.get("publicKey", ""))
PY
)"
    if [[ -n "$public_key_b64" ]]; then
      account="$candidate"
      break
    fi
  done

  printf -v "$result_var" '%s' "$public_key_b64"
  printf -v "$account_var" '%s' "$account"
}

if [[ "$AUTO_DISCOVER_PERSISTENT_KEM" == "true" ]]; then
  extract_kem_public_key_b64 \
    PEER_MLKEM_PUBLIC_B64 \
    PEER_MLKEM_ACCOUNT \
    'kem_key_257-liboqsPQC' \
    'kem_key_257-nativePQC' \
    'kem_key_257'
  extract_kem_public_key_b64 \
    PEER_XWING_PUBLIC_B64 \
    PEER_XWING_ACCOUNT \
    'kem_key_1-nativePQC' \
    'kem_key_1'
fi

stop_signed_mac_host_runner() {
  local runner_status=0

  [[ -n "$HOST_RUNNER_PID" ]] || return 0
  if kill -0 "$HOST_RUNNER_PID" >/dev/null 2>&1; then
    HOST_RUNNER_SHUTDOWN_REQUESTED="true"
    if ! kill -TERM "$HOST_RUNNER_PID" >/dev/null 2>&1; then
      echo "failed stage=cleanup phase=mac-host-runner reason=term-signal-failed" >&2
      return 1
    fi
  fi

  set +e
  wait "$HOST_RUNNER_PID"
  runner_status=$?
  set -e
  HOST_RUNNER_PID=""

  if [[ "$HOST_RUNNER_SHUTDOWN_REQUESTED" != "true" ]]; then
    echo "failed stage=cleanup phase=mac-host-runner reason=runner-exited-before-owned-shutdown status=$runner_status" >&2
    return 1
  fi
  case "$runner_status" in
    0|143) return 0 ;;
    *)
      echo "failed stage=cleanup phase=mac-host-runner reason=exact-apple-cleanup-failed status=$runner_status" >&2
      return 1
      ;;
  esac
}

remove_remote_smoke_scope() {
  [[ "$REMOTE_SMOKE_SCOPE_PREPARED" == "true" ]] || return 0
  if [[ ! "$SMOKE_STATUS_FILE_NAME" =~ ^debug-lan-interop-smoke-status-[0-9a-f]{64}\.log$ ]]; then
    echo "failed stage=cleanup phase=android-smoke-scope reason=invalid-status-name" >&2
    return 1
  fi
  local remote_command
  remote_command="rm -f files/$SMOKE_NONCE_FILE_NAME files/$SMOKE_STATUS_FILE_NAME && test ! -e files/$SMOKE_NONCE_FILE_NAME && test ! -e files/$SMOKE_STATUS_FILE_NAME"
  if ! "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "run-as com.skybridge.compass.debug sh -c $(remote_shell_quote "$remote_command")" \
    >/dev/null 2>&1; then
    echo "failed stage=cleanup phase=android-smoke-scope reason=exact-delete-or-absence-check-failed" >&2
    return 1
  fi
  REMOTE_SMOKE_SCOPE_PREPARED="false"
}

copy_remote_smoke_status() {
  if [[ ! "$SMOKE_STATUS_FILE_NAME" =~ ^debug-lan-interop-smoke-status-[0-9a-f]{64}\.log$ ]]; then
    echo "Android smoke status filename is invalid" >&2
    return 1
  fi
  local temporary_status="$RUN_DIR/.android-status.pending"
  local status_error="$RUN_DIR/.android-status.error"
  local remote_command
  local copy_status
  remote_command="if test -f files/$SMOKE_STATUS_FILE_NAME; then cat files/$SMOKE_STATUS_FILE_NAME; elif test -e files/$SMOKE_STATUS_FILE_NAME; then exit 42; else exit 44; fi"
  /bin/rm -f -- "$temporary_status" "$status_error"
  set +e
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "run-as com.skybridge.compass.debug sh -c $(remote_shell_quote "$remote_command")" \
    >"$temporary_status" 2>"$status_error"
  copy_status=$?
  set -e
  case "$copy_status" in
    0)
      /bin/mv -f -- "$temporary_status" "$STATUS_LOG"
      /bin/chmod 0600 "$STATUS_LOG"
      /bin/rm -f -- "$status_error"
      return 0
      ;;
    44)
      /bin/rm -f -- "$temporary_status" "$status_error" "$STATUS_LOG"
      return 2
      ;;
    *)
      echo "Android run-scoped status read failed with status $copy_status" >&2
      if [[ -s "$status_error" ]]; then
        /usr/bin/sed -n '1,4p' "$status_error" >&2
      fi
      /bin/rm -f -- "$temporary_status" "$status_error"
      return 1
      ;;
  esac
}

inspect_android_smoke_status() {
  local allow_incomplete_tail="${1:-false}"
  /usr/bin/python3 "$STATUS_VALIDATOR" \
    "$STATUS_LOG" \
    "$SMOKE_RUN_REF" \
    "$REQUIRE_SECURE" \
    "$ALLOW_PLAINTEXT_FALLBACK" \
    "$REQUIRE_EXISTING_PRODUCT_TRUST" \
    "$allow_incomplete_tail"
}

cleanup() {
  local original_status=$?
  local cleanup_status=0
  trap - EXIT INT TERM

  if [[ "$REMOTE_SMOKE_SCOPE_PREPARED" == "true" ]] \
    && ! "$ADB_BIN" -s "$DEVICE_SERIAL" shell am force-stop com.skybridge.compass.debug \
      >/dev/null 2>&1; then
    echo "failed stage=cleanup phase=android-debug-activity reason=force-stop-failed" >&2
    cleanup_status=1
  fi
  if ! remove_remote_smoke_scope; then
    cleanup_status=1
  fi
  if ! stop_signed_mac_host_runner; then
    cleanup_status=1
  fi

  if (( cleanup_status != 0 )); then
    exit "$cleanup_status"
  fi
  exit "$original_status"
}

exit_on_signal() {
  local signal_status="$1"
  trap - INT TERM
  exit "$signal_status"
}

trap cleanup EXIT
trap 'exit_on_signal 130' INT
trap 'exit_on_signal 143' TERM

write_failure_summary() {
  local failure_stage="$1"
  local failure_reason="$2"
  {
    echo "android_status_ok=false"
    echo "failure_stage=$failure_stage"
    echo "failure_reason=$failure_reason"
    echo "connection_mode=$(if [[ -n "$DIRECT_HOST" ]]; then echo direct; else echo discovery; fi)"
    echo "require_secure=$REQUIRE_SECURE"
    echo "allow_plaintext_fallback=$ALLOW_PLAINTEXT_FALLBACK"
    echo "allow_tofu=$ALLOW_TOFU"
    echo "prepair=$ENABLE_PREPAIRING"
    echo "diagnostic_trust_injection=$ALLOW_DIAGNOSTIC_TRUST_INJECTION"
    echo "acceptance_eligible=$ACCEPTANCE_ELIGIBLE"
    echo "diagnosticOnly=$(if [[ "$START_MAC_HOST" == "true" ]]; then echo 1; else echo 0; fi)"
    echo "currentSourceHelper=$(if [[ "$START_MAC_HOST" == "true" ]]; then echo 1; else echo 0; fi)"
    echo "hostPersistentIdentityMutationDenied=$(if [[ "$HOST_PERSISTENT_IDENTITY_MUTATION_DENIED" == "true" ]]; then echo 1; else echo 0; fi)"
    echo "forcedPersistentTrustMutationAllowed=0"
    echo "normalProductPairingWriteAuthorized=$(if [[ "$NORMAL_PRODUCT_PAIRING_WRITE_AUTHORIZED" == "true" ]]; then echo 1; else echo 0; fi)"
    echo "mac_host_mode=$MAC_HOST_MODE"
    echo "mac_host_auto_approve_pairing=$MAC_HOST_AUTO_APPROVE_PAIRING"
    echo "mac_host_remote_control_notice_auto_approve=$MAC_HOST_REMOTE_CONTROL_NOTICE_AUTO_APPROVE"
    echo "identity_verified=$IDENTITY_VERIFIED"
    echo "identity_source=$IDENTITY_SOURCE"
    echo "require_existing_product_trust=$REQUIRE_EXISTING_PRODUCT_TRUST"
    echo "keychain_read_timeout_seconds=$KEYCHAIN_READ_TIMEOUT_SECONDS"
    echo "command=$COMMAND_FILE"
    echo "environment=$ENV_FILE"
    echo "android_status=$STATUS_LOG"
    echo "android_status_outcome=${ANDROID_STATUS_OUTCOME:-unavailable}"
    echo "smoke_run_ref=${SMOKE_RUN_REF:-unavailable}"
    echo "android_logcat=$ANDROID_LOGCAT_LOG"
    echo "mac_host_build_log=$HOST_BUILD_LOG"
    echo "mac_host_log=$HOST_LOG"
    echo "mac_host_status=$HOST_STATUS"
    echo "mac_host_pqc_report=$HOST_PQC_REPORT"
    if [[ -n "$HOST_RUNNER_PID" ]]; then
      echo "mac_host_runner_pid=$HOST_RUNNER_PID"
    fi
    if [[ -n "$HOST_PROCESS_PID" ]]; then
      echo "mac_host_pid=$HOST_PROCESS_PID"
    fi
    if [[ -s "$HOST_STATUS" ]]; then
      echo "mac_host_ready=$(grep -m 1 'ready discovery=_skybridge._tcp' "$HOST_STATUS" || true)"
      echo "mac_remote_port=${DETECTED_REMOTE_PORT:-missing}"
    fi
    if [[ -s "$STATUS_LOG" ]]; then
      echo "android_failure_line=$(grep -m 1 'failure reason=' "$STATUS_LOG" || true)"
      echo "android_success_line=$(grep -m 1 'success reason=' "$STATUS_LOG" || true)"
    fi
  } >"$SUMMARY_FILE"
}

cat >"$COMMAND_FILE" <<EOF
script=scripts/run_android_mac_lan_remote_smoke.sh
device=$DEVICE_SERIAL
mac_package_path=$MAC_PACKAGE_PATH
expected_service_name=$EXPECTED_SERVICE_NAME
expected_device_id=$(if [[ -n "$EXPECTED_DEVICE_ID" ]]; then echo "<redacted:length=${#EXPECTED_DEVICE_ID}>"; else echo ""; fi)
expected_fingerprint=$(if [[ -n "$EXPECTED_FINGERPRINT" ]]; then echo "<redacted:length=${#EXPECTED_FINGERPRINT}>"; else echo ""; fi)
expected_device_id_supplied=$EXPECTED_DEVICE_ID_SUPPLIED
expected_fingerprint_supplied=$EXPECTED_FINGERPRINT_SUPPLIED
auto_discover_expected_identity=$AUTO_DISCOVER_EXPECTED_IDENTITY
auto_discover_persistent_kem=$AUTO_DISCOVER_PERSISTENT_KEM
identity_source=$IDENTITY_SOURCE
require_existing_product_trust=$REQUIRE_EXISTING_PRODUCT_TRUST
mac_host_keychain_in_memory=${SKYBRIDGE_KEYCHAIN_IN_MEMORY:-0}
mac_host_mode=$MAC_HOST_MODE
mac_host_build_log=$HOST_BUILD_LOG
peer_mlkem_public_b64_length=${#PEER_MLKEM_PUBLIC_B64}
peer_xwing_public_b64_length=${#PEER_XWING_PUBLIC_B64}
peer_mlkem_account=${PEER_MLKEM_ACCOUNT:-missing}
peer_xwing_account=${PEER_XWING_ACCOUNT:-missing}
direct_host=$DIRECT_HOST
direct_port=$DIRECT_PORT
timeout_seconds=$TIMEOUT_SECONDS
keychain_read_timeout_seconds=$KEYCHAIN_READ_TIMEOUT_SECONDS
require_secure=$REQUIRE_SECURE
allow_plaintext_fallback=$ALLOW_PLAINTEXT_FALLBACK
allow_tofu=$ALLOW_TOFU
prepair=$ENABLE_PREPAIRING
diagnostic_trust_injection=$ALLOW_DIAGNOSTIC_TRUST_INJECTION
acceptance_eligible=$ACCEPTANCE_ELIGIBLE
diagnosticOnly=$(if [[ "$START_MAC_HOST" == "true" ]]; then echo 1; else echo 0; fi)
currentSourceHelper=$(if [[ "$START_MAC_HOST" == "true" ]]; then echo 1; else echo 0; fi)
forcedPersistentTrustMutationAllowed=0
normalProductPairingWriteAuthorized=$(if [[ "$NORMAL_PRODUCT_PAIRING_WRITE_AUTHORIZED" == "true" ]]; then echo 1; else echo 0; fi)
mac_host_auto_approve_pairing=$MAC_HOST_AUTO_APPROVE_PAIRING
mac_host_remote_control_notice_auto_approve=$MAC_HOST_REMOTE_CONTROL_NOTICE_AUTO_APPROVE
identity_verified=$IDENTITY_VERIFIED
start_mac_host=$START_MAC_HOST
run_dir=$RUN_DIR
EOF

{
  echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "adb=$("$ADB_BIN" version 2>/dev/null | head -n 1)"
  echo "device_model=$(android_device_prop "$ADB_BIN" "$DEVICE_SERIAL" ro.product.model)"
  echo "device_release=$ANDROID_DEVICE_RELEASE"
  echo "device_sdk=$ANDROID_DEVICE_SDK"
  echo "keychain_read_timeout_seconds=$KEYCHAIN_READ_TIMEOUT_SECONDS"
  echo "mac_host_keychain_in_memory=${SKYBRIDGE_KEYCHAIN_IN_MEMORY:-0}"
  echo "prepair=$ENABLE_PREPAIRING"
  echo "diagnostic_trust_injection=$ALLOW_DIAGNOSTIC_TRUST_INJECTION"
  echo "acceptance_eligible=$ACCEPTANCE_ELIGIBLE"
  echo "diagnosticOnly=$(if [[ "$START_MAC_HOST" == "true" ]]; then echo 1; else echo 0; fi)"
  echo "currentSourceHelper=$(if [[ "$START_MAC_HOST" == "true" ]]; then echo 1; else echo 0; fi)"
  echo "hostPersistentIdentityMutationDenied=$(if [[ "$HOST_PERSISTENT_IDENTITY_MUTATION_DENIED" == "true" ]]; then echo 1; else echo 0; fi)"
  echo "forcedPersistentTrustMutationAllowed=0"
  echo "normalProductPairingWriteAuthorized=$(if [[ "$NORMAL_PRODUCT_PAIRING_WRITE_AUTHORIZED" == "true" ]]; then echo 1; else echo 0; fi)"
  echo "mac_host_mode=$MAC_HOST_MODE"
  echo "mac_host_auto_approve_pairing=$MAC_HOST_AUTO_APPROVE_PAIRING"
  echo "mac_host_remote_control_notice_auto_approve=$MAC_HOST_REMOTE_CONTROL_NOTICE_AUTO_APPROVE"
  if [[ "$START_MAC_HOST" == "true" ]]; then
    echo "mac_host_runner=$MAC_HOST_RUNNER"
  fi
} >"$ENV_FILE"
skybridge_append_git_source_binding "$ENV_FILE" android "$RELEASE_REPO_ROOT"
skybridge_append_git_source_binding "$ENV_FILE" apple "$MAC_PACKAGE_PATH"

validate_mac_host_ready_file() {
  python3 - \
    "$MAC_HOST_READY_FILE" \
    "$MAC_HOST_ARTIFACT_DIR" \
    "$HOST_RUNNER_PID" <<'PY'
import json
import os
import pathlib
import stat
import sys

ready_path = pathlib.Path(sys.argv[1])
expected_artifact = pathlib.Path(sys.argv[2]).resolve()
expected_runner_pid = int(sys.argv[3])
metadata = os.lstat(ready_path)
if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600:
    raise SystemExit("macOS host readiness is not a private regular 0600 file")
if metadata.st_size < 2 or metadata.st_size > 64 * 1024:
    raise SystemExit("macOS host readiness size is outside the bounded contract")
with ready_path.open("r", encoding="utf-8") as handle:
    payload = json.load(handle)

expected_values = {
    "acceptanceEligible": False,
    "autoApprovePairing": False,
    "diagnosticOnly": True,
    "forcedPersistentTrustMutationAllowed": False,
    "hostPersistentIdentityMutationDenied": True,
    "identityAccessPolicy": "existing-only",
    "keychainMode": "system",
    "launchMode": "packaged-lab",
    "mode": "current-source-signed-packaged-host",
    "remoteControlNoticeAutoApprove": False,
    "schemaVersion": 1,
}
for key, expected in expected_values.items():
    if payload.get(key) != expected:
        raise SystemExit(f"macOS host readiness field {key} is not bound to the strict signed diagnostic profile")
if "persistentTrustMutationAllowed" in payload:
    raise SystemExit("macOS host readiness uses an overbroad peer-trust mutation claim")
if pathlib.Path(payload.get("artifactDirectory", "")).resolve() != expected_artifact:
    raise SystemExit("macOS host readiness is bound to a different artifact directory")
if payload.get("runnerPID") != expected_runner_pid:
    raise SystemExit("macOS host readiness is bound to a different runner process")

def bounded_integer(key: str, maximum: int) -> int:
    value = payload.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= maximum:
        raise SystemExit(f"macOS host readiness field {key} is outside its bounded range")
    return value

def digest(key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
        raise SystemExit(f"macOS host readiness field {key} is not a SHA-256 digest")
    return value

def private_file(key: str, maximum_size: int) -> str:
    raw = payload.get(key)
    if not isinstance(raw, str) or not raw or "\n" in raw or "\r" in raw:
        raise SystemExit(f"macOS host readiness field {key} is not a safe path")
    path = pathlib.Path(raw)
    file_metadata = os.lstat(path)
    if not stat.S_ISREG(file_metadata.st_mode) or file_metadata.st_mode & 0o077:
        raise SystemExit(f"macOS host readiness field {key} is not a private regular file")
    if file_metadata.st_size < 1 or file_metadata.st_size > maximum_size:
        raise SystemExit(f"macOS host readiness field {key} has an invalid size")
    return raw

host_pid = bounded_integer("hostPID", 2**31 - 1)
remote_port = bounded_integer("remotePort", 65535)
control_port = bounded_integer("controlPort", 65535)
status_file = private_file("statusFile", 4 * 1024 * 1024)
pqc_file = private_file("pqcReportFile", 1024 * 1024)
source_digest = digest("sourceInputDigest")
executable_digest = digest("hostExecutableSHA256")

with open(status_file, "r", encoding="utf-8", errors="replace") as handle:
    status = handle.read()
marker = "identity-policy mode=existing-only mutation=denied source=explicit-smoke-environment"
if marker not in status or "ready discovery=_skybridge._tcp" not in status:
    raise SystemExit("macOS host readiness preceded the existing-only policy or listener marker")

for value in (
    host_pid,
    remote_port,
    control_port,
    status_file,
    pqc_file,
    source_digest,
    executable_digest,
):
    print(value)
PY
}

copy_private_host_evidence() {
  local source_path="$1"
  local destination_path="$2"

  if [[ ! -f "$source_path" || -L "$source_path" ]]; then
    echo "Refusing to copy missing or unsafe macOS host evidence: $source_path" >&2
    return 1
  fi
  if [[ -e "$destination_path" && ( ! -f "$destination_path" || -L "$destination_path" ) ]]; then
    echo "Refusing to overwrite unsafe macOS host evidence: $destination_path" >&2
    return 1
  fi
  cp -f -- "$source_path" "$destination_path"
  chmod 0600 "$destination_path"
}

refresh_signed_mac_host_evidence() {
  [[ "$START_MAC_HOST" == "true" ]] || return 0
  if [[ -z "$HOST_RUNNER_PID" || -z "$HOST_PROCESS_PID" ]] \
    || ! kill -0 "$HOST_RUNNER_PID" >/dev/null 2>&1 \
    || ! kill -0 "$HOST_PROCESS_PID" >/dev/null 2>&1; then
    echo "signed current-source macOS host ownership was lost before evidence refresh" >&2
    return 1
  fi
  copy_private_host_evidence "$HOST_STATUS_SOURCE" "$HOST_STATUS"
  copy_private_host_evidence "$HOST_PQC_REPORT_SOURCE" "$HOST_PQC_REPORT"
}

if [[ "$START_MAC_HOST" == "true" ]]; then
  MAC_HOST_RUN_ID="android-mac-lan-$(date +%Y%m%d%H%M%S)-$$"
  echo "Starting signed current-source macOS LAN host (diagnostic-only)..."
  SKYBRIDGE_SMOKE_ARTIFACT_DIR="$MAC_HOST_ARTIFACT_DIR" \
    SKYBRIDGE_SMOKE_P2P_REMOTE_RUN_ID="$MAC_HOST_RUN_ID" \
    SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1 \
    SKYBRIDGE_SMOKE_MAC_HOST_ONLY=1 \
    SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE=packaged-lab \
    SKYBRIDGE_SMOKE_KEYCHAIN_MODE=system \
    SKYBRIDGE_SMOKE_PQC_TRUST_MODE=actual \
    SKYBRIDGE_SMOKE_ALLOW_PERSISTENT_TRUST_MUTATION=0 \
    SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH=0 \
    SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH=0 \
    SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=0 \
    SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE=0 \
    bash "$MAC_HOST_RUNNER" >"$HOST_LOG" 2>&1 &
  HOST_RUNNER_PID=$!

  host_ready_started_at="$(date +%s)"
  while [[ ! -s "$MAC_HOST_READY_FILE" ]]; do
    if ! kill -0 "$HOST_RUNNER_PID" >/dev/null 2>&1; then
      echo "signed current-source macOS host runner exited before readiness" >&2
      write_failure_summary "mac_host_readiness" "signed_host_runner_exited_before_ready"
      echo "host log: $HOST_LOG" >&2
      echo "summary: $SUMMARY_FILE" >&2
      exit 1
    fi
    if (( "$(date +%s)" - host_ready_started_at >= MAC_HOST_READY_TIMEOUT_SECONDS )); then
      echo "Timed out waiting for signed current-source macOS host readiness" >&2
      write_failure_summary "mac_host_readiness" "signed_host_readiness_timeout"
      echo "host log: $HOST_LOG" >&2
      echo "summary: $SUMMARY_FILE" >&2
      exit 1
    fi
    sleep 0.5
  done

  if ! HOST_READY_DATA="$(validate_mac_host_ready_file)"; then
    echo "signed current-source macOS host readiness validation failed" >&2
    write_failure_summary "mac_host_readiness" "signed_host_ready_contract_invalid"
    echo "summary: $SUMMARY_FILE" >&2
    exit 1
  fi
  HOST_PROCESS_PID="$(printf '%s\n' "$HOST_READY_DATA" | sed -n '1p')"
  DETECTED_REMOTE_PORT="$(printf '%s\n' "$HOST_READY_DATA" | sed -n '2p')"
  DETECTED_CONTROL_PORT="$(printf '%s\n' "$HOST_READY_DATA" | sed -n '3p')"
  HOST_STATUS_SOURCE="$(printf '%s\n' "$HOST_READY_DATA" | sed -n '4p')"
  HOST_PQC_REPORT_SOURCE="$(printf '%s\n' "$HOST_READY_DATA" | sed -n '5p')"
  HOST_SOURCE_INPUT_SHA256="$(printf '%s\n' "$HOST_READY_DATA" | sed -n '6p')"
  HOST_EXECUTABLE_SHA256="$(printf '%s\n' "$HOST_READY_DATA" | sed -n '7p')"
  if ! kill -0 "$HOST_RUNNER_PID" >/dev/null 2>&1 \
    || ! kill -0 "$HOST_PROCESS_PID" >/dev/null 2>&1; then
    echo "signed current-source macOS host process ownership was lost after readiness" >&2
    write_failure_summary "mac_host_readiness" "signed_host_process_not_running"
    echo "summary: $SUMMARY_FILE" >&2
    exit 1
  fi
  copy_private_host_evidence "$HOST_STATUS_SOURCE" "$HOST_STATUS"
  copy_private_host_evidence "$HOST_PQC_REPORT_SOURCE" "$HOST_PQC_REPORT"
  HOST_PERSISTENT_IDENTITY_MUTATION_DENIED="true"
  DIRECT_PORT="$DETECTED_REMOTE_PORT"

  HOST_REPORT_DATA="$(python3 - "$HOST_PQC_REPORT" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    report = json.load(handle)
keys = {
    int(entry.get("suiteWireId", -1)): entry.get("publicKeyBase64", "")
    for entry in report.get("keys", [])
    if isinstance(entry, dict)
}
print(report.get("deviceId", ""))
print(keys.get(0x0001, ""))
PY
)"
  HOST_PQC_DEVICE_ID="$(printf '%s\n' "$HOST_REPORT_DATA" | sed -n '1p')"
  HOST_PQC_XWING_PUBLIC_KEY_BASE64="$(printf '%s\n' "$HOST_REPORT_DATA" | sed -n '2p')"
  if [[ -z "$HOST_PQC_DEVICE_ID" || -z "$HOST_PQC_XWING_PUBLIC_KEY_BASE64" ]]; then
    echo "signed current-source macOS host did not expose its existing X-Wing identity" >&2
    write_failure_summary "mac_host_readiness" "signed_host_existing_identity_missing"
    echo "summary: $SUMMARY_FILE" >&2
    exit 1
  fi
  if [[ -n "$EXPECTED_DEVICE_ID" && "$HOST_PQC_DEVICE_ID" != "$EXPECTED_DEVICE_ID" ]]; then
    echo "signed current-source macOS host identity differs from the explicitly configured lookup candidate" >&2
    write_failure_summary "mac_host_readiness" "signed_host_identity_mismatch"
    echo "summary: $SUMMARY_FILE" >&2
    exit 1
  fi
  EXPECTED_DEVICE_ID="$HOST_PQC_DEVICE_ID"
  if [[ "$REQUIRE_EXISTING_PRODUCT_TRUST" == "true" ]]; then
    IDENTITY_SOURCE="android_authenticated_product_v1_pending"
  fi
  {
    echo "detected_remote_port=$DETECTED_REMOTE_PORT"
    echo "detected_control_port=$DETECTED_CONTROL_PORT"
    echo "mac_host_source_input_sha256=$HOST_SOURCE_INPUT_SHA256"
    echo "mac_host_executable_sha256=$HOST_EXECUTABLE_SHA256"
    echo "hostPersistentIdentityMutationDenied=1"
    echo "host_identity_used_as_android_trust_lookup_candidate=1"
  } >>"$COMMAND_FILE"
fi

if [[ -z "$DIRECT_HOST" && "$DEVICE_SERIAL" == emulator-* ]]; then
  DIRECT_HOST="10.0.2.2"
fi

echo "Building Android debug APK..."
"$ROOT_DIR/gradlew" :app:assembleDebug >/dev/null

APP_APK="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"
if [[ ! -f "$APP_APK" ]]; then
  echo "App APK not found: $APP_APK" >&2
  exit 1
fi

{
  "$ADB_BIN" -s "$DEVICE_SERIAL" wait-for-device
  "$ADB_BIN" -s "$DEVICE_SERIAL" install -r "$APP_APK"
} >"$INSTALL_LOG" 2>&1

if ! ANDROID_LOGCAT_START="$(
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell "date '+%m-%d %H:%M:%S.000'" \
    | tr -d '\r\n'
)"; then
  echo "Unable to read the bounded Android logcat start time" >&2
  write_failure_summary "android_logcat" "logcat_start_time_unavailable"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi
if [[ ! "$ANDROID_LOGCAT_START" =~ ^[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}$ ]]; then
  echo "Unable to establish a bounded Android logcat start time" >&2
  write_failure_summary "android_logcat" "logcat_start_time_invalid"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi
if ! "$ADB_BIN" -s "$DEVICE_SERIAL" shell am force-stop com.skybridge.compass.debug \
  >/dev/null 2>&1; then
  echo "Unable to stop the prior Android debug activity" >&2
  write_failure_summary "android_activity" "force_stop_failed"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi

SMOKE_NONCE="$(/usr/bin/python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
SMOKE_SCOPE_DATA="$(/usr/bin/python3 - "$SMOKE_NONCE" <<'PY'
import hashlib
import re
import sys

nonce = sys.argv[1]
if re.fullmatch(r"[A-Za-z0-9_-]{32,128}", nonce) is None:
    raise SystemExit("generated smoke nonce is not canonical")
run_ref = hashlib.sha256(nonce.encode("utf-8")).hexdigest()
print(run_ref)
print(f"debug-lan-interop-smoke-status-{run_ref}.log")
PY
)"
SMOKE_RUN_REF="$(printf '%s\n' "$SMOKE_SCOPE_DATA" | /usr/bin/sed -n '1p')"
SMOKE_STATUS_FILE_NAME="$(printf '%s\n' "$SMOKE_SCOPE_DATA" | /usr/bin/sed -n '2p')"
if [[ ! "$SMOKE_RUN_REF" =~ ^[0-9a-f]{64}$ ]] \
  || [[ ! "$SMOKE_STATUS_FILE_NAME" =~ ^debug-lan-interop-smoke-status-[0-9a-f]{64}\.log$ ]]; then
  echo "Unable to derive the Android run-scoped status authority" >&2
  write_failure_summary "android_smoke_scope" "run_scope_derivation_failed"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi
{
  echo "smoke_run_ref=$SMOKE_RUN_REF"
  echo "smoke_status_file_name=$SMOKE_STATUS_FILE_NAME"
} >>"$COMMAND_FILE"

REMOTE_SMOKE_SCOPE_PREPARED="true"
if ! remove_remote_smoke_scope; then
  write_failure_summary "android_smoke_scope" "stale_scope_cleanup_failed"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi
REMOTE_SMOKE_SCOPE_PREPARED="true"
if ! printf '%s' "$SMOKE_NONCE" |
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "run-as com.skybridge.compass.debug sh -c 'mkdir -p files && umask 077 && cat > files/$SMOKE_NONCE_FILE_NAME'" \
    >/dev/null; then
  echo "Unable to stage the Android run nonce" >&2
  write_failure_summary "android_smoke_scope" "nonce_stage_failed"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi
STAGED_SMOKE_NONCE="$("$ADB_BIN" -s "$DEVICE_SERIAL" shell \
  run-as com.skybridge.compass.debug cat "files/$SMOKE_NONCE_FILE_NAME")"
if [[ "$STAGED_SMOKE_NONCE" != "$SMOKE_NONCE" ]]; then
  unset STAGED_SMOKE_NONCE
  echo "Android run nonce did not round-trip exactly" >&2
  write_failure_summary "android_smoke_scope" "nonce_round_trip_mismatch"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi
unset STAGED_SMOKE_NONCE

ACTIVITY_ARGS=(
  am start -W
  -n "$DEFAULT_ACTIVITY"
  --ez skybridgeRequireSecure "$REQUIRE_SECURE"
  --ez skybridgeAllowPlaintextFallback "$ALLOW_PLAINTEXT_FALLBACK"
  --ez skybridgeAllowTrustOnFirstUse "$ALLOW_TOFU"
  --es skybridgeTimeoutSeconds "$TIMEOUT_SECONDS"
  --ez skybridgeAutoFinish true
  --es skybridgeSmokeNonce "$SMOKE_NONCE"
  --es skybridgeRemoteNoticeAccountDisplayName "$SMOKE_REMOTE_NOTICE_ACCOUNT_DISPLAY_NAME"
  --es skybridgeRemoteNoticeNebulaId "$SMOKE_REMOTE_NOTICE_NEBULA_ID"
  --ez skybridgeAllowDiagnosticTrustInjection "$ALLOW_DIAGNOSTIC_TRUST_INJECTION"
  --ez skybridgeRequireExistingProductTrust "$REQUIRE_EXISTING_PRODUCT_TRUST"
)

if [[ -n "$PEER_MLKEM_PUBLIC_B64" ]]; then
  ACTIVITY_ARGS+=(--es skybridgePeerMlkemPublicB64 "$PEER_MLKEM_PUBLIC_B64")
fi
if [[ -n "$PEER_XWING_PUBLIC_B64" ]]; then
  ACTIVITY_ARGS+=(--es skybridgePeerXwingPublicB64 "$PEER_XWING_PUBLIC_B64")
fi

if [[ -n "$EXPECTED_SERVICE_NAME" ]]; then
  ACTIVITY_ARGS+=(--es skybridgeExpectedServiceName "$EXPECTED_SERVICE_NAME")
fi
if [[ -n "$EXPECTED_DEVICE_ID" ]]; then
  ACTIVITY_ARGS+=(--es skybridgeExpectedDeviceId "$EXPECTED_DEVICE_ID")
fi
if [[ -n "$EXPECTED_FINGERPRINT" ]]; then
  ACTIVITY_ARGS+=(--es skybridgeExpectedFingerprint "$EXPECTED_FINGERPRINT")
fi
if [[ -n "$DIRECT_HOST" ]]; then
  ACTIVITY_ARGS+=(--es skybridgeDirectHost "$DIRECT_HOST")
  ACTIVITY_ARGS+=(--es skybridgeDirectPort "$DIRECT_PORT")
fi
"$ADB_BIN" -s "$DEVICE_SERIAL" shell "$(remote_shell_join "${ACTIVITY_ARGS[@]}")" >/dev/null
unset SMOKE_NONCE

start_epoch="$(date +%s)"
ANDROID_STATUS_OUTCOME="pending"
/bin/rm -f -- "$STATUS_LOG"
while true; do
  if copy_remote_smoke_status; then
    if ! ANDROID_STATUS_OUTCOME="$(inspect_android_smoke_status true)"; then
      ANDROID_STATUS_OUTCOME="invalid"
      break
    fi
    case "$ANDROID_STATUS_OUTCOME" in
      pending) ;;
      success:secure|success:plaintext|failure:normal_product_pairing_required|failure:reported)
        break
        ;;
      *)
        echo "Android LAN status validator returned an unknown outcome" >&2
        ANDROID_STATUS_OUTCOME="invalid"
        break
        ;;
    esac
  else
    copy_status=$?
    if (( copy_status != 2 )); then
      ANDROID_STATUS_OUTCOME="invalid"
      break
    fi
  fi

  now_epoch="$(date +%s)"
  if (( now_epoch - start_epoch > TIMEOUT_SECONDS )); then
    echo "Timed out waiting for Android LAN smoke result" >&2
    ANDROID_STATUS_OUTCOME="timeout"
    break
  fi
  sleep 1
done

if ! android_capture_redacted_logcat \
  "$ADB_BIN" \
  "$DEVICE_SERIAL" \
  "$ANDROID_LOGCAT_LOG" \
  "" \
  "$ANDROID_LOGCAT_START"; then
  echo "Android logcat capture/redaction failed" >&2
  write_failure_summary "android_logcat" "logcat_capture_or_redaction_failed"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi

if copy_remote_smoke_status; then
  :
else
  status_copy_result=$?
  if (( status_copy_result == 2 )); then
    echo "Android run-scoped status log was not produced" >&2
    write_failure_summary "android_lan_smoke" "android_status_missing"
  else
    write_failure_summary "android_lan_smoke" "android_status_read_failed"
  fi
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi
if [[ ! -s "$STATUS_LOG" ]]; then
  echo "Android status log was not produced" >&2
  write_failure_summary "android_lan_smoke" "android_status_missing"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi
if ! ANDROID_STATUS_OUTCOME="$(inspect_android_smoke_status false)"; then
  write_failure_summary "android_lan_smoke" "android_status_contract_invalid"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi
case "$ANDROID_STATUS_OUTCOME" in
  failure:normal_product_pairing_required)
    write_failure_summary "android_lan_smoke" "normal_product_pairing_required"
    echo "Authenticated product trust is incomplete, including the product-origin peer KEM bootstrap. Complete the normal product flow; this debug runner will not inject or migrate trust." >&2
    echo "summary: $SUMMARY_FILE" >&2
    exit 1
    ;;
  failure:reported)
    write_failure_summary "android_lan_smoke" "android_reported_failure"
    echo "summary: $SUMMARY_FILE" >&2
    exit 1
    ;;
  pending)
    write_failure_summary "android_lan_smoke" "terminal_status_missing"
    echo "summary: $SUMMARY_FILE" >&2
    exit 1
    ;;
  success:secure|success:plaintext) ;;
  *)
    write_failure_summary "android_lan_smoke" "android_status_outcome_invalid"
    echo "summary: $SUMMARY_FILE" >&2
    exit 1
    ;;
esac

if [[ "$REQUIRE_SECURE" == "true" && "$ANDROID_STATUS_OUTCOME" != "success:secure" ]]; then
  echo "Android LAN smoke did not produce a secure current-owner frame" >&2
  write_failure_summary "android_lan_smoke" "secure_success_missing"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi

if [[ "$REQUIRE_EXISTING_PRODUCT_TRUST" == "true" ]]; then
  if [[ "$ANDROID_STATUS_OUTCOME" != "success:secure" ]]; then
    echo "Android LAN smoke did not bind a current-owner frame to existing authenticated product trust" >&2
    write_failure_summary "android_product_trust" "trusted_existing_secure_frame_missing"
    echo "summary: $SUMMARY_FILE" >&2
    exit 1
  fi
  IDENTITY_VERIFIED="true"
  IDENTITY_SOURCE="android_authenticated_product_v1"
  {
    echo "identity_verified_after_android_product_trust=1"
    echo "identity_source_final=$IDENTITY_SOURCE"
  } >>"$COMMAND_FILE"
fi

if ! refresh_signed_mac_host_evidence; then
  write_failure_summary "mac_host_evidence" "signed_host_final_evidence_unavailable"
  echo "summary: $SUMMARY_FILE" >&2
  exit 1
fi

{
  echo "android_status_ok=true"
  echo "android_status_outcome=$ANDROID_STATUS_OUTCOME"
  echo "smoke_run_ref=$SMOKE_RUN_REF"
  echo "connection_mode=$(if [[ -n "$DIRECT_HOST" ]]; then echo direct; else echo discovery; fi)"
  echo "require_secure=$REQUIRE_SECURE"
  echo "allow_plaintext_fallback=$ALLOW_PLAINTEXT_FALLBACK"
  echo "allow_tofu=$ALLOW_TOFU"
  echo "prepair=$ENABLE_PREPAIRING"
  echo "diagnostic_trust_injection=$ALLOW_DIAGNOSTIC_TRUST_INJECTION"
  echo "acceptance_eligible=$ACCEPTANCE_ELIGIBLE"
  echo "diagnosticOnly=$(if [[ "$START_MAC_HOST" == "true" ]]; then echo 1; else echo 0; fi)"
  echo "currentSourceHelper=$(if [[ "$START_MAC_HOST" == "true" ]]; then echo 1; else echo 0; fi)"
  echo "hostPersistentIdentityMutationDenied=$(if [[ "$HOST_PERSISTENT_IDENTITY_MUTATION_DENIED" == "true" ]]; then echo 1; else echo 0; fi)"
  echo "forcedPersistentTrustMutationAllowed=0"
  echo "normalProductPairingWriteAuthorized=$(if [[ "$NORMAL_PRODUCT_PAIRING_WRITE_AUTHORIZED" == "true" ]]; then echo 1; else echo 0; fi)"
  echo "mac_host_mode=$MAC_HOST_MODE"
  echo "mac_host_auto_approve_pairing=$MAC_HOST_AUTO_APPROVE_PAIRING"
  echo "mac_host_remote_control_notice_auto_approve=$MAC_HOST_REMOTE_CONTROL_NOTICE_AUTO_APPROVE"
  echo "identity_verified=$IDENTITY_VERIFIED"
  echo "identity_source=$IDENTITY_SOURCE"
  echo "require_existing_product_trust=$REQUIRE_EXISTING_PRODUCT_TRUST"
  echo "android_logcat_capture_ok=true"
  echo "success_line=$(/usr/bin/tail -n 1 "$STATUS_LOG")"
  if [[ -s "$HOST_STATUS" ]]; then
    echo "mac_host_ready=$(grep -m 1 'ready discovery=_skybridge._tcp' "$HOST_STATUS" || true)"
    echo "mac_remote_port=${DETECTED_REMOTE_PORT:-missing}"
  fi
  if [[ -s "$HOST_STATUS" ]]; then
    echo "mac_host_status=$HOST_STATUS"
  fi
if [[ -s "$HOST_PQC_REPORT" ]]; then
  echo "mac_host_pqc_report=$HOST_PQC_REPORT"
fi
} >"$SUMMARY_FILE"

echo "public_artifacts=$PUBLIC_ARTIFACT_DIR" >>"$SUMMARY_FILE"
if ! android_smoke_materialize_public_artifacts "$RUN_DIR" "$PUBLIC_ARTIFACT_DIR"; then
  echo "Android ↔ macOS LAN public artifact materialization failed; evidence bundle rejected." >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi
if ! android_smoke_check_public_artifacts \
  "$PUBLIC_ARTIFACT_DIR" \
  "$DEVICE_SERIAL" \
  "$EXPECTED_DEVICE_ID" \
  "$EXPECTED_FINGERPRINT" \
  "$DIRECT_HOST" \
  "$PEER_MLKEM_PUBLIC_B64" \
  "$PEER_XWING_PUBLIC_B64"; then
  echo "Android ↔ macOS LAN public artifact scan failed; evidence bundle rejected." >&2
  echo "See $SUMMARY_FILE" >&2
  exit 1
fi

if [[ "$ACCEPTANCE_ELIGIBLE" == "true" ]]; then
  echo "Android ↔ macOS LAN remote smoke passed."
else
  echo "Android ↔ macOS LAN diagnostic smoke completed; it is not acceptance evidence."
fi
echo "Artifacts:"
echo "  environment: $ENV_FILE"
echo "  command: $COMMAND_FILE"
echo "  install log: $INSTALL_LOG"
echo "  android status: $STATUS_LOG"
echo "  android logcat: $ANDROID_LOGCAT_LOG"
if [[ -s "$HOST_LOG" ]]; then
  echo "  mac host log: $HOST_LOG"
fi
if [[ -s "$HOST_BUILD_LOG" ]]; then
  echo "  mac host build log: $HOST_BUILD_LOG"
fi
if [[ -s "$HOST_STATUS" ]]; then
  echo "  mac host status: $HOST_STATUS"
fi
if [[ -s "$HOST_PQC_REPORT" ]]; then
  echo "  mac host pqc report: $HOST_PQC_REPORT"
fi
echo "  public artifacts: $PUBLIC_ARTIFACT_DIR"
echo "  summary: $SUMMARY_FILE"
