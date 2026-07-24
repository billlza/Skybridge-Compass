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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_PROJECT="${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj"
IOS_SCHEME="SkyBridgeCompass-iOS"
EXPORT_OPTIONS="${ROOT_DIR}/Scripts/ios_release_candidate_export_options.plist"

OUTPUT_DIR="${SKYBRIDGE_RC_OUTPUT_DIR:-${ROOT_DIR}/.sandbox-home/release-candidate}"
ARCHIVE_PATH="${OUTPUT_DIR}/SkyBridgeCompass-iOS.xcarchive"
EXPORT_DIR="${OUTPUT_DIR}/export"
DERIVED_DATA="${OUTPUT_DIR}/DerivedData"
ARCHIVE_LOG="${OUTPUT_DIR}/archive.log"
EXPORT_LOG="${OUTPUT_DIR}/export.log"

SOURCE_REPOSITORY="${GITHUB_REPOSITORY:-${SKYBRIDGE_SOURCE_REPOSITORY:-billlza/Skybridge-Compass}}"

log() { echo "[ios-release-candidate] $1"; }

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

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

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
  "INFOPLIST_KEY_SkyBridgePackagingBuildConfiguration=Release" \
  "INFOPLIST_KEY_SkyBridgePackagingGitDirtyState=clean" \
  "INFOPLIST_KEY_SkyBridgePackagingGitCommit=${SOURCE_COMMIT}" \
  "INFOPLIST_KEY_SkyBridgePackagingSourceRepository=${SOURCE_REPOSITORY}" \
  "INFOPLIST_KEY_SkyBridgePackagingProductSurface=production" \
  "INFOPLIST_KEY_SkyBridgePackagingSwiftActiveCompilationConditions=HAS_APPLE_PQC_SDK" \
  >"${ARCHIVE_LOG}" 2>&1
log "archive complete: ${ARCHIVE_PATH}"

log "exporting release-testing IPA"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -exportPath "${EXPORT_DIR}" \
  -allowProvisioningUpdates \
  >"${EXPORT_LOG}" 2>&1
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
log "done"
