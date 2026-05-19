use crate::webrtc_media_parse::{find_webrtc_f64_any, find_webrtc_string, find_webrtc_u64};

pub(in crate::webrtc_media_doctor) fn find_webrtc_fallback_producer_failure_reason(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let fallback_producer = find_webrtc_string(json, text, "fallbackProducer")
        .or_else(|| find_webrtc_string(json, text, "producer"))
        .unwrap_or_default();
    let reason = find_webrtc_string(json, text, "reason").unwrap_or_default();
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    let lower = text.to_lowercase();
    if fallback_producer == "cgdisplayEmergency"
        && (reason.contains("stale") || lower.contains("sck latest fallback stale"))
    {
        return Some("cgdisplayEmergency".to_owned());
    }
    if lower.contains("video_fps")
        && find_webrtc_f64_any(json, text, &["video_fps", "fps", "videoFPS"])
            .is_some_and(|fps| fps <= 2.0)
    {
        return Some("lowFPS".to_owned());
    }
    if probable.contains("capture") || probable.contains("encoder-no-output") {
        return Some(probable);
    }
    None
}

pub(in crate::webrtc_media_doctor) fn is_stale_fallback_line(
    json: Option<&serde_json::Value>,
    text: &str,
) -> bool {
    let reason = find_webrtc_string(json, text, "reason").unwrap_or_default();
    let producer = find_webrtc_string(json, text, "producer")
        .or_else(|| find_webrtc_string(json, text, "fallbackProducer"))
        .unwrap_or_default();
    let screen_transport = find_webrtc_string(json, text, "screenFrameTransport")
        .or_else(|| find_webrtc_string(json, text, "transport"))
        .unwrap_or_default();
    let media_fallback_policy = find_webrtc_string(json, text, "mediaFallbackPolicy")
        .or_else(|| find_webrtc_string(json, text, "fallbackPolicy"))
        .unwrap_or_default();
    let format = find_webrtc_string(json, text, "format").unwrap_or_default();
    let fallback_line =
        text.contains("fallback") || text.contains("Fallback") || text.contains("producer");
    let lower = text.to_ascii_lowercase();
    let producer_is_forbidden = matches!(
        producer.as_str(),
        "cgdisplaySync"
            | "cgdisplayEmergency"
            | "sckLatest"
            | "directEncoder"
            | "degradedJPEGWarmupMain"
            | "boundedJPEGWarmupMain"
    );
    let format_is_forbidden_screen_data = (lower.contains("stream-format")
        || lower.contains("screen-send"))
        && matches!(format.as_str(), "jpeg" | "jpg" | "h264" | "hevc" | "bgra");
    text.contains("stream-native-warmup-fallback-main")
        || text.contains("fallback-screen-frame-received")
        || text.contains("screen-channel-control-fallback-forbidden")
        || text.contains("degraded-screen-fallback-forbidden")
        || text.contains("native-warmup-bounded-jpeg")
        || screen_transport.contains("fallback")
        || media_fallback_policy == "explicit-degraded"
        || producer_is_forbidden
        || format_is_forbidden_screen_data
        || text.contains("SCK latest fallback stale")
        || (fallback_line && reason.contains("stale"))
        || (producer == "cgdisplayEmergency"
            && (reason.contains("stale") || text.contains("sckLatestAgeMs=-")))
}

pub(in crate::webrtc_media_doctor) fn is_backpressure_line(
    json: Option<&serde_json::Value>,
    text: &str,
) -> bool {
    let drop_reason = find_webrtc_string(json, text, "dropReason").unwrap_or_default();
    let chunk_drop_reason = find_webrtc_string(json, text, "chunkDropReason").unwrap_or_default();
    text.contains("stream-backpressure")
        || drop_reason == "backpressure"
        || chunk_drop_reason.contains("backpressure")
        || find_webrtc_u64(json, text, "droppedBackpressure").is_some_and(|value| value > 0)
}
