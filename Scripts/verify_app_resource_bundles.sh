#!/usr/bin/env bash
set -euo pipefail

# verify_app_resource_bundles.sh — release gate against the zh-Hans launch-crash class.
#
# Root cause guarded here: the SwiftPM-generated `Bundle.module` accessor traps
# (`fatalError("could not load resource bundle: ...")`) whenever the
# `<Package>_<Target>.bundle` directory it references cannot be found at
# runtime. The Aug 2026 1.0.0 DMG shipped a `swift build` executable whose
# accessor only probed the .app ROOT plus the build machine's
# /tmp/skybridge-swiftpm-release-arm64 scratch dir, so every zh-Hans user hit a
# 100% SIGTRAP at launch even though the bundle was correctly staged under
# Contents/Resources.
#
# This gate is cheap (strings + grep) and fails the package when:
#   1. any `<Package>_<Target>.bundle` name referenced by the app executable is
#      missing from <app>/Contents/Resources;
#   2. the canonical SkyBridge module bundles are missing outright;
#   3. the executable does not contain the non-trapping resolver marker
#      `SkyBridgeResourceBundleLocator/v1` (i.e. the binary would still rely on
#      the trapping SwiftPM accessor for localization/shader lookups).
#
# Usage:
#   Scripts/verify_app_resource_bundles.sh "/path/to/SkyBridge Compass Pro.app"
#
# Environment:
#   SKYBRIDGE_RESOURCE_BUNDLE_GATE_IGNORE
#     Optional space-separated bundle names to exempt from check 1 (escape
#     hatch for false-positive strings matches; canonical bundles can never be
#     exempted).

GATE_TAG="[resource-bundle-gate]"

fail() {
  echo "${GATE_TAG} ERROR: $1" >&2
  exit 1
}

log() {
  echo "${GATE_TAG} $1"
}

[[ $# -eq 1 ]] || fail "usage: $0 <path-to-.app>"
APP_PATH="$1"
[[ -d "${APP_PATH}" ]] || fail "app bundle not found: ${APP_PATH}"

INFO_PLIST="${APP_PATH}/Contents/Info.plist"
[[ -f "${INFO_PLIST}" ]] || fail "missing Info.plist: ${INFO_PLIST}"

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${INFO_PLIST}" 2>/dev/null || true)"
[[ -n "${EXECUTABLE_NAME}" ]] || fail "Info.plist is missing CFBundleExecutable"

EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
[[ -x "${EXECUTABLE_PATH}" ]] || fail "main executable is missing or not executable: ${EXECUTABLE_PATH}"

RESOURCES_DIR="${APP_PATH}/Contents/Resources"
[[ -d "${RESOURCES_DIR}" ]] || fail "missing Contents/Resources: ${RESOURCES_DIR}"

# Canonical SwiftPM module bundles for this package. `SkyBridgeCompassApp` is
# the root Package.swift `name:`; renaming the package or targets changes these
# names, and this list must be updated together with
# Sources/SkyBridgeCore/Localization/SkyBridgeResourceBundleLocator.swift.
CANONICAL_BUNDLES=(
  "SkyBridgeCompassApp_SkyBridgeCompassApp.bundle"
  "SkyBridgeCompassApp_SkyBridgeCore.bundle"
)

RESOLVER_MARKER="SkyBridgeResourceBundleLocator/v1"

EXECUTABLE_STRINGS="$(/usr/bin/strings -a "${EXECUTABLE_PATH}")"

# --- Check 1: every referenced <Package>_<Target>.bundle must be staged. ---
REFERENCED_BUNDLES="$(printf '%s\n' "${EXECUTABLE_STRINGS}" \
  | LC_ALL=C /usr/bin/grep -oE '[A-Za-z0-9][A-Za-z0-9.+-]*_[A-Za-z0-9]+\.bundle' \
  | LC_ALL=C sort -u || true)"

IGNORED_BUNDLES=" ${SKYBRIDGE_RESOURCE_BUNDLE_GATE_IGNORE:-} "

missing=0
while IFS= read -r bundle_name; do
  [[ -n "${bundle_name}" ]] || continue
  if [[ "${IGNORED_BUNDLES}" == *" ${bundle_name} "* ]]; then
    is_canonical=0
    for canonical in "${CANONICAL_BUNDLES[@]}"; do
      [[ "${bundle_name}" == "${canonical}" ]] && is_canonical=1
    done
    if [[ "${is_canonical}" -eq 0 ]]; then
      log "ignoring exempted bundle reference: ${bundle_name}"
      continue
    fi
    log "refusing to exempt canonical bundle: ${bundle_name}"
  fi
  if [[ ! -d "${RESOURCES_DIR}/${bundle_name}" ]]; then
    echo "${GATE_TAG} ERROR: executable references ${bundle_name} but it is not staged under Contents/Resources" >&2
    missing=1
  else
    log "referenced bundle staged: ${bundle_name}"
  fi
done <<< "${REFERENCED_BUNDLES}"
[[ "${missing}" -eq 0 ]] || fail "one or more referenced resource bundles are missing from ${RESOURCES_DIR}"

# --- Check 2: canonical bundles must exist regardless of strings output. ---
for canonical in "${CANONICAL_BUNDLES[@]}"; do
  [[ -d "${RESOURCES_DIR}/${canonical}" ]] \
    || fail "canonical module bundle missing from Contents/Resources: ${canonical}"
done

# --- Check 3: the non-trapping resolver must be compiled into the binary. ---
# Herestring instead of printf|grep: `grep -q` exits on first match, which
# SIGPIPEs the printf under `set -o pipefail` and turns a FOUND marker into a
# spurious failure.
if ! LC_ALL=C /usr/bin/grep -qF "${RESOLVER_MARKER}" <<< "${EXECUTABLE_STRINGS}"; then
  fail "executable is missing the ${RESOLVER_MARKER} marker; localization/shader lookups would rely on the trapping SwiftPM Bundle.module accessor (zh-Hans launch-crash class)"
fi
log "non-trapping resolver marker present: ${RESOLVER_MARKER}"

log "OK: resource bundle presence verified for ${APP_PATH}"
