#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_SCRIPT="${ROOT_DIR}/SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-ios-device-privacy-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${TMP_DIR}/bin"
CALL_LOG="${TMP_DIR}/xcodebuild.calls"
DEVICE_SUPPORT_ROOT="${TMP_DIR}/DeviceSupport"
EXPECTED_DEVICE_SUPPORT_SYMBOLS="${DEVICE_SUPPORT_ROOT}/iPad16,3 27.0 (24A5355q)/arm64e/Symbols"
mkdir -p "${EXPECTED_DEVICE_SUPPORT_SYMBOLS}"
export STUB_XCODEBUILD_CALL_LOG="${CALL_LOG}"
export STUB_REPO_ROOT="${ROOT_DIR}"
export STUB_TMP_ROOT="${TMP_DIR}"
export SKYBRIDGE_IOS_DEVICE_SUPPORT_ROOT="${DEVICE_SUPPORT_ROOT}"

cat >"${TMP_DIR}/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "devicectl" && "${2:-}" == "list" && "${3:-}" == "devices" && "${4:-}" == "--json-output" ]]; then
  output_path="${5:?missing json output path}"

  if [[ "${STUB_DEVICECTL_MODE:-ok}" == "fail" ]]; then
    echo "devicectl failed for SECRET-UDID-123 Sensitive iPad SECRET-SERIAL-456" >&2
    exit 67
  fi

  emit_devices_json() {
  if [[ "${STUB_DEVICE_PRESENT:-1}" != "1" ]]; then
    cat <<'JSON'
{
  "result": {
    "devices": []
  }
}
JSON
    return
  fi

  release_type="${STUB_DEVICE_RELEASE_TYPE:-Beta}"
  developer_mode_status="${STUB_DEVICE_DEVELOPER_MODE_STATUS:-enabled}"
  cat <<JSON
{
  "result": {
    "devices": [
      {
        "identifier": "SECRET-UDID-123",
        "connectionProperties": {
          "pairingState": "paired",
          "tunnelState": "${STUB_DEVICE_TUNNEL_STATE:-connected}",
          "localHostnames": ["secret-ipad.local"],
          "potentialHostnames": ["secret-ipad-alt.local"]
        },
        "deviceProperties": {
          "name": "Sensitive iPad",
          "bootState": "booted",
          "developerModeStatus": "${developer_mode_status}",
          "osVersionNumber": "27.0",
          "osBuildUpdate": "24A5355q",
          "releaseType": "${release_type}"
        },
        "hardwareProperties": {
          "platform": "iOS",
          "deviceType": "iPad",
          "productType": "iPad16,3",
          "cpuType": {
            "name": "arm64e"
          },
          "udid": "SECRET-HW-UDID-789",
          "serialNumber": "SECRET-SERIAL-456"
        }
      }
    ]
  }
}
JSON
  }

  if [[ "${STUB_DEVICECTL_JSON_OUTPUT_MODE:-file}" == "stdout_mixed" ]]; then
    printf 'Name Identifier\nSensitive iPad SECRET-UDID-123 secret-ipad.local\n'
    if [[ "${output_path}" == "-" ]]; then
      emit_devices_json
    fi
    exit 0
  fi

  if [[ "${output_path}" == "-" ]]; then
    emit_devices_json
  else
    emit_devices_json >"${output_path}"
  fi
  exit 0
fi

if [[ "${1:-}" == "devicectl" && "${2:-}" == "device" && "${3:-}" == "info" && "${4:-}" == "details" ]]; then
  output_path=""
  device_id=""
  shift 4
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --device)
        device_id="${2:?missing device identifier}"
        shift 2
        ;;
      --timeout)
        shift 2
        ;;
      --json-output)
        output_path="${2:?missing reachability JSON output path}"
        shift 2
        ;;
      *)
        exit 64
        ;;
    esac
  done

  if [[ "${STUB_DEVICECTL_REACHABILITY_MODE:-connected}" == "fail" ]]; then
    echo "reachability failed for ${device_id}" >&2
    exit 68
  fi
  [[ -n "${output_path}" && -n "${device_id}" ]] || exit 64
  connection_state="${STUB_DEVICECTL_REACHABILITY_MODE:-connected}"
  cat >"${output_path}" <<JSON
{
  "result": {
    "identifier": "${device_id}",
    "connectionProperties": {
      "pairingState": "paired",
      "tunnelState": "${connection_state}"
    },
    "properties": {
      "connection": {
        "pairingState": "paired",
        "state": "${connection_state}"
      }
    }
  }
}
JSON
  exit 0
fi

if [[ "${1:-}" == "devicectl" && "${2:-}" == "device" && "${3:-}" == "info" && "${4:-}" == "lockState" ]]; then
  output_path=""
  device_id=""
  shift 4
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --device)
        device_id="${2:?missing device identifier}"
        shift 2
        ;;
      --timeout)
        shift 2
        ;;
      --json-output)
        output_path="${2:?missing lock-state JSON output path}"
        shift 2
        ;;
      *)
        exit 64
        ;;
    esac
  done

  if [[ "${STUB_DEVICECTL_LOCK_STATE:-unlocked}" == "fail" ]]; then
    echo "lock-state probe failed for ${device_id}" >&2
    exit 69
  fi
  [[ -n "${output_path}" && -n "${device_id}" ]] || exit 64
  case "${STUB_DEVICECTL_LOCK_STATE:-unlocked}" in
    unlocked)
      passcode_required=false
      unlocked_since_boot=true
      ;;
    locked)
      passcode_required=true
      unlocked_since_boot=true
      ;;
    cold)
      passcode_required=true
      unlocked_since_boot=false
      ;;
    *)
      exit 64
      ;;
  esac
  cat >"${output_path}" <<JSON
{
  "result": {
    "deviceIdentifier": "${device_id}",
    "passcodeRequired": ${passcode_required},
    "unlockedSinceBoot": ${unlocked_since_boot}
  }
}
JSON
  exit 0
fi

exit 66
SH

cat >"${TMP_DIR}/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

{
  printf 'xcodebuild'
  for arg in "$@"; do
    printf ' <%s>' "${arg}"
  done
  printf '\n'
} >>"${STUB_XCODEBUILD_CALL_LOG}"

case "${STUB_XCODEBUILD_MODE:-success}" in
  success)
    echo "Command line invocation: /Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild -project ${STUB_REPO_ROOT}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj -derivedDataPath ${STUB_TMP_ROOT}/DerivedData"
    echo "Build description path: ${STUB_TMP_ROOT}/DerivedData/Build/Intermediates.noindex/XCBuildData/fake.xcbuilddata"
    echo 'Signing Identity:     "Apple Development: Zi ang Li (8PKXBGACNV)"'
    echo 'Provisioning Profile: "iOS Team Provisioning Profile: com.skybridge.compass.ios"'
    echo '                      (558f8b50-2a96-4fe8-a8e2-6767dffefd40)'
    echo "${STUB_TMP_ROOT}/UserData/Provisioning Profiles/558f8b50-2a96-4fe8-a8e2-6767dffefd40.mobileprovision"
    echo "/usr/bin/codesign --force --sign F05D629A68B79DA893855BE83F5B782F05D873B2 --timestamp=none ${STUB_TMP_ROOT}/DerivedData/Product.app"
    echo "building SECRET-UDID-123 Sensitive iPad SECRET-SERIAL-456 secret-ipad.local secret-ipad-alt.local SECRET-HW-UDID-789 ${SKYBRIDGE_IOS_DEVICE_ID:-}"
    echo "testing SECRET-UDID-123 Sensitive iPad SECRET-SERIAL-456 secret-ipad.local secret-ipad-alt.local SECRET-HW-UDID-789 ${SKYBRIDGE_IOS_DEVICE_ID:-}" >&2
    exit 0
    ;;
  fail)
    echo "error: failed for SECRET-UDID-123 Sensitive iPad SECRET-SERIAL-456 secret-ipad.local secret-ipad-alt.local SECRET-HW-UDID-789 ${SKYBRIDGE_IOS_DEVICE_ID:-} ${STUB_REPO_ROOT}/SkyBridge Compass iOS"
    echo "ERROR: failed for SECRET-UDID-123 Sensitive iPad SECRET-SERIAL-456 secret-ipad.local secret-ipad-alt.local SECRET-HW-UDID-789 ${SKYBRIDGE_IOS_DEVICE_ID:-} ${STUB_TMP_ROOT}/DerivedData" >&2
    exit 42
    ;;
  warning)
    echo "warning: destination SECRET-UDID-123 Sensitive iPad SECRET-SERIAL-456 secret-ipad.local secret-ipad-alt.local SECRET-HW-UDID-789 ${SKYBRIDGE_IOS_DEVICE_ID:-} /Applications/Xcode-beta.app/Contents/Developer"
    exit 0
    ;;
  duplicate_class)
    echo "objc[4242]: Class RTCVideoFrame is implemented in both ${STUB_TMP_ROOT}/Frameworks/WebRTC.framework/WebRTC (0x1000) and ${STUB_TMP_ROOT}/DerivedData/Build/Products/Debug-iphoneos/SkyBridgeCompassiOSTests-Runner.app/WebRTC.framework/WebRTC (0x2000). This may cause spurious casting failures and mysterious crashes. One of the duplicates must be removed or renamed."
    exit 0
    ;;
  xpc_runtime_error)
    echo "2026-07-29 14:02:03.456 SkyBridgeCompassiOSTests-Runner[4242:1717] [XPCErrors] non-launching port for SECRET-UDID-123"
    exit 0
    ;;
  benign_device_support)
    # Emits only the benign Xcode arch-fallback DeviceSupport diagnostic, which
    # must NOT trip the clean-log gate when device symbols are present.
    echo "2026-07-24 19:31:55.356 xcodebuild[52499:25123985] [MT] DVTDevice: Error locating DeviceSupport directory using Optional(\"arm64\") or Optional(\"arm64e\"): nilError"
    echo "Test Suite 'All tests' passed for SECRET-UDID-123 Sensitive iPad SECRET-SERIAL-456 secret-ipad.local secret-ipad-alt.local SECRET-HW-UDID-789 ${SKYBRIDGE_IOS_DEVICE_ID:-}"
    exit 0
    ;;
  *)
    echo "unknown STUB_XCODEBUILD_MODE=${STUB_XCODEBUILD_MODE}" >&2
    exit 64
    ;;
esac
SH

chmod +x "${TMP_DIR}/bin/xcrun" "${TMP_DIR}/bin/xcodebuild"

SECRETS=(
  "SECRET-UDID-123"
  "SECRET-HW-UDID-789"
  "SECRET-SERIAL-456"
  "Sensitive iPad"
  "secret-ipad.local"
  "secret-ipad-alt.local"
  "${ROOT_DIR}"
  "${TMP_DIR}"
  "/Applications/Xcode-beta.app/Contents/Developer"
  "Apple Development: Zi ang Li"
  "iOS Team Provisioning Profile: com.skybridge.compass.ios"
  "558f8b50-2a96-4fe8-a8e2-6767dffefd40"
  "F05D629A68B79DA893855BE83F5B782F05D873B2"
)

assert_contains() {
  local needle="$1"
  local haystack_file="$2"
  if ! grep -Fq -- "${needle}" "${haystack_file}"; then
    echo "Expected ${haystack_file} to contain: ${needle}" >&2
    cat "${haystack_file}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1"
  local haystack_file="$2"
  if grep -Fq -- "${needle}" "${haystack_file}"; then
    echo "Expected ${haystack_file} not to contain: ${needle}" >&2
    cat "${haystack_file}" >&2
    exit 1
  fi
}

assert_no_secret_output() {
  local output_file="$1"
  local secret
  for secret in "${SECRETS[@]}"; do
    assert_not_contains "${secret}" "${output_file}"
  done
}

assert_no_redaction_token_files() {
  local leaked_files=""
  leaked_files="$(find "${TMP_DIR}" -name 'skybridge-ios-device-redaction.*' -print)"
  if [[ -n "${leaked_files}" ]]; then
    echo "Expected iOS device redaction token files to be removed" >&2
    printf '%s\n' "${leaked_files}" >&2
    exit 1
  fi
}

assert_no_device_metadata_files() {
  local leaked_files=""
  leaked_files="$(find "${TMP_DIR}" -name 'skybridge-ios-device-metadata.*' -print)"
  if [[ -n "${leaked_files}" ]]; then
    echo "Expected iOS device metadata files to be removed" >&2
    printf '%s\n' "${leaked_files}" >&2
    exit 1
  fi
}

assert_no_device_reachability_files() {
  local leaked_files=""
  leaked_files="$(find "${TMP_DIR}" \( -name 'skybridge-ios-device-reachability.*' -o -name 'skybridge-ios-device-reachability-stderr.*' \) -print)"
  if [[ -n "${leaked_files}" ]]; then
    echo "Expected iOS device reachability files to be removed" >&2
    printf '%s\n' "${leaked_files}" >&2
    exit 1
  fi
}

run_lane() {
  local output_file="$1"
  local status=0
  shift

  : >"${CALL_LOG}"
  if TMPDIR="${TMP_DIR}" PATH="${TMP_DIR}/bin:${PATH}" "$@" bash "${TARGET_SCRIPT}" >"${output_file}" 2>&1; then
    status=0
  else
    status=$?
  fi
  return "${status}"
}

UNKNOWN_ARGUMENT_OUTPUT="${TMP_DIR}/unknown-argument.out"
: >"${CALL_LOG}"
set +e
TMPDIR="${TMP_DIR}" PATH="${TMP_DIR}/bin:${PATH}" bash "${TARGET_SCRIPT}" --diagnose-only >"${UNKNOWN_ARGUMENT_OUTPUT}" 2>&1
unknown_argument_status=$?
set -e
if [[ "${unknown_argument_status}" -ne 64 ]]; then
  echo "Expected unsupported argument lane to exit 64, got ${unknown_argument_status}" >&2
  cat "${UNKNOWN_ARGUMENT_OUTPUT}" >&2
  exit 1
fi
assert_contains "unsupported command-line arguments" "${UNKNOWN_ARGUMENT_OUTPUT}"
assert_no_secret_output "${UNKNOWN_ARGUMENT_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected unsupported argument lane not to invoke xcodebuild" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_redaction_token_files
assert_no_device_metadata_files

SUCCESS_OUTPUT="${TMP_DIR}/success.out"
set +e
run_lane "${SUCCESS_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1
success_status=$?
set -e
if [[ "${success_status}" -ne 0 ]]; then
  echo "Expected success lane to exit 0, got ${success_status}" >&2
  cat "${SUCCESS_OUTPUT}" >&2
  exit 1
fi
assert_contains "device=sha256:" "${SUCCESS_OUTPUT}"
assert_contains "<ios-device-sha256:" "${SUCCESS_OUTPUT}"
assert_contains "<repo>/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" "${SUCCESS_OUTPUT}"
assert_contains "<tmp>/DerivedData" "${SUCCESS_OUTPUT}"
assert_contains "<applications>/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild" "${SUCCESS_OUTPUT}"
assert_contains 'Signing Identity: "<redacted-signing-identity>"' "${SUCCESS_OUTPUT}"
assert_contains 'Provisioning Profile: "<redacted-provisioning-profile>"' "${SUCCESS_OUTPUT}"
assert_contains "(<redacted-profile-uuid>)" "${SUCCESS_OUTPUT}"
assert_contains "<redacted-uuid>.mobileprovision" "${SUCCESS_OUTPUT}"
assert_contains "--sign <redacted-signing-certificate>" "${SUCCESS_OUTPUT}"
assert_no_secret_output "${SUCCESS_OUTPUT}"
destination_count="$(grep -Fc '<platform=iOS,id=SECRET-UDID-123>' "${CALL_LOG}")"
if [[ "${destination_count}" -ne 2 ]]; then
  echo "Expected xcodebuild control plane to receive canonical device id twice, got ${destination_count}" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
destination_timeout_count="$(grep -Fc '<-destination-timeout> <90>' "${CALL_LOG}")"
if [[ "${destination_timeout_count}" -ne 2 ]]; then
  echo "Expected xcodebuild to receive the default destination timeout twice, got ${destination_timeout_count}" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_contains "<build-for-testing>" "${CALL_LOG}"
assert_contains "<test-without-building>" "${CALL_LOG}"
assert_no_redaction_token_files
assert_no_device_metadata_files

STDOUT_JSON_OUTPUT="${TMP_DIR}/stdout-json.out"
set +e
run_lane "${STDOUT_JSON_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  STUB_DEVICECTL_JSON_OUTPUT_MODE=stdout_mixed
stdout_json_status=$?
set -e
if [[ "${stdout_json_status}" -ne 0 ]]; then
  echo "Expected stdout-json lane to exit 0, got ${stdout_json_status}" >&2
  cat "${STDOUT_JSON_OUTPUT}" >&2
  exit 1
fi
assert_contains "device=sha256:" "${STDOUT_JSON_OUTPUT}"
assert_contains "<ios-device-sha256:" "${STDOUT_JSON_OUTPUT}"
assert_no_secret_output "${STDOUT_JSON_OUTPUT}"
stdout_json_destination_count="$(grep -Fc '<platform=iOS,id=SECRET-UDID-123>' "${CALL_LOG}")"
if [[ "${stdout_json_destination_count}" -ne 2 ]]; then
  echo "Expected stdout-json xcodebuild control plane to receive canonical device id twice, got ${stdout_json_destination_count}" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_redaction_token_files
assert_no_device_metadata_files

APPLE_PQC_SETTING_OUTPUT="${TMP_DIR}/apple-pqc-setting.out"
set +e
run_lane "${APPLE_PQC_SETTING_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK
apple_pqc_setting_status=$?
set -e
if [[ "${apple_pqc_setting_status}" -ne 0 ]]; then
  echo "Expected Apple PQC build setting lane to exit 0, got ${apple_pqc_setting_status}" >&2
  cat "${APPLE_PQC_SETTING_OUTPUT}" >&2
  exit 1
fi
apple_pqc_setting_count="$(grep -Fc '<SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK>' "${CALL_LOG}")"
if [[ "${apple_pqc_setting_count}" -ne 1 ]]; then
  echo "Expected xcodebuild build-for-testing to receive Apple PQC build setting once, got ${apple_pqc_setting_count}" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_secret_output "${APPLE_PQC_SETTING_OUTPUT}"
assert_no_redaction_token_files
assert_no_device_metadata_files

INVALID_APPLE_PQC_SETTING_OUTPUT="${TMP_DIR}/invalid-apple-pqc-setting.out"
set +e
run_lane "${INVALID_APPLE_PQC_SETTING_OUTPUT}" env \
  SKYBRIDGE_APPLE_PQC_SDK_CONDITION=maybe
invalid_apple_pqc_setting_status=$?
set -e
if [[ "${invalid_apple_pqc_setting_status}" -ne 64 ]]; then
  echo "Expected invalid Apple PQC build setting lane to exit 64, got ${invalid_apple_pqc_setting_status}" >&2
  cat "${INVALID_APPLE_PQC_SETTING_OUTPUT}" >&2
  exit 1
fi
assert_contains "SKYBRIDGE_APPLE_PQC_SDK_CONDITION must be empty or HAS_APPLE_PQC_SDK" "${INVALID_APPLE_PQC_SETTING_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected invalid Apple PQC build setting lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi

CUSTOM_DESTINATION_TIMEOUT_OUTPUT="${TMP_DIR}/custom-destination-timeout.out"
set +e
run_lane "${CUSTOM_DESTINATION_TIMEOUT_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  SKYBRIDGE_IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS=7
custom_destination_timeout_status=$?
set -e
if [[ "${custom_destination_timeout_status}" -ne 0 ]]; then
  echo "Expected custom destination-timeout lane to exit 0, got ${custom_destination_timeout_status}" >&2
  cat "${CUSTOM_DESTINATION_TIMEOUT_OUTPUT}" >&2
  exit 1
fi
custom_destination_timeout_count="$(grep -Fc '<-destination-timeout> <7>' "${CALL_LOG}")"
if [[ "${custom_destination_timeout_count}" -ne 2 ]]; then
  echo "Expected xcodebuild to receive the custom destination timeout twice, got ${custom_destination_timeout_count}" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_secret_output "${CUSTOM_DESTINATION_TIMEOUT_OUTPUT}"
assert_no_redaction_token_files
assert_no_device_metadata_files

UNKNOWN_DEVELOPER_MODE_OUTPUT="${TMP_DIR}/unknown-developer-mode.out"
set +e
run_lane "${UNKNOWN_DEVELOPER_MODE_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  STUB_DEVICE_DEVELOPER_MODE_STATUS=unknown
unknown_developer_mode_status=$?
set -e
if [[ "${unknown_developer_mode_status}" -eq 0 ]]; then
  echo "Expected unknown developer-mode lane to fail before xcodebuild" >&2
  cat "${UNKNOWN_DEVELOPER_MODE_OUTPUT}" >&2
  exit 1
fi
assert_contains "Requested iOS device does not satisfy required constraints" "${UNKNOWN_DEVELOPER_MODE_OUTPUT}"
assert_no_secret_output "${UNKNOWN_DEVELOPER_MODE_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected unknown developer-mode lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_redaction_token_files
assert_no_device_metadata_files

ON_DEMAND_TUNNEL_OUTPUT="${TMP_DIR}/on-demand-tunnel.out"
set +e
run_lane "${ON_DEMAND_TUNNEL_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  STUB_DEVICE_TUNNEL_STATE=disconnected
on_demand_tunnel_status=$?
set -e
if [[ "${on_demand_tunnel_status}" -ne 0 ]]; then
  echo "Expected paired device with an on-demand tunnel to pass the active reachability probe" >&2
  cat "${ON_DEMAND_TUNNEL_OUTPUT}" >&2
  exit 1
fi
assert_contains "full suite passed on device" "${ON_DEMAND_TUNNEL_OUTPUT}"
assert_no_secret_output "${ON_DEMAND_TUNNEL_OUTPUT}"
assert_no_device_reachability_files

UNREACHABLE_DEVICE_OUTPUT="${TMP_DIR}/unreachable-device.out"
set +e
run_lane "${UNREACHABLE_DEVICE_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  STUB_DEVICE_TUNNEL_STATE=disconnected \
  STUB_DEVICECTL_REACHABILITY_MODE=disconnected
unreachable_device_status=$?
set -e
if [[ "${unreachable_device_status}" -eq 0 ]]; then
  echo "Expected actively unreachable device lane to fail before xcodebuild" >&2
  cat "${UNREACHABLE_DEVICE_OUTPUT}" >&2
  exit 1
fi
assert_contains "selected device is paired but not actively reachable" "${UNREACHABLE_DEVICE_OUTPUT}"
assert_no_secret_output "${UNREACHABLE_DEVICE_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected unreachable device lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_redaction_token_files
assert_no_device_metadata_files
assert_no_device_reachability_files

LOCKED_DEVICE_OUTPUT="${TMP_DIR}/locked-device.out"
set +e
run_lane "${LOCKED_DEVICE_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  STUB_DEVICECTL_LOCK_STATE=locked
locked_device_status=$?
set -e
if [[ "${locked_device_status}" -eq 0 ]]; then
  echo "Expected locked device lane to fail before xcodebuild" >&2
  cat "${LOCKED_DEVICE_OUTPUT}" >&2
  exit 1
fi
assert_contains "selected device is locked; unlock it before starting the test lane" "${LOCKED_DEVICE_OUTPUT}"
assert_no_secret_output "${LOCKED_DEVICE_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected locked device lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_redaction_token_files
assert_no_device_metadata_files
assert_no_device_reachability_files

INVALID_OS_MAJOR_OUTPUT="${TMP_DIR}/invalid-os-major.out"
set +e
run_lane "${INVALID_OS_MAJOR_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27.0
invalid_os_major_status=$?
set -e
if [[ "${invalid_os_major_status}" -ne 64 ]]; then
  echo "Expected invalid OS-major lane to exit 64, got ${invalid_os_major_status}" >&2
  cat "${INVALID_OS_MAJOR_OUTPUT}" >&2
  exit 1
fi
assert_contains "SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR must be a positive integer OS major" "${INVALID_OS_MAJOR_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected invalid OS-major lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi

INVALID_BOOLEAN_OUTPUT="${TMP_DIR}/invalid-boolean.out"
set +e
run_lane "${INVALID_BOOLEAN_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=yes
invalid_boolean_status=$?
set -e
if [[ "${invalid_boolean_status}" -ne 64 ]]; then
  echo "Expected invalid boolean lane to exit 64, got ${invalid_boolean_status}" >&2
  cat "${INVALID_BOOLEAN_OUTPUT}" >&2
  exit 1
fi
assert_contains "SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD must be 0 or 1" "${INVALID_BOOLEAN_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected invalid boolean lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi

INVALID_DESTINATION_TIMEOUT_OUTPUT="${TMP_DIR}/invalid-destination-timeout.out"
set +e
run_lane "${INVALID_DESTINATION_TIMEOUT_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS=0
invalid_destination_timeout_status=$?
set -e
if [[ "${invalid_destination_timeout_status}" -ne 64 ]]; then
  echo "Expected invalid destination-timeout lane to exit 64, got ${invalid_destination_timeout_status}" >&2
  cat "${INVALID_DESTINATION_TIMEOUT_OUTPUT}" >&2
  exit 1
fi
assert_contains "SKYBRIDGE_IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS must be a positive integer" "${INVALID_DESTINATION_TIMEOUT_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected invalid destination-timeout lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi

UNSUPPORTED_ENV_OUTPUT="${TMP_DIR}/unsupported-env.out"
set +e
run_lane "${UNSUPPORTED_ENV_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_TRUST_ME=1
unsupported_env_status=$?
set -e
if [[ "${unsupported_env_status}" -ne 64 ]]; then
  echo "Expected unsupported env lane to exit 64, got ${unsupported_env_status}" >&2
  cat "${UNSUPPORTED_ENV_OUTPUT}" >&2
  exit 1
fi
assert_contains "unsupported environment variable: SKYBRIDGE_IOS_DEVICE_TRUST_ME" "${UNSUPPORTED_ENV_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected unsupported env lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi

DISABLED_DEVELOPER_MODE_OUTPUT="${TMP_DIR}/disabled-developer-mode.out"
set +e
run_lane "${DISABLED_DEVELOPER_MODE_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  STUB_DEVICE_DEVELOPER_MODE_STATUS=disabled
disabled_developer_mode_status=$?
set -e
if [[ "${disabled_developer_mode_status}" -eq 0 ]]; then
  echo "Expected disabled developer-mode lane to fail before xcodebuild" >&2
  cat "${DISABLED_DEVELOPER_MODE_OUTPUT}" >&2
  exit 1
fi
assert_contains "Requested iOS device does not satisfy required constraints" "${DISABLED_DEVELOPER_MODE_OUTPUT}"
assert_no_secret_output "${DISABLED_DEVELOPER_MODE_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected disabled developer-mode lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_redaction_token_files
assert_no_device_metadata_files

NOT_FOUND_OUTPUT="${TMP_DIR}/not-found.out"
set +e
run_lane "${NOT_FOUND_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-NOT-FOUND \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1
not_found_status=$?
set -e
if [[ "${not_found_status}" -eq 0 ]]; then
  echo "Expected not-found lane to fail" >&2
  cat "${NOT_FOUND_OUTPUT}" >&2
  exit 1
fi
assert_contains "Requested iOS device was not found by devicectl." "${NOT_FOUND_OUTPUT}"
assert_not_contains "SECRET-NOT-FOUND" "${NOT_FOUND_OUTPUT}"
assert_no_secret_output "${NOT_FOUND_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected not-found lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_redaction_token_files
assert_no_device_metadata_files

DEVICECTL_FAIL_OUTPUT="${TMP_DIR}/devicectl-fail.out"
set +e
run_lane "${DEVICECTL_FAIL_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  STUB_DEVICECTL_MODE=fail
devicectl_fail_status=$?
set -e
if [[ "${devicectl_fail_status}" -eq 0 ]]; then
  echo "Expected devicectl-fail lane to fail" >&2
  cat "${DEVICECTL_FAIL_OUTPUT}" >&2
  exit 1
fi
assert_contains "devicectl device list failed exit=67" "${DEVICECTL_FAIL_OUTPUT}"
assert_no_secret_output "${DEVICECTL_FAIL_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected devicectl-fail lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_redaction_token_files
assert_no_device_metadata_files

MISMATCH_OUTPUT="${TMP_DIR}/mismatch.out"
set +e
run_lane "${MISMATCH_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=26 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1
mismatch_status=$?
set -e
if [[ "${mismatch_status}" -eq 0 ]]; then
  echo "Expected constraint-mismatch lane to fail" >&2
  cat "${MISMATCH_OUTPUT}" >&2
  exit 1
fi
assert_contains "Requested iOS device does not satisfy required constraints" "${MISMATCH_OUTPUT}"
assert_no_secret_output "${MISMATCH_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected constraint-mismatch lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_redaction_token_files
assert_no_device_metadata_files

FAIL_OUTPUT="${TMP_DIR}/xcodebuild-fail.out"
set +e
run_lane "${FAIL_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  STUB_XCODEBUILD_MODE=fail
fail_status=$?
set -e
if [[ "${fail_status}" -eq 0 ]]; then
  echo "Expected xcodebuild-fail lane to fail" >&2
  cat "${FAIL_OUTPUT}" >&2
  exit 1
fi
assert_contains "error: failed for <ios-device-sha256:" "${FAIL_OUTPUT}"
assert_no_secret_output "${FAIL_OUTPUT}"
assert_no_redaction_token_files
assert_no_device_metadata_files

MISSING_DEVICE_SUPPORT_OUTPUT="${TMP_DIR}/missing-device-support.out"
set +e
run_lane "${MISSING_DEVICE_SUPPORT_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS=1 \
  SKYBRIDGE_IOS_DEVICE_SUPPORT_ROOT="${TMP_DIR}/MissingDeviceSupport"
missing_device_support_status=$?
set -e
if [[ "${missing_device_support_status}" -eq 0 ]]; then
  echo "Expected missing-device-support lane to fail before xcodebuild" >&2
  cat "${MISSING_DEVICE_SUPPORT_OUTPUT}" >&2
  exit 1
fi
assert_contains "missing DeviceSupport symbols for clean-log testing" "${MISSING_DEVICE_SUPPORT_OUTPUT}"
assert_contains "iPad16,3 27.0 (24A5355q)/Symbols" "${MISSING_DEVICE_SUPPORT_OUTPUT}"
assert_contains "iPad16,3 27.0 (24A5355q)/arm64e/Symbols" "${MISSING_DEVICE_SUPPORT_OUTPUT}"
assert_no_secret_output "${MISSING_DEVICE_SUPPORT_OUTPUT}"
if [[ -s "${CALL_LOG}" ]]; then
  echo "Expected missing-device-support lane to avoid xcodebuild calls" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_no_redaction_token_files
assert_no_device_metadata_files

CLEAN_LOG_OUTPUT="${TMP_DIR}/clean-log.out"
set +e
run_lane "${CLEAN_LOG_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS=1 \
  STUB_XCODEBUILD_MODE=warning
clean_log_status=$?
set -e
if [[ "${clean_log_status}" -eq 0 ]]; then
  echo "Expected clean-log lane to fail on warning" >&2
  cat "${CLEAN_LOG_OUTPUT}" >&2
  exit 1
fi
assert_contains "emitted warnings/errors under clean-log gate" "${CLEAN_LOG_OUTPUT}"
assert_contains "<ios-device-sha256:" "${CLEAN_LOG_OUTPUT}"
assert_no_secret_output "${CLEAN_LOG_OUTPUT}"
assert_no_redaction_token_files
assert_no_device_metadata_files

DUPLICATE_CLASS_OUTPUT="${TMP_DIR}/duplicate-class.out"
set +e
run_lane "${DUPLICATE_CLASS_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS=1 \
  STUB_XCODEBUILD_MODE=duplicate_class
duplicate_class_status=$?
set -e
if [[ "${duplicate_class_status}" -eq 0 ]]; then
  echo "Expected clean-log lane to fail on an Objective-C duplicate class diagnostic" >&2
  cat "${DUPLICATE_CLASS_OUTPUT}" >&2
  exit 1
fi
assert_contains "emitted warnings/errors under clean-log gate" "${DUPLICATE_CLASS_OUTPUT}"
assert_contains "Class RTCVideoFrame is implemented in both <tmp>/Frameworks/WebRTC.framework/WebRTC" "${DUPLICATE_CLASS_OUTPUT}"
assert_contains "One of the duplicates must be removed or renamed." "${DUPLICATE_CLASS_OUTPUT}"
assert_no_secret_output "${DUPLICATE_CLASS_OUTPUT}"
assert_no_redaction_token_files
assert_no_device_metadata_files
assert_no_device_reachability_files

XPC_RUNTIME_ERROR_OUTPUT="${TMP_DIR}/xpc-runtime-error.out"
set +e
run_lane "${XPC_RUNTIME_ERROR_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS=1 \
  STUB_XCODEBUILD_MODE=xpc_runtime_error
xpc_runtime_error_status=$?
set -e
if [[ "${xpc_runtime_error_status}" -eq 0 ]]; then
  echo "Expected clean-log lane to fail on an explicit XPC runtime error" >&2
  cat "${XPC_RUNTIME_ERROR_OUTPUT}" >&2
  exit 1
fi
assert_contains "emitted warnings/errors under clean-log gate" "${XPC_RUNTIME_ERROR_OUTPUT}"
assert_contains "[XPCErrors] non-launching port" "${XPC_RUNTIME_ERROR_OUTPUT}"
assert_no_secret_output "${XPC_RUNTIME_ERROR_OUTPUT}"
assert_no_redaction_token_files
assert_no_device_metadata_files
assert_no_device_reachability_files

# The benign Xcode arch-fallback DeviceSupport diagnostic must NOT trip the
# clean-log gate when device-specific symbols are present.
BENIGN_DEVICE_SUPPORT_OUTPUT="${TMP_DIR}/benign-device-support.out"
set +e
run_lane "${BENIGN_DEVICE_SUPPORT_OUTPUT}" env \
  SKYBRIDGE_IOS_DEVICE_ID=SECRET-SERIAL-456 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27 \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta \
  SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1 \
  SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS=1 \
  STUB_XCODEBUILD_MODE=benign_device_support
benign_device_support_status=$?
set -e
if [[ "${benign_device_support_status}" -ne 0 ]]; then
  echo "Expected clean-log lane to pass when only the benign DeviceSupport arch-fallback line is present" >&2
  cat "${BENIGN_DEVICE_SUPPORT_OUTPUT}" >&2
  exit 1
fi
assert_not_contains "emitted warnings/errors under clean-log gate" "${BENIGN_DEVICE_SUPPORT_OUTPUT}"
assert_contains "full suite passed on device" "${BENIGN_DEVICE_SUPPORT_OUTPUT}"
assert_no_secret_output "${BENIGN_DEVICE_SUPPORT_OUTPUT}"
assert_no_redaction_token_files
assert_no_device_metadata_files

echo "test_lane_ios_device privacy tests passed"
