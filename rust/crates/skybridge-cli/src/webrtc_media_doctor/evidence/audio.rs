use super::super::line_extract::{
    find_webrtc_audio_rx_relay_bind_failure, find_webrtc_audio_tx_missing_endpoint_reason,
    find_webrtc_audio_tx_relay_bind_pending_reason, find_webrtc_audio_tx_relay_failure_reason,
    is_webrtc_audio_rx_no_positive_placeholder,
};
use super::observation::{
    observe_webrtc_audio_playout_pressure, observe_webrtc_counter, update_latest_metric,
};
use super::types::{ObservedMetric, WebRtcMediaEvidence};

pub(in crate::webrtc_media_doctor) fn observe_webrtc_audio_evidence(
    evidence: &mut WebRtcMediaEvidence,
    json: Option<&serde_json::Value>,
    trimmed: &str,
    sequence: usize,
    summary: &str,
) {
    observe_webrtc_counter(
        &mut evidence.audio_tx_captured,
        json,
        trimmed,
        "audioTxCaptured",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_tx_encoded,
        json,
        trimmed,
        "audioTxEncoded",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_tx_sent,
        json,
        trimmed,
        "audioTxSent",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_tx_captured_total,
        json,
        trimmed,
        "audioTxCapturedTotal",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_tx_encoded_total,
        json,
        trimmed,
        "audioTxEncodedTotal",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_tx_sent_total,
        json,
        trimmed,
        "audioTxSentTotal",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_drops,
        json,
        trimmed,
        "audioDrops",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_drops_total,
        json,
        trimmed,
        "audioDropsTotal",
        sequence,
        summary,
    );

    if !is_webrtc_audio_rx_no_positive_placeholder(json, trimmed) {
        observe_webrtc_counter(
            &mut evidence.audio_rx_recv,
            json,
            trimmed,
            "audioRxRecv",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.audio_rx_decoded,
            json,
            trimmed,
            "audioRxDecoded",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.audio_rx_played,
            json,
            trimmed,
            "audioRxPlayed",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.audio_rx_recv_total,
            json,
            trimmed,
            "recvTotal",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.audio_rx_decoded_total,
            json,
            trimmed,
            "decodeTotal",
            sequence,
            summary,
        );
        observe_webrtc_counter(
            &mut evidence.audio_rx_played_total,
            json,
            trimmed,
            "playTotal",
            sequence,
            summary,
        );
    }

    observe_webrtc_counter(
        &mut evidence.audio_rendered_frames,
        json,
        trimmed,
        "renderedFrames",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_underflow,
        json,
        trimmed,
        "underflow",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_bridged_underflow,
        json,
        trimmed,
        "bridgedUnderflow",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_rebuffer,
        json,
        trimmed,
        "rebuffer",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_playback_drop,
        json,
        trimmed,
        "playbackDrop",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_jitter_evicted,
        json,
        trimmed,
        "jitterEvicted",
        sequence,
        summary,
    );
    observe_webrtc_counter(
        &mut evidence.audio_jitter_late,
        json,
        trimmed,
        "jitterLate",
        sequence,
        summary,
    );
    observe_webrtc_audio_playout_pressure(evidence, json, trimmed, sequence, summary);

    if let Some(reason) = find_webrtc_audio_tx_missing_endpoint_reason(json, trimmed) {
        update_latest_metric(
            &mut evidence.audio_tx_missing_viewer_endpoint,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }

    if let Some(reason) = find_webrtc_audio_tx_relay_failure_reason(json, trimmed) {
        update_latest_metric(
            &mut evidence.audio_tx_relay_failure,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }

    if let Some(reason) = find_webrtc_audio_tx_relay_bind_pending_reason(json, trimmed) {
        update_latest_metric(
            &mut evidence.audio_tx_relay_bind_pending,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }

    if let Some(reason) = find_webrtc_audio_rx_relay_bind_failure(json, trimmed) {
        update_latest_metric(
            &mut evidence.audio_rx_relay_bind_failure,
            ObservedMetric {
                value: reason,
                sequence,
                evidence: summary.to_owned(),
            },
        );
    }
}
