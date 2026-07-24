#!/usr/bin/env python3
"""Fail-closed tests for the seven release-evidence file-set contracts."""

from __future__ import annotations

import json
import importlib.util
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
STAGER = ROOT / "Scripts/stage_real_device_release_evidence.py"
SCANNER = ROOT / "Scripts/real_device_smoke_redaction.sh"

REQUIRED_PATTERN_FIXTURES = {
    "connectivity": (),
    "p2p-remote": ("ios-p2p-remote-contract.status.log",),
    "webrtc-remote": (
        "ios-real-webrtc-contract.status.log",
        "ios-real-webrtc-contract.status.log.trace.log",
    ),
    "file-transfer": ("ios-real-device-contract.status.log",),
    "p2p-notice": (),
    "webrtc-notice": ("mac_round_1.status.log",),
    "notice-panel": (),
}


def load_contracts() -> dict[str, object]:
    spec = importlib.util.spec_from_file_location("stage_real_device_release_evidence", STAGER)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load release evidence stager")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module.CONTRACTS


class RealDeviceReleaseEvidenceFileSetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contracts = load_contracts()

    def run_stager(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, os.fspath(STAGER), *arguments],
            text=True,
            capture_output=True,
            check=False,
        )

    def create_minimum_source(self, root: Path, kind: str) -> Path:
        source = root / "source"
        source.mkdir(mode=0o700)
        contract = self.contracts[kind]
        required_exact = contract.required_exact  # type: ignore[attr-defined]
        names = sorted(set(required_exact) | set(REQUIRED_PATTERN_FIXTURES[kind]))
        for name in names:
            path = source / name
            if name.endswith(".json"):
                path.write_text("{}\n", encoding="utf-8")
            else:
                path.write_text("measured release evidence\n", encoding="utf-8")
            path.chmod(0o600)
        return source

    def test_all_seven_contracts_stage_and_verify_canonical_file_sets(self) -> None:
        self.assertEqual(set(self.contracts), set(REQUIRED_PATTERN_FIXTURES))
        for kind in sorted(self.contracts):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                source = self.create_minimum_source(root, kind)
                destination = root / "staged"
                staged = self.run_stager(
                    "--kind",
                    kind,
                    "--source",
                    os.fspath(source),
                    "--destination",
                    os.fspath(destination),
                )
                self.assertEqual(staged.returncode, 0, staged.stderr)
                verified = self.run_stager(
                    "--kind", kind, "--verify", os.fspath(destination)
                )
                self.assertEqual(verified.returncode, 0, verified.stderr)
                manifest_path = destination / "release-evidence-file-set.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                self.assertEqual(manifest["schemaVersion"], 1)
                self.assertEqual(manifest["artifactKind"], kind)
                self.assertEqual(stat.S_IMODE(manifest_path.stat().st_mode), 0o600)
                self.assertEqual(
                    [entry["relativeFile"] for entry in manifest["files"]],
                    sorted(path.name for path in source.iterdir()),
                )

    def test_unknown_text_file_is_rejected_instead_of_silently_dropped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self.create_minimum_source(root, "connectivity")
            (source / "operator-notes.txt").write_text(
                "this file must never be uploaded\n", encoding="utf-8"
            )
            destination = root / "staged"
            result = self.run_stager(
                "--kind",
                "connectivity",
                "--source",
                os.fspath(source),
                "--destination",
                os.fspath(destination),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not in the 1 allowlist", result.stderr)
            self.assertFalse(destination.exists())

    def test_missing_required_evidence_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self.create_minimum_source(root, "notice-panel")
            (source / "panel_probe.status.log").unlink()
            result = self.run_stager(
                "--kind",
                "notice-panel",
                "--source",
                os.fspath(source),
                "--destination",
                os.fspath(root / "staged"),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("required evidence files are missing", result.stderr)

    def test_nested_link_and_hard_link_are_rejected(self) -> None:
        mutations = ("directory", "symlink", "hardlink")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                source = self.create_minimum_source(root, "connectivity")
                if mutation == "directory":
                    (source / "nested").mkdir()
                elif mutation == "symlink":
                    (source / "nested").symlink_to(source / "mac.status.log")
                else:
                    os.link(source / "mac.status.log", source / "nested")
                result = self.run_stager(
                    "--kind",
                    "connectivity",
                    "--source",
                    os.fspath(source),
                    "--destination",
                    os.fspath(root / "staged"),
                )
                self.assertNotEqual(result.returncode, 0)

    def test_post_stage_tampering_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self.create_minimum_source(root, "connectivity")
            destination = root / "staged"
            result = self.run_stager(
                "--kind",
                "connectivity",
                "--source",
                os.fspath(source),
                "--destination",
                os.fspath(destination),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            (destination / "mac.status.log").write_text("tampered\n", encoding="utf-8")
            verified = self.run_stager(
                "--kind", "connectivity", "--verify", os.fspath(destination)
            )
            self.assertNotEqual(verified.returncode, 0)
            self.assertIn("does not match its manifest", verified.stderr)

    def test_generated_manifest_passes_the_public_secret_scanner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self.create_minimum_source(root, "notice-panel")
            destination = root / "staged"
            result = self.run_stager(
                "--kind",
                "notice-panel",
                "--source",
                os.fspath(source),
                "--destination",
                os.fspath(destination),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            scan = subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; ROOT_DIR="$2" skybridge_smoke_check_public_artifacts "$3"',
                    "scanner-test",
                    os.fspath(SCANNER),
                    os.fspath(ROOT),
                    os.fspath(destination),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(scan.returncode, 0, scan.stderr)


if __name__ == "__main__":
    unittest.main()
