use time::OffsetDateTime;

use super::super::super::line_extract::{
    is_webrtc_native_video_tx_line, is_webrtc_sck_tx_telemetry_line,
};
use super::super::types::WebRtcMediaEvidence;

pub(in crate::webrtc_media_doctor) fn update_webrtc_gate_freshness_markers(
    evidence: &mut WebRtcMediaEvidence,
    line: &str,
    json: Option<&serde_json::Value>,
    observed_at: Option<OffsetDateTime>,
) {
    if observed_at.is_none() {
        return;
    }
    if is_webrtc_native_video_tx_line(line, json)
        || is_webrtc_sck_tx_telemetry_line(line, json)
        || line.contains("native-video-frame-source")
    {
        update_latest_time(&mut evidence.latest_video_evidence_at, observed_at);
    }
    if line.contains("native-receiver-frame")
        || line.contains("remote-video-stats")
        || line.contains("remote-video-frame-evidence")
        || line.contains("native-render-frame")
    {
        update_latest_time(&mut evidence.latest_receiver_evidence_at, observed_at);
    }
    if line.contains("audioTx") || line.contains("audio-tx") {
        update_latest_time(&mut evidence.latest_audio_tx_evidence_at, observed_at);
    }
    if line.contains("audioRx") || line.contains("audio-rx") || line.contains("renderedFrames") {
        update_latest_time(&mut evidence.latest_audio_rx_evidence_at, observed_at);
    }
}

fn update_latest_time(slot: &mut Option<OffsetDateTime>, observed_at: Option<OffsetDateTime>) {
    if let Some(observed_at) = observed_at
        && slot.is_none_or(|current| observed_at > current)
    {
        *slot = Some(observed_at);
    }
}

pub(in crate::webrtc_media_doctor) fn is_webrtc_diagnostic_recent(
    timestamp: OffsetDateTime,
    since_seconds: u64,
    now: OffsetDateTime,
) -> bool {
    if timestamp > now {
        return true;
    }
    let since_seconds = i64::try_from(since_seconds).unwrap_or(i64::MAX);
    now - timestamp <= time::Duration::seconds(since_seconds)
}
