#!/usr/bin/env python3
from __future__ import annotations

import re
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TARGETS = [
    (
        "macOS",
        ROOT / "Sources" / "SkyBridgeCore" / "P2P" / "TwoAttemptHandshakeManager.swift",
    ),
    (
        "iOS",
        ROOT
        / "SkyBridge Compass iOS"
        / "SkyBridgeCompassiOS"
        / "Sources"
        / "Core"
        / "Handshake"
        / "TwoAttemptHandshakeManager.swift",
    ),
]


def fail(message: str) -> int:
    print(f"[unknown-suite-gate] FAIL: {message}")
    return 1


def process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_for_process_group_exit(
    process_group_id: int, timeout_seconds: float
) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while process_group_exists(process_group_id):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)
    return True


def check_static_rules(name: str, source: str) -> list[str]:
    violations: list[str] = []

    disallowed_allowlist_patterns = [
        r"case\s+\.pqcProviderUnavailable\s*,\s*\.suiteNotSupported",
        r"case\s+\.suiteNotSupported\s*,\s*\.suiteNegotiationFailed",
    ]
    for pattern in disallowed_allowlist_patterns:
        if re.search(pattern, source):
            violations.append(f"disallowed fallback allow-list pattern matched: {pattern}")

    required_block_patterns = [
        r"private\s+static\s+func\s+shouldAllowFallback\([\s\S]*?case\s+\.suiteNotSupported:[\s\S]*?return\s+false",
        r"private\s+static\s+func\s+shouldAttemptPQC(?:Bridge|Compatibility)Retry\([\s\S]*?case\s+\.suiteNotSupported[\s\S]*?return\s+false",
        r"public\s+static\s+func\s+isPQCUnavailableError\([\s\S]*?case\s+\.suiteNotSupported:\s*[\s\S]*?return\s+false",
    ]
    for pattern in required_block_patterns:
        if not re.search(pattern, source):
            violations.append(f"{name}: missing required blocked-suite rule: {pattern}")

    return violations


def run_command(cmd: list[str], timeout_seconds: float = 1_200) -> tuple[int, str]:
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
    except OSError as error:
        return 127, f"unable to start command ({' '.join(cmd)}): {error}"

    try:
        stdout, stderr = proc.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = proc.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            stdout = ""
            stderr = ""
        cleanup_complete = wait_for_process_group_exit(proc.pid, timeout_seconds=1)
        if not cleanup_complete:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                reaped_stdout, reaped_stderr = proc.communicate(timeout=1)
                stdout = reaped_stdout or stdout
                stderr = reaped_stderr or stderr
            except subprocess.TimeoutExpired:
                pass
            cleanup_complete = wait_for_process_group_exit(
                proc.pid, timeout_seconds=1
            )
        output = (stdout or "") + (stderr or "")
        cleanup_status = "complete" if cleanup_complete else "incomplete"
        return 124, (
            f"{output}\ncommand timed out after {timeout_seconds}s; "
            f"process-group cleanup={cleanup_status}"
        )
    output = (stdout or "") + (stderr or "")
    return proc.returncode, output


def pick_bootable_ios_simulator() -> tuple[int, str, str]:
    helper = ROOT / "Scripts" / "ios_simulator_helpers.sh"
    if not helper.is_file():
        return 1, "", f"missing simulator helper: {helper}"
    requested_id = os.environ.get("SKYBRIDGE_IOS_SIMULATOR_ID", "")
    command = [
        "bash",
        "-c",
        (
            'source "$1"\n'
            'skybridge_pick_bootable_ios_simulator_id "$2" '
            '"[unknown-suite-gate]"'
        ),
        "skybridge-simulator-picker",
        str(helper),
        requested_id,
    ]
    code, output = run_command(command, timeout_seconds=240)
    if code != 0:
        return code, "", output
    simulator_ids = [
        line.strip()
        for line in output.splitlines()
        if re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", line.strip())
    ]
    if len(simulator_ids) != 1:
        return 1, "", f"simulator helper returned an ambiguous identifier:\n{output}"
    return 0, simulator_ids[0], output


def ios_runtime_gate_commands(
    simulator_id: str, derived_data_path: str
) -> tuple[list[str], list[str]]:
    common = [
        "-project",
        "SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj",
        "-scheme",
        "SkyBridgeCompassiOSTests",
        "-destination",
        f"platform=iOS Simulator,id={simulator_id}",
        "-destination-timeout",
        "120",
        "-derivedDataPath",
        derived_data_path,
        "-skipPackageUpdates",
        "-disableAutomaticPackageResolution",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
        "GCC_TREAT_WARNINGS_AS_ERRORS=YES",
        "SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK",
    ]
    build = ["xcodebuild", "build-for-testing", *common]
    test = [
        "xcodebuild",
        "test-without-building",
        *common,
        "-only-testing:SkyBridgeCompassiOSTests/HandshakeCryptoPolicyParityTests/testSuiteNotSupportedDoesNotFallbackOrRetry",
    ]
    return build, test


def run_runtime_gate() -> list[tuple[str, int, str]]:
    results = [
        (
            "macOS",
            *run_command(["swift", "test", "--filter", "SkyBridgeCoreTests.UnknownSuiteFallbackDenyTests"]),
        )
    ]
    selection_code, simulator_id, selection_output = pick_bootable_ios_simulator()
    if selection_code != 0:
        results.append(("iOS simulator selection", selection_code, selection_output))
        return results
    reset_command = [
        "xcrun",
        "simctl",
        "uninstall",
        simulator_id,
        "com.skybridge.compass.ios",
    ]
    reset_code, reset_output = run_command(
        reset_command,
        timeout_seconds=30,
    )
    if reset_code != 0:
        results.append(("iOS pre-test cleanup", reset_code, reset_output))
        return results
    with tempfile.TemporaryDirectory(prefix="skybridge-unknown-suite-") as derived_data:
        build_command, test_command = ios_runtime_gate_commands(
            simulator_id, derived_data
        )
        build_code, build_output = run_command(build_command, timeout_seconds=300)
        results.append(("iOS build-for-testing", build_code, build_output))
        if build_code == 0:
            results.append(
                (
                    "iOS",
                    *run_command(test_command, timeout_seconds=180),
                )
            )
    cleanup_code, cleanup_output = run_command(
        ["xcrun", "simctl", "uninstall", simulator_id, "com.skybridge.compass.ios"],
        timeout_seconds=30,
    )
    if cleanup_code != 0:
        results.append(
            (
                "iOS post-test cleanup",
                cleanup_code,
                cleanup_output,
            )
        )
    return results


def main() -> int:
    violations: list[str] = []
    for name, target in TARGETS:
        if not target.exists():
            return fail(f"missing {name} file: {target}")
        source = target.read_text(encoding="utf-8")
        violations.extend(check_static_rules(name, source))
    if violations:
        print("[unknown-suite-gate] static rule violations:")
        for item in violations:
            print(f"  - {item}")
        return 1

    for name, code, output in run_runtime_gate():
        if code != 0:
            print(f"[unknown-suite-gate] {name} runtime regression test failed")
            print(output.strip())
            return 1

    print("[unknown-suite-gate] PASS: unknown/unsupported suite is non-fallback-eligible on macOS and iOS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
