#!/usr/bin/env bash
# iOS 真机测试 lane（与模拟器 lane test_lane_ios.sh 互补）：
# - 模拟器 lane：覆盖“源码形状断言”类测试 + 运行时行为测试（仓库文件系统可见）。
# - 真机 lane：在真实 OS（如 iOS 27 beta）上覆盖运行时行为测试；
#   源码形状断言类测试在真机沙箱内无仓库文件，按设计 XCTSkip（见 SourceShapeTestSupport.swift）。
#
# 用法：
#   SKYBRIDGE_IOS_DEVICE_ID=<devicectl-identifier> bash test_lane_ios_device.sh
#   不指定时自动选择第一台符合约束的 paired/booted 真机。
#
# 可选约束：
#   SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR=27   只接受指定 major OS
#   SKYBRIDGE_IOS_DEVICE_MIN_OS_MAJOR=26        只接受不低于指定 major OS
#   SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE=Beta
#   SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD=1
#   SKYBRIDGE_IOS_DEVICE_ONLY_TESTING=Target/Class/testMethod
#   SKYBRIDGE_IOS_DEVICE_ALLOW_PROVISIONING_UPDATES=1
#   SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS=1
#   SKYBRIDGE_IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS=90
#   SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_PROJECT="${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompassiOSTests"
DEVICE_REDACTION_TOKENS_FILE="$(mktemp "${TMPDIR:-/tmp}/skybridge-ios-device-redaction.XXXXXX")"
DEVICE_METADATA_FILE="$(mktemp "${TMPDIR:-/tmp}/skybridge-ios-device-metadata.XXXXXX")"
IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS="${SKYBRIDGE_IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS:-90}"
DERIVED_DATA_PATH=""

cleanup_ios_device_lane() {
  rm -f "${DEVICE_REDACTION_TOKENS_FILE}"
  rm -f "${DEVICE_METADATA_FILE}"
  if [[ -n "${DERIVED_DATA_PATH}" ]]; then
    rm -rf "${DERIVED_DATA_PATH}"
  fi
}
trap cleanup_ios_device_lane EXIT

if [[ "$#" -ne 0 ]]; then
  echo "[iOS device lane] ERROR: unsupported command-line arguments; configure the lane through SKYBRIDGE_IOS_DEVICE_* environment variables." >&2
  exit 64
fi

validate_boolean_env() {
  local name="$1"
  local value="${!name:-}"
  if [[ -n "${value}" && "${value}" != "0" && "${value}" != "1" ]]; then
    echo "[iOS device lane] ERROR: ${name} must be 0 or 1, got: ${value}" >&2
    exit 64
  fi
}

validate_major_env() {
  local name="$1"
  local value="${!name:-}"
  if [[ -n "${value}" && ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[iOS device lane] ERROR: ${name} must be a positive integer OS major, got: ${value}" >&2
    exit 64
  fi
}

validate_positive_integer_env() {
  local name="$1"
  local value="${!name:-}"
  if [[ -n "${value}" && ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[iOS device lane] ERROR: ${name} must be a positive integer, got: ${value}" >&2
    exit 64
  fi
}

validate_release_type_env() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "${value}" ]]; then
    return 0
  fi

  case "${value}" in
    Beta | Release)
      ;;
    *)
      echo "[iOS device lane] ERROR: ${name} must be Beta or Release, got: ${value}" >&2
      exit 64
      ;;
  esac
}

validate_apple_pqc_sdk_condition_env() {
  case "${SKYBRIDGE_APPLE_PQC_SDK_CONDITION:-}" in
    "" | HAS_APPLE_PQC_SDK)
      ;;
    *)
      echo "[iOS device lane] ERROR: SKYBRIDGE_APPLE_PQC_SDK_CONDITION must be empty or HAS_APPLE_PQC_SDK, got: ${SKYBRIDGE_APPLE_PQC_SDK_CONDITION}" >&2
      exit 64
      ;;
  esac
}

validate_ios_device_environment() {
  local name
  while IFS='=' read -r name _; do
    [[ "${name}" == SKYBRIDGE_IOS_DEVICE_* ]] || continue
    case "${name}" in
      SKYBRIDGE_IOS_DEVICE_ID | \
      SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR | \
      SKYBRIDGE_IOS_DEVICE_MIN_OS_MAJOR | \
      SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE | \
      SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD | \
      SKYBRIDGE_IOS_DEVICE_ONLY_TESTING | \
      SKYBRIDGE_IOS_DEVICE_ALLOW_PROVISIONING_UPDATES | \
      SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS | \
      SKYBRIDGE_IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS | \
      SKYBRIDGE_IOS_DEVICE_SUPPORT_ROOT | \
      SKYBRIDGE_IOS_DEVICE_REDACTION_TOKENS_FILE | \
      SKYBRIDGE_IOS_DEVICE_METADATA_FILE)
        ;;
      *)
        echo "[iOS device lane] ERROR: unsupported environment variable: ${name}" >&2
        exit 64
        ;;
    esac
  done < <(env)

  validate_major_env SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR
  validate_major_env SKYBRIDGE_IOS_DEVICE_MIN_OS_MAJOR
  validate_boolean_env SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD
  validate_boolean_env SKYBRIDGE_IOS_DEVICE_ALLOW_PROVISIONING_UPDATES
  validate_boolean_env SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS
  validate_positive_integer_env SKYBRIDGE_IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS
  validate_release_type_env SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE
}

validate_ios_device_environment
validate_apple_pqc_sdk_condition_env

devicectl_devices_json_file_is_valid() {
  local payload_file="$1"
  [[ -s "${payload_file}" ]] || return 1
  python3 - "${payload_file}" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

if not isinstance(payload.get("result", {}).get("devices"), list):
    raise SystemExit(1)
PY
}

extract_devicectl_devices_json_from_stdout() {
  local stdout_file="$1"
  local payload_file="$2"
  python3 - "${stdout_file}" "${payload_file}" <<'PY'
import json
import sys
from pathlib import Path

stdout_path = Path(sys.argv[1])
payload_path = Path(sys.argv[2])
content = stdout_path.read_text(encoding="utf-8", errors="replace")

for index, character in enumerate(content):
    if character != "{":
        continue
    candidate = content[index:].strip()
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError:
        continue
    if not isinstance(payload.get("result", {}).get("devices"), list):
        continue
    payload_path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    raise SystemExit(0)

raise SystemExit(1)
PY
}

write_devicectl_devices_json() {
  local payload_file="$1"
  local stderr_file="$2"
  local stdout_file="${payload_file}.stdout"
  local status

  rm -f "${payload_file}" "${stdout_file}"
  if xcrun devicectl list devices --json-output "${payload_file}" >"${stdout_file}" 2>"${stderr_file}"; then
    if devicectl_devices_json_file_is_valid "${payload_file}"; then
      rm -f "${stdout_file}"
      return 0
    fi
    if extract_devicectl_devices_json_from_stdout "${stdout_file}" "${payload_file}"; then
      rm -f "${stdout_file}"
      return 0
    fi
  else
    status=$?
    rm -f "${stdout_file}"
    return "${status}"
  fi

  rm -f "${payload_file}" "${stdout_file}"
  if xcrun devicectl list devices --json-output - >"${stdout_file}" 2>"${stderr_file}"; then
    if extract_devicectl_devices_json_from_stdout "${stdout_file}" "${payload_file}"; then
      rm -f "${stdout_file}"
      return 0
    fi
    rm -f "${stdout_file}"
    return 70
  fi

  status=$?
  rm -f "${stdout_file}"
  return "${status}"
}

resolve_device_id() {
  local payload_dir
  local payload_file
  local stderr_file
  local status=0
  payload_dir="$(mktemp -d)"
  payload_file="${payload_dir}/devices.json"
  stderr_file="${payload_dir}/devicectl.stderr"
  trap 'rm -rf "${payload_dir}"' RETURN
  if write_devicectl_devices_json "${payload_file}" "${stderr_file}"; then
    :
  else
    status=$?
    echo "[iOS device lane] ERROR: devicectl device list failed exit=${status}" >&2
    return "${status}"
  fi
python3 - "${payload_file}" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

required_major = os.environ.get("SKYBRIDGE_IOS_DEVICE_REQUIRED_OS_MAJOR")
min_major = os.environ.get("SKYBRIDGE_IOS_DEVICE_MIN_OS_MAJOR")
required_release_type = os.environ.get("SKYBRIDGE_IOS_DEVICE_REQUIRE_RELEASE_TYPE")
require_ipad = os.environ.get("SKYBRIDGE_IOS_DEVICE_REQUIRE_IPAD") == "1"
requested_identifier = os.environ.get("SKYBRIDGE_IOS_DEVICE_ID")
redaction_tokens_path = os.environ.get("SKYBRIDGE_IOS_DEVICE_REDACTION_TOKENS_FILE")
device_metadata_path = os.environ.get("SKYBRIDGE_IOS_DEVICE_METADATA_FILE")

def parse_major(value):
    try:
        return int(str(value).split(".", 1)[0])
    except (TypeError, ValueError):
        return None

required_major = parse_major(required_major) if required_major else None
min_major = parse_major(min_major) if min_major else None

def identifier_candidates(device):
    conn = device.get("connectionProperties", {})
    hw = device.get("hardwareProperties", {})
    props = device.get("deviceProperties", {})
    values = [
        device.get("identifier"),
        hw.get("udid"),
        hw.get("serialNumber"),
        props.get("name"),
    ]
    values.extend(conn.get("localHostnames") or [])
    values.extend(conn.get("potentialHostnames") or [])
    return {str(value) for value in values if value}

def write_redaction_tokens(device=None):
    if not redaction_tokens_path:
        return

    tokens = set()
    if requested_identifier:
        tokens.add(str(requested_identifier))

    if isinstance(device, dict):
        tokens.update(identifier_candidates(device))

    with open(redaction_tokens_path, "w", encoding="utf-8") as handle:
        for token in sorted(tokens, key=lambda value: (-len(value), value)):
            handle.write(token + "\n")

def write_device_metadata(device):
    if not device_metadata_path:
        return

    hw = device.get("hardwareProperties", {})
    props = device.get("deviceProperties", {})
    cpu_type = hw.get("cpuType") or {}
    metadata = {
        "productType": hw.get("productType"),
        "cpuArchitecture": cpu_type.get("name"),
        "osVersionNumber": props.get("osVersionNumber"),
        "osBuildUpdate": props.get("osBuildUpdate"),
    }
    with open(device_metadata_path, "w", encoding="utf-8") as handle:
        json.dump(metadata, handle, sort_keys=True)

def matches_constraints(device):
    props = device.get("deviceProperties", {})
    conn = device.get("connectionProperties", {})
    hw = device.get("hardwareProperties", {})
    if conn.get("pairingState") != "paired":
        return False
    if conn.get("tunnelState") != "connected":
        return False
    if props.get("bootState") != "booted":
        return False
    if props.get("developerModeStatus") != "enabled":
        return False
    if hw.get("platform") != "iOS":
        return False
    if require_ipad and hw.get("deviceType") != "iPad":
        return False
    os_major = parse_major(props.get("osVersionNumber"))
    if required_major is not None and os_major != required_major:
        return False
    if min_major is not None and (os_major is None or os_major < min_major):
        return False
    if required_release_type and props.get("releaseType") != required_release_type:
        return False
    return True

def constraint_description():
    details = []
    if required_major is not None:
        details.append(f"os major == {required_major}")
    if min_major is not None:
        details.append(f"os major >= {min_major}")
    if required_release_type:
        details.append(f"releaseType == {required_release_type}")
    if require_ipad:
        details.append("deviceType == iPad")
    details.append("tunnelState == connected")
    return "; ".join(details)

devices = payload.get("result", {}).get("devices", [])

if requested_identifier:
    for device in devices:
        if requested_identifier not in identifier_candidates(device):
            continue
        if not matches_constraints(device):
            write_redaction_tokens(device)
            suffix = constraint_description()
            raise SystemExit(
                "Requested iOS device does not satisfy required constraints"
                + (f": {suffix}" if suffix else ".")
            )
        write_redaction_tokens(device)
        write_device_metadata(device)
        print(device["identifier"])
        break
    else:
        write_redaction_tokens()
        raise SystemExit("Requested iOS device was not found by devicectl.")
    raise SystemExit(0)

for device in devices:
    if not matches_constraints(device):
        continue
    write_redaction_tokens(device)
    write_device_metadata(device)
    print(device["identifier"])
    break
else:
    details = constraint_description()
    suffix = f" matching {details}" if details else ""
    raise SystemExit(f"No available paired booted iOS physical device found{suffix}.")
PY
}

DEVICE_ID="$(
  SKYBRIDGE_IOS_DEVICE_REDACTION_TOKENS_FILE="${DEVICE_REDACTION_TOKENS_FILE}" \
  SKYBRIDGE_IOS_DEVICE_METADATA_FILE="${DEVICE_METADATA_FILE}" \
    resolve_device_id
)"
DEVICE_LOG_LABEL="$(
  python3 - "${DEVICE_ID}" <<'PY'
import hashlib
import sys

value = sys.argv[1].encode("utf-8")
print("sha256:" + hashlib.sha256(value).hexdigest()[:12])
PY
)"
DERIVED_DATA_PATH="$(mktemp -d)"

redact_ios_device_log() {
  python3 - "${DEVICE_LOG_LABEL}" "${DEVICE_REDACTION_TOKENS_FILE}" "${ROOT_DIR}" "${DERIVED_DATA_PATH}" "${DEVICE_ID}" "${SKYBRIDGE_IOS_DEVICE_ID:-}" 3<&0 <<'PY'
import os
import re
import sys
from pathlib import Path

label = sys.argv[1]
tokens_path = Path(sys.argv[2])
root_dir = sys.argv[3]
derived_data_path = sys.argv[4]
tokens = [token for token in sys.argv[5:] if token]
if not tokens_path.exists():
    raise SystemExit("[iOS device lane] ERROR: missing iOS device redaction token file")
tokens.extend(
    token.strip()
    for token in tokens_path.read_text(encoding="utf-8").splitlines()
    if token.strip()
)
tokens = sorted(set(tokens), key=lambda token: (-len(token), token))
replacement = f"<ios-device-{label}>"
with os.fdopen(3, "r", encoding="utf-8", errors="replace") as input_stream:
    text = input_stream.read()
for token in tokens:
    text = text.replace(token, replacement)

path_replacements = []
for raw_path, redacted_path in [
    (derived_data_path, "<derived-data>"),
    (root_dir, "<repo>"),
    (os.environ.get("TMPDIR", "").rstrip("/"), "<tmp>"),
    (os.environ.get("HOME", ""), "<home>"),
]:
    if not raw_path:
        continue
    path_replacements.append((raw_path, redacted_path))
    path_replacements.append((os.path.normpath(raw_path), redacted_path))
for raw_path, redacted_path in sorted(
    ((raw, redacted) for raw, redacted in path_replacements if raw),
    key=lambda item: (-len(item[0]), item[0]),
):
    text = text.replace(raw_path, redacted_path)

text = re.sub(
    r"/Applications/([^/\s]+\.app)/Contents/Developer",
    r"<applications>/\1/Contents/Developer",
    text,
)
text = re.sub(r"/Applications/([^/\s]+\.app)", r"<applications>/\1", text)
text = re.sub(r"/var/folders/[^ \n\r\t]+", "<tmp>", text)
text = re.sub(r"/tmp/[^ \n\r\t]+", "<tmp>", text)
text = re.sub(
    r'Signing Identity:\s+"[^"]+"',
    'Signing Identity: "<redacted-signing-identity>"',
    text,
)
text = re.sub(
    r'Provisioning Profile:\s+"[^"]+"',
    'Provisioning Profile: "<redacted-provisioning-profile>"',
    text,
)
text = re.sub(
    r"\([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\)",
    "(<redacted-profile-uuid>)",
    text,
)
text = re.sub(
    r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b",
    "<redacted-uuid>",
    text,
)
text = re.sub(
    r"(--sign(?:ing-cert)?\s+)[0-9A-Fa-f]{40}",
    r"\1<redacted-signing-certificate>",
    text,
)
text = re.sub(
    r"(-signing-cert\s+)[0-9A-Fa-f]{40}",
    r"\1<redacted-signing-certificate>",
    text,
)
sys.stdout.write(text)
PY
}

run_xcodebuild_step() {
  local label="$1"
  local log_path="$2"
  shift 2

  local status=0
  if "$@" >"${log_path}" 2>&1; then
    status=0
  else
    status=$?
  fi

  redact_ios_device_log <"${log_path}"

  if [[ "${status}" -ne 0 ]]; then
    return "${status}"
  fi

  if [[ "${SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS:-0}" == "1" ]]; then
    local matches
    matches="$(
      { rg -n '(^|[^A-Za-z])warning:|(^|[^A-Za-z])error:|\bWARNING:\b|\bERROR:\b|Error locating DeviceSupport directory' "${log_path}" 2>/dev/null || true; }
    )"
    if [[ -n "${matches}" ]]; then
      echo "[iOS device lane] ERROR: ${label} emitted warnings/errors under clean-log gate" >&2
      redact_ios_device_log <<<"${matches}" >&2
      return 1
    fi
  fi
}

require_device_support_symbols_for_clean_log() {
  if [[ "${SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS:-0}" != "1" ]]; then
    return 0
  fi

  local support_root="${SKYBRIDGE_IOS_DEVICE_SUPPORT_ROOT:-${HOME}/Library/Developer/Xcode/iOS DeviceSupport}"
  local support_dir
  local resolution_status=0
  support_dir="$(
    python3 - "${DEVICE_METADATA_FILE}" "${support_root}" <<'PY'
import json
import sys
from pathlib import Path

metadata_path = Path(sys.argv[1])
support_root = Path(sys.argv[2])

try:
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit("missing selected-device metadata")

product_type = metadata.get("productType")
cpu_architecture = metadata.get("cpuArchitecture")
os_version = metadata.get("osVersionNumber")
os_build = metadata.get("osBuildUpdate")
if not product_type or not os_version or not os_build:
    raise SystemExit("selected-device metadata is missing productType/osVersionNumber/osBuildUpdate")

support_dir = support_root / f"{product_type} {os_version} ({os_build})"
candidates = [support_dir / "Symbols"]
if cpu_architecture:
    candidates.append(support_dir / cpu_architecture / "Symbols")

for candidate in candidates:
    if candidate.is_dir():
        print(candidate)
        raise SystemExit(0)

for candidate in candidates:
    print(candidate)
raise SystemExit(2)
PY
  )" || resolution_status=$?

  if [[ "${resolution_status}" -ne 0 && "${resolution_status}" -ne 2 ]]; then
    echo "[iOS device lane] ERROR: unable to resolve selected-device DeviceSupport symbols path" >&2
    return 1
  fi

  if [[ "${resolution_status}" -eq 2 ]]; then
    redact_ios_device_log <<<"[iOS device lane] ERROR: missing DeviceSupport symbols for clean-log testing: ${support_dir}" >&2
    echo "[iOS device lane] Install or prepare matching iOS DeviceSupport symbols before enabling SKYBRIDGE_IOS_DEVICE_ENFORCE_CLEAN_XCODE_LOGS=1." >&2
    return 1
  fi
}

echo "[iOS device lane] device=${DEVICE_LOG_LABEL}"
require_device_support_symbols_for_clean_log
echo "[iOS device lane] building for testing"

build_args=(
  xcodebuild
  -project "${IOS_PROJECT}" \
  -scheme "${IOS_SCHEME}" \
  -destination "platform=iOS,id=${DEVICE_ID}" \
  -destination-timeout "${IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS}" \
  -derivedDataPath "${DERIVED_DATA_PATH}"
)

if [[ "${SKYBRIDGE_IOS_DEVICE_ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
  build_args+=(-allowProvisioningUpdates)
fi

if [[ -n "${SKYBRIDGE_APPLE_PQC_SDK_CONDITION:-}" ]]; then
  build_args+=("SKYBRIDGE_APPLE_PQC_SDK_CONDITION=${SKYBRIDGE_APPLE_PQC_SDK_CONDITION}")
fi

build_args+=(
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  GCC_TREAT_WARNINGS_AS_ERRORS=YES
  build-for-testing
)

run_xcodebuild_step "build-for-testing" "${DERIVED_DATA_PATH}/build-for-testing.log" "${build_args[@]}"

echo "[iOS device lane] running full ${IOS_SCHEME} suite on device"

test_args=(
  xcodebuild
  -project "${IOS_PROJECT}" \
  -scheme "${IOS_SCHEME}" \
  -destination "platform=iOS,id=${DEVICE_ID}" \
  -destination-timeout "${IOS_DEVICE_DESTINATION_TIMEOUT_SECONDS}" \
  -derivedDataPath "${DERIVED_DATA_PATH}"
)

if [[ -n "${SKYBRIDGE_IOS_DEVICE_ONLY_TESTING:-}" ]]; then
  test_args+=("-only-testing:${SKYBRIDGE_IOS_DEVICE_ONLY_TESTING}")
fi

test_args+=(
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  GCC_TREAT_WARNINGS_AS_ERRORS=YES
  test-without-building
)

run_xcodebuild_step "test-without-building" "${DERIVED_DATA_PATH}/test-without-building.log" "${test_args[@]}"

echo "[iOS device lane] full suite passed on device"
