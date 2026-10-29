#!/usr/bin/env python3
"""Regression tests for the product-only physical release acceptance gate."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "Scripts"
sys.path.insert(0, os.fspath(SCRIPTS))

VALIDATOR = SCRIPTS / "validate_real_device_release_acceptance_artifact.py"

import test_stage_real_device_release_evidence as stage_fixtures


KIND_MAP = {
    "connectivity": "connectivity",
    "p2p-remote": "p2p",
    "webrtc-remote": "webrtc",
    "file-transfer": "file-transfer",
}


class ReleaseAcceptanceArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture_builder = stage_fixtures.RealDeviceReleaseEvidenceFileSetTests()
        cls.fixture_builder.contracts = stage_fixtures.load_contracts()

    def create_artifact(self, root: Path, contract_kind: str) -> Path:
        return self.fixture_builder.create_minimum_source(root, contract_kind)

    def run_validator(
        self,
        root: Path,
        artifact: Path,
        contract_kind: str,
        *,
        production_identity_only: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        arguments = [
            sys.executable,
            os.fspath(VALIDATOR),
            "--kind",
            "production-identity" if production_identity_only else KIND_MAP[contract_kind],
            "--artifact-dir",
            os.fspath(artifact),
            "--expected-source-repository",
            "example/skybridge",
            "--expected-source-sha",
            "a" * 40,
        ]
        if not production_identity_only:
            arguments.extend(
                [
                    "--ios-archive-identity",
                    os.fspath(root / "ios-release-archive-identity.json"),
                    "--release-testing-ipa",
                    os.fspath(root / "release-testing.ipa"),
                ]
            )
        return subprocess.run(
            arguments,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    @staticmethod
    def rewrite_json(
        path: Path,
        mutation: Callable[[dict[str, Any]], None],
    ) -> None:
        payload = json.loads(path.read_text(encoding="utf-8"))
        mutation(payload)
        path.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        path.chmod(0o600)

    def test_all_four_fixed_product_contracts_are_accepted(self) -> None:
        for contract_kind in KIND_MAP:
            with self.subTest(kind=contract_kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                artifact = self.create_artifact(root, contract_kind)
                result = self.run_validator(root, artifact, contract_kind)
                self.assertEqual(result.returncode, 0, result.stdout)

    def test_standalone_production_identity_contract_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.create_artifact(root, "connectivity")
            result = self.run_validator(
                root,
                artifact,
                "connectivity",
                production_identity_only=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout)

    def test_legacy_diagnostic_status_cannot_replace_product_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.create_artifact(root, "p2p-remote")
            (artifact / "ios-product-session.log").unlink()
            (artifact / "ios.status.log").write_text(
                "p2p authenticated result=success\n", encoding="utf-8"
            )
            result = self.run_validator(root, artifact, "p2p-remote")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ios-product-session.log", result.stdout)

    def test_identity_proof_must_bind_the_current_product_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.create_artifact(root, "webrtc-remote")
            self.rewrite_json(
                artifact / "ios-production-identity-proof.json",
                lambda payload: payload.__setitem__("evidenceSessionRef", "ev1:" + "f" * 32),
            )
            result = self.run_validator(root, artifact, "webrtc-remote")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not bound to this exact product session", result.stdout)

    def test_stable_identity_reference_is_forbidden_in_public_proof(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.create_artifact(root, "connectivity")
            self.rewrite_json(
                artifact / "ios-production-identity-proof.json",
                lambda payload: payload.__setitem__("deviceRef", "1" * 24),
            )
            result = self.run_validator(root, artifact, "connectivity")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("artifact-local identity-1 alias", result.stdout)

    def test_installation_capture_must_bind_the_sealed_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.create_artifact(root, "file-transfer")
            self.rewrite_json(
                artifact / "ios-product-installation-capture.json",
                lambda payload: payload["iosReleaseArchive"].__setitem__(
                    "archiveTreeSha256", "f" * 64
                ),
            )
            result = self.run_validator(root, artifact, "file-transfer")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("archive binding mismatch", result.stdout)

    def test_ios_disconnect_cannot_claim_the_mac_notice(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.create_artifact(root, "p2p-remote")
            path = artifact / "ios-product-session.log"
            path.write_text(
                path.read_text(encoding="ascii").replace(
                    "noticeHidden=not-applicable", "noticeHidden=1"
                ),
                encoding="ascii",
            )
            result = self.run_validator(root, artifact, "p2p-remote")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid disconnect result", result.stdout)

    def test_webrtc_media_counters_must_increase_over_thirty_seconds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.create_artifact(root, "webrtc-remote")
            path = artifact / "mac-product-session.log"
            path.write_text(
                path.read_text(encoding="ascii").replace(
                    "video_frames=1920", "video_frames=60"
                ),
                encoding="ascii",
            )
            result = self.run_validator(root, artifact, "webrtc-remote")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("video_frames did not increase", result.stdout)

    def test_file_transfer_requires_both_ui_directions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.create_artifact(root, "file-transfer")
            path = artifact / "mac-product-session.log"
            path.write_text(
                path.read_text(encoding="ascii").replace(
                    "direction=receive interaction=accept-ui",
                    "direction=send interaction=send-ui",
                ),
                encoding="ascii",
            )
            result = self.run_validator(root, artifact, "file-transfer")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("one send and one receive", result.stdout)

    def test_final_manifest_cannot_claim_a_diagnostic_or_unclean_run(self) -> None:
        for field, value in (("diagnosticOnly", True), ("cleanupComplete", False)):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                artifact = self.create_artifact(root, "connectivity")
                self.rewrite_json(
                    artifact / "release-acceptance.json",
                    lambda payload, field=field, value=value: payload.__setitem__(field, value),
                )
                result = self.run_validator(root, artifact, "connectivity")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(field, result.stdout)


if __name__ == "__main__":
    unittest.main()
