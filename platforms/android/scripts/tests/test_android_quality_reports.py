#!/usr/bin/env python3
"""Regression tests for semantic Android quality-report validation."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "check_android_quality_reports.py"
SPEC = importlib.util.spec_from_file_location("android_quality_reports", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load Android quality-report validator")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AndroidQualityReportTests(unittest.TestCase):
    def test_empty_lint_report_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            report = Path(temporary_root) / "lint.xml"
            report.write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                '<issues format="6" by="lint 9.3.1">\n</issues>\n',
                encoding="utf-8",
            )
            MODULE.verify_lint_report(report)

    def test_real_lint_issue_fails_with_its_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            report = Path(temporary_root) / "lint.xml"
            report.write_text(
                '<issues format="6" by="lint 9.3.1">'
                '<issue id="UnsafeOptInUsageError" severity="Error" />'
                "</issues>",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(RuntimeError, "UnsafeOptInUsageError"):
                MODULE.verify_lint_report(report)

    def test_malformed_or_wrong_root_lint_report_fails_closed(self) -> None:
        fixtures = (
            '<issues format="6" by="lint 9.3.1">',
            '<issue format="6" by="lint 9.3.1" />',
            '<issues format="6" by="lint 9.3.1"><summary /></issues>',
        )
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                with tempfile.TemporaryDirectory() as temporary_root:
                    report = Path(temporary_root) / "lint.xml"
                    report.write_text(fixture, encoding="utf-8")
                    with self.assertRaises(RuntimeError):
                        MODULE.verify_lint_report(report)

    def test_test_report_summary_and_failure_elements_are_both_enforced(self) -> None:
        fixtures = (
            '<testsuite tests="1" failures="1" errors="0"><testcase /></testsuite>',
            '<testsuite tests="1" failures="0" errors="0">'
            '<testcase><failure /></testcase></testsuite>',
        )
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                with tempfile.TemporaryDirectory() as temporary_root:
                    report = Path(temporary_root) / "test.xml"
                    report.write_text(fixture, encoding="utf-8")
                    with self.assertRaises(RuntimeError):
                        MODULE.verify_test_report(report)


if __name__ == "__main__":
    unittest.main()
