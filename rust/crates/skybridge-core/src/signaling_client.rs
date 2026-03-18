use std::sync::Arc;

use anyhow::{Result, anyhow, bail};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, mpsc};
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
use uuid::Uuid;

use crate::{
    SignalingBackend, SignalingFailureClass, SignalingHandleId, SignalingLifecycleEvent,
    SignalingLifecyclePhase, SignalingState,
};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WebRtcSignalingEnvelope {
    pub session_id: String,
    pub from: String,
    pub to: Option<String>,
    pub kind: WebRtcMessageType,
    pub payload: Option<WebRtcSignalingPayload>,
    pub auth_token: Option<String>,
    pub sent_at: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WebRtcMessageType {
    Join,
    Offer,
    Answer,
    IceCandidate,
    Leave,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WebRtcSignalingPayload {
    pub sdp: Option<String>,
    pub candidate: Option<String>,
    pub sdp_mid: Option<String>,
    pub sdp_m_line_index: Option<i32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignalingServerFrame {
    #[serde(rename = "type")]
    pub kind: String,
    pub error: Option<String>,
    pub session_id: Option<String>,
    pub what: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum InboundMessage {
    Envelope(WebRtcSignalingEnvelope),
    ServerFrame(SignalingServerFrame),
    Unknown,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SignalingRuntimeEvent {
    Lifecycle(SignalingLifecycleEvent),
    Inbound(InboundMessage),
}

#[derive(Debug)]
pub struct SignalingConnection {
    outgoing: mpsc::Sender<WebRtcSignalingEnvelope>,
    incoming: mpsc::Receiver<InboundMessage>,
    lifecycle: mpsc::Receiver<SignalingLifecycleEvent>,
    runtime_events: mpsc::Receiver<SignalingRuntimeEvent>,
    state: Arc<Mutex<SignalingState>>,
}

impl SignalingConnection {
    pub async fn connect(url: url::Url, session_id: &str) -> Result<Self> {
        let (ws_stream, _) = connect_async(url.as_str()).await?;
        let (mut sink, mut stream) = ws_stream.split();

        let generation = 1_u32;
        let handle_id = SignalingHandleId {
            session_id: session_id.to_owned(),
            backend: SignalingBackend::Native,
            generation,
        };
        let state = Arc::new(Mutex::new(SignalingState::default()));
        {
            let mut state_guard = state.lock().await;
            state_guard.seed(
                session_id.to_owned(),
                generation,
                handle_id.clone(),
                crate::SignalingSessionHealth::Healthy,
                SignalingLifecyclePhase::Connecting,
            );
        }

        let (out_tx, mut out_rx) = mpsc::channel::<WebRtcSignalingEnvelope>(32);
        let (in_tx, in_rx) = mpsc::channel::<InboundMessage>(64);
        let (life_tx, life_rx) = mpsc::channel::<SignalingLifecycleEvent>(64);
        let (event_tx, event_rx) = mpsc::channel::<SignalingRuntimeEvent>(128);

        emit_lifecycle(
            &life_tx,
            &event_tx,
            &state,
            SignalingLifecycleEvent::new(handle_id.clone(), SignalingLifecyclePhase::Connecting),
        )
        .await?;
        emit_lifecycle(
            &life_tx,
            &event_tx,
            &state,
            SignalingLifecycleEvent::new(handle_id.clone(), SignalingLifecyclePhase::SocketOpen),
        )
        .await?;

        tokio::spawn({
            let state = Arc::clone(&state);
            let life_tx = life_tx.clone();
            let event_tx = event_tx.clone();
            let handle_id = handle_id.clone();
            async move {
                while let Some(envelope) = out_rx.recv().await {
                    let body = match serde_json::to_string(&SerializableEnvelope::from(envelope)) {
                        Ok(value) => value,
                        Err(_) => continue,
                    };
                    if sink.send(Message::Text(body.into())).await.is_err() {
                        let _ = emit_lifecycle(
                            &life_tx,
                            &event_tx,
                            &state,
                            SignalingLifecycleEvent {
                                handle_id: handle_id.clone(),
                                phase: SignalingLifecyclePhase::Failed,
                                server_frame_type: None,
                                failure_class: Some(SignalingFailureClass::TransientNetwork),
                                error_description: Some("send_failed".to_owned()),
                                occurred_at: time::OffsetDateTime::now_utc(),
                            },
                        )
                        .await;
                        break;
                    }
                }
            }
        });

        tokio::spawn({
            let state = Arc::clone(&state);
            let life_tx = life_tx.clone();
            let event_tx = event_tx.clone();
            let handle_id = handle_id.clone();
            async move {
                while let Some(message_result) = stream.next().await {
                    match message_result {
                        Ok(Message::Text(text)) => {
                            let inbound = parse_inbound_message(&text);
                            if let InboundMessage::ServerFrame(frame) = &inbound {
                                if frame.kind == "bound" {
                                    let _ = emit_lifecycle(
                                        &life_tx,
                                        &event_tx,
                                        &state,
                                        SignalingLifecycleEvent {
                                            handle_id: handle_id.clone(),
                                            phase: SignalingLifecyclePhase::Bound,
                                            server_frame_type: Some(frame.kind.clone()),
                                            failure_class: None,
                                            error_description: None,
                                            occurred_at: time::OffsetDateTime::now_utc(),
                                        },
                                    )
                                    .await;
                                } else if let Some(error) = frame.error.clone() {
                                    let _ = emit_lifecycle(
                                        &life_tx,
                                        &event_tx,
                                        &state,
                                        SignalingLifecycleEvent {
                                            handle_id: handle_id.clone(),
                                            phase: SignalingLifecyclePhase::Failed,
                                            server_frame_type: Some(frame.kind.clone()),
                                            failure_class: Some(classify_server_error(&error)),
                                            error_description: Some(error),
                                            occurred_at: time::OffsetDateTime::now_utc(),
                                        },
                                    )
                                    .await;
                                }
                            }
                            if event_tx
                                .send(SignalingRuntimeEvent::Inbound(inbound.clone()))
                                .await
                                .is_err()
                            {
                                break;
                            }
                            if in_tx.send(inbound).await.is_err() {
                                break;
                            }
                        }
                        Ok(Message::Close(_)) => {
                            let _ = emit_lifecycle(
                                &life_tx,
                                &event_tx,
                                &state,
                                SignalingLifecycleEvent {
                                    handle_id: handle_id.clone(),
                                    phase: SignalingLifecyclePhase::Closed,
                                    server_frame_type: None,
                                    failure_class: Some(SignalingFailureClass::TransientNetwork),
                                    error_description: Some("websocket_closed".to_owned()),
                                    occurred_at: time::OffsetDateTime::now_utc(),
                                },
                            )
                            .await;
                            break;
                        }
                        Ok(_) => {}
                        Err(error) => {
                            let _ = emit_lifecycle(
                                &life_tx,
                                &event_tx,
                                &state,
                                SignalingLifecycleEvent {
                                    handle_id: handle_id.clone(),
                                    phase: SignalingLifecyclePhase::Failed,
                                    server_frame_type: None,
                                    failure_class: Some(SignalingFailureClass::TransientNetwork),
                                    error_description: Some(error.to_string()),
                                    occurred_at: time::OffsetDateTime::now_utc(),
                                },
                            )
                            .await;
                            break;
                        }
                    }
                }
            }
        });

        Ok(Self {
            outgoing: out_tx,
            incoming: in_rx,
            lifecycle: life_rx,
            runtime_events: event_rx,
            state,
        })
    }

    pub async fn send(&self, envelope: WebRtcSignalingEnvelope) -> Result<()> {
        let state = self.state.lock().await;
        let active_handle = state
            .active_handle
            .clone()
            .ok_or_else(|| anyhow!("signaling handle missing"))?;
        if state.lifecycle_phase != SignalingLifecyclePhase::Bound {
            bail!(
                "signaling send requires bound handle for session {}",
                active_handle.session_id
            );
        }
        drop(state);
        self.outgoing
            .send(envelope)
            .await
            .map_err(|_| anyhow!("signaling send queue closed"))
    }

    pub async fn next_inbound(&mut self) -> Option<InboundMessage> {
        self.incoming.recv().await
    }

    pub async fn next_lifecycle(&mut self) -> Option<SignalingLifecycleEvent> {
        self.lifecycle.recv().await
    }

    pub async fn next_runtime_event(&mut self) -> Option<SignalingRuntimeEvent> {
        self.runtime_events.recv().await
    }

    pub async fn snapshot(&self) -> SignalingState {
        self.state.lock().await.clone()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SerializableEnvelope {
    session_id: String,
    from: String,
    to: Option<String>,
    #[serde(rename = "type")]
    kind: WebRtcMessageType,
    payload: Option<WebRtcSignalingPayload>,
    auth_token: Option<String>,
    sent_at: f64,
}

impl From<WebRtcSignalingEnvelope> for SerializableEnvelope {
    fn from(value: WebRtcSignalingEnvelope) -> Self {
        Self {
            session_id: value.session_id,
            from: value.from,
            to: value.to,
            kind: value.kind,
            payload: value.payload,
            auth_token: value.auth_token,
            sent_at: value.sent_at,
        }
    }
}

fn parse_inbound_message(text: &str) -> InboundMessage {
    if let Ok(envelope) = serde_json::from_str::<SerializableEnvelope>(text) {
        return InboundMessage::Envelope(WebRtcSignalingEnvelope {
            session_id: envelope.session_id,
            from: envelope.from,
            to: envelope.to,
            kind: envelope.kind,
            payload: envelope.payload,
            auth_token: envelope.auth_token,
            sent_at: envelope.sent_at,
        });
    }
    if let Ok(frame) = serde_json::from_str::<SignalingServerFrame>(text) {
        return InboundMessage::ServerFrame(frame);
    }
    InboundMessage::Unknown
}

async fn emit_lifecycle(
    lifecycle_sender: &mpsc::Sender<SignalingLifecycleEvent>,
    runtime_sender: &mpsc::Sender<SignalingRuntimeEvent>,
    state: &Arc<Mutex<SignalingState>>,
    event: SignalingLifecycleEvent,
) -> Result<()> {
    {
        let mut state = state.lock().await;
        state.apply_lifecycle_event(event.clone());
    }
    runtime_sender
        .send(SignalingRuntimeEvent::Lifecycle(event.clone()))
        .await
        .map_err(|_| anyhow!("runtime event receiver dropped"))?;
    lifecycle_sender
        .send(event)
        .await
        .map_err(|_| anyhow!("lifecycle receiver dropped"))
}

fn classify_server_error(reason: &str) -> SignalingFailureClass {
    let normalized = reason.trim().to_ascii_lowercase();
    if normalized.contains("token") && normalized.contains("expired") {
        SignalingFailureClass::TokenExpired
    } else if normalized.contains("auth")
        || normalized.contains("unauthorized")
        || normalized.contains("forbidden")
        || normalized.contains("bind_rejected")
    {
        SignalingFailureClass::AuthBindRejected
    } else if normalized.contains("invalid shard")
        || normalized.contains("invalid session")
        || normalized.contains("session mismatch")
        || normalized.contains("unknown shard")
        || normalized.contains("room_full")
    {
        SignalingFailureClass::InvalidShardOrSessionMismatch
    } else if normalized.contains("protocol") || normalized.contains("malformed") {
        SignalingFailureClass::ProtocolViolation
    } else {
        SignalingFailureClass::TransientServer
    }
}

pub fn make_join_envelope(session_id: &str, device_id: &str) -> WebRtcSignalingEnvelope {
    WebRtcSignalingEnvelope {
        session_id: session_id.to_owned(),
        from: device_id.to_owned(),
        to: None,
        kind: WebRtcMessageType::Join,
        payload: None,
        auth_token: None,
        sent_at: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs_f64())
            .unwrap_or_default(),
    }
}

pub fn make_session_runtime_id(session_id: &str) -> String {
    format!("session-runtime:{}:{}", session_id, Uuid::now_v7())
}
