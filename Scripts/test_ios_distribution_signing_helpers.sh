#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-ios-signing-helper-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
chmod 0700 "$TMP_DIR"

fail() {
  echo "[test-ios-distribution-signing-helpers] $1" >&2
  exit 1
}

cd "$ROOT_DIR"
source Scripts/ios_distribution_signing_helpers.sh

PROJECT_PATH="$TMP_DIR/SkyBridge.xcodeproj"
ARCHIVE_PATH="$TMP_DIR/SkyBridge.xcarchive"
DERIVED_DATA_PATH="$TMP_DIR/DerivedData"
ARCHIVE_LOG="$TMP_DIR/archive.log"
ARCHIVE_ARGUMENTS="$TMP_DIR/archive-arguments.txt"
ARCHIVE_ENVIRONMENT="$TMP_DIR/archive-environment.txt"
mkdir "$PROJECT_PATH"

skybridge_run_xcodebuild() {
  printf '%s\n' "$@" >"$ARCHIVE_ARGUMENTS"
  printf 'identity=%s\nprofile=%s\nspecifier=%s\n' \
    "${CODE_SIGN_IDENTITY-unset}" \
    "${PROVISIONING_PROFILE-unset}" \
    "${PROVISIONING_PROFILE_SPECIFIER-unset}" \
    >"$ARCHIVE_ENVIRONMENT"
  local argument
  local next_is_archive=0
  for argument in "$@"; do
    if (( next_is_archive == 1 )); then
      mkdir -p "$argument"
      : >"$argument/Info.plist"
      next_is_archive=0
    elif [[ "$argument" == "-archivePath" ]]; then
      next_is_archive=1
    fi
  done
  return 0
}

CODE_SIGN_IDENTITY=caller-identity \
PROVISIONING_PROFILE=caller-profile \
PROVISIONING_PROFILE_SPECIFIER=caller-specifier \
skybridge_archive_ios_distribution_product \
  "$PROJECT_PATH" \
  SkyBridge \
  "$ARCHIVE_PATH" \
  "$DERIVED_DATA_PATH" \
  "$ARCHIVE_LOG" \
  installed-only \
  -- \
  DEVELOPMENT_TEAM=TEAM123 \
  SKYBRIDGE_PACKAGING_PRODUCT_SURFACE=testing

grep -Fxq 'archive' "$ARCHIVE_ARGUMENTS" \
  || fail "archive command was not used"
grep -Fxq 'CODE_SIGN_STYLE=Automatic' "$ARCHIVE_ARGUMENTS" \
  || fail "archive did not force Automatic signing"
grep -Fxq 'SKYBRIDGE_IOS_APP_DISTRIBUTION_PROFILE_SPECIFIER=' "$ARCHIVE_ARGUMENTS" \
  || fail "archive did not clear the App profile override"
grep -Fxq 'SKYBRIDGE_IOS_WIDGET_DISTRIBUTION_PROFILE_SPECIFIER=' "$ARCHIVE_ARGUMENTS" \
  || fail "archive did not clear the Widget profile override"
! grep -Fq -- '-allowProvisioningUpdates' "$ARCHIVE_ARGUMENTS" \
  || fail "installed-only archive attempted a provisioning update"
grep -Fxq 'identity=unset' "$ARCHIVE_ENVIRONMENT" \
  || fail "archive inherited CODE_SIGN_IDENTITY"
grep -Fxq 'profile=unset' "$ARCHIVE_ENVIRONMENT" \
  || fail "archive inherited PROVISIONING_PROFILE"
grep -Fxq 'specifier=unset' "$ARCHIVE_ENVIRONMENT" \
  || fail "archive inherited PROVISIONING_PROFILE_SPECIFIER"

if skybridge_archive_ios_distribution_product \
  "$PROJECT_PATH" \
  SkyBridge \
  "$TMP_DIR/rejected.xcarchive" \
  "$TMP_DIR/rejected-derived" \
  "$TMP_DIR/rejected.log" \
  installed-only \
  -- \
  CODE_SIGN_STYLE=Manual \
  2>"$TMP_DIR/rejected-archive.stderr"; then
  fail "archive accepted a caller signing-style override"
fi
grep -Fxq 'Caller attempted to override the installed-only Automatic signing boundary' \
  "$TMP_DIR/rejected-archive.stderr" \
  || fail "archive rejection did not expose the signing-boundary error"

EXPORT_OPTIONS="$TMP_DIR/ExportOptions.plist"
EXPORT_DIR="$TMP_DIR/export"
EXPORT_LOG="$TMP_DIR/export.log"
EXPORT_ARGUMENTS="$TMP_DIR/export-arguments.txt"
EXPORT_ENVIRONMENT="$TMP_DIR/export-environment.txt"
plutil -create xml1 "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :method string release-testing' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :signingStyle string automatic' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :teamID string TEAM123' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :manageAppVersionAndBuildNumber bool false' "$EXPORT_OPTIONS"

xcodebuild() {
  printf '%s\n' "$@" >"$EXPORT_ARGUMENTS"
  printf 'identity=%s\nprofile=%s\nspecifier=%s\n' \
    "${CODE_SIGN_IDENTITY-unset}" \
    "${PROVISIONING_PROFILE-unset}" \
    "${PROVISIONING_PROFILE_SPECIFIER-unset}" \
    >"$EXPORT_ENVIRONMENT"
  local argument
  local next_is_export=0
  for argument in "$@"; do
    if (( next_is_export == 1 )); then
      mkdir "$argument"
      next_is_export=0
    elif [[ "$argument" == "-exportPath" ]]; then
      next_is_export=1
    fi
  done
  return 0
}

CODE_SIGN_IDENTITY=caller-identity \
PROVISIONING_PROFILE=caller-profile \
PROVISIONING_PROFILE_SPECIFIER=caller-specifier \
skybridge_export_ios_distribution_archive \
  "$ARCHIVE_PATH" \
  "$EXPORT_OPTIONS" \
  "$EXPORT_DIR" \
  "$EXPORT_LOG" \
  TEAM123 \
  installed-only

grep -Fxq -- '-exportArchive' "$EXPORT_ARGUMENTS" \
  || fail "exportArchive command was not used"
! grep -Fq -- '-allowProvisioningUpdates' "$EXPORT_ARGUMENTS" \
  || fail "installed-only export attempted a provisioning update"
grep -Fxq 'identity=unset' "$EXPORT_ENVIRONMENT" \
  || fail "export inherited CODE_SIGN_IDENTITY"
grep -Fxq 'profile=unset' "$EXPORT_ENVIRONMENT" \
  || fail "export inherited PROVISIONING_PROFILE"
grep -Fxq 'specifier=unset' "$EXPORT_ENVIRONMENT" \
  || fail "export inherited PROVISIONING_PROFILE_SPECIFIER"

INVALID_EXPORT_OPTIONS="$TMP_DIR/InvalidExportOptions.plist"
cp "$EXPORT_OPTIONS" "$INVALID_EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Set :signingStyle manual' "$INVALID_EXPORT_OPTIONS"
if skybridge_export_ios_distribution_archive \
  "$ARCHIVE_PATH" \
  "$INVALID_EXPORT_OPTIONS" \
  "$TMP_DIR/rejected-export" \
  "$TMP_DIR/rejected-export.log" \
  TEAM123 \
  installed-only \
  2>"$TMP_DIR/rejected-export.stderr"; then
  fail "export accepted a non-Automatic signing contract"
fi
grep -Fxq 'iOS export options violate the release-testing Automatic signing contract' \
  "$TMP_DIR/rejected-export.stderr" \
  || fail "export rejection did not expose the options-contract error"

echo "iOS distribution signing helper contract passed"
