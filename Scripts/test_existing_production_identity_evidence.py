#!/usr/bin/env python3
"""Exercise versioned identity proof extraction using real files and CLI parsing.

These are synthetic validator inputs, never physical-device acceptance receipts.
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

import extract_ios_production_identity_evidence as evidence
import test_extract_ios_product_release_evidence as launch_fixtures
import test_validate_product_release_evidence_log as log_fixtures
from product_release_evidence_test_fixtures import connectivity_product_logs

V = evidence.product_lifecycle
REFERENCE = "id1:" + "a" * 32
Q = evidence.Q_AUTHENTICATED_SUITE


class ExistingProductionIdentityEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.files = launch_fixtures.IOSProductEvidenceExtractionTests()
        self.files.setUp()
        self.addCleanup(self.files.tearDown)
        self.root = self.files.root
        self.protection = "softwareKeychain"
        self.policy = evidence.IdentityEvidencePolicy(
            evidence.IdentityEvidencePurpose.EXISTING, "0x0012", self.protection
        )
        original = json.loads(self.files.identity.read_text())
        self.launches: list[Path] = []
        for index in (1, 2, 3):
            value = copy.deepcopy(original)
            value["processIdentifier"] = 8100 + index
            value["auditToken"][5] = 8100 + index
            value["startTimeToken"] = f"170000000{index}:123456"
            path = self.files.private / f"launch-{index}.json"
            self.write_json(path, value)
            self.launches.append(path)
        self.binding = self.files.private / "lifecycle-binding.json"
        self.lifecycle = self.files.output / "lifecycle.json"

    @staticmethod
    def write_json(path: Path, value: object) -> None:
        path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
        path.chmod(0o600)

    def restored(self, reference: str = REFERENCE) -> str:
        return (
            f"productionIdentityRestored identity_ref={reference} algorithm=mldsa65 "
            f"protection={self.protection} persistence=keychain-authority "
            "selfTest=verified result=success"
        )

    def raw(self, index: int, messages: list[str]) -> Path:
        path = self.files.private / f"raw-{index}.ndjson"
        rows = [
            {
                "eventType": "logEvent",
                "messageType": "Default",
                "subsystem": evidence.SUBSYSTEM,
                "category": evidence.CATEGORY,
                "processID": 8100 + index,
                "processImagePath": self.files.executable_path,
                "formatString": "%{public}s",
                "eventMessage": message,
            }
            for message in messages
        ]
        path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
        path.chmod(0o600)
        return path

    def lifecycle_arguments(self) -> dict[str, object]:
        return {
            "first_raw_oslog": self.raw(1, [self.restored()]),
            "first_launch_identity": self.launches[0],
            "second_raw_oslog": self.raw(2, [self.restored()]),
            "second_launch_identity": self.launches[1],
            "archive_identity": self.files.archive_identity,
            "private_binding": self.binding,
            "public_proof": self.lifecycle,
            "policy": self.policy,
        }

    def establish_lifecycle(self) -> None:
        evidence.extract_lifecycle(**self.lifecycle_arguments())

    def artifact(self, kind: str, *, q: bool = True) -> Path:
        if kind == "connectivity":
            mac, ios = connectivity_product_logs(include_q=q)
        else:
            mac, ios = {
                "p2p": (log_fixtures.p2p_remote_lines(), log_fixtures.p2p_ios_lines()),
                "webrtc": (
                    log_fixtures.webrtc_remote_lines(),
                    log_fixtures.webrtc_ios_lines(),
                ),
                "file-transfer": (
                    log_fixtures.file_transfer_lines(),
                    log_fixtures.file_transfer_ios_lines(),
                ),
            }[kind]
            if q:
                mac = [line.replace("suite=X-Wing", f"suite={Q}") for line in mac]
                ios = [line.replace("suite=X-Wing", f"suite={Q}") for line in ios]
        root = self.root / f"product-{kind}-{q}"
        root.mkdir()
        return log_fixtures.ProductReleaseEvidenceLogTests().write_artifact(
            root, mac, ios_lines=ios
        )

    def bound(self, kind: str, session: str) -> str:
        transport = "webrtc" if kind == "webrtc" else "p2p"
        attempt = "not-applicable" if transport == "webrtc" else "at1:" + "6" * 32
        return (
            f"productionIdentityHandshakeBound transport={transport} session_ref={session} "
            f"attempt_ref={attempt} identity_ref={REFERENCE} algorithm=mldsa65 "
            f"protection={self.protection} localSignature=used "
            "peerVerification=authenticated-finished currentPathAuthority=verified result=success "
            f"suite={Q} suite_wire=0x0012 localFinished=sent peerFinished=verified"
        )

    def session_arguments(self, artifact: Path, kind: str) -> dict[str, object]:
        sessions = V.product_session_references(artifact, kind, expected_suite="0x0012")
        return {
            "lifecycle_binding": self.binding,
            "lifecycle_proof": self.lifecycle,
            "current_raw_oslog": self.raw(
                3,
                [self.restored()] + [self.bound(kind, ref) for ref in sorted(sessions)],
            ),
            "current_launch_identity": self.launches[2],
            "archive_identity": self.files.archive_identity,
            "product_artifact_dir": artifact,
            "kind": kind,
            "output": artifact / "ios-production-identity-proof.json",
            "policy": self.policy,
        }

    def test_real_file_lifecycle_and_current_session_cover_all_four_product_kinds(
        self,
    ) -> None:
        self.establish_lifecycle()
        for kind in evidence.FORMAL_KINDS:
            with self.subTest(kind=kind):
                artifact = self.artifact(kind)
                args = self.session_arguments(artifact, kind)
                evidence.extract_session_proof(**args)
                proof = evidence.validate_public_proof(
                    args["output"], archive_identity=self.files.archive_identity
                )
                self.assertEqual(proof["expectedSuite"], "0x0012")
                self.assertEqual(proof["continuity"], "cold-start-restoration")
                self.assertIsNone(proof["baselineArchive"])
                self.assertNotIn("created", proof)
                self.assertIs(proof["secureEnclaveBacked"], False)
                self.assertNotIn("id1:", json.dumps(proof))
                self.assertEqual(
                    set(proof["evidenceSessionRefs"]),
                    V.product_session_references(
                        artifact, kind, expected_suite="0x0012"
                    ),
                )
                V.validate_capture(artifact)
        self.assertEqual(os.stat(self.binding).st_mode & 0o777, 0o600)
        self.assertEqual(
            evidence._read_private_binding(self.binding)["identityReference"], REFERENCE
        )

    def test_secure_enclave_protection_is_reported_only_when_explicit_and_observed(
        self,
    ) -> None:
        self.protection = "secureEnclaveRequired"
        self.policy = evidence.IdentityEvidencePolicy(
            evidence.IdentityEvidencePurpose.EXISTING, "0x0012", self.protection
        )
        self.establish_lifecycle()
        proof = evidence.validate_lifecycle_proof(self.lifecycle)
        self.assertIs(proof["secureEnclaveBacked"], True)
        self.assertIs(proof["softwareFallbackUsed"], False)

    def test_existing_purpose_rejects_creation_and_changed_identity(self) -> None:
        for first, second in (
            (
                self.restored()
                .replace("Restored", "Committed")
                .replace("selfTest=verified", "created=1"),
                self.restored(),
            ),
            (self.restored(), self.restored("id1:" + "b" * 32)),
            (
                self.restored(),
                self.restored().replace("selfTest=verified", "selfTest=failed"),
            ),
        ):
            with self.subTest(first=first, second=second):
                args = self.lifecycle_arguments()
                args["first_raw_oslog"] = self.raw(1, [first])
                args["second_raw_oslog"] = self.raw(2, [second])
                with self.assertRaises(evidence.ProductionIdentityEvidenceError):
                    evidence.extract_lifecycle(**args)
                self.assertFalse(self.binding.exists())
                self.assertFalse(self.lifecycle.exists())

    def test_default_creation_contract_does_not_accept_existing_identity(self) -> None:
        args = self.lifecycle_arguments()
        args["policy"] = evidence.IdentityEvidencePolicy()
        with self.assertRaises(evidence.ProductionIdentityEvidenceError):
            evidence.extract_lifecycle(**args)

    def test_current_terminal_rejects_missing_finished_wrong_identity_and_suite(
        self,
    ) -> None:
        self.establish_lifecycle()
        artifact = self.artifact("webrtc")
        args = self.session_arguments(artifact, "webrtc")
        good = args["current_raw_oslog"].read_text()
        for old, new in (
            ("localFinished=sent", "localFinished=pending"),
            ("peerFinished=verified", "peerFinished=unverified"),
            ("suite_wire=0x0012", "suite_wire=0x0001"),
            (f"suite={Q}", "suite=X-Wing"),
            ("currentPathAuthority=verified", "currentPathAuthority=failed"),
            ("localSignature=used", "localSignature=missing"),
            ("attempt_ref=not-applicable", "attempt_ref=at1:" + "6" * 32),
            (REFERENCE, "id1:" + "b" * 32),
            ("algorithm=mldsa65", "algorithm=mldsa87"),
            ("protection=softwareKeychain", "protection=secureEnclaveRequired"),
        ):
            with self.subTest(mutation=old):
                args["current_raw_oslog"].write_text(good.replace(old, new))
                with self.assertRaises(evidence.ProductionIdentityEvidenceError):
                    evidence.extract_session_proof(**args)
                self.assertFalse(args["output"].exists())

    def test_actual_product_suite_cannot_be_replaced_by_identity_claims(self) -> None:
        self.establish_lifecycle()
        for kind in evidence.FORMAL_KINDS:
            with self.subTest(kind=kind):
                artifact = self.artifact(kind, q=False)
                with self.assertRaises(V.ProductEvidenceError):
                    V.validate_artifact_log(artifact, kind, expected_suite="0x0012")
        artifact = self.artifact("connectivity")
        for name in (V.MAC_LOG_FILE, V.IOS_LOG_FILE):
            p = artifact / name
            p.write_text(p.read_text().replace(f"suite={Q}", "suite=ML-KEM-768"))
        with self.assertRaisesRegex(V.ProductEvidenceError, "Q connectivity pair"):
            V.validate_artifact_log(artifact, "connectivity", expected_suite="0x0012")

    def test_current_launch_and_exact_session_cannot_be_replayed(self) -> None:
        self.establish_lifecycle()
        artifact = self.artifact("p2p")
        args = self.session_arguments(artifact, "p2p")
        original = args["current_raw_oslog"].read_text()
        refs = sorted(
            V.product_session_references(artifact, "p2p", expected_suite="0x0012")
        )
        for wrong in (
            original.replace(refs[0], "ev1:" + "f" * 32),
            "\n".join(original.splitlines()[:2]) + "\n",
        ):
            args["current_raw_oslog"].write_text(wrong)
            with self.assertRaises(evidence.ProductionIdentityEvidenceError):
                evidence.extract_session_proof(**args)
        args["current_raw_oslog"].write_text(original)
        args["current_launch_identity"] = self.launches[1]
        with self.assertRaisesRegex(
            evidence.ProductionIdentityEvidenceError, "new exact launch"
        ):
            evidence.extract_session_proof(**args)

    def test_private_binding_is_not_accepted_with_public_file_permissions(self) -> None:
        self.establish_lifecycle()
        self.binding.chmod(0o644)
        with self.assertRaisesRegex(evidence.ProductionIdentityEvidenceError, "0600"):
            evidence._read_private_binding(self.binding)

    def test_connectivity_identity_terminal_must_match_its_actual_attempt(self) -> None:
        self.establish_lifecycle()
        artifact = self.artifact("connectivity")
        args = self.session_arguments(artifact, "connectivity")
        raw = args["current_raw_oslog"]
        raw.write_text(
            raw.read_text().replace(
                "attempt_ref=at1:" + "6" * 32, "attempt_ref=at1:" + "7" * 32
            )
        )
        with self.assertRaisesRegex(
            evidence.ProductionIdentityEvidenceError, "attempt owner"
        ):
            evidence.extract_session_proof(**args)

    def test_upgrade_continuity_requires_a_distinct_bound_prior_archive_and_same_identity(
        self,
    ) -> None:
        original_archive = json.loads(self.files.archive_identity.read_text())
        old_archive = original_archive | {
            "releaseBuild": "41",
            "archiveTreeSha256": "f" * 64,
            "sourceCommit": "2" * 40,
        }
        original_launches = [json.loads(path.read_text()) for path in self.launches]
        self.write_json(self.files.archive_identity, old_archive)
        for path, original in zip(self.launches, original_launches):
            old = copy.deepcopy(original)
            old["installationBinding"]["iosReleaseArchive"] = evidence.expected_binding(
                old_archive
            )
            self.write_json(path, old)
        self.establish_lifecycle()
        prior_binding = self.binding.with_name("prior-binding.json")
        self.binding.rename(prior_binding)
        self.lifecycle.rename(self.lifecycle.with_name("prior-lifecycle.json"))
        self.write_json(self.files.archive_identity, original_archive)
        for path, original in zip(self.launches, original_launches):
            self.write_json(path, original)
        args = self.lifecycle_arguments() | {"baseline_binding": prior_binding}
        prior = json.loads(prior_binding.read_text())
        self.write_json(prior_binding, prior | {"identityReference": "id1:" + "c" * 32})
        with self.assertRaisesRegex(
            evidence.ProductionIdentityEvidenceError, "actual identity"
        ):
            evidence.extract_lifecycle(**args)
        self.write_json(prior_binding, prior)
        evidence.extract_lifecycle(**args)
        proof = evidence.validate_lifecycle_proof(self.lifecycle)
        self.assertEqual(proof["continuity"], "upgrade-baseline-bound")
        self.assertEqual(
            proof["baselineArchive"], evidence.expected_binding(old_archive)
        )
        tampered = proof | {"baselineArchive": proof["iosReleaseArchive"]}
        self.write_json(self.lifecycle, tampered)
        with self.assertRaisesRegex(
            evidence.ProductionIdentityEvidenceError, "different installed archive"
        ):
            evidence.validate_lifecycle_proof(self.lifecycle)

    def test_legacy_creation_cli_contract_still_proves_new_commit_then_restore(
        self,
    ) -> None:
        args = self.lifecycle_arguments()
        restored = (
            self.restored()
            .replace("mldsa65", "mldsa87")
            .replace("softwareKeychain", "secureEnclaveRequired")
        )
        args.update(
            policy=evidence.IdentityEvidencePolicy(),
            first_raw_oslog=self.raw(
                1,
                [
                    restored.replace("Restored", "Committed").replace(
                        "selfTest=verified", "created=1"
                    )
                ],
            ),
            second_raw_oslog=self.raw(2, [restored]),
        )
        evidence.extract_lifecycle(**args)
        artifact = self.artifact("webrtc", q=False)
        session = self.session_arguments(artifact, "webrtc")
        ref = next(iter(V.product_session_references(artifact, "webrtc")))
        terminal = (
            self.bound("webrtc", ref)
            .split(" suite=")[0]
            .replace("mldsa65", "mldsa87")
            .replace("softwareKeychain", "secureEnclaveRequired")
        )
        session.update(
            policy=evidence.IdentityEvidencePolicy(),
            current_raw_oslog=self.raw(3, [restored, terminal]),
        )
        evidence.extract_session_proof(**session)
        proof = evidence.validate_public_proof(session["output"])
        self.assertEqual(proof["schemaVersion"], 1)
        self.assertIs(proof["created"], True)
        self.assertEqual(proof["algorithm"], "mldsa87")

    def test_formal_entrypoints_reject_incomplete_q_policy_before_device_actions(
        self,
    ) -> None:
        scripts = Path(evidence.__file__).parent
        for name in (
            "run_all_formal_product_evidence.sh",
            "run_formal_ios_identity_lifecycle.sh",
            "run_formal_product_evidence_session.sh",
        ):
            for flags, message in (
                (
                    [
                        "--identity-purpose",
                        "existing-production-identity",
                        "--expected-suite",
                        "0x0012",
                    ],
                    "actual committed key protection",
                ),
                (
                    [
                        "--identity-purpose",
                        "existing-production-identity",
                        "--expected-identity-protection",
                        "softwareKeychain",
                    ],
                    "explicit Q suite",
                ),
                (["--expected-suite", "0x0012"], "original creation purpose"),
            ):
                with self.subTest(script=name, flags=flags):
                    result = subprocess.run(
                        ["/bin/bash", str(scripts / name), *flags],
                        capture_output=True,
                        text=True,
                        timeout=10,
                        check=False,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
                    self.assertNotIn("Installing", result.stdout)

    def test_cli_performs_the_actual_three_launch_extraction(self) -> None:
        args = self.lifecycle_arguments()
        args.pop("policy")
        policy_args = [
            "--identity-purpose",
            self.policy.purpose.value,
            "--expected-suite",
            "0x0012",
            "--expected-identity-protection",
            self.protection,
        ]

        def run(
            command: str, values: dict[str, object]
        ) -> subprocess.CompletedProcess[str]:
            argv = [
                sys.executable,
                "-B",
                "-W",
                "error",
                str(Path(evidence.__file__)),
                command,
                *policy_args,
            ]
            for name, value in values.items():
                argv.extend(["--" + name.replace("_", "-"), str(value)])
            return subprocess.run(
                argv, capture_output=True, text=True, timeout=15, check=False
            )

        result = run("extract-lifecycle", args)
        self.assertEqual(result.returncode, 0, result.stderr)
        artifact = self.artifact("webrtc")
        session = self.session_arguments(artifact, "webrtc")
        session.pop("policy")
        result = run("extract-session-proof", session)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertNotIn(REFERENCE, result.stdout)

    def test_versioned_manifest_cannot_relabel_identity_or_protection(self) -> None:
        self.establish_lifecycle()
        artifact = self.artifact("webrtc")
        args = self.session_arguments(artifact, "webrtc")
        evidence.extract_session_proof(**args)
        proof = evidence.validate_public_proof(args["output"])
        manifest = evidence.identity_manifest_fields(proof)
        self.assertEqual(
            evidence.validate_manifest_identity_policy(manifest), self.policy
        )
        for change in (
            {"schemaVersion": 1},
            {"expectedSuite": "0x0001"},
            {"iosProductionIdentityPurpose": "new-secure-enclave-identity"},
            {"iosProductionIdentityAlgorithm": "mldsa87"},
            {"iosProductionIdentityProtection": "unknown"},
        ):
            with (
                self.subTest(change=change),
                self.assertRaises(evidence.ProductionIdentityEvidenceError),
            ):
                evidence.validate_manifest_identity_policy(manifest | change)


if __name__ == "__main__":
    unittest.main()
