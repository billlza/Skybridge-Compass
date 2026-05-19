#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
import sys
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


def run_command(cmd: list[str]) -> tuple[int, str]:
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, output


def run_runtime_gate() -> list[tuple[str, int, str]]:
    return [
        (
            "macOS",
            *run_command(["swift", "test", "--filter", "SkyBridgeCoreTests.UnknownSuiteFallbackDenyTests"]),
        ),
        (
            "iOS",
            *run_command(
                [
                    "xcodebuild",
                    "test",
                    "-project",
                    "SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj",
                    "-scheme",
                    "SkyBridgeCompass-iOS",
                    "-destination",
                    "platform=iOS Simulator,name=iPhone 17,OS=26.5",
                    "-only-testing:SkyBridgeCompassiOSTests/HandshakeCryptoPolicyParityTests/testSuiteNotSupportedDoesNotFallbackOrRetry",
                ]
            ),
        ),
    ]


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
