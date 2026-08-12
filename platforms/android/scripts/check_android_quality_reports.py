#!/usr/bin/env python3
"""Fail-closed semantic validation for Android unit-test and lint XML reports."""

from __future__ import annotations

import argparse
import os
import stat
import xml.etree.ElementTree as ET
from pathlib import Path, PureWindowsPath


MAXIMUM_REPORT_BYTES = 64 * 1024 * 1024
DIAGNOSTIC_IDENTIFIER_LIMIT = 256
DIAGNOSTIC_MESSAGE_LIMIT = 2048
DIAGNOSTIC_PATH_LIMIT = 1024
DIAGNOSTIC_POSITION_LIMIT = 32
DIAGNOSTIC_TRUNCATION_MARKER = "<truncated>"


def sanitize_diagnostic_field(value: str | None, fallback: str, limit: int) -> str:
    raw_value = value or fallback
    single_line = "".join(character if character.isprintable() else " " for character in raw_value)
    normalized = " ".join(single_line.split()) or fallback
    if len(normalized) <= limit:
        return normalized
    retained_length = limit - len(DIAGNOSTIC_TRUNCATION_MARKER)
    if retained_length <= 0:
        raise ValueError("diagnostic field limit is too small for the truncation marker")
    return f"{normalized[:retained_length]}{DIAGNOSTIC_TRUNCATION_MARKER}"


def sanitize_diagnostic_path(value: str | None) -> str:
    source = sanitize_diagnostic_field(value, "<missing-file>", DIAGNOSTIC_PATH_LIMIT)
    windows_candidate = PureWindowsPath(source)
    if windows_candidate.is_absolute():
        basename = windows_candidate.name or "<unnamed>"
        return sanitize_diagnostic_field(
            f"<external>/{basename}", "<external>/<unnamed>", DIAGNOSTIC_PATH_LIMIT
        )
    candidate = Path(source)
    working_directory = Path.cwd().resolve(strict=False)
    resolved_candidate = candidate.resolve(strict=False)
    try:
        relative = resolved_candidate.relative_to(working_directory)
    except ValueError:
        basename = candidate.name or "<unnamed>"
        return sanitize_diagnostic_field(
            f"<external>/{basename}", "<external>/<unnamed>", DIAGNOSTIC_PATH_LIMIT
        )
    return str(relative)


def parse_report(path: Path) -> ET.Element:
    try:
        file_stat = os.lstat(path)
    except FileNotFoundError as error:
        raise RuntimeError(f"required XML report is missing: {path}") from error
    if not stat.S_ISREG(file_stat.st_mode):
        raise RuntimeError(f"XML report must be a non-symbolic-link regular file: {path}")
    if file_stat.st_size <= 0 or file_stat.st_size > MAXIMUM_REPORT_BYTES:
        raise RuntimeError(f"XML report size is outside the supported bound: {path}")
    try:
        payload = path.read_bytes()
    except OSError as error:
        raise RuntimeError(f"could not read XML report: {path}") from error
    if b"<!DOCTYPE" in payload.upper():
        raise RuntimeError(f"XML report must not contain a document type declaration: {path}")
    try:
        return ET.fromstring(payload)
    except ET.ParseError as error:
        raise RuntimeError(f"XML report is malformed: {path}: {error}") from error


def verify_lint_report(path: Path) -> None:
    root = parse_report(path)
    if root.tag != "issues":
        raise RuntimeError(f"Android lint report root must be <issues>: {path}")
    if not root.get("format") or not root.get("by"):
        raise RuntimeError(f"Android lint report is missing format metadata: {path}")
    unexpected = [child.tag for child in root if child.tag != "issue"]
    if unexpected:
        raise RuntimeError(
            f"Android lint report contains unexpected root children {unexpected}: {path}"
        )
    issues = list(root.findall("issue"))
    if issues:
        descriptions = []
        for issue in issues[:10]:
            identifier = sanitize_diagnostic_field(
                issue.get("id"), "<missing-id>", DIAGNOSTIC_IDENTIFIER_LIMIT
            )
            message = sanitize_diagnostic_field(
                issue.get("message"), "<missing-message>", DIAGNOSTIC_MESSAGE_LIMIT
            )
            locations = []
            for location in issue.findall("location")[:3]:
                source = sanitize_diagnostic_path(location.get("file"))
                line = sanitize_diagnostic_field(
                    location.get("line"), "?", DIAGNOSTIC_POSITION_LIMIT
                )
                column = sanitize_diagnostic_field(
                    location.get("column"), "?", DIAGNOSTIC_POSITION_LIMIT
                )
                locations.append(f"{source}:{line}:{column}")
            location_summary = ",".join(locations) or "<missing-location>"
            descriptions.append(
                f"{identifier}: {message} [{location_summary}]"
            )
        raise RuntimeError(
            f"Android lint report contains {len(issues)} issue(s) "
            f"({'; '.join(descriptions)}): {path}"
        )


def verify_test_report(path: Path) -> int:
    root = parse_report(path)
    if root.tag != "testsuite":
        raise RuntimeError(f"Gradle test report root must be <testsuite>: {path}")
    try:
        tests = int(root.attrib["tests"])
        failures = int(root.attrib["failures"])
        errors = int(root.attrib["errors"])
    except (KeyError, ValueError) as error:
        raise RuntimeError(f"Gradle test report has invalid summary counts: {path}") from error
    if min(tests, failures, errors) < 0:
        raise RuntimeError(f"Gradle test report has negative summary counts: {path}")
    failure_elements = list(root.iter("failure"))
    error_elements = list(root.iter("error"))
    if failures or errors or failure_elements or error_elements:
        raise RuntimeError(
            f"Gradle test report contains failures={failures} errors={errors}: {path}"
        )
    return tests


def verify_module_reports(root: Path, modules: tuple[str, ...]) -> tuple[int, int]:
    total_tests = 0
    total_test_reports = 0
    for module in modules:
        module_root = root / module
        if not module_root.is_dir() or module_root.is_symlink():
            raise RuntimeError(f"Android module directory is missing or symbolic: {module_root}")
        lint_report = module_root / "build" / "reports" / "lint-results-debug.xml"
        verify_lint_report(lint_report)
        test_directory = module_root / "build" / "test-results" / "testDebugUnitTest"
        test_reports = sorted(test_directory.glob("TEST-*.xml"))
        if not test_reports:
            raise RuntimeError(f"Android module has no unit-test XML reports: {module}")
        for test_report in test_reports:
            total_tests += verify_test_report(test_report)
        total_test_reports += len(test_reports)
    return total_tests, total_test_reports


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Semantically validate Android test and lint XML reports."
    )
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("modules", nargs="+")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    modules = tuple(args.modules)
    if len(modules) != len(set(modules)):
        raise RuntimeError("Android report module list contains a duplicate")
    total_tests, total_test_reports = verify_module_reports(args.root, modules)
    print(
        "Android quality XML reports passed: "
        f"modules={len(modules)} test_reports={total_test_reports} tests={total_tests} "
        "lint_issues=0"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
