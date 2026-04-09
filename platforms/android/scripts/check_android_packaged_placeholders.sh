#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${1:-$ROOT_DIR/build/interop/android-packaging-audit/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$RUN_DIR"

APK_PATH="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"
SEARCH_ROOTS=(
  "$ROOT_DIR/app/build/intermediates/project_dex_archive/debug/dexBuilderDebug/out"
  "$ROOT_DIR/core/build/intermediates/runtime_library_classes_dir/debug/bundleLibRuntimeToDirDebug"
  "$ROOT_DIR/file-transfer/build/intermediates/runtime_library_classes_dir/debug/bundleLibRuntimeToDirDebug"
  "$ROOT_DIR/remote-control/build/intermediates/runtime_library_classes_dir/debug/bundleLibRuntimeToDirDebug"
  "$ROOT_DIR/shared/build/intermediates/runtime_library_classes_dir/debug/bundleLibRuntimeToDirDebug"
)
APK_LIST="$RUN_DIR/app-debug.dex-list.txt"
SUMMARY_FILE="$RUN_DIR/summary.txt"
ENV_FILE="$RUN_DIR/environment.txt"

cat >"$ENV_FILE" <<EOF
cwd=$ROOT_DIR
date=$(date '+%Y-%m-%d %H:%M:%S %z')
java=$(command -v java || true)
unzip=$(command -v unzip || true)
zipinfo=$(command -v zipinfo || true)
EOF

echo "Cleaning relevant module outputs..."
"$ROOT_DIR/gradlew" :app:clean :core:clean :shared:clean :remote-control:clean :file-transfer:clean >/dev/null

echo "Building debug APK..."
"$ROOT_DIR/gradlew" :app:assembleDebug >/dev/null

if [[ ! -f "$APK_PATH" ]]; then
  echo "Debug APK not found: $APK_PATH" >&2
  exit 1
fi

found_root=0
>"$APK_LIST"
for root in "${SEARCH_ROOTS[@]}"; do
  if [[ -d "$root" ]]; then
    found_root=1
    find "$root" -type f >>"$APK_LIST"
  fi
done

if [[ "$found_root" -ne 1 ]]; then
  echo "No compiled class roots were found under build/intermediates" >&2
  exit 1
fi

sort -o "$APK_LIST" "$APK_LIST"

declare -a FORBIDDEN_CLASSES=(
  "com/skybridge/compass/shared/protocol/SkyBridgeProtocolManagerImpl"
  "com/skybridge/compass/shared/protocol/SkyBridgeProtocolMessage"
  "com/skybridge/compass/remotecontrol/RemoteControlManager"
  "com/skybridge/compass/remotecontrol/data/services/RemoteControlNetworkServiceImpl"
  "com/skybridge/compass/remotecontrol/data/repositories/RemoteControlRepositoryImpl"
  "com/skybridge/compass/filetransfer/data/services/FileTransferService"
  "com/skybridge/compass/filetransfer/data/services/FileTransferNetworkServiceImpl"
  "com/skybridge/compass/filetransfer/di/FileTransferModule"
)

declare -a REQUIRED_CLASSES=(
  "com/skybridge/compass/android/remote/host/AndroidRemoteControlHostService"
  "com/skybridge/compass/core/webrtc/SkyBridgeWebRtcConnectionManager"
  "com/skybridge/compass/filetransfer/webrtc/WebRtcFileTransferController"
  "com/skybridge/compass/remotecontrol/execution/InputExecutionManager"
)

status=0
{
  echo "APK: $APK_PATH"
  echo "Search roots:"
  for root in "${SEARCH_ROOTS[@]}"; do
    if [[ -d "$root" ]]; then
      echo "  - $root"
    fi
  done
  echo "Compiled class list: $APK_LIST"
  echo
  echo "[forbidden]"
  for class_name in "${FORBIDDEN_CLASSES[@]}"; do
    if rg -q "${class_name//\//\\/}(\\$|\\.|/|$)" "$APK_LIST"; then
      echo "FAIL present $class_name"
      status=1
    else
      echo "OK absent $class_name"
    fi
  done
  echo
  echo "[required]"
  for class_name in "${REQUIRED_CLASSES[@]}"; do
    if rg -q "${class_name//\//\\/}(\\$|\\.|/|$)" "$APK_LIST"; then
      echo "OK present $class_name"
    else
      echo "FAIL missing $class_name"
      status=1
    fi
  done
} >"$SUMMARY_FILE"

cat "$SUMMARY_FILE"

if [[ "$status" -ne 0 ]]; then
  echo "Android packaging audit failed; see $SUMMARY_FILE" >&2
  exit "$status"
fi

echo "Android packaging audit passed."
echo "Artifacts:"
echo "  environment: $ENV_FILE"
echo "  compiled class list: $APK_LIST"
echo "  summary: $SUMMARY_FILE"
