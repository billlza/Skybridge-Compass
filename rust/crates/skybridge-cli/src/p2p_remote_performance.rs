use anyhow::{Result, anyhow};

use super::{
    DoctorCheck, DoctorProbeReport, PerformanceCheckArgs,
    required_p2p_remote_performance_check_names,
};
pub(crate) use crate::p2p_remote_performance_checks::*;
pub(crate) use crate::p2p_remote_performance_evidence::*;

pub(crate) fn build_p2p_remote_performance_report(
    args: &PerformanceCheckArgs,
) -> Result<DoctorProbeReport> {
    let artifact_dir = args
        .artifact_dir
        .as_deref()
        .ok_or_else(|| anyhow!("P2P remote performance check requires --artifact-dir"))?;
    let evidence = read_p2p_remote_performance_evidence(artifact_dir)?;
    let complete_artifact_check = if args.manual_artifact {
        check_p2p_remote_complete_artifact_for_mode(&evidence, true)
    } else {
        check_p2p_remote_complete_artifact(&evidence)
    };
    let mut checks = vec![
        check_p2p_remote_sources(&evidence),
        complete_artifact_check,
        check_p2p_remote_no_hidden_failure(&evidence),
        check_p2p_remote_lan_route(&evidence),
        check_p2p_remote_xwing(&evidence),
        check_p2p_remote_protocol_identity_binding(&evidence),
        check_p2p_remote_signed_kem_refresh(&evidence),
        check_p2p_remote_mac_ipad_online_connect_button(&evidence),
        check_p2p_remote_hevc_main_path(&evidence),
        check_p2p_remote_resolution(&evidence, args),
        check_p2p_remote_ios_window_fps(&evidence, args.min_fps),
        check_p2p_remote_mac_tx(&evidence, args.min_fps),
        check_p2p_remote_mac_final_window_fps(
            &evidence,
            args.min_fps,
            args.min_pass_window_seconds,
        ),
        check_p2p_remote_timing_correlation(&evidence, args.min_fps),
        check_p2p_remote_ios_raw_latency(&evidence, args.min_fps),
        check_p2p_remote_metal_render_queue(&evidence, args.min_fps),
        check_p2p_remote_decode_queue(&evidence),
        check_p2p_remote_audio(&evidence),
        check_p2p_remote_no_fallback(&evidence),
    ];
    let required = required_p2p_remote_performance_check_names();
    let missing = required
        .iter()
        .copied()
        .filter(|name| checks.iter().all(|check| check.name != *name))
        .collect::<Vec<_>>();
    checks.push(DoctorCheck {
        name: "performance_check_surface",
        ok: missing.is_empty(),
        severity: if missing.is_empty() { "info" } else { "error" },
        detail: if missing.is_empty() {
            format!(
                "P2P remote performance gate covers required checks: {}",
                required.join(",")
            )
        } else {
            format!(
                "P2P remote performance gate is missing checks: {}",
                missing.join(",")
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    });

    Ok(DoctorProbeReport {
        target: format!(
            "performance p2p-remote artifact={} min_fps={:.1}",
            artifact_dir.display(),
            args.min_fps
        ),
        checks,
        fault_stage: if evidence.already_connected_rejection_count > 0 {
            Some("p2p_remote_already_connected")
        } else {
            evidence
                .first_failure
                .as_ref()
                .map(|_| "p2p_remote_failed_stage")
        },
        latest_diagnostic_at: None,
        latest_video_evidence_at: None,
        latest_receiver_evidence_at: None,
        latest_audio_tx_evidence_at: None,
        latest_audio_rx_evidence_at: None,
    })
}
