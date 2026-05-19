use super::super::evidence::WebRtcMediaEvidence;
use super::audio::{
    classify_webrtc_audio_continuity_stage, webrtc_audio_has_hard_playback_failure,
    webrtc_audio_rx_has_received,
};
use super::video::{classify_webrtc_sck_tx_stage, webrtc_fallback_video_is_healthy};
use super::{counter_observed_positive, latest_counter_value};
use crate::DoctorCheck;

pub(in crate::webrtc_media_doctor) fn check_webrtc_probable_fault_stage(
    stage: Option<&'static str>,
) -> DoctorCheck {
    DoctorCheck {
        name: "probable_fault_stage",
        ok: stage.is_none(),
        severity: if stage.is_some() { "error" } else { "info" },
        detail: stage.map_or_else(
            || "no single dominant WebRTC media fault stage detected".to_owned(),
            |stage| format!("probable fault stage: {stage}"),
        ),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

pub(in crate::webrtc_media_doctor) fn classify_webrtc_probable_fault_stage(
    evidence: &WebRtcMediaEvidence,
    require_audio: bool,
    min_fps: f64,
) -> Option<&'static str> {
    if evidence.matched_lines == 0 {
        return Some("diagnostics_missing");
    }
    if require_audio {
        if evidence
            .strict_media_failure
            .as_ref()
            .is_some_and(|failure| {
                failure
                    .value
                    .contains("realtime-audio-main-path-unavailable")
            })
        {
            if evidence.audio_tx_relay_failure.is_some()
                || evidence.audio_tx_relay_bind_pending.is_some()
            {
                return Some("audio_tx_relay_bind");
            }
            if evidence.audio_tx_missing_viewer_endpoint.is_some() {
                return Some("audio_tx_relay_send");
            }
        }
        if latest_counter_value(&evidence.audio_tx_captured) == Some(0) {
            return Some("audio_tx_capture");
        }
        if latest_counter_value(&evidence.audio_tx_encoded) == Some(0) {
            return Some("audio_tx_encode");
        }
        if latest_counter_value(&evidence.audio_tx_sent) == Some(0) {
            return Some("audio_tx_relay_send");
        }
        let tx_has_sent_media =
            latest_counter_value(&evidence.audio_tx_sent).is_some_and(|value| value > 0);
        if !tx_has_sent_media
            && evidence
                .audio_tx_relay_failure
                .as_ref()
                .is_some_and(|metric| {
                    metric.value.contains("leaseLimit") || metric.value.contains("relayBind")
                })
        {
            return Some("audio_tx_relay_send");
        }
        if evidence.audio_tx_relay_failure.is_some() && !webrtc_audio_rx_has_received(evidence) {
            return Some("audio_tx_relay_bind");
        }
        if evidence.audio_tx_relay_bind_pending.is_some() && !webrtc_audio_rx_has_received(evidence)
        {
            return Some("audio_tx_relay_bind");
        }
        if evidence.audio_tx_missing_viewer_endpoint.is_some()
            && evidence.audio_tx_relay_failure.is_none()
        {
            return Some("audio_tx_relay_send");
        }
        if evidence.audio_rx_relay_bind_failure.is_some() {
            return Some("audio_rx_relay_recv");
        }
        if latest_counter_value(&evidence.audio_rx_recv) == Some(0)
            || evidence.audio_rx_recv.zero_after_positive.is_some()
        {
            return Some("audio_rx_relay_recv");
        }
        if latest_counter_value(&evidence.audio_rx_decoded) == Some(0)
            || evidence.audio_rx_decoded.zero_after_positive.is_some()
        {
            return Some("audio_rx_decode");
        }
        if latest_counter_value(&evidence.audio_rx_played) == Some(0)
            || evidence.audio_rx_played.zero_after_positive.is_some()
        {
            return Some("audio_rx_playback");
        }
        if webrtc_audio_has_hard_playback_failure(evidence)
            || counter_observed_positive(&evidence.audio_rebuffer)
            || counter_observed_positive(&evidence.audio_playback_drop)
            || counter_observed_positive(&evidence.audio_jitter_evicted)
        {
            return Some("audio_rx_playback");
        }
    }
    if evidence.strict_media_failure.is_some() {
        return Some("strict_media_failure");
    }
    if evidence.backpressure.is_some() {
        return Some("fallback_backpressure");
    }
    if let Some(stage) = classify_webrtc_sck_tx_stage(evidence, min_fps) {
        return Some(stage);
    }
    if evidence.fallback_producer_failure.is_some() {
        return Some("fallback_capture_stalled");
    }
    if evidence
        .lowest_fps
        .as_ref()
        .is_some_and(|fps| fps.value <= 2.0)
        || (evidence.native_video_failure.is_some() && !webrtc_fallback_video_is_healthy(evidence))
    {
        return Some("native_video_rtp_stalled");
    }
    if require_audio && let Some(stage) = classify_webrtc_audio_continuity_stage(evidence) {
        return Some(stage);
    }
    None
}
