use crate::performance_evidence::text::{extract_text_value, extract_text_value_any};

use super::{SignedKEMRefreshEvidence, remember_evidence_token};

#[derive(Debug, Default)]
pub(crate) struct ProtocolIdentityBindingEvidence {
    pub(crate) required_seen: bool,
    pub(crate) requester_pinned_seen: bool,
    pub(crate) request_seen: bool,
    pub(crate) served_seen: bool,
    pub(crate) verified_seen: bool,
    pub(crate) pinned_seen: bool,
    pub(crate) fingerprint_seen: bool,
    pub(crate) failure_seen: bool,
    pub(crate) lifecycle_samples: u64,
    pub(crate) requester_pinned_sequence: Option<u64>,
    pub(crate) request_sequence: Option<u64>,
    pub(crate) served_sequence: Option<u64>,
    pub(crate) verified_sequence: Option<u64>,
    pub(crate) pinned_sequence: Option<u64>,
    pub(crate) requester_pinned_requester: Option<String>,
    pub(crate) request_peer: Option<String>,
    pub(crate) served_target: Option<String>,
    pub(crate) verified_peer: Option<String>,
    pub(crate) pinned_peer: Option<String>,
    pub(crate) requester_pinned_fingerprint: Option<String>,
    pub(crate) served_fingerprint: Option<String>,
    pub(crate) verified_fingerprint: Option<String>,
    pub(crate) pinned_fingerprint: Option<String>,
    pub(crate) first_failure: Option<String>,
}

pub(in crate::performance_evidence::signed_kem_refresh) fn update_protocol_identity_binding_evidence(
    evidence: &mut ProtocolIdentityBindingEvidence,
    line: &str,
    lower: &str,
    sequence: u64,
    is_mac: bool,
    is_ios: bool,
) {
    evidence.required_seen |= lower.contains("missing_pinned_identity_requires_oob")
        || lower.contains("pinned_protocol_identity_mismatch_requires_oob");

    let is_pib = lower.contains("pib-1") || lower.contains("protocol identity binding");
    if !is_pib {
        return;
    }

    let request_event = lower.contains("protocol identity binding request:")
        || lower.contains("protocol identity binding request ")
        || lower.contains("lifecycle=identity-oob>request");
    let requester_pinned_event = lower.contains("requester protocol identity pinned")
        || lower.contains("lifecycle=identity-oob>requester-pinned");
    let served_event = lower.contains("protocol identity binding served:")
        || lower.contains("protocol identity binding served ")
        || lower.contains("lifecycle=identity-oob>served");
    let verified_event = lower.contains("protocol identity binding signature verified")
        || lower.contains("signature verified")
        || lower.contains("lifecycle=identity-oob>verified");
    let pinned_event = lower.contains("protocol identity binding pinned")
        || lower.contains("protocol identity binding operator approved")
        || lower.contains("lifecycle=identity-oob>pinned");
    let failure_event = lower.contains("protocol identity binding failed")
        || lower.contains("protocol identity binding rejected")
        || lower.contains("approval timed out")
        || lower.contains("operator rejected pib-1")
        || lower.contains("lifecycle=identity-oob>failed")
        || lower.contains("lifecycle=identity-oob>rejected")
        || lower.contains("lifecycle=identity-oob>timeout");

    evidence.request_seen |= request_event && is_ios && !is_mac;
    evidence.requester_pinned_seen |= requester_pinned_event && is_mac && !is_ios;
    evidence.served_seen |= served_event && is_mac && !is_ios;
    evidence.verified_seen |= verified_event && is_ios && !is_mac;
    evidence.pinned_seen |= pinned_event && is_ios && !is_mac;
    evidence.fingerprint_seen |=
        lower.contains("fingerprint=") || lower.contains("protocolidentityfingerprint=");
    evidence.failure_seen |= failure_event;
    if failure_event && evidence.first_failure.is_none() {
        evidence.first_failure = Some(line.trim().to_owned());
    }

    if request_event && is_ios && !is_mac && evidence.request_sequence.is_none() {
        evidence.request_sequence = Some(sequence);
    }
    if request_event && is_ios && !is_mac {
        remember_evidence_token(&mut evidence.request_peer, extract_text_value(line, "peer"));
    }
    if requester_pinned_event && is_mac && !is_ios && evidence.requester_pinned_sequence.is_none() {
        evidence.requester_pinned_sequence = Some(sequence);
    }
    if requester_pinned_event && is_mac && !is_ios {
        remember_evidence_token(
            &mut evidence.requester_pinned_requester,
            extract_text_value(line, "requester"),
        );
        remember_evidence_token(
            &mut evidence.requester_pinned_fingerprint,
            extract_text_value_any(line, &["fingerprint", "protocolIdentityFingerprint"]),
        );
    }
    if served_event && is_mac && !is_ios && evidence.served_sequence.is_none() {
        evidence.served_sequence = Some(sequence);
    }
    if served_event && is_mac && !is_ios {
        remember_evidence_token(
            &mut evidence.served_target,
            extract_text_value(line, "target"),
        );
        remember_evidence_token(
            &mut evidence.served_fingerprint,
            extract_text_value_any(line, &["fingerprint", "protocolIdentityFingerprint"]),
        );
    }
    if verified_event && is_ios && !is_mac && evidence.verified_sequence.is_none() {
        evidence.verified_sequence = Some(sequence);
    }
    if verified_event && is_ios && !is_mac {
        remember_evidence_token(
            &mut evidence.verified_peer,
            extract_text_value(line, "peer"),
        );
        remember_evidence_token(
            &mut evidence.verified_fingerprint,
            extract_text_value_any(line, &["fingerprint", "protocolIdentityFingerprint"]),
        );
    }
    if pinned_event && is_ios && !is_mac && evidence.pinned_sequence.is_none() {
        evidence.pinned_sequence = Some(sequence);
    }
    if pinned_event && is_ios && !is_mac {
        remember_evidence_token(&mut evidence.pinned_peer, extract_text_value(line, "peer"));
        remember_evidence_token(
            &mut evidence.pinned_fingerprint,
            extract_text_value_any(line, &["fingerprint", "protocolIdentityFingerprint"]),
        );
    }
    if request_event
        || requester_pinned_event
        || served_event
        || verified_event
        || pinned_event
        || failure_event
    {
        evidence.lifecycle_samples += 1;
    }
}

fn evidence_values_match_or_redacted<'a>(
    values: impl IntoIterator<Item = Option<&'a String>>,
) -> bool {
    let mut expected: Option<&str> = None;
    let mut saw_value = false;
    for value in values.into_iter().flatten() {
        saw_value = true;
        if value.contains("redacted") {
            continue;
        }
        match expected {
            Some(current) if current != value.as_str() => return false,
            Some(_) => {}
            None => expected = Some(value.as_str()),
        }
    }
    saw_value
}

pub(super) fn protocol_identity_binding_matches_skr(evidence: &SignedKEMRefreshEvidence) -> bool {
    let binding = &evidence.protocol_identity_binding;
    let identity_values = [
        binding.request_peer.as_ref(),
        binding.served_target.as_ref(),
        binding.verified_peer.as_ref(),
        binding.pinned_peer.as_ref(),
        evidence.request_peer.as_ref(),
        evidence.served_target.as_ref(),
        evidence.verified_peer.as_ref(),
    ];
    let binding_identity_complete = binding.request_peer.is_some()
        && binding.served_target.is_some()
        && binding.verified_peer.is_some()
        && binding.pinned_peer.is_some();
    let skr_identity_complete = binding.served_target.is_some()
        && evidence.request_peer.is_some()
        && evidence.served_target.is_some()
        && evidence.verified_peer.is_some();
    let identity_values_match = evidence_values_match_or_redacted(identity_values);
    let fingerprint_values = [
        binding.served_fingerprint.as_ref(),
        binding.verified_fingerprint.as_ref(),
        binding.pinned_fingerprint.as_ref(),
        evidence.protocol_identity_fingerprint.as_ref(),
    ];
    let fingerprint_sources_seen = fingerprint_values.iter().any(|value| value.is_some());
    let fingerprints_match = evidence_values_match_or_redacted(fingerprint_values);
    (binding_identity_complete || skr_identity_complete)
        && identity_values_match
        && evidence.pinned_identity_seen
        && fingerprint_sources_seen
        && fingerprints_match
}

fn protocol_identity_binding_lifecycle_order_ok(evidence: &SignedKEMRefreshEvidence) -> bool {
    let binding = &evidence.protocol_identity_binding;
    let skr_request_sequence = evidence
        .latest_request_sequence
        .or(evidence.request_sequence);
    match (
        binding.request_sequence,
        binding.verified_sequence,
        binding.pinned_sequence,
        skr_request_sequence,
    ) {
        (Some(request), Some(verified), Some(pinned), Some(skr_request)) => {
            // Mac and iOS logs are produced by different clocks; the iOS
            // verified event is causally dependent on the Mac served payload,
            // so require served evidence but order the lifecycle on the
            // initiator-local events.
            binding.served_seen && request < verified && verified < pinned && pinned < skr_request
        }
        _ => false,
    }
}

fn protocol_identity_binding_skr_lifecycle_order_ok(evidence: &SignedKEMRefreshEvidence) -> bool {
    let binding = &evidence.protocol_identity_binding;
    let skr_request_sequence = evidence
        .latest_request_sequence
        .or(evidence.request_sequence);
    match (
        binding.requester_pinned_sequence,
        binding.served_sequence,
        skr_request_sequence,
        evidence.verified_imported_sequence,
    ) {
        (Some(requester_pinned), Some(served), Some(skr_request), Some(skr_verified)) => {
            requester_pinned < served && skr_request < skr_verified
        }
        _ => false,
    }
}

fn protocol_identity_binding_complete_oob_ok(evidence: &SignedKEMRefreshEvidence) -> bool {
    let binding = &evidence.protocol_identity_binding;
    binding.request_seen
        && binding.served_seen
        && binding.verified_seen
        && binding.pinned_seen
        && binding.fingerprint_seen
        && !binding.failure_seen
        && binding.lifecycle_samples >= 4
        && protocol_identity_binding_matches_skr(evidence)
        && protocol_identity_binding_lifecycle_order_ok(evidence)
}

fn protocol_identity_binding_satisfied_by_skr(evidence: &SignedKEMRefreshEvidence) -> bool {
    let binding = &evidence.protocol_identity_binding;
    binding.requester_pinned_seen
        && binding.served_seen
        && binding.fingerprint_seen
        && !binding.failure_seen
        && binding.lifecycle_samples >= 2
        && evidence.request_seen
        && evidence.served_seen
        && evidence.verified_imported_seen
        && evidence.pinned_identity_seen
        && evidence.signature_verified_seen
        && evidence.request_hash_bound_seen
        && protocol_identity_binding_matches_skr(evidence)
        && protocol_identity_binding_skr_lifecycle_order_ok(evidence)
}

pub(crate) fn protocol_identity_binding_required_ok(evidence: &SignedKEMRefreshEvidence) -> bool {
    protocol_identity_binding_complete_oob_ok(evidence)
        || protocol_identity_binding_satisfied_by_skr(evidence)
}

pub(crate) fn protocol_identity_binding_check_detail(
    evidence: &SignedKEMRefreshEvidence,
) -> String {
    let binding = &evidence.protocol_identity_binding;
    format!(
        "pibRequired={} pibRequesterPinnedSeen={} pibRequestSeen={} pibServedSeen={} pibVerifiedSeen={} pibPinnedSeen={} pibFingerprintSeen={} pibFailureSeen={} pibLifecycleSamples={} pibRequesterPinnedSeq={:?} pibRequestSeq={:?} pibServedSeq={:?} pibVerifiedSeq={:?} pibPinnedSeq={:?} pibRequesterPinnedRequesterSeen={} pibRequestPeerSeen={} pibServedTargetSeen={} pibVerifiedPeerSeen={} pibPinnedPeerSeen={} pibRequesterPinnedFingerprintSeen={} pibServedFingerprintSeen={} pibVerifiedFingerprintSeen={} pibPinnedFingerprintSeen={} pibMatchesSKR={} pibSatisfiedBySKR={} pibFirstFailure={}",
        binding.required_seen,
        binding.requester_pinned_seen,
        binding.request_seen,
        binding.served_seen,
        binding.verified_seen,
        binding.pinned_seen,
        binding.fingerprint_seen,
        binding.failure_seen,
        binding.lifecycle_samples,
        binding.requester_pinned_sequence,
        binding.request_sequence,
        binding.served_sequence,
        binding.verified_sequence,
        binding.pinned_sequence,
        binding.requester_pinned_requester.is_some(),
        binding.request_peer.is_some(),
        binding.served_target.is_some(),
        binding.verified_peer.is_some(),
        binding.pinned_peer.is_some(),
        binding.requester_pinned_fingerprint.is_some(),
        binding.served_fingerprint.is_some(),
        binding.verified_fingerprint.is_some(),
        binding.pinned_fingerprint.is_some(),
        protocol_identity_binding_matches_skr(evidence),
        protocol_identity_binding_satisfied_by_skr(evidence),
        binding.first_failure.as_deref().unwrap_or("-")
    )
}
