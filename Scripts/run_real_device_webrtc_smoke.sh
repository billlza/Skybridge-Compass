#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/apple_pqc_sdk_probe.sh"
source "$ROOT_DIR/Scripts/signing_entitlements_helpers.sh"
source "$ROOT_DIR/Scripts/ios_distribution_signing_helpers.sh"
source "$ROOT_DIR/Scripts/real_device_ios_process_ownership.sh"
source "$ROOT_DIR/Scripts/real_device_smoke_redaction.sh"
source "$ROOT_DIR/Scripts/xcodebuild_helpers.sh"
PROCESS_OWNERSHIP_HELPER="$ROOT_DIR/Scripts/webrtc_smoke_process_ownership.py"
ARTIFACT_DIR="${SKYBRIDGE_SMOKE_ARTIFACT_DIR:-$ROOT_DIR/Artifacts/real_device_webrtc_smoke_$(date +%Y%m%d_%H%M%S)}"
if [[ "$ARTIFACT_DIR" != /* ]]; then
  ARTIFACT_DIR="$PWD/$ARTIFACT_DIR"
fi
PUBLIC_ARTIFACT_DIR="${SKYBRIDGE_SMOKE_PUBLIC_ARTIFACT_DIR:-${ARTIFACT_DIR}-public-redacted}"

IOS_PROJECT="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
IOS_EXPORT_OPTIONS="$ROOT_DIR/Scripts/ios_release_candidate_export_options.plist"
IOS_IPA_EXTRACTOR="$ROOT_DIR/Scripts/extract_ios_ipa.py"
IOS_BUNDLE_ID="com.skybridge.compass.ios"
IOS_WIDGET_BUNDLE_ID="com.skybridge.compass.ios.widgets"
IOS_TEAM_IDENTIFIER="YKUPL7Z869"
IOS_DEBUG_ENTITLEMENTS="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOSDebug.entitlements"
IOS_RELEASE_ENTITLEMENTS="$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompass-iOSRelease.entitlements"
IOS_APP_DISTRIBUTION_PROFILE_INPUT="${SKYBRIDGE_SMOKE_IOS_APP_DISTRIBUTION_PROFILE:-}"
IOS_WIDGET_DISTRIBUTION_PROFILE_INPUT="${SKYBRIDGE_SMOKE_IOS_WIDGET_DISTRIBUTION_PROFILE:-}"
SMOKE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_TIMEOUT_SECONDS:-240}"
SMOKE_SOAK_SECONDS="${SKYBRIDGE_SMOKE_SOAK_SECONDS:-10}"
SMOKE_MIN_FPS="${SKYBRIDGE_SMOKE_MIN_FPS:-30.00}"
SMOKE_REQUIRE_AUDIO="${SKYBRIDGE_SMOKE_REQUIRE_AUDIO:-1}"
SMOKE_AUDIO_BOOTSTRAP_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_AUDIO_BOOTSTRAP_TIMEOUT_SECONDS:-90}"
SMOKE_SYNTHETIC_OPUS_TONE="${SKYBRIDGE_SMOKE_SYNTHETIC_OPUS_TONE:-0}"
SMOKE_EXTREME_MEDIA=1
SMOKE_SYNTHETIC_SCREEN=0
SMOKE_FORCE_RELAY_ICE="${SKYBRIDGE_SMOKE_FORCE_RELAY_ICE:-1}"
MEDIA_RELAY_PREFLIGHT_HOST="${SKYBRIDGE_SMOKE_MEDIA_RELAY_PREFLIGHT_HOST:-82.156.225.30}"
MEDIA_RELAY_PREFLIGHT_PORT="${SKYBRIDGE_SMOKE_MEDIA_RELAY_PREFLIGHT_PORT:-3478}"
MEDIA_RELAY_PREFLIGHT_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_MEDIA_RELAY_PREFLIGHT_TIMEOUT_SECONDS:-3}"
SKIP_MEDIA_RELAY_PREFLIGHT="${SKYBRIDGE_SMOKE_SKIP_MEDIA_RELAY_PREFLIGHT:-0}"
SMOKE_VIDEO_WIDTH="${SKYBRIDGE_SMOKE_VIDEO_WIDTH:-2056}"
SMOKE_VIDEO_HEIGHT="${SKYBRIDGE_SMOKE_VIDEO_HEIGHT:-1329}"
if [[ -n "${SKYBRIDGE_SMOKE_TARGET_FPS:-}" ]]; then
  SMOKE_TARGET_FPS="$SKYBRIDGE_SMOKE_TARGET_FPS"
elif [[ "$SMOKE_MIN_FPS" =~ ^(59|[6-9][0-9]|1[0-1][0-9]|120)(\.|$) ]]; then
  SMOKE_TARGET_FPS=60
else
  SMOKE_TARGET_FPS=32
fi
if [[ "$SMOKE_SOAK_SECONDS" =~ ^[0-9]+$ && "$SMOKE_TIMEOUT_SECONDS" =~ ^[0-9]+$ && "$SMOKE_SOAK_SECONDS" -gt 0 && "$SMOKE_TIMEOUT_SECONDS" -le "$SMOKE_SOAK_SECONDS" ]]; then
  SMOKE_TIMEOUT_SECONDS=$((SMOKE_SOAK_SECONDS + 240))
fi
if [[ "$SMOKE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  DEFAULT_SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS=$((SMOKE_TIMEOUT_SECONDS + 60))
else
  DEFAULT_SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS=300
fi
SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS="${SKYBRIDGE_SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS:-$DEFAULT_SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS}"
PRESERVE_INSTALL="${SKYBRIDGE_SMOKE_PRESERVE_INSTALL:-1}"
ALLOW_PRIVATE_SIGNALING="${SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_PRIVATE_SIGNALING:-0}"
ALLOW_LOCALHOST_SIGNALING="${SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_LOCALHOST_SIGNALING:-0}"
ALLOW_INSECURE_SIGNALING="${SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_INSECURE_SIGNALING:-0}"
ALLOW_UNRESOLVED_SIGNALING="${SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_UNRESOLVED_SIGNALING:-0}"
LAB_RUN="${SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN:-0}"
KEYCHAIN_MODE="${SKYBRIDGE_SMOKE_KEYCHAIN_MODE:-system}"
MAC_HOST_MODE="${SKYBRIDGE_SMOKE_MAC_HOST_MODE:-product}"
MAC_PRODUCT_APP_BUNDLE="${SKYBRIDGE_SMOKE_MAC_PRODUCT_APP_BUNDLE:-$ROOT_DIR/dist/SkyBridge Compass Pro.app}"
MAC_PRODUCT_BUNDLE_ID="com.skybridge.compass.pro"
PRODUCT_ACCEPTANCE_MARKER="SkyBridge-WebRTC-Product-Acceptance-V3"
MIN_ACCEPTANCE_SOAK_SECONDS=10
DEVICECTL_TIMEOUT_SECONDS="${SKYBRIDGE_DEVICECTL_TIMEOUT_SECONDS:-60}"
IOS_COPY_TIMEOUT_SECONDS="${SKYBRIDGE_DEVICECTL_COPY_TIMEOUT_SECONDS:-12}"
IOS_COPY_HARD_TIMEOUT_SECONDS="${SKYBRIDGE_DEVICECTL_COPY_HARD_TIMEOUT_SECONDS:-18}"
IOS_CONSOLE_TOTAL_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_IOS_CONSOLE_TIMEOUT_SECONDS:-3600}"
IOS_CONSOLE_HANDLE_CAPTURE_TIMEOUT_SECONDS="${SKYBRIDGE_SMOKE_IOS_CONSOLE_CAPTURE_TIMEOUT_SECONDS:-10}"
RUN_ID="${SKYBRIDGE_SMOKE_WEBRTC_RUN_ID:-$(date +%Y%m%d%H%M%S)}"
skybridge_smoke_require_safe_run_id "$RUN_ID" "SKYBRIDGE_SMOKE_WEBRTC_RUN_ID"

DEFAULT_SIGNALING_SERVER_URL="https://api.nebula-technologies.net"
DEFAULT_SIGNALING_WS_URL="wss://api.nebula-technologies.net/ws"
SIGNALING_SERVER_URL="${SKYBRIDGE_SMOKE_SIGNALING_SERVER_URL:-${SKYBRIDGE_SIGNALING_SERVER_URL:-$DEFAULT_SIGNALING_SERVER_URL}}"
SIGNALING_WS_URL="${SKYBRIDGE_SMOKE_SIGNALING_WEBSOCKET_URL:-${SKYBRIDGE_SIGNALING_WEBSOCKET_URL:-$DEFAULT_SIGNALING_WS_URL}}"
STUN_URL="${SKYBRIDGE_STUN_URL:-}"
TURN_URLS="${SKYBRIDGE_TURN_URLS:-}"
CLIENT_VERSION="${SKYBRIDGE_CLIENT_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Sources/SkyBridgeCompassApp/Info.plist" 2>/dev/null || echo "1.0.0")}"
PROTOCOL_VERSION="${SKYBRIDGE_PROTOCOL_VERSION:-1}"

mkdir -p "$ARTIFACT_DIR"
chmod 0700 "$ARTIFACT_DIR"

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 1
  fi
}

pick_real_device_id() {
  python3 - <<'PY'
import re
import subprocess

output = subprocess.check_output(["xcrun", "xctrace", "list", "devices"], text=True)
in_devices = False
for line in output.splitlines():
    stripped = line.strip()
    if stripped == "== Devices ==":
        in_devices = True
        continue
    if stripped.startswith("== ") and stripped != "== Devices ==":
        in_devices = False
    if not in_devices:
        continue
    if not stripped or "Mac" in stripped or stripped.endswith("(Simulator)"):
        continue
    match = re.search(r"\(([0-9A-Fa-f-]{20,})\)$", stripped)
    if match:
        print(match.group(1))
        raise SystemExit(0)

raise SystemExit("No connected real iOS device found.")
PY
}

IOS_DEVICE_ID="${SKYBRIDGE_REAL_DEVICE_ID:-}"
MAC_DEVICE_ID="${SKYBRIDGE_SMOKE_MAC_DEVICE_ID:-real-webrtc-mac-${RUN_ID}}"
IOS_LOGICAL_DEVICE_ID="${SKYBRIDGE_SMOKE_IOS_DEVICE_ID:-real-webrtc-ios-${RUN_ID}}"

AUTH_SESSION_SOURCE_FILE="${SKYBRIDGE_SMOKE_AUTH_SESSION_FILE:-${SKYBRIDGE_AUTH_SESSION_FILE:-}}"
AUTH_SESSION_FILE=""
AUTH_PRIVATE_DIR=""
PROCESS_OWNERSHIP_PRIVATE_DIR=""
MAC_STATUS="$ARTIFACT_DIR/mac.status.log"
MAC_CODE=""
MAC_TOKEN=""
MAC_TENANT=""
MAC_AUTH_BINDING=""
AUTH_BINDING_DIGEST=""
MAC_PQC_REPORT="$ARTIFACT_DIR/mac.pqc.json"
MAC_STDOUT="$ARTIFACT_DIR/mac.stdout.log"
MAC_BUILD_LOG="$ARTIFACT_DIR/macos-build.log"
IOS_BUILD_LOG="$ARTIFACT_DIR/ios-build.log"
IOS_ARCHIVE_PATH="$ARTIFACT_DIR/SkyBridgeCompass-iOS.xcarchive"
IOS_ARCHIVE_DERIVED_DATA="$ARTIFACT_DIR/DerivedData-ios-archive"
IOS_ARCHIVE_LOG="$ARTIFACT_DIR/ios-archive.log"
IOS_EXPORT_DIR="$ARTIFACT_DIR/ios-export"
IOS_EXPORT_LOG="$ARTIFACT_DIR/ios-export.log"
IOS_EXPORTED_APP="$ARTIFACT_DIR/SkyBridgeCompass-iOS-exported.app"
IOS_STATUS_NAME="ios-real-webrtc-${RUN_ID}.status.log"
IOS_STATUS_LOCAL="$ARTIFACT_DIR/$IOS_STATUS_NAME"
IOS_TRACE_LOCAL="$ARTIFACT_DIR/$IOS_STATUS_NAME.trace.log"
IOS_MEDIA_LOCAL="$ARTIFACT_DIR/$IOS_STATUS_NAME.webrtc-media.jsonl"
IOS_DEVICE_INFO_JSON="$ARTIFACT_DIR/device-info.json"
IOS_LAUNCH_JSON=""
IOS_LAUNCH_SUMMARY_JSON="$ARTIFACT_DIR/ios-launch.json"
IOS_PROCESS_CLEANUP_RECEIPT="$ARTIFACT_DIR/ios-process-cleanup.json"
IOS_BOOTSTRAP_SOURCE=""
IOS_BOOTSTRAP_TOMBSTONE=""
IOS_BOOTSTRAP_REMOTE_DIRECTORY="Library/Caches"
IOS_BOOTSTRAP_FILE_NAME="skybridge-webrtc-smoke-bootstrap-v1.json"
MAC_PID=""
IOS_CONSOLE_PID=""
MAC_PROCESS_IDENTITY=""
IOS_PROCESS_IDENTITY=""
IOS_CONSOLE_HANDLE_IDENTITY=""
IOS_CONSOLE_STDOUT=""
IOS_CONSOLE_STDERR=""
IOS_CONSOLE_CAPTURE_DIAGNOSTIC=""
IOS_CONSOLE_HANDLE_STARTED=0
IOS_CONSOLE_HANDLE_CAPTURED=0
DID_COPY_IOS_BOOTSTRAP=0
MAC_PQC_DEVICE_ID=""
SESSION_ID=""
SESSION_REF=""
APP_SESSION_REF=""
WEBRTC_GATE_OBSERVED_MILLIS=0
MEDIA_EVIDENCE_WINDOW_MILLIS=0
MAC_SYSTEM_KEYCHAIN_PROOF=0
IOS_SYSTEM_KEYCHAIN_PROOF=0
HUMAN_APPROVAL_PROOF=0
IOS_BUILD_CONFIGURATION=""
IOS_SOURCE_COMMIT=""
IOS_SOURCE_DIRTY_STATE="unknown"
IOS_SOURCE_CLEAN=0
IOS_EXPECTED_ENTITLEMENTS=""
IOS_DISTRIBUTION_PREFLIGHT=""
IOS_APP_DISTRIBUTION_PROFILE=""
IOS_WIDGET_DISTRIBUTION_PROFILE=""
IOS_DISTRIBUTION_IDENTITY_HASH=""
IOS_DISTRIBUTION_PREFLIGHT_SCHEMA=""
IOS_DISTRIBUTION_SIGNING_STYLE=""
IOS_APP_PROFILE_IS_XCODE_MANAGED=""
IOS_WIDGET_PROFILE_IS_XCODE_MANAGED=""
ACCEPTANCE_CANDIDATE_READY=0

cleanup() {
  local original_status=$?
  local cleanup_status=0
  trap - EXIT

  if [[ "$IOS_CONSOLE_HANDLE_STARTED" == "1" ]]; then
    copy_round_diagnostics || true
    if ! terminate_ios_app; then
      cleanup_status=1
      echo "failed stage=cleanup phase=ios-process reason=exact-process-exit-unverified" >&2
    fi
  else
    copy_mac_media_diagnostics || true
  fi
  if ! terminate_mac_host; then
    cleanup_status=1
    echo "failed stage=cleanup phase=mac-process reason=exact-process-exit-unverified" >&2
  fi
  if ! destroy_process_ownership_session; then
    cleanup_status=1
    echo "Failed to remove the private WebRTC process-ownership directory: ${PROCESS_OWNERSHIP_PRIVATE_DIR:-<unknown>}" >&2
  fi
  if ! overwrite_ios_bootstrap_with_tombstone; then
    cleanup_status=1
    echo "Failed to overwrite the one-time iOS WebRTC bootstrap; reinstall the test app before another run." >&2
  fi
  if ! destroy_private_auth_session; then
    cleanup_status=1
    echo "Failed to remove the private WebRTC auth-session directory; secret material may remain at: ${AUTH_PRIVATE_DIR:-<unknown>}" >&2
  fi

  if (( original_status == 0 && cleanup_status == 0 && ACCEPTANCE_CANDIDATE_READY == 1 )); then
    if ! finalize_release_acceptance_manifests_after_cleanup; then
      cleanup_status=1
      echo "failed stage=cleanup phase=release-acceptance reason=manifest-finalization-failed" >&2
    fi
  fi

  if (( original_status == 0 && cleanup_status == 0 && ACCEPTANCE_CANDIDATE_READY == 1 )); then
    echo "==> Real-device WebRTC smoke succeeded after verified Mac/iOS process cleanup"
    echo "    session: $SESSION_ID"
    echo "    mac status: $MAC_STATUS"
    echo "    ios status: $IOS_STATUS_LOCAL"
    echo "    ios trace:  $IOS_TRACE_LOCAL"
    echo "    doctor:     $ARTIFACT_DIR/webrtc_media_doctor.json"
  fi

  if (( original_status == 0 && cleanup_status != 0 )); then
    exit "$cleanup_status"
  fi
  exit "$original_status"
}
trap cleanup EXIT

initialize_private_auth_session_dir() {
  if [[ -n "$AUTH_PRIVATE_DIR" ]]; then
    echo "Private auth-session directory was initialized more than once." >&2
    return 1
  fi
  AUTH_PRIVATE_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/skybridge-webrtc-auth.XXXXXX")"
  chmod 0700 "$AUTH_PRIVATE_DIR"
}

initialize_process_ownership_session() {
  if [[ -n "$PROCESS_OWNERSHIP_PRIVATE_DIR" ]]; then
    echo "Private process-ownership directory was initialized more than once." >&2
    return 1
  fi
  rm -f -- "$IOS_PROCESS_CLEANUP_RECEIPT"
  PROCESS_OWNERSHIP_PRIVATE_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/skybridge-webrtc-process-ownership.XXXXXX")"
  MAC_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/mac-process-identity.json"
  IOS_PROCESS_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-process-identity.json"
  IOS_CONSOLE_HANDLE_IDENTITY="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console-handle-identity.json"
  IOS_CONSOLE_STDOUT="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console.stdout"
  IOS_CONSOLE_STDERR="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console.stderr"
  IOS_CONSOLE_CAPTURE_DIAGNOSTIC="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console-capture.log"
  IOS_LAUNCH_JSON="$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-launch.raw.json"
  chmod 0700 "$PROCESS_OWNERSHIP_PRIVATE_DIR"
}

destroy_process_ownership_session() {
  local cleanup_failed=0
  if [[ -n "$PROCESS_OWNERSHIP_PRIVATE_DIR" ]]; then
    local identity_file
    for identity_file in \
      "$MAC_PROCESS_IDENTITY" \
      "$IOS_PROCESS_IDENTITY" \
      "$IOS_CONSOLE_HANDLE_IDENTITY" \
      "$IOS_CONSOLE_STDOUT" \
      "$IOS_CONSOLE_STDERR" \
      "$IOS_CONSOLE_CAPTURE_DIAGNOSTIC" \
      "$IOS_LAUNCH_JSON"; do
      case "$identity_file" in
        "$PROCESS_OWNERSHIP_PRIVATE_DIR/mac-process-identity.json"|\
        "$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-process-identity.json"|\
        "$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console-handle-identity.json"|\
        "$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console.stdout"|\
        "$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console.stderr"|\
        "$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-console-capture.log"|\
        "$PROCESS_OWNERSHIP_PRIVATE_DIR/ios-launch.raw.json")
          if [[ -e "$identity_file" || -L "$identity_file" ]] && ! rm -f -- "$identity_file"; then
            echo "Unable to remove private WebRTC process-ownership record: $identity_file" >&2
            cleanup_failed=1
          fi
          ;;
        *)
          echo "Refusing to remove an unexpected WebRTC process-ownership path." >&2
          cleanup_failed=1
          ;;
      esac
    done
    if ! rmdir -- "$PROCESS_OWNERSHIP_PRIVATE_DIR" 2>/dev/null; then
      echo "Private WebRTC process-ownership directory is not empty or could not be removed." >&2
      cleanup_failed=1
    fi
  fi
  if (( cleanup_failed == 0 )); then
    MAC_PROCESS_IDENTITY=""
    IOS_PROCESS_IDENTITY=""
    IOS_CONSOLE_HANDLE_IDENTITY=""
    IOS_CONSOLE_STDOUT=""
    IOS_CONSOLE_STDERR=""
    IOS_CONSOLE_CAPTURE_DIAGNOSTIC=""
    IOS_LAUNCH_JSON=""
    PROCESS_OWNERSHIP_PRIVATE_DIR=""
  fi
  return "$cleanup_failed"
}

precreate_product_output_files() {
  python3 - "$ARTIFACT_DIR" "$MAC_STATUS" "$MAC_CODE" "$MAC_PQC_REPORT" <<'PY'
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
paths = [pathlib.Path(value) for value in sys.argv[2:]]
metadata = root.lstat()
if root.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
    raise SystemExit("WebRTC product output root must be a real directory")
if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
    raise SystemExit("WebRTC product output root must be owned by the current user with mode 0700")

for path in paths:
    if path.parent != root:
        raise SystemExit("WebRTC product outputs must be direct children of the private output root")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise SystemExit(f"Unable to pre-create private product output {path.name} ({type(error).__name__})")
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) != 0o600
        ):
            raise SystemExit(f"Private product output boundary is invalid: {path.name}")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
PY
}

destroy_private_auth_session() {
  local cleanup_failed=0
  if [[ -n "$AUTH_PRIVATE_DIR" ]]; then
    local private_file
    for private_file in \
      "$AUTH_SESSION_FILE" \
      "$MAC_CODE" \
      "$MAC_TOKEN" \
      "$MAC_TENANT" \
      "$MAC_AUTH_BINDING" \
      "$IOS_BOOTSTRAP_SOURCE" \
      "$IOS_BOOTSTRAP_TOMBSTONE" \
      "$AUTH_PRIVATE_DIR/mac-product.entitlements.plist" \
      "$AUTH_PRIVATE_DIR/mac.code" \
      "$AUTH_PRIVATE_DIR/ios-product.entitlements.plist" \
      "$AUTH_PRIVATE_DIR/ios-product.mobileprovision.plist" \
      "$AUTH_PRIVATE_DIR/ios-product.codesign.txt" \
      "$AUTH_PRIVATE_DIR/ios-distribution-signing-preflight.json" \
      "$AUTH_PRIVATE_DIR/app-signed-entitlements.plist" \
      "$AUTH_PRIVATE_DIR/widget-signed-entitlements.plist" \
      "$AUTH_PRIVATE_DIR"/app-signing-certificate-* \
      "$AUTH_PRIVATE_DIR"/widget-signing-certificate-* \
      "$AUTH_PRIVATE_DIR"/ios-signing-certificate-* \
      "$AUTH_PRIVATE_DIR"/.host.auth-session.* \
      "$AUTH_PRIVATE_DIR"/.bootstrap-access-token.* \
      "$AUTH_PRIVATE_DIR"/.bootstrap-tenant.* \
      "$AUTH_PRIVATE_DIR"/.auth-binding.*; do
      case "$private_file" in
        "$AUTH_PRIVATE_DIR/host.auth-session.json"|"$AUTH_PRIVATE_DIR/mac.code"|"$AUTH_PRIVATE_DIR/mac.token"|"$AUTH_PRIVATE_DIR/mac.tenant"|"$AUTH_PRIVATE_DIR/mac.auth-binding.sha256"|"$AUTH_PRIVATE_DIR/$IOS_BOOTSTRAP_FILE_NAME"|"$AUTH_PRIVATE_DIR/bootstrap-tombstone/$IOS_BOOTSTRAP_FILE_NAME"|"$AUTH_PRIVATE_DIR/mac-product.entitlements.plist"|"$AUTH_PRIVATE_DIR/ios-product.entitlements.plist"|"$AUTH_PRIVATE_DIR/ios-product.mobileprovision.plist"|"$AUTH_PRIVATE_DIR/ios-product.codesign.txt"|"$AUTH_PRIVATE_DIR/ios-distribution-signing-preflight.json"|"$AUTH_PRIVATE_DIR/app-signed-entitlements.plist"|"$AUTH_PRIVATE_DIR/widget-signed-entitlements.plist"|"$AUTH_PRIVATE_DIR"/app-signing-certificate-*|"$AUTH_PRIVATE_DIR"/widget-signing-certificate-*|"$AUTH_PRIVATE_DIR"/ios-signing-certificate-*|"$AUTH_PRIVATE_DIR"/.host.auth-session.*|"$AUTH_PRIVATE_DIR"/.bootstrap-access-token.*|"$AUTH_PRIVATE_DIR"/.bootstrap-tenant.*|"$AUTH_PRIVATE_DIR"/.auth-binding.*)
          if [[ -e "$private_file" || -L "$private_file" ]] && ! rm -f -- "$private_file"; then
            echo "Unable to remove private WebRTC auth file: $private_file" >&2
            cleanup_failed=1
          fi
          ;;
      esac
    done
    if [[ -d "$AUTH_PRIVATE_DIR/bootstrap-tombstone" ]] \
      && ! rmdir -- "$AUTH_PRIVATE_DIR/bootstrap-tombstone" 2>/dev/null; then
      echo "Unable to remove private WebRTC bootstrap tombstone directory." >&2
      cleanup_failed=1
    fi
  fi
  if [[ -n "$AUTH_PRIVATE_DIR" ]] && ! rmdir -- "$AUTH_PRIVATE_DIR" 2>/dev/null; then
    echo "Private WebRTC auth directory is not empty or could not be removed: $AUTH_PRIVATE_DIR" >&2
    cleanup_failed=1
  fi
  if (( cleanup_failed == 0 )); then
    AUTH_SESSION_FILE=""
    MAC_CODE=""
    MAC_TOKEN=""
    MAC_TENANT=""
    MAC_AUTH_BINDING=""
    AUTH_BINDING_DIGEST=""
    IOS_BOOTSTRAP_SOURCE=""
    IOS_BOOTSTRAP_TOMBSTONE=""
    AUTH_PRIVATE_DIR=""
  fi
  return "$cleanup_failed"
}

overwrite_ios_bootstrap_with_tombstone() {
  if [[ "$DID_COPY_IOS_BOOTSTRAP" != "1" ]]; then
    return 0
  fi
  if [[ -z "$IOS_DEVICE_ID" || -z "$IOS_BOOTSTRAP_TOMBSTONE" || ! -f "$IOS_BOOTSTRAP_TOMBSTONE" ]]; then
    return 1
  fi

  if ! xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device copy to \
    --device "$IOS_DEVICE_ID" \
    --source "$IOS_BOOTSTRAP_TOMBSTONE" \
    --destination "$IOS_BOOTSTRAP_REMOTE_DIRECTORY" \
    --domain-type appDataContainer \
    --domain-identifier "$IOS_BUNDLE_ID" >/dev/null; then
    return 1
  fi
  DID_COPY_IOS_BOOTSTRAP=0
}

prepare_ios_bootstrap() {
  if [[ -z "$AUTH_PRIVATE_DIR" || ! -d "$AUTH_PRIVATE_DIR" ]]; then
    echo "Private auth-session directory is not initialized." >&2
    return 1
  fi
  IOS_BOOTSTRAP_SOURCE="$AUTH_PRIVATE_DIR/$IOS_BOOTSTRAP_FILE_NAME"
  local tombstone_directory="$AUTH_PRIVATE_DIR/bootstrap-tombstone"
  mkdir -p "$tombstone_directory"
  chmod 0700 "$tombstone_directory"
  IOS_BOOTSTRAP_TOMBSTONE="$tombstone_directory/$IOS_BOOTSTRAP_FILE_NAME"

  python3 - \
    "$MAC_CODE" \
    "$MAC_TOKEN" \
    "$MAC_TENANT" \
    "$MAC_PQC_REPORT" \
    "$IOS_BOOTSTRAP_SOURCE" \
    "$IOS_BOOTSTRAP_TOMBSTONE" \
    "$RUN_ID" \
    "$SMOKE_TIMEOUT_SECONDS" <<'PY'
import json
import os
import pathlib
import stat
import sys
import tempfile
import time

(
    code_path,
    token_path,
    tenant_path,
    pqc_report_path,
    output_path,
    tombstone_path,
    run_id,
    timeout_text,
) = sys.argv[1:9]


def fail(message):
    raise SystemExit(message)


def read_bounded_regular_file(path, label, maximum_bytes, require_private_mode=True):
    candidate = pathlib.Path(path)
    try:
        metadata = candidate.lstat()
    except OSError as exc:
        fail(f"Unable to inspect {label} source ({type(exc).__name__})")
    if candidate.is_symlink() or not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} source must be a regular non-symlink file")
    if metadata.st_uid != os.geteuid() or metadata.st_nlink != 1:
        fail(f"{label} source must be owned by the current user with exactly one link")
    if require_private_mode and stat.S_IMODE(metadata.st_mode) != 0o600:
        fail(f"{label} source permissions must be exactly 0600")
    if metadata.st_size <= 0 or metadata.st_size > maximum_bytes:
        fail(f"{label} source is empty or exceeds its size limit")
    descriptor = None
    try:
        descriptor = os.open(
            candidate,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        opened_metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened_metadata.st_mode)
            or (opened_metadata.st_dev, opened_metadata.st_ino)
            != (metadata.st_dev, metadata.st_ino)
            or opened_metadata.st_uid != os.geteuid()
            or opened_metadata.st_nlink != 1
            or (require_private_mode and stat.S_IMODE(opened_metadata.st_mode) != 0o600)
            or opened_metadata.st_size != metadata.st_size
        ):
            fail(f"{label} source changed while it was being opened")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = None
            data = handle.read(maximum_bytes + 1)
    except SystemExit:
        raise
    except OSError as exc:
        fail(f"Unable to read {label} source ({type(exc).__name__})")
    finally:
        if descriptor is not None:
            os.close(descriptor)
    if len(data) != metadata.st_size:
        fail(f"{label} source changed while it was being read")
    return data


def read_private_value(path, label, maximum_bytes):
    data = read_bounded_regular_file(path, label, maximum_bytes)
    try:
        decoded = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(f"{label} source is not UTF-8 ({type(exc).__name__})")
    value = decoded.rstrip("\r\n")
    if value != value.strip() or not value \
      or any(ord(character) < 0x20 or ord(character) == 0x7F for character in value):
        fail(f"{label} source contains an empty value or control character")
    return value


def atomic_private_json(path, payload):
    destination = pathlib.Path(path)
    try:
        parent_metadata = destination.parent.lstat()
    except OSError as exc:
        fail(f"Unable to inspect private bootstrap directory ({type(exc).__name__})")
    if (
        destination.parent.is_symlink()
        or not stat.S_ISDIR(parent_metadata.st_mode)
        or stat.S_IMODE(parent_metadata.st_mode) != 0o700
    ):
        fail("Private bootstrap directory must be a non-symlink directory with mode 0700")
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=destination.parent,
            delete=False,
        ) as handle:
            temporary_path = pathlib.Path(handle.name)
            os.fchmod(handle.fileno(), 0o600)
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"), allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, destination)
        temporary_path = None
        os.chmod(destination, 0o600, follow_symlinks=False)
        directory_descriptor = os.open(
            destination.parent,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


try:
    timeout_seconds = int(timeout_text)
except ValueError:
    fail("WebRTC smoke timeout must be an integer before creating the bootstrap")
if timeout_seconds <= 0:
    fail("WebRTC smoke timeout must be positive before creating the bootstrap")

connection_code = read_private_value(code_path, "connection code", 128)
access_token = read_private_value(token_path, "access token", 16_384)
tenant_id = read_private_value(tenant_path, "tenant id", 1_024)

report_path = pathlib.Path(pqc_report_path)
try:
    report_bytes = read_bounded_regular_file(
        report_path,
        "PQC report",
        64 * 1_024,
    )
    report = json.loads(report_bytes.decode("utf-8", errors="strict"))
except (UnicodeDecodeError, json.JSONDecodeError) as exc:
    fail(f"PQC report is malformed ({type(exc).__name__})")
if not isinstance(report, dict):
    fail("PQC report must be a JSON object")
peer_device_id = report.get("deviceId")
if not isinstance(peer_device_id, str) or not peer_device_id.strip():
    fail("PQC report is missing peer deviceId")

keys = []
seen_wire_ids = set()
for entry in report.get("keys", []):
    if not isinstance(entry, dict):
        fail("PQC report key entry is malformed")
    wire_id = entry.get("suiteWireId")
    public_key = entry.get("publicKeyBase64")
    if wire_id not in (0x0001, 0x0101, 0x0102):
        continue
    if wire_id in seen_wire_ids or not isinstance(public_key, str) or not public_key:
        fail("PQC report contains duplicate or empty accepted key material")
    seen_wire_ids.add(wire_id)
    keys.append({"suiteWireId": wire_id, "publicKeyBase64": public_key})
if 0x0001 not in seen_wire_ids:
    fail("PQC report is missing the required X-Wing public key")

expires_at = int(time.time()) + min(max(timeout_seconds + 120, 300), 900)
atomic_private_json(
    output_path,
    {
        "accessToken": access_token,
        "connectionCode": connection_code,
        "expiresAtEpochSeconds": expires_at,
        "peerDeviceId": peer_device_id,
        "peerKEMPublicKeys": sorted(keys, key=lambda item: item["suiteWireId"]),
        "runId": run_id,
        "schemaVersion": 1,
        "tenantId": tenant_id,
    },
)
atomic_private_json(
    tombstone_path,
    {
        "expiresAtEpochSeconds": 0,
        "runId": "consumed",
        "schemaVersion": 1,
        "state": "consumed",
    },
)
PY
}

terminate_mac_host() {
  if [[ -z "$MAC_PID" ]]; then
    return 0
  fi
  if [[ -z "$MAC_PROCESS_IDENTITY" || ! -f "$MAC_PROCESS_IDENTITY" ]]; then
    echo "Refusing to signal the macOS WebRTC PID without its private ownership record." >&2
    return 1
  fi
  local target_pid
  if ! target_pid="$(python3 "$PROCESS_OWNERSHIP_HELPER" identity-pid \
    --platform macos \
    --identity "$MAC_PROCESS_IDENTITY")"; then
    echo "Refusing to signal the macOS WebRTC PID because its ownership record is invalid." >&2
    return 1
  fi
  if [[ "$target_pid" != "$MAC_PID" ]]; then
    echo "Refusing to signal the macOS WebRTC PID because launch state and ownership record disagree." >&2
    return 1
  fi

  local process_status
  if python3 "$PROCESS_OWNERSHIP_HELPER" mac-status --identity "$MAC_PROCESS_IDENTITY"; then
    process_status=0
  else
    process_status=$?
  fi
  if (( process_status == 1 )); then
    wait "$target_pid" >/dev/null 2>&1 || true
    rm -f -- "$MAC_PROCESS_IDENTITY"
    MAC_PID=""
    return 0
  fi
  if (( process_status != 0 )); then
    echo "Refusing to send SIGTERM: macOS WebRTC process ownership is unverifiable." >&2
    return 1
  fi
  local signal_status
  if python3 "$PROCESS_OWNERSHIP_HELPER" mac-signal \
    --identity "$MAC_PROCESS_IDENTITY" \
    --signal TERM; then
    signal_status=0
  else
    signal_status=$?
  fi
  if (( signal_status == 1 )); then
    wait "$target_pid" >/dev/null 2>&1 || true
    rm -f -- "$MAC_PROCESS_IDENTITY"
    MAC_PID=""
    return 0
  fi
  if (( signal_status != 0 )); then
    echo "SIGTERM was not sent because exact macOS WebRTC process ownership could not be preserved." >&2
    return 1
  fi
  for _ in {1..20}; do
    if python3 "$PROCESS_OWNERSHIP_HELPER" mac-status --identity "$MAC_PROCESS_IDENTITY"; then
      sleep 0.25
      continue
    fi
    process_status=$?
    if (( process_status == 1 )); then
      wait "$target_pid" >/dev/null 2>&1 || true
      rm -f -- "$MAC_PROCESS_IDENTITY"
      MAC_PID=""
      return 0
    fi
    echo "macOS WebRTC process ownership became unverifiable after SIGTERM: pid=$target_pid" >&2
    return 1
  done

  if python3 "$PROCESS_OWNERSHIP_HELPER" mac-status --identity "$MAC_PROCESS_IDENTITY"; then
    process_status=0
  else
    process_status=$?
    if (( process_status == 1 )); then
      wait "$target_pid" >/dev/null 2>&1 || true
      rm -f -- "$MAC_PROCESS_IDENTITY"
      MAC_PID=""
      return 0
    fi
    echo "Refusing to send SIGKILL: macOS WebRTC process ownership is unverifiable." >&2
    return 1
  fi
  if python3 "$PROCESS_OWNERSHIP_HELPER" mac-signal \
    --identity "$MAC_PROCESS_IDENTITY" \
    --signal KILL; then
    signal_status=0
  else
    signal_status=$?
  fi
  if (( signal_status == 1 )); then
    wait "$target_pid" >/dev/null 2>&1 || true
    rm -f -- "$MAC_PROCESS_IDENTITY"
    MAC_PID=""
    return 0
  fi
  if (( signal_status != 0 )); then
    echo "SIGKILL was not sent because exact macOS WebRTC process ownership could not be preserved." >&2
    return 1
  fi
  for _ in {1..20}; do
    if python3 "$PROCESS_OWNERSHIP_HELPER" mac-status --identity "$MAC_PROCESS_IDENTITY"; then
      sleep 0.25
      continue
    fi
    process_status=$?
    if (( process_status == 1 )); then
      wait "$target_pid" >/dev/null 2>&1 || true
      rm -f -- "$MAC_PROCESS_IDENTITY"
      MAC_PID=""
      return 0
    fi
    echo "macOS WebRTC process ownership became unverifiable after SIGKILL: pid=$target_pid" >&2
    return 1
  done
  echo "macOS WebRTC product process remains alive after SIGKILL: pid=$target_pid" >&2
  return 1
}

ios_console_handle_is_exact_and_running() {
  [[ "$IOS_CONSOLE_HANDLE_CAPTURED" == "1" ]] || return 1
  skybridge_ios_console_handle_status \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$IOS_CONSOLE_PID" \
    "$IOS_CONSOLE_HANDLE_IDENTITY" >/dev/null 2>&1
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

launch_ios_app_with_console_handle() {
  if ! skybridge_ios_require_fresh_app_launch \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$IOS_DEVICE_ID" \
    "$IOS_APP_PATH" \
    "$PROCESS_OWNERSHIP_PRIVATE_DIR" \
    "$DEVICECTL_TIMEOUT_SECONDS"; then
    return 1
  fi

  skybridge_ios_start_console_launch \
    "$IOS_DEVICE_ID" \
    "$IOS_BUNDLE_ID" \
    "$IOS_ENV_JSON" \
    "$IOS_CONSOLE_TOTAL_TIMEOUT_SECONDS" \
    "$IOS_LAUNCH_JSON" \
    "$IOS_CONSOLE_STDOUT" \
    "$IOS_CONSOLE_STDERR" \
    IOS_CONSOLE_PID
  IOS_CONSOLE_HANDLE_STARTED=1

  if ! skybridge_ios_capture_console_handle \
    "$PROCESS_OWNERSHIP_HELPER" \
    "$IOS_CONSOLE_PID" \
    "$IOS_CONSOLE_HANDLE_IDENTITY" \
    "$IOS_CONSOLE_CAPTURE_DIAGNOSTIC" \
    "$IOS_CONSOLE_HANDLE_CAPTURE_TIMEOUT_SECONDS"; then
    if kill -0 "$IOS_CONSOLE_PID" >/dev/null 2>&1; then
      echo "iOS WebRTC console handle is alive but exact ownership capture failed; refusing PID-only cleanup." >&2
      return 1
    fi
    wait "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
    IOS_CONSOLE_HANDLE_STARTED=0
    if ! skybridge_ios_require_app_absent_after_handle_exit \
      "$PROCESS_OWNERSHIP_HELPER" \
      "$IOS_DEVICE_ID" \
      "$IOS_APP_PATH" \
      "$PROCESS_OWNERSHIP_PRIVATE_DIR" \
      "$DEVICECTL_TIMEOUT_SECONDS"; then
      echo "iOS WebRTC launch failed before handle capture and remote absence is unproven." >&2
      return 1
    fi
    echo "iOS WebRTC launch command exited before exact console ownership was captured." >&2
    return 1
  fi

  IOS_CONSOLE_HANDLE_CAPTURED=1
  sleep 0.5
  if ! ios_console_handle_is_exact_and_running; then
    echo "iOS WebRTC console launch handle exited or became unverifiable during startup." >&2
    return 1
  fi
}

terminate_ios_app() {
  local exited_ios_pid

  if [[ "$IOS_CONSOLE_HANDLE_CAPTURED" != "1" ]] \
    || [[ -z "$IOS_CONSOLE_PID" ]] \
    || [[ ! -f "$IOS_CONSOLE_HANDLE_IDENTITY" ]]; then
    echo "Refusing iOS WebRTC cleanup because exact console-handle ownership was not captured." >&2
    return 1
  fi

  local handle_status
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
        echo "Failed to signal the exact iOS WebRTC console launch handle." >&2
        return 1
      fi
      ;;
    1)
      wait "$IOS_CONSOLE_PID" >/dev/null 2>&1 || true
      ;;
    *)
      echo "Refusing iOS WebRTC cleanup because the console launch handle is unverifiable." >&2
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
    "$IOS_LAUNCH_JSON" \
    "$IOS_APP_PATH" \
    "$IOS_PROCESS_IDENTITY"; then
    echo "Unable to capture the exited iOS WebRTC launch identity." >&2
    return 1
  fi
  if ! exited_ios_pid="$(python3 "$PROCESS_OWNERSHIP_HELPER" identity-pid \
    --platform ios \
    --identity "$IOS_PROCESS_IDENTITY")" \
    || ! [[ "$exited_ios_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "Unable to read the exited iOS WebRTC launch PID evidence." >&2
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
    echo "Unable to write the iOS WebRTC process-cleanup receipt." >&2
    return 1
  fi

  IOS_CONSOLE_HANDLE_STARTED=0
  IOS_CONSOLE_HANDLE_CAPTURED=0
  return 0
}

regex_escape() {
  python3 - "$1" <<'PY'
import re
import sys

print(re.escape(sys.argv[1]))
PY
}

validate_remote_signaling_urls() {
  if [[ "$LAB_RUN" != "1" ]]; then
    if [[ "$ALLOW_PRIVATE_SIGNALING" == "1" || "$ALLOW_LOCALHOST_SIGNALING" == "1" || "$ALLOW_INSECURE_SIGNALING" == "1" || "$ALLOW_UNRESOLVED_SIGNALING" == "1" ]]; then
      cat >&2 <<'EOF'
Real-device WebRTC acceptance forbids local/private/insecure/unresolved signaling overrides.

Set SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN=1 only for non-acceptance diagnostics.
Lab runs are intentionally reported as non-acceptance and do not produce a successful
performance gate result.
EOF
      exit 1
    fi
  fi

  if [[ -z "$SIGNALING_SERVER_URL" || -z "$SIGNALING_WS_URL" ]]; then
    cat >&2 <<EOF
Missing real-device WebRTC signaling URLs.

Set SKYBRIDGE_SIGNALING_SERVER_URL and SKYBRIDGE_SIGNALING_WEBSOCKET_URL
to the remote registry/signaling service used by the cross-network test.
Defaults are:
  SKYBRIDGE_SIGNALING_SERVER_URL=$DEFAULT_SIGNALING_SERVER_URL
  SKYBRIDGE_SIGNALING_WEBSOCKET_URL=$DEFAULT_SIGNALING_WS_URL
This script intentionally does not start localhost signaling for the default
real-device performance gate, because localhost/LAN signaling would be a proxy
for the user's cross-network scenario.
EOF
    exit 1
  fi

  python3 - "$SIGNALING_SERVER_URL" "$SIGNALING_WS_URL" "$ALLOW_PRIVATE_SIGNALING" "$ALLOW_LOCALHOST_SIGNALING" "$ALLOW_INSECURE_SIGNALING" "$ALLOW_UNRESOLVED_SIGNALING" "$LAB_RUN" <<'PY'
import json
import ipaddress
import socket
import sys
import urllib.parse
import urllib.request
from urllib.parse import urlparse

http_url, ws_url, allow_private, allow_localhost, allow_insecure, allow_unresolved, lab_run = sys.argv[1:8]
allow_private = allow_private == "1"
allow_localhost = allow_localhost == "1"
allow_insecure = allow_insecure == "1"
allow_unresolved = allow_unresolved == "1"
lab_run = lab_run == "1"

def reject(message):
    raise SystemExit(message)

def public_dns_addresses(host):
    addresses = []
    for rrtype in ("A", "AAAA"):
        query = urllib.parse.urlencode({"name": host, "type": rrtype})
        request = urllib.request.Request(
            f"https://cloudflare-dns.com/dns-query?{query}",
            headers={"Accept": "application/dns-json"},
        )
        with urllib.request.urlopen(request, timeout=8) as response:
            payload = json.loads(response.read().decode("utf-8"))
        for answer in payload.get("Answer", []) or []:
            data = str(answer.get("data") or "").strip()
            if not data:
                continue
            try:
                addresses.append(ipaddress.ip_address(data))
            except ValueError:
                pass
    return addresses

def validate(url, label, secure_scheme):
    parsed = urlparse(url)
    supported = {"http", "https"} if secure_scheme == "https" else {"ws", "wss"}
    if parsed.scheme not in supported:
        reject(f"{label} has unsupported scheme: {url}")
    if parsed.scheme != secure_scheme and not allow_insecure:
        reject(
            f"{label} must use {secure_scheme} for real-device acceptance: {url}. "
            "Set SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_INSECURE_SIGNALING=1 only for non-acceptance lab runs."
        )
    host = parsed.hostname
    if not host:
        reject(f"{label} is missing host: {url}")
    if host in {"localhost", "127.0.0.1", "::1"} and not allow_localhost:
        reject(
            f"{label} points to localhost ({host}); set "
            "SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_LOCALHOST_SIGNALING=1 only for non-acceptance lab runs."
        )
    host_is_literal = False
    public_dns_error = None
    try:
        addresses = [ipaddress.ip_address(host)]
        host_is_literal = True
    except ValueError:
        addresses = []
        try:
            for family, _, _, _, sockaddr in socket.getaddrinfo(host, None):
                address = sockaddr[0]
                try:
                    addresses.append(ipaddress.ip_address(address))
                except ValueError:
                    pass
        except socket.gaierror as exc:
            if allow_unresolved:
                return
            reject(
                f"{label} host does not resolve ({host}): {exc}. "
                "Set SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_UNRESOLVED_SIGNALING=1 only for DNS lab runs."
            )
    if not host_is_literal:
        try:
            public_addresses = public_dns_addresses(host)
        except Exception as exc:
            public_addresses = []
            public_dns_error = str(exc)
        if public_addresses:
            addresses = public_addresses
    for address in addresses:
        if address.is_loopback and not allow_localhost:
            reject(f"{label} resolves to loopback address {address}")
        if (address.is_private or address.is_link_local) and not allow_private:
            reject(
                f"{label} resolves to private/link-local address {address}; set "
                "SKYBRIDGE_REAL_DEVICE_WEBRTC_ALLOW_PRIVATE_SIGNALING=1 only when this is an explicit lab run, "
                "not final cross-network acceptance."
            )
        if not lab_run and not address.is_global:
            suffix = f" Public DNS probe failed: {public_dns_error}" if public_dns_error else ""
            reject(
                f"{label} resolves to non-global address {address}; real-device cross-network "
                f"acceptance requires a globally routable signaling endpoint.{suffix}"
            )

validate(http_url, "SKYBRIDGE_SIGNALING_SERVER_URL", "https")
validate(ws_url, "SKYBRIDGE_SIGNALING_WEBSOCKET_URL", "wss")
PY
}

validate_acceptance_profile() {
  case "$LAB_RUN" in
    0|1) ;;
    *)
      echo "SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN must be 0 or 1" >&2
      exit 2
      ;;
  esac

  case "$KEYCHAIN_MODE" in
    system|in-memory) ;;
    *)
      echo "SKYBRIDGE_SMOKE_KEYCHAIN_MODE must be system or in-memory" >&2
      exit 2
      ;;
  esac
  case "$MAC_HOST_MODE" in
    product|diagnostic-cli) ;;
    *)
      echo "SKYBRIDGE_SMOKE_MAC_HOST_MODE must be product or diagnostic-cli" >&2
      exit 2
      ;;
  esac

  if [[ "$KEYCHAIN_MODE" == "in-memory" || "$MAC_HOST_MODE" == "diagnostic-cli" ]]; then
    if [[ "$LAB_RUN" != "1" ]]; then
      echo "In-memory identity and the CLI host are diagnostic-only and require SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN=1." >&2
      exit 2
    fi
    if [[ "$KEYCHAIN_MODE" != "in-memory" || "$MAC_HOST_MODE" != "diagnostic-cli" ]]; then
      echo "Diagnostic WebRTC runs must pair SKYBRIDGE_SMOKE_KEYCHAIN_MODE=in-memory with SKYBRIDGE_SMOKE_MAC_HOST_MODE=diagnostic-cli." >&2
      exit 2
    fi
  fi

  if ! [[ "$SMOKE_SOAK_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "SKYBRIDGE_SMOKE_SOAK_SECONDS must be a non-negative integer" >&2
    exit 2
  fi
  if ! [[ "$IOS_CONSOLE_TOTAL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "SKYBRIDGE_SMOKE_IOS_CONSOLE_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
  fi
  if ! [[ "$IOS_CONSOLE_HANDLE_CAPTURE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "SKYBRIDGE_SMOKE_IOS_CONSOLE_CAPTURE_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
  fi

  if [[ "$LAB_RUN" == "1" ]]; then
    return 0
  fi

  local violations=()
  [[ "$KEYCHAIN_MODE" == "system" ]] || violations+=("SKYBRIDGE_SMOKE_KEYCHAIN_MODE=system")
  [[ "$MAC_HOST_MODE" == "product" ]] || violations+=("SKYBRIDGE_SMOKE_MAC_HOST_MODE=product")
  [[ "$SMOKE_FORCE_RELAY_ICE" == "1" ]] || violations+=("SKYBRIDGE_SMOKE_FORCE_RELAY_ICE=1")
  [[ "$SMOKE_REQUIRE_AUDIO" == "1" ]] || violations+=("SKYBRIDGE_SMOKE_REQUIRE_AUDIO=1")
  [[ "$SKIP_MEDIA_RELAY_PREFLIGHT" == "0" ]] || violations+=("SKYBRIDGE_SMOKE_SKIP_MEDIA_RELAY_PREFLIGHT=0")
  [[ "$SMOKE_SYNTHETIC_SCREEN" == "0" ]] || violations+=("SKYBRIDGE_SMOKE_SYNTHETIC_SCREEN=0")
  [[ "$SMOKE_SYNTHETIC_OPUS_TONE" == "0" ]] || violations+=("SKYBRIDGE_SMOKE_SYNTHETIC_OPUS_TONE=0")
  (( SMOKE_SOAK_SECONDS >= MIN_ACCEPTANCE_SOAK_SECONDS )) \
    || violations+=("SKYBRIDGE_SMOKE_SOAK_SECONDS>=${MIN_ACCEPTANCE_SOAK_SECONDS}")

  if (( ${#violations[@]} > 0 )); then
    printf 'Real-device WebRTC acceptance profile is degraded; required: %s\n' "${violations[*]}" >&2
    echo "Set SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN=1 only for non-acceptance diagnostics." >&2
    exit 2
  fi
}

write_release_acceptance_manifest() {
  local relay_candidate_observed=0
  if [[ -n "$APP_SESSION_REF" ]] \
    && grep -Fq "remote-ice session_ref=${APP_SESSION_REF} kind=relay" "$IOS_TRACE_LOCAL" 2>/dev/null; then
    relay_candidate_observed=1
  fi
  if [[ "$LAB_RUN" != "1" && "$relay_candidate_observed" != "1" ]]; then
    echo "Real-device WebRTC acceptance did not observe a relay ICE candidate in app-authored diagnostics." >&2
    return 1
  fi

  python3 - \
    "$ARTIFACT_DIR/release-acceptance.json" \
    "$LAB_RUN" \
    "$SMOKE_FORCE_RELAY_ICE" \
    "$SMOKE_REQUIRE_AUDIO" \
    "$SKIP_MEDIA_RELAY_PREFLIGHT" \
    "$SMOKE_SYNTHETIC_SCREEN" \
    "$SMOKE_SYNTHETIC_OPUS_TONE" \
    "$SMOKE_SOAK_SECONDS" \
    "$relay_candidate_observed" \
    "$SESSION_REF" \
    "$WEBRTC_GATE_OBSERVED_MILLIS" \
    "$MEDIA_EVIDENCE_WINDOW_MILLIS" \
    "$KEYCHAIN_MODE" \
    "$MAC_HOST_MODE" \
    "$MAC_SYSTEM_KEYCHAIN_PROOF" \
    "$IOS_SYSTEM_KEYCHAIN_PROOF" \
    "$HUMAN_APPROVAL_PROOF" \
    "$ARTIFACT_DIR/product-path-proof.json" <<'PY'
import json
import os
import pathlib
import sys
import tempfile

(
    output_path,
    lab_run,
    force_relay,
    require_audio,
    skip_preflight,
    synthetic_screen,
    synthetic_audio,
    soak_seconds,
    relay_candidate_observed,
    session_ref,
    observed_gate_window_millis,
    media_evidence_window_millis,
    keychain_mode,
    mac_host_mode,
    mac_system_keychain_proof,
    ios_system_keychain_proof,
    human_approval_proof,
    product_path_proof_path,
) = sys.argv[1:]

is_lab = lab_run == "1"
product_path_proof = json.loads(pathlib.Path(product_path_proof_path).read_text(encoding="utf-8"))
if not isinstance(product_path_proof, dict) or product_path_proof.get("schemaVersion") != 1:
    raise SystemExit("WebRTC product path proof is malformed before manifest creation")
ios_production_identity_lifecycle_verified = False
payload = {
    "schemaVersion": 1,
    "transport": "webrtc",
    "realDevice": True,
    "acceptanceEligible": False,
    "preCleanupCandidate": (
        not is_lab
        and product_path_proof.get("iosProductionProduct") is True
        and ios_production_identity_lifecycle_verified
    ),
    "cleanupComplete": False,
    "diagnosticOnly": True,
    "labRun": is_lab,
    "forceRelayIce": force_relay == "1",
    "requireAudio": require_audio == "1",
    "relayPreflight": skip_preflight == "0",
    "relayCandidateObserved": relay_candidate_observed == "1",
    "sessionRef": session_ref,
    "relayCandidateSessionRef": session_ref,
    "observedGateWindowMillis": int(observed_gate_window_millis),
    "mediaEvidenceWindowMillis": int(media_evidence_window_millis),
    "syntheticScreen": synthetic_screen == "1",
    "syntheticAudio": synthetic_audio == "1",
    "soakSeconds": int(soak_seconds),
    "macHandshakeComplete": True,
    "iosHandshakeComplete": True,
    "macPQCRekeyComplete": True,
    "iosPQCRekeyComplete": True,
    "mutualHandshake": True,
    "keychainMode": keychain_mode,
    "macKeychainMode": keychain_mode,
    "iosKeychainMode": keychain_mode,
    "macProductPath": mac_host_mode == "product",
    "iosProductPath": True,
    "approvalSurface": "shared-product-panel" if mac_host_mode == "product" else "diagnostic-none",
    "humanApproval": human_approval_proof == "1",
    "runtimeAutoApproval": False,
    "macSystemKeychainProof": mac_system_keychain_proof == "1",
    "macAuthBindingVerified": mac_system_keychain_proof == "1",
    "iosSystemKeychainProof": ios_system_keychain_proof == "1",
    "iosBuildConfiguration": product_path_proof.get("iosBuildConfiguration"),
    "iosSourceDirtyState": product_path_proof.get("iosSourceDirtyState"),
    "sourceRepository": product_path_proof.get("sourceRepository"),
    "sourceCommit": product_path_proof.get("sourceCommit"),
    "iosSourceCommit": product_path_proof.get("iosSourceCommit"),
    "iosProductSurface": product_path_proof.get("iosProductSurface"),
    "iosSwiftActiveCompilationConditions": product_path_proof.get("iosSwiftActiveCompilationConditions"),
    "iosTestingCompilationCondition": product_path_proof.get("iosTestingCompilationCondition") is True,
    "iosBinaryTestSurfaceDetected": product_path_proof.get("iosBinaryTestSurfaceDetected") is True,
    "iosProductionProduct": product_path_proof.get("iosProductionProduct") is True,
    "iosProductionIdentityAlgorithm": "unproven",
    "iosProductionIdentityProtection": "unproven",
    "iosProductionIdentityLifecycleVerified": ios_production_identity_lifecycle_verified,
    "iosProductionIdentityProof": False,
    "iosReleaseProvenanceVerified": product_path_proof.get("iosReleaseProvenanceVerified") is True,
    "iosGetTaskAllowDisabled": product_path_proof.get("iosGetTaskAllowDisabled") is True,
    "iosProfileNotExpired": product_path_proof.get("iosProfileNotExpired") is True,
    "iosProfileDeviceBound": product_path_proof.get("iosProfileDeviceBound") is True,
    "iosProfileTeamMatchesSignature": product_path_proof.get("iosProfileTeamMatchesSignature") is True,
    "iosSigningCertificateTrusted": product_path_proof.get("iosSigningCertificateTrusted") is True,
    "iosSigningCertificateInProfile": product_path_proof.get("iosSigningCertificateInProfile") is True,
    "iosSigningCertificateNotExpired": product_path_proof.get("iosSigningCertificateNotExpired") is True,
    "iosDistributionSigningVerified": product_path_proof.get("iosDistributionSigningVerified") is True,
    "iosKeychainGroupsMatchProfile": product_path_proof.get("iosKeychainGroupsMatchProfile") is True,
    "iosExpectedEntitlementsMatch": product_path_proof.get("iosExpectedEntitlementsMatch") is True,
    "iosNestedWidgetVerified": product_path_proof.get("iosNestedWidgetVerified") is True,
}
output = pathlib.Path(output_path)
serialized = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
descriptor, temporary_name = tempfile.mkstemp(prefix=".release-acceptance.pre-cleanup.", dir=output.parent)
temporary = pathlib.Path(temporary_name)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "wb", closefd=True) as handle:
        handle.write(serialized)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, output)
    temporary = None
    directory_descriptor = os.open(output.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)
finally:
    if temporary is not None and temporary.exists():
        temporary.unlink()
PY
}

finalize_release_acceptance_manifests_after_cleanup() {
  local private_manifest="$ARTIFACT_DIR/release-acceptance.json"
  local public_manifest="$PUBLIC_ARTIFACT_DIR/release-acceptance.json"

  python3 "$ROOT_DIR/Scripts/finalize_release_acceptance_manifests.py" \
    --private-manifest "$private_manifest" \
    --public-manifest "$public_manifest"
}

stamp_release_session_evidence() {
  local session_id="$1"
  local refs
  refs="$(python3 - "$session_id" <<'PY'
import hashlib
import sys

session_id = sys.argv[1]
release_ref = hashlib.sha256(b"skybridge-release-session-ref-v1\0" + session_id.encode("utf-8")).hexdigest()[:24]
app_ref = "ref:" + hashlib.sha256(session_id.encode("utf-8")).hexdigest()[:16]
print(release_ref, app_ref)
PY
)"
  read -r SESSION_REF APP_SESSION_REF <<<"$refs"
  if ! [[ "$SESSION_REF" =~ ^[0-9a-f]{24}$ && "$APP_SESSION_REF" =~ ^ref:[0-9a-f]{16}$ ]]; then
    echo "Unable to derive non-sensitive WebRTC session evidence references." >&2
    return 1
  fi
  if ! grep -Fq "remote-ice session_ref=${APP_SESSION_REF} kind=relay" "$IOS_TRACE_LOCAL" 2>/dev/null; then
    echo "WebRTC release evidence is missing a relay candidate bound to the active session." >&2
    return 1
  fi

  MEDIA_EVIDENCE_WINDOW_MILLIS="$(python3 - \
    "$session_id" \
    "$SESSION_REF" \
    "$APP_SESSION_REF" \
    "$MAC_STATUS" \
    "$IOS_STATUS_LOCAL" \
    "$IOS_MEDIA_LOCAL" \
    "$ARTIFACT_DIR/webrtc_media_doctor.json" \
    "$WEBRTC_GATE_OBSERVED_MILLIS" \
    "$SMOKE_SOAK_SECONDS" <<'PY'
import datetime as dt
import json
import os
import pathlib
import re
import sys
import tempfile

(
    session_id,
    session_ref,
    app_session_ref,
    mac_status_path,
    ios_status_path,
    media_path,
    doctor_path,
    gate_window_ms_raw,
    soak_seconds_raw,
) = sys.argv[1:]
gate_window_ms = int(gate_window_ms_raw)
soak_ms = int(soak_seconds_raw) * 1000

def fail(message):
    raise SystemExit(message)

def read_text(path):
    return pathlib.Path(path).read_text(encoding="utf-8", errors="strict")

escaped_session = re.escape(session_id)
mac_status = read_text(mac_status_path)
ios_status = read_text(ios_status_path)
if re.search(r"\bfailed\s+stage=", mac_status) or re.search(r"\bfailed\s+stage=", ios_status):
    fail("WebRTC status contains a failed stage")
if re.search(rf"\bsuccess\s+session={escaped_session}\b.*\bsuite=X-Wing\b.*\bstream=true\b", mac_status) is None:
    fail("Mac success is not bound to the active WebRTC session")
if re.search(rf"\brekey\s+session={escaped_session}\s+complete\s+suite=X-Wing\b", mac_status) is None:
    fail("Mac rekey is not bound to the active WebRTC session")
if re.search(rf"\bhandshake\s+session={escaped_session}\s+suite=(?:X25519(?:-Ed25519)?|X-Wing)\b", ios_status) is None:
    fail("iOS handshake is not bound to the active WebRTC session")
if re.search(rf"\brekey\s+session={escaped_session}\s+complete\s+suite=X-Wing\b", ios_status) is None:
    fail("iOS rekey is not bound to the active WebRTC session")
if gate_window_ms < soak_ms:
    fail("WebRTC media doctor did not observe the configured wall-clock pass window")

media_file = pathlib.Path(media_path)
rows = []
matching_timestamps = []
for line_number, raw_line in enumerate(media_file.read_text(encoding="utf-8", errors="strict").splitlines(), 1):
    if not raw_line.strip():
        continue
    try:
        row = json.loads(raw_line)
    except json.JSONDecodeError as exc:
        fail(f"invalid media JSONL at line {line_number}: {exc}")
    if not isinstance(row, dict):
        fail(f"invalid media JSONL object at line {line_number}")
    if row.get("session_ref") == app_session_ref:
        timestamp = row.get("timestamp")
        if not isinstance(timestamp, str):
            fail(f"session-bound media row lacks timestamp at line {line_number}")
        try:
            parsed = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        except ValueError as exc:
            fail(f"invalid media timestamp at line {line_number}: {exc}")
        matching_timestamps.append(parsed.timestamp())
        row["release_session_ref"] = session_ref
    rows.append(row)

if len(matching_timestamps) < 2:
    fail("fewer than two session-bound media diagnostics were observed")
media_window_ms = int(round((max(matching_timestamps) - min(matching_timestamps)) * 1000))
if media_window_ms < soak_ms:
    fail("session-bound media diagnostics do not span the required soak window")

with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=media_file.parent, delete=False) as handle:
    temporary_path = pathlib.Path(handle.name)
    for row in rows:
        handle.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
os.replace(temporary_path, media_file)

doctor_file = pathlib.Path(doctor_path)
doctor = json.loads(doctor_file.read_text(encoding="utf-8", errors="strict"))
if not isinstance(doctor, dict):
    fail("WebRTC media doctor report is not a JSON object")
doctor["sessionRef"] = session_ref
doctor["observedGateWindowMillis"] = gate_window_ms
doctor["mediaEvidenceWindowMillis"] = media_window_ms
doctor["gateSessionBound"] = True
with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=doctor_file.parent, delete=False) as handle:
    temporary_path = pathlib.Path(handle.name)
    json.dump(doctor, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(temporary_path, doctor_file)

with open(mac_status_path, "a", encoding="utf-8") as handle:
    handle.write(f"release-session-binding role=mac sessionRef={session_ref} handshake=1 rekey=1\n")
with open(ios_status_path, "a", encoding="utf-8") as handle:
    handle.write(f"release-session-binding role=ios sessionRef={session_ref} handshake=1 rekey=1\n")

print(media_window_ms)
PY
)"
  if ! [[ "$MEDIA_EVIDENCE_WINDOW_MILLIS" =~ ^[0-9]+$ ]]; then
    echo "Unable to measure the WebRTC session-bound media evidence window." >&2
    return 1
  fi
  printf 'release-session-binding role=relay-candidate sessionRef=%s candidate=relay\n' \
    "$SESSION_REF" >>"$IOS_TRACE_LOCAL"
}

prepare_auth_session() {
  if [[ -z "$AUTH_PRIVATE_DIR" || ! -d "$AUTH_PRIVATE_DIR" ]]; then
    echo "Private auth-session directory is not initialized." >&2
    return 1
  fi
  local output="$AUTH_PRIVATE_DIR/host.auth-session.json"
  python3 - \
    "$AUTH_SESSION_SOURCE_FILE" \
    "$output" \
    "$MAC_TOKEN" \
    "$MAC_TENANT" \
    "$MAC_AUTH_BINDING" <<'PY'
# SKYBRIDGE_AUTH_SESSION_PYTHON_BEGIN
import base64
import hashlib
import json
import math
import os
import pathlib
import re
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

source_path, output_path, token_output_path, tenant_output_path, binding_output_path = sys.argv[1:6]

ALLOWED_SIGNED_ALGORITHMS = frozenset({"ES256", "HS256", "RS256"})
MAX_AUTH_FILE_BYTES = 1_048_576
MAX_AUTH_RESPONSE_BYTES = 1_048_576
MIN_FINAL_TOKEN_LIFETIME_SECONDS = 300
BASE64URL_PATTERN = re.compile(r"^[A-Za-z0-9_-]+$")


class RedirectRejected(Exception):
    pass


class RejectAuthRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        del request, file_pointer, code, message, headers, new_url
        raise RedirectRejected("Supabase auth endpoints must not redirect")

def fail(message):
    raise SystemExit(message)

def decode_base64url(segment, label):
    if not isinstance(segment, str) or not BASE64URL_PATTERN.fullmatch(segment):
        fail(f"Auth token {label} is not canonical base64url")
    padded = segment + "=" * ((4 - len(segment) % 4) % 4)
    try:
        decoded = base64.b64decode(padded.encode("ascii"), altchars=b"-_", validate=True)
    except (ValueError, UnicodeError) as exc:
        fail(f"Auth token {label} is not valid base64url ({type(exc).__name__})")
    if not decoded:
        fail(f"Auth token {label} is empty")
    return decoded


def decode_json_segment(segment, label):
    try:
        value = json.loads(decode_base64url(segment, label).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"Auth token {label} is not valid UTF-8 JSON ({type(exc).__name__})")
    if not isinstance(value, dict):
        fail(f"Auth token {label} must be a JSON object")
    return value


def normalize_supabase_origin(raw_url):
    if not isinstance(raw_url, str) or not raw_url:
        fail("SUPABASE_URL is required for real-device WebRTC acceptance")
    if raw_url != raw_url.strip():
        fail("SUPABASE_URL must not contain surrounding whitespace")
    if "\\" in raw_url or any(ord(character) <= 0x20 or ord(character) == 0x7F for character in raw_url):
        fail("SUPABASE_URL contains forbidden control or backslash characters")
    try:
        parsed = urllib.parse.urlsplit(raw_url)
        port = parsed.port
    except ValueError as exc:
        fail(f"SUPABASE_URL is malformed ({type(exc).__name__})")
    if parsed.scheme != "https":
        fail("SUPABASE_URL must be an HTTPS origin")
    if parsed.username is not None or parsed.password is not None:
        fail("SUPABASE_URL must not contain userinfo")
    if parsed.query or parsed.fragment:
        fail("SUPABASE_URL must not contain query or fragment components")
    if parsed.path not in ("", "/"):
        fail("SUPABASE_URL must be an origin without a path")
    if port not in (None, 443):
        fail("SUPABASE_URL must use the standard HTTPS port")
    hostname = parsed.hostname
    if not hostname:
        fail("SUPABASE_URL is missing a hostname")
    if hostname.endswith("."):
        fail("SUPABASE_URL hostname must not have a trailing dot")
    try:
        canonical_hostname = hostname.encode("idna").decode("ascii").lower()
    except UnicodeError as exc:
        fail(f"SUPABASE_URL hostname is not valid IDNA ({type(exc).__name__})")
    if not canonical_hostname or any(character.isspace() for character in canonical_hostname):
        fail("SUPABASE_URL hostname is not canonical")
    rendered_hostname = f"[{canonical_hostname}]" if ":" in canonical_hostname else canonical_hostname
    return f"https://{rendered_hostname}"


def parse_audiences(raw_audience):
    if isinstance(raw_audience, str):
        values = [raw_audience]
    elif isinstance(raw_audience, list):
        values = raw_audience
    else:
        fail("Auth token JWT payload aud must be a string or array of strings")
    if not values or any(not isinstance(value, str) or not value.strip() for value in values):
        fail("Auth token JWT payload aud contains an empty or non-string value")
    return frozenset(value.strip() for value in values)


def validate_jwt(token, expected_issuer, minimum_remaining_seconds=None):
    if not isinstance(token, str):
        fail("Auth token must be a string")
    token = token.strip()
    if not token or len(token) > MAX_AUTH_FILE_BYTES:
        fail("Auth token is empty or exceeds the size limit")
    parts = token.split(".")
    if len(parts) != 3:
        fail(f"Auth token must have 3 JWT segments; found {len(parts)}")
    if any(not part for part in parts):
        fail("Auth token has an empty JWT segment")
    header = decode_json_segment(parts[0], "header")
    payload = decode_json_segment(parts[1], "payload")
    signature = decode_base64url(parts[2], "signature")
    alg = header.get("alg")
    if not isinstance(alg, str) or alg not in ALLOWED_SIGNED_ALGORITHMS:
        found = alg if isinstance(alg, str) and alg else "<missing>"
        fail(f"Auth token JWT header must declare a supported signed alg; found {found}")
    expected_signature_lengths = {"ES256": {64}, "HS256": {32}, "RS256": {256, 384, 512}}
    if len(signature) not in expected_signature_lengths[alg]:
        fail(f"Auth token JWT signature length is invalid for {alg}")
    exp = payload.get("exp")
    if isinstance(exp, bool) or not isinstance(exp, (int, float)) or not math.isfinite(float(exp)):
        fail("Auth token JWT payload is missing numeric exp")
    if float(exp) <= 0:
        fail("Auth token JWT payload exp must be a positive NumericDate")
    remaining = float(exp) - time.time()
    if minimum_remaining_seconds is not None and remaining <= minimum_remaining_seconds:
        fail(f"Auth token expires too soon for real-device WebRTC smoke ({int(remaining)}s remaining)")
    subject = payload.get("sub")
    if (
        not isinstance(subject, str)
        or not subject
        or subject != subject.strip()
        or len(subject.encode("utf-8")) > 256
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in subject)
    ):
        fail("Auth token JWT payload is missing non-empty sub")
    role = payload.get("role")
    if not isinstance(role, str):
        fail("Auth token JWT payload role must be authenticated; found <missing>")
    role = role.strip()
    if role != "authenticated":
        fail(f"Auth token JWT payload role must be authenticated; found {role or '<missing>'}")
    audiences = parse_audiences(payload.get("aud"))
    if "authenticated" not in audiences:
        found = ",".join(sorted(audiences)) if audiences else "<missing>"
        fail(f"Auth token JWT payload aud must include authenticated; found {found}")
    if audiences.intersection({"anon", "service_role"}):
        fail("Auth token appears to be an anon/service_role JWT, not a signed Supabase user JWT")
    issuer = payload.get("iss")
    if not isinstance(issuer, str) or issuer != expected_issuer:
        found = issuer if isinstance(issuer, str) and issuer else "<missing>"
        fail(f"Auth token issuer mismatch: iss={found} expected={expected_issuer}")
    return {
        "audiences": audiences,
        "expires_at": float(exp),
        "issuer": issuer,
        "payload": payload,
        "role": role,
        "subject": subject,
        "tenant": tenant_identifier(payload),
    }

def require_header_secret(value, label):
    if not isinstance(value, str) or not value:
        fail(f"{label} is required for real-device WebRTC acceptance")
    if value != value.strip() or len(value) > 16_384:
        fail(f"{label} is malformed")
    if any(ord(character) <= 0x20 or ord(character) == 0x7F for character in value):
        fail(f"{label} contains forbidden control characters")
    return value


AUTH_OPENER = urllib.request.build_opener(RejectAuthRedirects())


def read_auth_json(request, timeout, operation, http_error_prefix):
    try:
        with AUTH_OPENER.open(request, timeout=timeout) as response:
            status_code = response.status
            response_body = response.read(MAX_AUTH_RESPONSE_BYTES + 1)
    except RedirectRejected:
        fail(f"Supabase {operation} redirect is forbidden")
    except urllib.error.HTTPError as exc:
        fail(f"{http_error_prefix} (HTTP {exc.code})")
    except urllib.error.URLError as exc:
        fail(f"Unable to {operation} ({type(exc.reason).__name__})")
    except (OSError, TimeoutError) as exc:
        fail(f"Unable to {operation} ({type(exc).__name__})")
    if not 200 <= status_code < 300:
        fail(f"{http_error_prefix} (HTTP {status_code})")
    if len(response_body) > MAX_AUTH_RESPONSE_BYTES:
        fail(f"Supabase {operation} response exceeds the size limit")
    try:
        return json.loads(response_body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"Supabase {operation} returned invalid JSON ({type(exc).__name__})")


def verify_supabase_user(token, subject, supabase_origin, anon_key):
    request = urllib.request.Request(
        f"{supabase_origin}/auth/v1/user",
        headers={
            "Authorization": f"Bearer {token}",
            "apikey": anon_key,
            "Accept": "application/json",
        },
    )
    user = read_auth_json(
        request,
        timeout=15,
        operation="verify auth token with /auth/v1/user",
        http_error_prefix="Supabase /auth/v1/user rejected auth token",
    )
    if not isinstance(user, dict):
        fail("Supabase /auth/v1/user response is not a JSON object")
    user_id = user.get("id") or user.get("sub")
    if not isinstance(user_id, str) or not user_id.strip():
        fail("Supabase /auth/v1/user response is missing user id")
    if user_id.strip() != subject:
        fail("Supabase /auth/v1/user identity does not match the JWT subject")

def refresh_supabase_session(session, supabase_origin, expected_issuer, anon_key, original_identity):
    refresh_token = session.get("refreshToken") or session.get("refresh_token")
    if refresh_token is None or refresh_token == "":
        final_identity = validate_jwt(
            session.get("accessToken") or session.get("access_token") or session.get("access-token"),
            expected_issuer,
            minimum_remaining_seconds=MIN_FINAL_TOKEN_LIFETIME_SECONDS,
        )
        return session, final_identity
    if not isinstance(refresh_token, str) or refresh_token != refresh_token.strip() or len(refresh_token) > MAX_AUTH_FILE_BYTES:
        fail("Auth session refresh token is malformed")
    request = urllib.request.Request(
        f"{supabase_origin}/auth/v1/token?grant_type=refresh_token",
        data=json.dumps({"refresh_token": refresh_token}).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {anon_key}",
            "apikey": anon_key,
            "Accept": "application/json",
        },
        method="POST",
    )
    payload = read_auth_json(
        request,
        timeout=20,
        operation="refresh the real-device smoke auth session",
        http_error_prefix="Supabase rejected the real-device smoke auth-session refresh",
    )
    if not isinstance(payload, dict):
        fail("Supabase auth-session refresh response is not a JSON object")
    refreshed_access = payload.get("access_token")
    if not isinstance(refreshed_access, str) or not refreshed_access.strip():
        fail("Supabase auth-session refresh response is missing access_token")
    refreshed_access = refreshed_access.strip()
    refreshed_identity = validate_jwt(
        refreshed_access,
        expected_issuer,
        minimum_remaining_seconds=MIN_FINAL_TOKEN_LIFETIME_SECONDS,
    )
    for identity_field in ("subject", "issuer", "role", "audiences", "tenant"):
        if refreshed_identity[identity_field] != original_identity[identity_field]:
            fail(f"Supabase refreshed JWT changed bound identity claim: {identity_field}")
    session["accessToken"] = refreshed_access
    refreshed_refresh = payload.get("refresh_token")
    if refreshed_refresh is not None:
        if not isinstance(refreshed_refresh, str) or not refreshed_refresh.strip() or len(refreshed_refresh) > MAX_AUTH_FILE_BYTES:
            fail("Supabase auth-session refresh response contains a malformed refresh_token")
        session["refreshToken"] = refreshed_refresh.strip()
    return session, refreshed_identity


def read_private_session(path):
    source = pathlib.Path(path)
    try:
        metadata = source.lstat()
    except OSError as exc:
        fail(f"Unable to inspect auth session file ({type(exc).__name__})")
    if not stat.S_ISREG(metadata.st_mode) or source.is_symlink():
        fail("Auth session source must be a regular, non-symlink file")
    if metadata.st_uid != os.geteuid() or metadata.st_nlink != 1:
        fail("Auth session source must be owned by the current user with exactly one link")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        fail("Auth session source permissions must be exactly 0600")
    if metadata.st_size <= 0 or metadata.st_size > MAX_AUTH_FILE_BYTES:
        fail("Auth session source is empty or exceeds the size limit")
    open_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(source, open_flags)
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            opened_metadata = os.fstat(handle.fileno())
            if (opened_metadata.st_dev, opened_metadata.st_ino) != (metadata.st_dev, metadata.st_ino):
                fail("Auth session source changed while it was being opened")
            if (
                not stat.S_ISREG(opened_metadata.st_mode)
                or opened_metadata.st_uid != os.geteuid()
                or opened_metadata.st_nlink != 1
                or stat.S_IMODE(opened_metadata.st_mode) != 0o600
            ):
                fail("Opened auth session source violates the private-file boundary")
            session = json.load(handle)
    except SystemExit:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"Unable to read auth session file ({type(exc).__name__})")
    if not isinstance(session, dict):
        fail("Auth session source must contain a JSON object")
    return session


def write_private_session_atomically(session, output_path):
    output = pathlib.Path(output_path)
    parent = output.parent
    try:
        parent_metadata = parent.lstat()
    except OSError as exc:
        fail(f"Unable to inspect private auth-session directory ({type(exc).__name__})")
    if not stat.S_ISDIR(parent_metadata.st_mode) or parent.is_symlink() or stat.S_IMODE(parent_metadata.st_mode) != 0o700:
        fail("Private auth-session directory must be a non-symlink directory with mode 0700")
    temporary_path = None
    try:
        descriptor, raw_temporary_path = tempfile.mkstemp(prefix=".host.auth-session.", dir=parent)
        temporary_path = pathlib.Path(raw_temporary_path)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(session, handle, separators=(",", ":"), sort_keys=True, allow_nan=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, output)
        temporary_path = None
        os.chmod(output, 0o600, follow_symlinks=False)
        if stat.S_IMODE(output.stat().st_mode) != 0o600:
            fail("Private auth-session file permissions are not 0600")
        directory_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except SystemExit:
        raise
    except (OSError, TypeError, ValueError) as exc:
        fail(f"Unable to atomically write private auth session ({type(exc).__name__})")
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


def write_private_value_atomically(value, output_path, temporary_prefix):
    if (
        not isinstance(value, str)
        or not value
        or value != value.strip()
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)
    ):
        fail("Refusing to write a malformed private auth value")
    output = pathlib.Path(output_path)
    parent = output.parent
    metadata = parent.lstat()
    if parent.is_symlink() or not stat.S_ISDIR(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o700:
        fail("Private auth value directory must be a non-symlink directory with mode 0700")
    descriptor, temporary_name = tempfile.mkstemp(prefix=temporary_prefix, dir=parent)
    temporary_path = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(value.encode("utf-8"))
            handle.write(b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, output)
        temporary_path = None
        opened = output.lstat()
        if not stat.S_ISREG(opened.st_mode) or stat.S_IMODE(opened.st_mode) != 0o600:
            fail("Private auth value file permissions are not 0600")
        directory_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


def tenant_identifier(payload):
    app_metadata = payload.get("app_metadata")
    if app_metadata is not None and not isinstance(app_metadata, dict):
        fail("Auth token JWT payload app_metadata must be an object")
    app_metadata = app_metadata or {}

    candidates = (
        payload.get("tenant_id"),
        payload.get("tenantId"),
        payload.get("org_id"),
        payload.get("workspace_id"),
        app_metadata.get("tenant_id"),
        app_metadata.get("tenantId"),
        app_metadata.get("org_id"),
        app_metadata.get("workspace_id"),
    )
    normalized = set()
    for value in candidates:
        if value is None:
            continue
        if (
            not isinstance(value, str)
            or not value
            or value != value.strip()
            or len(value.encode("utf-8")) > 256
            or any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)
        ):
            fail("Auth token JWT payload contains a malformed tenant claim")
        normalized.add(value)
    if len(normalized) > 1:
        fail("Auth token JWT payload contains conflicting tenant claims")
    return next(iter(normalized), None)


supabase_origin = normalize_supabase_origin(os.environ.get("SUPABASE_URL") or "")
expected_issuer = f"{supabase_origin}/auth/v1"
anon_key = require_header_secret(os.environ.get("SUPABASE_ANON_KEY") or "", "SUPABASE_ANON_KEY")
session = None
if source_path:
    session = read_private_session(source_path)
else:
    token = os.environ.get("SKYBRIDGE_BEARER_TOKEN") or os.environ.get("SKYBRIDGE_ACCESS_TOKEN") or ""
    if isinstance(token, str):
        token = token.strip()
    if token:
        original_identity = validate_jwt(token, expected_issuer)
        payload = original_identity["payload"]
        refresh = os.environ.get("SKYBRIDGE_REFRESH_TOKEN") or ""
        if not isinstance(refresh, str):
            fail("SKYBRIDGE_REFRESH_TOKEN must be a string")
        environment_user = os.environ.get("SKYBRIDGE_USER_ID")
        if environment_user and environment_user.strip() != original_identity["subject"]:
            fail("SKYBRIDGE_USER_ID does not match the JWT subject")
        tenant = tenant_identifier(payload)
        environment_tenant = os.environ.get("SKYBRIDGE_NEBULA_ID") or os.environ.get("SKYBRIDGE_TENANT_ID")
        if environment_tenant:
            if environment_tenant != environment_tenant.strip():
                fail("Environment tenant identifier is malformed")
            if tenant is None:
                fail("Environment tenant identifier requires an explicit JWT tenant claim")
            if environment_tenant != tenant:
                fail("Environment tenant identifier does not match the JWT tenant claim")
        session = {
            "accessToken": token,
            "refreshToken": refresh,
            "userIdentifier": original_identity["subject"],
            "nebulaId": environment_tenant or (str(tenant) if tenant is not None else None),
            "displayName": os.environ.get("SKYBRIDGE_DISPLAY_NAME") or "Real Device WebRTC Smoke",
            "issuedAt": time.time(),
        }

if not session:
    fail(
        "Missing signed Supabase auth session. Provide SKYBRIDGE_SMOKE_AUTH_SESSION_FILE, "
        "SKYBRIDGE_AUTH_SESSION_FILE, SKYBRIDGE_ACCESS_TOKEN, or SKYBRIDGE_BEARER_TOKEN."
    )

token = (
    session.get("accessToken")
    or session.get("access_token")
    or session.get("access-token")
)
original_identity = validate_jwt(token, expected_issuer)
session, final_identity = refresh_supabase_session(
    session,
    supabase_origin,
    expected_issuer,
    anon_key,
    original_identity,
)
token = session["accessToken"]
verify_supabase_user(token, final_identity["subject"], supabase_origin, anon_key)
payload = final_identity["payload"]
session["accessToken"] = token
session_user = session.get("userIdentifier")
if session_user is not None and (not isinstance(session_user, str) or session_user.strip() != final_identity["subject"]):
    fail("Auth session userIdentifier does not match the JWT subject")
session["userIdentifier"] = final_identity["subject"]
tenant = final_identity["tenant"]
session_tenant = session.get("nebulaId")
if session_tenant is not None:
    if (
        not isinstance(session_tenant, str)
        or not session_tenant
        or session_tenant != session_tenant.strip()
        or len(session_tenant.encode("utf-8")) > 256
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in session_tenant)
    ):
        fail("Auth session nebulaId is malformed")
    if tenant is not None and session_tenant != tenant:
        fail("Auth session nebulaId does not match the final JWT tenant claim")

if tenant is None:
    # A legacy Nebula value is not a tenant authority when the verified JWT has no
    # server-controlled tenant claim. Keep the normalized session undeclared so the
    # runtime policy can use the verified JWT subject as its explicit fallback.
    session.pop("nebulaId", None)
else:
    session["nebulaId"] = tenant
session.setdefault("displayName", "Real Device WebRTC Smoke")
session.setdefault("issuedAt", time.time())

write_private_session_atomically(session, output_path)
effective_tenant = tenant or final_identity["subject"]
binding_material = (
    b"skybridge-webrtc-auth-binding-v1\0"
    + final_identity["subject"].encode("utf-8")
    + b"\0"
    + effective_tenant.encode("utf-8")
)
write_private_value_atomically(token, token_output_path, ".bootstrap-access-token.")
write_private_value_atomically(effective_tenant, tenant_output_path, ".bootstrap-tenant.")
write_private_value_atomically(
    hashlib.sha256(binding_material).hexdigest(),
    binding_output_path,
    ".auth-binding.",
)
print(output_path)
# SKYBRIDGE_AUTH_SESSION_PYTHON_END
PY
}

load_pqc_report() {
  local report_path="$1"
  MAC_PQC_DEVICE_ID="$(python3 - "$report_path" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], "r", encoding="utf-8"))
keys = {
    int(entry.get("suiteWireId", -1)): entry.get("publicKeyBase64", "")
    for entry in report.get("keys", [])
}
device_id = report.get("deviceId", "")
if not isinstance(device_id, str) or not device_id.strip() or not keys.get(0x0001):
    raise SystemExit("PQC report is missing required deviceId/X-Wing key")
print(device_id)
PY
)"
  if [[ -z "$MAC_PQC_DEVICE_ID" ]]; then
    echo "PQC report is missing required deviceId/X-Wing key: ${report_path}" >&2
    return 1
  fi
}

wait_for_file_nonempty() {
  local path="$1"
  local timeout_seconds="$2"
  local label="$3"
  local started_at
  started_at="$(date +%s)"
  while true; do
    if [[ -s "$path" ]]; then
      return 0
    fi
    if [[ -f "$MAC_STATUS" ]] && grep -q 'failed stage=' "$MAC_STATUS"; then
      echo "macOS smoke failed while waiting for ${label}: $(tail -n 1 "$MAC_STATUS")" >&2
      return 1
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${path}" >&2
      return 1
    fi
    sleep 1
  done
}

wait_for_file_pattern() {
  local path="$1"
  local pattern="$2"
  local timeout_seconds="$3"
  local label="$4"
  local started_at
  started_at="$(date +%s)"
  while true; do
    if [[ "$IOS_CONSOLE_HANDLE_STARTED" == "1" ]] \
      && ! ios_console_handle_is_exact_and_running; then
      echo "Exact iOS WebRTC console launch handle exited or became unverifiable before ${label}." >&2
      return 1
    fi
    if [[ -f "$path" ]] && grep -qE "$pattern" "$path"; then
      return 0
    fi
    if [[ -f "$path" ]] && grep -q 'failed stage=' "$path"; then
      echo "Smoke failed while waiting for ${label}: $(tail -n 1 "$path")" >&2
      return 1
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${path}" >&2
      return 1
    fi
    sleep 1
  done
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
  local status="$?"
  set -e
  return "$status"
}

copy_ios_file() {
  local remote="$1"
  local local_path="$2"
  local tmp_path="${local_path}.tmp.${BASHPID:-$$}"
  rm -f "$tmp_path"
  if run_with_hard_timeout "$IOS_COPY_HARD_TIMEOUT_SECONDS" \
    xcrun devicectl --timeout "$IOS_COPY_TIMEOUT_SECONDS" device copy from \
    --device "$IOS_DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$IOS_BUNDLE_ID" \
    --source "Library/Caches/$remote" \
    --destination "$tmp_path" >/dev/null 2>&1; then
    if [[ -s "$tmp_path" || ! -s "$local_path" ]]; then
      mv -f "$tmp_path" "$local_path"
    else
      rm -f "$tmp_path"
    fi
  else
    rm -f "$tmp_path"
    [[ -f "$local_path" ]] || : > "$local_path"
  fi
}

copy_mac_media_diagnostics() {
  local media_log_dir="$HOME/Library/Logs/SkyBridge"
  local session_id="${SESSION_ID:-}"
  if [[ -d "$media_log_dir" && -n "$session_id" ]]; then
    local session_log="$media_log_dir/webrtc-media-${session_id}.jsonl"
    if [[ -f "$session_log" ]]; then
      local target="$ARTIFACT_DIR/webrtc-media-${session_id}.jsonl"
      local tmp="$ARTIFACT_DIR/.webrtc-media-${session_id}.jsonl.tmp"
      if cp "$session_log" "$tmp" 2>/dev/null; then
        mv "$tmp" "$target" 2>/dev/null || true
      else
        rm -f "$tmp" 2>/dev/null || true
      fi
    fi
  fi
}

copy_round_diagnostics() {
  copy_mac_media_diagnostics
  copy_ios_file "$IOS_STATUS_NAME" "$IOS_STATUS_LOCAL"
  copy_ios_file "$IOS_STATUS_NAME.webrtc-media.jsonl" "$IOS_MEDIA_LOCAL"
  copy_ios_file "$IOS_STATUS_NAME.trace.log" "$IOS_TRACE_LOCAL"
}

wait_for_ios_pattern() {
  local local_path="$1"
  local remote="$2"
  local pattern="$3"
  local timeout_seconds="$4"
  local label="$5"
  local failure_pattern='failed stage=|fallback-frame|transport=fallback-screen|strict-media-failed|screen-drop .*fallback|screenFallbackDrop|stream-native-warmup-fallback-main|fallbackProducerSwitch|uiSurface=smokeOverlay|nativePromotionState=smoke-hold'
  local started_at
  started_at="$(date +%s)"
  while true; do
    copy_ios_file "$remote" "$local_path"
    if [[ "$IOS_CONSOLE_HANDLE_STARTED" == "1" ]] \
      && ! ios_console_handle_is_exact_and_running; then
      echo "Exact iOS WebRTC console launch handle exited or became unverifiable before ${label}." >&2
      return 1
    fi
    if [[ -f "$local_path" ]] && grep -qE "$failure_pattern" "$local_path"; then
      echo "iOS smoke failed while waiting for ${label}: $(tail -n 1 "$local_path")" >&2
      return 1
    fi
    if [[ -f "$MAC_STATUS" ]] && grep -qE "$failure_pattern|failed stage=" "$MAC_STATUS"; then
      echo "macOS smoke failed while waiting for ${label}: $(tail -n 1 "$MAC_STATUS")" >&2
      return 1
    fi
    if [[ -f "$local_path" ]] && grep -qE "$pattern" "$local_path"; then
      return 0
    fi
    if (( "$(date +%s)" - started_at >= timeout_seconds )); then
      echo "Timed out waiting for ${label}: ${local_path}" >&2
      return 1
    fi
    sleep 2
  done
}

run_webrtc_media_doctor() {
  local session_id="$1"
  local output="$ARTIFACT_DIR/webrtc_media_doctor.json"
  local last_error="$ARTIFACT_DIR/webrtc_media_doctor.stderr.log"
  local copier_pid=""
  local started_monotonic_ns
  local completed_monotonic_ns
  started_monotonic_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
  copy_round_diagnostics
  (
    while true; do
      copy_round_diagnostics || true
      sleep 2
    done
  ) &
  copier_pid="$!"

  set +e
  cargo run --quiet --manifest-path "$ROOT_DIR/rust/Cargo.toml" -p skybridge -- \
    smoke webrtc gate \
    --session-id "$session_id" \
    --artifact-dir "$ARTIFACT_DIR" \
    --since-seconds "$SMOKE_TIMEOUT_SECONDS" \
    --timeout-seconds "$SMOKE_TIMEOUT_SECONDS" \
    --min-pass-seconds "$SMOKE_SOAK_SECONDS" \
    --poll-interval-seconds 2 \
    --min-fps "$SMOKE_MIN_FPS" \
    --min-width "$SMOKE_VIDEO_WIDTH" \
    --min-height "$SMOKE_VIDEO_HEIGHT" \
    --exact-video-size \
    --require-audio "$([[ "$SMOKE_REQUIRE_AUDIO" == "1" ]] && echo true || echo false)" \
    --json > "$output" 2>"$last_error"
  local status="$?"
  set -e
  completed_monotonic_ns="$(python3 -c 'import time; print(time.monotonic_ns())')"
  WEBRTC_GATE_OBSERVED_MILLIS=$(( (completed_monotonic_ns - started_monotonic_ns) / 1000000 ))

  kill "$copier_pid" >/dev/null 2>&1 || true
  wait "$copier_pid" >/dev/null 2>&1 || true

  if [[ "$status" == "0" ]] && (( WEBRTC_GATE_OBSERVED_MILLIS >= SMOKE_SOAK_SECONDS * 1000 )); then
    return 0
  fi

  if [[ "$status" == "0" ]]; then
    echo "WebRTC media gate returned before the required observed pass window: observedMs=${WEBRTC_GATE_OBSERVED_MILLIS} requiredMs=$((SMOKE_SOAK_SECONDS * 1000))" >&2
    return 1
  fi

  echo "WebRTC media smoke gate failed (session=${session_id}, min_fps=${SMOKE_MIN_FPS}, require_audio=${SMOKE_REQUIRE_AUDIO})" >&2
  cat "$last_error" >&2 || true
  return "$status"
}

preflight_media_relay_udp() {
  if [[ "$SKIP_MEDIA_RELAY_PREFLIGHT" == "1" || "$SMOKE_REQUIRE_AUDIO" != "1" || "$SMOKE_FORCE_RELAY_ICE" != "1" ]]; then
    return 0
  fi

  local log="$ARTIFACT_DIR/media-relay-preflight.log"
  echo "==> Preflighting media relay UDP: ${MEDIA_RELAY_PREFLIGHT_HOST}:${MEDIA_RELAY_PREFLIGHT_PORT}"
  if python3 - "$MEDIA_RELAY_PREFLIGHT_HOST" "$MEDIA_RELAY_PREFLIGHT_PORT" "$MEDIA_RELAY_PREFLIGHT_TIMEOUT_SECONDS" "$log" <<'PY'
import ipaddress
import json
import re
import socket
import subprocess
import sys
import time

host, port_raw, timeout_raw, log_path = sys.argv[1:5]
port = int(port_raw)
timeout = float(timeout_raw)

def log(line):
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")

def parse_route_destination(value):
    if value == "default":
        return ipaddress.ip_network("0.0.0.0/0")
    match = re.fullmatch(r"(\d+(?:\.\d+){0,3})(?:/(\d+))?", value)
    if not match:
        return None
    parts = [int(part) for part in match.group(1).split(".")]
    if any(part < 0 or part > 255 for part in parts):
        return None
    prefix = int(match.group(2)) if match.group(2) is not None else len(parts) * 8
    while len(parts) < 4:
        parts.append(0)
    try:
        return ipaddress.ip_network((".".join(str(part) for part in parts), prefix), strict=False)
    except ValueError:
        return None

target_ip = ipaddress.ip_address(socket.gethostbyname(host))
log(f"target={host}:{port} resolved={target_ip}")

try:
    routes = subprocess.check_output(["netstat", "-rn", "-f", "inet"], text=True, stderr=subprocess.STDOUT)
except Exception as exc:
    log(f"route_probe_error={exc}")
else:
    best = None
    for line in routes.splitlines():
        columns = line.split()
        if len(columns) < 4:
            continue
        network = parse_route_destination(columns[0])
        if network is None or target_ip not in network:
            continue
        if best is None or network.prefixlen > best[0].prefixlen:
            best = (network, columns[0], columns[3])
    if best is not None:
        network, label, netif = best
        log(f"route_match={label} network={network} netif={netif}")
        if netif.startswith("utun"):
            log("route_warning=media relay target currently matches a utun/TUN route; UDP relay may be intercepted by VPN/proxy")

payload = json.dumps({"type": "bind", "leaseToken": "invalid-preflight-token"}).encode("utf-8")
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(timeout)
try:
    started = time.time()
    sock.sendto(payload, (host, port))
    data, addr = sock.recvfrom(2048)
    elapsed_ms = int(round((time.time() - started) * 1000))
    body = data.decode("utf-8", "replace")
    log(f"udp_bind_probe=ok from={addr[0]}:{addr[1]} bytes={len(data)} rttMs={elapsed_ms} bodyPrefix={body[:120]}")
except Exception as exc:
    log(f"udp_bind_probe=failed error={type(exc).__name__}:{exc}")
    raise SystemExit(78)
finally:
    sock.close()
PY
  then
    return 0
  fi

  echo "Media relay UDP preflight failed: ${MEDIA_RELAY_PREFLIGHT_HOST}:${MEDIA_RELAY_PREFLIGHT_PORT}" >&2
  echo "    log: $log" >&2
  echo "    For acceptance, disable TUN/VPN/proxy interception or route this UDP endpoint DIRECT, then rerun." >&2
  tail -n 12 "$log" >&2 || true
  return 1
}

verify_macos_product_host() {
  [[ "$MAC_HOST_MODE" == "product" ]] || return 0
  local info_plist="$MAC_PRODUCT_APP_BUNDLE/Contents/Info.plist"
  local executable_name
  local executable_path
  local entitlements_path="$AUTH_PRIVATE_DIR/mac-product.entitlements.plist"

  if [[ ! -d "$MAC_PRODUCT_APP_BUNDLE" || ! -f "$info_plist" ]]; then
    echo "Physical WebRTC acceptance requires a packaged macOS product app: $MAC_PRODUCT_APP_BUNDLE" >&2
    return 1
  fi
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null || true)"
  executable_path="$MAC_PRODUCT_APP_BUNDLE/Contents/MacOS/$executable_name"
  if [[ -z "$executable_name" || ! -x "$executable_path" ]]; then
    echo "Packaged macOS WebRTC product executable is missing." >&2
    return 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)" != "$MAC_PRODUCT_BUNDLE_ID" ]]; then
    echo "Packaged macOS WebRTC product bundle identifier is not the release product identifier." >&2
    return 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingBuildConfiguration' "$info_plist" 2>/dev/null || true)" != "Release" \
        || "$(/usr/libexec/PlistBuddy -c 'Print :SkyBridgePackagingGitDirtyState' "$info_plist" 2>/dev/null || true)" != "clean" ]]; then
    echo "Packaged macOS WebRTC product must be a clean-provenance Release build." >&2
    return 1
  fi
  if ! /usr/bin/strings "$executable_path" | /usr/bin/grep -Fqx "$PRODUCT_ACCEPTANCE_MARKER"; then
    echo "Packaged macOS WebRTC product predates the system-Keychain/human-approval acceptance path; rebuild and notarize current source." >&2
    return 1
  fi
  if [[ ! -f "$MAC_PRODUCT_APP_BUNDLE/Contents/embedded.provisionprofile" ]]; then
    echo "Packaged macOS WebRTC product is missing its embedded product provisioning profile." >&2
    return 1
  fi
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$MAC_PRODUCT_APP_BUNDLE" >/dev/null
  /usr/bin/xcrun stapler validate "$MAC_PRODUCT_APP_BUNDLE" >/dev/null
  /usr/sbin/spctl --assess --type execute "$MAC_PRODUCT_APP_BUNDLE" >/dev/null
  /usr/bin/codesign -d --entitlements :- "$MAC_PRODUCT_APP_BUNDLE" >"$entitlements_path" 2>/dev/null
  python3 - "$entitlements_path" "$MAC_PRODUCT_BUNDLE_ID" <<'PY'
import plistlib
import sys
from pathlib import Path

with Path(sys.argv[1]).open("rb") as handle:
    entitlements = plistlib.load(handle)
bundle_id = sys.argv[2]
application_id = entitlements.get("com.apple.application-identifier")
groups = entitlements.get("keychain-access-groups")
if not isinstance(application_id, str) or not application_id.endswith("." + bundle_id):
    raise SystemExit("macOS product application identifier entitlement mismatch")
if not isinstance(groups, list) or len(groups) != len(set(groups)):
    raise SystemExit("macOS product Keychain access groups are missing or duplicated")
required_suffixes = ("." + bundle_id, ".group.com.skybridge.compass")
if any(sum(isinstance(group, str) and group.endswith(suffix) for group in groups) != 1 for suffix in required_suffixes):
    raise SystemExit("macOS product does not contain the exact required product/shared Keychain groups")
PY
  MAC_APP_BIN="$executable_path"
}

prepare_ios_build_provenance() {
  IOS_SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify HEAD 2>/dev/null || true)"
  if ! [[ "$IOS_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Unable to resolve the iOS acceptance source commit." >&2
    return 1
  fi

  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
    IOS_SOURCE_DIRTY_STATE="dirty"
    IOS_SOURCE_CLEAN=0
  else
    IOS_SOURCE_DIRTY_STATE="clean"
    IOS_SOURCE_CLEAN=1
  fi

  if [[ "$LAB_RUN" == "1" ]]; then
    IOS_BUILD_CONFIGURATION="${SKYBRIDGE_IOS_BUILD_CONFIGURATION:-Debug}"
    case "$IOS_BUILD_CONFIGURATION" in
      Debug|Release) ;;
      *)
        echo "Lab iOS build configuration must be Debug or Release." >&2
        return 1
        ;;
    esac
    if [[ "$IOS_BUILD_CONFIGURATION" == "Release" ]]; then
      IOS_EXPECTED_ENTITLEMENTS="$IOS_RELEASE_ENTITLEMENTS"
    else
      IOS_EXPECTED_ENTITLEMENTS="$IOS_DEBUG_ENTITLEMENTS"
    fi
    return 0
  fi

  IOS_BUILD_CONFIGURATION="${SKYBRIDGE_IOS_BUILD_CONFIGURATION:-Release}"
  if [[ "$IOS_BUILD_CONFIGURATION" != "Release" ]]; then
    echo "Physical WebRTC acceptance requires an iOS Release build; Debug is diagnostic-only." >&2
    return 1
  fi
  if [[ "$IOS_SOURCE_DIRTY_STATE" != "clean" ]]; then
    echo "Physical WebRTC acceptance requires clean iOS source provenance." >&2
    return 1
  fi
  IOS_EXPECTED_ENTITLEMENTS="$IOS_RELEASE_ENTITLEMENTS"
}

resolve_ios_distribution_signing_inputs() {
  if [[ "$IOS_BUILD_CONFIGURATION" != "Release" ]]; then
    return 0
  fi
  IOS_DISTRIBUTION_PREFLIGHT="$AUTH_PRIVATE_DIR/ios-distribution-signing-preflight.json"
  python3 "$ROOT_DIR/Scripts/resolve_ios_distribution_signing.py" \
    "$IOS_DISTRIBUTION_PREFLIGHT" \
    "$IOS_APP_DISTRIBUTION_PROFILE_INPUT" \
    "$IOS_WIDGET_DISTRIBUTION_PROFILE_INPUT" \
    "$IOS_TEAM_IDENTIFIER" \
    "$IOS_BUNDLE_ID" \
    "$IOS_WIDGET_BUNDLE_ID" \
    "$IOS_DEVICE_ID" \
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
    echo "Resolved iOS distribution signing inputs violate the strict WebRTC preflight contract." >&2
    return 1
  fi
  if ! skybridge_profile_supports_requested_profile_backed_entitlements \
    "$IOS_APP_DISTRIBUTION_PROFILE" \
    "$IOS_RELEASE_ENTITLEMENTS"; then
    echo "The installed iOS app distribution profile does not cover Release entitlements." >&2
    return 1
  fi
}

verify_ios_product_app() {
  if (( $# != 1 )); then
    echo "verify_ios_product_app requires one app bundle path" >&2
    return 2
  fi
  local app_bundle="$1"
  local widget_bundle="$app_bundle/PlugIns/SkyBridgeCompass-Widgets.appex"
  local app_profile="$app_bundle/embedded.mobileprovision"
  local widget_profile="$widget_bundle/embedded.mobileprovision"
  local verification_path="$ARTIFACT_DIR/ios-product-verification.json"

  if [[ ! -d "$app_bundle" || -L "$app_bundle" || \
        ! -d "$widget_bundle" || -L "$widget_bundle" || \
        ! -f "$app_profile" || -L "$app_profile" || \
        ! -f "$widget_profile" || -L "$widget_profile" ]]; then
    echo "Built iOS App/Widget product or embedded profiles are missing or symlinked." >&2
    return 1
  fi
  skybridge_write_ios_distribution_product_proof \
    "$app_bundle" \
    "$widget_bundle" \
    "$app_profile" \
    "$widget_profile" \
    "$IOS_EXPECTED_ENTITLEMENTS" \
    "$verification_path" \
    "$AUTH_PRIVATE_DIR" \
    "$IOS_BUNDLE_ID" \
    "$IOS_WIDGET_BUNDLE_ID" \
    "$IOS_TEAM_IDENTIFIER" \
    "$IOS_BUILD_CONFIGURATION" \
    "$LAB_RUN" \
    "$IOS_SOURCE_COMMIT" \
    "$IOS_SOURCE_CLEAN" \
    "$IOS_DEVICE_ID" \
    "$IOS_APP_DISTRIBUTION_PROFILE" \
    "$IOS_WIDGET_DISTRIBUTION_PROFILE" \
    "$ROOT_DIR/Scripts/verify_ios_distribution_product.py"
}
write_product_path_proof() {
  python3 - \
    "$ARTIFACT_DIR/product-path-proof.json" \
    "$ARTIFACT_DIR/ios-product-verification.json" \
    "$KEYCHAIN_MODE" \
    "$MAC_HOST_MODE" \
    "$IOS_SOURCE_COMMIT" \
    "$IOS_SOURCE_DIRTY_STATE" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import tempfile

path, ios_verification_path, keychain_mode, mac_host_mode, source_commit, source_dirty_state = sys.argv[1:]
ios_verification = json.loads(pathlib.Path(ios_verification_path).read_text(encoding="utf-8"))
if not isinstance(ios_verification, dict) or ios_verification.get("schemaVersion") != 1:
    raise SystemExit("iOS product verification evidence is malformed")
if ios_verification.get("sourceRevisionRef") != hashlib.sha256(source_commit.encode("ascii")).hexdigest()[:24]:
    raise SystemExit("iOS product verification is not bound to the current source revision")
payload = {
    "schemaVersion": 1,
    "keychainMode": keychain_mode,
    "macProductBundle": mac_host_mode == "product",
    "macProductSignatureVerified": mac_host_mode == "product",
    "macProductProfileVerified": mac_host_mode == "product",
    "iosProductBundle": ios_verification.get("productBundle") is True,
    "iosProductSignatureVerified": ios_verification.get("signatureVerified") is True,
    "iosProductProfileVerified": ios_verification.get("profileVerified") is True,
    "iosProfileNotExpired": ios_verification.get("profileNotExpired") is True,
    "iosProfileDeviceBound": ios_verification.get("profileDeviceBound") is True,
    "iosProfileTeamMatchesSignature": ios_verification.get("teamMatch") is True,
    "iosSigningCertificateTrusted": ios_verification.get("certificateTrusted") is True,
    "iosSigningCertificateInProfile": ios_verification.get("certificateMatch") is True,
    "iosSigningCertificateNotExpired": ios_verification.get("certificateNotExpired") is True,
    "iosDistributionSigningVerified": ios_verification.get("distributionSigning") is True,
    "iosKeychainGroupsMatchProfile": ios_verification.get("keychainGroupsVerified") is True,
    "iosExpectedEntitlementsMatch": ios_verification.get("expectedEntitlementsMatch") is True,
    "iosNestedWidgetVerified": ios_verification.get("nestedWidgetVerified") is True,
    "iosGetTaskAllowDisabled": ios_verification.get("getTaskAllow") is False,
    "iosReleaseProvenanceVerified": ios_verification.get("releaseProvenanceVerified") is True,
    "iosBuildConfiguration": ios_verification.get("configuration"),
    "iosSourceDirtyState": source_dirty_state,
    "sourceRepository": ios_verification.get("sourceRepository"),
    "sourceCommit": ios_verification.get("sourceCommit"),
    "iosSourceCommit": source_commit,
    "iosProductSurface": ios_verification.get("productSurface"),
    "iosSwiftActiveCompilationConditions": ios_verification.get("swiftActiveCompilationConditions"),
    "iosTestingCompilationCondition": ios_verification.get("testingCompilationCondition") is True,
    "iosBinaryTestSurfaceDetected": ios_verification.get("binaryTestSurfaceDetected") is True,
    "iosProductionProduct": ios_verification.get("productionProduct") is True,
}
output = pathlib.Path(path)
serialized = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
temporary = pathlib.Path(temporary_name)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "wb", closefd=True) as handle:
        handle.write(serialized)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, output)
finally:
    if temporary.exists():
        temporary.unlink()
PY
}

require_command python3
require_command xcrun
require_command swift
require_command xcodebuild
require_command cargo
validate_acceptance_profile
validate_remote_signaling_urls
initialize_private_auth_session_dir
initialize_process_ownership_session
MAC_CODE="$ARTIFACT_DIR/mac.code"
MAC_TOKEN="$AUTH_PRIVATE_DIR/mac.token"
MAC_TENANT="$AUTH_PRIVATE_DIR/mac.tenant"
MAC_AUTH_BINDING="$AUTH_PRIVATE_DIR/mac.auth-binding.sha256"
precreate_product_output_files
verify_macos_product_host
AUTH_SESSION_FILE="$(prepare_auth_session)"
IFS= read -r AUTH_BINDING_DIGEST <"$MAC_AUTH_BINDING"
if ! [[ "$AUTH_BINDING_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Verified WebRTC authentication binding digest is malformed." >&2
  exit 1
fi
preflight_media_relay_udp
if [[ -z "$IOS_DEVICE_ID" ]]; then
  IOS_DEVICE_ID="$(pick_real_device_id)"
fi
IOS_DEVICE_LABEL="$(skybridge_smoke_hash_label "$IOS_DEVICE_ID")"
if [[ "$PRESERVE_INSTALL" != "1" && -z "${SKYBRIDGE_REAL_DEVICE_ID:-}" ]]; then
  echo "SKYBRIDGE_SMOKE_PRESERVE_INSTALL=0 requires explicit SKYBRIDGE_REAL_DEVICE_ID to avoid uninstalling from the wrong device." >&2
  exit 1
fi

echo "==> Artifacts: $ARTIFACT_DIR"
echo "==> Real device: $IOS_DEVICE_ID"
echo "==> Run ID: $RUN_ID"
echo "==> Signaling HTTP: $SIGNALING_SERVER_URL"
echo "==> Signaling WS: $SIGNALING_WS_URL"
echo "==> Extreme media: $SMOKE_EXTREME_MEDIA syntheticScreen=$SMOKE_SYNTHETIC_SCREEN forceRelayIce=$SMOKE_FORCE_RELAY_ICE minFps=$SMOKE_MIN_FPS targetFps=$SMOKE_TARGET_FPS requireAudio=$SMOKE_REQUIRE_AUDIO hostHold=$SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS"
echo "==> Strict video target: ${SMOKE_VIDEO_WIDTH}x${SMOKE_VIDEO_HEIGHT}"

echo "==> Inspecting connected device"
xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" list devices --json-output "$IOS_DEVICE_INFO_JSON" >/dev/null

echo "==> Checking Apple PQC SDK gate for macOS WebRTC host"
skybridge_configure_optional_apple_pqc_sdk_compile_gate macosx
if [[ "${SKYBRIDGE_ENABLE_APPLE_PQC_SDK:-0}" != "1" ]]; then
  echo "Apple PQC SDK symbol probe failed for the macOS WebRTC host; refusing to build an X-Wing smoke host without HAS_APPLE_PQC_SDK." >&2
  echo "probeMode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown} sdk=${SKYBRIDGE_PQC_SDK_VER:-unknown} target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown} error=$(skybridge_sanitize_pqc_probe_log_value "${SKYBRIDGE_PQC_PROBE_ERROR:-}")" >&2
  exit 1
fi
echo "==> macOS Apple PQC SDK gate passed: mode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown} sdk=${SKYBRIDGE_PQC_SDK_VER:-unknown} target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown}"

if [[ "$MAC_HOST_MODE" == "diagnostic-cli" ]]; then
  echo "==> Building diagnostic macOS WebRTC smoke host"
  SMOKE_BUILD_DIR="${SKYBRIDGE_SMOKE_BUILD_DIR:-$ROOT_DIR/.build/real-device-webrtc-smoke}"
  if [[ "$SMOKE_BUILD_DIR" != /* ]]; then
    SMOKE_BUILD_DIR="$ROOT_DIR/$SMOKE_BUILD_DIR"
  fi
  (
    cd "$ROOT_DIR"
    swift build \
      --disable-dependency-cache \
      --manifest-cache local \
      --scratch-path "$SMOKE_BUILD_DIR" \
      -Xswiftc -warnings-as-errors \
      --product LocalWebRTCSmokeHost
  ) >"$MAC_BUILD_LOG" 2>&1

  MAC_APP_BIN="$SMOKE_BUILD_DIR/debug/LocalWebRTCSmokeHost"
  if [[ ! -x "$MAC_APP_BIN" ]]; then
    echo "macOS diagnostic smoke host executable not found: $MAC_APP_BIN" >&2
    exit 1
  fi
else
  echo "==> Using verified packaged macOS product WebRTC host"
  printf 'product-host verified bundle=release signature=developer-id notarized=1 profile=1 keychain=system\n' >"$MAC_BUILD_LOG"
fi

prepare_ios_build_provenance
resolve_ios_distribution_signing_inputs
echo "==> Building iOS app for real device ($IOS_BUILD_CONFIGURATION)"
IOS_BUILD_DESTINATION="${SKYBRIDGE_IOS_BUILD_DESTINATION:-generic/platform=iOS}"
echo "    build destination: $IOS_BUILD_DESTINATION"
skybridge_configure_optional_apple_pqc_sdk_compile_gate iphoneos
if [[ "${SKYBRIDGE_ENABLE_APPLE_PQC_SDK:-0}" != "1" ]] || ! skybridge_apple_pqc_sdk_probe_succeeded; then
  echo "Apple PQC SDK symbol probe failed for the iOS WebRTC app; refusing to build an X-Wing smoke target without HAS_APPLE_PQC_SDK." >&2
  echo "probeMode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown} sdk=${SKYBRIDGE_PQC_SDK_VER:-unknown} target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown} error=$(skybridge_sanitize_pqc_probe_log_value "${SKYBRIDGE_PQC_PROBE_ERROR:-}")" >&2
  exit 1
fi
echo "==> iOS Apple PQC SDK gate passed: mode=${SKYBRIDGE_PQC_PROBE_MODE:-unknown} sdk=${SKYBRIDGE_PQC_SDK_VER:-unknown} target=${SKYBRIDGE_PQC_SWIFT_TARGET:-unknown}"
IOS_XCODEBUILD_SETTINGS=(
  "SKYBRIDGE_PACKAGING_BUILD_CONFIGURATION=$IOS_BUILD_CONFIGURATION"
  "SKYBRIDGE_PACKAGING_GIT_DIRTY_STATE=$IOS_SOURCE_DIRTY_STATE"
  "SKYBRIDGE_PACKAGING_GIT_COMMIT=$IOS_SOURCE_COMMIT"
  "SKYBRIDGE_PACKAGING_SOURCE_REPOSITORY=${GITHUB_REPOSITORY:-${SKYBRIDGE_SOURCE_REPOSITORY:-billlza/Skybridge-Compass}}"
  "SKYBRIDGE_PACKAGING_PRODUCT_SURFACE=testing"
  "SKYBRIDGE_PACKAGING_SWIFT_ACTIVE_COMPILATION_CONDITIONS=HAS_APPLE_PQC_SDK,SKYBRIDGE_TESTING"
  SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK
  "OTHER_SWIFT_FLAGS=\$(inherited) -D SKYBRIDGE_TESTING"
)
if [[ "$IOS_BUILD_CONFIGURATION" == "Release" ]]; then
  echo "==> Archiving iOS WebRTC testing product with installed-only Automatic signing"
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
  echo "==> Exporting the distribution-signed iOS WebRTC testing product"
  skybridge_export_ios_distribution_archive \
    "$IOS_ARCHIVE_PATH" \
    "$IOS_EXPORT_OPTIONS" \
    "$IOS_EXPORT_DIR" \
    "$IOS_EXPORT_LOG" \
    "$IOS_TEAM_IDENTIFIER" \
    installed-only
  IOS_APP_PATH="$(
    skybridge_extract_single_ios_exported_app \
      "$IOS_IPA_EXTRACTOR" \
      "$IOS_EXPORT_DIR" \
      "$IOS_EXPORTED_APP"
  )"
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
    skybridge_run_xcodebuild "${IOS_XCODEBUILD_ARGS[@]}" >"$IOS_BUILD_LOG" 2>&1
  IOS_APP_PATH="$ARTIFACT_DIR/DerivedData-ios/Build/Products/${IOS_BUILD_CONFIGURATION}-iphoneos/SkyBridgeCompass-iOS.app"
fi
if [[ ! -d "$IOS_APP_PATH" ]]; then
  echo "iOS app bundle not found: $IOS_APP_PATH" >&2
  exit 1
fi
verify_ios_product_app "$IOS_APP_PATH"
write_product_path_proof

echo "==> Installing iOS app on real device"
if [[ "$PRESERVE_INSTALL" != "1" ]]; then
  xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device uninstall app --device "$IOS_DEVICE_ID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
else
  echo "    preserving existing install to keep Local Network/TCC grants when possible"
fi
xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device install app --device "$IOS_DEVICE_ID" "$IOS_APP_PATH" >/dev/null

echo "==> Starting macOS WebRTC host"
if [[ "$KEYCHAIN_MODE" == "in-memory" ]]; then
  KEYCHAIN_IN_MEMORY=1
else
  KEYCHAIN_IN_MEMORY=0
fi
MAC_HOST_ENV=(
  "SKYBRIDGE_KEYCHAIN_IN_MEMORY=$KEYCHAIN_IN_MEMORY"
  "SKYBRIDGE_SMOKE_KEYCHAIN_MODE=$KEYCHAIN_MODE"
  "SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN=$LAB_RUN"
  "SB_PQC_PREFERRED_SUITE=xwing"
  "SKYBRIDGE_SIGNALING_SERVER_URL=$SIGNALING_SERVER_URL"
  "SKYBRIDGE_SIGNALING_WEBSOCKET_URL=$SIGNALING_WS_URL"
  "SKYBRIDGE_CLIENT_VERSION=$CLIENT_VERSION"
  "SKYBRIDGE_PROTOCOL_VERSION=$PROTOCOL_VERSION"
  "SKYBRIDGE_SMOKE_SUPABASE_URL=${SUPABASE_URL:-}"
  "SKYBRIDGE_SMOKE_SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY:-}"
  "SKYBRIDGE_SMOKE_SKIP_SUPABASE_AUTH=0"
  "SKYBRIDGE_SMOKE_ROLE=mac-host"
  "SKYBRIDGE_SMOKE_STATUS_FILE=$MAC_STATUS"
  "SKYBRIDGE_SMOKE_CODE_FILE=$MAC_CODE"
  "SKYBRIDGE_SMOKE_PQC_REPORT_FILE=$MAC_PQC_REPORT"
  "SKYBRIDGE_SMOKE_SKIP_AUTH_REFRESH=1"
  "SKYBRIDGE_SMOKE_REQUIRE_STREAM=1"
  "SKYBRIDGE_SMOKE_SYNTHETIC_SCREEN=$SMOKE_SYNTHETIC_SCREEN"
  "SKYBRIDGE_SMOKE_SYNTHETIC_OPUS_TONE=$SMOKE_SYNTHETIC_OPUS_TONE"
  "SKYBRIDGE_SMOKE_EXTREME_MEDIA=$SMOKE_EXTREME_MEDIA"
  "SKYBRIDGE_SMOKE_FORCE_RELAY_ICE=$SMOKE_FORCE_RELAY_ICE"
  "SKYBRIDGE_WEBRTC_EXTREME_MEDIA=$SMOKE_EXTREME_MEDIA"
  "SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK=$SMOKE_EXTREME_MEDIA"
  "SKYBRIDGE_SMOKE_ALLOW_CLASSIC_MEDIA_SUCCESS=0"
  "SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS=$SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS"
  "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1"
  "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS=$SMOKE_TIMEOUT_SECONDS"
  "SKYBRIDGE_SMOKE_AUTO_EXIT=0"
)
if [[ "$MAC_HOST_MODE" == "diagnostic-cli" ]]; then
  MAC_HOST_ENV+=(
    "SKYBRIDGE_AUTH_SESSION_FILE=$AUTH_SESSION_FILE"
    "SKYBRIDGE_DEVICE_ID=$MAC_DEVICE_ID"
  )
else
  MAC_HOST_ENV+=(
    "SKYBRIDGE_SMOKE_EXPECTED_AUTH_BINDING_SHA256=$AUTH_BINDING_DIGEST"
  )
fi
if [[ -n "$STUN_URL" ]]; then
  MAC_HOST_ENV+=("SKYBRIDGE_STUN_URL=$STUN_URL")
fi
if [[ -n "$TURN_URLS" ]]; then
  MAC_HOST_ENV+=("SKYBRIDGE_TURN_URLS=$TURN_URLS")
fi
if [[ "$MAC_HOST_MODE" == "product" ]]; then
  existing_mac_pids="$(/usr/bin/pgrep -x SkyBridgeCompassApp 2>/dev/null || true)"
  open_args=(
    -n
    --stdout "$MAC_STDOUT"
    --stderr "$MAC_STDOUT"
  )
  for environment_entry in "${MAC_HOST_ENV[@]}"; do
    open_args+=(--env "$environment_entry")
  done
  /usr/bin/open "${open_args[@]}" "$MAC_PRODUCT_APP_BUNDLE"
  mac_launch_started_at="$(date +%s)"
  while [[ -z "$MAC_PID" ]]; do
    while IFS= read -r candidate_pid; do
      [[ -n "$candidate_pid" ]] || continue
      if ! grep -qx "$candidate_pid" <<<"$existing_mac_pids"; then
        MAC_PID="$candidate_pid"
        break
      fi
    done < <(/usr/bin/pgrep -x SkyBridgeCompassApp 2>/dev/null || true)
    if (( "$(date +%s)" - mac_launch_started_at >= 20 )); then
      echo "Timed out waiting for the packaged macOS WebRTC product process." >&2
      exit 1
    fi
    sleep 0.25
  done
else
  (
    umask 077
    exec env "${MAC_HOST_ENV[@]}" "$MAC_APP_BIN"
  ) >"$MAC_STDOUT" 2>&1 &
  MAC_PID="$!"
fi
if ! python3 "$PROCESS_OWNERSHIP_HELPER" mac-capture \
  --pid "$MAC_PID" \
  --expected-executable "$MAC_APP_BIN" \
  --output "$MAC_PROCESS_IDENTITY"; then
  echo "Failed to capture the exact macOS WebRTC process executable and start-time token." >&2
  exit 1
fi

wait_for_file_nonempty "$MAC_CODE" 90 "macOS connection code"
wait_for_file_nonempty "$MAC_PQC_REPORT" 90 "macOS PQC report"
load_pqc_report "$MAC_PQC_REPORT"
prepare_ios_bootstrap

echo "==> Copying one-time iOS bootstrap through the app data container"
xcrun devicectl --timeout "$DEVICECTL_TIMEOUT_SECONDS" device copy to \
  --device "$IOS_DEVICE_ID" \
  --source "$IOS_BOOTSTRAP_SOURCE" \
  --destination "$IOS_BOOTSTRAP_REMOTE_DIRECTORY" \
  --domain-type appDataContainer \
  --domain-identifier "$IOS_BUNDLE_ID" >/dev/null
DID_COPY_IOS_BOOTSTRAP=1

echo "==> Launching iOS WebRTC smoke client"
echo "    if the iPad shows a Local Network permission alert, tap Allow"
if [[ "$KEYCHAIN_MODE" == "in-memory" ]]; then
  IOS_DEVICE_ID_OVERRIDE="$IOS_LOGICAL_DEVICE_ID"
else
  IOS_DEVICE_ID_OVERRIDE=""
fi
IOS_ENV_JSON="$(
  SKYBRIDGE_KEYCHAIN_IN_MEMORY="$KEYCHAIN_IN_MEMORY" \
  SKYBRIDGE_SMOKE_KEYCHAIN_MODE="$KEYCHAIN_MODE" \
  SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN="$LAB_RUN" \
  SB_PQC_PREFERRED_SUITE=xwing \
  SKYBRIDGE_DEVICE_ID="$IOS_DEVICE_ID_OVERRIDE" \
  SKYBRIDGE_SIGNALING_SERVER_URL="$SIGNALING_SERVER_URL" \
  SKYBRIDGE_SIGNALING_WEBSOCKET_URL="$SIGNALING_WS_URL" \
  SKYBRIDGE_CLIENT_VERSION="$CLIENT_VERSION" \
  SKYBRIDGE_PROTOCOL_VERSION="$PROTOCOL_VERSION" \
  SKYBRIDGE_STUN_URL="$STUN_URL" \
  SKYBRIDGE_TURN_URLS="$TURN_URLS" \
  SKYBRIDGE_SMOKE_ROLE=ios-client \
  SKYBRIDGE_SMOKE_BOOTSTRAP_RUN_ID="$RUN_ID" \
  SKYBRIDGE_SMOKE_STATUS_BASENAME="$IOS_STATUS_NAME" \
  SKYBRIDGE_SMOKE_TIMEOUT_SECONDS="$SMOKE_TIMEOUT_SECONDS" \
  SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS="$SMOKE_HOST_HOLD_AFTER_SUCCESS_SECONDS" \
  SKYBRIDGE_SMOKE_REQUIRE_AUDIO="$SMOKE_REQUIRE_AUDIO" \
  SKYBRIDGE_SMOKE_REQUIRE_NATIVE_VIDEO=1 \
  SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB=1 \
  SKYBRIDGE_SMOKE_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
  SKYBRIDGE_SMOKE_VIDEO_WIDTH="$SMOKE_VIDEO_WIDTH" \
  SKYBRIDGE_SMOKE_VIDEO_HEIGHT="$SMOKE_VIDEO_HEIGHT" \
  SKYBRIDGE_SMOKE_TARGET_FPS="$SMOKE_TARGET_FPS" \
  SKYBRIDGE_SMOKE_FORCE_RELAY_ICE="$SMOKE_FORCE_RELAY_ICE" \
  SKYBRIDGE_WEBRTC_EXTREME_MEDIA="$SMOKE_EXTREME_MEDIA" \
  SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK="$SMOKE_EXTREME_MEDIA" \
  SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY=1 \
  python3 - <<'PY'
import json
import os

keys = [
    "SKYBRIDGE_KEYCHAIN_IN_MEMORY",
    "SKYBRIDGE_SMOKE_KEYCHAIN_MODE",
    "SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN",
    "SB_PQC_PREFERRED_SUITE",
    "SKYBRIDGE_DEVICE_ID",
    "SKYBRIDGE_SIGNALING_SERVER_URL",
    "SKYBRIDGE_SIGNALING_WEBSOCKET_URL",
    "SKYBRIDGE_CLIENT_VERSION",
    "SKYBRIDGE_PROTOCOL_VERSION",
    "SKYBRIDGE_STUN_URL",
    "SKYBRIDGE_TURN_URLS",
    "SKYBRIDGE_SMOKE_ROLE",
    "SKYBRIDGE_SMOKE_BOOTSTRAP_RUN_ID",
    "SKYBRIDGE_SMOKE_STATUS_BASENAME",
    "SKYBRIDGE_SMOKE_TIMEOUT_SECONDS",
    "SKYBRIDGE_SMOKE_HOLD_AFTER_SUCCESS_SECONDS",
    "SKYBRIDGE_SMOKE_REQUIRE_AUDIO",
    "SKYBRIDGE_SMOKE_REQUIRE_NATIVE_VIDEO",
    "SKYBRIDGE_SMOKE_OPEN_REMOTE_TAB",
    "SKYBRIDGE_SMOKE_EXTREME_MEDIA",
    "SKYBRIDGE_SMOKE_VIDEO_WIDTH",
    "SKYBRIDGE_SMOKE_VIDEO_HEIGHT",
    "SKYBRIDGE_SMOKE_TARGET_FPS",
    "SKYBRIDGE_SMOKE_FORCE_RELAY_ICE",
    "SKYBRIDGE_WEBRTC_EXTREME_MEDIA",
    "SKYBRIDGE_WEBRTC_FAIL_ON_MEDIA_FALLBACK",
    "SKYBRIDGE_SMOKE_EXPECT_PQC_REKEY",
]
env = {}
for key in keys:
    value = os.environ.get(key)
    if value is not None and value != "":
        env[key] = value
print(json.dumps(env, ensure_ascii=False))
PY
)"

launch_ios_app_with_console_handle
python3 - "$IOS_LAUNCH_SUMMARY_JSON" "$IOS_BUNDLE_ID" <<'PY'
import json
import os
import pathlib
import sys
import tempfile

output_path = pathlib.Path(sys.argv[1])
payload = {
    "bundleIdentifier": sys.argv[2],
    "launched": True,
    "rawLaunchContextRetained": False,
    "schemaVersion": 1,
}
with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=output_path.parent, delete=False) as handle:
    temporary_path = pathlib.Path(handle.name)
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary_path, output_path)
PY
wait_for_ios_pattern \
  "$IOS_STATUS_LOCAL" \
  "$IOS_STATUS_NAME" \
  "^bootstrap-consumed run=${RUN_ID}$" \
  90 \
  "iOS one-time bootstrap consumption"
overwrite_ios_bootstrap_with_tombstone
if ! rm -f -- "$MAC_CODE"; then
  echo "Unable to remove the consumed WebRTC connection-code output." >&2
  exit 1
fi
MAC_CODE=""
destroy_private_auth_session

wait_for_file_pattern "$MAC_STATUS" 'rekey session=.*complete suite=X-Wing' "$SMOKE_TIMEOUT_SECONDS" "macOS X-Wing rekey"
SESSION_ID="$(grep -Eo 'rekey session=[^ ]+ complete suite=X-Wing' "$MAC_STATUS" 2>/dev/null | tail -n 1 | awk '{print $2}' | cut -d= -f2 || true)"
if [[ -z "$SESSION_ID" ]]; then
  echo "Unable to extract the X-Wing rekey session id from mac status: $MAC_STATUS" >&2
  exit 1
fi
SESSION_REGEX="$(regex_escape "$SESSION_ID")"
wait_for_file_pattern \
  "$MAC_STATUS" \
  "rekey session=${SESSION_REGEX} complete suite=X-Wing" \
  "$SMOKE_TIMEOUT_SECONDS" \
  "macOS session-bound X-Wing rekey"

wait_for_ios_pattern \
  "$IOS_STATUS_LOCAL" \
  "$IOS_STATUS_NAME" \
  "handshake session=${SESSION_REGEX} suite=(X25519(-Ed25519)?|X-Wing)" \
  "$SMOKE_TIMEOUT_SECONDS" \
  "iOS bootstrap handshake"
wait_for_ios_pattern \
  "$IOS_STATUS_LOCAL" \
  "$IOS_STATUS_NAME" \
  "rekey session=${SESSION_REGEX} complete suite=X-Wing" \
  "$SMOKE_TIMEOUT_SECONDS" \
  "iOS X-Wing rekey"

if [[ "$MAC_HOST_MODE" == "product" ]]; then
  wait_for_file_pattern \
    "$MAC_STATUS" \
    "remoteControlNoticePanelPresented session=${SESSION_REGEX} transport=webrtc phase=awaitingApproval .*buttons=.*approve" \
    "$SMOKE_TIMEOUT_SECONDS" \
    "macOS product remote-control approval panel"
  cat >&2 <<'EOF'
==> Human approval required on the Mac
    Review the top-centered SkyBridge remote-control security panel and click Approve.
    Do not use automation or a smoke helper: release evidence requires the real panel action.
EOF
  wait_for_file_pattern \
    "$MAC_STATUS" \
    "remoteControlNoticeHumanApproved session=${SESSION_REGEX} transport=webrtc" \
    "$SMOKE_TIMEOUT_SECONDS" \
    "human WebRTC remote-control approval"
  wait_for_file_pattern \
    "$MAC_STATUS" \
    "remoteControlNoticeApproved session=${SESSION_REGEX} transport=webrtc" \
    "$SMOKE_TIMEOUT_SECONDS" \
    "approved WebRTC remote-control notice"
  wait_for_file_pattern \
    "$MAC_STATUS" \
    "remoteControlNoticeActive session=${SESSION_REGEX} transport=webrtc" \
    "$SMOKE_TIMEOUT_SECONDS" \
    "active WebRTC remote-control notice"
  HUMAN_APPROVAL_PROOF=1
fi

if grep -qE '^.*keychain-proof platform=mac mode=system auth=existing-product-session identity=system authBinding=verified productBundle=true' "$MAC_STATUS"; then
  MAC_SYSTEM_KEYCHAIN_PROOF=1
fi
if grep -qE '^.*keychain-proof platform=ios mode=system auth=existing-product-session productBundle=true' "$IOS_STATUS_LOCAL"; then
  IOS_SYSTEM_KEYCHAIN_PROOF=1
fi
if [[ "$LAB_RUN" != "1" \
      && ( "$MAC_SYSTEM_KEYCHAIN_PROOF" != "1" \
        || "$IOS_SYSTEM_KEYCHAIN_PROOF" != "1" \
        || "$HUMAN_APPROVAL_PROOF" != "1" ) ]]; then
  echo "WebRTC acceptance is missing system-Keychain/product-path/human-approval evidence." >&2
  exit 1
fi

wait_for_file_pattern \
  "$MAC_STATUS" \
  "success session=${SESSION_REGEX} suite=X-Wing.*stream=true" \
  "$SMOKE_TIMEOUT_SECONDS" \
  "macOS session-bound WebRTC success"

if [[ "$SMOKE_REQUIRE_AUDIO" == "1" ]]; then
  echo "==> Waiting for iOS audio receive evidence"
  if ! wait_for_ios_pattern \
    "$IOS_TRACE_LOCAL" \
    "$IOS_STATUS_NAME.trace.log" \
    "audio-rx .*audioRxRecv=[1-9][0-9]* .*audioRxPlayed=[1-9][0-9]*" \
    "$SMOKE_AUDIO_BOOTSTRAP_TIMEOUT_SECONDS" \
    "iOS audio receive evidence"; then
    echo "==> Running WebRTC media doctor after audio bootstrap timeout" >&2
    run_webrtc_media_doctor "$SESSION_ID" || true
    exit 1
  fi
fi

echo "==> Running WebRTC media doctor"
run_webrtc_media_doctor "$SESSION_ID"
copy_round_diagnostics
echo "==> Closing the exact iOS console launch handle and proving remote app absence"
terminate_ios_app
stamp_release_session_evidence "$SESSION_ID"
write_release_acceptance_manifest
echo "==> Materializing redacted public WebRTC smoke artifacts"
skybridge_smoke_materialize_public_artifacts "$IOS_DEVICE_LABEL" "$ARTIFACT_DIR" "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID" "$MAC_DEVICE_ID" "$IOS_LOGICAL_DEVICE_ID" "$MAC_PQC_DEVICE_ID"
skybridge_smoke_check_public_artifacts "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID" "$MAC_DEVICE_ID" "$IOS_LOGICAL_DEVICE_ID" "$MAC_PQC_DEVICE_ID"
echo "==> Redacted public artifacts: $PUBLIC_ARTIFACT_DIR"
ACCEPTANCE_CANDIDATE_READY=1

if [[ "$LAB_RUN" == "1" ]]; then
  echo "Lab run completed, but this is not an acceptance pass because SKYBRIDGE_REAL_DEVICE_WEBRTC_LAB_RUN=1." >&2
  echo "    session: $SESSION_ID" >&2
  echo "    mac status: $MAC_STATUS" >&2
  echo "    ios status: $IOS_STATUS_LOCAL" >&2
  echo "    ios trace:  $IOS_TRACE_LOCAL" >&2
  echo "    doctor:     $ARTIFACT_DIR/webrtc_media_doctor.json" >&2
  exit 2
fi

echo "==> WebRTC acceptance candidate complete; final eligibility waits for verified process cleanup"
