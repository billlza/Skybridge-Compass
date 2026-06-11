use super::super::CheckCoverageEntry;
use super::super::source::{SearchableCheckSource, source_has_all};

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    entries.push(CheckCoverageEntry {
        id: "device_discover_mdns_gate",
        domain: "operator-surface",
        command: "skybridge device discover [--require-capability <capability>]",
        covered: source_has_all(
            source,
            &[
                "Discover(DeviceDiscoverArgs)",
                "DeviceSubcommand::Discover(args)",
                "device_discover(args).await",
                "_skybridge-remote._tcp.local.",
                "ensure_required_capabilities",
                "operator_device_discover_file_and_remote_desktop_subcommands_parse",
                "help_surfaces_operator_capabilities",
            ],
        ),
        evidence: "device discovery exposes control, file-transfer, and remote-desktop Bonjour service discovery with parse/help coverage and required-capability fail-closed checks".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "file_transfer_proof_alias_gate",
        domain: "operator-surface",
        command: "skybridge file prove --artifact-dir <file-transfer-artifact>",
        covered: source_has_all(
            source,
            &[
                "Prove(FileProveArgs)",
                "FileSubcommand::Prove(args)",
                "prove_file_transfer",
                "PerformanceKindArg::FileTransfer",
                "file-transfer proof failed",
                "file_transfer_fixture",
            ],
        ),
        evidence: "file-transfer operator alias delegates to the strict artifact performance gate instead of implementing a parallel or fake transfer path".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "remote_desktop_proof_alias_gate",
        domain: "operator-surface",
        command: "skybridge session remote-desktop prove --artifact-dir <p2p-artifact>",
        covered: source_has_all(
            source,
            &[
                "RemoteDesktop(RemoteDesktopCommand)",
                "RemoteDesktopSubcommand::Prove",
                "prove_remote_desktop",
                "PerformanceKindArg::P2pRemote",
                "remote-desktop proof failed",
                "p2p_remote_fixture",
            ],
        ),
        evidence: "remote-desktop operator alias delegates to the strict P2P remote artifact gate and stays separate from realtime viewer implementation".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "file_transfer_live_placeholder_fail_closed_gate",
        domain: "correctness",
        command: "skybridge file send|receive|history",
        covered: source_has_all(
            source,
            &[
                "send_placeholder",
                "receive_placeholder",
                "history_placeholder(_as_json",
                "file transfer history is not wired to a real transfer registry",
                "file_placeholders_fail_closed_until_live_transfer_registry_exists",
            ],
        ),
        evidence: "live file send/receive/history remain explicit fail-closed paths until a real transfer registry/session adapter exists".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "control_plane_doctor_fail_closed_gate",
        domain: "control-plane",
        command: "skybridge doctor signaling|media-lease",
        covered: source_has_all(
            source,
            &[
                "ensure_probe_report_passed(&report, \"signaling doctor failed\")",
                "ensure_probe_report_passed(&report, \"media lease doctor failed\")",
                "blocking_check_summaries",
            ],
        ),
        evidence: "control-plane doctor subcommands print reports and return non-zero when any warning/error check remains".to_owned(),
    });
}
