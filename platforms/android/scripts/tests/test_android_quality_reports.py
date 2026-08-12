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
                '<issue id="UnsafeOptInUsageError" severity="Error" '
                'message="Unsafe API usage">'
                '<location file="src/main.kt" line="12" column="3" />'
                '</issue>'
                "</issues>",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                RuntimeError,
                r"UnsafeOptInUsageError: Unsafe API usage \[src/main\.kt:12:3\]",
            ):
                MODULE.verify_lint_report(report)

    def test_lint_diagnostics_are_single_line_bounded_and_location_limited(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            report = Path(temporary_root) / "lint.xml"
            long_message = (
                "prefix&#13;&#10;&#9;::error::forged "
                + "M" * (MODULE.DIAGNOSTIC_MESSAGE_LIMIT + 1)
            )
            report.write_text(
                '<issues format="6" by="lint 9.3.1">'
                '<issue id="Unsafe&#10;Identifier" severity="Error" '
                f'message="{long_message}">'
                '<location file="src/first&#10;line.kt" line="1&#10;2" column="3&#9;4" />'
                '<location file="src/second.kt" line="5" column="6" />'
                '<location file="src/third.kt" line="7" column="8" />'
                '<location file="src/fourth.kt" line="9" column="10" />'
                '</issue>'
                "</issues>",
                encoding="utf-8",
            )
            with self.assertRaises(RuntimeError) as raised:
                MODULE.verify_lint_report(report)
            diagnostic = str(raised.exception)
            self.assertNotIn("\n", diagnostic)
            self.assertNotIn("\r", diagnostic)
            self.assertNotIn("\t", diagnostic)
            self.assertIn("Unsafe Identifier", diagnostic)
            self.assertIn("prefix ::error::forged", diagnostic)
            self.assertIn(MODULE.DIAGNOSTIC_TRUNCATION_MARKER, diagnostic)
            self.assertIn("src/first line.kt:1 2:3 4", diagnostic)
            self.assertIn("src/third.kt:7:8", diagnostic)
            self.assertNotIn("src/fourth.kt", diagnostic)

    def test_lint_diagnostic_lists_only_ten_issues_but_reports_total(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            report = Path(temporary_root) / "lint.xml"
            issues = "".join(
                f'<issue id="Issue{index}" severity="Warning" message="message{index}" />'
                for index in range(1, 12)
            )
            report.write_text(
                f'<issues format="6" by="lint 9.3.1">{issues}</issues>',
                encoding="utf-8",
            )
            with self.assertRaises(RuntimeError) as raised:
                MODULE.verify_lint_report(report)
            diagnostic = str(raised.exception)
            self.assertIn("contains 11 issue(s)", diagnostic)
            self.assertIn("Issue10", diagnostic)
            self.assertNotIn("Issue11", diagnostic)

    def test_external_absolute_lint_path_is_reduced_to_its_basename(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_root:
            report = Path(temporary_root) / "lint.xml"
            report.write_text(
                '<issues format="6" by="lint 9.3.1">'
                '<issue id="Issue" severity="Warning" message="message">'
                '<location file="/private/runner/secret/source.kt" line="1" column="2" />'
                '</issue>'
                '</issues>',
                encoding="utf-8",
            )
            with self.assertRaises(RuntimeError) as raised:
                MODULE.verify_lint_report(report)
            diagnostic = str(raised.exception)
            self.assertIn("<external>/source.kt:1:2", diagnostic)
            self.assertNotIn("/private/runner/secret", diagnostic)

    def test_lint_paths_cannot_escape_with_parent_or_windows_absolute_syntax(self) -> None:
        parent_escape = str(Path.cwd() / ".." / "private" / "secret.kt")
        self.assertEqual(
            MODULE.sanitize_diagnostic_path(parent_escape),
            "<external>/secret.kt",
        )
        self.assertEqual(
            MODULE.sanitize_diagnostic_path(r"C:\Users\runner\secret\source.kt"),
            "<external>/source.kt",
        )

    def test_diagnostic_field_truncation_respects_the_declared_limit(self) -> None:
        result = MODULE.sanitize_diagnostic_field(
            "M" * (MODULE.DIAGNOSTIC_MESSAGE_LIMIT + 1),
            "<missing-message>",
            MODULE.DIAGNOSTIC_MESSAGE_LIMIT,
        )
        self.assertEqual(len(result), MODULE.DIAGNOSTIC_MESSAGE_LIMIT)
        self.assertTrue(result.endswith(MODULE.DIAGNOSTIC_TRUNCATION_MARKER))

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
