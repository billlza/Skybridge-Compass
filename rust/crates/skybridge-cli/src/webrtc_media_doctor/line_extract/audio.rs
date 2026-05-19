use crate::performance_evidence::extract_text_value;
use crate::webrtc_media_parse::{find_webrtc_string, find_webrtc_u64};

pub(in crate::webrtc_media_doctor) fn is_webrtc_audio_rx_no_positive_placeholder(
    json: Option<&serde_json::Value>,
    text: &str,
) -> bool {
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    if !probable.contains("audio-rx-no-positive-evidence") {
        return false;
    }
    let source = find_webrtc_string(json, text, "source").unwrap_or_default();
    let is_heartbeat = source == "remote-heartbeat"
        || source == "smoke-heartbeat"
        || text.contains("source=remote-heartbeat")
        || text.contains("source=smoke-heartbeat");
    if !is_heartbeat {
        return false;
    }
    find_webrtc_u64(json, text, "audioRxRecv") == Some(0)
        && find_webrtc_u64(json, text, "audioRxDecoded") == Some(0)
        && find_webrtc_u64(json, text, "audioRxPlayed") == Some(0)
}

pub(in crate::webrtc_media_doctor) fn find_webrtc_audio_tx_missing_endpoint_reason(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let reason = find_webrtc_string(json, text, "reason").unwrap_or_default();
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    if text.contains("audioTxUnavailable")
        && (reason == "missingViewerEndpoint" || text.contains("missingViewerEndpoint"))
    {
        return Some("missingViewerEndpoint".to_owned());
    }
    if probable.contains("missingViewerEndpoint") || probable.contains("missing-viewer-endpoint") {
        return Some(probable);
    }
    None
}

pub(in crate::webrtc_media_doctor) fn find_webrtc_audio_tx_relay_failure_reason(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let reason = find_webrtc_string(json, text, "reason").unwrap_or_default();
    let detail = find_webrtc_string(json, text, "detail").unwrap_or_default();
    let error = find_webrtc_string(json, text, "error").unwrap_or_default();
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    let lower = text.to_lowercase();
    let has_tx_prefix = text.contains("audioTxUnavailable")
        || text.contains("audioTxRelay")
        || text.contains("audioTxEndpointReady");
    if !has_tx_prefix {
        return None;
    }
    if reason == "missingViewerEndpoint" {
        return None;
    }
    if reason == "relayUnavailable"
        && (detail.contains("timed out")
            || error.contains("timed out")
            || lower.contains("timed out"))
    {
        return Some("relayBindTimedOut".to_owned());
    }
    if reason == "leaseLimit" || lower.contains("media_admission_token_lease_limit") {
        return Some("leaseLimit".to_owned());
    }
    if reason == "relayBindTimedOut" || lower.contains("relaybindtimedout") {
        return Some("relayBindTimedOut".to_owned());
    }
    if reason == "relayBindRejected" || lower.contains("relaybindrejected") {
        return Some(if error.is_empty() {
            "relayBindRejected".to_owned()
        } else {
            format!("relayBindRejected:{error}")
        });
    }
    if reason == "relayBindMalformed" || lower.contains("relaybindmalformed") {
        return Some("relayBindMalformed".to_owned());
    }
    if matches!(
        probable.as_str(),
        "relay-bind-sent"
            | "relay-bind-ack-pending-media-optimistic"
            | "relay-lease-renewed-in-place"
    ) {
        return None;
    }
    if probable.contains("relay-bind")
        && (probable.contains("timed-out")
            || probable.contains("timeout")
            || probable.contains("rejected")
            || probable.contains("malformed")
            || probable.contains("failed"))
    {
        return Some(probable);
    }
    if probable.contains("relayUnavailable") {
        return Some(probable);
    }
    None
}

pub(in crate::webrtc_media_doctor) fn find_webrtc_audio_tx_relay_bind_pending_reason(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let kind = find_webrtc_string(json, text, "kind").unwrap_or_default();
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    if kind == "audioTxRelayBindAckPending"
        || text.contains("audioTxRelayBindAckPending")
        || probable == "relay-bind-ack-pending-media-optimistic"
    {
        return Some("relayBindAckPending".to_owned());
    }
    None
}

pub(in crate::webrtc_media_doctor) fn find_webrtc_audio_rx_relay_bind_failure(
    json: Option<&serde_json::Value>,
    text: &str,
) -> Option<String> {
    let kind = find_webrtc_string(json, text, "kind").unwrap_or_default();
    let stage = find_webrtc_string(json, text, "stage").unwrap_or_default();
    let probable = find_webrtc_string(json, text, "probable").unwrap_or_default();
    let reason = find_webrtc_string(json, text, "reason").unwrap_or_default();
    let kind_lower = kind.to_ascii_lowercase();
    let text_lower = text.to_ascii_lowercase();
    let receiver_context = kind_lower.starts_with("audiorx")
        || text_lower.contains("audio-rx")
        || text_lower.contains("audiorx")
        || text.contains("receiverStartFailed");
    let sender_context = kind_lower.starts_with("audiotx")
        || text_lower.contains("audio-tx")
        || text_lower.contains("audiotx");
    if sender_context && !receiver_context {
        return None;
    }
    if text.contains("relayBindAckTimedOut") || stage == "relayBindAckTimedOut" {
        return Some("relayBindAckTimedOut".to_owned());
    }
    if text.contains("relayBindRejected") || stage == "relayBindRejected" {
        return Some(if reason.is_empty() {
            "relayBindRejected".to_owned()
        } else {
            format!("relayBindRejected:{reason}")
        });
    }
    if text.contains("relayBindMalformed") || stage == "relayBindMalformed" {
        return Some("relayBindMalformed".to_owned());
    }
    if text.contains("receiverStartFailed")
        && (text.contains("stage=udpBind")
            || text.contains("stage=relayBindAck")
            || text.contains("stage=udpConnection"))
    {
        return Some(
            extract_text_value(text, "stage")
                .map(|stage| format!("receiverStartFailed:{stage}"))
                .unwrap_or_else(|| "receiverStartFailed:relayBind".to_owned()),
        );
    }
    if matches!(probable.as_str(), "relay-bind-ok" | "relay-bind-pending") {
        return None;
    }
    if receiver_context
        && (probable.contains("public-udp-relay-unreachable")
            || probable.contains("wrong-port")
            || probable.contains("relay-bind"))
    {
        return Some(probable);
    }
    None
}
