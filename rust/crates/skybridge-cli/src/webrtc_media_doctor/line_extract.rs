use crate::performance_evidence::extract_text_value;
use crate::webrtc_media_parse::{find_json_value, find_webrtc_string, json_value_to_string};

mod audio;
mod fallback;
mod video;

pub(super) use self::audio::{
    find_webrtc_audio_rx_relay_bind_failure, find_webrtc_audio_tx_missing_endpoint_reason,
    find_webrtc_audio_tx_relay_bind_pending_reason, find_webrtc_audio_tx_relay_failure_reason,
    is_webrtc_audio_rx_no_positive_placeholder,
};
pub(super) use self::fallback::{
    find_webrtc_fallback_producer_failure_reason, is_backpressure_line, is_stale_fallback_line,
};
pub(super) use self::video::{
    find_webrtc_native_video_receiver_frame, find_webrtc_native_video_render_dimensions,
    find_webrtc_native_video_render_frame, find_webrtc_native_video_state,
    is_native_video_failure_state, is_webrtc_native_video_receiver_line,
    is_webrtc_native_video_render_line, is_webrtc_native_video_tx_line,
    is_webrtc_sck_tx_telemetry_line, is_webrtc_stream_stats_line,
    is_webrtc_visible_native_render_fps_line,
};

pub(super) fn webrtc_line_matches_session(
    text: &str,
    json: Option<&serde_json::Value>,
    session_id: &str,
) -> bool {
    if let Some(json) = json {
        for key in ["session", "sessionId", "session_id"] {
            if find_json_value(json, key)
                .and_then(json_value_to_string)
                .is_some_and(|value| value == session_id)
            {
                return true;
            }
        }
    }
    extract_text_value(text, "session").is_some_and(|value| value == session_id)
}

pub(super) fn find_webrtc_strict_media_failure_reason(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let event = json
        .and_then(|json| {
            find_json_value(json, "event")
                .or_else(|| find_json_value(json, "name"))
                .or_else(|| find_json_value(json, "kind"))
                .and_then(json_value_to_string)
        })
        .unwrap_or_default();
    let matched = text.contains("strict-media-failed")
        || matches!(
            event.as_str(),
            "strict-media-failed"
                | "strictMediaFailed"
                | "strict-media-failure"
                | "strictMediaFailure"
        );
    if !matched {
        return None;
    }
    Some(
        find_webrtc_string(json, text, "reason")
            .or_else(|| find_webrtc_string(json, text, "failureReason"))
            .or_else(|| find_webrtc_string(json, text, "failure_reason"))
            .or_else(|| find_webrtc_string(json, text, "probable"))
            .unwrap_or_else(|| "strict-media-failed".to_owned()),
    )
}
