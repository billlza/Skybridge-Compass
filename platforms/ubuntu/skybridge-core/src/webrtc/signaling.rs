use serde::{Deserialize, Serialize};

/// WebRTC signaling message type (offer/answer/ice/join/leave).
///
/// Mirrors the macOS/iOS `WebRTCSignalingEnvelope.MessageType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WebRtcSignalingType {
    Join,
    Offer,
    Answer,
    #[serde(rename = "iceCandidate")]
    IceCandidate,
    Leave,
}

/// Signaling message payload (SDP / ICE candidate).
///
/// Mirrors the macOS/iOS `WebRTCSignalingEnvelope.Payload`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebRtcSignalingPayload {
    pub sdp: Option<String>,
    pub candidate: Option<String>,
    pub sdp_mid: Option<String>,
    pub sdp_m_line_index: Option<i32>,
}

impl WebRtcSignalingPayload {
    pub fn sdp(sdp: String) -> Self {
        Self {
            sdp: Some(sdp),
            candidate: None,
            sdp_mid: None,
            sdp_m_line_index: None,
        }
    }

    pub fn ice_candidate(
        candidate: String,
        sdp_mid: Option<String>,
        sdp_m_line_index: Option<i32>,
    ) -> Self {
        Self {
            sdp: None,
            candidate: Some(candidate),
            sdp_mid,
            sdp_m_line_index,
        }
    }
}

/// A signaling envelope sent over WebSocket (or any signaling transport).
///
/// Mirrors the macOS/iOS `WebRTCSignalingEnvelope`:
/// - `sessionId` room
/// - `from` sender device id/fingerprint
/// - optional `to` for directed routing
/// - `type` message type
/// - `payload` optional SDP/candidate fields
/// - `sentAt` epoch seconds
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebRtcSignalingEnvelope {
    pub session_id: String,
    pub from: String,
    pub to: Option<String>,
    #[serde(rename = "type")]
    pub msg_type: WebRtcSignalingType,
    pub payload: Option<WebRtcSignalingPayload>,
    pub auth_token: Option<String>,
    pub sent_at: f64,
}

impl WebRtcSignalingEnvelope {
    pub fn new(session_id: String, from: String, msg_type: WebRtcSignalingType) -> Self {
        Self {
            session_id,
            from,
            to: None,
            msg_type,
            payload: None,
            auth_token: None,
            sent_at: now_epoch_seconds(),
        }
    }

    pub fn with_to(mut self, to: String) -> Self {
        self.to = Some(to);
        self
    }

    pub fn with_payload(mut self, payload: WebRtcSignalingPayload) -> Self {
        self.payload = Some(payload);
        self
    }

    pub fn with_auth_token(mut self, auth_token: impl Into<String>) -> Self {
        let auth_token = auth_token.into();
        if !auth_token.trim().is_empty() {
            self.auth_token = Some(auth_token);
        }
        self
    }
}

pub fn now_epoch_seconds() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    now.as_secs_f64()
}
