#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/real_device_ios_process_ownership.sh"

OWNERSHIP_HELPER="$ROOT_DIR/Scripts/webrtc_smoke_process_ownership.py"
IOS_CAPTURE="$ROOT_DIR/Scripts/capture_ios_product_process_oslog.sh"
IDENTITY_EXTRACTOR="$ROOT_DIR/Scripts/extract_ios_production_identity_evidence.py"

usage() {
  cat <<'USAGE'
Produce the one-time shipping iOS identity lifecycle evidence.

Usage:
  run_formal_ios_identity_lifecycle.sh \
    --private-output-dir <new mode-0700 directory> \
    --public-output-dir <new mode-0700 directory> \
    --ios-archive-identity <sealed archive identity> \
    --ios-release-testing-ipa <sealed physical-testing IPA> \
    --ios-device-id <devicectl identifier> \
    --ios-device-udid <xcdevice physical UDID> \
    [--timeout-seconds <30-900>]

This transaction installs the exact app extracted from the sealed IPA, records
one normal launch that commits a newly created production identity, then a
different fresh launch that restores it and completes its signing self-test.
It must be run once per immutable identity lifecycle, not once per evidence
kind. It never clears Keychain, injects state, or enables a testing surface.
USAGE
}

PRIVATE_OUTPUT_DIR=""
PUBLIC_OUTPUT_DIR=""
IOS_ARCHIVE_IDENTITY=""
IOS_RELEASE_TESTING_IPA=""
IOS_DEVICE_ID=""
IOS_DEVICE_UDID=""
TIMEOUT_SECONDS=600

while (( $# > 0 )); do
  case "$1" in
    --private-output-dir) PRIVATE_OUTPUT_DIR="${2:-}"; shift 2 ;;
    --public-output-dir) PUBLIC_OUTPUT_DIR="${2:-}"; shift 2 ;;
    --ios-archive-identity) IOS_ARCHIVE_IDENTITY="${2:-}"; shift 2 ;;
    --ios-release-testing-ipa) IOS_RELEASE_TESTING_IPA="${2:-}"; shift 2 ;;
    --ios-device-id) IOS_DEVICE_ID="${2:-}"; shift 2 ;;
    --ios-device-udid) IOS_DEVICE_UDID="${2:-}"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || (( TIMEOUT_SECONDS < 30 || TIMEOUT_SECONDS > 900 )); then
  echo "--timeout-seconds must be an integer from 30 through 900" >&2
  exit 2
fi
for path in \
  "$PRIVATE_OUTPUT_DIR" "$PUBLIC_OUTPUT_DIR" "$IOS_ARCHIVE_IDENTITY" \
  "$IOS_RELEASE_TESTING_IPA"; do
  [[ "$path" == /* ]] || { echo "all paths must be absolute" >&2; exit 2; }
done
for destination in "$PRIVATE_OUTPUT_DIR" "$PUBLIC_OUTPUT_DIR"; do
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    echo "lifecycle destination must not already exist: $destination" >&2
    exit 1
  }
done
for path in "$IOS_ARCHIVE_IDENTITY" "$IOS_RELEASE_TESTING_IPA"; do
  [[ -f "$path" && ! -L "$path" ]] || {
    echo "required sealed-product input must be a real file: $path" >&2
    exit 1
  }
done
[[ -n "$IOS_DEVICE_ID" && -n "$IOS_DEVICE_UDID" ]] || {
  echo "both devicectl identifier and xcdevice UDID are required" >&2
  exit 2
}

python3 "$ROOT_DIR/Scripts/ios_physical_release_acceptance.py" verify-product \
  --identity "$IOS_ARCHIVE_IDENTITY" \
  --release-testing-ipa "$IOS_RELEASE_TESTING_IPA"

mkdir -m 0700 "$PRIVATE_OUTPUT_DIR" "$PUBLIC_OUTPUT_DIR"
PRIVATE_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-identity-lifecycle.XXXXXX")"
chmod 0700 "$PRIVATE_RUNTIME"
IOS_EXTRACTED_APP="$PRIVATE_RUNTIME/SkyBridgeCompass-iOS.app"
IOS_INSTALL_RESULT="$PRIVATE_RUNTIME/ios-install.json"
IOS_INSTALLED_APPS_RESULT="$PRIVATE_RUNTIME/ios-installed-apps.json"
IOS_INSTALLATION_BINDING="$PRIVATE_RUNTIME/ios-installation-binding.json"
IOS_PRELAUNCH_PROCESSES="$PRIVATE_RUNTIME/ios-postinstall-prelaunch-processes.json"
IOS_LAUNCH_PERSISTENT_IDENTIFIER=""
IOS_CONSOLE_PID=""
IOS_CONSOLE_HANDLE_IDENTITY=""
IOS_CONSOLE_HANDLE_CAPTURED=0
TRANSACTION_COMPLETE=0

cleanup() {
  local cleanup_failed=0
  if [[ "$IOS_CONSOLE_HANDLE_CAPTURED" == "1" ]]; then
    if skybridge_ios_console_handle_status \
      "$OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$IOS_CONSOLE_HANDLE_IDENTITY"; then
      skybridge_ios_signal_console_handle \
        "$OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$IOS_CONSOLE_HANDLE_IDENTITY" \
        || cleanup_failed=1
      skybridge_ios_wait_console_handle_exit \
        "$OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$IOS_CONSOLE_HANDLE_IDENTITY" 30 \
        || cleanup_failed=1
    else
      handle_status=$?
      (( handle_status == 1 )) || cleanup_failed=1
    fi
  fi
  if (( cleanup_failed == 0 )); then
    /bin/rm -rf "$PRIVATE_RUNTIME"
    if [[ "$TRANSACTION_COMPLETE" != "1" ]]; then
      /bin/rm -rf "$PRIVATE_OUTPUT_DIR" "$PUBLIC_OUTPUT_DIR"
    fi
  else
    echo "exact iOS cleanup is incomplete; private runtime preserved: $PRIVATE_RUNTIME" >&2
  fi
  [[ "$TRANSACTION_COMPLETE" == "1" && "$cleanup_failed" == "0" ]]
}
trap cleanup EXIT

python3 "$ROOT_DIR/Scripts/ios_physical_release_acceptance.py" prepare-product \
  --identity "$IOS_ARCHIVE_IDENTITY" \
  --release-testing-ipa "$IOS_RELEASE_TESTING_IPA" \
  --destination-app "$IOS_EXTRACTED_APP" >/dev/null
skybridge_ios_require_fresh_app_launch \
  "$OWNERSHIP_HELPER" "$IOS_DEVICE_ID" "$IOS_EXTRACTED_APP" \
  "$PRIVATE_RUNTIME" 60

echo "==> Installing the exact sealed release-testing product"
xcrun devicectl --timeout 120 device install app \
  --device "$IOS_DEVICE_ID" \
  --json-output "$IOS_INSTALL_RESULT" \
  "$IOS_EXTRACTED_APP" >/dev/null
chmod 0600 "$IOS_INSTALL_RESULT"
xcrun devicectl --timeout 60 device info apps \
  --device "$IOS_DEVICE_ID" \
  --bundle-id com.skybridge.compass.ios \
  --columns '*' \
  --json-output "$IOS_INSTALLED_APPS_RESULT" >/dev/null
chmod 0600 "$IOS_INSTALLED_APPS_RESULT"
python3 "$ROOT_DIR/Scripts/ios_product_installation.py" \
  --install-result "$IOS_INSTALL_RESULT" \
  --apps-result "$IOS_INSTALLED_APPS_RESULT" \
  --extracted-app "$IOS_EXTRACTED_APP" \
  --archive-identity "$IOS_ARCHIVE_IDENTITY" \
  --release-testing-ipa "$IOS_RELEASE_TESTING_IPA" \
  --expected-device-identifier "$IOS_DEVICE_ID" \
  --output "$IOS_INSTALLATION_BINDING"
skybridge_ios_process_snapshot "$IOS_DEVICE_ID" "$IOS_PRELAUNCH_PROCESSES" 60
if python3 "$OWNERSHIP_HELPER" ios-presence \
  --processes-json "$IOS_PRELAUNCH_PROCESSES" \
  --app-path "$IOS_EXTRACTED_APP"; then
  echo "installed iOS product is already running before the first launch" >&2
  exit 1
else
  prelaunch_status=$?
  (( prelaunch_status == 1 )) || {
    echo "post-install iOS product absence is unverifiable" >&2
    exit 1
  }
fi
IOS_LAUNCH_PERSISTENT_IDENTIFIER="$(
  python3 - "$IOS_INSTALLATION_BINDING" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload["launchServicesIdentifier"])
PY
)"

launch_and_capture() {
  local prefix="${1:?missing launch prefix}"
  local checkpoint="${2:?missing checkpoint text}"
  local launch_result="$PRIVATE_RUNTIME/${prefix}-launch.json"
  local console_stdout="$PRIVATE_RUNTIME/${prefix}-console.stdout.log"
  local console_stderr="$PRIVATE_RUNTIME/${prefix}-console.stderr.log"
  local console_identity="$PRIVATE_RUNTIME/${prefix}-console-handle.json"
  local console_diagnostic="$PRIVATE_RUNTIME/${prefix}-console-capture.log"
  local raw_oslog="$PRIVATE_RUNTIME/${prefix}-product.ndjson"
  local launch_identity="$PRIVATE_RUNTIME/${prefix}-product-identity.json"
  local start_epoch
  local start_token

  start_epoch="$(date +%s)"
  start_token="$(python3 - <<'PY'
import time

value = time.time_ns()
print(f"{value // 1_000_000_000}:{(value // 1_000) % 1_000_000:06d}")
PY
)"
  : >"$console_stdout"
  : >"$console_stderr"
  chmod 0600 "$console_stdout" "$console_stderr"
  xcrun devicectl --timeout "$((TIMEOUT_SECONDS + 120))" device process launch \
    --device "$IOS_DEVICE_ID" \
    --console \
    --launch-persistent-identifier "$IOS_LAUNCH_PERSISTENT_IDENTIFIER" \
    --json-output "$launch_result" \
    com.skybridge.compass.ios \
    >"$console_stdout" 2>"$console_stderr" &
  IOS_CONSOLE_PID="$!"
  IOS_CONSOLE_HANDLE_IDENTITY="$console_identity"
  skybridge_ios_capture_console_handle \
    "$OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$console_identity" \
    "$console_diagnostic" 20
  IOS_CONSOLE_HANDLE_CAPTURED=1

  printf '%s\n' "$checkpoint"
  printf 'Type COMPLETE only after the ordinary product reports the terminal state: '
  IFS= read -r operator_checkpoint
  [[ "$operator_checkpoint" == "COMPLETE" ]] || {
    echo "operator checkpoint was not confirmed" >&2
    return 1
  }
  skybridge_ios_signal_console_handle \
    "$OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$console_identity"
  skybridge_ios_wait_console_handle_exit \
    "$OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$console_identity" 30
  skybridge_ios_capture_exited_console_identity \
    "$OWNERSHIP_HELPER" "$launch_result" "$IOS_EXTRACTED_APP" \
    "$PRIVATE_RUNTIME/${prefix}-base-identity.json"
  skybridge_ios_require_app_absent_after_handle_exit \
    "$OWNERSHIP_HELPER" "$IOS_DEVICE_ID" "$IOS_EXTRACTED_APP" \
    "$PRIVATE_RUNTIME" 60
  IOS_CONSOLE_HANDLE_CAPTURED=0
  IOS_CONSOLE_PID=""
  IOS_CONSOLE_HANDLE_IDENTITY=""
  "$IOS_CAPTURE" \
    --device-udid "$IOS_DEVICE_UDID" \
    --launch-result "$launch_result" \
    --installation-binding "$IOS_INSTALLATION_BINDING" \
    --launch-start-epoch "$start_epoch" \
    --launch-start-time-token "$start_token" \
    --extracted-app "$IOS_EXTRACTED_APP" \
    --raw-output "$raw_oslog" \
    --launch-identity-output "$launch_identity"
}

launch_and_capture \
  first \
  "==> In normal Settings UI, create and commit the ML-DSA-87 Secure Enclave identity only after the real remote rotation receipt and runtime self-test succeed. Do not clear or inject Keychain state."
launch_and_capture \
  second \
  "==> This fresh launch must restore the same immutable Keychain authority and complete a real signing self-test. Do not rotate or recreate it."

python3 "$IDENTITY_EXTRACTOR" extract-lifecycle \
  --first-raw-oslog "$PRIVATE_RUNTIME/first-product.ndjson" \
  --first-launch-identity "$PRIVATE_RUNTIME/first-product-identity.json" \
  --second-raw-oslog "$PRIVATE_RUNTIME/second-product.ndjson" \
  --second-launch-identity "$PRIVATE_RUNTIME/second-product-identity.json" \
  --archive-identity "$IOS_ARCHIVE_IDENTITY" \
  --private-binding "$PRIVATE_OUTPUT_DIR/ios-production-identity-lifecycle-binding.json" \
  --public-proof "$PUBLIC_OUTPUT_DIR/ios-production-identity-lifecycle-proof.json"
python3 "$IDENTITY_EXTRACTOR" validate-lifecycle-proof \
  --proof "$PUBLIC_OUTPUT_DIR/ios-production-identity-lifecycle-proof.json" \
  --archive-identity "$IOS_ARCHIVE_IDENTITY"

TRANSACTION_COMPLETE=1
echo "private lifecycle binding: $PRIVATE_OUTPUT_DIR/ios-production-identity-lifecycle-binding.json"
echo "public lifecycle proof: $PUBLIC_OUTPUT_DIR/ios-production-identity-lifecycle-proof.json"
