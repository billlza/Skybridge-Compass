#!/usr/bin/env python3
"""Regression tests for the fail-closed iOS IPA extractor."""

from __future__ import annotations

import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import extract_ios_ipa


SCRIPT_PATH = Path(__file__).with_name("extract_ios_ipa.py").resolve()


class IOSIPAExtractorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="skybridge-ios-ipa-test-"
        )
        self.root = Path(self.temporary_directory.name).resolve()
        self.export_dir = self.root / "export"
        self.destination_parent = self.root / "destination"
        self.export_dir.mkdir(mode=0o700)
        self.destination_parent.mkdir(mode=0o700)
        self.destination_app = self.destination_parent / "Exported.app"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def _zip_info(name: str, mode: int, *, directory: bool = False) -> zipfile.ZipInfo:
        if directory and not name.endswith("/"):
            name += "/"
        info = zipfile.ZipInfo(name)
        info.create_system = 3
        file_type = stat.S_IFDIR if directory else stat.S_IFREG
        info.external_attr = (file_type | mode) << 16
        if directory:
            info.external_attr |= 0x10
        return info

    @staticmethod
    def _plist(executable: str, identifier: str) -> bytes:
        return plistlib.dumps(
            {
                "CFBundleExecutable": executable,
                "CFBundleIdentifier": identifier,
            },
            fmt=plistlib.FMT_BINARY,
        )

    def _valid_entries(self) -> list[tuple[zipfile.ZipInfo, bytes]]:
        app = "Payload/Test.app"
        widget = f"{app}/PlugIns/TestWidget.appex"
        return [
            (self._zip_info(app, 0o755, directory=True), b""),
            (
                self._zip_info(f"{app}/Info.plist", 0o644),
                self._plist("Test", "com.example.test"),
            ),
            (self._zip_info(f"{app}/Test", 0o4755), b"app-executable"),
            (
                self._zip_info(f"{app}/embedded.mobileprovision", 0o600),
                b"app-profile",
            ),
            (self._zip_info(f"{app}/PlugIns", 0o755, directory=True), b""),
            (self._zip_info(widget, 0o755, directory=True), b""),
            (
                self._zip_info(f"{widget}/Info.plist", 0o644),
                self._plist("TestWidget", "com.example.test.widget"),
            ),
            (
                self._zip_info(f"{widget}/TestWidget", 0o2755),
                b"widget-executable",
            ),
            (
                self._zip_info(f"{widget}/embedded.mobileprovision", 0o600),
                b"widget-profile",
            ),
        ]

    def _write_ipa(
        self,
        entries: list[tuple[zipfile.ZipInfo, bytes]] | None = None,
        *,
        name: str = "Export.ipa",
    ) -> Path:
        ipa_path = self.export_dir / name
        with zipfile.ZipFile(ipa_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for info, payload in entries or self._valid_entries():
                archive.writestr(info, payload)
        return ipa_path

    def _assert_rejected(self) -> None:
        with self.assertRaises(extract_ios_ipa.IPAValidationError):
            extract_ios_ipa.extract_single_ios_app(
                self.export_dir,
                self.destination_app,
            )
        self.assertFalse(self.destination_app.exists())

    def test_extracts_one_app_and_widget_atomically_with_safe_modes(self) -> None:
        self._write_ipa()

        result = extract_ios_ipa.extract_single_ios_app(
            self.export_dir,
            self.destination_app,
        )

        self.assertEqual(result, self.destination_app)
        self.assertEqual((result / "Test").read_bytes(), b"app-executable")
        self.assertEqual(
            (result / "PlugIns/TestWidget.appex/TestWidget").read_bytes(),
            b"widget-executable",
        )
        self.assertEqual(stat.S_IMODE((result / "Test").stat().st_mode), 0o755)
        self.assertEqual(
            stat.S_IMODE(
                (result / "PlugIns/TestWidget.appex/TestWidget").stat().st_mode
            ),
            0o755,
        )
        self.assertEqual(list(self.destination_parent.glob(".ios-ipa-stage-*")), [])

    def test_cli_success_prints_only_the_absolute_app_path(self) -> None:
        self._write_ipa()

        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "--export-dir",
                str(self.export_dir),
                "--destination-app",
                str(self.destination_app),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, f"{self.destination_app}\n")
        self.assertEqual(completed.stderr, "")

    def test_rejects_multiple_ipas(self) -> None:
        self._write_ipa(name="First.ipa")
        self._write_ipa(name="Second.ipa")
        self._assert_rejected()

    def test_rejects_multiple_payload_apps(self) -> None:
        entries = self._valid_entries()
        entries.append(
            (
                self._zip_info("Payload/Other.app/Info.plist", 0o644),
                self._plist("Other", "com.example.other"),
            )
        )
        self._write_ipa(entries)
        self._assert_rejected()

    def test_rejects_path_traversal(self) -> None:
        entries = self._valid_entries()
        entries.append((self._zip_info("Payload/Test.app/../escape", 0o644), b"x"))
        self._write_ipa(entries)
        self._assert_rejected()

    def test_rejects_absolute_path(self) -> None:
        entries = self._valid_entries()
        entries.append((self._zip_info("/tmp/escape", 0o644), b"x"))
        self._write_ipa(entries)
        self._assert_rejected()

    def test_rejects_backslash_path(self) -> None:
        entries = self._valid_entries()
        entries.append((self._zip_info(r"Payload\Test.app\escape", 0o644), b"x"))
        self._write_ipa(entries)
        self._assert_rejected()

    def test_rejects_symbolic_link(self) -> None:
        entries = self._valid_entries()
        link = zipfile.ZipInfo("Payload/Test.app/link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        entries.append((link, b"/tmp/escape"))
        self._write_ipa(entries)
        self._assert_rejected()

    def test_rejects_special_file(self) -> None:
        entries = self._valid_entries()
        fifo = zipfile.ZipInfo("Payload/Test.app/fifo")
        fifo.create_system = 3
        fifo.external_attr = (stat.S_IFIFO | 0o600) << 16
        entries.append((fifo, b"x"))
        self._write_ipa(entries)
        self._assert_rejected()

    def test_rejects_casefold_duplicate(self) -> None:
        entries = self._valid_entries()
        entries.append(
            (
                self._zip_info("Payload/Test.app/info.PLIST", 0o644),
                b"duplicate",
            )
        )
        self._write_ipa(entries)
        self._assert_rejected()

    def test_rejects_unicode_normalization_duplicate(self) -> None:
        entries = self._valid_entries()
        entries.extend(
            (
                (
                    self._zip_info("Payload/Test.app/caf\N{LATIN SMALL LETTER E WITH ACUTE}", 0o644),
                    b"composed",
                ),
                (
                    self._zip_info("Payload/Test.app/cafe\N{COMBINING ACUTE ACCENT}", 0o644),
                    b"decomposed",
                ),
            )
        )
        self._write_ipa(entries)
        self._assert_rejected()

    def test_rejects_expanded_size_over_bound(self) -> None:
        self._write_ipa()
        with mock.patch.object(extract_ios_ipa, "MAX_UNCOMPRESSED_BYTES", 1):
            self._assert_rejected()

    def test_failure_keeps_destination_absent_and_removes_staging(self) -> None:
        entries = [
            entry
            for entry in self._valid_entries()
            if entry[0].filename != "Payload/Test.app/embedded.mobileprovision"
        ]
        self._write_ipa(entries)

        self._assert_rejected()

        self.assertEqual(list(self.destination_parent.glob(".ios-ipa-stage-*")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
