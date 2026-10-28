#!/usr/bin/env python3

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

import finalize_release_acceptance_manifests as finalizer
import formal_product_evidence_manifest as formal
import test_stage_real_device_release_evidence as stage_fixtures
import validate_real_device_release_acceptance_artifact as acceptance
from ios_physical_release_acceptance import expected_binding
from ios_release_archive_identity import load_identity
from product_release_evidence_test_fixtures import connectivity_product_logs
from validate_product_release_evidence_log import product_session_references


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

    def existing_q_artifact(self, root: Path, contract_kind: str, kind: str) -> Path:
        artifact = self.create_artifact(root, contract_kind)
        for index, product in enumerate(("mac", "ios")):
            path = artifact / f"{product}-product-session.log"
            if kind == "connectivity":
                lines = connectivity_product_logs(include_q=True)[index]
                path.write_text("\n".join(lines) + "\n")
            else:
                path.write_text(
                    path.read_text().replace(
                        "suite=X-Wing", "suite=Q-Periapt-ABI2-PolicyBound"
                    )
                )
            capture_path = artifact / f"{product}-product-session-capture.json"
            capture = json.loads(capture_path.read_text())
            capture["eventCount"] = len(path.read_text().splitlines())
            self.rewrite_json(capture_path, capture)
        proof_path = artifact / "ios-production-identity-proof.json"
        proof = json.loads(proof_path.read_text())
        proof.pop("created")
        refs = sorted(
            product_session_references(artifact, kind, expected_suite="0x0012")
        )
        proof.update(
            schemaVersion=2,
            purpose="existing-production-identity",
            expectedSuite="0x0012",
            algorithm="mldsa65",
            protection="softwareKeychain",
            secureEnclaveBacked=False,
            identityDisposition="restored-committed-authority",
            continuity="cold-start-restoration",
            baselineArchive=None,
            iosReleaseArchive=expected_binding(
                load_identity(root / "ios-release-archive-identity.json")
            ),
            evidenceSessionRef=refs[0],
            evidenceSessionRefs=refs,
            localFinishedSent=True,
            peerFinishedVerified=True,
        )
        self.rewrite_json(proof_path, proof)
        return artifact

    def test_existing_q_identity_survives_manifest_finalization_and_final_validation(
        self,
    ) -> None:
        for contract, kind in (
            ("connectivity", "connectivity"),
            ("p2p-remote", "p2p"),
            ("webrtc-remote", "webrtc"),
            ("file-transfer", "file-transfer"),
        ):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                artifact = self.existing_q_artifact(root, contract, kind)
                archive = root / "ios-release-archive-identity.json"
                payload = formal.build_manifest(
                    kind=kind, artifact_dir=artifact, archive_identity=archive
                )
                self.assertEqual(payload["schemaVersion"], 2)
                self.assertEqual(payload["expectedSuite"], "0x0012")
                self.assertEqual(
                    payload["iosProductionIdentityProtection"], "softwareKeychain"
                )
                self.assertIs(payload["acceptanceEligible"], False)
                private_manifest = artifact / "release-acceptance.json"
                self.rewrite_json(private_manifest, payload)
                artifact.chmod(0o700)
                public = root / "public"
                shutil.copytree(artifact, public)
                public.chmod(0o700)
                finalizer.finalize_release_acceptance_manifests(
                    private_manifest,
                    public / "release-acceptance.json",
                    archive_identity=archive,
                )
                final = json.loads((public / "release-acceptance.json").read_text())
                repository, commit = acceptance._validate_manifest(final, kind)
                acceptance.validate_product_only_formal_evidence(
                    public,
                    kind,
                    final,
                    expected_repository=repository,
                    expected_source_sha=commit,
                )
                for field, value in (
                    ("iosProductionIdentityProtection", "secureEnclaveRequired"),
                    ("schemaVersion", 1),
                ):
                    with self.subTest(field=field), self.assertRaises(SystemExit):
                        acceptance.validate_product_only_formal_evidence(
                            public,
                            kind,
                            final | {field: value},
                            expected_repository=repository,
                            expected_source_sha=commit,
                        )

    def test_existing_q_manifest_rejects_cross_archive_and_incomplete_session_proof(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self.existing_q_artifact(root, "p2p-remote", "p2p")
            path = artifact / "ios-production-identity-proof.json"
            proof = json.loads(path.read_text())
            changed = json.loads(path.read_text())
            changed["iosReleaseArchive"]["archiveTreeSha256"] = "f" * 64
            self.rewrite_json(path, changed)
            with self.assertRaisesRegex(formal.FormalManifestError, "different sealed"):
                formal.build_manifest(
                    kind="p2p",
                    artifact_dir=artifact,
                    archive_identity=root / "ios-release-archive-identity.json",
                )
            proof["evidenceSessionRefs"] = [proof["evidenceSessionRef"]]
            self.rewrite_json(path, proof)
            with self.assertRaisesRegex(formal.FormalManifestError, "every exact Q"):
                formal.build_manifest(
                    kind="p2p",
                    artifact_dir=artifact,
                    archive_identity=root / "ios-release-archive-identity.json",
                )

    def test_all_four_candidates_are_derived_from_fixed_product_evidence(self) -> None:
        mappings = {
            "connectivity": "connectivity",
            "p2p-remote": "p2p",
            "webrtc-remote": "webrtc",
            "file-transfer": "file-transfer",
        }
        for contract_kind, formal_kind in mappings.items():
            with (
                self.subTest(kind=formal_kind),
                tempfile.TemporaryDirectory() as temporary,
            ):
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
            with self.assertRaisesRegex(
                formal.FormalManifestError, "source identities differ"
            ):
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
            with self.assertRaisesRegex(
                formal.FormalManifestError, "archive binding mismatch"
            ):
                formal.build_manifest(
                    kind="file-transfer",
                    artifact_dir=artifact,
                    archive_identity=root / "ios-release-archive-identity.json",
                )


if __name__ == "__main__":
    unittest.main()
