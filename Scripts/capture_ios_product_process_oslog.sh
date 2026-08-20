#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNERSHIP_HELPER="$ROOT_DIR/Scripts/webrtc_smoke_process_ownership.py"
EXTRACTOR="$ROOT_DIR/Scripts/extract_ios_product_release_evidence.py"

usage() {
  cat <<'USAGE'
Capture private unified-log rows for one exact, exited iOS shipping process.

Usage:
  capture_ios_product_process_oslog.sh \
    --device-udid <physical xcdevice UDID> \
    --launch-result <devicectl launch JSON> \
    --installation-binding <verified sealed-product install binding> \
    --launch-start-epoch <positive epoch seconds> \
    --launch-start-time-token <seconds:microseconds> \
    --extracted-app <sealed SkyBridgeCompass-iOS.app> \
    --raw-output <new private NDJSON file> \
    --launch-identity-output <new private bound identity JSON>

The caller must first stop the exact devicectl console handle and prove the
remote process absent. Outputs are private inputs to fixed-schema extractors;
they are never public release artifacts.
USAGE
}

DEVICE_UDID=""
LAUNCH_RESULT=""
INSTALLATION_BINDING=""
LAUNCH_START_EPOCH=""
LAUNCH_START_TIME_TOKEN=""
EXTRACTED_APP=""
RAW_OUTPUT=""
LAUNCH_IDENTITY_OUTPUT=""

while (( $# > 0 )); do
  case "$1" in
    --device-udid) DEVICE_UDID="${2:-}"; shift 2 ;;
    --launch-result) LAUNCH_RESULT="${2:-}"; shift 2 ;;
    --installation-binding) INSTALLATION_BINDING="${2:-}"; shift 2 ;;
    --launch-start-epoch) LAUNCH_START_EPOCH="${2:-}"; shift 2 ;;
    --launch-start-time-token) LAUNCH_START_TIME_TOKEN="${2:-}"; shift 2 ;;
    --extracted-app) EXTRACTED_APP="${2:-}"; shift 2 ;;
    --raw-output) RAW_OUTPUT="${2:-}"; shift 2 ;;
    --launch-identity-output) LAUNCH_IDENTITY_OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$DEVICE_UDID" =~ ^[A-Za-z0-9][A-Za-z0-9-]{7,63}$ ]] || {
  echo "--device-udid must be the physical xcdevice UDID" >&2
  exit 2
}
[[ "$LAUNCH_START_EPOCH" =~ ^[1-9][0-9]*$ ]] || {
  echo "--launch-start-epoch must be positive integer epoch seconds" >&2
  exit 2
}
[[ "$LAUNCH_START_TIME_TOKEN" =~ ^[1-9][0-9]*:[0-9]{1,6}$ ]] || {
  echo "--launch-start-time-token must use seconds:microseconds" >&2
  exit 2
}
token_microseconds="${LAUNCH_START_TIME_TOKEN#*:}"
(( 10#$token_microseconds < 1000000 )) || {
  echo "launch start-time microseconds must be below 1000000" >&2
  exit 2
}
for path in \
  "$LAUNCH_RESULT" "$INSTALLATION_BINDING" "$EXTRACTED_APP" \
  "$RAW_OUTPUT" "$LAUNCH_IDENTITY_OUTPUT"; do
  [[ "$path" == /* ]] || { echo "all paths must be absolute" >&2; exit 2; }
done
for path in "$LAUNCH_RESULT" "$INSTALLATION_BINDING"; do
  [[ -f "$path" && ! -L "$path" ]] || {
    echo "required input must be a real regular file: $path" >&2
    exit 2
  }
done
[[ -d "$EXTRACTED_APP" && ! -L "$EXTRACTED_APP" ]] || {
  echo "extracted app must be a real directory" >&2
  exit 2
}
for path in "$RAW_OUTPUT" "$LAUNCH_IDENTITY_OUTPUT"; do
  [[ ! -e "$path" && ! -L "$path" ]] || {
    echo "private output already exists: $path" >&2
    exit 1
  }
  [[ -d "$(dirname "$path")" && ! -L "$(dirname "$path")" ]] || {
    echo "private output parent must be a real directory: $path" >&2
    exit 2
  }
done

PRIVATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-ios-process-oslog.XXXXXX")"
chmod 0700 "$PRIVATE_DIR"
trap '/bin/rm -rf "$PRIVATE_DIR"' EXIT
BASE_OWNERSHIP="$PRIVATE_DIR/devicectl-launch-ownership.json"
LOG_ARCHIVE="$PRIVATE_DIR/ios-product.logarchive"
RAW_TEMP="$PRIVATE_DIR/ios-product.ndjson"

python3 "$OWNERSHIP_HELPER" ios-capture \
  --launch-json "$LAUNCH_RESULT" \
  --app-path "$EXTRACTED_APP" \
  --output "$BASE_OWNERSHIP"
python3 "$EXTRACTOR" bind-launch \
  --ownership-record "$BASE_OWNERSHIP" \
  --installation-binding "$INSTALLATION_BINDING" \
  --extracted-app "$EXTRACTED_APP" \
  --start-time-token "$LAUNCH_START_TIME_TOKEN" \
  --output "$LAUNCH_IDENTITY_OUTPUT"

IOS_PROCESS_ID="$(python3 "$OWNERSHIP_HELPER" identity-pid \
  --platform ios --identity "$BASE_OWNERSHIP")"
[[ "$IOS_PROCESS_ID" =~ ^[1-9][0-9]*$ ]] || {
  echo "bound iOS launch identity has no exact process" >&2
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
  >"$RAW_TEMP"
chmod 0600 "$RAW_TEMP"

python3 - "$RAW_TEMP" "$RAW_OUTPUT" <<'PY'
import os
import pathlib
import stat
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
parent = destination.parent.lstat()
if destination.parent.is_symlink() or not stat.S_ISDIR(parent.st_mode):
    raise SystemExit("private raw output parent is unsafe")
content = source.read_bytes()
if not content or len(content) > 8 * 1024 * 1024:
    raise SystemExit("private raw iOS OSLog is empty or exceeds the fixed bound")
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(destination, flags, 0o600)
try:
    os.fchmod(descriptor, 0o600)
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise SystemExit("unable to write complete private raw iOS OSLog")
        view = view[written:]
    os.fsync(descriptor)
finally:
    os.close(descriptor)
directory = os.open(destination.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY

echo "private exact-process iOS OSLog captured: $RAW_OUTPUT"
