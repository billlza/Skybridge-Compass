use crate::performance_evidence::text::{extract_text_value, extract_text_value_any};

use super::{SignedKEMRefreshEvidence, remember_evidence_token};

#[derive(Debug, Default)]
pub(crate) struct ProtocolIdentityBindingEvidence {
    pub(crate) required_seen: bool,
    pub(crate) request_seen: bool,
    pub(crate) served_seen: bool,
    pub(crate) verified_seen: bool,
    pub(crate) pinned_seen: bool,
    pub(crate) fingerprint_seen: bool,
    pub(crate) failure_seen: bool,
    pub(crate) lifecycle_samples: u64,
    pub(crate) request_sequence: Option<u64>,
    pub(crate) served_sequence: Option<u64>,
    pub(crate) verified_sequence: Option<u64>,
    pub(crate) pinned_sequence: Option<u64>,
    pub(crate) request_peer: Option<String>,
    pub(crate) served_target: Option<String>,
    pub(crate) verified_peer: Option<String>,
    pub(crate) pinned_peer: Option<String>,
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
    if request_event || served_event || verified_event || pinned_event || failure_event {
        evidence.lifecycle_samples += 1;
    }
}

fn evidence_values_match<'a>(values: impl IntoIterator<Item = Option<&'a String>>) -> bool {
    let mut expected: Option<&str> = None;
    for value in values.into_iter().flatten() {
        match expected {
            Some(current) if current != value.as_str() => return false,
            Some(_) => {}
            None => expected = Some(value.as_str()),
        }
    }
    true
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
    let identity_values_match = evidence_values_match(identity_values);
    let identity_redaction_seen = identity_values
        .into_iter()
        .flatten()
        .any(|value| value.contains("redacted"));
    let binding_identity_complete = binding.request_peer.is_some()
        && binding.served_target.is_some()
        && binding.verified_peer.is_some()
        && binding.pinned_peer.is_some();
    let binding_fingerprints_match = evidence_values_match([
        binding.served_fingerprint.as_ref(),
        binding.verified_fingerprint.as_ref(),
        binding.pinned_fingerprint.as_ref(),
    ]);
    let skr_fingerprint_is_bound = evidence.protocol_identity_fingerprint.as_ref().map_or_else(
        || evidence.pinned_identity_seen && binding_fingerprints_match,
        |fingerprint| {
            evidence_values_match([
                binding.served_fingerprint.as_ref(),
                binding.verified_fingerprint.as_ref(),
                binding.pinned_fingerprint.as_ref(),
                Some(fingerprint),
            ])
        },
    );
    let identity_is_bound = identity_values_match
        || (identity_redaction_seen
            && evidence.pinned_identity_seen
            && binding_identity_complete
            && binding_fingerprints_match);
    identity_is_bound && skr_fingerprint_is_bound
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

pub(crate) fn protocol_identity_binding_required_ok(evidence: &SignedKEMRefreshEvidence) -> bool {
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

pub(crate) fn protocol_identity_binding_check_detail(
    binding: &ProtocolIdentityBindingEvidence,
) -> String {
    format!(
        "pibRequired={} pibRequestSeen={} pibServedSeen={} pibVerifiedSeen={} pibPinnedSeen={} pibFingerprintSeen={} pibFailureSeen={} pibLifecycleSamples={} pibRequestSeq={:?} pibServedSeq={:?} pibVerifiedSeq={:?} pibPinnedSeq={:?} pibRequestPeerSeen={} pibServedTargetSeen={} pibVerifiedPeerSeen={} pibPinnedPeerSeen={} pibServedFingerprintSeen={} pibVerifiedFingerprintSeen={} pibPinnedFingerprintSeen={} pibFirstFailure={}",
        binding.required_seen,
        binding.request_seen,
        binding.served_seen,
        binding.verified_seen,
        binding.pinned_seen,
        binding.fingerprint_seen,
        binding.failure_seen,
        binding.lifecycle_samples,
        binding.request_sequence,
        binding.served_sequence,
        binding.verified_sequence,
        binding.pinned_sequence,
        binding.request_peer.is_some(),
        binding.served_target.is_some(),
        binding.verified_peer.is_some(),
        binding.pinned_peer.is_some(),
        binding.served_fingerprint.is_some(),
        binding.verified_fingerprint.is_some(),
        binding.pinned_fingerprint.is_some(),
        binding.first_failure.as_deref().unwrap_or("-")
    )
}
