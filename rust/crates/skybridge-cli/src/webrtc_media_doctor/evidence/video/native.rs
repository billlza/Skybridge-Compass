use super::super::super::line_extract::{
    find_webrtc_native_video_state, is_native_video_failure_state, is_webrtc_native_video_tx_line,
    is_webrtc_stream_stats_line,
};
use super::super::observation::{
    observe_webrtc_counter, observe_webrtc_latest_f64_any, observe_webrtc_latest_string_any,
    update_latest_metric, update_lowest_f64,
};
use super::super::types::{ObservedMetric, WebRtcMediaEvidence};
use crate::webrtc_media_parse::{find_webrtc_f64_any, find_webrtc_u64};

pub(super) fn observe_webrtc_native_video_evidence(
    evidence: &mut WebRtcMediaEvidence,
    json: Option<&serde_json::Value>,
    trimmed: &str,
    sequence: usize,
    summary: &str,
) {
    if let Some(state) = find_webrtc_native_video_state(json, trimmed) {
        let observed = ObservedMetric {
            value: state.clone(),
            sequence,
            evidence: summary.to_owned(),
        };
        update_latest_metric(&mut evidence.native_video_state, observed.clone());
        if is_native_video_failure_state(&state) {
            update_latest_metric(&mut evidence.native_video_failure, observed);
        }
    }

    if is_webrtc_native_video_tx_line(trimmed, json)
        || (is_webrtc_stream_stats_line(trimmed, json)
            && (find_webrtc_u64(json, trimmed, "framesSent").is_some()
                || find_webrtc_u64(json, trimmed, "packetsSent").is_some()))
    {
        observe_webrtc_counter(
            &mut evidence.native_video_submitted,
            json,
            trimmed,
            "submitted",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_frames_encoded,
            json,
            trimmed,
            "framesEncoded",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_frames_sent,
            json,
            trimmed,
            "framesSent",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_key_frames_encoded,
            json,
            trimmed,
            "keyFramesEncoded",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_packets_sent,
            json,
            trimmed,
            "packetsSent",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_bytes_sent,
            json,
            trimmed,
            "bytesSent",
            sequence,
            summary,
        );
        observe_webrtc_latest_string_any(
            &mut evidence.native_video_codec,
            json,
            trimmed,
            &["codec", "mimeType"],
            sequence,
            summary,
        );
        observe_webrtc_latest_string_any(
            &mut evidence.native_video_encoder,
            json,
            trimmed,
            &["encoder", "encoderImplementation"],
            sequence,
            summary,
        );
        observe_webrtc_latest_string_any(
            &mut evidence.native_video_quality_limit,
            json,
            trimmed,
            &["qualityLimit", "qualityLimitationReason"],
            sequence,
            summary,
        );
        if let Some(fps) = find_webrtc_f64_any(json, trimmed, &["encodeFPS", "framesPerSecond"]) {
            let observed = ObservedMetric {
                value: fps,
                sequence,
                evidence: summary.to_owned(),
            };
            update_latest_metric(&mut evidence.native_video_encode_fps, observed.clone());
            update_lowest_f64(&mut evidence.native_video_lowest_encode_fps, observed);
        }
        observe_webrtc_counter(
            &mut evidence.native_video_target_bitrate,
            json,
            trimmed,
            "targetBitrate",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.native_video_available_outgoing_bitrate,
            json,
            trimmed,
            "availableOutgoingBitrate",
            sequence,
            summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.native_video_current_rtt,
            json,
            trimmed,
            &["currentRTT", "currentRoundTripTime"],
            sequence,
            summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.native_video_remote_rtt,
            json,
            trimmed,
            &["remoteRTT", "remoteRoundTripTime"],
            sequence,
            summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.native_video_remote_packets_lost,
            json,
            trimmed,
            &["remotePacketsLost"],
            sequence,
            summary,
        );
        observe_webrtc_latest_f64_any(
            &mut evidence.native_video_remote_jitter,
            json,
            trimmed,
            &["remoteJitter"],
            sequence,
            summary,
        );
    }
}
