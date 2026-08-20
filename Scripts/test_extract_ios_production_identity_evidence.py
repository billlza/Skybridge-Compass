#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import extract_ios_production_identity_evidence as identity_evidence
from ios_physical_release_acceptance import expected_binding


IDENTITY_REFERENCE = "id1:0123456789abcdef0123456789abcdef"
SESSION_REFERENCE = "ev1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
ATTEMPT_REFERENCE = "at1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
EXECUTABLE_PATH = (
    "/private/var/containers/Bundle/Application/release/"
    "SkyBridgeCompass-iOS.app/SkyBridgeCompass-iOS"
)


class IOSProductionIdentityEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive = {
            "identityPurpose": "detect-accidental-cross-run-mismatch",
            "archiveTreeSha256": "1" * 64,
            "releaseTestingIpaSha256": "2" * 64,
            "appExecutableUUIDs": [
                {"architecture": "arm64", "uuid": "a" * 36}
            ],
            "widgetExecutableUUIDs": [
                {"architecture": "arm64", "uuid": "b" * 36}
            ],
            "debugSymbolsVerified": True,
            "sourceInputDigest": "3" * 64,
            "releaseVersion": "1.0.2",
            "releaseBuild": "2",
            "sourceRepository": "owner/repository",
            "sourceCommit": "c" * 40,
            "swiftActiveCompilationConditions": ["HAS_APPLE_PQC_SDK"],
        }
        self.installation = {
            "iosReleaseArchive": expected_binding(self.archive),
            "schemaVersion": 1,
        }
        self.first_identity = self._launch_identity(101, "1000:1")
        self.second_identity = self._launch_identity(202, "2000:2")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _launch_identity(self, process_id: int, start_time: str) -> dict[str, object]:
        return {
            "processIdentifier": process_id,
            "startTimeToken": start_time,
            "installationBinding": self.installation,
            "executablePath": EXECUTABLE_PATH,
        }

    def _row(self, process_id: int, message: str) -> str:
        return json.dumps(
            {
                "eventType": "logEvent",
                "messageType": "Default",
                "subsystem": identity_evidence.SUBSYSTEM,
                "category": identity_evidence.CATEGORY,
                "processID": process_id,
                "processImagePath": EXECUTABLE_PATH,
                "formatString": "%{public}s",
                "eventMessage": message,
            },
            separators=(",", ":"),
        )

    def _committed(self, reference: str = IDENTITY_REFERENCE) -> str:
        return (
            "productionIdentityCommitted "
            f"identity_ref={reference} algorithm=mldsa87 "
            "protection=secureEnclaveRequired persistence=keychain-authority "
            "created=1 result=success"
        )

    def _restored(self, reference: str = IDENTITY_REFERENCE) -> str:
        return (
            "productionIdentityRestored "
            f"identity_ref={reference} algorithm=mldsa87 "
            "protection=secureEnclaveRequired persistence=keychain-authority "
            "selfTest=verified result=success"
        )

    def _bound(
        self,
        reference: str = IDENTITY_REFERENCE,
        session_reference: str = SESSION_REFERENCE,
    ) -> str:
        return (
            "productionIdentityHandshakeBound transport=p2p "
            f"session_ref={session_reference} attempt_ref={ATTEMPT_REFERENCE} "
            f"identity_ref={reference} algorithm=mldsa87 "
            "protection=secureEnclaveRequired localSignature=used "
            "peerVerification=authenticated-finished "
            "currentPathAuthority=verified result=success"
        )

    def _write_logs(
        self,
        first_messages: list[str],
        second_messages: list[str],
    ) -> tuple[Path, Path]:
        first = self.root / "first.ndjson"
        second = self.root / "second.ndjson"
        first.write_text(
            "\n".join(self._row(101, message) for message in first_messages) + "\n",
            encoding="utf-8",
        )
        second.write_text(
            "\n".join(self._row(202, message) for message in second_messages) + "\n",
            encoding="utf-8",
        )
        return first, second

    def _extract(
        self,
        first_messages: list[str] | None = None,
        second_messages: list[str] | None = None,
        identities: tuple[dict[str, object], dict[str, object]] | None = None,
    ) -> Path:
        first, second = self._write_logs(
            first_messages or [self._committed()],
            second_messages or [self._restored(), self._bound()],
        )
        output = self.root / "ios-production-identity-proof.json"
        launch_identities = identities or (self.first_identity, self.second_identity)
        with (
            mock.patch.object(
                identity_evidence.product_evidence,
                "_validate_private_launch_identity",
                side_effect=launch_identities,
            ),
            mock.patch.object(
                identity_evidence,
                "load_identity",
                return_value=self.archive,
            ),
        ):
            identity_evidence.extract(
                first_raw_oslog=first,
                first_launch_identity=self.root / "first-launch.json",
                second_raw_oslog=second,
                second_launch_identity=self.root / "second-launch.json",
                archive_identity=self.root / "archive.json",
                output=output,
            )
        return output

    def test_extracts_two_launch_lifecycle_without_public_stable_identifier(self) -> None:
        output = self._extract()
        proof = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(proof["deviceRef"], "identity-1")
        self.assertEqual(proof["evidenceSessionRef"], SESSION_REFERENCE)
        self.assertTrue(proof["created"])
        self.assertTrue(proof["restoredAfterRelaunch"])
        self.assertTrue(proof["handshakePersistenceVerified"])
        public_text = output.read_text(encoding="utf-8")
        self.assertNotIn(IDENTITY_REFERENCE, public_text)
        self.assertNotIn(IDENTITY_REFERENCE[4:], public_text)
        self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)

    def test_rejects_same_process_or_start_token_as_fake_relaunch(self) -> None:
        duplicate = self._launch_identity(101, "1000:1")
        with self.assertRaisesRegex(
            identity_evidence.ProductionIdentityEvidenceError,
            "two distinct fresh product launches",
        ):
            self._extract(identities=(self.first_identity, duplicate))

    def test_rejects_stale_or_different_identity_across_launches(self) -> None:
        different = "id1:fedcba9876543210fedcba9876543210"
        with self.assertRaisesRegex(
            identity_evidence.ProductionIdentityEvidenceError,
            "identities do not match",
        ):
            self._extract(
                second_messages=[self._restored(different), self._bound(different)]
            )

    def test_rejects_wrong_order_duplicate_and_wrong_session(self) -> None:
        cases = (
            [self._bound(), self._restored()],
            [self._restored(), self._restored(), self._bound()],
            [self._restored(), self._bound(session_reference="ev1:short")],
        )
        for index, messages in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(
                identity_evidence.ProductionIdentityEvidenceError
            ):
                self._extract(second_messages=messages)

    def test_public_proof_validator_rejects_private_reference_and_wrong_alias(self) -> None:
        output = self._extract()
        proof = json.loads(output.read_text(encoding="utf-8"))
        proof["deviceRef"] = IDENTITY_REFERENCE
        output.write_text(json.dumps(proof), encoding="utf-8")
        os.chmod(output, 0o600)
        with self.assertRaises(identity_evidence.ProductionIdentityEvidenceError):
            identity_evidence.validate_public_proof(output)

    def test_source_contract_has_no_hidden_trigger_or_raw_secret_field(self) -> None:
        repository = Path(__file__).resolve().parents[1]
        recorder = (
            repository
            / "SkyBridge Compass iOS"
            / "SkyBridgeCompassiOS"
            / "Sources"
            / "Core"
            / "Diagnostics"
            / "ProductReleaseEvidenceRecorder.swift"
        ).read_text(encoding="utf-8")
        parser = (repository / "Scripts" / "extract_ios_production_identity_evidence.py").read_text(
            encoding="utf-8"
        )
        for forbidden in (
            "ProcessInfo.processInfo.environment",
            "SKYBRIDGE_SMOKE",
            "SKYBRIDGE_TESTING",
            "#if DEBUG",
            "privateKey=",
            "publicKey=",
            "fingerprint=",
            "deviceId=",
            "userId=",
            "remoteIP=",
        ):
            self.assertNotIn(forbidden, recorder)
            self.assertNotIn(forbidden, parser)


if __name__ == "__main__":
    unittest.main()
