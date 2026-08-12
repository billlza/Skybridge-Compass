#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/android_env.sh
source "$ANDROID_ROOT/scripts/lib/android_env.sh"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-android-env-test.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP"' EXIT
FAKE_ADB="$TEST_TMP/adb"
FAKE_STATE="$TEST_TMP/package-present"
EXPECTED_DIGEST="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

cat >"$FAKE_ADB" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-s" ]] || exit 90
serial="${2:-}"
shift 2
case "${1:-}" in
  get-state)
    printf '%s\n' "${FAKE_DEVICE_STATE:-device}"
    ;;
  get-serialno)
    printf '%s\n' "${FAKE_SELF_SERIAL:-$serial}"
    ;;
  shell)
    shift
    if [[ "${FAKE_TRANSPORT_FAILURE:-0}" == "1" ]]; then
      exit 1
    elif [[ "${1:-}" == "sh" && "${2:-}" == "-c" ]]; then
      remote_command="${3:-}"
      if [[ "$remote_command" == *'pm path '* ]]; then
        case "${FAKE_PM_MODE:-present}" in
          absent-exit-one) printf '\n%s\n' '__SKYBRIDGE_REMOTE_STATUS__=1' ;;
          absent-exit-zero) printf '\n%s\n' '__SKYBRIDGE_REMOTE_STATUS__=0' ;;
          failed) printf '%s\n' 'package manager unavailable' '__SKYBRIDGE_REMOTE_STATUS__=2' ;;
          stateful)
            if [[ -e "$FAKE_STATE" ]]; then
              printf '%s\n' 'package:/data/app/~~abc/com.example.test-def/base.apk' '__SKYBRIDGE_REMOTE_STATUS__=0'
            else
              printf '\n%s\n' '__SKYBRIDGE_REMOTE_STATUS__=1'
            fi
            ;;
          present) printf '%s\n' 'package:/data/app/~~abc/com.example.test-def/base.apk' '__SKYBRIDGE_REMOTE_STATUS__=0' ;;
          malformed) printf '%s\n' 'package:/system/app/not-owned.apk' '__SKYBRIDGE_REMOTE_STATUS__=0' ;;
          *) exit 91 ;;
        esac
      elif [[ "$remote_command" == *'pidof '* ]]; then
        case "${FAKE_PIDOF_MODE:-absent}" in
          absent) printf '\n%s\n' '__SKYBRIDGE_REMOTE_STATUS__=1' ;;
          present) printf '%s\n' '101 202' '__SKYBRIDGE_REMOTE_STATUS__=0' ;;
          malformed) printf '%s\n' 'not-a-pid' '__SKYBRIDGE_REMOTE_STATUS__=0' ;;
          failed) printf '%s\n' 'pid service unavailable' '__SKYBRIDGE_REMOTE_STATUS__=2' ;;
          *) exit 95 ;;
        esac
      else
        exit 97
      fi
    elif [[ "${1:-}" == "getprop" ]]; then
      case "${2:-}" in
        ro.product.manufacturer) printf '%s\n' "${FAKE_MANUFACTURER:-Samsung}" ;;
        ro.product.model) printf '%s\n' "${FAKE_MODEL:-SM-S948U}" ;;
        ro.build.version.release) printf '%s\n' "${FAKE_RELEASE:-16}" ;;
        ro.build.version.sdk) printf '%s\n' "${FAKE_SDK:-36}" ;;
        ro.product.cpu.abi) printf '%s\n' "${FAKE_ABI:-arm64-v8a}" ;;
        ro.kernel.qemu) printf '%s\n' "${FAKE_QEMU:-0}" ;;
        *) exit 96 ;;
      esac
    elif [[ "${1:-}" == "getconf" && "${2:-}" == "PAGESIZE" ]]; then
      printf '%s\n' "${FAKE_PAGE_SIZE:-4096}"
    elif [[ "${1:-}" == "pm" && "${2:-}" == "path" ]]; then
      case "${FAKE_PM_MODE:-present}" in
        absent-exit-one) exit 1 ;;
        absent-exit-zero) exit 0 ;;
        failed) printf '%s\n' "package manager unavailable"; exit 1 ;;
        stateful)
          [[ -e "$FAKE_STATE" ]] || exit 1
          printf '%s\n' 'package:/data/app/~~abc/com.example.test-def/base.apk'
          ;;
        present) printf '%s\n' 'package:/data/app/~~abc/com.example.test-def/base.apk' ;;
        malformed) printf '%s\n' 'package:/system/app/not-owned.apk' ;;
        *) exit 91 ;;
      esac
    elif [[ "${1:-}" == "sha256sum" ]]; then
      printf '%s  %s\n' "${FAKE_DIGEST:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" "${2:-}"
    elif [[ "${1:-}" == "pidof" ]]; then
      case "${FAKE_PIDOF_MODE:-absent}" in
        absent) exit 1 ;;
        present) printf '%s\n' '101 202' ;;
        malformed) printf '%s\n' 'not-a-pid' ;;
        failed) printf '%s\n' 'pid service unavailable'; exit 2 ;;
        *) exit 95 ;;
      esac
    else
      exit 92
    fi
    ;;
  uninstall)
    [[ "${FAKE_PM_MODE:-}" == "stateful" ]] || exit 93
    rm -f -- "$FAKE_STATE"
    case "${FAKE_UNINSTALL_TERMINAL:-success}" in
      success) printf '%s\n' 'Success' ;;
      embedded-cr) printf 'Suc\rcess\n' ;;
      repeated-cr) printf 'Success\r\r\n' ;;
      extra) printf '%s\n' 'Success' 'unexpected-terminal' ;;
      *) exit 98 ;;
    esac
    ;;
  *) exit 94 ;;
esac
FAKE
chmod 0700 "$FAKE_ADB"
export FAKE_STATE

expect_status() {
  local expected="$1"
  shift
  local actual=0
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  if (( actual != expected )); then
    echo "expected status $expected, got $actual: $*" >&2
    exit 1
  fi
}

FAKE_DEVICE_STATE=device FAKE_SELF_SERIAL=SERIAL-1 \
  android_require_exact_device "$FAKE_ADB" SERIAL-1
expect_status 1 env FAKE_DEVICE_STATE=device FAKE_SELF_SERIAL=SERIAL-2 \
  bash -c 'source "$1"; android_require_exact_device "$2" SERIAL-1' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"

binding="$(android_collect_samsung_4k_device_binding "$FAKE_ADB" SERIAL-1)"
grep -qx 'profile=samsung-physical-4k' <<<"$binding"
grep -qx 'page_size=4096' <<<"$binding"
grep -qx 'qemu=0' <<<"$binding"
grep -Eq '^serial_ref=sha256:[0-9a-f]{16}$' <<<"$binding"
expect_status 1 env FAKE_MANUFACTURER=Google \
  bash -c 'source "$1"; android_collect_samsung_4k_device_binding "$2" SERIAL-1' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"
expect_status 1 env FAKE_PAGE_SIZE=16384 \
  bash -c 'source "$1"; android_collect_samsung_4k_device_binding "$2" SERIAL-1' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"
expect_status 1 env FAKE_QEMU=1 \
  bash -c 'source "$1"; android_collect_samsung_4k_device_binding "$2" SERIAL-1' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"

expect_status 2 env FAKE_PM_MODE=absent-exit-one \
  bash -c 'set -o pipefail; source "$1"; android_installed_package_path "$2" SERIAL-1 com.example.test' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"
expect_status 1 env FAKE_PM_MODE=absent-exit-zero \
  bash -c 'set -o pipefail; source "$1"; android_installed_package_path "$2" SERIAL-1 com.example.test' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"
expect_status 1 env FAKE_PM_MODE=failed \
  bash -c 'set -o pipefail; source "$1"; android_installed_package_path "$2" SERIAL-1 com.example.test' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"
expect_status 1 env FAKE_TRANSPORT_FAILURE=1 \
  bash -c 'set -o pipefail; source "$1"; android_installed_package_path "$2" SERIAL-1 com.example.test' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"

FAKE_PIDOF_MODE=absent android_require_package_process_absent \
  "$FAKE_ADB" SERIAL-1 com.example.test
expect_status 1 env FAKE_PIDOF_MODE=present \
  bash -c 'source "$1"; android_require_package_process_absent "$2" SERIAL-1 com.example.test' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"
expect_status 1 env FAKE_PIDOF_MODE=malformed \
  bash -c 'source "$1"; android_require_package_process_absent "$2" SERIAL-1 com.example.test' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"
expect_status 1 env FAKE_PIDOF_MODE=failed \
  bash -c 'source "$1"; android_require_package_process_absent "$2" SERIAL-1 com.example.test' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"
expect_status 1 env FAKE_TRANSPORT_FAILURE=1 \
  bash -c 'source "$1"; android_require_package_process_absent "$2" SERIAL-1 com.example.test' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB"

android_require_exact_success_output $'Success\r' "fixture install"
expect_status 1 bash -c \
  'source "$1"; android_require_exact_success_output "$2" "fixture install"' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" $'Suc\rcess'
expect_status 1 bash -c \
  'source "$1"; android_require_exact_success_output "$2" "fixture install"' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" $'Success\r\r'
expect_status 1 bash -c \
  'source "$1"; android_require_exact_success_output "$2" "fixture install"' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" $'Success\nwarning: unexpected'
expect_status 1 bash -c \
  'source "$1"; android_require_exact_success_output "$2" "fixture install"' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" $'Success\nunexpected-terminal'
expect_status 1 bash -c \
  'source "$1"; android_require_exact_success_output "$2" "fixture install"' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" $'Success\nSuccess'

INSTALL_APK_PATH="/private/tmp/SkyBridge App/app-debug.apk"
INSTALL_APK_BYTES="152873226"
INSTALL_TRANSCRIPT="$INSTALL_APK_PATH: 1 file pushed, 0 skipped. 91.2 MB/s ($INSTALL_APK_BYTES bytes in 1.598s)"$'\nPerforming Push Install\nSuccess'
android_require_exact_install_success_output \
  "$INSTALL_TRANSCRIPT" "$INSTALL_APK_PATH" "$INSTALL_APK_BYTES" "fixture push install"
android_require_exact_install_success_output \
  "Success" "$INSTALL_APK_PATH" "$INSTALL_APK_BYTES" "fixture direct install"
for invalid_transcript in \
  "other.apk: 1 file pushed, 0 skipped. 91.2 MB/s ($INSTALL_APK_BYTES bytes in 1.598s)"$'\nPerforming Push Install\nSuccess' \
  "$INSTALL_APK_PATH: 1 file pushed, 0 skipped. 91.2 MB/s (1 bytes in 1.598s)"$'\nPerforming Push Install\nSuccess' \
  "$INSTALL_TRANSCRIPT"$'\nunexpected-terminal' \
  "$INSTALL_APK_PATH: 1 file pushed, 0 skipped. 91.2 MB/s ($INSTALL_APK_BYTES bytes in 1.598s)"$'\nwarning\nPerforming Push Install\nSuccess' \
  "$INSTALL_APK_PATH: 1 file pushed, 0 skipped. 91.2 MB/s ($INSTALL_APK_BYTES bytes in 1.598s)"$'\r\nPerforming Push Install\nSuccess'
do
  expect_status 1 bash -c \
    'source "$1"; android_require_exact_install_success_output "$2" "$3" "$4" "fixture push install"' \
    _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$invalid_transcript" \
    "$INSTALL_APK_PATH" "$INSTALL_APK_BYTES"
done

FAKE_PM_MODE=present android_require_installed_apk_digest \
  "$FAKE_ADB" SERIAL-1 com.example.test "$EXPECTED_DIGEST"
expect_status 1 env FAKE_PM_MODE=present FAKE_DIGEST=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  bash -c 'set -o pipefail; source "$1"; android_require_installed_apk_digest "$2" SERIAL-1 com.example.test "$3"' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB" "$EXPECTED_DIGEST"

touch "$FAKE_STATE"
FAKE_PM_MODE=stateful android_remove_owned_package \
  "$FAKE_ADB" SERIAL-1 com.example.test "$EXPECTED_DIGEST"
[[ ! -e "$FAKE_STATE" ]] || { echo "owned package state was not removed" >&2; exit 1; }

touch "$FAKE_STATE"
expect_status 1 env FAKE_PM_MODE=stateful FAKE_DIGEST=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  bash -c 'set -o pipefail; source "$1"; android_remove_owned_package "$2" SERIAL-1 com.example.test "$3"' \
  _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB" "$EXPECTED_DIGEST"
[[ -e "$FAKE_STATE" ]] || { echo "mismatched package was removed" >&2; exit 1; }

for uninstall_terminal in embedded-cr repeated-cr extra; do
  touch "$FAKE_STATE"
  expect_status 1 env FAKE_PM_MODE=stateful FAKE_UNINSTALL_TERMINAL="$uninstall_terminal" \
    bash -c 'set -o pipefail; source "$1"; android_remove_owned_package "$2" SERIAL-1 com.example.test "$3"' \
    _ "$ANDROID_ROOT/scripts/lib/android_env.sh" "$FAKE_ADB" "$EXPECTED_DIGEST"
done

echo "android device helper fake-command tests passed"
