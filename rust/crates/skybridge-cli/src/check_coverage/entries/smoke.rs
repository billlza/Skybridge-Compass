use super::super::CheckCoverageEntry;
use super::super::source::{SearchableCheckSource, source_has_all};

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    entries.push(CheckCoverageEntry {
        id: "local_webrtc_smoke_gate",
        domain: "smoke",
        command: "skybridge smoke suite --profile local-webrtc",
        covered: source_has_all(source, &["local-webrtc", "SmokeSuiteProfile::LocalWebrtc"]),
        evidence: "existing smoke suite profile carries Rust media doctor gate".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "local_webrtc_security_notice_gate",
        domain: "smoke",
        command: "skybridge smoke local-webrtc-security-notice",
        covered: source_has_all(
            source,
            &[
                "local-webrtc-security-notice",
                "SmokeSuiteProfile::LocalWebrtcSecurityNotice",
                "remote-control-notice",
            ],
        ),
        evidence: "local WebRTC smoke profile validates remote-control security notice evidence"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "real_device_p2p_remote_gate",
        domain: "smoke",
        command: "skybridge smoke suite --profile real-device-p2p",
        covered: source_has_all(
            source,
            &[
                "real-device-p2p",
                "run_real_device_p2p_remote_smoke.sh",
                "smoke-final result=success validated=1",
            ],
        ),
        evidence: "existing real-device P2P remote smoke is exposed through the Rust CLI"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "real_device_p2p_security_notice_gate",
        domain: "smoke",
        command: "skybridge smoke real-device-p2p-security-notice",
        covered: source_has_all(
            source,
            &[
                "real-device-p2p-security-notice",
                "SmokeSuiteProfile::RealDeviceP2pSecurityNotice",
                "remote-control-notice",
            ],
        ),
        evidence: "real-device P2P smoke profile validates remote-control security notice evidence"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "remote_control_notice_artifact_gate",
        domain: "security",
        command: "skybridge check remote-control-notice --artifact-dir <dir> --transport p2p|webrtc [--require-panel]",
        covered: source_has_all(
            source,
            &[
                "CheckSubcommand::RemoteControlNotice(args)",
                "local-macos-security-notice-panel",
                "--require-panel",
                "remoteControlNoticeShown",
                "session_order",
                "remoteAccount",
                "remoteNebula",
                "device",
                "pqc_suite",
                "panel_pending_top_center",
                "panel_active_buttons",
                "panel_visible_until_disconnect",
            ],
        ),
        evidence: "remote-control security notice lifecycle has a first-class artifact parser"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "real_device_file_transfer_gate",
        domain: "smoke",
        command: "skybridge smoke suite --profile real-device-file-transfer",
        covered: source_has_all(
            source,
            &[
                "real-device-file-transfer",
                "run_real_device_file_transfer_smoke.sh",
            ],
        ),
        evidence: "existing real-device file-transfer smoke is exposed through the Rust CLI"
            .to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "fault_injection_gate",
        domain: "faults",
        command: "skybridge smoke faults",
        covered: source_has_all(source, &["Faults(SmokeFaultsArgs)", "fault-detection"]),
        evidence: "existing fault detection smoke remains a first-class CLI gate".to_owned(),
    });
}
