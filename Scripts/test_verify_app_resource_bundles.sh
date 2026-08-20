#!/usr/bin/env bash
set -euo pipefail

# Tests for Scripts/verify_app_resource_bundles.sh (the zh-Hans launch-crash
# resource-bundle gate). Uses synthetic .app fixtures; `strings` extracts
# printable runs from any file, so a plain text "executable" is sufficient.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE_SCRIPT="${SCRIPT_DIR}/verify_app_resource_bundles.sh"

fail() {
  echo "[test] $1" >&2
  exit 1
}

[[ -x "${GATE_SCRIPT}" ]] || fail "gate script missing or not executable: ${GATE_SCRIPT}"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-resource-bundle-gate.XXXXXX")"
trap '/bin/rm -rf -- "${SANDBOX}"' EXIT

RESOLVER_MARKER="SkyBridgeResourceBundleLocator/v1"

make_fixture_app() {
  local app_path="$1"
  shift
  local executable_content="$1"
  shift

  mkdir -p "${app_path}/Contents/MacOS" "${app_path}/Contents/Resources"
  /usr/libexec/PlistBuddy \
    -c 'Add :CFBundleExecutable string FixtureApp' \
    "${app_path}/Contents/Info.plist" >/dev/null
  printf '%s\n' "${executable_content}" > "${app_path}/Contents/MacOS/FixtureApp"
  chmod +x "${app_path}/Contents/MacOS/FixtureApp"

  local bundle_name
  for bundle_name in "$@"; do
    mkdir -p "${app_path}/Contents/Resources/${bundle_name}"
  done
}

GOOD_STRINGS="prefix
/tmp/skybridge-swiftpm-release-arm64/arm64-apple-macosx/release/SkyBridgeCompassApp_SkyBridgeCore.bundle
SkyBridgeCompassApp_SkyBridgeCore.bundle
SkyBridgeCompassApp_SkyBridgeCompassApp.bundle
${RESOLVER_MARKER}
suffix"

# --- Case 1: fully staged app with resolver marker passes. ---
APP_OK="${SANDBOX}/ok/Fixture App.app"
make_fixture_app "${APP_OK}" "${GOOD_STRINGS}" \
  "SkyBridgeCompassApp_SkyBridgeCore.bundle" \
  "SkyBridgeCompassApp_SkyBridgeCompassApp.bundle"
"${GATE_SCRIPT}" "${APP_OK}" >/dev/null \
  || fail "gate must pass when referenced bundles are staged and the resolver marker is present"

# --- Case 2: referenced bundle missing from Resources fails. ---
APP_MISSING_REFERENCED="${SANDBOX}/missing-referenced/Fixture App.app"
make_fixture_app "${APP_MISSING_REFERENCED}" "${GOOD_STRINGS}" \
  "SkyBridgeCompassApp_SkyBridgeCompassApp.bundle"
if "${GATE_SCRIPT}" "${APP_MISSING_REFERENCED}" >/dev/null 2>&1; then
  fail "gate must fail when a referenced module bundle is missing (installed-app crash shape)"
fi

# --- Case 3: renamed package expectation (e.g. SkyBridgeRoot_*) with old
# staged names fails: the binary references a bundle that is not staged. ---
RENAMED_STRINGS="SkyBridgeRoot_SkyBridgeCore.bundle
SkyBridgeCompassApp_SkyBridgeCore.bundle
SkyBridgeCompassApp_SkyBridgeCompassApp.bundle
${RESOLVER_MARKER}"
APP_RENAMED="${SANDBOX}/renamed/Fixture App.app"
make_fixture_app "${APP_RENAMED}" "${RENAMED_STRINGS}" \
  "SkyBridgeCompassApp_SkyBridgeCore.bundle" \
  "SkyBridgeCompassApp_SkyBridgeCompassApp.bundle"
if "${GATE_SCRIPT}" "${APP_RENAMED}" >/dev/null 2>&1; then
  fail "gate must fail when the executable references a bundle name that packaging did not stage"
fi

# --- Case 4: resolver marker absent fails even with bundles staged. ---
NO_MARKER_STRINGS="SkyBridgeCompassApp_SkyBridgeCore.bundle
SkyBridgeCompassApp_SkyBridgeCompassApp.bundle
could not load resource bundle: from "
APP_NO_MARKER="${SANDBOX}/no-marker/Fixture App.app"
make_fixture_app "${APP_NO_MARKER}" "${NO_MARKER_STRINGS}" \
  "SkyBridgeCompassApp_SkyBridgeCore.bundle" \
  "SkyBridgeCompassApp_SkyBridgeCompassApp.bundle"
if "${GATE_SCRIPT}" "${APP_NO_MARKER}" >/dev/null 2>&1; then
  fail "gate must fail when the non-trapping resolver marker is absent from the executable"
fi

# --- Case 5: canonical bundle missing fails even when unreferenced. ---
MARKER_ONLY_STRINGS="${RESOLVER_MARKER}"
APP_NO_CANONICAL="${SANDBOX}/no-canonical/Fixture App.app"
make_fixture_app "${APP_NO_CANONICAL}" "${MARKER_ONLY_STRINGS}" \
  "SkyBridgeCompassApp_SkyBridgeCompassApp.bundle"
if "${GATE_SCRIPT}" "${APP_NO_CANONICAL}" >/dev/null 2>&1; then
  fail "gate must fail when a canonical module bundle is missing from Contents/Resources"
fi

# --- Case 6: ignore list exempts non-canonical false positives only. ---
FALSE_POSITIVE_STRINGS="${GOOD_STRINGS}
someother-pkg_SomeTarget.bundle"
APP_FALSE_POSITIVE="${SANDBOX}/false-positive/Fixture App.app"
make_fixture_app "${APP_FALSE_POSITIVE}" "${FALSE_POSITIVE_STRINGS}" \
  "SkyBridgeCompassApp_SkyBridgeCore.bundle" \
  "SkyBridgeCompassApp_SkyBridgeCompassApp.bundle"
if "${GATE_SCRIPT}" "${APP_FALSE_POSITIVE}" >/dev/null 2>&1; then
  fail "gate must fail on an unstaged referenced bundle even if it is third-party"
fi
SKYBRIDGE_RESOURCE_BUNDLE_GATE_IGNORE="someother-pkg_SomeTarget.bundle" \
  "${GATE_SCRIPT}" "${APP_FALSE_POSITIVE}" >/dev/null \
  || fail "gate must honour SKYBRIDGE_RESOURCE_BUNDLE_GATE_IGNORE for non-canonical names"
if SKYBRIDGE_RESOURCE_BUNDLE_GATE_IGNORE="SkyBridgeCompassApp_SkyBridgeCore.bundle" \
  "${GATE_SCRIPT}" "${APP_MISSING_REFERENCED}" >/dev/null 2>&1; then
  fail "gate must refuse to exempt canonical bundles via the ignore list"
fi

echo "[test] verify_app_resource_bundles.sh: all cases passed"
