#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=scripts/lib/repository_layout.sh
source "$ROOT_DIR/scripts/lib/repository_layout.sh"
# shellcheck source=scripts/lib/android_packaging_policy.sh
source "$ROOT_DIR/scripts/lib/android_packaging_policy.sh"
RELEASE_REPO_ROOT="$(skybridge_canonical_release_root "$ROOT_DIR")"

AAB_PATH=""
MAPPING_PATH=""
AUDIT_METADATA_PATH=""
BUNDLETOOL_PATH=""
EXPECTED_UPLOAD_CERT_SHA256=""
EXPECTED_COMMIT=""
RUN_DIR=""
EXPECTED_BUNDLETOOL_VERSION="1.18.3"
EXPECTED_PACKAGE_NAME="com.skybridge.compass"
EXPECTED_VERSION_CODE="2"
EXPECTED_VERSION_NAME="1.0.2"

usage() {
  cat <<'EOF'
Usage:
  scripts/check_android_release_aab.sh \
    --aab <signed-release.aab> \
    --mapping <release-mapping.txt> \
    --audit-metadata <release-aab-audit-metadata.properties> \
    --bundletool <official-bundletool-all-1.18.3.jar> \
    --expected-upload-cert-sha256 <approved-upload-certificate-fingerprint> \
    --expected-commit <full-clean-git-commit> \
    [--run-dir <new-artifact-directory>]

The formal AAB gate is read-only with respect to source and never builds a release artifact.
It proves the independently approved upload signer on the AAB. Google Play's app-signing
(distribution) certificate signs Play-generated APKs and remains a separate Play-console or
downloaded-APK release gate.
EOF
}

fail() {
  echo "Android formal AAB gate failed: $*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    fail "$option requires a value"
  fi
}

resolve_regular_file() {
  local label="$1"
  local candidate="$2"
  local parent
  if [[ "$candidate" == *$'\n'* || "$candidate" == *$'\r'* ]]; then
    fail "$label path contains a control character"
  fi
  parent="$(dirname "$candidate")"
  [[ -d "$parent" ]] || fail "$label parent directory does not exist: $parent"
  parent="$(cd "$parent" && pwd -P)"
  candidate="$parent/$(basename "$candidate")"
  [[ -f "$candidate" && ! -L "$candidate" ]] || {
    fail "$label is missing, not regular, or a symbolic link: $candidate"
  }
  printf '%s\n' "$candidate"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --aab)
      require_value "$1" "${2:-}"
      AAB_PATH="$2"
      shift 2
      ;;
    --mapping)
      require_value "$1" "${2:-}"
      MAPPING_PATH="$2"
      shift 2
      ;;
    --audit-metadata)
      require_value "$1" "${2:-}"
      AUDIT_METADATA_PATH="$2"
      shift 2
      ;;
    --bundletool)
      require_value "$1" "${2:-}"
      BUNDLETOOL_PATH="$2"
      shift 2
      ;;
    --expected-upload-cert-sha256)
      require_value "$1" "${2:-}"
      EXPECTED_UPLOAD_CERT_SHA256="$2"
      shift 2
      ;;
    --expected-commit)
      require_value "$1" "${2:-}"
      EXPECTED_COMMIT="$2"
      shift 2
      ;;
    --run-dir)
      require_value "$1" "${2:-}"
      RUN_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$AAB_PATH" ]] || fail "--aab is required"
[[ -n "$MAPPING_PATH" ]] || fail "--mapping is required"
[[ -n "$AUDIT_METADATA_PATH" ]] || fail "--audit-metadata is required"
[[ -n "$BUNDLETOOL_PATH" ]] || fail "--bundletool is required"
[[ -n "$EXPECTED_UPLOAD_CERT_SHA256" ]] || {
  fail "--expected-upload-cert-sha256 is required from an independent approval channel"
}
[[ -n "$EXPECTED_COMMIT" ]] || fail "--expected-commit is required"

if [[ ! "$EXPECTED_UPLOAD_CERT_SHA256" =~ ^([[:xdigit:]]{2}:){31}[[:xdigit:]]{2}$ ]]; then
  fail "--expected-upload-cert-sha256 must be a colon-delimited SHA-256 certificate fingerprint"
fi
if [[ ! "$EXPECTED_COMMIT" =~ ^[[:xdigit:]]{40}$ ]]; then
  fail "--expected-commit must be a full 40-hex Git commit"
fi

AAB_PATH="$(resolve_regular_file "release AAB" "$AAB_PATH")"
MAPPING_PATH="$(resolve_regular_file "release R8 mapping" "$MAPPING_PATH")"
AUDIT_METADATA_PATH="$(resolve_regular_file "release AAB audit metadata" "$AUDIT_METADATA_PATH")"
BUNDLETOOL_PATH="$(resolve_regular_file "official bundletool executable JAR" "$BUNDLETOOL_PATH")"
[[ "$AAB_PATH" == *.aab ]] || fail "--aab must name an .aab file"
[[ "$BUNDLETOOL_PATH" == *.jar ]] || fail "--bundletool must name the official executable JAR"
[[ -s "$MAPPING_PATH" ]] || fail "release R8 mapping is empty"

current_commit="$(git -C "$RELEASE_REPO_ROOT" rev-parse --verify HEAD)"
if [[ "${current_commit,,}" != "${EXPECTED_COMMIT,,}" ]]; then
  fail "--expected-commit does not match the canonical release worktree HEAD"
fi
if [[ -n "$(git -C "$RELEASE_REPO_ROOT" status --porcelain --untracked-files=all)" ]]; then
  fail "formal AAB audit requires a clean canonical release worktree"
fi

for required_tool in java jarsigner keytool python3 rg; do
  command -v "$required_tool" >/dev/null 2>&1 || fail "required tool is unavailable: $required_tool"
done

bundletool_version="$(java -jar "$BUNDLETOOL_PATH" version 2>&1)" || {
  fail "--bundletool is not an executable official bundletool JAR"
}
bundletool_version="${bundletool_version//$'\r'/}"
bundletool_version="${bundletool_version//$'\n'/}"
if [[ "$bundletool_version" != "$EXPECTED_BUNDLETOOL_VERSION" ]]; then
  fail "bundletool version must be $EXPECTED_BUNDLETOOL_VERSION, found $bundletool_version"
fi

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$ROOT_DIR/build/interop/android-aab-audit/$(date +%Y%m%d-%H%M%S)"
fi
if [[ "$RUN_DIR" == *$'\n'* || "$RUN_DIR" == *$'\r'* ]]; then
  fail "--run-dir contains a control character"
fi
run_parent="$(dirname "$RUN_DIR")"
mkdir -p "$run_parent"
run_parent="$(cd "$run_parent" && pwd -P)"
RUN_DIR="$run_parent/$(basename "$RUN_DIR")"
[[ ! -e "$RUN_DIR" && ! -L "$RUN_DIR" ]] || {
  fail "--run-dir must not already exist: $RUN_DIR"
}
mkdir "$RUN_DIR"
chmod 700 "$RUN_DIR"

ENV_FILE="$RUN_DIR/environment.txt"
AAB_CONTENTS_FILE="$RUN_DIR/aab-contents.txt"
AAB_MODULES_FILE="$RUN_DIR/aab-modules.txt"
AAB_VALIDATE_FILE="$RUN_DIR/bundletool-validate.txt"
AAB_CONFIG_FILE="$RUN_DIR/bundletool-config.txt"
SOURCE_BINDING_FILE="$RUN_DIR/source.properties"
SIGNATURE_FILE="$RUN_DIR/aab-jarsigner.txt"
SIGNER_CERTIFICATE_FILE="$RUN_DIR/aab-upload-certificate.pem"
APKS_PATH="$RUN_DIR/universal.apks"
APKS_CONTENTS_FILE="$RUN_DIR/universal-apks-contents.txt"
UNIVERSAL_APK_PATH="$RUN_DIR/universal.apk"
APK_CONTENTS_FILE="$RUN_DIR/universal-apk-contents.txt"
BADGING_FILE="$RUN_DIR/universal-apk-badging.txt"
PERMISSIONS_FILE="$RUN_DIR/universal-apk-permissions.txt"
MANIFEST_TREE_FILE="$RUN_DIR/universal-apk-manifest-tree.txt"
APK_SIGNING_FILE="$RUN_DIR/universal-apk-signing.txt"
APK_CLASSES_FILE="$RUN_DIR/universal-apk-classes.txt"
APK_ZIPALIGN_FILE="$RUN_DIR/universal-apk-zipalign-16k.txt"
APK_ELF_ALIGNMENT_FILE="$RUN_DIR/universal-apk-elf-alignment.txt"
VIEWER_SOURCE_GATE_FILE="$RUN_DIR/viewer-source-gate.txt"
SUMMARY_FILE="$RUN_DIR/summary.txt"

AUDIT_SIGNING_DIR=""
cleanup_audit_signing() {
  if [[ -n "${AUDIT_SIGNING_DIR:-}" && -d "$AUDIT_SIGNING_DIR" ]]; then
    rm -rf -- "$AUDIT_SIGNING_DIR"
  fi
}
AUDIT_SIGNING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-aab-audit-signing.XXXXXX")"
trap cleanup_audit_signing EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 700 "$AUDIT_SIGNING_DIR"
AUDIT_KEYSTORE_PATH="$AUDIT_SIGNING_DIR/audit-only-universal-apk.p12"
AUDIT_KEYSTORE_PASSWORD_FILE="$AUDIT_SIGNING_DIR/keystore-password.txt"

"$ROOT_DIR/scripts/tests/test_viewer_only_packaging_gate.sh" >"$VIEWER_SOURCE_GATE_FILE"

cat >"$ENV_FILE" <<EOF
cwd=$ROOT_DIR
date=$(date '+%Y-%m-%d %H:%M:%S %z')
git_root=$RELEASE_REPO_ROOT
git_head=$current_commit
git_clean=true
aab_path=$AAB_PATH
mapping_path=$MAPPING_PATH
audit_metadata_path=$AUDIT_METADATA_PATH
bundletool_path=$BUNDLETOOL_PATH
bundletool_version=$bundletool_version
expected_upload_certificate_sha256=${EXPECTED_UPLOAD_CERT_SHA256^^}
play_distribution_certificate_verified=false
EOF

android_inspect_aab_archive "$AAB_PATH" "$AAB_MODULES_FILE" "$AAB_CONTENTS_FILE"
android_extract_archive_entry \
  "$AAB_PATH" "base/assets/skybridge-release/source.properties" "$SOURCE_BINDING_FILE" 4096
android_verify_release_source_binding_file "$SOURCE_BINDING_FILE" "$EXPECTED_COMMIT"
android_verify_release_aab_audit_metadata \
  "$AAB_PATH" "$MAPPING_PATH" "$AUDIT_METADATA_PATH" "$EXPECTED_COMMIT"

if ! jarsigner -J-Duser.language=en -J-Duser.country=US \
    -verify -verbose -certs "$AAB_PATH" >"$SIGNATURE_FILE" 2>&1; then
  fail "AAB JAR signature verification failed; see $SIGNATURE_FILE"
fi
rg -Fq 'jar verified.' "$SIGNATURE_FILE" || {
  fail "jarsigner did not confirm the AAB signature; see $SIGNATURE_FILE"
}
android_verify_complete_jar_signature "$AAB_PATH"

keytool -J-Duser.language=en -J-Duser.country=US \
  -printcert -rfc -jarfile "$AAB_PATH" >"$SIGNER_CERTIFICATE_FILE" 2>&1 || {
  fail "could not extract the AAB upload signer certificate"
}
if [[ "$(rg -c '^Signer #[0-9]+:$' "$SIGNER_CERTIFICATE_FILE")" != '1' ]]; then
  fail "release AAB must have exactly one upload signer"
fi
actual_upload_cert_sha256="$(
  android_certificate_sha256_from_pem "$SIGNER_CERTIFICATE_FILE"
)"
if [[ "${actual_upload_cert_sha256^^}" != "${EXPECTED_UPLOAD_CERT_SHA256^^}" ]]; then
  fail "AAB upload certificate does not match the independently approved fingerprint"
fi

java -jar "$BUNDLETOOL_PATH" validate --bundle="$AAB_PATH" >"$AAB_VALIDATE_FILE" 2>&1 || {
  fail "bundletool rejected the release AAB; see $AAB_VALIDATE_FILE"
}
java -jar "$BUNDLETOOL_PATH" dump config --bundle="$AAB_PATH" >"$AAB_CONFIG_FILE" 2>&1 || {
  fail "bundletool could not inspect the release AAB configuration"
}
if [[ "$(rg -o 'PAGE_ALIGNMENT_(?:4K|16K|64K)' "$AAB_CONFIG_FILE" | sort -u)" != \
      'PAGE_ALIGNMENT_16K' ]]; then
  fail "release AAB must request PAGE_ALIGNMENT_16K; see $AAB_CONFIG_FILE"
fi
python3 - "$AUDIT_KEYSTORE_PASSWORD_FILE" <<'PY'
from pathlib import Path
import secrets
import sys

output = Path(sys.argv[1])
if output.exists() or output.is_symlink():
    raise SystemExit("refusing to replace audit-only keystore password file")
output.write_text(secrets.token_urlsafe(32) + "\n", encoding="ascii")
PY
chmod 600 "$AUDIT_KEYSTORE_PASSWORD_FILE"
keytool -genkeypair \
  -alias skybridge-aab-audit \
  -keystore "$AUDIT_KEYSTORE_PATH" \
  -storetype PKCS12 \
  -storepass:file "$AUDIT_KEYSTORE_PASSWORD_FILE" \
  -keypass:file "$AUDIT_KEYSTORE_PASSWORD_FILE" \
  -keyalg RSA \
  -keysize 2048 \
  -validity 1 \
  -dname 'CN=SkyBridge AAB Audit Only' \
  -noprompt >/dev/null 2>"$AUDIT_SIGNING_DIR/keytool.stderr.txt" || {
  fail "could not create the isolated audit-only universal APK key"
}
java -jar "$BUNDLETOOL_PATH" build-apks \
  --bundle="$AAB_PATH" \
  --output="$APKS_PATH" \
  --mode=universal \
  --ks="$AUDIT_KEYSTORE_PATH" \
  --ks-pass="file:$AUDIT_KEYSTORE_PASSWORD_FILE" \
  --ks-key-alias=skybridge-aab-audit \
  --key-pass="file:$AUDIT_KEYSTORE_PASSWORD_FILE" \
  >/dev/null 2>"$RUN_DIR/bundletool-build-apks.stderr.txt" || {
  fail "bundletool could not generate the audit-only universal APK"
}
android_inspect_generated_apks_archive "$APKS_PATH" "$APKS_CONTENTS_FILE"
android_extract_archive_entry "$APKS_PATH" "universal.apk" "$UNIVERSAL_APK_PATH"
android_inspect_apk_archive "$UNIVERSAL_APK_PATH" "$APK_CONTENTS_FILE"

SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
BUILD_TOOLS_DIR="$SDK_ROOT/build-tools/37.0.0"
AAPT="${ANDROID_AAPT:-$BUILD_TOOLS_DIR/aapt}"
APKSIGNER="${ANDROID_APKSIGNER:-$BUILD_TOOLS_DIR/apksigner}"
ZIPALIGN="${ANDROID_ZIPALIGN:-$BUILD_TOOLS_DIR/zipalign}"
NDK_VERSION="30.0.14904198"
case "$(uname -s)" in
  Darwin) NDK_HOST_PREBUILT="darwin-x86_64" ;;
  Linux) NDK_HOST_PREBUILT="linux-x86_64" ;;
  *) fail "unsupported NDK host operating system: $(uname -s)" ;;
esac
LLVM_OBJDUMP="${ANDROID_LLVM_OBJDUMP:-$SDK_ROOT/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/$NDK_HOST_PREBUILT/bin/llvm-objdump}"
[[ -x "$AAPT" ]] || fail "aapt 37.0.0 is unavailable: $AAPT"
[[ -x "$APKSIGNER" ]] || fail "apksigner 37.0.0 is unavailable: $APKSIGNER"
[[ -x "$ZIPALIGN" ]] || fail "zipalign 37.0.0 is unavailable: $ZIPALIGN"
[[ -x "$LLVM_OBJDUMP" ]] || {
  fail "NDK $NDK_VERSION llvm-objdump is unavailable: $LLVM_OBJDUMP"
}

"$ZIPALIGN" -c -P 16 -v 4 "$UNIVERSAL_APK_PATH" >"$APK_ZIPALIGN_FILE" 2>&1 || {
  fail "universal APK native libraries are not 16 KB ZIP aligned; see $APK_ZIPALIGN_FILE"
}
android_audit_apk_elf_page_alignment \
  "$UNIVERSAL_APK_PATH" "$LLVM_OBJDUMP" "$APK_ELF_ALIGNMENT_FILE" || {
  fail "universal APK has incompatible 64-bit ELF PT_LOAD alignment; see $APK_ELF_ALIGNMENT_FILE"
}

"$AAPT" dump badging "$UNIVERSAL_APK_PATH" >"$BADGING_FILE"
"$AAPT" dump permissions "$UNIVERSAL_APK_PATH" >"$PERMISSIONS_FILE"
"$AAPT" dump xmltree "$UNIVERSAL_APK_PATH" AndroidManifest.xml >"$MANIFEST_TREE_FILE"
"$APKSIGNER" verify --verbose --print-certs "$UNIVERSAL_APK_PATH" >"$APK_SIGNING_FILE"
android_list_apk_dex_classes "$UNIVERSAL_APK_PATH" "$APK_CLASSES_FILE"

declare -a FORBIDDEN_HOST_CLASSES=(
  "com.skybridge.compass.android.remote.host.AndroidRemoteControlHostService"
  "com.skybridge.compass.android.remote.host.AndroidRemoteHostVideoEncoder"
  "com.skybridge.compass.android.remote.host.AndroidRemoteHostStreamPlan"
  "com.skybridge.compass.remotecontrol.host.AndroidRemoteControlHostService"
  "com.skybridge.compass.remotecontrol.host.AndroidRemoteHostVideoEncoder"
  "com.skybridge.compass.remotecontrol.host.AndroidRemoteHostStreamPlan"
  "com.skybridge.compass.remotecontrol.service.RemoteControlAccessibilityService"
  "com.skybridge.compass.remotecontrol.execution.InputExecutionManager"
  "com.skybridge.compass.remotecontrol.capture.InputCaptureManager"
)
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
  echo "[artifact identity]"
  echo "AAB: $AAB_PATH"
  echo "Source commit: $EXPECTED_COMMIT"
  echo "R8 mapping: $MAPPING_PATH"
  echo "AAB audit metadata: $AUDIT_METADATA_PATH"
  echo "Bundletool: $BUNDLETOOL_PATH ($bundletool_version)"
  echo
  echo "[bundle structure]"
  echo "OK bundletool validate"
  echo "OK AAB requests PAGE_ALIGNMENT_16K"
  echo "OK modules: base only"
  echo "OK universal APK generated with an isolated audit-only key and verified"
  echo "OK universal APK passes zipalign -c -P 16 -v 4"
  echo "OK NDK llvm-objdump reports every arm64-v8a/x86_64 ELF PT_LOAD p_align >= 0x4000"
  echo "INFO 32-bit ELF alignments are recorded but are not a blocking 16 KB requirement"
  echo
  echo "[release metadata]"
  if rg -q \
      "^package: name='$EXPECTED_PACKAGE_NAME' versionCode='$EXPECTED_VERSION_CODE' versionName='$EXPECTED_VERSION_NAME'" \
      "$BADGING_FILE"; then
    echo "OK release identity $EXPECTED_PACKAGE_NAME $EXPECTED_VERSION_NAME ($EXPECTED_VERSION_CODE)"
  else
    echo "FAIL package/version mismatch"
    status=1
  fi
  echo
  echo "[viewer/client-only boundary]"
  if android_packaging_forbidden_placeholder_key_present "$AAB_CONTENTS_FILE" || \
      android_packaging_forbidden_placeholder_key_present "$APK_CONTENTS_FILE"; then
    echo "FAIL deprecated placeholder pin-verification key is packaged"
    status=1
  else
    echo "OK deprecated placeholder pin-verification key absent from AAB and universal APK"
  fi
  if android_r8_original_class_prefix_present \
      "$MAPPING_PATH" 'com.skybridge.compass.remotecontrol.'; then
    echo "FAIL R8 mapping contains classes from the excluded :remote-control module"
    status=1
  elif rg -q '^com/skybridge/compass/remotecontrol/' "$APK_CLASSES_FILE"; then
    echo "FAIL DEX contains unobfuscated classes from the excluded :remote-control module"
    status=1
  else
    echo "OK excluded :remote-control module absent from R8 mapping and DEX"
  fi
  for class_name in "${FORBIDDEN_HOST_CLASSES[@]}"; do
    original_descriptor="${class_name//./\/}"
    mapped_name="$(android_r8_mapped_class_name "$MAPPING_PATH" "$class_name")"
    if android_dex_class_or_nested_present "$APK_CLASSES_FILE" "$original_descriptor"; then
      echo "FAIL present $class_name without obfuscation"
      status=1
    elif [[ -n "$mapped_name" ]]; then
      descriptor="${mapped_name//./\/}"
      if android_dex_class_or_nested_present "$APK_CLASSES_FILE" "$descriptor"; then
        echo "FAIL present $class_name as R8 class $mapped_name"
        status=1
      else
        echo "OK absent $class_name (mapping-aware)"
      fi
    else
      echo "OK absent $class_name (original and mapping-aware)"
    fi
  done
  for permission_name in "${FORBIDDEN_PERMISSIONS[@]}"; do
    if android_packaging_forbidden_permission_present "$PERMISSIONS_FILE" "$permission_name"; then
      echo "FAIL present $permission_name"
      status=1
    else
      echo "OK absent $permission_name"
    fi
  done
  if android_packaging_forbidden_manifest_surface_present "$MANIFEST_TREE_FILE"; then
    echo "FAIL present Accessibility or MediaProjection manifest surface"
    status=1
  else
    echo "OK absent Accessibility and MediaProjection manifest surface"
  fi
  echo
  echo "[required payload]"
  if rg -q '^lib/(arm64-v8a|armeabi-v7a|x86|x86_64)/libjingle_peerconnection_so\.so$' \
      "$APK_CONTENTS_FILE"; then
    echo "OK WebRTC native ABI present"
  else
    echo "FAIL WebRTC native ABI missing"
    status=1
  fi
  if rg -Fqx 'assets/third_party_licenses/webrtc-sdk.txt' "$APK_CONTENTS_FILE"; then
    echo "OK WebRTC third-party notice packaged"
  else
    echo "FAIL WebRTC third-party notice missing"
    status=1
  fi
  if rg -Fqx 'assets/third_party_licenses/liboqs.txt' "$APK_CONTENTS_FILE"; then
    echo "OK liboqs third-party notice packaged"
  else
    echo "FAIL liboqs third-party notice missing"
    status=1
  fi
  if rg -Fqx 'assets/skybridge-release/source.properties' "$APK_CONTENTS_FILE"; then
    echo "OK release source binding packaged"
  else
    echo "FAIL release source binding missing from universal APK"
    status=1
  fi
  echo
  echo "[signing scope]"
  echo "OK AAB upload certificate SHA-256: ${actual_upload_cert_sha256^^}"
  echo "NOT PROVEN Google Play app-signing/distribution certificate"
  echo "NOT PROVEN runtime on a device/emulator with a 16 KB kernel page size"
} >"$SUMMARY_FILE"

cat "$SUMMARY_FILE"
if [[ "$status" -ne 0 ]]; then
  fail "packaged viewer/client-only policy failed; see $SUMMARY_FILE"
fi

echo "Android formal AAB gate passed for the upload artifact only."
echo "Google Play distribution identity remains a separate release gate."
echo "Audit directory: $RUN_DIR"
