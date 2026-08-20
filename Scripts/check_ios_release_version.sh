#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/check_ios_release_version.sh [options]

Validates the iOS app and Widget release version transaction. The user-visible
version must be strict semantic version text, while the build is an independent
positive integer. Prints "<version><TAB><build>" on success.

Options:
  --root PATH                 repository root (test-only override)
  --expected-version VERSION  require this user-visible version
  --expected-build BUILD      require this positive integer build
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
EXPECTED_VERSION=""
EXPECTED_BUILD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 && -n "$2" ]] || {
        echo "[ios-release-version] ERROR: --root requires a value" >&2
        exit 2
      }
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --expected-version)
      [[ $# -ge 2 && -n "$2" ]] || {
        echo "[ios-release-version] ERROR: --expected-version requires a value" >&2
        exit 2
      }
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    --expected-build)
      [[ $# -ge 2 && -n "$2" ]] || {
        echo "[ios-release-version] ERROR: --expected-build requires a value" >&2
        exit 2
      }
      EXPECTED_BUILD="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "[ios-release-version] ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

python3 - \
  "$PROJECT_ROOT/SkyBridge Compass iOS/project.yml" \
  "$PROJECT_ROOT/SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files/Info.plist" \
  "$PROJECT_ROOT/SkyBridge Compass iOS/Widgets/Info.plist" \
  "$EXPECTED_VERSION" \
  "$EXPECTED_BUILD" <<'PY'
import plistlib
import re
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"[ios-release-version] ERROR: {message}")


project_path = Path(sys.argv[1])
app_info_path = Path(sys.argv[2])
widget_info_path = Path(sys.argv[3])
expected_version = sys.argv[4]
expected_build = sys.argv[5]

try:
    project_source = project_path.read_text(encoding="utf-8")
except OSError as error:
    fail(f"unable to read iOS project specification: {error}")

project_versions = re.findall(
    r'^\s{8}CFBundleShortVersionString:\s*"([^"]+)"\s*$',
    project_source,
    flags=re.MULTILINE,
)
project_builds = re.findall(
    r'^\s{8}CFBundleVersion:\s*"([^"]+)"\s*$',
    project_source,
    flags=re.MULTILINE,
)
if len(project_versions) != 2 or len(project_builds) != 2:
    fail("project.yml must define app and Widget CFBundleShortVersionString/CFBundleVersion exactly once each")
if len(set(project_versions)) != 1:
    fail(f"project.yml app and Widget versions differ: {project_versions!r}")
if len(set(project_builds)) != 1:
    fail(f"project.yml app and Widget builds differ: {project_builds!r}")

version = project_versions[0]
build = project_builds[0]
if re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version) is None:
    fail(f"CFBundleShortVersionString must be strict semantic version text, got {version!r}")
if re.fullmatch(r'[1-9][0-9]*', build) is None:
    fail(f"CFBundleVersion must be a positive integer, got {build!r}")
if expected_version and version != expected_version:
    fail(f"source version {version!r} does not match expected version {expected_version!r}")
if expected_build and build != expected_build:
    fail(f"source build {build!r} does not match expected build {expected_build!r}")

for label, path in (("app", app_info_path), ("Widget", widget_info_path)):
    try:
        with path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"unable to read {label} Info.plist: {error}")
    actual_version = info.get("CFBundleShortVersionString")
    actual_build = info.get("CFBundleVersion")
    if actual_version != version:
        fail(f"{label} Info.plist version must be {version!r}, got {actual_version!r}")
    if actual_build != build:
        fail(f"{label} Info.plist build must be {build!r}, got {actual_build!r}")

print(f"{version}\t{build}")
PY
