#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/signing_entitlements_helpers.sh"
source "$ROOT_DIR/Scripts/ios_distribution_signing_helpers.sh"
source "$ROOT_DIR/Scripts/skybridge_core_resource_bundle_helpers.sh"
source "$ROOT_DIR/Scripts/xcodebuild_helpers.sh"
source "$ROOT_DIR/Scripts/apple_pqc_sdk_probe.sh"
source "$ROOT_DIR/Scripts/framework_artifact_helpers.sh"
source "$ROOT_DIR/Scripts/real_device_ios_process_ownership.sh"
source "$ROOT_DIR/Scripts/real_device_smoke_redaction.sh"
source "$ROOT_DIR/Scripts/real_device_smoke_performance_gate.sh"
source "$ROOT_DIR/Scripts/release_candidate_evidence_helpers.sh"
XCODE_SWIFT_BIN="$(skybridge_xcode_swift_executable)" || {
  echo "Selected Xcode Swift executable is unavailable" >&2
  exit 1
}
PROCESS_OWNERSHIP_HELPER="$ROOT_DIR/Scripts/webrtc_smoke_process_ownership.py"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/real_device_p2p_remote_smoke_$(date +%Y%m%d_%H%M%S)}"
PUBLIC_ARTIFACT_DIR="${SKYBRIDGE_SMOKE_PUBLIC_ARTIFACT_DIR:-${ARTIFACT_DIR}-public-redacted}"
IOS_PROJECT="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_EXPORT_OPTIONS="$ROOT_DIR/Scripts/ios_release_candidate_export_options.plist"
IOS_IPA_EXTRACTOR="$ROOT_DIR/Scripts/extract_ios_ipa.py"
IDENTITY_REFRESH_EVIDENCE_VALIDATOR="$ROOT_DIR/Scripts/validate_p2p_identity_refresh_evidence.py"
IOS_DEBUG_ENTITLEMENTS="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOSDebug.entitlements"
IOS_RELEASE_ENTITLEMENTS="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOSRelease.entitlements"
IOS_BUNDLE_ID="com.skybridge.compass.ios"
IOS_WIDGET_BUNDLE_ID="com.skybridge.compass.ios.widgets"
IOS_TEAM_IDENTIFIER="YKUPL7Z869"
IOS_APP_DISTRIBUTION_PROFILE_INPUT="${SKYBRIDGE_SMOKE_IOS_APP_DISTRIBUTION_PROFILE:-}"
IOS_WIDGET_DISTRIBUTION_PROFILE_INPUT="${SKYBRIDGE_SMOKE_IOS_WIDGET_DISTRIBUTION_PROFILE:-}"
IOS_BUILD_DESTINATION="${SKYBRIDGE_IOS_BUILD_DESTINATION:-generic/platform=iOS}"
IOS_BUILD_CONFIGURATION="${SKYBRIDGE_SMOKE_IOS_BUILD_CONFIGURATION:-Release}"
SMOKE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-240}"
IOS_LAUNCH_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_IOS_LAUNCH_TIMEOUT_SECONDS:-$((SMOKE_TIMEOUT_SECONDS + 60))}"
DEVICECTL_TIMEOUT_SECONDS="${SKYBRIDGE_DEVICECTL_TIMEOUT_SECONDS:-60}"
IOS_CONSOLE_HANDLE_CAPTURE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_IOS_CONSOLE_HANDLE_CAPTURE_TIMEOUT_SECONDS:-10}"
SMOKE_REMOTE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_REMOTE_DESKTOP_TIMEOUT_SECONDS:-$SMOKE_TIMEOUT_SECONDS}"
IOS_CONSOLE_TOTAL_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_IOS_CONSOLE_TIMEOUT_SECONDS:-$((SMOKE_TIMEOUT_SECONDS + SMOKE_REMOTE_TIMEOUT_SECONDS + 300))}"
SMOKE_MIN_FPS="${SKYBRIDGE_SMOKE_MIN_FPS:-59}"
SMOKE_TARGET_FPS="${SKYBRIDGE_SMOKE_TARGET_FPS:-60}"
SMOKE_SOAK_SECONDS="${SKYBRIDGE_SMOKE_SOAK_SECONDS:-10}"
SMOKE_VIDEO_WIDTH="${SKYBRIDGE_SMOKE_VIDEO_WIDTH:-2056}"
SMOKE_VIDEO_HEIGHT="${SKYBRIDGE_SMOKE_VIDEO_HEIGHT:-1329}"
SMOKE_EXPECT_RENDER_ORIENTATION="${SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION:-upright}"
SMOKE_REQUIRE_SIGNED_KEM_REFRESH="${SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH:-0}"
SMOKE_FORCE_SIGNED_KEM_REFRESH="${SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH:-$SMOKE_REQUIRE_SIGNED_KEM_REFRESH}"
ALLOW_PERSISTENT_TRUST_MUTATION="${SKYBRIDGE_SMOKE_ALLOW_PERSISTENT_TRUST_MUTATION:-0}"
RUN_MAC_ONLINE_IPAD_SMOKE="${SKYBRIDGE_SMOKE_RUN_MAC_ONLINE_IPAD:-1}"
RUN_ID="${SKYBRIDGE_SMOKE_P2P_REMOTE_RUN_ID:-$(date +%Y%m%d%H%M%S)}"
skybridge_smoke_require_safe_run_id "$RUN_ID" "SKYBRIDGE_SMOKE_P2P_REMOTE_RUN_ID"
MAC_ONLINE_RUNTIME_DIR="${TMPDIR:-/tmp}/skybridge-mac-online-${RUN_ID}"
PREFERRED_SUITE="${SB_PQC_PREFERRED_SUITE:-xwing}"
HOST_PREFERRED_SUITE="${SB_PQC_HOST_PREFERRED_SUITE:-$PREFERRED_SUITE}"
IOS_PREFERRED_SUITE="${SB_PQC_IOS_PREFERRED_SUITE:-$PREFERRED_SUITE}"
EXPECTED_TARGET_SUITE="${SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE:-X-Wing}"
HOST_HANDSHAKE_PATTERN="(success .*suite=${EXPECTED_TARGET_SUITE} .*handshakeOnly=1|mac remote established .*suite=${EXPECTED_TARGET_SUITE})"
PRESERVE_INSTALL="${SKYBRIDGE_SMOKE_PRESERVE_INSTALL:-1}"
PQC_TRUST_MODE="${SKYBRIDGE_SMOKE_PQC_TRUST_MODE:-actual}"
KEYCHAIN_MODE="${SKYBRIDGE_SMOKE_KEYCHAIN_MODE:-system}"
LAB_RUN="${SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN:-0}"
MAC_HOST_LAUNCH_MODE="${SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE:-packaged}"
IDENTITY_AUDIT_ONLY="${SKYBRIDGE_SMOKE_IDENTITY_AUDIT_ONLY:-0}"
MAC_HOST_ONLY="${SKYBRIDGE_SMOKE_MAC_HOST_ONLY:-0}"
MAC_HOST_READY_FILE="$ARTIFACT_DIR/mac-host-ready.json"
IDENTITY_AUDIT_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_IDENTITY_AUDIT_TIMEOUT_SECONDS:-120}"
SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE="${SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE:-1}"
SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME="${SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME:-Mac Smoke Operator}"
SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID="${SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID:-mac-smoke-nebula}"
SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME="${SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME:-iPad Smoke Operator}"
SKYBRIDGE_SMOKE_REMOTE_NEBULA_ID="${SKYBRIDGE_SMOKE_REMOTE_NEBULA_ID:-ipad-smoke-nebula}"
SWIFTPM_CACHE_DIR="${SKYBRIDGE_SWIFTPM_CACHE_DIR:-$ROOT_DIR/.swiftpm-cache}"
SWIFT_MODULE_CACHE_DIR="${SKYBRIDGE_SWIFT_MODULE_CACHE_DIR:-$ROOT_DIR/.swiftpm-module-cache}"
SMOKE_BUILD_DIR="${SKYBRIDGE_P2P_SMOKE_BUILD_DIR:-$ROOT_DIR/.build/real-device-p2p-smoke}"
if [[ "$SMOKE_BUILD_DIR" != /* ]]; then
  SMOKE_BUILD_DIR="$ROOT_DIR/$SMOKE_BUILD_DIR"
fi
SOURCE_INPUT_DIGEST_TOOL="$ROOT_DIR/Scripts/source_input_digest.py"
SOURCE_INPUT_BINDING_LOG="$ARTIFACT_DIR/source-input-binding.log"
SOURCE_INPUT_BINDING_PROOF="$ARTIFACT_DIR/source-input-binding.json"
SOURCE_INPUT_PATHS=(
  Package.swift
  Package.resolved
  project.yml
  Config
  Sources
  Scripts
  Packages
  "SkyBridge Compass iOS"
)
IOS_SOURCE_INPUT_DIGEST=""
IOS_SOURCE_INPUT_FILE_COUNT=""
ACCEPTANCE_CANDIDATE_READY=0

case "$PQC_TRUST_MODE" in
  user|actual|injected) ;;
  *)
    echo "Unsupported SKYBRIDGE_SMOKE_PQC_TRUST_MODE=$PQC_TRUST_MODE (expected: user, actual, injected)" >&2
    exit 2
    ;;
esac

case "$KEYCHAIN_MODE" in
  system) KEYCHAIN_IN_MEMORY=0 ;;
  in-memory) KEYCHAIN_IN_MEMORY=1 ;;
  *)
    echo "Unsupported SKYBRIDGE_SMOKE_KEYCHAIN_MODE=$KEYCHAIN_MODE (expected: system, in-memory)" >&2
    exit 2
    ;;
esac

case "$LAB_RUN" in
  0|1) ;;
  *)
    echo "SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN must be 0 or 1" >&2
    exit 2
    ;;
esac

case "$IOS_BUILD_CONFIGURATION" in
  Release|Debug) ;;
  *)
    echo "SKYBRIDGE_SMOKE_IOS_BUILD_CONFIGURATION must be Release or Debug" >&2
    exit 2
    ;;
esac

if [[ "$IOS_BUILD_CONFIGURATION" == "Debug" && "$LAB_RUN" != "1" ]]; then
  echo "The iOS Debug product is diagnostic-only and requires SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1." >&2
  exit 2
fi

if [[ "$IOS_BUILD_CONFIGURATION" == "Release" ]]; then
  IOS_EXPECTED_ENTITLEMENTS="$IOS_RELEASE_ENTITLEMENTS"
else
  IOS_EXPECTED_ENTITLEMENTS="$IOS_DEBUG_ENTITLEMENTS"
fi

case "$MAC_HOST_LAUNCH_MODE" in
  packaged|packaged-lab|direct) ;;
  *)
    echo "Unsupported SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE=$MAC_HOST_LAUNCH_MODE (expected: packaged, packaged-lab, direct)" >&2
    exit 2
    ;;
esac
if [[ "$MAC_HOST_LAUNCH_MODE" == "packaged-lab" && "$LAB_RUN" != "1" ]]; then
  echo "SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE=packaged-lab requires SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1." >&2
  exit 2
fi

case "$IDENTITY_AUDIT_ONLY" in
  0|1) ;;
  *)
    echo "SKYBRIDGE_SMOKE_IDENTITY_AUDIT_ONLY must be 0 or 1" >&2
    exit 2
    ;;
esac
case "$MAC_HOST_ONLY" in
  0|1) ;;
  *)
    echo "SKYBRIDGE_SMOKE_MAC_HOST_ONLY must be 0 or 1" >&2
    exit 2
    ;;
esac
if [[ ! "$IDENTITY_AUDIT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] \
  || (( IDENTITY_AUDIT_TIMEOUT_SECONDS < 30 || IDENTITY_AUDIT_TIMEOUT_SECONDS > 300 )); then
  echo "SKYBRIDGE_SMOKE_IDENTITY_AUDIT_TIMEOUT_SECONDS must be an integer from 30 through 300" >&2
  exit 2
fi
if [[ "$IDENTITY_AUDIT_ONLY" == "1" ]]; then
  if [[ "$LAB_RUN" != "1" || "$MAC_HOST_LAUNCH_MODE" != "packaged-lab" ]]; then
    echo "The identity audit is diagnostic-only and requires LAB_RUN=1 with MAC_HOST_LAUNCH_MODE=packaged-lab." >&2
    exit 2
  fi
  if [[ "$KEYCHAIN_MODE" != "system" ]]; then
    echo "The identity audit requires the persistent system Keychain view." >&2
    exit 2
  fi
fi

case "$ALLOW_PERSISTENT_TRUST_MUTATION" in
  0|1) ;;
  *)
    echo "SKYBRIDGE_SMOKE_ALLOW_PERSISTENT_TRUST_MUTATION must be 0 or 1" >&2
    exit 2
    ;;
esac

if [[ "$MAC_HOST_ONLY" == "1" ]]; then
  if [[ "$IDENTITY_AUDIT_ONLY" == "1" ]]; then
    echo "The signed macOS host-only mode cannot be combined with the identity-audit-only mode." >&2
    exit 2
  fi
  if [[ "$LAB_RUN" != "1" || "$MAC_HOST_LAUNCH_MODE" != "packaged-lab" ]]; then
    echo "The signed macOS host-only mode is diagnostic-only and requires LAB_RUN=1 with MAC_HOST_LAUNCH_MODE=packaged-lab." >&2
    exit 2
  fi
  if [[ "$KEYCHAIN_MODE" != "system" ]]; then
    echo "The signed macOS host-only mode requires the persistent system Keychain view." >&2
    exit 2
  fi
  if [[ "$PQC_TRUST_MODE" != "actual" ]]; then
    echo "The signed macOS host-only mode requires SKYBRIDGE_SMOKE_PQC_TRUST_MODE=actual." >&2
    exit 2
  fi
  if [[ "$ALLOW_PERSISTENT_TRUST_MUTATION" != "0" ]]; then
    echo "The signed macOS host-only mode forbids forced persistent trust mutation." >&2
    exit 2
  fi
  if [[ "${SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING:-0}" != "0" ]]; then
    echo "The signed macOS host-only mode requires SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=0." >&2
    exit 2
  fi
  if [[ "${SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE:-0}" != "0" ]]; then
    echo "The signed macOS host-only mode requires SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE=0." >&2
    exit 2
  fi
fi

case "$SMOKE_REQUIRE_SIGNED_KEM_REFRESH:$SMOKE_FORCE_SIGNED_KEM_REFRESH" in
  1:1)
    if [[ "$ALLOW_PERSISTENT_TRUST_MUTATION" != "1" ]]; then
      echo "Forced signed KEM refresh mutates persistent trust and requires explicit SKYBRIDGE_SMOKE_ALLOW_PERSISTENT_TRUST_MUTATION=1." >&2
      exit 2
    fi
    ;;
  0:0) ;;
  *)
    echo "SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH and SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH must both be 0 or both be 1." >&2
    exit 2
    ;;
esac

mac_host_uses_signed_app_bundle() {
  case "$MAC_HOST_LAUNCH_MODE" in
    packaged|packaged-lab) return 0 ;;
    direct) return 1 ;;
    *)
      echo "Invalid macOS host mode reached the signed-app boundary: $MAC_HOST_LAUNCH_MODE" >&2
      return 2
      ;;
  esac
}

if [[ "$LAB_RUN" != "1" ]]; then
  acceptance_violations=()
  [[ "$PQC_TRUST_MODE" != "injected" ]] \
    || acceptance_violations+=("SKYBRIDGE_SMOKE_PQC_TRUST_MODE=user|actual")
  [[ "$KEYCHAIN_MODE" == "system" ]] \
    || acceptance_violations+=("SKYBRIDGE_SMOKE_KEYCHAIN_MODE=system")
  [[ "$RUN_MAC_ONLINE_IPAD_SMOKE" == "1" ]] \
    || acceptance_violations+=("SKYBRIDGE_SMOKE_RUN_MAC_ONLINE_IPAD=1")
  [[ "$MAC_HOST_LAUNCH_MODE" == "packaged" ]] \
    || acceptance_violations+=("SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE=packaged")
  [[ "$IOS_BUILD_CONFIGURATION" == "Release" ]] \
    || acceptance_violations+=("SKYBRIDGE_SMOKE_IOS_BUILD_CONFIGURATION=Release")
  [[ "$SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE" == "1" ]] \
    || acceptance_violations+=("SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE=1")
  [[ "${SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING:-0}" != "1" ]] \
    || acceptance_violations+=("SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=0")
  [[ "${SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE:-0}" != "1" ]] \
    || acceptance_violations+=("SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE=0")
  if (( ${#acceptance_violations[@]} > 0 )); then
    printf 'Real-device P2P acceptance profile is diagnostic-only; required: %s\n' "${acceptance_violations[*]}" >&2
    echo "Set SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1 only for non-acceptance diagnostics." >&2
    exit 2
  fi
fi

case "$IOS_LAUNCH_TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    echo "Unsupported SKYBRIDGE_SMOKE_IOS_LAUNCH_TIMEOUT_SECONDS=$IOS_LAUNCH_TIMEOUT_SECONDS (expected positive integer seconds)" >&2
    exit 2
    ;;
  *)
    if (( IOS_LAUNCH_TIMEOUT_SECONDS < 5 )); then
      echo "Unsupported SKYBRIDGE_SMOKE_IOS_LAUNCH_TIMEOUT_SECONDS=$IOS_LAUNCH_TIMEOUT_SECONDS (minimum 5 seconds)" >&2
      exit 2
    fi
    ;;
esac

mkdir -p "$ARTIFACT_DIR" "$SWIFTPM_CACHE_DIR" "$SWIFT_MODULE_CACHE_DIR"
chmod 0700 "$ARTIFACT_DIR"

pick_real_device_id() {
  python3 - <<'PY'
import json
import sys
import subprocess
import tempfile

def load_devicectl_device_list(context):
    with tempfile.NamedTemporaryFile(prefix="skybridge-devicectl-devices-", suffix=".json") as handle:
        try:
            result = subprocess.run(
                ["xcrun", "devicectl", "list", "devices", "--json-output", handle.name],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
            )
            if result.returncode != 0:
                print(f"devicectl JSON device list failed while {context}.", file=sys.stderr)
                raise SystemExit(1)
            handle.seek(0)
            return json.load(handle)
        except subprocess.TimeoutExpired as exc:
            print(f"devicectl JSON device list timed out while {context}.", file=sys.stderr)
            raise SystemExit(1)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"devicectl JSON device list could not be read while {context}: {exc}", file=sys.stderr)
            raise SystemExit(1)

def eligible_ipad_identifiers(payload):
    result = payload.get("result", {}) if isinstance(payload, dict) else {}
    devices = result.get("devices", []) if isinstance(result, dict) else []
    identifiers = []
    for device in devices:
        if not isinstance(device, dict) or not is_pairable_devicectl_device(device):
            continue
        if not is_physical_devicectl_device(device):
            continue
        if not is_ipad_devicectl_device(device):
            continue
        if not has_connect_or_install_capability(device):
            continue
        identifier = (
            string_value(nested_value(device, "hardwareProperties", "udid"))
            or string_value(nested_value(device, "deviceProperties", "udid"))
            or string_value(device.get("identifier"))
        )
        if identifier:
            identifiers.append(identifier)
    return identifiers

def is_pairable_devicectl_device(device):
    connection = device.get("connectionProperties", {})
    if not isinstance(connection, dict):
        return False
    tunnel_state = string_value(connection.get("tunnelState")).lower()
    pairing_state = string_value(connection.get("pairingState")).lower()
    # CoreDevice tunnels are demand-driven. A paired device can advertise only
    # connectdevice while idle; the details preflight below must establish the
    # tunnel and prove installapp before any build or install side effect.
    return tunnel_state == "connected" or pairing_state == "paired"

def is_physical_devicectl_device(device):
    hardware_reality = string_value(nested_value(device, "hardwareProperties", "reality")).lower()
    properties_reality = string_value(nested_value(device, "properties", "hardware", "reality")).lower()
    visibility_class = string_value(device.get("visibilityClass")).lower()
    provider = string_value(nested_value(device, "deviceProperties", "provider"))
    return (
        "physical" in {hardware_reality, properties_reality}
        and visibility_class != "simulators"
        and provider != "com.apple.CoreSimulator.SimulatorCoreDevicePlugin"
    )

def is_ipad_devicectl_device(device):
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    evidence = [
        hardware.get("deviceType") if isinstance(hardware, dict) else None,
        hardware.get("productType") if isinstance(hardware, dict) else None,
        hardware.get("marketingName") if isinstance(hardware, dict) else None,
        properties.get("deviceClass") if isinstance(properties, dict) else None,
    ]
    return any(string_value(value).lower().startswith("ipad") for value in evidence)

def has_connect_or_install_capability(device):
    capabilities = device.get("capabilities", [])
    if not isinstance(capabilities, list):
        return False
    allowed_features = {
        "com.apple.coredevice.feature.connectdevice",
        "com.apple.coredevice.feature.installapp",
    }
    return any(
        isinstance(capability, dict)
        and capability.get("featureIdentifier") in allowed_features
        for capability in capabilities
    )

def nested_value(value, *keys):
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value

def string_value(value):
    return value.strip() if isinstance(value, str) else ""

def print_selected_candidate(candidates):
    if candidates:
        print(sorted(candidates)[0])
        return True
    return False

payload = load_devicectl_device_list("selecting the real iPad target")
if print_selected_candidate(eligible_ipad_identifiers(payload)):
    raise SystemExit(0)
raise SystemExit("No paired physical iPad with CoreDevice connection capability found. Set SKYBRIDGE_REAL_DEVICE_ID explicitly if automatic discovery cannot see it.")
PY
}

IOS_DEVICE_ID=""
IOS_DEVICE_LABEL="mac-host-only"
IOS_PROVISIONING_DEVICE_ID=""
if [[ "$IDENTITY_AUDIT_ONLY" != "1" && "$MAC_HOST_ONLY" != "1" ]]; then
  IOS_DEVICE_ID="${SKYBRIDGE_REAL_DEVICE_ID:-$(pick_real_device_id)}"
  IOS_DEVICE_LABEL="$(skybridge_smoke_hash_label "$IOS_DEVICE_ID")"
fi
validate_real_ipad_device_id() {
  python3 - "$IOS_DEVICE_ID" <<'PY'
import json
import sys
import subprocess
import tempfile

target = sys.argv[1].strip()

def load_devicectl_device_details():
    with tempfile.NamedTemporaryFile(prefix="skybridge-devicectl-details-", suffix=".json") as handle:
        try:
            result = subprocess.run(
                [
                    "xcrun",
                    "devicectl",
                    "device",
                    "info",
                    "details",
                    "--device",
                    target,
                    "--timeout",
                    "60",
                    "--json-output",
                    handle.name,
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=75,
            )
            if result.returncode != 0:
                print("devicectl could not establish a CoreDevice details session with the selected iPad.", file=sys.stderr)
                raise SystemExit(1)
            handle.seek(0)
            return json.load(handle)
        except subprocess.TimeoutExpired as exc:
            print("devicectl timed out establishing a CoreDevice details session with the selected iPad.", file=sys.stderr)
            raise SystemExit(1)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"devicectl details JSON could not be read: {exc}", file=sys.stderr)
            raise SystemExit(1)

def is_connected_devicectl_device(device):
    connection = device.get("connectionProperties", {})
    if not isinstance(connection, dict):
        return False
    tunnel_state = string_value(connection.get("tunnelState")).lower()
    pairing_state = string_value(connection.get("pairingState")).lower()
    return tunnel_state == "connected" and pairing_state == "paired"

def is_physical_devicectl_device(device):
    hardware_reality = string_value(nested_value(device, "hardwareProperties", "reality")).lower()
    properties_reality = string_value(nested_value(device, "properties", "hardware", "reality")).lower()
    visibility_class = string_value(device.get("visibilityClass")).lower()
    provider = string_value(nested_value(device, "deviceProperties", "provider"))
    return (
        "physical" in {hardware_reality, properties_reality}
        and visibility_class != "simulators"
        and provider != "com.apple.CoreSimulator.SimulatorCoreDevicePlugin"
    )

def is_ipad_devicectl_device(device):
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    evidence = [
        hardware.get("deviceType") if isinstance(hardware, dict) else None,
        hardware.get("productType") if isinstance(hardware, dict) else None,
        hardware.get("marketingName") if isinstance(hardware, dict) else None,
        properties.get("deviceClass") if isinstance(properties, dict) else None,
    ]
    return any(string_value(value).lower().startswith("ipad") for value in evidence)

def has_install_application_capability(device):
    capabilities = device.get("capabilities", [])
    if not isinstance(capabilities, list):
        return False
    return any(
        isinstance(capability, dict)
        and capability.get("featureIdentifier") == "com.apple.coredevice.feature.installapp"
        for capability in capabilities
    )

def nested_value(value, *keys):
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value

def string_value(value):
    return value.strip() if isinstance(value, str) else ""

if not target:
    raise SystemExit("No real iPad target UDID was selected.")

payload = load_devicectl_device_details()
device = payload.get("result", {}) if isinstance(payload, dict) else {}
if not isinstance(device, dict):
    raise SystemExit("devicectl details did not return a device record.")

hardware_udid = (
    string_value(nested_value(device, "hardwareProperties", "udid"))
    or string_value(nested_value(device, "deviceProperties", "udid"))
)
identifiers = {
    string_value(device.get("identifier")),
    hardware_udid,
    string_value(nested_value(device, "deviceProperties", "udid")),
}
identifiers.discard("")
if target not in identifiers:
    raise SystemExit("devicectl details returned a different device than the selected target.")
if not is_connected_devicectl_device(device):
    raise SystemExit("Selected iPad did not establish a paired CoreDevice tunnel.")
if not is_physical_devicectl_device(device) or not is_ipad_devicectl_device(device):
    raise SystemExit("Selected CoreDevice target is not a physical iPad.")
if not has_install_application_capability(device):
    raise SystemExit("Connected physical iPad does not advertise installapp capability.")
if not hardware_udid:
    raise SystemExit("Connected physical iPad did not expose a hardware UDID for profile validation.")
print(hardware_udid)
PY
}
if [[ "$IDENTITY_AUDIT_ONLY" != "1" && "$MAC_HOST_ONLY" != "1" ]]; then
  IOS_PROVISIONING_DEVICE_ID="$(validate_real_ipad_device_id)"
fi
MAC_TARGET_NAME="${SKYBRIDGE_SMOKE_MAC_TARGET_NAME:-$(scutil --get ComputerName 2>/dev/null || hostname)}"
HOST_STATUS_ARTIFACT="$ARTIFACT_DIR/mac.status.log"
HOST_PQC_REPORT_ARTIFACT="$ARTIFACT_DIR/mac.pqc.json"
HOST_STDOUT_ARTIFACT="$ARTIFACT_DIR/mac.stdout.log"
HOST_STATUS="$MAC_ONLINE_RUNTIME_DIR/mac.status.log"
HOST_PQC_REPORT="$MAC_ONLINE_RUNTIME_DIR/mac.pqc.json"
HOST_STDOUT="$MAC_ONLINE_RUNTIME_DIR/mac.stdout.log"
MAC_SOURCE_STDOUT="$ARTIFACT_DIR/mac-smoke-source.stdout.log"
IOS_PQC_REPORT_NAME="ios.pqc.json"
IOS_PQC_REPORT="$ARTIFACT_DIR/$IOS_PQC_REPORT_NAME"
IOS_PQC_DEVICE_ID=""
IOS_PQC_XWING_PUBLIC_KEY_BASE64=""
MAC_REMOTE_PORT=""
MAC_ONLINE_STATUS_ARTIFACT="$ARTIFACT_DIR/mac-online-ipad.status.log"
MAC_ONLINE_STATUS="$MAC_ONLINE_RUNTIME_DIR/mac-online-ipad.status.log"
MAC_ONLINE_RUNTIME_APP_BUNDLE="$MAC_ONLINE_RUNTIME_DIR/SkyBridge Compass Pro.app"
MAC_ONLINE_STDOUT="$ARTIFACT_DIR/mac-online-ipad.stdout.log"
MAC_ONLINE_STDERR="$ARTIFACT_DIR/mac-online-ipad.stderr.log"
MAC_ONLINE_APP_STDOUT="$ARTIFACT_DIR/mac-online-ipad.app.stdout.log"
MAC_ONLINE_APP_STDERR="$ARTIFACT_DIR/mac-online-ipad.app.stderr.log"
MAC_ONLINE_OPEN_STDERR="$ARTIFACT_DIR/mac-online-ipad-open.stderr.log"
MAC_ONLINE_BUILD_LOG="$ARTIFACT_DIR/mac-online-ipad-build.log"
MAC_TO_IOS_CRYPTO_HANDSHAKE_COMPLETE=0
MAC_ONLINE_LAUNCH_STDOUT="$MAC_ONLINE_RUNTIME_DIR/mac-online-ipad.app.stdout.log"
MAC_ONLINE_LAUNCH_STDERR="$MAC_ONLINE_RUNTIME_DIR/mac-online-ipad.app.stderr.log"
MAC_ONLINE_LAUNCH_OPEN_STDERR="$MAC_ONLINE_RUNTIME_DIR/mac-online-ipad-open.stderr.log"
MAC_ONLINE_DERIVED_DATA="$ARTIFACT_DIR/DerivedData-mac-online"
MAC_ONLINE_PACKAGED_APP_BUNDLE="${SKYBRIDGE_SMOKE_MAC_ONLINE_APP_BUNDLE:-$ROOT_DIR/dist/SkyBridge Compass Pro.app}"
MAC_ONLINE_ALLOW_DEBUG_BUILD="${SKYBRIDGE_SMOKE_MAC_ONLINE_ALLOW_DEBUG_BUILD:-0}"
MAC_ONLINE_VISIBLE_CONNECTABLE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_MAC_ONLINE_VISIBLE_CONNECTABLE_TIMEOUT_SECONDS:-120}"
MAC_ONLINE_PATTERN_FINAL_GRACE_SECONDS="${SKYBRIDGE_SMOKE_MAC_ONLINE_PATTERN_FINAL_GRACE_SECONDS:-3}"
MAC_HOST_PRODUCT_APP_BUNDLE="${SKYBRIDGE_SMOKE_MAC_PRODUCT_APP_BUNDLE:-$ROOT_DIR/dist/SkyBridge Compass Pro.app}"
MAC_HOST_PRODUCT_BUNDLE_ID="com.skybridge.compass.pro"
MAC_HOST_PRODUCT_PROFILE="$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/embedded.provisionprofile"
MAC_HOST_PRODUCT_WIDGET_BUNDLE="$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex"
MAC_HOST_PRODUCT_WIDGET_BUNDLE_ID="com.skybridge.compass.pro.widgets"
MAC_HOST_PRODUCT_WIDGET_PROFILE="$MAC_HOST_PRODUCT_WIDGET_BUNDLE/Contents/embedded.provisionprofile"
MAC_HOST_SIGNING_DIR="$MAC_ONLINE_RUNTIME_DIR/mac-host-signing"
MAC_HOST_PRODUCT_ENTITLEMENTS="$MAC_HOST_SIGNING_DIR/product-entitlements.plist"
MAC_HOST_PRODUCT_WIDGET_ENTITLEMENTS="$MAC_HOST_SIGNING_DIR/product-widget-entitlements.plist"
MAC_HOST_HELPER_ENTITLEMENTS="$MAC_HOST_SIGNING_DIR/helper-entitlements.plist"
MAC_HOST_SIGNED_ENTITLEMENTS="$MAC_HOST_SIGNING_DIR/helper-signed-entitlements.plist"
MAC_ONLINE_SIGNED_ENTITLEMENTS="$MAC_HOST_SIGNING_DIR/mac-online-signed-entitlements.plist"
MAC_ONLINE_WIDGET_SIGNED_ENTITLEMENTS="$MAC_HOST_SIGNING_DIR/mac-online-widget-signed-entitlements.plist"
MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH=""
MAC_HOST_PRODUCT_TEAM_IDENTIFIER=""
MAC_HOST_PRODUCT_AUTHORITY=""
MAC_HOST_PRODUCT_CDHASH=""
MAC_HOST_PRODUCT_WIDGET_CDHASH=""
MAC_HOST_PRODUCT_EXECUTABLE_SHA256=""
MAC_HOST_PRODUCT_WIDGET_EXECUTABLE_SHA256=""
MAC_HOST_PRODUCT_PROFILE_SHA256=""
MAC_HOST_PRODUCT_WIDGET_PROFILE_SHA256=""
MAC_HOST_IDENTITY_SOURCE_STAPLER_VALID=0
MAC_HOST_IDENTITY_SOURCE_GATEKEEPER_ACCEPTED=0
MAC_HOST_HELPER_REGISTERED=0
MAC_ONLINE_APP_REGISTERED=0
MAC_LAUNCH_SERVICES_RESTORE_REQUIRED=0
MAC_ONLINE_APP_SOURCE="not-run"
MAC_ONLINE_APP_SOURCE_CURRENT=0
MAC_APP_BUNDLE="$MAC_ONLINE_RUNTIME_DIR/LocalLanInteropHost.app"
MAC_DIRECT_BIN="$SMOKE_BUILD_DIR/debug/LocalLanInteropHost"
MAC_SOURCE_DIRECT_BIN="$SMOKE_BUILD_DIR/debug/LocalLanSmokeSourceHost"
MAC_APP_BIN=""
MAC_ONLINE_APP_BUNDLE=""
MAC_ONLINE_APP_BIN=""
MAC_SMOKE_SOURCE_FRAME_A="$ARTIFACT_DIR/mac-smoke-source-a.png"
MAC_SMOKE_SOURCE_FRAME_B="$ARTIFACT_DIR/mac-smoke-source-b.png"
IOS_STATUS_NAME="ios-p2p-remote-${RUN_ID}.status.log"
IOS_STATUS_LOCAL="$ARTIFACT_DIR/$IOS_STATUS_NAME"
IOS_STATUS_CONSOLE_LIVE="$ARTIFACT_DIR/${IOS_STATUS_NAME%.status.log}.console-live.status.log"
IOS_STATUS_APP_CACHE_LOCAL="$ARTIFACT_DIR/${IOS_STATUS_NAME%.status.log}.app-cache.status.log"
IOS_STATUS_CONSOLE_SNAPSHOT="$ARTIFACT_DIR/${IOS_STATUS_NAME%.status.log}.console.status.log"
IOS_TRACE_NAME="${IOS_STATUS_NAME}.trace.log"
IOS_TRACE_LOCAL="$ARTIFACT_DIR/${IOS_STATUS_NAME%.status.log}.trace.log"
IOS_LISTENER_STATUS_NAME="${IOS_STATUS_NAME%.status.log}.listener.status.log"
IOS_LISTENER_STATUS_LOCAL="$ARTIFACT_DIR/$IOS_LISTENER_STATUS_NAME"
IOS_CONSOLE_STDERR="$ARTIFACT_DIR/ios-console.stderr.log"

skybridge_bind_macos_release_candidate_evidence \
  "$ROOT_DIR" \
  "$MAC_HOST_PRODUCT_APP_BUNDLE" \
  "$ARTIFACT_DIR" \
  "$LAB_RUN"

if [[ "$LAB_RUN" != "1" ]]; then
  echo "Formal P2P evidence is unavailable until inbound remote control and its notice panel run in the normal SkyBridgeCompassApp product entry point." >&2
  echo "LocalLanInteropHost remains diagnostic-only and cannot produce release evidence." >&2
  exit 2
fi
IOS_COPY_TIMEOUT_SECONDS="${SKYBRIDGE_IOS_COPY_TIMEOUT_SECONDS:-15}"
IOS_COPY_HARD_TIMEOUT_SECONDS="${SKYBRIDGE_IOS_COPY_HARD_TIMEOUT_SECONDS:-25}"
IOS_COPY_STATUS_APP_CACHE="${SKYBRIDGE_IOS_COPY_STATUS_APP_CACHE:-1}"
IOS_BUILD_LOG="$ARTIFACT_DIR/ios-build.log"
IOS_ARCHIVE_PATH="$ARTIFACT_DIR/SkyBridgeCompass-iOS.xcarchive"
IOS_ARCHIVE_DERIVED_DATA="$ARTIFACT_DIR/DerivedData-ios-archive"
IOS_ARCHIVE_LOG="$ARTIFACT_DIR/ios-archive.log"
IOS_EXPORT_DIR="$ARTIFACT_DIR/ios-export"
IOS_EXPORT_LOG="$ARTIFACT_DIR/ios-export.log"
IOS_EXPORTED_APP="$ARTIFACT_DIR/SkyBridgeCompass-iOS-exported.app"
IOS_RELEASE_ARCHIVE_IDENTITY="${SKYBRIDGE_IOS_RELEASE_ARCHIVE_IDENTITY:-}"
IOS_RELEASE_TESTING_IPA="${SKYBRIDGE_IOS_RELEASE_TESTING_IPA:-}"
IOS_FORMAL_EXTRACTED_APP="$ARTIFACT_DIR/ios-release-testing/SkyBridgeCompass-iOS.app"
IOS_PRODUCT_PROOF="$ARTIFACT_DIR/ios-product-proof.json"
P2P_APPROVAL_PROOF="$ARTIFACT_DIR/p2p-approval-proof.json"
IOS_DISTRIBUTION_PREFLIGHT="$MAC_ONLINE_RUNTIME_DIR/ios-distribution-signing-preflight.json"
IOS_SOURCE_REVISION=""
IOS_SOURCE_CLEAN=0
IOS_SOURCE_DIRTY_STATE="unknown"
IOS_APP_DISTRIBUTION_PROFILE=""
IOS_WIDGET_DISTRIBUTION_PROFILE=""
IOS_DISTRIBUTION_IDENTITY_HASH=""
IOS_DISTRIBUTION_PREFLIGHT_SCHEMA=""
IOS_DISTRIBUTION_SIGNING_STYLE=""
IOS_APP_PROFILE_IS_XCODE_MANAGED=""
IOS_WIDGET_PROFILE_IS_XCODE_MANAGED=""
LAUNCH_RESULT_JSON="$ARTIFACT_DIR/ios-launch.json"
IOS_PROCESS_CLEANUP_RECEIPT="$ARTIFACT_DIR/ios-process-cleanup.json"
IOS_PROCESS_LIST_JSON="$ARTIFACT_DIR/ios-processes.json"
IOS_PROCESS_LIST_LOG="$ARTIFACT_DIR/ios-processes.log"
IOS_PROCESS_LIST_STDERR="$ARTIFACT_DIR/ios-processes.stderr.log"
DEVICE_INFO_TXT="$ARTIFACT_DIR/device-info.txt"
HOST_PID=""
MAC_HOST_STARTED=0
MAC_SOURCE_PID=""
MAC_ONLINE_PID=""
IOS_CONSOLE_PID=""
IOS_CONSOLE_HANDLE_STARTED=0
IOS_CONSOLE_HANDLE_CAPTURED=0
IOS_PREINSTALL_ABSENCE_PROVEN=0
PROCESS_OWNERSHIP_PRIVATE_DIR=""
MAC_HOST_PROCESS_IDENTITY=""
MAC_SOURCE_PROCESS_IDENTITY=""
MAC_ONLINE_PROCESS_IDENTITY=""
IOS_PROCESS_IDENTITY=""
IOS_CONSOLE_HANDLE_IDENTITY=""
IOS_CONSOLE_CAPTURE_DIAGNOSTIC=""
P2P_NOTICE_SESSION=""
COMMON_REMOTE_SMOKE_FAILURE_PATTERN='classic fallback|compatibility fallback|fallback=true|legacyFallback=true|pipeline=stillImageFallback|orientation=verticalFlip|orientation=horizontalFlip|orientation=inverted|renderOrientation=verticalFlip|renderOrientation=horizontalFlip|renderOrientation=inverted|已立即回退|已回退到|fallback producer|perf=extreme.*h264|h264.*perf=extreme|suite_rejected_unknown|wireId=0x0000|wireId=0X0000|unknown suite|unknown-suite|signed LAN KEM refresh rejected|signed LAN KEM refresh failed|PIB-1 protocol identity binding failed|PIB-1 protocol identity binding rejected|PIB-1 protocol identity binding timed out|lifecycle=request>rejected|lifecycle=missing-kem>failed|lifecycle=identity-oob>failed|lifecycle=identity-oob>timeout|remoteControlNoticeRejected .*missing_required_notice_metadata|render-main-path-failed|strict-media-failed|already_connected|rejectAlreadyConnected|对端拒绝连接：already_connected|Peer rejected handshake: already_connected'
IOS_REMOTE_SMOKE_FAILURE_PATTERN="failed stage=|${COMMON_REMOTE_SMOKE_FAILURE_PATTERN}|crossNetwork=1|audioRxPlaybackDrop=[1-9][0-9]*|audioRxJitterEvicted=[1-9][0-9]*|audioRxUnderflow=[1-9][0-9]*|audioRxRebuffer=[1-9][0-9]*|jitterEvicted=[1-9][0-9]*|playbackDrop=[1-9][0-9]*|datagrams=[1-9][0-9][0-9]+ .*probable=rx-decode-stalled|HEVC 连续失败|临时降级 H\\.264|codec=h264"
HOST_REMOTE_SMOKE_FAILURE_PATTERN="${COMMON_REMOTE_SMOKE_FAILURE_PATTERN}|failed stage=mac-host|failed stage=mac-smoke-source|failed stage=(identity|handshake|remote-desktop|remote-control|media)|remoteControlNoticeTimedOut .*transport=p2p|mac-sck-start .*codec=h264|mac-sck-first-frame codec=h264|mac-sck-tx .*codec=h264 .*capturesAudio=false|mac-sck-encode-failed .*capturesAudio=false|mac-sck-tx .*encodeFailures=[1-9][0-9]*|mac-stream-config .*damage=true .*perf=extreme"
MAC_ONLINE_WAIT_FAILURE_PATTERN="failed stage=|mac-online-connect-result .*result=failure|mac-online-connect-app .*result=failure|${COMMON_REMOTE_SMOKE_FAILURE_PATTERN}"
REMOTE_CONTROL_SECURITY_NOTICE_LOCALIZATION_KEYS=(
  "remoteControl.securityNotice.account"
  "remoteControl.securityNotice.activeTitle"
  "remoteControl.securityNotice.appName"
  "remoteControl.securityNotice.approve"
  "remoteControl.securityNotice.close"
  "remoteControl.securityNotice.collapse"
  "remoteControl.securityNotice.device"
  "remoteControl.securityNotice.disconnect"
  "remoteControl.securityNotice.expand"
  "remoteControl.securityNotice.nebulaID"
  "remoteControl.securityNotice.pendingTitle"
  "remoteControl.securityNotice.pqc"
  "remoteControl.securityNotice.reject"
  "remoteControl.securityNotice.remoteIP"
  "remoteControl.securityNotice.subtitle"
  "remoteControl.securityNotice.transport"
  "remoteControl.securityNotice.transport.p2p"
  "remoteControl.securityNotice.transport.webrtc"
  "remoteControl.securityNotice.valueUnavailable"
  "remoteControl.securityNotice.windowTitle"
)

validate_remote_control_security_notice_localizations() {
  local resource_root="$1"
  local phase="$2"
  local locale
  local strings_path
  local locales=("en" "ja" "zh-Hans")

  if [[ "${#REMOTE_CONTROL_SECURITY_NOTICE_LOCALIZATION_KEYS[@]}" -ne 20 ]]; then
    echo "Remote-control security notice localization contract must contain exactly 20 keys." >&2
    return 1
  fi

  for locale in "${locales[@]}"; do
    strings_path="$resource_root/$locale.lproj/Localizable.strings"
    if [[ ! -f "$strings_path" || -L "$strings_path" ]]; then
      echo "Missing regular $locale remote-control localization during $phase validation: $strings_path" >&2
      return 1
    fi
    if ! /usr/bin/plutil -lint "$strings_path" >/dev/null; then
      echo "Malformed $locale Localizable.strings during $phase validation." >&2
      return 1
    fi
    if ! python3 - "$strings_path" "$locale" "$phase" "${REMOTE_CONTROL_SECURITY_NOTICE_LOCALIZATION_KEYS[@]}" <<'PY'
import json
import subprocess
import sys

strings_path, locale, phase, *required_keys = sys.argv[1:]
completed = subprocess.run(
    ["/usr/bin/plutil", "-convert", "json", "-o", "-", strings_path],
    check=False,
    capture_output=True,
    text=True,
)
if completed.returncode != 0:
    print(f"Unable to decode {locale} localization during {phase} validation", file=sys.stderr)
    raise SystemExit(1)
payload = json.loads(completed.stdout)
if not isinstance(payload, dict):
    print(f"{locale} localization is not a dictionary during {phase} validation", file=sys.stderr)
    raise SystemExit(1)
missing_or_raw = [
    key
    for key in required_keys
    if not isinstance(payload.get(key), str)
    or not payload[key].strip()
    or payload[key] == key
]
if missing_or_raw:
    print(
        f"{locale} localization is missing required non-raw keys during {phase} validation: "
        + ",".join(missing_or_raw),
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
    then
      return 1
    fi
  done
}

fail_if_forbidden_fallback_evidence() {
  local path="$1"
  local label="$2"
  [[ -f "$path" ]] || return 0
  python3 - "$path" "$label" <<'PY'
import re
import sys

path, label = sys.argv[1:]
allowed = {
    "attemptedFallback": {"none"},
    "fallbackResult": {"none", "not-attempted"},
}
with open(path, "r", encoding="utf-8", errors="replace") as handle:
    for line in handle:
        for key, allowed_values in allowed.items():
            for value in re.findall(rf"\b{key}=([^\s,;]+)", line):
                if value.lower() not in allowed_values:
                    print(
                        f"Detected forbidden fallback evidence while waiting for {label}: "
                        f"{key}={value} in {path}",
                        file=sys.stderr,
                    )
                    print(line.rstrip(), file=sys.stderr)
                    raise SystemExit(1)
raise SystemExit(0)
PY
}

sync_mac_online_launch_stdio() {
  if [[ -f "$MAC_ONLINE_STATUS" ]]; then
    cp -f "$MAC_ONLINE_STATUS" "$MAC_ONLINE_STATUS_ARTIFACT" 2>/dev/null || true
  fi
  if [[ -f "$MAC_ONLINE_LAUNCH_STDOUT" ]]; then
    cp -f "$MAC_ONLINE_LAUNCH_STDOUT" "$MAC_ONLINE_APP_STDOUT" 2>/dev/null || true
  fi
  if [[ -f "$MAC_ONLINE_LAUNCH_STDERR" ]]; then
    cp -f "$MAC_ONLINE_LAUNCH_STDERR" "$MAC_ONLINE_APP_STDERR" 2>/dev/null || true
  fi
  if [[ -f "$MAC_ONLINE_LAUNCH_OPEN_STDERR" ]]; then
    cp -f "$MAC_ONLINE_LAUNCH_OPEN_STDERR" "$MAC_ONLINE_OPEN_STDERR" 2>/dev/null || true
  fi
}

sync_macos_smoke_host_artifacts() {
  local source_path
  local destination_path
  local pair

  if [[ "$MAC_HOST_STARTED" == "1" ]]; then
    if [[ ! -s "$HOST_STATUS" ]] || [[ ! -s "$HOST_PQC_REPORT" ]] || [[ ! -f "$HOST_STDOUT" ]]; then
      echo "Required macOS smoke host evidence is missing after the host was launched." >&2
      return 1
    fi
  fi

  for pair in \
    "$HOST_STATUS|$HOST_STATUS_ARTIFACT" \
    "$HOST_PQC_REPORT|$HOST_PQC_REPORT_ARTIFACT" \
    "$HOST_STDOUT|$HOST_STDOUT_ARTIFACT"
  do
    source_path="${pair%%|*}"
    destination_path="${pair#*|}"
    if [[ -f "$source_path" ]] && ! cp -f -- "$source_path" "$destination_path"; then
      echo "Unable to persist macOS smoke host artifact: $destination_path" >&2
      return 1
    fi
  done
}

compute_source_input_snapshot() {
  local snapshot
  local digest
  local file_count
  local extra

  if [[ ! -f "$SOURCE_INPUT_DIGEST_TOOL" || -L "$SOURCE_INPUT_DIGEST_TOOL" ]]; then
    echo "Source-input digest tool is missing or symlinked." >&2
    return 1
  fi
  if ! snapshot="$(
    python3 "$SOURCE_INPUT_DIGEST_TOOL" \
      --root "$ROOT_DIR" \
      "${SOURCE_INPUT_PATHS[@]}"
  )"; then
    return 1
  fi
  read -r digest file_count extra <<<"$snapshot"
  if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]] || \
     [[ ! "$file_count" =~ ^[1-9][0-9]*$ ]] || \
     [[ -n "$extra" ]]; then
    echo "Source-input digest tool returned malformed output." >&2
    return 1
  fi
  printf '%s %s\n' "$digest" "$file_count"
}

capture_source_input_binding() {
  local snapshot
  if ! snapshot="$(compute_source_input_snapshot)"; then
    return 1
  fi
  read -r IOS_SOURCE_INPUT_DIGEST IOS_SOURCE_INPUT_FILE_COUNT <<<"$snapshot"
  printf '%s stage=initial digest=%s files=%s matched=1\n' \
    "$(timestamp_utc)" \
    "$IOS_SOURCE_INPUT_DIGEST" \
    "$IOS_SOURCE_INPUT_FILE_COUNT" \
    >"$SOURCE_INPUT_BINDING_LOG"
}

verify_source_input_binding_unchanged() {
  local stage="$1"
  local snapshot
  local current_digest
  local current_file_count
  local matched=0

  if ! snapshot="$(compute_source_input_snapshot)"; then
    return 1
  fi
  read -r current_digest current_file_count <<<"$snapshot"
  if [[ "$current_digest" == "$IOS_SOURCE_INPUT_DIGEST" && \
        "$current_file_count" == "$IOS_SOURCE_INPUT_FILE_COUNT" ]]; then
    matched=1
  fi
  printf '%s stage=%s digest=%s files=%s matched=%s\n' \
    "$(timestamp_utc)" "$stage" "$current_digest" "$current_file_count" "$matched" \
    >>"$SOURCE_INPUT_BINDING_LOG"
  printf '{"schemaVersion":1,"algorithm":"sha256","stage":"%s","sourceInputDigest":"%s","currentDigest":"%s","fileCount":%s,"currentFileCount":%s,"matched":%s}\n' \
    "$stage" \
    "$IOS_SOURCE_INPUT_DIGEST" \
    "$current_digest" \
    "$IOS_SOURCE_INPUT_FILE_COUNT" \
    "$current_file_count" \
    "$([[ "$matched" == "1" ]] && printf true || printf false)" \
    >"$SOURCE_INPUT_BINDING_PROOF"
  if [[ "$matched" != "1" ]]; then
    echo "Source inputs changed while producing the $stage smoke product; refusing mixed-source evidence." >&2
    return 1
  fi
}

capture_ios_release_source_provenance() {
  local repository_root
  local dirty_entries

  if ! repository_root="$(git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null)" || \
     [[ "$repository_root" != "$ROOT_DIR" ]]; then
    echo "The P2P smoke must run from the canonical Git repository root." >&2
    return 1
  fi
  if ! IOS_SOURCE_REVISION="$(git -C "$ROOT_DIR" rev-parse --verify HEAD 2>/dev/null)" || \
     [[ ! "$IOS_SOURCE_REVISION" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
    echo "Unable to resolve a concrete Git source revision for the iOS product build." >&2
    return 1
  fi
  if ! dirty_entries="$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)"; then
    echo "Unable to determine Git source provenance for the iOS product build." >&2
    return 1
  fi
  if [[ -z "$dirty_entries" ]]; then
    IOS_SOURCE_CLEAN=1
    IOS_SOURCE_DIRTY_STATE="clean"
  else
    IOS_SOURCE_CLEAN=0
    IOS_SOURCE_DIRTY_STATE="dirty"
  fi
  if [[ "$LAB_RUN" != "1" && "$IOS_SOURCE_CLEAN" != "1" ]]; then
    echo "Formal P2P acceptance requires a clean Git worktree; current source provenance is dirty." >&2
    return 1
  fi
  capture_source_input_binding
}

resolve_ios_distribution_signing_inputs() {
  if [[ "$IOS_BUILD_CONFIGURATION" != "Release" ]]; then
    return 0
  fi

  python3 "$ROOT_DIR/Scripts/resolve_ios_distribution_signing.py" \
    "$IOS_DISTRIBUTION_PREFLIGHT" \
    "$IOS_APP_DISTRIBUTION_PROFILE_INPUT" \
    "$IOS_WIDGET_DISTRIBUTION_PROFILE_INPUT" \
    "$IOS_TEAM_IDENTIFIER" \
    "$IOS_BUNDLE_ID" \
    "$IOS_WIDGET_BUNDLE_ID" \
    "$IOS_PROVISIONING_DEVICE_ID" \
    automatic

  IOS_APP_DISTRIBUTION_PROFILE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["appProfilePath"])' "$IOS_DISTRIBUTION_PREFLIGHT")"
  IOS_WIDGET_DISTRIBUTION_PROFILE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["widgetProfilePath"])' "$IOS_DISTRIBUTION_PREFLIGHT")"
  IOS_DISTRIBUTION_IDENTITY_HASH="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["identityHash"])' "$IOS_DISTRIBUTION_PREFLIGHT")"
  IOS_DISTRIBUTION_PREFLIGHT_SCHEMA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["schemaVersion"])' "$IOS_DISTRIBUTION_PREFLIGHT")"
  IOS_DISTRIBUTION_SIGNING_STYLE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["signingStyle"])' "$IOS_DISTRIBUTION_PREFLIGHT")"
  IOS_APP_PROFILE_IS_XCODE_MANAGED="$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1], encoding="utf-8"))["appProfileIsXcodeManaged"]).lower())' "$IOS_DISTRIBUTION_PREFLIGHT")"
  IOS_WIDGET_PROFILE_IS_XCODE_MANAGED="$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1], encoding="utf-8"))["widgetProfileIsXcodeManaged"]).lower())' "$IOS_DISTRIBUTION_PREFLIGHT")"

  if [[ "$IOS_DISTRIBUTION_PREFLIGHT_SCHEMA" != "2" || \
        ! "$IOS_DISTRIBUTION_IDENTITY_HASH" =~ ^[0-9A-F]{40}$ || \
        "$IOS_DISTRIBUTION_SIGNING_STYLE" != "automatic" || \
        "$IOS_APP_PROFILE_IS_XCODE_MANAGED" != "true" || \
        "$IOS_WIDGET_PROFILE_IS_XCODE_MANAGED" != "true" ]]; then
    echo "Resolved iOS distribution signing inputs violate the strict preflight contract." >&2
    return 1
  fi
  if ! skybridge_profile_supports_requested_profile_backed_entitlements \
    "$IOS_APP_DISTRIBUTION_PROFILE" \
    "$IOS_RELEASE_ENTITLEMENTS"; then
    echo "The installed iOS app distribution profile does not cover Release entitlements." >&2
    return 1
  fi
}

write_ios_p2p_product_proof() {
  if (( $# != 2 )); then
    echo "write_ios_p2p_product_proof requires app and Widget embedded profiles" >&2
    return 2
  fi
  skybridge_write_ios_distribution_product_proof \
    "$IOS_APP_PATH" \
    "$IOS_WIDGET_BUNDLE" \
    "$1" \
    "$2" \
    "$IOS_EXPECTED_ENTITLEMENTS" \
    "$IOS_PRODUCT_PROOF" \
    "$MAC_ONLINE_RUNTIME_DIR/ios-signing-proof" \
    "$IOS_BUNDLE_ID" \
    "$IOS_WIDGET_BUNDLE_ID" \
    "$IOS_TEAM_IDENTIFIER" \
    "$IOS_BUILD_CONFIGURATION" \
    "$LAB_RUN" \
    "$IOS_SOURCE_REVISION" \
    "$IOS_SOURCE_CLEAN" \
    "$IOS_PROVISIONING_DEVICE_ID" \
    "$IOS_APP_DISTRIBUTION_PROFILE" \
    "$IOS_WIDGET_DISTRIBUTION_PROFILE" \
    "$ROOT_DIR/Scripts/verify_ios_distribution_product.py"
}

verify_ios_product_source_input_binding() {
  local product_digest
  local executable_name
  local executable_path
  local executable_sha256
  local info_plist_sha256

  product_digest="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :SkyBridgePackagingSourceInputDigest' \
      "$IOS_APP_PATH/Info.plist" 2>/dev/null || true
  )"
  if [[ "$product_digest" != "$IOS_SOURCE_INPUT_DIGEST" ]]; then
    echo "The signed iOS product is not bound to the measured source-input digest." >&2
    return 1
  fi
  executable_name="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$IOS_APP_PATH/Info.plist" 2>/dev/null || true
  )"
  executable_path="$IOS_APP_PATH/$executable_name"
  if [[ -z "$executable_name" || ! -f "$executable_path" ]]; then
    echo "The exact iOS app executable is missing from the source-bound product." >&2
    return 1
  fi
  executable_sha256="$(shasum -a 256 "$executable_path" | awk '{print $1}')"
  info_plist_sha256="$(shasum -a 256 "$IOS_APP_PATH/Info.plist" | awk '{print $1}')"
  if [[ ! "$executable_sha256" =~ ^[0-9a-f]{64}$ || \
        ! "$info_plist_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Unable to bind the exact iOS executable and signed Info.plist bytes." >&2
    return 1
  fi
  printf '{"schemaVersion":1,"algorithm":"sha256","stage":"product","sourceInputDigest":"%s","currentDigest":"%s","fileCount":%s,"currentFileCount":%s,"matched":true,"appExecutableSHA256":"%s","infoPlistSHA256":"%s"}\n' \
    "$IOS_SOURCE_INPUT_DIGEST" \
    "$IOS_SOURCE_INPUT_DIGEST" \
    "$IOS_SOURCE_INPUT_FILE_COUNT" \
    "$IOS_SOURCE_INPUT_FILE_COUNT" \
    "$executable_sha256" \
    "$info_plist_sha256" \
    >"$SOURCE_INPUT_BINDING_PROOF"
}

finalize_release_acceptance_manifests_after_cleanup() {
  local private_manifest="$ARTIFACT_DIR/release-acceptance.json"
  local public_manifest="$PUBLIC_ARTIFACT_DIR/release-acceptance.json"
  local identity_arguments=()

  if [[ "$LAB_RUN" != "1" ]]; then
    identity_arguments=(--archive-identity "$IOS_RELEASE_ARCHIVE_IDENTITY")
  fi

  python3 "$ROOT_DIR/Scripts/finalize_release_acceptance_manifests.py" \
    --private-manifest "$private_manifest" \
    --public-manifest "$public_manifest" \
    "${identity_arguments[@]}"
}

initialize_ios_process_ownership_session() {
  if [[ -n "$PROCESS_OWNERSHIP_PRIVATE_DIR" ]]; then
    echo "Private P2P remote process-ownership directory was initialized more than once." >&2
    return 1
  fi
  rm -f -- "$IOS_PROCESS_CLEANUP_RECEIPT"
  PROCESS_OWNERSHIP_PRIVATE_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/skybridge-p2p-remote-process-ownership.XXXXXX")"
  MAC_HOST_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/mac-host-process-identity.json"
  MAC_SOURCE_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/mac-source-process-identity.json"
  MAC_ONLINE_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/mac-online-process-identity.json"
  IOS_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-process-identity.json"
  IOS_CONSOLE_HANDLE_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console-handle-identity.json"
  IOS_CONSOLE_CAPTURE_DIAGNOSTIC="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console-capture.log"
  chmod 0700 "$PROCESS_OWNERSHIP_PRIVATE_DIR"
}

destroy_ios_process_ownership_session() {
  local cleanup_failed=0
  local private_path

  [[ -n "$PROCESS_OWNERSHIP_PRIVATE_DIR" ]] || return 0
  for private_path in \
    "$MAC_HOST_PROCESS_IDENTITY" \
    "$MAC_SOURCE_PROCESS_IDENTITY" \
    "$MAC_ONLINE_PROCESS_IDENTITY" \
    "$IOS_PROCESS_IDENTITY" \
    "$IOS_CONSOLE_HANDLE_IDENTITY" \
    "$IOS_CONSOLE_CAPTURE_DIAGNOSTIC"; do
    case "$private_path" in
      "$PROCESS_OWNERSHIP_PRIVATE_DIR/mac-host-process-identity.json"|\
      "$PROCESS_OWNERSHIP_PRIVATE_DIR/mac-source-process-identity.json"|\
      "$PROCESS_OWNERSHIP_PRIVATE_DIR/mac-online-process-identity.json"|\
      "$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-process-identity.json"|\
      "$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console-handle-identity.json"|\
      "$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console-capture.log")
        if [[ -e "$private_path" || -L "$private_path" ]] \
          && ! rm -f -- "$private_path"; then
          echo "Unable to remove a private P2P remote process-ownership record." >&2
          cleanup_failed=1
        fi
        ;;
      *)
        echo "Refusing to remove an unexpected P2P remote process-ownership path." >&2
        cleanup_failed=1
        ;;
    esac
  done
  if ! rmdir -- "$PROCESS_OWNERSHIP_PRIVATE_DIR" 2>/dev/null; then
    echo "Private P2P remote process-ownership directory is not empty or could not be removed." >&2
    cleanup_failed=1
  fi
  return "$cleanup_failed"
}

write_ios_process_cleanup_receipt() {
  python3 - "$IOS_PROCESS_CLEANUP_RECEIPT" <<'PY'
import json
import os
import pathlib
import tempfile
import sys

output = pathlib.Path(sys.argv[1])
payload = {
    "cleanupComplete": True,
    "exactConsoleHandle": True,
    "pidOnlySignal": False,
    "remoteAbsenceProven": True,
    "schemaVersion": 1,
}
descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
temporary = pathlib.Path(temporary_name)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, output)
finally:
    if temporary.exists():
        temporary.unlink()
PY
}

ios_console_handle_is_exact_and_running() {
  [[ "$IOS_CONSOLE_HANDLE_CAPTURED" == "1" ]] \
    && [[ -n "$IOS_CONSOLE_PID" ]] \
    && [[ -f "$IOS_CONSOLE_HANDLE_IDENTITY" ]] \
    && skybridge_ios_console_handle_status \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$IOS_CONSOLE_PID" \
      "$IOS_CONSOLE_HANDLE_IDENTITY" >/dev/null 2>&1
}

finish_failed_ios_console_launch_without_process() {
  local handle_status

  if skybridge_ios_console_handle_status \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$IOS_CONSOLE_PID" \
    "$IOS_CONSOLE_HANDLE_IDENTITY" >/dev/null 2>&1; then
    handle_status=0
  else
    handle_status=$?
  fi
  if (( handle_status != 1 )); then
    echo "Refusing no-process launch cleanup because the exact console handle is not proven absent." >&2
    return 1
  fi
  if ! skybridge_ios_wait_console_handle_exit \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$IOS_CONSOLE_PID" \
    "$IOS_CONSOLE_HANDLE_IDENTITY" \
    15; then
    return 1
  fi
  if ! skybridge_ios_require_app_absent_after_handle_exit \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$IOS_DEVICE_ID" \
    "$IOS_APP_PATH" \
    "$PROCESS_OWNERSHIP_PRIVATE_DIR" \
    "$DEVICECTL_TIMEOUT_SECONDS"; then
    return 1
  fi

  IOS_CONSOLE_HANDLE_STARTED=0
  IOS_CONSOLE_HANDLE_CAPTURED=0
  IOS_CONSOLE_PID=""
  return 0
}

terminate_ios_remote_smoke_app_exact() {
  local reason="${1:?missing iOS P2P remote termination reason}"
  local exited_ios_pid
  local handle_status

  if [[ "$IOS_CONSOLE_HANDLE_STARTED" != "1" ]] \
    || [[ "$IOS_CONSOLE_HANDLE_CAPTURED" != "1" ]] \
    || [[ -z "$IOS_CONSOLE_PID" ]] \
    || [[ ! -f "$IOS_CONSOLE_HANDLE_IDENTITY" ]]; then
    echo "Refusing iOS P2P remote cleanup because exact console-handle ownership was not captured." >&2
    return 1
  fi

  if skybridge_ios_console_handle_status \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$IOS_CONSOLE_PID" \
    "$IOS_CONSOLE_HANDLE_IDENTITY"; then
    handle_status=0
  else
    handle_status=$?
  fi
  case "$handle_status" in
    0)
      if ! skybridge_ios_signal_console_handle \
        "$PROCESS_OWNERSHIP_HELPER" \
        "$IOS_CONSOLE_PID" \
        "$IOS_CONSOLE_HANDLE_IDENTITY"; then
        echo "Failed to signal the exact iOS P2P remote console launch handle." >&2
        return 1
      fi
      ;;
    1)
      wait "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
      ;;
    *)
      echo "Refusing iOS P2P remote cleanup because the console launch handle is unverifiable." >&2
      return 1
      ;;
  esac

  if ! skybridge_ios_wait_console_handle_exit \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$IOS_CONSOLE_PID" \
    "$IOS_CONSOLE_HANDLE_IDENTITY" \
    15; then
    return 1
  fi
  if ! skybridge_ios_capture_exited_console_identity \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$LAUNCH_RESULT_JSON" \
    "$IOS_APP_PATH" \
    "$IOS_PROCESS_IDENTITY"; then
    echo "Unable to capture the exited iOS P2P remote launch identity." >&2
    return 1
  fi
  if ! exited_ios_pid="$(python3 "$PROCESS_OWNERSHIP_HELPER" identity-pid \
    --platform ios \
    --identity "$IOS_PROCESS_IDENTITY")" \
    || ! [[ "$exited_ios_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "Unable to read the exited iOS P2P remote launch PID evidence." >&2
    return 1
  fi
  if ! skybridge_ios_require_app_absent_after_handle_exit \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$IOS_DEVICE_ID" \
    "$IOS_APP_PATH" \
    "$PROCESS_OWNERSHIP_PRIVATE_DIR" \
    "$DEVICECTL_TIMEOUT_SECONDS"; then
    return 1
  fi
  if ! write_ios_process_cleanup_receipt; then
    echo "Unable to write the iOS P2P remote process-cleanup receipt." >&2
    return 1
  fi

  append_host_status "ios-remote-smoke terminated exactConsoleHandle=1 remoteAbsence=1 reason=$reason"
  IOS_CONSOLE_HANDLE_STARTED=0
  IOS_CONSOLE_HANDLE_CAPTURED=0
  IOS_CONSOLE_PID=""
  return 0
}

cleanup() {
  local original_status=$?
  local cleanup_status=0
  local ios_cleanup_status=0
  local mac_cleanup_status=0
  local launch_services_was_mutated=0
  trap - EXIT INT TERM

  if [[ "${MAC_LAUNCH_SERVICES_RESTORE_REQUIRED:-0}" == "1" || \
        "${MAC_ONLINE_APP_REGISTERED:-0}" == "1" || \
        "${MAC_HOST_HELPER_REGISTERED:-0}" == "1" ]]; then
    launch_services_was_mutated=1
  fi

  if [[ "$IOS_CONSOLE_HANDLE_STARTED" == "1" ]]; then
    if ! terminate_ios_remote_smoke_app_exact "trap-cleanup"; then
      ios_cleanup_status=1
      cleanup_status=1
      echo "failed stage=cleanup phase=ios-process reason=exact-process-exit-unverified" >&2
    fi
  elif [[ "$IOS_CONSOLE_HANDLE_CAPTURED" == "1" ]]; then
    ios_cleanup_status=1
    cleanup_status=1
    echo "failed stage=cleanup phase=ios-process reason=inconsistent-console-handle-state" >&2
  fi
  if [[ -n "${IOS_DEVICE_ID:-}" && ( -s "${IOS_STATUS_CONSOLE_LIVE:-}" || -n "${IOS_CONSOLE_PID:-}" ) ]]; then
    copy_ios_status || true
    copy_ios_trace || true
  fi
  if [[ -n "$HOST_PID" ]]; then
    if ! skybridge_mac_terminate_owned_process \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$HOST_PID" \
      "$MAC_HOST_PROCESS_IDENTITY" \
      "macOS smoke host"; then
      cleanup_status=1
      mac_cleanup_status=1
      echo "failed stage=cleanup phase=mac-host-process reason=exact-process-exit-unverified" >&2
    fi
  fi
  if [[ -n "$MAC_SOURCE_PID" ]]; then
    if ! skybridge_mac_terminate_owned_process \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$MAC_SOURCE_PID" \
      "$MAC_SOURCE_PROCESS_IDENTITY" \
      "macOS smoke source"; then
      cleanup_status=1
      mac_cleanup_status=1
      echo "failed stage=cleanup phase=mac-source-process reason=exact-process-exit-unverified" >&2
    fi
  fi
  if [[ -n "$MAC_ONLINE_PID" ]]; then
    if ! skybridge_mac_terminate_owned_process \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$MAC_ONLINE_PID" \
      "$MAC_ONLINE_PROCESS_IDENTITY" \
      "macOS online iPad client"; then
      cleanup_status=1
      mac_cleanup_status=1
      echo "failed stage=cleanup phase=mac-online-process reason=exact-process-exit-unverified" >&2
    fi
  fi
  if [[ "${MAC_ONLINE_APP_REGISTERED:-0}" == "1" ]]; then
    if ! cleanup_macos_online_ipad_launch_services_registration; then
      cleanup_status=1
      echo "failed stage=cleanup phase=mac-online-launch-services reason=runtime-app-or-widget-registration-remains runtime=preserved-private" >&2
    fi
  elif [[ -n "${MAC_ONLINE_APP_BIN:-}" ]] && \
       ! skybridge_mac_require_executable_absent \
         "$PROCESS_OWNERSHIP_HELPER" \
         "$MAC_ONLINE_APP_BIN" \
         "macOS online iPad client" >/dev/null 2>&1; then
    cleanup_status=1
    echo "failed stage=cleanup phase=mac-online-process reason=exact-client-process-remains" >&2
  fi
  if ! cleanup_macos_smoke_host_launch_services_registration; then
    cleanup_status=1
    echo "failed stage=cleanup phase=helper-launch-services reason=helper-registration-cleanup-failed runtime=preserved-private" >&2
  fi
  if [[ "$launch_services_was_mutated" == "1" ]] && \
     ! restore_canonical_macos_launch_services_registration_last; then
    cleanup_status=1
    echo "failed stage=cleanup phase=launch-services-restore reason=canonical-app-or-runtime-absence-proof-missing runtime=preserved-private" >&2
  fi
  if [[ -n "$PROCESS_OWNERSHIP_PRIVATE_DIR" ]]; then
    if (( ios_cleanup_status == 0 && mac_cleanup_status == 0 )); then
      if ! destroy_ios_process_ownership_session; then
        cleanup_status=1
        echo "failed stage=cleanup phase=process-ownership reason=private-ownership-remove-failed" >&2
      fi
    else
      echo "Preserving private P2P remote ownership diagnostics after unverifiable cleanup: $PROCESS_OWNERSHIP_PRIVATE_DIR" >&2
    fi
  fi
  if ! sync_macos_smoke_host_artifacts; then
    cleanup_status=1
    echo "failed stage=cleanup phase=artifact-sync reason=mac-host-runtime-artifact-copy-failed" >&2
  fi
  sync_mac_online_launch_stdio
  rm -f -- \
    "$MAC_ONLINE_LAUNCH_STDOUT" \
    "$MAC_ONLINE_LAUNCH_STDERR" \
    "$MAC_ONLINE_LAUNCH_OPEN_STDERR"
  if [[ "${MAC_LAUNCH_SERVICES_RESTORE_REQUIRED:-0}" == "1" || \
        "${MAC_HOST_HELPER_REGISTERED:-0}" == "1" || \
        "${MAC_ONLINE_APP_REGISTERED:-0}" == "1" || \
        "$cleanup_status" != "0" ]]; then
    cleanup_status=1
    echo "failed stage=cleanup phase=runtime-remove reason=launch-services-cleanup-incomplete runtime=preserved-private" >&2
  else
    if ! rm -rf -- "$MAC_ONLINE_RUNTIME_DIR" || [[ -e "$MAC_ONLINE_RUNTIME_DIR" ]]; then
      cleanup_status=1
      echo "failed stage=cleanup phase=runtime-remove reason=private-runtime-remove-failed" >&2
    fi
  fi

  if (( original_status == 0 && cleanup_status == 0 )); then
    if [[ "$MAC_HOST_ONLY" != "1" && "$ACCEPTANCE_CANDIDATE_READY" != "1" ]]; then
      cleanup_status=1
      echo "failed stage=cleanup phase=release-acceptance reason=candidate-ineligible" >&2
    elif [[ "$MAC_HOST_ONLY" != "1" ]] \
      && ! finalize_release_acceptance_manifests_after_cleanup; then
      cleanup_status=1
      echo "failed stage=cleanup phase=release-acceptance reason=manifest-finalization-failed" >&2
    fi
  fi

  if (( original_status == 0 && cleanup_status == 0 )) \
    && [[ "$MAC_HOST_ONLY" != "1" && "$ACCEPTANCE_CANDIDATE_READY" == "1" ]]; then
    echo "==> Real-device P2P remote desktop smoke succeeded after verified Mac/iOS process cleanup"
    echo "    mac status: $HOST_STATUS_ARTIFACT"
    echo "    ios status: $IOS_STATUS_LOCAL"
    echo "    host stdout: $HOST_STDOUT_ARTIFACT"
  fi

  if (( cleanup_status != 0 )) \
    && { (( original_status == 0 )) || [[ "$MAC_HOST_ONLY" == "1" ]]; }; then
    exit "$cleanup_status"
  fi
  exit "$original_status"
}

exit_mac_host_only_on_signal() {
  local signal_status="$1"
  trap - INT TERM
  exit "$signal_status"
}

trap cleanup EXIT
if [[ "$MAC_HOST_ONLY" == "1" ]]; then
  trap 'exit_mac_host_only_on_signal 130' INT
  trap 'exit_mac_host_only_on_signal 143' TERM
fi

require_remote_control_notice_identity_env() {
  if [[ "${SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE:-0}" != "1" ]]; then
    return 0
  fi
  if [[ -z "${SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME:-}" ]]; then
    echo "SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME is required when SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE=1" >&2
    exit 2
  fi
  if [[ -z "${SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID:-}" ]]; then
    echo "SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID is required when SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE=1" >&2
    exit 2
  fi
  if [[ -z "${SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME:-}" ]]; then
    echo "SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME is required when SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE=1" >&2
    exit 2
  fi
  if [[ -z "${SKYBRIDGE_SMOKE_REMOTE_NEBULA_ID:-}" ]]; then
    echo "SKYBRIDGE_SMOKE_REMOTE_NEBULA_ID is required when SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE=1" >&2
    exit 2
  fi
}

timestamp_utc() {
  date -u +"[%Y-%m-%dT%H:%M:%SZ]"
}

append_host_status() {
  printf '%s %s\n' "$(timestamp_utc)" "$*" >>"$HOST_STATUS"
}

write_mac_host_ready_file() {
  local executable_sha256

  if [[ "$MAC_HOST_ONLY" != "1" ]]; then
    echo "Refusing to write a macOS host-only readiness record outside host-only mode." >&2
    return 2
  fi
  if [[ ! -f "$MAC_APP_BIN" || ! -x "$MAC_APP_BIN" || -L "$MAC_APP_BIN" ]]; then
    echo "Signed macOS host-only executable is missing or unsafe." >&2
    return 1
  fi
  executable_sha256="$(shasum -a 256 "$MAC_APP_BIN" | awk '{print $1}')"
  if [[ ! "$executable_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Unable to bind the signed macOS host-only executable bytes." >&2
    return 1
  fi

  python3 - \
    "$MAC_HOST_READY_FILE" \
    "$ARTIFACT_DIR" \
    "$HOST_STATUS" \
    "$HOST_PQC_REPORT" \
    "$HOST_PID" \
    "$$" \
    "$MAC_CONTROL_PORT" \
    "$MAC_REMOTE_PORT" \
    "$IOS_SOURCE_INPUT_DIGEST" \
    "$executable_sha256" <<'PY'
import json
import os
import pathlib
import stat
import sys
import tempfile

(
    output_raw,
    artifact_raw,
    status_raw,
    pqc_raw,
    host_pid_raw,
    runner_pid_raw,
    control_port_raw,
    remote_port_raw,
    source_digest,
    executable_digest,
) = sys.argv[1:]

output = pathlib.Path(output_raw)
artifact = pathlib.Path(artifact_raw)
if output.parent.resolve() != artifact.resolve() or output.name != "mac-host-ready.json":
    raise SystemExit("macOS host-only readiness path escaped its private artifact directory")
if output.exists() and (output.is_symlink() or not output.is_file()):
    raise SystemExit("macOS host-only readiness target is not a regular file")
if not stat.S_ISDIR(os.lstat(artifact).st_mode):
    raise SystemExit("macOS host-only artifact directory is not a directory")

def bounded_positive(raw: str, label: str, maximum: int) -> int:
    if not raw.isdigit():
        raise SystemExit(f"{label} is not a positive integer")
    value = int(raw)
    if value < 1 or value > maximum:
        raise SystemExit(f"{label} is outside its bounded range")
    return value

if len(source_digest) != 64 or any(character not in "0123456789abcdef" for character in source_digest):
    raise SystemExit("source input digest is malformed")
if len(executable_digest) != 64 or any(character not in "0123456789abcdef" for character in executable_digest):
    raise SystemExit("signed host executable digest is malformed")

payload = {
    "acceptanceEligible": False,
    "artifactDirectory": str(artifact),
    "autoApprovePairing": False,
    "diagnosticOnly": True,
    "hostExecutableSHA256": executable_digest,
    "hostPID": bounded_positive(host_pid_raw, "host PID", 2**31 - 1),
    "hostPersistentIdentityMutationDenied": True,
    "identityAccessPolicy": "existing-only",
    "keychainMode": "system",
    "launchMode": "packaged-lab",
    "mode": "current-source-signed-packaged-host",
    "forcedPersistentTrustMutationAllowed": False,
    "pqcReportFile": pqc_raw,
    "remoteControlNoticeAutoApprove": False,
    "remotePort": bounded_positive(remote_port_raw, "remote port", 65535),
    "runnerPID": bounded_positive(runner_pid_raw, "runner PID", 2**31 - 1),
    "schemaVersion": 1,
    "sourceInputDigest": source_digest,
    "statusFile": status_raw,
    "controlPort": bounded_positive(control_port_raw, "control port", 65535),
}

descriptor, temporary_raw = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
temporary = pathlib.Path(temporary_raw)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, output)
    os.chmod(output, 0o600)
    directory_descriptor = os.open(output.parent, os.O_RDONLY)
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)
finally:
    if temporary.exists():
        temporary.unlink()

metadata = os.lstat(output)
if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600:
    raise SystemExit("macOS host-only readiness permissions are not exactly 0600")
PY
}

validate_mac_host_only_pqc_report() {
  python3 - "$HOST_PQC_REPORT" <<'PY'
import base64
import json
import os
import stat
import sys

path = sys.argv[1]
metadata = os.lstat(path)
if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
    raise SystemExit("macOS host-only PQC report is not a private regular file")
if metadata.st_size < 2 or metadata.st_size > 1024 * 1024:
    raise SystemExit("macOS host-only PQC report size is outside the bounded contract")
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
device_id = payload.get("deviceId")
if not isinstance(device_id, str) or not device_id.strip():
    raise SystemExit("macOS host-only PQC report is missing its existing device identity")
keys = payload.get("keys")
if not isinstance(keys, list):
    raise SystemExit("macOS host-only PQC report keys are malformed")
xwing_entries = [entry for entry in keys if isinstance(entry, dict) and entry.get("suiteWireId") == 0x0001]
if len(xwing_entries) != 1:
    raise SystemExit("macOS host-only PQC report must contain exactly one existing X-Wing identity")
encoded = xwing_entries[0].get("publicKeyBase64")
if not isinstance(encoded, str) or not encoded:
    raise SystemExit("macOS host-only X-Wing identity is empty")
try:
    decoded = base64.b64decode(encoded, validate=True)
except (ValueError, TypeError) as error:
    raise SystemExit("macOS host-only X-Wing identity is not valid base64") from error
if not decoded:
    raise SystemExit("macOS host-only X-Wing identity decoded to empty bytes")
PY
}

wait_for_mac_host_only_shutdown() {
  local ownership_status
  append_host_status "mac-host-only ready=1 diagnosticOnly=1 currentSourceHelper=1 hostPersistentIdentityMutationDenied=1 acceptanceEligible=0"
  echo "==> Signed current-source macOS host is ready (diagnostic-only): $MAC_HOST_READY_FILE"
  while true; do
    if skybridge_mac_owned_process_status \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$HOST_PID" \
      "$MAC_HOST_PROCESS_IDENTITY"; then
      sleep 0.5
      continue
    fi
    ownership_status=$?
    if (( ownership_status == 1 )); then
      append_host_status "failed stage=mac-host phase=host-only-lifecycle reason=host-exited-before-runner-shutdown"
      echo "Signed macOS host exited before the host-only runner was asked to stop." >&2
    else
      append_host_status "failed stage=mac-host phase=host-only-lifecycle reason=exact-process-ownership-unverifiable"
      echo "Signed macOS host ownership became unverifiable before runner shutdown." >&2
    fi
    return 1
  done
}

reset_smoke_artifacts() {
  local runtime_host_executable="$MAC_ONLINE_RUNTIME_DIR/LocalLanInteropHost.app/Contents/MacOS/LocalLanInteropHost"
  local runtime_online_executable="$MAC_ONLINE_RUNTIME_APP_BUNDLE/Contents/MacOS/SkyBridgeCompassApp"
  local canonical_product_executable="$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/MacOS/SkyBridgeCompassApp"
  local executable_path
  local process_label

  while IFS='|' read -r executable_path process_label; do
    [[ -x "$executable_path" ]] || continue
    if ! skybridge_mac_require_executable_absent \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$executable_path" \
      "$process_label"; then
      echo "Refusing to reset smoke artifacts while a prior exact runtime executable remains active." >&2
      return 1
    fi
  done <<EOF
$MAC_DIRECT_BIN|macOS direct P2P smoke host
$MAC_SOURCE_DIRECT_BIN|macOS P2P smoke source
$runtime_host_executable|macOS packaged P2P smoke host
$runtime_online_executable|macOS online iPad client
$canonical_product_executable|canonical macOS product
EOF

  # Rust smoke profiles intentionally reuse stable artifact dirs for follow-up checks.
  # Clear per-run evidence so waits cannot match a stale ready/notice line.
  rm -f -- \
    "$HOST_STATUS" \
    "$HOST_PQC_REPORT" \
    "$HOST_STDOUT" \
    "$HOST_STATUS_ARTIFACT" \
    "$HOST_PQC_REPORT_ARTIFACT" \
    "$HOST_STDOUT_ARTIFACT" \
    "$MAC_HOST_READY_FILE" \
    "$MAC_SOURCE_STDOUT" \
    "$ARTIFACT_DIR/mac-control-port-probe.stderr.log" \
    "$ARTIFACT_DIR/mac-remote-port-probe.stderr.log" \
    "$IOS_PQC_REPORT" \
    "$IOS_STATUS_LOCAL" \
    "$IOS_STATUS_CONSOLE_LIVE" \
    "$IOS_STATUS_APP_CACHE_LOCAL" \
    "$IOS_STATUS_CONSOLE_SNAPSHOT" \
    "$IOS_TRACE_LOCAL" \
    "$IOS_LISTENER_STATUS_LOCAL" \
    "$IOS_CONSOLE_STDERR" \
    "$LAUNCH_RESULT_JSON" \
    "$IOS_PROCESS_LIST_JSON" \
    "$IOS_PROCESS_LIST_LOG" \
    "$IOS_PROCESS_LIST_STDERR" \
    "$MAC_ONLINE_STATUS_ARTIFACT" \
    "$MAC_ONLINE_STATUS" \
    "$MAC_ONLINE_STDOUT" \
    "$MAC_ONLINE_STDERR" \
    "$MAC_ONLINE_APP_STDOUT" \
    "$MAC_ONLINE_APP_STDERR" \
    "$MAC_ONLINE_OPEN_STDERR" \
    "$MAC_ONLINE_BUILD_LOG" \
    "$P2P_APPROVAL_PROOF" \
    "$DEVICE_INFO_TXT" \
    "$MAC_ONLINE_LAUNCH_STDOUT" \
    "$MAC_ONLINE_LAUNCH_STDERR" \
    "$MAC_ONLINE_LAUNCH_OPEN_STDERR"

  rm -f -- \
    "$ARTIFACT_DIR"/ios-p2p-remote-*.status.log \
    "$ARTIFACT_DIR"/ios-p2p-remote-*.app-cache.status.log \
    "$ARTIFACT_DIR"/ios-p2p-remote-*.console-live.status.log \
    "$ARTIFACT_DIR"/ios-p2p-remote-*.console.status.log \
    "$ARTIFACT_DIR"/ios-copy-*.json \
    "$ARTIFACT_DIR"/ios-copy-*.log \
    "$ARTIFACT_DIR"/ios-copy-*.stdout.log \
    "$ARTIFACT_DIR"/ios-copy-*.stderr.log

  rm -rf -- "$MAC_ONLINE_RUNTIME_DIR"
  /bin/mkdir -m 700 "$MAC_ONLINE_RUNTIME_DIR"
}

require_no_concurrent_smoke_scripts() {
  local pid
  local pids
  pids="$(pgrep -f 'Scripts/run_real_device_p2p_remote_smoke\.sh' 2>/dev/null | sort -u || true)"

  [[ -n "$pids" ]] || return 0

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ "$pid" == "$$" || "$pid" == "${BASHPID:-$$}" || "$pid" == "$PPID" ]] && continue
    echo "Refusing to start while another real-device P2P smoke script may be active: pid=$pid" >&2
    return 1
  done <<<"$pids"
}

validate_macos_smoke_host_product_entitlements() {
  local entitlements_path="$1"
  local label="$2"

  python3 - "$entitlements_path" "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER" "$MAC_HOST_PRODUCT_BUNDLE_ID" "$label" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
team_identifier = sys.argv[2].strip()
bundle_identifier = sys.argv[3].strip()
label = sys.argv[4]

try:
    with path.open("rb") as handle:
        entitlements = plistlib.load(handle)
except Exception as error:
    print(f"Unable to decode {label} entitlements: {error}", file=sys.stderr)
    raise SystemExit(1)

expected_application_identifier = f"{team_identifier}.{bundle_identifier}"
actual_application_identifier = entitlements.get("com.apple.application-identifier")
if actual_application_identifier != expected_application_identifier:
    print(
        f"{label} application identifier mismatch: "
        f"expected={expected_application_identifier} actual={actual_application_identifier}",
        file=sys.stderr,
    )
    raise SystemExit(1)

keychain_groups = entitlements.get("keychain-access-groups")
if not isinstance(keychain_groups, list):
    print(f"{label} is missing keychain-access-groups", file=sys.stderr)
    raise SystemExit(1)
normalized_groups = {
    str(value).strip()
    for value in keychain_groups
    if isinstance(value, str) and value.strip()
}
if expected_application_identifier not in normalized_groups:
    print(
        f"{label} keychain-access-groups does not include the product application identifier",
        file=sys.stderr,
    )
    raise SystemExit(1)

if "com.apple.security.get-task-allow" in entitlements:
    print(f"{label} unexpectedly contains get-task-allow", file=sys.stderr)
    raise SystemExit(1)
PY
}

derive_macos_smoke_host_minimal_entitlements() {
  python3 - \
    "$MAC_HOST_PRODUCT_ENTITLEMENTS" \
    "$MAC_HOST_HELPER_ENTITLEMENTS" \
    "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER" \
    "$MAC_HOST_PRODUCT_BUNDLE_ID" <<'PY'
import plistlib
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
team_identifier = sys.argv[3].strip()
bundle_identifier = sys.argv[4].strip()
expected_application_identifier = f"{team_identifier}.{bundle_identifier}"

with source_path.open("rb") as source_file:
    source = plistlib.load(source_file)

if source.get("com.apple.application-identifier") != expected_application_identifier:
    print("Product entitlements cannot provide the expected application identifier", file=sys.stderr)
    raise SystemExit(1)

source_groups = source.get("keychain-access-groups")
if not isinstance(source_groups, list):
    print("Product entitlements cannot provide keychain-access-groups", file=sys.stderr)
    raise SystemExit(1)
normalized_source_groups = [
    value.strip()
    for value in source_groups
    if isinstance(value, str) and value.strip()
]
expected_shared_group = f"{team_identifier}.group.com.skybridge.compass"
required_groups = {expected_application_identifier, expected_shared_group}
if not required_groups.issubset(set(normalized_source_groups)):
    print("Product entitlements do not contain both required product/shared Keychain groups", file=sys.stderr)
    raise SystemExit(1)
groups = [value for value in normalized_source_groups if value in required_groups]
if len(groups) != 2 or set(groups) != required_groups:
    print("Product entitlements contain duplicate required Keychain groups", file=sys.stderr)
    raise SystemExit(1)

for capability in (
    "com.apple.security.network.client",
    "com.apple.security.network.server",
):
    if source.get(capability) is not True:
        print(f"Product entitlements do not enable required capability: {capability}", file=sys.stderr)
        raise SystemExit(1)

minimal = {
    "com.apple.application-identifier": expected_application_identifier,
    "keychain-access-groups": groups,
    "com.apple.security.network.client": True,
    "com.apple.security.network.server": True,
}
product_team = source.get("com.apple.developer.team-identifier")
if product_team is not None:
    if product_team != team_identifier:
        print("Product team entitlement does not match the verified signing team", file=sys.stderr)
        raise SystemExit(1)
    minimal["com.apple.developer.team-identifier"] = product_team

output_path.write_bytes(plistlib.dumps(minimal, fmt=plistlib.FMT_XML, sort_keys=False))
PY
}

validate_macos_smoke_host_minimal_entitlements() {
  local entitlements_path="$1"
  local label="$2"

  python3 - "$entitlements_path" "$label" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
label = sys.argv[2]
with path.open("rb") as handle:
    entitlements = plistlib.load(handle)

allowed = {
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
    "keychain-access-groups",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
}
required = allowed - {"com.apple.developer.team-identifier"}
keys = set(entitlements)
unknown = keys - allowed
missing = required - keys
if unknown or missing:
    print(
        f"{label} entitlement allow-list mismatch: "
        f"unknown={sorted(unknown)} missing={sorted(missing)}",
        file=sys.stderr,
    )
    raise SystemExit(1)
for capability in (
    "com.apple.security.network.client",
    "com.apple.security.network.server",
):
    if entitlements.get(capability) is not True:
        print(f"{label} does not enable required capability: {capability}", file=sys.stderr)
        raise SystemExit(1)
PY
}

validate_macos_product_widget_entitlements() {
  local widget_entitlements_path="$1"
  local label="$2"

  python3 - \
    "$widget_entitlements_path" \
    "$MAC_HOST_PRODUCT_ENTITLEMENTS" \
    "$label" <<'PY'
import plistlib
import sys
from pathlib import Path

widget_path = Path(sys.argv[1])
app_path = Path(sys.argv[2])
label = sys.argv[3]

with widget_path.open("rb") as widget_file:
    widget = plistlib.load(widget_file)
with app_path.open("rb") as app_file:
    app = plistlib.load(app_file)

allowed_keys = {
    "com.apple.security.app-sandbox",
    "com.apple.security.application-groups",
}
if set(widget) != allowed_keys:
    print(
        f"{label} entitlement allow-list mismatch: "
        f"actual={sorted(widget)} expected={sorted(allowed_keys)}",
        file=sys.stderr,
    )
    raise SystemExit(1)
if widget.get("com.apple.security.app-sandbox") is not True:
    print(f"{label} does not enable the App Sandbox", file=sys.stderr)
    raise SystemExit(1)

expected_groups = {"group.com.skybridge.compass"}
widget_groups = {
    value.strip()
    for value in widget.get("com.apple.security.application-groups", [])
    if isinstance(value, str) and value.strip()
}
app_groups = {
    value.strip()
    for value in app.get("com.apple.security.application-groups", [])
    if isinstance(value, str) and value.strip()
}
if widget_groups != expected_groups or app_groups != expected_groups:
    print(
        f"{label} App Group does not exactly match the packaged product App Group",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

verify_macos_smoke_host_product_signing_context() {
  local product_info_plist="$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/Info.plist"
  local product_widget_info_plist="$MAC_HOST_PRODUCT_WIDGET_BUNDLE/Contents/Info.plist"
  local product_executable_name
  local product_executable
  local product_bundle_identifier
  local product_metadata
  local product_signed_identifier
  local product_authority
  local product_identity_hash
  local product_cdhash
  local product_executable_sha256
  local product_profile_sha256
  local product_widget_executable_name
  local product_widget_executable
  local product_widget_bundle_identifier
  local product_widget_metadata
  local product_widget_signed_identifier
  local product_widget_team_identifier
  local product_widget_authority
  local product_widget_identity_hash
  local product_widget_cdhash
  local product_widget_executable_sha256
  local product_widget_profile_sha256

  case "$MAC_HOST_LAUNCH_MODE" in
    packaged) ;;
    packaged-lab)
      if [[ "$LAB_RUN" != "1" ]]; then
        echo "packaged-lab signing verification requires an explicit lab run." >&2
        return 1
      fi
      ;;
    *)
      echo "Product signing context cannot be used by macOS host mode: $MAC_HOST_LAUNCH_MODE" >&2
      return 1
      ;;
  esac

  if [[ ! -d "$MAC_HOST_PRODUCT_APP_BUNDLE" ]]; then
    echo "Packaged macOS product app is required for acceptance host signing: $MAC_HOST_PRODUCT_APP_BUNDLE" >&2
    return 1
  fi
  if [[ -L "$MAC_HOST_PRODUCT_APP_BUNDLE" || \
        "$MAC_HOST_PRODUCT_APP_BUNDLE" != "$ROOT_DIR/dist/SkyBridge Compass Pro.app" ]]; then
    echo "Acceptance host signing requires the non-symlink canonical dist product app." >&2
    return 1
  fi
  if [[ ! -f "$product_info_plist" ]]; then
    echo "Packaged macOS product Info.plist is missing: $product_info_plist" >&2
    return 1
  fi
  if [[ ! -f "$MAC_HOST_PRODUCT_PROFILE" || -L "$MAC_HOST_PRODUCT_PROFILE" ]]; then
    echo "Packaged macOS product embedded provisioning profile is required: $MAC_HOST_PRODUCT_PROFILE" >&2
    return 1
  fi
  if [[ ! -d "$MAC_HOST_PRODUCT_WIDGET_BUNDLE" || -L "$MAC_HOST_PRODUCT_WIDGET_BUNDLE" ]]; then
    echo "Packaged macOS product Widget extension is missing or symlinked: $MAC_HOST_PRODUCT_WIDGET_BUNDLE" >&2
    return 1
  fi
  if [[ ! -f "$product_widget_info_plist" || -L "$product_widget_info_plist" ]]; then
    echo "Packaged macOS product Widget Info.plist is missing or symlinked: $product_widget_info_plist" >&2
    return 1
  fi
  if [[ ! -f "$MAC_HOST_PRODUCT_WIDGET_PROFILE" || -L "$MAC_HOST_PRODUCT_WIDGET_PROFILE" ]]; then
    echo "Packaged macOS product Widget provisioning profile is missing or symlinked: $MAC_HOST_PRODUCT_WIDGET_PROFILE" >&2
    return 1
  fi
  if [[ ! -x /usr/libexec/PlistBuddy ]]; then
    echo "PlistBuddy is unavailable; cannot verify the packaged macOS product identity." >&2
    return 1
  fi

  product_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$product_info_plist" 2>/dev/null || true)"
  if [[ "$product_bundle_identifier" != "$MAC_HOST_PRODUCT_BUNDLE_ID" ]]; then
    echo "Packaged macOS product bundle identifier mismatch: expected=$MAC_HOST_PRODUCT_BUNDLE_ID actual=${product_bundle_identifier:-missing}" >&2
    return 1
  fi
  product_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$product_info_plist" 2>/dev/null || true)"
  product_executable="$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/MacOS/$product_executable_name"
  if [[ -z "$product_executable_name" || ! -x "$product_executable" ]]; then
    echo "Packaged macOS product executable is missing or not executable: $product_executable" >&2
    return 1
  fi
  product_widget_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$product_widget_info_plist" 2>/dev/null || true)"
  if [[ "$product_widget_bundle_identifier" != "$MAC_HOST_PRODUCT_WIDGET_BUNDLE_ID" ]]; then
    echo "Packaged macOS product Widget bundle identifier mismatch: expected=$MAC_HOST_PRODUCT_WIDGET_BUNDLE_ID actual=${product_widget_bundle_identifier:-missing}" >&2
    return 1
  fi
  product_widget_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$product_widget_info_plist" 2>/dev/null || true)"
  product_widget_executable="$MAC_HOST_PRODUCT_WIDGET_BUNDLE/Contents/MacOS/$product_widget_executable_name"
  if [[ -z "$product_widget_executable_name" || ! -x "$product_widget_executable" ]]; then
    echo "Packaged macOS product Widget executable is missing or not executable: $product_widget_executable" >&2
    return 1
  fi

  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$MAC_HOST_PRODUCT_APP_BUNDLE" >/dev/null; then
    echo "Packaged macOS product signature verification failed: $MAC_HOST_PRODUCT_APP_BUNDLE" >&2
    return 1
  fi
  if ! /usr/bin/codesign --verify --strict --verbose=2 "$MAC_HOST_PRODUCT_WIDGET_BUNDLE" >/dev/null; then
    echo "Packaged macOS product Widget signature verification failed: $MAC_HOST_PRODUCT_WIDGET_BUNDLE" >&2
    return 1
  fi
  if [[ "$MAC_HOST_LAUNCH_MODE" == "packaged" ]]; then
    if ! /usr/bin/xcrun stapler validate "$MAC_HOST_PRODUCT_APP_BUNDLE" >/dev/null; then
      echo "Packaged macOS product does not have a valid stapled notarization ticket." >&2
      return 1
    fi
    MAC_HOST_IDENTITY_SOURCE_STAPLER_VALID=1
    if ! /usr/sbin/spctl --assess --type execute "$MAC_HOST_PRODUCT_APP_BUNDLE" >/dev/null; then
      echo "Packaged macOS product failed Gatekeeper assessment." >&2
      return 1
    fi
    MAC_HOST_IDENTITY_SOURCE_GATEKEEPER_ACCEPTED=1
  else
    MAC_HOST_IDENTITY_SOURCE_STAPLER_VALID=0
    MAC_HOST_IDENTITY_SOURCE_GATEKEEPER_ACCEPTED=0
  fi
  if ! product_metadata="$(/usr/bin/codesign --display --verbose=4 "$MAC_HOST_PRODUCT_APP_BUNDLE" 2>&1)"; then
    echo "Unable to read the packaged macOS product signature metadata." >&2
    return 1
  fi

  product_signed_identifier="$(printf '%s\n' "$product_metadata" | sed -n 's/^Identifier=//p' | head -n 1)"
  MAC_HOST_PRODUCT_TEAM_IDENTIFIER="$(printf '%s\n' "$product_metadata" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  product_authority="$(printf '%s\n' "$product_metadata" | sed -n 's/^Authority=//p' | head -n 1)"
  product_cdhash="$(printf '%s\n' "$product_metadata" | sed -n 's/^CDHash=//p' | head -n 1)"
  if [[ "$product_signed_identifier" != "$MAC_HOST_PRODUCT_BUNDLE_ID" ]]; then
    echo "Packaged macOS product signed identifier mismatch: expected=$MAC_HOST_PRODUCT_BUNDLE_ID actual=${product_signed_identifier:-missing}" >&2
    return 1
  fi
  if [[ -z "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER" || "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER" == "not set" ]]; then
    echo "Packaged macOS product signature does not contain a TeamIdentifier." >&2
    return 1
  fi
  if [[ "$product_authority" != Developer\ ID\ Application:* ]]; then
    echo "Packaged macOS product is not signed with a Developer ID Application identity." >&2
    return 1
  fi
  if [[ "$product_authority" != *"($MAC_HOST_PRODUCT_TEAM_IDENTIFIER)"* ]]; then
    echo "Packaged macOS product signing authority does not match its TeamIdentifier." >&2
    return 1
  fi
  if ! product_widget_metadata="$(/usr/bin/codesign --display --verbose=4 "$MAC_HOST_PRODUCT_WIDGET_BUNDLE" 2>&1)"; then
    echo "Unable to read the packaged macOS product Widget signature metadata." >&2
    return 1
  fi
  product_widget_signed_identifier="$(printf '%s\n' "$product_widget_metadata" | sed -n 's/^Identifier=//p' | head -n 1)"
  product_widget_team_identifier="$(printf '%s\n' "$product_widget_metadata" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  product_widget_authority="$(printf '%s\n' "$product_widget_metadata" | sed -n 's/^Authority=//p' | head -n 1)"
  product_widget_cdhash="$(printf '%s\n' "$product_widget_metadata" | sed -n 's/^CDHash=//p' | head -n 1)"
  if [[ "$product_widget_signed_identifier" != "$MAC_HOST_PRODUCT_WIDGET_BUNDLE_ID" ]]; then
    echo "Packaged macOS product Widget signed identifier mismatch: expected=$MAC_HOST_PRODUCT_WIDGET_BUNDLE_ID actual=${product_widget_signed_identifier:-missing}" >&2
    return 1
  fi
  if [[ "$product_widget_team_identifier" != "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER" ]]; then
    echo "Packaged macOS product Widget TeamIdentifier does not match the host app." >&2
    return 1
  fi
  if [[ "$product_widget_authority" != "$product_authority" ]]; then
    echo "Packaged macOS product Widget signing authority does not exactly match the host app authority." >&2
    return 1
  fi

  mkdir -p "$MAC_HOST_SIGNING_DIR"
  if ! skybridge_write_signed_entitlements "$MAC_HOST_PRODUCT_APP_BUNDLE" "$MAC_HOST_PRODUCT_ENTITLEMENTS"; then
    echo "Unable to extract signed entitlements from the packaged macOS product app." >&2
    return 1
  fi
  if ! validate_macos_smoke_host_product_entitlements "$MAC_HOST_PRODUCT_ENTITLEMENTS" "packaged product"; then
    return 1
  fi
  if ! skybridge_write_signed_entitlements \
    "$MAC_HOST_PRODUCT_WIDGET_BUNDLE" \
    "$MAC_HOST_PRODUCT_WIDGET_ENTITLEMENTS"; then
    echo "Unable to extract signed entitlements from the packaged macOS product Widget." >&2
    return 1
  fi
  if ! validate_macos_product_widget_entitlements \
    "$MAC_HOST_PRODUCT_WIDGET_ENTITLEMENTS" \
    "packaged product Widget"; then
    return 1
  fi
  if ! derive_macos_smoke_host_minimal_entitlements; then
    echo "Unable to derive least-privilege smoke host entitlements from the packaged product signature." >&2
    return 1
  fi
  if ! validate_macos_smoke_host_product_entitlements "$MAC_HOST_HELPER_ENTITLEMENTS" "derived smoke host"; then
    return 1
  fi
  if ! validate_macos_smoke_host_minimal_entitlements "$MAC_HOST_HELPER_ENTITLEMENTS" "derived smoke host"; then
    return 1
  fi
  if ! skybridge_validate_provisionprofile_app_identity \
    "$MAC_HOST_PRODUCT_PROFILE" \
    "$MAC_HOST_PRODUCT_BUNDLE_ID" \
    "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER"; then
    echo "Packaged macOS product profile does not match the signed bundle/team identity." >&2
    return 1
  fi
  if ! skybridge_profile_supports_requested_profile_backed_entitlements \
    "$MAC_HOST_PRODUCT_PROFILE" \
    "$MAC_HOST_PRODUCT_ENTITLEMENTS"; then
    echo "Packaged macOS product profile does not cover its signed profile-backed entitlements." >&2
    return 1
  fi
  if ! skybridge_profile_supports_requested_profile_backed_entitlements \
    "$MAC_HOST_PRODUCT_PROFILE" \
    "$MAC_HOST_HELPER_ENTITLEMENTS"; then
    echo "Packaged macOS product profile does not cover the derived helper profile-backed entitlements." >&2
    return 1
  fi
  if ! skybridge_validate_provisionprofile_app_identity \
    "$MAC_HOST_PRODUCT_WIDGET_PROFILE" \
    "$MAC_HOST_PRODUCT_WIDGET_BUNDLE_ID" \
    "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER"; then
    echo "Packaged macOS product Widget profile does not match the signed bundle/team identity." >&2
    return 1
  fi
  if ! skybridge_profile_supports_requested_profile_backed_entitlements \
    "$MAC_HOST_PRODUCT_WIDGET_PROFILE" \
    "$MAC_HOST_PRODUCT_WIDGET_ENTITLEMENTS"; then
    echo "Packaged macOS product Widget profile does not cover its exact signed entitlements." >&2
    return 1
  fi

  if ! product_identity_hash="$(
    skybridge_resolve_profile_bound_codesign_identity_hash \
      "$MAC_HOST_PRODUCT_PROFILE" \
      "$product_authority"
  )"; then
    echo "Unable to resolve a unique profile-bound local identity for packaged-product signing." >&2
    return 1
  fi
  if ! product_widget_identity_hash="$(
    skybridge_resolve_profile_bound_codesign_identity_hash \
      "$MAC_HOST_PRODUCT_WIDGET_PROFILE" \
      "$product_widget_authority"
  )"; then
    echo "Unable to resolve a unique profile-bound local identity for packaged-product Widget signing." >&2
    return 1
  fi
  if [[ "$product_identity_hash" != "$product_widget_identity_hash" ]]; then
    echo "Packaged app and Widget profiles do not bind to the same unique local Developer ID identity." >&2
    return 1
  fi
  MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH="$product_identity_hash"
  MAC_HOST_PRODUCT_AUTHORITY="$product_authority"

  product_executable_sha256="$(shasum -a 256 "$product_executable" | awk '{print $1}')"
  product_widget_executable_sha256="$(shasum -a 256 "$product_widget_executable" | awk '{print $1}')"
  product_profile_sha256="$(shasum -a 256 "$MAC_HOST_PRODUCT_PROFILE" | awk '{print $1}')"
  product_widget_profile_sha256="$(shasum -a 256 "$MAC_HOST_PRODUCT_WIDGET_PROFILE" | awk '{print $1}')"
  if [[ ! "$product_cdhash" =~ ^[0-9a-fA-F]{40,64}$ || \
        ! "$product_widget_cdhash" =~ ^[0-9a-fA-F]{40,64}$ || \
        ! "$product_executable_sha256" =~ ^[0-9a-f]{64}$ || \
        ! "$product_widget_executable_sha256" =~ ^[0-9a-f]{64}$ || \
        ! "$product_profile_sha256" =~ ^[0-9a-f]{64}$ || \
        ! "$product_widget_profile_sha256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Packaged-product signing context hashes are missing or malformed." >&2
    return 1
  fi
  MAC_HOST_PRODUCT_CDHASH="$(printf '%s' "$product_cdhash" | tr '[:upper:]' '[:lower:]')"
  MAC_HOST_PRODUCT_WIDGET_CDHASH="$(printf '%s' "$product_widget_cdhash" | tr '[:upper:]' '[:lower:]')"
  MAC_HOST_PRODUCT_EXECUTABLE_SHA256="$product_executable_sha256"
  MAC_HOST_PRODUCT_WIDGET_EXECUTABLE_SHA256="$product_widget_executable_sha256"
  MAC_HOST_PRODUCT_PROFILE_SHA256="$product_profile_sha256"
  MAC_HOST_PRODUCT_WIDGET_PROFILE_SHA256="$product_widget_profile_sha256"

  append_host_status "mac-host-product-signing-context source=packaged-product mode=$MAC_HOST_LAUNCH_MODE signature=developer-id bundleIdentifier=product team=matched appProfile=developer-id-current widgetProfile=developer-id-current certificate=profile-bound-shared entitlements=app-widget-exact keychainIdentity=unique stapler=$([[ "$MAC_HOST_IDENTITY_SOURCE_STAPLER_VALID" == "1" ]] && echo valid || echo skipped) spctl=$([[ "$MAC_HOST_IDENTITY_SOURCE_GATEKEEPER_ACCEPTED" == "1" ]] && echo accepted || echo skipped) diagnosticOnly=$([[ "$MAC_HOST_LAUNCH_MODE" == "packaged-lab" ]] && echo 1 || echo 0)"
}

verify_macos_smoke_host_identity_source_unchanged() {
  local product_info_plist="$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/Info.plist"
  local widget_info_plist="$MAC_HOST_PRODUCT_WIDGET_BUNDLE/Contents/Info.plist"
  local product_executable_name
  local widget_executable_name
  local product_executable
  local widget_executable
  local product_metadata
  local widget_metadata
  local product_cdhash
  local widget_cdhash
  local product_executable_sha256
  local widget_executable_sha256
  local product_profile_sha256
  local widget_profile_sha256

  case "$MAC_HOST_LAUNCH_MODE" in
    packaged) ;;
    packaged-lab)
      [[ "$LAB_RUN" == "1" ]] || {
        echo "packaged-lab identity freshness verification requires an explicit lab run." >&2
        return 1
      }
      ;;
    *)
      echo "Product identity freshness verification reached invalid mode: $MAC_HOST_LAUNCH_MODE" >&2
      return 1
      ;;
  esac

  if [[ -L "$MAC_HOST_PRODUCT_APP_BUNDLE" || \
        -L "$MAC_HOST_PRODUCT_PROFILE" || \
        -L "$MAC_HOST_PRODUCT_WIDGET_BUNDLE" || \
        -L "$MAC_HOST_PRODUCT_WIDGET_PROFILE" ]]; then
    echo "Packaged-product identity source became symlinked after verification." >&2
    return 1
  fi
  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$MAC_HOST_PRODUCT_APP_BUNDLE" >/dev/null || \
     ! /usr/bin/codesign --verify --strict --verbose=2 "$MAC_HOST_PRODUCT_WIDGET_BUNDLE" >/dev/null; then
    echo "Packaged-product identity source signature changed after verification." >&2
    return 1
  fi

  product_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$product_info_plist" 2>/dev/null || true)"
  widget_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$widget_info_plist" 2>/dev/null || true)"
  product_executable="$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/MacOS/$product_executable_name"
  widget_executable="$MAC_HOST_PRODUCT_WIDGET_BUNDLE/Contents/MacOS/$widget_executable_name"
  if [[ ! -x "$product_executable" || ! -x "$widget_executable" || \
        ! -f "$MAC_HOST_PRODUCT_PROFILE" || ! -f "$MAC_HOST_PRODUCT_WIDGET_PROFILE" ]]; then
    echo "Packaged-product identity source files disappeared after verification." >&2
    return 1
  fi

  product_metadata="$(/usr/bin/codesign --display --verbose=4 "$MAC_HOST_PRODUCT_APP_BUNDLE" 2>&1)" || return 1
  widget_metadata="$(/usr/bin/codesign --display --verbose=4 "$MAC_HOST_PRODUCT_WIDGET_BUNDLE" 2>&1)" || return 1
  product_cdhash="$(printf '%s\n' "$product_metadata" | sed -n 's/^CDHash=//p' | head -n 1 | tr '[:upper:]' '[:lower:]')"
  widget_cdhash="$(printf '%s\n' "$widget_metadata" | sed -n 's/^CDHash=//p' | head -n 1 | tr '[:upper:]' '[:lower:]')"
  product_executable_sha256="$(shasum -a 256 "$product_executable" | awk '{print $1}')"
  widget_executable_sha256="$(shasum -a 256 "$widget_executable" | awk '{print $1}')"
  product_profile_sha256="$(shasum -a 256 "$MAC_HOST_PRODUCT_PROFILE" | awk '{print $1}')"
  widget_profile_sha256="$(shasum -a 256 "$MAC_HOST_PRODUCT_WIDGET_PROFILE" | awk '{print $1}')"

  if [[ "$product_cdhash" != "$MAC_HOST_PRODUCT_CDHASH" || \
        "$widget_cdhash" != "$MAC_HOST_PRODUCT_WIDGET_CDHASH" || \
        "$product_executable_sha256" != "$MAC_HOST_PRODUCT_EXECUTABLE_SHA256" || \
        "$widget_executable_sha256" != "$MAC_HOST_PRODUCT_WIDGET_EXECUTABLE_SHA256" || \
        "$product_profile_sha256" != "$MAC_HOST_PRODUCT_PROFILE_SHA256" || \
        "$widget_profile_sha256" != "$MAC_HOST_PRODUCT_WIDGET_PROFILE_SHA256" ]]; then
    echo "Packaged-product identity source changed between verification and helper signing." >&2
    return 1
  fi
}

prepare_macos_smoke_host_app_bundle() {
  local source_bin="$MAC_DIRECT_BIN"
  local source_webrtc_framework="$SMOKE_BUILD_DIR/debug/WebRTC.framework"
  local source_core_resource_bundle="$SMOKE_BUILD_DIR/debug/SkyBridgeCompassApp_SkyBridgeCore.bundle"
  local contents_dir="$MAC_APP_BUNDLE/Contents"
  local macos_dir="$contents_dir/MacOS"
  local resources_dir="$contents_dir/Resources"
  local embedded_core_resource_bundle="$resources_dir/SkyBridgeCompassApp_SkyBridgeCore.bundle"
  local embedded_core_resource_contents="$embedded_core_resource_bundle/Contents"
  local embedded_core_resource_root="$embedded_core_resource_contents/Resources"
  local plist_path="$contents_dir/Info.plist"
  local embedded_profile="$contents_dir/embedded.provisionprofile"
  local scratch_root_dir
  local scratch_debug_dir
  local source_resource_dir
  local source_resource_root
  local source_resource_layout
  local source_resource_status
  local helper_metadata
  local helper_identifier
  local helper_team_identifier
  local helper_authority
  local embedded_profile_sha256

  case "$MAC_HOST_LAUNCH_MODE" in
    packaged) ;;
    packaged-lab)
      [[ "$LAB_RUN" == "1" ]] || {
        echo "packaged-lab helper preparation requires an explicit lab run." >&2
        exit 1
      }
      ;;
    *)
      echo "Signed helper preparation reached invalid mode: $MAC_HOST_LAUNCH_MODE" >&2
      exit 1
      ;;
  esac
  verify_macos_smoke_host_identity_source_unchanged || exit 1

  if [[ ! -x "$source_bin" ]]; then
    echo "macOS LAN host executable not found: $source_bin" >&2
    exit 1
  fi
  if [[ ! -d "$source_webrtc_framework" ]]; then
    echo "WebRTC framework not found beside the SwiftPM build product: $source_webrtc_framework" >&2
    exit 1
  fi
  if [[ ! -d "$SMOKE_BUILD_DIR" || ! -d "$SMOKE_BUILD_DIR/debug" ]]; then
    echo "Dedicated SwiftPM smoke scratch directory is missing: $SMOKE_BUILD_DIR" >&2
    exit 1
  fi
  if [[ ! -d "$source_core_resource_bundle" || -L "$source_core_resource_bundle" ]]; then
    echo "SkyBridgeCore resource bundle is missing or symlinked in the dedicated smoke scratch: $source_core_resource_bundle" >&2
    exit 1
  fi
  scratch_root_dir="$(cd "$SMOKE_BUILD_DIR" && pwd -P)"
  scratch_debug_dir="$(cd "$SMOKE_BUILD_DIR/debug" && pwd -P)"
  source_resource_dir="$(cd "$source_core_resource_bundle" && pwd -P)"
  if [[ "$scratch_debug_dir" != "$scratch_root_dir/"* ]]; then
    echo "SwiftPM debug product directory resolves outside the dedicated smoke scratch." >&2
    exit 1
  fi
  if [[ "$source_resource_dir" != "$scratch_debug_dir/SkyBridgeCompassApp_SkyBridgeCore.bundle" ]]; then
    echo "SkyBridgeCore resource bundle did not resolve directly inside the dedicated smoke scratch." >&2
    exit 1
  fi
  if [[ ! -x /usr/libexec/PlistBuddy ]]; then
    echo "PlistBuddy is unavailable; cannot build the temporary macOS smoke host app bundle." >&2
    exit 1
  fi
  if [[ ! "$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH" =~ ^[0-9A-F]{40}$ || \
        -z "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER" || \
        -z "$MAC_HOST_PRODUCT_AUTHORITY" ]]; then
    echo "Packaged macOS product signing context was not verified before preparing the smoke host." >&2
    exit 1
  fi
  if [[ ! -s "$MAC_HOST_HELPER_ENTITLEMENTS" || ! -f "$MAC_HOST_PRODUCT_PROFILE" ]]; then
    echo "Verified packaged-product entitlements/profile are unavailable for smoke host signing." >&2
    exit 1
  fi

  rm -rf "$MAC_APP_BUNDLE"
  mkdir -p "$macos_dir" "$resources_dir"
  if source_resource_layout="$(skybridge_copy_normalized_core_resource_bundle \
    "$source_core_resource_bundle" \
    "$embedded_core_resource_bundle")"; then
    :
  else
    source_resource_status=$?
    exit "$source_resource_status"
  fi
  case "$source_resource_layout" in
    swiftpm-flat)
      source_resource_root="$source_core_resource_bundle"
      ;;
    swiftpm-macos-contents)
      source_resource_root="$source_core_resource_bundle/Contents/Resources"
      ;;
    *)
      echo "SkyBridgeCore resource normalizer returned an unknown layout token." >&2
      exit 1
      ;;
  esac
  if ! validate_remote_control_security_notice_localizations \
    "$source_resource_root" \
    "source-$source_resource_layout"; then
    exit 1
  fi
  if ! validate_remote_control_security_notice_localizations \
    "$embedded_core_resource_root" \
    "pre-sign"; then
    exit 1
  fi
  cp "$source_bin" "$macos_dir/LocalLanInteropHost"
  cp -R "$source_webrtc_framework" "$macos_dir/WebRTC.framework"
  cp "$MAC_HOST_PRODUCT_PROFILE" "$embedded_profile"
  chmod +x "$macos_dir/LocalLanInteropHost"
  embedded_profile_sha256="$(shasum -a 256 "$embedded_profile" | awk '{print $1}')"
  if [[ "$embedded_profile_sha256" != "$MAC_HOST_PRODUCT_PROFILE_SHA256" ]]; then
    echo "Copied smoke-host profile does not match the verified identity-source profile hash." >&2
    exit 1
  fi

  /usr/libexec/PlistBuddy \
    -c 'Clear dict' \
    -c 'Add :CFBundleExecutable string LocalLanInteropHost' \
    -c "Add :CFBundleIdentifier string $MAC_HOST_PRODUCT_BUNDLE_ID" \
    -c 'Add :CFBundleName string LocalLanInteropHostSmoke' \
    -c 'Add :CFBundlePackageType string APPL' \
    -c 'Add :CFBundleVersion string 1' \
    -c 'Add :CFBundleShortVersionString string 1.0' \
    -c 'Add :NSPrincipalClass string NSApplication' \
    -c 'Add :NSLocalNetworkUsageDescription string SkyBridge Compass uses the local network to discover and connect to nearby devices for secure P2P remote control.' \
    -c 'Add :NSBonjourServices array' \
    -c 'Add :NSBonjourServices:0 string _skybridge._tcp' \
    -c 'Add :NSBonjourServices:1 string _skybridge._udp' \
    -c 'Add :NSBonjourServices:2 string _skybridge-xfer._tcp' \
    -c 'Add :NSBonjourServices:3 string _skybridge-rd._tcp' \
    "$plist_path" >/dev/null
  /usr/bin/codesign --force --timestamp=none --options runtime --sign "$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH" "$macos_dir/WebRTC.framework" >/dev/null
  /usr/bin/codesign \
    --force \
    --timestamp=none \
    --options runtime \
    --sign "$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH" \
    --entitlements "$MAC_HOST_HELPER_ENTITLEMENTS" \
    "$MAC_APP_BUNDLE" >/dev/null
  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$MAC_APP_BUNDLE" >/dev/null; then
    echo "Product-identity smoke host signature verification failed: $MAC_APP_BUNDLE" >&2
    exit 1
  fi
  if ! validate_remote_control_security_notice_localizations \
    "$embedded_core_resource_root" \
    "post-sign"; then
    exit 1
  fi
  if ! helper_metadata="$(/usr/bin/codesign --display --verbose=4 "$MAC_APP_BUNDLE" 2>&1)"; then
    echo "Unable to read the signed smoke host metadata." >&2
    exit 1
  fi
  helper_identifier="$(printf '%s\n' "$helper_metadata" | sed -n 's/^Identifier=//p' | head -n 1)"
  helper_team_identifier="$(printf '%s\n' "$helper_metadata" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  helper_authority="$(printf '%s\n' "$helper_metadata" | sed -n 's/^Authority=//p' | head -n 1)"
  if [[ "$helper_identifier" != "$MAC_HOST_PRODUCT_BUNDLE_ID" || \
        "$helper_team_identifier" != "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER" || \
        "$helper_authority" != "$MAC_HOST_PRODUCT_AUTHORITY" ]]; then
    echo "Signed smoke host identity does not exactly match the verified packaged-product identity." >&2
    exit 1
  fi
  if ! cmp -s "$MAC_HOST_PRODUCT_PROFILE" "$embedded_profile"; then
    echo "Signed smoke host embedded profile differs from the verified packaged-product profile." >&2
    exit 1
  fi
  embedded_profile_sha256="$(shasum -a 256 "$embedded_profile" | awk '{print $1}')"
  if [[ "$embedded_profile_sha256" != "$MAC_HOST_PRODUCT_PROFILE_SHA256" ]]; then
    echo "Signed smoke-host profile hash differs from the verified identity-source profile." >&2
    exit 1
  fi
  if ! skybridge_write_signed_entitlements "$MAC_APP_BUNDLE" "$MAC_HOST_SIGNED_ENTITLEMENTS"; then
    echo "Unable to extract the signed smoke host entitlements." >&2
    exit 1
  fi
  if ! validate_macos_smoke_host_product_entitlements "$MAC_HOST_SIGNED_ENTITLEMENTS" "signed smoke host"; then
    exit 1
  fi
  if ! validate_macos_smoke_host_minimal_entitlements "$MAC_HOST_SIGNED_ENTITLEMENTS" "signed smoke host"; then
    exit 1
  fi
  if ! python3 - "$MAC_HOST_HELPER_ENTITLEMENTS" "$MAC_HOST_SIGNED_ENTITLEMENTS" <<'PY'
import plistlib
import sys
from pathlib import Path

with Path(sys.argv[1]).open("rb") as expected_file:
    expected = plistlib.load(expected_file)
with Path(sys.argv[2]).open("rb") as actual_file:
    actual = plistlib.load(actual_file)
if actual != expected:
    print("Signed smoke host entitlements differ from the derived least-privilege entitlements", file=sys.stderr)
    raise SystemExit(1)
PY
  then
    exit 1
  fi
  if ! verify_macos_smoke_host_identity_source_unchanged; then
    echo "Packaged-product identity source changed while the helper was being signed." >&2
    exit 1
  fi
  clear_runtime_bundle_quarantine_if_present "$MAC_APP_BUNDLE" "product-identity smoke host"
  MAC_APP_BIN="$macos_dir/LocalLanInteropHost"
  register_macos_smoke_host_app_bundle
  append_host_status "mac-host-signing source=packaged-product mode=$MAC_HOST_LAUNCH_MODE signature=developer-id bundleIdentifier=product team=matched profile=verified entitlements=exact keychainAccess=product resourceBundle=SkyBridgeCompassApp_SkyBridgeCore.bundle resourceBundleLayout=normalized-contents-resources resourceBundleSource=dedicated-swiftpm-scratch resourceBundleSourceLayout=$source_resource_layout resourceBundleSealed=1 identitySourceStaplerValid=$MAC_HOST_IDENTITY_SOURCE_STAPLER_VALID identitySourceGatekeeperAccepted=$MAC_HOST_IDENTITY_SOURCE_GATEKEEPER_ACCEPTED diagnosticOnly=$([[ "$MAC_HOST_LAUNCH_MODE" == "packaged-lab" ]] && echo 1 || echo 0)"
}

register_launch_services_app_bundle() {
  local app_bundle="$1"
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ ! -x "$lsregister" ]]; then
    echo "LaunchServices registration tool is unavailable: $lsregister" >&2
    return 1
  fi
  if ! "$lsregister" -f "$app_bundle" >/dev/null 2>&1; then
    echo "LaunchServices registration failed for app bundle: $app_bundle" >&2
    return 1
  fi
}

unregister_launch_services_app_bundle() {
  local app_bundle="$1"
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ ! -x "$lsregister" ]]; then
    echo "LaunchServices registration tool is unavailable; cannot unregister helper bundle." >&2
    return 1
  fi
  if ! "$lsregister" -u "$app_bundle" >/dev/null 2>&1; then
    echo "LaunchServices unregistration failed for helper app bundle: $app_bundle" >&2
    return 1
  fi
}

verify_launch_services_paths_state() {
  local expected_state="$1"
  shift
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  local dump_path="$MAC_HOST_SIGNING_DIR/launch-services.dump"

  if [[ "$expected_state" != "present" && "$expected_state" != "absent" ]]; then
    echo "Unsupported LaunchServices path state: $expected_state" >&2
    return 2
  fi
  if (( $# == 0 )); then
    echo "LaunchServices path-state verification requires at least one exact path." >&2
    return 2
  fi
  if [[ ! -x "$lsregister" ]]; then
    echo "LaunchServices registration tool is unavailable for registration-state verification." >&2
    return 2
  fi
  mkdir -p "$MAC_HOST_SIGNING_DIR"
  if ! "$lsregister" -dump >"$dump_path"; then
    echo "LaunchServices registration database could not be read." >&2
    return 2
  fi
  python3 - "$dump_path" "$expected_state" "$@" <<'PY'
import sys
from pathlib import Path

dump_path = Path(sys.argv[1])
expected_state = sys.argv[2]
targets = sys.argv[3:]
content = dump_path.read_text(encoding="utf-8", errors="strict")
for target in targets:
    plain_record = f"path:                       {target} ("
    quoted_record = f'Path = "{target}";'
    is_present = plain_record in content or quoted_record in content
    if (expected_state == "present") != is_present:
        raise SystemExit(1)
raise SystemExit(0)
PY
}

verify_launch_services_runtime_paths_absent() {
  local runtime_app="$1"
  local runtime_widget="$runtime_app/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex"

  if ! verify_launch_services_paths_state absent "$runtime_app" "$runtime_widget"; then
    echo "LaunchServices still contains a stale runtime app or Widget path after unregister." >&2
    return 1
  fi
}

cleanup_macos_smoke_host_launch_services_registration() {
  local restore_status=0
  local helper_terminated=1
  local helper_unregistered=0

  if [[ "${MAC_HOST_HELPER_REGISTERED:-0}" != "1" ]]; then
    return 0
  fi
  if [[ -z "${MAC_ONLINE_RUNTIME_DIR:-}" || \
        "$MAC_APP_BUNDLE" != "$MAC_ONLINE_RUNTIME_DIR/"* || \
        "$MAC_APP_BUNDLE" == "$MAC_ONLINE_RUNTIME_DIR" ]]; then
    echo "Refusing unsafe helper cleanup path: ${MAC_APP_BUNDLE:-missing}" >&2
    return 1
  fi
  local remaining_helper_pids=""
  if ! remaining_helper_pids="$(skybridge_mac_exact_executable_pids \
    "$PROCESS_OWNERSHIP_HELPER" "$MAC_APP_BIN")" \
    || [[ -n "$remaining_helper_pids" ]]; then
    restore_status=1
    helper_terminated=0
  fi
  if [[ "$helper_terminated" != "1" ]]; then
    echo "Refusing to unregister or delete a product-identity helper while a process may still be alive." >&2
  elif [[ ! -d "$MAC_APP_BUNDLE" ]]; then
    echo "Registered product-identity helper disappeared before LaunchServices cleanup: $MAC_APP_BUNDLE" >&2
    restore_status=1
  else
    if unregister_launch_services_app_bundle "$MAC_APP_BUNDLE" && \
       verify_launch_services_runtime_paths_absent "$MAC_APP_BUNDLE"; then
      helper_unregistered=1
    else
      restore_status=1
    fi
    if [[ "$helper_unregistered" == "1" ]]; then
      rm -rf -- "$MAC_APP_BUNDLE"
    fi
  fi
  if [[ "$helper_terminated" == "1" && "$helper_unregistered" == "1" && ! -d "$MAC_APP_BUNDLE" ]]; then
    MAC_HOST_HELPER_REGISTERED=0
  fi
  return "$restore_status"
}

restore_canonical_macos_launch_services_registration_last() {
  local canonical_widget="$MAC_HOST_PRODUCT_WIDGET_BUNDLE"
  local runtime_online_widget="$MAC_ONLINE_RUNTIME_APP_BUNDLE/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex"
  local runtime_helper_widget="$MAC_APP_BUNDLE/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex"

  if [[ ! -d "$MAC_HOST_PRODUCT_APP_BUNDLE" || -L "$MAC_HOST_PRODUCT_APP_BUNDLE" ]]; then
    echo "Canonical packaged macOS product app is unavailable for final LaunchServices restoration." >&2
    return 1
  fi
  if [[ ! -d "$canonical_widget" || -L "$canonical_widget" ]]; then
    echo "Canonical packaged macOS product Widget is unavailable for final LaunchServices restoration." >&2
    return 1
  fi
  if ! register_launch_services_app_bundle "$MAC_HOST_PRODUCT_APP_BUNDLE"; then
    echo "Failed to restore the canonical packaged macOS product as the final LaunchServices registration." >&2
    return 1
  fi
  if ! verify_launch_services_paths_state \
    present \
    "$MAC_HOST_PRODUCT_APP_BUNDLE"; then
    echo "Canonical packaged macOS product app path is absent after final LaunchServices registration." >&2
    return 1
  fi
  if ! verify_launch_services_paths_state \
    absent \
    "$MAC_ONLINE_RUNTIME_APP_BUNDLE" \
    "$runtime_online_widget" \
    "$MAC_APP_BUNDLE" \
    "$runtime_helper_widget"; then
    echo "LaunchServices retains a runtime app or Widget path after canonical parent restoration." >&2
    return 1
  fi
  MAC_LAUNCH_SERVICES_RESTORE_REQUIRED=0
}

clear_runtime_bundle_quarantine_if_present() {
  local app_bundle="$1"
  local label="$2"
  local attributes

  if [[ ! -d "$app_bundle" ]]; then
    echo "Cannot inspect quarantine state for missing $label: $app_bundle" >&2
    return 1
  fi
  if ! attributes="$(/usr/bin/xattr -r "$app_bundle" 2>&1)"; then
    echo "Unable to inspect quarantine attributes for $label." >&2
    return 1
  fi
  if printf '%s\n' "$attributes" | grep -Fq 'com.apple.quarantine'; then
    if ! /usr/bin/xattr -dr com.apple.quarantine "$app_bundle"; then
      echo "Unable to remove quarantine from runtime-only $label." >&2
      return 1
    fi
  fi
}

register_macos_smoke_host_app_bundle() {
  local canonical_product_executable="$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/MacOS/SkyBridgeCompassApp"
  if ! skybridge_mac_require_executable_absent \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$MAC_APP_BIN" \
    "packaged macOS P2P smoke host"; then
    return 1
  fi
  if [[ "$canonical_product_executable" != "$MAC_APP_BIN" ]] \
    && ! skybridge_mac_require_executable_absent \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$canonical_product_executable" \
      "canonical macOS product sharing the P2P host bundle identity"; then
    return 1
  fi
  register_launch_services_app_bundle "$MAC_APP_BUNDLE" || return 1
  MAC_HOST_HELPER_REGISTERED=1
  MAC_LAUNCH_SERVICES_RESTORE_REQUIRED=1
}

open_macos_smoke_host_app_bundle() {
  /usr/bin/open \
    --stdout "$HOST_STDOUT" \
    --stderr "$HOST_STDOUT" \
    --env "SKYBRIDGE_KEYCHAIN_IN_MEMORY=$KEYCHAIN_IN_MEMORY" \
    --env "SB_PQC_PREFERRED_SUITE=$HOST_PREFERRED_SUITE" \
    --env "SKYBRIDGE_SMOKE_ROLE=mac-host" \
    --env "SKYBRIDGE_SMOKE_IDENTITY_AUDIT_ONLY=$IDENTITY_AUDIT_ONLY" \
    --env "SKYBRIDGE_SMOKE_IDENTITY_EXISTING_ONLY=$MAC_HOST_ONLY" \
    --env "SKYBRIDGE_SMOKE_STATUS_FILE=$HOST_STATUS" \
    --env "SKYBRIDGE_SMOKE_PQC_REPORT_FILE=$HOST_PQC_REPORT" \
    --env "SKYBRIDGE_SMOKE_ALLOW_PERSISTENT_TRUST_MUTATION=$ALLOW_PERSISTENT_TRUST_MUTATION" \
    --env "SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING=${SKYBRIDGE_SMOKE_AUTO_APPROVE_PAIRING:-0}" \
    --env "SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE=${SKYBRIDGE_REMOTE_CONTROL_NOTICE_AUTO_APPROVE:-0}" \
    --env "SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE=$EXPECTED_TARGET_SUITE" \
    --env "SKYBRIDGE_SMOKE_REQUIRE_EMBEDDED_CORE_RESOURCES=1" \
    --env "SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE=${SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE:-0}" \
    --env "SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME=${SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME:-}" \
    --env "SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID=${SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID:-}" \
    "$MAC_APP_BUNDLE"
}

start_macos_smoke_host_directly() {
  if [[ "$LAB_RUN" != "1" ]]; then
    append_host_status "failed stage=mac-host phase=launch reason=direct-mode-requires-lab-run"
    echo "Direct SwiftPM host launch is diagnostic-only and requires SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1." >&2
    return 2
  fi
  if ! skybridge_mac_require_executable_absent \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$MAC_DIRECT_BIN" \
    "macOS direct P2P smoke host"; then
    return 1
  fi
  SKYBRIDGE_KEYCHAIN_IN_MEMORY="$KEYCHAIN_IN_MEMORY" \
  SB_PQC_PREFERRED_SUITE="$HOST_PREFERRED_SUITE" \
  SKYBRIDGE_SMOKE_ROLE=mac-host \
  SKYBRIDGE_SMOKE_IDENTITY_EXISTING_ONLY=0 \
  SKYBRIDGE_SMOKE_STATUS_FILE="$HOST_STATUS" \
  SKYBRIDGE_SMOKE_PQC_REPORT_FILE="$HOST_PQC_REPORT" \
  SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE="$EXPECTED_TARGET_SUITE" \
  SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE="${SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE:-0}" \
  SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME="${SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME:-}" \
  SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID="${SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID:-}" \
  "$MAC_DIRECT_BIN" >"$HOST_STDOUT" 2>&1 &
  HOST_PID="$!"
  skybridge_mac_capture_owned_process \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$HOST_PID" \
    "$MAC_DIRECT_BIN" \
    "$MAC_HOST_PROCESS_IDENTITY" \
    "macOS direct P2P smoke host"
}

start_macos_smoke_source_host() {
  : >"$MAC_SOURCE_STDOUT"
  if [[ ! -x "$MAC_SOURCE_DIRECT_BIN" ]]; then
    append_host_status "failed stage=mac-smoke-source phase=launch reason=missing-helper binary=$MAC_SOURCE_DIRECT_BIN"
    echo "macOS smoke source helper executable not found: $MAC_SOURCE_DIRECT_BIN" >&2
    return 1
  fi
  if ! skybridge_mac_require_executable_absent \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$MAC_SOURCE_DIRECT_BIN" \
    "macOS P2P smoke source"; then
    return 1
  fi

  SKYBRIDGE_SMOKE_STATUS_FILE="$HOST_STATUS" \
  SKYBRIDGE_SMOKE_ROLE=mac-smoke-source \
  "$MAC_SOURCE_DIRECT_BIN" >"$MAC_SOURCE_STDOUT" 2>&1 &
  MAC_SOURCE_PID="$!"
  if ! skybridge_mac_capture_owned_process \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$MAC_SOURCE_PID" \
    "$MAC_SOURCE_DIRECT_BIN" \
    "$MAC_SOURCE_PROCESS_IDENTITY" \
    "macOS P2P smoke source"; then
    return 1
  fi
  append_host_status "launch method=direct-app-binary pid=$MAC_SOURCE_PID role=mac-smoke-source binary=swiftpm-build-product"
}

validate_identity_audit_output() {
  python3 - "$HOST_STDOUT" <<'PY'
import json
import os
import stat
import sys

path = sys.argv[1]
metadata = os.lstat(path)
if not stat.S_ISREG(metadata.st_mode):
    raise SystemExit("Identity audit output is not a regular file")
if metadata.st_mode & 0o077:
    raise SystemExit("Identity audit output permissions are too broad")
if metadata.st_size <= 0 or metadata.st_size > 64 * 1024:
    raise SystemExit("Identity audit output size is outside the bounded contract")

with open(path, "r", encoding="utf-8") as handle:
    lines = [line.strip() for line in handle if line.strip()]
if len(lines) != 1:
    raise SystemExit("Identity audit output must contain exactly one JSON record")
payload = json.loads(lines[0])

expected_top_level = {
    "authorityKeyValidated",
    "authorityPresent",
    "comparisonBasis",
    "inspectionStatus",
    "namespaces",
    "schemaVersion",
    "stableAcrossReads",
    "state",
}
if set(payload) != expected_top_level:
    raise SystemExit("Identity audit output has an unexpected top-level field")
if payload.get("schemaVersion") != 2:
    raise SystemExit("Identity audit output is not schema v2")
authority_present = payload.get("authorityPresent")
authority_validated = payload.get("authorityKeyValidated")
comparison_basis = payload.get("comparisonBasis")
if not isinstance(authority_present, bool) or not isinstance(authority_validated, bool):
    raise SystemExit("Identity audit authority state is not boolean")
inspection = payload.get("inspectionStatus")
if not isinstance(inspection, dict) or inspection.get("schemaVersion") != 1:
    raise SystemExit("Identity audit inspection status is invalid")
inspection_complete = inspection.get("inspectionComplete")
if not isinstance(inspection_complete, bool):
    raise SystemExit("Identity audit inspection completeness is not boolean")
if not inspection_complete:
    expected_inspection_fields = {
        "schemaVersion",
        "inspectionComplete",
        "failureReason",
    }
    allowed_failure_reasons = {
        "access-denied",
        "keychain-unavailable",
        "malformed-attributes",
        "malformed-key-info",
        "invalid-device-id",
        "candidate-limit-exceeded",
        "key-material-unavailable",
        "changed-during-read",
    }
    if set(inspection) != expected_inspection_fields:
        raise SystemExit("Unavailable identity audit inspection has unexpected fields")
    if inspection.get("failureReason") not in allowed_failure_reasons:
        raise SystemExit("Unavailable identity audit inspection has an invalid reason")
    if (
        authority_present is not True
        or authority_validated is not True
        or comparison_basis != "shared-authority"
        or payload.get("state") != "inspection-unavailable"
        or payload.get("stableAcrossReads") is not False
        or payload.get("namespaces") != []
    ):
        raise SystemExit("Unavailable identity audit is not bound to a validated authority")
    print(lines[0])
    raise SystemExit(0)

if set(inspection) != {"schemaVersion", "inspectionComplete", "hasConflicts"}:
    raise SystemExit("Complete identity audit inspection has unexpected fields")
if not isinstance(inspection.get("hasConflicts"), bool):
    raise SystemExit("Complete identity audit conflict state is not boolean")
if payload.get("stableAcrossReads") is not True:
    raise SystemExit("Complete identity audit is not a stable snapshot")
if authority_present:
    if authority_validated is not True or comparison_basis != "shared-authority":
        raise SystemExit("Identity audit did not bind its comparison to the validated authority")
    allowed_states = {
        "authority-clean",
        "matching-legacy-remnants",
        "conflicting-legacy-remnants",
    }
else:
    if authority_validated is not False or comparison_basis not in {
        "none",
        "first-validated-legacy-key-info",
    }:
        raise SystemExit("Identity audit returned an invalid authority-absent comparison basis")
    allowed_states = {
        "no-identity",
        "legacy-migration-incomplete",
        "legacy-migration-conflict",
        "legacy-migration-requires-rotation",
        "legacy-committed-tuple-selected",
    }
if payload.get("state") not in allowed_states:
    raise SystemExit("Identity audit state is inconsistent with authority presence")

expected_namespaces = [
    "shared-data-protection",
    "other-data-protection",
    "legacy-file-keychain",
]
expected_dimensions = [
    "key-info-device-id",
    "key-info-public-key",
    "key-info-fingerprint",
    "key-info-created-at",
    "key-info-secure-enclave",
    "private-key-public-key",
    "private-key-secure-enclave",
    "device-id",
]
namespaces = payload.get("namespaces")
if not isinstance(namespaces, list) or [item.get("namespace") for item in namespaces] != expected_namespaces:
    raise SystemExit("Identity audit namespace order is invalid")

def validate_count(value):
    if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 64:
        raise SystemExit("Identity audit count is outside the bounded contract")

for namespace in namespaces:
    if set(namespace) != {"namespace", "privateKeys", "keyInfos", "deviceIds", "mismatches"}:
        raise SystemExit("Identity audit namespace has an unexpected field")
    for key in ("privateKeys", "keyInfos", "deviceIds"):
        counts = namespace.get(key)
        if not isinstance(counts, dict) or set(counts) != {"matching", "conflicting", "unresolved"}:
            raise SystemExit("Identity audit value count has an unexpected field")
        for value in counts.values():
            validate_count(value)
    mismatches = namespace.get("mismatches")
    if not isinstance(mismatches, list) or [item.get("dimension") for item in mismatches] != expected_dimensions:
        raise SystemExit("Identity audit mismatch dimension order is invalid")
    for mismatch in mismatches:
        if set(mismatch) != {"dimension", "count"}:
            raise SystemExit("Identity audit mismatch has an unexpected field")
        validate_count(mismatch["count"])

print(lines[0])
PY
}

start_macos_smoke_host() {
  : >"$HOST_STDOUT"

  case "$MAC_HOST_LAUNCH_MODE" in
    direct)
      start_macos_smoke_host_directly
      return $?
      ;;
    packaged) ;;
    packaged-lab)
      if [[ "$LAB_RUN" != "1" ]]; then
        append_host_status "failed stage=mac-host phase=launch reason=packaged-lab-without-lab-run"
        return 1
      fi
      ;;
    *)
      append_host_status "failed stage=mac-host phase=launch reason=invalid-launch-mode"
      return 1
      ;;
  esac

  if ! skybridge_mac_require_executable_absent \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$MAC_APP_BIN" \
    "packaged macOS P2P smoke host"; then
    return 1
  fi
  local canonical_product_executable="$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/MacOS/SkyBridgeCompassApp"
  if [[ "$canonical_product_executable" != "$MAC_APP_BIN" ]] \
    && ! skybridge_mac_require_executable_absent \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$canonical_product_executable" \
      "canonical macOS product sharing the P2P host bundle identity"; then
    return 1
  fi

  local open_status
  if open_macos_smoke_host_app_bundle; then
    open_status=0
  else
    open_status=$?
    append_host_status "failed stage=mac-host phase=launch reason=packaged-product-open-failed status=$open_status"
    echo "LaunchServices failed to open the product-identity smoke host (status=$open_status)." >&2
    return "$open_status"
  fi

  if ! skybridge_mac_wait_for_single_exact_process \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$MAC_APP_BIN" \
    15 \
    HOST_PID \
    "packaged macOS P2P smoke host"; then
    append_host_status "failed stage=mac-host phase=launch reason=packaged-product-app-pid-not-found"
    echo "Timed out waiting for the product-identity LocalLanInteropHost app pid after LaunchServices start." >&2
    print_smoke_tail_for_operator 80 "$HOST_STDOUT"
    return 1
  fi
  if ! skybridge_mac_capture_owned_process \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$HOST_PID" \
    "$MAC_APP_BIN" \
    "$MAC_HOST_PROCESS_IDENTITY" \
    "packaged macOS P2P smoke host"; then
    append_host_status "failed stage=mac-host phase=launch reason=packaged-product-process-ownership-unverifiable"
    return 1
  fi

  if [[ "$IDENTITY_AUDIT_ONLY" == "1" ]]; then
    local audit_started_at
    audit_started_at="$(date +%s)"
    while true; do
      if [[ -s "$HOST_STDOUT" ]] \
        && grep -Fq '"schemaVersion":2' "$HOST_STDOUT"; then
        validate_identity_audit_output
        return 0
      fi
      if (( "$(date +%s)" - audit_started_at >= IDENTITY_AUDIT_TIMEOUT_SECONDS )); then
        echo "Timed out waiting for the signed read-only identity audit." >&2
        print_smoke_tail_for_operator 20 "$HOST_STDOUT"
        return 1
      fi
      sleep 0.25
    done
  fi

  return 0
}

record_macos_smoke_host_launch_evidence() {
  local ownership_status
  if [[ -z "$HOST_PID" ]]; then
    append_host_status "failed stage=mac-host phase=launch-evidence reason=host-pid-not-running"
    echo "macOS smoke host exited before launch evidence could be bound to its reset status file." >&2
    return 1
  fi
  if skybridge_mac_owned_process_status \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$HOST_PID" \
    "$MAC_HOST_PROCESS_IDENTITY"; then
    ownership_status=0
  else
    ownership_status=$?
  fi
  if (( ownership_status != 0 )); then
    append_host_status "failed stage=mac-host phase=launch-evidence reason=host-process-ownership-unverifiable"
    echo "macOS smoke host exact process ownership was lost before launch evidence was recorded." >&2
    return 1
  fi

  case "$MAC_HOST_LAUNCH_MODE" in
    direct)
      append_host_status "launch method=direct-app-binary pid=$HOST_PID mode=direct binary=swiftpm-build-product"
      ;;
    packaged)
      append_host_status "launch method=packaged-product-app-bundle pid=$HOST_PID mode=packaged identity=verified signature=developer-id profile=developer-id-current certificate=profile-bound entitlements=least-privilege keychainAccess=product stapler=valid spctl=accepted diagnosticOnly=0"
      ;;
    packaged-lab)
      append_host_status "launch method=signed-lab-app-bundle pid=$HOST_PID mode=packaged-lab identity=verified signature=developer-id profile=developer-id-current certificate=profile-bound entitlements=least-privilege keychainAccess=product stapler=skipped spctl=skipped diagnosticOnly=1"
      ;;
    *)
      append_host_status "failed stage=mac-host phase=launch-evidence reason=invalid-launch-mode"
      return 1
      ;;
  esac
}

append_ios_status() {
  printf '%s %s\n' "$(timestamp_utc)" "$*" >>"$IOS_STATUS_CONSOLE_LIVE"
}

print_smoke_tail_for_operator() {
  local lines="$1"
  local path="$2"
  skybridge_smoke_tail_redacted "$IOS_DEVICE_LABEL" "$lines" "$path" "$IOS_DEVICE_ID" >&2 || true
}

redacted_last_log_line() {
  local path="$1"
  skybridge_smoke_tail_redacted "$IOS_DEVICE_LABEL" 1 "$path" "$IOS_DEVICE_ID" | tr '[:space:]' '_' || true
}

macos_online_ipad_rpaths() {
  local binary="$1"
  /usr/bin/otool -l "$binary" | awk '
    /cmd LC_RPATH/ { in_rpath = 1; next }
    in_rpath && /^[[:space:]]*path / {
      sub(/^[[:space:]]*path /, "")
      sub(/ \(offset [0-9]+\)$/, "")
      print
      in_rpath = 0
    }
  '
}

remove_macos_online_ipad_debug_signature_before_binary_mutation() {
  if ! /usr/bin/codesign --display "$MAC_ONLINE_APP_BIN" >/dev/null 2>&1; then
    echo "The Xcode-built macOS online iPad executable is unexpectedly unsigned before rpath normalization." >&2
    return 1
  fi
  if ! /usr/bin/codesign --remove-signature "$MAC_ONLINE_APP_BIN" >/dev/null; then
    echo "Unable to remove the transient Xcode signature before mutating macOS online iPad rpaths." >&2
    return 1
  fi
  if /usr/bin/codesign --display "$MAC_ONLINE_APP_BIN" >/dev/null 2>&1; then
    echo "The macOS online iPad executable remained signed after explicit pre-mutation signature removal." >&2
    return 1
  fi
}

normalize_macos_online_ipad_debug_rpaths() {
  local rpath
  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    case "$rpath" in
      */Build/Products/*/PackageFrameworks|*/PackageFrameworks)
        /usr/bin/install_name_tool -delete_rpath "$rpath" "$MAC_ONLINE_APP_BIN"
        ;;
    esac
  done < <(macos_online_ipad_rpaths "$MAC_ONLINE_APP_BIN")

  if ! macos_online_ipad_rpaths "$MAC_ONLINE_APP_BIN" | grep -Fxq '@executable_path/../Frameworks'; then
    /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$MAC_ONLINE_APP_BIN"
  fi
}

normalize_macos_online_ipad_debug_frameworks() {
  if [[ ! -d "$MAC_ONLINE_APP_BUNDLE/Contents/Frameworks" ]]; then
    return 0
  fi

  while IFS= read -r -d '' framework; do
    skybridge_normalize_versioned_framework_layout "$framework"
  done < <(find "$MAC_ONLINE_APP_BUNDLE/Contents/Frameworks" -type d -name '*.framework' -prune -print0)
}

validate_macos_online_ipad_debug_bundle_identity() {
  local app_info_plist="$MAC_ONLINE_APP_BUNDLE/Contents/Info.plist"
  local widget_bundle="$MAC_ONLINE_APP_BUNDLE/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex"
  local widget_info_plist="$widget_bundle/Contents/Info.plist"
  local app_bundle_identifier
  local widget_bundle_identifier
  local nested_code_bundles

  if [[ "$MAC_ONLINE_APP_BUNDLE" != "$MAC_ONLINE_RUNTIME_APP_BUNDLE" || \
        ! -d "$MAC_ONLINE_APP_BUNDLE" || -L "$MAC_ONLINE_APP_BUNDLE" ]]; then
    echo "The macOS online iPad Debug app must be the non-symlink private runtime bundle." >&2
    return 1
  fi
  if [[ ! "$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH" =~ ^[0-9A-F]{40}$ || \
        -z "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER" || \
        "$MAC_HOST_PRODUCT_AUTHORITY" != Developer\ ID\ Application:* ]]; then
    echo "The verified canonical product Developer ID signing context is unavailable for the Debug app." >&2
    return 1
  fi
  for required_file in \
    "$MAC_HOST_PRODUCT_PROFILE" \
    "$MAC_HOST_PRODUCT_WIDGET_PROFILE" \
    "$MAC_HOST_PRODUCT_ENTITLEMENTS" \
    "$MAC_HOST_PRODUCT_WIDGET_ENTITLEMENTS" \
    "$app_info_plist" \
    "$widget_info_plist"; do
    if [[ ! -f "$required_file" || -L "$required_file" ]]; then
      echo "Required canonical product signing input is missing or symlinked: $required_file" >&2
      return 1
    fi
  done
  if [[ ! -d "$widget_bundle" || -L "$widget_bundle" ]]; then
    echo "The macOS online iPad Debug app is missing the regular product Widget extension." >&2
    return 1
  fi
  nested_code_bundles="$(
    find "$MAC_ONLINE_APP_BUNDLE/Contents" -type d \
      \( -name '*.appex' -o -name '*.xpc' -o -name '*.app' \) \
      -prune -print
  )"
  if [[ "$nested_code_bundles" != "$widget_bundle" ]]; then
    echo "The macOS online iPad Debug app contains an unexpected nested code bundle." >&2
    return 1
  fi

  app_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_info_plist" 2>/dev/null || true)"
  widget_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$widget_info_plist" 2>/dev/null || true)"
  if [[ "$app_bundle_identifier" != "$MAC_HOST_PRODUCT_BUNDLE_ID" || \
        "$widget_bundle_identifier" != "$MAC_HOST_PRODUCT_WIDGET_BUNDLE_ID" ]]; then
    echo "The Debug app/Widget bundle identifiers do not exactly match the canonical product identities." >&2
    return 1
  fi

  cp "$MAC_HOST_PRODUCT_PROFILE" "$MAC_ONLINE_APP_BUNDLE/Contents/embedded.provisionprofile"
  cp "$MAC_HOST_PRODUCT_WIDGET_PROFILE" "$widget_bundle/Contents/embedded.provisionprofile"
  if ! cmp -s \
    "$MAC_HOST_PRODUCT_PROFILE" \
    "$MAC_ONLINE_APP_BUNDLE/Contents/embedded.provisionprofile"; then
    echo "The Debug app did not retain the exact canonical product profile bytes." >&2
    return 1
  fi
  if ! cmp -s \
    "$MAC_HOST_PRODUCT_WIDGET_PROFILE" \
    "$widget_bundle/Contents/embedded.provisionprofile"; then
    echo "The Debug Widget did not retain the exact canonical product profile bytes." >&2
    return 1
  fi
  if ! skybridge_validate_provisionprofile_app_identity \
    "$MAC_ONLINE_APP_BUNDLE/Contents/embedded.provisionprofile" \
    "$MAC_HOST_PRODUCT_BUNDLE_ID" \
    "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER"; then
    echo "The embedded Debug app profile does not match the product bundle/team identity." >&2
    return 1
  fi
  if ! skybridge_validate_provisionprofile_app_identity \
    "$widget_bundle/Contents/embedded.provisionprofile" \
    "$MAC_HOST_PRODUCT_WIDGET_BUNDLE_ID" \
    "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER"; then
    echo "The embedded Debug Widget profile does not match the product bundle/team identity." >&2
    return 1
  fi
  if ! skybridge_profile_supports_requested_profile_backed_entitlements \
    "$MAC_ONLINE_APP_BUNDLE/Contents/embedded.provisionprofile" \
    "$MAC_HOST_PRODUCT_ENTITLEMENTS"; then
    echo "The embedded Debug app profile does not cover the exact product entitlements." >&2
    return 1
  fi
  if ! skybridge_profile_supports_requested_profile_backed_entitlements \
    "$widget_bundle/Contents/embedded.provisionprofile" \
    "$MAC_HOST_PRODUCT_WIDGET_ENTITLEMENTS"; then
    echo "The embedded Debug Widget profile does not cover the exact product entitlements." >&2
    return 1
  fi
}

sign_macos_online_ipad_debug_frameworks() {
  local framework_root
  local binary
  local framework

  for framework_root in \
    "$MAC_ONLINE_APP_BUNDLE/Contents/Frameworks" \
    "$MAC_ONLINE_APP_BUNDLE/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex/Contents/Frameworks"; do
    [[ -d "$framework_root" ]] || continue
    while IFS= read -r -d '' binary; do
      if /usr/bin/file -b "$binary" | grep -Fq 'Mach-O'; then
        /usr/bin/codesign \
          --force \
          --timestamp=none \
          --options runtime \
          --sign "$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH" \
          "$binary" >/dev/null
      fi
    done < <(find "$framework_root" -type f -print0)
    while IFS= read -r -d '' framework; do
      /usr/bin/codesign \
        --force \
        --timestamp=none \
        --options runtime \
        --sign "$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH" \
        "$framework" >/dev/null
    done < <(find "$framework_root" -depth -type d -name '*.framework' -print0)
  done
}

verify_macos_online_ipad_signed_identity() {
  local target="$1"
  local expected_identifier="$2"
  local label="$3"
  local metadata
  local identifier
  local team_identifier
  local authority

  if ! /usr/bin/codesign --verify --strict --verbose=2 "$target" >/dev/null; then
    echo "$label strict signature verification failed: $target" >&2
    return 1
  fi
  if ! metadata="$(/usr/bin/codesign --display --verbose=4 "$target" 2>&1)"; then
    echo "Unable to read $label signature metadata." >&2
    return 1
  fi
  identifier="$(printf '%s\n' "$metadata" | sed -n 's/^Identifier=//p' | head -n 1)"
  team_identifier="$(printf '%s\n' "$metadata" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  authority="$(printf '%s\n' "$metadata" | sed -n 's/^Authority=//p' | head -n 1)"
  if [[ "$identifier" != "$expected_identifier" || \
        "$team_identifier" != "$MAC_HOST_PRODUCT_TEAM_IDENTIFIER" || \
        "$authority" != "$MAC_HOST_PRODUCT_AUTHORITY" ]]; then
    echo "$label signed identity does not exactly match the canonical product Developer ID identity." >&2
    return 1
  fi
}

compare_macos_online_ipad_entitlements_exact() {
  local expected_path="$1"
  local actual_path="$2"
  local label="$3"

  python3 - "$expected_path" "$actual_path" "$label" <<'PY'
import plistlib
import sys
from pathlib import Path

expected_path = Path(sys.argv[1])
actual_path = Path(sys.argv[2])
label = sys.argv[3]
with expected_path.open("rb") as expected_file:
    expected = plistlib.load(expected_file)
with actual_path.open("rb") as actual_file:
    actual = plistlib.load(actual_file)
if actual != expected:
    print(f"{label} signed entitlements differ from the canonical product entitlements", file=sys.stderr)
    raise SystemExit(1)
PY
}

verify_macos_online_ipad_debug_product_signature() {
  local widget_bundle="$MAC_ONLINE_APP_BUNDLE/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex"
  local framework_root
  local framework
  local framework_identifier

  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$MAC_ONLINE_APP_BUNDLE" >/dev/null; then
    echo "The product-identity macOS online iPad Debug app failed strict nested signature verification." >&2
    return 1
  fi
  if ! verify_macos_online_ipad_signed_identity \
    "$MAC_ONLINE_APP_BUNDLE" \
    "$MAC_HOST_PRODUCT_BUNDLE_ID" \
    "macOS online iPad Debug app"; then
    return 1
  fi
  if ! verify_macos_online_ipad_signed_identity \
    "$widget_bundle" \
    "$MAC_HOST_PRODUCT_WIDGET_BUNDLE_ID" \
    "macOS online iPad Debug Widget"; then
    return 1
  fi
  for framework_root in \
    "$MAC_ONLINE_APP_BUNDLE/Contents/Frameworks" \
    "$widget_bundle/Contents/Frameworks"; do
    [[ -d "$framework_root" ]] || continue
    while IFS= read -r -d '' framework; do
      framework_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$framework/Resources/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$framework/Versions/Current/Resources/Info.plist" 2>/dev/null || true)"
      if [[ -z "$framework_identifier" ]]; then
        echo "Embedded framework is missing a readable CFBundleIdentifier: $framework" >&2
        return 1
      fi
      if ! verify_macos_online_ipad_signed_identity \
        "$framework" \
        "$framework_identifier" \
        "macOS online iPad embedded framework"; then
        return 1
      fi
    done < <(find "$framework_root" -depth -type d -name '*.framework' -print0)
  done

  if ! cmp -s \
    "$MAC_HOST_PRODUCT_PROFILE" \
    "$MAC_ONLINE_APP_BUNDLE/Contents/embedded.provisionprofile" || \
     ! cmp -s \
    "$MAC_HOST_PRODUCT_WIDGET_PROFILE" \
    "$widget_bundle/Contents/embedded.provisionprofile"; then
    echo "The signed Debug app/Widget profiles drifted from the canonical product profiles." >&2
    return 1
  fi
  if ! skybridge_write_signed_entitlements "$MAC_ONLINE_APP_BUNDLE" "$MAC_ONLINE_SIGNED_ENTITLEMENTS" || \
     ! skybridge_write_signed_entitlements "$widget_bundle" "$MAC_ONLINE_WIDGET_SIGNED_ENTITLEMENTS"; then
    echo "Unable to re-extract signed Debug app/Widget entitlements." >&2
    return 1
  fi
  if ! compare_macos_online_ipad_entitlements_exact \
    "$MAC_HOST_PRODUCT_ENTITLEMENTS" \
    "$MAC_ONLINE_SIGNED_ENTITLEMENTS" \
    "macOS online iPad Debug app" || \
     ! compare_macos_online_ipad_entitlements_exact \
    "$MAC_HOST_PRODUCT_WIDGET_ENTITLEMENTS" \
    "$MAC_ONLINE_WIDGET_SIGNED_ENTITLEMENTS" \
    "macOS online iPad Debug Widget"; then
    return 1
  fi
  if ! validate_macos_smoke_host_product_entitlements \
    "$MAC_ONLINE_SIGNED_ENTITLEMENTS" \
    "signed macOS online iPad Debug app" || \
     ! validate_macos_product_widget_entitlements \
    "$MAC_ONLINE_WIDGET_SIGNED_ENTITLEMENTS" \
    "signed macOS online iPad Debug Widget"; then
    return 1
  fi
  if ! skybridge_profile_supports_requested_profile_backed_entitlements \
    "$MAC_ONLINE_APP_BUNDLE/Contents/embedded.provisionprofile" \
    "$MAC_ONLINE_SIGNED_ENTITLEMENTS" || \
     ! skybridge_profile_supports_requested_profile_backed_entitlements \
    "$widget_bundle/Contents/embedded.provisionprofile" \
    "$MAC_ONLINE_WIDGET_SIGNED_ENTITLEMENTS"; then
    echo "The signed Debug app/Widget entitlements are not covered by their exact embedded profiles." >&2
    return 1
  fi
}

sign_macos_online_ipad_debug_app() {
  local widget_bundle="$MAC_ONLINE_APP_BUNDLE/Contents/PlugIns/SkyBridgeCompassWidgetsExtension.appex"

  validate_macos_online_ipad_debug_bundle_identity
  remove_macos_online_ipad_debug_signature_before_binary_mutation
  normalize_macos_online_ipad_debug_rpaths
  normalize_macos_online_ipad_debug_frameworks
  sign_macos_online_ipad_debug_frameworks

  /usr/bin/codesign \
    --force \
    --timestamp=none \
    --options runtime \
    --sign "$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH" \
    --entitlements "$MAC_HOST_PRODUCT_WIDGET_ENTITLEMENTS" \
    "$widget_bundle" >/dev/null
  /usr/bin/codesign \
    --force \
    --timestamp=none \
    --options runtime \
    --sign "$MAC_HOST_PRODUCT_SIGN_IDENTITY_HASH" \
    --entitlements "$MAC_HOST_PRODUCT_ENTITLEMENTS" \
    "$MAC_ONLINE_APP_BUNDLE" >/dev/null
  verify_macos_online_ipad_debug_product_signature

  mkdir -p "$(dirname "$MAC_ONLINE_STATUS")"
  printf '%s mac-online-app-signing source=debug identityKind=developer-id identitySource=canonical-dist appProfile=exact widgetProfile=exact entitlements=app-widget-exact nested=verified keychainAccess=product preMutationSignature=removed\n' \
    "$(timestamp_utc)" >>"$MAC_ONLINE_STATUS"
}

build_macos_online_ipad_app() {
  if [[ -d "$MAC_ONLINE_PACKAGED_APP_BUNDLE" ]]; then
    echo "==> Using packaged macOS online iPad UI client"
    MAC_ONLINE_APP_SOURCE="packaged"
    MAC_ONLINE_APP_SOURCE_CURRENT=0
    MAC_ONLINE_APP_BUNDLE="$MAC_ONLINE_PACKAGED_APP_BUNDLE"
    MAC_ONLINE_APP_BIN="$MAC_ONLINE_APP_BUNDLE/Contents/MacOS/SkyBridgeCompassApp"
    verify_macos_online_ipad_app_bundle "packaged"
    return 0
  fi

  if [[ "$MAC_ONLINE_ALLOW_DEBUG_BUILD" != "1" ]]; then
    echo "Packaged macOS online iPad app bundle not found: $MAC_ONLINE_PACKAGED_APP_BUNDLE" >&2
    echo "Build and notarize the packaged app before running the real-device mac-online UI smoke, or set SKYBRIDGE_SMOKE_MAC_ONLINE_ALLOW_DEBUG_BUILD=1 for an explicit diagnostic Debug build." >&2
    exit 1
  fi

  echo "==> Building macOS online iPad UI client"
  SKYBRIDGE_XCODE_WARNINGS_AS_ERRORS=1 skybridge_run_xcodebuild \
    -project "$ROOT_DIR/SkyBridgeWidgets.xcodeproj" \
    -scheme "SkyBridgeCompassMac" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$MAC_ONLINE_DERIVED_DATA" \
    ENABLE_DEBUG_DYLIB=NO \
    build >"$MAC_ONLINE_BUILD_LOG"

  local debug_app_bundle="$MAC_ONLINE_DERIVED_DATA/Build/Products/Debug/SkyBridge Compass Pro.app"
  if [[ ! -d "$debug_app_bundle" ]]; then
    echo "macOS online iPad app bundle not found: $debug_app_bundle" >&2
    exit 1
  fi
  rm -rf -- "$MAC_ONLINE_RUNTIME_APP_BUNDLE"
  ditto "$debug_app_bundle" "$MAC_ONLINE_RUNTIME_APP_BUNDLE"
  MAC_ONLINE_APP_SOURCE="debug"
  MAC_ONLINE_APP_SOURCE_CURRENT=0
  MAC_ONLINE_APP_BUNDLE="$MAC_ONLINE_RUNTIME_APP_BUNDLE"
  MAC_ONLINE_APP_BIN="$MAC_ONLINE_APP_BUNDLE/Contents/MacOS/SkyBridgeCompassApp"
  if [[ ! -x "$MAC_ONLINE_APP_BIN" ]]; then
    echo "macOS online iPad app executable not found: $MAC_ONLINE_APP_BIN" >&2
    exit 1
  fi
  sign_macos_online_ipad_debug_app
  clear_runtime_bundle_quarantine_if_present "$MAC_ONLINE_APP_BUNDLE" "macOS online iPad Debug app"
  verify_macos_online_ipad_app_bundle "debug"
}

register_macos_online_ipad_app_bundle() {
  if ! require_no_external_macos_online_ipad_clients; then
    return 1
  fi
  register_launch_services_app_bundle "$MAC_ONLINE_APP_BUNDLE" || return 1
  if [[ "$MAC_ONLINE_APP_BUNDLE" == "$MAC_ONLINE_RUNTIME_APP_BUNDLE" ]]; then
    MAC_ONLINE_APP_REGISTERED=1
    MAC_LAUNCH_SERVICES_RESTORE_REQUIRED=1
  fi
}

verify_macos_online_ipad_pib_v3_wire_freshness() {
  local wire_source="$ROOT_DIR/Sources/SkyBridgeCore/P2P/AppMessage.swift"
  local required_markers=(
    "SkyBridge-PIB-1-V3-Confirm"
    "SkyBridge-PIB-1-V3-SignedFinalAck"
  )
  local marker

  if [[ ! -f "$wire_source" ]]; then
    echo "PIB-1 wire source is missing: $wire_source" >&2
    return 1
  fi

  for marker in "${required_markers[@]}"; do
    if ! LC_ALL=C /usr/bin/grep -aFq -- "$marker" "$MAC_ONLINE_APP_BIN"; then
      echo "macOS online iPad app is missing a required PIB-1 v3 wire marker: $marker" >&2
      echo "Refusing a protocol-incompatible packaged client that iOS must reject fail closed." >&2
      echo "Rebuild, sign, and notarize the macOS app from the current source before rerunning this smoke." >&2
      return 1
    fi
  done

  if [[ "$wire_source" -nt "$MAC_ONLINE_APP_BIN" ]]; then
    echo "macOS online iPad app is older than the current PIB-1 wire source: $wire_source" >&2
    echo "Rebuild, sign, and notarize the macOS app before claiming Mac-to-iOS handshake proof." >&2
    return 1
  fi

  printf '%s mac-online-app-wire protocol=PIB-1-v3 transaction=present finalAck=present sourceFresh=1\n' \
    "$(timestamp_utc)" >>"$MAC_ONLINE_STATUS"
}

verify_macos_online_ipad_app_bundle() {
  local source_kind="$1"
  if [[ ! -d "$MAC_ONLINE_APP_BUNDLE" ]]; then
    echo "macOS online iPad app bundle not found: $MAC_ONLINE_APP_BUNDLE" >&2
    exit 1
  fi
  if [[ ! -x "$MAC_ONLINE_APP_BIN" ]]; then
    echo "macOS online iPad app executable not found: $MAC_ONLINE_APP_BIN" >&2
    exit 1
  fi
  verify_macos_online_ipad_pib_v3_wire_freshness
  verify_macos_online_ipad_framework_resolution
  codesign --verify --deep --strict "$MAC_ONLINE_APP_BUNDLE" >/dev/null
  local trust_status="codesign=verified"
  if [[ "$source_kind" == "packaged" ]]; then
    xcrun stapler validate "$MAC_ONLINE_APP_BUNDLE" >/dev/null
    spctl --assess --type execute "$MAC_ONLINE_APP_BUNDLE" >/dev/null
    trust_status="$trust_status stapler=valid spctl=accepted"
  fi
  MAC_ONLINE_APP_SOURCE_CURRENT=1
  printf '%s mac-online-app source=%s %s bundle=%s executable=%s\n' "$(timestamp_utc)" "$source_kind" "$trust_status" "$MAC_ONLINE_APP_BUNDLE" "$MAC_ONLINE_APP_BIN" >>"$MAC_ONLINE_STATUS"
}

verify_macos_online_ipad_framework_resolution() {
  local forbidden_rpaths
  forbidden_rpaths="$(macos_online_ipad_rpaths "$MAC_ONLINE_APP_BIN" | grep -E '/Build/Products/.*/PackageFrameworks|/PackageFrameworks$' || true)"
  if [[ -n "$forbidden_rpaths" ]]; then
    echo "macOS online iPad app contains external PackageFrameworks rpath(s):" >&2
    printf '%s\n' "$forbidden_rpaths" >&2
    exit 1
  fi

  if /usr/bin/otool -L "$MAC_ONLINE_APP_BIN" | grep -Fq '@rpath/WebRTC.framework/WebRTC'; then
    local webrtc_framework="$MAC_ONLINE_APP_BUNDLE/Contents/Frameworks/WebRTC.framework"
    if [[ ! -d "$webrtc_framework" ]]; then
      echo "macOS online iPad app links WebRTC via @rpath but does not embed Contents/Frameworks/WebRTC.framework." >&2
      exit 1
    fi
    if [[ ! -x "$webrtc_framework/WebRTC" && ! -x "$webrtc_framework/Versions/A/WebRTC" ]]; then
      echo "macOS online iPad app embeds WebRTC.framework without an executable WebRTC binary." >&2
      exit 1
    fi
    if ! skybridge_assert_no_nested_framework_versions_payload "$webrtc_framework"; then
      echo "macOS online iPad app embeds WebRTC.framework with a nested Versions directory under Versions/A; repackage the framework before LaunchServices smoke." >&2
      exit 1
    fi
    if ! macos_online_ipad_rpaths "$MAC_ONLINE_APP_BIN" | grep -Fxq '@executable_path/../Frameworks'; then
      echo "macOS online iPad app links WebRTC via @rpath but lacks @executable_path/../Frameworks." >&2
      exit 1
    fi
  fi
}

canonical_macos_online_ipad_client_bin() {
  [[ -n "$MAC_ONLINE_APP_BIN" ]] || return 1
  local app_dir
  app_dir="$(cd "$(dirname "$MAC_ONLINE_APP_BIN")" && pwd -P)" || return 1
  printf '%s/%s\n' "$app_dir" "$(basename "$MAC_ONLINE_APP_BIN")"
}

require_no_external_macos_online_ipad_clients() {
  local app_bin
  local canonical_product_executable="$MAC_HOST_PRODUCT_APP_BUNDLE/Contents/MacOS/SkyBridgeCompassApp"
  app_bin="$(canonical_macos_online_ipad_client_bin)" || return 1
  if ! skybridge_mac_require_executable_absent \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$app_bin" \
    "macOS online iPad client"; then
    return 1
  fi
  if [[ "$canonical_product_executable" != "$app_bin" ]] \
    && ! skybridge_mac_require_executable_absent \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$canonical_product_executable" \
      "canonical macOS product sharing the online client bundle identity"; then
    return 1
  fi
}

cleanup_macos_online_ipad_launch_services_registration() {
  local runtime_app="$MAC_ONLINE_RUNTIME_APP_BUNDLE"

  if [[ "${MAC_ONLINE_APP_REGISTERED:-0}" != "1" ]]; then
    return 0
  fi
  if [[ -z "${MAC_ONLINE_RUNTIME_DIR:-}" || \
        "$runtime_app" != "$MAC_ONLINE_RUNTIME_DIR/"* || \
        "$runtime_app" == "$MAC_ONLINE_RUNTIME_DIR" || \
        "$MAC_ONLINE_APP_BUNDLE" != "$runtime_app" ]]; then
    echo "Refusing unsafe macOS online iPad runtime registration cleanup path." >&2
    return 1
  fi
  if [[ ! -d "$runtime_app" || -L "$runtime_app" ]]; then
    echo "Registered macOS online iPad runtime app disappeared before cleanup." >&2
    return 1
  fi
  if ! require_no_external_macos_online_ipad_clients; then
    echo "Refusing to unregister the macOS online iPad runtime while its exact executable is still active." >&2
    return 1
  fi
  if ! unregister_launch_services_app_bundle "$runtime_app"; then
    return 1
  fi
  if ! verify_launch_services_runtime_paths_absent "$runtime_app"; then
    return 1
  fi
  MAC_ONLINE_APP_REGISTERED=0
}

open_macos_online_ipad_app_bundle() {
  mkdir -p "$MAC_ONLINE_RUNTIME_DIR"
  : >"$MAC_ONLINE_LAUNCH_STDOUT"
  : >"$MAC_ONLINE_LAUNCH_STDERR"
  : >"$MAC_ONLINE_LAUNCH_OPEN_STDERR"
  /usr/bin/open \
    --stdout "$MAC_ONLINE_LAUNCH_STDOUT" \
    --stderr "$MAC_ONLINE_LAUNCH_STDERR" \
    --env "SKYBRIDGE_KEYCHAIN_IN_MEMORY=$KEYCHAIN_IN_MEMORY" \
    --env "SKYBRIDGE_SMOKE_ROLE=mac-online-ipad-client" \
    --env "SKYBRIDGE_SMOKE_AUTO_EXIT=1" \
    --env "SKYBRIDGE_SMOKE_STATUS_FILE=$MAC_ONLINE_STATUS" \
    --env "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS=$SMOKE_TIMEOUT_SECONDS" \
    --env "SKYBRIDGE_TARGET_IPAD_IDENTITY=$IOS_PQC_DEVICE_ID" \
    "$MAC_ONLINE_APP_BUNDLE" \
    2>>"$MAC_ONLINE_LAUNCH_OPEN_STDERR"
  local open_status=$?
  sync_mac_online_launch_stdio
  return "$open_status"
}

find_macos_online_ipad_client_pid() {
  # Resolves the freshly opened client's pid into MAC_ONLINE_PID, requiring a
  # single exact-executable match so the smoke can never latch onto a stray
  # SkyBridge process.
  skybridge_mac_wait_for_single_exact_process \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$MAC_ONLINE_APP_BIN" \
    20 \
    MAC_ONLINE_PID \
    "macOS online iPad client"
}

start_macos_online_ipad_client() {
  : >"$MAC_ONLINE_STDOUT"
  : >"$MAC_ONLINE_STDERR"
  : >"$MAC_ONLINE_APP_STDOUT"
  : >"$MAC_ONLINE_APP_STDERR"
  : >"$MAC_ONLINE_OPEN_STDERR"

  if ! register_macos_online_ipad_app_bundle; then
    printf '%s failed stage=mac-online-ipad phase=launch reason=launch-services-registration-failed\n' "$(timestamp_utc)" >>"$MAC_ONLINE_STATUS"
    return 1
  fi
  local open_attempt=1
  while (( open_attempt <= 3 )); do
    if ! require_no_external_macos_online_ipad_clients; then
      printf '%s failed stage=mac-online-ipad phase=launch reason=pre-existing-exact-executable\n' "$(timestamp_utc)" >>"$MAC_ONLINE_STATUS"
      return 1
    fi
    printf '%s launch method=open-app-bundle attempt=%s preExistingExactExecutable=0\n' "$(timestamp_utc)" "$open_attempt" >>"$MAC_ONLINE_STATUS"
    if open_macos_online_ipad_app_bundle; then
      if find_macos_online_ipad_client_pid; then
        if ! skybridge_mac_capture_owned_process \
          "$PROCESS_OWNERSHIP_HELPER" \
          "$MAC_ONLINE_PID" \
          "$MAC_ONLINE_APP_BIN" \
          "$MAC_ONLINE_PROCESS_IDENTITY" \
          "macOS online iPad client"; then
          printf '%s failed stage=mac-online-ipad phase=launch reason=process-ownership-unverifiable\n' "$(timestamp_utc)" >>"$MAC_ONLINE_STATUS"
          return 1
        fi
        printf '%s launch method=open-app-bundle pid=%s role=mac-online-ipad-client ownership=audit-token\n' "$(timestamp_utc)" "$MAC_ONLINE_PID" >>"$MAC_ONLINE_STATUS"
        return 0
      fi
      printf '%s launch method=open-app-bundle attempt=%s result=pid-timeout\n' "$(timestamp_utc)" "$open_attempt" >>"$MAC_ONLINE_STATUS"
    else
      local open_status=$?
      printf '%s launch method=open-app-bundle attempt=%s result=open-failed status=%s\n' "$(timestamp_utc)" "$open_attempt" "$open_status" >>"$MAC_ONLINE_STATUS"
    fi

    sleep "$open_attempt"
    open_attempt=$((open_attempt + 1))
  done

  printf '%s failed stage=mac-online-ipad phase=launch reason=app-pid-not-found\n' "$(timestamp_utc)" >>"$MAC_ONLINE_STATUS"
  echo "Timed out waiting for SkyBridge Compass Pro app pid after LaunchServices start." >&2
  print_smoke_tail_for_operator 80 "$MAC_ONLINE_STATUS"
  print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDOUT"
  print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDERR"
  print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDOUT"
  print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDERR"
  print_smoke_tail_for_operator 80 "$MAC_ONLINE_OPEN_STDERR"
  return 1
}

wait_for_mac_online_pattern() {
  local pattern="$1"
  local timeout_seconds="$2"
  local label="$3"
  local started_at
  started_at="$(date +%s)"
  while true; do
    if [[ -n "$MAC_ONLINE_PID" ]] && ! skybridge_mac_owned_process_status \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$MAC_ONLINE_PID" \
      "$MAC_ONLINE_PROCESS_IDENTITY"; then
      wait "$MAC_ONLINE_PID" >/dev/null 2>&1 || true
      printf '%s failed stage=mac-online-ipad phase=wait-pattern reason=process-exited label=%s pid=%s\n' \
        "$(timestamp_utc)" "${label// /_}" "$MAC_ONLINE_PID" >>"$MAC_ONLINE_STATUS"
      MAC_ONLINE_PID=""
      if [[ -f "$MAC_ONLINE_STATUS" ]] && grep -qE "$pattern" "$MAC_ONLINE_STATUS"; then
        return 0
      fi
      echo "macOS online iPad UI client exited while waiting for ${label}: ${MAC_ONLINE_STATUS}" >&2
      sync_mac_online_launch_stdio
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STATUS"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDERR"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDERR"
      return 1
    fi
    if [[ -f "$MAC_ONLINE_STATUS" ]] && grep -qE "$MAC_ONLINE_WAIT_FAILURE_PATTERN" "$MAC_ONLINE_STATUS"; then
      echo "Detected macOS online iPad UI failure while waiting for ${label}: ${MAC_ONLINE_STATUS}" >&2
      sync_mac_online_launch_stdio
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STATUS"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDERR"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDERR"
      return 1
    fi
    if [[ -f "$MAC_ONLINE_STATUS" ]] && grep -qE "$pattern" "$MAC_ONLINE_STATUS"; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      local grace_started_at
      grace_started_at="$(date +%s)"
      while (( "$(date +%s)" - grace_started_at < MAC_ONLINE_PATTERN_FINAL_GRACE_SECONDS )); do
        sync_mac_online_launch_stdio
        if [[ -f "$MAC_ONLINE_STATUS" ]] && grep -qE "$pattern" "$MAC_ONLINE_STATUS"; then
          return 0
        fi
        sleep 0.5
      done
      printf '%s failed stage=mac-online-ipad phase=wait-pattern reason=timeout label=%s pid=%s\n' \
        "$(timestamp_utc)" "${label// /_}" "${MAC_ONLINE_PID:-none}" >>"$MAC_ONLINE_STATUS"
      echo "Timed out waiting for ${label}: ${MAC_ONLINE_STATUS}" >&2
      sync_mac_online_launch_stdio
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STATUS"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDERR"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDERR"
      return 1
    fi
    sleep 1
  done
}

press_mac_online_ipad_connect_button() {
  run_stdin_command_with_hard_timeout 20 "$XCODE_SWIFT_BIN" - <<'SWIFT'
	import ApplicationServices
	import AppKit
	import Darwin
	import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard AXIsProcessTrusted() else {
    fail("macOS Accessibility permission is required to press the SkyBridge online iPad Connect button")
}

let targetProcessIdentifier = ProcessInfo.processInfo.environment["SKYBRIDGE_MAC_ONLINE_APP_PID"]
    .flatMap { pid in Int32(pid.trimmingCharacters(in: .whitespacesAndNewlines)) }
let candidates = NSWorkspace.shared.runningApplications.filter { app in
    app.localizedName == "SkyBridge Compass Pro"
        || app.executableURL?.lastPathComponent == "SkyBridgeCompassApp"
}
let app: NSRunningApplication?
if let targetProcessIdentifier {
    app = candidates.first { $0.processIdentifier == targetProcessIdentifier }
} else {
    app = candidates.sorted(by: { $0.processIdentifier > $1.processIdentifier }).first
}
guard let app else {
    fail("SkyBridge Compass Pro process is not running")
}

let labels = Set(["连接", "Connect"])
let statusPath = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]
let targetIdentityFromEnvironment = ProcessInfo.processInfo.environment["SKYBRIDGE_TARGET_IPAD_IDENTITY"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let targetNameFromEnvironment = ProcessInfo.processInfo.environment["SKYBRIDGE_TARGET_IPAD_NAME"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let statusLines = statusPath
    .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
    .split(whereSeparator: \.isNewline)
    .map(String.init) ?? []

func fieldValue(_ key: String, in line: String) -> String? {
    guard let keyRange = line.range(of: "\(key)=") else { return nil }
    let suffix = line[keyRange.upperBound...]
    return suffix.split(separator: " ", maxSplits: 1).first.map(String.init)
}

let targetIdentity: String? = {
    if let targetIdentityFromEnvironment, !targetIdentityFromEnvironment.isEmpty {
        return targetIdentityFromEnvironment
    }
    guard let targetLine = statusLines.reversed().first(where: { line in
        line.contains("waiting-connect-click source=OnlineDeviceCard")
    }) else {
        return nil
    }
    return fieldValue("identity", in: targetLine)
}()

func accessibilityIdentifierToken(for identity: String) -> String {
    identity.unicodeScalars.map { scalar -> String in
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return String(scalar)
        default:
            return "_"
        }
    }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

func stableIdentityPayload(from identity: String) -> String? {
    let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lowercased = trimmed.lowercased()
    if lowercased.hasPrefix("id:") {
        let payload = String(trimmed.dropFirst("id:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload.lowercased()
    }
    if trimmed.range(
        of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
        options: .regularExpression
    ) != nil {
        return trimmed.lowercased()
    }
    return nil
}

func identityVariants(for identity: String?) -> Set<String> {
    guard let identity else { return [] }
    let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let lowercased = trimmed.lowercased()
    var variants = Set<String>()
    variants.insert(trimmed)
    variants.insert(lowercased)
    if let stable = stableIdentityPayload(from: trimmed) {
        variants.insert(stable)
        variants.insert("id:\(stable)")
        if !lowercased.hasPrefix("id:") {
            variants.insert("id:\(trimmed)")
        }
    }
    return variants
}

let targetIdentityVariants = identityVariants(for: targetIdentity)

func identityValueMatchesTarget(_ value: String?) -> Bool {
    guard let value,
          !targetIdentityVariants.isEmpty else {
        return false
    }
    let variants = identityVariants(for: value)
    return !variants.isDisjoint(with: targetIdentityVariants)
}

func normalizedAXText(_ value: String) -> String {
    value
        .replacingOccurrences(of: "_", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}

let enabledOnlineDeviceRows = statusLines.filter { line in
    line.contains("mac-online-device-ui")
        && line.contains("targetFamily=ipad")
        && line.contains("source=OnlineDeviceCard")
        && line.contains("buttonEnabled=1")
}

let targetRowEvidenceLine: String? = {
    guard !enabledOnlineDeviceRows.isEmpty else { return nil }

    if targetIdentity != nil,
       let identityMatched = enabledOnlineDeviceRows.reversed().first(where: { line in
           identityValueMatchesTarget(fieldValue("identityKey", in: line))
               || identityValueMatchesTarget(fieldValue("targetDeviceId", in: line))
               || identityValueMatchesTarget(fieldValue("p2pDeviceId", in: line))
       }) {
        return identityMatched
    }

    let requestedName = normalizedAXText(targetNameFromEnvironment ?? "")
    if !requestedName.isEmpty,
       requestedName != "ipad" {
        let nameMatches = enabledOnlineDeviceRows.filter { line in
            [fieldValue("device", in: line), fieldValue("bonjourServiceName", in: line)]
                .compactMap { $0 }
                .map(normalizedAXText)
                .contains { $0.contains(requestedName) || requestedName.contains($0) }
        }
        if nameMatches.count == 1 {
            return nameMatches[0]
        }
    }

    if targetIdentity == nil, enabledOnlineDeviceRows.count == 1 {
        return enabledOnlineDeviceRows[0]
    }

    guard targetIdentity == nil else { return nil }
    return enabledOnlineDeviceRows.last
}()

func appendIdentityVariants(_ value: String?, to variants: inout Set<String>) {
    variants.formUnion(identityVariants(for: value))
}

let targetButtonIdentityVariants: Set<String> = {
    var variants = targetIdentityVariants
    if let rowLine = targetRowEvidenceLine {
        appendIdentityVariants(fieldValue("identityKey", in: rowLine), to: &variants)
        appendIdentityVariants(fieldValue("targetDeviceId", in: rowLine), to: &variants)
        appendIdentityVariants(fieldValue("p2pDeviceId", in: rowLine), to: &variants)
    }
    return variants
}()

let targetIdentifiers: Set<String> = {
    guard !targetButtonIdentityVariants.isEmpty else { return [] }
    return Set(targetButtonIdentityVariants.compactMap { identity in
        let token = accessibilityIdentifierToken(for: identity)
        guard !token.isEmpty else { return nil }
        return "skybridge-online-device-connect-button-\(token)"
    })
}()

let targetDeviceNames: Set<String> = {
    let rawValues = [
        targetNameFromEnvironment,
        targetRowEvidenceLine.flatMap { fieldValue("device", in: $0) }
    ].compactMap { $0 }
    var variants: [String] = []
    for raw in rawValues {
        variants.append(raw)
        variants.append(raw.replacingOccurrences(of: "_", with: " "))
    }
    return Set(variants.map(normalizedAXText).filter { !$0.isEmpty && $0 != "-" })
}()

	func appendStatus(_ body: String) {
	    guard let statusPath else { return }
	    let rendered = "[\(ISO8601DateFormatter().string(from: Date()))] \(body)\n"
	    guard let data = rendered.data(using: .utf8) else {
	        return
	    }
	    let flags = O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW
	    let fd = open(statusPath, flags, mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH))
	    guard fd >= 0 else { return }
	    defer { close(fd) }

	    var metadata = stat()
	    guard fstat(fd, &metadata) == 0,
	          (metadata.st_mode & S_IFMT) == S_IFREG else {
	        return
	    }

	    data.withUnsafeBytes { rawBuffer in
	        guard var current = rawBuffer.baseAddress else { return }
	        var remaining = rawBuffer.count
	        while remaining > 0 {
	            let written = write(fd, current, remaining)
	            if written <= 0 {
	                break
	            }
	            current = current.advanced(by: written)
	            remaining -= written
	        }
	    }
	}

func appendButtonClickEvidence(
    targetRowBound: Bool,
    axMatch: String,
    buttonIdentifier: String,
    didCenterClick: Bool
) {
    let identity = targetIdentity ?? "ax-visible-ipad-row"
    if targetRowEvidenceLine == nil, targetRowBound, targetIdentity == nil {
        appendStatus([
            "mac-online-device-ui",
            "targetFamily=ipad",
            "visible=1",
            "source=OnlineDeviceCard",
            "evidenceSource=external-ax",
            "status=online",
            "buttonEnabled=1",
            "matchStrength=\(targetIdentity == nil ? "visual-label" : "stable-id")",
            "identityKey=\(identity)",
            "buttonEvidenceSource=accessibility"
        ].joined(separator: " "))
    }
    var fields = [
        "mac-online-connect",
        "action=button",
        "targetFamily=ipad",
        "button=1",
        "source=OnlineDeviceCard",
        "clickSource=accessibility",
        "clickMechanism=AXUIElementPerformAction",
        "clickAssist=\(didCenterClick ? "CGEventCenterClick" : "none")",
        "targetRowBound=\(targetRowBound ? 1 : 0)",
        "axMatch=\(axMatch)",
        "buttonIdentifier=\(buttonIdentifier.isEmpty ? "-" : buttonIdentifier)"
    ]
    if targetRowEvidenceLine == nil {
        fields.append("identityKey=\(identity)")
        appendStatus(fields.joined(separator: " "))
        appendConnectStartEvidence(targetRowBound: targetRowBound, didCenterClick: didCenterClick)
        return
    }
    let rowLine = targetRowEvidenceLine!
    for key in [
        "resolvedSource",
        "controlEndpoint",
        "candidateCount",
        "service",
        "endpointClass",
        "identityKey",
        "targetDeviceId",
        "p2pDeviceId",
        "pubKeyFP",
        "routeIdentifier",
        "bonjourServiceName",
        "endpointHost",
        "endpointPort",
        "buttonEnabledAtClick",
        "disabledReason"
    ] {
        if let value = fieldValue(key, in: rowLine) {
            fields.append("\(key)=\(value)")
        }
    }
    appendStatus(fields.joined(separator: " "))
    appendConnectStartEvidence(targetRowBound: targetRowBound, didCenterClick: didCenterClick)
}

func appendConnectStartEvidence(targetRowBound: Bool, didCenterClick: Bool) {
    let identity = targetIdentity ?? "ax-visible-ipad-row"
    var fields = [
        "mac-online-connect-start",
        "action=button",
        "targetFamily=ipad",
        "source=OnlineDeviceCard",
        "evidenceSource=external-ax",
        "clickSource=accessibility",
        "clickMechanism=AXUIElementPerformAction",
        "clickAssist=\(didCenterClick ? "CGEventCenterClick" : "none")",
        "targetRowBound=\(targetRowBound ? 1 : 0)"
    ]
    guard let rowLine = targetRowEvidenceLine else {
        fields.append("identityKey=\(identity)")
        appendStatus(fields.joined(separator: " "))
        return
    }
    for key in [
        "identityKey",
        "targetDeviceId",
        "p2pDeviceId",
        "pubKeyFP",
        "buttonEnabledAtClick",
        "disabledReason"
    ] {
        if let value = fieldValue(key, in: rowLine) {
            fields.append("\(key)=\(value)")
        }
    }
    appendStatus(fields.joined(separator: " "))
}

let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 0.25)

let maxAXTraversalNodes = 5000
let maxAXTraversalDepth = 32
var axTraversalNodes = 0

func resetAXTraversalBudget() {
    axTraversalNodes = 0
}

func shouldVisitAXNode(depth: Int) -> Bool {
    guard depth <= maxAXTraversalDepth,
          axTraversalNodes < maxAXTraversalNodes else {
        return false
    }
    axTraversalNodes += 1
    return true
}

func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    AXUIElementSetMessagingTimeout(element, 0.25)
    var result: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
    guard error == .success else { return nil }
    return result as AnyObject?
}

func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
    value(element, attribute) as? String
}

func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
    value(element, attribute) as? Bool
}

func pointValue(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let axValue = value(element, attribute) else { return nil }
    let opaque = axValue as! AXValue
    guard AXValueGetType(opaque) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(opaque, .cgPoint, &point) ? point : nil
}

func sizeValue(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let axValue = value(element, attribute) else { return nil }
    let opaque = axValue as! AXValue
    guard AXValueGetType(opaque) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(opaque, .cgSize, &size) ? size : nil
}

@discardableResult
func clickElementCenter(_ element: AXUIElement) -> Bool {
    guard let position = pointValue(element, kAXPositionAttribute as String),
          let size = sizeValue(element, kAXSizeAttribute as String),
          size.width > 0,
          size.height > 0 else {
        return false
    }
    let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
          let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) else {
        return false
    }
    mouseDown.post(tap: .cghidEventTap)
    usleep(80_000)
    mouseUp.post(tap: .cghidEventTap)
    return true
}

func textValues(of element: AXUIElement) -> [String] {
    [
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
        kAXHelpAttribute as String
    ].compactMap { stringValue(element, $0) }
}

func children(of element: AXUIElement) -> [AXUIElement] {
    let childAttributes = [kAXWindowsAttribute as String, kAXChildrenAttribute as String]
    for attribute in childAttributes {
        if let values = value(element, attribute) as? [AXUIElement], !values.isEmpty {
            return values
        }
    }
    return []
}

func subtreeContainsTargetDevice(_ element: AXUIElement, depth: Int = 0) -> Bool {
    guard !targetDeviceNames.isEmpty,
          shouldVisitAXNode(depth: depth) else { return false }
    let ownText = normalizedAXText(textValues(of: element).joined(separator: " "))
    if targetDeviceNames.contains(where: { ownText.contains($0) }) {
        return true
    }
    return children(of: element).contains { subtreeContainsTargetDevice($0, depth: depth + 1) }
}

func subtreeContainsConnectButton(_ element: AXUIElement, depth: Int = 0) -> Bool {
    guard shouldVisitAXNode(depth: depth) else { return false }
    let role = stringValue(element, kAXRoleAttribute as String) ?? ""
    let identifier = stringValue(element, kAXIdentifierAttribute as String) ?? ""
    let title = stringValue(element, kAXTitleAttribute as String)
        ?? stringValue(element, kAXDescriptionAttribute as String)
        ?? ""
    let enabled = boolValue(element, kAXEnabledAttribute as String) ?? true
    if role == kAXButtonRole as String,
       enabled,
       identifier.hasPrefix("skybridge-online-device-connect-button-") || labels.contains(title) {
        return true
    }
    return children(of: element).contains { subtreeContainsConnectButton($0, depth: depth + 1) }
}

func pressExactIdentifierButton(in element: AXUIElement, depth: Int = 0) -> Bool {
    guard shouldVisitAXNode(depth: depth) else { return false }
    let role = stringValue(element, kAXRoleAttribute as String) ?? ""
    let identifier = stringValue(element, kAXIdentifierAttribute as String) ?? ""
    let title = stringValue(element, kAXTitleAttribute as String)
        ?? stringValue(element, kAXDescriptionAttribute as String)
        ?? ""
    let enabled = boolValue(element, kAXEnabledAttribute as String) ?? true
    if role == kAXButtonRole as String,
       enabled,
       targetIdentifiers.contains(identifier) {
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        let didCenterClick = clickElementCenter(element)
        if error == .success || didCenterClick {
            appendButtonClickEvidence(
                targetRowBound: true,
                axMatch: "target-identifier",
                buttonIdentifier: identifier,
                didCenterClick: didCenterClick
            )
            print("pressed connect button title=\(title) identifier=\(identifier)")
            return true
        }
    }
    for child in children(of: element) {
        if pressExactIdentifierButton(in: child, depth: depth + 1) {
            return true
        }
    }
    return false
}

func pressFirstConnectButton(
    in element: AXUIElement,
    depth: Int = 0,
    allowTitleMatch: Bool,
    targetRowBound: Bool
) -> Bool {
    guard shouldVisitAXNode(depth: depth) else { return false }
    let role = stringValue(element, kAXRoleAttribute as String) ?? ""
    let identifier = stringValue(element, kAXIdentifierAttribute as String) ?? ""
    let title = stringValue(element, kAXTitleAttribute as String)
        ?? stringValue(element, kAXDescriptionAttribute as String)
        ?? ""
    let enabled = boolValue(element, kAXEnabledAttribute as String) ?? true
    let exactIdentifierMatch = !targetIdentifiers.isEmpty && targetIdentifiers.contains(identifier)
    let isSkyBridgeDeviceButton = identifier.hasPrefix("skybridge-online-device-connect-button-")
    let fallbackIdentifierMatch = targetIdentity == nil && isSkyBridgeDeviceButton
    let targetScopedTitleMatch = allowTitleMatch
        && targetRowBound
        && labels.contains(title)
        && (targetIdentity == nil || targetRowEvidenceLine != nil || !isSkyBridgeDeviceButton)
    let unscopedTitleMatch = allowTitleMatch
        && targetIdentity == nil
        && labels.contains(title)
    let titleMatch = targetScopedTitleMatch || unscopedTitleMatch
    if role == kAXButtonRole as String,
       enabled,
       exactIdentifierMatch || fallbackIdentifierMatch || titleMatch {
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        let didCenterClick = clickElementCenter(element)
        if error == .success || didCenterClick {
            let matchKind = exactIdentifierMatch ? "target-identifier" : (fallbackIdentifierMatch ? "fallback-identifier" : "target-row-title")
            appendButtonClickEvidence(
                targetRowBound: targetRowBound || exactIdentifierMatch,
                axMatch: matchKind,
                buttonIdentifier: identifier,
                didCenterClick: didCenterClick
            )
            print("pressed connect button title=\(title) identifier=\(identifier)")
            return true
        }
    }
    for child in children(of: element) {
        if pressFirstConnectButton(
            in: child,
            depth: depth + 1,
            allowTitleMatch: allowTitleMatch,
            targetRowBound: targetRowBound
        ) {
            return true
        }
    }
    return false
}

func pressConnectButtonInTargetRow(in element: AXUIElement, depth: Int = 0) -> Bool {
    guard shouldVisitAXNode(depth: depth) else { return false }
    let candidateChildren = children(of: element).filter { child in
        subtreeContainsTargetDevice(child) && subtreeContainsConnectButton(child)
    }
    for child in candidateChildren {
        if pressConnectButtonInTargetRow(in: child, depth: depth + 1) {
            return true
        }
    }
    if subtreeContainsTargetDevice(element),
       subtreeContainsConnectButton(element),
       pressFirstConnectButton(in: element, allowTitleMatch: true, targetRowBound: true) {
        return true
    }
    return false
}

NSRunningApplication(processIdentifier: app.processIdentifier)?.activate(options: [.activateAllWindows])
Thread.sleep(forTimeInterval: 0.5)

var pressed = false
resetAXTraversalBudget()
if !targetIdentifiers.isEmpty {
    pressed = pressExactIdentifierButton(in: root)
}
if !pressed {
    resetAXTraversalBudget()
    pressed = pressFirstConnectButton(in: root, allowTitleMatch: false, targetRowBound: false)
}
if !pressed {
    resetAXTraversalBudget()
    pressed = pressConnectButtonInTargetRow(in: root)
}
if !pressed && targetDeviceNames.isEmpty {
    resetAXTraversalBudget()
    pressed = pressFirstConnectButton(in: root, allowTitleMatch: true, targetRowBound: false)
}

guard pressed else {
    fail("unable to find an enabled SkyBridge online iPad Connect button targetIdentifiers=\(targetIdentifiers.count) targetRowBound=\(targetRowEvidenceLine != nil)")
}
SWIFT
}

observe_mac_online_ipad_connected_row() {
  run_stdin_command_with_hard_timeout 20 "$XCODE_SWIFT_BIN" - <<'SWIFT'
	import ApplicationServices
	import AppKit
	import Darwin
	import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard AXIsProcessTrusted() else {
    fail("macOS Accessibility permission is required to observe the SkyBridge online iPad connection result")
}

let targetProcessIdentifier = ProcessInfo.processInfo.environment["SKYBRIDGE_MAC_ONLINE_APP_PID"]
    .flatMap { pid in Int32(pid.trimmingCharacters(in: .whitespacesAndNewlines)) }
let candidates = NSWorkspace.shared.runningApplications.filter { app in
    app.localizedName == "SkyBridge Compass Pro"
        || app.executableURL?.lastPathComponent == "SkyBridgeCompassApp"
}
let app: NSRunningApplication?
if let targetProcessIdentifier {
    app = candidates.first { $0.processIdentifier == targetProcessIdentifier }
} else {
    app = candidates.sorted(by: { $0.processIdentifier > $1.processIdentifier }).first
}
guard let app else {
    fail("SkyBridge Compass Pro process is not running")
}

let statusPath = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_STATUS_FILE"]
let targetIdentityFromEnvironment = ProcessInfo.processInfo.environment["SKYBRIDGE_TARGET_IPAD_IDENTITY"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let targetNameFromEnvironment = ProcessInfo.processInfo.environment["SKYBRIDGE_TARGET_IPAD_NAME"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let statusLines = statusPath
    .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
    .split(whereSeparator: \.isNewline)
    .map(String.init) ?? []

func fieldValue(_ key: String, in line: String) -> String? {
    guard let keyRange = line.range(of: "\(key)=") else { return nil }
    let suffix = line[keyRange.upperBound...]
    return suffix.split(separator: " ", maxSplits: 1).first.map(String.init)
}

let targetIdentity: String? = {
    if let targetIdentityFromEnvironment, !targetIdentityFromEnvironment.isEmpty {
        return targetIdentityFromEnvironment
    }
    guard let targetLine = statusLines.reversed().first(where: { line in
        line.contains("mac-online-connect") && line.contains("source=OnlineDeviceCard")
    }) else {
        return nil
    }
    return fieldValue("identityKey", in: targetLine)
        ?? fieldValue("targetDeviceId", in: targetLine)
        ?? fieldValue("p2pDeviceId", in: targetLine)
}()

func stableIdentityPayload(from identity: String) -> String? {
    let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lowercased = trimmed.lowercased()
    if lowercased.hasPrefix("id:") {
        let payload = String(trimmed.dropFirst("id:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload.lowercased()
    }
    if trimmed.range(
        of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
        options: .regularExpression
    ) != nil {
        return trimmed.lowercased()
    }
    return nil
}

func identityVariants(for identity: String?) -> Set<String> {
    guard let identity else { return [] }
    let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let lowercased = trimmed.lowercased()
    var variants = Set<String>()
    variants.insert(trimmed)
    variants.insert(lowercased)
    if let stable = stableIdentityPayload(from: trimmed) {
        variants.insert(stable)
        variants.insert("id:\(stable)")
        if !lowercased.hasPrefix("id:") {
            variants.insert("id:\(trimmed)")
        }
    }
    return variants
}

let targetIdentityVariants = identityVariants(for: targetIdentity)

func identityValueMatchesTarget(_ value: String?) -> Bool {
    guard !targetIdentityVariants.isEmpty else { return false }
    return !identityVariants(for: value).isDisjoint(with: targetIdentityVariants)
}

let targetRowEvidenceLine: String? = statusLines.reversed().first { line in
    guard line.contains("mac-online-device-ui"),
          line.contains("source=OnlineDeviceCard") else {
        return false
    }
    guard targetIdentity != nil else { return true }
    return identityValueMatchesTarget(fieldValue("identityKey", in: line))
        || identityValueMatchesTarget(fieldValue("targetDeviceId", in: line))
        || identityValueMatchesTarget(fieldValue("p2pDeviceId", in: line))
}

func normalizedAXText(_ value: String) -> String {
    value
        .replacingOccurrences(of: "_", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
}

let targetDeviceNames: Set<String> = {
    let rawValues = [
        targetNameFromEnvironment,
        targetRowEvidenceLine.flatMap { fieldValue("device", in: $0) }
    ].compactMap { $0 }
    var variants: [String] = []
    for raw in rawValues {
        variants.append(raw)
        variants.append(raw.replacingOccurrences(of: "_", with: " "))
    }
    return Set(variants.map(normalizedAXText).filter { !$0.isEmpty && $0 != "-" })
}()

func appendStatus(_ body: String) {
    guard let statusPath else { return }
    let rendered = "[\(ISO8601DateFormatter().string(from: Date()))] \(body)\n"
    guard let data = rendered.data(using: .utf8) else {
        return
    }
    let flags = O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW
    let fd = open(statusPath, flags, mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH))
    guard fd >= 0 else { return }
    defer { close(fd) }

    var metadata = stat()
    guard fstat(fd, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG else {
        return
    }

    data.withUnsafeBytes { rawBuffer in
        guard var current = rawBuffer.baseAddress else { return }
        var remaining = rawBuffer.count
        while remaining > 0 {
            let written = write(fd, current, remaining)
            if written <= 0 {
                break
            }
            current = current.advanced(by: written)
            remaining -= written
        }
    }
}

let root = AXUIElementCreateApplication(app.processIdentifier)

func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var result: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
    guard error == .success else { return nil }
    return result as AnyObject?
}

func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
    value(element, attribute) as? String
}

func textValues(of element: AXUIElement) -> [String] {
    [
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
        kAXHelpAttribute as String
    ].compactMap { stringValue(element, $0) }
}

func children(of element: AXUIElement) -> [AXUIElement] {
    let childAttributes = [kAXWindowsAttribute as String, kAXChildrenAttribute as String]
    for attribute in childAttributes {
        if let values = value(element, attribute) as? [AXUIElement], !values.isEmpty {
            return values
        }
    }
    return []
}

func subtreeText(of element: AXUIElement, depth: Int = 0) -> String {
    guard depth < 16 else { return "" }
    var values = textValues(of: element)
    for child in children(of: element) {
        let childText = subtreeText(of: child, depth: depth + 1)
        if !childText.isEmpty {
            values.append(childText)
        }
    }
    return values.joined(separator: " ")
}

func appendConnectedResult() {
    let identity = targetIdentity
        ?? targetRowEvidenceLine.flatMap { fieldValue("identityKey", in: $0) }
        ?? "ax-visible-ipad-row"
    var fields = [
        "mac-online-connect-result",
        "action=button",
        "targetFamily=ipad",
        "result=success",
        "source=OnlineDeviceCard",
        "evidenceSource=external-ax",
        "observer=accessibility",
        "targetRowBound=1",
        "status=connected",
        "identityKey=\(identity)"
    ]
    if let rowLine = targetRowEvidenceLine {
        for key in [
            "targetDeviceId",
            "p2pDeviceId",
            "pubKeyFP",
            "buttonEnabledAtClick",
            "disabledReason"
        ] {
            if let value = fieldValue(key, in: rowLine) {
                fields.append("\(key)=\(value)")
            }
        }
    }
    appendStatus(fields.joined(separator: " "))
}

func connectedTargetRowExists(in element: AXUIElement, depth: Int = 0) -> Bool {
    guard depth < 12 else { return false }
    let normalizedText = normalizedAXText(subtreeText(of: element))
    let containsTarget = !targetDeviceNames.isEmpty && targetDeviceNames.contains { normalizedText.contains($0) }
    let containsConnected = normalizedText.contains("已连接") || normalizedText.contains("connected")
    if containsTarget && containsConnected {
        appendConnectedResult()
        return true
    }
    return children(of: element).contains { connectedTargetRowExists(in: $0, depth: depth + 1) }
}

guard connectedTargetRowExists(in: root) else {
    fail("target iPad row has not reached connected state yet")
}
SWIFT
}

wait_for_mac_online_connected_row() {
  local timeout_seconds="$1"
  local started_at
  started_at="$(date +%s)"
  while true; do
    if [[ -f "$MAC_ONLINE_STATUS" ]] \
      && grep -qE 'bootstrap-control-waiting .*reason=local-network-permission-denied|bootstrap-control-failed .*reason=local-network-permission-denied' "$MAC_ONLINE_STATUS"; then
      printf '%s failed stage=mac-online-ipad phase=app-local-network-privacy reason=local-network-permission-denied identityKey=%s\n' "$(timestamp_utc)" "$IOS_PQC_DEVICE_ID" >>"$MAC_ONLINE_STATUS"
      sync_mac_online_launch_stdio
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STATUS"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDERR"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDERR"
      return 1
    fi
    if mac_online_app_reports_connected_after_ax_click; then
      append_mac_online_app_connected_result
      sync_mac_online_launch_stdio
      return 0
    fi
    if SKYBRIDGE_SMOKE_STATUS_FILE="$MAC_ONLINE_STATUS" \
      SKYBRIDGE_MAC_ONLINE_APP_PID="$MAC_ONLINE_PID" \
      SKYBRIDGE_TARGET_IPAD_IDENTITY="$IOS_PQC_DEVICE_ID" \
      SKYBRIDGE_TARGET_IPAD_NAME="${SKYBRIDGE_SMOKE_IOS_TARGET_NAME:-iPad}" \
      observe_mac_online_ipad_connected_row >>"$MAC_ONLINE_STDOUT" 2>&1; then
      return 0
    fi
    if [[ -n "$MAC_ONLINE_PID" ]] && ! skybridge_mac_owned_process_status \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$MAC_ONLINE_PID" \
      "$MAC_ONLINE_PROCESS_IDENTITY"; then
      wait "$MAC_ONLINE_PID" >/dev/null 2>&1 || true
      MAC_ONLINE_PID=""
      printf '%s mac-online-connect-result action=button targetFamily=ipad result=failure source=OnlineDeviceCard evidenceSource=external-ax observer=accessibility status=process-exited identityKey=%s\n' "$(timestamp_utc)" "$IOS_PQC_DEVICE_ID" >>"$MAC_ONLINE_STATUS"
      sync_mac_online_launch_stdio
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STATUS"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDERR"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDERR"
      return 1
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      printf '%s mac-online-connect-result action=button targetFamily=ipad result=failure source=OnlineDeviceCard evidenceSource=external-ax observer=accessibility status=connected-row-timeout identityKey=%s\n' "$(timestamp_utc)" "$IOS_PQC_DEVICE_ID" >>"$MAC_ONLINE_STATUS"
      sync_mac_online_launch_stdio
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STATUS"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDERR"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDOUT"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_APP_STDERR"
      return 1
    fi
    sleep 1
  done
}

mac_online_app_reports_connected_after_ax_click() {
  [[ -f "$MAC_ONLINE_STATUS" ]] || return 1
  grep -qE 'mac-online-connect action=button .*targetFamily=ipad .*source=OnlineDeviceCard .*clickSource=accessibility .*targetRowBound=1' "$MAC_ONLINE_STATUS" \
    || return 1
  grep -qE 'mac-online-connect-start .*targetFamily=ipad .*source=OnlineDeviceCard .*evidenceSource=external-ax' "$MAC_ONLINE_STATUS" \
    || return 1
  grep -qE 'mac-online-connect-app action=button .*targetFamily=ipad .*result=success .*source=OnlineDeviceCard' "$MAC_ONLINE_STATUS" \
    || return 1
  grep -qE 'mac-online-device-ui .*targetFamily=ipad .*source=OnlineDeviceCard .*status=connected' "$MAC_ONLINE_STATUS" \
    || return 1
}

append_mac_online_app_connected_result() {
  if grep -qE 'mac-online-connect-result action=button .*targetFamily=ipad .*result=success' "$MAC_ONLINE_STATUS"; then
    return 0
  fi
  local identity="$IOS_PQC_DEVICE_ID"
  local row_line
  row_line="$(grep -E 'mac-online-device-ui .*targetFamily=ipad .*source=OnlineDeviceCard .*status=connected' "$MAC_ONLINE_STATUS" | tail -n 1 || true)"
  local pub_key_fp="-"
  if [[ "$row_line" =~ pubKeyFP=([^[:space:]]+) ]]; then
    pub_key_fp="${BASH_REMATCH[1]}"
  fi
  printf '%s mac-online-connect-result action=button targetFamily=ipad result=success source=OnlineDeviceCard evidenceSource=app-smoke observer=app-status-after-ax-click targetRowBound=1 status=connected identityKey=%s pubKeyFP=%s\n' \
    "$(timestamp_utc)" \
    "$identity" \
    "$pub_key_fp" \
    >>"$MAC_ONLINE_STATUS"
}

latest_mac_online_ipad_control_route() {
  python3 - "$MAC_ONLINE_STATUS" "$IOS_PQC_DEVICE_ID" <<'PY'
import re
import sys

status_path, target_identity = sys.argv[1], sys.argv[2]

def field(line, key):
    match = re.search(rf"(?:^|\s){re.escape(key)}=([^\s]+)", line)
    return match.group(1) if match else None

def variants(value):
    if not value:
        return set()
    raw = value.strip()
    if not raw:
        return set()
    lowered = raw.lower()
    result = {raw, lowered}
    if lowered.startswith("id:"):
        payload = raw[3:].strip().lower()
        if payload:
            result.add(payload)
            result.add(f"id:{payload}")
    elif re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", raw):
        result.add(f"id:{lowered}")
    return result

target_variants = variants(target_identity)
try:
    with open(status_path, "r", encoding="utf-8") as handle:
        lines = handle.read().splitlines()
except OSError:
    raise SystemExit(1)

for line in reversed(lines):
    if "mac-online-device-ui" not in line:
        continue
    if "targetFamily=ipad" not in line or "source=OnlineDeviceCard" not in line:
        continue
    if "status=online" not in line or "buttonEnabled=1" not in line:
        continue
    if target_variants:
        row_variants = set()
        for key in ("identityKey", "targetDeviceId", "p2pDeviceId"):
            row_variants.update(variants(field(line, key)))
        if row_variants.isdisjoint(target_variants):
            continue
    host = field(line, "endpointHost")
    port = field(line, "endpointPort")
    if not port or not port.isdigit() or int(port) <= 0:
        continue
    if host and host != "-":
        print("host", host, port)
        raise SystemExit(0)
    service_name_base64 = field(line, "bonjourServiceNameBase64")
    if service_name_base64 and service_name_base64 != "-":
        print("bonjour", service_name_base64, port)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

authenticated_forward_ipad_control_host() {
  python3 \
    "$ROOT_DIR/Scripts/extract_authenticated_p2p_route.py" \
    "$HOST_STATUS" \
    "$IOS_PQC_DEVICE_ID"
}

bonjour_control_route_reachable() {
  local service_name_base64="$1"
  local probe_error="$2"
  local service_name
  service_name="$(python3 - "$service_name_base64" <<'PY'
import base64
import sys

try:
    decoded = base64.b64decode(sys.argv[1], validate=True).decode("utf-8")
except (ValueError, UnicodeDecodeError):
    raise SystemExit(1)
if not decoded or "\x00" in decoded:
    raise SystemExit(1)
print(decoded)
PY
)" || return 1

  run_stdin_command_with_hard_timeout 8 "$XCODE_SWIFT_BIN" - "$service_name" > /dev/null 2>"$probe_error" <<'SWIFT'
import Darwin
import Foundation
import Network

guard CommandLine.arguments.count == 2 else {
    fputs("invalid service-name arguments\n", stderr)
    exit(2)
}

let serviceName = CommandLine.arguments[1]
let parameters = NWParameters.tcp
parameters.includePeerToPeer = true
parameters.requiredInterfaceType = .wifi
let endpoint = NWEndpoint.service(
    name: serviceName,
    type: "_skybridge._tcp",
    domain: "local.",
    interface: nil
)
let connection = NWConnection(to: endpoint, using: parameters)
let completion = DispatchSemaphore(value: 0)
final class BonjourControlProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var succeeded = false

    func finish(_ result: Bool, detail: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        succeeded = result
        if let detail {
            fputs("\(detail)\n", stderr)
        }
        return true
    }

    func result() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return succeeded
    }
}
let probeState = BonjourControlProbeState()

connection.stateUpdateHandler = { state in
    switch state {
    case .ready:
        if probeState.finish(true) { completion.signal() }
    case .failed(let error):
        if probeState.finish(false, detail: "NWConnection failed: \(error)") { completion.signal() }
    case .cancelled:
        if probeState.finish(false, detail: "NWConnection cancelled before ready") { completion.signal() }
    default:
        break
    }
}
connection.start(queue: DispatchQueue(label: "com.skybridge.smoke.bonjour-control-probe"))
if completion.wait(timeout: .now() + 5) == .timedOut {
    _ = probeState.finish(false, detail: "NWConnection timed out waiting for Bonjour control connection readiness")
}
connection.cancel()
exit(probeState.result() ? 0 : 1)
SWIFT
}

ios_listener_ready_for_control_port() {
  local port="$1"
  copy_ios_app_cache_file "$IOS_LISTENER_STATUS_NAME" "$IOS_LISTENER_STATUS_LOCAL" "listener-status" >/dev/null 2>&1 || true
  python3 - "$port" "$IOS_LISTENER_STATUS_LOCAL" <<'PY'
import os
import re
import sys

port = sys.argv[1]
latest = None
lifecycle_pattern = re.compile(r"\bp2p-listener\s+(ready|stopped|failed|cancelled|unhealthy)\b")
for path in sys.argv[2:]:
    if not path or not os.path.exists(path):
        continue
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if lifecycle_pattern.search(line):
                    latest = line.strip()
    except OSError:
        continue

if latest is None:
    raise SystemExit(1)

if (
    re.search(r"\bp2p-listener\s+ready\b", latest)
    and re.search(rf"\bactualPort={re.escape(port)}(?:\s|$)", latest)
    and re.search(r"\bhandlerInstalled=1(?:\s|$)", latest)
):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

verify_ipad_control_port_reachable_from_mac() {
  local started_at
  local endpoint=""
  local route_kind=""
  local route_value=""
  local host=""
  local port=""
  local probe_error="$ARTIFACT_DIR/ipad-control-port-probe.stderr.log"
  local authenticated_probe_error="$ARTIFACT_DIR/ipad-authenticated-forward-port-probe.stderr.log"
  local authenticated_route_error="$ARTIFACT_DIR/ipad-authenticated-forward-route.stderr.log"
  local detail=""
  local listener_ready=0
  local primary_reachable=0
  local authenticated_host=""
  local tcp_reachable_without_listener=0
  started_at="$(date +%s)"

  while true; do
    endpoint="$(latest_mac_online_ipad_control_route 2>/dev/null || true)"
    if [[ -n "$endpoint" ]]; then
      read -r route_kind route_value port <<<"$endpoint"
      if [[ "$route_kind" == "host" ]]; then
        host="$route_value"
      else
        host="bonjour-service"
      fi
      if ios_listener_ready_for_control_port "$port"; then
        listener_ready=1
      else
        listener_ready=0
      fi
      primary_reachable=0
      : >"$probe_error"
      if [[ "$route_kind" == "host" ]]; then
        if tcp_port_reachable "$route_value" "$port" "$probe_error"; then
          primary_reachable=1
        fi
      elif [[ "$route_kind" == "bonjour" ]]; then
        if bonjour_control_route_reachable "$route_value" "$probe_error"; then
          primary_reachable=1
        fi
      fi

      if [[ "$primary_reachable" == "1" ]]; then
        if [[ "$listener_ready" == "1" ]]; then
          printf '%s ipad-control-port reachable=1 host=%s port=%s identityKey=%s targetDeviceId=%s source=pre-mac-online-probe probe=tcp-only listenerReady=1 routeKind=%s\n' "$(timestamp_utc)" "$host" "$port" "$IOS_PQC_DEVICE_ID" "$IOS_PQC_DEVICE_ID" "$route_kind" >>"$MAC_ONLINE_STATUS"
          return 0
        fi
        tcp_reachable_without_listener=1
        detail="listener-not-ready"
        printf '%s ipad-control-port reachable=0 host=%s port=%s identityKey=%s targetDeviceId=%s source=pre-mac-online-probe probe=tcp-only listenerReady=0 routeKind=%s reason=listener-not-ready\n' "$(timestamp_utc)" "$host" "$port" "$IOS_PQC_DEVICE_ID" "$IOS_PQC_DEVICE_ID" "$route_kind" >>"$MAC_ONLINE_STATUS"
      else
        detail="$(redacted_last_log_line "$probe_error")"
        printf '%s ipad-control-route-observation routeKind=%s reachable=0 host=%s port=%s identityKey=%s targetDeviceId=%s source=pre-mac-online-probe listenerReady=%s detail=%s\n' "$(timestamp_utc)" "$route_kind" "$host" "$port" "$IOS_PQC_DEVICE_ID" "$IOS_PQC_DEVICE_ID" "$listener_ready" "${detail:-unknown}" >>"$MAC_ONLINE_STATUS"

        : >"$authenticated_route_error"
        authenticated_host="$(authenticated_forward_ipad_control_host 2>"$authenticated_route_error" || true)"
        if [[ -z "$authenticated_host" ]]; then
          detail="$(redacted_last_log_line "$authenticated_route_error")"
          printf '%s ipad-control-route-observation routeKind=authenticated-forward-peer reachable=0 host=unavailable port=%s identityKey=%s targetDeviceId=%s source=operator-approved-xwing-forward-session listenerReady=%s bonjourReachable=0 detail=%s\n' "$(timestamp_utc)" "$port" "$IOS_PQC_DEVICE_ID" "$IOS_PQC_DEVICE_ID" "$listener_ready" "${detail:-target_bound_route_unavailable}" >>"$MAC_ONLINE_STATUS"
        elif [[ "$route_kind" == "host" && "$authenticated_host" == "$route_value" ]]; then
          printf '%s ipad-control-route-observation routeKind=authenticated-forward-peer reachable=0 host=%s port=%s identityKey=%s targetDeviceId=%s source=operator-approved-xwing-forward-session listenerReady=%s detail=same_unreachable_route_as_online_row\n' "$(timestamp_utc)" "$authenticated_host" "$port" "$IOS_PQC_DEVICE_ID" "$IOS_PQC_DEVICE_ID" "$listener_ready" >>"$MAC_ONLINE_STATUS"
        else
          : >"$authenticated_probe_error"
          if tcp_port_reachable "$authenticated_host" "$port" "$authenticated_probe_error"; then
            printf '%s ipad-control-route-observation routeKind=authenticated-forward-peer reachable=1 host=%s port=%s identityKey=%s targetDeviceId=%s source=operator-approved-xwing-forward-session listenerReady=%s bonjourReachable=0\n' "$(timestamp_utc)" "$authenticated_host" "$port" "$IOS_PQC_DEVICE_ID" "$IOS_PQC_DEVICE_ID" "$listener_ready" >>"$MAC_ONLINE_STATUS"
            if [[ "$listener_ready" == "1" ]]; then
              printf '%s ipad-control-port reachable=1 host=%s port=%s identityKey=%s targetDeviceId=%s source=pre-mac-online-probe probe=tcp-only listenerReady=1 routeKind=authenticated-forward-peer bonjourReachable=0 routeEvidence=operator-approved-xwing-forward-session\n' "$(timestamp_utc)" "$authenticated_host" "$port" "$IOS_PQC_DEVICE_ID" "$IOS_PQC_DEVICE_ID" >>"$MAC_ONLINE_STATUS"
              return 0
            fi
            tcp_reachable_without_listener=1
            detail="listener-not-ready"
          else
            detail="$(redacted_last_log_line "$authenticated_probe_error")"
            printf '%s ipad-control-route-observation routeKind=authenticated-forward-peer reachable=0 host=%s port=%s identityKey=%s targetDeviceId=%s source=operator-approved-xwing-forward-session listenerReady=%s bonjourReachable=0 detail=%s\n' "$(timestamp_utc)" "$authenticated_host" "$port" "$IOS_PQC_DEVICE_ID" "$IOS_PQC_DEVICE_ID" "$listener_ready" "${detail:-unknown}" >>"$MAC_ONLINE_STATUS"
          fi
        fi
      fi
    fi

    if (( "$(date +%s)" - started_at >= 20 )); then
      if [[ "$tcp_reachable_without_listener" == "1" ]]; then
        printf '%s failed stage=mac-online-ipad phase=ipad-control-port-probe reason=listener-not-ready targetDeviceId=%s port=%s detail=%s\n' "$(timestamp_utc)" "$IOS_PQC_DEVICE_ID" "${port:-unknown}" "${detail:-listener-not-ready}" >>"$MAC_ONLINE_STATUS"
      else
        printf '%s failed stage=mac-online-ipad phase=ipad-control-port-probe reason=tcp-unreachable targetDeviceId=%s port=%s detail=%s\n' "$(timestamp_utc)" "$IOS_PQC_DEVICE_ID" "${port:-unknown}" "${detail:-no_endpoint_or_timeout}" >>"$MAC_ONLINE_STATUS"
      fi
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STATUS"
      print_smoke_tail_for_operator 80 "$IOS_STATUS_CONSOLE_LIVE"
      return 1
    fi
    sleep 1
  done
}

validate_mac_online_product_p2p_path() {
  python3 - "$MAC_ONLINE_STATUS" "$IOS_PQC_DEVICE_ID" <<'PY'
import re
import sys

status_path, target_device_id = sys.argv[1:]

def field(line, key):
    match = re.search(rf"(?:^|\s){re.escape(key)}=([^\s]+)", line)
    return match.group(1) if match else None

def canonical_device_id(raw):
    if raw is None:
        return None
    value = raw.strip().lower()
    if value.startswith("id:"):
        value = value[3:]
    return value or None

with open(status_path, "r", encoding="utf-8", errors="strict") as handle:
    lines = handle.read().splitlines()

connect_start_indexes = [
    index
    for index, line in enumerate(lines)
    if "mac-online-connect-start" in line
    and "targetFamily=ipad" in line
    and "evidenceSource=external-ax" in line
]
if not connect_start_indexes:
    raise SystemExit("missing target-bound Mac online connect-start evidence")
connect_start_index = connect_start_indexes[-1]
target = canonical_device_id(target_device_id)

for line in reversed(lines[connect_start_index + 1 :]):
    if "p2p-connection-ready-path" not in line:
        continue
    if canonical_device_id(field(line, "deviceId")) != target:
        continue
    path_status = field(line, "pathStatus")
    route_class = field(line, "routeClass")
    attached = field(line, "attached")
    link_local = field(line, "linkLocal")
    interface_types = set((field(line, "usedInterfaceTypes") or "").lower().split(","))
    if path_status != "satisfied":
        raise SystemExit("target product P2P path is not satisfied")
    if route_class not in {"wifi", "awdl"}:
        raise SystemExit(f"target product P2P path is not Wi-Fi/AWDL: {route_class}")
    if attached != "0" or "wiredethernet" in interface_types:
        raise SystemExit("target product P2P path used an attached or wired interface")
    if link_local != "0":
        raise SystemExit("target product P2P path used a link-local address")
    print(
        "Mac online product P2P path passed: "
        f"routeClass={route_class} interfaceTypes={','.join(sorted(interface_types))}"
    )
    raise SystemExit(0)

raise SystemExit("missing target-bound product P2P currentPath evidence")
PY
}

transition_to_mac_online_ipad_client() {
  local helper_was_registered="${MAC_HOST_HELPER_REGISTERED:-0}"

  if [[ -n "$MAC_SOURCE_PID" ]]; then
    if ! skybridge_mac_terminate_owned_process \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$MAC_SOURCE_PID" \
      "$MAC_SOURCE_PROCESS_IDENTITY" \
      "macOS P2P smoke source"; then
      echo "Unable to stop the run-owned macOS smoke source before the reverse product launch." >&2
      return 1
    fi
    MAC_SOURCE_PID=""
  fi
  if [[ -n "$HOST_PID" ]]; then
    if ! skybridge_mac_terminate_owned_process \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$HOST_PID" \
      "$MAC_HOST_PROCESS_IDENTITY" \
      "macOS P2P smoke host"; then
      echo "Unable to stop the run-owned macOS host before the reverse product launch." >&2
      return 1
    fi
    HOST_PID=""
  fi
  if ! sync_macos_smoke_host_artifacts; then
    echo "Unable to persist the completed iOS-to-Mac evidence before the reverse product launch." >&2
    return 1
  fi
  if [[ "$helper_was_registered" == "1" ]]; then
    if ! cleanup_macos_smoke_host_launch_services_registration; then
      echo "Unable to remove the temporary host registration before launching the canonical product." >&2
      return 1
    fi
    if ! restore_canonical_macos_launch_services_registration_last; then
      echo "Unable to restore the canonical product registration before the reverse product launch." >&2
      return 1
    fi
  fi
  append_host_status "mac-online-transition hostStopped=1 sourceStopped=1 temporaryRegistrationAbsent=1 canonicalRegistrationRestored=$helper_was_registered"
}

run_mac_online_ipad_button_smoke() {
  mkdir -p "$MAC_ONLINE_RUNTIME_DIR"
  : >"$MAC_ONLINE_STATUS"
  : >"$MAC_ONLINE_STATUS_ARTIFACT"
  transition_to_mac_online_ipad_client
  build_macos_online_ipad_app
  require_no_external_macos_online_ipad_clients
  load_ios_pqc_report_for_mac_online
  echo "==> Starting macOS online iPad UI client"
  printf '%s launch requested role=mac-online-ipad-client process=SkyBridgeCompassApp uiRole=external-accessibility method=open-app-bundle\n' "$(timestamp_utc)" >>"$MAC_ONLINE_STATUS"
  start_macos_online_ipad_client
  wait_for_mac_online_pattern 'boot .*role=mac-online-ipad-client .*source=app' 20 "macOS online iPad app smoke role boot"
  wait_for_mac_online_pattern 'mac-online-device-ui .*targetFamily=ipad .*source=OnlineDeviceCard .*status=online .*buttonEnabled=1' "$MAC_ONLINE_VISIBLE_CONNECTABLE_TIMEOUT_SECONDS" "macOS online iPad visible connectable row"
  verify_ipad_control_port_reachable_from_mac

  echo "==> Pressing macOS online iPad Connect button"
  local click_started_at
  click_started_at="$(date +%s)"
  while true; do
    if SKYBRIDGE_SMOKE_STATUS_FILE="$MAC_ONLINE_STATUS" \
      SKYBRIDGE_MAC_ONLINE_APP_PID="$MAC_ONLINE_PID" \
      SKYBRIDGE_TARGET_IPAD_IDENTITY="$IOS_PQC_DEVICE_ID" \
      SKYBRIDGE_TARGET_IPAD_NAME="${SKYBRIDGE_SMOKE_IOS_TARGET_NAME:-iPad}" \
      press_mac_online_ipad_connect_button >>"$MAC_ONLINE_STDOUT" 2>&1; then
      break
    fi
    if (( "$(date +%s)" - click_started_at >= SMOKE_TIMEOUT_SECONDS )); then
      printf '%s failed stage=mac-online-ipad phase=ui-click reason=accessibility-click-failed\n' "$(timestamp_utc)" >>"$MAC_ONLINE_STATUS"
      print_smoke_tail_for_operator 80 "$MAC_ONLINE_STDOUT"
      return 1
    fi
    sleep 1
  done

  wait_for_mac_online_pattern 'mac-online-connect action=button .*source=OnlineDeviceCard .*clickSource=accessibility .*targetRowBound=1 .*axMatch=(target-identifier|target-row-title)' 30 "macOS online iPad real button click evidence"
  wait_for_mac_online_pattern 'mac-online-connect-start .*targetFamily=ipad .*source=OnlineDeviceCard .*evidenceSource=external-ax' 30 "macOS online iPad connect start from clicked row"
  wait_for_mac_online_pattern 'p2p-connection-ready-path .*pathStatus=satisfied .*routeClass=(wifi|awdl) .*attached=0 .*linkLocal=0' "$SMOKE_TIMEOUT_SECONDS" "macOS-to-iOS product Wi-Fi/AWDL P2P path"
  validate_mac_online_product_p2p_path
  wait_for_mac_online_pattern "mac remote established .*suite=${EXPECTED_TARGET_SUITE}" "$SMOKE_TIMEOUT_SECONDS" "macOS-to-iOS authenticated ${EXPECTED_TARGET_SUITE} remote-control handshake"
  wait_for_ios_status_pattern "p2p-inbound handshake-established .*suite=${EXPECTED_TARGET_SUITE}" "$SMOKE_TIMEOUT_SECONDS" "iOS inbound ${EXPECTED_TARGET_SUITE} P2P handshake"
  wait_for_ios_status_pattern "lan-remote handshake-established .*suite=${EXPECTED_TARGET_SUITE}" "$SMOKE_TIMEOUT_SECONDS" "iOS inbound ${EXPECTED_TARGET_SUITE} remote-control handshake"
  MAC_TO_IOS_CRYPTO_HANDSHAKE_COMPLETE=1
  wait_for_mac_online_connected_row "$SMOKE_TIMEOUT_SECONDS"
  sync_mac_online_launch_stdio
  if ! grep -qE 'mac-online-connect-result .*targetFamily=ipad .*result=success' "$MAC_ONLINE_STATUS_ARTIFACT"; then
    printf '%s failed stage=mac-online-ipad phase=status-sync reason=status-sync-missing-success identityKey=%s\n' "$(timestamp_utc)" "$IOS_PQC_DEVICE_ID" >>"$MAC_ONLINE_STATUS"
    sync_mac_online_launch_stdio
    print_smoke_tail_for_operator 80 "$MAC_ONLINE_STATUS"
    return 1
  fi
}

fail_if_host_exited() {
  local label="$1"
  if [[ -n "$HOST_PID" ]] && ! skybridge_mac_owned_process_status \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$HOST_PID" \
    "$MAC_HOST_PROCESS_IDENTITY"; then
    append_host_status "failed stage=mac-host phase=process-exited label=${label// /_}"
    echo "macOS host process exited while waiting for ${label}: ${HOST_STATUS}" >&2
    echo "---- macOS status tail ($HOST_STATUS) ----" >&2
    print_smoke_tail_for_operator 80 "$HOST_STATUS"
    echo "---- host stdout tail ($HOST_STDOUT) ----" >&2
    print_smoke_tail_for_operator 80 "$HOST_STDOUT"
    return 1
  fi
}

fail_if_smoke_source_exited() {
  local label="$1"
  if [[ -n "$MAC_SOURCE_PID" ]] && ! skybridge_mac_owned_process_status \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$MAC_SOURCE_PID" \
    "$MAC_SOURCE_PROCESS_IDENTITY"; then
    append_host_status "failed stage=mac-smoke-source phase=process-exited label=${label// /_}"
    echo "macOS smoke source helper exited while waiting for ${label}: ${HOST_STATUS}" >&2
    echo "---- macOS status tail ($HOST_STATUS) ----" >&2
    print_smoke_tail_for_operator 80 "$HOST_STATUS"
    echo "---- smoke source stdout tail ($MAC_SOURCE_STDOUT) ----" >&2
    print_smoke_tail_for_operator 80 "$MAC_SOURCE_STDOUT"
    return 1
  fi
}

fail_if_smoke_source_stale() {
  local label="$1"
  local max_age_seconds="${2:-15}"
  if [[ -z "$MAC_SOURCE_PID" ]] || [[ ! -f "$HOST_STATUS" ]]; then
    return 0
  fi

  local freshness
  set +e
  freshness="$(python3 - "$HOST_STATUS" "$max_age_seconds" <<'PY'
from datetime import datetime, timezone
import sys

path = sys.argv[1]
max_age = float(sys.argv[2])
last_timestamp = None
with open(path, "r", encoding="utf-8", errors="replace") as handle:
    for line in reversed(handle.readlines()):
        if "smoke-capture-source active=1" not in line:
            continue
        if not line.startswith("[") or "]" not in line:
            print("unparseable")
            sys.exit(2)
        raw = line[1:line.index("]")]
        try:
            last_timestamp = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            print("unparseable")
            sys.exit(2)
        break

if last_timestamp is None:
    print("missing")
    sys.exit(3)

now = datetime.now(timezone.utc)
age = (now - last_timestamp.astimezone(timezone.utc)).total_seconds()
print(f"{age:.1f}")
if age > max_age:
    sys.exit(4)
PY
)"
  local status=$?
  set -e
  if (( status != 0 )); then
    append_host_status "failed stage=mac-smoke-source phase=heartbeat-stale label=${label// /_} ageSeconds=${freshness:-unknown} budgetSeconds=$max_age_seconds"
    echo "macOS smoke source heartbeat is stale while waiting for ${label}: ageSeconds=${freshness:-unknown}, budgetSeconds=${max_age_seconds}" >&2
    echo "---- macOS status tail ($HOST_STATUS) ----" >&2
    print_smoke_tail_for_operator 80 "$HOST_STATUS"
    echo "---- smoke source stdout tail ($MAC_SOURCE_STDOUT) ----" >&2
    print_smoke_tail_for_operator 80 "$MAC_SOURCE_STDOUT"
    return 1
  fi
}

verify_mac_control_port_reachable() {
  local host="$1"
  local port="$2"
  local started_at
  local probe_error="$ARTIFACT_DIR/mac-control-port-probe.stderr.log"
  started_at="$(date +%s)"

  while true; do
    if tcp_port_reachable "$host" "$port" "$probe_error"
    then
      append_host_status "mac-control-port reachable=1 host=$host port=$port source=local-self-probe"
      return 0
    fi

    fail_if_host_exited "macOS control port reachability" || return 1
    if (( "$(date +%s)" - started_at >= 10 )); then
      local detail
      detail="$(redacted_last_log_line "$probe_error")"
      append_host_status "failed stage=mac-host phase=control-port-probe reason=tcp-unreachable host=$host port=$port detail=${detail:-unknown}"
      echo "macOS host control port is not reachable before iOS launch: ${host}:${port}" >&2
      print_smoke_tail_for_operator 80 "$HOST_STATUS"
      return 1
    fi
    sleep 0.5
  done
}

verify_mac_remote_port_listening() {
  local host="$1"
  local port="$2"
  local started_at
  local probe_error="$ARTIFACT_DIR/mac-remote-port-probe.stderr.log"
  started_at="$(date +%s)"

  while true; do
    if tcp_port_reachable "$host" "$port" "$probe_error"
    then
      append_host_status "mac-remote-control-port reachable=1 host=$host port=$port source=local-self-probe"
      return 0
    fi

    fail_if_host_exited "macOS remote-control port listener" || return 1
    if (( "$(date +%s)" - started_at >= 10 )); then
      local detail
      detail="$(redacted_last_log_line "$probe_error")"
      append_host_status "failed stage=mac-host phase=remote-control-port-probe reason=tcp-unreachable host=$host port=$port detail=${detail:-unknown}"
      echo "macOS host remote-control port is not reachable before iOS launch: ${host}:${port}" >&2
      print_smoke_tail_for_operator 80 "$HOST_STATUS"
      return 1
    fi
    sleep 0.5
  done
}

verify_host_pid_owns_listener_port() {
  local port="$1"
  local label="$2"
  local owning_pids

  if [[ -z "$HOST_PID" ]] || ! skybridge_mac_owned_process_status \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$HOST_PID" \
    "$MAC_HOST_PROCESS_IDENTITY"; then
    append_host_status "failed stage=mac-host phase=listener-ownership reason=host-pid-not-running label=$label port=$port"
    return 1
  fi
  if ! owning_pids="$(/usr/sbin/lsof -nP -a -p "$HOST_PID" -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)"; then
    append_host_status "failed stage=mac-host phase=listener-ownership reason=lsof-no-listener label=$label port=$port"
    echo "macOS smoke host PID does not own the expected $label listener on port $port." >&2
    return 1
  fi
  if ! printf '%s\n' "$owning_pids" | grep -Fxq "$HOST_PID"; then
    append_host_status "failed stage=mac-host phase=listener-ownership reason=pid-mismatch label=$label port=$port"
    echo "macOS $label listener is not owned by the tracked smoke host PID." >&2
    return 1
  fi
  append_host_status "mac-listener-owned pid=$HOST_PID label=$label port=$port source=pid-socket"
}

tcp_port_reachable() {
  local host="$1"
  local port="$2"
  local probe_error="$3"
  python3 - "$host" "$port" > /dev/null 2>"$probe_error" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=1.5):
        pass
except OSError as exc:
    print(f"{type(exc).__name__}:{exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

wait_for_file_pattern() {
  local path="$1"
  local pattern="$2"
  local timeout_seconds="$3"
  local label="$4"
  local started_at
  started_at="$(date +%s)"
  while true; do
    fail_if_host_exited "$label" || return 1
    fail_if_smoke_source_exited "$label" || return 1
    if [[ -n "$IOS_CONSOLE_PID" ]] \
      && [[ -f "$IOS_STATUS_CONSOLE_LIVE" ]] \
      && grep -qE "$IOS_REMOTE_SMOKE_FAILURE_PATTERN" "$IOS_STATUS_CONSOLE_LIVE"; then
      echo "Detected iOS failure while waiting for ${label}: ${IOS_STATUS_CONSOLE_LIVE}" >&2
      print_smoke_tail_for_operator 80 "$IOS_STATUS_CONSOLE_LIVE"
      print_smoke_tail_for_operator 40 "$IOS_CONSOLE_STDERR"
      return 1
    fi
    fail_if_forbidden_fallback_evidence "$IOS_STATUS_CONSOLE_LIVE" "$label" || return 1
    if [[ "$IOS_CONSOLE_HANDLE_CAPTURED" == "1" ]] \
      && ! ios_console_handle_is_exact_and_running; then
      echo "The exact iOS console launch handle exited or became unverifiable while waiting for ${label}: ${IOS_STATUS_CONSOLE_LIVE}" >&2
      print_smoke_tail_for_operator 80 "$IOS_STATUS_CONSOLE_LIVE"
      print_smoke_tail_for_operator 80 "$IOS_CONSOLE_STDERR"
      return 1
    fi
    fail_if_host_udp_local_network_permission_denied "$label" || return 1
    if [[ -f "$HOST_STATUS" ]] && grep -qE "$HOST_REMOTE_SMOKE_FAILURE_PATTERN" "$HOST_STATUS"; then
      echo "Detected macOS host media failure while waiting for ${label}: ${HOST_STATUS}" >&2
      copy_ios_status
      echo "---- macOS status tail ($HOST_STATUS) ----" >&2
      print_smoke_tail_for_operator 80 "$HOST_STATUS"
      echo "---- iOS live console tail ($IOS_STATUS_CONSOLE_LIVE) ----" >&2
      print_smoke_tail_for_operator 80 "$IOS_STATUS_CONSOLE_LIVE"
      return 1
    fi
    fail_if_forbidden_fallback_evidence "$HOST_STATUS" "$label" || return 1
    if [[ -f "$path" ]] && grep -qE "$pattern" "$path"; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${path}" >&2
      copy_ios_status
      echo "---- iOS live console tail ($IOS_STATUS_CONSOLE_LIVE) ----" >&2
      print_smoke_tail_for_operator 80 "$IOS_STATUS_CONSOLE_LIVE"
      print_smoke_tail_for_operator 40 "$path"
      return 1
    fi
    sleep 1
  done
}

fail_if_host_udp_local_network_permission_denied() {
  local label="$1"
  local denial_pattern='audioTxSenderStartFailed .*reason=udp_local_network_permission_denied .*strict=1 .*action=strict-fail-closed'
  local failure_line='failed stage=mac-host phase=udp-local-network-privacy reason=local-network-permission-denied source=current-udp-path'

  if [[ ! -f "$HOST_STATUS" ]] || ! grep -qE "$denial_pattern" "$HOST_STATUS"; then
    return 0
  fi
  if ! grep -Fq "$failure_line" "$HOST_STATUS"; then
    append_host_status "$failure_line"
  fi
  echo "macOS denied Local Network access while waiting for ${label}. Enable SkyBridge Compass Pro in System Settings → Privacy & Security → Local Network, fully restart the app, and rerun." >&2
  print_smoke_tail_for_operator 80 "$HOST_STATUS"
  return 1
}

run_with_hard_timeout() {
  local timeout_seconds="$1"
  shift
  local pid
  local started_at
  "$@" &
  pid="$!"
  started_at="$(date +%s)"
  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 0.25
  done

  set +e
  wait "$pid"
  local exit_status="$?"
  set -e
  return "$exit_status"
}

run_stdin_command_with_hard_timeout() {
  local timeout_seconds="$1"
  shift
  python3 -c '
import subprocess
import sys

timeout_seconds = float(sys.argv[1])
command = sys.argv[2:]
input_data = sys.stdin.buffer.read()
process = subprocess.Popen(command, stdin=subprocess.PIPE)
try:
    process.communicate(input=input_data, timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    raise SystemExit(124)
raise SystemExit(process.returncode)
' "$timeout_seconds" "$@"
}

copy_ios_app_cache_file() {
  local remote_name="$1"
  local local_path="$2"
  local label="$3"
  local tmp_path="${local_path}.tmp.${BASHPID:-$$}"
  local json_log="$ARTIFACT_DIR/ios-copy-${label}.json"
  local devicectl_log="$ARTIFACT_DIR/ios-copy-${label}.log"
  local stdout_log="$ARTIFACT_DIR/ios-copy-${label}.stdout.log"
  local stderr_log="$ARTIFACT_DIR/ios-copy-${label}.stderr.log"
  local remote_path="Library/Caches/$remote_name"

  rm -f "$tmp_path" "$json_log" "$devicectl_log" "$stdout_log" "$stderr_log"
  if run_with_hard_timeout "$IOS_COPY_HARD_TIMEOUT_SECONDS" \
    xcrun devicectl device copy from \
    --device "$IOS_DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$IOS_BUNDLE_ID" \
    --source "$remote_path" \
    --destination "$tmp_path" \
    --timeout "$IOS_COPY_TIMEOUT_SECONDS" \
    --json-output "$json_log" \
    --log-output "$devicectl_log" >"$stdout_log" 2>"$stderr_log"; then
    if [[ -s "$tmp_path" ]]; then
      mv -f "$tmp_path" "$local_path"
      return 0
    fi
    echo "iOS app-cache copy produced an empty file: label=$label remote=$remote_path destination=$local_path json=$json_log log=$devicectl_log" >&2
  else
    local copy_exit="$?"
    echo "iOS app-cache copy failed: label=$label remote=$remote_path destination=$local_path exit=$copy_exit json=$json_log log=$devicectl_log stderr=$stderr_log" >&2
  fi

  rm -f "$tmp_path"
  return 1
}

copy_ios_trace() {
  copy_ios_app_cache_file "$IOS_TRACE_NAME" "$IOS_TRACE_LOCAL" "trace"
}

copy_ios_status() {
  local merged_tmp="${IOS_STATUS_LOCAL}.tmp.${BASHPID:-$$}"

  if [[ -f "$IOS_STATUS_CONSOLE_LIVE" ]]; then
    cp "$IOS_STATUS_CONSOLE_LIVE" "$IOS_STATUS_CONSOLE_SNAPSHOT" 2>/dev/null || true
  else
    rm -f "$IOS_STATUS_CONSOLE_SNAPSHOT"
  fi

  if [[ "$IOS_COPY_STATUS_APP_CACHE" == "1" || ! -s "$IOS_STATUS_CONSOLE_SNAPSHOT" ]]; then
    copy_ios_app_cache_file "$IOS_STATUS_NAME" "$IOS_STATUS_APP_CACHE_LOCAL" "status" || true
  fi

  if [[ -f "$IOS_STATUS_CONSOLE_SNAPSHOT" && -s "$IOS_STATUS_APP_CACHE_LOCAL" ]]; then
    {
      printf '%s\n' "# source=devicectl-console"
      sed -n 'p' "$IOS_STATUS_CONSOLE_SNAPSHOT"
      printf '\n'
      printf '%s\n' "# source=app-cache"
      sed -n 'p' "$IOS_STATUS_APP_CACHE_LOCAL"
    } >"$merged_tmp"
    mv "$merged_tmp" "$IOS_STATUS_LOCAL"
  elif [[ -s "$IOS_STATUS_APP_CACHE_LOCAL" ]]; then
    cp "$IOS_STATUS_APP_CACHE_LOCAL" "$IOS_STATUS_LOCAL" 2>/dev/null || true
  elif [[ -s "$IOS_STATUS_CONSOLE_SNAPSHOT" ]]; then
    cp "$IOS_STATUS_CONSOLE_SNAPSHOT" "$IOS_STATUS_LOCAL" 2>/dev/null || true
  else
    rm -f "$merged_tmp"
    return 1
  fi
}

materialize_ios_pqc_report_from_app_authored_status() {
  local status_source="$IOS_STATUS_APP_CACHE_LOCAL"
  if [[ ! -s "$status_source" ]]; then
    status_source="$IOS_STATUS_CONSOLE_LIVE"
  fi
  [[ -s "$status_source" ]] || return 1

  python3 - "$status_source" "$IOS_PQC_REPORT" <<'PY'
import base64
import json
import re
import sys

status_path, output_path = sys.argv[1:]
pattern = re.compile(r"\bpqc-report\b.*\breportJSONBase64=([A-Za-z0-9+/=]+)")

try:
    with open(status_path, "r", encoding="utf-8", errors="replace") as handle:
        lines = handle.readlines()
except OSError as exc:
    print(f"unable to read iOS status for app-authored PQC report: {exc}", file=sys.stderr)
    raise SystemExit(1)

for line in reversed(lines):
    match = pattern.search(line)
    if not match:
        continue
    try:
        data = base64.b64decode(match.group(1), validate=True)
        report = json.loads(data.decode("utf-8"))
    except (ValueError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        print(f"invalid app-authored iOS PQC report in status: {exc}", file=sys.stderr)
        raise SystemExit(1)

    device_id = report.get("deviceId")
    keys = report.get("keys")
    if not isinstance(device_id, str) or not device_id.strip():
        print("app-authored iOS PQC report is missing deviceId", file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(keys, list) or not keys:
        print("app-authored iOS PQC report is missing keys", file=sys.stderr)
        raise SystemExit(1)
    for key in keys:
        if not isinstance(key, dict):
            print("app-authored iOS PQC report contains a non-object key entry", file=sys.stderr)
            raise SystemExit(1)
        if not isinstance(key.get("suiteWireId"), int):
            print("app-authored iOS PQC report key entry is missing suiteWireId", file=sys.stderr)
            raise SystemExit(1)
        public_key = key.get("publicKeyBase64")
        if not isinstance(public_key, str) or not public_key.strip():
            print("app-authored iOS PQC report key entry is missing publicKeyBase64", file=sys.stderr)
            raise SystemExit(1)

    with open(output_path, "w", encoding="utf-8") as output:
        json.dump(report, output, indent=2, sort_keys=True)
        output.write("\n")
    print(f"iOS PQC report materialized from app-authored status: device={device_id} keys={len(keys)}")
    raise SystemExit(0)

raise SystemExit(1)
PY
}

load_ios_pqc_report_for_mac_online() {
  copy_ios_status

  if [[ ! -s "$IOS_PQC_REPORT" ]]; then
    materialize_ios_pqc_report_from_app_authored_status || true
  fi

  if [[ ! -s "$IOS_PQC_REPORT" ]]; then
    copy_ios_app_cache_file "$IOS_PQC_REPORT_NAME" "$IOS_PQC_REPORT" "pqc-report" || true
  fi

  if [[ ! -s "$IOS_PQC_REPORT" ]]; then
    copy_ios_status
    materialize_ios_pqc_report_from_app_authored_status || true
  fi

  if [[ ! -s "$IOS_PQC_REPORT" ]]; then
    echo "iOS PQC report is missing; cannot prove Mac online iPad button with a real trusted KEM key: $IOS_PQC_REPORT" >&2
    echo "---- iOS PQC report copy log ----" >&2
    print_smoke_tail_for_operator 80 "$ARTIFACT_DIR/ios-copy-pqc-report.log"
    print_smoke_tail_for_operator 80 "$ARTIFACT_DIR/ios-copy-pqc-report.stderr.log"
    echo "---- iOS authoritative app-cache tail ($IOS_STATUS_APP_CACHE_LOCAL) ----" >&2
    print_smoke_tail_for_operator 80 "$IOS_STATUS_APP_CACHE_LOCAL"
    return 1
  fi

  local report_data
  report_data="$(python3 - "$IOS_PQC_REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
keys = {
    int(entry.get("suiteWireId", -1)): entry.get("publicKeyBase64", "")
    for entry in report.get("keys", [])
}
print(report.get("deviceId", ""))
print(keys.get(0x0001, ""))
PY
)"
  IOS_PQC_DEVICE_ID="$(printf '%s\n' "$report_data" | sed -n '1p')"
  IOS_PQC_XWING_PUBLIC_KEY_BASE64="$(printf '%s\n' "$report_data" | sed -n '2p')"

  if [[ -z "$IOS_PQC_DEVICE_ID" || -z "$IOS_PQC_XWING_PUBLIC_KEY_BASE64" ]]; then
    echo "iOS PQC report is missing required X-Wing identity: $IOS_PQC_REPORT" >&2
    return 1
  fi
}

verify_mac_smoke_capture_source_visible() {
  local first="$MAC_SMOKE_SOURCE_FRAME_A"
  local second="$MAC_SMOKE_SOURCE_FRAME_B"
  local proof

  detect_macos_loginwindow_occlusion

  if ! command -v screencapture >/dev/null 2>&1; then
    append_host_status "failed stage=mac-host phase=smoke-source-preflight reason=missing-screencapture"
    echo "macOS screencapture command is unavailable; cannot prove the smoke source is visible before iPad launch." >&2
    return 1
  fi

  screencapture -x "$first"
  sleep 0.45
  screencapture -x "$second"

  if ! proof="$("$XCODE_SWIFT_BIN" - "$first" "$second" 2>&1 <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: swift - first.png second.png")
}

func loadImage(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("unable to decode screenshot \(path)")
    }
    return image
}

func rgbaPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    pixels.withUnsafeMutableBytes { storage in
        guard let context = CGContext(
            data: storage.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            fail("unable to allocate screenshot comparison context")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return pixels
}

let first = loadImage(CommandLine.arguments[1])
let second = loadImage(CommandLine.arguments[2])
let width = min(first.width, second.width)
let height = min(first.height, second.height)
guard width >= 160, height >= 120 else {
    fail("screenshot is too small for smoke source preflight: \(width)x\(height)")
}

let firstPixels = rgbaPixels(first, width: width, height: height)
let secondPixels = rgbaPixels(second, width: width, height: height)
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
let gridColumns = 42
let gridRows = 24
let xStart = width / 8
let xEnd = max(xStart + 1, width * 7 / 8)
let yStart = height / 8
let yEnd = max(yStart + 1, height * 7 / 8)
var changedSamples = 0
var totalSamples = 0
var deltaTotal = 0

for row in 0..<gridRows {
    let y = yStart + ((yEnd - yStart) * row / max(1, gridRows - 1))
    for column in 0..<gridColumns {
        let x = xStart + ((xEnd - xStart) * column / max(1, gridColumns - 1))
        let offset = y * bytesPerRow + x * bytesPerPixel
        let redDelta = abs(Int(firstPixels[offset]) - Int(secondPixels[offset]))
        let greenDelta = abs(Int(firstPixels[offset + 1]) - Int(secondPixels[offset + 1]))
        let blueDelta = abs(Int(firstPixels[offset + 2]) - Int(secondPixels[offset + 2]))
        let delta = redDelta + greenDelta + blueDelta
        deltaTotal += delta
        totalSamples += 1
        if delta >= 36 {
            changedSamples += 1
        }
    }
}

let changedRatio = Double(changedSamples) / Double(max(1, totalSamples))
let meanDelta = Double(deltaTotal) / Double(max(1, totalSamples))
print(String(format: "changedRatio=%.3f meanDelta=%.1f samples=%d", changedRatio, meanDelta, totalSamples))

guard changedRatio >= 0.25, meanDelta >= 8.0 else {
    fail(String(format: "smoke source was not visibly dynamic in screencapture: changedRatio=%.3f meanDelta=%.1f samples=%d", changedRatio, meanDelta, totalSamples))
}
SWIFT
)"; then
    append_host_status "failed stage=mac-host phase=smoke-source-preflight reason=capture-not-dynamic screenshotA=$(basename "$first") screenshotB=$(basename "$second")"
    echo "$proof" >&2
    echo "Mac smoke source is not visible/dynamic in screencapture. Unlock the Mac display, keep the desktop visible, and rerun before using the iPad smoke." >&2
    return 1
  fi

  append_host_status "smoke-capture-source captureVerified=1 $proof screenshotA=$(basename "$first") screenshotB=$(basename "$second")"
}

detect_macos_loginwindow_occlusion() {
  local proof
  local status

  set +e
  proof="$(swift - 2>&1 <<'SWIFT'
import CoreGraphics
import Foundation

let displayBounds = CGDisplayBounds(CGMainDisplayID())
let displayArea = max(1.0, displayBounds.width * displayBounds.height)
let windowOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

guard let windows = CGWindowListCopyWindowInfo(windowOptions, kCGNullWindowID) as? [[String: Any]] else {
    exit(0)
}

func doubleValue(_ dictionary: [String: Any], _ key: String) -> Double? {
    if let number = dictionary[key] as? NSNumber {
        return number.doubleValue
    }
    return dictionary[key] as? Double
}

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    guard owner == "loginwindow" else { continue }
    let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
        ?? window[kCGWindowLayer as String] as? Int
        ?? 0
    guard layer >= 1000,
          let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
          let x = doubleValue(boundsDictionary, "X"),
          let y = doubleValue(boundsDictionary, "Y"),
          let width = doubleValue(boundsDictionary, "Width"),
          let height = doubleValue(boundsDictionary, "Height") else {
        continue
    }
    let bounds = CGRect(x: x, y: y, width: width, height: height)
    let intersection = bounds.intersection(displayBounds)
    let coverage = max(0.0, intersection.width) * max(0.0, intersection.height) / displayArea
    if coverage >= 0.90 {
        print(String(format: "loginwindowLayer=%d loginwindowCoverage=%.3f display=%dx%d window=%d,%d,%dx%d",
                     layer,
                     coverage,
                     Int(displayBounds.width),
                     Int(displayBounds.height),
                     Int(bounds.origin.x),
                     Int(bounds.origin.y),
                     Int(bounds.width),
                     Int(bounds.height)))
        exit(2)
    }
}
SWIFT
)"
  status=$?
  set -e
  if (( status == 2 )); then
    append_host_status "failed stage=mac-host phase=smoke-source-preflight reason=screen-locked-loginwindow-occlusion $proof"
    echo "Mac desktop is covered by loginwindow; unlock the Mac display before running the visible remote desktop smoke." >&2
    echo "$proof" >&2
    return 1
  fi
  if (( status != 0 )); then
    append_host_status "failed stage=mac-host phase=smoke-source-preflight reason=loginwindow-occlusion-check-error"
    echo "$proof" >&2
    return 1
  fi
}

wait_for_ios_status_pattern() {
  local pattern="$1"
  local timeout_seconds="$2"
  local label="$3"
  local started_at
  local last_status_mtime=0
  local last_status_update_at=0
  started_at="$(date +%s)"
  last_status_update_at="$started_at"
  while true; do
    fail_if_host_exited "$label" || return 1
    fail_if_smoke_source_exited "$label" || return 1
    fail_if_smoke_source_stale "$label" 15 || return 1
    local now
    now="$(date +%s)"
    if [[ -f "$IOS_STATUS_CONSOLE_LIVE" ]]; then
      local current_status_mtime
      current_status_mtime="$(stat -f %m "$IOS_STATUS_CONSOLE_LIVE" 2>/dev/null || echo 0)"
      if (( current_status_mtime > last_status_mtime )); then
        last_status_mtime="$current_status_mtime"
        last_status_update_at="$now"
      elif (( now - last_status_update_at >= 60 )); then
        echo "Timed out waiting for fresh iOS status while waiting for ${label}: ${IOS_STATUS_CONSOLE_LIVE}" >&2
        print_smoke_tail_for_operator 80 "$IOS_STATUS_CONSOLE_LIVE"
        print_smoke_tail_for_operator 40 "$IOS_CONSOLE_STDERR"
        return 1
      fi
    fi
    if [[ -f "$IOS_STATUS_CONSOLE_LIVE" ]] && grep -qE "$IOS_REMOTE_SMOKE_FAILURE_PATTERN" "$IOS_STATUS_CONSOLE_LIVE"; then
      echo "Detected failure while waiting for ${label}: ${IOS_STATUS_CONSOLE_LIVE}" >&2
      print_smoke_tail_for_operator 80 "$IOS_STATUS_CONSOLE_LIVE"
      print_smoke_tail_for_operator 40 "$IOS_CONSOLE_STDERR"
      return 1
    fi
    fail_if_host_udp_local_network_permission_denied "$label" || return 1
    if [[ -f "$HOST_STATUS" ]] && grep -qE "$HOST_REMOTE_SMOKE_FAILURE_PATTERN" "$HOST_STATUS"; then
      echo "Detected macOS host media failure while waiting for ${label}: ${HOST_STATUS}" >&2
      print_smoke_tail_for_operator 80 "$HOST_STATUS"
      print_smoke_tail_for_operator 80 "$IOS_STATUS_CONSOLE_LIVE"
      return 1
    fi
    if [[ -f "$IOS_STATUS_CONSOLE_LIVE" ]] && grep -qE "$pattern" "$IOS_STATUS_CONSOLE_LIVE"; then
      return 0
    fi
    if [[ "$IOS_CONSOLE_HANDLE_CAPTURED" == "1" ]] \
      && ! ios_console_handle_is_exact_and_running; then
      echo "The exact iOS console launch handle exited or became unverifiable while waiting for ${label}: ${IOS_STATUS_CONSOLE_LIVE}" >&2
      print_smoke_tail_for_operator 80 "$IOS_STATUS_CONSOLE_LIVE"
      print_smoke_tail_for_operator 80 "$IOS_CONSOLE_STDERR"
      return 1
    fi
    if (( now - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${IOS_STATUS_CONSOLE_LIVE}" >&2
      print_smoke_tail_for_operator 80 "$IOS_STATUS_CONSOLE_LIVE"
      print_smoke_tail_for_operator 40 "$IOS_CONSOLE_STDERR"
      return 1
    fi
    sleep 2
  done
}

validate_protocol_identity_bootstrap_evidence() {
  local identity_bootstrap_mode
  if [[ ! -s "$IOS_STATUS_APP_CACHE_LOCAL" || -L "$IOS_STATUS_APP_CACHE_LOCAL" ]]; then
    echo "The authoritative on-device iOS status is unavailable for identity refresh validation: $IOS_STATUS_APP_CACHE_LOCAL" >&2
    return 1
  fi
  if ! identity_bootstrap_mode="$(python3 "$IDENTITY_REFRESH_EVIDENCE_VALIDATOR" \
    --host-status "$HOST_STATUS" \
    --ios-status "$IOS_STATUS_APP_CACHE_LOCAL" \
    --expected-suite "$EXPECTED_TARGET_SUITE")"; then
    echo "Protocol identity bootstrap evidence is incomplete." >&2
    return 1
  fi
  if [[ "$identity_bootstrap_mode" != "forced-pib-skr" ]]; then
    echo "Unexpected protocol identity bootstrap mode: $identity_bootstrap_mode" >&2
    return 1
  fi
  append_host_status "identity-bootstrap mode=$identity_bootstrap_mode validated=1"
  append_ios_status "identity-bootstrap mode=$identity_bootstrap_mode validated=1"
}

validate_remote_desktop_route_evidence() {
  python3 - "$HOST_STATUS" "$IOS_STATUS_APP_CACHE_LOCAL" <<'PY'
import re
import sys

host_path, ios_path = sys.argv[1:]

def fail(message):
    raise SystemExit(f"remote route validation failed: {message}")

def metric(line, key):
    match = re.search(rf"(?:^|\s){re.escape(key)}=([^\s]+)", line)
    return match.group(1).strip() if match else None

with open(ios_path, "r", encoding="utf-8", errors="replace") as handle:
    ios_lines = handle.readlines()
with open(host_path, "r", encoding="utf-8", errors="replace") as handle:
    host_lines = handle.readlines()

route_lines = [line for line in ios_lines if "ios-lan-remote-route " in line]
if not route_lines:
    fail(f"no ios-lan-remote-route evidence in {ios_path}")
route_ready_lines = [line for line in ios_lines if "ios-lan-remote-route-ready " in line]
if not route_ready_lines:
    fail(f"no ios-lan-remote-route-ready evidence in {ios_path}")

def is_infrastructure_candidate(line):
    requested_interface = metric(line, "requestedInterface")
    return (
        metric(line, "provenance") == "liveBrowser"
        and metric(line, "addressClass") == "bonjour-service"
        and metric(line, "transportClass") == "infrastructure"
        and metric(line, "peerToPeer") == "false"
        and metric(line, "interfaceBound") == "1"
        and requested_interface not in (None, "-")
        and not requested_interface.lower().startswith(("awdl", "p2p"))
    )

def is_infrastructure_ready(line):
    requested_interface = metric(line, "requestedInterface")
    resolved_address_class = metric(line, "resolvedAddressClass")
    if resolved_address_class not in ("lan-direct", "link-local"):
        return False
    if not (
        metric(line, "provenance") == "liveBrowser"
        and metric(line, "requestedAddressClass") == "bonjour-service"
        and metric(line, "transportClass") == "infrastructure"
        and metric(line, "peerToPeer") == "false"
        and metric(line, "interfaceBound") == "1"
        and metric(line, "interfaceTypeMatch") == "1"
        and metric(line, "interfaceScopeMatch") == "1"
        and requested_interface not in (None, "-")
        and not requested_interface.lower().startswith(("awdl", "p2p"))
    ):
        return False
    if resolved_address_class == "link-local":
        return metric(line, "resolvedScope") == requested_interface.lower()
    return True

lan_main_route = [line for line in route_lines if is_infrastructure_candidate(line)]
if not lan_main_route:
    fail("no provenance-bound Bonjour infrastructure route candidate")
lan_ready_route = [line for line in route_ready_lines if is_infrastructure_ready(line)]
if not lan_ready_route:
    fail("no provenance/interface-bound infrastructure route-ready evidence")

bad_ios_routes = [line.strip() for line in route_lines if not is_infrastructure_candidate(line)]
if bad_ios_routes:
    fail("iOS remote media candidate lacked live infrastructure ownership: " + bad_ios_routes[-1])
bad_ios_ready_routes = [line.strip() for line in route_ready_lines if not is_infrastructure_ready(line)]
if bad_ios_ready_routes:
    fail("iOS remote media ready route lacked interface/scope proof: " + bad_ios_ready_routes[-1])

bad_mac_peer = [
    line.strip()
    for line in host_lines
    if ("mac remote" in line or "mac-remote" in line or "mac-stream-config" in line)
    and re.search(r"(?:^|\s)peer=[^\s]*(?:%25|%)(?:awdl|p2p)[a-z0-9]*", line.lower())
]
if bad_mac_peer:
    fail("macOS remote tx peer used a disallowed peer-to-peer interface: " + bad_mac_peer[-1])

print(
    "remote route validation passed: "
    f"routeSamples={len(route_lines)} readySamples={len(route_ready_lines)} "
    f"infrastructureCandidates={len(lan_main_route)} infrastructureReady={len(lan_ready_route)} peerToPeer=0"
)
PY
}

validate_remote_desktop_operation_evidence() {
  python3 "$ROOT_DIR/Scripts/validate_p2p_remote_operation_evidence.py" \
    --host-status "$HOST_STATUS" \
    --ios-status "$IOS_STATUS_APP_CACHE_LOCAL" \
    --approval-proof "$P2P_APPROVAL_PROOF" \
    --require-identity-link "$(if [[ "$SMOKE_REQUIRE_SIGNED_KEM_REFRESH" == "1" ]]; then echo true; else echo false; fi)"
}

validate_remote_desktop_performance_window() {
  python3 - "$HOST_STATUS" "$IOS_STATUS_APP_CACHE_LOCAL" "$SMOKE_MIN_FPS" "$SMOKE_TARGET_FPS" "$SMOKE_SOAK_SECONDS" "$SMOKE_VIDEO_WIDTH" "$SMOKE_VIDEO_HEIGHT" "$SMOKE_EXPECT_RENDER_ORIENTATION" <<'PY'
import datetime as dt
import math
import re
import sys

host_path, ios_path, min_fps_raw, target_fps_raw, soak_raw, width_raw, height_raw, expected_orientation = sys.argv[1:]
min_fps = float(min_fps_raw)
target_fps = float(target_fps_raw)
max_transport_fps = target_fps + 3.0
sck_cadence_catch_up_limit = 2
sender_cadence_catch_up_limit = 1
bounded_missed_cadence_slots_limit = 0
strict_mac_sender_queue_limit = 6
sender_content_backlog_frame_limit = 18
strict_ios_decode_feed_mode = "ordered-vt-decode-metal-direct"
strict_ios_decode_pending_limit = 12
strict_ios_decode_in_flight_limit = 4
max_sck_source_frame_age_ms = 34.0
max_sck_source_frame_repeat = 3
hevc_burst_headroom_multiplier = 8
hevc_single_chunk_encoded_budget_bytes = 256 * 1024 - 36 - 68 - 36
soak_seconds = float(soak_raw)
expected_frame = f"{int(width_raw)}x{int(height_raw)}"
minimum_window_samples = max(1, int(soak_seconds) - 2)

def fail(message):
    raise SystemExit(f"remote performance window validation failed: {message}")

def parse_iso_timestamp(line):
    match = re.match(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?)Z\]", line)
    if not match:
        return None
    stamp = match.group(1)
    if "." in stamp:
        whole, fraction = stamp.split(".", 1)
        stamp = f"{whole}.{(fraction + '000000')[:6]}"
        return dt.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=dt.timezone.utc)
    return dt.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)

local_log_tz = dt.datetime.now().astimezone().tzinfo or dt.timezone.utc

def parse_console_timestamp(line, anchor_utc):
    match = re.match(r"^\[(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?\]", line)
    if not match or anchor_utc is None:
        return None
    fraction = match.group(4) or ""
    microsecond = int((fraction + "000000")[:6])
    anchor_local = anchor_utc.astimezone(local_log_tz)
    candidate_local = anchor_local.replace(
        hour=int(match.group(1)),
        minute=int(match.group(2)),
        second=int(match.group(3)),
        microsecond=microsecond,
    )
    candidate_utc = candidate_local.astimezone(dt.timezone.utc)
    if (candidate_utc - anchor_utc).total_seconds() > 12 * 60 * 60:
        candidate_utc -= dt.timedelta(days=1)
    elif (anchor_utc - candidate_utc).total_seconds() > 12 * 60 * 60:
        candidate_utc += dt.timedelta(days=1)
    return candidate_utc

def parse_window_timestamp(line, anchor_utc):
    return parse_iso_timestamp(line) or parse_console_timestamp(line, anchor_utc)

def metric(line, key):
    match = re.search(rf"(?:^|\s){re.escape(key)}=([^\s]+)", line)
    return match.group(1).strip() if match else None

def float_metric(line, key):
    value = metric(line, key)
    if value is None:
        fail(f"missing {key}: {line.strip()}")
    try:
        return float(value)
    except ValueError:
        fail(f"invalid {key}={value}: {line.strip()}")

def int_metric(line, key):
    value = metric(line, key)
    if value is None:
        fail(f"missing {key}: {line.strip()}")
    try:
        return int(value)
    except ValueError:
        fail(f"invalid {key}={value}: {line.strip()}")

with open(ios_path, "r", encoding="utf-8", errors="replace") as handle:
    ios_lines = handle.readlines()

pass_candidates = [
    (idx, timestamp)
    for idx, line in enumerate(ios_lines)
    if "remote-desktop-pass " in line
    for timestamp in [parse_iso_timestamp(line)]
    if timestamp is not None
]
if not pass_candidates:
    fail(f"no remote-desktop-pass marker in {ios_path}")
pass_index, pass_time = max(pass_candidates, key=lambda item: item[1])
pass_line = ios_lines[pass_index]
reported_window_seconds = float_metric(pass_line, "windowSeconds")
if reported_window_seconds + 0.5 < soak_seconds:
    fail(f"reported pass window shorter than requested soak: seconds={reported_window_seconds:.2f} soak={soak_seconds}")
reported_window_fps = float_metric(pass_line, "windowFPS")
reported_window_rx_fps = float_metric(pass_line, "windowRxFps")
if reported_window_fps < min_fps:
    fail(f"iOS aggregate display windowFPS below {min_fps}: {pass_line.strip()}")
if reported_window_rx_fps < min_fps:
    fail(f"iOS aggregate rx windowRxFps below {min_fps}: {pass_line.strip()}")
if int_metric(pass_line, "windowDisplayedFrames") <= 0:
    fail(f"iOS pass marker did not report displayed frames: {pass_line.strip()}")
if int_metric(pass_line, "windowReceivedFrames") <= 0:
    fail(f"iOS pass marker did not report received frames: {pass_line.strip()}")
two_second_required = int_metric(pass_line, "twoSecondRequiredFrames")
if two_second_required < math.ceil(min_fps * 2):
    fail(f"iOS two-second cadence requirement is too low: {pass_line.strip()}")
if int_metric(pass_line, "min2sDisplayFrames") < two_second_required:
    fail(f"iOS worst two-second display cadence below requirement: {pass_line.strip()}")
if int_metric(pass_line, "min2sRxFrames") < two_second_required:
    fail(f"iOS worst two-second receive cadence below requirement: {pass_line.strip()}")
rolling_display_cadence = metric(pass_line, "rollingDisplayCadencePass") or metric(pass_line, "rollingCadencePass")
if rolling_display_cadence != "1":
    fail(f"iOS rolling display cadence did not pass: {pass_line.strip()}")
rolling_rx_cadence = metric(pass_line, "rollingRxCadencePass") or metric(pass_line, "rollingCadencePass")
if rolling_rx_cadence != "1":
    fail(f"iOS rolling receive cadence did not pass: {pass_line.strip()}")
rolling_combined_cadence = metric(pass_line, "rollingCombinedCadencePass") or metric(pass_line, "rollingCadencePass")
if rolling_combined_cadence != "1":
    fail(f"iOS rolling combined display/receive cadence did not pass: {pass_line.strip()}")
if metric(pass_line, "rxFrameClock") != "source-cadence+metal-delivery":
    fail(f"iOS receive cadence did not expose source-cadence plus Metal-delivery evidence: {pass_line.strip()}")
if int_metric(pass_line, "last2sSourceFrames") < two_second_required:
    fail(f"iOS source-frame cadence below requirement: {pass_line.strip()}")
if int_metric(pass_line, "last2sMetalDeliveryFrames") < two_second_required:
    fail(f"iOS Metal-delivery cadence below requirement: {pass_line.strip()}")
if int_metric(pass_line, "last2sSocketRxFrames") <= 0:
    fail(f"iOS socket-arrival telemetry was missing from the receive cadence report: {pass_line.strip()}")
start_candidates = [
    (idx, timestamp)
    for idx, line in enumerate(ios_lines)
    if "remote-desktop pass-window-start " in line
    for timestamp in [parse_iso_timestamp(line)]
    if timestamp is not None and timestamp <= pass_time
]
if not start_candidates:
    fail("no pass-window-start before remote-desktop-pass")
start_index, start_time = max(start_candidates, key=lambda item: item[1])
if start_time is None:
    fail("pass window markers are missing ISO timestamps")
if (pass_time - start_time).total_seconds() + 0.5 < soak_seconds:
    fail(f"pass window shorter than requested soak: start={start_time} pass={pass_time} soak={soak_seconds}")

pass_time_upper = pass_time + dt.timedelta(seconds=1)
window_lines = [
    line for idx, line in enumerate(ios_lines)
    for timestamp in [parse_window_timestamp(line, pass_time)]
    if start_index <= idx <= pass_index and timestamp is not None and start_time <= timestamp <= pass_time_upper
]
ios_status_count = 0
audio_status_samples = 0
audio_recv_start = None
audio_recv_end = None
audio_decoded_start = None
audio_decoded_end = None
audio_played_start = None
audio_played_end = None
metal_count = 0
metal_sample_ms = 0
metal_input = 0
metal_draw_callbacks = 0
metal_submitted = 0
metal_displayed = 0
metal_direct_bgra = 0
metal_coalesced_before_draw = 0
metal_realtime_replacement_before_draw = 0
metal_realtime_replacement_reason_samples = 0
metal_realtime_replacement_reason_bad = 0
metal_manual_draw = 0
metal_queue_backpressure = 0
metal_queue_capacity_max = 0
metal_queue_depth_max = 0
metal_frame_age_max_ms = 0.0
metal_frame_age_samples = 0
metal_display_link_pump_fps = 0
lan_rx_count = 0
frame_budget_ms = 1000.0 / max(min_fps, 1.0)
max_raw_chunk_gap_ms = frame_budget_ms * 12.0
minimum_sampled_lan_fps = min_fps * 0.90
lan_rx_sample_ms = 0
lan_rx_screen_frames = 0
lan_rx_sbc2_frames = 0
lan_rx_sbc2_chunks = 0
lan_rx_max_screen_fps = 0.0
lan_rx_max_gap_ms = 0.0
lan_rx_source_samples = 0
lan_rx_source_gap_max_ms = 0.0
lan_rx_source_to_read_max_ms = 0.0
lan_rx_source_to_read_unsynced_clock_samples = 0
lan_rx_raw_chunks = 0
lan_rx_read_ahead_samples = 0
lan_rx_screen_delivery_samples = 0
lan_rx_screen_delivery_strict_samples = 0
lan_rx_screen_delivery_attempted = 0
lan_rx_screen_delivery_delivered = 0
lan_rx_screen_delivery_backpressure = 0
lan_rx_screen_delivery_queue_depth_max = 0
lan_rx_screen_delivery_delay_max_ms = 0.0
lan_rx_decode_feed_samples = 0
lan_rx_decode_feed_strict_samples = 0
lan_rx_decode_attempted = 0
lan_rx_decode_accepted = 0
lan_rx_decode_dropped = 0
lan_rx_decode_pending_max = 0
lan_rx_decode_in_flight_max = 0
lan_rx_decode_waiting_sync = 0
lan_rx_decode_resets = 0
lan_rx_raw_chunk_gap_max_ms = 0.0
lan_rx_main_hop_max_ms = 0.0
lan_rx_raw_chunk_main_hop_max_ms = 0.0
lan_rx_complete_frames_per_drain_max = 0
lan_rx_parser_drain_max_ms = 0.0
lan_rx_parser_budget_samples = 0
lan_rx_parser_budget_ms_max = 0.0
lan_rx_parser_budget_hits = 0
for line in window_lines:
    if "remote-desktop status " in line:
        ios_status_count += 1
        if metric(line, "corePass") != "1":
            fail(f"iOS core media gate fell out of pass state inside final window: {line.strip()}")
        if metric(line, "frame") != expected_frame:
            fail(f"iOS frame size is not {expected_frame}: {line.strip()}")
        if metric(line, "pipeline") != "metalRenderer":
            fail(f"iOS renderer is not Metal: {line.strip()}")
        if metric(line, "renderOrientation") != expected_orientation:
            fail(f"iOS render orientation is not {expected_orientation}: {line.strip()}")
        for key in ("audioRxPlaybackDrop", "audioRxJitterEvicted", "audioRxUnderflow", "audioRxRebuffer"):
            if int_metric(line, key) != 0:
                fail(f"iOS audio {key} was nonzero: {line.strip()}")
        audio_recv = int_metric(line, "audioRxRecv")
        audio_decoded = int_metric(line, "audioRxDecoded")
        audio_played = int_metric(line, "audioRxPlayed")
        if audio_recv > 0 or audio_decoded > 0 or audio_played > 0:
            audio_status_samples += 1
            if audio_recv_start is None:
                audio_recv_start = audio_recv
                audio_decoded_start = audio_decoded
                audio_played_start = audio_played
            audio_recv_end = audio_recv
            audio_decoded_end = audio_decoded
            audio_played_end = audio_played
    if "Metal render telemetry:" in line:
        metal_count += 1
        metal_sample_ms += int_metric(line, "sampleMs")
        metal_input += int_metric(line, "input")
        metal_draw_callbacks += int_metric(line, "drawCallbacks")
        metal_submitted += int_metric(line, "submitted")
        metal_displayed += int_metric(line, "displayed")
        metal_direct_bgra += int_metric(line, "directBGRA")
        metal_coalesced_before_draw += int_metric(line, "coalescedBeforeDraw")
        metal_realtime_replacement_before_draw += int_metric(line, "realtimeReplacementBeforeDraw")
        replacement_reason = metric(line, "realtimeReplacementReason")
        if replacement_reason:
            metal_realtime_replacement_reason_samples += 1
            if replacement_reason != "none":
                metal_realtime_replacement_reason_bad += 1
        metal_manual_draw += int_metric(line, "manualDraw")
        metal_queue_capacity_max = max(metal_queue_capacity_max, int_metric(line, "queueCapacity"))
        metal_queue_depth_max = max(metal_queue_depth_max, int_metric(line, "queueDepthMax"))
        metal_display_link_target_fps = int_metric(line, "displayLinkTargetFPS")
        metal_display_link_pump_fps = max(metal_display_link_pump_fps, int_metric(line, "displayLinkPumpFPS"))
        if metal_display_link_target_fps < int(math.ceil(min_fps)):
            fail(f"Metal displayLinkTargetFPS is below the strict FPS gate: {line.strip()}")
        if int_metric(line, "displayLinkPumpFPS") < metal_display_link_target_fps:
            fail(f"Metal displayLinkPumpFPS is below the render target FPS: {line.strip()}")
        if metric(line, "displayLink") != "mtkview-native":
            fail(f"Metal display driver is not the strict MTKView native path: {line.strip()}")
        if metric(line, "displayCadence") != "strict-60-native-pump-catch-up-vsync":
            fail(f"Metal display cadence is not the strict 60Hz MTKView native-vsync path: {line.strip()}")
        frame_age_value = metric(line, "frameAgeMs")
        if frame_age_value and frame_age_value != "-":
            try:
                metal_frame_age_max_ms = max(metal_frame_age_max_ms, float(frame_age_value))
                metal_frame_age_samples += 1
            except ValueError:
                fail(f"invalid Metal frameAgeMs={frame_age_value}: {line.strip()}")
        if int_metric(line, "ciFallback") != 0:
            fail(f"Metal CI fallback rendered frames were nonzero: {line.strip()}")
        metal_queue_backpressure += int_metric(line, "queueBackpressure")
        for key in ("queueDrop", "drawableSkip", "inflightSkip", "failureSkip"):
            if int_metric(line, key) != 0:
                fail(f"Metal {key} was nonzero: {line.strip()}")
    if "ios-lan-remote-rx " in line:
        lan_rx_count += 1
        lan_rx_sample_ms += int_metric(line, "sampleMs")
        lan_rx_screen_frames += int_metric(line, "screenFrames")
        lan_rx_sbc2_frames += int_metric(line, "sbc2Frames")
        lan_rx_sbc2_chunks += int_metric(line, "sbc2Chunks")
        lan_rx_max_screen_fps = max(lan_rx_max_screen_fps, float_metric(line, "screenFPS"))
        lan_rx_max_gap_ms = max(lan_rx_max_gap_ms, float_metric(line, "maxGapMs"))
        lan_rx_source_samples += int_metric(line, "sourceSamples")
        lan_rx_source_gap_max_ms = max(lan_rx_source_gap_max_ms, float_metric(line, "sourceGapMaxMs"))
        lan_rx_source_to_read_max_ms = max(lan_rx_source_to_read_max_ms, float_metric(line, "sourceToReadMaxMs"))
        if metric(line, "sourceToReadClock") == "remote-wall-clock-unsynced":
            lan_rx_source_to_read_unsynced_clock_samples += 1
        lan_rx_raw_chunks += int_metric(line, "rawChunks")
        lan_rx_raw_chunk_gap_max_ms = max(lan_rx_raw_chunk_gap_max_ms, float_metric(line, "rawChunkGapMaxMs"))
        lan_rx_main_hop_max_ms = max(lan_rx_main_hop_max_ms, float_metric(line, "maxMainHopMs"))
        lan_rx_raw_chunk_main_hop_max_ms = max(lan_rx_raw_chunk_main_hop_max_ms, float_metric(line, "rawChunkMainHopMaxMs"))
        lan_rx_complete_frames_per_drain_max = max(lan_rx_complete_frames_per_drain_max, int_metric(line, "completeFramesPerDrainMax"))
        lan_rx_parser_drain_max_ms = max(lan_rx_parser_drain_max_ms, float_metric(line, "parserDrainMaxMs"))
        if metric(line, "parserBudgetMs") is not None:
            lan_rx_parser_budget_samples += 1
            lan_rx_parser_budget_ms_max = max(lan_rx_parser_budget_ms_max, float_metric(line, "parserBudgetMs"))
        lan_rx_parser_budget_hits += int_metric(line, "parserBudgetHits")
        if metric(line, "parserDrainMaxMs") is not None and metric(line, "parserBudgetMs") is not None:
            if float_metric(line, "parserDrainMaxMs") > float_metric(line, "parserBudgetMs"):
                fail(f"iOS LAN parser drain exceeded its per-sample budget: {line.strip()}")
        if metric(line, "screenWire") != "sbc2-chunked-v1":
            fail(f"iOS LAN receive did not use sbc2-chunked-v1: {line.strip()}")
        if metric(line, "readAhead") != "stream-parser-low-latency-256k-4frame-6ms-drain-budget":
            fail(f"iOS LAN receive did not prove low-latency read-ahead and bounded drain: {line.strip()}")
        lan_rx_read_ahead_samples += 1
        screen_delivery = metric(line, "screenDelivery")
        if screen_delivery is not None:
            lan_rx_screen_delivery_samples += 1
        if screen_delivery == "immediate-decode-metal-feed-direct":
            lan_rx_screen_delivery_strict_samples += 1
        lan_rx_screen_delivery_attempted += int_metric(line, "screenDeliveryAttempted")
        lan_rx_screen_delivery_delivered += int_metric(line, "screenDeliveryDelivered")
        lan_rx_screen_delivery_backpressure += int_metric(line, "screenDeliveryBackpressure")
        lan_rx_screen_delivery_queue_depth_max = max(lan_rx_screen_delivery_queue_depth_max, int_metric(line, "screenDeliveryQueueDepthMax"))
        lan_rx_screen_delivery_delay_max_ms = max(lan_rx_screen_delivery_delay_max_ms, float_metric(line, "screenDeliveryDelayMaxMs"))
        decode_feed = metric(line, "decodeFeed")
        if decode_feed is not None:
            lan_rx_decode_feed_samples += 1
        if decode_feed == strict_ios_decode_feed_mode:
            lan_rx_decode_feed_strict_samples += 1
        lan_rx_decode_attempted += int_metric(line, "decodeAttempted")
        lan_rx_decode_accepted += int_metric(line, "decodeAccepted")
        lan_rx_decode_dropped += int_metric(line, "decodeDropped")
        lan_rx_decode_pending_max = max(lan_rx_decode_pending_max, int_metric(line, "decodePendingMax"))
        lan_rx_decode_in_flight_max = max(lan_rx_decode_in_flight_max, int_metric(line, "decodeInFlightMax"))
        lan_rx_decode_waiting_sync += int_metric(line, "decodeWaitingSyncSamples")
        lan_rx_decode_resets += int_metric(line, "decodeResets")

if ios_status_count == 0:
    fail("no iOS remote-desktop status samples inside final pass window")
if metal_count == 0:
    fail("no Metal render telemetry inside final pass window")
if lan_rx_count == 0:
    fail("no iOS LAN receive telemetry inside final pass window")
if ios_status_count < minimum_window_samples:
    fail(f"too few iOS status samples inside final pass window: count={ios_status_count} required={minimum_window_samples}")
if metal_count < minimum_window_samples:
    fail(f"too few Metal render telemetry samples inside final pass window: count={metal_count} required={minimum_window_samples}")
if lan_rx_count < minimum_window_samples:
    fail(f"too few iOS LAN receive telemetry samples inside final pass window: count={lan_rx_count} required={minimum_window_samples}")
if metal_sample_ms <= 0:
    fail("Metal render telemetry did not report a positive aggregate sample window")
if metal_frame_age_samples <= 0:
    fail("Metal render telemetry did not report frameAgeMs evidence inside final pass window")
metal_input_fps = metal_input * 1000.0 / metal_sample_ms
if metal_input_fps < min_fps:
    fail(f"Metal aggregate inputFPS below {min_fps}: input={metal_input} sampleMs={metal_sample_ms} fps={metal_input_fps:.1f}")
if lan_rx_sample_ms <= 0:
    fail("iOS LAN receive telemetry did not report a positive aggregate sample window")
lan_rx_screen_fps = lan_rx_screen_frames * 1000.0 / lan_rx_sample_ms
if lan_rx_screen_fps < minimum_sampled_lan_fps:
    fail(f"iOS LAN sampled receive screenFPS far below final pass marker: frames={lan_rx_screen_frames} sampleMs={lan_rx_sample_ms} fps={lan_rx_screen_fps:.1f} minimumSampledFPS={minimum_sampled_lan_fps:.1f} finalWindowRxFPS={reported_window_rx_fps:.1f} maxGapMs={lan_rx_max_gap_ms:.1f}")
if lan_rx_screen_fps > max_transport_fps:
    fail(f"iOS LAN receive aggregate screenFPS exceeded strict target: fps={lan_rx_screen_fps:.1f} target={target_fps:.1f}")
if lan_rx_sbc2_frames <= 0:
    fail(f"iOS LAN receive did not report SBC2 screen frames inside final pass window: screenFrames={lan_rx_screen_frames} sbc2Frames={lan_rx_sbc2_frames}")
if lan_rx_sbc2_chunks < lan_rx_sbc2_frames:
    fail(f"iOS LAN receive reported fewer SBC2 chunks than frames: sbc2Chunks={lan_rx_sbc2_chunks} sbc2Frames={lan_rx_sbc2_frames}")
if lan_rx_source_samples <= 0:
    fail("iOS LAN receive did not expose source timestamp correlation inside final pass window")
if lan_rx_source_gap_max_ms > 100.0:
    fail(f"iOS LAN source timestamp gap exceeded 100ms inside final pass window: sourceGapMaxMs={lan_rx_source_gap_max_ms:.1f}")
if lan_rx_source_to_read_max_ms > 100.0 and lan_rx_source_to_read_unsynced_clock_samples != lan_rx_count:
    fail(f"iOS LAN source-to-read latency exceeded 100ms inside final pass window: sourceToReadMaxMs={lan_rx_source_to_read_max_ms:.1f}")
if lan_rx_raw_chunks <= 0:
    fail("iOS LAN receive did not report raw NWConnection receive chunks inside final pass window")
if lan_rx_read_ahead_samples != lan_rx_count:
    fail(f"iOS LAN receive read-ahead samples did not cover every telemetry line: readAhead={lan_rx_read_ahead_samples} lanRx={lan_rx_count}")
if lan_rx_screen_delivery_samples != lan_rx_count:
    fail(f"iOS LAN screen delivery samples did not cover every telemetry line: screenDelivery={lan_rx_screen_delivery_samples} lanRx={lan_rx_count}")
if lan_rx_screen_delivery_strict_samples != lan_rx_count:
    fail(f"iOS LAN screen delivery was not strict decoded-to-Metal 60Hz feed for every telemetry line: strictScreenDelivery={lan_rx_screen_delivery_strict_samples} lanRx={lan_rx_count}")
if lan_rx_screen_delivery_delivered <= 0:
    fail("iOS LAN screen delivery did not report delivered frames inside final pass window")
if lan_rx_screen_delivery_attempted < lan_rx_screen_delivery_delivered:
    fail(f"iOS LAN screen delivery accepted more frames than attempted: attempted={lan_rx_screen_delivery_attempted} delivered={lan_rx_screen_delivery_delivered}")
lan_rx_screen_delivery_fps = lan_rx_screen_delivery_delivered * 1000.0 / lan_rx_sample_ms
if lan_rx_screen_delivery_fps < minimum_sampled_lan_fps:
    fail(f"iOS LAN sampled screen delivery FPS far below final pass marker: delivered={lan_rx_screen_delivery_delivered} sampleMs={lan_rx_sample_ms} fps={lan_rx_screen_delivery_fps:.1f} minimumSampledFPS={minimum_sampled_lan_fps:.1f} finalWindowFPS={reported_window_fps:.1f}")
if lan_rx_screen_delivery_queue_depth_max > 1:
    fail(f"iOS LAN direct screen delivery queued frames instead of immediate Metal feed: screenDeliveryQueueDepthMax={lan_rx_screen_delivery_queue_depth_max}")
if lan_rx_screen_delivery_delay_max_ms > 100.0:
    fail(f"iOS LAN screen delivery delay exceeded 100ms inside final pass window: screenDeliveryDelayMaxMs={lan_rx_screen_delivery_delay_max_ms:.1f}")
if lan_rx_decode_feed_samples != lan_rx_count:
    fail(f"iOS LAN decode-feed samples did not cover every telemetry line: decodeFeed={lan_rx_decode_feed_samples} lanRx={lan_rx_count}")
if lan_rx_decode_feed_strict_samples != lan_rx_count:
    fail(f"iOS LAN decode feed was not ordered VideoToolbox-to-Metal direct for every telemetry line: strictDecodeFeed={lan_rx_decode_feed_strict_samples} lanRx={lan_rx_count} expected={strict_ios_decode_feed_mode}")
if lan_rx_decode_attempted <= 0:
    fail("iOS LAN decode feed did not report attempted frames inside final pass window")
if lan_rx_decode_attempted != lan_rx_decode_accepted:
    fail(f"iOS LAN decode feed accepted frames did not match attempts: attempted={lan_rx_decode_attempted} accepted={lan_rx_decode_accepted}")
if lan_rx_decode_dropped != 0:
    fail(f"iOS LAN decode feed dropped frames inside final pass window: decodeDropped={lan_rx_decode_dropped}")
if lan_rx_decode_pending_max > strict_ios_decode_pending_limit:
    fail(f"iOS LAN decode pending queue exceeded strict bound inside final pass window: decodePendingMax={lan_rx_decode_pending_max} limit={strict_ios_decode_pending_limit}")
if lan_rx_decode_in_flight_max > strict_ios_decode_in_flight_limit:
    fail(f"iOS LAN decode in-flight count exceeded strict bound inside final pass window: decodeInFlightMax={lan_rx_decode_in_flight_max} limit={strict_ios_decode_in_flight_limit}")
if lan_rx_decode_waiting_sync != 0:
    fail(f"iOS LAN decode feed entered waiting-for-sync inside final pass window: decodeWaitingSyncSamples={lan_rx_decode_waiting_sync}")
if lan_rx_decode_resets != 0:
    fail(f"iOS LAN decode pipeline reset inside final pass window: decodeResets={lan_rx_decode_resets}")
if lan_rx_raw_chunk_gap_max_ms > max_raw_chunk_gap_ms:
    fail(f"iOS LAN raw receive chunk gap exceeded 12-frame bounded receive budget inside final pass window: rawChunkGapMaxMs={lan_rx_raw_chunk_gap_max_ms:.1f} budgetMs={max_raw_chunk_gap_ms:.1f}")
if lan_rx_main_hop_max_ms > 100.0:
    fail(f"iOS LAN frame handling MainActor hop exceeded 100ms inside final pass window: maxMainHopMs={lan_rx_main_hop_max_ms:.1f}")
if lan_rx_raw_chunk_main_hop_max_ms > 100.0:
    fail(f"iOS LAN raw receive MainActor handoff exceeded 100ms inside final pass window: rawChunkMainHopMaxMs={lan_rx_raw_chunk_main_hop_max_ms:.1f}")
if lan_rx_complete_frames_per_drain_max > 4:
    fail(f"iOS LAN parser drain submitted too many complete screen frames for bounded 4-frame drain: completeFramesPerDrainMax={lan_rx_complete_frames_per_drain_max}")
if lan_rx_parser_budget_samples != lan_rx_count:
    fail(f"iOS LAN parser drain budget samples did not cover every telemetry line: parserBudgetSamples={lan_rx_parser_budget_samples} lanRx={lan_rx_count}")
if lan_rx_parser_budget_ms_max > 6.0:
    fail(f"iOS LAN parser drain budget exceeded strict 6ms bound: parserBudgetMsMax={lan_rx_parser_budget_ms_max:.1f}")
if lan_rx_parser_drain_max_ms > lan_rx_parser_budget_ms_max:
    fail(f"iOS LAN parser drain exceeded strict budget inside final pass window: parserDrainMaxMs={lan_rx_parser_drain_max_ms:.1f} parserBudgetMs={lan_rx_parser_budget_ms_max:.1f}")
if lan_rx_parser_budget_hits != 0:
    fail(f"iOS LAN parser drain hit the strict 6ms budget inside final pass window: parserBudgetHits={lan_rx_parser_budget_hits}")
if metal_direct_bgra != metal_submitted:
    fail(f"Metal direct BGRA frames did not match submitted frames: directBGRA={metal_direct_bgra} submitted={metal_submitted}")
metal_submitted_fps = metal_submitted * 1000.0 / metal_sample_ms
metal_displayed_fps = metal_displayed * 1000.0 / metal_sample_ms
metal_draw_callback_fps = metal_draw_callbacks * 1000.0 / metal_sample_ms
if metal_draw_callback_fps < min_fps:
    fail(f"Metal aggregate drawCallbackFPS below {min_fps}: drawCallbacks={metal_draw_callbacks} sampleMs={metal_sample_ms} fps={metal_draw_callback_fps:.1f}")
max_draw_callback_fps = max(float(metal_display_link_pump_fps), target_fps) + 2.0
if metal_draw_callback_fps > max_draw_callback_fps:
    fail(f"Metal aggregate drawCallbackFPS exceeded native pump budget: drawCallbacks={metal_draw_callbacks} sampleMs={metal_sample_ms} fps={metal_draw_callback_fps:.1f} pumpFPS={metal_display_link_pump_fps} target={target_fps:.1f}")
if metal_submitted_fps < min_fps:
    fail(f"Metal aggregate submittedFPS below {min_fps}: submitted={metal_submitted} sampleMs={metal_sample_ms} fps={metal_submitted_fps:.1f}")
if metal_displayed_fps < min_fps:
    fail(f"Metal aggregate displayFPS below {min_fps}: displayed={metal_displayed} sampleMs={metal_sample_ms} fps={metal_displayed_fps:.1f}")
if metal_submitted_fps > max_transport_fps:
    fail(f"Metal aggregate submittedFPS exceeded strict target: submitted={metal_submitted} sampleMs={metal_sample_ms} fps={metal_submitted_fps:.1f} target={target_fps:.1f}")
if metal_displayed_fps > max_transport_fps:
    fail(f"Metal aggregate displayFPS exceeded strict target: displayed={metal_displayed} sampleMs={metal_sample_ms} fps={metal_displayed_fps:.1f} target={target_fps:.1f}")
max_allowed_metal_coalesced = 0
if metal_coalesced_before_draw > max_allowed_metal_coalesced:
    fail(f"Metal realtime coalescedBeforeDraw was nonzero inside final pass window: coalesced={metal_coalesced_before_draw} allowed={max_allowed_metal_coalesced} submitted={metal_submitted}")
if metal_realtime_replacement_before_draw != metal_coalesced_before_draw:
    fail(f"Metal realtime replacement evidence did not match coalescedBeforeDraw inside final pass window: replacement={metal_realtime_replacement_before_draw} coalesced={metal_coalesced_before_draw}")
if metal_coalesced_before_draw > 0 and metal_realtime_replacement_reason_samples <= 0:
    fail("Metal realtime replacement was nonzero without structured replacement reason inside final pass window")
if metal_realtime_replacement_reason_bad != 0:
    fail(f"Metal realtime replacement reported unexpected reason inside final pass window: badReasons={metal_realtime_replacement_reason_bad}")
if metal_manual_draw != 0:
    fail(f"Metal manualDraw was nonzero inside final pass window: manualDraw={metal_manual_draw}")
if metal_queue_capacity_max > 3:
    fail(f"Metal queueCapacity exceeded bounded 3-frame realtime render queue inside final pass window: queueCapacity={metal_queue_capacity_max}")
if metal_queue_depth_max > 3:
    fail(f"Metal queueDepthMax exceeded bounded 3-frame realtime render queue inside final pass window: queueDepthMax={metal_queue_depth_max}")
if metal_frame_age_max_ms > 100.0:
    fail(f"Metal frameAgeMs exceeded 100ms inside final pass window: frameAgeMs={metal_frame_age_max_ms:.1f}")

with open(host_path, "r", encoding="utf-8", errors="replace") as handle:
    host_lines = handle.readlines()

encoder_config_seen = False
encoder_key_interval = 0
encoder_key_duration_ms = 0
encoder_requested_gop = 0
encoder_cadence_catch_up_limit = 0
encoder_rate_limit_bytes_per_second = 0
encoder_burst_limit_bytes = 0
encoder_burst_window_ms = 0
encoder_data_rate_limits_status = -1
encoder_data_rate_limits_readback_status = -1
encoder_data_rate_limits_applied = 0
encoder_readback_burst_limit_bytes = 0
encoder_readback_burst_window_ms = 0
encoder_low_latency_rate_control = "missing"
encoder_max_frame_delay_count = 0
encoder_maximum_real_time_frame_rate = 0
encoder_single_chunk_budget_bytes = 0
for line in host_lines:
    timestamp = parse_iso_timestamp(line)
    if timestamp is None or timestamp > pass_time:
        continue
    if "mac-sck-encoder " in line and "codec=hevc" in line and "capturesAudio=false" in line:
        encoder_config_seen = True
        encoder_key_interval = int_metric(line, "keyInterval")
        encoder_key_duration_ms = int_metric(line, "keyDurationMs")
        encoder_requested_gop = int_metric(line, "requestedGOP")
        encoder_cadence_catch_up_limit = int_metric(line, "cadenceCatchUpLimit")
        encoder_max_frame_delay_count = int_metric(line, "maxFrameDelayCount")
        encoder_maximum_real_time_frame_rate = int_metric(line, "maximumRealTimeFrameRate")
        encoder_rate_limit_bytes_per_second = int_metric(line, "dataRateLimitBytesPerSecond")
        encoder_burst_limit_bytes = int_metric(line, "dataRateBurstLimitBytes")
        encoder_burst_window_ms = int_metric(line, "dataRateBurstWindowMs")
        encoder_data_rate_limits_status = int_metric(line, "dataRateLimitsStatus")
        encoder_data_rate_limits_readback_status = int_metric(line, "dataRateLimitsReadbackStatus")
        encoder_data_rate_limits_applied = int_metric(line, "dataRateLimitsApplied")
        encoder_readback_burst_limit_bytes = int_metric(line, "dataRateReadbackBurstLimitBytes")
        encoder_readback_burst_window_ms = int_metric(line, "dataRateReadbackBurstWindowMs")
        encoder_single_chunk_budget_bytes = int_metric(line, "singleChunkHEVCBudgetBytes")
        encoder_low_latency_rate_control = metric(line, "lowLatencyRateControl") or "false"
        if metric(line, "lowLatency") != "true":
            fail(f"Mac HEVC encoder was not in low-latency strict mode: {line.strip()}")

if not encoder_config_seen:
    fail("no Mac HEVC encoder configuration telemetry before final pass")
expected_encoder_gop = max(60, int(round(target_fps)))
if encoder_key_interval != expected_encoder_gop or encoder_requested_gop != expected_encoder_gop:
    fail(
        "Mac HEVC encoder GOP drifted from strict 1s cadence: "
        f"requestedGOP={encoder_requested_gop} keyInterval={encoder_key_interval} expected={expected_encoder_gop}"
    )
if encoder_key_duration_ms < 900 or encoder_key_duration_ms > 1100:
    fail(f"Mac HEVC encoder keyframe duration is not ~1s: keyDurationMs={encoder_key_duration_ms}")
if encoder_cadence_catch_up_limit != sck_cadence_catch_up_limit:
    fail(f"Mac HEVC SCK cadence recovery limit was not the bounded strict producer path: cadenceCatchUpLimit={encoder_cadence_catch_up_limit} expected={sck_cadence_catch_up_limit}")
if encoder_max_frame_delay_count != 3:
    fail(f"Mac HEVC 2K60 encoder delay window did not prove the bounded three-frame VideoToolbox path: maxFrameDelayCount={encoder_max_frame_delay_count}")
if encoder_maximum_real_time_frame_rate != min(int(round(target_fps)) * sck_cadence_catch_up_limit, 120):
    fail(f"Mac HEVC encoder did not expose the bounded realtime catch-up rate: maximumRealTimeFrameRate={encoder_maximum_real_time_frame_rate}")
if encoder_low_latency_rate_control not in ("true", "false"):
    fail(f"Mac HEVC encoder did not expose VideoToolbox low-latency rate-control selection: lowLatencyRateControl={encoder_low_latency_rate_control}")
if encoder_single_chunk_budget_bytes != hevc_single_chunk_encoded_budget_bytes:
    fail(f"Mac HEVC encoder did not expose the SBC2 single-chunk payload budget: singleChunkHEVCBudgetBytes={encoder_single_chunk_budget_bytes} expected={hevc_single_chunk_encoded_budget_bytes}")
if encoder_burst_window_ms != int(round(1000.0 / target_fps)):
    fail(f"Mac HEVC encoder short-window burst cap duration drifted from the single-frame transport budget: dataRateBurstWindowMs={encoder_burst_window_ms}")
expected_encoder_burst_limit_bytes = min(
    max(
        ((encoder_rate_limit_bytes_per_second + int(round(target_fps)) - 1) // int(round(target_fps))) * hevc_burst_headroom_multiplier,
        128 * 1024,
    ),
    hevc_single_chunk_encoded_budget_bytes,
)
if encoder_burst_limit_bytes != expected_encoder_burst_limit_bytes:
    fail(
        "Mac HEVC encoder short-window burst cap drifted from the single-chunk transport budget with bounded headroom: "
        f"dataRateLimitBytesPerSecond={encoder_rate_limit_bytes_per_second} "
        f"dataRateBurstLimitBytes={encoder_burst_limit_bytes} expected={expected_encoder_burst_limit_bytes}"
    )
if encoder_data_rate_limits_status != 0 or encoder_data_rate_limits_readback_status != 0 or encoder_data_rate_limits_applied != 1:
    fail(f"Mac HEVC encoder DataRateLimits were not accepted and read back by VideoToolbox: status={encoder_data_rate_limits_status} readbackStatus={encoder_data_rate_limits_readback_status} applied={encoder_data_rate_limits_applied}")
if encoder_readback_burst_limit_bytes != expected_encoder_burst_limit_bytes or encoder_readback_burst_window_ms != encoder_burst_window_ms:
    fail(f"Mac HEVC encoder DataRateLimits readback did not match strict budget: readbackBurstBytes={encoder_readback_burst_limit_bytes} readbackBurstWindowMs={encoder_readback_burst_window_ms}")

host_window_start = start_time + dt.timedelta(seconds=1)
minimum_source_observed_seconds = max(2.0, soak_seconds - 4.0)
minimum_source_samples = 2
sck_count = 0
tx_count = 0
source_count = 0
sck_sample_ms = 0
sck_encoded_frames = 0
sck_captured_frames = 0
sck_meaningful_frames = 0
sck_source_frame_age_max_ms = 0.0
sck_source_frame_repeat_max = 0
tx_sample_ms = 0
tx_sent_frames = 0
tx_chunked_frames = 0
tx_sent_chunks = 0
tx_max_chunks_per_frame = 0
tx_backpressure = 0
tx_raw_backpressure = 0
tx_ordered_throttle = 0
tx_queue_backlog = 0
tx_queued_max = 0
tx_inflight_max = 0
tx_content_backlog_max = 0
tx_content_backlog_limit = 0
tx_content_backlog_bytes_max = 0
tx_content_backlog_byte_limit = 0
tx_max_frames_per_drain = 0
tx_schedule_budget_max = 0
tx_missed_cadence_slots_max = 0
tx_content_backlog_full = 0
tx_oldest_content_backlog_ms = 0.0
tx_queue_age_max_ms = 0.0
tx_dequeued_age_max_ms = 0.0
tx_max_send_ms = 0.0
tx_schedule_gap_max_ms = 0.0
tx_schedule_jitter_max_ms = 0.0
tx_completion_gap_max_ms = 0.0
tx_content_callback_gap_max_ms = 0.0
tx_content_actor_hop_max_ms = 0.0
tx_encoded_to_submit_max_ms = 0.0
tx_submit_gap_max_ms = 0.0
tx_clock_fire_to_drain_max_ms = 0.0
tx_max_sent_fps = 0.0
tx_stale_queue_catch_up = 0
tx_chunk_cap_bytes = 0
tx_writer_clock_ok = 0
tx_writer_clock_strict_ok = 0
tx_send_scheduler_ok = 0
tx_wire_batch_single_frames = 0
tx_wire_batch_multi_frames = 0
tx_wire_single_unbatched_frames = 0
remote_realtime_activity_active = 0
sck_cadence_timer_fires = 0
sck_cadence_submitted = 0
sck_cadence_catch_up_frames = 0
sck_cadence_batch_max = 0
min_capture_fps = None
min_meaningful_fps = None
source_render_fps_min = None
source_render_gap_max_ms = 0.0
source_last_render_age_max_ms = 0.0
source_window_visible = 0
source_window_occlusion_visible = 0
source_frame_start = None
source_frame_end = None
source_time_start = None
source_time_end = None
for line in host_lines:
    timestamp = parse_iso_timestamp(line)
    if timestamp is not None and timestamp <= pass_time and "mac-remote-realtime-activity active=1" in line:
        if int_metric(line, "appNapDisabled") == 1:
            remote_realtime_activity_active = 1
    if timestamp is None or timestamp < host_window_start or timestamp > pass_time:
        continue
    if "smoke-capture-source active=1" in line:
        source_count += 1
        source_render_fps = float_metric(line, "renderFPS")
        source_render_fps_min = source_render_fps if source_render_fps_min is None else min(source_render_fps_min, source_render_fps)
        source_render_gap_max_ms = max(source_render_gap_max_ms, float_metric(line, "renderGapMaxMs"))
        source_last_render_age_max_ms = max(source_last_render_age_max_ms, float_metric(line, "lastRenderAgeMs"))
        source_window_visible = max(source_window_visible, int_metric(line, "windowVisible"))
        source_window_occlusion_visible = max(source_window_occlusion_visible, int_metric(line, "windowOcclusionVisible"))
        source_frame = int_metric(line, "frame")
        source_frame_start = source_frame if source_frame_start is None else min(source_frame_start, source_frame)
        source_frame_end = source_frame if source_frame_end is None else max(source_frame_end, source_frame)
        source_time_start = timestamp if source_time_start is None else min(source_time_start, timestamp)
        source_time_end = timestamp if source_time_end is None else max(source_time_end, timestamp)
    if "mac-sck-tx " in line and "codec=hevc" in line and "capturesAudio=false" in line:
        sck_count += 1
        capture_fps = float_metric(line, "captureFPS")
        meaningful_fps = float_metric(line, "meaningfulFPS")
        min_capture_fps = capture_fps if min_capture_fps is None else min(min_capture_fps, capture_fps)
        min_meaningful_fps = meaningful_fps if min_meaningful_fps is None else min(min_meaningful_fps, meaningful_fps)
        sck_sample_ms += int_metric(line, "sampleMs")
        sck_captured_frames += int_metric(line, "captured")
        sck_meaningful_frames += int_metric(line, "meaningful")
        sck_encoded_frames += int_metric(line, "encoded")
        sck_source_frame_age_max_ms = max(sck_source_frame_age_max_ms, float_metric(line, "sourceFrameAgeMaxMs"))
        sck_source_frame_repeat_max = max(sck_source_frame_repeat_max, int_metric(line, "sourceFrameRepeatMax"))
        if metric(line, "visible") != expected_frame:
            fail(f"Mac SCK visible size is not {expected_frame}: {line.strip()}")
        if int_metric(line, "encodeFailures") != 0:
            fail(f"Mac HEVC encode failures were nonzero: {line.strip()}")
        sck_cadence_timer_fires += int_metric(line, "cadenceTimerFires")
        sck_cadence_submitted += int_metric(line, "cadenceSubmitted")
        sck_cadence_catch_up_frames += int_metric(line, "cadenceCatchUpFrames")
        sck_cadence_batch_max = max(sck_cadence_batch_max, int_metric(line, "cadenceBatchMax"))
    if "mac-remote-frame-tx " in line:
        tx_count += 1
        tx_sample_ms += int_metric(line, "sampleMs")
        tx_sent_frames += int_metric(line, "sent")
        tx_chunked_frames += int_metric(line, "chunkedFrames")
        tx_sent_chunks += int_metric(line, "sentChunks")
        line_sent_frames = int_metric(line, "sent")
        line_wire_batch_single_frames = int_metric(line, "wireBatchSingleFrames")
        line_wire_batch_multi_frames = int_metric(line, "wireBatchMultiFrames")
        line_wire_single_unbatched_frames = int_metric(line, "wireSingleUnbatchedFrames")
        tx_wire_batch_single_frames += line_wire_batch_single_frames
        tx_wire_batch_multi_frames += line_wire_batch_multi_frames
        tx_wire_single_unbatched_frames += line_wire_single_unbatched_frames
        tx_max_chunks_per_frame = max(tx_max_chunks_per_frame, int_metric(line, "maxChunksPerFrame"))
        line_backpressure = int_metric(line, "backpressure")
        line_raw_backpressure = int_metric(line, "rawBackpressure")
        line_ordered_throttle = int_metric(line, "orderedThrottle")
        line_queue_backlog = int_metric(line, "queueBacklog")
        tx_backpressure += line_backpressure
        tx_raw_backpressure += line_raw_backpressure
        tx_ordered_throttle += line_ordered_throttle
        tx_queue_backlog += line_queue_backlog
        tx_queued_max = max(tx_queued_max, int_metric(line, "queuedMax"))
        tx_inflight_max = max(tx_inflight_max, int_metric(line, "inFlightMax"))
        tx_content_backlog_max = max(tx_content_backlog_max, int_metric(line, "contentBacklogMax"))
        tx_content_backlog_limit = max(tx_content_backlog_limit, int_metric(line, "contentBacklogLimit"))
        tx_content_backlog_bytes_max = max(tx_content_backlog_bytes_max, int_metric(line, "contentBacklogBytesMax"))
        tx_content_backlog_byte_limit = max(tx_content_backlog_byte_limit, int_metric(line, "contentBacklogByteLimit"))
        tx_max_frames_per_drain = max(tx_max_frames_per_drain, int_metric(line, "maxFramesPerDrain"))
        tx_schedule_budget_max = max(tx_schedule_budget_max, int_metric(line, "scheduleBudgetMax"))
        tx_missed_cadence_slots_max = max(tx_missed_cadence_slots_max, int_metric(line, "missedCadenceSlotsMax"))
        tx_content_backlog_full += int_metric(line, "contentBacklogFull")
        tx_oldest_content_backlog_ms = max(tx_oldest_content_backlog_ms, float_metric(line, "oldestContentBacklogMs"))
        tx_queue_age_max_ms = max(tx_queue_age_max_ms, float_metric(line, "queueAgeMaxMs"))
        tx_dequeued_age_max_ms = max(tx_dequeued_age_max_ms, float_metric(line, "dequeuedAgeMaxMs"))
        tx_max_send_ms = max(tx_max_send_ms, float_metric(line, "maxSendMs"))
        tx_schedule_gap_max_ms = max(tx_schedule_gap_max_ms, float_metric(line, "scheduleGapMaxMs"))
        tx_schedule_jitter_max_ms = max(tx_schedule_jitter_max_ms, float_metric(line, "scheduleJitterMaxMs"))
        tx_completion_gap_max_ms = max(tx_completion_gap_max_ms, float_metric(line, "completionGapMaxMs"))
        tx_content_callback_gap_max_ms = max(tx_content_callback_gap_max_ms, float_metric(line, "contentCallbackGapMaxMs"))
        tx_content_actor_hop_max_ms = max(tx_content_actor_hop_max_ms, float_metric(line, "contentActorHopMaxMs"))
        tx_encoded_to_submit_max_ms = max(tx_encoded_to_submit_max_ms, float_metric(line, "encodedToSubmitMaxMs"))
        tx_submit_gap_max_ms = max(tx_submit_gap_max_ms, float_metric(line, "submitGapMaxMs"))
        tx_clock_fire_to_drain_max_ms = max(tx_clock_fire_to_drain_max_ms, float_metric(line, "clockFireToDrainMaxMs"))
        tx_max_sent_fps = max(tx_max_sent_fps, float_metric(line, "sentFPS"))
        tx_stale_queue_catch_up += int_metric(line, "staleQueueCatchUp")
        tx_chunk_cap_bytes = max(tx_chunk_cap_bytes, int_metric(line, "chunkCapBytes"))
        if metric(line, "transport") != "sbc2-chunked-v1":
            fail(f"Mac remote tx did not use sbc2-chunked-v1: {line.strip()}")
        if metric(line, "source") != "encoded-direct-pump":
            fail(f"Mac remote tx did not prove direct encoded-frame handoff to the sender pump: {line.strip()}")
        if line_sent_frames > 0 and metric(line, "chunkSend") not in ("single-unbatched", "batch-single", "batch-multi", "batch-mixed"):
            fail(f"Mac remote tx did not expose a real Network.framework send mode for SBC2 frames: {line.strip()}")
        if (
            line_wire_single_unbatched_frames > 0
            and line_wire_batch_multi_frames == 0
            and int_metric(line, "maxChunksPerFrame") != 1
        ):
            fail(f"Mac remote tx used single-message sends for multi-chunk SBC2 frames: {line.strip()}")
        if line_wire_batch_single_frames + line_wire_batch_multi_frames + line_wire_single_unbatched_frames != line_sent_frames:
            fail(f"Mac remote tx send-mode evidence did not cover every sent frame: {line.strip()}")
        if metric(line, "writerClock") != "dispatch-source-userinteractive":
            fail(f"Mac remote tx did not use the strict DispatchSource writer clock: {line.strip()}")
        tx_writer_clock_ok += 1
        if int_metric(line, "writerClockStrict") != 1:
            fail(f"Mac remote tx did not prove strict DispatchSource timer mode: {line.strip()}")
        tx_writer_clock_strict_ok += 1
        if metric(line, "sendScheduler") != "dispatch-clock-only":
            fail(f"Mac remote tx was not exclusively scheduled by the DispatchSource writer clock: {line.strip()}")
        tx_send_scheduler_ok += 1
        if int_metric(line, "chunkCapBytes") != 256 * 1024:
            fail(f"Mac remote SBC2 chunk cap did not match the LAN receive window: {line.strip()}")
        if int_metric(line, "dropped") != 0:
            fail(f"Mac remote dropped frames were nonzero: {line.strip()}")
        if line_backpressure != 0:
            fail(f"Mac remote harmful backpressure was nonzero: {line.strip()}")
        if line_queue_backlog != 0:
            fail(f"Mac remote queue backlog was nonzero: {line.strip()}")
        if int_metric(line, "contentBacklogLimit") != sender_content_backlog_frame_limit:
            fail(f"Mac remote contentBacklogLimit drifted from the strict byte-bounded chunked contentProcessed pipeline: {line.strip()}")
        if int_metric(line, "contentBacklogByteLimit") != 12 * 256 * 1024:
            fail(f"Mac remote contentBacklogByteLimit drifted from the bounded chunked contentProcessed pipeline: {line.strip()}")
        if int_metric(line, "maxFramesPerDrain") != sender_cadence_catch_up_limit:
            fail(f"Mac remote maxFramesPerDrain was not the bounded strict cadence path: {line.strip()}")
        if int_metric(line, "scheduleBudgetMax") > sender_cadence_catch_up_limit:
            fail(f"Mac remote scheduleBudgetMax exceeded bounded strict cadence recovery: {line.strip()}")
        if int_metric(line, "missedCadenceSlotsMax") > bounded_missed_cadence_slots_limit:
            fail(f"Mac remote missed cadence slots exceeded strict zero-miss cadence budget: {line.strip()}")
        if metric(line, "waitingForSync") != "false":
            fail(f"Mac remote was waiting for sync: {line.strip()}")

if sck_count == 0:
    fail("no Mac HEVC SCK telemetry samples inside final pass window")
if tx_count == 0:
    fail("no Mac remote frame tx telemetry samples inside final pass window")
if source_count == 0:
    fail("no Mac smoke source heartbeat samples inside final pass window")
if sck_count < minimum_window_samples:
    fail(f"too few Mac HEVC SCK telemetry samples inside final pass window: count={sck_count} required={minimum_window_samples}")
if tx_count < minimum_window_samples:
    fail(f"too few Mac remote frame tx telemetry samples inside final pass window: count={tx_count} required={minimum_window_samples}")
if source_count < minimum_source_samples:
    fail(f"too few Mac smoke source heartbeat samples inside final pass window: count={source_count} required={minimum_source_samples}")
if source_frame_start is None or source_frame_end is None or source_frame_end <= source_frame_start:
    fail(f"Mac smoke source frame counter did not progress inside final pass window: frames={source_frame_start}->{source_frame_end}")
if source_time_start is None or source_time_end is None or source_time_end <= source_time_start:
    fail(f"Mac smoke source heartbeat timestamps did not span the final pass window: start={source_time_start} end={source_time_end}")
source_observed_seconds = (source_time_end - source_time_start).total_seconds()
if source_observed_seconds + 0.25 < minimum_source_observed_seconds:
    fail(
        "Mac smoke source heartbeat coverage was too short inside final pass window: "
        f"observedSeconds={source_observed_seconds:.2f} requiredSeconds={minimum_source_observed_seconds:.2f}"
    )
source_frame_delta = source_frame_end - source_frame_start
source_render_progress_fps = source_frame_delta / max(source_observed_seconds, 0.001)
source_render_gap_budget_exceeded = int(source_render_gap_max_ms > max_sck_source_frame_age_ms)
source_last_render_age_budget_exceeded = int(source_last_render_age_max_ms > max_sck_source_frame_age_ms)
if source_window_visible != 1 or source_window_occlusion_visible != 1:
    fail(f"Mac smoke source was not visible in the final pass window: windowVisible={source_window_visible} windowOcclusionVisible={source_window_occlusion_visible}")
if source_render_fps_min is None:
    fail("Mac smoke source heartbeat did not expose renderFPS inside final pass window")
# Source-helper render-gap and frame-age spikes are diagnostic. The fail-closed
# gates remain on visible source progress, stale-frame repeat count, encoded/sent
# cadence, transport bounds, iOS receive cadence, and iOS Metal delivery.
if source_frame_start is None or source_frame_end is None or source_frame_end <= source_frame_start:
    fail(f"Mac smoke source frame counter did not advance inside final pass window: frame={source_frame_start}->{source_frame_end}")
if tx_writer_clock_ok < tx_count:
    fail(f"Mac remote tx did not prove DispatchSource writer clock on every sample: ok={tx_writer_clock_ok} count={tx_count}")
if tx_writer_clock_strict_ok < tx_count:
    fail(f"Mac remote tx did not prove strict DispatchSource timer mode on every sample: ok={tx_writer_clock_strict_ok} count={tx_count}")
if tx_send_scheduler_ok < tx_count:
    fail(f"Mac remote tx did not prove DispatchSource-only scheduling on every sample: ok={tx_send_scheduler_ok} count={tx_count}")
if remote_realtime_activity_active != 1:
    fail("Mac remote sender did not prove realtime activity/App Nap protection before final pass")
if sck_sample_ms <= 0:
    fail("Mac HEVC SCK telemetry did not report a positive aggregate sample window")
if tx_sample_ms <= 0:
    fail("Mac remote tx telemetry did not report a positive aggregate sample window")
if sck_cadence_timer_fires <= 0:
    fail("Mac HEVC SCK telemetry did not prove display cadence timer activity inside final pass window")
if sck_cadence_submitted <= 0:
    fail("Mac HEVC SCK telemetry did not prove display cadence frame submissions inside final pass window")
if sck_cadence_batch_max < 1:
    fail(f"Mac HEVC SCK display cadence batch max was invalid: cadenceBatchMax={sck_cadence_batch_max}")
if sck_cadence_batch_max > sck_cadence_catch_up_limit:
    fail(f"Mac HEVC SCK display cadence exceeded bounded producer recovery inside final pass window: cadenceBatchMax={sck_cadence_batch_max} limit={sck_cadence_catch_up_limit}")
sck_encoded_fps = sck_encoded_frames * 1000.0 / sck_sample_ms
sck_capture_fps = sck_captured_frames * 1000.0 / sck_sample_ms
sck_meaningful_fps = sck_meaningful_frames * 1000.0 / sck_sample_ms
tx_sent_fps = tx_sent_frames * 1000.0 / tx_sample_ms
if min_capture_fps is None or min_meaningful_fps is None:
    fail("Mac HEVC SCK telemetry did not expose captureFPS/meaningfulFPS inside final pass window")
sck_source_frame_age_budget_exceeded = int(sck_source_frame_age_max_ms > max_sck_source_frame_age_ms)
if sck_source_frame_age_budget_exceeded:
    fail(
        "Mac HEVC SCK source frame age exceeded live-source budget inside final pass window: "
        f"sourceFrameAgeMaxMs={sck_source_frame_age_max_ms:.1f} limit={max_sck_source_frame_age_ms:.1f}"
    )
if sck_source_frame_repeat_max > max_sck_source_frame_repeat:
    fail(f"Mac HEVC SCK repeated stale source frames inside final pass window: sourceFrameRepeatMax={sck_source_frame_repeat_max} limit={max_sck_source_frame_repeat}")
if sck_encoded_fps < min_fps:
    fail(f"Mac HEVC aggregate encodedFPS below {min_fps}: encoded={sck_encoded_frames} sampleMs={sck_sample_ms} fps={sck_encoded_fps:.1f}")
if tx_sent_fps < min_fps:
    fail(f"Mac remote aggregate sentFPS below {min_fps}: sent={tx_sent_frames} sampleMs={tx_sample_ms} fps={tx_sent_fps:.1f}")
if tx_sent_fps > max_transport_fps:
    fail(f"Mac remote aggregate sentFPS exceeded strict target: sent={tx_sent_frames} sampleMs={tx_sample_ms} fps={tx_sent_fps:.1f} target={target_fps:.1f}")
if tx_max_sent_fps > max_transport_fps:
    fail(f"Mac remote burst sentFPS exceeded strict target: maxSentFPS={tx_max_sent_fps:.1f} target={target_fps:.1f}")
if tx_chunked_frames != tx_sent_frames:
    fail(f"Mac remote tx accepted non-SBC2 screen frames: sent={tx_sent_frames} chunkedFrames={tx_chunked_frames}")
if tx_wire_batch_single_frames + tx_wire_batch_multi_frames + tx_wire_single_unbatched_frames != tx_sent_frames:
    fail(
        "Mac remote tx did not prove an explicit Network.framework send mode for every final-window frame: "
        f"singleUnbatched={tx_wire_single_unbatched_frames} batchSingle={tx_wire_batch_single_frames} batchMulti={tx_wire_batch_multi_frames} sent={tx_sent_frames}"
    )
if tx_wire_batch_single_frames + tx_wire_batch_multi_frames + tx_wire_single_unbatched_frames <= 0:
    fail("Mac remote tx did not expose positive real send-mode evidence inside final pass window")
if tx_sent_chunks < tx_chunked_frames:
    fail(f"Mac remote tx reported fewer SBC2 chunks than frames: sentChunks={tx_sent_chunks} chunkedFrames={tx_chunked_frames}")
if tx_max_chunks_per_frame < 1:
    fail(f"Mac remote tx maxChunksPerFrame was invalid: maxChunksPerFrame={tx_max_chunks_per_frame}")
if tx_max_chunks_per_frame != 1:
    fail(f"Mac remote tx emitted multi-chunk HEVC frames inside final pass window: maxChunksPerFrame={tx_max_chunks_per_frame}")
if tx_queued_max > strict_mac_sender_queue_limit:
    fail(f"Mac remote queuedMax exceeded ordered SBC2 cadence buffer inside final pass window: queuedMax={tx_queued_max} limit={strict_mac_sender_queue_limit}")
if tx_content_backlog_limit != sender_content_backlog_frame_limit:
    fail(f"Mac remote contentBacklogLimit did not prove the strict byte-bounded chunked contentProcessed pipeline: limit={tx_content_backlog_limit}")
if tx_content_backlog_byte_limit != 12 * 256 * 1024:
    fail(f"Mac remote contentBacklogByteLimit did not prove the bounded chunked contentProcessed pipeline: limit={tx_content_backlog_byte_limit}")
if tx_max_frames_per_drain != sender_cadence_catch_up_limit:
    fail(f"Mac remote maxFramesPerDrain did not prove bounded strict cadence recovery: maxFramesPerDrain={tx_max_frames_per_drain} expected={sender_cadence_catch_up_limit}")
if tx_schedule_budget_max > sender_cadence_catch_up_limit:
    fail(f"Mac remote scheduleBudgetMax exceeded bounded strict cadence recovery: scheduleBudgetMax={tx_schedule_budget_max} limit={sender_cadence_catch_up_limit}")
if tx_missed_cadence_slots_max > bounded_missed_cadence_slots_limit:
    fail(f"Mac remote missed cadence slots exceeded strict zero-miss cadence budget inside final pass window: missedCadenceSlotsMax={tx_missed_cadence_slots_max} limit={bounded_missed_cadence_slots_limit}")
if tx_content_backlog_max > sender_content_backlog_frame_limit:
    fail(f"Mac remote contentProcessed backlog exceeded the strict frame limit inside final pass window: contentBacklogMax={tx_content_backlog_max} limit={sender_content_backlog_frame_limit}")
if tx_content_backlog_max >= sender_content_backlog_frame_limit:
    fail(f"Mac remote contentProcessed backlog hit the strict frame ceiling inside final pass window: contentBacklogMax={tx_content_backlog_max} limit={sender_content_backlog_frame_limit}")
if tx_content_backlog_bytes_max >= 12 * 256 * 1024:
    fail(f"Mac remote contentProcessed byte backlog hit the bounded ceiling inside final pass window: contentBacklogBytesMax={tx_content_backlog_bytes_max}")
if tx_content_backlog_full != 0:
    fail(f"Mac remote contentProcessed backlog hit the strict frame/3072KiB ceiling inside final pass window: contentBacklogFull={tx_content_backlog_full} frameLimit={sender_content_backlog_frame_limit}")
if tx_max_send_ms > 200.0:
    fail(f"Mac remote contentProcessed latency exceeded the 200ms budget inside final pass window: maxSendMs={tx_max_send_ms:.1f}")
max_bounded_schedule_gap_ms = 50.0
if tx_schedule_gap_max_ms > max_bounded_schedule_gap_ms:
    fail(f"Mac remote sender schedule gap exceeded 50ms inside final pass window: scheduleGapMaxMs={tx_schedule_gap_max_ms:.1f} budgetMs={max_bounded_schedule_gap_ms:.1f}")
if tx_schedule_jitter_max_ms > max_bounded_schedule_gap_ms:
    fail(f"Mac remote sender schedule jitter exceeded bounded recovery budget inside final pass window: scheduleJitterMaxMs={tx_schedule_jitter_max_ms:.1f} budgetMs={max_bounded_schedule_gap_ms:.1f}")
if tx_completion_gap_max_ms > 200.0:
    fail(f"Mac remote contentProcessed completion gap exceeded the 200ms budget inside final pass window: completionGapMaxMs={tx_completion_gap_max_ms:.1f}")
if tx_content_callback_gap_max_ms > 200.0:
    fail(f"Mac remote contentProcessed callback gap exceeded the 200ms budget inside final pass window: contentCallbackGapMaxMs={tx_content_callback_gap_max_ms:.1f}")
if tx_content_actor_hop_max_ms > 25.0:
    fail(f"Mac remote contentProcessed actor hop exceeded 25ms inside final pass window: contentActorHopMaxMs={tx_content_actor_hop_max_ms:.1f}")
if tx_clock_fire_to_drain_max_ms > 25.0:
    fail(f"Mac remote writer-clock fire to actor drain exceeded 25ms inside final pass window: clockFireToDrainMaxMs={tx_clock_fire_to_drain_max_ms:.1f}")
if tx_encoded_to_submit_max_ms > 100.0:
    fail(f"Mac remote encoded-to-sender actor delay exceeded 100ms inside final pass window: encodedToSubmitMaxMs={tx_encoded_to_submit_max_ms:.1f}")
if tx_submit_gap_max_ms > frame_budget_ms * 4.0:
    fail(f"Mac remote encoded-frame submit gap exceeded four-frame budget inside final pass window: submitGapMaxMs={tx_submit_gap_max_ms:.1f}")
if tx_oldest_content_backlog_ms > 300.0:
    fail(f"Mac remote oldest contentProcessed backlog exceeded 300ms inside final pass window: oldestContentBacklogMs={tx_oldest_content_backlog_ms:.1f}")
if tx_queue_age_max_ms > 100.0:
    fail(f"Mac remote queued frame age exceeded 100ms inside final pass window: queueAgeMaxMs={tx_queue_age_max_ms:.1f}")
if tx_dequeued_age_max_ms > 100.0:
    fail(f"Mac remote dequeued frame age exceeded 100ms inside final pass window: dequeuedAgeMaxMs={tx_dequeued_age_max_ms:.1f}")
if tx_stale_queue_catch_up != 0:
    fail(f"Mac remote stale queue catch-up was nonzero inside final pass window: staleQueueCatchUp={tx_stale_queue_catch_up}")
if audio_status_samples < minimum_window_samples:
    fail(f"iOS audio continuity telemetry had too few final-window samples: samples={audio_status_samples} required={minimum_window_samples}")
if audio_recv_start is None or audio_recv_end is None or audio_recv_end <= audio_recv_start:
    fail(f"iOS audio receive did not progress inside final pass window: recv={audio_recv_start}->{audio_recv_end}")
if audio_decoded_start is None or audio_decoded_end is None or audio_decoded_end <= audio_decoded_start:
    fail(f"iOS audio decode did not progress inside final pass window: decoded={audio_decoded_start}->{audio_decoded_end}")
if audio_played_start is None or audio_played_end is None or audio_played_end <= audio_played_start:
    fail(f"iOS audio playback did not progress inside final pass window: played={audio_played_start}->{audio_played_end}")

sck_source_callback_bottleneck = int(
    sck_capture_fps < min_fps
    or sck_meaningful_fps < min_fps
    or min_capture_fps < min_fps
    or min_meaningful_fps < min_fps
)

print(
    "remote performance window validation passed: "
    f"iosStatus={ios_status_count} metal={metal_count} macSCK={sck_count} macTx={tx_count} "
    f"iosWindowFPS={reported_window_fps:.1f} iosWindowRxFPS={reported_window_rx_fps:.1f} "
    f"metalInputFPS={metal_input_fps:.1f} metalDrawCallbackFPS={metal_draw_callback_fps:.1f} metalDisplayFPS={metal_displayed_fps:.1f} metalSubmittedFPS={metal_submitted_fps:.1f} "
    f"metalCoalesced={metal_coalesced_before_draw} metalCoalescedAllowed={max_allowed_metal_coalesced} metalRealtimeReplacement={metal_realtime_replacement_before_draw} metalManualDraw={metal_manual_draw} metalQueueCapacityMax={metal_queue_capacity_max} metalQueueDepthMax={metal_queue_depth_max} metalQueueBackpressure={metal_queue_backpressure} "
    f"metalFrameAgeMaxMs={metal_frame_age_max_ms:.1f} metalDisplayLinkPumpFPS={metal_display_link_pump_fps} "
    f"lanRxMaxGapMs={lan_rx_max_gap_ms:.1f} lanSampledScreenFPS={lan_rx_screen_fps:.1f} lanMaxScreenFPS={lan_rx_max_screen_fps:.1f} "
    f"audioSamples={audio_status_samples} audioRecv={audio_recv_start}->{audio_recv_end} audioDecoded={audio_decoded_start}->{audio_decoded_end} audioPlayed={audio_played_start}->{audio_played_end} "
    f"lanSourceSamples={lan_rx_source_samples} lanSourceGapMaxMs={lan_rx_source_gap_max_ms:.1f} "
    f"lanSourceToReadMaxMs={lan_rx_source_to_read_max_ms:.1f} lanSourceToReadUnsyncedClockSamples={lan_rx_source_to_read_unsynced_clock_samples}/{lan_rx_count} "
    f"lanSBC2Frames={lan_rx_sbc2_frames} lanSBC2Chunks={lan_rx_sbc2_chunks} "
    f"lanScreenDeliveryAttempted={lan_rx_screen_delivery_attempted} lanScreenDeliveryDelivered={lan_rx_screen_delivery_delivered} lanScreenDeliveryFPS={lan_rx_screen_delivery_fps:.1f} lanScreenDeliveryBackpressure={lan_rx_screen_delivery_backpressure} "
    f"lanRawChunks={lan_rx_raw_chunks} lanRawChunkGapMaxMs={lan_rx_raw_chunk_gap_max_ms:.1f} "
    f"lanMaxMainHopMs={lan_rx_main_hop_max_ms:.1f} lanRawChunkMainHopMaxMs={lan_rx_raw_chunk_main_hop_max_ms:.1f} lanReadAheadSamples={lan_rx_read_ahead_samples} "
    f"lanParserDrainMaxMs={lan_rx_parser_drain_max_ms:.1f} lanParserBudgetMsMax={lan_rx_parser_budget_ms_max:.1f} lanParserBudgetHits={lan_rx_parser_budget_hits} "
    f"macSourceSamples={source_count} macSourceObservedSeconds={source_observed_seconds:.2f} macSourceRenderProgressFPS={source_render_progress_fps:.1f} macSourceRenderFPSMin={source_render_fps_min:.1f} macSourceRenderGapMaxMs={source_render_gap_max_ms:.1f} macSourceRenderGapBudgetMs={max_sck_source_frame_age_ms:.1f} macSourceRenderGapBudgetExceeded={source_render_gap_budget_exceeded} macSourceLastRenderAgeMaxMs={source_last_render_age_max_ms:.1f} macSourceLastRenderAgeBudgetExceeded={source_last_render_age_budget_exceeded} macSourceFrames={source_frame_start}->{source_frame_end} "
    f"macCaptureFPS={sck_capture_fps:.1f} macMeaningfulFPS={sck_meaningful_fps:.1f} "
    f"macEncodedFPS={sck_encoded_fps:.1f} macSentFPS={tx_sent_fps:.1f} "
    f"macSourceFrameAgeMaxMs={sck_source_frame_age_max_ms:.1f} macSourceFrameAgeBudgetMs={max_sck_source_frame_age_ms:.1f} macSourceFrameAgeBudgetExceeded={sck_source_frame_age_budget_exceeded} macSourceFrameRepeatMax={sck_source_frame_repeat_max} "
    f"macSCKSourceCallbackBottleneck={sck_source_callback_bottleneck} "
    f"macChunkedFrames={tx_chunked_frames} macSentChunks={tx_sent_chunks} macMaxChunksPerFrame={tx_max_chunks_per_frame} "
    f"macWireBatchSingleFrames={tx_wire_batch_single_frames} macWireBatchMultiFrames={tx_wire_batch_multi_frames} macWireSingleUnbatchedFrames={tx_wire_single_unbatched_frames} "
    f"macChunkCapBytes={tx_chunk_cap_bytes} macEncoderGOP={encoder_key_interval} macEncoderKeyDurationMs={encoder_key_duration_ms} "
    f"macEncoderLowLatencyRateControl={encoder_low_latency_rate_control} "
    f"macSCKCatchUpLimit={encoder_cadence_catch_up_limit} macEncoderBurstLimitBytes={encoder_burst_limit_bytes} "
    f"macSCKCadenceTimerFires={sck_cadence_timer_fires} macSCKCadenceSubmitted={sck_cadence_submitted} "
    f"macSCKCadenceCatchUpFrames={sck_cadence_catch_up_frames} macSCKCadenceBatchMax={sck_cadence_batch_max} "
    f"macEncoderBurstWindowMs={encoder_burst_window_ms} macEncoderDataRateLimitsStatus={encoder_data_rate_limits_status} "
    f"macEncoderDataRateLimitsReadbackStatus={encoder_data_rate_limits_readback_status} macEncoderDataRateLimitsApplied={encoder_data_rate_limits_applied} "
    f"macEncoderReadbackBurstLimitBytes={encoder_readback_burst_limit_bytes} macEncoderReadbackBurstWindowMs={encoder_readback_burst_window_ms} "
    f"macMaxFramesPerDrain={tx_max_frames_per_drain} "
    f"macScheduleBudgetMax={tx_schedule_budget_max} macMissedCadenceSlotsMax={tx_missed_cadence_slots_max} "
    f"macBackpressure={tx_backpressure} macRawBackpressure={tx_raw_backpressure} "
    f"macOrderedThrottle={tx_ordered_throttle} macQueueBacklog={tx_queue_backlog} "
    f"macQueuedMax={tx_queued_max} macInFlightMax={tx_inflight_max} "
    f"macContentBacklogMax={tx_content_backlog_max} macContentBacklogLimit={tx_content_backlog_limit} "
    f"macContentBacklogFull={tx_content_backlog_full} macOldestContentBacklogMs={tx_oldest_content_backlog_ms:.1f} "
    f"macQueueAgeMaxMs={tx_queue_age_max_ms:.1f} macDequeuedAgeMaxMs={tx_dequeued_age_max_ms:.1f} "
    f"macMaxSendMs={tx_max_send_ms:.1f} macMaxSentFPS={tx_max_sent_fps:.1f} "
    f"macScheduleGapMaxMs={tx_schedule_gap_max_ms:.1f} macScheduleJitterMaxMs={tx_schedule_jitter_max_ms:.1f} "
    f"macCompletionGapMaxMs={tx_completion_gap_max_ms:.1f} macContentCallbackGapMaxMs={tx_content_callback_gap_max_ms:.1f} "
    f"macContentActorHopMaxMs={tx_content_actor_hop_max_ms:.1f} "
    f"macClockFireToDrainMaxMs={tx_clock_fire_to_drain_max_ms:.1f} "
    f"macEncodedToSubmitMaxMs={tx_encoded_to_submit_max_ms:.1f} macSubmitGapMaxMs={tx_submit_gap_max_ms:.1f} "
    f"macStaleQueueCatchUp={tx_stale_queue_catch_up} "
    f"macCaptureMin={min_capture_fps:.1f} macMeaningfulMin={min_meaningful_fps:.1f}"
)
PY
}

launch_result_indicates_profile_trust_failure() {
  [[ -f "$LAUNCH_RESULT_JSON" ]] \
    && grep -qE 'invalid code signature|inadequate entitlements|profile has not been explicitly trusted' "$LAUNCH_RESULT_JSON"
}

launch_result_indicates_locked_device() {
  { [[ -f "$LAUNCH_RESULT_JSON" ]] && grep -qE 'Locked|could not be unlocked|device.*locked|Device.*locked|RequestDenied' "$LAUNCH_RESULT_JSON"; } \
    || { [[ -f "$IOS_CONSOLE_STDERR" ]] && grep -qE 'Locked|could not be unlocked|device.*locked|Device.*locked|RequestDenied' "$IOS_CONSOLE_STDERR"; }
}

launch_result_indicates_explicit_failure() {
  [[ -f "$LAUNCH_RESULT_JSON" ]] \
    && grep -qE '"outcome"[[:space:]]*:[[:space:]]*"failed"|CoreDeviceError|FBSOpenApplication' "$LAUNCH_RESULT_JSON"
}

report_ios_launch_failure() {
  local reason="$1"
  copy_ios_status
  echo "iOS remote smoke app launch failed before P2P handshake: ${reason}" >&2
  echo "This is a real-device launch/signing stage failure, not a P2P handshake or media pass." >&2
  echo "---- iOS launch result ($LAUNCH_RESULT_JSON) ----" >&2
  skybridge_smoke_cat_redacted "$IOS_DEVICE_LABEL" "$LAUNCH_RESULT_JSON" "$IOS_DEVICE_ID" >&2 || true
  echo "---- iOS console stderr ($IOS_CONSOLE_STDERR) ----" >&2
  skybridge_smoke_tail_redacted "$IOS_DEVICE_LABEL" 80 "$IOS_CONSOLE_STDERR" "$IOS_DEVICE_ID" >&2 || true
  echo "---- iOS live console tail ($IOS_STATUS_CONSOLE_LIVE) ----" >&2
  skybridge_smoke_tail_redacted "$IOS_DEVICE_LABEL" 80 "$IOS_STATUS_CONSOLE_LIVE" "$IOS_DEVICE_ID" >&2 || true
}

validate_ios_launch_notice_identity_env() {
  local validation_source
  validation_source="$(python3 - "$LAUNCH_RESULT_JSON" "$IOS_ENV_JSON" <<'PY'
import json
import sys

launch_path, expected_env_json = sys.argv[1:]
required = [
    "SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME",
    "SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID",
]

try:
    expected_env = json.loads(expected_env_json)
except json.JSONDecodeError as exc:
    print(f"Unable to parse intended iOS launch environment: {exc}", file=sys.stderr)
    raise SystemExit(1)

source = "intended-env"
launched_env = expected_env
try:
    with open(launch_path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    candidate_env = (
        payload.get("result", {})
        .get("launchOptions", {})
        .get("environmentVariables", {})
    )
    if isinstance(candidate_env, dict) and candidate_env:
        launched_env = candidate_env
        source = "devicectl-launch-json"
except (FileNotFoundError, json.JSONDecodeError):
    pass

missing = []
for key in required:
    value = launched_env.get(key)
    if not isinstance(value, str) or not value.strip():
        missing.append(key)
    expected_value = expected_env.get(key)
    if isinstance(expected_value, str) and expected_value.strip() and value != expected_value:
        missing.append(f"{key}:mismatch")

if missing:
    print(
        "iOS launch missing required remote-control notice identity env: "
        + ",".join(missing),
        file=sys.stderr,
    )
    raise SystemExit(1)
print(source)
PY
)"
  local status=$?
  if (( status != 0 )); then
    append_host_status "failed stage=ios-launch phase=notice-identity-env reason=missing-ios-launch-env"
    return "$status"
  fi
  append_host_status "ios-launch notice-identity-env account=present nebula=present source=$validation_source"
}

terminate_ios_remote_smoke_app_for_notice_disconnect() {
  if [[ "${SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE:-0}" != "1" ]]; then
    return 0
  fi
  terminate_ios_remote_smoke_app_exact "remote-control-notice-disconnect-proof"
  copy_ios_status
}

generate_p2p_remote_control_approval_proof() {
  local status_path="${1:?missing P2P approval status path}"
  local output_path="${2:?missing P2P approval proof path}"
  python3 - "$status_path" "$output_path" <<'PY'
import json
import os
import re
import stat
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

status_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
metadata = status_path.lstat()
if not stat.S_ISREG(metadata.st_mode):
    raise SystemExit("P2P approval status input must be a regular file")
status = status_path.read_text(encoding="utf-8", errors="strict")

event_pattern = re.compile(
    r"\bremoteControlNotice(?P<event>Shown|PanelPresented|HumanApproved|Approved|Active)\s+"
    r"session=(?P<session>[^\s]+)\s+"
    r"session_ref=(?P<session_ref>ev1:[0-9a-f]{32})\s+"
    r"transport=p2p\b(?P<tail>[^\n]*)"
)
events_by_session: dict[tuple[str, str], list[tuple[str, int]]] = defaultdict(list)
active_sessions: set[tuple[str, str]] = set()
panel_contract_by_session: dict[tuple[str, str], bool] = {}
for match in event_pattern.finditer(status):
    event = match.group("event")
    session = match.group("session")
    session_ref = match.group("session_ref")
    key = (session, session_ref)
    tail = match.group("tail")
    if event == "PanelPresented":
        if re.search(r"\bphase=awaitingApproval\b", tail) is None:
            continue
        buttons_match = re.search(r"\bbuttons=([^\s]+)", tail)
        buttons = set(buttons_match.group(1).split(",")) if buttons_match else set()
        panel_contract_by_session[key] = {"approve", "reject"}.issubset(buttons)
    if event == "Active":
        active_sessions.add(key)
    events_by_session[key].append((event, match.start()))

expected_lifecycle = ["Shown", "PanelPresented", "HumanApproved", "Approved", "Active"]
valid_sessions = []
for key, events in events_by_session.items():
    lifecycle = [event for event, _ in events]
    if lifecycle == expected_lifecycle and panel_contract_by_session.get(key) is True:
        valid_sessions.append(key)

if len(valid_sessions) != 1:
    raise SystemExit("P2P approval proof requires exactly one strict same-session human lifecycle")
approved_key = valid_sessions[0]
session, session_ref = approved_key
if active_sessions != {approved_key}:
    raise SystemExit("P2P approval proof contains an active notice outside the strict human-approved session")

escaped_session = re.escape(session)
auto_patterns = (
    rf"\bremoteControlNoticeAutoApproved\s+session={escaped_session}(?=\s)[^\n]*\btransport=p2p\b",
    rf"\bremoteControlNoticeApproved\s+session={escaped_session}(?=\s)[^\n]*\btransport=p2p\b[^\n]*\bapprovalSource=(?:auto|runtime)\b",
    rf"(?m)^(?=[^\n]*\bsession={escaped_session}(?=\s))(?=[^\n]*\b(?:runtimeAutoApproval|autoApprove)=true\b)[^\n]*$",
)
runtime_auto_approval = any(re.search(pattern, status, re.IGNORECASE) for pattern in auto_patterns)
human_approval = "HumanApproved" in [event for event, _ in events_by_session[approved_key]]
if not human_approval or runtime_auto_approval:
    raise SystemExit("P2P approval proof did not establish exclusive human approval")

proof = {
    "schemaVersion": 2,
    "sessionRef": session_ref,
    "humanApproval": human_approval,
    "runtimeAutoApproval": runtime_auto_approval,
    "lifecycle": expected_lifecycle,
    "panelActionsVerified": panel_contract_by_session[approved_key],
}
output_path.parent.mkdir(parents=True, exist_ok=True)
descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output_path.name}.", dir=output_path.parent)
temporary_path = Path(temporary_name)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as handle:
        json.dump(proof, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_path, output_path)
finally:
    if temporary_path.exists():
        temporary_path.unlink()
print(session)
PY
}

write_p2p_remote_control_approval_proof() {
  local approved_session
  if ! approved_session="$(
    generate_p2p_remote_control_approval_proof "$HOST_STATUS" "$P2P_APPROVAL_PROOF"
  )"; then
    return 1
  fi
  if [[ -z "$approved_session" || "$approved_session" =~ [[:space:]] ]] \
    || (( ${#approved_session} > 256 )); then
    echo "P2P approval proof returned an invalid session identifier." >&2
    return 1
  fi
  P2P_NOTICE_SESSION="$approved_session"
}

wait_for_remote_control_notice_lifecycle() {
  if [[ "${SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE:-0}" != "1" ]]; then
    return 0
  fi

  wait_for_file_pattern "$HOST_STATUS" 'remoteControlNoticeShown .*transport=p2p' "$SMOKE_TIMEOUT_SECONDS" "macOS remote-control notice shown"
  wait_for_file_pattern "$HOST_STATUS" 'remoteControlNoticePanelPresented .*transport=p2p .*phase=awaitingApproval .*buttons=[^[:space:]]*(approve[^[:space:]]*reject|reject[^[:space:]]*approve)' "$SMOKE_TIMEOUT_SECONDS" "macOS P2P remote-control approval panel with approve/reject actions"
  echo "==> Waiting for the operator to approve the visible macOS P2P remote-control notice"
  wait_for_file_pattern "$HOST_STATUS" 'remoteControlNoticeHumanApproved .*transport=p2p' "$SMOKE_TIMEOUT_SECONDS" "human-approved macOS P2P remote-control notice"
  wait_for_file_pattern "$HOST_STATUS" 'remoteControlNoticeApproved .*transport=p2p' "$SMOKE_TIMEOUT_SECONDS" "operator-approved macOS P2P remote-control notice"
  wait_for_file_pattern "$HOST_STATUS" 'remoteControlNoticeActive .*transport=p2p' "$SMOKE_TIMEOUT_SECONDS" "active macOS P2P remote-control notice"
  write_p2p_remote_control_approval_proof
}

wait_for_same_session_notice_disconnected() {
  local started_at
  local lifecycle_status

  if [[ -z "$P2P_NOTICE_SESSION" ]]; then
    echo "Cannot verify P2P notice disconnect without the approved session identifier." >&2
    return 1
  fi
  started_at="$(date +%s)"
  while true; do
    fail_if_host_exited "same-session macOS remote-control notice disconnect" || return 1
    fail_if_smoke_source_exited "same-session macOS remote-control notice disconnect" || return 1
    if python3 "$ROOT_DIR/Scripts/check_p2p_notice_disconnect.py" \
      "$HOST_STATUS" \
      "$P2P_NOTICE_SESSION"; then
      return 0
    else
      lifecycle_status=$?
    fi
    if (( lifecycle_status == 2 )); then
      echo "P2P remote-control notice disconnect evidence is ambiguous or invalid." >&2
      print_smoke_tail_for_operator 80 "$HOST_STATUS"
      return 1
    fi
    if (( "$(date +%s)" - started_at >= 30 )); then
      echo "Timed out waiting for the approved P2P notice session to disconnect." >&2
      print_smoke_tail_for_operator 80 "$HOST_STATUS"
      return 1
    fi
    sleep 1
  done
}

wait_for_remote_control_notice_disconnected() {
  if [[ "${SKYBRIDGE_SMOKE_REQUIRE_REMOTE_CONTROL_NOTICE:-0}" != "1" ]]; then
    terminate_ios_remote_smoke_app_exact "smoke-complete"
    copy_ios_status
    return 0
  fi

  terminate_ios_remote_smoke_app_for_notice_disconnect
  wait_for_same_session_notice_disconnected
}

launch_ios_remote_smoke_app() {
  local started_at
  local attempt=1
  local handle_status
  started_at="$(date +%s)"
  while true; do
    if [[ "$IOS_PREINSTALL_ABSENCE_PROVEN" != "1" ]]; then
      echo "Refusing iOS smoke launch because pre-install app absence was not proven." >&2
      return 1
    fi
    rm -f "$LAUNCH_RESULT_JSON" "$IOS_STATUS_LOCAL" "$IOS_STATUS_CONSOLE_LIVE" "$IOS_STATUS_APP_CACHE_LOCAL" "$IOS_STATUS_CONSOLE_SNAPSHOT" "$IOS_LISTENER_STATUS_LOCAL" "$IOS_CONSOLE_STDERR"
    skybridge_ios_start_console_launch \
      "$IOS_DEVICE_ID" \
      "$IOS_BUNDLE_ID" \
      "$IOS_ENV_JSON" \
      "$IOS_CONSOLE_TOTAL_TIMEOUT_SECONDS" \
      "$LAUNCH_RESULT_JSON" \
      "$IOS_STATUS_CONSOLE_LIVE" \
      "$IOS_CONSOLE_STDERR" \
      IOS_CONSOLE_PID \
      1
    IOS_CONSOLE_HANDLE_STARTED=1

    if ! skybridge_ios_capture_console_handle \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$IOS_CONSOLE_PID" \
      "$IOS_CONSOLE_HANDLE_IDENTITY" \
      "$IOS_CONSOLE_CAPTURE_DIAGNOSTIC" \
      "$IOS_CONSOLE_HANDLE_CAPTURE_TIMEOUT_SECONDS"; then
      if kill -0 "$IOS_CONSOLE_PID" >/dev/null 2>&1; then
        echo "iOS P2P remote console handle is alive but exact ownership capture failed; refusing PID-only cleanup." >&2
        return 1
      fi
      wait "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
      IOS_CONSOLE_HANDLE_STARTED=0
      IOS_CONSOLE_PID=""
      if ! skybridge_ios_require_app_absent_after_handle_exit \
        "$PROCESS_OWNERSHIP_HELPER" \
        "$IOS_DEVICE_ID" \
        "$IOS_APP_PATH" \
        "$PROCESS_OWNERSHIP_PRIVATE_DIR" \
        "$DEVICECTL_TIMEOUT_SECONDS"; then
        report_ios_launch_failure "launch handle exited before capture and remote absence is unproven"
        return 1
      fi
      if launch_result_indicates_profile_trust_failure; then
        report_ios_launch_failure "code signature/profile/trust rejected by device"
        return 1
      fi
      if launch_result_indicates_locked_device; then
        if (( "$(date +%s)" - started_at >= IOS_LAUNCH_TIMEOUT_SECONDS )); then
          report_ios_launch_failure "device remained locked for ${IOS_LAUNCH_TIMEOUT_SECONDS}s"
          echo "Unlock the iPad/iPhone and rerun; this is a real-device precondition, not a remote desktop media pass." >&2
          return 1
        fi
        echo "    iOS remote launch attempt ${attempt} was denied because the device is locked; unlock the device, keep it awake, and waiting..." >&2
        attempt=$((attempt + 1))
        sleep 5
        continue
      fi
      report_ios_launch_failure "devicectl launch exited before exact console ownership was captured"
      return 1
    fi

    IOS_CONSOLE_HANDLE_CAPTURED=1
    sleep 0.5
    if skybridge_ios_console_handle_status \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$IOS_CONSOLE_PID" \
      "$IOS_CONSOLE_HANDLE_IDENTITY" >/dev/null 2>&1; then
      return 0
    else
      handle_status=$?
    fi
    if (( handle_status == 1 )) \
      && { launch_result_indicates_locked_device \
        || launch_result_indicates_profile_trust_failure \
        || launch_result_indicates_explicit_failure; }; then
      if ! finish_failed_ios_console_launch_without_process; then
        report_ios_launch_failure "failed launch exited but remote app absence could not be proven"
        return 1
      fi
      if launch_result_indicates_locked_device; then
        if (( "$(date +%s)" - started_at >= IOS_LAUNCH_TIMEOUT_SECONDS )); then
          report_ios_launch_failure "device remained locked for ${IOS_LAUNCH_TIMEOUT_SECONDS}s"
          return 1
        fi
        attempt=$((attempt + 1))
        sleep 5
        continue
      fi
      if launch_result_indicates_profile_trust_failure; then
        report_ios_launch_failure "code signature/profile/trust rejected by device"
      else
        report_ios_launch_failure "devicectl rejected the launch before creating an app process"
      fi
      return 1
    fi
    if ! terminate_ios_remote_smoke_app_exact "startup-exit"; then
      report_ios_launch_failure "console launch handle became unverifiable during startup"
      return 1
    fi
    if (( handle_status == 1 )) && launch_result_indicates_locked_device; then
      if (( "$(date +%s)" - started_at >= IOS_LAUNCH_TIMEOUT_SECONDS )); then
        report_ios_launch_failure "device remained locked for ${IOS_LAUNCH_TIMEOUT_SECONDS}s"
        return 1
      fi
      attempt=$((attempt + 1))
      sleep 5
      continue
    fi
    report_ios_launch_failure "console launch handle exited before P2P startup completed"
    return 1
  done
}

require_no_concurrent_smoke_scripts
reset_smoke_artifacts
initialize_ios_process_ownership_session

echo "==> Artifacts: $ARTIFACT_DIR"
if [[ "$IDENTITY_AUDIT_ONLY" == "1" ]]; then
  echo "==> Scope: signed macOS identity audit (no iOS target)"
elif [[ "$MAC_HOST_ONLY" == "1" ]]; then
  echo "==> Scope: signed current-source macOS host (diagnostic-only; no iOS target)"
else
  echo "==> Real device: $IOS_DEVICE_LABEL"
  echo "==> Build destination: $IOS_BUILD_DESTINATION"
  echo "==> Target: ${SMOKE_VIDEO_WIDTH}x${SMOKE_VIDEO_HEIGHT}@${SMOKE_TARGET_FPS} minFps=${SMOKE_MIN_FPS}"
  echo "==> Expected render orientation: $SMOKE_EXPECT_RENDER_ORIENTATION"
  echo "==> Expected suite: $EXPECTED_TARGET_SUITE"

  require_remote_control_notice_identity_env

  echo "==> Checking macOS visible desktop preflight"
  detect_macos_loginwindow_occlusion
fi

if [[ "$IDENTITY_AUDIT_ONLY" == "1" ]]; then
  echo "==> Capturing macOS identity-audit source-input binding"
  capture_source_input_binding
elif [[ "$MAC_HOST_ONLY" == "1" ]]; then
  echo "==> Capturing signed current-source macOS host input binding"
  capture_source_input_binding
else
  echo "==> Verifying iOS source provenance"
  capture_ios_release_source_provenance
fi

if [[ "$LAB_RUN" == "1" && "$IDENTITY_AUDIT_ONLY" != "1" && "$MAC_HOST_ONLY" != "1" && "$IOS_BUILD_CONFIGURATION" == "Release" ]]; then
  echo "==> Resolving installed iOS app and Widget distribution profiles"
  resolve_ios_distribution_signing_inputs
fi

if mac_host_uses_signed_app_bundle; then
  echo "==> Verifying product-identity signing context for the macOS LAN host ($MAC_HOST_LAUNCH_MODE)"
  verify_macos_smoke_host_product_signing_context
fi

echo "==> Checking Apple PQC SDK gate for macOS host"
skybridge_configure_optional_apple_pqc_sdk_compile_gate macosx
if [[ "${SKYBRIDGE_ENABLE_APPLE_PQC_SDK:-0}" != "1" ]]; then
  echo "Apple PQC SDK symbol probe failed for the macOS host; refusing to build a real-device X-Wing smoke host without HAS_APPLE_PQC_SDK." >&2
  echo "probeMode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown} sdk=${SKYBRIDGE_PQC_SDK_VER:-unknown} target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown} error=$(skybridge_sanitize_pqc_probe_log_value "${SKYBRIDGE_PQC_PROBE_ERROR:-}")" >&2
  exit 1
fi
echo "==> Apple PQC SDK gate passed: mode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown} sdk=${SKYBRIDGE_PQC_SDK_VER:-unknown} target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown}"

if [[ "$IDENTITY_AUDIT_ONLY" != "1" && "$MAC_HOST_ONLY" != "1" ]]; then
  xcrun devicectl list devices 2>&1 \
    | skybridge_smoke_redact_stream "$IOS_DEVICE_LABEL" "$IOS_DEVICE_ID" \
      >"$DEVICE_INFO_TXT" || true
fi

echo "==> Building macOS LAN host"
(
  cd "$ROOT_DIR"
  SWIFTPM_CACHE_PATH="$SWIFTPM_CACHE_DIR" \
  CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
  "$XCODE_SWIFT_BIN" build --scratch-path "$SMOKE_BUILD_DIR" --product LocalLanInteropHost
  if [[ "$IDENTITY_AUDIT_ONLY" != "1" && "$MAC_HOST_ONLY" != "1" ]]; then
    SWIFTPM_CACHE_PATH="$SWIFTPM_CACHE_DIR" \
    CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
    SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_DIR" \
    "$XCODE_SWIFT_BIN" build --scratch-path "$SMOKE_BUILD_DIR" --product LocalLanSmokeSourceHost
  fi
) >"$ARTIFACT_DIR/macos-build.log"

if [[ "$IDENTITY_AUDIT_ONLY" == "1" ]]; then
  verify_source_input_binding_unchanged "mac-identity-audit-build"
elif [[ "$MAC_HOST_ONLY" == "1" ]]; then
  verify_source_input_binding_unchanged "mac-host-only-build"
else
  verify_source_input_binding_unchanged "mac-build"
fi

if [[ ! -x "$MAC_DIRECT_BIN" ]]; then
  echo "macOS LAN host executable not found: $MAC_DIRECT_BIN" >&2
  exit 1
fi
if [[ "$IDENTITY_AUDIT_ONLY" != "1" && "$MAC_HOST_ONLY" != "1" && ! -x "$MAC_SOURCE_DIRECT_BIN" ]]; then
  echo "macOS smoke source helper executable not found: $MAC_SOURCE_DIRECT_BIN" >&2
  exit 1
fi

if mac_host_uses_signed_app_bundle; then
  prepare_macos_smoke_host_app_bundle
fi

echo "==> Starting macOS LAN host"
start_macos_smoke_host
if [[ "$IDENTITY_AUDIT_ONLY" == "1" ]]; then
  echo "==> Signed read-only identity audit completed; this diagnostic is never release-acceptance evidence."
  exit 2
fi
MAC_HOST_STARTED=1

if mac_host_uses_signed_app_bundle; then
  wait_for_file_pattern \
    "$HOST_STATUS" \
    'remote-control-localization requiredKeys=20 embeddedRawKeys=0 managerRawKeys=0 source=embedded-signed-core' \
    30 \
    "embedded signed SkyBridgeCore localization contract"
fi
if [[ "$MAC_HOST_ONLY" == "1" ]]; then
  wait_for_file_pattern \
    "$HOST_STATUS" \
    'identity-policy mode=existing-only mutation=denied source=explicit-smoke-environment' \
    30 \
    "existing-only macOS identity policy"
fi
wait_for_file_pattern "$HOST_STATUS" 'ready discovery=_skybridge._tcp' 60 "macOS host ready"
record_macos_smoke_host_launch_evidence
MAC_REMOTE_PORT="$(python3 - "$HOST_STATUS" <<'PY'
import re
import sys

port = ""
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as handle:
    for line in handle:
        match = re.search(r"\bready remote=_skybridge-rd\._tcp port=([1-9][0-9]{0,4})\b", line)
        if match:
            value = int(match.group(1))
            if 0 < value <= 65535:
                port = str(value)
print(port)
PY
)"
if [[ -z "$MAC_REMOTE_PORT" ]]; then
  echo "macOS host did not report a concrete _skybridge-rd._tcp remote-control port." >&2
  exit 1
fi
MAC_CONTROL_PORT="$(python3 - "$HOST_STATUS" <<'PY'
import re
import sys

port = ""
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as handle:
    for line in handle:
        match = re.search(r"\bready discovery=_skybridge\._tcp port=([1-9][0-9]{0,4})\b", line)
        if match:
            value = int(match.group(1))
            if 0 < value <= 65535:
                port = str(value)
print(port)
PY
)"
if [[ -z "$MAC_CONTROL_PORT" ]]; then
  echo "macOS host did not report a concrete _skybridge._tcp control port." >&2
  exit 1
fi
verify_host_pid_owns_listener_port "$MAC_CONTROL_PORT" "control"
verify_host_pid_owns_listener_port "$MAC_REMOTE_PORT" "remote-control"
if [[ "$MAC_HOST_ONLY" == "1" ]]; then
  wait_for_file_pattern "$HOST_PQC_REPORT" '"deviceId"' 30 "existing-only macOS PQC report"
  validate_mac_host_only_pqc_report
  verify_source_input_binding_unchanged "mac-host-only-ready"
  write_mac_host_ready_file
  wait_for_mac_host_only_shutdown
  exit 1
fi
MAC_CONTROL_HOST="${SKYBRIDGE_SMOKE_MAC_CONTROL_HOST:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname)}"
if [[ -z "$MAC_CONTROL_HOST" ]]; then
  echo "macOS host LAN address could not be determined for real-device smoke." >&2
  exit 1
fi
verify_mac_control_port_reachable "$MAC_CONTROL_HOST" "$MAC_CONTROL_PORT"
verify_mac_remote_port_listening "$MAC_CONTROL_HOST" "$MAC_REMOTE_PORT"
echo "==> Starting macOS smoke source helper"
start_macos_smoke_source_host
wait_for_file_pattern "$HOST_STATUS" 'smoke-capture-source active=1' 60 "macOS smoke capture source"
detect_macos_loginwindow_occlusion
wait_for_file_pattern "$HOST_STATUS" 'smoke-capture-source active=1 .*windowOcclusionVisible=1' 10 "macOS smoke capture source visible on the active desktop"
verify_mac_smoke_capture_source_visible
wait_for_file_pattern "$HOST_PQC_REPORT" '"deviceId"' 60 "macOS PQC report"

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

if [[ -z "$MAC_PQC_DEVICE_ID" || -z "$MAC_PQC_XWING_PUBLIC_KEY_BASE64" ]]; then
  echo "PQC report is missing required X-Wing identity: $HOST_PQC_REPORT" >&2
  exit 1
fi

if [[ "$LAB_RUN" != "1" ]]; then
  if [[ -z "$IOS_RELEASE_ARCHIVE_IDENTITY" || -z "$IOS_RELEASE_TESTING_IPA" ]]; then
    echo "Formal P2P evidence requires SKYBRIDGE_IOS_RELEASE_ARCHIVE_IDENTITY and SKYBRIDGE_IOS_RELEASE_TESTING_IPA." >&2
    exit 2
  fi
  mkdir -m 0700 "$(dirname "$IOS_FORMAL_EXTRACTED_APP")"
  echo "==> Preparing the sealed release-testing IPA without rebuilding"
  IOS_APP_PATH="$(
    python3 "$ROOT_DIR/Scripts/ios_physical_release_acceptance.py" prepare-product \
      --identity "$IOS_RELEASE_ARCHIVE_IDENTITY" \
      --release-testing-ipa "$IOS_RELEASE_TESTING_IPA" \
      --destination-app "$IOS_FORMAL_EXTRACTED_APP"
  )"
  printf 'formal iOS product source=sealed-release-testing-ipa build=not-performed\n' >"$IOS_BUILD_LOG"
else
  echo "==> Building diagnostic iOS app for real device"
  skybridge_detect_apple_pqc_sdk iphoneos
  if ! skybridge_apple_pqc_sdk_probe_succeeded; then
    echo "Apple PQC SDK symbol probe failed for the diagnostic iOS app; refusing a real-device X-Wing smoke target without HAS_APPLE_PQC_SDK." >&2
    echo "probeMode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown} sdk=${SKYBRIDGE_PQC_SDK_VER:-unknown} target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown} error=$(skybridge_sanitize_pqc_probe_log_value "${SKYBRIDGE_PQC_PROBE_ERROR:-}")" >&2
    exit 1
  fi
  echo "==> iOS Apple PQC SDK gate passed: mode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown} sdk=${SKYBRIDGE_PQC_SDK_VER:-unknown} target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown}"
  IOS_XCODEBUILD_SETTINGS=(
  "SKYBRIDGE_PACKAGING_BUILD_CONFIGURATION=$IOS_BUILD_CONFIGURATION"
  "SKYBRIDGE_PACKAGING_GIT_DIRTY_STATE=$IOS_SOURCE_DIRTY_STATE"
  "SKYBRIDGE_PACKAGING_GIT_COMMIT=$IOS_SOURCE_REVISION"
  "SKYBRIDGE_PACKAGING_SOURCE_INPUT_DIGEST=$IOS_SOURCE_INPUT_DIGEST"
  "SKYBRIDGE_PACKAGING_SOURCE_REPOSITORY=${GITHUB_REPOSITORY:-${SKYBRIDGE_SOURCE_REPOSITORY:-billlza/Skybridge-Compass}}"
  "SKYBRIDGE_PACKAGING_PRODUCT_SURFACE=testing"
  "SKYBRIDGE_PACKAGING_SWIFT_ACTIVE_COMPILATION_CONDITIONS=HAS_APPLE_PQC_SDK,SKYBRIDGE_TESTING"
  SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK
  "OTHER_SWIFT_FLAGS=\$(inherited) -D SKYBRIDGE_TESTING"
  )
  if [[ "$IOS_BUILD_CONFIGURATION" == "Release" ]]; then
  echo "==> Archiving iOS testing product with installed-only Automatic signing"
  skybridge_archive_ios_distribution_product \
    "$IOS_PROJECT" \
    "$IOS_SCHEME" \
    "$IOS_ARCHIVE_PATH" \
    "$IOS_ARCHIVE_DERIVED_DATA" \
    "$IOS_ARCHIVE_LOG" \
    installed-only \
    -- \
    "${IOS_XCODEBUILD_SETTINGS[@]}" \
    "DEVELOPMENT_TEAM=$IOS_TEAM_IDENTIFIER"
  verify_source_input_binding_unchanged "ios-archive"

  echo "==> Exporting the distribution-signed iOS testing product"
  skybridge_export_ios_distribution_archive \
    "$IOS_ARCHIVE_PATH" \
    "$IOS_EXPORT_OPTIONS" \
    "$IOS_EXPORT_DIR" \
    "$IOS_EXPORT_LOG" \
    "$IOS_TEAM_IDENTIFIER" \
    installed-only
  verify_source_input_binding_unchanged "ios-export"

  IOS_APP_PATH="$(
    skybridge_extract_single_ios_exported_app \
      "$IOS_IPA_EXTRACTOR" \
      "$IOS_EXPORT_DIR" \
      "$IOS_EXPORTED_APP"
  )"
  verify_source_input_binding_unchanged "ios-exported-product"
  else
  IOS_XCODEBUILD_ARGS=(
    -project "$IOS_PROJECT"
    -scheme "$IOS_SCHEME"
    -configuration "$IOS_BUILD_CONFIGURATION"
    -destination "$IOS_BUILD_DESTINATION"
    -derivedDataPath "$ARTIFACT_DIR/DerivedData-ios"
    "${IOS_XCODEBUILD_SETTINGS[@]}"
    build
  )
  SKYBRIDGE_XCODE_WARNINGS_AS_ERRORS=1 \
    skybridge_run_xcodebuild "${IOS_XCODEBUILD_ARGS[@]}" >"$IOS_BUILD_LOG"
  verify_source_input_binding_unchanged "ios-build"

  IOS_APP_PATH="$ARTIFACT_DIR/DerivedData-ios/Build/Products/${IOS_BUILD_CONFIGURATION}-iphoneos/SkyBridgeCompass-iOS.app"
  fi
fi
if [[ ! -d "$IOS_APP_PATH" ]]; then
  echo "iOS app bundle not found: $IOS_APP_PATH" >&2
  exit 1
fi

IOS_EMBEDDED_PROFILE="$IOS_APP_PATH/embedded.mobileprovision"
IOS_WIDGET_BUNDLE="$IOS_APP_PATH/PlugIns/SkyBridgeCompass-Widgets.appex"
IOS_WIDGET_EMBEDDED_PROFILE="$IOS_WIDGET_BUNDLE/embedded.mobileprovision"
if [[ ! -d "$IOS_WIDGET_BUNDLE" ]]; then
  echo "iOS Widget bundle not found at the exact product path: $IOS_WIDGET_BUNDLE" >&2
  exit 1
fi
if [[ "$LAB_RUN" != "1" ]]; then
  IOS_APP_DISTRIBUTION_PROFILE="$IOS_EMBEDDED_PROFILE"
  IOS_WIDGET_DISTRIBUTION_PROFILE="$IOS_WIDGET_EMBEDDED_PROFILE"
fi
if ! skybridge_profile_supports_requested_profile_backed_entitlements \
  "$IOS_EMBEDDED_PROFILE" \
  "$IOS_EXPECTED_ENTITLEMENTS"; then
  echo "iOS app provisioning profile does not cover the requested configuration entitlements; refusing a smoke run that would hide a signing mismatch." >&2
  echo "profile=<redacted-profile-path> entitlements=<redacted-entitlements-path>" >&2
  exit 1
fi
write_ios_p2p_product_proof "$IOS_EMBEDDED_PROFILE" "$IOS_WIDGET_EMBEDDED_PROFILE"
verify_ios_product_source_input_binding

if ! skybridge_ios_require_fresh_app_launch \
  "$PROCESS_OWNERSHIP_HELPER" \
  "$IOS_DEVICE_ID" \
  "$IOS_APP_PATH" \
  "$PROCESS_OWNERSHIP_PRIVATE_DIR" \
  "$DEVICECTL_TIMEOUT_SECONDS"; then
  exit 1
fi
IOS_PREINSTALL_ABSENCE_PROVEN=1
append_host_status "ios-preinstall appAbsence=1 terminateExistingLaunch=1"

echo "==> Installing iOS app on real device"
if [[ "$PRESERVE_INSTALL" != "1" ]]; then
  xcrun devicectl device uninstall app --device "$IOS_DEVICE_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
else
  echo "    preserving existing install to keep Local Network/TCC grants when possible"
fi
xcrun devicectl device install app --device "$IOS_DEVICE_ID" "$IOS_APP_PATH" >/dev/null

echo "==> Revalidating macOS listeners immediately before iOS launch"
verify_host_pid_owns_listener_port "$MAC_CONTROL_PORT" "control"
verify_host_pid_owns_listener_port "$MAC_REMOTE_PORT" "remote-control"
verify_mac_control_port_reachable "$MAC_CONTROL_HOST" "$MAC_CONTROL_PORT"
verify_mac_remote_port_listening "$MAC_CONTROL_HOST" "$MAC_REMOTE_PORT"
append_host_status "host-listener-prelaunch verified=1 pid=$HOST_PID controlPort=$MAC_CONTROL_PORT remoteControlPort=$MAC_REMOTE_PORT"

echo "==> Launching iOS P2P remote smoke"
IOS_PQC_PEER_DEVICE_ID=""
IOS_PQC_PEER_XWING_PUBLIC_KEY_BASE64=""
IOS_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64=""
IOS_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64=""
if [[ "$PQC_TRUST_MODE" == "injected" ]]; then
  IOS_PQC_PEER_DEVICE_ID="$MAC_PQC_DEVICE_ID"
  IOS_PQC_PEER_XWING_PUBLIC_KEY_BASE64="$MAC_PQC_XWING_PUBLIC_KEY_BASE64"
  IOS_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768_PUBLIC_KEY_BASE64"
  IOS_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64="$MAC_PQC_MLKEM768FS_PUBLIC_KEY_BASE64"
  echo "    trust mode: injected KEM public keys (diagnostic only)"
else
  echo "    trust mode: user app trust store (no injected KEM keys)"
fi
IOS_SMOKE_DEVICE_ID="${SKYBRIDGE_SMOKE_IOS_DEVICE_ID:-$IOS_DEVICE_ID}"
IOS_ENV_JSON="$(
  SKYBRIDGE_KEYCHAIN_IN_MEMORY="$KEYCHAIN_IN_MEMORY" \
  SKYBRIDGE_DEVICE_ID="$IOS_SMOKE_DEVICE_ID" \
  SKYBRIDGE_SMOKE_TARGET_DEVICE_ID="$MAC_PQC_DEVICE_ID" \
  SKYBRIDGE_SMOKE_TARGET_NAME="$MAC_TARGET_NAME" \
  SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
  SKYBRIDGE_SMOKE_REMOTE_DESKTOP_TIMEOUT_SECONDS="$SMOKE_REMOTE_TIMEOUT_SECONDS" \
  SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_NAME" \
  SKYBRIDGE_SMOKE_LISTENER_STATUS_BASENAME="$IOS_LISTENER_STATUS_NAME" \
  SKYBRIDGE_SMOKE_MIN_FPS="$SMOKE_MIN_FPS" \
  SKYBRIDGE_SMOKE_TARGET_FPS="$SMOKE_TARGET_FPS" \
  SKYBRIDGE_SMOKE_SOAK_SECONDS="$SMOKE_SOAK_SECONDS" \
  SKYBRIDGE_SMOKE_VIDEO_WIDTH="$SMOKE_VIDEO_WIDTH" \
  SKYBRIDGE_SMOKE_VIDEO_HEIGHT="$SMOKE_VIDEO_HEIGHT" \
  SKYBRIDGE_SMOKE_PQC_REPORT_BASENAME="$IOS_PQC_REPORT_NAME" \
  SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION="$SMOKE_EXPECT_RENDER_ORIENTATION" \
  SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH="$SMOKE_REQUIRE_SIGNED_KEM_REFRESH" \
  SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH="$SMOKE_FORCE_SIGNED_KEM_REFRESH" \
  SKYBRIDGE_SMOKE_ALLOW_PERSISTENT_TRUST_MUTATION="$ALLOW_PERSISTENT_TRUST_MUTATION" \
  SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE="$EXPECTED_TARGET_SUITE" \
  SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME="${SKYBRIDGE_SMOKE_REMOTE_ACCOUNT_DISPLAY_NAME:-}" \
  SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID="${SKYBRIDGE_SMOKE_REMOTE_NEBULA_ID:-}" \
  SB_PQC_PREFERRED_SUITE="$IOS_PREFERRED_SUITE" \
  SKYBRIDGE_PQC_PEER_DEVICE_ID="$IOS_PQC_PEER_DEVICE_ID" \
  SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64="$IOS_PQC_PEER_XWING_PUBLIC_KEY_BASE64" \
  SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64="$IOS_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64" \
  SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64="$IOS_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64" \
  python3 - <<'PY'
import json
import os

keys = [
    "SKYBRIDGE_DEVICE_ID",
    "SKYBRIDGE_SMOKE_TARGET_DEVICE_ID",
    "SKYBRIDGE_SMOKE_TARGET_NAME",
    "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS",
    "SKYBRIDGE_SMOKE_REMOTE_DESKTOP_TIMEOUT_SECONDS",
    "SKYBRIDGE_SMOKE_STATUS_BASENAME",
    "SKYBRIDGE_SMOKE_LISTENER_STATUS_BASENAME",
    "SKYBRIDGE_SMOKE_MIN_FPS",
    "SKYBRIDGE_SMOKE_TARGET_FPS",
    "SKYBRIDGE_SMOKE_SOAK_SECONDS",
    "SKYBRIDGE_SMOKE_VIDEO_WIDTH",
    "SKYBRIDGE_SMOKE_VIDEO_HEIGHT",
    "SKYBRIDGE_SMOKE_PQC_REPORT_BASENAME",
    "SKYBRIDGE_SMOKE_EXPECT_RENDER_ORIENTATION",
    "SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH",
    "SKYBRIDGE_SMOKE_FORCE_SIGNED_KEM_REFRESH",
    "SKYBRIDGE_SMOKE_ALLOW_PERSISTENT_TRUST_MUTATION",
    "SKYBRIDGE_SMOKE_EXPECT_TARGET_SUITE",
    "SKYBRIDGE_SMOKE_LOCAL_ACCOUNT_DISPLAY_NAME",
    "SKYBRIDGE_SMOKE_LOCAL_NEBULA_ID",
    "SB_PQC_PREFERRED_SUITE",
    "SKYBRIDGE_PQC_PEER_DEVICE_ID",
    "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64",
    "SKYBRIDGE_PQC_PEER_MLKEM768FS_PUBLIC_KEY_BASE64",
]
env = {
    "SKYBRIDGE_KEYCHAIN_IN_MEMORY": os.environ["SKYBRIDGE_KEYCHAIN_IN_MEMORY"],
    "SKYBRIDGE_SMOKE_ROLE": "ios-p2p-client",
    "SKYBRIDGE_SMOKE_EXPECT_REMOTE_DESKTOP": "1",
    "SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB": "1",
    "SKYBRIDGE_SMOKE_REQUIRE_VISIBLE_REMOTE_VIEW": "1",
    "SKYBRIDGE_SMOKE_REQUIRE_AUDIO": "1",
    "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY": "0",
    "SKYBRIDGE_SMOKE_EXTREME_MEDIA": "1",
    "SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK": "1",
}
for key in keys:
    value = os.environ.get(key)
    if value:
        env[key] = value
print(json.dumps(env, ensure_ascii=False))
PY
)"

launch_ios_remote_smoke_app
validate_ios_launch_notice_identity_env

echo "==> Waiting for P2P handshake"
wait_for_file_pattern "$HOST_STATUS" "$HOST_HANDSHAKE_PATTERN" "$SMOKE_TIMEOUT_SECONDS" "macOS P2P handshake"
echo "==> PIB-1 and SKR-1 evidence will be validated from the merged on-device status after the media run"
wait_for_ios_status_pattern "streamConfigSent .*preferred=hevc, formats=hevc, fps=${SMOKE_TARGET_FPS}.*perf=extreme" "$SMOKE_TIMEOUT_SECONDS" "strict HEVC-only stream configuration"
wait_for_remote_control_notice_lifecycle
wait_for_ios_status_pattern "success .*suite=${EXPECTED_TARGET_SUITE} .*handshakeOnly=1 .*remoteDesktop=1" "$SMOKE_TIMEOUT_SECONDS" "iOS P2P remote desktop success"
wait_for_ios_status_pattern "remote-desktop-pass .*renderOrientation=${SMOKE_EXPECT_RENDER_ORIENTATION}" "$SMOKE_TIMEOUT_SECONDS" "P2P remote desktop pass window"
copy_ios_status
if [[ "$SMOKE_REQUIRE_SIGNED_KEM_REFRESH" == "1" ]]; then
  validate_protocol_identity_bootstrap_evidence
else
  append_host_status "identity-refresh evidence=not-requested persistentTrustMutation=0"
  append_ios_status "identity-refresh evidence=not-requested persistentTrustMutation=0"
fi
validate_remote_desktop_route_evidence
validate_remote_desktop_operation_evidence
validate_remote_desktop_performance_window
if [[ "$RUN_MAC_ONLINE_IPAD_SMOKE" == "1" ]]; then
  run_mac_online_ipad_button_smoke
else
  append_host_status "mac-online-ipad smoke=skipped reason=profile-separated-from-active-remote-control-session"
  append_ios_status "mac-online-ipad smoke=skipped reason=profile-separated-from-active-remote-control-session"
fi
wait_for_remote_control_notice_disconnected
append_host_status "smoke-final result=success validated=1 route=lan-main fps=${SMOKE_MIN_FPS} frame=${SMOKE_VIDEO_WIDTH}x${SMOKE_VIDEO_HEIGHT}"
append_ios_status "smoke-final result=success validated=1 route=lan-main fps=${SMOKE_MIN_FPS} frame=${SMOKE_VIDEO_WIDTH}x${SMOKE_VIDEO_HEIGHT}"
copy_ios_status

sync_macos_smoke_host_artifacts
echo "==> Running Rust CLI P2P remote performance artifact gate"
skybridge_smoke_check_performance_gate "$ROOT_DIR" p2p-remote "$ARTIFACT_DIR" \
  --min-fps "$SMOKE_MIN_FPS" \
  --min-width "$SMOKE_VIDEO_WIDTH" \
  --min-height "$SMOKE_VIDEO_HEIGHT" \
  --exact-video-size \
  --min-pass-window-seconds "$SMOKE_SOAK_SECONDS" \
  --require-audio true \
  --strict-fps-floor true
python3 - \
  "$ARTIFACT_DIR/release-acceptance.json" \
  "$LAB_RUN" \
  "$PQC_TRUST_MODE" \
  "$KEYCHAIN_MODE" \
  "$RUN_MAC_ONLINE_IPAD_SMOKE" \
  "$MAC_TO_IOS_CRYPTO_HANDSHAKE_COMPLETE" \
  "$MAC_ONLINE_APP_SOURCE" \
  "$MAC_ONLINE_APP_SOURCE_CURRENT" \
  "$MAC_HOST_LAUNCH_MODE" \
  "$MAC_HOST_IDENTITY_SOURCE_STAPLER_VALID" \
  "$MAC_HOST_IDENTITY_SOURCE_GATEKEEPER_ACCEPTED" \
  "$P2P_APPROVAL_PROOF" \
  "$IOS_PRODUCT_PROOF" <<'PY'
import json
import pathlib
import re
import stat
import sys

(
    output_path,
    lab_run,
    trust_mode,
    keychain_mode,
    reverse_run,
    reverse_crypto,
    mac_online_source,
    mac_online_source_current,
    mac_host_launch_mode,
    mac_host_stapler_valid,
    mac_host_gatekeeper_accepted,
    approval_proof_path,
    ios_product_proof_path,
) = sys.argv[1:]


def load_measured_proof(path_value: str, label: str) -> dict:
    path = pathlib.Path(path_value)
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0 or metadata.st_size > 1024 * 1024:
        raise SystemExit(f"{label} is not a bounded regular file")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise SystemExit(f"{label} is not a JSON object")
    return payload


approval_proof = load_measured_proof(approval_proof_path, "P2P approval proof")
ios_product_proof = load_measured_proof(ios_product_proof_path, "iOS product proof")
human_approval = approval_proof.get("humanApproval") is True
runtime_auto_approval = approval_proof.get("runtimeAutoApproval") is True
approval_lifecycle = approval_proof.get("lifecycle")
approval_session_ref = approval_proof.get("sessionRef")
expected_approval_lifecycle = ["Shown", "PanelPresented", "HumanApproved", "Approved", "Active"]
if (
    approval_proof.get("schemaVersion") != 2
    or approval_lifecycle != expected_approval_lifecycle
    or approval_proof.get("panelActionsVerified") is not True
    or not isinstance(approval_session_ref, str)
    or re.fullmatch(r"ev1:[0-9a-f]{32}", approval_session_ref) is None
):
    raise SystemExit("P2P approval proof contract is invalid")

required_ios_true_fields = (
    "releaseConfiguration",
    "sourceClean",
    "productBundle",
    "signatureVerified",
    "profileVerified",
    "teamMatch",
    "certificateMatch",
    "certificateNotExpired",
    "profileNotExpired",
    "profileDeviceBound",
    "distributionSigning",
    "expectedEntitlementsMatch",
    "keychainGroupsVerified",
    "nestedWidgetVerified",
    "productionProduct",
    "releaseVersionVerified",
)
ios_product_ready = (
    ios_product_proof.get("schemaVersion") == 1
    and ios_product_proof.get("configuration") == "Release"
    and all(ios_product_proof.get(key) is True for key in required_ios_true_fields)
    and ios_product_proof.get("getTaskAllow") is False
)
ios_source_revision_ref = ios_product_proof.get("sourceRevisionRef")
if not isinstance(ios_source_revision_ref, str) or len(ios_source_revision_ref) != 24:
    raise SystemExit("iOS product proof source revision reference is invalid")

is_lab = lab_run == "1"
ios_production_identity_lifecycle_verified = False
has_reverse_run = reverse_run == "1"
has_reverse_crypto = reverse_crypto == "1"
has_current_packaged_mac_online = (
    mac_online_source == "packaged" and mac_online_source_current == "1"
)
has_formal_mac_host_identity = (
    mac_host_launch_mode == "packaged"
    and mac_host_stapler_valid == "1"
    and mac_host_gatekeeper_accepted == "1"
)
normal_product_p2p_inbound = False
pre_cleanup_candidate = (
    not is_lab
    and trust_mode != "injected"
    and keychain_mode == "system"
    and has_reverse_run
    and has_reverse_crypto
    and has_current_packaged_mac_online
    and has_formal_mac_host_identity
    and normal_product_p2p_inbound
    and human_approval
    and not runtime_auto_approval
    and ios_product_ready
    and ios_production_identity_lifecycle_verified
)
payload = {
    "schemaVersion": 1,
    "transport": "p2p",
    "realDevice": True,
    "acceptanceEligible": False,
    "diagnosticOnly": True,
    "cleanupComplete": False,
    "preCleanupCandidate": pre_cleanup_candidate,
    "labRun": is_lab,
    "trustMode": trust_mode,
    "keychainMode": keychain_mode,
    "injectedTrust": trust_mode == "injected",
    "inMemoryKeychain": keychain_mode == "in-memory",
    "humanApproval": human_approval,
    "runtimeAutoApproval": runtime_auto_approval,
    "approvalSessionRef": approval_session_ref,
    "approvalLifecycle": approval_lifecycle,
    "iosToMacRemoteControl": True,
    "macToIOSConnection": has_reverse_run and has_reverse_crypto,
    "reverseCryptoHandshakeComplete": has_reverse_crypto,
    "bidirectionalHandshake": has_reverse_crypto,
    "macOnlineSource": mac_online_source,
    "macOnlineSourceCurrent": mac_online_source_current == "1",
    "macHostLaunchMode": mac_host_launch_mode,
    "macHostDiagnosticOnly": mac_host_launch_mode != "packaged",
    "macCandidateIdentityVerified": not is_lab,
    "macRuntimeExecutable": "LocalLanInteropHost",
    "macProductSurface": "diagnostic-helper",
    "macProductPath": normal_product_p2p_inbound,
    "macDebugBuild": True,
    "macTestingCompilationCondition": True,
    "remoteControlNoticeProductPath": normal_product_p2p_inbound,
    "remoteControlNoticeHumanApproval": human_approval,
    "remoteControlNoticePanelPresented": approval_proof.get("panelActionsVerified") is True,
    "noticeEvidenceSource": "diagnostic-helper-session",
    "identitySourceStaplerValid": mac_host_stapler_valid == "1",
    "identitySourceGatekeeperAccepted": mac_host_gatekeeper_accepted == "1",
    "iosBuildConfiguration": ios_product_proof.get("configuration"),
    "iosReleaseConfiguration": ios_product_proof.get("releaseConfiguration") is True,
    "iosSourceClean": ios_product_proof.get("sourceClean") is True,
    "sourceRepository": ios_product_proof.get("sourceRepository"),
    "sourceCommit": ios_product_proof.get("sourceCommit"),
    "iosSourceRevisionRef": ios_source_revision_ref,
    "iosProductSurface": ios_product_proof.get("productSurface"),
    "iosSwiftActiveCompilationConditions": ios_product_proof.get("swiftActiveCompilationConditions"),
    "iosTestingCompilationCondition": ios_product_proof.get("testingCompilationCondition") is True,
    "iosBinaryTestSurfaceDetected": ios_product_proof.get("binaryTestSurfaceDetected") is True,
    "iosProductionProduct": ios_product_proof.get("productionProduct") is True,
    "iosReleaseVersion": ios_product_proof.get("releaseVersion"),
    "iosReleaseBuild": ios_product_proof.get("releaseBuild"),
    "iosReleaseVersionVerified": ios_product_proof.get("releaseVersionVerified") is True,
    "iosProductionIdentityAlgorithm": "unproven",
    "iosProductionIdentityProtection": "unproven",
    "iosProductionIdentityLifecycleVerified": ios_production_identity_lifecycle_verified,
    "iosProductionIdentityProof": False,
    "iosProductBundle": ios_product_proof.get("productBundle") is True,
    "iosSignatureVerified": ios_product_proof.get("signatureVerified") is True,
    "iosProfileVerified": ios_product_proof.get("profileVerified") is True,
    "iosTeamMatch": ios_product_proof.get("teamMatch") is True,
    "iosCertificateMatch": ios_product_proof.get("certificateMatch") is True,
    "iosCertificateNotExpired": ios_product_proof.get("certificateNotExpired") is True,
    "iosProfileNotExpired": ios_product_proof.get("profileNotExpired") is True,
    "iosProfileDeviceBound": ios_product_proof.get("profileDeviceBound") is True,
    "iosDistributionSigning": ios_product_proof.get("distributionSigning") is True,
    "iosExpectedEntitlementsMatch": ios_product_proof.get("expectedEntitlementsMatch") is True,
    "iosKeychainGroupsVerified": ios_product_proof.get("keychainGroupsVerified") is True,
    "iosNestedWidgetVerified": ios_product_proof.get("nestedWidgetVerified") is True,
    "iosGetTaskAllow": ios_product_proof.get("getTaskAllow") is True,
    "iosProductProof": ios_product_ready,
}
pathlib.Path(output_path).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
if [[ "$LAB_RUN" != "1" ]]; then
  python3 "$ROOT_DIR/Scripts/ios_physical_release_acceptance.py" bind-manifest \
    --identity "$IOS_RELEASE_ARCHIVE_IDENTITY" \
    --manifest "$ARTIFACT_DIR/release-acceptance.json"
fi
echo "==> Materializing redacted public P2P remote smoke artifacts"
skybridge_smoke_materialize_public_artifacts "$IOS_DEVICE_LABEL" "$ARTIFACT_DIR" "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID"
skybridge_verify_public_macos_release_candidate_evidence \
  "$ROOT_DIR" \
  "$ARTIFACT_DIR" \
  "$PUBLIC_ARTIFACT_DIR"
skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID"
echo "==> Redacted public artifacts: $PUBLIC_ARTIFACT_DIR"
ACCEPTANCE_CANDIDATE_READY="$(python3 - "$ARTIFACT_DIR/release-acceptance.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
candidate = payload.get("preCleanupCandidate")
if type(candidate) is not bool:
    raise SystemExit("P2P pre-cleanup acceptance candidate flag is not a boolean")
print("1" if candidate else "0")
PY
)"

if [[ "$LAB_RUN" == "1" ]]; then
  echo "Lab run completed, but this is not an acceptance pass because SKYBRIDGE_REAL_DEVICE_P2P_LAB_RUN=1." >&2
  exit 2
fi

echo "==> P2P acceptance candidate complete; final eligibility waits for verified process cleanup"
