#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/android_env.sh
source "$ROOT_DIR/scripts/lib/android_env.sh"
# shellcheck source=scripts/lib/source_provenance.sh
source "$ROOT_DIR/scripts/lib/source_provenance.sh"
# shellcheck source=scripts/lib/strict_gradle_output.sh
source "$ROOT_DIR/scripts/lib/strict_gradle_output.sh"

VALIDATOR="$ROOT_DIR/scripts/validate_android_pqc_native_runtime_evidence.py"
GRADLEW="$ROOT_DIR/gradlew"
APP_APK="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"
TEST_APK="$ROOT_DIR/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
APP_PACKAGE="com.skybridge.compass.debug"
TEST_PACKAGE="com.skybridge.compass.debug.nativepqc.test"
TEST_RUNNER="com.skybridge.compass.android.HiltTestRunner"
TEST_CLASS="com.skybridge.compass.android.crypto.NativePqcRuntimeInstrumentationTest"
INSTRUMENTATION_COMPONENT="$TEST_PACKAGE/$TEST_RUNNER"

SAMSUNG_SERIAL=""
API37_SERIAL=""
API37_ABI=""
EXPECTED_SOURCE_COMMIT=""
EVIDENCE_DIR=""
ADB_BIN=""
GIT_ROOT=""
PRIVATE_DIR=""
LANE_LOCK_DIR=""
LANE_LOCK_ACQUIRED=0
BUILD_STARTED=0
GRADLE_STOPPED=0
EVIDENCE_CREATED=0
SESSION_COMPLETE=0
SAMSUNG_TEST_PACKAGE_STATE="untouched"
API37_TEST_PACKAGE_STATE="untouched"

usage() {
  cat <<'USAGE'
Build and run one source-bound Android native-PQC runtime matrix.

Usage:
  run_android_pqc_native_runtime_gate.sh \
    --samsung-api36-4k-serial <exact-adb-serial> \
    --api37-16k-serial <exact-adb-serial> \
    --api37-16k-abi <arm64-v8a|x86_64> \
    --expected-source-commit <40-lowercase-hex> \
    --evidence-dir <new-absolute-directory> \
    [--adb <absolute-adb-path>]

The runner requires a clean frozen revision, builds the canonical debug app
and instrumentation APKs exactly once, then installs that same pair
sequentially on the API 36 / 4K and API 37 / 16K runtimes. No AVD is started.
USAGE
}

fail() {
  echo "Android native PQC runtime gate failed: $*" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --samsung-api36-4k-serial) SAMSUNG_SERIAL="${2:-}"; shift 2 ;;
    --api37-16k-serial) API37_SERIAL="${2:-}"; shift 2 ;;
    --api37-16k-abi) API37_ABI="${2:-}"; shift 2 ;;
    --expected-source-commit) EXPECTED_SOURCE_COMMIT="${2:-}"; shift 2 ;;
    --evidence-dir) EVIDENCE_DIR="${2:-}"; shift 2 ;;
    --adb) ADB_BIN="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for serial in "$SAMSUNG_SERIAL" "$API37_SERIAL"; do
  [[ "$serial" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || {
    fail "both target serials must be explicit safe adb serials"
  }
done
[[ "$SAMSUNG_SERIAL" != "$API37_SERIAL" ]] || fail "the two runtime profiles require distinct serials"
[[ "$API37_ABI" == "arm64-v8a" || "$API37_ABI" == "x86_64" ]] || {
  fail "--api37-16k-abi must be arm64-v8a or x86_64"
}
[[ "$EXPECTED_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  fail "--expected-source-commit must be a full lowercase Git revision"
}
[[ "$EVIDENCE_DIR" == /* && ! -e "$EVIDENCE_DIR" && ! -L "$EVIDENCE_DIR" ]] || {
  fail "--evidence-dir must be a new absolute path"
}
EVIDENCE_PARENT="$(dirname "$EVIDENCE_DIR")"
[[ -d "$EVIDENCE_PARENT" && ! -L "$EVIDENCE_PARENT" ]] || {
  fail "the evidence parent must be an existing non-symbolic-link directory"
}
if [[ -z "$ADB_BIN" ]]; then
  if ! ADB_BIN="$(resolve_adb_bin "$ROOT_DIR")"; then
    fail "unable to resolve adb from the controlled Android environment"
  fi
fi
[[ "$ADB_BIN" == /* && -x "$ADB_BIN" && -f "$ADB_BIN" && ! -L "$ADB_BIN" ]] || {
  fail "adb must resolve to an absolute executable regular file"
}
[[ -x "$GRADLEW" && -f "$GRADLEW" && ! -L "$GRADLEW" ]] || fail "Gradle wrapper is missing"
[[ -f "$VALIDATOR" && ! -L "$VALIDATOR" ]] || fail "native PQC evidence validator is missing"

if [[ ! -f "$ROOT_DIR/local.properties" ]]; then
  GRADLE_SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$GRADLE_SDK_ROOT" ]]; then
    ADB_PARENT="$(cd "$(dirname "$ADB_BIN")" && pwd -P)"
    GRADLE_SDK_ROOT="$(cd "$ADB_PARENT/.." && pwd -P)"
  fi
  [[ -d "$GRADLE_SDK_ROOT/platforms" && -d "$GRADLE_SDK_ROOT/build-tools" ]] || {
    fail "unable to derive a complete Android SDK for the fixed Gradle build"
  }
  export ANDROID_HOME="$GRADLE_SDK_ROOT"
  export ANDROID_SDK_ROOT="$GRADLE_SDK_ROOT"
fi

GIT_ROOT="$(git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null)" || {
  fail "unable to resolve the canonical Git worktree"
}

require_frozen_source() {
  local phase="$1"
  local actual_commit=""
  local worktree_status=""

  actual_commit="$(git -C "$GIT_ROOT" rev-parse --verify HEAD 2>/dev/null)" || {
    fail "unable to resolve the source revision during $phase"
  }
  [[ "$actual_commit" == "$EXPECTED_SOURCE_COMMIT" ]] || {
    fail "the source revision changed or does not match during $phase"
  }
  worktree_status="$(git -C "$GIT_ROOT" status --porcelain=v1 --untracked-files=all)" || {
    fail "unable to inspect the source tree during $phase"
  }
  [[ -z "$worktree_status" ]] || {
    fail "the native PQC physical gate requires a clean frozen source tree during $phase"
  }
}

require_frozen_source "pre-build verification"

PRIVATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-pqc-native-runtime.XXXXXX")"
chmod 0700 "$PRIVATE_DIR"

test_package_state() {
  local serial="$1"
  case "$serial" in
    "$SAMSUNG_SERIAL") printf '%s\n' "$SAMSUNG_TEST_PACKAGE_STATE" ;;
    "$API37_SERIAL") printf '%s\n' "$API37_TEST_PACKAGE_STATE" ;;
    *) return 1 ;;
  esac
}

set_test_package_state() {
  local serial="$1"
  local state="$2"
  case "$state" in
    untouched|baseline_absent|install_attempted|owned_installed|cleaned|ownership_ambiguous) ;;
    *) fail "refusing to record an invalid test-package ownership state" ;;
  esac
  case "$serial" in
    "$SAMSUNG_SERIAL") SAMSUNG_TEST_PACKAGE_STATE="$state" ;;
    "$API37_SERIAL") API37_TEST_PACKAGE_STATE="$state" ;;
    *) fail "refusing to track an unexpected adb serial for cleanup" ;;
  esac
}

acquire_lane_lock() {
  local common_git_dir=""
  common_git_dir="$(git -C "$GIT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    fail "unable to resolve the common Git directory for the native-PQC lane lock"
  }
  [[ "$common_git_dir" == /* && -d "$common_git_dir" && ! -L "$common_git_dir" ]] || {
    fail "the common Git directory is not a trusted absolute directory"
  }
  LANE_LOCK_DIR="$common_git_dir/skybridge-native-pqc-runtime.lock"
  if ! mkdir -m 0700 -- "$LANE_LOCK_DIR" 2>/dev/null; then
    fail "another native-PQC runtime matrix owns the repository lane lock"
  fi
  LANE_LOCK_ACQUIRED=1
}

release_lane_lock() {
  [[ "$LANE_LOCK_ACQUIRED" == "1" ]] || return 0
  if ! rmdir "$LANE_LOCK_DIR"; then
    return 1
  fi
  LANE_LOCK_ACQUIRED=0
}

stop_gradle() {
  local stop_log="$PRIVATE_DIR/gradle-stop.log"
  local stop_status=0

  if "$GRADLEW" --stop >"$stop_log" 2>&1; then
    stop_status=0
  else
    stop_status=$?
  fi
  if (( stop_status != 0 )); then
    echo "Gradle normal stop failed with status $stop_status" >&2
    return "$stop_status"
  fi
  if ! skybridge_require_zero_warning_tool_log "$stop_log"; then
    echo "Gradle normal stop emitted a warning" >&2
    return 1
  fi
  GRADLE_STOPPED=1
}

cleanup() {
  local status=$?
  local stop_status=0
  local test_cleanup_status=0
  local state=""
  trap - EXIT
  set +e
  if [[ "$BUILD_STARTED" == "1" && "$GRADLE_STOPPED" != "1" ]]; then
    stop_gradle
    stop_status=$?
    if (( status == 0 && stop_status != 0 )); then
      status=$stop_status
    fi
  fi
  if { [[ "$SESSION_COMPLETE" != "1" ]] || (( status != 0 )); }; then
    state="$(test_package_state "$SAMSUNG_SERIAL")"
    case "$state" in
      install_attempted|owned_installed)
        remove_run_test_package_after_target_exit \
          "samsung-api36-4k" "$SAMSUNG_SERIAL" "failure cleanup" || test_cleanup_status=1
        ;;
      ownership_ambiguous)
        echo "Samsung test-package ownership is ambiguous; refusing destructive cleanup" >&2
        test_cleanup_status=1
        ;;
      untouched|baseline_absent|cleaned) ;;
      *)
        echo "Samsung test-package ownership state is invalid: $state" >&2
        test_cleanup_status=1
        ;;
    esac

    state="$(test_package_state "$API37_SERIAL")"
    case "$state" in
      install_attempted|owned_installed)
        remove_run_test_package_after_target_exit \
          "api37-16k" "$API37_SERIAL" "failure cleanup" || test_cleanup_status=1
        ;;
      ownership_ambiguous)
        echo "API 37 test-package ownership is ambiguous; refusing destructive cleanup" >&2
        test_cleanup_status=1
        ;;
      untouched|baseline_absent|cleaned) ;;
      *)
        echo "API 37 test-package ownership state is invalid: $state" >&2
        test_cleanup_status=1
        ;;
    esac
    if (( status == 0 && test_cleanup_status != 0 )); then
      status=$test_cleanup_status
    fi
  fi
  if [[ "$EVIDENCE_CREATED" == "1" ]] \
      && { [[ "$SESSION_COMPLETE" != "1" ]] || (( status != 0 )); }; then
    /bin/rm -f -- "$EVIDENCE_DIR/native-pqc-runtime-evidence.json"
    rmdir "$EVIDENCE_DIR" >/dev/null 2>&1
  fi
  if [[ -n "$PRIVATE_DIR" && -d "$PRIVATE_DIR" ]]; then
    /bin/rm -rf -- "$PRIVATE_DIR"
  fi
  if [[ "$LANE_LOCK_ACQUIRED" == "1" ]]; then
    if ! release_lane_lock; then
      echo "Failed to release the native-PQC repository lane lock: $LANE_LOCK_DIR" >&2
      if (( status == 0 )); then
        status=1
      fi
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

acquire_lane_lock

for output_apk in "$APP_APK" "$TEST_APK"; do
  if [[ -e "$output_apk" || -L "$output_apk" ]]; then
    [[ ! -d "$output_apk" ]] || fail "canonical APK output path is unexpectedly a directory"
    /bin/rm -f -- "$output_apk"
  fi
done

BUILD_STARTED=1
if ! "$GRADLEW" \
    --no-daemon \
    --no-parallel \
    --max-workers=2 \
    --rerun-tasks \
    --warning-mode all \
    -PskybridgeNativePqcGateTestApplicationId="$TEST_PACKAGE" \
    :app:assembleDebug \
    :app:assembleDebugAndroidTest \
    2>&1 | tee "$PRIVATE_DIR/gradle-build.log"; then
  fail "canonical debug APK build failed"
fi
skybridge_require_zero_warning_tool_log "$PRIVATE_DIR/gradle-build.log" || {
  fail "canonical debug APK build emitted a warning"
}
require_frozen_source "post-build verification"

python3 - "$APP_APK" "$TEST_APK" <<'PY'
import re
import stat
import sys
import zipfile
from pathlib import Path

app_path, test_path = map(Path, sys.argv[1:])
for path, label in ((app_path, "app APK"), (test_path, "test APK")):
    metadata = path.stat(follow_symlinks=False)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size <= 0:
        raise SystemExit(f"{label} must be a nonempty single-link regular file")
    try:
        with zipfile.ZipFile(path) as archive:
            names = [entry.filename for entry in archive.infolist()]
            if len(names) != len(set(names)):
                raise SystemExit(f"{label} contains duplicate ZIP entries")
            if "AndroidManifest.xml" not in names:
                raise SystemExit(f"{label} is missing AndroidManifest.xml")
    except zipfile.BadZipFile as exc:
        raise SystemExit(f"{label} is not a valid APK ZIP") from exc

with zipfile.ZipFile(app_path) as archive:
    native_entries = {
        match.group(1): name
        for name in archive.namelist()
        if (match := re.fullmatch(r"lib/([^/]+)/libskybridge_pqc\.so", name))
    }
    if set(native_entries) != {"arm64-v8a", "x86_64"}:
        raise SystemExit("app APK does not contain the exact required native PQC ABI set")
    for abi, name in native_entries.items():
        if archive.getinfo(name).file_size <= 0:
            raise SystemExit(f"app APK contains an empty native PQC library for {abi}")
    if any(re.fullmatch(r"lib/[^/]+/liboqs\.so", name) for name in archive.namelist()):
        raise SystemExit("app APK unexpectedly packages a separate liboqs shared library")
PY

android_collect_apk_provenance "$APP_APK" app_apk >"$PRIVATE_DIR/app-apk.properties"
android_collect_apk_provenance "$TEST_APK" test_apk >"$PRIVATE_DIR/test-apk.properties"
APP_APK_SHA256="$(sed -n 's/^app_apk_sha256=//p' "$PRIVATE_DIR/app-apk.properties")"
APP_APK_BYTES="$(sed -n 's/^app_apk_bytes=//p' "$PRIVATE_DIR/app-apk.properties")"
TEST_APK_SHA256="$(sed -n 's/^test_apk_sha256=//p' "$PRIVATE_DIR/test-apk.properties")"
TEST_APK_BYTES="$(sed -n 's/^test_apk_bytes=//p' "$PRIVATE_DIR/test-apk.properties")"
[[ "$APP_APK_SHA256" =~ ^[0-9a-f]{64}$ && "$APP_APK_BYTES" =~ ^[1-9][0-9]*$ ]] || {
  fail "app APK provenance is malformed"
}
[[ "$TEST_APK_SHA256" =~ ^[0-9a-f]{64}$ && "$TEST_APK_BYTES" =~ ^[1-9][0-9]*$ ]] || {
  fail "test APK provenance is malformed"
}

require_apk_provenance_unchanged() {
  local current_app_sha256=""
  local current_app_bytes=""
  local current_test_sha256=""
  local current_test_bytes=""

  [[ -f "$APP_APK" && ! -L "$APP_APK" && -f "$TEST_APK" && ! -L "$TEST_APK" ]] || {
    fail "canonical APK outputs changed type after the fixed build"
  }
  android_collect_apk_provenance "$APP_APK" current_app_apk \
    >"$PRIVATE_DIR/current-app-apk.properties"
  android_collect_apk_provenance "$TEST_APK" current_test_apk \
    >"$PRIVATE_DIR/current-test-apk.properties"
  current_app_sha256="$(sed -n 's/^current_app_apk_sha256=//p' "$PRIVATE_DIR/current-app-apk.properties")"
  current_app_bytes="$(sed -n 's/^current_app_apk_bytes=//p' "$PRIVATE_DIR/current-app-apk.properties")"
  current_test_sha256="$(sed -n 's/^current_test_apk_sha256=//p' "$PRIVATE_DIR/current-test-apk.properties")"
  current_test_bytes="$(sed -n 's/^current_test_apk_bytes=//p' "$PRIVATE_DIR/current-test-apk.properties")"
  [[ "$current_app_sha256" == "$APP_APK_SHA256" && "$current_app_bytes" == "$APP_APK_BYTES" ]] || {
    fail "canonical app APK changed after the fixed build"
  }
  [[ "$current_test_sha256" == "$TEST_APK_SHA256" && "$current_test_bytes" == "$TEST_APK_BYTES" ]] || {
    fail "canonical test APK changed after the fixed build"
  }
}

mkdir -m 0700 -- "$EVIDENCE_DIR"
EVIDENCE_CREATED=1

capture_adb() {
  local profile="$1"
  local serial="$2"
  local output="$3"
  shift 3
  if ! "$ADB_BIN" -s "$serial" "$@" >"$output" 2>&1; then
    fail "$profile adb operation failed"
  fi
  tr -d '\r' <"$output"
}

single_line() {
  local input="$1"
  local label="$2"
  local value=""
  value="$(tr -d '\r' <"$input")"
  [[ -n "$value" && "$value" != *$'\n'* ]] || fail "$label did not return exactly one line"
  printf '%s\n' "$value"
}

require_install_success() {
  local input="$1"
  local label="$2"
  local expected_apk_path="$3"
  local expected_apk_bytes="$4"
  local output=""
  output="$(<"$input")" || fail "$label output could not be read"
  android_require_exact_install_success_output \
    "$output" "$expected_apk_path" "$expected_apk_bytes" "$label" \
    || fail "$label terminal was invalid"
}

require_installed_apk_digest() {
  local profile="$1"
  local serial="$2"
  local package_name="$3"
  local expected_digest="$4"
  local stem="$5"
  local path_output="$PRIVATE_DIR/$stem-path.txt"
  local digest_output="$PRIVATE_DIR/$stem-digest.txt"
  local package_line=""
  local remote_path=""
  local digest_line=""

  capture_adb "$profile" "$serial" "$path_output" shell pm path "$package_name" >/dev/null
  package_line="$(single_line "$path_output" "$profile installed package path")"
  [[ "$package_line" =~ ^package:(/data/app/[A-Za-z0-9_./=+~-]+/base\.apk)$ ]] || {
    fail "$profile installed package path is not one canonical base APK"
  }
  remote_path="${BASH_REMATCH[1]}"
  [[ "$remote_path" != *"/../"* && "$remote_path" != *"/./"* ]] || {
    fail "$profile installed package path is not canonical"
  }
  capture_adb "$profile" "$serial" "$digest_output" shell sha256sum "$remote_path" >/dev/null
  digest_line="$(single_line "$digest_output" "$profile installed APK digest")"
  [[ "$digest_line" =~ ^([0-9a-f]{64})[[:space:]]+([^[:space:]]+)$ ]] || {
    fail "$profile installed APK digest output is malformed"
  }
  [[ "${BASH_REMATCH[1]}" == "$expected_digest" && "${BASH_REMATCH[2]}" == "$remote_path" ]] || {
    fail "$profile installed APK bytes do not match the selected local APK"
  }
}

require_test_package_absent() {
  local profile="$1"
  local serial="$2"
  local phase="$3"

  android_require_package_absent "$ADB_BIN" "$serial" "$TEST_PACKAGE" || {
    fail "$profile test package was present or unverifiable during $phase; remove a preexisting package explicitly before retrying"
  }
  set_test_package_state "$serial" baseline_absent
}

reconcile_and_remove_run_test_package() {
  local profile="$1"
  local serial="$2"
  local phase="$3"
  local state=""
  local query_status=0

  state="$(test_package_state "$serial")" || {
    echo "$profile cleanup refused an unexpected adb serial during $phase" >&2
    return 1
  }
  if [[ "$state" == "install_attempted" ]]; then
    if android_installed_package_path "$ADB_BIN" "$serial" "$TEST_PACKAGE" >/dev/null; then
      set_test_package_state "$serial" ownership_ambiguous
      echo "$profile test package appeared after an unconfirmed install during $phase; refusing uninstall" >&2
      return 1
    else
      query_status=$?
    fi
    if (( query_status == 2 )); then
      set_test_package_state "$serial" cleaned
      return 0
    fi
    set_test_package_state "$serial" ownership_ambiguous
    echo "$profile could not prove test-package absence after an unconfirmed install during $phase; refusing uninstall" >&2
    return 1
  fi
  if [[ "$state" != "owned_installed" ]]; then
    echo "$profile cleanup refused non-owned test-package state $state during $phase" >&2
    return 1
  fi
  if ! android_remove_owned_package \
      "$ADB_BIN" "$serial" "$TEST_PACKAGE" "$TEST_APK_SHA256"; then
    set_test_package_state "$serial" ownership_ambiguous
    echo "$profile could not remove the confirmed run-owned test package during $phase" >&2
    return 1
  fi
  set_test_package_state "$serial" cleaned
}

remove_run_test_package_after_target_exit() {
  local profile="$1"
  local serial="$2"
  local phase="$3"

  if ! android_require_package_process_absent \
      "$ADB_BIN" "$serial" "$APP_PACKAGE"; then
    echo "$profile main app process is active or unverifiable during $phase; refusing concurrent test-package cleanup" >&2
    return 1
  fi
  reconcile_and_remove_run_test_package "$profile" "$serial" "$phase"
}

run_profile() {
  local profile="$1"
  local serial="$2"
  local expected_api="$3"
  local expected_page_size="$4"
  local expected_abi="$5"
  local require_physical_samsung="$6"
  local prefix="$PRIVATE_DIR/$profile"
  local state=""
  local self_serial=""
  local api=""
  local page_size=""
  local abi=""
  local manufacturer=""
  local manufacturer_lower=""
  local qemu=""
  local instrumentation=""

  capture_adb "$profile" "$serial" "$prefix-state.txt" get-state >/dev/null
  state="$(single_line "$prefix-state.txt" "$profile device state")"
  [[ "$state" == "device" ]] || fail "$profile target is not in adb device state"
  capture_adb "$profile" "$serial" "$prefix-serial.txt" get-serialno >/dev/null
  self_serial="$(single_line "$prefix-serial.txt" "$profile serial identity")"
  [[ "$self_serial" == "$serial" ]] || fail "$profile adb transport resolved a different serial"

  capture_adb "$profile" "$serial" "$prefix-api.txt" shell getprop ro.build.version.sdk >/dev/null
  api="$(single_line "$prefix-api.txt" "$profile API level")"
  capture_adb "$profile" "$serial" "$prefix-page-size.txt" shell getconf PAGE_SIZE >/dev/null
  page_size="$(single_line "$prefix-page-size.txt" "$profile page size")"
  capture_adb "$profile" "$serial" "$prefix-abi.txt" shell getprop ro.product.cpu.abi >/dev/null
  abi="$(single_line "$prefix-abi.txt" "$profile primary ABI")"
  [[ "$api" == "$expected_api" && "$page_size" == "$expected_page_size" && "$abi" == "$expected_abi" ]] || {
    fail "$profile API/page-size/ABI identity mismatch"
  }

  if [[ "$require_physical_samsung" == "1" ]]; then
    capture_adb "$profile" "$serial" "$prefix-manufacturer.txt" shell getprop ro.product.manufacturer >/dev/null
    manufacturer="$(single_line "$prefix-manufacturer.txt" "$profile manufacturer")"
    manufacturer_lower="$(
      printf '%s' "$manufacturer" | LC_ALL=C tr '[:upper:]' '[:lower:]'
    )" || fail "$profile manufacturer normalization failed"
    capture_adb "$profile" "$serial" "$prefix-qemu.txt" shell getprop ro.kernel.qemu >/dev/null
    qemu="$(tr -d '\r\n' <"$prefix-qemu.txt")"
    [[ "$manufacturer_lower" == "samsung" && "$qemu" != "1" ]] || {
      fail "$profile must be a physical Samsung runtime"
    }
  fi

  require_test_package_absent "$profile" "$serial" "profile preflight"
  android_require_package_process_absent "$ADB_BIN" "$serial" "$APP_PACKAGE" || {
    fail "$profile main app process must be closed normally before overlay installation"
  }
  capture_adb "$profile" "$serial" "$prefix-app-install.txt" \
    install --no-streaming -r -t "$APP_APK" >/dev/null
  require_install_success \
    "$prefix-app-install.txt" "$profile app APK installation" \
    "$APP_APK" "$APP_APK_BYTES"
  require_test_package_absent "$profile" "$serial" "test install boundary"
  set_test_package_state "$serial" install_attempted
  capture_adb "$profile" "$serial" "$prefix-test-install.txt" \
    install --no-streaming -t "$TEST_APK" >/dev/null
  require_install_success \
    "$prefix-test-install.txt" "$profile test APK installation" \
    "$TEST_APK" "$TEST_APK_BYTES"
  set_test_package_state "$serial" owned_installed

  require_installed_apk_digest "$profile" "$serial" "$TEST_PACKAGE" "$TEST_APK_SHA256" "$profile-test"
  require_installed_apk_digest "$profile" "$serial" "$APP_PACKAGE" "$APP_APK_SHA256" "$profile-app"
  capture_adb "$profile" "$serial" "$prefix-instrumentation-list.txt" \
    shell pm list instrumentation >/dev/null
  instrumentation="instrumentation:$INSTRUMENTATION_COMPONENT (target=$APP_PACKAGE)"
  [[ "$(rg -Fxc "$instrumentation" "$prefix-instrumentation-list.txt")" == "1" ]] || {
    fail "$profile exact instrumentation component is not installed"
  }

  capture_adb "$profile" "$serial" "$prefix-instrumentation.txt" \
    shell am instrument -w -r \
    -e class "$TEST_CLASS" \
    -e skybridgePqcRuntimeProfile "$profile" \
    -e skybridgeExpectedApi "$expected_api" \
    -e skybridgeExpectedPageSize "$expected_page_size" \
    -e skybridgeExpectedAbi "$expected_abi" \
    "$INSTRUMENTATION_COMPONENT" >/dev/null
  if rg -Fq -- "$serial" "$prefix-instrumentation.txt"; then
    fail "$profile instrumentation output exposed a device serial"
  fi
  remove_run_test_package_after_target_exit "$profile" "$serial" "normal completion" || {
    fail "$profile could not remove the run-owned test package"
  }
}

require_test_package_absent "samsung-api36-4k" "$SAMSUNG_SERIAL" "matrix preflight"
require_test_package_absent "api37-16k" "$API37_SERIAL" "matrix preflight"
run_profile "samsung-api36-4k" "$SAMSUNG_SERIAL" 36 4096 arm64-v8a 1
run_profile "api37-16k" "$API37_SERIAL" 37 16384 "$API37_ABI" 0

require_frozen_source "post-device verification"
require_apk_provenance_unchanged

python3 "$VALIDATOR" \
  --source-commit "$EXPECTED_SOURCE_COMMIT" \
  --app-apk-sha256 "$APP_APK_SHA256" \
  --app-apk-bytes "$APP_APK_BYTES" \
  --test-apk-sha256 "$TEST_APK_SHA256" \
  --test-apk-bytes "$TEST_APK_BYTES" \
  --samsung-output "$PRIVATE_DIR/samsung-api36-4k-instrumentation.txt" \
  --api37-output "$PRIVATE_DIR/api37-16k-instrumentation.txt" \
  --api37-abi "$API37_ABI" \
  --output "$EVIDENCE_DIR/native-pqc-runtime-evidence.json"

if rg -Fq -- "$SAMSUNG_SERIAL" "$EVIDENCE_DIR/native-pqc-runtime-evidence.json" \
    || rg -Fq -- "$API37_SERIAL" "$EVIDENCE_DIR/native-pqc-runtime-evidence.json"; then
  fail "public evidence exposed a device serial"
fi

stop_gradle || fail "Gradle normal stop failed"
release_lane_lock || fail "native-PQC repository lane lock release failed"
SESSION_COMPLETE=1
echo "Android native PQC runtime matrix passed: $EVIDENCE_DIR/native-pqc-runtime-evidence.json"
