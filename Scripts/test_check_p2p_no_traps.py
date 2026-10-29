#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("check_p2p_no_traps.py")
SPEC = importlib.util.spec_from_file_location("check_p2p_no_traps", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {SCRIPT_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class P2PNoTrapsScannerTests(unittest.TestCase):
    def make_clean_tree(self, root: Path) -> None:
        for index, scan_spec in enumerate(MODULE.SCAN_SPECS):
            directory = root / scan_spec.relative_root
            directory.mkdir(parents=True, exist_ok=True)
            name = "P2PFixture.swift" if scan_spec.pattern.startswith("P2P") else f"Fixture{index}.swift"
            (directory / name).write_text("func safeFixture() throws {}\n", encoding="utf-8")

    def assert_finding(self, source: str, primitive: str) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.make_clean_tree(root)
            target = root / MODULE.SCAN_SPECS[0].relative_root / "Unsafe.swift"
            target.write_text(source, encoding="utf-8")
            configuration_errors, findings = MODULE.scan(root)
            self.assertEqual(configuration_errors, [])
            self.assertIn(primitive, [finding.primitive for finding in findings])

    def test_clean_required_roots_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.make_clean_tree(root)
            configuration_errors, findings = MODULE.scan(root)
            self.assertEqual(configuration_errors, [])
            self.assertEqual(findings, [])

    def test_fatal_error_fails(self) -> None:
        self.assert_finding('fatalError("unsafe") // ALLOWED\n', "fatalError")

    def test_precondition_fails(self) -> None:
        self.assert_finding("precondition(value > 0)\n", "precondition")

    def test_multiline_precondition_failure_fails(self) -> None:
        self.assert_finding("preconditionFailure\n(\"unsafe\")\n", "preconditionFailure")

    def test_missing_required_root_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.make_clean_tree(root)
            missing = root / MODULE.SCAN_SPECS[1].relative_root
            for path in missing.iterdir():
                path.unlink()
            missing.rmdir()
            configuration_errors, _ = MODULE.scan(root)
            self.assertTrue(configuration_errors)

    def test_empty_required_root_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            self.make_clean_tree(root)
            target = root / MODULE.SCAN_SPECS[2].relative_root
            for path in target.iterdir():
                path.unlink()
            configuration_errors, _ = MODULE.scan(root)
            self.assertTrue(configuration_errors)


if __name__ == "__main__":
    unittest.main()
