#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
BUILD_FILE="$ROOT_DIR/app/build.gradle.kts"
AUDIT_SCRIPT="$ROOT_DIR/scripts/check_android_packaged_placeholders.sh"
RUNBOOK="$ROOT_DIR/docs/REAL_DEVICE_INTEROP_RUNBOOK.md"
# shellcheck source=scripts/lib/android_packaging_policy.sh
source "$ROOT_DIR/scripts/lib/android_packaging_policy.sh"

if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" && \
      -d "$HOME/Library/Android/sdk" ]]; then
  export ANDROID_HOME="$HOME/Library/Android/sdk"
fi

fail() {
  echo "viewer-only packaging gate test failed: $*" >&2
  exit 1
}

if rg -q '(project|project\.dependencies\.project)\(\":remote-control\"\)' "$BUILD_FILE"; then
  fail 'shipping app still depends on the Android host module'
fi

if rg -q \
  'AndroidRemoteControlHostService|RemoteControlAccessibilityService|InputExecutionManager|STOP_REMOTE_INJECTION|FOREGROUND_SERVICE_MEDIA_PROJECTION|BIND_ACCESSIBILITY_SERVICE' \
  "$ROOT_DIR/app/src/main"; then
  fail 'viewer lifecycle still reaches Android host cleanup compatibility paths'
fi

for forbidden in \
  'com/skybridge/compass/remotecontrol/host/AndroidRemoteControlHostService' \
  'com/skybridge/compass/remotecontrol/service/RemoteControlAccessibilityService' \
  'com/skybridge/compass/remotecontrol/execution/InputExecutionManager' \
  'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION'; do
  rg -Fq "$forbidden" "$AUDIT_SCRIPT" || fail "packaging audit is missing forbidden item $forbidden"
done

rg -Fq -- '--mode formal' "$AUDIT_SCRIPT" || fail 'formal APK mode is missing'
rg -Fq 'apksigner' "$AUDIT_SCRIPT" || fail 'formal APK signature verification is missing'
rg -Fq 'viewer/client only' "$RUNBOOK" || fail 'runbook viewer boundary is missing'

if command -v java >/dev/null 2>&1; then
  release_runtime="${TMPDIR:-/tmp}/skybridge-release-runtime.$$.txt"
  trap 'rm -f "$release_runtime"' EXIT
  "$ROOT_DIR/gradlew" --no-daemon :app:dependencies \
    --configuration releaseRuntimeClasspath >"$release_runtime"
  if rg -q 'project :remote-control|:remote-control:' "$release_runtime"; then
    fail 'resolved releaseRuntimeClasspath still contains the Android host module'
  fi
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-viewer-gate.XXXXXX")"
trap 'rm -rf "$TMP_DIR"; rm -f "${release_runtime:-}"' EXIT

printf "uses-permission: name='android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION'\n" \
  >"$TMP_DIR/permissions.txt"
android_packaging_forbidden_permission_present \
  "$TMP_DIR/permissions.txt" \
  'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION' || {
  fail 'forbidden permission policy did not reject MediaProjection'
}

for manifest_surface in \
  'A: android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE"' \
  'E: action android:name="android.accessibilityservice.AccessibilityService"' \
  'A: android:foregroundServiceType="mediaProjection"' \
  'A: android:foregroundServiceType(0x01010599)=(type 0x11)0x20' \
  'A: android:foregroundServiceType(0x01010599)=(type 0x11)0x22'; do
  printf '%s\n' "$manifest_surface" >"$TMP_DIR/manifest-tree.txt"
  android_packaging_forbidden_manifest_surface_present "$TMP_DIR/manifest-tree.txt" || {
    fail "manifest policy did not reject $manifest_surface"
  }
done

printf 'apk-bytes\n' >"$TMP_DIR/release.apk"
printf 'mapping-bytes\n' >"$TMP_DIR/mapping.txt"
python3 - "$TMP_DIR/release.apk" "$TMP_DIR/mapping.txt" "$TMP_DIR/metadata.properties" <<'PY'
from pathlib import Path
import hashlib
import sys

apk, mapping, output = map(Path, sys.argv[1:])
output.write_text(
    "format=skybridge-release-apk-audit-v1\n"
    f"apk.sha256={hashlib.sha256(apk.read_bytes()).hexdigest()}\n"
    f"mapping.sha256={hashlib.sha256(mapping.read_bytes()).hexdigest()}\n"
    "source.commit=0000000000000000000000000000000000000000\n",
    encoding="utf-8",
)
PY
android_verify_release_audit_metadata \
  "$TMP_DIR/release.apk" "$TMP_DIR/mapping.txt" "$TMP_DIR/metadata.properties" \
  '0000000000000000000000000000000000000000'
printf 'wrong-mapping\n' >"$TMP_DIR/mapping.txt"
if android_verify_release_audit_metadata \
  "$TMP_DIR/release.apk" "$TMP_DIR/mapping.txt" "$TMP_DIR/metadata.properties" \
  '0000000000000000000000000000000000000000' \
  >/dev/null 2>&1; then
  fail 'mismatched R8 mapping unexpectedly passed release audit binding'
fi

echo 'viewer-only packaging gate tests passed'
