#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_ONLY=0

usage() {
  cat <<'EOF'
用法: check_ios_test_configuration.sh [--root <path>] [--static-only]

校验 iOS Xcode 测试配置是否满足以下约束：
1. SkyBridgeCompassiOSTests 目录下的 Swift 文件都已加入测试 target Sources
2. App scheme 使用共享 test plan，且 test plan 正确引用测试 target 与宿主 app
3. 独立测试 scheme 的 BuildAction / TestAction / LaunchAction / ProfileAction 都指向正确宿主 app
4. 测试 target 保持 TEST_HOST / BUNDLE_LOADER 配置
5. 若存在 XcodeGen project.yml，则其 target / scheme 源配置也必须保持一致
6. iOS app/test target 的 Apple PQC 编译条件必须由 probe 后显式 build setting 注入，不能由 SDK selector 默认启用
7. iOS/macOS 最低部署目标不得因 OS 27 适配被抬高（含根 macOS XcodeGen 与已提交 Xcode 工程）
8. iOS 模拟器/真机 XCTest lane 的每个构建与执行阶段都必须将 Swift/Clang warning 视为 error
9. 模拟器 lane 必须先通过 Apple PQC symbol probe，并在两个阶段显式启用编译条件
10. 模拟器/真机 lane 必须严格使用 Package.resolved，禁止自动更新依赖
11. iOS WebRTC runtime 必须显式静态聚合 ProtocolCore；hosted tests 只获取模块依赖，不得二次链接
12. 默认模式下额外用 xcodebuild -showdestinations 做一次轻量动态探测
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_DIR="$2"
      shift 2
      ;;
    --static-only)
      STATIC_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ios-test-config] 未知参数: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

python3 - "$ROOT_DIR" "$STATIC_ONLY" <<'PY'
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional

root = Path(sys.argv[1]).resolve()
static_only = sys.argv[2] == "1"

project_dir = root / "SkyBridge Compass iOS" / "SkyBridgeCompass-iOS.xcodeproj"
pbxproj_path = project_dir / "project.pbxproj"
app_scheme_path = project_dir / "xcshareddata" / "xcschemes" / "SkyBridgeCompass-iOS.xcscheme"
test_scheme_path = project_dir / "xcshareddata" / "xcschemes" / "SkyBridgeCompassiOSTests.xcscheme"
test_plan_path = project_dir / "xcshareddata" / "xctestplans" / "SkyBridgeCompass-iOS-Shared.xctestplan"
project_yaml_path = root / "SkyBridge Compass iOS" / "project.yml"
root_project_yaml_path = root / "project.yml"
macos_pbxproj_path = root / "SkyBridgeWidgets.xcodeproj" / "project.pbxproj"
tests_dir = root / "SkyBridge Compass iOS" / "SkyBridgeCompassiOSTests"
root_package_path = root / "Package.swift"
ios_package_path = root / "SkyBridge Compass iOS" / "Package.swift"
ios_test_lane_path = root / "SkyBridge Compass iOS" / "Scripts" / "test_lane_ios.sh"
ios_device_test_lane_path = root / "SkyBridge Compass iOS" / "Scripts" / "test_lane_ios_device.sh"

required_paths = [
    pbxproj_path,
    app_scheme_path,
    test_scheme_path,
    test_plan_path,
    tests_dir,
    root_package_path,
    ios_package_path,
    root_project_yaml_path,
    macos_pbxproj_path,
    ios_test_lane_path,
    ios_device_test_lane_path,
]

errors: list[str] = []

for path in required_paths:
    if not path.exists():
        errors.append(f"缺少必需路径: {path}")

if errors:
    for error in errors:
        print(f"[ios-test-config] {error}", file=sys.stderr)
    sys.exit(1)

pbxproj_text = pbxproj_path.read_text(encoding="utf-8")
project_yaml_text = project_yaml_path.read_text(encoding="utf-8") if project_yaml_path.exists() else None
root_project_yaml_text = root_project_yaml_path.read_text(encoding="utf-8")
macos_pbxproj_text = macos_pbxproj_path.read_text(encoding="utf-8")
root_package_text = root_package_path.read_text(encoding="utf-8")
ios_package_text = ios_package_path.read_text(encoding="utf-8")
ios_test_lane_text = ios_test_lane_path.read_text(encoding="utf-8")
ios_device_test_lane_text = ios_device_test_lane_path.read_text(encoding="utf-8")

APP_TARGET_NAME = "SkyBridgeCompass-iOS"
TEST_TARGET_NAME = "SkyBridgeCompassiOSTests"
TEST_PLAN_REFERENCE = "container:SkyBridgeCompass-iOS.xcodeproj/xcshareddata/xctestplans/SkyBridgeCompass-iOS-Shared.xctestplan"
IOS_DEPLOYMENT_TARGET = "17.0"
MACOS_DEPLOYMENT_TARGET = "14.0"
PQC_SDK_SELECTOR_PATTERN = re.compile(
    r"SWIFT_ACTIVE_COMPILATION_CONDITIONS\[sdk=(?:iphoneos|iphonesimulator)[0-9]+\*\].*HAS_APPLE_PQC_SDK"
)
PQC_XCODEBUILD_SETTING = "SKYBRIDGE_APPLE_PQC_SDK_CONDITION"
PQC_DEFAULT_CONDITION = "HAS_APPLE_PQC_SDK"
PQC_CONDITION_REFERENCE = "$(SKYBRIDGE_APPLE_PQC_SDK_CONDITION)"
WEBRTC_RUNTIME_PRODUCT = "SkyBridgeWebRTCRuntime"
WEBRTC_RUNTIME_TARGETS = (
    "SkyBridgeProtocolCore",
    "SkyBridgeWebRTCRuntime",
)


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def parse_scheme(path: Path) -> ET.Element:
    return ET.parse(path).getroot()


def buildable_refs_by_blueprint_name(scheme: ET.Element) -> dict[str, list[ET.Element]]:
    refs: dict[str, list[ET.Element]] = {}
    for ref in scheme.iterfind(".//BuildableReference"):
        name = ref.attrib.get("BlueprintName")
        if not name:
            continue
        refs.setdefault(name, []).append(ref)
    return refs


def build_action_entries(scheme: ET.Element) -> list[ET.Element]:
    return scheme.findall("./BuildAction/BuildActionEntries/BuildActionEntry")


def testable_entries(scheme: ET.Element) -> list[ET.Element]:
    return scheme.findall("./TestAction/Testables/TestableReference")


def macro_expansion_ref(scheme: ET.Element) -> Optional[ET.Element]:
    return scheme.find("./TestAction/MacroExpansion/BuildableReference")


def action_buildable_ref(action: Optional[ET.Element]) -> Optional[ET.Element]:
    if action is None:
        return None
    ref = action.find("./BuildableProductRunnable/BuildableReference")
    if ref is not None:
        return ref
    return action.find("./MacroExpansion/BuildableReference")


def extract_yaml_child_block(text: str, section_name: str, child_name: str) -> Optional[str]:
    lines = text.splitlines()
    section_start = None
    for index, line in enumerate(lines):
        if line.rstrip() == f"{section_name}:":
            section_start = index + 1
            break
    if section_start is None:
        return None

    child_start = None
    for index in range(section_start, len(lines)):
        line = lines[index]
        stripped = line.strip()
        if stripped and not line.startswith(" "):
            break
        if line.rstrip() == f"  {child_name}:":
            child_start = index
            break
    if child_start is None:
        return None

    block: list[str] = [lines[child_start]]
    for index in range(child_start + 1, len(lines)):
        line = lines[index]
        stripped = line.strip()
        if stripped and not line.startswith(" "):
            break
        if line.startswith("  ") and not line.startswith("    ") and stripped.endswith(":"):
            break
        block.append(line)
    return "\n".join(block)


def yaml_scheme_build_includes_target(block: str, target_name: str) -> bool:
    pattern = rf"(?m)^\s+{re.escape(target_name)}:\s*(?:all|\[[^\]]*\btest\b[^\]]*\])\s*$"
    return re.search(pattern, block) is not None


def nested_key_present(payload: object, key: str) -> bool:
    if isinstance(payload, dict):
        if key in payload:
            return True
        return any(nested_key_present(value, key) for value in payload.values())
    if isinstance(payload, list):
        return any(nested_key_present(item, key) for item in payload)
    return False


WARNING_AS_ERROR_SETTINGS = (
    "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
    "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
)
LOCKED_PACKAGE_SETTINGS = (
    "-skipPackageUpdates",
    "-disableAutomaticPackageResolution",
)
XCTEST_STAGES = ("build-for-testing", "test-without-building")


def normalized_shell_lines(block: str) -> set[str]:
    return {
        line.strip().removesuffix("\\").strip()
        for line in block.splitlines()
        if line.strip()
    }


def continued_command_stage_blocks(text: str, command: str) -> dict[str, list[str]]:
    lines = text.splitlines()
    blocks: dict[str, list[str]] = {stage: [] for stage in XCTEST_STAGES}
    index = 0
    command_prefix = f"{command} \\"

    while index < len(lines):
        if lines[index].strip() != command_prefix:
            index += 1
            continue

        block_lines = [lines[index]]
        index += 1
        while index < len(lines):
            block_lines.append(lines[index])
            stage = lines[index].strip()
            index += 1
            if stage in XCTEST_STAGES:
                blocks[stage].append("\n".join(block_lines))
                break

    return blocks


def array_backed_stage_blocks(
    text: str,
    expected_array_by_stage: dict[str, str],
) -> dict[str, list[str]]:
    lines = text.splitlines()
    blocks: dict[str, list[str]] = {stage: [] for stage in XCTEST_STAGES}
    index = 0

    while index < len(lines):
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\+=\(", lines[index].strip())
        if match is None:
            index += 1
            continue

        array_name = match.group(1)
        block_lines = [lines[index]]
        index += 1
        while index < len(lines) and lines[index].strip() != ")":
            block_lines.append(lines[index])
            index += 1
        if index >= len(lines):
            break
        block_lines.append(lines[index])
        index += 1

        normalized_lines = normalized_shell_lines("\n".join(block_lines))
        for stage in XCTEST_STAGES:
            if stage not in normalized_lines:
                continue
            if array_name != expected_array_by_stage[stage]:
                continue
            base_array_pattern = re.compile(
                rf"(?ms)^{re.escape(array_name)}=\(\s*\n\s*xcodebuild(?:\s|$).*?^\)\s*$"
            )
            run_step_reference = f'"${{{array_name}[@]}}"'
            has_matching_run_step = any(
                line.strip().startswith(f'run_xcodebuild_step "{stage}" ')
                and run_step_reference in line
                for line in lines
            )
            if base_array_pattern.search(text) is not None and has_matching_run_step:
                blocks[stage].append("\n".join(block_lines))

    return blocks


def require_warning_gates_by_stage(
    blocks: dict[str, list[str]],
    lane_name: str,
) -> None:
    for stage in XCTEST_STAGES:
        stage_blocks = blocks.get(stage, [])
        require(
            len(stage_blocks) == 1,
            f"{lane_name} 必须且只能定义一个 {stage} xcodebuild 阶段",
        )
        if len(stage_blocks) != 1:
            continue

        normalized_lines = normalized_shell_lines(stage_blocks[0])
        for setting in WARNING_AS_ERROR_SETTINGS:
            require(
                setting in normalized_lines,
                f"{lane_name} 的 {stage} 阶段必须设置 {setting}",
            )


def require_locked_packages_by_stage(
    blocks: dict[str, list[str]],
    lane_name: str,
) -> None:
    for stage in XCTEST_STAGES:
        stage_blocks = blocks.get(stage, [])
        if len(stage_blocks) != 1:
            continue

        normalized_lines = normalized_shell_lines(stage_blocks[0])
        for setting in LOCKED_PACKAGE_SETTINGS:
            require(
                setting in normalized_lines,
                f"{lane_name} 的 {stage} 阶段必须设置 {setting}",
            )


app_scheme = parse_scheme(app_scheme_path)
test_scheme = parse_scheme(test_scheme_path)

app_build_refs = buildable_refs_by_blueprint_name(app_scheme)
test_build_refs = buildable_refs_by_blueprint_name(test_scheme)

def blueprint_identifier(scheme_refs: dict[str, list[ET.Element]], target_name: str) -> Optional[str]:
    refs = scheme_refs.get(target_name) or []
    for ref in refs:
        value = ref.attrib.get("BlueprintIdentifier")
        if value:
            return value
    return None


app_target_id = blueprint_identifier(app_build_refs, APP_TARGET_NAME)
test_target_id = blueprint_identifier(app_build_refs, TEST_TARGET_NAME) or blueprint_identifier(test_build_refs, TEST_TARGET_NAME)

require(app_target_id is not None, f"{APP_TARGET_NAME} 的 BlueprintIdentifier 未能从 scheme 解析出来")
require(test_target_id is not None, f"{TEST_TARGET_NAME} 的 BlueprintIdentifier 未能从 scheme 解析出来")

if errors:
    for error in errors:
        print(f"[ios-test-config] {error}", file=sys.stderr)
    sys.exit(1)

assert app_target_id is not None
assert test_target_id is not None

# 1. 新增测试文件必须进入测试 target Sources
test_swift_files = sorted(path.name for path in tests_dir.glob("*.swift"))
require(bool(test_swift_files), f"{tests_dir} 下未找到任何 Swift 测试文件")

native_target_match = re.search(
    rf"{re.escape(test_target_id)} /\* {re.escape(TEST_TARGET_NAME)} \*/ = \{{.*?buildPhases = \((.*?)\);.*?\}};",
    pbxproj_text,
    re.DOTALL,
)
require(native_target_match is not None, f"project.pbxproj 未找到测试 target {TEST_TARGET_NAME} 的 PBXNativeTarget 定义")

sources_phase_id = None
if native_target_match is not None:
    build_phases_payload = native_target_match.group(1)
    phase_match = re.search(r"([A-Z0-9]+) /\* Sources \*/", build_phases_payload)
    if phase_match:
        sources_phase_id = phase_match.group(1)
require(sources_phase_id is not None, f"{TEST_TARGET_NAME} 未绑定 Sources build phase")

sources_phase_match = None
if sources_phase_id is not None:
    sources_phase_match = re.search(
        rf"{re.escape(sources_phase_id)} /\* Sources \*/ = \{{.*?files = \((.*?)\);.*?\}};",
        pbxproj_text,
        re.DOTALL,
    )
require(sources_phase_match is not None, f"project.pbxproj 未找到测试 target Sources build phase 内容")

sources_payload = sources_phase_match.group(1) if sources_phase_match is not None else ""

for file_name in test_swift_files:
    require(
        f"/* {file_name} */ = {{isa = PBXFileReference;" in pbxproj_text,
        f"{file_name} 未加入 project.pbxproj 文件引用",
    )
    require(
        f"/* {file_name} in Sources */ = {{isa = PBXBuildFile;" in pbxproj_text,
        f"{file_name} 未生成测试 target 的 PBXBuildFile 记录",
    )
    require(
        f"/* {file_name} in Sources */" in sources_payload,
        f"{file_name} 未加入 {TEST_TARGET_NAME} 的 Sources build phase",
    )

# 2. 测试 target 需要宿主 app
for required_snippet in [
    'BUNDLE_LOADER = "$(TEST_HOST)";',
    'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/SkyBridgeCompass-iOS.app/SkyBridgeCompass-iOS";',
]:
    require(required_snippet in pbxproj_text, f"测试 target 缺少必需配置: {required_snippet}")

# The project pins Xcode 26.5+, so ordinary developer builds must compile the
# reviewed Apple PQC surface instead of silently removing it. Formal release and
# device lanes still typecheck the full symbol set before invoking xcodebuild.
# Keep one explicit setting rather than fragile per-SDK selectors.
require(
    PQC_SDK_SELECTOR_PATTERN.search(pbxproj_text) is None,
    "project.pbxproj 不得使用 SDK selector 启用 HAS_APPLE_PQC_SDK；必须通过统一 SKYBRIDGE_APPLE_PQC_SDK_CONDITION 接入",
)
require(
    pbxproj_text.count(f"{PQC_XCODEBUILD_SETTING} = {PQC_DEFAULT_CONDITION};") >= 4,
    "project.pbxproj 的 app/test build configs 必须默认编译 HAS_APPLE_PQC_SDK；不兼容工具链应构建失败而非静默移除 PQC",
)
require(
    pbxproj_text.count(f'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) {PQC_CONDITION_REFERENCE}";') >= 4,
    "project.pbxproj 的 app/test build configs 必须通过 SKYBRIDGE_APPLE_PQC_SDK_CONDITION 接入 Apple PQC 编译条件",
)

require(
    pbxproj_text.count(f"IPHONEOS_DEPLOYMENT_TARGET = {IOS_DEPLOYMENT_TARGET};") >= 2,
    f"project.pbxproj 的 app/test IPHONEOS_DEPLOYMENT_TARGET 必须保持 {IOS_DEPLOYMENT_TARGET}",
)
require(
    ".iOS(.v17)" in root_package_text,
    "根 Package.swift 必须保持 .iOS(.v17)，OS 27 适配不得抬高最低 iOS 版本",
)
require(
    ".macOS(.v14)" in root_package_text,
    "根 Package.swift 必须保持 .macOS(.v14)，OS 27 适配不得抬高最低 macOS 版本",
)
require(
    f'macOS: "{MACOS_DEPLOYMENT_TARGET}"' in root_project_yaml_text,
    f"根 project.yml 的 deploymentTarget.macOS 必须保持 {MACOS_DEPLOYMENT_TARGET}",
)
require(
    f'MACOSX_DEPLOYMENT_TARGET: "{MACOS_DEPLOYMENT_TARGET}"' in root_project_yaml_text,
    f"根 project.yml 的 MACOSX_DEPLOYMENT_TARGET 必须保持 {MACOS_DEPLOYMENT_TARGET}",
)
require(
    macos_pbxproj_text.count(f"MACOSX_DEPLOYMENT_TARGET = {MACOS_DEPLOYMENT_TARGET};") >= 2,
    f"SkyBridgeWidgets.xcodeproj 的 macOS target MACOSX_DEPLOYMENT_TARGET 必须保持 {MACOS_DEPLOYMENT_TARGET}",
)
require(
    ".iOS(.v17)" in ios_package_text,
    "iOS Package.swift 必须保持 .iOS(.v17)，OS 27 适配不得抬高最低 iOS 版本",
)

# The multi-target WebRTC product must be explicitly static. If left automatic, Xcode can
# produce a PackageProduct framework while Q-Periapt links its ProtocolCore dependency into
# the app executable, producing duplicate runtime classes and split state.
webrtc_runtime_product_match = re.search(
    rf'\.library\(\s*name:\s*"{WEBRTC_RUNTIME_PRODUCT}",\s*type:\s*\.static,\s*targets:\s*\[(.*?)\]\s*\)',
    root_package_text,
    re.DOTALL,
)
require(
    webrtc_runtime_product_match is not None,
    f"根 Package.swift 必须声明显式 static {WEBRTC_RUNTIME_PRODUCT} 聚合产品",
)
if webrtc_runtime_product_match is not None:
    aggregate_targets = webrtc_runtime_product_match.group(1)
    for target_name in WEBRTC_RUNTIME_TARGETS:
        require(
            f'"{target_name}"' in aggregate_targets,
            f"{WEBRTC_RUNTIME_PRODUCT} 缺少必需 target: {target_name}",
        )

require(
    f'.product(name: "{WEBRTC_RUNTIME_PRODUCT}", package: "SkyBridgeRoot")'
    in ios_package_text,
    f"iOS Package.swift 必须通过 {WEBRTC_RUNTIME_PRODUCT} 消费共享 WebRTC runtime",
)

require(
    pbxproj_text.count(f"productName = {WEBRTC_RUNTIME_PRODUCT};") == 2,
    f"project.pbxproj 必须为 app/test 各保留一个 {WEBRTC_RUNTIME_PRODUCT} package dependency",
)
require(
    pbxproj_text.count(f"/* {WEBRTC_RUNTIME_PRODUCT} in Frameworks */") == 2,
    f"project.pbxproj 只能由宿主 app 链接一次 {WEBRTC_RUNTIME_PRODUCT}；hosted tests 不得二次链接",
)

simulator_stage_blocks = continued_command_stage_blocks(
    ios_test_lane_text,
    "run_xcodebuild_with_retry",
)
require_warning_gates_by_stage(simulator_stage_blocks, "iOS 模拟器 XCTest lane")
require_locked_packages_by_stage(simulator_stage_blocks, "iOS 模拟器 XCTest lane")
for stage in XCTEST_STAGES:
    stage_blocks = simulator_stage_blocks.get(stage, [])
    if len(stage_blocks) == 1:
        require(
            "SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK"
            in normalized_shell_lines(stage_blocks[0]),
            f"iOS 模拟器 XCTest lane 的 {stage} 阶段必须在 symbol probe 后启用 HAS_APPLE_PQC_SDK",
        )
require(
    'source "${ROOT_DIR}/Scripts/apple_pqc_sdk_probe.sh"' in ios_test_lane_text,
    "iOS 模拟器 XCTest lane 必须加载 Apple PQC symbol probe",
)
require(
    "skybridge_require_apple_pqc_sdk_symbol_probe iphonesimulator" in ios_test_lane_text,
    "iOS 模拟器 XCTest lane 必须 fail-closed 要求 iphonesimulator Apple PQC symbol probe",
)
require(
    "validate_ios_simulator_runtime_diagnostics.sh" in ios_test_lane_text,
    "iOS 模拟器 XCTest lane 必须分类并约束 CoreSimulator runtime diagnostics",
)
for reset_command in (
    'xcrun simctl terminate "${SIM_ID}" "${IOS_APP_BUNDLE_ID}"',
    'xcrun simctl uninstall "${SIM_ID}" "${IOS_APP_BUNDLE_ID}"',
    'xcrun simctl shutdown "${SIM_ID}"',
    'xcrun simctl boot "${SIM_ID}"',
    'xcrun simctl bootstatus "${SIM_ID}" -b',
):
    require(
        reset_command in ios_test_lane_text,
        f"iOS 模拟器 XCTest lane 缺少确定性 simulator reset 步骤: {reset_command}",
    )
device_stage_blocks = array_backed_stage_blocks(
    ios_device_test_lane_text,
    {
        "build-for-testing": "build_args",
        "test-without-building": "test_args",
    },
)
require_warning_gates_by_stage(device_stage_blocks, "iOS 真机 XCTest lane")
require_locked_packages_by_stage(device_stage_blocks, "iOS 真机 XCTest lane")

# 3. App scheme 必须引用共享 test plan，且能构建测试 target
app_scheme_test_plan = app_scheme.find("./TestAction/TestPlans/TestPlanReference")
require(app_scheme_test_plan is not None, f"{APP_TARGET_NAME}.xcscheme 未配置 TestPlanReference")
if app_scheme_test_plan is not None:
    require(
        app_scheme_test_plan.attrib.get("reference") == TEST_PLAN_REFERENCE,
        f"{APP_TARGET_NAME}.xcscheme 未引用共享 test plan: {TEST_PLAN_REFERENCE}",
    )

app_scheme_build_entries = build_action_entries(app_scheme)
app_scheme_build_targets = {
    entry.find("./BuildableReference").attrib.get("BlueprintName")
    for entry in app_scheme_build_entries
    if entry.find("./BuildableReference") is not None
}
require(TEST_TARGET_NAME in app_scheme_build_targets, f"{APP_TARGET_NAME}.xcscheme 的 BuildAction 未包含 {TEST_TARGET_NAME}")

app_scheme_macro = macro_expansion_ref(app_scheme)
require(app_scheme_macro is not None, f"{APP_TARGET_NAME}.xcscheme 缺少 TestAction MacroExpansion")
if app_scheme_macro is not None:
    require(
        app_scheme_macro.attrib.get("BlueprintIdentifier") == app_target_id,
        f"{APP_TARGET_NAME}.xcscheme 的 TestAction MacroExpansion 必须指向宿主 app",
    )

# 4. 共享 test plan 必须同时知道测试 target 与宿主 app
test_plan = json.loads(test_plan_path.read_text(encoding="utf-8"))
test_target_entries = test_plan.get("testTargets", [])
test_target_ids = {
    entry.get("target", {}).get("identifier")
    for entry in test_target_entries
    if isinstance(entry, dict)
}
require(
    test_target_id in test_target_ids,
    f"{test_plan_path.name} 未包含测试 target {TEST_TARGET_NAME}",
)

variable_expansion_target_id = (
    test_plan.get("defaultOptions", {})
    .get("targetForVariableExpansion", {})
    .get("identifier")
)
require(
    variable_expansion_target_id == app_target_id,
    f"{test_plan_path.name} 的 targetForVariableExpansion 必须指向宿主 app",
)
require(
    not nested_key_present(test_plan, "selectedTests"),
    f"{test_plan_path.name} 不得静态配置 selectedTests 过滤",
)
require(
    not nested_key_present(test_plan, "skippedTests"),
    f"{test_plan_path.name} 不得静态配置 skippedTests 过滤",
)

# 5. 独立测试 scheme 也必须可单独运行
test_scheme_build_entries = build_action_entries(test_scheme)
test_scheme_build_targets = {
    entry.find("./BuildableReference").attrib.get("BlueprintName")
    for entry in test_scheme_build_entries
    if entry.find("./BuildableReference") is not None
}
require(APP_TARGET_NAME in test_scheme_build_targets, f"{TEST_TARGET_NAME}.xcscheme 的 BuildAction 未包含宿主 app")
require(TEST_TARGET_NAME in test_scheme_build_targets, f"{TEST_TARGET_NAME}.xcscheme 的 BuildAction 未包含测试 bundle")

test_scheme_macro = macro_expansion_ref(test_scheme)
require(test_scheme_macro is not None, f"{TEST_TARGET_NAME}.xcscheme 缺少 TestAction MacroExpansion")
if test_scheme_macro is not None:
    require(
        test_scheme_macro.attrib.get("BlueprintIdentifier") == app_target_id,
        f"{TEST_TARGET_NAME}.xcscheme 的 TestAction MacroExpansion 必须指向宿主 app",
    )

test_scheme_launch_ref = action_buildable_ref(test_scheme.find("./LaunchAction"))
require(test_scheme_launch_ref is not None, f"{TEST_TARGET_NAME}.xcscheme 缺少 LaunchAction 宿主 app 引用")
if test_scheme_launch_ref is not None:
    require(
        test_scheme_launch_ref.attrib.get("BlueprintIdentifier") == app_target_id,
        f"{TEST_TARGET_NAME}.xcscheme 的 LaunchAction 必须指向宿主 app",
    )

test_scheme_profile_ref = action_buildable_ref(test_scheme.find("./ProfileAction"))
require(test_scheme_profile_ref is not None, f"{TEST_TARGET_NAME}.xcscheme 缺少 ProfileAction 宿主 app 引用")
if test_scheme_profile_ref is not None:
    require(
        test_scheme_profile_ref.attrib.get("BlueprintIdentifier") == app_target_id,
        f"{TEST_TARGET_NAME}.xcscheme 的 ProfileAction 必须指向宿主 app",
    )

testables = testable_entries(test_scheme)
testable_target_ids = {
    testable.find("./BuildableReference").attrib.get("BlueprintIdentifier")
    for testable in testables
    if testable.find("./BuildableReference") is not None and testable.attrib.get("skipped") != "YES"
}
require(
    test_target_id in testable_target_ids,
    f"{TEST_TARGET_NAME}.xcscheme 的 Testables 未启用 {TEST_TARGET_NAME}",
)

# 6. 若仓库以 XcodeGen project.yml 为工程源头，也必须保持同样约束
if project_yaml_text is not None:
    require(
        PQC_SDK_SELECTOR_PATTERN.search(project_yaml_text) is None,
        "project.yml 不得使用 SDK selector 启用 HAS_APPLE_PQC_SDK；必须通过统一 SKYBRIDGE_APPLE_PQC_SDK_CONDITION 接入",
    )
    require(
        project_yaml_text.count(f"{PQC_XCODEBUILD_SETTING}: {PQC_DEFAULT_CONDITION}") >= 2,
        "project.yml 的 app/test target 必须默认编译 HAS_APPLE_PQC_SDK；不兼容工具链应构建失败而非静默移除 PQC",
    )
    require(
        'xcodeVersion: "26.5"' in project_yaml_text,
        "project.yml 默认启用 Apple PQC 时必须固定 Xcode 26.5+ 工具链",
    )
    require(
        project_yaml_text.count(f'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) {PQC_CONDITION_REFERENCE}"') >= 2,
        "project.yml 的 app/test target 必须通过 SKYBRIDGE_APPLE_PQC_SDK_CONDITION 接入 Apple PQC 编译条件",
    )
    require(
        f'iOS: "{IOS_DEPLOYMENT_TARGET}"' in project_yaml_text,
        f"project.yml 的 deploymentTarget.iOS 必须保持 {IOS_DEPLOYMENT_TARGET}",
    )

    app_target_block = extract_yaml_child_block(project_yaml_text, "targets", APP_TARGET_NAME)
    require(app_target_block is not None, "project.yml 缺少 SkyBridgeCompass-iOS target 定义")
    if app_target_block is not None:
        require(
            re.search(
                rf"(?m)^\s+- package: SkyBridgeRoot\s*\n\s+product: {WEBRTC_RUNTIME_PRODUCT}\s*$",
                app_target_block,
            )
            is not None,
            f"project.yml 的宿主 app 必须链接 {WEBRTC_RUNTIME_PRODUCT}",
        )

    target_block = extract_yaml_child_block(project_yaml_text, "targets", TEST_TARGET_NAME)
    require(target_block is not None, "project.yml 缺少 SkyBridgeCompassiOSTests target 定义")
    if target_block is not None:
        require(
            "hostApplication: SkyBridgeCompass-iOS" in target_block,
            "project.yml 的 SkyBridgeCompassiOSTests target 缺少 hostApplication: SkyBridgeCompass-iOS",
        )
        require(
            "- path: SkyBridgeCompassiOSTests" in target_block,
            "project.yml 的 SkyBridgeCompassiOSTests target 未覆盖测试源码目录",
        )
        require(
            re.search(
                rf"(?m)^\s+- package: SkyBridgeRoot\s*\n"
                rf"\s+product: {WEBRTC_RUNTIME_PRODUCT}\s*\n"
                r"\s+link: false\s*\n"
                r"\s+embed: false\s*$",
                target_block,
            )
            is not None,
            f"project.yml 的 hosted tests 必须以 link:false/embed:false 依赖 {WEBRTC_RUNTIME_PRODUCT}",
        )

    require(
        project_yaml_text.count(f"product: {WEBRTC_RUNTIME_PRODUCT}") == 2,
        f"project.yml 必须由 app/test 各声明一次 {WEBRTC_RUNTIME_PRODUCT}",
    )

    app_scheme_block = extract_yaml_child_block(project_yaml_text, "schemes", APP_TARGET_NAME)
    require(app_scheme_block is not None, "project.yml 缺少 SkyBridgeCompass-iOS scheme 定义")
    if app_scheme_block is not None:
        require(
            yaml_scheme_build_includes_target(app_scheme_block, TEST_TARGET_NAME),
            "project.yml 的 SkyBridgeCompass-iOS scheme 未将 SkyBridgeCompassiOSTests 纳入 build targets",
        )

    test_scheme_block = extract_yaml_child_block(project_yaml_text, "schemes", TEST_TARGET_NAME)
    require(test_scheme_block is not None, "project.yml 缺少 SkyBridgeCompassiOSTests scheme 定义")
    if test_scheme_block is not None:
        require(
            yaml_scheme_build_includes_target(test_scheme_block, APP_TARGET_NAME),
            "project.yml 的 SkyBridgeCompassiOSTests scheme 未将宿主 app 纳入 build targets",
        )
        require(
            yaml_scheme_build_includes_target(test_scheme_block, TEST_TARGET_NAME),
            "project.yml 的 SkyBridgeCompassiOSTests scheme 未将测试 bundle 纳入 build targets",
        )

# 7. 轻量动态探测：scheme 不应再掉成 empty supported platforms
if not static_only:
    command = [
        "xcodebuild",
        "-project",
        str(project_dir),
        "-scheme",
        TEST_TARGET_NAME,
        "-showdestinations",
    ]
    probe = subprocess.run(
        command,
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    output = probe.stdout or ""
    require(probe.returncode == 0, f"xcodebuild -showdestinations 执行失败: {output.strip()}")
    require(
        "Supported platforms for the buildables in the current scheme is empty." not in output,
        f"{TEST_TARGET_NAME}.xcscheme 仍然出现 supported platforms is empty",
    )
    require(
        f'Available destinations for the "{TEST_TARGET_NAME}" scheme:' in output,
        f"{TEST_TARGET_NAME}.xcscheme 未返回可用 destinations",
    )

if errors:
    for error in errors:
        print(f"[ios-test-config] {error}", file=sys.stderr)
    sys.exit(1)

mode = "static" if static_only else "static+dynamic"
print(f"[ios-test-config] iOS 测试配置检查通过 ({mode})")
PY
