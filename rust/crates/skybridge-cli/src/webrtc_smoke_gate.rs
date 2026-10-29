use std::time::{Duration, Instant};

use anyhow::{Result, bail};
use time::OffsetDateTime;

use super::{
    OutputOptions, WebRtcMediaDoctorArgs, WebRtcSmokeGateArgs, ensure_webrtc_media_doctor_passed,
    print_doctor_probe_report,
};
use crate::webrtc_media_artifacts::resolve_webrtc_media_session_arg;
use crate::webrtc_media_doctor::build_webrtc_media_doctor_report_for_gate;

mod policy;

use policy::{
    webrtc_smoke_gate_doctor_since_seconds, webrtc_smoke_gate_pass_window_satisfied,
    webrtc_smoke_gate_report_is_fresh, webrtc_smoke_gate_required_evidence_floor,
    webrtc_smoke_gate_strict_fps_floor, webrtc_smoke_gate_terminal_failure,
};

pub(super) async fn smoke_webrtc_gate(args: WebRtcSmokeGateArgs) -> Result<()> {
    if args.timeout_seconds == 0 {
        bail!("--timeout-seconds must be greater than zero");
    }
    if args.min_pass_seconds >= args.timeout_seconds {
        bail!("--min-pass-seconds must be smaller than --timeout-seconds");
    }
    if args.poll_interval_seconds == 0 {
        bail!("--poll-interval-seconds must be greater than zero");
    }
    if !args.min_fps.is_finite() || args.min_fps <= 0.0 {
        bail!("--min-fps must be a positive finite number");
    }
    if (args.min_width == 0) != (args.min_height == 0) {
        bail!("pass both --min-width and --min-height, or neither");
    }
    if args.exact_video_size && (args.min_width == 0 || args.min_height == 0) {
        bail!("--exact-video-size requires --min-width and --min-height");
    }

    let session_id = resolve_webrtc_media_session_arg(
        args.session_id.as_deref(),
        args.latest,
        args.artifact_dir.as_deref(),
        args.log_file.as_deref(),
    )?;
    let started = Instant::now();
    let timeout = Duration::from_secs(args.timeout_seconds);
    let min_pass_duration = Duration::from_secs(args.min_pass_seconds);
    let poll_interval = Duration::from_secs(args.poll_interval_seconds);
    let fresh_sample_max_age = time::Duration::seconds(
        i64::try_from((args.poll_interval_seconds.saturating_mul(3)).max(10)).unwrap_or(i64::MAX),
    );
    let mut passing_since: Option<Instant> = None;
    let mut pass_window_start_at: Option<OffsetDateTime> = None;

    loop {
        let require_receiver = args.min_width > 0 && args.min_height > 0;
        let gate_since_seconds =
            webrtc_smoke_gate_doctor_since_seconds(args.since_seconds, args.poll_interval_seconds);
        let doctor_args = WebRtcMediaDoctorArgs {
            session_id: Some(session_id.clone()),
            latest: false,
            artifact_dir: args.artifact_dir.clone(),
            log_file: args.log_file.clone(),
            since_seconds: gate_since_seconds,
            min_fps: args.min_fps,
            require_audio: args.require_audio,
            output: OutputOptions {
                json: args.output.json,
            },
        };
        let report = build_webrtc_media_doctor_report_for_gate(
            &doctor_args,
            &session_id,
            args.min_width,
            args.min_height,
            args.exact_video_size,
            webrtc_smoke_gate_strict_fps_floor(args.min_fps, args.min_pass_seconds),
            pass_window_start_at,
        )?;
        if ensure_webrtc_media_doctor_passed(&report).is_ok() {
            if min_pass_duration.is_zero() {
                print_doctor_probe_report(&report, args.output.json)?;
                return Ok(());
            }
            if !webrtc_smoke_gate_report_is_fresh(
                &report,
                fresh_sample_max_age,
                args.require_audio,
                require_receiver,
            ) {
                passing_since = None;
                pass_window_start_at = None;
            } else {
                if passing_since.is_none() {
                    if let Some(window_start) = webrtc_smoke_gate_required_evidence_floor(
                        &report,
                        args.require_audio,
                        require_receiver,
                    ) {
                        passing_since = Some(Instant::now());
                        pass_window_start_at = Some(window_start);
                    } else {
                        passing_since = None;
                        pass_window_start_at = None;
                    }
                }
                let wall_window_satisfied = passing_since
                    .is_some_and(|first_passing| first_passing.elapsed() >= min_pass_duration);
                let evidence_window_satisfied = pass_window_start_at.is_some_and(|window_start| {
                    webrtc_smoke_gate_pass_window_satisfied(
                        &report,
                        window_start,
                        min_pass_duration,
                        args.require_audio,
                        require_receiver,
                    )
                });
                if wall_window_satisfied || evidence_window_satisfied {
                    print_doctor_probe_report(&report, args.output.json)?;
                    return Ok(());
                }
            }
        } else {
            passing_since = None;
            pass_window_start_at = None;
        }
        if webrtc_smoke_gate_terminal_failure(&report) {
            print_doctor_probe_report(&report, args.output.json)?;
            ensure_webrtc_media_doctor_passed(&report)?;
            return Ok(());
        }

        if started.elapsed() >= timeout {
            print_doctor_probe_report(&report, args.output.json)?;
            bail!(
                "WebRTC media smoke gate timed out after {}s for session {session_id} (min_fps={:.2}, require_audio={}, min_pass_seconds={})",
                args.timeout_seconds,
                args.min_fps,
                args.require_audio,
                args.min_pass_seconds
            );
        }

        let remaining = timeout.saturating_sub(started.elapsed());
        tokio::time::sleep(poll_interval.min(remaining)).await;
    }
}
