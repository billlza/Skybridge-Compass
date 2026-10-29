use std::time::Duration;

use time::OffsetDateTime;

use crate::DoctorProbeReport;

pub(super) fn webrtc_smoke_gate_strict_fps_floor(min_fps: f64, min_pass_seconds: u64) -> bool {
    min_pass_seconds > 0 || min_fps >= 30.0
}

pub(super) fn webrtc_smoke_gate_doctor_since_seconds(
    args_since_seconds: u64,
    poll_interval_seconds: u64,
) -> u64 {
    args_since_seconds.max((poll_interval_seconds.saturating_mul(3)).max(10))
}

pub(super) fn webrtc_smoke_gate_report_is_fresh(
    report: &DoctorProbeReport,
    max_age: time::Duration,
    require_audio: bool,
    require_receiver: bool,
) -> bool {
    let now = OffsetDateTime::now_utc();
    if !webrtc_smoke_gate_time_is_fresh(report.latest_diagnostic_at, now, max_age)
        || !webrtc_smoke_gate_time_is_fresh(report.latest_video_evidence_at, now, max_age)
    {
        return false;
    }
    if require_receiver
        && !webrtc_smoke_gate_time_is_fresh(report.latest_receiver_evidence_at, now, max_age)
    {
        return false;
    }
    if require_audio {
        webrtc_smoke_gate_time_is_fresh(report.latest_audio_tx_evidence_at, now, max_age)
            && webrtc_smoke_gate_time_is_fresh(report.latest_audio_rx_evidence_at, now, max_age)
    } else {
        true
    }
}

fn webrtc_smoke_gate_time_is_fresh(
    observed_at: Option<OffsetDateTime>,
    now: OffsetDateTime,
    max_age: time::Duration,
) -> bool {
    observed_at.is_some_and(|latest| latest <= now && now - latest <= max_age)
}

pub(super) fn webrtc_smoke_gate_required_evidence_floor(
    report: &DoctorProbeReport,
    require_audio: bool,
    require_receiver: bool,
) -> Option<OffsetDateTime> {
    let mut times = vec![report.latest_video_evidence_at?];
    if require_receiver {
        times.push(report.latest_receiver_evidence_at?);
    }
    if require_audio {
        times.push(report.latest_audio_tx_evidence_at?);
        times.push(report.latest_audio_rx_evidence_at?);
    }
    times.into_iter().min()
}

pub(super) fn webrtc_smoke_gate_pass_window_satisfied(
    report: &DoctorProbeReport,
    window_start: OffsetDateTime,
    min_pass_duration: Duration,
    require_audio: bool,
    require_receiver: bool,
) -> bool {
    if min_pass_duration.is_zero() {
        return true;
    }
    let Some(evidence_floor) =
        webrtc_smoke_gate_required_evidence_floor(report, require_audio, require_receiver)
    else {
        return false;
    };
    if evidence_floor < window_start {
        return false;
    }
    let Ok(required_seconds) = i64::try_from(min_pass_duration.as_secs()) else {
        return false;
    };
    evidence_floor - window_start >= time::Duration::seconds(required_seconds)
}

pub(super) fn webrtc_smoke_gate_terminal_failure(report: &DoctorProbeReport) -> bool {
    if matches!(
        report.fault_stage,
        Some(
            "strict_media_failure"
                | "fallback_backpressure"
                | "fallback_capture_stalled"
                | "sck_capture_stalled"
                | "vt_encode_stalled"
                | "vt_encode_slow"
                | "native_video_rtp_stalled"
        )
    ) {
        return true;
    }

    report.checks.iter().any(|check| {
        !check.ok
            && matches!(
                check.name,
                "strict_media_failure" | "stale_fallback" | "backpressure" | "audio_relay_startup"
            )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DoctorCheck, DoctorProbeReport};

    #[test]
    fn smoke_webrtc_gate_terminal_failure_classifies_hard_failures() {
        let report = DoctorProbeReport {
            target: "webrtc-media session=SESSION1".to_owned(),
            checks: vec![],
            fault_stage: Some("strict_media_failure"),
            latest_diagnostic_at: None,
            latest_video_evidence_at: None,
            latest_receiver_evidence_at: None,
            latest_audio_tx_evidence_at: None,
            latest_audio_rx_evidence_at: None,
        };
        assert!(webrtc_smoke_gate_terminal_failure(&report));

        let vt_slow = DoctorProbeReport {
            target: "webrtc-media session=SESSION1".to_owned(),
            checks: vec![],
            fault_stage: Some("vt_encode_slow"),
            latest_diagnostic_at: None,
            latest_video_evidence_at: None,
            latest_receiver_evidence_at: None,
            latest_audio_tx_evidence_at: None,
            latest_audio_rx_evidence_at: None,
        };
        assert!(webrtc_smoke_gate_terminal_failure(&vt_slow));

        let pending = DoctorProbeReport {
            target: "webrtc-media session=SESSION1".to_owned(),
            checks: vec![DoctorCheck {
                name: "diagnostic_samples",
                ok: false,
                severity: "warn",
                detail: "no diagnostics matched yet".to_owned(),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            }],
            fault_stage: Some("diagnostics_missing"),
            latest_diagnostic_at: None,
            latest_video_evidence_at: None,
            latest_receiver_evidence_at: None,
            latest_audio_tx_evidence_at: None,
            latest_audio_rx_evidence_at: None,
        };
        assert!(!webrtc_smoke_gate_terminal_failure(&pending));
    }

    #[test]
    fn smoke_webrtc_gate_uses_strict_fps_floor_for_high_fps_and_soak() {
        assert!(webrtc_smoke_gate_strict_fps_floor(30.0, 0));
        assert!(webrtc_smoke_gate_strict_fps_floor(30.0, 60));
        assert!(webrtc_smoke_gate_strict_fps_floor(59.0, 0));
        assert!(webrtc_smoke_gate_strict_fps_floor(60.0, 0));
    }

    #[test]
    fn smoke_webrtc_gate_uses_full_doctor_window_for_continuity() {
        assert_eq!(webrtc_smoke_gate_doctor_since_seconds(600, 2), 600);
        assert_eq!(webrtc_smoke_gate_doctor_since_seconds(5, 2), 10);
    }

    #[test]
    fn smoke_webrtc_gate_soak_window_uses_slowest_required_evidence() {
        let base = OffsetDateTime::from_unix_timestamp(1_700_000_000).unwrap();
        let report = DoctorProbeReport {
            target: "webrtc-media session=SESSION1".to_owned(),
            checks: vec![],
            fault_stage: None,
            latest_diagnostic_at: Some(base + time::Duration::seconds(8)),
            latest_video_evidence_at: Some(base + time::Duration::seconds(5)),
            latest_receiver_evidence_at: Some(base + time::Duration::seconds(4)),
            latest_audio_tx_evidence_at: Some(base),
            latest_audio_rx_evidence_at: Some(base + time::Duration::seconds(6)),
        };

        assert_eq!(
            webrtc_smoke_gate_required_evidence_floor(&report, true, true),
            Some(base)
        );
        assert_eq!(
            webrtc_smoke_gate_required_evidence_floor(&report, false, true),
            Some(base + time::Duration::seconds(4))
        );
    }

    #[test]
    fn smoke_webrtc_gate_soak_window_passes_on_diagnostic_timestamps() {
        let base = OffsetDateTime::from_unix_timestamp(1_700_000_000).unwrap();
        let mut report = DoctorProbeReport {
            target: "webrtc-media session=SESSION1".to_owned(),
            checks: vec![],
            fault_stage: None,
            latest_diagnostic_at: Some(base),
            latest_video_evidence_at: Some(base),
            latest_receiver_evidence_at: Some(base),
            latest_audio_tx_evidence_at: Some(base),
            latest_audio_rx_evidence_at: Some(base),
        };
        let duration = Duration::from_secs(30);

        report.latest_video_evidence_at = Some(base + time::Duration::seconds(29));
        report.latest_receiver_evidence_at = Some(base + time::Duration::seconds(30));
        report.latest_audio_tx_evidence_at = Some(base + time::Duration::seconds(30));
        report.latest_audio_rx_evidence_at = Some(base + time::Duration::seconds(30));
        assert!(!webrtc_smoke_gate_pass_window_satisfied(
            &report, base, duration, true, true
        ));

        report.latest_video_evidence_at = Some(base + time::Duration::seconds(31));
        assert!(webrtc_smoke_gate_pass_window_satisfied(
            &report, base, duration, true, true
        ));
    }
}
