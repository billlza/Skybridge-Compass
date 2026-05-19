use super::super::super::line_extract::is_webrtc_sck_tx_telemetry_line;
use super::super::observation::{
    observe_webrtc_counter, observe_webrtc_latest_f64_any, observe_webrtc_latest_string_any,
};
use super::super::types::WebRtcMediaEvidence;

pub(super) fn observe_webrtc_sck_video_evidence(
    evidence: &mut WebRtcMediaEvidence,
    json: Option<&serde_json::Value>,
    trimmed: &str,
    sequence: usize,
    summary: &str,
) {
    if is_webrtc_sck_tx_telemetry_line(trimmed, json) {
        observe_webrtc_counter(
            &mut evidence.sck_captured,
            json,
            trimmed,
            "sckCaptured",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_captured,
            json,
            trimmed,
            "captured",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_meaningful,
            json,
            trimmed,
            "sckMeaningful",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_meaningful,
            json,
            trimmed,
            "meaningful",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encoded,
            json,
            trimmed,
            "sckEncoded",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encoded,
            json,
            trimmed,
            "encoded",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encoded_bytes,
            json,
            trimmed,
            "sckEncodedBytes",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encoded_bytes,
            json,
            trimmed,
            "encodedBytes",
            sequence,
            summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_capture_fps,
            json,
            trimmed,
            &["sckCaptureFPS", "captureFPS"],
            sequence,
            summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_meaningful_fps,
            json,
            trimmed,
            &["sckMeaningfulFPS", "meaningfulFPS"],
            sequence,
            summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_encoded_fps,
            json,
            trimmed,
            &["sckEncodedFPS", "encodedFPS"],
            sequence,
            summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_encode_latency_p50_ms,
            json,
            trimmed,
            &["sckEncodeLatencyP50Ms", "encodeLatencyP50Ms"],
            sequence,
            summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_encode_latency_p95_ms,
            json,
            trimmed,
            &["sckEncodeLatencyP95Ms", "encodeLatencyP95Ms"],
            sequence,
            summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.sck_encode_latency_max_ms,
            json,
            trimmed,
            &["sckEncodeLatencyMaxMs", "encodeLatencyMaxMs"],
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encode_failures,
            json,
            trimmed,
            "sckEncodeFailures",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.sck_encode_failures,
            json,
            trimmed,
            "encodeFailures",
            sequence,
            summary,
        );
        observe_webrtc_latest_string_any(
            &mut evidence.sck_codec,
            json,
            trimmed,
            &["codec"],
            sequence,
            summary,
        );
    }
}
