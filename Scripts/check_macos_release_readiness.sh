#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Check minimum macOS release readiness for SkyBridge Compass Pro.

Usage:
  check_macos_release_readiness.sh [options]

Options:
  --app-path <path>             App bundle to validate
  --dmg-path <path>             DMG to validate; defaults to dist/SkyBridgeCompassPro-<app-version>.dmg
  --source-info-plist <path>    Source Info.plist to compare product feature flags against
  --source-entitlements <path>  Source packaging entitlements plist
  --widget-path <path>          Widget appex to validate; defaults to <app>/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex
  --widget-source-entitlements <path>
                                Source widget entitlements plist
  --skip-launch-smoke           Skip open/launch smoke test
  --launch-timeout <seconds>    Seconds to wait for a fresh process to appear (default: 20)
  --steady-state <seconds>      Seconds the launched process must stay alive (default: 5)
  --require-notarization        Fail when Gatekeeper does not report notarization
  -h, --help                    Show this help

Checks:
  - package_app/build_dmg artifacts exist and look structurally valid
  - app bundle executable launches through LaunchServices and stays alive briefly
  - Apple 登录产品开关保持与源 Info.plist 一致，且签名产物的 Apple 登录模式与发布策略一致
  - Widget appex 已嵌入、签名、带 profile，并与主应用共享一致的 App Groups
  - codesign identity, signed entitlements, embedded profiles, and source entitlements stay consistent
  - Gatekeeper/notarization status is surfaced with warnings or failures
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_ROOT}/Scripts/notarytool_helpers.sh"
source "${PROJECT_ROOT}/Scripts/signing_entitlements_helpers.sh"

APP_PATH="${PROJECT_ROOT}/dist/SkyBridge Compass Pro.app"
DMG_PATH=""
SOURCE_INFO_PLIST="${PROJECT_ROOT}/Sources/SkyBridgeCompassApp/Info.plist"
SOURCE_ENTITLEMENTS="${PROJECT_ROOT}/Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.packaging.entitlements"
WIDGET_PATH=""
SOURCE_WIDGET_ENTITLEMENTS="${PROJECT_ROOT}/Sources/SkyBridgeCompassWidgets/SkyBridgeCompassWidgetsExtension.entitlements"
REQUIRE_NOTARIZATION="${SKYBRIDGE_RELEASE_GATE_REQUIRE_NOTARIZATION:-0}"
SKIP_LAUNCH_SMOKE=0
LAUNCH_TIMEOUT_SECONDS="${SKYBRIDGE_RELEASE_GATE_LAUNCH_TIMEOUT_SECONDS:-20}"
STEADY_STATE_SECONDS="${SKYBRIDGE_RELEASE_GATE_STEADY_STATE_SECONDS:-5}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="${2:-}"
      shift 2
      ;;
    --dmg-path)
      DMG_PATH="${2:-}"
      shift 2
      ;;
    --source-info-plist)
      SOURCE_INFO_PLIST="${2:-}"
      shift 2
      ;;
    --source-entitlements)
      SOURCE_ENTITLEMENTS="${2:-}"
      shift 2
      ;;
    --widget-path)
      WIDGET_PATH="${2:-}"
      shift 2
      ;;
    --widget-source-entitlements)
      SOURCE_WIDGET_ENTITLEMENTS="${2:-}"
      shift 2
      ;;
    --skip-launch-smoke)
      SKIP_LAUNCH_SMOKE=1
      shift
      ;;
    --launch-timeout)
      LAUNCH_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --steady-state)
      STEADY_STATE_SECONDS="${2:-}"
      shift 2
      ;;
    --require-notarization)
      REQUIRE_NOTARIZATION=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[macos-release-readiness] unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! [[ "${LAUNCH_TIMEOUT_SECONDS}" =~ ^[0-9]+$ && "${STEADY_STATE_SECONDS}" =~ ^[0-9]+$ ]]; then
  echo "[macos-release-readiness] launch timeout and steady-state must be numeric" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-release-readiness.XXXXXX")"

cleanup_tmp() {
  rm -rf "${TMP_DIR}"
}

trap cleanup_tmp EXIT

log_info() {
  echo "[macos-release-readiness] $1"
}

log_warn() {
  echo "[macos-release-readiness] WARNING: $1"
}

log_error() {
  echo "[macos-release-readiness] ERROR: $1" >&2
}

fail() {
  log_error "$1"
  exit 1
}

plist_read_value() {
  local plist_path="$1"
  local key_path="$2"

  python3 - "${plist_path}" "${key_path}" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
key_path = sys.argv[2].split(".")

if not plist_path.exists():
    raise SystemExit(1)

with plist_path.open("rb") as fh:
    value = plistlib.load(fh)

for key in key_path:
    if isinstance(value, dict) and key in value:
        value = value[key]
    else:
        raise SystemExit(1)

if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    raise SystemExit(1)
else:
    print(value)
PY
}

extract_helper_version() {
  local bin_path="$1"
  if [[ -x "${bin_path}" ]]; then
    strings "${bin_path}" 2>/dev/null | grep -m1 'SKYBRIDGE_HELPER_VERSION=' | cut -d= -f2 || true
  fi
}

resolve_default_dmg_path() {
  local app_info_plist="$1"
  local version=""
  local candidate=""

  version="$(plist_read_value "${app_info_plist}" "CFBundleShortVersionString" 2>/dev/null || true)"
  if [[ -n "${version}" ]]; then
    candidate="${PROJECT_ROOT}/dist/SkyBridgeCompassPro-${version}.dmg"
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  fi

  candidate="$(find "${PROJECT_ROOT}/dist" -maxdepth 1 -type f -name 'SkyBridgeCompassPro-*.dmg' -print | sort | tail -n 1 || true)"
  printf '%s\n' "${candidate}"
}

pid_in_list() {
  local target_pid="$1"
  local pid_list="$2"
  local existing_pid=""

  for existing_pid in ${pid_list}; do
    if [[ "${existing_pid}" == "${target_pid}" ]]; then
      return 0
    fi
  done

  return 1
}

collect_named_pids() {
  local executable_name="$1"
  pgrep -x "${executable_name}" 2>/dev/null || true
}

capture_recent_logs() {
  local process_name="$1"
  if ! command -v log >/dev/null 2>&1; then
    return 0
  fi

  log show --style compact --last 2m --predicate "process == \"${process_name}\"" 2>/dev/null | tail -n 20 || true
}

compare_plists() {
  local expected_path="$1"
  local actual_path="$2"
  local label="$3"

  python3 - "${expected_path}" "${actual_path}" "${label}" <<'PY'
import plistlib
import sys

expected_path, actual_path, label = sys.argv[1:]

with open(expected_path, "rb") as fh:
    expected = plistlib.load(fh)
with open(actual_path, "rb") as fh:
    actual = plistlib.load(fh)

if expected != actual:
    print(f"{label} mismatch", file=sys.stderr)
    print(f"expected={expected}", file=sys.stderr)
    print(f"actual={actual}", file=sys.stderr)
    raise SystemExit(1)
PY
}

compare_product_feature_flag_preservation() {
  local source_info_plist="$1"
  local actual_info_plist="$2"

  python3 - "${source_info_plist}" "${actual_info_plist}" <<'PY'
import plistlib
import sys

source_path, actual_path = sys.argv[1:]

with open(source_path, "rb") as fh:
    source = plistlib.load(fh)
with open(actual_path, "rb") as fh:
    actual = plistlib.load(fh)

expected_value = source.get("SKYBRIDGE_ENABLE_APPLE_SIGN_IN")
actual_value = actual.get("SKYBRIDGE_ENABLE_APPLE_SIGN_IN")

if expected_value != actual_value:
    print(
        "SKYBRIDGE_ENABLE_APPLE_SIGN_IN product flag mismatch: "
        f"expected={expected_value} actual={actual_value}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

compare_native_flag_alignment() {
  local expected_info_plist="$1"
  local actual_info_plist="$2"

  python3 - "${expected_info_plist}" "${actual_info_plist}" <<'PY'
import plistlib
import sys

expected_path, actual_path = sys.argv[1:]

with open(expected_path, "rb") as fh:
    expected = plistlib.load(fh)
with open(actual_path, "rb") as fh:
    actual = plistlib.load(fh)

expected_value = expected.get("SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN")
actual_value = actual.get("SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN")

if expected_value != actual_value:
    print(
        "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN mismatch: "
        f"expected={expected_value} actual={actual_value}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

compare_apple_sign_in_mode_alignment() {
  local expected_info_plist="$1"
  local actual_info_plist="$2"

  python3 - "${expected_info_plist}" "${actual_info_plist}" <<'PY'
import plistlib
import sys

expected_path, actual_path = sys.argv[1:]

with open(expected_path, "rb") as fh:
    expected = plistlib.load(fh)
with open(actual_path, "rb") as fh:
    actual = plistlib.load(fh)

expected_value = expected.get("SKYBRIDGE_APPLE_SIGN_IN_MODE")
actual_value = actual.get("SKYBRIDGE_APPLE_SIGN_IN_MODE")

if expected_value != actual_value:
    print(
        "SKYBRIDGE_APPLE_SIGN_IN_MODE mismatch: "
        f"expected={expected_value} actual={actual_value}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

extract_embedded_info_plist() {
  local executable_path="$1"
  local output_path="$2"

  python3 - "${executable_path}" "${output_path}" <<'PY'
import plistlib
import re
import subprocess
import sys
from pathlib import Path

executable_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

proc = subprocess.run(
    ["otool", "-X", "-s", "__TEXT", "__info_plist", str(executable_path)],
    check=False,
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    print(proc.stderr.strip() or proc.stdout.strip(), file=sys.stderr)
    raise SystemExit(1)

hex_bytes = bytearray()
for line in proc.stdout.splitlines():
    parts = line.split()
    if len(parts) < 2:
        continue
    for word in parts[1:]:
        if not re.fullmatch(r"[0-9a-fA-F]{8}", word):
            continue
        # otool prints 32-bit words in target byte order; reverse each word to
        # reconstruct the section bytes.
        raw = bytes.fromhex(word)
        hex_bytes.extend(raw[::-1])

payload = bytes(hex_bytes).rstrip(b"\x00")
if not payload:
    print("missing __TEXT,__info_plist section", file=sys.stderr)
    raise SystemExit(1)

start = payload.find(b"<?xml")
if start == -1:
    start = payload.find(b"<plist")
if start > 0:
    payload = payload[start:]

try:
    plistlib.loads(payload)
except Exception as exc:
    print(f"embedded __TEXT,__info_plist is not a valid plist: {exc}", file=sys.stderr)
    raise SystemExit(1)

output_path.write_bytes(payload)
PY
}

compare_required_privacy_usage_descriptions() {
  local expected_info_plist="$1"
  local actual_info_plist="$2"
  local label="$3"

  python3 - "${expected_info_plist}" "${actual_info_plist}" "${label}" <<'PY'
import plistlib
import sys

expected_path, actual_path, label = sys.argv[1:]

required_keys = [
    "NSBluetoothAlwaysUsageDescription",
    "NSLocalNetworkUsageDescription",
    "NSCameraUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSAudioCaptureUsageDescription",
    "NSLocationUsageDescription",
    "NSLocationWhenInUseUsageDescription",
    "NSUSBUsageDescription",
]

with open(expected_path, "rb") as fh:
    expected = plistlib.load(fh)
with open(actual_path, "rb") as fh:
    actual = plistlib.load(fh)

for key in required_keys:
    expected_value = expected.get(key)
    actual_value = actual.get(key)
    if not isinstance(actual_value, str) or not actual_value.strip():
        print(f"{label} missing required privacy usage description: {key}", file=sys.stderr)
        raise SystemExit(1)
    if expected_value != actual_value:
        print(
            f"{label} privacy usage description mismatch for {key}: "
            f"expected={expected_value!r} actual={actual_value!r}",
            file=sys.stderr,
        )
        raise SystemExit(1)
PY
}

compare_app_group_alignment() {
  local app_entitlements_path="$1"
  local widget_entitlements_path="$2"

  python3 - "${app_entitlements_path}" "${widget_entitlements_path}" <<'PY'
import plistlib
import sys

app_path, widget_path = sys.argv[1:]

with open(app_path, "rb") as fh:
    app_entitlements = plistlib.load(fh)
with open(widget_path, "rb") as fh:
    widget_entitlements = plistlib.load(fh)

app_groups = {
    str(item).strip()
    for item in (app_entitlements.get("com.apple.security.application-groups") or [])
    if str(item).strip()
}
widget_groups = {
    str(item).strip()
    for item in (widget_entitlements.get("com.apple.security.application-groups") or [])
    if str(item).strip()
}

if not widget_groups:
    print("widget extension is missing com.apple.security.application-groups", file=sys.stderr)
    raise SystemExit(1)

if not widget_groups.issubset(app_groups):
    print(
        "widget extension requested App Groups that are absent from the signed host app: "
        f"widget={sorted(widget_groups)} app={sorted(app_groups)}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

assess_gatekeeper_target() {
  local target_path="$1"
  local target_type="$2"
  local label="$3"
  local output=""
  local stapler_output=""

  output="$(skybridge_assess_gatekeeper "${target_path}" "${target_type}" 2>&1 || true)"

  if skybridge_gatekeeper_is_notarized "${output}"; then
    log_info "${label} Gatekeeper assessment: notarized"
    return 0
  fi

  if skybridge_gatekeeper_is_unnotarized_developer_id "${output}"; then
    if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
      fail "${label} is signed but still unnotarized: ${output//$'\n'/ | }"
    fi
    log_warn "${label} is signed but not notarized yet: ${output//$'\n'/ | }"
    return 0
  fi

  if skybridge_gatekeeper_is_accepted "${output}"; then
    if [[ "${target_path}" == *.dmg ]] && stapler_output="$(xcrun stapler validate "${target_path}" 2>&1)"; then
      log_info "${label} Gatekeeper assessment lacked notarization context, but stapler validation confirmed a stapled ticket"
      return 0
    fi

    if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
      fail "${label} was accepted by Gatekeeper but notarization could not be confirmed: ${output//$'\n'/ | }"
    fi
    log_warn "${label} was accepted by Gatekeeper but notarization could not be confirmed: ${output//$'\n'/ | }"
    return 0
  fi

  if [[ -n "${output}" ]]; then
    fail "${label} Gatekeeper assessment failed: ${output//$'\n'/ | }"
  fi

  fail "${label} Gatekeeper assessment returned no output"
}

smoke_launch_app() {
  local app_path="$1"
  local executable_name="$2"
  local before_pids=""
  local new_pid=""
  local open_output=""
  local pid=""
  local logs=""
  local deadline=0
  local quit_deadline=0

  before_pids="$(collect_named_pids "${executable_name}" | tr '\n' ' ')"

  if ! open_output="$(open -Fn -g "${app_path}" 2>&1)"; then
    fail "failed to open app bundle: ${open_output}"
  fi

  deadline=$((SECONDS + LAUNCH_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    while IFS= read -r pid; do
      [[ -n "${pid}" ]] || continue
      if ! pid_in_list "${pid}" "${before_pids}"; then
        new_pid="${pid}"
        break 2
      fi
    done < <(collect_named_pids "${executable_name}")
    sleep 1
  done

  if [[ -z "${new_pid}" ]]; then
    fail "app launch smoke did not observe a fresh ${executable_name} process within ${LAUNCH_TIMEOUT_SECONDS}s"
  fi

  log_info "App launch smoke observed pid=${new_pid}; waiting ${STEADY_STATE_SECONDS}s for crash-free startup"
  sleep "${STEADY_STATE_SECONDS}"

  if ! kill -0 "${new_pid}" 2>/dev/null; then
    logs="$(capture_recent_logs "${executable_name}")"
    fail "app process exited during smoke window.${logs:+ Recent logs: ${logs//$'\n'/ | }}"
  fi

  kill -TERM "${new_pid}" >/dev/null 2>&1 || true
  quit_deadline=$((SECONDS + 10))
  while kill -0 "${new_pid}" 2>/dev/null; do
    if (( SECONDS >= quit_deadline )); then
      kill -KILL "${new_pid}" >/dev/null 2>&1 || true
      break
    fi
    sleep 1
  done

  log_info "App launch smoke passed"
}

if [[ ! -d "${APP_PATH}" ]]; then
  fail "missing app bundle: ${APP_PATH}. Run Scripts/package_app.sh or Scripts/build_dmg.sh first."
fi

APP_INFO_PLIST="${APP_PATH}/Contents/Info.plist"
APP_PROFILE_PATH="${APP_PATH}/Contents/embedded.provisionprofile"

[[ -f "${APP_INFO_PLIST}" ]] || fail "missing app Info.plist: ${APP_INFO_PLIST}"
[[ -f "${SOURCE_INFO_PLIST}" ]] || fail "missing source Info.plist: ${SOURCE_INFO_PLIST}"
[[ -f "${SOURCE_ENTITLEMENTS}" ]] || fail "missing source entitlements: ${SOURCE_ENTITLEMENTS}"

APP_EXECUTABLE_NAME="$(plist_read_value "${APP_INFO_PLIST}" "CFBundleExecutable" 2>/dev/null || true)"
APP_BUNDLE_IDENTIFIER="$(plist_read_value "${APP_INFO_PLIST}" "CFBundleIdentifier" 2>/dev/null || true)"
APP_VERSION="$(plist_read_value "${APP_INFO_PLIST}" "CFBundleShortVersionString" 2>/dev/null || true)"
APP_BUILD_SOURCE="$(plist_read_value "${APP_INFO_PLIST}" "SkyBridgePackagingBuildSource" 2>/dev/null || true)"
APP_EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${APP_EXECUTABLE_NAME}"
APP_HELPER_PLIST_PATH="${APP_PATH}/Contents/Library/LaunchDaemons/com.skybridge.PowerMetricsHelper.plist"
APP_HELPER_BIN_PATH="${APP_PATH}/Contents/Library/LaunchDaemons/com.skybridge.PowerMetricsHelper/com.skybridge.PowerMetricsHelper"
if [[ -z "${WIDGET_PATH}" ]]; then
  WIDGET_PATH="${APP_PATH}/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex"
fi

[[ -n "${APP_EXECUTABLE_NAME}" ]] || fail "app Info.plist is missing CFBundleExecutable"
[[ -n "${APP_BUNDLE_IDENTIFIER}" ]] || fail "app Info.plist is missing CFBundleIdentifier"
[[ -x "${APP_EXECUTABLE_PATH}" ]] || fail "main executable is missing or not executable: ${APP_EXECUTABLE_PATH}"
[[ -f "${APP_HELPER_PLIST_PATH}" ]] || fail "missing PowerMetricsHelper launchd plist: ${APP_HELPER_PLIST_PATH}"
[[ -x "${APP_HELPER_BIN_PATH}" ]] || fail "PowerMetricsHelper binary is missing or not executable: ${APP_HELPER_BIN_PATH}"
APP_HELPER_VERSION="$(extract_helper_version "${APP_HELPER_BIN_PATH}")"
[[ -n "${APP_HELPER_VERSION}" ]] || fail "PowerMetricsHelper version marker is missing; refusing version unknown helper"
[[ -f "${SOURCE_WIDGET_ENTITLEMENTS}" ]] || fail "missing widget source entitlements: ${SOURCE_WIDGET_ENTITLEMENTS}"

if [[ "${APP_BUILD_SOURCE}" != "xcode_release" ]]; then
  fail "app bundle was not packaged from xcode_release artifacts (actual: ${APP_BUILD_SOURCE:-missing})"
fi

if [[ -z "${DMG_PATH}" ]]; then
  DMG_PATH="$(resolve_default_dmg_path "${APP_INFO_PLIST}")"
fi

[[ -n "${DMG_PATH}" ]] || fail "could not resolve DMG path under dist/"
[[ -f "${DMG_PATH}" ]] || fail "missing DMG artifact: ${DMG_PATH}. Run Scripts/build_dmg.sh first."

if ! hdiutil imageinfo "${DMG_PATH}" >/dev/null 2>&1; then
  fail "DMG is present but hdiutil could not read it: ${DMG_PATH}"
fi

if [[ -n "${APP_VERSION}" && "$(basename "${DMG_PATH}")" != *"${APP_VERSION}.dmg" ]]; then
  fail "DMG filename does not include app version ${APP_VERSION}: $(basename "${DMG_PATH}")"
fi

DMG_SIGNED_METADATA="$(codesign --display --verbose=2 "${DMG_PATH}" 2>&1)" \
  || fail "DMG is not codesigned with a Developer ID Application identity: ${DMG_PATH}"

if [[ "${DMG_SIGNED_METADATA}" != *"Authority=Developer ID Application:"* ]]; then
  fail "DMG is not signed with a Developer ID Application identity"
fi

SIGNED_METADATA="$(codesign --display --verbose=2 "${APP_PATH}" 2>&1)"
SIGNED_TEAM_IDENTIFIER="$(printf '%s\n' "${SIGNED_METADATA}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
[[ -n "${SIGNED_TEAM_IDENTIFIER}" ]] || fail "could not read TeamIdentifier from codesign metadata"

if [[ "${SIGNED_METADATA}" != *"Authority=Developer ID Application:"* ]]; then
  fail "release bundle is not signed with a Developer ID Application identity"
fi

DMG_TEAM_IDENTIFIER="$(printf '%s\n' "${DMG_SIGNED_METADATA}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
if [[ -n "${DMG_TEAM_IDENTIFIER}" && "${DMG_TEAM_IDENTIFIER}" != "${SIGNED_TEAM_IDENTIFIER}" ]]; then
  fail "DMG TeamIdentifier (${DMG_TEAM_IDENTIFIER}) does not match app TeamIdentifier (${SIGNED_TEAM_IDENTIFIER})"
fi

log_info "Verifying codesign integrity"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null
codesign --verify --verbose=2 "${DMG_PATH}" >/dev/null
log_info "Verifying PowerMetricsHelper codesign integrity (version ${APP_HELPER_VERSION})"
codesign --verify --strict --verbose=2 "${APP_HELPER_BIN_PATH}" >/dev/null

SIGNED_ENTITLEMENTS_PATH="${TMP_DIR}/signed-entitlements.plist"
EXPECTED_ENTITLEMENTS_PATH="${TMP_DIR}/expected-entitlements.plist"
EXPECTED_INFO_PLIST="${TMP_DIR}/expected-info.plist"
EMBEDDED_APP_INFO_PLIST="${TMP_DIR}/embedded-app-info.plist"
WIDGET_INFO_PLIST="${WIDGET_PATH}/Contents/Info.plist"
WIDGET_PROFILE_PATH="${WIDGET_PATH}/Contents/embedded.provisionprofile"
SIGNED_WIDGET_ENTITLEMENTS_PATH="${TMP_DIR}/signed-widget-entitlements.plist"
EXPECTED_WIDGET_ENTITLEMENTS_PATH="${TMP_DIR}/expected-widget-entitlements.plist"

skybridge_write_signed_entitlements "${APP_PATH}" "${SIGNED_ENTITLEMENTS_PATH}" \
  || fail "could not extract signed entitlements from ${APP_PATH}"

if [[ -f "${APP_PROFILE_PATH}" ]]; then
  log_info "Validating embedded provisioning profile against bundle identity"
  skybridge_validate_provisionprofile_app_identity \
    "${APP_PROFILE_PATH}" \
    "${APP_BUNDLE_IDENTIFIER}" \
    "${SIGNED_TEAM_IDENTIFIER}" \
    || fail "embedded provisioning profile does not match the signed app identity"

  if ! skybridge_profile_supports_requested_restricted_entitlements "${APP_PROFILE_PATH}" "${SIGNED_ENTITLEMENTS_PATH}"; then
    fail "embedded provisioning profile does not cover the signed App Groups entitlements"
  fi
else
  if skybridge_entitlements_request_application_groups "${SIGNED_ENTITLEMENTS_PATH}"; then
    fail "signed app still requests profile-backed entitlements but no embedded provisioning profile is present"
  fi
fi

cp "${SOURCE_INFO_PLIST}" "${EXPECTED_INFO_PLIST}"
skybridge_prepare_signing_entitlements \
  "${SOURCE_ENTITLEMENTS}" \
  "${EXPECTED_ENTITLEMENTS_PATH}" \
  "${EXPECTED_INFO_PLIST}" \
  "${APP_PROFILE_PATH:-}" \
  >/dev/null

compare_plists "${EXPECTED_ENTITLEMENTS_PATH}" "${SIGNED_ENTITLEMENTS_PATH}" "signed entitlements" \
  || fail "signed entitlements drifted from the expected packaging entitlements"

compare_product_feature_flag_preservation "${SOURCE_INFO_PLIST}" "${APP_INFO_PLIST}" \
  || fail "app Info.plist changed SKYBRIDGE_ENABLE_APPLE_SIGN_IN instead of preserving the product feature flag"

compare_native_flag_alignment "${EXPECTED_INFO_PLIST}" "${APP_INFO_PLIST}" \
  || fail "app Info.plist SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN drifted from the effective signed entitlements"

compare_apple_sign_in_mode_alignment "${EXPECTED_INFO_PLIST}" "${APP_INFO_PLIST}" \
  || fail "app Info.plist SKYBRIDGE_APPLE_SIGN_IN_MODE drifted from the effective signed entitlements"

compare_required_privacy_usage_descriptions "${SOURCE_INFO_PLIST}" "${APP_INFO_PLIST}" "app Info.plist" \
  || fail "app Info.plist privacy usage descriptions drifted from the source Info.plist"

extract_embedded_info_plist "${APP_EXECUTABLE_PATH}" "${EMBEDDED_APP_INFO_PLIST}" \
  || fail "main executable is missing an embedded __TEXT,__info_plist section"

compare_required_privacy_usage_descriptions "${APP_INFO_PLIST}" "${EMBEDDED_APP_INFO_PLIST}" "main executable embedded Info.plist" \
  || fail "main executable embedded Info.plist privacy usage descriptions drifted from the app bundle Info.plist"

APP_FEATURE_APPLE_SIGN_IN="$(plist_read_value "${APP_INFO_PLIST}" "SKYBRIDGE_ENABLE_APPLE_SIGN_IN" 2>/dev/null || true)"
APP_NATIVE_APPLE_SIGN_IN="$(plist_read_value "${APP_INFO_PLIST}" "SKYBRIDGE_ENABLE_NATIVE_APPLE_SIGN_IN" 2>/dev/null || true)"
APP_APPLE_SIGN_IN_MODE="$(plist_read_value "${APP_INFO_PLIST}" "SKYBRIDGE_APPLE_SIGN_IN_MODE" 2>/dev/null || true)"

if [[ "${SKYBRIDGE_REQUIRE_APPLE_SIGN_IN:-0}" == "1" && "${APP_FEATURE_APPLE_SIGN_IN}" == "true" && "${APP_NATIVE_APPLE_SIGN_IN}" != "true" ]]; then
  fail "Apple 登录产品功能已开启，但签名产物未启用原生 Apple Sign In"
fi

if [[ "${APP_FEATURE_APPLE_SIGN_IN}" == "true" && "${APP_APPLE_SIGN_IN_MODE}" != "web_session" ]]; then
  fail "Developer ID DMG 发布要求 Apple 登录采用 web_session，当前模式为：${APP_APPLE_SIGN_IN_MODE:-missing}"
fi

[[ -d "${WIDGET_PATH}" ]] || fail "missing widget appex: ${WIDGET_PATH}"
[[ -f "${WIDGET_INFO_PLIST}" ]] || fail "missing widget Info.plist: ${WIDGET_INFO_PLIST}"

WIDGET_BUNDLE_IDENTIFIER="$(plist_read_value "${WIDGET_INFO_PLIST}" "CFBundleIdentifier" 2>/dev/null || true)"
[[ -n "${WIDGET_BUNDLE_IDENTIFIER}" ]] || fail "widget Info.plist is missing CFBundleIdentifier"

WIDGET_SIGNED_METADATA="$(codesign --display --verbose=2 "${WIDGET_PATH}" 2>&1)"
if [[ "${WIDGET_SIGNED_METADATA}" != *"Authority=Developer ID Application:"* ]]; then
  fail "widget appex is not signed with a Developer ID Application identity"
fi

log_info "Verifying widget appex codesign integrity"
codesign --verify --strict --verbose=2 "${WIDGET_PATH}" >/dev/null

skybridge_write_signed_entitlements "${WIDGET_PATH}" "${SIGNED_WIDGET_ENTITLEMENTS_PATH}" \
  || fail "could not extract signed entitlements from ${WIDGET_PATH}"

cp "${SOURCE_WIDGET_ENTITLEMENTS}" "${EXPECTED_WIDGET_ENTITLEMENTS_PATH}"
compare_plists "${EXPECTED_WIDGET_ENTITLEMENTS_PATH}" "${SIGNED_WIDGET_ENTITLEMENTS_PATH}" "widget signed entitlements" \
  || fail "widget signed entitlements drifted from the expected widget entitlements"

compare_app_group_alignment "${SIGNED_ENTITLEMENTS_PATH}" "${SIGNED_WIDGET_ENTITLEMENTS_PATH}" \
  || fail "widget App Groups are not aligned with the signed host app entitlements"

[[ -f "${WIDGET_PROFILE_PATH}" ]] || fail "widget appex is missing embedded.provisionprofile"
skybridge_validate_provisionprofile_app_identity \
  "${WIDGET_PROFILE_PATH}" \
  "${WIDGET_BUNDLE_IDENTIFIER}" \
  "${SIGNED_TEAM_IDENTIFIER}" \
  || fail "widget embedded provisioning profile does not match the signed appex identity"

if ! skybridge_profile_supports_requested_profile_backed_entitlements \
  "${WIDGET_PROFILE_PATH}" \
  "${SIGNED_WIDGET_ENTITLEMENTS_PATH}"; then
  fail "widget embedded provisioning profile does not cover the signed App Groups entitlement"
fi

assess_gatekeeper_target "${APP_PATH}" "execute" "App Bundle"
assess_gatekeeper_target "${DMG_PATH}" "open" "DMG"

if [[ "${SKIP_LAUNCH_SMOKE}" == "1" ]]; then
  log_warn "launch smoke was skipped by request"
else
  smoke_launch_app "${APP_PATH}" "${APP_EXECUTABLE_NAME}"
fi

log_info "PowerMetricsHelper app bundle version: ${APP_HELPER_VERSION}"
INSTALLED_HELPER_BIN="/Library/PrivilegedHelperTools/com.skybridge.PowerMetricsHelper"
if [[ -x "${INSTALLED_HELPER_BIN}" ]]; then
  INSTALLED_HELPER_VERSION="$(extract_helper_version "${INSTALLED_HELPER_BIN}")"
  log_info "PowerMetricsHelper installed version: ${INSTALLED_HELPER_VERSION:-unknown}"
fi
RUNNING_INFO="$(launchctl print system/com.skybridge.PowerMetricsHelper 2>/dev/null || true)"
RUNNING_PATH="$(echo "${RUNNING_INFO}" | awk -F'= ' '/path =/{print $2; exit}')"
if [[ -n "${RUNNING_PATH}" ]]; then
  RUNNING_VERSION="$(extract_helper_version "${RUNNING_PATH}")"
  log_info "PowerMetricsHelper running version: ${RUNNING_VERSION:-unknown}"
fi

log_info "minimum macOS release readiness checks passed"
