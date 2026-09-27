use anyhow::Result;

use crate::{
    MediaLeaseDoctorArgs, OutputOptions, SignalingDoctorArgs, WebRtcMediaDiagnoseArgs,
    WebRtcMediaDoctorArgs, control_plane_doctor, ensure_probe_report_passed,
    print_doctor_probe_report, webrtc_media_artifacts::resolve_webrtc_media_session_arg,
    webrtc_media_doctor::build_webrtc_media_doctor_report,
};

pub(crate) async fn doctor_signaling(args: SignalingDoctorArgs) -> Result<()> {
    let as_json = args.output.json;
    let report = control_plane_doctor::build_signaling_doctor_report(
        args.base_url,
        args.allow_insecure_loopback,
        args.expected_backend.as_deref(),
    )
    .await?;
    finish_doctor_report(&report, as_json, "Signaling doctor failed")
}

pub(crate) async fn doctor_media_lease(args: MediaLeaseDoctorArgs) -> Result<()> {
    let as_json = args.output.json;
    let report = control_plane_doctor::build_media_lease_doctor_report(
        args.base_url,
        args.allow_insecure_loopback,
        args.session_id,
        args.media_admission_token,
    )
    .await?;
    finish_doctor_report(&report, as_json, "Media lease doctor failed")
}

pub(crate) async fn doctor_webrtc_media(args: WebRtcMediaDoctorArgs) -> Result<()> {
    let as_json = args.output.json;
    let session_id = resolve_webrtc_media_session_arg(
        args.session_id.as_deref(),
        args.latest,
        args.artifact_dir.as_deref(),
        args.log_file.as_deref(),
    )?;
    let report = build_webrtc_media_doctor_report(&args, &session_id)?;
    finish_doctor_report(&report, as_json, "WebRTC media doctor failed")
}

fn finish_doctor_report(
    report: &crate::DoctorProbeReport,
    as_json: bool,
    context: &str,
) -> Result<()> {
    let outcome = ensure_probe_report_passed(report, context);
    if as_json && outcome.is_err() {
        crate::cli_output::write_json_failure(&serde_json::json!({
            "schema_version": 1,
            "success": false,
            "status": "failed",
            "error": { "code": "doctor_checks_failed", "message": context, "retryable": false },
            "report": report,
        }))?;
    } else {
        print_doctor_probe_report(report, as_json)?;
    }
    outcome
}

pub(crate) async fn diagnose_webrtc_media(args: WebRtcMediaDiagnoseArgs) -> Result<()> {
    let as_json = args.output.json;
    let session_id = resolve_webrtc_media_session_arg(
        args.session_id.as_deref(),
        args.latest,
        args.artifact_dir.as_deref(),
        args.log_file.as_deref(),
    )?;
    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some(session_id.clone()),
            latest: false,
            artifact_dir: args.artifact_dir,
            log_file: args.log_file,
            since_seconds: args.since_seconds,
            min_fps: args.min_fps,
            require_audio: args.require_audio,
            output: OutputOptions { json: as_json },
        },
        &session_id,
    )?;
    print_doctor_probe_report(&report, as_json)
}
