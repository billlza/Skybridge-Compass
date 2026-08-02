#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT_DIR / "Scripts" / "validate_real_device_release_acceptance_artifact.py"
SOURCE_REPOSITORY = "billlza/Skybridge-Compass"
SOURCE_COMMIT = "a" * 40
SOURCE_REVISION_REF = hashlib.sha256(SOURCE_COMMIT.encode("ascii")).hexdigest()[:24]
PRODUCTION_COMPILATION_CONDITIONS = ["HAS_APPLE_PQC_SDK"]


class ReleaseAcceptanceArtifactTests(unittest.TestCase):
    def run_validator(self, kind: str, directory: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(VALIDATOR),
                "--kind",
                kind,
                "--artifact-dir",
                str(directory),
                "--expected-source-repository",
                SOURCE_REPOSITORY,
                "--expected-source-sha",
                SOURCE_COMMIT,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def write_json(self, path: Path, payload: object) -> None:
        if (
            path.name == "release-acceptance.json"
            and isinstance(payload, dict)
            and payload.get("transport") == "p2p"
        ):
            raw_notice_session = "peer:192.0.2.10"
            payload = {
                "humanApproval": True,
                "runtimeAutoApproval": False,
                "finalizationOrder": "private-then-public-v1",
                "approvalSessionRef": hashlib.sha256(raw_notice_session.encode()).hexdigest()[:24],
                "approvalLifecycle": ["Shown", "PanelPresented", "HumanApproved", "Approved", "Active"],
                "iosBuildConfiguration": "Release",
                "iosReleaseConfiguration": True,
                "iosSourceClean": True,
                "sourceRepository": SOURCE_REPOSITORY,
                "sourceCommit": SOURCE_COMMIT,
                "iosSourceRevisionRef": SOURCE_REVISION_REF,
                "iosProductSurface": "production",
                "iosSwiftActiveCompilationConditions": PRODUCTION_COMPILATION_CONDITIONS,
                "iosTestingCompilationCondition": False,
                "iosBinaryTestSurfaceDetected": False,
                "iosProductionProduct": True,
                "iosProductionIdentityAlgorithm": "mldsa87",
                "iosProductionIdentityProtection": "secureEnclaveRequired",
                "iosProductionIdentityLifecycleVerified": True,
                "iosProductionIdentityProof": True,
                "iosProductBundle": True,
                "iosSignatureVerified": True,
                "iosProfileVerified": True,
                "iosTeamMatch": True,
                "iosCertificateMatch": True,
                "iosCertificateNotExpired": True,
                "iosProfileNotExpired": True,
                "iosProfileDeviceBound": True,
                "iosDistributionSigning": True,
                "iosExpectedEntitlementsMatch": True,
                "iosKeychainGroupsVerified": True,
                "iosNestedWidgetVerified": True,
                "iosGetTaskAllow": False,
                "iosProductProof": True,
                **payload,
            }
        if (
            path.name == "release-acceptance.json"
            and isinstance(payload, dict)
            and payload.get("transport") == "webrtc"
        ):
            payload = {
                "keychainMode": "system",
                "macKeychainMode": "system",
                "iosKeychainMode": "system",
                "macProductPath": True,
                "iosProductPath": True,
                "approvalSurface": "shared-product-panel",
                "humanApproval": True,
                "runtimeAutoApproval": False,
                "finalizationOrder": "private-then-public-v1",
                "macSystemKeychainProof": True,
                "macAuthBindingVerified": True,
                "iosSystemKeychainProof": True,
                "cleanupComplete": True,
                "preCleanupCandidate": True,
                "diagnosticOnly": False,
                "iosBuildConfiguration": "Release",
                "iosSourceDirtyState": "clean",
                "sourceRepository": SOURCE_REPOSITORY,
                "sourceCommit": SOURCE_COMMIT,
                "iosSourceCommit": SOURCE_COMMIT,
                "iosProductSurface": "production",
                "iosSwiftActiveCompilationConditions": PRODUCTION_COMPILATION_CONDITIONS,
                "iosTestingCompilationCondition": False,
                "iosBinaryTestSurfaceDetected": False,
                "iosProductionProduct": True,
                "iosProductionIdentityAlgorithm": "mldsa87",
                "iosProductionIdentityProtection": "secureEnclaveRequired",
                "iosProductionIdentityLifecycleVerified": True,
                "iosProductionIdentityProof": True,
                "iosReleaseProvenanceVerified": True,
                "iosGetTaskAllowDisabled": True,
                "iosProfileNotExpired": True,
                "iosProfileDeviceBound": True,
                "iosProfileTeamMatchesSignature": True,
                "iosSigningCertificateTrusted": True,
                "iosSigningCertificateInProfile": True,
                "iosSigningCertificateNotExpired": True,
                "iosDistributionSigningVerified": True,
                "iosKeychainGroupsMatchProfile": True,
                "iosExpectedEntitlementsMatch": True,
                "iosNestedWidgetVerified": True,
                **payload,
            }
        path.write_text(json.dumps(payload), encoding="utf-8")
        path.chmod(0o600)

    def write_valid_production_identity_proof(self, directory: Path) -> None:
        self.write_json(
            directory / "ios-production-identity-proof.json",
            {
                "schemaVersion": 1,
                "sourceRepository": SOURCE_REPOSITORY,
                "sourceCommit": SOURCE_COMMIT,
                "productSurface": "production",
                "swiftActiveCompilationConditions": PRODUCTION_COMPILATION_CONDITIONS,
                "testingCompilationCondition": False,
                "binaryTestSurfaceDetected": False,
                "realDevice": True,
                "measurementSource": "signed-production-app-runtime",
                "algorithm": "mldsa87",
                "protection": "secureEnclaveRequired",
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
                "deviceRef": "0123456789abcdef01234567",
                "evidenceSessionRef": "89abcdef0123456789abcdef",
            },
        )

    def write_valid_p2p_logs(self, directory: Path) -> None:
        raw_notice_session = "peer:192.0.2.10"
        notice_session_ref = hashlib.sha256(raw_notice_session.encode()).hexdigest()[:24]
        (directory / "mac.status.log").write_text(
            "identity legacyResidueInspectionComplete=1 conflicts=1 reason=none\n"
            f"remoteControlNoticeShown session={raw_notice_session} transport=p2p\n"
            f"remoteControlNoticePanelPresented session={raw_notice_session} transport=p2p phase=awaitingApproval buttons=collapse,close,reject,approve\n"
            f"remoteControlNoticeHumanApproved session={raw_notice_session} transport=p2p\n"
            f"remoteControlNoticeApproved session={raw_notice_session} transport=p2p\n"
            f"remoteControlNoticeActive session={raw_notice_session} transport=p2p\n"
            "success suite=X-Wing handshakeOnly=1\n"
            "smoke-final result=success validated=1 route=lan-main\n",
            encoding="utf-8",
        )
        self.write_json(
            directory / "p2p-approval-proof.json",
            {
                "schemaVersion": 1,
                "sessionRef": notice_session_ref,
                "humanApproval": True,
                "runtimeAutoApproval": False,
                "lifecycle": ["Shown", "PanelPresented", "HumanApproved", "Approved", "Active"],
                "panelActionsVerified": True,
            },
        )
        self.write_json(
            directory / "ios-product-proof.json",
            {
                "schemaVersion": 1,
                "configuration": "Release",
                "releaseConfiguration": True,
                "sourceClean": True,
                "sourceRepository": SOURCE_REPOSITORY,
                "sourceCommit": SOURCE_COMMIT,
                "sourceRevisionRef": SOURCE_REVISION_REF,
                "productSurface": "production",
                "swiftActiveCompilationConditions": PRODUCTION_COMPILATION_CONDITIONS,
                "testingCompilationCondition": False,
                "binaryTestSurfaceDetected": False,
                "productionProduct": True,
                "productBundle": True,
                "signatureVerified": True,
                "profileVerified": True,
                "teamMatch": True,
                "certificateMatch": True,
                "certificateNotExpired": True,
                "profileNotExpired": True,
                "profileDeviceBound": True,
                "distributionSigning": True,
                "expectedEntitlementsMatch": True,
                "keychainGroupsVerified": True,
                "nestedWidgetVerified": True,
                "getTaskAllow": False,
            },
        )
        self.write_valid_production_identity_proof(directory)
        (directory / "ios-p2p-remote-test.status.log").write_text(
            "success suite=X-Wing handshakeOnly=1 remoteDesktop=1\n"
            "p2p-inbound handshake-established peer=<redacted> suite=X-Wing\n"
            "lan-remote handshake-established peer=<redacted> suite=X-Wing\n"
            "remote-desktop-pass renderOrientation=upright\n"
            "smoke-final result=success validated=1 route=lan-main\n",
            encoding="utf-8",
        )
        (directory / "mac-online-ipad.status.log").write_text(
            "mac-online-connect action=button clickSource=accessibility targetRowBound=1\n"
            "mac-online-connect-start targetFamily=ipad evidenceSource=external-ax\n"
            "mac-online-connect-app action=button targetFamily=ipad result=success source=OnlineDeviceCard\n"
            "mac-online-device-ui targetFamily=ipad status=connected\n"
            "p2p-connection-ready-path deviceId=id:target endpointClass=service pathStatus=satisfied usedInterfaceTypes=wifi usedInterfaceNames=en0 routeClass=wifi attached=0 linkLocal=0\n"
            "mac remote established peer=<redacted> suite=X-Wing\n"
            "mac-online-connect-result action=button result=success status=connected\n",
            encoding="utf-8",
        )

    def write_valid_p2p_artifact(self, directory: Path) -> None:
        self.write_json(
            directory / "release-acceptance.json",
            {
                "schemaVersion": 1,
                "transport": "p2p",
                "realDevice": True,
                "acceptanceEligible": True,
                "labRun": False,
                "trustMode": "actual",
                "keychainMode": "system",
                "injectedTrust": False,
                "inMemoryKeychain": False,
                "iosToMacRemoteControl": True,
                "macToIOSConnection": True,
                "reverseCryptoHandshakeComplete": True,
                "bidirectionalHandshake": True,
                "diagnosticOnly": False,
                "cleanupComplete": True,
                "preCleanupCandidate": True,
                "macOnlineSource": "packaged",
                "macOnlineSourceCurrent": True,
                "macHostLaunchMode": "packaged",
                "macHostDiagnosticOnly": False,
                "identitySourceStaplerValid": True,
                "identitySourceGatekeeperAccepted": True,
            },
        )
        self.write_valid_p2p_logs(directory)

    def write_valid_webrtc_artifact(self, directory: Path) -> None:
        session_ref = "0123456789abcdef01234567"
        manifest = {
            "schemaVersion": 1,
            "transport": "webrtc",
            "realDevice": True,
            "acceptanceEligible": True,
            "labRun": False,
            "forceRelayIce": True,
            "requireAudio": True,
            "relayPreflight": True,
            "relayCandidateObserved": True,
            "syntheticScreen": False,
            "syntheticAudio": False,
            "soakSeconds": 10,
            "macHandshakeComplete": True,
            "iosHandshakeComplete": True,
            "macPQCRekeyComplete": True,
            "iosPQCRekeyComplete": True,
            "mutualHandshake": True,
            "sessionRef": session_ref,
            "relayCandidateSessionRef": session_ref,
            "observedGateWindowMillis": 10_000,
            "mediaEvidenceWindowMillis": 10_000,
        }
        required_checks = {
            "diagnostic_sources",
            "diagnostic_samples",
            "video_fps",
            "video_resolution",
            "native_video_health",
            "native_video_rtc_stats",
            "sck_vt_encode_latency",
            "native_video_receiver",
            "visible_native_render",
            "visible_render_fps",
            "audio_activity_continuity",
            "audio_playback_continuity",
            "audio_relay_startup",
            "audio_tx_captured",
            "audio_tx_encoded",
            "audio_tx_sent",
            "audio_rx_recv",
            "audio_rx_decoded",
            "audio_rx_played",
            "audio_rendered_frames",
            "strict_media_failure",
            "stale_fallback",
            "backpressure",
            "probable_fault_stage",
        }
        self.write_json(directory / "release-acceptance.json", manifest)
        self.write_json(
            directory / "product-path-proof.json",
            {
                "schemaVersion": 1,
                "keychainMode": "system",
                "macProductBundle": True,
                "macProductSignatureVerified": True,
                "macProductProfileVerified": True,
                "iosProductBundle": True,
                "iosProductSignatureVerified": True,
                "iosProductProfileVerified": True,
                "iosProfileNotExpired": True,
                "iosProfileDeviceBound": True,
                "iosProfileTeamMatchesSignature": True,
                "iosSigningCertificateTrusted": True,
                "iosSigningCertificateInProfile": True,
                "iosSigningCertificateNotExpired": True,
                "iosDistributionSigningVerified": True,
                "iosKeychainGroupsMatchProfile": True,
                "iosExpectedEntitlementsMatch": True,
                "iosNestedWidgetVerified": True,
                "iosGetTaskAllowDisabled": True,
                "iosReleaseProvenanceVerified": True,
                "iosBuildConfiguration": "Release",
                "iosSourceDirtyState": "clean",
                "sourceRepository": SOURCE_REPOSITORY,
                "sourceCommit": SOURCE_COMMIT,
                "iosSourceCommit": SOURCE_COMMIT,
                "iosProductSurface": "production",
                "iosSwiftActiveCompilationConditions": PRODUCTION_COMPILATION_CONDITIONS,
                "iosTestingCompilationCondition": False,
                "iosBinaryTestSurfaceDetected": False,
                "iosProductionProduct": True,
            },
        )
        self.write_json(
            directory / "webrtc_media_doctor.json",
            {
                "sessionRef": session_ref,
                "observedGateWindowMillis": 10_000,
                "mediaEvidenceWindowMillis": 10_000,
                "gateSessionBound": True,
                "checks": [
                    {"name": name, "ok": True, "severity": "info"}
                    for name in sorted(required_checks)
                ],
            },
        )
        (directory / "mac.status.log").write_text(
            "webrtc-config session=<redacted> role=offerer relayOnly=true turn=true turnUrls=1\n"
            "rekey session=<redacted> complete suite=X-Wing\n"
            "keychain-proof platform=mac mode=system auth=existing-product-session identity=system authBinding=verified productBundle=true\n"
            "remoteControlNoticePanelPresented session=<redacted> transport=webrtc phase=awaitingApproval buttons=collapse,close,reject,approve\n"
            "remoteControlNoticeHumanApproved session=<redacted> transport=webrtc\n"
            "remoteControlNoticeApproved session=<redacted> transport=webrtc\n"
            "remoteControlNoticeActive session=<redacted> transport=webrtc\n"
            "success session=<redacted> suite=X-Wing stream=true\n"
            f"release-session-binding role=mac sessionRef={session_ref} handshake=1 rekey=1\n",
            encoding="utf-8",
        )
        (directory / "media-relay-preflight.log").write_text(
            "udp_bind_probe=ok bytes=20\n", encoding="utf-8"
        )
        (directory / "ios-real-webrtc-1.status.log").write_text(
            "handshake session=<redacted> suite=X25519-Ed25519\n"
            "rekey session=<redacted> complete suite=X-Wing\n"
            "keychain-proof platform=ios mode=system auth=existing-product-session productBundle=true\n"
            f"release-session-binding role=ios sessionRef={session_ref} handshake=1 rekey=1\n",
            encoding="utf-8",
        )
        (directory / "ios-real-webrtc-1.status.log.trace.log").write_text(
            f"release-session-binding role=relay-candidate sessionRef={session_ref} candidate=relay\n",
            encoding="utf-8",
        )
        (directory / "ios-real-webrtc-1.status.log.webrtc-media.jsonl").write_text(
            f'{{"release_session_ref":"{session_ref}","timestamp":"2026-07-10T00:00:00.000Z","frames":1}}\n'
            f'{{"release_session_ref":"{session_ref}","timestamp":"2026-07-10T00:00:10.000Z","frames":2}}\n',
            encoding="utf-8",
        )
        self.write_valid_production_identity_proof(directory)

    def test_p2p_rejects_injected_or_in_memory_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "schemaVersion": 1,
                "transport": "p2p",
                "realDevice": True,
                "acceptanceEligible": True,
                "labRun": False,
                "trustMode": "injected",
                "keychainMode": "in-memory",
                "injectedTrust": True,
                "inMemoryKeychain": True,
                "runtimeAutoApproval": False,
                "iosToMacRemoteControl": True,
                "macToIOSConnection": True,
                "reverseCryptoHandshakeComplete": True,
                "bidirectionalHandshake": True,
                "diagnosticOnly": False,
                "cleanupComplete": True,
                "preCleanupCandidate": True,
                "macOnlineSource": "packaged",
                "macOnlineSourceCurrent": True,
                "macHostLaunchMode": "packaged",
                "macHostDiagnosticOnly": False,
                "identitySourceStaplerValid": True,
                "identitySourceGatekeeperAccepted": True,
            }
            self.write_json(directory / "release-acceptance.json", manifest)
            result = self.run_validator("p2p", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("injected trust is diagnostic-only", result.stdout)

    def test_p2p_accepts_real_system_trust_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            result = self.run_validator("p2p", directory)
            self.assertEqual(result.returncode, 0, result.stdout)

    def test_production_identity_contract_accepts_same_repo_sha_mldsa87_secure_enclave(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_production_identity_proof(directory)
            result = self.run_validator("production-identity", directory)
            self.assertEqual(result.returncode, 0, result.stdout)

    def test_p2p_rejects_testing_compilation_surface(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            product_path = directory / "ios-product-proof.json"
            product = json.loads(product_path.read_text(encoding="utf-8"))
            product.update(
                {
                    "productSurface": "testing",
                    "swiftActiveCompilationConditions": [
                        "HAS_APPLE_PQC_SDK",
                        "SKYBRIDGE_TESTING",
                    ],
                    "testingCompilationCondition": True,
                    "binaryTestSurfaceDetected": True,
                    "productionProduct": False,
                }
            )
            self.write_json(product_path, product)
            result = self.run_validator("p2p", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("productSurface must be production", result.stdout)

    def test_production_identity_contract_rejects_cross_repository_or_sha(self) -> None:
        for key, value, expected in (
            ("sourceRepository", "attacker/fork", "sourceRepository does not match"),
            ("sourceCommit", "b" * 40, "sourceCommit does not match"),
        ):
            with self.subTest(key=key):
                with tempfile.TemporaryDirectory() as raw:
                    directory = Path(raw)
                    self.write_valid_production_identity_proof(directory)
                    proof_path = directory / "ios-production-identity-proof.json"
                    proof = json.loads(proof_path.read_text(encoding="utf-8"))
                    proof[key] = value
                    self.write_json(proof_path, proof)
                    result = self.run_validator("production-identity", directory)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stdout)

    def test_production_identity_contract_rejects_malformed_repository(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_production_identity_proof(directory)
            proof_path = directory / "ios-production-identity-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["sourceRepository"] = "../.."
            self.write_json(proof_path, proof)
            result = self.run_validator("production-identity", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be an owner/repository identifier", result.stdout)

    def test_production_identity_contract_rejects_wrong_algorithm_or_protection(self) -> None:
        for key, value, expected in (
            ("algorithm", "mldsa65", "algorithm must be mldsa87"),
            ("protection", "software", "protection must be secureEnclaveRequired"),
        ):
            with self.subTest(key=key):
                with tempfile.TemporaryDirectory() as raw:
                    directory = Path(raw)
                    self.write_valid_production_identity_proof(directory)
                    proof_path = directory / "ios-production-identity-proof.json"
                    proof = json.loads(proof_path.read_text(encoding="utf-8"))
                    proof[key] = value
                    self.write_json(proof_path, proof)
                    result = self.run_validator("production-identity", directory)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stdout)

    def test_production_identity_contract_rejects_missing_relaunch_persistence(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_production_identity_proof(directory)
            proof_path = directory / "ios-production-identity-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["restoredAfterRelaunch"] = False
            self.write_json(proof_path, proof)
            result = self.run_validator("production-identity", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("restoredAfterRelaunch must be true", result.stdout)

    def test_p2p_rejects_debug_ios_product_proof(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            proof_path = directory / "ios-product-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["configuration"] = "Debug"
            self.write_json(proof_path, proof)

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("product proof configuration must be Release", result.stdout)

    def test_p2p_rejects_get_task_allow_ios_product_proof(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            proof_path = directory / "ios-product-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["getTaskAllow"] = True
            self.write_json(proof_path, proof)

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("product proof requires getTaskAllow=false", result.stdout)

    def test_p2p_rejects_expired_profile_ios_product_proof(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            proof_path = directory / "ios-product-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["profileNotExpired"] = False
            self.write_json(proof_path, proof)

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires profileNotExpired=true", result.stdout)

    def test_p2p_rejects_wrong_team_ios_product_proof(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            proof_path = directory / "ios-product-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["teamMatch"] = False
            self.write_json(proof_path, proof)

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires teamMatch=true", result.stdout)

    def test_p2p_rejects_wrong_certificate_ios_product_proof(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            proof_path = directory / "ios-product-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["certificateMatch"] = False
            self.write_json(proof_path, proof)

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires certificateMatch=true", result.stdout)

    def test_p2p_rejects_unverified_nested_widget_product_proof(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            proof_path = directory / "ios-product-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["nestedWidgetVerified"] = False
            self.write_json(proof_path, proof)

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires nestedWidgetVerified=true", result.stdout)

    def test_p2p_rejects_dirty_source_provenance_ios_product_proof(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            proof_path = directory / "ios-product-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["sourceClean"] = False
            self.write_json(proof_path, proof)

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires sourceClean=true", result.stdout)

    def test_p2p_rejects_incomplete_legacy_residue_inspection(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            status_path = directory / "mac.status.log"
            status_path.write_text(
                status_path.read_text(encoding="utf-8").replace(
                    "identity legacyResidueInspectionComplete=1 conflicts=1 reason=none",
                    "identity legacyResidueInspectionComplete=0 conflicts=unknown reason=keychain-unavailable",
                ),
                encoding="utf-8",
            )

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("complete legacy-residue inspection", result.stdout)

    def test_p2p_rejects_approved_without_human_approved_event(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            status_path = directory / "mac.status.log"
            status = status_path.read_text(encoding="utf-8")
            status_path.write_text(
                status.replace(
                    "remoteControlNoticeHumanApproved session=peer:192.0.2.10 transport=p2p\n",
                    "",
                ),
                encoding="utf-8",
            )

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("same-session HumanApproved", result.stdout)

    def test_p2p_rejects_human_approved_from_a_different_session(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            status_path = directory / "mac.status.log"
            status = status_path.read_text(encoding="utf-8")
            status_path.write_text(
                status.replace(
                    "remoteControlNoticeHumanApproved session=peer:192.0.2.10 transport=p2p",
                    "remoteControlNoticeHumanApproved session=peer:192.0.2.11 transport=p2p",
                ),
                encoding="utf-8",
            )

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("same-session HumanApproved", result.stdout)

    def test_p2p_rejects_runtime_auto_approval_after_session_field(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            status_path = directory / "mac.status.log"
            status_path.write_text(
                status_path.read_text(encoding="utf-8")
                + "approval-audit session=peer:192.0.2.10 runtimeAutoApproval=true\n",
                encoding="utf-8",
            )

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("runtime auto-approval evidence", result.stdout)

    def test_p2p_rejects_pre_cleanup_candidate_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_json(
                directory / "release-acceptance.json",
                {
                    "schemaVersion": 1,
                    "transport": "p2p",
                    "realDevice": True,
                    "acceptanceEligible": False,
                    "diagnosticOnly": True,
                    "cleanupComplete": False,
                    "preCleanupCandidate": True,
                    "labRun": False,
                },
            )
            result = self.run_validator("p2p", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cleanupComplete must be true", result.stdout)

    def test_p2p_rejects_false_candidate_claiming_post_cleanup_green(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_json(
                directory / "release-acceptance.json",
                {
                    "schemaVersion": 1,
                    "transport": "p2p",
                    "realDevice": True,
                    "acceptanceEligible": True,
                    "diagnosticOnly": False,
                    "cleanupComplete": True,
                    "preCleanupCandidate": False,
                    "labRun": False,
                },
            )
            result = self.run_validator("p2p", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("preCleanupCandidate must be true", result.stdout)

    def test_p2p_rejects_exact_product_signed_debug_mac_online_source(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "schemaVersion": 1,
                "transport": "p2p",
                "realDevice": True,
                "acceptanceEligible": True,
                "diagnosticOnly": False,
                "cleanupComplete": True,
                "preCleanupCandidate": True,
                "labRun": False,
                "trustMode": "actual",
                "keychainMode": "system",
                "injectedTrust": False,
                "inMemoryKeychain": False,
                "runtimeAutoApproval": False,
                "iosToMacRemoteControl": True,
                "macToIOSConnection": True,
                "reverseCryptoHandshakeComplete": True,
                "bidirectionalHandshake": True,
                "macOnlineSource": "debug",
                "macOnlineSourceCurrent": True,
                "macHostLaunchMode": "packaged",
                "macHostDiagnosticOnly": False,
                "identitySourceStaplerValid": True,
                "identitySourceGatekeeperAccepted": True,
            }
            self.write_json(directory / "release-acceptance.json", manifest)
            self.write_valid_p2p_logs(directory)
            result = self.run_validator("p2p", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Debug product-identity signing is diagnostic-only", result.stdout)

    def test_p2p_rejects_signed_lab_host_even_when_other_fields_claim_formal(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_p2p_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["macHostLaunchMode"] = "packaged-lab"
            manifest["macHostDiagnosticOnly"] = True
            manifest["identitySourceStaplerValid"] = False
            manifest["identitySourceGatekeeperAccepted"] = False
            self.write_json(manifest_path, manifest)

            result = self.run_validator("p2p", directory)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("macHostLaunchMode must be packaged", result.stdout)

    def test_p2p_rejects_missing_mac_host_distribution_proof(self) -> None:
        for field, expected in (
            ("identitySourceStaplerValid", "identitySourceStaplerValid must be true"),
            (
                "identitySourceGatekeeperAccepted",
                "identitySourceGatekeeperAccepted must be true",
            ),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                self.write_valid_p2p_artifact(directory)
                manifest_path = directory / "release-acceptance.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                manifest[field] = False
                self.write_json(manifest_path, manifest)

                result = self.run_validator("p2p", directory)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stdout)

    def test_p2p_rejects_stale_packaged_mac_online_source(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "schemaVersion": 1,
                "transport": "p2p",
                "realDevice": True,
                "acceptanceEligible": True,
                "diagnosticOnly": False,
                "cleanupComplete": True,
                "preCleanupCandidate": True,
                "labRun": False,
                "trustMode": "actual",
                "keychainMode": "system",
                "injectedTrust": False,
                "inMemoryKeychain": False,
                "runtimeAutoApproval": False,
                "iosToMacRemoteControl": True,
                "macToIOSConnection": True,
                "reverseCryptoHandshakeComplete": True,
                "bidirectionalHandshake": True,
                "macOnlineSource": "packaged",
                "macOnlineSourceCurrent": False,
                "macHostLaunchMode": "packaged",
                "macHostDiagnosticOnly": False,
                "identitySourceStaplerValid": True,
                "identitySourceGatekeeperAccepted": True,
            }
            self.write_json(directory / "release-acceptance.json", manifest)
            self.write_valid_p2p_logs(directory)
            result = self.run_validator("p2p", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("macOnlineSourceCurrent must be true", result.stdout)

    def test_p2p_rejects_manifest_without_bidirectional_handshake(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "schemaVersion": 1,
                "transport": "p2p",
                "realDevice": True,
                "acceptanceEligible": True,
                "labRun": False,
                "trustMode": "actual",
                "keychainMode": "system",
                "injectedTrust": False,
                "inMemoryKeychain": False,
                "runtimeAutoApproval": False,
                "iosToMacRemoteControl": True,
                "macToIOSConnection": False,
                "reverseCryptoHandshakeComplete": False,
                "bidirectionalHandshake": False,
                "diagnosticOnly": False,
                "cleanupComplete": True,
                "preCleanupCandidate": True,
                "macOnlineSource": "packaged",
                "macOnlineSourceCurrent": True,
                "macHostLaunchMode": "packaged",
                "macHostDiagnosticOnly": False,
                "identitySourceStaplerValid": True,
                "identitySourceGatekeeperAccepted": True,
            }
            self.write_json(directory / "release-acceptance.json", manifest)
            self.write_valid_p2p_logs(directory)
            result = self.run_validator("p2p", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("macToIOSConnection must be true", result.stdout)

    def test_p2p_rejects_missing_reverse_status_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "schemaVersion": 1,
                "transport": "p2p",
                "realDevice": True,
                "acceptanceEligible": True,
                "labRun": False,
                "trustMode": "actual",
                "keychainMode": "system",
                "injectedTrust": False,
                "inMemoryKeychain": False,
                "runtimeAutoApproval": False,
                "iosToMacRemoteControl": True,
                "macToIOSConnection": True,
                "reverseCryptoHandshakeComplete": True,
                "bidirectionalHandshake": True,
                "diagnosticOnly": False,
                "cleanupComplete": True,
                "preCleanupCandidate": True,
                "macOnlineSource": "packaged",
                "macOnlineSourceCurrent": True,
                "macHostLaunchMode": "packaged",
                "macHostDiagnosticOnly": False,
                "identitySourceStaplerValid": True,
                "identitySourceGatekeeperAccepted": True,
            }
            self.write_json(directory / "release-acceptance.json", manifest)
            self.write_valid_p2p_logs(directory)
            (directory / "mac-online-ipad.status.log").unlink()
            result = self.run_validator("p2p", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing Mac-to-iOS P2P status log", result.stdout)

    def test_p2p_rejects_reverse_ui_success_without_crypto_handshake(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "schemaVersion": 1,
                "transport": "p2p",
                "realDevice": True,
                "acceptanceEligible": True,
                "labRun": False,
                "trustMode": "actual",
                "keychainMode": "system",
                "injectedTrust": False,
                "inMemoryKeychain": False,
                "runtimeAutoApproval": False,
                "iosToMacRemoteControl": True,
                "macToIOSConnection": True,
                "reverseCryptoHandshakeComplete": True,
                "bidirectionalHandshake": True,
                "diagnosticOnly": False,
                "cleanupComplete": True,
                "preCleanupCandidate": True,
                "macOnlineSource": "packaged",
                "macOnlineSourceCurrent": True,
                "macHostLaunchMode": "packaged",
                "macHostDiagnosticOnly": False,
                "identitySourceStaplerValid": True,
                "identitySourceGatekeeperAccepted": True,
            }
            self.write_json(directory / "release-acceptance.json", manifest)
            self.write_valid_p2p_logs(directory)
            reverse = directory / "mac-online-ipad.status.log"
            reverse.write_text(
                reverse.read_text(encoding="utf-8").replace(
                    "mac remote established peer=<redacted> suite=X-Wing\n", ""
                ),
                encoding="utf-8",
            )
            result = self.run_validator("p2p", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("authenticated X-Wing", result.stdout)

    def test_p2p_rejects_attached_product_route(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "schemaVersion": 1,
                "transport": "p2p",
                "realDevice": True,
                "acceptanceEligible": True,
                "labRun": False,
                "trustMode": "actual",
                "keychainMode": "system",
                "injectedTrust": False,
                "inMemoryKeychain": False,
                "runtimeAutoApproval": False,
                "iosToMacRemoteControl": True,
                "macToIOSConnection": True,
                "reverseCryptoHandshakeComplete": True,
                "bidirectionalHandshake": True,
                "diagnosticOnly": False,
                "cleanupComplete": True,
                "preCleanupCandidate": True,
                "macOnlineSource": "packaged",
                "macOnlineSourceCurrent": True,
                "macHostLaunchMode": "packaged",
                "macHostDiagnosticOnly": False,
                "identitySourceStaplerValid": True,
                "identitySourceGatekeeperAccepted": True,
            }
            self.write_json(directory / "release-acceptance.json", manifest)
            self.write_valid_p2p_logs(directory)
            reverse = directory / "mac-online-ipad.status.log"
            reverse.write_text(
                reverse.read_text(encoding="utf-8").replace(
                    "usedInterfaceTypes=wifi usedInterfaceNames=en0 routeClass=wifi attached=0 linkLocal=0",
                    "usedInterfaceTypes=wiredEthernet usedInterfaceNames=en9 routeClass=attached attached=1 linkLocal=1",
                ),
                encoding="utf-8",
            )
            result = self.run_validator("p2p", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("product Wi-Fi/AWDL P2P path", result.stdout)

    def test_webrtc_rejects_degraded_acceptance_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "schemaVersion": 1,
                "transport": "webrtc",
                "realDevice": True,
                "acceptanceEligible": True,
                "labRun": False,
                "forceRelayIce": False,
                "requireAudio": False,
                "relayPreflight": False,
                "relayCandidateObserved": False,
                "syntheticScreen": True,
                "syntheticAudio": True,
                "soakSeconds": 0,
                "macHandshakeComplete": False,
                "iosHandshakeComplete": False,
                "macPQCRekeyComplete": False,
                "iosPQCRekeyComplete": False,
                "mutualHandshake": False,
            }
            self.write_json(directory / "release-acceptance.json", manifest)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("forceRelayIce must be true", result.stdout)

    def test_webrtc_rejects_missing_relay_candidate_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "schemaVersion": 1,
                "transport": "webrtc",
                "realDevice": True,
                "acceptanceEligible": True,
                "labRun": False,
                "forceRelayIce": True,
                "requireAudio": True,
                "relayPreflight": True,
                "relayCandidateObserved": False,
                "syntheticScreen": False,
                "syntheticAudio": False,
                "soakSeconds": 10,
                "macHandshakeComplete": True,
                "iosHandshakeComplete": True,
                "macPQCRekeyComplete": True,
                "iosPQCRekeyComplete": True,
                "mutualHandshake": True,
                "sessionRef": "0123456789abcdef01234567",
                "relayCandidateSessionRef": "0123456789abcdef01234567",
                "observedGateWindowMillis": 10_000,
                "mediaEvidenceWindowMillis": 10_000,
            }
            self.write_json(directory / "release-acceptance.json", manifest)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("relayCandidateObserved must be true", result.stdout)

    def test_webrtc_requires_complete_passing_doctor_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "schemaVersion": 1,
                "transport": "webrtc",
                "realDevice": True,
                "acceptanceEligible": True,
                "labRun": False,
                "forceRelayIce": True,
                "requireAudio": True,
                "relayPreflight": True,
                "relayCandidateObserved": True,
                "syntheticScreen": False,
                "syntheticAudio": False,
                "soakSeconds": 10,
                "macHandshakeComplete": True,
                "iosHandshakeComplete": True,
                "macPQCRekeyComplete": True,
                "iosPQCRekeyComplete": True,
                "mutualHandshake": True,
                "sessionRef": "0123456789abcdef01234567",
                "relayCandidateSessionRef": "0123456789abcdef01234567",
                "observedGateWindowMillis": 10_000,
                "mediaEvidenceWindowMillis": 10_000,
            }
            self.write_json(directory / "release-acceptance.json", manifest)
            self.write_json(
                directory / "webrtc_media_doctor.json",
                {
                    "sessionRef": "0123456789abcdef01234567",
                    "observedGateWindowMillis": 10_000,
                    "mediaEvidenceWindowMillis": 10_000,
                    "gateSessionBound": True,
                    "checks": [],
                },
            )
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing checks", result.stdout)

    def test_webrtc_accepts_strict_real_device_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            result = self.run_validator("webrtc", directory)
            self.assertEqual(result.returncode, 0, result.stdout)

    def test_webrtc_rejects_mismatched_session_reference_after_redaction(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            mac_status = directory / "mac.status.log"
            mac_status.write_text(
                mac_status.read_text(encoding="utf-8").replace(
                    "sessionRef=0123456789abcdef01234567",
                    "sessionRef=89abcdef0123456789abcdef",
                ),
                encoding="utf-8",
            )
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("macOS WebRTC status is not bound", result.stdout)

    def test_webrtc_rejects_missing_audio_counter_check(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            doctor_path = directory / "webrtc_media_doctor.json"
            doctor = json.loads(doctor_path.read_text(encoding="utf-8"))
            doctor["checks"] = [
                check for check in doctor["checks"] if check["name"] != "audio_rx_played"
            ]
            self.write_json(doctor_path, doctor)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("audio_rx_played", result.stdout)

    def test_webrtc_rejects_short_media_evidence_window(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            media_path = directory / "ios-real-webrtc-1.status.log.webrtc-media.jsonl"
            media_path.write_text(
                media_path.read_text(encoding="utf-8").replace(
                    "2026-07-10T00:00:10.000Z", "2026-07-10T00:00:01.000Z"
                ),
                encoding="utf-8",
            )
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("do not span the required soak window", result.stdout)

    def test_webrtc_rejects_stale_failed_stage(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            with (directory / "ios-real-webrtc-1.status.log").open("a", encoding="utf-8") as handle:
                handle.write("failed stage=handshake error=stale_failure\n")
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("iOS WebRTC status contains a failed stage", result.stdout)

    def test_webrtc_rejects_in_memory_identity_for_release(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["keychainMode"] = "in-memory"
            self.write_json(manifest_path, manifest)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("keychainMode must be system", result.stdout)

    def test_webrtc_rejects_programmatic_approval_without_human_event(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            mac_status = directory / "mac.status.log"
            mac_status.write_text(
                mac_status.read_text(encoding="utf-8").replace(
                    "remoteControlNoticeHumanApproved session=<redacted> transport=webrtc\n",
                    "",
                ),
                encoding="utf-8",
            )
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("human panel approval", result.stdout)

    def test_webrtc_rejects_pre_cleanup_candidate_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest.update(
                {
                    "acceptanceEligible": False,
                    "cleanupComplete": False,
                    "preCleanupCandidate": True,
                    "diagnosticOnly": True,
                }
            )
            self.write_json(manifest_path, manifest)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cleanupComplete must be true", result.stdout)

    def test_webrtc_rejects_false_cleanup_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["preCleanupCandidate"] = False
            self.write_json(manifest_path, manifest)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("preCleanupCandidate must be true", result.stdout)

    def test_webrtc_rejects_debug_ios_product_proof(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["iosBuildConfiguration"] = "Debug"
            self.write_json(manifest_path, manifest)
            proof_path = directory / "product-path-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["iosBuildConfiguration"] = "Debug"
            self.write_json(proof_path, proof)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("iosBuildConfiguration must be Release", result.stdout)

    def test_webrtc_rejects_get_task_allow_ios_product_proof(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["iosGetTaskAllowDisabled"] = False
            self.write_json(manifest_path, manifest)
            proof_path = directory / "product-path-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["iosGetTaskAllowDisabled"] = False
            self.write_json(proof_path, proof)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("iosGetTaskAllowDisabled must be true", result.stdout)

    def test_webrtc_rejects_development_signed_ios_product_proof(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["iosDistributionSigningVerified"] = False
            self.write_json(manifest_path, manifest)
            proof_path = directory / "product-path-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["iosDistributionSigningVerified"] = False
            self.write_json(proof_path, proof)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("iosDistributionSigningVerified must be true", result.stdout)

    def test_webrtc_rejects_dirty_ios_product_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["iosSourceDirtyState"] = "dirty"
            self.write_json(manifest_path, manifest)
            proof_path = directory / "product-path-proof.json"
            proof = json.loads(proof_path.read_text(encoding="utf-8"))
            proof["iosSourceDirtyState"] = "dirty"
            proof["iosReleaseProvenanceVerified"] = False
            self.write_json(proof_path, proof)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("iosSourceDirtyState must be clean", result.stdout)

    def test_webrtc_rejects_missing_product_auth_binding(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            mac_status = directory / "mac.status.log"
            mac_status.write_text(
                mac_status.read_text(encoding="utf-8").replace(" authBinding=verified", ""),
                encoding="utf-8",
            )
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("system-Keychain product session", result.stdout)

    def test_rejects_boolean_schema_version(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["schemaVersion"] = True
            self.write_json(manifest_path, manifest)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("schemaVersion must be 1", result.stdout)

    def test_rejects_unproven_finalization_order(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["finalizationOrder"] = "public-then-private"
            self.write_json(manifest_path, manifest)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("finalizationOrder must be private-then-public-v1", result.stdout)

    def test_rejects_release_manifest_with_group_read_mode(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            manifest_path.chmod(0o640)
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mode must be 0600", result.stdout)

    def test_rejects_hard_linked_release_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            self.write_valid_webrtc_artifact(directory)
            manifest_path = directory / "release-acceptance.json"
            os.link(manifest_path, directory / "release-acceptance-hard-link.json")
            result = self.run_validator("webrtc", directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exactly one filesystem link", result.stdout)


if __name__ == "__main__":
    unittest.main()
