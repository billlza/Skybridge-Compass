#!/usr/bin/env python3
"""Security and exact-surface tests for the macOS release handoff extractor."""

from __future__ import annotations

import io
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
EXTRACTOR = ROOT / "Scripts/extract_macos_release_handoff.py"


def add_file(archive: tarfile.TarFile, name: str, content: bytes, mode: int = 0o600) -> None:
    member = tarfile.TarInfo(name)
    member.mode = mode
    member.size = len(content)
    archive.addfile(member, io.BytesIO(content))


def add_dir(archive: tarfile.TarFile, name: str, mode: int = 0o700) -> None:
    member = tarfile.TarInfo(name)
    member.type = tarfile.DIRTYPE
    member.mode = mode
    archive.addfile(member)


def write_valid_archive(path: Path) -> None:
    with tarfile.open(path, mode="w:gz") as archive:
        add_dir(archive, "SkyBridge Compass Pro.app")
        add_dir(archive, "SkyBridge Compass Pro.app/Contents")
        add_dir(archive, "SkyBridge Compass Pro.app/Contents/MacOS")
        add_file(
            archive,
            "SkyBridge Compass Pro.app/Contents/Info.plist",
            b"<?xml version='1.0'?><plist><dict/></plist>\n",
        )
        add_file(
            archive,
            "SkyBridge Compass Pro.app/Contents/MacOS/SkyBridgeCompassApp",
            b"signed-app\n",
            mode=0o755,
        )
        add_file(archive, "SkyBridgeCompassPro-1.2.3.dmg", b"notarized-dmg\n")
        add_file(archive, "macos-release-candidate.json", b"{}\n")


class MacOSReleaseHandoffExtractorTests(unittest.TestCase):
    def run_extractor(self, archive: Path, destination: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                os.fspath(EXTRACTOR),
                "--archive",
                os.fspath(archive),
                "--destination",
                os.fspath(destination),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_exact_handoff_extracts_and_preserves_executable_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = root / "handoff.tar.gz"
            destination = root / "release"
            write_valid_archive(archive)
            result = self.run_extractor(archive, destination)
            self.assertEqual(result.returncode, 0, result.stderr)
            executable = (
                destination
                / "SkyBridge Compass Pro.app"
                / "Contents"
                / "MacOS"
                / "SkyBridgeCompassApp"
            )
            self.assertTrue(os.access(executable, os.X_OK))
            self.assertEqual(
                sorted(path.name for path in destination.iterdir()),
                [
                    "SkyBridge Compass Pro.app",
                    "SkyBridgeCompassPro-1.2.3.dmg",
                    "macos-release-candidate.json",
                ],
            )

    def test_unknown_top_level_file_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = root / "handoff.tar.gz"
            with tarfile.open(archive, mode="w:gz") as output:
                add_file(output, "operator-secret.txt", b"must-not-publish\n")
            result = self.run_extractor(archive, root / "release")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("outside the release handoff contract", result.stderr)

    def test_traversal_and_escaping_symlink_fail_closed(self) -> None:
        for attack in ("traversal", "symlink"):
            with self.subTest(attack=attack), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                archive = root / "handoff.tar.gz"
                with tarfile.open(archive, mode="w:gz") as output:
                    if attack == "traversal":
                        add_file(output, "../escaped", b"unsafe\n")
                    else:
                        member = tarfile.TarInfo(
                            "SkyBridge Compass Pro.app/Contents/Frameworks/Current"
                        )
                        member.type = tarfile.SYMTYPE
                        member.linkname = "../../../../outside"
                        output.addfile(member)
                destination = root / "release"
                result = self.run_extractor(archive, destination)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(destination.exists())
                self.assertFalse((root / "escaped").exists())

    def test_hard_links_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive = root / "handoff.tar.gz"
            with tarfile.open(archive, mode="w:gz") as output:
                member = tarfile.TarInfo(
                    "SkyBridge Compass Pro.app/Contents/Info.plist"
                )
                member.type = tarfile.LNKTYPE
                member.linkname = "macos-release-candidate.json"
                output.addfile(member)
            result = self.run_extractor(archive, root / "release")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("hard links are forbidden", result.stderr)


if __name__ == "__main__":
    unittest.main()
