#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SCRIPT="${ROOT_DIR}/Scripts/check_ios_test_configuration.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  echo "[test-ios-test-config] $1" >&2
  exit 1
}

make_fixture() {
  local name="$1"
  local fixture_root="${TMP_DIR}/${name}"
  mkdir -p "${fixture_root}/SkyBridge Compass iOS"
  cp -R "${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj" "${fixture_root}/SkyBridge Compass iOS/"
  cp -R "${ROOT_DIR}/SkyBridge Compass iOS/SkyBridgeCompassiOSTests" "${fixture_root}/SkyBridge Compass iOS/"
  cp "${ROOT_DIR}/SkyBridge Compass iOS/project.yml" "${fixture_root}/SkyBridge Compass iOS/project.yml"
  printf '%s\n' "${fixture_root}"
}

expect_failure_contains() {
  local description="$1"
  local expected_fragment="$2"
  shift 2

  local output=""
  local status=0
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    fail "${description}: expected failure but command succeeded"
  fi
  if [[ "${output}" != *"${expected_fragment}"* ]]; then
    printf '%s\n' "${output}" >&2
    fail "${description}: expected output to contain '${expected_fragment}'"
  fi
}

positive_root="$(make_fixture positive)"
bash "${CHECK_SCRIPT}" --root "${positive_root}" --static-only >/dev/null \
  || fail "positive fixture should pass static validation"

missing_membership_root="$(make_fixture missing-membership)"
cat > "${missing_membership_root}/SkyBridge Compass iOS/SkyBridgeCompassiOSTests/GuardProbeTests.swift" <<'EOF'
import XCTest

final class GuardProbeTests: XCTestCase {}
EOF
expect_failure_contains \
  "new test file without target membership" \
  "GuardProbeTests.swift 未加入 project.pbxproj 文件引用" \
  bash "${CHECK_SCRIPT}" --root "${missing_membership_root}" --static-only

project_yaml_root="$(make_fixture broken-project-yaml)"
python3 - "${project_yaml_root}/SkyBridge Compass iOS/project.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "        SkyBridgeCompass-iOS: [test]\n"
if needle not in text:
    raise SystemExit("missing test-scheme host-app line in project.yml fixture")
path.write_text(text.replace(needle, "", 1), encoding="utf-8")
PY
expect_failure_contains \
  "project.yml host app omitted from test scheme" \
  "project.yml 的 SkyBridgeCompassiOSTests scheme 未将宿主 app 纳入 build targets" \
  bash "${CHECK_SCRIPT}" --root "${project_yaml_root}" --static-only

launch_action_root="$(make_fixture broken-launch-action)"
python3 - "${launch_action_root}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj/xcshareddata/xcschemes/SkyBridgeCompassiOSTests.xcscheme" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

path = Path(sys.argv[1])
tree = ET.parse(path)
root = tree.getroot()
testable_ref = root.find("./TestAction/Testables/TestableReference/BuildableReference")
launch_ref = root.find("./LaunchAction/BuildableProductRunnable/BuildableReference")
if launch_ref is None:
    launch_ref = root.find("./LaunchAction/MacroExpansion/BuildableReference")
if testable_ref is None or launch_ref is None:
    raise SystemExit("missing required scheme nodes in launch-action fixture")

for key in ("BlueprintIdentifier", "BuildableName", "BlueprintName"):
    launch_ref.set(key, testable_ref.get(key, ""))

tree.write(path, encoding="utf-8", xml_declaration=True)
PY
expect_failure_contains \
  "launch action drifted to test bundle" \
  "SkyBridgeCompassiOSTests.xcscheme 的 LaunchAction 必须指向宿主 app" \
  bash "${CHECK_SCRIPT}" --root "${launch_action_root}" --static-only

echo "[test-ios-test-config] passed"
