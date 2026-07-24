#!/usr/bin/env python3
"""Regression tests for the fail-closed protocol-parity checker."""

from __future__ import annotations

import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import check_protocol_parity as parity


class AnchorRegistryTests(unittest.TestCase):
    def test_production_registry_contains_thirty_four_unique_extracting_anchors(self) -> None:
        self.assertEqual(len(parity.WIRE_ANCHORS), 34)
        labels = [label for label, _, _ in parity.WIRE_ANCHORS]
        self.assertEqual(len(labels), len(set(labels)))
        for label, pattern, filename in parity.WIRE_ANCHORS:
            with self.subTest(label=label):
                self.assertGreater(parity._compile_anchor(pattern, label=label).groups, 0)
                if filename is not None:
                    self.assertTrue(filename.endswith(".swift"))


class CommandLineTests(unittest.TestCase):
    def test_update_and_list_modes_are_mutually_exclusive(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with mock.patch.object(parity, "cmd_update") as update:
                with mock.patch.object(parity, "cmd_list") as list_pairs:
                    with self.assertRaisesRegex(SystemExit, "2"):
                        parity.main(["--update-baseline", "--list"])

        update.assert_not_called()
        list_pairs.assert_not_called()


class NormalizerTests(unittest.TestCase):
    def test_comment_markers_inside_all_swift_string_forms_are_preserved(self) -> None:
        source = r'''
            let plain = "https://plain.example/api/*literal*/"
            let raw = ##"https://raw.example/a//b/*literal*/"##
            let multiline = """
            https://multiline.example/a//b
            /* still literal */
            """
            let rawMultiline = #"""
            https://raw-multiline.example/a//b
            /* still raw literal */
            """#
            let interpolated = "url: \(make("https://inner.example/a//b"))" // cosmetic
        '''

        normalized = parity.normalize(source)

        self.assertIn("https://plain.example/api/*literal*/", normalized)
        self.assertIn("https://raw.example/a//b/*literal*/", normalized)
        self.assertIn("https://multiline.example/a//b", normalized)
        self.assertIn("/* still literal */", normalized)
        self.assertIn("https://raw-multiline.example/a//b", normalized)
        self.assertIn("/* still raw literal */", normalized)
        self.assertIn("https://inner.example/a//b", normalized)
        self.assertNotIn("cosmetic", normalized)

    def test_urls_with_different_values_no_longer_normalize_identically(self) -> None:
        good = parity.normalize('let endpoint = "https://good.example/api"')
        evil = parity.normalize('let endpoint = "https://evil.example/other"')

        self.assertNotEqual(good, evil)

    def test_nested_comments_are_removed_without_fusing_tokens(self) -> None:
        source = "let value = left/* outer /* nested */ tail */right // cosmetic\n"

        self.assertEqual(parity.normalize(source), "let value = left right")

    def test_multiline_string_whitespace_and_blank_lines_remain_semantic(self) -> None:
        compact = 'let value = """\nline one\nline two\n"""\n'
        indented = 'let value = """\nline one\n line two\n"""\n'
        with_blank_line = 'let value = """\nline one\n\nline two\n"""\n'

        self.assertNotEqual(parity.normalize(compact), parity.normalize(indented))
        self.assertNotEqual(parity.normalize(compact), parity.normalize(with_blank_line))

    def test_unterminated_lexical_constructs_fail_closed(self) -> None:
        malformed_sources = (
            "let value = 1 /* never closed",
            'let value = "never closed',
            'let value = #"never closed',
            'let value = """never closed',
            'let value = "prefix \\(call(1)',
        )

        for source in malformed_sources:
            with self.subTest(source=source):
                with self.assertRaises(parity.ProtocolParityError):
                    parity.normalize(source)


class BaselineUpdateTests(unittest.TestCase):
    SENTINEL = b"accepted-baseline-must-not-change\n"
    MATCHING_ANCHOR: parity.Anchor = (
        "wire version",
        r'wireVersion\s*=\s*"([^"]+)"',
        "Shared.swift",
    )

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repo = Path(self.temporary_directory.name)
        self.ios = self.repo / "ios"
        self.macos = self.repo / "macos"
        self.ios.mkdir()
        self.macos.mkdir()
        self.baseline = self.repo / "protocol_parity_baseline.json"
        self.baseline.write_bytes(self.SENTINEL)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_pair(
        self,
        ios_source: str = 'let wireVersion = "v1"\n',
        macos_source: str = 'let wireVersion = "v1"\n',
    ) -> None:
        (self.ios / "Shared.swift").write_text(ios_source, encoding="utf-8")
        (self.macos / "Shared.swift").write_text(macos_source, encoding="utf-8")

    def _update(self, anchors: list[parity.Anchor] | tuple[parity.Anchor, ...]) -> int:
        return parity.cmd_update(
            ios_root=self.ios,
            macos_root=self.macos,
            baseline_path=self.baseline,
            repo_root=self.repo,
            anchors=anchors,
        )

    def _assert_no_temporary_baseline(self) -> None:
        pattern = f".{self.baseline.name}.*.tmp"
        self.assertEqual(list(self.baseline.parent.glob(pattern)), [])

    def test_duplicate_paired_basename_fails_before_anchor_validation_or_write(self) -> None:
        self._write_pair()
        nested = self.ios / "Nested"
        nested.mkdir()
        (nested / "Shared.swift").write_text('let wireVersion = "v1"\n', encoding="utf-8")

        with mock.patch.object(parity, "check_wire_anchors") as check_anchors:
            with self.assertRaises(parity.ProtocolParityError):
                self._update([self.MATCHING_ANCHOR])

        check_anchors.assert_not_called()
        self.assertEqual(self.baseline.read_bytes(), self.SENTINEL)
        self._assert_no_temporary_baseline()

    def test_duplicate_named_anchor_source_fails_before_write(self) -> None:
        self._write_pair()
        anchor_name = "WeatherService.swift"  # Exempt from pairing, but not from anchor uniqueness.
        for root in (self.ios / "First", self.ios / "Second", self.macos / "Only"):
            root.mkdir()
            (root / anchor_name).write_text('let anchorValue = "v1"\n', encoding="utf-8")
        anchor: parity.Anchor = (
            "exempt named anchor",
            r'anchorValue\s*=\s*"([^"]+)"',
            anchor_name,
        )

        with self.assertRaisesRegex(parity.ProtocolParityError, "exactly one path"):
            self._update([anchor])

        self.assertEqual(self.baseline.read_bytes(), self.SENTINEL)
        self._assert_no_temporary_baseline()

    def test_escaping_symlink_source_fails_before_write(self) -> None:
        outside = self.repo / "outside.swift"
        outside.write_text('let wireVersion = "v1"\n', encoding="utf-8")
        (self.ios / "Shared.swift").symlink_to(outside)
        (self.macos / "Shared.swift").write_text('let wireVersion = "v1"\n', encoding="utf-8")

        with self.assertRaises(parity.ProtocolParityError):
            self._update([self.MATCHING_ANCHOR])

        self.assertEqual(self.baseline.read_bytes(), self.SENTINEL)
        self._assert_no_temporary_baseline()

    def test_overlapping_platform_roots_are_rejected_before_write(self) -> None:
        self._write_pair()

        with self.assertRaisesRegex(parity.ProtocolParityError, "must be disjoint"):
            parity.cmd_update(
                ios_root=self.ios,
                macos_root=self.ios,
                baseline_path=self.baseline,
                repo_root=self.repo,
                anchors=[self.MATCHING_ANCHOR],
            )

        self.assertEqual(self.baseline.read_bytes(), self.SENTINEL)
        self._assert_no_temporary_baseline()

    def test_all_fifteen_anchors_are_checked_before_any_write(self) -> None:
        self._write_pair()
        anchors: list[parity.Anchor] = [
            (f"wire version {index}", self.MATCHING_ANCHOR[1], "Shared.swift")
            for index in range(14)
        ]
        anchors.append(("final missing anchor", r'notPresent\s*=\s*"([^"]+)"', "Shared.swift"))

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            with mock.patch.object(parity, "_atomic_write_text") as atomic_write:
                result = self._update(anchors)

        self.assertEqual(result, 1)
        atomic_write.assert_not_called()
        self.assertIn("final missing anchor", stderr.getvalue())
        self.assertIn("Anchors checked: 15", stderr.getvalue())
        self.assertEqual(self.baseline.read_bytes(), self.SENTINEL)
        self._assert_no_temporary_baseline()

    def test_malformed_source_fails_before_temporary_file_creation(self) -> None:
        self._write_pair(
            ios_source='let wireVersion = "v1"\nlet broken = #"unterminated\n',
        )

        with self.assertRaises(parity.ProtocolParityError):
            self._update([self.MATCHING_ANCHOR])

        self.assertEqual(self.baseline.read_bytes(), self.SENTINEL)
        self._assert_no_temporary_baseline()

    def test_invalid_utf8_source_fails_before_temporary_file_creation(self) -> None:
        self._write_pair()
        (self.ios / "Shared.swift").write_bytes(b'let wireVersion = "v1"\n\xff')

        with self.assertRaisesRegex(parity.ProtocolParityError, "as UTF-8"):
            self._update([self.MATCHING_ANCHOR])

        self.assertEqual(self.baseline.read_bytes(), self.SENTINEL)
        self._assert_no_temporary_baseline()

    def test_baseline_outside_repository_is_rejected_before_write(self) -> None:
        self._write_pair()
        with tempfile.TemporaryDirectory() as outside_directory:
            outside_baseline = Path(outside_directory) / "baseline.json"
            outside_baseline.write_bytes(self.SENTINEL)

            with self.assertRaisesRegex(parity.ProtocolParityError, "outside the repository"):
                parity.cmd_update(
                    ios_root=self.ios,
                    macos_root=self.macos,
                    baseline_path=outside_baseline,
                    repo_root=self.repo,
                    anchors=[self.MATCHING_ANCHOR],
                )

            self.assertEqual(outside_baseline.read_bytes(), self.SENTINEL)
            self.assertEqual(list(outside_baseline.parent.glob(".baseline.json.*.tmp")), [])

    def test_successful_update_uses_same_directory_atomic_replace(self) -> None:
        self._write_pair()
        real_replace = os.replace
        replacements: list[tuple[Path, Path]] = []

        def recording_replace(source: str | os.PathLike[str], destination: str | os.PathLike[str]) -> None:
            source_path = Path(source)
            destination_path = Path(destination)
            replacements.append((source_path, destination_path))
            self.assertEqual(source_path.parent, self.baseline.parent)
            self.assertEqual(destination_path, self.baseline)
            real_replace(source_path, destination_path)

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            with mock.patch.object(parity.os, "replace", side_effect=recording_replace):
                result = self._update([self.MATCHING_ANCHOR])

        self.assertEqual(result, 0)
        self.assertEqual(len(replacements), 1)
        decoded = json.loads(self.baseline.read_text(encoding="utf-8"))
        self.assertEqual(set(decoded), {"Shared.swift"})
        self.assertEqual(decoded["Shared.swift"]["ios"], "ios/Shared.swift")
        self.assertEqual(decoded["Shared.swift"]["macos"], "macos/Shared.swift")
        self._assert_no_temporary_baseline()

    def test_replace_failure_preserves_baseline_and_removes_temporary_file(self) -> None:
        self._write_pair()

        with mock.patch.object(parity.os, "replace", side_effect=OSError("injected replace failure")):
            with self.assertRaisesRegex(parity.ProtocolParityError, "injected replace failure"):
                self._update([self.MATCHING_ANCHOR])

        self.assertEqual(self.baseline.read_bytes(), self.SENTINEL)
        self._assert_no_temporary_baseline()


class BaselineSchemaTests(unittest.TestCase):
    def test_duplicate_baseline_key_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            baseline = Path(temporary_directory) / "baseline.json"
            baseline.write_text('{"Shared.swift": {}, "Shared.swift": {}}\n', encoding="utf-8")

            with self.assertRaisesRegex(parity.ProtocolParityError, "duplicate JSON key"):
                parity._load_baseline(baseline)

    def test_unsafe_baseline_path_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            baseline = Path(temporary_directory) / "baseline.json"
            baseline.write_text(
                json.dumps(
                    {
                        "Shared.swift": {
                            "ios": "../Shared.swift",
                            "macos": "macos/Shared.swift",
                            "ios_hash": "0" * 64,
                            "macos_hash": "0" * 64,
                            "forked": False,
                        }
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaises(parity.ProtocolParityError):
                parity._load_baseline(baseline)


if __name__ == "__main__":
    unittest.main()
