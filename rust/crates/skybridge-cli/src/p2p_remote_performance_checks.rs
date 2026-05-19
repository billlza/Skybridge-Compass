use super::{
    DoctorCheck, protocol_identity_binding_check_detail, protocol_identity_binding_required_ok,
    signed_kem_refresh_check_detail, signed_kem_refresh_ok, simple_doctor_check,
};
use crate::p2p_remote_performance_evidence::P2pRemotePerformanceEvidence;

mod realtime;
mod video;

pub(crate) use realtime::{
    check_p2p_remote_audio, check_p2p_remote_decode_queue, check_p2p_remote_ios_raw_latency,
    check_p2p_remote_ios_window_fps, check_p2p_remote_mac_final_window_fps,
    check_p2p_remote_mac_tx, check_p2p_remote_metal_render_queue,
    check_p2p_remote_timing_correlation,
};
pub(crate) use video::{check_p2p_remote_hevc_main_path, check_p2p_remote_resolution};

pub(crate) fn check_p2p_remote_sources(evidence: &P2pRemotePerformanceEvidence) -> DoctorCheck {
    let ok = evidence.has_mac_log && evidence.has_ios_log;
    simple_doctor_check(
        "p2p_remote_sources",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "files={} macLog={} iosLog={}",
            evidence.file_count, evidence.has_mac_log, evidence.has_ios_log
        ),
    )
}

pub(crate) fn check_p2p_remote_complete_artifact(
    evidence: &P2pRemotePerformanceEvidence,
) -> DoctorCheck {
    check_p2p_remote_complete_artifact_for_mode(evidence, false)
}

pub(crate) fn check_p2p_remote_complete_artifact_for_mode(
    evidence: &P2pRemotePerformanceEvidence,
    manual_artifact: bool,
) -> DoctorCheck {
    let formal_complete = evidence.smoke_final_success && evidence.smoke_final_validated;
    let manual_complete = manual_artifact && evidence.remote_desktop_pass;
    let ok = evidence.has_mac_log
        && evidence.has_ios_log
        && (formal_complete || manual_complete)
        && !evidence.host_process_exited;
    simple_doctor_check(
        "p2p_remote_complete_artifact",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "macLog={} iosLog={} smokeFinalSuccess={} smokeFinalValidated={} manualArtifact={} remoteDesktopPass={} hostProcessExited={}",
            evidence.has_mac_log,
            evidence.has_ios_log,
            evidence.smoke_final_success,
            evidence.smoke_final_validated,
            manual_artifact,
            evidence.remote_desktop_pass,
            evidence.host_process_exited
        ),
    )
}

pub(crate) fn check_p2p_remote_no_hidden_failure(
    evidence: &P2pRemotePerformanceEvidence,
) -> DoctorCheck {
    let ok = evidence.failed_stage_count == 0
        && evidence.unknown_phase_count == 0
        && evidence.missing_failure_phase_count == 0;
    simple_doctor_check(
        "p2p_remote_no_hidden_failure",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "failedStageCount={} unknownPhaseCount={} missingPhaseCount={} firstFailure={}",
            evidence.failed_stage_count,
            evidence.unknown_phase_count,
            evidence.missing_failure_phase_count,
            evidence.first_failure.as_deref().unwrap_or("-")
        ),
    )
}

pub(crate) fn check_p2p_remote_lan_route(evidence: &P2pRemotePerformanceEvidence) -> DoctorCheck {
    let has_new_route_evidence = evidence.lan_route_samples > 0;
    let lan_main_route_samples =
        evidence.lan_direct_route_samples + evidence.lan_bonjour_infrastructure_route_samples;
    let ok = has_new_route_evidence
        && lan_main_route_samples > 0
        && evidence.lan_route_ready_samples > 0
        && evidence.lan_resolved_direct_route_samples > 0
        && evidence.lan_resolved_link_local_route_samples == 0
        && evidence.lan_resolved_peer_to_peer_route_samples == 0
        && evidence.lan_link_local_route_samples == 0
        && evidence.lan_peer_to_peer_route_samples == 0
        && !evidence.mac_link_local_peer_seen;
    simple_doctor_check(
        "p2p_remote_lan_route",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "routeSamples={} routeReady={} lanDirect={} bonjourInfrastructure={} resolvedLanDirect={} linkLocal={} resolvedLinkLocal={} peerToPeer={} resolvedPeerToPeer={} macLinkLocalPeer={}",
            evidence.lan_route_samples,
            evidence.lan_route_ready_samples,
            evidence.lan_direct_route_samples,
            evidence.lan_bonjour_infrastructure_route_samples,
            evidence.lan_resolved_direct_route_samples,
            evidence.lan_link_local_route_samples,
            evidence.lan_resolved_link_local_route_samples,
            evidence.lan_peer_to_peer_route_samples,
            evidence.lan_resolved_peer_to_peer_route_samples,
            evidence.mac_link_local_peer_seen
        ),
    )
}

pub(crate) fn check_p2p_remote_xwing(evidence: &P2pRemotePerformanceEvidence) -> DoctorCheck {
    let ok = evidence.xwing_established && !evidence.unknown_suite_rejected;
    simple_doctor_check(
        "p2p_remote_xwing",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "xwingEstablished={} unknownSuiteRejected={}",
            evidence.xwing_established, evidence.unknown_suite_rejected
        ),
    )
}

pub(crate) fn check_p2p_remote_signed_kem_refresh(
    evidence: &P2pRemotePerformanceEvidence,
) -> DoctorCheck {
    let binding_ok = protocol_identity_binding_required_ok(&evidence.signed_kem_refresh);
    let refresh_ok = signed_kem_refresh_ok(&evidence.signed_kem_refresh) && binding_ok;
    let ok = refresh_ok && evidence.xwing_established && !evidence.unknown_suite_rejected;
    simple_doctor_check(
        "p2p_remote_signed_kem_refresh",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "{} xwingEstablished={} unknownSuiteRejected={}",
            signed_kem_refresh_check_detail(&evidence.signed_kem_refresh),
            evidence.xwing_established,
            evidence.unknown_suite_rejected
        ),
    )
}

pub(crate) fn check_p2p_remote_protocol_identity_binding(
    evidence: &P2pRemotePerformanceEvidence,
) -> DoctorCheck {
    let binding = &evidence.signed_kem_refresh.protocol_identity_binding;
    let ok = protocol_identity_binding_required_ok(&evidence.signed_kem_refresh);
    simple_doctor_check(
        "p2p_remote_protocol_identity_binding",
        ok,
        if ok { "info" } else { "error" },
        protocol_identity_binding_check_detail(binding),
    )
}

pub(crate) fn check_p2p_remote_no_fallback(evidence: &P2pRemotePerformanceEvidence) -> DoctorCheck {
    let ok = !evidence.fallback_detected
        && !evidence.h264_video_path
        && !evidence.unknown_suite_rejected;
    simple_doctor_check(
        "p2p_remote_no_fallback",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "fallbackDetected={} h264Video={} unknownSuiteRejected={}",
            evidence.fallback_detected, evidence.h264_video_path, evidence.unknown_suite_rejected
        ),
    )
}
