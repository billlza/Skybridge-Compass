#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=scripts/lib/repository_layout.sh
source "$ROOT_DIR/scripts/lib/repository_layout.sh"
RELEASE_REPO_ROOT="$(skybridge_canonical_release_root "$ROOT_DIR")"
# shellcheck source=scripts/lib/android_env.sh
source "$ROOT_DIR/scripts/lib/android_env.sh"
# shellcheck source=scripts/lib/source_provenance.sh
source "$ROOT_DIR/scripts/lib/source_provenance.sh"
# shellcheck source=scripts/lib/strict_gradle_output.sh
source "$ROOT_DIR/scripts/lib/strict_gradle_output.sh"

VALIDATOR="$ROOT_DIR/scripts/validate_android_mac_webrtc_formal_evidence.py"
PROCESS_HELPER="$ROOT_DIR/scripts/lib/webrtc_smoke_process_ownership.py"
APP_PACKAGE="com.skybridge.compass.debug"
TEST_PACKAGE="com.skybridge.compass.debug.macwebrtc.test"
TEST_RUNNER="$TEST_PACKAGE/com.skybridge.compass.android.HiltTestRunner"
TEST_CLASS="com.skybridge.compass.android.webrtc.AppleReleaseInteropOffererAppInstrumentationTest"
HOST_PRODUCT="FormalMacWebRTCHost"
HOST_EXECUTABLE="$RELEASE_REPO_ROOT/.build/debug/$HOST_PRODUCT"

DEVICE_SERIAL=""
SIGNALING_WSS_URL=""
SOURCE_TOKEN_FILE=""
TENANT_ID=""
EXPECTED_SOURCE_COMMIT=""
RUN_DIR=""
ANDROID_TIMEOUT_SECONDS="180"
HOST_TIMEOUT_SECONDS="180"
FILE_TRANSFER_TIMEOUT_SECONDS="60"
POST_SUCCESS_HOLD_MILLIS="6000"
HOST_HOLD_SECONDS="6"

usage() {
  cat <<'EOF'
Usage:
  scripts/run_android_mac_webrtc_formal_smoke.sh \
    --device <exact-Samsung-adb-serial> \
    --signaling-wss-url <wss://host/path> \
    --token-file <absolute-private-short-JWT-file> \
    --tenant-id <exact-tenant-id> \
    --expected-source-commit <40-lowercase-hex> \
    [--android-timeout-seconds <n>] \
    [--host-timeout-seconds <n>] \
    [--file-transfer-timeout-seconds <n>] \
    [--run-dir <new-absolute-path>]

The formal lane requires one existing Samsung debug-app installation and its
existing identity/trust material. It overlay-installs the main APK without
uninstalling, clearing, or force-stopping it. Cleanup may remove only the exact
dedicated test APK and private files owned by this invocation. The legacy
run_android_apple_webrtc_smoke.sh and run_android_mac_lan_remote_smoke.sh lanes
are not accepted as this formal evidence.
EOF
}

require_value() {
  local option="$1"
  local value="${2-}"
  if [[ -z "$value" ]]; then
    echo "Missing value for $option" >&2
    exit 1
  fi
}

require_seconds() {
  local label="$1"
  local value="$2"
  local minimum="$3"
  local maximum="$4"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < minimum || value > maximum )); then
    echo "$label must be an integer from $minimum through $maximum" >&2
    exit 1
  fi
}

remote_shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

remote_shell_join() {
  local joined=""
  local argument=""
  for argument in "$@"; do
    if [[ -n "$joined" ]]; then
      joined+=" "
    fi
    joined+="$(remote_shell_quote "$argument")"
  done
  printf '%s' "$joined"
}

validate_wss_url() {
  python3 - "$1" <<'PY'
import ipaddress
import sys
from urllib.parse import urlsplit

value = sys.argv[1]
if value != value.strip() or any(character.isspace() or ord(character) < 0x20 for character in value):
    raise SystemExit("formal signaling URL must not contain whitespace or control characters")
parsed = urlsplit(value)
if (
    parsed.scheme != "wss"
    or not parsed.hostname
    or parsed.username is not None
    or parsed.password is not None
    or parsed.query
    or parsed.fragment
    or not parsed.path.startswith("/")
):
    raise SystemExit("formal signaling URL must be one credential-free wss URL")
host = parsed.hostname.lower()
if host == "localhost":
    raise SystemExit("formal signaling URL must not be loopback")
try:
    if ipaddress.ip_address(host).is_loopback:
        raise SystemExit("formal signaling URL must not be loopback")
except ValueError:
    pass
try:
    port = parsed.port
except ValueError as exc:
    raise SystemExit("formal signaling URL has an invalid port") from exc
if port is not None and not 1 <= port <= 65535:
    raise SystemExit("formal signaling URL has an invalid port")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      require_value "$1" "${2-}"
      DEVICE_SERIAL="$2"
      shift 2
      ;;
    --signaling-wss-url)
      require_value "$1" "${2-}"
      SIGNALING_WSS_URL="$2"
      shift 2
      ;;
    --token-file)
      require_value "$1" "${2-}"
      SOURCE_TOKEN_FILE="$2"
      shift 2
      ;;
    --tenant-id)
      require_value "$1" "${2-}"
      TENANT_ID="$2"
      shift 2
      ;;
    --expected-source-commit)
      require_value "$1" "${2-}"
      EXPECTED_SOURCE_COMMIT="$2"
      shift 2
      ;;
    --android-timeout-seconds)
      require_value "$1" "${2-}"
      ANDROID_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --host-timeout-seconds)
      require_value "$1" "${2-}"
      HOST_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --file-transfer-timeout-seconds)
      require_value "$1" "${2-}"
      FILE_TRANSFER_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --run-dir)
      require_value "$1" "${2-}"
      RUN_DIR="$2"
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

if [[ -z "$DEVICE_SERIAL" || -z "$SIGNALING_WSS_URL" || -z "$SOURCE_TOKEN_FILE" \
    || -z "$TENANT_ID" || -z "$EXPECTED_SOURCE_COMMIT" ]]; then
  usage >&2
  exit 1
fi
if [[ ! "$EXPECTED_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "--expected-source-commit must be one full lowercase Git revision" >&2
  exit 1
fi
if ! python3 - "$TENANT_ID" <<'PY'
import sys

value = sys.argv[1]
if (
    not value
    or value != value.strip()
    or len(value.encode("utf-8")) > 512
    or any(character.isspace() or ord(character) < 0x20 for character in value)
):
    raise SystemExit(1)
PY
then
  echo "--tenant-id is malformed" >&2
  exit 1
fi
require_seconds "--android-timeout-seconds" "$ANDROID_TIMEOUT_SECONDS" 30 600
require_seconds "--host-timeout-seconds" "$HOST_TIMEOUT_SECONDS" 30 600
require_seconds "--file-transfer-timeout-seconds" "$FILE_TRANSFER_TIMEOUT_SECONDS" 10 300
validate_wss_url "$SIGNALING_WSS_URL"

while IFS= read -r environment_name; do
  if [[ "$environment_name" == SKYBRIDGE_SMOKE_* ]]; then
    echo "Formal interoperability refuses inherited SKYBRIDGE_SMOKE_* diagnostics" >&2
    exit 1
  fi
done < <(compgen -e)

if [[ "$SOURCE_TOKEN_FILE" != /* ]]; then
  echo "--token-file must be absolute" >&2
  exit 1
fi
if [[ ! -f "$VALIDATOR" || -L "$VALIDATOR" || ! -f "$PROCESS_HELPER" || -L "$PROCESS_HELPER" ]]; then
  echo "Formal evidence helpers are missing or symbolic" >&2
  exit 1
fi

if [[ -z "$RUN_DIR" ]]; then
  EXPECTED_RUN_PARENT="$ROOT_DIR/build/interop/android-mac-webrtc-formal"
  mkdir -p -- "$EXPECTED_RUN_PARENT"
  [[ -d "$EXPECTED_RUN_PARENT" && ! -L "$EXPECTED_RUN_PARENT" ]] || {
    echo "Formal run parent is not a real directory" >&2
    exit 1
  }
  RUN_PARENT="$(cd "$EXPECTED_RUN_PARENT" && pwd -P)"
  if [[ "$RUN_PARENT" != "$EXPECTED_RUN_PARENT" ]]; then
    echo "Formal run parent must not traverse a symbolic ancestor" >&2
    exit 1
  fi
  RUN_DIR="$(mktemp -d "$RUN_PARENT/run.XXXXXX")"
else
  if [[ "$RUN_DIR" != /* || "$RUN_DIR" == *$'\n'* || "$RUN_DIR" == *$'\r'* \
      || -e "$RUN_DIR" || -L "$RUN_DIR" ]]; then
    echo "--run-dir must be one new absolute non-symbolic path" >&2
    exit 1
  fi
  REQUESTED_RUN_DIR="$RUN_DIR"
  REQUESTED_RUN_PARENT="$(dirname "$REQUESTED_RUN_DIR")"
  RUN_BASENAME="$(basename "$REQUESTED_RUN_DIR")"
  [[ "$RUN_BASENAME" != "." && "$RUN_BASENAME" != ".." ]] || {
    echo "--run-dir has an invalid final path component" >&2
    exit 1
  }
  [[ -d "$REQUESTED_RUN_PARENT" && ! -L "$REQUESTED_RUN_PARENT" ]] || {
    echo "--run-dir parent must be one existing real directory" >&2
    exit 1
  }
  RUN_PARENT="$(cd "$REQUESTED_RUN_PARENT" && pwd -P)"
  if [[ "$RUN_PARENT" != "$REQUESTED_RUN_PARENT" ]]; then
    echo "--run-dir parent must be one canonical non-symbolic path" >&2
    exit 1
  fi
  RUN_DIR="$RUN_PARENT/$RUN_BASENAME"
  mkdir -m 0700 -- "$RUN_DIR"
fi
chmod 0700 "$RUN_DIR"
RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"
if [[ "$(stat -f '%Su:%Lp' "$RUN_DIR")" != "$(id -un):700" ]]; then
  echo "Formal run directory must be current-user owned with mode 0700" >&2
  exit 1
fi

RUN_REF="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
TRANSFER_IDS_OUTPUT="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
print(uuid.uuid4())
PY
)"
ANDROID_TO_MAC_TRANSFER_ID="${TRANSFER_IDS_OUTPUT%%$'\n'*}"
MAC_TO_ANDROID_TRANSFER_ID="${TRANSFER_IDS_OUTPUT#*$'\n'}"
if [[ "$TRANSFER_IDS_OUTPUT" != *$'\n'* \
    || "$MAC_TO_ANDROID_TRANSFER_ID" == *$'\n'* \
    || "$ANDROID_TO_MAC_TRANSFER_ID" == "$MAC_TO_ANDROID_TRANSFER_ID" ]]; then
  echo "Unable to create distinct canonical transfer identifiers" >&2
  exit 1
fi

SUMMARY_FILE="$RUN_DIR/summary.txt"
COMMAND_FILE="$RUN_DIR/command.txt"
ANDROID_BUILD_LOG="$RUN_DIR/android-build.log"
SWIFT_BUILD_LOG="$RUN_DIR/swift-build.log"
ANDROID_INSTALL_LOG="$RUN_DIR/android-install.log"
ANDROID_TEST_INSTALL_LOG="$RUN_DIR/android-test-install.log"
ANDROID_INSTRUMENTATION_LOG="$RUN_DIR/android-instrumentation.log"
HOST_STDOUT="$RUN_DIR/mac-host.stdout.log"
HOST_STDERR="$RUN_DIR/mac-host.stderr.log"
MAC_RESULT="$RUN_DIR/mac-formal-result.json"
MAC_PROCESS_IDENTITY="$RUN_DIR/mac-process-identity.json"
RECEIPT="$RUN_DIR/android-mac-formal-evidence.json"
RECEIPT_CANDIDATE="$RUN_DIR/.android-mac-formal-evidence.candidate.json"
SOURCE_BEFORE="$RUN_DIR/source-before.properties"
SOURCE_AFTER="$RUN_DIR/source-after.properties"
DEVICE_BEFORE="$RUN_DIR/android-device-before.properties"
DEVICE_AFTER="$RUN_DIR/android-device-after.properties"
SENSITIVE_BEFORE="$RUN_DIR/android-sensitive-before.properties"
SENSITIVE_AFTER="$RUN_DIR/android-sensitive-after.properties"
INSTALLED_BEFORE="$RUN_DIR/android-installed-before.properties"
INSTALLED_AFTER="$RUN_DIR/android-installed-after.properties"
MANIFEST_BINDING="$RUN_DIR/merged-manifest.properties"
APP_PROVENANCE="$RUN_DIR/app-apk.properties"
TEST_PROVENANCE="$RUN_DIR/test-apk.properties"
HOST_PROVENANCE_BEFORE="$RUN_DIR/mac-host-before.properties"
HOST_PROVENANCE_AFTER="$RUN_DIR/mac-host-after.properties"
TOKEN_FILE="$RUN_DIR/auth-token"
TOKEN_PROPERTIES="$RUN_DIR/auth-token.properties"
AUTH_CONTEXT="$RUN_DIR/android-auth-context.json"
AUTH_CONTEXT_PROVENANCE="$RUN_DIR/android-auth-context.properties"
CODE_FILE="$RUN_DIR/connection-code"
CODE_PROPERTIES="$RUN_DIR/connection-code.properties"
APP_APK="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"
TEST_APK="$ROOT_DIR/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
MERGED_MANIFEST="$ROOT_DIR/app/build/intermediates/merged_manifests/debug/processDebugManifest/AndroidManifest.xml"
AUTH_CONTEXT_FILE_NAME="mac-formal-auth-$RUN_REF.json"
CODE_FILE_NAME="mac-formal-code-$RUN_REF.txt"
MAC_RUN_PAYLOAD_DIR="${HOME:?}/Library/Caches/com.skybridge.formal-interop/$RUN_REF"

ADB_BIN=""
ANDROID_USER_ID=""
DEVICE_LOCK=""
ANDROID_PID=""
HOST_PID=""
HOST_OWNERSHIP_CAPTURED="false"
ANDROID_STARTED="false"
HOST_STARTED="false"
ANDROID_QUIESCENT="true"
HOST_QUIESCENT="true"
TEST_PACKAGE_STATE="absent"
TEST_APK_SHA256=""
APP_APK_SHA256=""
ANDROID_CONTEXT_STAGED="false"
ANDROID_CONTEXT_CLEANUP_VERIFIED="false"
TEST_PACKAGE_CLEANUP_VERIFIED="false"
PRIVATE_FILE_CLEANUP_VERIFIED="false"
MAC_PROCESS_CLEANUP_VERIFIED="false"
MAC_EXIT_VERIFIED="false"
MAC_PAYLOAD_CLEANUP_VERIFIED="false"
ANDROID_APP_EXIT_VERIFIED="false"
CLEANUP_RUNNING="false"
MAIN_OVERLAY_ATTEMPTED="false"

property_value() {
  local path="$1"
  local key="$2"
  local value=""
  value="$(sed -n "s/^${key}=//p" "$path")"
  if [[ -z "$value" || "$value" == *$'\n'* ]]; then
    echo "Missing canonical property $key in $path" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

unlink_private() {
  local path="$1"
  local properties="$2"
  local prefix="$3"
  local digest=""
  local bytes=""
  digest="$(property_value "$properties" "${prefix}sha256")" || return 1
  bytes="$(property_value "$properties" "${prefix}bytes")" || return 1
  python3 "$VALIDATOR" private-unlink \
    --path "$path" \
    --expected-sha256 "$digest" \
    --expected-bytes "$bytes"
}

remove_android_context() {
  local remote_command=""
  if [[ "$ANDROID_CONTEXT_STAGED" != "true" ]]; then
    ANDROID_CONTEXT_CLEANUP_VERIFIED="true"
    return 0
  fi
  remote_command="rm -f files/$AUTH_CONTEXT_FILE_NAME files/$CODE_FILE_NAME; test ! -e files/$AUTH_CONTEXT_FILE_NAME; test ! -e files/$CODE_FILE_NAME"
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "$(remote_shell_join run-as "$TEST_PACKAGE" sh -c "$remote_command")" >/dev/null \
    || return 1
  ANDROID_CONTEXT_STAGED="false"
  ANDROID_CONTEXT_CLEANUP_VERIFIED="true"
}

remove_owned_test_package() {
  local query_status=0
  case "$TEST_PACKAGE_STATE" in
    absent)
      TEST_PACKAGE_CLEANUP_VERIFIED="true"
      return 0
      ;;
    install_attempted)
      if android_installed_package_path "$ADB_BIN" "$DEVICE_SERIAL" "$TEST_PACKAGE" >/dev/null; then
        echo "Dedicated test package appeared after an ambiguous install; refusing uninstall" >&2
        return 1
      else
        query_status=$?
      fi
      if (( query_status == 2 )); then
        TEST_PACKAGE_STATE="absent"
        TEST_PACKAGE_CLEANUP_VERIFIED="true"
        return 0
      fi
      echo "Dedicated test-package absence is unverifiable after install failure" >&2
      return 1
      ;;
    owned)
      android_remove_owned_package \
        "$ADB_BIN" "$DEVICE_SERIAL" "$TEST_PACKAGE" "$TEST_APK_SHA256" \
        || return 1
      TEST_PACKAGE_STATE="absent"
      TEST_PACKAGE_CLEANUP_VERIFIED="true"
      ;;
    *)
      echo "Dedicated test-package ownership state is invalid" >&2
      return 1
      ;;
  esac
}

wait_for_mac_exit() {
  local deadline=$((SECONDS + 10))
  local status=0
  if [[ "$HOST_STARTED" != "true" ]]; then
    return 0
  fi
  if [[ "$HOST_OWNERSHIP_CAPTURED" != "true" ]]; then
    wait_for_uncaptured_mac_child_exit \
      $(((HOST_TIMEOUT_SECONDS + HOST_HOLD_SECONDS + 60) * 4))
    return $?
  fi
  if python3 "$PROCESS_HELPER" mac-status \
    --identity "$MAC_PROCESS_IDENTITY" >/dev/null 2>&1; then
    status=0
  else
    status=$?
  fi
  if (( status == 0 )); then
    python3 "$PROCESS_HELPER" mac-signal \
      --identity "$MAC_PROCESS_IDENTITY" --signal TERM >/dev/null || return 1
    while (( SECONDS < deadline )); do
      if python3 "$PROCESS_HELPER" mac-status \
        --identity "$MAC_PROCESS_IDENTITY" >/dev/null 2>&1; then
        status=0
      else
        status=$?
      fi
      (( status != 0 )) && break
      sleep 0.25
    done
    if (( status == 0 )); then
      python3 "$PROCESS_HELPER" mac-signal \
        --identity "$MAC_PROCESS_IDENTITY" --signal KILL >/dev/null || return 1
      sleep 0.25
      if python3 "$PROCESS_HELPER" mac-status \
        --identity "$MAC_PROCESS_IDENTITY" >/dev/null 2>&1; then
        status=0
      else
        status=$?
      fi
    fi
  fi
  if (( status != 1 )); then
    echo "Exact macOS child absence is not proven; no broader process cleanup was attempted" >&2
    return 1
  fi
  if [[ -n "$HOST_PID" ]]; then
    wait "$HOST_PID" >/dev/null 2>&1 || true
    HOST_PID=""
  fi
  HOST_QUIESCENT="true"
  MAC_PROCESS_CLEANUP_VERIFIED="true"
}

wait_for_uncaptured_mac_child_exit() {
  local wait_ticks="$1"
  local child_status=0
  if [[ ! "$wait_ticks" =~ ^[1-9][0-9]*$ || "$HOST_STARTED" != "true" \
      || "$HOST_OWNERSHIP_CAPTURED" == "true" \
      || ! "$HOST_PID" =~ ^[1-9][0-9]*$ ]]; then
    echo "Uncaptured macOS child wait state is invalid; preserving private files" >&2
    return 3
  fi
  while kill -0 "$HOST_PID" >/dev/null 2>&1 && (( wait_ticks > 0 )); do
    sleep 0.25
    wait_ticks=$((wait_ticks - 1))
  done
  if kill -0 "$HOST_PID" >/dev/null 2>&1; then
    echo "Uncaptured macOS child remains live; refusing signals and preserving private files" >&2
    return 2
  fi
  if wait "$HOST_PID" >/dev/null 2>&1; then
    child_status=0
  else
    child_status=$?
  fi
  HOST_PID=""
  HOST_QUIESCENT="true"
  echo "Uncaptured macOS child exited naturally with status $child_status; ownership cleanup remains failed" >&2
  return 1
}

cleanup_host_private_files() {
  if [[ "$HOST_QUIESCENT" != "true" ]]; then
    echo "Host private files were preserved because exact child quiescence is unproven" >&2
    return 1
  fi
  if [[ -e "$CODE_FILE" && -f "$CODE_PROPERTIES" ]]; then
    unlink_private "$CODE_FILE" "$CODE_PROPERTIES" "" || return 1
  fi
  if [[ -e "$AUTH_CONTEXT" && -f "$AUTH_CONTEXT_PROVENANCE" ]]; then
    unlink_private "$AUTH_CONTEXT" "$AUTH_CONTEXT_PROVENANCE" \
      "android_auth_context_" || return 1
  fi
  if [[ -e "$TOKEN_FILE" && -f "$TOKEN_PROPERTIES" ]]; then
    unlink_private "$TOKEN_FILE" "$TOKEN_PROPERTIES" "" || return 1
  fi
  if [[ -e "$CODE_FILE" || -e "$AUTH_CONTEXT" || -e "$TOKEN_FILE" ]]; then
    echo "Host private file cleanup is incomplete" >&2
    return 1
  fi
  PRIVATE_FILE_CLEANUP_VERIFIED="true"
}

release_device_lock_after_quiescence() {
  if [[ -z "$DEVICE_LOCK" ]]; then
    return 0
  fi
  if [[ "$ANDROID_QUIESCENT" != "true" || "$HOST_QUIESCENT" != "true" ]]; then
    echo "Device lock was preserved because Android/macOS quiescence is unproven" >&2
    return 1
  fi
  skybridge_release_device_lock "$DEVICE_LOCK" || return 1
  DEVICE_LOCK=""
}

cleanup() {
  local original_status=$?
  local cleanup_failed="false"
  local deadline=0
  if [[ "$CLEANUP_RUNNING" == "true" ]]; then
    return
  fi
  CLEANUP_RUNNING="true"
  set +e

  if [[ "$HOST_STARTED" == "true" && "$HOST_QUIESCENT" != "true" ]]; then
    wait_for_mac_exit || cleanup_failed="true"
  fi

  if [[ "$ANDROID_STARTED" == "true" && "$ANDROID_QUIESCENT" != "true" && -n "$ANDROID_PID" ]]; then
    deadline=$((SECONDS + 10))
    while kill -0 "$ANDROID_PID" >/dev/null 2>&1 && (( SECONDS < deadline )); do
      sleep 0.25
    done
    if kill -0 "$ANDROID_PID" >/dev/null 2>&1; then
      echo "Android instrumentation is still active; refusing force-stop and package cleanup" >&2
      cleanup_failed="true"
    else
      wait "$ANDROID_PID" >/dev/null 2>&1 || true
      ANDROID_PID=""
      ANDROID_QUIESCENT="true"
    fi
  fi

  if [[ "$ANDROID_QUIESCENT" == "true" && "$HOST_QUIESCENT" == "true" \
      && -n "$ADB_BIN" ]]; then
    if android_require_package_process_absent \
      "$ADB_BIN" "$DEVICE_SERIAL" "$APP_PACKAGE"; then
      remove_android_context || cleanup_failed="true"
      remove_owned_test_package || cleanup_failed="true"
    else
      cleanup_failed="true"
    fi
  elif [[ "$TEST_PACKAGE_STATE" != "absent" || "$ANDROID_CONTEXT_STAGED" == "true" ]]; then
    echo "Android run-owned state was preserved because Android/macOS quiescence is unproven" >&2
    cleanup_failed="true"
  fi

  if [[ "$HOST_QUIESCENT" == "true" ]]; then
    cleanup_host_private_files || cleanup_failed="true"
  elif [[ -e "$CODE_FILE" || -e "$AUTH_CONTEXT" || -e "$TOKEN_FILE" ]]; then
    echo "Host private files were preserved because exact child quiescence is unproven" >&2
    cleanup_failed="true"
  fi

  if [[ -n "$DEVICE_LOCK" ]]; then
    release_device_lock_after_quiescence || cleanup_failed="true"
  fi
  set -e
  CLEANUP_RUNNING="false"
  if [[ "$cleanup_failed" == "true" && $original_status -eq 0 ]]; then
    return 1
  fi
  return "$original_status"
}

fail_run() {
  local stage="$1"
  local reason="$2"
  {
    echo "status=failed"
    echo "stage=$stage"
    echo "reason=$reason"
    echo "run_ref=$RUN_REF"
    echo "main_package_overlay_attempted=$MAIN_OVERLAY_ATTEMPTED"
    echo "main_package_destructive_cleanup_attempted=false"
    echo "receipt=$RECEIPT"
  } >"$SUMMARY_FILE"
  echo "Android -> macOS formal smoke failed at $stage: $reason" >&2
  echo "Private evidence directory: $RUN_DIR" >&2
  exit 1
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

ADB_BIN="$(resolve_adb_bin "$ROOT_DIR" || true)"
if [[ -z "$ADB_BIN" ]]; then
  fail_run "preflight" "adb_not_found"
fi
android_require_exact_device "$ADB_BIN" "$DEVICE_SERIAL" \
  || fail_run "preflight" "exact_android_device_unavailable"
ANDROID_USER_ID="$(android_current_user_id "$ADB_BIN" "$DEVICE_SERIAL")" \
  || fail_run "preflight" "android_user_id_unavailable"
DEVICE_LOCK="$(skybridge_acquire_device_lock "$RELEASE_REPO_ROOT" android-mac-formal "$DEVICE_SERIAL")" \
  || fail_run "preflight" "formal_device_lane_locked"

skybridge_require_frozen_git_source \
  "$RELEASE_REPO_ROOT" "$EXPECTED_SOURCE_COMMIT" "formal pre-build verification" \
  || fail_run "source_freeze" "source_not_clean_or_expected"
skybridge_collect_frozen_git_binding \
  "$RELEASE_REPO_ROOT" "$EXPECTED_SOURCE_COMMIT" before >"$SOURCE_BEFORE" \
  || fail_run "source_freeze" "source_before_binding_failed"
android_collect_samsung_4k_device_binding "$ADB_BIN" "$DEVICE_SERIAL" >"$DEVICE_BEFORE" \
  || fail_run "android_device" "samsung_api36_4k_preflight_failed"
if [[ "$(property_value "$DEVICE_BEFORE" sdk)" != "36" ]]; then
  fail_run "android_device" "exact_api36_required"
fi

if [[ -x "$HOST_EXECUTABLE" ]]; then
  EXISTING_HOST_PIDS="$(
    python3 "$PROCESS_HELPER" mac-list-exact --expected-executable "$HOST_EXECUTABLE"
  )" || fail_run "mac_process" "prebuild_process_absence_unverifiable"
  [[ -z "$EXISTING_HOST_PIDS" ]] \
    || fail_run "mac_process" "preexisting_formal_host_process"
fi

for output in "$APP_APK" "$TEST_APK" "$HOST_EXECUTABLE"; do
  if [[ -e "$output" || -L "$output" ]]; then
    [[ ! -d "$output" ]] || fail_run "build" "canonical_output_is_directory"
    rm -f -- "$output"
  fi
done

if ! "$ROOT_DIR/gradlew" \
  -p "$ROOT_DIR" \
  --no-daemon \
  --no-parallel \
  --max-workers=2 \
  --rerun-tasks \
  --warning-mode all \
  -PskybridgeMacWebRtcFormalTestApplicationId="$TEST_PACKAGE" \
  :app:assembleDebug \
  :app:assembleDebugAndroidTest >"$ANDROID_BUILD_LOG" 2>&1; then
  fail_run "android_build" "gradle_build_failed"
fi
skybridge_require_zero_warning_tool_log "$ANDROID_BUILD_LOG" \
  || fail_run "android_build" "gradle_build_warning"

if ! (
  cd "$RELEASE_REPO_ROOT"
  git ls-files --error-unmatch Package.resolved >/dev/null
  swift build \
    -c debug \
    --disable-automatic-resolution \
    --product "$HOST_PRODUCT" \
    -Xswiftc -warnings-as-errors
) >"$SWIFT_BUILD_LOG" 2>&1; then
  fail_run "mac_build" "swift_build_failed"
fi
skybridge_require_zero_warning_tool_log "$SWIFT_BUILD_LOG" \
  || fail_run "mac_build" "swift_build_warning"

[[ -f "$APP_APK" && ! -L "$APP_APK" ]] || fail_run "android_build" "app_apk_missing_or_symbolic"
[[ -f "$TEST_APK" && ! -L "$TEST_APK" ]] || fail_run "android_build" "test_apk_missing_or_symbolic"
[[ -x "$HOST_EXECUTABLE" && ! -L "$HOST_EXECUTABLE" ]] \
  || fail_run "mac_build" "formal_host_missing_or_symbolic"
[[ -f "$MERGED_MANIFEST" && ! -L "$MERGED_MANIFEST" ]] \
  || fail_run "android_build" "merged_manifest_missing_or_symbolic"

skybridge_require_frozen_git_source \
  "$RELEASE_REPO_ROOT" "$EXPECTED_SOURCE_COMMIT" "formal post-build verification" \
  || fail_run "source_freeze" "source_changed_during_build"
android_collect_apk_provenance "$APP_APK" app_debug_apk >"$APP_PROVENANCE" \
  || fail_run "artifact_binding" "app_apk_provenance_failed"
android_collect_apk_provenance "$TEST_APK" android_test_apk >"$TEST_PROVENANCE" \
  || fail_run "artifact_binding" "test_apk_provenance_failed"
python3 "$VALIDATOR" artifact \
  --path "$HOST_EXECUTABLE" \
  --prefix mac_formal_host \
  --output "$HOST_PROVENANCE_BEFORE" \
  || fail_run "artifact_binding" "mac_host_provenance_failed"
python3 "$VALIDATOR" manifest \
  --manifest "$MERGED_MANIFEST" \
  --output "$MANIFEST_BINDING" \
  || fail_run "android_manifest" "automatic_start_entry_present_or_unverifiable"
python3 "$VALIDATOR" private-copy \
  --kind token \
  --maximum-bytes 16384 \
  --input "$SOURCE_TOKEN_FILE" \
  --output "$TOKEN_FILE" >"$TOKEN_PROPERTIES" \
  || fail_run "auth_context" "private_short_jwt_invalid"
python3 "$VALIDATOR" auth-context \
  --token-file "$TOKEN_FILE" \
  --tenant-id "$TENANT_ID" \
  --output "$AUTH_CONTEXT" \
  || fail_run "auth_context" "private_auth_context_creation_failed"
python3 "$VALIDATOR" artifact \
  --path "$AUTH_CONTEXT" \
  --prefix android_auth_context \
  --output "$AUTH_CONTEXT_PROVENANCE" \
  || fail_run "auth_context" "auth_context_provenance_failed"

APP_APK_SHA256="$(property_value "$APP_PROVENANCE" app_debug_apk_sha256)" \
  || fail_run "artifact_binding" "app_apk_digest_missing"
TEST_APK_SHA256="$(property_value "$TEST_PROVENANCE" android_test_apk_sha256)" \
  || fail_run "artifact_binding" "test_apk_digest_missing"
APP_APK_BYTES="$(property_value "$APP_PROVENANCE" app_debug_apk_bytes)" \
  || fail_run "artifact_binding" "app_apk_bytes_missing"
TEST_APK_BYTES="$(property_value "$TEST_PROVENANCE" android_test_apk_bytes)" \
  || fail_run "artifact_binding" "test_apk_bytes_missing"

android_installed_package_path "$ADB_BIN" "$DEVICE_SERIAL" "$APP_PACKAGE" >/dev/null \
  || fail_run "android_preoverlay" "existing_main_package_required"
android_require_package_process_absent "$ADB_BIN" "$DEVICE_SERIAL" "$APP_PACKAGE" \
  || fail_run "android_preoverlay" "main_process_must_be_normally_closed"
android_require_package_absent "$ADB_BIN" "$DEVICE_SERIAL" "$TEST_PACKAGE" \
  || fail_run "android_preoverlay" "dedicated_test_package_preexisted"

collect_android_sensitive_snapshot() {
  local output="$1"
  local remote_script=""
  remote_script="$(sed -e 's/^[[:space:]]*//' <<'SH'
set -eu
uid="$(id -u)"
snapshot() {
key="$1"
path="$2"
test -f "$path"
test ! -L "$path"
before="$(stat -c '%d:%i:%h:%s:%Y' "$path")"
set -- $(sha256sum "$path")
digest="$1"
after="$(stat -c '%d:%i:%h:%s:%Y' "$path")"
test "$before" = "$after"
without_mtime="${before%:*}"
bytes="${without_mtime##*:}"
without_size="${without_mtime%:*}"
links="${without_size##*:}"
case "$bytes:$links:$digest" in *[!0-9a-f:]*|:*|*:) exit 42;; esac
test "$links" = 1
printf "%s_bytes=%s\n%s_sha256=%s\n" "$key" "$bytes" "$key" "$digest"
}
printf "uid=%s\n" "$uid"
snapshot p2p_identity __DEVICE_PROTECTED__/shared_prefs/skybridge_p2p_identity.xml
snapshot pqc_keys __DEVICE_PROTECTED__/shared_prefs/skybridge_pqc_keys.xml
snapshot peer_kem_keys __CREDENTIAL_PROTECTED__/shared_prefs/skybridge_peer_kem_keys.xml
SH
)"
  remote_script="${remote_script//__DEVICE_PROTECTED__//data/user_de/$ANDROID_USER_ID/$APP_PACKAGE}"
  remote_script="${remote_script//__CREDENTIAL_PROTECTED__//data/user/$ANDROID_USER_ID/$APP_PACKAGE}"
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "$(remote_shell_join run-as "$APP_PACKAGE" sh -c "$remote_script")" \
    | python3 "$VALIDATOR" android-sensitive --output "$output"
}

collect_android_sensitive_snapshot "$SENSITIVE_BEFORE" \
  || fail_run "android_preoverlay" "raw_sensitive_state_snapshot_failed"

"$ADB_BIN" -s "$DEVICE_SERIAL" wait-for-device \
  || fail_run "android_install" "device_wait_failed"
MAIN_OVERLAY_ATTEMPTED="true"
set +e
MAIN_INSTALL_OUTPUT="$(
  "$ADB_BIN" -s "$DEVICE_SERIAL" install --no-streaming -r -t "$APP_APK" 2>&1
)"
MAIN_INSTALL_STATUS=$?
set -e
printf '%s\n' "$MAIN_INSTALL_OUTPUT" >"$ANDROID_INSTALL_LOG"
if (( MAIN_INSTALL_STATUS != 0 )); then
  fail_run "android_install" "main_overlay_install_failed"
fi
android_require_exact_install_success_output \
  "$MAIN_INSTALL_OUTPUT" "$APP_APK" "$APP_APK_BYTES" "Android main overlay install" \
  || fail_run "android_install" "main_overlay_install_ambiguous"
android_require_package_process_absent "$ADB_BIN" "$DEVICE_SERIAL" "$APP_PACKAGE" \
  || fail_run "android_install" "main_process_started_during_overlay"

TEST_PACKAGE_STATE="install_attempted"
set +e
TEST_INSTALL_OUTPUT="$(
  "$ADB_BIN" -s "$DEVICE_SERIAL" install --no-streaming -t "$TEST_APK" 2>&1
)"
TEST_INSTALL_STATUS=$?
set -e
printf '%s\n' "$TEST_INSTALL_OUTPUT" >"$ANDROID_TEST_INSTALL_LOG"
if (( TEST_INSTALL_STATUS != 0 )) || ! android_require_exact_install_success_output \
  "$TEST_INSTALL_OUTPUT" "$TEST_APK" "$TEST_APK_BYTES" "dedicated Android test install"; then
  fail_run "android_install" "dedicated_test_install_failed_or_ambiguous"
fi
TEST_PACKAGE_STATE="owned"
android_require_installed_apk_digest \
  "$ADB_BIN" "$DEVICE_SERIAL" "$APP_PACKAGE" "$APP_APK_SHA256" \
  || fail_run "android_install" "installed_main_apk_digest_mismatch"
android_require_installed_apk_digest \
  "$ADB_BIN" "$DEVICE_SERIAL" "$TEST_PACKAGE" "$TEST_APK_SHA256" \
  || fail_run "android_install" "installed_test_apk_digest_mismatch"
{
  android_collect_installed_apk_binding \
    "$ADB_BIN" "$DEVICE_SERIAL" "$APP_PACKAGE" "$APP_APK_SHA256" app
  android_collect_installed_apk_binding \
    "$ADB_BIN" "$DEVICE_SERIAL" "$TEST_PACKAGE" "$TEST_APK_SHA256" test
} >"$INSTALLED_BEFORE" \
  || fail_run "android_install" "installed_apk_binding_failed"

REMOTE_STAGE_COMMAND="set -eu; umask 077; mkdir -p files; test ! -e files/$AUTH_CONTEXT_FILE_NAME; test ! -e files/$CODE_FILE_NAME; set -C; cat > files/$AUTH_CONTEXT_FILE_NAME; chmod 600 files/$AUTH_CONTEXT_FILE_NAME"
if ! python3 "$VALIDATOR" private-emit --path "$AUTH_CONTEXT" \
  | "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "$(remote_shell_join run-as "$TEST_PACKAGE" sh -c "$REMOTE_STAGE_COMMAND")" >/dev/null; then
  fail_run "auth_context" "android_auth_context_stage_failed"
fi
ANDROID_CONTEXT_STAGED="true"
EXPECTED_AUTH_SHA="$(property_value "$AUTH_CONTEXT_PROVENANCE" android_auth_context_sha256)" \
  || fail_run "auth_context" "auth_context_digest_missing"
REMOTE_AUTH_DIGEST="$(
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "$(remote_shell_join run-as "$TEST_PACKAGE" sha256sum "files/$AUTH_CONTEXT_FILE_NAME")" \
    | tr -d '\r'
)" || fail_run "auth_context" "android_auth_context_hash_failed"
if [[ ! "$REMOTE_AUTH_DIGEST" =~ ^([0-9a-f]{64})[[:space:]]+files/$AUTH_CONTEXT_FILE_NAME$ ]] \
    || [[ "${BASH_REMATCH[1]}" != "$EXPECTED_AUTH_SHA" ]]; then
  fail_run "auth_context" "android_auth_context_digest_mismatch"
fi

{
  echo "script=scripts/run_android_mac_webrtc_formal_smoke.sh"
  echo "source_commit=$EXPECTED_SOURCE_COMMIT"
  echo "run_ref=$RUN_REF"
  echo "device_profile=samsung-physical-api36-4k"
  echo "signaling_scheme=wss"
  echo "suite_wire_id=0x0101"
  echo "test_package=$TEST_PACKAGE"
  echo "main_install=overlay-preserve-data"
  echo "main_destructive_cleanup_authorized=false"
  echo "android_timeout_seconds=$ANDROID_TIMEOUT_SECONDS"
  echo "host_timeout_seconds=$HOST_TIMEOUT_SECONDS"
  echo "file_transfer_timeout_seconds=$FILE_TRANSFER_TIMEOUT_SECONDS"
} >"$COMMAND_FILE"

ANDROID_ARGS=(
  am instrument -w --user "$ANDROID_USER_ID"
  -e class "$TEST_CLASS"
  -e skybridgeWsUrl "$SIGNALING_WSS_URL"
  -e skybridgeTimeoutSeconds "$ANDROID_TIMEOUT_SECONDS"
  -e skybridgePqcEnabled true
  -e skybridgePqcMinimumTier nativePQC
  -e skybridgeExpectQPeriapt false
  -e skybridgeExpectedNegotiatedSuite MLKEM_768
  -e skybridgeExpectFileTransfer true
  -e skybridgeExpectBidirectionalFileTransfer true
  -e skybridgeAndroidToPeerTransferId "$ANDROID_TO_MAC_TRANSFER_ID"
  -e skybridgePeerToAndroidTransferId "$MAC_TO_ANDROID_TRANSFER_ID"
  -e skybridgeFileTransferTimeoutSeconds "$FILE_TRANSFER_TIMEOUT_SECONDS"
  -e skybridgePostSuccessHoldMillis "$POST_SUCCESS_HOLD_MILLIS"
  -e skybridgeAuthContextFile "$AUTH_CONTEXT_FILE_NAME"
  -e skybridgeCodeOutputFile "$CODE_FILE_NAME"
  -e skybridgeClientVersion 1.0.2
  -e skybridgeProtocolVersion 1
  -e skybridgeRequireDirectRoute false
  -e skybridgeUseDedicatedTestStorage true
  -e skybridgeExpectedStoragePackage "$TEST_PACKAGE"
  -e skybridgeSmokeRunRef "$RUN_REF"
  "$TEST_RUNNER"
)
(
  "$ADB_BIN" -s "$DEVICE_SERIAL" shell "$(remote_shell_join "${ANDROID_ARGS[@]}")"
) >"$ANDROID_INSTRUMENTATION_LOG" 2>&1 &
ANDROID_PID=$!
ANDROID_STARTED="true"
ANDROID_QUIESCENT="false"

CODE_READY="false"
for _ in $(seq 1 $((ANDROID_TIMEOUT_SECONDS * 4))); do
  if ! kill -0 "$ANDROID_PID" >/dev/null 2>&1; then
    wait "$ANDROID_PID" >/dev/null 2>&1 || true
    ANDROID_PID=""
    ANDROID_QUIESCENT="true"
    fail_run "android_code" "instrumentation_exited_before_code"
  fi
  if "$ADB_BIN" -s "$DEVICE_SERIAL" shell \
    "$(remote_shell_join run-as "$TEST_PACKAGE" sh -c "test -s files/$CODE_FILE_NAME")" \
    >/dev/null 2>&1; then
    CODE_READY="true"
    break
  fi
  sleep 0.25
done
[[ "$CODE_READY" == "true" ]] || fail_run "android_code" "connection_code_timeout"

if ! "$ADB_BIN" -s "$DEVICE_SERIAL" exec-out \
  run-as "$TEST_PACKAGE" cat "files/$CODE_FILE_NAME" \
  | python3 "$VALIDATOR" private-create \
    --kind code \
    --maximum-bytes 256 \
    --output "$CODE_FILE" >"$CODE_PROPERTIES"; then
  fail_run "android_code" "private_connection_code_capture_failed"
fi

EXISTING_HOST_PIDS="$(
  python3 "$PROCESS_HELPER" mac-list-exact --expected-executable "$HOST_EXECUTABLE"
)" || fail_run "mac_process" "process_absence_unverifiable"
[[ -z "$EXISTING_HOST_PIDS" ]] || fail_run "mac_process" "preexisting_formal_host_process"
if [[ -e "$MAC_RUN_PAYLOAD_DIR" || -L "$MAC_RUN_PAYLOAD_DIR" ]]; then
  fail_run "mac_payload" "run_payload_path_preexisted"
fi

"$HOST_EXECUTABLE" \
  --signaling-wss-url "$SIGNALING_WSS_URL" \
  --token-file "$TOKEN_FILE" \
  --tenant-id "$TENANT_ID" \
  --run-ref "$RUN_REF" \
  --android-to-mac-transfer-id "$ANDROID_TO_MAC_TRANSFER_ID" \
  --mac-to-android-transfer-id "$MAC_TO_ANDROID_TRANSFER_ID" \
  --connect-code-file "$CODE_FILE" \
  --result-output "$MAC_RESULT" \
  --timeout-seconds "$HOST_TIMEOUT_SECONDS" \
  --hold-seconds "$HOST_HOLD_SECONDS" >"$HOST_STDOUT" 2>"$HOST_STDERR" &
HOST_PID=$!
HOST_STARTED="true"
HOST_QUIESCENT="false"
python3 "$PROCESS_HELPER" mac-capture \
  --pid "$HOST_PID" \
  --expected-executable "$HOST_EXECUTABLE" \
  --output "$MAC_PROCESS_IDENTITY" \
  || fail_run "mac_process" "exact_child_ownership_capture_failed"
HOST_OWNERSHIP_CAPTURED="true"

OVERALL_DEADLINE=$((SECONDS + ANDROID_TIMEOUT_SECONDS + HOST_TIMEOUT_SECONDS + 30))
while :; do
  ANDROID_ALIVE="false"
  HOST_ALIVE="false"
  [[ -n "$ANDROID_PID" ]] && kill -0 "$ANDROID_PID" >/dev/null 2>&1 && ANDROID_ALIVE="true"
  [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" >/dev/null 2>&1 && HOST_ALIVE="true"
  if [[ "$ANDROID_ALIVE" == "false" && "$HOST_ALIVE" == "false" ]]; then
    break
  fi
  (( SECONDS < OVERALL_DEADLINE )) || fail_run "runtime" "formal_transaction_timeout"
  sleep 0.25
done

set +e
wait "$ANDROID_PID"
ANDROID_EXIT=$?
wait "$HOST_PID"
HOST_EXIT=$?
set -e
ANDROID_PID=""
HOST_PID=""
ANDROID_QUIESCENT="true"
HOST_QUIESCENT="true"
if (( ANDROID_EXIT != 0 )); then
  fail_run "android_runtime" "instrumentation_failed"
fi
if (( HOST_EXIT != 0 )); then
  fail_run "mac_runtime" "formal_host_failed"
fi
MAC_EXIT_VERIFIED="true"

set +e
python3 "$PROCESS_HELPER" mac-status --identity "$MAC_PROCESS_IDENTITY" >/dev/null 2>&1
MAC_STATUS=$?
set -e
if (( MAC_STATUS != 1 )); then
  fail_run "mac_process" "exact_child_exit_unverifiable"
fi
MAC_PROCESS_CLEANUP_VERIFIED="true"
if [[ -e "$MAC_RUN_PAYLOAD_DIR" || -L "$MAC_RUN_PAYLOAD_DIR" ]]; then
  fail_run "mac_payload" "run_owned_payload_cleanup_unproven"
fi
MAC_PAYLOAD_CLEANUP_VERIFIED="true"
android_require_package_process_absent "$ADB_BIN" "$DEVICE_SERIAL" "$APP_PACKAGE" \
  || fail_run "android_process" "main_process_remained_after_instrumentation"
ANDROID_APP_EXIT_VERIFIED="true"

[[ -f "$MAC_RESULT" && ! -L "$MAC_RESULT" ]] \
  || fail_run "mac_evidence" "typed_result_missing_or_symbolic"
python3 "$VALIDATOR" secret-scan \
  --token-file "$TOKEN_FILE" \
  --code-file "$CODE_FILE" \
  --scan-file "$ANDROID_INSTRUMENTATION_LOG" \
  --scan-file "$HOST_STDOUT" \
  --scan-file "$HOST_STDERR" \
  || fail_run "secret_scan" "runtime_log_contains_private_auth_or_code"

android_require_exact_device "$ADB_BIN" "$DEVICE_SERIAL" \
  || fail_run "postflight" "android_transport_changed"
android_collect_samsung_4k_device_binding "$ADB_BIN" "$DEVICE_SERIAL" >"$DEVICE_AFTER" \
  || fail_run "postflight" "android_device_binding_failed"
cmp -s -- "$DEVICE_BEFORE" "$DEVICE_AFTER" \
  || fail_run "postflight" "android_device_binding_changed"
android_require_apk_provenance_unchanged \
  "$APP_APK" app_debug_apk "$APP_PROVENANCE" \
  || fail_run "postflight" "app_apk_changed"
android_require_apk_provenance_unchanged \
  "$TEST_APK" android_test_apk "$TEST_PROVENANCE" \
  || fail_run "postflight" "test_apk_changed"
python3 "$VALIDATOR" artifact \
  --path "$HOST_EXECUTABLE" \
  --prefix mac_formal_host \
  --output "$HOST_PROVENANCE_AFTER" \
  || fail_run "postflight" "mac_host_provenance_failed"
cmp -s -- "$HOST_PROVENANCE_BEFORE" "$HOST_PROVENANCE_AFTER" \
  || fail_run "postflight" "mac_host_changed"
skybridge_require_frozen_git_source \
  "$RELEASE_REPO_ROOT" "$EXPECTED_SOURCE_COMMIT" "formal post-device verification" \
  || fail_run "source_freeze" "source_changed_during_device_run"
skybridge_collect_frozen_git_binding \
  "$RELEASE_REPO_ROOT" "$EXPECTED_SOURCE_COMMIT" after >"$SOURCE_AFTER" \
  || fail_run "source_freeze" "source_after_binding_failed"
android_require_installed_apk_digest \
  "$ADB_BIN" "$DEVICE_SERIAL" "$APP_PACKAGE" "$APP_APK_SHA256" \
  || fail_run "postflight" "installed_main_apk_changed"
android_require_installed_apk_digest \
  "$ADB_BIN" "$DEVICE_SERIAL" "$TEST_PACKAGE" "$TEST_APK_SHA256" \
  || fail_run "postflight" "installed_test_apk_changed"
{
  android_collect_installed_apk_binding \
    "$ADB_BIN" "$DEVICE_SERIAL" "$APP_PACKAGE" "$APP_APK_SHA256" app
  android_collect_installed_apk_binding \
    "$ADB_BIN" "$DEVICE_SERIAL" "$TEST_PACKAGE" "$TEST_APK_SHA256" test
} >"$INSTALLED_AFTER" \
  || fail_run "postflight" "installed_apk_binding_failed"
cmp -s -- "$INSTALLED_BEFORE" "$INSTALLED_AFTER" \
  || fail_run "postflight" "installed_apk_binding_changed"

remove_android_context \
  || fail_run "cleanup" "android_auth_or_code_cleanup_failed"
remove_owned_test_package \
  || fail_run "cleanup" "dedicated_test_package_cleanup_failed"
collect_android_sensitive_snapshot "$SENSITIVE_AFTER" \
  || fail_run "postflight" "raw_sensitive_state_postflight_failed"
cmp -s -- "$SENSITIVE_BEFORE" "$SENSITIVE_AFTER" \
  || fail_run "postflight" "main_uid_or_sensitive_state_changed_since_preoverlay"

unlink_private "$CODE_FILE" "$CODE_PROPERTIES" "" \
  || fail_run "cleanup" "connection_code_exact_unlink_failed"
unlink_private "$AUTH_CONTEXT" "$AUTH_CONTEXT_PROVENANCE" "android_auth_context_" \
  || fail_run "cleanup" "auth_context_exact_unlink_failed"
unlink_private "$TOKEN_FILE" "$TOKEN_PROPERTIES" "" \
  || fail_run "cleanup" "token_exact_unlink_failed"
PRIVATE_FILE_CLEANUP_VERIFIED="true"

python3 "$VALIDATOR" receipt \
  --source-commit "$EXPECTED_SOURCE_COMMIT" \
  --run-ref "$RUN_REF" \
  --source-binding-before "$SOURCE_BEFORE" \
  --source-binding-after "$SOURCE_AFTER" \
  --app-apk-provenance "$APP_PROVENANCE" \
  --test-apk-provenance "$TEST_PROVENANCE" \
  --host-provenance-before "$HOST_PROVENANCE_BEFORE" \
  --host-provenance-after "$HOST_PROVENANCE_AFTER" \
  --android-device-before "$DEVICE_BEFORE" \
  --android-device-after "$DEVICE_AFTER" \
  --android-installed-before "$INSTALLED_BEFORE" \
  --android-installed-after "$INSTALLED_AFTER" \
  --android-sensitive-before "$SENSITIVE_BEFORE" \
  --android-sensitive-after "$SENSITIVE_AFTER" \
  --manifest-binding "$MANIFEST_BINDING" \
  --android-instrumentation "$ANDROID_INSTRUMENTATION_LOG" \
  --mac-result "$MAC_RESULT" \
  --mac-process-identity "$MAC_PROCESS_IDENTITY" \
  --android-app-exit-verified "$ANDROID_APP_EXIT_VERIFIED" \
  --test-package-cleanup-verified "$TEST_PACKAGE_CLEANUP_VERIFIED" \
  --android-context-cleanup-verified "$ANDROID_CONTEXT_CLEANUP_VERIFIED" \
  --private-file-cleanup-verified "$PRIVATE_FILE_CLEANUP_VERIFIED" \
  --mac-process-cleanup-verified "$MAC_PROCESS_CLEANUP_VERIFIED" \
  --mac-exit-verified "$MAC_EXIT_VERIFIED" \
  --mac-payload-cleanup-verified "$MAC_PAYLOAD_CLEANUP_VERIFIED" \
  --output "$RECEIPT_CANDIDATE" \
  || fail_run "receipt" "typed_formal_evidence_rejected"

release_device_lock_after_quiescence \
  || fail_run "cleanup" "device_lock_release_failed"

mv -f -- "$RECEIPT_CANDIDATE" "$RECEIPT" \
  || fail_run "receipt" "typed_formal_evidence_publish_failed"
trap - EXIT INT TERM HUP

{
  echo "status=success"
  echo "source_commit=$EXPECTED_SOURCE_COMMIT"
  echo "run_ref=$RUN_REF"
  echo "receipt=$RECEIPT"
  echo "main_app_overlay_only=true"
  echo "main_app_data_preserved=true"
  echo "dedicated_test_package_removed=true"
  echo "android_to_macos_bidirectional_durable_transfer=true"
  echo "suite_wire_id=0x0101"
} >"$SUMMARY_FILE"
echo "Android -> macOS formal WebRTC evidence accepted: $RECEIPT"
