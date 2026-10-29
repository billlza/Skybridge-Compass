use time::OffsetDateTime;

use crate::webrtc_media_parse::parse_webrtc_diagnostic_timestamp;

use super::protocol_identity_binding::update_protocol_identity_binding_evidence;
use super::{SignedKEMRefreshEvidence, remember_evidence_token};
use crate::performance_evidence::text::{
    extract_text_f64, extract_text_u64, extract_text_value, extract_text_value_any,
    is_unknown_suite_rejection_line, update_max_f64, update_max_u64, update_min_f64,
};

fn has_lower_log_token(lower: &str, token: &str) -> bool {
    lower
        .split(|value: char| !(value.is_ascii_alphanumeric() || value == '-'))
        .any(|value| value == token)
}

fn is_unsigned_or_tofu_evidence_line(lower: &str) -> bool {
    has_lower_log_token(lower, "unsigned")
        || lower.contains("self-asserted")
        || lower.contains("self asserted")
        || has_lower_log_token(lower, "tofu")
        || lower.contains("trust-on-first-use")
}

pub(crate) fn update_signed_kem_refresh_evidence(
    evidence: &mut SignedKEMRefreshEvidence,
    line: &str,
    lower: &str,
    is_mac: bool,
    is_ios: bool,
    observed_at_override: Option<OffsetDateTime>,
) -> u64 {
    evidence.line_sequence = evidence.line_sequence.saturating_add(1);
    let sequence = evidence.line_sequence;
    update_protocol_identity_binding_evidence(
        &mut evidence.protocol_identity_binding,
        line,
        lower,
        sequence,
        is_mac,
        is_ios,
    );
    let is_skr = lower.contains("skr-1") || lower.contains("signed lan kem refresh");
    if !is_skr {
        if lower.contains("strictpqc trust preflight failed") && lower.contains("missing peer kem")
        {
            evidence.missing_kem_preflight_seen = true;
            evidence.lifecycle_samples += 1;
        }
        return sequence;
    }

    let request_event = lower.contains("signed lan kem refresh request:")
        || lower.contains("signed lan kem refresh request ")
        || lower.contains("lifecycle=missing-kem>request");
    let served_event = lower.contains("signed lan kem refresh served:")
        || lower.contains("signed lan kem refresh served ")
        || lower.contains("lifecycle=request>served");
    let rejected_event = lower.contains("signed lan kem refresh rejected")
        || lower.contains("signed lan kem refresh failed")
        || lower.contains("lifecycle=request>rejected")
        || lower.contains("lifecycle=missing-kem>failed");
    let verified_imported_event = lower.contains("signed lan kem refresh verified and imported")
        || lower.contains("verified/imported")
        || lower.contains("lifecycle=served>verified")
        || lower.contains("signed lan kem refresh smoke-evidence");
    let source_is_ios_only = is_ios && !is_mac;
    let source_is_mac_only = is_mac && !is_ios;
    let observed_at =
        observed_at_override.or_else(|| parse_webrtc_diagnostic_timestamp(line, None));
    let timestamp_has_fractional_seconds = log_line_timestamp_has_fractional_seconds(line);

    evidence.ios_request_seen |= request_event && source_is_ios_only;
    evidence.mac_served_seen |= served_event && source_is_mac_only;
    evidence.ios_verified_imported_seen |= verified_imported_event && source_is_ios_only;
    if request_event && source_is_ios_only && evidence.request_sequence.is_none() {
        evidence.request_sequence = Some(sequence);
        evidence.request_observed_at = observed_at;
        evidence.request_timestamp_has_fractional_seconds = timestamp_has_fractional_seconds;
    }
    if request_event && source_is_ios_only {
        remember_evidence_token(&mut evidence.request_peer, extract_text_value(line, "peer"));
        remember_evidence_token(
            &mut evidence.selected_endpoint,
            extract_text_value(line, "endpoint"),
        );
        remember_evidence_token(
            &mut evidence.selected_endpoint_class,
            extract_text_value(line, "selectedEndpointClass"),
        );
        evidence.direct_host_candidate_seen |=
            extract_text_u64(line, "directHostCandidate").is_some_and(|value| value == 1);
        evidence.selected_endpoint_direct_seen |= extract_text_u64(line, "selectedEndpointDirect")
            .is_some_and(|value| value == 1)
            || extract_text_value(line, "selectedEndpointClass")
                .is_some_and(|value| value.eq_ignore_ascii_case("direct-host"));
        evidence.selected_endpoint_direct_lan_seen |=
            extract_text_u64(line, "selectedEndpointDirectLAN").is_some_and(|value| value == 1);
        evidence.selected_endpoint_peer_to_peer_seen |=
            extract_text_u64(line, "selectedEndpointPeerToPeer").is_some_and(|value| value == 1);
    }
    if request_event && source_is_ios_only && !evidence.verified_imported_seen {
        evidence.latest_request_sequence = Some(sequence);
    }
    if served_event && source_is_mac_only && evidence.served_sequence.is_none() {
        evidence.served_sequence = Some(sequence);
        evidence.served_observed_at = observed_at;
        evidence.served_timestamp_has_fractional_seconds = timestamp_has_fractional_seconds;
    }
    if served_event && source_is_mac_only {
        remember_evidence_token(
            &mut evidence.served_target,
            extract_text_value(line, "target"),
        );
    }
    if verified_imported_event
        && source_is_ios_only
        && evidence.verified_imported_sequence.is_none()
    {
        evidence.verified_imported_sequence = Some(sequence);
        evidence.verified_imported_observed_at = observed_at;
        evidence.verified_imported_timestamp_has_fractional_seconds =
            timestamp_has_fractional_seconds;
    }
    if verified_imported_event && source_is_ios_only {
        remember_evidence_token(
            &mut evidence.verified_peer,
            extract_text_value(line, "peer"),
        );
        remember_evidence_token(
            &mut evidence.protocol_identity_fingerprint,
            extract_text_value_any(
                line,
                &[
                    "protocolIdentityFingerprint",
                    "fingerprint",
                    "signingFingerprint",
                ],
            ),
        );
    }
    evidence.request_seen = evidence.ios_request_seen;
    evidence.served_seen = evidence.mac_served_seen;
    evidence.verified_imported_seen = evidence.ios_verified_imported_seen;
    evidence.rejected_seen |= rejected_event;
    if rejected_event && evidence.first_rejection.is_none() {
        evidence.first_rejection = Some(line.trim().to_owned());
    }
    evidence.pinned_identity_seen |= lower.contains("pinnedprotocolidentity=1")
        || lower.contains("pinnedidentity=1")
        || lower.contains("pinned protocol identity")
        || lower.contains("protocolidentityfingerprint=");
    evidence.signature_verified_seen |= lower.contains("signature=verified")
        || lower.contains("signatureverified=1")
        || lower.contains("verified and imported");
    evidence.request_hash_bound_seen |= lower.contains("requesthash=bound")
        || lower.contains("requesthashhex=")
        || lower.contains("request hash");
    evidence.xwing_suite_seen |= line.contains("X-Wing")
        || lower.contains("suite=x-wing")
        || lower.contains("suites=x-wing")
        || lower.contains("suites=0x0001")
        || lower.contains("wireid=0x0001");
    evidence.xwing_wire_id_seen |= lower.contains("wireid=0x0001")
        || lower.contains("suites=0x0001")
        || lower.contains("suitewireids=0x0001");
    evidence.missing_kem_preflight_seen |= lower.contains("missing peer kem")
        || lower.contains("missing trusted kem")
        || lower.contains("missingpeerkem=1")
        || lower.contains("missingtrustedkem=1")
        || lower.contains("lifecycle=missing-kem")
        || lower.contains("preflight failed");
    let strict_xwing_marker =
        lower.contains("strictxwingestablished=1") || lower.contains("strict x-wing established");
    if strict_xwing_marker
        && evidence
            .verified_imported_sequence
            .is_some_and(|verified| sequence >= verified)
    {
        evidence.strict_xwing_established_after_refresh = true;
        evidence
            .strict_xwing_established_sequence
            .get_or_insert(sequence);
    }
    evidence.unsigned_or_tofu_seen |= is_unsigned_or_tofu_evidence_line(lower);
    evidence.classic_suite_seen |= lower.contains("classic suite")
        || lower.contains("classicfallback=1")
        || lower.contains("allowclassicfallback=1")
        || lower.contains("0x1001")
        || lower.contains("0x1002");
    evidence.unknown_suite_seen |= is_unknown_suite_rejection_line(line, lower);

    if lower.contains("lifecycle=")
        || lower.contains("phase=")
        || request_event
        || served_event
        || rejected_event
        || verified_imported_event
    {
        evidence.lifecycle_samples += 1;
    }
    if verified_imported_event && source_is_ios_only {
        update_max_f64(
            &mut evidence.latency_ms_max,
            extract_text_f64(line, "latencyMs")
                .or_else(|| extract_text_f64(line, "totalLatencyMs"))
                .or_else(|| extract_text_f64(line, "responseLatencyMs")),
        );
        update_max_f64(
            &mut evidence.jitter_ms_max,
            extract_text_f64(line, "jitterMs")
                .or_else(|| extract_text_f64(line, "attemptJitterMs")),
        );
        update_max_f64(
            &mut evidence.application_loss_pct_max,
            extract_text_f64(line, "applicationLossPct")
                .or_else(|| extract_text_f64(line, "appLossPct"))
                .or_else(|| extract_text_f64(line, "packetLossPct"))
                .or_else(|| extract_text_f64(line, "lossPct")),
        );
        let loss_pct = extract_text_f64(line, "applicationLossPct")
            .or_else(|| extract_text_f64(line, "appLossPct"))
            .or_else(|| extract_text_f64(line, "packetLossPct"))
            .or_else(|| extract_text_f64(line, "lossPct"));
        update_min_f64(
            &mut evidence.success_rate_pct_min,
            extract_text_f64(line, "successRatePct")
                .or_else(|| extract_text_f64(line, "attemptSuccessPct"))
                .or_else(|| loss_pct.map(|value| (100.0 - value).max(0.0))),
        );
        update_max_u64(
            &mut evidence.retry_count_max,
            extract_text_u64(line, "retryCount").or_else(|| extract_text_u64(line, "retries")),
        );
    }
    sequence
}

fn log_line_timestamp_has_fractional_seconds(text: &str) -> bool {
    let Some(timestamp) = text
        .strip_prefix('[')
        .and_then(|value| value.split_once(']'))
    else {
        return false;
    };
    timestamp.0.contains('.')
}
