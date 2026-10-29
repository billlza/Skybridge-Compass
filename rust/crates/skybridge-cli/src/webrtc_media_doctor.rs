use anyhow::{Result, bail};
use time::OffsetDateTime;

use super::{DoctorProbeReport, WebRtcMediaDoctorArgs};

mod checks;
mod evidence;
mod line_extract;
use checks::*;
use evidence::{describe_webrtc_sources, read_webrtc_media_evidence};

pub(super) fn build_webrtc_media_doctor_report(
    args: &WebRtcMediaDoctorArgs,
    session_id: &str,
) -> Result<DoctorProbeReport> {
    build_webrtc_media_doctor_report_with_video_requirements(args, session_id, 0, 0, false)
}

pub(super) fn build_webrtc_media_doctor_report_with_video_requirements(
    args: &WebRtcMediaDoctorArgs,
    session_id: &str,
    min_width: u32,
    min_height: u32,
    exact_video_size: bool,
) -> Result<DoctorProbeReport> {
    build_webrtc_media_doctor_report_with_options(
        args,
        session_id,
        min_width,
        min_height,
        exact_video_size,
        false,
        None,
    )
}

pub(crate) fn build_webrtc_media_doctor_report_for_gate(
    args: &WebRtcMediaDoctorArgs,
    session_id: &str,
    min_width: u32,
    min_height: u32,
    exact_video_size: bool,
    strict_fps_floor: bool,
    not_before: Option<OffsetDateTime>,
) -> Result<DoctorProbeReport> {
    build_webrtc_media_doctor_report_with_options(
        args,
        session_id,
        min_width,
        min_height,
        exact_video_size,
        strict_fps_floor,
        not_before,
    )
}

fn build_webrtc_media_doctor_report_with_options(
    args: &WebRtcMediaDoctorArgs,
    session_id: &str,
    min_width: u32,
    min_height: u32,
    exact_video_size: bool,
    strict_fps_floor: bool,
    not_before: Option<OffsetDateTime>,
) -> Result<DoctorProbeReport> {
    let session_id = session_id.trim();
    if session_id.is_empty() {
        bail!("--session-id must not be empty");
    }
    if !args.min_fps.is_finite() || args.min_fps <= 0.0 {
        bail!("--min-fps must be a positive finite number");
    }
    if (min_width == 0) != (min_height == 0) {
        bail!("pass both min_width and min_height, or neither");
    }
    if exact_video_size && (min_width == 0 || min_height == 0) {
        bail!("exact_video_size requires min_width and min_height");
    }

    let now = OffsetDateTime::now_utc();
    let evidence = read_webrtc_media_evidence(
        session_id,
        args.artifact_dir.as_deref(),
        args.log_file.as_deref(),
        args.since_seconds,
        now,
        not_before,
    );
    let require_audio = args.require_audio;
    let mut checks = Vec::new();
    checks.push(check_webrtc_media_sources(&evidence));
    checks.push(check_webrtc_media_samples(
        &evidence,
        session_id,
        args.since_seconds,
    ));
    checks.push(check_webrtc_media_fps(
        &evidence,
        args.min_fps,
        require_audio,
        strict_fps_floor,
    ));
    if min_width > 0 && min_height > 0 {
        checks.push(check_webrtc_video_resolution(
            &evidence,
            min_width,
            min_height,
            exact_video_size,
        ));
    }
    if require_audio {
        checks.push(check_webrtc_media_counter(
            "audio_tx_captured",
            "audioTxCaptured",
            &evidence.audio_tx_captured,
        ));
        checks.push(check_webrtc_media_counter(
            "audio_tx_encoded",
            "audioTxEncoded",
            &evidence.audio_tx_encoded,
        ));
        checks.push(check_webrtc_media_counter(
            "audio_tx_sent",
            "audioTxSent",
            &evidence.audio_tx_sent,
        ));
        checks.push(check_webrtc_media_counter(
            "audio_rx_recv",
            "audioRxRecv",
            &evidence.audio_rx_recv,
        ));
        checks.push(check_webrtc_media_counter(
            "audio_rx_decoded",
            "audioRxDecoded",
            &evidence.audio_rx_decoded,
        ));
        checks.push(check_webrtc_media_counter(
            "audio_rx_played",
            "audioRxPlayed",
            &evidence.audio_rx_played,
        ));
        checks.push(check_webrtc_rendered_frames_counter(&evidence));
        checks.push(check_webrtc_audio_activity_continuity(&evidence));
        checks.push(check_webrtc_audio_playback_continuity(&evidence));
        checks.push(check_webrtc_audio_relay_startup(&evidence));
    }
    checks.push(check_webrtc_native_video_health(&evidence));
    checks.push(check_webrtc_native_video_rtc_stats(
        &evidence,
        args.min_fps,
        strict_fps_floor,
    ));
    checks.push(check_webrtc_sck_vt_encode_latency(
        &evidence,
        args.min_fps,
        strict_fps_floor,
    ));
    checks.push(check_webrtc_native_video_receiver(&evidence));
    checks.push(check_webrtc_visible_native_render(
        &evidence,
        args.min_fps,
        strict_fps_floor,
    ));
    checks.push(check_webrtc_visible_render_fps(
        &evidence,
        args.min_fps,
        strict_fps_floor,
    ));
    checks.push(check_webrtc_strict_media_failure(&evidence));
    checks.push(check_webrtc_stale_fallback(&evidence));
    checks.push(check_webrtc_backpressure(&evidence));
    let fault_stage = classify_webrtc_probable_fault_stage(&evidence, require_audio, args.min_fps);
    checks.push(check_webrtc_probable_fault_stage(fault_stage));

    Ok(DoctorProbeReport {
        target: format!(
            "webrtc-media session={} since={}s sources={}",
            session_id,
            args.since_seconds,
            describe_webrtc_sources(&evidence)
        ),
        checks,
        fault_stage,
        latest_diagnostic_at: evidence.latest_at,
        latest_video_evidence_at: evidence.latest_video_evidence_at,
        latest_receiver_evidence_at: evidence.latest_receiver_evidence_at,
        latest_audio_tx_evidence_at: evidence.latest_audio_tx_evidence_at,
        latest_audio_rx_evidence_at: evidence.latest_audio_rx_evidence_at,
    })
}
