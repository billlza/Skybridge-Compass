use super::super::CheckCoverageEntry;
use super::super::source::{SearchableCheckSource, source_has_all};

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    entries.push(CheckCoverageEntry {
        id: "release_signed_github_update_manifest_gate",
        domain: "release",
        command: "Scripts/check_macos_release_readiness.sh",
        covered: source_has_all(
            source,
            &[
                "validate_update_check_configuration",
                "SKYBRIDGE_UPDATE_MANIFEST_ED25519_PUBLIC_KEYS",
                "https://github.com/billlza/Skybridge-Compass/releases/latest/download/macos-stable.json",
                "manifestSignatureVerificationFailed",
                "published_at",
                "expires_at",
                "manifestSequenceRollback",
                "recordAcceptedSequence(decision.manifest.sequence)",
                "validate_macos_update_manifest.sh",
                "does not match DMG sha256",
                "apple_pqc_sdk_build must be present and signed",
                "validate_macos_release_artifact_run.sh",
                "--require-public-redacted-artifacts",
                "validate_macos_release_public_artifacts.sh",
                "release-artifact-run-provenance.json",
                "Artifacts/release-gate-public/connectivity",
                "dmg_path=\"dist/SkyBridgeCompassPro-${app_version}.dmg\"",
            ],
        ),
        evidence: "release readiness, publishing, and workflow gates require an exact GitHub Releases manifest/DMG/app match, trusted Ed25519 signature verification, signed anti-replay metadata, run provenance, and public-redacted release artifacts".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "release_swift_63_toolchain_gate",
        domain: "release",
        command: "Scripts/check_macos_release_readiness.sh",
        covered: source_has_all(
            source,
            &[
                "validate_swift_toolchain_baseline",
                "EXPECTED_SWIFT_VERSION=\"${SKYBRIDGE_REQUIRED_APPLE_SWIFT_VERSION:-6.3.3}\"",
                "Apple Swift version ${EXPECTED_SWIFT_VERSION}",
                "swift-tools-version: 6.3",
            ],
        ),
        evidence: "release readiness fails when the SwiftPM manifests or local Apple Swift toolchain drift below the Swift 6.3 baseline".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "remote_control_notice_metadata_fail_closed_gate",
        domain: "security",
        command: "skybridge check remote-control-notice --artifact-dir <dir> --transport p2p|webrtc [--require-panel]",
        covered: source_has_all(
            source,
            &[
                "missingRequiredNoticeMetadata",
                "missing_required_notice_metadata",
                "testMissingRequiredNoticeMetadataFailsClosedWithoutShowingApproval",
                "testDescriptorDoesNotInventMissingOrGenericCryptoSuite",
                "notice_evidence_fails_when_crypto_suite_is_generic_pqc_fallback",
                "notice_evidence_fails_when_only_local_identity_is_present",
            ],
        ),
        evidence: "remote-control approval fails closed before presentation when required IP, remote account, NebulaID, device identity, or concrete PQC suite metadata is missing".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "remote_control_notice_panel_position_gate",
        domain: "security",
        command: "skybridge check remote-control-notice --artifact-dir <dir> --transport p2p|webrtc --require-panel",
        covered: source_has_all(
            source,
            &[
                "recordPanelPresentedEvidence",
                "remoteControlNoticePanelPresented",
                "run_remote_control_notice_panel_probe.sh",
                "LocalMacosSecurityNoticePanel",
                "panel_pending_top_center",
                "panel_active_buttons",
                "panel_visible_until_disconnect",
                "testSecurityNoticePanelEmitsVerifiableTopCenterEvidence",
            ],
        ),
        evidence: "remote-control security notice artifacts prove the production AppKit panel is top-centered, exposes approval/disconnect actions, and stays visible until disconnect".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "remote_control_notice_identity_redaction_gate",
        domain: "security",
        command: "skybridge check remote-control-notice --artifact-dir <dir> --transport p2p|webrtc",
        covered: source_has_all(
            source,
            &[
                "maskedStatusValue(descriptor.remoteAccountDisplayName)",
                "maskedStatusValue(descriptor.remoteNebulaId)",
                "testSecurityNoticePanelDoesNotFallbackToLocalIdentity",
            ],
        ),
        evidence: "remote-control notice evidence preserves required field presence without writing raw account or Nebula identifiers".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "ipad_multi_route_dedupe_swift_gate",
        domain: "correctness",
        command: "skybridge check performance --kind p2p-remote --artifact-dir <p2p-artifact>",
        covered: source_has_all(
            source,
            &[
                "testUSBGenericIPadNameCoalescesWithPersonalizedBonjourAndP2PRoutes",
                "testCloudUSBBonjourAndHostIPadRowsCoalesceAndPreserveDialableRoute",
                "testGenericIPadNameDoesNotCoalesceTwoNetworkOnlyRows",
                "CloudDevicePresentationPolicy.visibleICloudDevices",
                "resolvedOnlineDevice(for: device)",
                "manager.onlineDevices.contains",
                "duplicatePhysicalRows",
            ],
        ),
        evidence: "Swift dedupe tests, iCloud presentation policy, and Rust P2P artifact gates reject one physical iPad being rendered as multiple USB, Bonjour, P2P, or cloud rows".to_owned(),
    });
}
