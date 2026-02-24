#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "Sources" / "SkyBridgeCore" / "P2P" / "TwoAttemptHandshakeManager.swift"


def fail(message: str) -> int:
    print(f"[unknown-suite-gate] FAIL: {message}")
    return 1


def check_static_rules(source: str) -> list[str]:
    violations: list[str] = []

    disallowed_allowlist_patterns = [
        r"case\s+\.pqcProviderUnavailable\s*,\s*\.suiteNotSupported",
        r"case\s+\.suiteNotSupported\s*,\s*\.suiteNegotiationFailed",
    ]
    for pattern in disallowed_allowlist_patterns:
        if re.search(pattern, source):
            violations.append(f"disallowed fallback allow-list pattern matched: {pattern}")

    required_block_patterns = [
        r"private\s+static\s+func\s+shouldAllowFallback\([\s\S]*?case\s+\.suiteNotSupported:\s*return\s+false",
        r"private\s+static\s+func\s+shouldAttemptPQCBridgeRetry\([\s\S]*?case\s+\.suiteNotSupported:\s*return\s+false",
        r"public\s+static\s+func\s+isPQCUnavailableError\([\s\S]*?case\s+\.suiteNotSupported:\s*[\s\S]*?return\s+false",
    ]
    for pattern in required_block_patterns:
        if not re.search(pattern, source):
            violations.append(f"missing required blocked-suite rule: {pattern}")

    return violations


def run_runtime_gate() -> tuple[int, str]:
    cmd = ["swift", "test", "--filter", "SkyBridgeCoreTests.UnknownSuiteFallbackDenyTests"]
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, output


def main() -> int:
    if not TARGET.exists():
        return fail(f"missing file: {TARGET}")

    source = TARGET.read_text(encoding="utf-8")
    violations = check_static_rules(source)
    if violations:
        print("[unknown-suite-gate] static rule violations:")
        for item in violations:
            print(f"  - {item}")
        return 1

    code, output = run_runtime_gate()
    if code != 0:
        print("[unknown-suite-gate] runtime regression test failed")
        print(output.strip())
        return 1

    print("[unknown-suite-gate] PASS: unknown/unsupported suite is non-fallback-eligible")
    return 0


if __name__ == "__main__":
    sys.exit(main())
