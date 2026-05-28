use super::super::CheckCoverageEntry;
use super::super::source::{SearchableCheckSource, source_has_all};

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    entries.push(CheckCoverageEntry {
        id: "connectivity_matrix_gate",
        domain: "connectivity",
        command: "skybridge check connectivity --artifact-dir <connectivity-artifact>",
        covered: source_has_all(
            source,
            &[
                "Connectivity(ConnectivityCheckArgs)",
                "CheckSubcommand::Connectivity(args)",
                "build_connectivity_check_report",
                "connectivity_mac_ios_xwing_xwing",
                "connectivity_mac_ios_xwing_pqc",
                "connectivity_no_unexpected_downgrade",
                "missing_stable_protocol_identity",
            ],
        ),
        evidence: "requires a Mac->iOS connectivity matrix covering X-Wing/X-Wing, X-Wing/PQC, PQC/X-Wing, PQC/classic, and classic/PQC outcomes with stable protocol identity evidence".to_owned(),
    });
}
