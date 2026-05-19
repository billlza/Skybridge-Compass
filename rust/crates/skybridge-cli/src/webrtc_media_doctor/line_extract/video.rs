use crate::performance_evidence::extract_text_value;
use crate::webrtc_media_dimensions::{
    ReceiverVideoDimensions, find_webrtc_video_dimensions, parse_webrtc_video_dimensions,
};
use crate::webrtc_media_parse::{
    find_json_value, find_webrtc_string, find_webrtc_u64, json_value_to_string,
};

pub(in crate::webrtc_media_doctor) fn is_webrtc_stream_stats_line(
    text: &str,
    json: Option<&serde_json::Value>,
) -> bool {
    text.contains("stream-stats")
        || text.contains("WebRTC 屏幕推流吞吐")
        || json
            .and_then(|json| {
                find_json_value(json, "event")
                    .or_else(|| find_json_value(json, "name"))
                    .or_else(|| find_json_value(json, "kind"))
                    .and_then(json_value_to_string)
            })
            .is_some_and(|event| {
                event == "stream-stats" || event == "webrtc.stream_stats" || event == "videoStats"
            })
}

pub(in crate::webrtc_media_doctor) fn is_webrtc_native_video_tx_line(
    text: &str,
    json: Option<&serde_json::Value>,
) -> bool {
    text.contains("native-video-tx")
        || json
            .and_then(|json| {
                find_json_value(json, "event")
                    .or_else(|| find_json_value(json, "name"))
                    .or_else(|| find_json_value(json, "kind"))
                    .and_then(json_value_to_string)
            })
            .is_some_and(|event| event == "native-video-tx" || event == "nativeVideoTx")
}

pub(in crate::webrtc_media_doctor) fn is_webrtc_sck_tx_telemetry_line(
    text: &str,
    json: Option<&serde_json::Value>,
) -> bool {
    text.contains("sckTxTelemetry")
        || json
            .and_then(|json| {
                find_json_value(json, "event")
                    .or_else(|| find_json_value(json, "name"))
                    .or_else(|| find_json_value(json, "kind"))
                    .and_then(json_value_to_string)
            })
            .is_some_and(|event| event == "sckTxTelemetry")
}

pub(in crate::webrtc_media_doctor) fn is_webrtc_native_video_receiver_line(
    text: &str,
    json: Option<&serde_json::Value>,
) -> bool {
    text.contains("native-receiver-frame")
        || text.contains("remote-video-frame-evidence")
        || json
            .and_then(|json| {
                find_json_value(json, "event")
                    .or_else(|| find_json_value(json, "name"))
                    .or_else(|| find_json_value(json, "kind"))
                    .and_then(json_value_to_string)
            })
            .is_some_and(|event| {
                matches!(
                    event.as_str(),
                    "native-receiver-frame"
                        | "nativeReceiverFrame"
                        | "remote-video-frame-evidence"
                        | "remoteVideoFrameEvidence"
                )
            })
}

pub(in crate::webrtc_media_doctor) fn is_webrtc_native_video_render_line(
    text: &str,
    json: Option<&serde_json::Value>,
) -> bool {
    text.contains("native-render-frame")
        || text.contains("nativeRenderEvidenceSource=rtc-mtl-video-view")
        || json
            .and_then(|json| {
                find_json_value(json, "event")
                    .or_else(|| find_json_value(json, "name"))
                    .or_else(|| find_json_value(json, "kind"))
                    .and_then(json_value_to_string)
            })
            .is_some_and(|event| {
                matches!(
                    event.as_str(),
                    "native-render-frame" | "nativeRenderFrame" | "visibleNativeRender"
                )
            })
}

pub(in crate::webrtc_media_doctor) fn is_webrtc_visible_native_render_fps_line(
    text: &str,
    json: Option<&serde_json::Value>,
) -> bool {
    let candidate = text.contains("viewerDisplayFPS=")
        || text.contains("displayFPS=")
        || text.contains("visibleNativeRenderFPS")
        || json
            .and_then(|json| {
                find_json_value(json, "event")
                    .or_else(|| find_json_value(json, "name"))
                    .or_else(|| find_json_value(json, "kind"))
                    .and_then(json_value_to_string)
            })
            .is_some_and(|event| {
                matches!(
                    event.as_str(),
                    "visibleNativeRenderFPS" | "viewerDisplayStats" | "visibleRenderFPS"
                )
            });
    if !candidate {
        return false;
    }
    let source = find_webrtc_string(json, text, "source").unwrap_or_default();
    let ui_surface = find_webrtc_string(json, text, "uiSurface")
        .or_else(|| find_webrtc_string(json, text, "surface"))
        .unwrap_or_default();
    let metric_source = find_webrtc_string(json, text, "metricSource").unwrap_or_default();
    let render_pipeline = find_webrtc_string(json, text, "renderPipeline").unwrap_or_default();
    source == "rtc-mtl-video-view"
        && ui_surface == "remoteDesktopView"
        && metric_source == "rtc-mtl-render-frame"
        && (render_pipeline.is_empty() || render_pipeline == "webrtcNativeVideo")
}

pub(in crate::webrtc_media_doctor) fn find_webrtc_native_video_render_frame(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    if !is_webrtc_native_video_render_line(text, json) {
        return None;
    }
    let source = find_webrtc_string(json, text, "nativeRenderEvidenceSource")
        .or_else(|| find_webrtc_string(json, text, "source"))
        .unwrap_or_else(|| "-".to_owned());
    if source != "rtc-mtl-video-view" {
        return None;
    }
    let size = find_webrtc_string(json, text, "size").unwrap_or_else(|| "-".to_owned());
    let visible_size = find_webrtc_string(json, text, "visibleSize")
        .or_else(|| find_webrtc_string(json, text, "visibleFrame"))
        .unwrap_or_else(|| size.clone());
    let coded_size = find_webrtc_string(json, text, "codedSize")
        .or_else(|| find_webrtc_string(json, text, "codedFrame"))
        .unwrap_or_else(|| size.clone());
    let native_promotion_state =
        find_webrtc_string(json, text, "nativePromotionState").unwrap_or_else(|| "-".to_owned());
    let ui_surface = find_webrtc_string(json, text, "uiSurface")
        .or_else(|| find_webrtc_string(json, text, "surface"))
        .unwrap_or_else(|| "-".to_owned());
    if native_promotion_state == "smoke-hold" || ui_surface != "remoteDesktopView" {
        return None;
    }
    Some(format!(
        "source={source} uiSurface={ui_surface} size={size} visibleSize={visible_size} codedSize={coded_size} nativePromotionState={native_promotion_state}"
    ))
}

pub(in crate::webrtc_media_doctor) fn find_webrtc_native_video_render_dimensions(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<ReceiverVideoDimensions> {
    if !is_webrtc_native_video_render_line(text, json) {
        return None;
    }
    if let Some(value) = find_webrtc_string(json, text, "visibleSize")
        .or_else(|| find_webrtc_string(json, text, "visibleFrame"))
        && let Some(dimensions) = parse_webrtc_video_dimensions(&value)
    {
        return Some(ReceiverVideoDimensions {
            dimensions,
            explicit_visible: true,
        });
    }
    find_webrtc_video_dimensions(json, text).map(|dimensions| ReceiverVideoDimensions {
        dimensions,
        explicit_visible: false,
    })
}

pub(in crate::webrtc_media_doctor) fn find_webrtc_native_video_receiver_frame(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    if !is_webrtc_native_video_receiver_line(text, json) {
        return None;
    }

    let frames_decoded = find_webrtc_u64(json, text, "framesDecoded").unwrap_or(0);
    let frames_received = find_webrtc_u64(json, text, "framesReceived").unwrap_or(0);
    let packets = find_webrtc_u64(json, text, "packets")
        .or_else(|| find_webrtc_u64(json, text, "packetsReceived"))
        .unwrap_or(0);
    let bytes = find_webrtc_u64(json, text, "bytes")
        .or_else(|| find_webrtc_u64(json, text, "bytesReceived"))
        .unwrap_or(0);
    let size = find_webrtc_string(json, text, "size").unwrap_or_else(|| "-".to_owned());
    let visible_size = find_webrtc_string(json, text, "visibleSize")
        .or_else(|| find_webrtc_string(json, text, "visibleFrame"))
        .unwrap_or_else(|| size.clone());
    let coded_size = find_webrtc_string(json, text, "codedSize")
        .or_else(|| find_webrtc_string(json, text, "codedFrame"))
        .unwrap_or_else(|| size.clone());
    let source = find_webrtc_string(json, text, "source").unwrap_or_else(|| "-".to_owned());
    if frames_decoded > 0 || frames_received > 0 || (packets > 0 && bytes > 0) {
        return Some(format!(
            "source={source} size={size} visibleSize={visible_size} codedSize={coded_size} packets={packets} bytes={bytes} framesReceived={frames_received} framesDecoded={frames_decoded}"
        ));
    }
    None
}

pub(in crate::webrtc_media_doctor) fn find_webrtc_native_video_state(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    if let Some(json) = json
        && let Some(state) = find_json_value(json, "nativeVideoHealth")
            .and_then(json_value_to_string)
            .or_else(|| find_json_value(json, "native_video_health").and_then(json_value_to_string))
    {
        return Some(state);
    }
    let native_video_line = text.contains("native-video-health")
        || text.contains("native-video-tx")
        || text.contains("nativeVideoHealth");
    if !native_video_line {
        return None;
    }
    extract_text_value(text, "nativeVideoHealth").or_else(|| extract_text_value(text, "state"))
}

pub(in crate::webrtc_media_doctor) fn is_native_video_failure_state(state: &str) -> bool {
    matches!(state, "failedNoRTP" | "senderZero")
}
