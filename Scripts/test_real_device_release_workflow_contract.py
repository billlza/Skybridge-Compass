#!/usr/bin/env python3
"""Source contracts for candidate -> physical evidence -> publish transaction."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CANDIDATE_WORKFLOW = ROOT / ".github/workflows/macos-release-readiness.yml"
EVIDENCE_WORKFLOW = ROOT / ".github/workflows/real-device-release-gate.yml"
PUBLISH_WORKFLOW = ROOT / ".github/workflows/macos-release-publish.yml"
ACTIONLINT_CONFIG = ROOT / ".github/actionlint.yaml"
CANDIDATE_IDENTITY = ROOT / "Scripts/macos_release_candidate_identity.py"
P2P_PRODUCER = ROOT / "Scripts/run_real_device_p2p_remote_smoke.sh"
WEBRTC_PRODUCER = ROOT / "Scripts/run_real_device_webrtc_smoke.sh"
FILE_TRANSFER_PRODUCER = ROOT / "Scripts/run_real_device_file_transfer_smoke.sh"
IOS_PHYSICAL_ACCEPTANCE = ROOT / "Scripts/ios_physical_release_acceptance.py"
PRODUCT_EVIDENCE_COLLECTOR = ROOT / "Scripts/collect_product_release_evidence_log.sh"
PRODUCT_EVIDENCE_VALIDATOR = ROOT / "Scripts/validate_product_release_evidence_log.py"
CHECKOUT_V6 = "actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803"
UPLOAD_V7 = "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
DOWNLOAD_V8 = "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"

CANONICAL_EVIDENCE = (
    "real-device-connectivity-matrix-public-redacted",
    "real-device-p2p-remote-smoke-public-redacted",
    "real-device-webrtc-smoke-public-redacted",
    "real-device-file-transfer-smoke-public-redacted",
)
LEGACY_NOTICE_EVIDENCE = (
    "real-device-p2p-security-notice-public-redacted",
    "local-webrtc-security-notice-public-redacted",
    "local-macos-security-notice-panel-public-redacted",
)


class ReleaseWorkflowTransactionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.candidate = CANDIDATE_WORKFLOW.read_text(encoding="utf-8")
        cls.evidence = EVIDENCE_WORKFLOW.read_text(encoding="utf-8")
        cls.publish = PUBLISH_WORKFLOW.read_text(encoding="utf-8")

    def test_candidate_workflow_builds_once_before_any_physical_evidence(self) -> None:
        self.assertIn("release_build_id:", self.candidate)
        self.assertIn("macos-signed-release-candidate:", self.candidate)
        build = self.candidate.index("Build Signed + Notarized Release DMG")
        identity = self.candidate.index("Create Immutable Candidate Identity")
        handoff = self.candidate.index("Assemble and Verify Signed Candidate Handoff")
        upload = self.candidate.index("Upload Signed Release Candidate")
        self.assertLess(build, identity)
        self.assertLess(identity, handoff)
        self.assertLess(handoff, upload)
        self.assertIn("macos_release_candidate_identity.py create", self.candidate)
        self.assertIn("--package-integrity-only", self.candidate)
        self.assertNotIn("release_artifact_run_id", self.candidate)
        signed_job = self.candidate[self.candidate.index("  macos-signed-release-candidate:") :]
        self.assertNotIn("publish_macos_update_release.sh", signed_job)
        for name in CANONICAL_EVIDENCE + LEGACY_NOTICE_EVIDENCE:
            self.assertNotIn(name, self.candidate)

    def test_candidate_identity_carries_platform_and_byte_binding(self) -> None:
        identity = CANDIDATE_IDENTITY.read_text(encoding="utf-8")
        for required in (
            "teamIdentifier",
            "cdHash",
            "designatedRequirement",
            "notarizationAccepted",
            "appStaplerValid",
            "dmgStaplerValid",
            "appGatekeeperAccepted",
            "dmgGatekeeperAccepted",
            "appBundleDigest",
            "dmgDigest",
            "detect accidental candidate/evidence mismatch",
        ):
            self.assertIn(required, identity)

    def test_evidence_workflow_is_protected_and_consumes_exact_candidate(self) -> None:
        for required in (
            "runs-on: [self-hosted, macOS, skybridge-real-device-release]",
            "environment: release-real-device-evidence",
            "verify-evidence-environment-protection:",
            "needs: verify-evidence-environment-protection",
            "Require Independent Evidence Approval Environment",
            "validate_release_environment_protection.py",
            "candidate_run_id:",
            "candidate_run_attempt:",
            "CANDIDATE_WORKFLOW_PATH: .github/workflows/macos-release-readiness.yml",
            "CANDIDATE_ARTIFACT_NAME: macos-signed-release-candidate",
            "macos_release_candidate_identity.py verify",
            "macos_release_candidate_identity.py compare",
            '[[ "$(git rev-parse --verify HEAD)" == "$GITHUB_SHA" ]]',
            '--expected-head-sha "$GITHUB_SHA"',
            '--expected-head-branch "$GITHUB_REF_NAME"',
            "ios_archive_identity:",
            "ios_release_testing_ipa:",
            "Verify Sealed iOS Physical Product Inputs",
            "ios_physical_release_acceptance.py verify-product",
            '--ios-archive-identity "$IOS_ARCHIVE_IDENTITY"',
            '--release-testing-ipa "$IOS_RELEASE_TESTING_IPA"',
        ):
            self.assertIn(required, self.evidence)
        candidate_verify = self.evidence.index("Verify and Extract Immutable Signed Candidate")
        evidence_stage = self.evidence.index("Validate and Stage Four Candidate-Bound Physical Artifacts")
        first_upload = self.evidence.index("Upload Connectivity Matrix Evidence")
        self.assertLess(candidate_verify, evidence_stage)
        self.assertLess(evidence_stage, first_upload)

    def test_formal_ios_producers_only_prepare_the_sealed_ipa(self) -> None:
        producers = (
            (P2P_PRODUCER, 'if [[ "$LAB_RUN" != "1" ]]; then'),
            (WEBRTC_PRODUCER, 'if [[ "$LAB_RUN" != "1" ]]; then'),
            (FILE_TRANSFER_PRODUCER, 'if [[ "$USER_REALISTIC" == "1" ]]; then'),
        )
        for path, predicate in producers:
            with self.subTest(producer=path.name):
                source = path.read_text(encoding="utf-8")
                required_message = (
                    "requires SKYBRIDGE_IOS_RELEASE_ARCHIVE_IDENTITY and "
                    "SKYBRIDGE_IOS_RELEASE_TESTING_IPA"
                )
                message_index = source.index(required_message)
                formal_start = source.rfind(predicate, 0, message_index)
                diagnostic_message = source.index(
                    'echo "==> Building diagnostic iOS app for real device',
                    message_index,
                )
                diagnostic_start = source.rfind(
                    "\nelse\n", message_index, diagnostic_message
                )
                formal_branch = source[formal_start:diagnostic_start]
                self.assertGreaterEqual(formal_start, 0)
                self.assertGreaterEqual(diagnostic_start, 0)
                self.assertIn("ios_physical_release_acceptance.py\" prepare-product", formal_branch)
                self.assertIn("build=not-performed", formal_branch)
                for forbidden in (
                    "skybridge_run_xcodebuild",
                    "skybridge_archive_ios_distribution_product",
                    "skybridge_export_ios_distribution_archive",
                    "xcodebuild archive",
                    "xcodebuild -exportArchive",
                ):
                    self.assertNotIn(forbidden, formal_branch)

    def test_archive_binding_is_producer_finalizer_stager_validator_bound(self) -> None:
        physical = IOS_PHYSICAL_ACCEPTANCE.read_text(encoding="utf-8")
        finalizer = (ROOT / "Scripts/finalize_release_acceptance_manifests.py").read_text(
            encoding="utf-8"
        )
        stager = (ROOT / "Scripts/stage_real_device_release_evidence.py").read_text(
            encoding="utf-8"
        )
        validator = (
            ROOT / "Scripts/validate_real_device_release_acceptance_artifact.py"
        ).read_text(encoding="utf-8")
        self.assertIn('manifest["iosReleaseArchive"] = binding', physical)
        self.assertIn('payload.get("iosReleaseArchive") != required_archive_binding', finalizer)
        self.assertIn("recorded_binding != required_binding", stager)
        self.assertIn('manifest.get("iosReleaseArchive") != expected_binding(identity)', validator)

    def test_only_four_canonical_evidence_artifacts_are_formal(self) -> None:
        for name in CANONICAL_EVIDENCE:
            self.assertIn(name, self.evidence)
            self.assertIn(name, self.publish)
        for name in LEGACY_NOTICE_EVIDENCE:
            self.assertNotIn(name, self.evidence)
            self.assertNotIn(name, self.publish)
        for step in (
            "Upload Connectivity Matrix Evidence",
            "Upload P2P Remote Evidence",
            "Upload WebRTC Remote Evidence",
            "Upload File Transfer Evidence",
        ):
            self.assertEqual(self.evidence.count(step), 1)
        self.assertEqual(
            self.evidence.count("skybridge-release-evidence-archives/real-device-"), 4
        )

    def test_publish_workflow_consumes_original_candidate_without_rebuild(self) -> None:
        for required in (
            "environment: macos-production-release",
            "verify-publish-environment-protection:",
            "needs: verify-publish-environment-protection",
            "Require Independent Publication Approval Environment",
            "validate_release_environment_protection.py",
            "contents: write",
            "candidate_run_id:",
            "evidence_run_id:",
            "Verify Immutable Candidate and Four Evidence Artifacts",
            "macos_release_candidate_identity.py verify",
            "macos_release_candidate_identity.py compare",
            "Validate Full Readiness Against Candidate-Bound Evidence",
            "Publish Original Immutable Candidate Bytes",
            "publish_macos_update_release.sh",
            '--app-path "$MACOS_PUBLISH_CANDIDATE_ROOT/SkyBridge Compass Pro.app"',
            '--dmg-path "$MACOS_PUBLISH_DMG_PATH"',
        ):
            self.assertIn(required, self.publish)
        for forbidden in (
            "build_dmg.sh",
            "package_app.sh",
            "swift build",
            "xcodebuild build",
            "--notarize-app",
        ):
            self.assertNotIn(forbidden, self.publish)

    def test_formal_paths_do_not_promote_diagnostic_notice_probes(self) -> None:
        for workflow in (self.candidate, self.evidence, self.publish):
            for forbidden in (
                "run_remote_control_notice_panel_probe.sh",
                "LocalLanInteropHost",
                "SmokeHarness",
                "SKYBRIDGE_TESTING",
                "p2p-notice",
                "webrtc-notice",
                "notice-panel",
            ):
                self.assertNotIn(forbidden, workflow)

    def test_p2p_missing_normal_product_inbound_is_fail_closed(self) -> None:
        p2p = P2P_PRODUCER.read_text(encoding="utf-8")
        self.assertIn("LocalLanInteropHost remains diagnostic-only", p2p)
        self.assertIn("Formal P2P evidence is unavailable", p2p)
        self.assertIn('if [[ "$LAB_RUN" != "1" ]]', p2p)
        self.assertIn('"macRuntimeExecutable": "LocalLanInteropHost"', p2p)
        self.assertIn('"macProductPath": normal_product_p2p_inbound', p2p)
        self.assertIn("normal_product_p2p_inbound = False", p2p)

    def test_webrtc_missing_normal_product_entry_is_fail_closed(self) -> None:
        webrtc = WEBRTC_PRODUCER.read_text(encoding="utf-8")
        for required in (
            "skybridge_bind_macos_release_candidate_evidence",
            "Formal WebRTC evidence is unavailable",
            "LocalWebRTCSmokeHarness remains diagnostic-only",
            '"macRuntimeExecutable": "SkyBridgeCompassApp" if mac_host_mode == "product"',
            '"noticeEvidenceSource": "normal-product-session"',
        ):
            self.assertIn(required, webrtc)

    def test_file_transfer_missing_normal_product_entry_is_fail_closed(self) -> None:
        producer = FILE_TRANSFER_PRODUCER.read_text(encoding="utf-8")
        for required in (
            "skybridge_bind_macos_release_candidate_evidence",
            "Formal file-transfer evidence is unavailable",
            "LocalP2PFileTransferSmokeHarness remains diagnostic-only",
        ):
            self.assertIn(required, producer)

    def test_normal_product_log_is_pid_start_time_and_audit_token_bound(self) -> None:
        collector = PRODUCT_EVIDENCE_COLLECTOR.read_text(encoding="utf-8")
        validator = PRODUCT_EVIDENCE_VALIDATOR.read_text(encoding="utf-8")
        for required in (
            "webrtc_smoke_process_ownership.py",
            "mac-capture",
            "mac-status --identity",
            "--ownership-record",
            "com.skybridge.compass.release-evidence",
            "ProductSession",
        ):
            self.assertIn(required, collector)
        self.assertGreaterEqual(collector.count("mac-status --identity"), 2)
        self.assertNotIn("/bin/ps", collector)
        for required in (
            'MAX_EVENT_COUNT_PER_SESSION = 20',
            '"startTimeToken"',
            '"ownershipVerified"',
            '"SkyBridgeCompassApp"',
            '"fileTransferStarted"',
            '"fileTransferCompleted"',
            '"localFramePresented"',
            '"p2p-renderer-ack"',
            '"webrtc-renderer-receipt"',
            '"local-renderer"',
            '"ios-product-session.log"',
            '"ios-product-session-capture.json"',
            '"connectivityAttemptStarted"',
            '"connectivityAttemptAuthenticated"',
            '"connectivityEndpoint"',
            '"connectivityPolicyRejected"',
            '"peerOfferSignature"',
            '"releaseArchiveBindingVerified"',
            '"SkyBridgeCompass-iOS"',
        ):
            self.assertIn(required, validator)
        self.assertNotIn("fileChunkAccepted", validator)
        self.assertNotIn('"connectivityCase"', validator)
        self.assertNotIn('"Q-Periapt-ContextBound",', validator)

    def test_evidence_consumer_regressions_are_warning_strict_and_ci_bound(self) -> None:
        source_gate = (ROOT / "Scripts/gates/source_quality_gate.sh").read_text(
            encoding="utf-8"
        )
        strict_python_tests = (
            "test_validate_real_device_release_acceptance_artifact.py",
            "test_validate_product_release_evidence_log.py",
            "test_stage_real_device_release_evidence.py",
            "test_real_device_release_workflow_contract.py",
        )
        for test in strict_python_tests:
            with self.subTest(test=test):
                command = f"python3 -W error Scripts/{test}"
                self.assertIn(command, self.candidate)
                self.assertIn(command, self.evidence)
                self.assertIn(
                    f'python3 -W error "${{ROOT_DIR}}/Scripts/{test}"',
                    source_gate,
                )
        redaction_test = "bash Scripts/test_real_device_smoke_redaction.sh"
        self.assertIn(redaction_test, self.candidate)
        self.assertIn(redaction_test, self.evidence)
        self.assertIn(
            'bash "${ROOT_DIR}/Scripts/test_real_device_smoke_redaction.sh"',
            source_gate,
        )

    def test_actions_are_pinned_and_checkouts_never_persist_credentials(self) -> None:
        combined = self.candidate + self.evidence + self.publish
        self.assertIn(UPLOAD_V7, combined)
        self.assertIn(DOWNLOAD_V8, combined)
        self.assertEqual(
            combined.count(f"uses: {CHECKOUT_V6}"),
            combined.count("persist-credentials: false"),
        )

    def test_actionlint_knows_protected_runner_label(self) -> None:
        self.assertEqual(
            ACTIONLINT_CONFIG.read_text(encoding="utf-8"),
            "self-hosted-runner:\n  labels:\n    - skybridge-real-device-release\n",
        )

    def test_readiness_covers_ios_export_and_runs_actionlint(self) -> None:
        self.assertGreaterEqual(
            self.candidate.count('.github/workflows/ios-app-store-export.yml'),
            2,
        )
        # The readiness lane must run the pinned actionlint release binary,
        # verify its published SHA-256 digest before executing it, and lint
        # with the repository configuration. (The macOS runner image ships no
        # Go toolchain, so `go run` is not a usable invocation there.)
        self.assertIn(
            "https://github.com/rhysd/actionlint/releases/download/v1.7.12/",
            self.candidate,
        )
        self.assertIn("| shasum -a 256 -c -", self.candidate)
        self.assertIn(
            'actionlint" -config-file .github/actionlint.yaml',
            self.candidate,
        )


if __name__ == "__main__":
    unittest.main()
