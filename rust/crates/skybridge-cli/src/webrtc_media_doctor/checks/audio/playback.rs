use crate::DoctorCheck;
use crate::webrtc_media_doctor::evidence::WebRtcMediaEvidence;

use super::super::{
    counter_observed_positive, latest_counter_value, latest_positive_counter_value,
};

pub(in crate::webrtc_media_doctor) fn check_webrtc_audio_playback_continuity(
    evidence: &WebRtcMediaEvidence,
) -> DoctorCheck {
    let mut failures = Vec::new();
    for (label, observation) in [
        ("rebuffer", &evidence.audio_rebuffer),
        ("playbackDrop", &evidence.audio_playback_drop),
        ("jitterEvicted", &evidence.audio_jitter_evicted),
    ] {
        if let Some(metric) = observation.latest_positive.as_ref() {
            failures.push(format!(
                "{label}={} evidence {}",
                metric.value, metric.evidence
            ));
        }
    }
    if counter_observed_positive(&evidence.audio_underflow)
        && !webrtc_audio_underflow_is_soft_bridged(evidence)
        && let Some(metric) = evidence.audio_underflow.latest_positive.as_ref()
    {
        failures.push(format!(
            "underflow={} evidence {}",
            metric.value, metric.evidence
        ));
    }
    if let Some(metric) = evidence.audio_playout_pressure.as_ref() {
        failures.push(format!(
            "playout pressure ({}) evidence {}",
            metric.value, metric.evidence
        ));
    }
    if failures.is_empty() {
        let detail = if counter_observed_positive(&evidence.audio_underflow)
            && webrtc_audio_underflow_is_soft_bridged(evidence)
        {
            "bounded soft-bridged audio underflow observed without rebuffer/playbackDrop/jitterEvicted"
                .to_owned()
        } else {
            "no audio underflow/rebuffer/playbackDrop/jitterEvicted/playout-pressure evidence observed"
                .to_owned()
        };
        return DoctorCheck {
            name: "audio_playback_continuity",
            ok: true,
            severity: "info",
            detail,
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    DoctorCheck {
        name: "audio_playback_continuity",
        ok: false,
        severity: "error",
        detail: format!("audio playback continuity failed: {}", failures.join("; ")),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

pub(in crate::webrtc_media_doctor) fn webrtc_audio_has_hard_playback_failure(
    evidence: &WebRtcMediaEvidence,
) -> bool {
    counter_observed_positive(&evidence.audio_rebuffer)
        || counter_observed_positive(&evidence.audio_playback_drop)
        || counter_observed_positive(&evidence.audio_jitter_evicted)
        || evidence.audio_playout_pressure.is_some()
        || (counter_observed_positive(&evidence.audio_underflow)
            && !webrtc_audio_underflow_is_soft_bridged(evidence))
}

fn webrtc_audio_underflow_is_soft_bridged(evidence: &WebRtcMediaEvidence) -> bool {
    const MAX_SOFT_BRIDGED_UNDERFLOW_EVENTS: u64 = 4;
    const MAX_SOFT_BRIDGED_UNDERFLOW_SAMPLES: u64 = 3_840;

    let Some(underflow_events) = latest_positive_counter_value(&evidence.audio_underflow) else {
        return false;
    };
    let Some(bridged_samples) = latest_positive_counter_value(&evidence.audio_bridged_underflow)
    else {
        return false;
    };
    underflow_events <= MAX_SOFT_BRIDGED_UNDERFLOW_EVENTS
        && bridged_samples <= MAX_SOFT_BRIDGED_UNDERFLOW_SAMPLES
        && !counter_observed_positive(&evidence.audio_rebuffer)
        && !counter_observed_positive(&evidence.audio_playback_drop)
        && !counter_observed_positive(&evidence.audio_jitter_evicted)
        && latest_counter_value(&evidence.audio_rendered_frames).is_some_and(|value| value > 0)
}
