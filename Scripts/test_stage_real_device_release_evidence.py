#!/usr/bin/env python3
"""Fail-closed tests for the four release-evidence file-set contracts."""

from __future__ import annotations

import json
import hashlib
import importlib.util
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))
STAGER = ROOT / "Scripts/stage_real_device_release_evidence.py"
SCANNER = ROOT / "Scripts/real_device_smoke_redaction.sh"

import ios_physical_release_acceptance as physical
import ios_release_archive_identity as archive_identity
from product_release_evidence_test_fixtures import (
    MAC_PRODUCT,
    IOS_PRODUCT,
    capture_manifest,
    connectivity_product_logs,
)
from test_validate_product_release_evidence_log import (
    file_transfer_ios_lines,
    file_transfer_lines,
    p2p_ios_lines,
    p2p_remote_lines,
    webrtc_ios_lines,
    webrtc_remote_lines,
)

REQUIRED_PATTERN_FIXTURES = {
    "connectivity": (),
    "p2p-remote": (),
    "webrtc-remote": (),
    "file-transfer": (),
}


def product_evidence_lines(kind: str) -> list[str]:
    if kind == "p2p-remote":
        return p2p_remote_lines()
    if kind == "webrtc-remote":
        return webrtc_remote_lines()
    if kind == "file-transfer":
        return file_transfer_lines()
    raise AssertionError("connectivity uses paired product endpoint logs")


def ios_product_evidence_lines(kind: str) -> list[str]:
    if kind == "p2p-remote":
        return p2p_ios_lines()
    if kind == "webrtc-remote":
        return webrtc_ios_lines()
    if kind == "file-transfer":
        return file_transfer_ios_lines()
    raise AssertionError("connectivity uses paired product endpoint logs")


def connectivity_product_lines(owner: str) -> list[str]:
    mac_lines, ios_lines = connectivity_product_logs()
    if owner == MAC_PRODUCT:
        return mac_lines
    if owner == IOS_PRODUCT:
        return ios_lines
    raise ValueError(f"unsupported product evidence owner: {owner}")


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
        values = list(arguments)
        if "--ios-archive-identity" not in values:
            path_flag = "--source" if "--source" in values else "--verify"
            artifact_path = Path(values[values.index(path_flag) + 1])
            release_root = artifact_path.parent
            values.extend(
                (
                    "--ios-archive-identity",
                    os.fspath(release_root / "ios-release-archive-identity.json"),
                    "--release-testing-ipa",
                    os.fspath(release_root / "release-testing.ipa"),
                )
            )
        return subprocess.run(
            [sys.executable, os.fspath(STAGER), *values],
            text=True,
            capture_output=True,
            check=False,
        )

    def create_minimum_source(self, root: Path, kind: str) -> Path:
        ipa = root / "release-testing.ipa"
        ipa.write_bytes(b"sealed-release-testing-ipa")
        identity = archive_identity.validate_identity(
            {
                "schemaVersion": 1,
                "identityPurpose": archive_identity.IDENTITY_PURPOSE,
                "archiveTreeSha256": "3" * 64,
                "archiveFileCount": 12,
                "archiveTotalBytes": 8192,
                "appExecutableUUIDs": [
                    {
                        "architecture": "arm64",
                        "uuid": "11111111-1111-1111-1111-111111111111",
                    }
                ],
                "widgetExecutableUUIDs": [
                    {
                        "architecture": "arm64",
                        "uuid": "22222222-2222-2222-2222-222222222222",
                    }
                ],
                "debugSymbolsVerified": True,
                "releaseTestingIpaSha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
                "sourceRepository": "example/skybridge",
                "sourceCommit": "a" * 40,
                "sourceInputDigest": "2" * 64,
                "releaseVersion": "1.2.3",
                "releaseBuild": "42",
                "appBundleIdentifier": archive_identity.APP_BUNDLE_IDENTIFIER,
                "widgetBundleIdentifier": archive_identity.WIDGET_BUNDLE_IDENTIFIER,
                "productSurface": "production",
                "buildConfiguration": "Release",
                "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
            }
        )
        (root / "ios-release-archive-identity.json").write_bytes(
            archive_identity.canonical_bytes(identity)
        )
        source = root / "source"
        source.mkdir(mode=0o700)
        contract = self.contracts[kind]
        required_exact = contract.required_exact  # type: ignore[attr-defined]
        names = sorted(set(required_exact) | set(REQUIRED_PATTERN_FIXTURES[kind]))
        product_lines = (
            connectivity_product_lines("SkyBridgeCompassApp")
            if kind == "connectivity"
            else product_evidence_lines(kind)
        )
        ios_product_lines = (
            connectivity_product_lines("SkyBridgeCompassiOS")
            if kind == "connectivity"
            else ios_product_evidence_lines(kind)
        )
        for name in names:
            path = source / name
            if name == "macos-release-candidate.json":
                payload = {
                    "schemaVersion": 1,
                    "source": {"repository": "example/skybridge", "commit": "a" * 40},
                    "product": {
                        "bundleIdentifier": "com.skybridge.compass.pro",
                        "version": "1.2.3",
                        "build": "42",
                        "teamIdentifier": "ABCDEFGHIJ",
                        "cdHash": "b" * 40,
                        "designatedRequirement": 'identifier "com.skybridge.compass.pro" and anchor apple generic',
                    },
                    "platformValidation": {
                        "codeSignatureValid": True,
                        "notarizationAccepted": True,
                        "appStaplerValid": True,
                        "dmgStaplerValid": True,
                        "appGatekeeperAccepted": True,
                        "dmgGatekeeperAccepted": True,
                    },
                    "artifactBinding": {
                        "algorithm": "sha256",
                        "purpose": "detect accidental candidate/evidence mismatch",
                        "appBundleDigest": "c" * 64,
                        "dmgDigest": "d" * 64,
                        "dmgFileName": "SkyBridgeCompassPro-1.2.3.dmg",
                    },
                }
                path.write_text(
                    json.dumps(payload, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            elif name == "mac-product-session.log":
                path.write_text("\n".join(product_lines) + "\n", encoding="ascii")
            elif name == "mac-product-session-capture.json":
                path.write_text(
                    json.dumps(
                        capture_manifest(MAC_PRODUCT, len(product_lines), 4321),
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
            elif name == "ios-product-session.log":
                path.write_text(
                    "\n".join(ios_product_lines) + "\n", encoding="ascii"
                )
            elif name == "ios-product-session-capture.json":
                path.write_text(
                    json.dumps(
                        capture_manifest(
                            IOS_PRODUCT,
                            len(ios_product_lines),
                            4322,
                            ios_release_archive=physical.expected_binding(identity),
                        ),
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
            elif name == "release-acceptance.json":
                formal_kind = {
                    "p2p-remote": "p2p",
                    "webrtc-remote": "webrtc",
                }.get(kind, kind)
                path.write_text(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "acceptanceEligible": True,
                            "cleanupComplete": True,
                            "diagnosticOnly": False,
                            "finalizationOrder": "private-then-public-v1",
                            "iosBinaryTestSurfaceDetected": False,
                            "iosProductSurface": "production",
                            "iosProductionIdentityAlgorithm": "mldsa87",
                            "iosProductionIdentityLifecycleVerified": True,
                            "iosProductionIdentityProof": True,
                            "iosProductionIdentityProtection": "secureEnclaveRequired",
                            "iosProductionProduct": True,
                            "iosReleaseArchive": physical.expected_binding(identity),
                            "iosSwiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
                            "iosTestingCompilationCondition": False,
                            "labRun": False,
                            "macCandidateIdentityVerified": True,
                            "macDebugBuild": False,
                            "macProductSurface": "production",
                            "identitySourceGatekeeperAccepted": True,
                            "identitySourceStaplerValid": True,
                            "macHostLaunchMode": "packaged",
                            "macRuntimeExecutable": "SkyBridgeCompassApp",
                            "macTestingCompilationCondition": False,
                            "preCleanupCandidate": True,
                            "realDevice": True,
                            "sourceCommit": "a" * 40,
                            "sourceRepository": "example/skybridge",
                            "transport": formal_kind,
                            **(
                                {
                                    "noticeEvidenceSource": "normal-product-session",
                                    "remoteControlNoticeHumanApproval": True,
                                    "remoteControlNoticePanelPresented": True,
                                    "remoteControlNoticeProductPath": True,
                                }
                                if formal_kind in {"p2p", "webrtc"}
                                else {}
                            ),
                        },
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
            elif name == "ios-production-identity-proof.json":
                evidence_session = (
                    "ev1:" + "1" * 32
                    if kind == "connectivity"
                    else "ev1:" + "ab" * 16
                )
                path.write_text(
                    json.dumps(
                        {
                            "algorithm": "mldsa87",
                            "binaryTestSurfaceDetected": False,
                            "created": True,
                            "currentPathAuthorityVerified": True,
                            "deviceRef": "identity-1",
                            "evidenceSessionRef": evidence_session,
                            "handshakePersistenceVerified": True,
                            "measurementSource": "signed-production-app-runtime",
                            "persisted": True,
                            "privateKeyExported": False,
                            "productSurface": "production",
                            "protection": "secureEnclaveRequired",
                            "realDevice": True,
                            "restoredAfterRelaunch": True,
                            "schemaVersion": 1,
                            "secureEnclaveBacked": True,
                            "signed": True,
                            "softwareFallbackUsed": False,
                            "sourceCommit": "a" * 40,
                            "sourceRepository": "example/skybridge",
                            "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
                            "testingCompilationCondition": False,
                            "verified": True,
                        },
                        indent=2,
                        sort_keys=True,
                    ) + "\n",
                    encoding="utf-8",
                )
            elif name == "ios-product-installation-capture.json":
                path.write_text(
                    json.dumps(
                        {
                            "bundleIdentifier": "com.skybridge.compass.ios",
                            "candidateIdentityFile": "release-acceptance.json",
                            "candidateIdentityVerified": True,
                            "freshLaunchVerified": True,
                            "installationReceiptVerified": True,
                            "installedApplicationVerified": True,
                            "iosReleaseArchive": physical.expected_binding(identity),
                            "launchPersistentIdentifierVerified": True,
                            "platform": "ios",
                            "preLaunchAbsenceVerified": True,
                            "processExecutable": "SkyBridgeCompass-iOS",
                            "processID": 4322,
                            "processOwnershipVerified": True,
                            "profile": "skybridge-formal-ios-product-installation-capture",
                            "releaseArchiveBindingVerified": True,
                            "releaseBuild": "42",
                            "releaseVersion": "1.2.3",
                            "schemaVersion": 1,
                            "startTimeToken": "1700000000:223456",
                        },
                        indent=2,
                        sort_keys=True,
                    ) + "\n",
                    encoding="utf-8",
                )
            elif name.endswith(".json"):
                path.write_text("{}\n", encoding="utf-8")
            elif kind == "connectivity" and name in {"ios.status.log", "mac.status.log"}:
                raise AssertionError(
                    "connectivity contract must not require external status labels"
                )
            else:
                path.write_text("measured release evidence\n", encoding="utf-8")
            path.chmod(0o600)
        return source

    def test_all_four_contracts_stage_and_verify_canonical_file_sets(self) -> None:
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
                downstream_verified = subprocess.run(
                    [
                        sys.executable,
                        os.fspath(STAGER),
                        "--kind",
                        kind,
                        "--verify",
                        os.fspath(destination),
                    ],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(
                    downstream_verified.returncode, 0, downstream_verified.stderr
                )
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

    def test_connectivity_rejects_external_status_labels(self) -> None:
        for external_name in ("mac.status.log", "ios.status.log"):
            with self.subTest(external_name=external_name), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                source = self.create_minimum_source(root, "connectivity")
                (source / external_name).write_text(
                    "connectivity-case result=success\n", encoding="utf-8"
                )
                result = self.run_stager(
                    "--kind",
                    "connectivity",
                    "--source",
                    os.fspath(source),
                    "--destination",
                    os.fspath(root / "staged"),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("not in the 1 allowlist", result.stderr)

    def test_missing_required_evidence_fails_closed(self) -> None:
        for missing in (
            "macos-release-candidate.json",
            "ios-product-session.log",
            "ios-product-session-capture.json",
        ):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                source = self.create_minimum_source(root, "connectivity")
                (source / missing).unlink()
                result = self.run_stager(
                    "--kind",
                    "connectivity",
                    "--source",
                    os.fspath(source),
                    "--destination",
                    os.fspath(root / "staged"),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("required evidence files are missing", result.stderr)

    def test_ios_product_capture_cannot_be_published_without_valid_pairing(self) -> None:
        for mutation in ("missing-mac", "unbound-ios"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                source = self.create_minimum_source(root, "connectivity")
                if mutation == "missing-mac":
                    (source / "mac-product-session.log").unlink()
                else:
                    capture_path = source / "ios-product-session-capture.json"
                    capture = json.loads(capture_path.read_text(encoding="utf-8"))
                    capture["releaseArchiveBindingVerified"] = False
                    capture_path.write_text(
                        json.dumps(capture, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
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
                self.assertFalse(destination.exists())

    def test_nested_link_and_hard_link_are_rejected(self) -> None:
        mutations = ("directory", "symlink", "hardlink")
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory)
                source = self.create_minimum_source(root, "connectivity")
                if mutation == "directory":
                    (source / "nested").mkdir()
                elif mutation == "symlink":
                    (source / "nested").symlink_to(
                        source / "mac-product-session.log"
                    )
                else:
                    os.link(source / "mac-product-session.log", source / "nested")
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
            (destination / "mac-product-session.log").write_text(
                "tampered\n", encoding="utf-8"
            )
            verified = self.run_stager(
                "--kind", "connectivity", "--verify", os.fspath(destination)
            )
            self.assertNotEqual(verified.returncode, 0)
            self.assertIn("does not match its manifest", verified.stderr)

    def test_replaced_release_testing_ipa_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self.create_minimum_source(root, "connectivity")
            destination = root / "staged"
            staged = self.run_stager(
                "--kind",
                "connectivity",
                "--source",
                os.fspath(source),
                "--destination",
                os.fspath(destination),
            )
            self.assertEqual(staged.returncode, 0, staged.stderr)
            (root / "release-testing.ipa").write_bytes(b"substituted-ipa")
            verified = self.run_stager(
                "--kind", "connectivity", "--verify", os.fspath(destination)
            )
            self.assertNotEqual(verified.returncode, 0)
            self.assertIn("does not match the sealed archive identity", verified.stderr)

    def test_generated_manifest_passes_the_public_secret_scanner(self) -> None:
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
