#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/check_macos_release_version.sh [--expected-version <semver>]

Validates the canonical macOS release version in project.yml and every checked-in
mirror consumed by Xcode or app packaging. Prints the validated version on
standard output.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
EXPECTED_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-version)
      [[ $# -ge 2 && -n "$2" ]] || {
        echo "[release-version] ERROR: --expected-version requires a value" >&2
        exit 2
      }
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "[release-version] ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

python3 - \
  "$PROJECT_ROOT/project.yml" \
  "$PROJECT_ROOT/Sources/SkyBridgeCompassApp/Info.plist" \
  "$PROJECT_ROOT/XcodeSupport/SkyBridgeCompassMac/Info.plist" \
  "$PROJECT_ROOT/SkyBridgeWidgets.xcodeproj/project.pbxproj" \
  "$EXPECTED_VERSION" <<'PY'
import plistlib
import re
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"[release-version] ERROR: {message}")


project_path = Path(sys.argv[1])
packaging_info_path = Path(sys.argv[2])
xcode_info_path = Path(sys.argv[3])
pbxproj_path = Path(sys.argv[4])
expected_version = sys.argv[5]

try:
    project_source = project_path.read_text(encoding="utf-8")
    pbxproj_source = pbxproj_path.read_text(encoding="utf-8")
except OSError as error:
    fail(f"unable to read release version configuration: {error}")

marketing_versions = re.findall(
    r'^\s{4}MARKETING_VERSION:\s*"([^"]+)"\s*$',
    project_source,
    flags=re.MULTILINE,
)
project_build_versions = re.findall(
    r'^\s{4}CURRENT_PROJECT_VERSION:\s*"([^"]+)"\s*$',
    project_source,
    flags=re.MULTILINE,
)
if len(marketing_versions) != 1 or len(project_build_versions) != 1:
    fail("project.yml must define exactly one base MARKETING_VERSION and CURRENT_PROJECT_VERSION")

version = marketing_versions[0]
if re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version) is None:
    fail(f"project.yml MARKETING_VERSION must be strict semantic version text, got {version!r}")
if project_build_versions[0] != version:
    fail(
        "project.yml CURRENT_PROJECT_VERSION must mirror MARKETING_VERSION; "
        f"got {project_build_versions[0]!r} and {version!r}"
    )
if expected_version and expected_version != version:
    fail(f"source release version {version!r} does not match expected version {expected_version!r}")

for label, path in (
    ("packaging Info.plist", packaging_info_path),
    ("Xcode Info.plist", xcode_info_path),
):
    try:
        with path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"unable to read {label}: {error}")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        value = info.get(key)
        if value != version:
            fail(f"{label} {key} must mirror project.yml version {version!r}, got {value!r}")

for setting_name in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
    values = re.findall(
        rf'^\s*{setting_name}\s*=\s*([^;]+);\s*$',
        pbxproj_source,
        flags=re.MULTILINE,
    )
    if len(values) != 2:
        fail(f"Xcode project must contain exactly two generated {setting_name} mirrors, found {len(values)}")
    normalized_values = [value.strip().strip('"') for value in values]
    if any(value != version for value in normalized_values):
        fail(
            f"Xcode project {setting_name} mirrors must all equal {version!r}, "
            f"got {normalized_values!r}"
        )

print(version)
PY
