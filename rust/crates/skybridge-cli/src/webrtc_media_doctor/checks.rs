use super::evidence::{CounterObservation, WebRtcMediaEvidence};
use crate::DoctorCheck;

mod audio;
mod continuity;
mod diagnostics;
mod fault_stage;

pub(super) use audio::{
    check_webrtc_audio_activity_continuity, check_webrtc_audio_playback_continuity,
    check_webrtc_audio_relay_startup,
};
pub(super) use diagnostics::{check_webrtc_media_samples, check_webrtc_media_sources};
pub(super) use fault_stage::{
    check_webrtc_probable_fault_stage, classify_webrtc_probable_fault_stage,
};

mod video;

use continuity::{
    describe_webrtc_counter_continuity, describe_webrtc_rendered_frames_continuity,
    webrtc_counter_has_continuity, webrtc_rendered_frames_have_continuity,
};
pub(super) use video::{
    check_webrtc_media_fps, check_webrtc_native_video_health, check_webrtc_native_video_receiver,
    check_webrtc_native_video_rtc_stats, check_webrtc_sck_vt_encode_latency,
    check_webrtc_video_resolution, check_webrtc_visible_native_render,
    check_webrtc_visible_render_fps,
};

pub(super) fn latest_counter_value(observation: &CounterObservation) -> Option<u64> {
    observation.latest.as_ref().map(|value| value.value)
}

pub(super) fn latest_positive_counter_value(observation: &CounterObservation) -> Option<u64> {
    observation
        .latest_positive
        .as_ref()
        .map(|value| value.value)
}

pub(super) fn counter_observed_positive(observation: &CounterObservation) -> bool {
    observation
        .latest_positive
        .as_ref()
        .is_some_and(|metric| metric.value > 0)
}

pub(super) fn check_webrtc_media_counter(
    name: &'static str,
    label: &str,
    observation: &CounterObservation,
) -> DoctorCheck {
    let Some(latest_metric) = observation.latest.as_ref() else {
        return webrtc_missing_observation_check(
            name,
            &format!("{label} was not observed for this session"),
        );
    };
    let latest = latest_metric.value.to_string();
    let ok = latest_metric.value > 0
        || (observation.seen_positive && observation.zero_after_positive.is_none());
    let zero_after_positive = observation.zero_after_positive.as_ref();
    DoctorCheck {
        name,
        ok: ok && zero_after_positive.is_none(),
        severity: if ok && zero_after_positive.is_none() {
            "info"
        } else {
            "error"
        },
        detail: if let Some(zero_after_positive) = zero_after_positive {
            format!(
                "{label} fell to zero after prior positive traffic; latest {latest}; evidence {}",
                zero_after_positive.evidence
            )
        } else if ok {
            format!("{label} stayed above zero; latest {latest}")
        } else {
            format!(
                "{label} has no positive observation; latest {latest}; evidence {}",
                latest_metric.evidence
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

pub(super) fn check_webrtc_rendered_frames_counter(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    let observation = &evidence.audio_rendered_frames;
    let Some(latest_metric) = observation.latest.as_ref() else {
        return webrtc_missing_observation_check(
            "audio_rendered_frames",
            "renderedFrames was not observed for this session",
        );
    };
    let latest = latest_metric.value.to_string();
    let ok = observation.seen_positive;
    DoctorCheck {
        name: "audio_rendered_frames",
        ok,
        severity: if ok { "info" } else { "error" },
        detail: if ok {
            let positive = observation
                .latest_positive
                .as_ref()
                .map(|metric| metric.value.to_string())
                .unwrap_or_else(|| "unknown".to_owned());
            format!(
                "renderedFrames observed positive playback frames; latest {latest}; latest positive {positive}"
            )
        } else {
            format!(
                "renderedFrames has no positive observation; latest {latest}; evidence {}",
                latest_metric.evidence
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

pub(super) fn check_webrtc_strict_media_failure(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    if let Some(failure) = evidence.strict_media_failure.as_ref() {
        return DoctorCheck {
            name: "strict_media_failure",
            ok: false,
            severity: "error",
            detail: format!(
                "strict WebRTC media failure observed: {}; evidence {}",
                failure.value, failure.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    DoctorCheck {
        name: "strict_media_failure",
        ok: true,
        severity: "info",
        detail: "no strict WebRTC media failure was observed".to_owned(),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

pub(super) fn check_webrtc_stale_fallback(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    if let Some(stale) = evidence.stale_fallback.as_ref() {
        return DoctorCheck {
            name: "stale_fallback",
            ok: false,
            severity: "error",
            detail: format!(
                "forbidden WebRTC fallback evidence observed: {}",
                stale.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    DoctorCheck {
        name: "stale_fallback",
        ok: true,
        severity: "info",
        detail: "no WebRTC fallback evidence observed".to_owned(),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

pub(super) fn check_webrtc_backpressure(evidence: &WebRtcMediaEvidence) -> DoctorCheck {
    if let Some(backpressure) = evidence.backpressure.as_ref() {
        return DoctorCheck {
            name: "backpressure",
            ok: false,
            severity: "warn",
            detail: format!("backpressure evidence observed: {}", backpressure.evidence),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    DoctorCheck {
        name: "backpressure",
        ok: true,
        severity: "info",
        detail: "no stream backpressure/drop evidence observed".to_owned(),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

fn webrtc_missing_observation_check(name: &'static str, detail: &str) -> DoctorCheck {
    DoctorCheck {
        name,
        ok: false,
        severity: "warn",
        detail: detail.to_owned(),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}
