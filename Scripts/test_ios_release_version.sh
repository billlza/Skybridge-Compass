#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT_DIR/Scripts/check_ios_release_version.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p \
  "$SCRATCH/SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files" \
  "$SCRATCH/SkyBridge Compass iOS/Widgets"
cp "$ROOT_DIR/SkyBridge Compass iOS/project.yml" "$SCRATCH/SkyBridge Compass iOS/project.yml"
cp "$ROOT_DIR/SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files/Info.plist" \
  "$SCRATCH/SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files/Info.plist"
cp "$ROOT_DIR/SkyBridge Compass iOS/Widgets/Info.plist" \
  "$SCRATCH/SkyBridge Compass iOS/Widgets/Info.plist"


# The regression fixture has an explicit baseline independent of the next shipping build.
python3 - "$SCRATCH" <<'PYFIXTURE'
from pathlib import Path
import plistlib
import re
import sys

root = Path(sys.argv[1]) / "SkyBridge Compass iOS"
project = root / "project.yml"
source = project.read_text(encoding="utf-8")
source, versions = re.subn(r'(CFBundleShortVersionString:\s*)"[^"]+"', r'\g<1>"1.0.2"', source)
source, builds = re.subn(r'(CFBundleVersion:\s*)"[^"]+"', r'\g<1>"4"', source)
assert versions == 2 and builds == 2
project.write_text(source, encoding="utf-8")
for relative in ["SkyBridgeCompassiOS/Supporting Files/Info.plist", "Widgets/Info.plist"]:
    path = root / relative
    value = plistlib.loads(path.read_bytes())
    value["CFBundleShortVersionString"] = "1.0.2"
    value["CFBundleVersion"] = "4"
    path.write_bytes(plistlib.dumps(value))
PYFIXTURE

assert_rejected() {
  local description="$1"
  if "$CHECKER" --root "$SCRATCH" >/dev/null 2>&1; then
    echo "[ios-release-version-test] ERROR: accepted $description" >&2
    exit 1
  fi
}

actual="$("$CHECKER" --root "$SCRATCH" --expected-version 1.0.2 --expected-build 4)"
[[ "$actual" == $'1.0.2\t4' ]] || {
  echo "[ios-release-version-test] ERROR: unexpected checker output: $actual" >&2
  exit 1
}

/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 5' \
  "$SCRATCH/SkyBridge Compass iOS/Widgets/Info.plist"
assert_rejected "a mismatched Widget build"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 4' \
  "$SCRATCH/SkyBridge Compass iOS/Widgets/Info.plist"

/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 0' \
  "$SCRATCH/SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files/Info.plist"
assert_rejected "a non-positive app build"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 4' \
  "$SCRATCH/SkyBridge Compass iOS/SkyBridgeCompassiOS/Supporting Files/Info.plist"

python3 - "$SCRATCH/SkyBridge Compass iOS/project.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
source = source.replace('CFBundleShortVersionString: "1.0.2"', 'CFBundleShortVersionString: "1.0"', 1)
path.write_text(source, encoding="utf-8")
PY
assert_rejected "different app and Widget semantic versions"

echo "iOS release version tests passed"
