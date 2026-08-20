#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNERSHIP_HELPER="$ROOT_DIR/Scripts/webrtc_smoke_process_ownership.py"
EXTRACTOR="$ROOT_DIR/Scripts/extract_ios_product_release_evidence.py"

usage() {
  cat <<'USAGE'
Collect fixed product evidence from one exact, ordinary iOS product launch.

Usage:
  collect_ios_product_release_evidence_log.sh \
    --device-udid <physical xcdevice UDID> \
    --launch-result <private devicectl --console JSON after exact cleanup> \
    --installation-binding <private verified install binding> \
    --launch-start-epoch <integer epoch seconds recorded before launch> \
    --launch-start-time-token <seconds:microseconds recorded before launch> \
    --extracted-app <sealed release-testing SkyBridgeCompass-iOS.app> \
    --archive-identity <sealed iOS archive identity> \
    --artifact-dir <existing private evidence directory>

The caller must launch the app with normal product arguments (none), perform
the ordinary UI matrix, terminate only the exact owned devicectl console
handle, and prove the remote app absent before invoking this collector. The
device log archive and raw metadata remain in a mode-0700 temporary directory.
USAGE
}

DEVICE_UDID=""
LAUNCH_RESULT=""
INSTALLATION_BINDING=""
LAUNCH_START_EPOCH=""
LAUNCH_START_TIME_TOKEN=""
EXTRACTED_APP=""
ARCHIVE_IDENTITY=""
ARTIFACT_DIR=""

while (( $# > 0 )); do
  case "$1" in
    --device-udid)
      DEVICE_UDID="${2:-}"
      shift 2
      ;;
    --launch-result)
      LAUNCH_RESULT="${2:-}"
      shift 2
      ;;
    --installation-binding)
      INSTALLATION_BINDING="${2:-}"
      shift 2
      ;;
    --launch-start-epoch)
      LAUNCH_START_EPOCH="${2:-}"
      shift 2
      ;;
    --launch-start-time-token)
      LAUNCH_START_TIME_TOKEN="${2:-}"
      shift 2
      ;;
    --extracted-app)
      EXTRACTED_APP="${2:-}"
      shift 2
      ;;
    --archive-identity)
      ARCHIVE_IDENTITY="${2:-}"
      shift 2
      ;;
    --artifact-dir)
      ARTIFACT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$DEVICE_UDID" =~ ^[A-Za-z0-9][A-Za-z0-9-]{7,63}$ ]]; then
  echo "--device-udid must be the physical xcdevice UDID" >&2
  exit 2
fi
if [[ ! "$LAUNCH_START_EPOCH" =~ ^[1-9][0-9]*$ ]]; then
  echo "--launch-start-epoch must be positive integer epoch seconds" >&2
  exit 2
fi
if [[ ! "$LAUNCH_START_TIME_TOKEN" =~ ^[1-9][0-9]*:[0-9]{1,6}$ ]]; then
  echo "--launch-start-time-token must use seconds:microseconds" >&2
  exit 2
fi
token_microseconds="${LAUNCH_START_TIME_TOKEN#*:}"
if (( 10#$token_microseconds >= 1000000 )); then
  echo "--launch-start-time-token microseconds must be below 1000000" >&2
  exit 2
fi
for absolute_path in \
  "$LAUNCH_RESULT" "$INSTALLATION_BINDING" "$EXTRACTED_APP" \
  "$ARCHIVE_IDENTITY" "$ARTIFACT_DIR"; do
  [[ "$absolute_path" == /* ]] || {
    echo "launch, product, manifest, and artifact paths must be absolute" >&2
    exit 2
  }
done
[[ -f "$LAUNCH_RESULT" && ! -L "$LAUNCH_RESULT" ]] || {
  echo "launch result must be a real regular file" >&2
  exit 2
}
[[ -f "$INSTALLATION_BINDING" && ! -L "$INSTALLATION_BINDING" ]] || {
  echo "installation binding must be a real regular file" >&2
  exit 2
}
[[ -d "$EXTRACTED_APP" && ! -L "$EXTRACTED_APP" ]] || {
  echo "extracted release-testing app must be a real directory" >&2
  exit 2
}
[[ -f "$ARCHIVE_IDENTITY" && ! -L "$ARCHIVE_IDENTITY" ]] || {
  echo "archive identity must be a real regular file" >&2
  exit 2
}
[[ -d "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" ]] || {
  echo "artifact directory must be a real directory" >&2
  exit 2
}
OUTPUT_LOG="$ARTIFACT_DIR/ios-product-session.log"
OUTPUT_CAPTURE="$ARTIFACT_DIR/ios-product-session-capture.json"
[[ ! -e "$OUTPUT_LOG" && ! -L "$OUTPUT_LOG" && ! -e "$OUTPUT_CAPTURE" && ! -L "$OUTPUT_CAPTURE" ]] || {
  echo "iOS product evidence outputs already exist" >&2
  exit 1
}

PRIVATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-ios-product-evidence.XXXXXX")"
chmod 0700 "$PRIVATE_DIR"
cleanup() {
  /bin/rm -rf "$PRIVATE_DIR"
}
trap cleanup EXIT

BASE_OWNERSHIP="$PRIVATE_DIR/devicectl-launch-ownership.json"
BOUND_OWNERSHIP="$PRIVATE_DIR/product-launch-ownership.json"
LOG_ARCHIVE="$PRIVATE_DIR/ios-product.logarchive"
RAW_OSLOG="$PRIVATE_DIR/ios-product.ndjson"

python3 "$OWNERSHIP_HELPER" ios-capture \
  --launch-json "$LAUNCH_RESULT" \
  --app-path "$EXTRACTED_APP" \
  --output "$BASE_OWNERSHIP"
python3 "$EXTRACTOR" bind-launch \
  --ownership-record "$BASE_OWNERSHIP" \
  --installation-binding "$INSTALLATION_BINDING" \
  --extracted-app "$EXTRACTED_APP" \
  --start-time-token "$LAUNCH_START_TIME_TOKEN" \
  --output "$BOUND_OWNERSHIP"

read -r IOS_PROCESS_ID IOS_EXECUTABLE_PATH < <(
  python3 - "$BOUND_OWNERSHIP" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload["processIdentifier"], payload["executablePath"])
PY
)
[[ "$IOS_PROCESS_ID" =~ ^[1-9][0-9]*$ && "$IOS_EXECUTABLE_PATH" == /* ]] || {
  echo "bound iOS launch identity is missing its exact process" >&2
  exit 1
}

PREDICATE="processIdentifier == $IOS_PROCESS_ID AND subsystem == \"com.skybridge.compass.release-evidence\" AND category == \"ProductSession\""
/usr/bin/log collect \
  --device-udid "$DEVICE_UDID" \
  --start "@$LAUNCH_START_EPOCH" \
  --predicate "$PREDICATE" \
  --output "$LOG_ARCHIVE" >/dev/null
[[ -d "$LOG_ARCHIVE" && ! -L "$LOG_ARCHIVE" ]] || {
  echo "physical iOS unified-log archive was not produced" >&2
  exit 1
}
/usr/bin/log show \
  --archive "$LOG_ARCHIVE" \
  --style ndjson \
  --predicate "$PREDICATE" \
  >"$RAW_OSLOG"
chmod 0600 "$RAW_OSLOG"

python3 "$EXTRACTOR" extract \
  --raw-oslog "$RAW_OSLOG" \
  --launch-identity "$BOUND_OWNERSHIP" \
  --archive-identity "$ARCHIVE_IDENTITY" \
  --output-log "$OUTPUT_LOG" \
  --output-capture "$OUTPUT_CAPTURE"

echo "iOS product release evidence captured: $OUTPUT_LOG"
