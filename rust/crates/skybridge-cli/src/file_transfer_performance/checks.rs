use super::evidence::FileTransferPerformanceEvidence;
use crate::{
    DoctorCheck, protocol_identity_binding_check_detail, protocol_identity_binding_required_ok,
    signed_kem_refresh_check_detail, signed_kem_refresh_ok, simple_doctor_check,
};

pub(super) fn classify_file_transfer_probable_fault_stage(
    evidence: &FileTransferPerformanceEvidence,
) -> Option<&'static str> {
    if evidence.ios_launch_signing_rejected {
        return Some("ios_launch_signing_rejected");
    }
    let binding = &evidence.signed_kem_refresh.protocol_identity_binding;
    if binding.verified_seen && !binding.pinned_seen {
        return Some(if binding.failure_seen {
            "protocol_identity_binding_failed"
        } else {
            "protocol_identity_binding_approval_missing"
        });
    }
    if binding.required_seen
        && (!binding.request_seen || !binding.served_seen || !binding.verified_seen)
    {
        return Some("protocol_identity_binding_incomplete");
    }
    if evidence.signed_kem_refresh.request_seen && !evidence.signed_kem_refresh.served_seen {
        return Some("signed_kem_refresh_not_served");
    }
    if evidence.signed_kem_refresh.served_seen
        && !evidence.signed_kem_refresh.verified_imported_seen
    {
        return Some("signed_kem_refresh_not_imported");
    }
    if evidence.first_failure.as_ref().is_some_and(|failure| {
        failure
            .to_ascii_lowercase()
            .contains("phase=signed_kem_refresh_evidence_missing")
    }) {
        return Some("signed_kem_refresh_evidence_missing");
    }
    evidence
        .first_failure
        .as_ref()
        .map(|_| "file_transfer_failed_stage")
}

pub(super) fn check_file_transfer_sources(
    evidence: &FileTransferPerformanceEvidence,
) -> DoctorCheck {
    let ok = evidence.has_mac_log && evidence.has_ios_log && evidence.mac_boot && evidence.ios_boot;
    simple_doctor_check(
        "file_transfer_sources",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "files={} macLog={} iosLog={} macBoot={} iosBoot={} iosLaunchSigningRejected={} iosLaunchFailure={}",
            evidence.file_count,
            evidence.has_mac_log,
            evidence.has_ios_log,
            evidence.mac_boot,
            evidence.ios_boot,
            evidence.ios_launch_signing_rejected,
            evidence.ios_launch_failure_detail.as_deref().unwrap_or("-")
        ),
    )
}

pub(super) fn check_file_transfer_no_hidden_failure(
    evidence: &FileTransferPerformanceEvidence,
) -> DoctorCheck {
    let ok = evidence.failed_stage_count == 0
        && evidence.unknown_phase_count == 0
        && evidence.missing_file_transfer_phase_count == 0
        && !evidence.fallback_detected
        && !evidence.unknown_suite_rejected;
    simple_doctor_check(
        "file_transfer_no_hidden_failure",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "failedStageCount={} unknownPhaseCount={} missingPhaseCount={} fallbackDetected={} unknownSuiteRejected={} firstFailure={}",
            evidence.failed_stage_count,
            evidence.unknown_phase_count,
            evidence.missing_file_transfer_phase_count,
            evidence.fallback_detected,
            evidence.unknown_suite_rejected,
            evidence.first_failure.as_deref().unwrap_or("-")
        ),
    )
}

pub(crate) fn check_file_transfer_xwing(evidence: &FileTransferPerformanceEvidence) -> DoctorCheck {
    let ok = evidence.xwing_suite_seen && !evidence.unknown_suite_rejected;
    simple_doctor_check(
        "file_transfer_xwing",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "xwingSuiteSeen={} unknownSuiteRejected={} signedRefreshVerified={}",
            evidence.xwing_suite_seen,
            evidence.unknown_suite_rejected,
            evidence.signed_kem_refresh.verified_imported_seen
        ),
    )
}

pub(super) fn check_file_transfer_signed_kem_refresh(
    evidence: &FileTransferPerformanceEvidence,
) -> DoctorCheck {
    let refresh_ok = signed_kem_refresh_ok(&evidence.signed_kem_refresh);
    let binding_ok = protocol_identity_binding_required_ok(&evidence.signed_kem_refresh);
    let ok = refresh_ok
        && binding_ok
        && evidence.xwing_suite_seen
        && !evidence.fallback_detected
        && !evidence.qr_connect_link_seen
        && !evidence.pqc_preseed_seen;
    simple_doctor_check(
        "file_transfer_signed_kem_refresh",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "{} pibRequiredOk={} qrConnectLinkSeen={} pqcPreseedSeen={} xwingSuiteSeen={} fallbackDetected={}",
            signed_kem_refresh_check_detail(&evidence.signed_kem_refresh),
            binding_ok,
            evidence.qr_connect_link_seen,
            evidence.pqc_preseed_seen,
            evidence.xwing_suite_seen,
            evidence.fallback_detected
        ),
    )
}

pub(super) fn check_file_transfer_skr_direct_route(
    evidence: &FileTransferPerformanceEvidence,
) -> DoctorCheck {
    let refresh = &evidence.signed_kem_refresh;
    let ok = refresh.request_seen
        && refresh.direct_host_candidate_seen
        && refresh.selected_endpoint_direct_seen;
    simple_doctor_check(
        "file_transfer_skr_direct_route",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "requestSeen={} directHostCandidate={} selectedEndpointDirect={} selectedEndpointClass={} selectedEndpoint={}",
            refresh.request_seen,
            refresh.direct_host_candidate_seen,
            refresh.selected_endpoint_direct_seen,
            refresh.selected_endpoint_class.as_deref().unwrap_or("-"),
            refresh.selected_endpoint.as_deref().unwrap_or("-")
        ),
    )
}

pub(super) fn check_file_transfer_protocol_identity_binding(
    evidence: &FileTransferPerformanceEvidence,
) -> DoctorCheck {
    let binding = &evidence.signed_kem_refresh.protocol_identity_binding;
    let ok = protocol_identity_binding_required_ok(&evidence.signed_kem_refresh);
    simple_doctor_check(
        "file_transfer_protocol_identity_binding",
        ok,
        if ok { "info" } else { "error" },
        protocol_identity_binding_check_detail(binding),
    )
}

pub(super) fn check_file_transfer_bidirectional(
    evidence: &FileTransferPerformanceEvidence,
) -> DoctorCheck {
    let reconnect_ok = !evidence.mac_reconnect_required
        || (evidence.mac_reconnect_outbound_complete && evidence.ios_reconnect_inbound_complete);
    let ok = evidence.mac_inbound_complete
        && evidence.ios_outbound_complete
        && evidence.mac_outbound_complete
        && evidence.ios_inbound_complete
        && reconnect_ok;
    simple_doctor_check(
        "file_transfer_bidirectional",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "macInboundComplete={} iosOutboundComplete={} macOutboundComplete={} iosInboundComplete={} macReconnectRequired={} macReconnectOutboundComplete={} iosReconnectInboundComplete={}",
            evidence.mac_inbound_complete,
            evidence.ios_outbound_complete,
            evidence.mac_outbound_complete,
            evidence.ios_inbound_complete,
            evidence.mac_reconnect_required,
            evidence.mac_reconnect_outbound_complete,
            evidence.ios_reconnect_inbound_complete
        ),
    )
}

pub(super) fn check_file_transfer_success(
    evidence: &FileTransferPerformanceEvidence,
) -> DoctorCheck {
    let ok = evidence.mac_success && evidence.ios_success;
    simple_doctor_check(
        "file_transfer_success",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "macSuccess={} iosSuccess={}",
            evidence.mac_success, evidence.ios_success
        ),
    )
}

pub(super) fn check_file_transfer_route_evidence(
    evidence: &FileTransferPerformanceEvidence,
) -> DoctorCheck {
    let ok = evidence.route_evidence_samples > 0;
    simple_doctor_check(
        "file_transfer_route_evidence",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "routeEvidenceSamples={} signedRefreshRequestSeen={}",
            evidence.route_evidence_samples, evidence.signed_kem_refresh.request_seen
        ),
    )
}
