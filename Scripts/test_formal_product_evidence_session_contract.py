#!/usr/bin/env python3

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ORCHESTRATOR = ROOT / "Scripts/run_formal_product_evidence_session.sh"
LIFECYCLE_ORCHESTRATOR = ROOT / "Scripts/run_formal_ios_identity_lifecycle.sh"
ALL_ORCHESTRATOR = ROOT / "Scripts/run_all_formal_product_evidence.sh"
IOS_CAPTURE = ROOT / "Scripts/capture_ios_product_process_oslog.sh"
IOS_EXTRACTOR = ROOT / "Scripts/extract_ios_product_release_evidence.py"
IDENTITY_EXTRACTOR = ROOT / "Scripts/extract_ios_production_identity_evidence.py"
IOS_INSTALLATION = ROOT / "Scripts/ios_product_installation.py"
MANIFEST_BUILDER = ROOT / "Scripts/formal_product_evidence_manifest.py"
DIAGNOSTIC_PRODUCERS = (
    ROOT / "Scripts/run_real_device_p2p_remote_smoke.sh",
    ROOT / "Scripts/run_real_device_webrtc_smoke.sh",
    ROOT / "Scripts/run_real_device_file_transfer_smoke.sh",
)


class FormalProductEvidenceSessionContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.orchestrator = ORCHESTRATOR.read_text(encoding="utf-8")
        cls.lifecycle = LIFECYCLE_ORCHESTRATOR.read_text(encoding="utf-8")
        cls.all_orchestrator = ALL_ORCHESTRATOR.read_text(encoding="utf-8")
        cls.ios_capture = IOS_CAPTURE.read_text(encoding="utf-8")
        cls.ios_extractor = IOS_EXTRACTOR.read_text(encoding="utf-8")
        cls.identity_extractor = IDENTITY_EXTRACTOR.read_text(encoding="utf-8")
        cls.ios_installation = IOS_INSTALLATION.read_text(encoding="utf-8")
        cls.manifest_builder = MANIFEST_BUILDER.read_text(encoding="utf-8")

    def test_formal_front_doors_use_only_shipping_entry_points(self) -> None:
        combined = self.orchestrator + self.lifecycle
        for required in (
            '/usr/bin/open "$CANDIDATE_APP"',
            "device process launch",
            "com.skybridge.compass.ios",
            "Manual ordinary-product checkpoint",
            "Type COMPLETE",
        ):
            self.assertIn(required, combined)
        for forbidden in (
            "LocalLanInteropHost",
            "LocalWebRTCSmokeHarness",
            "LocalP2PFileTransferSmokeHarness",
            "SKYBRIDGE_TESTING",
            "SKYBRIDGE_SMOKE_ROLE",
            "--environment-variables",
            "--terminate-existing",
            "AUTO_APPROVE",
        ):
            self.assertNotIn(forbidden, combined)

    def test_formal_kind_run_has_no_diagnostic_supplemental_input(self) -> None:
        for forbidden in (
            "--supplemental-dir",
            "supplemental-release-acceptance",
            "mac.status.log",
            "ios.status.log",
            "product-path-proof.json",
            "webrtc_media_doctor.json",
            "p2p-approval-proof.json",
        ):
            self.assertNotIn(forbidden, self.orchestrator)
        for required in (
            "collect_product_release_evidence_log.sh",
            "ios-product-session.log",
            "ios-product-installation-capture.json",
            "ios-production-identity-proof.json",
        ):
            self.assertIn(required, self.orchestrator)

    def test_sealed_app_is_installed_before_every_owned_launch(self) -> None:
        for source in (self.orchestrator, self.lifecycle):
            install = source.index("device install app")
            verify = source.index("ios_product_installation.py")
            launch = source.index("device process launch")
            self.assertLess(install, verify)
            self.assertLess(verify, launch)
            self.assertIn("--launch-persistent-identifier", source)
            self.assertIn("--installation-binding", source)
            self.assertIn("ios-postinstall-prelaunch-processes.json", source)
        for required in (
            "launchServicesIdentifier",
            "devicectl.device.install.app",
            "devicectl.device.info.apps",
            "appExecutableUUIDs",
            "validate_release_testing_ipa",
            "remoteApplicationPath",
            "installedApplications",
        ):
            self.assertIn(required, self.ios_installation)

    def test_identity_lifecycle_is_one_time_and_kind_runs_only_cross_bind(self) -> None:
        for required in (
            "extract-lifecycle",
            "--private-binding",
            "--public-proof",
            "first-product.ndjson",
            "second-product.ndjson",
        ):
            self.assertIn(required, self.lifecycle)
        for required in (
            "--identity-lifecycle-binding",
            "--identity-lifecycle-proof",
            "extract-session-proof",
            "--product-artifact-dir",
            '--kind "$KIND"',
        ):
            self.assertIn(required, self.orchestrator)
        self.assertNotIn("extract-lifecycle", self.orchestrator)
        for forbidden in ("security delete", "delete-generic-password", "SecItemDelete"):
            self.assertNotIn(forbidden, self.lifecycle)

    def test_top_level_all_transaction_keeps_private_identity_ephemeral(self) -> None:
        for required in (
            '"$LIFECYCLE_PRODUCER"',
            '"$KIND_PRODUCER"',
            "kind_specs=(",
            '"connectivity|real-device-connectivity-matrix-public-redacted"',
            '"p2p|real-device-p2p-remote-smoke-public-redacted"',
            '"webrtc|real-device-webrtc-smoke-public-redacted"',
            '"file-transfer|real-device-file-transfer-smoke-public-redacted"',
            'id1:[0-9a-f]{32}',
            '/bin/rm -rf "$LIFECYCLE_RUNTIME"',
            'mv "$PUBLIC_STAGING" "$PUBLIC_EVIDENCE_ROOT"',
        ):
            self.assertIn(required, self.all_orchestrator)
        lifecycle = self.all_orchestrator.index('"$LIFECYCLE_PRODUCER"')
        kinds = self.all_orchestrator.index('for spec in "${kind_specs[@]}"')
        publish = self.all_orchestrator.index(
            'mv "$PUBLIC_STAGING" "$PUBLIC_EVIDENCE_ROOT"'
        )
        self.assertLess(lifecycle, kinds)
        self.assertLess(kinds, publish)
        self.assertNotIn("upload", self.all_orchestrator.lower())

    def test_private_identity_reference_never_enters_public_proof(self) -> None:
        for required in (
            '"deviceRef": "identity-1"',
            "public identity proof contains the private",
            "validate-lifecycle-proof",
            "validate-proof",
        ):
            self.assertIn(required, self.identity_extractor)
        self.assertIn("raw stable production identity reference", (
            ROOT / "Scripts/real_device_smoke_redaction.sh"
        ).read_text(encoding="utf-8"))

    def test_current_ios_capture_is_exact_pid_and_archive_bound(self) -> None:
        for required in (
            "processIdentifier == $IOS_PROCESS_ID",
            'subsystem == \\"com.skybridge.compass.release-evidence\\"',
            'category == \\"ProductSession\\"',
            "bind-launch",
        ):
            self.assertIn(required, self.ios_capture)
        for required in (
            'row.get("processID") != identity["processIdentifier"]',
            '!= identity["executablePath"]',
            '"iosReleaseArchive": binding',
            '"releaseArchiveBindingVerified": True',
            "IDENTITY_EVENT_NAMES",
        ):
            self.assertIn(required, self.ios_extractor)

    def test_process_cleanup_precedes_manifest_and_public_finalization(self) -> None:
        ios_cleanup = self.orchestrator.index(
            "skybridge_ios_require_app_absent_after_handle_exit"
        )
        mac_cleanup = self.orchestrator.rindex("skybridge_mac_terminate_owned_process")
        manifest = self.orchestrator.index('"$MANIFEST_BUILDER"')
        materialize = self.orchestrator.index(
            "skybridge_smoke_materialize_public_artifacts"
        )
        finalize = self.orchestrator.index('"$FINALIZER"')
        acceptance = self.orchestrator.index('"$ACCEPTANCE_VALIDATOR"')
        self.assertLess(ios_cleanup, manifest)
        self.assertLess(mac_cleanup, manifest)
        self.assertLess(manifest, materialize)
        self.assertLess(materialize, finalize)
        self.assertLess(finalize, acceptance)

    def test_candidate_bit_is_derived_after_all_fixed_validators(self) -> None:
        validate_log = self.manifest_builder.index(
            "validate_artifact_log(artifact_dir, kind)"
        )
        validate_install = self.manifest_builder.index("validate_installation_capture(")
        validate_identity = self.manifest_builder.index(
            "validate_production_identity_proof("
        )
        candidate = self.manifest_builder.index('"preCleanupCandidate": True')
        self.assertLess(validate_log, candidate)
        self.assertLess(validate_install, candidate)
        self.assertLess(validate_identity, candidate)
        self.assertNotIn('"acceptanceEligible": True', self.manifest_builder)

    def test_both_ios_identifiers_are_public_redaction_tokens(self) -> None:
        materialize = self.orchestrator[
            self.orchestrator.index("skybridge_smoke_materialize_public_artifacts"):
        ]
        self.assertIn('"$IOS_DEVICE_ID" "$IOS_DEVICE_UDID"', materialize)
        check = materialize[materialize.index("skybridge_smoke_check_public_artifacts"):]
        self.assertIn('"$IOS_DEVICE_ID" "$IOS_DEVICE_UDID"', check)

    def test_old_smoke_front_doors_remain_explicitly_diagnostic(self) -> None:
        expected_messages = (
            "LocalLanInteropHost remains diagnostic-only",
            "LocalWebRTCSmokeHarness remains diagnostic-only",
            "LocalP2PFileTransferSmokeHarness remains diagnostic-only",
        )
        for path, message in zip(DIAGNOSTIC_PRODUCERS, expected_messages):
            with self.subTest(producer=path.name):
                source = path.read_text(encoding="utf-8")
                self.assertIn(message, source)

    def test_final_manual_contract_preserves_all_release_semantics(self) -> None:
        for required in (
            "xwing/xwing",
            "xwing/pqc",
            "pqc/xwing",
            "signed classic offer",
            "two different P2P sessions",
            "peer renderer acknowledgement",
            "at least 31 seconds",
            "Mac-to-iOS and one iOS-to-Mac",
        ):
            self.assertIn(required, self.orchestrator)


if __name__ == "__main__":
    unittest.main()
