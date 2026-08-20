#!/usr/bin/env python3

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import formal_product_evidence_manifest as formal
import test_stage_real_device_release_evidence as stage_fixtures


class FormalProductEvidenceManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture_builder = stage_fixtures.RealDeviceReleaseEvidenceFileSetTests()
        cls.fixture_builder.contracts = stage_fixtures.load_contracts()

    def create_artifact(self, root: Path, contract_kind: str) -> Path:
        return self.fixture_builder.create_minimum_source(root, contract_kind)

    @staticmethod
    def rewrite_json(path: Path, payload: object) -> None:
        path.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        path.chmod(0o600)

    def test_all_four_candidates_are_derived_from_fixed_product_evidence(self) -> None:
        mappings = {
            "connectivity": "connectivity",
            "p2p-remote": "p2p",
            "webrtc-remote": "webrtc",
            "file-transfer": "file-transfer",
        }
        for contract_kind, formal_kind in mappings.items():
            with self.subTest(kind=formal_kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                artifact = self.create_artifact(root, contract_kind)
                payload = formal.build_manifest(
                    kind=formal_kind,
                    artifact_dir=artifact,
                    archive_identity=root / "ios-release-archive-identity.json",
                )
                self.assertIs(payload["preCleanupCandidate"], True)
                self.assertIs(payload["acceptanceEligible"], False)
                self.assertIs(payload["cleanupComplete"], False)
                self.assertIs(payload["diagnosticOnly"], True)
                self.assertEqual(payload["transport"], formal_kind)
                self.assertNotIn("finalizationOrder", payload)
                self.assertNotIn("supplemental", json.dumps(payload))

    def test_cross_run_identity_session_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.create_artifact(root, "webrtc-remote")
            proof_path = artifact / "ios-production-identity-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["evidenceSessionRef"] = "ev1:" + "f" * 32
            self.rewrite_json(proof_path, proof)
            with self.assertRaisesRegex(formal.FormalManifestError, "not bound"):
                formal.build_manifest(
                    kind="webrtc",
                    artifact_dir=artifact,
                    archive_identity=root / "ios-release-archive-identity.json",
                )

    def test_candidate_source_must_match_the_sealed_ios_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.create_artifact(root, "connectivity")
            candidate_path = artifact / "macos-release-candidate.json"
            candidate = json.loads(candidate_path.read_text(encoding="utf-8"))
            candidate["source"]["commit"] = "b" * 40
            self.rewrite_json(candidate_path, candidate)
            with self.assertRaisesRegex(formal.FormalManifestError, "source identities differ"):
                formal.build_manifest(
                    kind="connectivity",
                    artifact_dir=artifact,
                    archive_identity=root / "ios-release-archive-identity.json",
                )

    def test_installation_capture_must_bind_the_same_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.create_artifact(root, "file-transfer")
            capture_path = artifact / "ios-product-installation-capture.json"
            capture = json.loads(capture_path.read_text(encoding="utf-8"))
            capture["iosReleaseArchive"]["archiveTreeSha256"] = "f" * 64
            self.rewrite_json(capture_path, capture)
            with self.assertRaisesRegex(formal.FormalManifestError, "archive binding mismatch"):
                formal.build_manifest(
                    kind="file-transfer",
                    artifact_dir=artifact,
                    archive_identity=root / "ios-release-archive-identity.json",
                )


if __name__ == "__main__":
    unittest.main()
