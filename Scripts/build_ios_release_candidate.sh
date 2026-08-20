#!/usr/bin/env bash
# Reproducible iOS production release-candidate producer.
#
# Archives the SkyBridge Compass iOS app + embedded Widget in the Release
# configuration with Xcode-managed (Automatic) distribution signing, then
# exports a release-testing IPA. The archive is stamped with production-surface
# provenance metadata (HAS_APPLE_PQC_SDK, no DEBUG/SKYBRIDGE_TESTING, no test
# hooks) so the downstream product verifier can prove it is a production build.
#
# Fail-fast: warnings are errors; the working tree must be clean (a release
# candidate must come from a committed HEAD). No secrets are printed.
#
# Environment overrides:
#   SKYBRIDGE_RC_OUTPUT_DIR   output root (default .sandbox-home/release-candidate)
#   SKYBRIDGE_SOURCE_REPOSITORY / GITHUB_REPOSITORY   owner/repo provenance
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_PROJECT="${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
EXPORT_OPTIONS="${ROOT_DIR}/Scripts/ios_release_candidate_export_options.plist"
# shellcheck source=Scripts/apple_pqc_sdk_probe.sh
source "${ROOT_DIR}/Scripts/apple_pqc_sdk_probe.sh"

IOS_RELEASE_VERSION_RECORD="$(
  bash "${ROOT_DIR}/Scripts/check_ios_release_version.sh"
)"
IFS=$'\t' read -r IOS_RELEASE_VERSION IOS_RELEASE_BUILD <<<"${IOS_RELEASE_VERSION_RECORD}"
if [[ -z "${IOS_RELEASE_VERSION}" || ! "${IOS_RELEASE_BUILD}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[ios-release-candidate] ERROR: invalid iOS release version transaction." >&2
  exit 1
fi

REQUESTED_OUTPUT_DIR="${SKYBRIDGE_RC_OUTPUT_DIR:-${ROOT_DIR}/.sandbox-home/release-candidate}"
TEMPORARY_ROOT="${TMPDIR:-/private/tmp}"
OUTPUT_DIR="$(
  python3 "${ROOT_DIR}/Scripts/validate_release_output_directory.py" \
    --repository-root "${ROOT_DIR}" \
    --temporary-root "${TEMPORARY_ROOT}" \
    --output "${REQUESTED_OUTPUT_DIR}"
)"
ARCHIVE_PATH="${OUTPUT_DIR}/SkyBridgeCompass-iOS.xcarchive"
EXPORT_DIR="${OUTPUT_DIR}/export"
DERIVED_DATA="${OUTPUT_DIR}/DerivedData"
ARCHIVE_LOG="${OUTPUT_DIR}/archive.log"
EXPORT_LOG="${OUTPUT_DIR}/export.log"

SOURCE_REPOSITORY="${GITHUB_REPOSITORY:-${SKYBRIDGE_SOURCE_REPOSITORY:-billlza/Skybridge-Compass}}"
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
SOURCE_INPUT_DIGEST=""
SOURCE_INPUT_FILE_COUNT=""

log() { echo "[ios-release-candidate] $1"; }

compute_source_input_snapshot() {
  local snapshot digest file_count extra
  snapshot="$(
    python3 "${ROOT_DIR}/Scripts/source_input_digest.py" \
      --root "${ROOT_DIR}" \
      "${SOURCE_INPUT_PATHS[@]}"
  )"
  read -r digest file_count extra <<<"${snapshot}"
  if [[ ! "${digest}" =~ ^[0-9a-f]{64}$ || \
        ! "${file_count}" =~ ^[1-9][0-9]*$ || \
        -n "${extra}" ]]; then
    echo "[ios-release-candidate] ERROR: source-input digest tool returned malformed output." >&2
    return 1
  fi
  printf '%s %s\n' "${digest}" "${file_count}"
}

verify_source_snapshot() {
  local stage="$1"
  local current_digest current_count
  read -r current_digest current_count <<<"$(compute_source_input_snapshot)"
  if [[ "${current_digest}" != "${SOURCE_INPUT_DIGEST}" || \
        "${current_count}" != "${SOURCE_INPUT_FILE_COUNT}" ]]; then
    echo "[ios-release-candidate] ERROR: source inputs changed during ${stage}." >&2
    exit 1
  fi
  if [[ "$(git -C "${ROOT_DIR}" rev-parse HEAD)" != "${SOURCE_COMMIT}" || \
        -n "$(git -C "${ROOT_DIR}" status --porcelain=v1 --untracked-files=all)" ]]; then
    echo "[ios-release-candidate] ERROR: repository revision or cleanliness changed during ${stage}." >&2
    exit 1
  fi
}

verify_bundle_version() {
  local label="$1"
  local info_plist="$2"
  local actual_version actual_build
  actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}" 2>/dev/null || true)"
  actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${info_plist}" 2>/dev/null || true)"
  if [[ "${actual_version}" != "${IOS_RELEASE_VERSION}" || "${actual_build}" != "${IOS_RELEASE_BUILD}" ]]; then
    echo "[ios-release-candidate] ERROR: ${label} version/build mismatch: expected ${IOS_RELEASE_VERSION} (${IOS_RELEASE_BUILD}), got ${actual_version:-missing} (${actual_build:-missing})." >&2
    exit 1
  fi
}

# A release candidate must be built from a committed, clean HEAD.
if [[ -n "$(git -C "${ROOT_DIR}" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "[ios-release-candidate] ERROR: working tree is dirty; commit before producing a release candidate." >&2
  exit 1
fi
SOURCE_COMMIT="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
if [[ ! "${SOURCE_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "[ios-release-candidate] ERROR: could not resolve a full-length HEAD commit." >&2
  exit 1
fi
read -r SOURCE_INPUT_DIGEST SOURCE_INPUT_FILE_COUNT <<<"$(compute_source_input_snapshot)"

if ! skybridge_require_apple_pqc_sdk_symbol_probe iphoneos; then
  echo "[ios-release-candidate] ERROR: the selected iPhoneOS SDK cannot typecheck the required Apple CryptoKit PQC symbol set." >&2
  echo "[ios-release-candidate] ${SKYBRIDGE_PQC_PROBE_ERROR:-Apple PQC symbol probe failed without details}" >&2
  exit 1
fi
log "Apple PQC symbols verified (sdk=${SKYBRIDGE_PQC_SDK_VER}, target=${SKYBRIDGE_PQC_SWIFT_TARGET}, secure-enclave=${SKYBRIDGE_PQC_INCLUDED_SECURE_ENCLAVE})"

rm -rf -- "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(
  python3 "${ROOT_DIR}/Scripts/validate_release_output_directory.py" \
    --repository-root "${ROOT_DIR}" \
    --temporary-root "${TEMPORARY_ROOT}" \
    --output "${OUTPUT_DIR}"
)"

log "archiving ${IOS_SCHEME} (Release, production surface, Automatic signing) from ${SOURCE_COMMIT}"
xcodebuild archive \
  -project "${IOS_PROJECT}" \
  -scheme "${IOS_SCHEME}" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "${ARCHIVE_PATH}" \
  -derivedDataPath "${DERIVED_DATA}" \
  -allowProvisioningUpdates \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK \
  SKYBRIDGE_PACKAGING_SOURCE_INPUT_DIGEST="${SOURCE_INPUT_DIGEST}" \
  >"${ARCHIVE_LOG}" 2>&1
verify_source_snapshot "archive"
log "archive complete: ${ARCHIVE_PATH}"

# Stamp production-surface provenance into the archived app Info.plist before the
# export step re-signs the bundle. (INFOPLIST_KEY_* only injects Apple-recognised
# keys, not arbitrary custom keys, into an explicit Info.plist; the macOS lane in
# package_app.sh stamps provenance the same way via plutil -replace.)
ARCHIVE_APP="$(find "${ARCHIVE_PATH}/Products/Applications" -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "${ARCHIVE_APP}" || ! -d "${ARCHIVE_APP}" ]]; then
  echo "[ios-release-candidate] ERROR: archived app not found for provenance stamping." >&2
  exit 1
fi
ARCHIVE_APP_INFO="${ARCHIVE_APP}/Info.plist"
ARCHIVE_WIDGET="$(find "${ARCHIVE_APP}/PlugIns" -maxdepth 1 -name '*.appex' -print -quit)"
if [[ -z "${ARCHIVE_WIDGET}" || ! -d "${ARCHIVE_WIDGET}" ]]; then
  echo "[ios-release-candidate] ERROR: archived Widget not found for release version verification." >&2
  exit 1
fi
verify_bundle_version "archived app" "${ARCHIVE_APP_INFO}"
verify_bundle_version "archived Widget" "${ARCHIVE_WIDGET}/Info.plist"
plutil -replace SkyBridgePackagingBuildConfiguration -string "Release" "${ARCHIVE_APP_INFO}"
plutil -replace SkyBridgePackagingGitDirtyState -string "clean" "${ARCHIVE_APP_INFO}"
plutil -replace SkyBridgePackagingGitCommit -string "${SOURCE_COMMIT}" "${ARCHIVE_APP_INFO}"
plutil -replace SkyBridgePackagingSourceInputDigest -string "${SOURCE_INPUT_DIGEST}" "${ARCHIVE_APP_INFO}"
plutil -replace SkyBridgePackagingSourceRepository -string "${SOURCE_REPOSITORY}" "${ARCHIVE_APP_INFO}"
plutil -replace SkyBridgePackagingProductSurface -string "production" "${ARCHIVE_APP_INFO}"
plutil -replace SkyBridgePackagingSwiftActiveCompilationConditions -string "HAS_APPLE_PQC_SDK" "${ARCHIVE_APP_INFO}"
log "verified iOS ${IOS_RELEASE_VERSION} (${IOS_RELEASE_BUILD}) and stamped production provenance"

log "exporting release-testing IPA"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -exportPath "${EXPORT_DIR}" \
  -allowProvisioningUpdates \
  >"${EXPORT_LOG}" 2>&1
verify_source_snapshot "export"
log "export complete: ${EXPORT_DIR}"

# Surface any archive/export warnings (the build already treats them as errors,
# this is a defensive audit of the logs).
if grep -Eq '(^|[^A-Za-z])(warning|error):' "${ARCHIVE_LOG}" "${EXPORT_LOG}"; then
  echo "[ios-release-candidate] ERROR: archive/export logs contain warnings or errors." >&2
  grep -nE '(^|[^A-Za-z])(warning|error):' "${ARCHIVE_LOG}" "${EXPORT_LOG}" >&2 || true
  exit 1
fi

IPA_PATH="$(find "${EXPORT_DIR}" -maxdepth 1 -name '*.ipa' -print -quit)"
if [[ -z "${IPA_PATH}" || ! -f "${IPA_PATH}" ]]; then
  echo "[ios-release-candidate] ERROR: no IPA was exported." >&2
  exit 1
fi

log "release candidate IPA: ${IPA_PATH}"
log "sha256: $(shasum -a 256 "${IPA_PATH}" | awk '{print $1}')"
log "running formal signed-product verification"
SKYBRIDGE_RC_EXPORT_DIR="${EXPORT_DIR}" \
SKYBRIDGE_RC_ACCEPTANCE_MANIFEST="${OUTPUT_DIR}/ios-release-acceptance-sha256.json" \
python3 "${ROOT_DIR}/Scripts/verify_ios_release_candidate.py"
log "done"
