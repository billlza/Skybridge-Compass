#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_SCRIPT="${ROOT_DIR}/Scripts/run_os27_beta_compatibility.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-os27-diagnose-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${TMP_DIR}/bin" "${TMP_DIR}/Xcode-beta.app/Contents/Developer" "${TMP_DIR}/Xcode-beta.app/Contents/MacOS"
CALL_LOG="${TMP_DIR}/calls.log"
export STUB_CALL_LOG="${CALL_LOG}"
export STUB_REPO_ROOT="${ROOT_DIR}"

cat >"${TMP_DIR}/bin/bash" <<'SH'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
  *"SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh")
    printf 'bash-device-lane %s required_os=%s release=%s require_ipad=%s only_testing=%s\n' \
      "$*" \
      "${SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR:-}" \
      "${SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE:-}" \
      "${SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD:-}" \
      "${SKYBRIDGE_IOS_DEVICE_ONLY_TESTING:-}" >>"${STUB_CALL_LOG}"
    exit "${STUB_IOS_DEVICE_TEST_EXIT:-0}"
    ;;
  *"Scripts/check_ios_test_configuration.sh")
    printf 'bash-ios-config %s\n' "$*" >>"${STUB_CALL_LOG}"
    exit 0
    ;;
esac
exec /bin/bash "$@"
SH

cat >"${TMP_DIR}/Xcode-beta.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.apple.dt.Xcode</string>
  <key>CFBundleShortVersionString</key>
  <string>27.0</string>
  <key>ProductBuildVersion</key>
  <string>27A5194q</string>
</dict>
</plist>
PLIST
printf '#!/usr/bin/env bash\nexit 0\n' >"${TMP_DIR}/Xcode-beta.app/Contents/MacOS/Xcode"
printf 'simulated beta package timestamp anomaly\n' >"${TMP_DIR}/Xcode-beta.app/Contents/Developer/LegacyTimestamp"
touch -t 197001010000.01 "${TMP_DIR}/Xcode-beta.app/Contents/Developer/LegacyTimestamp"
chmod +x "${TMP_DIR}/Xcode-beta.app/Contents/MacOS/Xcode"

cat >"${TMP_DIR}/bin/xcode-select" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-p" ]]; then
  printf '%s\n' "${STUB_XCODE_SELECT_PATH:-/Applications/Xcode.app/Contents/Developer}"
  exit 0
fi
exit 64
SH

cat >"${TMP_DIR}/bin/strings" <<'SH'
#!/bin/bash
set -euo pipefail
env -u DEVELOPER_DIR /usr/bin/strings "$@"
SH

cat >"${TMP_DIR}/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodebuild %s\n' "$*" >>"${STUB_CALL_LOG}"
if [[ -n "${STUB_XCODEBUILD_SLEEP_SECONDS:-}" ]]; then
  sleep "${STUB_XCODEBUILD_SLEEP_SECONDS}"
fi
if [[ "${1:-}" == "-version" ]]; then
  printf 'Xcode %s\nBuild version %s\n' "${STUB_XCODE_VERSION:-27.0}" "${STUB_XCODE_BUILD:-27A5194q}"
  exit 0
fi
if [[ "$*" == *"-project "* && "$*" == *" build"* ]]; then
  printf 'xcodebuild private output path=%s app=%s repo=%s\n' \
    "${TMPDIR:-/tmp}/skybridge-os27-xcodebuild/private.log" \
    "/Applications/Xcode-beta.app/Contents/Developer" \
    "${STUB_REPO_ROOT}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
  exit 0
fi
exit 42
SH

cat >"${TMP_DIR}/bin/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'swift-direct %s\n' "$*" >>"${STUB_CALL_LOG}"
if [[ -n "${STUB_SWIFT_SLEEP_SECONDS:-}" ]]; then
  sleep "${STUB_SWIFT_SLEEP_SECONDS}"
fi
if [[ "${1:-}" == "build" && "${STUB_SWIFT_BUILD_WARNING:-0}" == "1" ]]; then
  echo "WARNING: fake SwiftPM clean-log warning"
  exit 0
fi
scratch_path=""
previous=""
for arg in "$@"; do
  if [[ "${previous}" == "--scratch-path" ]]; then
    scratch_path="${arg}"
    break
  fi
  previous="${arg}"
done
if [[ "${1:-}" == "build" ]]; then
  printf 'swift-stub scratch=%s args=%s\n' "${scratch_path}" "$*" >>"${STUB_CALL_LOG}"
  if [[ -n "${scratch_path}" ]]; then
    mkdir -p "${scratch_path}/debug/WebRTC.framework"
    mkdir -p "${scratch_path}/out/Products/Debug/WebRTC.framework"
    mkdir -p "${scratch_path}/out/Products/Debug"
    printf 'fake-webrtc-runtime' >"${scratch_path}/debug/WebRTC.framework/WebRTC"
    printf 'fake-webrtc-runtime' >"${scratch_path}/out/Products/Debug/WebRTC.framework/WebRTC"
    printf 'skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk\n' >"${scratch_path}/debug/SkyBridgeCompassApp"
    printf 'skybridge.apple-pqc-sdk.compile-fact.v1.has-apple-pqc-sdk\n' >"${scratch_path}/out/Products/Debug/SkyBridgeCompassApp"
    chmod 755 "${scratch_path}/debug/SkyBridgeCompassApp"
    chmod 755 "${scratch_path}/out/Products/Debug/SkyBridgeCompassApp"
    printf 'swift-stub executable debug=%s out=%s\n' \
      "$(test -x "${scratch_path}/debug/SkyBridgeCompassApp" && printf yes || printf no)" \
      "$(test -x "${scratch_path}/out/Products/Debug/SkyBridgeCompassApp" && printf yes || printf no)" >>"${STUB_CALL_LOG}"
  fi
  exit 0
fi
if [[ "${1:-}" == "test" ]]; then
  exit 0
fi
exit 43
SH

cat >"${TMP_DIR}/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >>"${STUB_CALL_LOG}"

if [[ "${1:-}" == "swift" && "${2:-}" == "--version" ]]; then
  printf 'Apple Swift version 7.0 (swiftlang-7.0.0 clang-1800.0.0)\n'
  exit 0
fi

if [[ "${1:-}" == "--sdk" && "${3:-}" == "--show-sdk-version" ]]; then
  case "${2:-}" in
    macosx)
      printf '%s\n' "${STUB_MACOS_SDK:-27.0}"
      ;;
    iphoneos)
      printf '%s\n' "${STUB_IPHONEOS_SDK:-27.0}"
      ;;
    iphonesimulator)
      printf '%s\n' "${STUB_IPHONESIM_SDK:-27.0}"
      ;;
    *)
      exit 65
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "--sdk" && "${3:-}" == "--show-sdk-path" ]]; then
  printf '/FakeSDKs/%s.sdk\n' "${2:-unknown}"
  exit 0
fi

if [[ "${1:-}" == "--sdk" && "${3:-}" == "swiftc" ]]; then
  sdk="${2:-unknown}"
  shift 3
  printf 'xcrun-pqc-swiftc sdk=%s args=%s\n' "${sdk}" "$*" >>"${STUB_CALL_LOG}"
  if [[ "${STUB_PQC_SWIFTC_FAIL:-}" == "1" || "${STUB_PQC_SWIFTC_FAIL:-}" == "${sdk}" ]]; then
    echo "${TMPDIR:-/tmp}/skybridge-apple-pqc-probe/probe.swift:1:1: error: fake Apple PQC typecheck failure for ${sdk}" >&2
    exit 1
  fi
  if [[ "$*" == *"apple-macosx27.0"* || "$*" == *"apple-ios27.0"* ]]; then
    if [[ "${STUB_NETWORK_TLS_SWIFTC_SUCCEED:-0}" != "1" ]]; then
      echo "${TMPDIR:-/tmp}/skybridge-network-tls-pqc-probe/probe.swift:5:26: error: cannot find 'SwiftTLSOptions' in scope" >&2
      echo "type 'KeyExchangeGroup' has no member 'x25519MLKEM768'" >&2
      exit 1
    fi
  fi
  exit 0
fi

if [[ "${1:-}" == "devicectl" && "${2:-}" == "list" && "${3:-}" == "devices" && "${4:-}" == "--json-output" ]]; then
  output_path="${5:?missing json output path}"
  emit_devices_json() {
    if [[ "${STUB_DEVICE_PRESENT:-1}" == "1" ]]; then
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
          "developerModeStatus": "${STUB_DEVICE_DEVELOPER_MODE_STATUS:-enabled}",
          "osVersionNumber": "27.0",
          "releaseType": "${STUB_DEVICE_RELEASE_TYPE:-Beta}"
        },
        "hardwareProperties": {
          "platform": "iOS",
          "deviceType": "iPad",
          "udid": "SECRET-HW-UDID-789",
          "serialNumber": "SECRET-SERIAL-456"
        }
      }
    ]
  }
}
JSON
    else
      cat <<'JSON'
{
  "result": {
    "devices": []
  }
}
JSON
    fi
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

exit 66
SH

cat >"${TMP_DIR}/bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$*" >>"${STUB_CALL_LOG}"

for arg in "$@"; do
  if [[ "${arg}" == "--verify" ]]; then
    if [[ -n "${STUB_CODESIGN_VERIFY_SLEEP_SECONDS:-}" ]]; then
      sleep "${STUB_CODESIGN_VERIFY_SLEEP_SECONDS}"
    fi
    if [[ "${STUB_CODESIGN_VERIFY_FAIL:-0}" == "1" ]]; then
      echo "SECRET-CODESIGN-VERIFY-DETAIL" >&2
      exit 1
    fi
    exit 0
  fi
done

if [[ "${STUB_CODESIGN_METADATA_FAIL:-0}" == "1" ]]; then
  echo "SECRET-CODESIGN-METADATA-DETAIL" >&2
  exit 1
fi

cat >&2 <<'OUT'
Executable=/tmp/SECRET/Xcode-beta.app/Contents/MacOS/Xcode
Identifier=com.apple.dt.Xcode
CDHash=SECRET-CDHASH
Authority=Software Signing
Authority=Apple Code Signing Certification Authority
Authority=Apple Root CA
Signed Time=Jun 7, 2026 at 03:09:49
TeamIdentifier=SECRET-TEAMID
OUT
exit 0
SH

cat >"${TMP_DIR}/bin/spctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'spctl %s\n' "$*" >>"${STUB_CALL_LOG}"

if [[ "${1:-}" == "--status" ]]; then
  printf 'assessments %s\n' "${STUB_SPCTL_ASSESSMENTS:-disabled}"
  exit "${STUB_SPCTL_STATUS_EXIT:-0}"
fi

if [[ "${1:-}" == "--assess" ]]; then
  if [[ "${STUB_SPCTL_ASSESS_FAIL:-0}" == "1" ]]; then
    echo "rejected SECRET-GATEKEEPER-DETAIL" >&2
    exit 1
  fi
  echo "accepted SECRET-GATEKEEPER-DETAIL" >&2
  exit 0
fi

exit 64
SH

cat >"${TMP_DIR}/bin/xattr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xattr %s\n' "$*" >>"${STUB_CALL_LOG}"

if [[ "${1:-}" == "-p" && "${2:-}" == "com.apple.quarantine" ]]; then
  if [[ "${STUB_QUARANTINE_PRESENT:-0}" == "1" ]]; then
    printf '%s\n' '0081;SECRET-QUARANTINE-UUID;Atlas;https://secret.example/xcode.xip'
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "-p" && "${2:-}" == "com.apple.provenance" ]]; then
  if [[ "${STUB_PROVENANCE_PRESENT:-1}" == "1" ]]; then
    printf '%s\n' 'SECRET-PROVENANCE'
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "-d" || "${1:-}" == "-dr" || "${1:-}" == "-w" ]]; then
  echo "diagnostic must not mutate xattrs" >&2
  exit 88
fi

exit 64
SH

chmod +x \
  "${TMP_DIR}/bin/bash" \
  "${TMP_DIR}/bin/strings" \
  "${TMP_DIR}/bin/xcode-select" \
  "${TMP_DIR}/bin/xcodebuild" \
  "${TMP_DIR}/bin/swift" \
  "${TMP_DIR}/bin/xcrun" \
  "${TMP_DIR}/bin/codesign" \
  "${TMP_DIR}/bin/spctl" \
  "${TMP_DIR}/bin/xattr"

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

assert_contains "bash Scripts/test_rust_cli_remote_desktop_contract_gate.sh" "${TARGET_SCRIPT}"

assert_json_value() {
  local json_file="$1"
  local dotted_path="$2"
  local expected="$3"

  python3 - "${json_file}" "${dotted_path}" "${expected}" <<'PY'
import json
import sys

json_file, dotted_path, expected = sys.argv[1:]
with open(json_file, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

value = payload
for part in dotted_path.split("."):
    value = value[part]

if isinstance(value, bool):
    actual = "true" if value else "false"
elif isinstance(value, list):
    actual = " ".join(str(item) for item in value)
else:
    actual = str(value)

if actual != expected:
    raise SystemExit(f"Expected {dotted_path} to be {expected!r}, got {actual!r}")
PY
}

run_diagnose() {
  local output_file="$1"
  local report_file="${output_file}.json"
  local status=0
  shift

  if PATH="${TMP_DIR}/bin:${PATH}" \
    DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
    SKYBRIDGE_OS27_COMPAT_REPORT_PATH="${report_file}" \
    "$@" \
    bash "${TARGET_SCRIPT}" --diagnose-environment >"${output_file}" 2>&1; then
    status=0
  else
    status=$?
  fi
  return "${status}"
}

READY_OUTPUT="${TMP_DIR}/ready.out"
set +e
run_diagnose "${READY_OUTPUT}" env
ready_status=$?
set -e
if [[ "${ready_status}" -ne 0 ]]; then
  echo "Expected ready diagnostic run to exit 0, got ${ready_status}" >&2
  cat "${READY_OUTPUT}" >&2
  exit 1
fi

assert_contains "full_validation=false" "${READY_OUTPUT}"
assert_contains "compatibility=not_validated" "${READY_OUTPUT}"
assert_contains "coverage=toolchain_sdk_device_readiness_only" "${READY_OUTPUT}"
assert_contains "developer_dir_override=present path=<tmp>" "${READY_OUTPUT}"
assert_contains "selected_developer_dir=present path=<tmp>" "${READY_OUTPUT}"
assert_contains "requirement xcode27=present" "${READY_OUTPUT}"
assert_contains "requirement sdk27=present" "${READY_OUTPUT}"
assert_contains "xcode27_bundle_complete=1" "${READY_OUTPUT}"
assert_contains "xcode27_bundle_info identifier=com.apple.dt.Xcode short_version=27.0 build=27A5194q" "${READY_OUTPUT}"
assert_contains "xcode27_bundle_timestamp_anomalies early_mtime_file_count=1 future_mtime_file_count=0" "${READY_OUTPUT}"
assert_contains "evidence=metadata_only action=record_only" "${READY_OUTPUT}"
assert_contains "xcode27_bundle_codesign_metadata status=ok identifier=com.apple.dt.Xcode authority=apple_software_signing team_identifier=present cdhash=present signed_time=present" "${READY_OUTPUT}"
assert_contains "xcode27_bundle_codesign_verify status=ok" "${READY_OUTPUT}"
assert_contains "xcode27_bundle_quarantine status=absent" "${READY_OUTPUT}"
assert_contains "xcode27_bundle_provenance_xattr status=present" "${READY_OUTPUT}"
assert_contains "xcode27_gatekeeper_assessments status=disabled" "${READY_OUTPUT}"
assert_contains "xcode27_bundle_gatekeeper status=not_run reason=assessments_disabled" "${READY_OUTPUT}"
assert_contains "xcode27_bundle_diagnostic ready=1 compatibility=not_validated release_eligible=false evidence=environment_metadata_only" "${READY_OUTPUT}"
assert_contains "xcode27_build_consistency status=matched bundle_build=27A5194q xcodebuild_build=27A5194q release_eligible=false" "${READY_OUTPUT}"
assert_contains "matching_ipados27_beta_ipad_count=1" "${READY_OUTPUT}"
assert_contains "ready_ipados27_beta_ipad_count=1" "${READY_OUTPUT}"
assert_contains "candidate_ipados27_ipad_count=1" "${READY_OUTPUT}"
assert_contains "ready_ipados27_ipad_candidate_count=1" "${READY_OUTPUT}"
assert_contains "device_ready=1" "${READY_OUTPUT}"
assert_contains "full_validation=not_run compatibility=not_validated" "${READY_OUTPUT}"
assert_not_contains "Sensitive iPad" "${READY_OUTPUT}"
assert_not_contains "SECRET-UDID-123" "${READY_OUTPUT}"
assert_not_contains "SECRET-HW-UDID-789" "${READY_OUTPUT}"
assert_not_contains "SECRET-SERIAL-456" "${READY_OUTPUT}"
assert_not_contains "secret-ipad.local" "${READY_OUTPUT}"
assert_not_contains "secret-ipad-alt.local" "${READY_OUTPUT}"
assert_not_contains "SECRET-CDHASH" "${READY_OUTPUT}"
assert_not_contains "SECRET-TEAMID" "${READY_OUTPUT}"
assert_not_contains "SECRET-PROVENANCE" "${READY_OUTPUT}"
assert_not_contains "SECRET-QUARANTINE" "${READY_OUTPUT}"
assert_not_contains "SECRET-GATEKEEPER" "${READY_OUTPUT}"
assert_not_contains "${TMP_DIR}/Xcode-beta.app/Contents/Developer" "${READY_OUTPUT}"
assert_not_contains "[os27-beta-compat] passed" "${READY_OUTPUT}"

assert_contains "xcodebuild -version" "${CALL_LOG}"
assert_contains "xcrun swift --version" "${CALL_LOG}"
assert_contains "xcrun --sdk macosx --show-sdk-version" "${CALL_LOG}"
assert_contains "xcrun --sdk iphoneos --show-sdk-version" "${CALL_LOG}"
assert_contains "xcrun --sdk iphonesimulator --show-sdk-version" "${CALL_LOG}"
assert_contains "xcrun devicectl list devices --json-output" "${CALL_LOG}"
assert_contains "codesign -dv --verbose=4" "${CALL_LOG}"
assert_contains "codesign --verify --strict --verbose=2" "${CALL_LOG}"
assert_contains "spctl --status" "${CALL_LOG}"
assert_contains "xattr -p com.apple.quarantine" "${CALL_LOG}"
assert_not_contains "xattr -d" "${CALL_LOG}"
assert_not_contains "xattr -dr" "${CALL_LOG}"
assert_not_contains "xattr -w" "${CALL_LOG}"
assert_not_contains "swift-direct test" "${CALL_LOG}"
assert_not_contains "xcodebuild -project" "${CALL_LOG}"
assert_not_contains "test_lane_ios_device" "${CALL_LOG}"

READY_REPORT="${READY_OUTPUT}.json"
assert_json_value "${READY_REPORT}" "mode" "diagnose"
assert_json_value "${READY_REPORT}" "status" "diagnose_ready"
assert_json_value "${READY_REPORT}" "compatibility" "not_validated"
assert_json_value "${READY_REPORT}" "release_eligible" "false"
assert_json_value "${READY_REPORT}" "full_validation" "false"
assert_json_value "${READY_REPORT}" "full_validation_attempted" "false"
assert_json_value "${READY_REPORT}" "full_validation_passed" "false"
assert_json_value "${READY_REPORT}" "toolchain.xcode27_ready" "true"
assert_json_value "${READY_REPORT}" "toolchain.sdk27_ready" "true"
assert_json_value "${READY_REPORT}" "xcode_beta_bundle.ready" "true"
assert_json_value "${READY_REPORT}" "xcode_beta_bundle.build_consistency" "matched"
assert_json_value "${READY_REPORT}" "xcode_beta_bundle.gatekeeper_assessments" "disabled"
assert_json_value "${READY_REPORT}" "xcode_beta_bundle.gatekeeper_bundle" "not_run_assessments_disabled"
assert_json_value "${READY_REPORT}" "xcode_beta_bundle.timestamp_anomalies.early_mtime_file_count" "1"
assert_json_value "${READY_REPORT}" "xcode_beta_bundle.timestamp_anomalies.future_mtime_file_count" "0"
assert_json_value "${READY_REPORT}" "xcode_beta_bundle.timestamp_anomalies.action" "record_only"
assert_json_value "${READY_REPORT}" "device_readiness.required_ipados27_device_ready" "true"

STDOUT_JSON_OUTPUT="${TMP_DIR}/stdout-json.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${STDOUT_JSON_OUTPUT}" env \
  STUB_DEVICECTL_JSON_OUTPUT_MODE=stdout_mixed
stdout_json_status=$?
set -e
if [[ "${stdout_json_status}" -ne 0 ]]; then
  echo "Expected stdout-json diagnostic run to exit 0, got ${stdout_json_status}" >&2
  cat "${STDOUT_JSON_OUTPUT}" >&2
  exit 1
fi
assert_contains "device_ready=1" "${STDOUT_JSON_OUTPUT}"
assert_contains "ready_ipados27_ipad_candidate_count=1" "${STDOUT_JSON_OUTPUT}"
assert_contains "xcrun devicectl list devices --json-output -" "${CALL_LOG}"
assert_not_contains "Sensitive iPad" "${STDOUT_JSON_OUTPUT}"
assert_not_contains "SECRET-UDID-123" "${STDOUT_JSON_OUTPUT}"
assert_not_contains "secret-ipad.local" "${STDOUT_JSON_OUTPUT}"
assert_json_value "${STDOUT_JSON_OUTPUT}.json" "device_readiness.required_ipados27_device_ready" "true"

BUILD_MISMATCH_OUTPUT="${TMP_DIR}/build-mismatch.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${BUILD_MISMATCH_OUTPUT}" env \
  STUB_XCODE_BUILD=27A5194z
build_mismatch_status=$?
set -e
if [[ "${build_mismatch_status}" -ne 0 ]]; then
  echo "Expected build-mismatch diagnostic run to remain usable but not release-eligible, got ${build_mismatch_status}" >&2
  cat "${BUILD_MISMATCH_OUTPUT}" >&2
  exit 1
fi
assert_contains "xcode27_build_consistency status=metadata_mismatch bundle_build=27A5194q xcodebuild_build=27A5194z release_eligible=false" "${BUILD_MISMATCH_OUTPUT}"
assert_json_value "${BUILD_MISMATCH_OUTPUT}.json" "xcode_beta_bundle.build_consistency" "metadata_mismatch"
assert_json_value "${BUILD_MISMATCH_OUTPUT}.json" "release_eligible" "false"

SPCTL_DISABLED_NONZERO_OUTPUT="${TMP_DIR}/spctl-disabled-nonzero.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${SPCTL_DISABLED_NONZERO_OUTPUT}" env \
  STUB_SPCTL_STATUS_EXIT=1
spctl_disabled_nonzero_status=$?
set -e
if [[ "${spctl_disabled_nonzero_status}" -ne 0 ]]; then
  echo "Expected disabled Gatekeeper diagnostic with non-zero spctl status to exit 0, got ${spctl_disabled_nonzero_status}" >&2
  cat "${SPCTL_DISABLED_NONZERO_OUTPUT}" >&2
  exit 1
fi
assert_contains "xcode27_gatekeeper_assessments status=disabled" "${SPCTL_DISABLED_NONZERO_OUTPUT}"
assert_contains "xcode27_bundle_gatekeeper status=not_run reason=assessments_disabled" "${SPCTL_DISABLED_NONZERO_OUTPUT}"
assert_not_contains "assessment_status_unavailable" "${SPCTL_DISABLED_NONZERO_OUTPUT}"

UNKNOWN_RELEASE_OUTPUT="${TMP_DIR}/unknown-release.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${UNKNOWN_RELEASE_OUTPUT}" env \
  STUB_DEVICE_RELEASE_TYPE=unknown \
  STUB_DEVICE_DEVELOPER_MODE_STATUS=unknown
unknown_release_status=$?
set -e
if [[ "${unknown_release_status}" -ne 2 ]]; then
  echo "Expected unknown developer-mode diagnostic candidate to exit 2, got ${unknown_release_status}" >&2
  cat "${UNKNOWN_RELEASE_OUTPUT}" >&2
  exit 1
fi
assert_contains "matching_ipados27_beta_ipad_count=0" "${UNKNOWN_RELEASE_OUTPUT}"
assert_contains "ready_ipados27_beta_ipad_count=0" "${UNKNOWN_RELEASE_OUTPUT}"
assert_contains "candidate_ipados27_ipad_count=1" "${UNKNOWN_RELEASE_OUTPUT}"
assert_contains "ready_ipados27_ipad_candidate_count=0" "${UNKNOWN_RELEASE_OUTPUT}"
assert_contains "developer_mode_enabled=0" "${UNKNOWN_RELEASE_OUTPUT}"
assert_contains "developer_mode_unknown=1" "${UNKNOWN_RELEASE_OUTPUT}"
assert_contains "device_ready=0" "${UNKNOWN_RELEASE_OUTPUT}"
assert_not_contains "Sensitive iPad" "${UNKNOWN_RELEASE_OUTPUT}"
assert_not_contains "SECRET-UDID-123" "${UNKNOWN_RELEASE_OUTPUT}"
assert_not_contains "secret-ipad.local" "${UNKNOWN_RELEASE_OUTPUT}"

UNKNOWN_RELEASE_READY_CANDIDATE_OUTPUT="${TMP_DIR}/unknown-release-ready-candidate.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${UNKNOWN_RELEASE_READY_CANDIDATE_OUTPUT}" env \
  STUB_DEVICE_RELEASE_TYPE=unknown
unknown_release_ready_candidate_status=$?
set -e
if [[ "${unknown_release_ready_candidate_status}" -ne 2 ]]; then
  echo "Expected releaseType=unknown candidate to remain not ready for required beta proof, got ${unknown_release_ready_candidate_status}" >&2
  cat "${UNKNOWN_RELEASE_READY_CANDIDATE_OUTPUT}" >&2
  exit 1
fi
assert_contains "matching_ipados27_beta_ipad_count=0" "${UNKNOWN_RELEASE_READY_CANDIDATE_OUTPUT}"
assert_contains "ready_ipados27_beta_ipad_count=0" "${UNKNOWN_RELEASE_READY_CANDIDATE_OUTPUT}"
assert_contains "candidate_ipados27_ipad_count=1" "${UNKNOWN_RELEASE_READY_CANDIDATE_OUTPUT}"
assert_contains "ready_ipados27_ipad_candidate_count=1" "${UNKNOWN_RELEASE_READY_CANDIDATE_OUTPUT}"
assert_contains "device_ready=0" "${UNKNOWN_RELEASE_READY_CANDIDATE_OUTPUT}"

QUARANTINE_OUTPUT="${TMP_DIR}/quarantine.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${QUARANTINE_OUTPUT}" env \
  STUB_QUARANTINE_PRESENT=1
quarantine_status=$?
set -e
if [[ "${quarantine_status}" -ne 2 ]]; then
  echo "Expected quarantine diagnostic run to exit 2, got ${quarantine_status}" >&2
  cat "${QUARANTINE_OUTPUT}" >&2
  exit 1
fi
assert_contains "xcode27_bundle_quarantine status=present" "${QUARANTINE_OUTPUT}"
assert_contains "xcode27_bundle_diagnostic ready=0 compatibility=not_validated release_eligible=false evidence=environment_metadata_only" "${QUARANTINE_OUTPUT}"
assert_contains "full_validation=not_run compatibility=not_validated" "${QUARANTINE_OUTPUT}"
assert_not_contains "SECRET-QUARANTINE" "${QUARANTINE_OUTPUT}"
assert_not_contains "https://secret.example" "${QUARANTINE_OUTPUT}"
assert_not_contains "[os27-beta-compat] passed" "${QUARANTINE_OUTPUT}"

CODESIGN_FAILURE_OUTPUT="${TMP_DIR}/codesign-failure.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${CODESIGN_FAILURE_OUTPUT}" env \
  STUB_CODESIGN_VERIFY_FAIL=1
codesign_failure_status=$?
set -e
if [[ "${codesign_failure_status}" -ne 2 ]]; then
  echo "Expected codesign failure diagnostic run to exit 2, got ${codesign_failure_status}" >&2
  cat "${CODESIGN_FAILURE_OUTPUT}" >&2
  exit 1
fi
assert_contains "xcode27_bundle_codesign_verify status=failed" "${CODESIGN_FAILURE_OUTPUT}"
assert_contains "xcode27_bundle_diagnostic ready=0 compatibility=not_validated release_eligible=false evidence=environment_metadata_only" "${CODESIGN_FAILURE_OUTPUT}"
assert_not_contains "SECRET-CODESIGN-VERIFY-DETAIL" "${CODESIGN_FAILURE_OUTPUT}"

CODESIGN_TIMEOUT_OUTPUT="${TMP_DIR}/codesign-timeout.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${CODESIGN_TIMEOUT_OUTPUT}" env \
  SKYBRIDGE_OS27_BUNDLE_VERIFY_TIMEOUT_SECONDS=1 \
  STUB_CODESIGN_VERIFY_SLEEP_SECONDS=2
codesign_timeout_status=$?
set -e
if [[ "${codesign_timeout_status}" -ne 2 ]]; then
  echo "Expected codesign timeout diagnostic run to exit 2, got ${codesign_timeout_status}" >&2
  cat "${CODESIGN_TIMEOUT_OUTPUT}" >&2
  exit 1
fi
assert_contains "xcode27_bundle_codesign_verify status=toolchain_invocation_timeout" "${CODESIGN_TIMEOUT_OUTPUT}"
assert_contains "xcode27_bundle_diagnostic ready=0 compatibility=not_validated release_eligible=false evidence=environment_metadata_only" "${CODESIGN_TIMEOUT_OUTPUT}"

MISSING_PLIST_OUTPUT="${TMP_DIR}/missing-plist.out"
mv "${TMP_DIR}/Xcode-beta.app/Contents/Info.plist" "${TMP_DIR}/Xcode-beta.app/Contents/Info.plist.bak"
: >"${CALL_LOG}"
set +e
run_diagnose "${MISSING_PLIST_OUTPUT}" env
missing_plist_status=$?
set -e
mv "${TMP_DIR}/Xcode-beta.app/Contents/Info.plist.bak" "${TMP_DIR}/Xcode-beta.app/Contents/Info.plist"
if [[ "${missing_plist_status}" -ne 2 ]]; then
  echo "Expected missing Info.plist diagnostic run to exit 2, got ${missing_plist_status}" >&2
  cat "${MISSING_PLIST_OUTPUT}" >&2
  exit 1
fi
assert_contains "xcode27_bundle_complete=0" "${MISSING_PLIST_OUTPUT}"
assert_contains "missing_required_paths=info_plist" "${MISSING_PLIST_OUTPUT}"
assert_contains "xcode27_bundle_diagnostic ready=0 compatibility=not_validated release_eligible=false evidence=environment_metadata_only" "${MISSING_PLIST_OUTPUT}"

SPCTL_ENABLED_OUTPUT="${TMP_DIR}/spctl-enabled.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${SPCTL_ENABLED_OUTPUT}" env \
  STUB_SPCTL_ASSESSMENTS=enabled
spctl_enabled_status=$?
set -e
if [[ "${spctl_enabled_status}" -ne 0 ]]; then
  echo "Expected enabled Gatekeeper accepted diagnostic run to exit 0, got ${spctl_enabled_status}" >&2
  cat "${SPCTL_ENABLED_OUTPUT}" >&2
  exit 1
fi
assert_contains "xcode27_gatekeeper_assessments status=enabled" "${SPCTL_ENABLED_OUTPUT}"
assert_contains "xcode27_bundle_gatekeeper status=accepted" "${SPCTL_ENABLED_OUTPUT}"
assert_not_contains "SECRET-GATEKEEPER-DETAIL" "${SPCTL_ENABLED_OUTPUT}"

SPCTL_REJECTED_OUTPUT="${TMP_DIR}/spctl-rejected.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${SPCTL_REJECTED_OUTPUT}" env \
  STUB_SPCTL_ASSESSMENTS=enabled \
  STUB_SPCTL_ASSESS_FAIL=1
spctl_rejected_status=$?
set -e
if [[ "${spctl_rejected_status}" -ne 2 ]]; then
  echo "Expected rejected Gatekeeper diagnostic run to exit 2, got ${spctl_rejected_status}" >&2
  cat "${SPCTL_REJECTED_OUTPUT}" >&2
  exit 1
fi
assert_contains "xcode27_bundle_gatekeeper status=failed" "${SPCTL_REJECTED_OUTPUT}"
assert_contains "xcode27_bundle_diagnostic ready=0 compatibility=not_validated release_eligible=false evidence=environment_metadata_only" "${SPCTL_REJECTED_OUTPUT}"
assert_not_contains "SECRET-GATEKEEPER-DETAIL" "${SPCTL_REJECTED_OUTPUT}"

DISCONNECTED_OUTPUT="${TMP_DIR}/disconnected.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${DISCONNECTED_OUTPUT}" env \
  STUB_DEVICE_TUNNEL_STATE=disconnected
disconnected_status=$?
set -e
if [[ "${disconnected_status}" -ne 2 ]]; then
  echo "Expected disconnected diagnostic candidate to exit 2, got ${disconnected_status}" >&2
  cat "${DISCONNECTED_OUTPUT}" >&2
  exit 1
fi
assert_contains "matching_ipados27_beta_ipad_count=1" "${DISCONNECTED_OUTPUT}"
assert_contains "ready_ipados27_beta_ipad_count=0" "${DISCONNECTED_OUTPUT}"
assert_contains "candidate_ipados27_ipad_count=1" "${DISCONNECTED_OUTPUT}"
assert_contains "ready_ipados27_ipad_candidate_count=0" "${DISCONNECTED_OUTPUT}"
assert_contains "tunnel_available=1" "${DISCONNECTED_OUTPUT}"
assert_contains "tunnel_connected=0" "${DISCONNECTED_OUTPUT}"
assert_contains "device_ready=0" "${DISCONNECTED_OUTPUT}"
assert_not_contains "Sensitive iPad" "${DISCONNECTED_OUTPUT}"
assert_not_contains "SECRET-UDID-123" "${DISCONNECTED_OUTPUT}"
assert_not_contains "secret-ipad.local" "${DISCONNECTED_OUTPUT}"

INCOMPLETE_OUTPUT="${TMP_DIR}/incomplete.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${INCOMPLETE_OUTPUT}" env \
  STUB_XCODE_VERSION=26.5 \
  STUB_XCODE_BUILD=17F42 \
  STUB_MACOS_SDK=26.5 \
  STUB_IPHONEOS_SDK=26.5 \
  STUB_IPHONESIM_SDK=26.5 \
  STUB_DEVICE_PRESENT=0
incomplete_status=$?
set -e
if [[ "${incomplete_status}" -ne 2 ]]; then
  echo "Expected incomplete diagnostic run to exit 2, got ${incomplete_status}" >&2
  cat "${INCOMPLETE_OUTPUT}" >&2
  exit 1
fi

assert_contains "compatibility=not_validated" "${INCOMPLETE_OUTPUT}"
assert_contains "requirement xcode27=missing" "${INCOMPLETE_OUTPUT}"
assert_contains "requirement sdk27=missing" "${INCOMPLETE_OUTPUT}"
assert_contains "matching_ipados27_beta_ipad_count=0" "${INCOMPLETE_OUTPUT}"
assert_contains "candidate_ipados27_ipad_count=0" "${INCOMPLETE_OUTPUT}"
assert_contains "device_ready=0" "${INCOMPLETE_OUTPUT}"
assert_not_contains "[os27-beta-compat] passed" "${INCOMPLETE_OUTPUT}"
assert_not_contains "swift-direct test" "${CALL_LOG}"
assert_not_contains "xcodebuild -project" "${CALL_LOG}"

TIMEOUT_OUTPUT="${TMP_DIR}/timeout.out"
: >"${CALL_LOG}"
set +e
run_diagnose "${TIMEOUT_OUTPUT}" env \
  SKYBRIDGE_OS27_DIAGNOSTIC_TOOL_TIMEOUT_SECONDS=1 \
  STUB_XCODEBUILD_SLEEP_SECONDS=2
timeout_status=$?
set -e
if [[ "${timeout_status}" -ne 2 ]]; then
  echo "Expected timeout diagnostic run to exit 2, got ${timeout_status}" >&2
  cat "${TIMEOUT_OUTPUT}" >&2
  exit 1
fi
assert_contains "toolchain_probe=xcodebuild status=toolchain_invocation_timeout seconds=1" "${TIMEOUT_OUTPUT}"
assert_contains "compatibility=not_validated" "${TIMEOUT_OUTPUT}"
assert_contains "requirement xcode27=missing" "${TIMEOUT_OUTPUT}"
assert_not_contains "[os27-beta-compat] passed" "${TIMEOUT_OUTPUT}"
assert_not_contains "Sensitive iPad" "${TIMEOUT_OUTPUT}"
assert_not_contains "SECRET-UDID-123" "${TIMEOUT_OUTPUT}"
assert_not_contains "xcodebuild -project" "${CALL_LOG}"

SKIP_OUTPUT="${TMP_DIR}/skip-build-gates.out"
SKIP_REPORT="${TMP_DIR}/skip-build-gates.json"
: >"${CALL_LOG}"
set +e
PATH="${TMP_DIR}/bin:${PATH}" \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  SKYBRIDGE_OS27_COMPAT_REPORT_PATH="${SKIP_REPORT}" \
  SKYBRIDGE_OS27_SKIP_IOS_GENERIC_BUILD=1 \
  SKYBRIDGE_OS27_SKIP_IOS_SIMULATOR_BUILD=1 \
  bash "${TARGET_SCRIPT}" >"${SKIP_OUTPUT}" 2>&1
skip_status=$?
set -e
if [[ "${skip_status}" -ne 2 ]]; then
  echo "Expected full validation with skipped iOS build gates to exit 2, got ${skip_status}" >&2
  cat "${SKIP_OUTPUT}" >&2
  exit 1
fi
assert_contains "skipped_iOS_build_gates=generic-iOS iOS-Simulator" "${SKIP_OUTPUT}"
assert_contains "compatibility=partial_not_validated" "${SKIP_OUTPUT}"
assert_not_contains "[os27-beta-compat] passed" "${SKIP_OUTPUT}"
assert_not_contains "xcodebuild -project" "${CALL_LOG}"
assert_json_value "${SKIP_REPORT}" "mode" "validate"
assert_json_value "${SKIP_REPORT}" "status" "partial"
assert_json_value "${SKIP_REPORT}" "compatibility" "partial_not_validated"
assert_json_value "${SKIP_REPORT}" "release_eligible" "false"
assert_json_value "${SKIP_REPORT}" "full_validation" "false"
assert_json_value "${SKIP_REPORT}" "full_validation_attempted" "true"
assert_json_value "${SKIP_REPORT}" "full_validation_passed" "false"
assert_json_value "${SKIP_REPORT}" "gates.skipped_ios_build_gates" "generic-iOS iOS-Simulator"
assert_json_value "${SKIP_REPORT}" "gates.swiftpm_filtered_tests" "not_run"
assert_json_value "${SKIP_REPORT}" "gates.source_contracts" "not_run"

FULL_XCODE_BUILD_MISMATCH_OUTPUT="${TMP_DIR}/full-xcode-build-mismatch.out"
FULL_XCODE_BUILD_MISMATCH_REPORT="${TMP_DIR}/full-xcode-build-mismatch.json"
: >"${CALL_LOG}"
set +e
PATH="${TMP_DIR}/bin:${PATH}" \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  SKYBRIDGE_OS27_COMPAT_REPORT_PATH="${FULL_XCODE_BUILD_MISMATCH_REPORT}" \
  SKYBRIDGE_OS27_RUN_IOS_DEVICE_TESTS=1 \
  STUB_XCODE_BUILD=27A5194z \
  bash "${TARGET_SCRIPT}" >"${FULL_XCODE_BUILD_MISMATCH_OUTPUT}" 2>&1
full_xcode_build_mismatch_status=$?
set -e
if [[ "${full_xcode_build_mismatch_status}" -ne 0 ]]; then
  echo "Expected OS27 full validation to continue through Xcode bundle/xcodebuild metadata mismatch, got ${full_xcode_build_mismatch_status}" >&2
  cat "${FULL_XCODE_BUILD_MISMATCH_OUTPUT}" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_contains "xcode27_build_consistency status=metadata_mismatch bundle_build=27A5194q xcodebuild_build=27A5194z release_eligible=false" "${FULL_XCODE_BUILD_MISMATCH_OUTPUT}"
assert_contains "xcode27_build_consistency action=record_only status=metadata_mismatch compatibility=not_validated release_eligible=false" "${FULL_XCODE_BUILD_MISMATCH_OUTPUT}"
assert_contains "[os27-beta-compat] passed" "${FULL_XCODE_BUILD_MISMATCH_OUTPUT}"
assert_contains "swift-direct build --scratch-path" "${CALL_LOG}"
assert_contains "swift-direct test --scratch-path" "${CALL_LOG}"
assert_contains "xcodebuild -project SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" "${CALL_LOG}"
assert_contains "bash-device-lane SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh" "${CALL_LOG}"
assert_json_value "${FULL_XCODE_BUILD_MISMATCH_REPORT}" "mode" "validate"
assert_json_value "${FULL_XCODE_BUILD_MISMATCH_REPORT}" "status" "passed"
assert_json_value "${FULL_XCODE_BUILD_MISMATCH_REPORT}" "compatibility" "validated"
assert_json_value "${FULL_XCODE_BUILD_MISMATCH_REPORT}" "release_eligible" "false"
assert_json_value "${FULL_XCODE_BUILD_MISMATCH_REPORT}" "full_validation" "true"
assert_json_value "${FULL_XCODE_BUILD_MISMATCH_REPORT}" "full_validation_attempted" "true"
assert_json_value "${FULL_XCODE_BUILD_MISMATCH_REPORT}" "full_validation_passed" "true"
assert_json_value "${FULL_XCODE_BUILD_MISMATCH_REPORT}" "toolchain.xcodebuild_build" "27A5194z"
assert_json_value "${FULL_XCODE_BUILD_MISMATCH_REPORT}" "toolchain.xcode27_ready" "true"
assert_json_value "${FULL_XCODE_BUILD_MISMATCH_REPORT}" "xcode_beta_bundle.ready" "true"
assert_json_value "${FULL_XCODE_BUILD_MISMATCH_REPORT}" "xcode_beta_bundle.build_consistency" "metadata_mismatch"

FULL_SUCCESS_OUTPUT="${TMP_DIR}/full-success.out"
FULL_SUCCESS_REPORT="${TMP_DIR}/full-success.json"
: >"${CALL_LOG}"
set +e
PATH="${TMP_DIR}/bin:${PATH}" \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  SKYBRIDGE_OS27_COMPAT_REPORT_PATH="${FULL_SUCCESS_REPORT}" \
  SKYBRIDGE_OS27_RUN_IOS_DEVICE_TESTS=1 \
  bash "${TARGET_SCRIPT}" >"${FULL_SUCCESS_OUTPUT}" 2>&1
full_success_status=$?
set -e
if [[ "${full_success_status}" -ne 0 ]]; then
  echo "Expected OS27 full validation success fixture to exit 0, got ${full_success_status}" >&2
  cat "${FULL_SUCCESS_OUTPUT}" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_contains "[os27-beta-compat] passed" "${FULL_SUCCESS_OUTPUT}"
assert_contains "Network TLS PQC public API probe: sdk=macosx status=unavailable mode=symbol_probe_failed releaseEligible=false affectsCryptoSuiteSelection=false" "${FULL_SUCCESS_OUTPUT}"
assert_contains "xcodebuild private output path=<tmp> app=<applications>/Xcode-beta.app/Contents/Developer repo=<repo>/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" "${FULL_SUCCESS_OUTPUT}"
assert_not_contains "${TMP_DIR}/skybridge-os27-xcodebuild/private.log" "${FULL_SUCCESS_OUTPUT}"
assert_not_contains "/Applications/Xcode-beta.app/Contents/Developer" "${FULL_SUCCESS_OUTPUT}"
assert_not_contains "${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" "${FULL_SUCCESS_OUTPUT}"
assert_contains "swift-direct build --scratch-path" "${CALL_LOG}"
assert_contains "swift-direct test --scratch-path" "${CALL_LOG}"
assert_contains "--disable-prefetching" "${CALL_LOG}"
assert_contains "xcodebuild -project SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" "${CALL_LOG}"
assert_contains "bash-device-lane SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh" "${CALL_LOG}"
assert_contains "required_os=27 release=Beta require_ipad=1" "${CALL_LOG}"
assert_contains "only_testing=SkyBridgeCompassiOSTests/ApplePQCProviderRuntimeSelfTestTests/testApplePQCAndXWingProbesGenerateKeysOnAvailableRuntime" "${CALL_LOG}"
assert_json_value "${FULL_SUCCESS_REPORT}" "mode" "validate"
assert_json_value "${FULL_SUCCESS_REPORT}" "status" "passed"
assert_json_value "${FULL_SUCCESS_REPORT}" "compatibility" "validated"
assert_json_value "${FULL_SUCCESS_REPORT}" "release_eligible" "false"
assert_json_value "${FULL_SUCCESS_REPORT}" "full_validation" "true"
assert_json_value "${FULL_SUCCESS_REPORT}" "full_validation_attempted" "true"
assert_json_value "${FULL_SUCCESS_REPORT}" "full_validation_passed" "true"
assert_json_value "${FULL_SUCCESS_REPORT}" "toolchain.xcode27_ready" "true"
assert_json_value "${FULL_SUCCESS_REPORT}" "toolchain.sdk27_ready" "true"
assert_json_value "${FULL_SUCCESS_REPORT}" "xcode_beta_bundle.ready" "true"
assert_json_value "${FULL_SUCCESS_REPORT}" "xcode_beta_bundle.build_consistency" "matched"
assert_json_value "${FULL_SUCCESS_REPORT}" "pqc_symbol_probe_details.macosx.symbol_set" "cryptokit-pqc-os27-v1"
assert_json_value "${FULL_SUCCESS_REPORT}" "pqc_symbol_probe_details.macosx.secure_enclave_symbols_included" "true"
assert_json_value "${FULL_SUCCESS_REPORT}" "pqc_symbol_probe_details.macosx.proof_scope" "cryptokit_compile_time_symbol_surface_only"
assert_json_value "${FULL_SUCCESS_REPORT}" "pqc_symbol_probe_details.macosx.affects_session_status" "false"
assert_json_value "${FULL_SUCCESS_REPORT}" "pqc_symbol_probe_details.macosx.affects_network_tls_pqc" "false"
assert_json_value "${FULL_SUCCESS_REPORT}" "pqc_symbol_probe_details.macosx.release_eligible" "false"
assert_json_value "${FULL_SUCCESS_REPORT}" "network_tls_pqc_symbol_probe_details.macosx.status" "unavailable"
assert_json_value "${FULL_SUCCESS_REPORT}" "network_tls_pqc_symbol_probe_details.macosx.error_summary" "sdk=macosx target=arm64-apple-macosx27.0 version=27.0: <tmp> error: cannot find 'SwiftTLSOptions' in scope type 'KeyExchangeGroup' has no member 'x25519MLKEM768'"
assert_json_value "${FULL_SUCCESS_REPORT}" "gates.required_ios_device_test" "passed"
assert_json_value "${FULL_SUCCESS_REPORT}" "apple_quantum_secure_runtime_proof.status" "passed"
assert_json_value "${FULL_SUCCESS_REPORT}" "apple_quantum_secure_runtime_proof.proof_scope" "apple_cryptokit_runtime_self_test_only"
assert_json_value "${FULL_SUCCESS_REPORT}" "apple_quantum_secure_runtime_proof.session_negotiated" "false"
assert_json_value "${FULL_SUCCESS_REPORT}" "apple_quantum_secure_runtime_proof.affects_network_tls_pqc" "false"

WEAKENED_DEVICE_GATE_OUTPUT="${TMP_DIR}/weakened-device-gate.out"
WEAKENED_DEVICE_GATE_REPORT="${TMP_DIR}/weakened-device-gate.json"
: >"${CALL_LOG}"
set +e
PATH="${TMP_DIR}/bin:${PATH}" \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  SKYBRIDGE_OS27_COMPAT_REPORT_PATH="${WEAKENED_DEVICE_GATE_REPORT}" \
  SKYBRIDGE_OS27_RUN_IOS_DEVICE_TESTS=1 \
  SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=26 \
  bash "${TARGET_SCRIPT}" >"${WEAKENED_DEVICE_GATE_OUTPUT}" 2>&1
weakened_device_gate_status=$?
set -e
if [[ "${weakened_device_gate_status}" -eq 0 ]]; then
  echo "Expected OS27 full validation to reject weakened device OS major" >&2
  cat "${WEAKENED_DEVICE_GATE_OUTPUT}" >&2
  exit 1
fi
assert_contains "SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR must be 27" "${WEAKENED_DEVICE_GATE_OUTPUT}"
assert_not_contains "[os27-beta-compat] passed" "${WEAKENED_DEVICE_GATE_OUTPUT}"
assert_not_contains "bash-device-lane SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh" "${CALL_LOG}"
assert_json_value "${WEAKENED_DEVICE_GATE_REPORT}" "mode" "validate"
assert_json_value "${WEAKENED_DEVICE_GATE_REPORT}" "status" "failed"
assert_json_value "${WEAKENED_DEVICE_GATE_REPORT}" "compatibility" "not_validated"
assert_json_value "${WEAKENED_DEVICE_GATE_REPORT}" "release_eligible" "false"
assert_json_value "${WEAKENED_DEVICE_GATE_REPORT}" "full_validation" "false"
assert_json_value "${WEAKENED_DEVICE_GATE_REPORT}" "full_validation_passed" "false"
assert_json_value "${WEAKENED_DEVICE_GATE_REPORT}" "gates.required_ios_device_test" "failed"

PARTIAL_WITHOUT_DEVICE_OUTPUT="${TMP_DIR}/partial-without-device.out"
PARTIAL_WITHOUT_DEVICE_REPORT="${TMP_DIR}/partial-without-device.json"
: >"${CALL_LOG}"
set +e
PATH="${TMP_DIR}/bin:${PATH}" \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  SKYBRIDGE_OS27_COMPAT_REPORT_PATH="${PARTIAL_WITHOUT_DEVICE_REPORT}" \
  SKYBRIDGE_OS27_ALLOW_PARTIAL_WITHOUT_DEVICE=1 \
  bash "${TARGET_SCRIPT}" >"${PARTIAL_WITHOUT_DEVICE_OUTPUT}" 2>&1
partial_without_device_status=$?
set -e
if [[ "${partial_without_device_status}" -ne 2 ]]; then
  echo "Expected OS27 validation without required device runtime proof to exit 2, got ${partial_without_device_status}" >&2
  cat "${PARTIAL_WITHOUT_DEVICE_OUTPUT}" >&2
  cat "${CALL_LOG}" >&2
  exit 1
fi
assert_contains "iOS 27 beta physical-device PQC runtime tests were not run" "${PARTIAL_WITHOUT_DEVICE_OUTPUT}"
assert_contains "compatibility=partial_not_validated" "${PARTIAL_WITHOUT_DEVICE_OUTPUT}"
assert_not_contains "[os27-beta-compat] passed" "${PARTIAL_WITHOUT_DEVICE_OUTPUT}"
assert_contains "swift-direct build --scratch-path" "${CALL_LOG}"
assert_contains "swift-direct test --scratch-path" "${CALL_LOG}"
assert_contains "--disable-prefetching" "${CALL_LOG}"
assert_contains "xcodebuild -project SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" "${CALL_LOG}"
assert_not_contains "bash-device-lane SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh" "${CALL_LOG}"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "mode" "validate"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "status" "partial"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "compatibility" "partial_not_validated"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "release_eligible" "false"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "full_validation" "false"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "full_validation_attempted" "true"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "full_validation_passed" "false"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "pqc_symbol_probe_details.macosx.symbol_set" "cryptokit-pqc-os27-v1"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "pqc_symbol_probe_details.macosx.proof_scope" "cryptokit_compile_time_symbol_surface_only"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "network_tls_pqc_symbol_probe_details.macosx.status" "unavailable"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "gates.swiftpm_app_build" "passed"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "gates.swiftpm_filtered_tests" "passed"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "gates.generic_ios_build" "passed"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "gates.ios_simulator_build" "passed"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "gates.required_ios_device_test" "skipped"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "apple_quantum_secure_runtime_proof.status" "skipped"
assert_json_value "${PARTIAL_WITHOUT_DEVICE_REPORT}" "apple_quantum_secure_runtime_proof.session_negotiated" "false"

PQC_FAILURE_OUTPUT="${TMP_DIR}/pqc-failure.out"
PQC_FAILURE_REPORT="${TMP_DIR}/pqc-failure.json"
: >"${CALL_LOG}"
set +e
PATH="${TMP_DIR}/bin:${PATH}" \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  SKYBRIDGE_OS27_COMPAT_REPORT_PATH="${PQC_FAILURE_REPORT}" \
  STUB_PQC_SWIFTC_FAIL=macosx \
  bash "${TARGET_SCRIPT}" >"${PQC_FAILURE_OUTPUT}" 2>&1
pqc_failure_status=$?
set -e
if [[ "${pqc_failure_status}" -eq 0 ]]; then
  echo "Expected OS27 full validation to fail closed when Apple PQC symbol probe fails" >&2
  cat "${PQC_FAILURE_OUTPUT}" >&2
  exit 1
fi
assert_contains "Apple PQC SDK symbol probe failed for macosx" "${PQC_FAILURE_OUTPUT}"
assert_contains "symbol_probe_failed" "${PQC_FAILURE_OUTPUT}"
assert_contains "<tmp> error: fake Apple PQC typecheck failure for macosx" "${PQC_FAILURE_OUTPUT}"
assert_contains "fake Apple PQC typecheck failure for macosx" "${PQC_FAILURE_OUTPUT}"
assert_not_contains "skybridge-apple-pqc-probe/probe.swift" "${PQC_FAILURE_OUTPUT}"
assert_not_contains "[os27-beta-compat] passed" "${PQC_FAILURE_OUTPUT}"
assert_contains "xcrun-pqc-swiftc sdk=macosx" "${CALL_LOG}"
assert_not_contains "swift-direct build" "${CALL_LOG}"
assert_not_contains "swift-direct test" "${CALL_LOG}"
assert_not_contains "xcodebuild -project" "${CALL_LOG}"
assert_json_value "${PQC_FAILURE_REPORT}" "mode" "validate"
assert_json_value "${PQC_FAILURE_REPORT}" "status" "failed"
assert_json_value "${PQC_FAILURE_REPORT}" "compatibility" "not_validated"
assert_json_value "${PQC_FAILURE_REPORT}" "release_eligible" "false"
assert_json_value "${PQC_FAILURE_REPORT}" "full_validation" "false"
assert_json_value "${PQC_FAILURE_REPORT}" "full_validation_attempted" "true"
assert_json_value "${PQC_FAILURE_REPORT}" "full_validation_passed" "false"
assert_json_value "${PQC_FAILURE_REPORT}" "pqc_symbol_probes.macosx" "failed"
assert_json_value "${PQC_FAILURE_REPORT}" "pqc_symbol_probes.iphoneos" "not_run"
assert_json_value "${PQC_FAILURE_REPORT}" "pqc_symbol_probe_details.macosx.status" "failed"
assert_json_value "${PQC_FAILURE_REPORT}" "pqc_symbol_probe_details.macosx.mode" "symbol_probe_failed"
assert_json_value "${PQC_FAILURE_REPORT}" "pqc_symbol_probe_details.macosx.sdk_name" "macosx"
assert_json_value "${PQC_FAILURE_REPORT}" "pqc_symbol_probe_details.macosx.sdk_version" "27.0"
assert_json_value "${PQC_FAILURE_REPORT}" "pqc_symbol_probe_details.macosx.swift_target" "arm64-apple-macosx26.0"
assert_json_value "${PQC_FAILURE_REPORT}" "pqc_symbol_probe_details.macosx.secure_enclave_symbols_included" "true"
assert_json_value "${PQC_FAILURE_REPORT}" "pqc_symbol_probe_details.macosx.symbol_set" "cryptokit-pqc-os27-v1"
assert_json_value "${PQC_FAILURE_REPORT}" "pqc_symbol_probe_details.macosx.proof_scope" "cryptokit_compile_time_symbol_surface_only"
assert_json_value "${PQC_FAILURE_REPORT}" "apple_quantum_secure_runtime_proof.status" "not_run"
assert_json_value "${PQC_FAILURE_REPORT}" "apple_quantum_secure_runtime_proof.required_device_test_identifier" "SkyBridgeCompassiOSTests/ApplePQCProviderRuntimeSelfTestTests/testApplePQCAndXWingProbesGenerateKeysOnAvailableRuntime"
assert_json_value "${PQC_FAILURE_REPORT}" "apple_quantum_secure_runtime_proof.requires_ipados27_beta_device" "true"
assert_json_value "${PQC_FAILURE_REPORT}" "apple_quantum_secure_runtime_proof.proof_scope" "apple_cryptokit_runtime_self_test_only"

REPORT_WRITE_FAILURE_OUTPUT="${TMP_DIR}/report-write-failure.out"
REPORT_WRITE_FAILURE_PARENT="${TMP_DIR}/report-parent-not-directory"
: >"${REPORT_WRITE_FAILURE_PARENT}"
: >"${CALL_LOG}"
set +e
PATH="${TMP_DIR}/bin:${PATH}" \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  SKYBRIDGE_OS27_COMPAT_REPORT_PATH="${REPORT_WRITE_FAILURE_PARENT}/compatibility-report.json" \
  STUB_PQC_SWIFTC_FAIL=macosx \
  bash "${TARGET_SCRIPT}" >"${REPORT_WRITE_FAILURE_OUTPUT}" 2>&1
report_write_failure_status=$?
set -e
if [[ "${report_write_failure_status}" -eq 0 ]]; then
  echo "Expected OS27 validation to fail when both the main lane and report write fail" >&2
  cat "${REPORT_WRITE_FAILURE_OUTPUT}" >&2
  exit 1
fi
assert_contains "Apple PQC SDK symbol probe failed for macosx" "${REPORT_WRITE_FAILURE_OUTPUT}"
assert_contains "failed to write compatibility report: <tmp>" "${REPORT_WRITE_FAILURE_OUTPUT}"
assert_not_contains "${REPORT_WRITE_FAILURE_PARENT}/compatibility-report.json" "${REPORT_WRITE_FAILURE_OUTPUT}"

SWIFTPM_WARNING_OUTPUT="${TMP_DIR}/swiftpm-warning.out"
SWIFTPM_WARNING_REPORT="${TMP_DIR}/swiftpm-warning.json"
: >"${CALL_LOG}"
set +e
PATH="${TMP_DIR}/bin:${PATH}" \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  SKYBRIDGE_OS27_COMPAT_REPORT_PATH="${SWIFTPM_WARNING_REPORT}" \
  STUB_SWIFT_BUILD_WARNING=1 \
  bash "${TARGET_SCRIPT}" >"${SWIFTPM_WARNING_OUTPUT}" 2>&1
swiftpm_warning_status=$?
set -e
if [[ "${swiftpm_warning_status}" -eq 0 ]]; then
  echo "Expected OS27 full validation to fail closed when SwiftPM emits warnings" >&2
  cat "${SWIFTPM_WARNING_OUTPUT}" >&2
  exit 1
fi
assert_contains "SwiftPM OS27 app build emitted warnings/errors under clean-log gate" "${SWIFTPM_WARNING_OUTPUT}"
assert_contains "WARNING: fake SwiftPM clean-log warning" "${SWIFTPM_WARNING_OUTPUT}"
assert_contains "SwiftPM OS27 app build failed clean-log gate" "${SWIFTPM_WARNING_OUTPUT}"
assert_not_contains "[os27-beta-compat] passed" "${SWIFTPM_WARNING_OUTPUT}"
assert_contains "swift-direct build --scratch-path" "${CALL_LOG}"
assert_not_contains "xcodebuild -project" "${CALL_LOG}"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "mode" "validate"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "status" "failed"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "compatibility" "not_validated"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "release_eligible" "false"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "full_validation" "false"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "full_validation_attempted" "true"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "full_validation_passed" "false"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "pqc_symbol_probe_details.macosx.status" "passed"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "pqc_symbol_probe_details.macosx.mode" "symbol_probe"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "pqc_symbol_probe_details.macosx.secure_enclave_symbols_included" "true"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "pqc_symbol_probe_details.macosx.symbol_set" "cryptokit-pqc-os27-v1"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "pqc_symbol_probe_details.macosx.affects_session_status" "false"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "network_tls_pqc_symbol_probe_details.macosx.status" "unavailable"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "network_tls_pqc_symbol_probe_details.macosx.error_summary" "sdk=macosx target=arm64-apple-macosx27.0 version=27.0: <tmp> error: cannot find 'SwiftTLSOptions' in scope type 'KeyExchangeGroup' has no member 'x25519MLKEM768'"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "pqc_symbol_probe_details.iphoneos.status" "passed"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "pqc_symbol_probe_details.iphonesimulator.status" "passed"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "gates.swiftpm_app_build" "failed"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "gates.swiftpm_app_apple_pqc_marker" "not_run"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "gates.source_contracts" "not_run"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "apple_quantum_secure_runtime_proof.status" "not_run"
assert_json_value "${SWIFTPM_WARNING_REPORT}" "apple_quantum_secure_runtime_proof.affects_network_tls_pqc" "false"

SWIFTPM_TIMEOUT_OUTPUT="${TMP_DIR}/swiftpm-timeout.out"
SWIFTPM_TIMEOUT_REPORT="${TMP_DIR}/swiftpm-timeout.json"
: >"${CALL_LOG}"
set +e
PATH="${TMP_DIR}/bin:${PATH}" \
  DEVELOPER_DIR="${TMP_DIR}/Xcode-beta.app/Contents/Developer" \
  SKYBRIDGE_OS27_COMPAT_REPORT_PATH="${SWIFTPM_TIMEOUT_REPORT}" \
  SKYBRIDGE_OS27_BUILD_GATE_TIMEOUT_SECONDS=1 \
  STUB_SWIFT_SLEEP_SECONDS=2 \
  bash "${TARGET_SCRIPT}" >"${SWIFTPM_TIMEOUT_OUTPUT}" 2>&1
swiftpm_timeout_status=$?
set -e
if [[ "${swiftpm_timeout_status}" -eq 0 ]]; then
  echo "Expected OS27 full validation to fail closed when SwiftPM times out" >&2
  cat "${SWIFTPM_TIMEOUT_OUTPUT}" >&2
  exit 1
fi
assert_contains "command timed out after 1 seconds; command redacted" "${SWIFTPM_TIMEOUT_OUTPUT}"
assert_not_contains "command timed out after 1 seconds: swift build --scratch-path" "${SWIFTPM_TIMEOUT_OUTPUT}"
assert_contains "SwiftPM OS27 app build timed out under clean-log gate after 1s" "${SWIFTPM_TIMEOUT_OUTPUT}"
assert_contains "SwiftPM OS27 app build failed clean-log gate" "${SWIFTPM_TIMEOUT_OUTPUT}"
assert_not_contains "[os27-beta-compat] passed" "${SWIFTPM_TIMEOUT_OUTPUT}"
assert_contains "swift-direct build --scratch-path" "${CALL_LOG}"
assert_not_contains "swift-direct test" "${CALL_LOG}"
assert_not_contains "xcodebuild -project" "${CALL_LOG}"
assert_json_value "${SWIFTPM_TIMEOUT_REPORT}" "mode" "validate"
assert_json_value "${SWIFTPM_TIMEOUT_REPORT}" "status" "failed"
assert_json_value "${SWIFTPM_TIMEOUT_REPORT}" "compatibility" "not_validated"
assert_json_value "${SWIFTPM_TIMEOUT_REPORT}" "release_eligible" "false"
assert_json_value "${SWIFTPM_TIMEOUT_REPORT}" "full_validation" "false"
assert_json_value "${SWIFTPM_TIMEOUT_REPORT}" "full_validation_attempted" "true"
assert_json_value "${SWIFTPM_TIMEOUT_REPORT}" "full_validation_passed" "false"
assert_json_value "${SWIFTPM_TIMEOUT_REPORT}" "gates.swiftpm_app_build" "failed"
assert_json_value "${SWIFTPM_TIMEOUT_REPORT}" "gates.swiftpm_filtered_tests" "not_run"
assert_json_value "${SWIFTPM_TIMEOUT_REPORT}" "gates.generic_ios_build" "not_run"
assert_json_value "${SWIFTPM_TIMEOUT_REPORT}" "apple_quantum_secure_runtime_proof.status" "not_run"

if ! grep -Fq 'run_xcodebuild_clean_log "generic iOS build"' "${TARGET_SCRIPT}"; then
  echo "Expected OS27 generic iOS build to use clean-log gate" >&2
  exit 1
fi
if ! grep -Fq 'run_xcodebuild_clean_log "iOS Simulator build"' "${TARGET_SCRIPT}"; then
  echo "Expected OS27 iOS Simulator build to use clean-log gate" >&2
  exit 1
fi

echo "run_os27_beta_compatibility diagnose tests passed"
