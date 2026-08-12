#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/lib/source_provenance.sh"
source "$ROOT_DIR/scripts/lib/repository_layout.sh"
source "$ROOT_DIR/scripts/lib/android_packaging_policy.sh"
# shellcheck source=scripts/lib/strict_gradle_output.sh
source "$ROOT_DIR/scripts/lib/strict_gradle_output.sh"
RELEASE_REPO_ROOT="$(skybridge_canonical_release_root "$ROOT_DIR")"
MODE="formal"
APK_PATH=""
MAPPING_PATH=""
AUDIT_METADATA_PATH=""
EXPECTED_CERT_SHA256=""
EXPECTED_COMMIT=""
RUN_DIR=""

usage() {
  cat <<'EOF'
Usage:
  scripts/check_android_packaged_placeholders.sh \
    --mode formal \
    --apk <signed-release.apk> \
    --mapping <release-mapping.txt> \
    --audit-metadata <release-audit-metadata.properties> \
    --expected-cert-sha256 <production-certificate-fingerprint> \
    --expected-commit <full-clean-git-commit> \
    [--run-dir <artifact-directory>]

  scripts/check_android_packaged_placeholders.sh \
    --mode diagnostic-debug \
    [--run-dir <artifact-directory>]

Formal mode never builds an artifact. It requires an existing signed release APK produced after
verifyReleaseArtifactConfiguration, the matching R8 mapping, and the independently supplied
production signing-certificate fingerprint. diagnostic-debug builds app-debug.apk and is not
release proof.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --apk)
      APK_PATH="${2:-}"
      shift 2
      ;;
    --mapping)
      MAPPING_PATH="${2:-}"
      shift 2
      ;;
    --audit-metadata)
      AUDIT_METADATA_PATH="${2:-}"
      shift 2
      ;;
    --expected-cert-sha256)
      EXPECTED_CERT_SHA256="${2:-}"
      shift 2
      ;;
    --expected-commit)
      EXPECTED_COMMIT="${2:-}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$MODE" in
  formal)
    if [[ -z "$APK_PATH" ]]; then
      echo "Formal packaging audit requires --apk <signed-release.apk>" >&2
      exit 1
    fi
    if [[ -z "$MAPPING_PATH" || -z "$AUDIT_METADATA_PATH" || \
          -z "$EXPECTED_CERT_SHA256" || -z "$EXPECTED_COMMIT" ]]; then
      echo "Formal packaging audit requires --mapping, --audit-metadata, " \
        "--expected-cert-sha256, and --expected-commit" >&2
      exit 1
    fi
    APK_PATH="$(cd "$(dirname "$APK_PATH")" && pwd -P)/$(basename "$APK_PATH")"
    if [[ ! -f "$APK_PATH" || -L "$APK_PATH" ]]; then
      echo "Formal release APK is missing, not regular, or a symbolic link: $APK_PATH" >&2
      exit 1
    fi
    MAPPING_PATH="$(cd "$(dirname "$MAPPING_PATH")" && pwd -P)/$(basename "$MAPPING_PATH")"
    if [[ ! -f "$MAPPING_PATH" || -L "$MAPPING_PATH" ]]; then
      echo "Release mapping is missing, not regular, or a symbolic link: $MAPPING_PATH" >&2
      exit 1
    fi
    AUDIT_METADATA_PATH="$(cd "$(dirname "$AUDIT_METADATA_PATH")" && pwd -P)/$(basename "$AUDIT_METADATA_PATH")"
    if [[ ! -f "$AUDIT_METADATA_PATH" || -L "$AUDIT_METADATA_PATH" ]]; then
      echo "Release audit metadata is missing, not regular, or a symbolic link: $AUDIT_METADATA_PATH" >&2
      exit 1
    fi
    if [[ ! "$EXPECTED_CERT_SHA256" =~ ^([[:xdigit:]]{2}:){31}[[:xdigit:]]{2}$ ]]; then
      echo "--expected-cert-sha256 must be the production certificate SHA-256 fingerprint" >&2
      exit 1
    fi
    if [[ ! "$EXPECTED_COMMIT" =~ ^[[:xdigit:]]{40}$ ]]; then
      echo "--expected-commit must be a full 40-hex Git commit" >&2
      exit 1
    fi
    current_commit="$(git -C "$RELEASE_REPO_ROOT" rev-parse --verify HEAD)"
    if [[ "${current_commit,,}" != "${EXPECTED_COMMIT,,}" ]]; then
      echo "--expected-commit does not match the selected release worktree HEAD" >&2
      exit 1
    fi
    if [[ -n "$(git -C "$RELEASE_REPO_ROOT" status --porcelain --untracked-files=all)" ]]; then
      echo "Formal packaging audit requires a clean selected release worktree" >&2
      exit 1
    fi
    ;;
  diagnostic-debug)
    if [[ -n "$APK_PATH" ]]; then
      echo "diagnostic-debug mode does not accept --apk" >&2
      exit 1
    fi
    APK_PATH="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"
    ;;
  *)
    echo "Unsupported --mode: $MODE" >&2
    exit 1
    ;;
esac

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$ROOT_DIR/build/interop/android-packaging-audit/$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$RUN_DIR"

PROVENANCE_DIR="$RUN_DIR/source-provenance"
PROVENANCE_FILE="$RUN_DIR/source-provenance.txt"
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
AAPT="${ANDROID_AAPT:-$SDK_ROOT/build-tools/37.0.0/aapt}"
APKSIGNER="${ANDROID_APKSIGNER:-$SDK_ROOT/build-tools/37.0.0/apksigner}"
APK_LIST="$RUN_DIR/apk-dex-classes.txt"
PERMISSIONS_FILE="$RUN_DIR/apk-permissions.txt"
BADGING_FILE="$RUN_DIR/apk-badging.txt"
SIGNING_FILE="$RUN_DIR/apk-signing.txt"
CONTENTS_FILE="$RUN_DIR/apk-contents.txt"
MANIFEST_TREE_FILE="$RUN_DIR/apk-manifest-tree.txt"
VIEWER_SOURCE_GATE_FILE="$RUN_DIR/viewer-source-gate.txt"
SUMMARY_FILE="$RUN_DIR/summary.txt"
ENV_FILE="$RUN_DIR/environment.txt"

cat >"$ENV_FILE" <<EOF
cwd=$ROOT_DIR
date=$(date '+%Y-%m-%d %H:%M:%S %z')
java=$(command -v java || true)
unzip=$(command -v unzip || true)
zipinfo=$(command -v zipinfo || true)
aapt=$AAPT
apksigner=$APKSIGNER
mode=$MODE
apk_path=$APK_PATH
EOF
skybridge_append_git_source_binding "$ENV_FILE" android "$RELEASE_REPO_ROOT"

if [[ "$MODE" == "diagnostic-debug" ]]; then
  echo "Building diagnostic debug APK (not release evidence)..."
  DIAGNOSTIC_BUILD_LOG="$RUN_DIR/diagnostic-build.log"
  "$ROOT_DIR/gradlew" --no-daemon --warning-mode=fail :app:assembleDebug \
    >"$DIAGNOSTIC_BUILD_LOG" 2>&1 || {
    sed -n '1,240p' "$DIAGNOSTIC_BUILD_LOG" >&2
    exit 1
  }
  skybridge_require_zero_warning_tool_log "$DIAGNOSTIC_BUILD_LOG"
fi

if [[ ! -f "$APK_PATH" ]]; then
  echo "Debug APK not found: $APK_PATH" >&2
  exit 1
fi

if [[ "$MODE" == "formal" ]]; then
  android_collect_apk_provenance "$APK_PATH" "release_apk" >"$PROVENANCE_FILE"
else
  android_collect_source_provenance "$ROOT_DIR" "$PROVENANCE_DIR" >"$PROVENANCE_FILE"
  android_collect_apk_provenance "$APK_PATH" "diagnostic_debug_apk" >>"$PROVENANCE_FILE"
fi
cat "$PROVENANCE_FILE" >>"$ENV_FILE"

if [[ ! -x "$AAPT" ]]; then
  echo "aapt not found or not executable: $AAPT" >&2
  echo "Set ANDROID_AAPT or install Android SDK build-tools 37.0.0." >&2
  exit 1
fi
if [[ ! -x "$APKSIGNER" ]]; then
  echo "apksigner not found or not executable: $APKSIGNER" >&2
  exit 1
fi

"$AAPT" dump badging "$APK_PATH" >"$BADGING_FILE"
"$AAPT" dump xmltree "$APK_PATH" AndroidManifest.xml >"$MANIFEST_TREE_FILE"
"$APKSIGNER" verify --verbose --print-certs "$APK_PATH" >"$SIGNING_FILE"
zipinfo -1 "$APK_PATH" | LC_ALL=C sort >"$CONTENTS_FILE"

if [[ "$MODE" == "formal" ]]; then
  "$ROOT_DIR/scripts/tests/test_viewer_only_packaging_gate.sh" >"$VIEWER_SOURCE_GATE_FILE"
  packaged_binding="$(unzip -p "$APK_PATH" assets/skybridge-release/source.properties)" || {
    echo "Formal release APK is missing assets/skybridge-release/source.properties" >&2
    exit 1
  }
  packaged_repository="$(printf '%s\n' "$packaged_binding" | sed -n 's/^repository=//p')"
  packaged_commit="$(printf '%s\n' "$packaged_binding" | sed -n 's/^commit=//p')"
  if [[ "$packaged_repository" != "skybridge-compass" || \
        "${packaged_commit,,}" != "${EXPECTED_COMMIT,,}" ]]; then
    echo "Formal release APK source binding does not match the expected clean commit" >&2
    exit 1
  fi
  android_verify_release_audit_metadata \
    "$APK_PATH" "$MAPPING_PATH" "$AUDIT_METADATA_PATH" "$EXPECTED_COMMIT"
fi

python3 - "$APK_PATH" >"$APK_LIST" <<'PY'
import struct
import sys
import zipfile

apk_path = sys.argv[1]


def read_u32(buf, offset):
    return struct.unpack_from("<I", buf, offset)[0]


def dex_class_descriptors(dex_bytes):
    if len(dex_bytes) < 0x70 or dex_bytes[:4] != b"dex\n":
        raise ValueError("invalid dex header")
    string_ids_size = read_u32(dex_bytes, 0x38)
    string_ids_off = read_u32(dex_bytes, 0x3C)
    type_ids_size = read_u32(dex_bytes, 0x40)
    type_ids_off = read_u32(dex_bytes, 0x44)

    strings = []
    for index in range(string_ids_size):
        string_data_off = read_u32(dex_bytes, string_ids_off + index * 4)
        cursor = string_data_off
        while dex_bytes[cursor] & 0x80:
            cursor += 1
        cursor += 1
        end = dex_bytes.index(0, cursor)
        strings.append(dex_bytes[cursor:end].decode("utf-8", errors="replace"))

    for index in range(type_ids_size):
        descriptor_index = read_u32(dex_bytes, type_ids_off + index * 4)
        descriptor = strings[descriptor_index]
        if descriptor.startswith("L") and descriptor.endswith(";"):
            yield descriptor[1:-1]


with zipfile.ZipFile(apk_path) as apk:
    dex_names = sorted(name for name in apk.namelist() if name.startswith("classes") and name.endswith(".dex"))
    if not dex_names:
        raise SystemExit(f"no classes*.dex found in {apk_path}")
    classes = set()
    for name in dex_names:
        classes.update(dex_class_descriptors(apk.read(name)))

for class_name in sorted(classes):
    print(class_name)
PY

declare -a FORBIDDEN_HOST_CLASSES=(
  "com/skybridge/compass/remotecontrol/host/AndroidRemoteControlHostService"
  "com/skybridge/compass/remotecontrol/host/AndroidRemoteHostVideoEncoder"
  "com/skybridge/compass/remotecontrol/host/AndroidRemoteHostStreamPlan"
  "com/skybridge/compass/remotecontrol/service/RemoteControlAccessibilityService"
  "com/skybridge/compass/remotecontrol/execution/InputExecutionManager"
  "com/skybridge/compass/remotecontrol/capture/InputCaptureManager"
)

"$AAPT" dump permissions "$APK_PATH" >"$PERMISSIONS_FILE"

declare -a FORBIDDEN_PERMISSIONS=(
  "android.permission.READ_EXTERNAL_STORAGE"
  "android.permission.WRITE_EXTERNAL_STORAGE"
  "android.permission.MANAGE_EXTERNAL_STORAGE"
  "android.permission.READ_MEDIA_IMAGES"
  "android.permission.READ_MEDIA_VIDEO"
  "android.permission.READ_MEDIA_AUDIO"
  "android.permission.READ_PHONE_STATE"
  "android.permission.RECORD_AUDIO"
  "android.permission.CAMERA"
  "android.permission.SYSTEM_ALERT_WINDOW"
  "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"
)

status=0
{
	  echo "[provenance]"
	  cat "$PROVENANCE_FILE"
	  echo
	  echo "APK: $APK_PATH"
	  echo "APK dex class list: $APK_LIST"
	  echo "Mode: $MODE"
	  echo "Badging: $BADGING_FILE"
	  echo "Signing: $SIGNING_FILE"
	  echo
	  echo "[forbidden]"
	  if android_packaging_forbidden_placeholder_key_present "$CONTENTS_FILE"; then
	    echo "FAIL packaged deprecated placeholder pin-verification key"
	    status=1
	  else
	    echo "OK absent deprecated placeholder pin-verification key"
	  fi
	  for class_name in "${FORBIDDEN_HOST_CLASSES[@]}"; do
	    mapped_name="${class_name//\//.}"
	    if [[ "$MODE" == "formal" ]]; then
	      mapped_name="$(python3 - "$MAPPING_PATH" "$mapped_name" <<'PY'
from pathlib import Path
import sys

mapping_path = Path(sys.argv[1])
original = sys.argv[2]
prefix = original + " -> "
for line in mapping_path.read_text(encoding="utf-8", errors="strict").splitlines():
    if line.startswith(prefix) and line.endswith(":"):
        print(line[len(prefix):-1])
        break
PY
)"
	    fi
	    mapped_descriptor="${mapped_name//./\/}"
	    if [[ -n "$mapped_name" ]] && rg -q "^${mapped_descriptor}(\\$|$)" "$APK_LIST"; then
	      echo "FAIL present $class_name"
	      status=1
	    else
      echo "OK absent $class_name (mapping-aware)"
    fi
  done
	  echo
  echo "[permissions]"
  echo "Permissions dump: $PERMISSIONS_FILE"
  for permission_name in "${FORBIDDEN_PERMISSIONS[@]}"; do
    if android_packaging_forbidden_permission_present "$PERMISSIONS_FILE" "$permission_name"; then
      echo "FAIL present $permission_name"
      status=1
    else
      echo "OK absent $permission_name"
    fi
  done
  if android_packaging_forbidden_manifest_surface_present "$MANIFEST_TREE_FILE"; then
    echo "FAIL present renamed Android host Accessibility/MediaProjection manifest surface"
    status=1
  else
    echo "OK absent renamed Android host Accessibility/MediaProjection manifest surface"
  fi
  echo
  echo "[release metadata]"
  if [[ "$MODE" == "formal" ]] && \
      rg -q "^package: name='com\.skybridge\.compass' versionCode='2' versionName='1\.0\.2'" "$BADGING_FILE"; then
    echo "OK release identity com.skybridge.compass 1.0.2 (2)"
  elif [[ "$MODE" == "diagnostic-debug" ]] && \
      rg -q "^package: name='com\.skybridge\.compass\.debug' versionCode='2' versionName='1\.0\.2-debug'" "$BADGING_FILE"; then
    echo "OK diagnostic identity com.skybridge.compass.debug 1.0.2-debug (2)"
  else
    echo "FAIL package/version mismatch for mode=$MODE"
    status=1
  fi
  if rg -q '^Verified using v[234] scheme \(APK Signature Scheme' "$SIGNING_FILE"; then
    echo "OK APK signature verified"
  else
    echo "FAIL APK has no verified modern signature scheme"
    status=1
  fi
  if [[ "$MODE" == "formal" ]]; then
    actual_cert_sha256="$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' "$SIGNING_FILE" | head -n 1)"
    expected_cert_compact="${EXPECTED_CERT_SHA256//:/}"
    if [[ "${actual_cert_sha256^^}" == "${expected_cert_compact^^}" ]]; then
      echo "OK production signing certificate"
    else
      echo "FAIL production signing certificate mismatch"
      status=1
    fi
  fi
  if [[ "$MODE" == "formal" ]]; then
    echo "OK APK source binding commit=$EXPECTED_COMMIT"
    echo "OK matching R8 mapping supplied: $MAPPING_PATH"
  fi
  if rg -q '^lib/(arm64-v8a|armeabi-v7a|x86|x86_64)/libjingle_peerconnection_so\.so$' "$CONTENTS_FILE"; then
    echo "OK WebRTC native ABI present"
  else
    echo "FAIL WebRTC native ABI missing"
    status=1
  fi
  if rg -q '^assets/third_party_licenses/webrtc-sdk\.txt$' "$CONTENTS_FILE"; then
    echo "OK WebRTC third-party notice packaged"
  else
    echo "FAIL WebRTC third-party notice missing"
    status=1
  fi
} >"$SUMMARY_FILE"

cat "$SUMMARY_FILE"

if [[ "$status" -ne 0 ]]; then
  echo "Android packaging audit failed; see $SUMMARY_FILE" >&2
  exit "$status"
fi

echo "Android packaging audit passed."
echo "Artifacts:"
echo "  environment: $ENV_FILE"
echo "  provenance: $PROVENANCE_FILE"
echo "  APK dex class list: $APK_LIST"
echo "  permissions: $PERMISSIONS_FILE"
if [[ "$MODE" == "formal" ]]; then
  echo "  source-bound viewer gate: $VIEWER_SOURCE_GATE_FILE"
fi
echo "  summary: $SUMMARY_FILE"
