use anyhow::Result;

use super::{
    DoctorCheck, DoctorProbeReport, OutputOptions, PerformanceCheckArgs, PerformanceKindArg,
    WebRtcMediaDoctorArgs, ensure_probe_report_passed, print_doctor_probe_report,
};
use crate::file_transfer_performance::{
    build_file_transfer_performance_report, file_transfer_performance_artifact_available,
};
use crate::p2p_remote_performance::{
    build_p2p_remote_performance_report, p2p_remote_performance_artifact_available,
};
use crate::performance_check_names::required_webrtc_performance_check_names;
use crate::webrtc_media_artifacts::resolve_webrtc_media_session_arg;
use crate::webrtc_media_doctor::build_webrtc_media_doctor_report_for_gate;

pub(crate) async fn check_performance(args: PerformanceCheckArgs) -> Result<()> {
    run_performance_check(args, "performance check failed").await
}

pub(crate) async fn run_performance_check(
    args: PerformanceCheckArgs,
    failure_context: &'static str,
) -> Result<()> {
    let as_json = args.output.json;
    let report = match args.kind {
        PerformanceKindArg::P2pRemote => build_p2p_remote_performance_report(&args)?,
        PerformanceKindArg::FileTransfer => build_file_transfer_performance_report(&args)?,
        PerformanceKindArg::Webrtc => {
            let session_id = resolve_webrtc_media_session_arg(
                args.session_id.as_deref(),
                args.latest,
                args.artifact_dir.as_deref(),
                args.log_file.as_deref(),
            )?;
            build_performance_check_report(&args, &session_id)?
        }
        PerformanceKindArg::Auto
            if args.session_id.is_none()
                && args.artifact_dir.is_some()
                && p2p_remote_performance_artifact_available(args.artifact_dir.as_deref()) =>
        {
            build_p2p_remote_performance_report(&args)?
        }
        PerformanceKindArg::Auto
            if args.session_id.is_none()
                && args.artifact_dir.is_some()
                && file_transfer_performance_artifact_available(args.artifact_dir.as_deref()) =>
        {
            build_file_transfer_performance_report(&args)?
        }
        PerformanceKindArg::Auto => {
            let session_id = resolve_webrtc_media_session_arg(
                args.session_id.as_deref(),
                args.latest,
                args.artifact_dir.as_deref(),
                args.log_file.as_deref(),
            )?;
            build_performance_check_report(&args, &session_id)?
        }
    };
    print_doctor_probe_report(&report, as_json)?;
    ensure_probe_report_passed(&report, failure_context)
}

pub(super) fn build_performance_check_report(
    args: &PerformanceCheckArgs,
    session_id: &str,
) -> Result<DoctorProbeReport> {
    let doctor_args = WebRtcMediaDoctorArgs {
        session_id: Some(session_id.to_owned()),
        latest: false,
        artifact_dir: args.artifact_dir.clone(),
        log_file: args.log_file.clone(),
        since_seconds: args.since_seconds,
        min_fps: args.min_fps,
        require_audio: args.require_audio,
        output: OutputOptions {
            json: args.output.json,
        },
    };
    let mut report = build_webrtc_media_doctor_report_for_gate(
        &doctor_args,
        session_id,
        args.min_width,
        args.min_height,
        args.exact_video_size,
        args.strict_fps_floor,
        None,
    )?;
    let required = required_webrtc_performance_check_names();
    let missing = required
        .iter()
        .copied()
        .filter(|name| report.checks.iter().all(|check| check.name != *name))
        .collect::<Vec<_>>();
    report.checks.push(DoctorCheck {
        name: "performance_check_surface",
        ok: missing.is_empty(),
        severity: if missing.is_empty() { "info" } else { "error" },
        detail: if missing.is_empty() {
            format!(
                "performance gate covers required checks: {}",
                required.join(",")
            )
        } else {
            format!("performance gate is missing checks: {}", missing.join(","))
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    });
    report.target = format!("performance {}", report.target);
    Ok(report)
}
