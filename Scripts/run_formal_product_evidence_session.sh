#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/real_device_ios_process_ownership.sh"
source "$ROOT_DIR/Scripts/release_candidate_evidence_helpers.sh"

OWNERSHIP_HELPER="$ROOT_DIR/Scripts/webrtc_smoke_process_ownership.py"
MAC_COLLECTOR="$ROOT_DIR/Scripts/collect_product_release_evidence_log.sh"
IOS_CAPTURE="$ROOT_DIR/Scripts/capture_ios_product_process_oslog.sh"
IOS_EXTRACTOR="$ROOT_DIR/Scripts/extract_ios_product_release_evidence.py"
IDENTITY_EXTRACTOR="$ROOT_DIR/Scripts/extract_ios_production_identity_evidence.py"
MANIFEST_BUILDER="$ROOT_DIR/Scripts/formal_product_evidence_manifest.py"
PRODUCT_VALIDATOR="$ROOT_DIR/Scripts/validate_product_release_evidence_log.py"
ACCEPTANCE_VALIDATOR="$ROOT_DIR/Scripts/validate_real_device_release_acceptance_artifact.py"
FINALIZER="$ROOT_DIR/Scripts/finalize_release_acceptance_manifests.py"

usage() {
  cat <<'USAGE'
Run one formal, ordinary-product physical evidence session.

Usage:
  run_formal_product_evidence_session.sh \
    --kind <connectivity|p2p|webrtc|file-transfer> \
    --artifact-dir <new private directory> \
    --public-artifact-dir <new public-redacted directory> \
    --candidate-manifest <macos-release-candidate.json> \
    --candidate-app <signed/notarized SkyBridge Compass Pro.app> \
    --candidate-dmg <same immutable candidate DMG> \
    --ios-archive-identity <sealed archive identity> \
    --ios-release-testing-ipa <sealed physical-testing IPA> \
    --ios-device-id <devicectl identifier> \
    --ios-device-udid <xcdevice physical UDID> \
    --identity-lifecycle-binding <private one-time lifecycle binding> \
    --identity-lifecycle-proof <public one-time lifecycle proof> \
    --expected-source-repository <owner/repository> \
    --expected-source-sha <40 lowercase hex> \
    [--timeout-seconds <30-1800>]

The one-time lifecycle inputs must be produced by
run_formal_ios_identity_lifecycle.sh from this same sealed iOS product. This
run performs one new ordinary iOS launch and requires a current restored +
handshake-bound identity event for this run's exact product session. It never
uses helper/testing status files, hidden triggers, launch arguments, or child
environment variables.
USAGE
}

KIND=""
ARTIFACT_DIR=""
PUBLIC_ARTIFACT_DIR=""
CANDIDATE_MANIFEST=""
CANDIDATE_APP=""
CANDIDATE_DMG=""
IOS_ARCHIVE_IDENTITY=""
IOS_RELEASE_TESTING_IPA=""
IOS_DEVICE_ID=""
IOS_DEVICE_UDID=""
IDENTITY_LIFECYCLE_BINDING=""
IDENTITY_LIFECYCLE_PROOF=""
EXPECTED_SOURCE_REPOSITORY=""
EXPECTED_SOURCE_SHA=""
TIMEOUT_SECONDS=900

while (( $# > 0 )); do
  case "$1" in
    --kind) KIND="${2:-}"; shift 2 ;;
    --artifact-dir) ARTIFACT_DIR="${2:-}"; shift 2 ;;
    --public-artifact-dir) PUBLIC_ARTIFACT_DIR="${2:-}"; shift 2 ;;
    --candidate-manifest) CANDIDATE_MANIFEST="${2:-}"; shift 2 ;;
    --candidate-app) CANDIDATE_APP="${2:-}"; shift 2 ;;
    --candidate-dmg) CANDIDATE_DMG="${2:-}"; shift 2 ;;
    --ios-archive-identity) IOS_ARCHIVE_IDENTITY="${2:-}"; shift 2 ;;
    --ios-release-testing-ipa) IOS_RELEASE_TESTING_IPA="${2:-}"; shift 2 ;;
    --ios-device-id) IOS_DEVICE_ID="${2:-}"; shift 2 ;;
    --ios-device-udid) IOS_DEVICE_UDID="${2:-}"; shift 2 ;;
    --identity-lifecycle-binding) IDENTITY_LIFECYCLE_BINDING="${2:-}"; shift 2 ;;
    --identity-lifecycle-proof) IDENTITY_LIFECYCLE_PROOF="${2:-}"; shift 2 ;;
    --expected-source-repository) EXPECTED_SOURCE_REPOSITORY="${2:-}"; shift 2 ;;
    --expected-source-sha) EXPECTED_SOURCE_SHA="${2:-}"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$KIND" in
  connectivity|p2p|webrtc|file-transfer) ;;
  *) echo "--kind must be connectivity, p2p, webrtc, or file-transfer" >&2; exit 2 ;;
esac
if [[ ! "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || (( TIMEOUT_SECONDS < 30 || TIMEOUT_SECONDS > 1800 )); then
  echo "--timeout-seconds must be an integer from 30 through 1800" >&2
  exit 2
fi
if [[ ! "$EXPECTED_SOURCE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || [[ ! "$EXPECTED_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "expected repository/SHA are malformed" >&2
  exit 2
fi
for path in \
  "$ARTIFACT_DIR" "$PUBLIC_ARTIFACT_DIR" "$CANDIDATE_MANIFEST" \
  "$CANDIDATE_APP" "$CANDIDATE_DMG" "$IOS_ARCHIVE_IDENTITY" \
  "$IOS_RELEASE_TESTING_IPA" "$IDENTITY_LIFECYCLE_BINDING" \
  "$IDENTITY_LIFECYCLE_PROOF"; do
  [[ "$path" == /* ]] || { echo "all file and directory paths must be absolute" >&2; exit 2; }
done
for destination in "$ARTIFACT_DIR" "$PUBLIC_ARTIFACT_DIR"; do
  [[ ! -e "$destination" && ! -L "$destination" ]] || {
    echo "artifact destination must not already exist: $destination" >&2
    exit 1
  }
done
for path in \
  "$CANDIDATE_MANIFEST" "$CANDIDATE_DMG" "$IOS_ARCHIVE_IDENTITY" \
  "$IOS_RELEASE_TESTING_IPA" "$IDENTITY_LIFECYCLE_BINDING" \
  "$IDENTITY_LIFECYCLE_PROOF"; do
  [[ -f "$path" && ! -L "$path" ]] || {
    echo "required input must be a real file: $path" >&2
    exit 1
  }
done
[[ -d "$CANDIDATE_APP" && ! -L "$CANDIDATE_APP" ]] || {
  echo "candidate app must be a real directory" >&2
  exit 1
}
[[ -n "$IOS_DEVICE_ID" && -n "$IOS_DEVICE_UDID" ]] || {
  echo "both devicectl identifier and xcdevice UDID are required" >&2
  exit 2
}

MAC_EXECUTABLE="$CANDIDATE_APP/Contents/MacOS/SkyBridgeCompassApp"
[[ -x "$MAC_EXECUTABLE" && ! -L "$MAC_EXECUTABLE" ]] || {
  echo "candidate app is missing its shipping executable" >&2
  exit 1
}
python3 "$ROOT_DIR/Scripts/macos_release_candidate_identity.py" verify \
  --identity "$CANDIDATE_MANIFEST" \
  --app "$CANDIDATE_APP" \
  --dmg "$CANDIDATE_DMG"
python3 "$ROOT_DIR/Scripts/ios_physical_release_acceptance.py" verify-product \
  --identity "$IOS_ARCHIVE_IDENTITY" \
  --release-testing-ipa "$IOS_RELEASE_TESTING_IPA"
python3 "$IDENTITY_EXTRACTOR" validate-lifecycle-proof \
  --proof "$IDENTITY_LIFECYCLE_PROOF" \
  --archive-identity "$IOS_ARCHIVE_IDENTITY"

mkdir -m 0700 "$ARTIFACT_DIR"
PRIVATE_RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-formal-product-session.XXXXXX")"
chmod 0700 "$PRIVATE_RUNTIME"
IOS_EXTRACTED_APP="$PRIVATE_RUNTIME/SkyBridgeCompass-iOS.app"
IOS_INSTALL_RESULT="$PRIVATE_RUNTIME/ios-install.json"
IOS_INSTALLED_APPS_RESULT="$PRIVATE_RUNTIME/ios-installed-apps.json"
IOS_INSTALLATION_BINDING="$PRIVATE_RUNTIME/ios-installation-binding.json"
IOS_PRELAUNCH_PROCESSES="$PRIVATE_RUNTIME/ios-postinstall-prelaunch-processes.json"
IOS_LAUNCH_RESULT="$PRIVATE_RUNTIME/ios-current-launch.json"
IOS_CONSOLE_STDOUT="$PRIVATE_RUNTIME/ios-current-console.stdout.log"
IOS_CONSOLE_STDERR="$PRIVATE_RUNTIME/ios-current-console.stderr.log"
IOS_CONSOLE_HANDLE_IDENTITY="$PRIVATE_RUNTIME/ios-current-console-handle.json"
IOS_CONSOLE_CAPTURE_DIAGNOSTIC="$PRIVATE_RUNTIME/ios-current-console-capture.log"
IOS_CURRENT_RAW_OSLOG="$PRIVATE_RUNTIME/ios-current-product.ndjson"
IOS_CURRENT_LAUNCH_IDENTITY="$PRIVATE_RUNTIME/ios-current-product-identity.json"
MAC_PROCESS_IDENTITY="$PRIVATE_RUNTIME/mac-process.json"
MAC_CAPTURE_STOP_FILE="$PRIVATE_RUNTIME/mac-capture.stop"
MAC_PID=""
MAC_CAPTURE_PID=""
IOS_CONSOLE_PID=""
IOS_CONSOLE_HANDLE_CAPTURED=0
IOS_LAUNCH_START_EPOCH=""
IOS_LAUNCH_START_TIME_TOKEN=""
SESSION_COMPLETE=0

cleanup() {
  local cleanup_failed=0
  if [[ -n "$MAC_CAPTURE_PID" ]]; then
    if [[ ! -e "$MAC_CAPTURE_STOP_FILE" ]]; then
      printf '%s\n' stop >"$MAC_CAPTURE_STOP_FILE"
      chmod 0600 "$MAC_CAPTURE_STOP_FILE"
    fi
    wait "$MAC_CAPTURE_PID" >/dev/null 2>&1 || cleanup_failed=1
    MAC_CAPTURE_PID=""
  fi
  if [[ -n "$MAC_PID" ]]; then
    skybridge_mac_terminate_owned_process \
      "$OWNERSHIP_HELPER" "$MAC_PID" "$MAC_PROCESS_IDENTITY" \
      "formal macOS product" || cleanup_failed=1
    MAC_PID=""
  fi
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
  else
    echo "exact process cleanup is incomplete; private runtime preserved: $PRIVATE_RUNTIME" >&2
  fi
  [[ "$SESSION_COMPLETE" == "1" && "$cleanup_failed" == "0" ]]
}
trap cleanup EXIT

python3 "$ROOT_DIR/Scripts/ios_physical_release_acceptance.py" prepare-product \
  --identity "$IOS_ARCHIVE_IDENTITY" \
  --release-testing-ipa "$IOS_RELEASE_TESTING_IPA" \
  --destination-app "$IOS_EXTRACTED_APP" >/dev/null
skybridge_mac_require_executable_absent \
  "$OWNERSHIP_HELPER" "$MAC_EXECUTABLE" "formal macOS product"
skybridge_ios_require_fresh_app_launch \
  "$OWNERSHIP_HELPER" "$IOS_DEVICE_ID" "$IOS_EXTRACTED_APP" \
  "$PRIVATE_RUNTIME" 60

echo "==> Installing the exact app extracted from the sealed release-testing IPA"
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
  echo "installed iOS product is already running before the owned launch" >&2
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
[[ -n "$IOS_LAUNCH_PERSISTENT_IDENTIFIER" ]] || {
  echo "verified installation has no launch persistent identifier" >&2
  exit 1
}

echo "==> Launching immutable Mac candidate through its ordinary application entry"
/usr/bin/open "$CANDIDATE_APP"
skybridge_mac_wait_for_single_exact_process \
  "$OWNERSHIP_HELPER" "$MAC_EXECUTABLE" 30 MAC_PID "formal macOS product"
skybridge_mac_capture_owned_process \
  "$OWNERSHIP_HELPER" "$MAC_PID" "$MAC_EXECUTABLE" \
  "$MAC_PROCESS_IDENTITY" "formal macOS product"
"$MAC_COLLECTOR" \
  --pid "$MAC_PID" \
  --candidate-manifest "$CANDIDATE_MANIFEST" \
  --candidate-app "$CANDIDATE_APP" \
  --candidate-dmg "$CANDIDATE_DMG" \
  --timeout-seconds "$TIMEOUT_SECONDS" \
  --stop-file "$MAC_CAPTURE_STOP_FILE" \
  --artifact-dir "$ARTIFACT_DIR" &
MAC_CAPTURE_PID="$!"

IOS_LAUNCH_START_EPOCH="$(date +%s)"
IOS_LAUNCH_START_TIME_TOKEN="$(python3 - <<'PY'
import time

value = time.time_ns()
print(f"{value // 1_000_000_000}:{(value // 1_000) % 1_000_000:06d}")
PY
)"
: >"$IOS_CONSOLE_STDOUT"
: >"$IOS_CONSOLE_STDERR"
chmod 0600 "$IOS_CONSOLE_STDOUT" "$IOS_CONSOLE_STDERR"
echo "==> Launching sealed iOS product with no arguments or child environment"
xcrun devicectl --timeout "$((TIMEOUT_SECONDS + 120))" device process launch \
  --device "$IOS_DEVICE_ID" \
  --console \
  --launch-persistent-identifier "$IOS_LAUNCH_PERSISTENT_IDENTIFIER" \
  --json-output "$IOS_LAUNCH_RESULT" \
  com.skybridge.compass.ios \
  >"$IOS_CONSOLE_STDOUT" 2>"$IOS_CONSOLE_STDERR" &
IOS_CONSOLE_PID="$!"
skybridge_ios_capture_console_handle \
  "$OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$IOS_CONSOLE_HANDLE_IDENTITY" \
  "$IOS_CONSOLE_CAPTURE_DIAGNOSTIC" 20
IOS_CONSOLE_HANDLE_CAPTURED=1

cat <<EOF
==> Manual ordinary-product checkpoint: $KIND
    Use only normal Mac and iPhone/iPad UI. The iOS launch must restore the
    existing production identity and bind it to this exact authenticated run.
EOF
case "$KIND" in
  connectivity)
    cat <<'EOF'
    Complete exactly three paired authenticated profiles: xwing/xwing,
    xwing/pqc, pqc/xwing. Present one correctly signed classic offer to each
    strict-PQC shipping responder. The classic stimulus is not an endpoint.
EOF
    ;;
  p2p)
    cat <<'EOF'
    Complete two different P2P sessions. First, iOS initiates and Mac responds:
    approve the visible Mac notice, obtain the peer renderer acknowledgement,
    apply real input, and disconnect. Second, Mac initiates and iOS responds;
    authenticate with X-Wing and disconnect normally on both endpoints.
EOF
    ;;
  webrtc)
    cat <<'EOF'
    Establish relay-selected WebRTC with authenticated X-Wing rekey. Approve
    the visible Mac notice, sustain real audio/video for at least 31 seconds,
    obtain the peer-renderer receipt, apply real input, then disconnect.
EOF
    ;;
  file-transfer)
    cat <<'EOF'
    Within one authenticated P2P session, use normal Send/Accept UI for one
    Mac-to-iOS and one iOS-to-Mac nonempty transfer. Wait for both Completed UI
    states and authenticated integrity receipts, then disconnect normally.
EOF
    ;;
esac
printf 'Type COMPLETE only after the exact product lifecycle is terminal: '
IFS= read -r operator_checkpoint
[[ "$operator_checkpoint" == "COMPLETE" ]] || {
  echo "operator checkpoint was not confirmed" >&2
  exit 1
}
printf '%s\n' stop >"$MAC_CAPTURE_STOP_FILE"
chmod 0600 "$MAC_CAPTURE_STOP_FILE"

echo "==> Closing exact run-owned processes before eligibility finalization"
skybridge_ios_signal_console_handle \
  "$OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$IOS_CONSOLE_HANDLE_IDENTITY"
skybridge_ios_wait_console_handle_exit \
  "$OWNERSHIP_HELPER" "$IOS_CONSOLE_PID" "$IOS_CONSOLE_HANDLE_IDENTITY" 30
skybridge_ios_capture_exited_console_identity \
  "$OWNERSHIP_HELPER" "$IOS_LAUNCH_RESULT" "$IOS_EXTRACTED_APP" \
  "$PRIVATE_RUNTIME/ios-current-base-identity.json"
skybridge_ios_require_app_absent_after_handle_exit \
  "$OWNERSHIP_HELPER" "$IOS_DEVICE_ID" "$IOS_EXTRACTED_APP" \
  "$PRIVATE_RUNTIME" 60
IOS_CONSOLE_HANDLE_CAPTURED=0
IOS_CONSOLE_PID=""

"$IOS_CAPTURE" \
  --device-udid "$IOS_DEVICE_UDID" \
  --launch-result "$IOS_LAUNCH_RESULT" \
  --installation-binding "$IOS_INSTALLATION_BINDING" \
  --launch-start-epoch "$IOS_LAUNCH_START_EPOCH" \
  --launch-start-time-token "$IOS_LAUNCH_START_TIME_TOKEN" \
  --extracted-app "$IOS_EXTRACTED_APP" \
  --raw-output "$IOS_CURRENT_RAW_OSLOG" \
  --launch-identity-output "$IOS_CURRENT_LAUNCH_IDENTITY"

if ! wait "$MAC_CAPTURE_PID"; then
  MAC_CAPTURE_PID=""
  echo "Mac product evidence capture failed" >&2
  exit 1
fi
MAC_CAPTURE_PID=""
skybridge_mac_terminate_owned_process \
  "$OWNERSHIP_HELPER" "$MAC_PID" "$MAC_PROCESS_IDENTITY" "formal macOS product"
MAC_PID=""

python3 "$IOS_EXTRACTOR" extract \
  --raw-oslog "$IOS_CURRENT_RAW_OSLOG" \
  --launch-identity "$IOS_CURRENT_LAUNCH_IDENTITY" \
  --archive-identity "$IOS_ARCHIVE_IDENTITY" \
  --output-log "$ARTIFACT_DIR/ios-product-session.log" \
  --output-capture "$ARTIFACT_DIR/ios-product-session-capture.json"
python3 "$IDENTITY_EXTRACTOR" extract-session-proof \
  --lifecycle-binding "$IDENTITY_LIFECYCLE_BINDING" \
  --lifecycle-proof "$IDENTITY_LIFECYCLE_PROOF" \
  --current-raw-oslog "$IOS_CURRENT_RAW_OSLOG" \
  --current-launch-identity "$IOS_CURRENT_LAUNCH_IDENTITY" \
  --archive-identity "$IOS_ARCHIVE_IDENTITY" \
  --product-artifact-dir "$ARTIFACT_DIR" \
  --kind "$KIND" \
  --output "$ARTIFACT_DIR/ios-production-identity-proof.json"
python3 "$IOS_EXTRACTOR" installation-capture \
  --prelaunch-processes "$IOS_PRELAUNCH_PROCESSES" \
  --launch-identity "$IOS_CURRENT_LAUNCH_IDENTITY" \
  --extracted-app "$IOS_EXTRACTED_APP" \
  --archive-identity "$IOS_ARCHIVE_IDENTITY" \
  --output "$ARTIFACT_DIR/ios-product-installation-capture.json"
/bin/cp -p "$CANDIDATE_MANIFEST" "$ARTIFACT_DIR/macos-release-candidate.json"
chmod 0600 "$ARTIFACT_DIR/macos-release-candidate.json"

python3 "$PRODUCT_VALIDATOR" validate --kind "$KIND" --artifact-dir "$ARTIFACT_DIR"
python3 "$IDENTITY_EXTRACTOR" validate-proof \
  --proof "$ARTIFACT_DIR/ios-production-identity-proof.json" \
  --archive-identity "$IOS_ARCHIVE_IDENTITY"
"$MANIFEST_BUILDER" \
  --kind "$KIND" \
  --artifact-dir "$ARTIFACT_DIR" \
  --archive-identity "$IOS_ARCHIVE_IDENTITY" \
  --output "$ARTIFACT_DIR/release-acceptance.json"

echo "==> Materializing only validated public fixed-schema artifacts"
source "$ROOT_DIR/Scripts/real_device_smoke_redaction.sh"
SKYBRIDGE_FORMAL_PRODUCT_ARTIFACTS=1 \
skybridge_smoke_materialize_public_artifacts \
  "physical-ios" "$ARTIFACT_DIR" "$PUBLIC_ARTIFACT_DIR" \
  "$IOS_DEVICE_ID" "$IOS_DEVICE_UDID"
skybridge_verify_public_macos_release_candidate_evidence \
  "$ROOT_DIR" "$ARTIFACT_DIR" "$PUBLIC_ARTIFACT_DIR"
skybridge_smoke_check_public_artifacts \
  "$PUBLIC_ARTIFACT_DIR" "$IOS_DEVICE_ID" "$IOS_DEVICE_UDID"

"$FINALIZER" \
  --private-manifest "$ARTIFACT_DIR/release-acceptance.json" \
  --public-manifest "$PUBLIC_ARTIFACT_DIR/release-acceptance.json" \
  --archive-identity "$IOS_ARCHIVE_IDENTITY"
python3 "$ACCEPTANCE_VALIDATOR" \
  --kind "$KIND" \
  --artifact-dir "$PUBLIC_ARTIFACT_DIR" \
  --expected-source-repository "$EXPECTED_SOURCE_REPOSITORY" \
  --expected-source-sha "$EXPECTED_SOURCE_SHA" \
  --ios-archive-identity "$IOS_ARCHIVE_IDENTITY" \
  --release-testing-ipa "$IOS_RELEASE_TESTING_IPA"

SESSION_COMPLETE=1
echo "formal product evidence finalized: $PUBLIC_ARTIFACT_DIR"
