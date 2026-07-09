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
    let formal_complete = evidence.smoke_final_success
        && evidence.smoke_final_validated
        && evidence.remote_desktop_pass
        && evidence.smoke_capture_source_verified;
    let manual_complete =
        manual_artifact && evidence.remote_desktop_pass && evidence.smoke_capture_source_verified;
    let ok = evidence.has_mac_log
        && evidence.has_ios_log
        && (formal_complete || manual_complete)
        && !evidence.host_process_exited;
    simple_doctor_check(
        "p2p_remote_complete_artifact",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "macLog={} iosLog={} smokeFinalSuccess={} smokeFinalValidated={} captureVerified={} manualArtifact={} remoteDesktopPass={} hostProcessExited={}",
            evidence.has_mac_log,
            evidence.has_ios_log,
            evidence.smoke_final_success,
            evidence.smoke_final_validated,
            evidence.smoke_capture_source_verified,
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
        && evidence.missing_failure_phase_count == 0
        && evidence.already_connected_rejection_count == 0;
    simple_doctor_check(
        "p2p_remote_no_hidden_failure",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "failedStageCount={} unknownPhaseCount={} missingPhaseCount={} alreadyConnectedRejections={} firstFailure={}",
            evidence.failed_stage_count,
            evidence.unknown_phase_count,
            evidence.missing_failure_phase_count,
            evidence.already_connected_rejection_count,
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

pub(crate) fn check_p2p_remote_mac_ipad_online_connect_button(
    evidence: &P2pRemotePerformanceEvidence,
) -> DoctorCheck {
    let ordered_success_identity = p2p_remote_mac_ipad_ordered_connect_success_identity(evidence);
    let duplicate_physical_rows = p2p_remote_mac_ipad_duplicate_physical_row_summary(evidence);
    let ok = evidence.ios_ipad_presence_heartbeat_samples > 0
        && evidence.mac_ipad_dashboard_role_boot_samples > 0
        && evidence.mac_ipad_online_ui_rows > 0
        && evidence.mac_ipad_real_online_row_source_samples > 0
        && evidence.mac_ipad_online_button_enabled_rows > 0
        && evidence.mac_ipad_online_connectable_enabled_rows > 0
        && evidence.mac_ipad_online_strong_match_rows > 0
        && evidence.mac_ipad_control_port_reachable_samples > 0
        && evidence.mac_ipad_control_port_unreachable_samples == 0
        && evidence.mac_ipad_connect_click_samples > 0
        && evidence.mac_ipad_real_button_source_click_samples > 0
        && evidence.mac_ipad_connect_no_endpoint_failures == 0
        && evidence.mac_ipad_p2p_connect_start_samples > 0
        && evidence.mac_ipad_connect_success_samples > 0
        && evidence.mac_ipad_connect_failure_samples == 0
        && ordered_success_identity.is_some()
        && duplicate_physical_rows.is_none();
    simple_doctor_check(
        "p2p_remote_mac_ipad_online_connect_button",
        ok,
        if ok { "info" } else { "error" },
        format!(
            "iosIpadHeartbeat={} dashboardRoleBoot={} macOnlineRows={} realRowSourceRows={} buttonEnabledRows={} connectableEnabledRows={} strongMatchRows={} weakMatchRows={} ipadControlReachable={} ipadControlUnreachable={} connectClicks={} buttonSourceClicks={} realEndpointSamples={} noEndpointFailures={} connectStarts={} connectSuccess={} connectFailure={} orderedIdentity={} rowIdentities={} controlIdentities={} clickIdentities={} startIdentities={} successIdentities={} duplicatePhysicalRows={}",
            evidence.ios_ipad_presence_heartbeat_samples,
            evidence.mac_ipad_dashboard_role_boot_samples,
            evidence.mac_ipad_online_ui_rows,
            evidence.mac_ipad_real_online_row_source_samples,
            evidence.mac_ipad_online_button_enabled_rows,
            evidence.mac_ipad_online_connectable_enabled_rows,
            evidence.mac_ipad_online_strong_match_rows,
            evidence.mac_ipad_online_weak_match_rows,
            evidence.mac_ipad_control_port_reachable_samples,
            evidence.mac_ipad_control_port_unreachable_samples,
            evidence.mac_ipad_connect_click_samples,
            evidence.mac_ipad_real_button_source_click_samples,
            evidence.mac_ipad_connect_real_endpoint_samples,
            evidence.mac_ipad_connect_no_endpoint_failures,
            evidence.mac_ipad_p2p_connect_start_samples,
            evidence.mac_ipad_connect_success_samples,
            evidence.mac_ipad_connect_failure_samples,
            if ordered_success_identity.is_some() {
                "bound"
            } else {
                "missing"
            },
            evidence
                .mac_ipad_online_connectable_identity_sequences
                .len(),
            evidence
                .mac_ipad_control_port_reachable_identity_sequences
                .len(),
            evidence.mac_ipad_connect_click_identity_sequences.len(),
            evidence.mac_ipad_connect_start_identity_sequences.len(),
            evidence.mac_ipad_connect_success_identity_sequences.len(),
            duplicate_physical_rows.as_deref().unwrap_or("0")
        ),
    )
}

fn p2p_remote_mac_ipad_duplicate_physical_row_summary(
    evidence: &P2pRemotePerformanceEvidence,
) -> Option<String> {
    evidence
        .mac_ipad_online_physical_identity_rows
        .iter()
        .find_map(|(physical_key, identities)| {
            let row_count = evidence
                .mac_ipad_online_physical_row_counts
                .get(physical_key)
                .copied()
                .unwrap_or(identities.len() as u64);
            if identities.len() <= 1 {
                return None;
            }
            Some(format!(
                "duplicate:rows={}:identityCount={}",
                row_count,
                identities.len()
            ))
        })
}

fn p2p_remote_mac_ipad_ordered_connect_success_identity(
    evidence: &P2pRemotePerformanceEvidence,
) -> Option<String> {
    evidence
        .mac_ipad_online_connectable_identity_sequences
        .iter()
        .find_map(|(identity_source, row_sequence)| {
            let click_sequence = evidence
                .mac_ipad_connect_click_identity_sequences
                .get(identity_source)?;
            let identity = identity_source
                .split_once('\u{1f}')
                .map(|(identity, _)| identity)
                .unwrap_or(identity_source.as_str());
            let control_probe_sequence = evidence
                .mac_ipad_control_port_reachable_identity_sequences
                .get(identity)?;
            let start_sequence = evidence
                .mac_ipad_connect_start_identity_sequences
                .get(identity)?;
            let success_sequence = evidence
                .mac_ipad_connect_success_identity_sequences
                .get(identity)?;
            (*row_sequence <= *click_sequence
                && *row_sequence <= *control_probe_sequence
                && *control_probe_sequence <= *click_sequence
                && *click_sequence <= *start_sequence
                && *start_sequence <= *success_sequence)
                .then(|| identity.to_owned())
        })
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
