#!/usr/bin/env python3
"""Exercise the producer/consumer contract for real-device release evidence."""

from __future__ import annotations

import io
import json
import os
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PRODUCER_WORKFLOW = ROOT / ".github/workflows/real-device-release-gate.yml"
CONSUMER_WORKFLOW = ROOT / ".github/workflows/macos-release-readiness.yml"
ACTIONLINT_CONFIG = ROOT / ".github/actionlint.yaml"
EXTRACTOR = ROOT / "Scripts/extract_real_device_release_evidence_archive.py"
FILE_SET_STAGER = ROOT / "Scripts/stage_real_device_release_evidence.py"
MACOS_HANDOFF_EXTRACTOR = ROOT / "Scripts/extract_macos_release_handoff.py"
CHECKOUT_V6 = "actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803"  # v6.1.0
UPLOAD_ARTIFACT_V4 = (
    "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"  # v4.6.2
)
DOWNLOAD_ARTIFACT_V4 = (
    "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093"  # v4.3.0
)


def add_regular_file(
    archive: tarfile.TarFile,
    name: str,
    content: bytes,
    *,
    mode: int = 0o600,
) -> None:
    member = tarfile.TarInfo(name)
    member.mode = mode
    member.size = len(content)
    archive.addfile(member, io.BytesIO(content))


class RealDeviceReleaseWorkflowContractTests(unittest.TestCase):
    def run_extractor(self, archive_path: Path, destination: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                os.fspath(EXTRACTOR),
                "--archive",
                os.fspath(archive_path),
                "--destination",
                os.fspath(destination),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_workflows_bind_producer_and_consumer_to_same_repository_sha(self) -> None:
        producer = PRODUCER_WORKFLOW.read_text(encoding="utf-8")
        consumer = CONSUMER_WORKFLOW.read_text(encoding="utf-8")
        for required in (
            "SKYBRIDGE_RELEASE_EVIDENCE_EXPECTED_REPOSITORY: ${{ github.repository }}",
            "SKYBRIDGE_RELEASE_EVIDENCE_EXPECTED_SHA: ${{ github.sha }}",
            '[[ "$(git rev-parse --verify HEAD)" == "$GITHUB_SHA" ]]',
            '--expected-source-repository "$GITHUB_REPOSITORY"',
            '--expected-source-sha "$GITHUB_SHA"',
            '[[ "$EVIDENCE_ROOT" == /* ]]',
            '[[ -d "$EVIDENCE_ROOT" && ! -L "$EVIDENCE_ROOT" ]]',
        ):
            self.assertIn(required, producer)
        for required in (
            "RELEASE_ARTIFACT_WORKFLOW_PATH: .github/workflows/real-device-release-gate.yml",
            '--expected-head-sha "${GITHUB_SHA}"',
            '--expected-head-branch "${GITHUB_REF_NAME}"',
            "SKYBRIDGE_RELEASE_EVIDENCE_EXPECTED_REPOSITORY: ${{ github.repository }}",
            "SKYBRIDGE_RELEASE_EVIDENCE_EXPECTED_SHA: ${{ github.sha }}",
        ):
            self.assertIn(required, consumer)

    def test_actionlint_knows_the_protected_runner_label(self) -> None:
        self.assertEqual(
            ACTIONLINT_CONFIG.read_text(encoding="utf-8"),
            "self-hosted-runner:\n"
            "  labels:\n"
            "    - skybridge-real-device-release\n",
        )

    def test_generic_ios_release_compiles_the_probed_iphoneos_pqc_surface(self) -> None:
        consumer = CONSUMER_WORKFLOW.read_text(encoding="utf-8")
        probe = "skybridge_require_apple_pqc_sdk_symbol_probe iphoneos"
        build = "Build Generic iOS Release Without Signing"
        self.assertIn(probe, consumer)
        self.assertIn('${SKYBRIDGE_PQC_INCLUDED_SECURE_ENCLAVE:-0}', consumer)
        self.assertIn("SKYBRIDGE_APPLE_PQC_SDK_CONDITION=HAS_APPLE_PQC_SDK", consumer)
        self.assertLess(consumer.index(probe), consumer.index(build))

    def test_rust_protocol_changes_trigger_the_apple_release_lane(self) -> None:
        consumer = CONSUMER_WORKFLOW.read_text(encoding="utf-8")
        self.assertEqual(
            consumer.count('- "rust/**"'),
            2,
            "Rust SBWC/wire changes must trigger both pull-request and push Apple release checks",
        )

    def test_producer_uploads_archives_and_consumer_extracts_them(self) -> None:
        producer = PRODUCER_WORKFLOW.read_text(encoding="utf-8")
        consumer = CONSUMER_WORKFLOW.read_text(encoding="utf-8")
        self.assertEqual(producer.count("skybridge-release-evidence-archives/"), 7)
        self.assertEqual(producer.count(".tar.gz\n          if-no-files-found: error"), 7)
        self.assertIn("Extract Mode-Preserving Release Evidence", consumer)
        self.assertIn('extraction_path="$download_directory/public-redacted"', consumer)
        self.assertIn("python3 Scripts/extract_real_device_release_evidence_archive.py", consumer)
        extractor = EXTRACTOR.read_text(encoding="utf-8")
        self.assertIn("member.isdir() or member.isfile()", extractor)
        self.assertIn('".." in parts', extractor)

    def test_producer_revalidates_the_exact_archived_bytes_before_upload(self) -> None:
        producer = PRODUCER_WORKFLOW.read_text(encoding="utf-8")
        archive_validation = producer.index(
            '--artifact-dir "$archive_verification_root/$evidence_name"'
        )
        first_upload = producer.index("- name: Upload Connectivity Matrix Evidence")
        self.assertLess(archive_validation, first_upload)
        self.assertIn(
            '--artifact-dir "$archive_verification_root/'
            'real-device-p2p-remote-smoke-public-redacted"',
            producer,
        )
        self.assertIn(
            '--artifact-dir "$archive_verification_root/'
            'real-device-webrtc-smoke-public-redacted"',
            producer,
        )

    def test_producer_stages_only_contract_files_and_scans_both_byte_surfaces(self) -> None:
        producer = PRODUCER_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("python3 Scripts/test_stage_real_device_release_evidence.py", producer)
        self.assertIn("python3 Scripts/stage_real_device_release_evidence.py", producer)
        self.assertNotIn('cp -R -p "$source_path/."', producer)
        self.assertEqual(producer.count("skybridge_smoke_check_public_artifacts"), 2)
        staging_contract = producer.index('--destination "$staging/$evidence_name"')
        staging_scan = producer.index(
            'skybridge_smoke_check_public_artifacts "$staging/$evidence_name"'
        )
        archive_contract = producer.index('--verify "$verification_path"')
        archive_scan = producer.index(
            'skybridge_smoke_check_public_artifacts "$verification_path"'
        )
        first_upload = producer.index("- name: Upload Connectivity Matrix Evidence")
        self.assertLess(staging_contract, staging_scan)
        self.assertLess(archive_contract, archive_scan)
        self.assertLess(archive_scan, first_upload)
        stager = FILE_SET_STAGER.read_text(encoding="utf-8")
        self.assertIn("evidence file is not in the", stager)
        self.assertIn('FILE_SET_MANIFEST = "release-evidence-file-set.json"', stager)

    def test_macos_signing_and_publishing_are_separate_permission_domains(self) -> None:
        consumer = CONSUMER_WORKFLOW.read_text(encoding="utf-8")
        signed_start = consumer.index("  macos-signed-release-gate:")
        publish_start = consumer.index("  macos-immutable-release-publish:")
        signed_job = consumer[signed_start:publish_start]
        publish_job = consumer[publish_start:]
        self.assertIn("contents: read", signed_job)
        self.assertIn("actions: read", signed_job)
        self.assertNotIn("contents: write", signed_job)
        self.assertNotIn("SKYBRIDGE_UPDATE_MANIFEST_ED25519_PRIVATE_KEY_BASE64", signed_job)
        self.assertIn("if: always()", signed_job)
        self.assertIn("Remove Temporary Signing Credentials", signed_job)
        self.assertIn("macos-signed-release-handoff.tar.gz.sha256", signed_job)
        self.assertIn("environment: macos-production-release", publish_job)
        self.assertIn("contents: write", publish_job)
        self.assertIn("needs.macos-signed-release-gate.result == 'success'", publish_job)
        self.assertIn("inputs.publish_update_release == true", publish_job)
        self.assertIn("Scripts/publish_macos_update_release.sh", publish_job)
        self.assertIn("python3 Scripts/extract_macos_release_handoff.py", consumer)
        self.assertIn(UPLOAD_ARTIFACT_V4, signed_job)
        self.assertIn(DOWNLOAD_ARTIFACT_V4, publish_job)
        self.assertEqual(
            consumer.count(f"uses: {CHECKOUT_V6}"),
            consumer.count("persist-credentials: false"),
        )
        handoff_extractor = MACOS_HANDOFF_EXTRACTOR.read_text(encoding="utf-8")
        self.assertIn("archive hard links are forbidden", handoff_extractor)
        self.assertIn("archive member is outside the release handoff contract", handoff_extractor)

    def test_embedded_extractor_preserves_safe_file_modes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive_path = root / "evidence.tar.gz"
            destination = root / "public-redacted"
            with tarfile.open(archive_path, mode="w:gz") as archive:
                child = tarfile.TarInfo("proofs/device")
                child.type = tarfile.DIRTYPE
                child.mode = 0o700
                archive.addfile(child)
                parent = tarfile.TarInfo("proofs")
                parent.type = tarfile.DIRTYPE
                parent.mode = 0o700
                archive.addfile(parent)
                identity_proof = {
                    "schemaVersion": 1,
                    "sourceRepository": "billlza/Skybridge-Compass",
                    "sourceCommit": "a" * 40,
                    "productSurface": "production",
                    "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
                    "testingCompilationCondition": False,
                    "binaryTestSurfaceDetected": False,
                    "realDevice": True,
                    "secureEnclaveBacked": True,
                    "softwareFallbackUsed": False,
                    "privateKeyExported": False,
                    "created": True,
                    "persisted": True,
                    "restoredAfterRelaunch": True,
                    "signed": True,
                    "verified": True,
                    "handshakePersistenceVerified": True,
                    "currentPathAuthorityVerified": True,
                    "measurementSource": "signed-production-app-runtime",
                    "algorithm": "mldsa87",
                    "protection": "secureEnclaveRequired",
                    "deviceRef": "1" * 24,
                    "evidenceSessionRef": "2" * 24,
                }
                add_regular_file(
                    archive,
                    "ios-production-identity-proof.json",
                    (json.dumps(identity_proof, sort_keys=True) + "\n").encode("utf-8"),
                )
                add_regular_file(
                    archive,
                    "proofs/device/diagnostic.txt",
                    b"measured\n",
                )
                add_regular_file(
                    archive,
                    "release-acceptance.json",
                    b'{"schemaVersion":1}\n',
                )

            result = self.run_extractor(archive_path, destination)
            self.assertEqual(result.returncode, 0, result.stderr)
            release_manifest = destination / "release-acceptance.json"
            identity_proof_path = destination / "ios-production-identity-proof.json"
            self.assertEqual(release_manifest.read_bytes(), b'{"schemaVersion":1}\n')
            self.assertEqual(stat.S_IMODE(release_manifest.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(identity_proof_path.stat().st_mode), 0o600)
            validation = subprocess.run(
                [
                    sys.executable,
                    os.fspath(
                        ROOT / "Scripts/validate_real_device_release_acceptance_artifact.py"
                    ),
                    "--kind",
                    "production-identity",
                    "--artifact-dir",
                    os.fspath(destination),
                    "--expected-source-repository",
                    "billlza/Skybridge-Compass",
                    "--expected-source-sha",
                    "a" * 40,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(validation.returncode, 0, validation.stderr)

    def test_embedded_extractor_rejects_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            archive_path = root / "traversal.tar.gz"
            destination = root / "public-redacted"
            escaped_path = root / "escaped.json"
            with tarfile.open(archive_path, mode="w:gz") as archive:
                add_regular_file(archive, "../escaped.json", b"unsafe\n")

            result = self.run_extractor(archive_path, destination)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(escaped_path.exists())

    def test_embedded_extractor_rejects_links_and_special_files(self) -> None:
        for member_type in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE):
            with self.subTest(member_type=member_type):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    archive_path = root / "special.tar.gz"
                    destination = root / "public-redacted"
                    with tarfile.open(archive_path, mode="w:gz") as archive:
                        member = tarfile.TarInfo("unsafe-entry")
                        member.type = member_type
                        member.mode = 0o600
                        member.linkname = "release-acceptance.json"
                        archive.addfile(member)

                    result = self.run_extractor(archive_path, destination)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse((destination / "unsafe-entry").exists())


if __name__ == "__main__":
    unittest.main()
