use super::types::WebRtcMediaEvidence;

mod native;
mod sck;

pub(in crate::webrtc_media_doctor) fn observe_webrtc_video_evidence(
    evidence: &mut WebRtcMediaEvidence,
    json: Option<&serde_json::Value>,
    trimmed: &str,
    sequence: usize,
    summary: &str,
) {
    native::observe_webrtc_native_video_evidence(evidence, json, trimmed, sequence, summary);
    sck::observe_webrtc_sck_video_evidence(evidence, json, trimmed, sequence, summary);
}
