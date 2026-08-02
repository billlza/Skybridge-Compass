#!/usr/bin/env python3
"""Fail closed when remotely reachable Apple P2P code can terminate the process."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


DEFAULT_ROOT = Path(__file__).resolve().parents[1]
TRAP_PATTERN = re.compile(
    r"\b(?P<primitive>preconditionFailure|precondition|fatalError)\s*\(",
    re.MULTILINE,
)


@dataclass(frozen=True)
class ScanSpec:
    relative_root: Path
    pattern: str
    recursive: bool = True


@dataclass(frozen=True)
class TrapFinding:
    path: Path
    line: int
    primitive: str


SCAN_SPECS = (
    ScanSpec(Path("Sources/SkyBridgeCore/P2P"), "*.swift"),
    ScanSpec(Path("Sources/SkyBridgeProtocolCore/P2P"), "*.swift"),
    ScanSpec(Path("Sources/SkyBridgeProtocolCore/Security"), "*.swift"),
    ScanSpec(Path("Sources/SkyBridgeQPeriaptRuntime"), "*.swift"),
    ScanSpec(
        Path("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/P2P"),
        "*.swift",
    ),
    ScanSpec(
        Path("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Handshake"),
        "*.swift",
    ),
    ScanSpec(
        Path("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/Providers"),
        "*.swift",
    ),
    ScanSpec(
        Path("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers"),
        "P2P*.swift",
        recursive=False,
    ),
)


def _files_for_spec(root: Path, spec: ScanSpec) -> tuple[list[Path], str | None]:
    scan_root = root / spec.relative_root
    if not scan_root.is_dir():
        return [], f"required scan root is missing: {spec.relative_root}"
    iterator = scan_root.rglob(spec.pattern) if spec.recursive else scan_root.glob(spec.pattern)
    files = sorted(path for path in iterator if path.is_file())
    if not files:
        return [], (
            "required scan root contains no matching Swift sources: "
            f"{spec.relative_root}/{spec.pattern}"
        )
    return files, None


def scan(root: Path) -> tuple[list[str], list[TrapFinding]]:
    configuration_errors: list[str] = []
    files: set[Path] = set()
    for spec in SCAN_SPECS:
        matched, error = _files_for_spec(root, spec)
        if error is not None:
            configuration_errors.append(error)
        files.update(matched)

    findings: list[TrapFinding] = []
    for path in sorted(files):
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            configuration_errors.append(
                f"failed to read {path.relative_to(root)}: {type(error).__name__}"
            )
            continue
        for match in TRAP_PATTERN.finditer(source):
            findings.append(
                TrapFinding(
                    path=path.relative_to(root),
                    line=source.count("\n", 0, match.start()) + 1,
                    primitive=match.group("primitive"),
                )
            )
    return configuration_errors, findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    args = parser.parse_args(argv)
    root = args.root.resolve()

    configuration_errors, findings = scan(root)
    for error in configuration_errors:
        print(f"[p2p-no-traps] CONFIGURATION ERROR: {error}")
    for finding in findings:
        print(
            f"[p2p-no-traps] {finding.path}:{finding.line}: "
            f"disallowed {finding.primitive}("
        )

    if configuration_errors or findings:
        print(
            "[p2p-no-traps] FAIL: replace process-terminating invariants with "
            "typed, testable failure paths"
        )
        return 1
    print("[p2p-no-traps] PASS: no process-terminating P2P traps found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
