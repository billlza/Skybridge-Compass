use super::super::evidence::WebRtcMediaEvidence;
use super::{
    counter_observed_positive, describe_webrtc_counter_continuity,
    describe_webrtc_rendered_frames_continuity, webrtc_counter_has_continuity,
    webrtc_rendered_frames_have_continuity,
};
use crate::DoctorCheck;

mod playback;
mod relay;

pub(in crate::webrtc_media_doctor) use playback::{
    check_webrtc_audio_playback_continuity, webrtc_audio_has_hard_playback_failure,
};
pub(in crate::webrtc_media_doctor) use relay::{
    check_webrtc_audio_relay_startup, webrtc_audio_rx_has_received,
};

pub(in crate::webrtc_media_doctor) fn classify_webrtc_audio_continuity_stage(
    evidence: &WebRtcMediaEvidence,
) -> Option<&'static str> {
    if !webrtc_counter_has_continuity(
        &evidence.audio_tx_captured,
        Some(&evidence.audio_tx_captured_total),
    ) {
        return Some("audio_tx_capture");
    }
    if !webrtc_counter_has_continuity(
        &evidence.audio_tx_encoded,
        Some(&evidence.audio_tx_encoded_total),
    ) {
        return Some("audio_tx_encode");
    }
    if !webrtc_counter_has_continuity(&evidence.audio_tx_sent, Some(&evidence.audio_tx_sent_total))
        || counter_observed_positive(&evidence.audio_drops)
        || counter_observed_positive(&evidence.audio_drops_total)
    {
        return Some("audio_tx_relay_send");
    }
    if !webrtc_counter_has_continuity(&evidence.audio_rx_recv, Some(&evidence.audio_rx_recv_total))
    {
        return Some("audio_rx_relay_recv");
    }
    if !webrtc_counter_has_continuity(
        &evidence.audio_rx_decoded,
        Some(&evidence.audio_rx_decoded_total),
    ) {
        return Some("audio_rx_decode");
    }
    if !webrtc_counter_has_continuity(
        &evidence.audio_rx_played,
        Some(&evidence.audio_rx_played_total),
    ) || !webrtc_rendered_frames_have_continuity(evidence)
    {
        return Some("audio_rx_playback");
    }
    None
}

pub(in crate::webrtc_media_doctor) fn check_webrtc_audio_activity_continuity(
    evidence: &WebRtcMediaEvidence,
) -> DoctorCheck {
    let mut failures = Vec::new();
    for (label, window, total) in [
        (
            "audioTxCaptured",
            &evidence.audio_tx_captured,
            Some(&evidence.audio_tx_captured_total),
        ),
        (
            "audioTxEncoded",
            &evidence.audio_tx_encoded,
            Some(&evidence.audio_tx_encoded_total),
        ),
        (
            "audioTxSent",
            &evidence.audio_tx_sent,
            Some(&evidence.audio_tx_sent_total),
        ),
        (
            "audioRxRecv",
            &evidence.audio_rx_recv,
            Some(&evidence.audio_rx_recv_total),
        ),
        (
            "audioRxDecoded",
            &evidence.audio_rx_decoded,
            Some(&evidence.audio_rx_decoded_total),
        ),
        (
            "audioRxPlayed",
            &evidence.audio_rx_played,
            Some(&evidence.audio_rx_played_total),
        ),
    ] {
        if let Some(failure) = describe_webrtc_counter_continuity(label, window, total) {
            failures.push(failure);
        }
    }
    if let Some(failure) = describe_webrtc_rendered_frames_continuity(evidence) {
        failures.push(failure);
    }
    if let Some(drop) = evidence.audio_drops.latest_positive.as_ref() {
        failures.push(format!(
            "audioDrops={} after telemetry prime; evidence {}",
            drop.value, drop.evidence
        ));
    }
    DoctorCheck {
        name: "audio_activity_continuity",
        ok: failures.is_empty(),
        severity: if failures.is_empty() { "info" } else { "error" },
        detail: if failures.is_empty() {
            "audio TX/RX/playback counters showed sustained activity across multiple samples"
                .to_owned()
        } else {
            format!(
                "audio activity continuity insufficient: {}",
                failures.join("; ")
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}
