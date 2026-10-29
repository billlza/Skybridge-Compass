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
                "connectivity_candidate_bound_product_logs",
                "connectivity_three_success_pairs",
                "connectivity_endpoint_join",
                "connectivity_actual_offer_suite_family",
                "connectivity_signed_classic_rejections",
                "ios-product-session-capture.json",
                "peerOfferSignature",
            ],
        ),
        evidence: "requires exact candidate-bound Mac and iOS shipping-product logs joined into X-Wing/X-Wing, X-Wing/PQC, and PQC/X-Wing authenticated success pairs plus one verified signed-classic policy rejection at each shipping responder".to_owned(),
    });
}
