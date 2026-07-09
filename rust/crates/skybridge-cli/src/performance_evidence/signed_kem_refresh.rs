use time::OffsetDateTime;

use crate::performance_budgets::{
    SIGNED_KEM_REFRESH_MAX_APPLICATION_LOSS_PCT, SIGNED_KEM_REFRESH_MAX_CROSS_CLOCK_SKEW_MS,
    SIGNED_KEM_REFRESH_MAX_JITTER_MS, SIGNED_KEM_REFRESH_MAX_LATENCY_MS,
    SIGNED_KEM_REFRESH_MAX_RETRY_COUNT, SIGNED_KEM_REFRESH_MIN_SUCCESS_RATE_PCT,
};

mod line_update;
mod protocol_identity_binding;

pub(crate) use line_update::update_signed_kem_refresh_evidence;
use protocol_identity_binding::protocol_identity_binding_matches_skr;
pub(crate) use protocol_identity_binding::{
    ProtocolIdentityBindingEvidence, protocol_identity_binding_check_detail,
    protocol_identity_binding_required_ok,
};

#[derive(Debug, Default)]
pub(crate) struct SignedKEMRefreshEvidence {
    pub(crate) line_sequence: u64,
    pub(crate) protocol_identity_binding: ProtocolIdentityBindingEvidence,
    pub(crate) request_seen: bool,
    pub(crate) served_seen: bool,
    pub(crate) verified_imported_seen: bool,
    pub(crate) ios_request_seen: bool,
    pub(crate) mac_served_seen: bool,
    pub(crate) ios_verified_imported_seen: bool,
    pub(crate) pinned_identity_seen: bool,
    pub(crate) signature_verified_seen: bool,
    pub(crate) request_hash_bound_seen: bool,
    pub(crate) xwing_suite_seen: bool,
    pub(crate) xwing_wire_id_seen: bool,
    pub(crate) missing_kem_preflight_seen: bool,
    pub(crate) strict_xwing_established_after_refresh: bool,
    pub(crate) unsigned_or_tofu_seen: bool,
    pub(crate) classic_suite_seen: bool,
    pub(crate) unknown_suite_seen: bool,
    pub(crate) rejected_seen: bool,
    pub(crate) first_rejection: Option<String>,
    pub(crate) lifecycle_samples: u64,
    pub(crate) request_sequence: Option<u64>,
    pub(crate) latest_request_sequence: Option<u64>,
    pub(crate) served_sequence: Option<u64>,
    pub(crate) verified_imported_sequence: Option<u64>,
    pub(crate) strict_xwing_established_sequence: Option<u64>,
    pub(crate) request_observed_at: Option<OffsetDateTime>,
    pub(crate) served_observed_at: Option<OffsetDateTime>,
    pub(crate) verified_imported_observed_at: Option<OffsetDateTime>,
    pub(crate) request_timestamp_has_fractional_seconds: bool,
    pub(crate) served_timestamp_has_fractional_seconds: bool,
    pub(crate) verified_imported_timestamp_has_fractional_seconds: bool,
    pub(crate) request_peer: Option<String>,
    pub(crate) served_target: Option<String>,
    pub(crate) verified_peer: Option<String>,
    pub(crate) protocol_identity_fingerprint: Option<String>,
    pub(crate) selected_endpoint: Option<String>,
    pub(crate) selected_endpoint_class: Option<String>,
    pub(crate) direct_host_candidate_seen: bool,
    pub(crate) selected_endpoint_direct_seen: bool,
    pub(crate) latency_ms_max: Option<f64>,
    pub(crate) jitter_ms_max: Option<f64>,
    pub(crate) success_rate_pct_min: Option<f64>,
    pub(crate) application_loss_pct_max: Option<f64>,
    pub(crate) retry_count_max: Option<u64>,
}

fn normalize_evidence_token(value: &str) -> Option<String> {
    let normalized = value
        .trim()
        .trim_matches('"')
        .trim_matches('\'')
        .to_ascii_lowercase();
    if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    }
}

fn remember_evidence_token(slot: &mut Option<String>, value: Option<String>) {
    if let Some(value) = value.and_then(|value| normalize_evidence_token(&value)) {
        *slot = Some(value);
    }
}

pub(crate) fn signed_kem_refresh_check_detail(evidence: &SignedKEMRefreshEvidence) -> String {
    format!(
        "requestSeen={} servedSeen={} verifiedImported={} iosRequestSeen={} macServedSeen={} iosVerifiedImported={} pinnedIdentity={} signatureVerified={} requestHashBound={} xwingSuite={} xwingWireId={} missingKEMPreflight={} strictXWingAfterRefresh={} unsignedOrTOFU={} classicSuite={} unknownSuite={} rejectedSeen={} firstRejection={} lifecycleSamples={} requestSeq={:?} latestRequestSeq={:?} servedSeq={:?} verifiedSeq={:?} strictXWingSeq={:?} skrRequestPeerSeen={} skrServedTargetSeen={} skrVerifiedPeerSeen={} skrProtocolIdentityFingerprintSeen={} selectedEndpointSeen={} selectedEndpointClass={} directHostCandidate={} selectedEndpointDirect={} pibSkrIdentityBound={} latencyMsMax={:?} jitterMsMax={:?} successRatePctMin={:?} applicationLossPctMax={:?} retryCountMax={:?} {} limits=latency<={:.1},jitter<={:.1},successRate>={:.1},appLossPct<={:.1},retry<={}",
        evidence.request_seen,
        evidence.served_seen,
        evidence.verified_imported_seen,
        evidence.ios_request_seen,
        evidence.mac_served_seen,
        evidence.ios_verified_imported_seen,
        evidence.pinned_identity_seen,
        evidence.signature_verified_seen,
        evidence.request_hash_bound_seen,
        evidence.xwing_suite_seen,
        evidence.xwing_wire_id_seen,
        evidence.missing_kem_preflight_seen,
        evidence.strict_xwing_established_after_refresh,
        evidence.unsigned_or_tofu_seen,
        evidence.classic_suite_seen,
        evidence.unknown_suite_seen,
        evidence.rejected_seen,
        evidence.first_rejection.as_deref().unwrap_or("-"),
        evidence.lifecycle_samples,
        evidence.request_sequence,
        evidence.latest_request_sequence,
        evidence.served_sequence,
        evidence.verified_imported_sequence,
        evidence.strict_xwing_established_sequence,
        evidence.request_peer.is_some(),
        evidence.served_target.is_some(),
        evidence.verified_peer.is_some(),
        evidence.protocol_identity_fingerprint.is_some(),
        evidence.selected_endpoint.is_some(),
        evidence.selected_endpoint_class.as_deref().unwrap_or("-"),
        evidence.direct_host_candidate_seen,
        evidence.selected_endpoint_direct_seen,
        protocol_identity_binding_matches_skr(evidence),
        evidence.latency_ms_max,
        evidence.jitter_ms_max,
        evidence.success_rate_pct_min,
        evidence.application_loss_pct_max,
        evidence.retry_count_max,
        protocol_identity_binding_check_detail(evidence),
        SIGNED_KEM_REFRESH_MAX_LATENCY_MS,
        SIGNED_KEM_REFRESH_MAX_JITTER_MS,
        SIGNED_KEM_REFRESH_MIN_SUCCESS_RATE_PCT,
        SIGNED_KEM_REFRESH_MAX_APPLICATION_LOSS_PCT,
        SIGNED_KEM_REFRESH_MAX_RETRY_COUNT
    )
}

pub(crate) fn signed_kem_refresh_ok(evidence: &SignedKEMRefreshEvidence) -> bool {
    evidence.request_seen
        && evidence.served_seen
        && evidence.verified_imported_seen
        && evidence.pinned_identity_seen
        && evidence.signature_verified_seen
        && evidence.request_hash_bound_seen
        && evidence.xwing_suite_seen
        && evidence.xwing_wire_id_seen
        && evidence.missing_kem_preflight_seen
        && evidence.strict_xwing_established_after_refresh
        && signed_kem_refresh_lifecycle_order_ok(evidence)
        && evidence.lifecycle_samples >= 3
        && !evidence.unsigned_or_tofu_seen
        && !evidence.classic_suite_seen
        && !evidence.unknown_suite_seen
        && !evidence.rejected_seen
        && evidence
            .latency_ms_max
            .is_some_and(|value| value <= SIGNED_KEM_REFRESH_MAX_LATENCY_MS)
        && evidence
            .jitter_ms_max
            .is_some_and(|value| value <= SIGNED_KEM_REFRESH_MAX_JITTER_MS)
        && evidence
            .success_rate_pct_min
            .is_some_and(|value| value >= SIGNED_KEM_REFRESH_MIN_SUCCESS_RATE_PCT)
        && evidence
            .application_loss_pct_max
            .is_some_and(|value| value <= SIGNED_KEM_REFRESH_MAX_APPLICATION_LOSS_PCT)
        && evidence
            .retry_count_max
            .is_some_and(|value| value <= SIGNED_KEM_REFRESH_MAX_RETRY_COUNT)
}

fn signed_kem_refresh_lifecycle_order_ok(evidence: &SignedKEMRefreshEvidence) -> bool {
    let request_sequence = evidence
        .latest_request_sequence
        .or(evidence.request_sequence);
    match (
        request_sequence,
        evidence.served_sequence,
        evidence.verified_imported_sequence,
        evidence.strict_xwing_established_sequence,
    ) {
        (Some(request), Some(served), Some(verified), Some(xwing)) => {
            request < verified
                && verified < xwing
                && signed_kem_refresh_served_before_verified_or_ambiguous(
                    evidence, served, verified, xwing,
                )
        }
        _ => false,
    }
}

fn signed_kem_refresh_served_before_verified_or_ambiguous(
    evidence: &SignedKEMRefreshEvidence,
    served_sequence: u64,
    verified_sequence: u64,
    strict_xwing_sequence: u64,
) -> bool {
    if served_sequence < verified_sequence {
        return true;
    }

    let (Some(served_at), Some(verified_at)) = (
        evidence.served_observed_at,
        evidence.verified_imported_observed_at,
    ) else {
        return false;
    };
    if served_at <= verified_at {
        return true;
    }

    let skew_ms = (served_at - verified_at).whole_milliseconds();
    if (0..=SIGNED_KEM_REFRESH_MAX_CROSS_CLOCK_SKEW_MS).contains(&skew_ms) {
        return true;
    }

    let cross_source_precision_is_ambiguous = !evidence.served_timestamp_has_fractional_seconds
        || !evidence.verified_imported_timestamp_has_fractional_seconds;
    if cross_source_precision_is_ambiguous && (0..=999).contains(&skew_ms) {
        return true;
    }

    !evidence.verified_imported_timestamp_has_fractional_seconds
        && served_sequence < strict_xwing_sequence
}
