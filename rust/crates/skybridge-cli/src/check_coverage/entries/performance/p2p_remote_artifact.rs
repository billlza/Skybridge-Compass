use super::super::super::CheckCoverageEntry;
use super::super::super::source::{SearchableCheckSource, source_has_all};
use crate::performance_check_names::required_p2p_remote_performance_check_names;

pub(super) fn append_entries(
    source: &SearchableCheckSource,
    entries: &mut Vec<CheckCoverageEntry>,
) {
    let p2p_checks = required_p2p_remote_performance_check_names().join(",");
    entries.push(CheckCoverageEntry {
        id: "performance_strict_2k60_resolution_gate",
        domain: "performance",
        command: "skybridge check performance --artifact-dir <p2p-artifact> --min-fps 59",
        covered: source_has_all(
            source,
            &[
                "exact_video_size",
                "check_p2p_remote_resolution",
                "p2p_remote_resolution",
            ],
        ),
        evidence: "requires strict fps floor plus exact 2056x1329 video-size evidence for real-device P2P remote artifacts by default".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "performance_p2p_remote_artifact_gate",
        domain: "performance",
        command: "skybridge check performance --latest --artifact-dir <p2p-artifact> --min-fps 59",
        covered: source_has_all(
            source,
            &[
                "build_p2p_remote_performance_report",
                "check_p2p_remote_complete_artifact",
                "p2p_remote_artifact_requires_smoke_final_success_sentinel",
            ],
        ),
        evidence: format!(
            "parses real-device P2P remote artifacts and requires checks: {p2p_checks}"
        ),
    });
    entries.push(CheckCoverageEntry {
        id: "performance_p2p_remote_hidden_failure_gate",
        domain: "correctness",
        command: "skybridge check performance --kind p2p-remote --artifact-dir <p2p-artifact>",
        covered: source_has_all(
            source,
            &[
                "check_p2p_remote_no_hidden_failure",
                "missing_failure_phase_count",
                "p2p_remote_artifact_rejects_failed_stage_before_or_after_success",
            ],
        ),
        evidence: "rejects P2P remote artifacts that mix success sentinels with failed stage lines, unknown phases, or missing phase evidence".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "performance_p2p_remote_lan_route_gate",
        domain: "performance",
        command: "skybridge check performance --artifact-dir <p2p-artifact>",
        covered: source_has_all(
            source,
            &[
                "check_p2p_remote_lan_route",
                "mac_link_local_peer_seen",
                "p2p_remote_lan_route_rejects_link_local_peer_to_peer_video_path",
            ],
        ),
        evidence: "requires routable LAN direct route and rejects link-local or peer-to-peer remote video paths".to_owned(),
    });
    entries.push(CheckCoverageEntry {
        id: "performance_p2p_remote_signed_kem_refresh_gate",
        domain: "correctness",
        command: "skybridge check performance --kind p2p-remote --artifact-dir <p2p-artifact>",
        covered: source_has_all(
            source,
            &[
                "check_p2p_remote_signed_kem_refresh",
                "check_p2p_remote_protocol_identity_binding",
                "SignedKEMRefreshEvidence",
                "ProtocolIdentityBindingEvidence",
                "protocol_identity_binding_required_ok",
                "signature_verified_seen",
                "pinned_identity_seen",
                "signed_kem_refresh_lifecycle_order_ok",
                "success_rate_pct_min",
                "application_loss_pct_max",
                "SIGNED_KEM_REFRESH_MAX_LATENCY_MS",
                "SIGNED_KEM_REFRESH_MIN_SUCCESS_RATE_PCT",
                "p2p_remote_signed_kem_refresh_requires_verified_signed_lifecycle_metrics",
            ],
        ),
        evidence: "requires SKR-1 request/served/verified-imported lifecycle, same-source request-before-verify ordering, pinned protocol identity, verified signature, X-Wing wireId, cross-device timestamp ambiguity guards, and latency/success-rate/jitter/application-loss/retry evidence before strict X-Wing success can count".to_owned(),
    });
}
