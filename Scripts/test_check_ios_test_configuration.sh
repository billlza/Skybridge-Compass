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
  cp -R "${ROOT_DIR}/SkyBridgeWidgets.xcodeproj" "${fixture_root}/SkyBridgeWidgets.xcodeproj"
  cp "${ROOT_DIR}/project.yml" "${fixture_root}/project.yml"
  cp "${ROOT_DIR}/SkyBridge Compass iOS/project.yml" "${fixture_root}/SkyBridge Compass iOS/project.yml"
  cp "${ROOT_DIR}/SkyBridge Compass iOS/Package.swift" "${fixture_root}/SkyBridge Compass iOS/Package.swift"
  mkdir -p "${fixture_root}/SkyBridge Compass iOS/Scripts"
  cp "${ROOT_DIR}/SkyBridge Compass iOS/Scripts/test_lane_ios.sh" "${fixture_root}/SkyBridge Compass iOS/Scripts/test_lane_ios.sh"
  cp "${ROOT_DIR}/SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh" "${fixture_root}/SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh"
  cp "${ROOT_DIR}/Package.swift" "${fixture_root}/Package.swift"
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

remove_warning_setting_from_stage() {
  local script_path="$1"
  local stage_style="$2"
  local stage="$3"
  local setting="$4"

  python3 - "${script_path}" "${stage_style}" "${stage}" "${setting}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
stage_style = sys.argv[2]
stage = sys.argv[3]
setting = sys.argv[4]
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)

candidate_ranges: list[tuple[int, int]] = []
if stage_style == "continued-command":
    for start, line in enumerate(lines):
        if line.strip() != "run_xcodebuild_with_retry \\":
            continue
        for end in range(start + 1, len(lines)):
            candidate_stage = lines[end].strip()
            if candidate_stage not in ("build-for-testing", "test-without-building"):
                continue
            if candidate_stage == stage:
                candidate_ranges.append((start, end + 1))
            break
elif stage_style == "array-append":
    for start, line in enumerate(lines):
        if not line.strip().endswith("_args+=("):
            continue
        for end in range(start + 1, len(lines)):
            if lines[end].strip() != ")":
                continue
            if any(candidate.strip() == stage for candidate in lines[start:end]):
                candidate_ranges.append((start, end + 1))
            break
else:
    raise SystemExit(f"unsupported stage style: {stage_style}")

if len(candidate_ranges) != 1:
    raise SystemExit(
        f"expected one {stage_style} block for {stage}, found {len(candidate_ranges)}"
    )

start, end = candidate_ranges[0]
matching_indexes = [
    index
    for index in range(start, end)
    if lines[index].strip().removesuffix("\\").strip() == setting
]
if len(matching_indexes) != 1:
    raise SystemExit(
        f"expected one {setting} in {stage}, found {len(matching_indexes)}"
    )

del lines[matching_indexes[0]]
path.write_text("".join(lines), encoding="utf-8")
PY
}

positive_root="$(make_fixture positive)"
bash "${CHECK_SCRIPT}" --root "${positive_root}" --static-only >/dev/null \
  || fail "positive fixture should pass static validation"

automatic_webrtc_runtime_root="$(make_fixture automatic-webrtc-runtime)"
python3 - "${automatic_webrtc_runtime_root}/Package.swift" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = '''        .library(
            name: "SkyBridgeWebRTCRuntime",
            type: .static,
            targets: ["SkyBridgeProtocolCore", "SkyBridgeWebRTCRuntime"]
        ),
'''
replacement = '''        .library(
            name: "SkyBridgeWebRTCRuntime",
            targets: ["SkyBridgeProtocolCore", "SkyBridgeWebRTCRuntime"]
        ),
'''
if needle not in text:
    raise SystemExit("missing explicit static WebRTC runtime product in fixture")
path.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
PY
expect_failure_contains \
  "automatic WebRTC runtime product rejected" \
  "根 Package.swift 必须声明显式 static SkyBridgeWebRTCRuntime 聚合产品" \
  bash "${CHECK_SCRIPT}" --root "${automatic_webrtc_runtime_root}" --static-only

linked_hosted_runtime_root="$(make_fixture linked-hosted-runtime)"
python3 - "${linked_hosted_runtime_root}/SkyBridge Compass iOS/project.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = '''      - package: SkyBridgeRoot
        product: SkyBridgeWebRTCRuntime
        link: false
        embed: false
'''
replacement = '''      - package: SkyBridgeRoot
        product: SkyBridgeWebRTCRuntime
'''
if needle not in text:
    raise SystemExit("missing hosted-test non-linking runtime dependency in fixture")
path.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
PY
expect_failure_contains \
  "hosted test must not relink shared runtime" \
  "project.yml 的 hosted tests 必须以 link:false/embed:false 依赖 SkyBridgeWebRTCRuntime" \
  bash "${CHECK_SCRIPT}" --root "${linked_hosted_runtime_root}" --static-only

missing_simulator_build_swift_gate_root="$(make_fixture missing-simulator-build-swift-gate)"
remove_warning_setting_from_stage \
  "${missing_simulator_build_swift_gate_root}/SkyBridge Compass iOS/Scripts/test_lane_ios.sh" \
  continued-command \
  build-for-testing \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
expect_failure_contains \
  "simulator build stage missing Swift warnings-as-errors" \
  "iOS 模拟器 XCTest lane 的 build-for-testing 阶段必须设置 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" \
  bash "${CHECK_SCRIPT}" --root "${missing_simulator_build_swift_gate_root}" --static-only

missing_simulator_test_clang_gate_root="$(make_fixture missing-simulator-test-clang-gate)"
remove_warning_setting_from_stage \
  "${missing_simulator_test_clang_gate_root}/SkyBridge Compass iOS/Scripts/test_lane_ios.sh" \
  continued-command \
  test-without-building \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES
expect_failure_contains \
  "simulator test stage missing Clang warnings-as-errors" \
  "iOS 模拟器 XCTest lane 的 test-without-building 阶段必须设置 GCC_TREAT_WARNINGS_AS_ERRORS=YES" \
  bash "${CHECK_SCRIPT}" --root "${missing_simulator_test_clang_gate_root}" --static-only

missing_simulator_pqc_gate_root="$(make_fixture missing-simulator-pqc-gate)"
remove_warning_setting_from_stage \
  "${missing_simulator_pqc_gate_root}/SkyBridge Compass iOS/Scripts/test_lane_ios.sh" \
  continued-command \
  test-without-building \
  SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK
expect_failure_contains \
  "simulator test stage missing probe-authorized Apple PQC condition" \
  "iOS 模拟器 XCTest lane 的 test-without-building 阶段必须在 symbol probe 后启用 HAS_APPLE_PQC_SDK" \
  bash "${CHECK_SCRIPT}" --root "${missing_simulator_pqc_gate_root}" --static-only

missing_device_build_clang_gate_root="$(make_fixture missing-device-build-clang-gate)"
remove_warning_setting_from_stage \
  "${missing_device_build_clang_gate_root}/SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh" \
  array-append \
  build-for-testing \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES
expect_failure_contains \
  "device build stage missing Clang warnings-as-errors" \
  "iOS 真机 XCTest lane 的 build-for-testing 阶段必须设置 GCC_TREAT_WARNINGS_AS_ERRORS=YES" \
  bash "${CHECK_SCRIPT}" --root "${missing_device_build_clang_gate_root}" --static-only

missing_device_test_swift_gate_root="$(make_fixture missing-device-test-swift-gate)"
remove_warning_setting_from_stage \
  "${missing_device_test_swift_gate_root}/SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh" \
  array-append \
  test-without-building \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
expect_failure_contains \
  "device test stage missing Swift warnings-as-errors" \
  "iOS 真机 XCTest lane 的 test-without-building 阶段必须设置 SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" \
  bash "${CHECK_SCRIPT}" --root "${missing_device_test_swift_gate_root}" --static-only

missing_simulator_locked_packages_root="$(make_fixture missing-simulator-locked-packages)"
remove_warning_setting_from_stage \
  "${missing_simulator_locked_packages_root}/SkyBridge Compass iOS/Scripts/test_lane_ios.sh" \
  continued-command \
  build-for-testing \
  -disableAutomaticPackageResolution
expect_failure_contains \
  "simulator build stage permits automatic package resolution" \
  "iOS 模拟器 XCTest lane 的 build-for-testing 阶段必须设置 -disableAutomaticPackageResolution" \
  bash "${CHECK_SCRIPT}" --root "${missing_simulator_locked_packages_root}" --static-only

missing_device_package_updates_root="$(make_fixture missing-device-package-updates)"
remove_warning_setting_from_stage \
  "${missing_device_package_updates_root}/SkyBridge Compass iOS/Scripts/test_lane_ios_device.sh" \
  array-append \
  test-without-building \
  -skipPackageUpdates
expect_failure_contains \
  "device test stage permits package updates" \
  "iOS 真机 XCTest lane 的 test-without-building 阶段必须设置 -skipPackageUpdates" \
  bash "${CHECK_SCRIPT}" --root "${missing_device_package_updates_root}" --static-only

missing_pqc_sdk_root="$(make_fixture missing-pqc-sdk-setting)"
python3 - "${missing_pqc_sdk_root}/SkyBridge Compass iOS/project.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = '        SKYBRIDGE_APPLE_PQC_SDK_CONDITION: ""\n'
if needle not in text:
    raise SystemExit("missing Apple PQC build setting in project.yml fixture")
path.write_text(text.replace(needle, "", 1), encoding="utf-8")
PY
expect_failure_contains \
  "project.yml missing Apple PQC explicit build setting" \
  "project.yml 的 app/test target 必须声明空的 SKYBRIDGE_APPLE_PQC_SDK_CONDITION 默认值" \
  bash "${CHECK_SCRIPT}" --root "${missing_pqc_sdk_root}" --static-only

forbidden_pqc_yml_root="$(make_fixture forbidden-pqc-sdk-selector-yml)"
python3 - "${forbidden_pqc_yml_root}/SkyBridge Compass iOS/project.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = '        SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) $(SKYBRIDGE_APPLE_PQC_SDK_CONDITION)"\n'
if needle not in text:
    raise SystemExit("missing Swift compilation condition line in project.yml fixture")
replacement = needle + '        SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos27*]: "$(inherited) HAS_APPLE_PQC_SDK"\n'
path.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
PY
expect_failure_contains \
  "project.yml rejects SDK-selector Apple PQC gate" \
  "project.yml 不得使用 SDK selector 默认启用 HAS_APPLE_PQC_SDK" \
  bash "${CHECK_SCRIPT}" --root "${forbidden_pqc_yml_root}" --static-only

forbidden_pqc_pbxproj_root="$(make_fixture forbidden-pqc-sdk-selector-pbxproj)"
python3 - "${forbidden_pqc_pbxproj_root}/SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import sys

import re

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
# Match the condition line by content and capture its actual indentation. Xcode
# rewrites pbxproj indentation when the project is edited, so pinning an exact
# tab count made this fixture break on an unrelated reformat instead of on a
# real policy regression.
pattern = re.compile(
    r'^([ \t]*)SWIFT_ACTIVE_COMPILATION_CONDITIONS = '
    r'"\$\(inherited\) \$\(SKYBRIDGE_APPLE_PQC_SDK_CONDITION\)";\n',
    re.MULTILINE,
)
match = pattern.search(text)
if match is None:
    raise SystemExit("missing Swift compilation condition line in project.pbxproj fixture")
indent = match.group(1)
replacement = match.group(0) + (
    f'{indent}"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphonesimulator27*]" = '
    '"$(inherited) HAS_APPLE_PQC_SDK";\n'
)
path.write_text(text[: match.start()] + replacement + text[match.end() :], encoding="utf-8")
PY
expect_failure_contains \
  "project.pbxproj rejects SDK-selector Apple PQC gate" \
  "project.pbxproj 不得使用 SDK selector 默认启用 HAS_APPLE_PQC_SDK" \
  bash "${CHECK_SCRIPT}" --root "${forbidden_pqc_pbxproj_root}" --static-only

raised_deployment_root="$(make_fixture raised-deployment-target)"
python3 - "${raised_deployment_root}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
project_yml = root / "SkyBridge Compass iOS" / "project.yml"
pbxproj = root / "SkyBridge Compass iOS" / "SkyBridgeCompass-iOS.xcodeproj" / "project.pbxproj"

project_text = project_yml.read_text(encoding="utf-8")
project_text = project_text.replace('    iOS: "17.0"', '    iOS: "27.0"', 1)
project_yml.write_text(project_text, encoding="utf-8")

pbxproj_text = pbxproj.read_text(encoding="utf-8")
pbxproj_text = pbxproj_text.replace("IPHONEOS_DEPLOYMENT_TARGET = 17.0;", "IPHONEOS_DEPLOYMENT_TARGET = 27.0;", 1)
pbxproj.write_text(pbxproj_text, encoding="utf-8")
PY
expect_failure_contains \
  "iOS deployment target raised" \
  "IPHONEOS_DEPLOYMENT_TARGET 必须保持 17.0" \
  bash "${CHECK_SCRIPT}" --root "${raised_deployment_root}" --static-only

raised_macos_project_root="$(make_fixture raised-macos-project-yaml)"
python3 - "${raised_macos_project_root}/project.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace('    macOS: "14.0"', '    macOS: "27.0"', 1)
text = text.replace('    MACOSX_DEPLOYMENT_TARGET: "14.0"', '    MACOSX_DEPLOYMENT_TARGET: "27.0"', 1)
path.write_text(text, encoding="utf-8")
PY
expect_failure_contains \
  "macOS project.yml deployment target raised" \
  "根 project.yml 的 deploymentTarget.macOS 必须保持 14.0" \
  bash "${CHECK_SCRIPT}" --root "${raised_macos_project_root}" --static-only

raised_macos_pbxproj_root="$(make_fixture raised-macos-pbxproj)"
python3 - "${raised_macos_pbxproj_root}/SkyBridgeWidgets.xcodeproj/project.pbxproj" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = "MACOSX_DEPLOYMENT_TARGET = 14.0;"
if needle not in text:
    raise SystemExit("missing macOS deployment target in fixture")
path.write_text(text.replace(needle, "MACOSX_DEPLOYMENT_TARGET = 27.0;", 1), encoding="utf-8")
PY
expect_failure_contains \
  "macOS xcodeproj deployment target raised" \
  "SkyBridgeWidgets.xcodeproj 的 macOS target MACOSX_DEPLOYMENT_TARGET 必须保持 14.0" \
  bash "${CHECK_SCRIPT}" --root "${raised_macos_pbxproj_root}" --static-only

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
