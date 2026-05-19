use std::sync::Arc;
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use bytes::BytesMut;
use tokio::sync::{Mutex, mpsc};
use tokio::time::timeout;
use tracing::{debug, info, warn};
use webrtc::data_channel::{DataChannel, DataChannelEvent, RTCDataChannelMessage};
use webrtc::peer_connection::{
    MediaEngine, PeerConnection, PeerConnectionBuilder, PeerConnectionEventHandler,
    RTCConfigurationBuilder, RTCIceCandidateInit, RTCIceGatheringState, RTCPeerConnectionState,
    RTCSessionDescription,
};

use crate::{
    ClassicHandleResult, ClassicInitiatorConfig, ClassicSessionKeys, PqcInitiatorConfig,
    PqcResponderConfig, RuntimeSessionKeepaliveKind, RuntimeSessionRole, TurnCredentials,
    WebRtcMessageType, WebRtcSignalingEnvelope, WebRtcSignalingPayload,
};

mod handshake;
mod support;
#[cfg(test)]
mod tests;

use handshake::NativeSessionHandshake;
use support::{build_ice_servers, native_webrtc_udp_bind_addrs, now_unix_seconds};

const CONTROL_CHANNEL_LABEL: &str = "skybridge";
const MAX_FRAMED_PAYLOAD_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct NativeWebRtcConfig {
    pub session_id: String,
    pub local_device_id: String,
    pub role: RuntimeSessionRole,
    pub turn_credentials: Option<TurnCredentials>,
    pub classic_initiator: Option<ClassicInitiatorConfig>,
    pub pqc_initiator: Option<PqcInitiatorConfig>,
    pub pqc_responder: Option<PqcResponderConfig>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum NativeWebRtcEvent {
    SignalingEnvelope(WebRtcSignalingEnvelope),
    TransportReady,
    HandshakeComplete {
        negotiated_suite: String,
    },
    Keepalive {
        kind: RuntimeSessionKeepaliveKind,
        ping_id: Option<u64>,
    },
    TransportDisconnected {
        reason: Option<String>,
    },
}

#[derive(Debug, Default)]
struct NativeWebRtcState {
    offer_started: bool,
    answer_sent: bool,
    remote_description_set: bool,
    transport_ready_emitted: bool,
    transport_disconnected_emitted: bool,
    handshake_complete_emitted: bool,
    inbound_framed_buffer: Vec<u8>,
    handshake: Option<NativeSessionHandshake>,
    established_session_keys: Option<ClassicSessionKeys>,
    heartbeat_task_started: bool,
    next_ping_id: u64,
    pending_remote_candidates: Vec<RTCIceCandidateInit>,
}

struct NativeWebRtcInner {
    session_id: String,
    local_device_id: String,
    role: RuntimeSessionRole,
    peer: Arc<dyn PeerConnection>,
    events_tx: mpsc::Sender<NativeWebRtcEvent>,
    data_channel: Mutex<Option<Arc<dyn DataChannel>>>,
    gather_complete_rx: Mutex<mpsc::Receiver<()>>,
    state: Mutex<NativeWebRtcState>,
}

pub struct NativeWebRtcSession {
    inner: Arc<NativeWebRtcInner>,
    events_rx: mpsc::Receiver<NativeWebRtcEvent>,
}

struct NativeWebRtcEventRouter {
    session_id: String,
    role: RuntimeSessionRole,
    data_channel_tx: mpsc::Sender<Arc<dyn DataChannel>>,
    disconnect_tx: mpsc::Sender<Option<String>>,
    gather_complete_tx: mpsc::Sender<()>,
}

#[async_trait::async_trait]
impl PeerConnectionEventHandler for NativeWebRtcEventRouter {
    async fn on_ice_gathering_state_change(&self, state: RTCIceGatheringState) {
        debug!(
            kind = "native_webrtc.ice_gathering.state_changed",
            session_id = %self.session_id,
            role = ?self.role,
            state = ?state,
            "native WebRTC ICE gathering state changed"
        );
        if state == RTCIceGatheringState::Complete {
            let _ = self.gather_complete_tx.send(()).await;
        }
    }

    async fn on_connection_state_change(&self, state: RTCPeerConnectionState) {
        info!(
            kind = "native_webrtc.peer_connection.state_changed",
            session_id = %self.session_id,
            role = ?self.role,
            state = ?state,
            "peer connection state changed"
        );
        if matches!(
            state,
            RTCPeerConnectionState::Failed
                | RTCPeerConnectionState::Disconnected
                | RTCPeerConnectionState::Closed
        ) {
            let _ = self
                .disconnect_tx
                .send(Some(format!("peer_connection_state_{state:?}")))
                .await;
        }
    }

    async fn on_data_channel(&self, data_channel: Arc<dyn DataChannel>) {
        let label = data_channel.label().await.unwrap_or_default();
        info!(
            kind = "native_webrtc.data_channel.discovered",
            session_id = %self.session_id,
            role = ?self.role,
            label = %label,
            id = data_channel.id(),
            "received remote-created data channel"
        );
        let _ = self.data_channel_tx.send(data_channel).await;
    }
}

impl NativeWebRtcSession {
    pub async fn new(config: NativeWebRtcConfig) -> Result<Self> {
        let mut media_engine = MediaEngine::default();
        media_engine.register_default_codecs()?;
        let rtc_configuration = RTCConfigurationBuilder::new()
            .with_ice_servers(build_ice_servers(config.turn_credentials.as_ref()))
            .build();

        let (events_tx, events_rx) = mpsc::channel(128);
        let (data_channel_tx, mut data_channel_rx) = mpsc::channel(16);
        let (disconnect_tx, mut disconnect_rx) = mpsc::channel(16);
        let (gather_complete_tx, gather_complete_rx) = mpsc::channel(8);
        let handler = Arc::new(NativeWebRtcEventRouter {
            session_id: config.session_id.clone(),
            role: config.role,
            data_channel_tx,
            disconnect_tx,
            gather_complete_tx,
        });
        let udp_bind_addrs = native_webrtc_udp_bind_addrs();
        let peer = Arc::new(
            PeerConnectionBuilder::new()
                .with_configuration(rtc_configuration)
                .with_media_engine(media_engine)
                .with_handler(handler)
                .with_udp_addrs(udp_bind_addrs)
                .build()
                .await?,
        ) as Arc<dyn PeerConnection>;

        let inner = Arc::new(NativeWebRtcInner {
            session_id: config.session_id,
            local_device_id: config.local_device_id,
            role: config.role,
            peer,
            events_tx,
            data_channel: Mutex::new(None),
            gather_complete_rx: Mutex::new(gather_complete_rx),
            state: Mutex::new(NativeWebRtcState {
                handshake: match (
                    config.classic_initiator,
                    config.pqc_initiator,
                    config.pqc_responder,
                ) {
                    (_, Some(config), _) => Some(NativeSessionHandshake::pqc_initiator(config)?),
                    (Some(config), None, _) => {
                        Some(NativeSessionHandshake::classic_initiator(config)?)
                    }
                    (None, None, Some(config)) => {
                        Some(NativeSessionHandshake::pqc_responder(config)?)
                    }
                    (None, None, None) => None,
                },
                ..NativeWebRtcState::default()
            }),
        });
        let remote_channel_inner = Arc::clone(&inner);
        tokio::spawn(async move {
            while let Some(data_channel) = data_channel_rx.recv().await {
                remote_channel_inner.attach_data_channel(data_channel).await;
            }
        });
        let disconnect_inner = Arc::clone(&inner);
        tokio::spawn(async move {
            while let Some(reason) = disconnect_rx.recv().await {
                disconnect_inner.emit_transport_disconnected(reason).await;
            }
        });

        Ok(Self { inner, events_rx })
    }

    pub async fn start(&self) -> Result<()> {
        if self.inner.role == RuntimeSessionRole::Initiator {
            info!(
                kind = "native_webrtc.data_channel.create",
                session_id = %self.inner.session_id,
                role = ?self.inner.role,
                label = CONTROL_CHANNEL_LABEL,
                "creating native WebRTC control channel"
            );
            let data_channel = self
                .inner
                .peer
                .create_data_channel(CONTROL_CHANNEL_LABEL, None)
                .await?;
            self.inner.attach_data_channel(data_channel).await;
        }
        Ok(())
    }

    pub async fn notify_remote_join(&self, remote_device_id: &str) -> Result<()> {
        if self.inner.role == RuntimeSessionRole::Initiator
            && remote_device_id != self.inner.local_device_id
        {
            self.inner.start_offer_if_needed().await?;
        }
        Ok(())
    }

    pub async fn handle_signaling_envelope(
        &self,
        envelope: &WebRtcSignalingEnvelope,
    ) -> Result<()> {
        if envelope.session_id != self.inner.session_id
            || envelope.from == self.inner.local_device_id
        {
            return Ok(());
        }

        match envelope.kind {
            WebRtcMessageType::Join => self.notify_remote_join(&envelope.from).await?,
            WebRtcMessageType::Offer => {
                if let Some(sdp) = envelope
                    .payload
                    .as_ref()
                    .and_then(|payload| payload.sdp.clone())
                {
                    self.inner.apply_remote_offer(sdp).await?;
                }
            }
            WebRtcMessageType::Answer => {
                if let Some(sdp) = envelope
                    .payload
                    .as_ref()
                    .and_then(|payload| payload.sdp.clone())
                {
                    self.inner.apply_remote_answer(sdp).await?;
                }
            }
            WebRtcMessageType::IceCandidate => {
                if let Some(payload) = envelope.payload.as_ref() {
                    self.inner.apply_remote_candidate(payload).await?;
                }
            }
            WebRtcMessageType::Leave => {
                self.inner
                    .emit_transport_disconnected(Some("remote_leave".to_owned()))
                    .await;
            }
        }

        Ok(())
    }

    pub async fn next_event(&mut self) -> Option<NativeWebRtcEvent> {
        self.events_rx.recv().await
    }

    pub fn try_next_event(&mut self) -> Option<NativeWebRtcEvent> {
        self.events_rx.try_recv().ok()
    }

    pub async fn close(&self) -> Result<()> {
        self.inner.peer.close().await?;
        Ok(())
    }
}

impl NativeWebRtcInner {
    async fn attach_data_channel(self: &Arc<Self>, data_channel: Arc<dyn DataChannel>) {
        let label = data_channel.label().await.unwrap_or_default();
        if !label.is_empty() && label != CONTROL_CHANNEL_LABEL {
            warn!(
                kind = "native_webrtc.data_channel.rejected",
                session_id = %self.session_id,
                role = ?self.role,
                label = %label,
                id = data_channel.id(),
                expected_label = CONTROL_CHANNEL_LABEL,
                "rejecting unexpected native WebRTC data channel"
            );
            return;
        }
        info!(
            kind = "native_webrtc.data_channel.attached",
            session_id = %self.session_id,
            role = ?self.role,
            label = %label,
            id = data_channel.id(),
            "attaching native WebRTC data channel callbacks"
        );
        {
            let mut slot = self.data_channel.lock().await;
            *slot = Some(Arc::clone(&data_channel));
        }

        let channel_self = Arc::clone(self);
        tokio::spawn(async move {
            while let Some(event) = data_channel.poll().await {
                match event {
                    DataChannelEvent::OnOpen => {
                        if let Err(error) = channel_self
                            .handle_data_channel_open(Arc::clone(&data_channel))
                            .await
                        {
                            warn!(
                                kind = "native_webrtc.data_channel.open_failed",
                                session_id = %channel_self.session_id,
                                role = ?channel_self.role,
                                error = %error,
                                "failed while handling data channel open"
                            );
                            channel_self
                                .emit_transport_disconnected(Some(format!(
                                    "data_channel_open_failed:{error}"
                                )))
                                .await;
                            break;
                        }
                    }
                    DataChannelEvent::OnMessage(message) => {
                        if let Err(error) = channel_self.handle_data_channel_message(message).await
                        {
                            warn!(
                                kind = "native_webrtc.data_channel.message_failed",
                                session_id = %channel_self.session_id,
                                role = ?channel_self.role,
                                error = %error,
                                "failed while handling data channel message"
                            );
                            channel_self
                                .emit_transport_disconnected(Some(format!(
                                    "data_channel_message_failed:{error}"
                                )))
                                .await;
                            break;
                        }
                    }
                    DataChannelEvent::OnClose => {
                        let label = data_channel.label().await.unwrap_or_default();
                        info!(
                            kind = "native_webrtc.data_channel.closed",
                            session_id = %channel_self.session_id,
                            role = ?channel_self.role,
                            label = %label,
                            id = data_channel.id(),
                            "native WebRTC data channel closed"
                        );
                        if channel_self
                            .clear_data_channel_if_current(&data_channel)
                            .await
                        {
                            channel_self
                                .emit_transport_disconnected(Some("data_channel_closed".to_owned()))
                                .await;
                        }
                        break;
                    }
                    DataChannelEvent::OnError => {
                        warn!(
                            kind = "native_webrtc.data_channel.error",
                            session_id = %channel_self.session_id,
                            role = ?channel_self.role,
                            id = data_channel.id(),
                            "native WebRTC data channel emitted an error"
                        );
                        if channel_self
                            .clear_data_channel_if_current(&data_channel)
                            .await
                        {
                            channel_self
                                .emit_transport_disconnected(Some("data_channel_error".to_owned()))
                                .await;
                        }
                        break;
                    }
                    DataChannelEvent::OnClosing
                    | DataChannelEvent::OnBufferedAmountLow
                    | DataChannelEvent::OnBufferedAmountHigh => {}
                }
            }
        });
    }

    async fn clear_data_channel_if_current(&self, data_channel: &Arc<dyn DataChannel>) -> bool {
        let mut slot = self.data_channel.lock().await;
        if slot
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, data_channel))
        {
            *slot = None;
            true
        } else {
            false
        }
    }

    async fn start_offer_if_needed(&self) -> Result<()> {
        {
            let mut state = self.state.lock().await;
            if state.offer_started {
                return Ok(());
            }
            state.offer_started = true;
        }

        let result = async {
            let offer = self.peer.create_offer(None).await?;
            self.peer.set_local_description(offer).await?;
            self.wait_for_ice_gathering_complete().await?;
            let local_description = self
                .peer
                .local_description()
                .await
                .ok_or_else(|| anyhow!("local_offer_missing"))?;
            self.emit_signaling_envelope(
                WebRtcMessageType::Offer,
                Some(WebRtcSignalingPayload {
                    sdp: Some(local_description.sdp),
                    candidate: None,
                    sdp_mid: None,
                    sdp_m_line_index: None,
                }),
            )
            .await
        }
        .await;

        if result.is_err() {
            let mut state = self.state.lock().await;
            state.offer_started = false;
        }

        result
    }

    async fn apply_remote_offer(&self, sdp: String) -> Result<()> {
        self.peer
            .set_remote_description(RTCSessionDescription::offer(sdp)?)
            .await?;
        {
            let mut state = self.state.lock().await;
            state.remote_description_set = true;
        }
        self.flush_pending_remote_candidates().await?;
        self.start_answer_if_needed().await
    }

    async fn start_answer_if_needed(&self) -> Result<()> {
        {
            let mut state = self.state.lock().await;
            if state.answer_sent {
                return Ok(());
            }
            state.answer_sent = true;
        }

        let result = async {
            let answer = self.peer.create_answer(None).await?;
            self.peer.set_local_description(answer).await?;
            self.wait_for_ice_gathering_complete().await?;
            let local_description = self
                .peer
                .local_description()
                .await
                .ok_or_else(|| anyhow!("local_answer_missing"))?;
            self.emit_signaling_envelope(
                WebRtcMessageType::Answer,
                Some(WebRtcSignalingPayload {
                    sdp: Some(local_description.sdp),
                    candidate: None,
                    sdp_mid: None,
                    sdp_m_line_index: None,
                }),
            )
            .await
        }
        .await;

        if result.is_err() {
            let mut state = self.state.lock().await;
            state.answer_sent = false;
        }

        result
    }

    async fn wait_for_ice_gathering_complete(&self) -> Result<()> {
        let mut gather_complete_rx = self.gather_complete_rx.lock().await;
        timeout(Duration::from_secs(10), gather_complete_rx.recv())
            .await
            .map_err(|_| anyhow!("ice_gathering_timeout"))?
            .ok_or_else(|| anyhow!("ice_gathering_channel_closed"))?;
        Ok(())
    }

    async fn apply_remote_answer(&self, sdp: String) -> Result<()> {
        self.peer
            .set_remote_description(RTCSessionDescription::answer(sdp)?)
            .await?;
        {
            let mut state = self.state.lock().await;
            state.remote_description_set = true;
        }
        self.flush_pending_remote_candidates().await
    }

    async fn apply_remote_candidate(&self, payload: &WebRtcSignalingPayload) -> Result<()> {
        let Some(candidate) = payload.candidate.clone() else {
            return Ok(());
        };
        let candidate_init = RTCIceCandidateInit {
            candidate,
            sdp_mid: payload.sdp_mid.clone(),
            sdp_mline_index: payload
                .sdp_m_line_index
                .and_then(|value| u16::try_from(value).ok()),
            username_fragment: None,
            url: None,
        };

        let remote_description_set = {
            let state = self.state.lock().await;
            state.remote_description_set
        };
        if remote_description_set {
            self.peer.add_ice_candidate(candidate_init).await?;
        } else {
            let mut state = self.state.lock().await;
            state.pending_remote_candidates.push(candidate_init);
        }
        Ok(())
    }

    async fn flush_pending_remote_candidates(&self) -> Result<()> {
        let pending = {
            let mut state = self.state.lock().await;
            std::mem::take(&mut state.pending_remote_candidates)
        };
        for candidate in pending {
            self.peer.add_ice_candidate(candidate).await?;
        }
        Ok(())
    }

    async fn handle_data_channel_open(
        self: &Arc<Self>,
        data_channel: Arc<dyn DataChannel>,
    ) -> Result<()> {
        let (should_emit_ready, outbound_message_a) = {
            let mut state = self.state.lock().await;
            let should_emit_ready = if state.transport_ready_emitted {
                false
            } else {
                state.transport_ready_emitted = true;
                true
            };
            let outbound_message_a = state
                .handshake
                .as_mut()
                .map(NativeSessionHandshake::start)
                .transpose()?;
            (should_emit_ready, outbound_message_a)
        };

        if should_emit_ready {
            let label = data_channel.label().await.unwrap_or_default();
            if !label.is_empty() && label != CONTROL_CHANNEL_LABEL {
                bail!("unexpected_data_channel_label:{label}");
            }
            info!(
                kind = "native_webrtc.transport.ready",
                session_id = %self.session_id,
                role = ?self.role,
                label = %label,
                id = data_channel.id(),
                "data channel opened; emitting transport_ready"
            );
            self.events_tx
                .send(NativeWebRtcEvent::TransportReady)
                .await
                .map_err(|_| anyhow!("native_webrtc_event_receiver_dropped"))?;
        }

        if let Some(message_a) = outbound_message_a.filter(|message| !message.is_empty()) {
            info!(
                kind = "native_webrtc.handshake.message_a.sent",
                session_id = %self.session_id,
                role = ?self.role,
                bytes = message_a.len(),
                "sending initial handshake frame over data channel"
            );
            self.send_framed_payload(&data_channel, &message_a).await?;
        }
        Ok(())
    }

    async fn handle_data_channel_message(
        self: &Arc<Self>,
        message: RTCDataChannelMessage,
    ) -> Result<()> {
        if message.is_string {
            let preview = String::from_utf8_lossy(&message.data);
            debug!(
                kind = "native_webrtc.data_channel.message_text",
                session_id = %self.session_id,
                role = ?self.role,
                bytes = message.data.len(),
                preview = %preview.chars().take(96).collect::<String>(),
                "received text message on native WebRTC data channel"
            );
        } else {
            debug!(
                kind = "native_webrtc.data_channel.message_binary",
                session_id = %self.session_id,
                role = ?self.role,
                bytes = message.data.len(),
                "received binary message on native WebRTC data channel"
            );
        }
        let frames = self.buffer_inbound_frames(message.data.as_ref()).await?;
        for frame in frames {
            self.handle_framed_payload(frame).await?;
        }
        Ok(())
    }

    async fn buffer_inbound_frames(&self, chunk: &[u8]) -> Result<Vec<Vec<u8>>> {
        let mut frames = Vec::new();
        let mut state = self.state.lock().await;
        state.inbound_framed_buffer.extend_from_slice(chunk);
        loop {
            if state.inbound_framed_buffer.len() < 4 {
                break;
            }
            let length = u32::from_be_bytes(
                state.inbound_framed_buffer[..4]
                    .try_into()
                    .map_err(|_| anyhow!("invalid inbound frame header"))?,
            ) as usize;
            if length == 0 || length > MAX_FRAMED_PAYLOAD_BYTES {
                bail!("invalid framed payload length: {length}");
            }
            if state.inbound_framed_buffer.len() < 4 + length {
                break;
            }
            let payload = state.inbound_framed_buffer[4..(4 + length)].to_vec();
            state.inbound_framed_buffer.drain(..(4 + length));
            frames.push(payload);
        }
        Ok(frames)
    }

    async fn handle_framed_payload(self: &Arc<Self>, payload: Vec<u8>) -> Result<()> {
        let actions = {
            let mut state = self.state.lock().await;
            if let Some(handshake) = state.handshake.as_mut() {
                handshake.handle_frame(&payload)?
            } else {
                ClassicHandleResult::default()
            }
        };

        if !actions.outbound_frames.is_empty() {
            let data_channel = self
                .data_channel
                .lock()
                .await
                .clone()
                .ok_or_else(|| anyhow!("data channel is not attached"))?;
            for outbound in actions.outbound_frames {
                self.send_framed_payload(&data_channel, &outbound).await?;
            }
        }

        if let Some(established) = actions.established {
            self.mark_handshake_complete(established).await?;
        }

        if let Some(pong_id) = actions.pong_id {
            info!(
                kind = "native_webrtc.keepalive.pong_reply",
                session_id = %self.session_id,
                role = ?self.role,
                ping_id = pong_id,
                "replying to encrypted keepalive ping"
            );
            let outbound = {
                let state = self.state.lock().await;
                let handshake = state
                    .handshake
                    .as_ref()
                    .ok_or_else(|| anyhow!("native handshake missing"))?;
                handshake.build_pong_frame(pong_id)?
            };
            let data_channel = self
                .data_channel
                .lock()
                .await
                .clone()
                .ok_or_else(|| anyhow!("data channel is not attached"))?;
            self.send_framed_payload(&data_channel, &outbound).await?;
            self.emit_keepalive_event(RuntimeSessionKeepaliveKind::PongReplied, Some(pong_id))
                .await;
        }

        if actions.observed_heartbeat {
            info!(
                kind = "native_webrtc.keepalive.heartbeat_received",
                session_id = %self.session_id,
                role = ?self.role,
                "received encrypted heartbeat"
            );
            self.emit_keepalive_event(RuntimeSessionKeepaliveKind::HeartbeatReceived, None)
                .await;
        }

        if let Some(pong_id) = actions.observed_pong_id {
            info!(
                kind = "native_webrtc.keepalive.pong_received",
                session_id = %self.session_id,
                role = ?self.role,
                ping_id = pong_id,
                "received encrypted keepalive pong"
            );
            self.emit_keepalive_event(RuntimeSessionKeepaliveKind::PongReceived, Some(pong_id))
                .await;
        }

        if actions.heartbeat_requested {
            self.ensure_heartbeat_task().await?;
        }

        Ok(())
    }

    async fn mark_handshake_complete(
        self: &Arc<Self>,
        established: ClassicSessionKeys,
    ) -> Result<()> {
        let should_emit = {
            let mut state = self.state.lock().await;
            state.established_session_keys = Some(established.clone());
            if state.handshake_complete_emitted {
                false
            } else {
                state.handshake_complete_emitted = true;
                true
            }
        };
        if should_emit {
            info!(
                kind = "native_webrtc.handshake.complete",
                session_id = %self.session_id,
                role = ?self.role,
                negotiated_suite = %established.negotiated_suite,
                "native handshake reached handshake_complete"
            );
            self.events_tx
                .send(NativeWebRtcEvent::HandshakeComplete {
                    negotiated_suite: established.negotiated_suite,
                })
                .await
                .map_err(|_| anyhow!("native_webrtc_event_receiver_dropped"))?;
        }
        self.ensure_heartbeat_task().await?;
        Ok(())
    }

    async fn ensure_heartbeat_task(self: &Arc<Self>) -> Result<()> {
        let should_start = {
            let mut state = self.state.lock().await;
            if state.heartbeat_task_started || state.established_session_keys.is_none() {
                false
            } else {
                state.heartbeat_task_started = true;
                true
            }
        };
        if !should_start {
            return Ok(());
        }

        let heartbeat_self = Arc::clone(self);
        tokio::spawn(async move {
            if let Err(error) = heartbeat_self.send_heartbeat_once().await {
                warn!(
                    kind = "native_webrtc.heartbeat.initial_failed",
                    session_id = %heartbeat_self.session_id,
                    role = ?heartbeat_self.role,
                    error = %error,
                    "initial handshake heartbeat send failed"
                );
                return;
            }

            if let Err(error) = heartbeat_self.send_ping_once().await {
                warn!(
                    kind = "native_webrtc.keepalive.initial_ping_failed",
                    session_id = %heartbeat_self.session_id,
                    role = ?heartbeat_self.role,
                    error = %error,
                    "initial handshake keepalive ping failed"
                );
                return;
            }

            let mut interval = tokio::time::interval(Duration::from_secs(2));
            let mut tick_count = 0_u64;
            loop {
                interval.tick().await;
                tick_count = tick_count.saturating_add(1);
                if tick_count.is_multiple_of(3)
                    && let Err(error) = heartbeat_self.send_heartbeat_once().await
                {
                    warn!(
                        kind = "native_webrtc.heartbeat.stopped",
                        session_id = %heartbeat_self.session_id,
                        role = ?heartbeat_self.role,
                        error = %error,
                        "stopping handshake heartbeat loop"
                    );
                    break;
                }
                if let Err(error) = heartbeat_self.send_ping_once().await {
                    warn!(
                        kind = "native_webrtc.keepalive.stopped",
                        session_id = %heartbeat_self.session_id,
                        role = ?heartbeat_self.role,
                        error = %error,
                        "stopping handshake keepalive loop"
                    );
                    break;
                }
            }
        });

        Ok(())
    }

    async fn send_heartbeat_once(self: &Arc<Self>) -> Result<()> {
        let heartbeat_frame = {
            let state = self.state.lock().await;
            let handshake = state
                .handshake
                .as_ref()
                .ok_or_else(|| anyhow!("native handshake missing"))?;
            handshake.build_heartbeat_frame()?
        };
        let data_channel = self
            .data_channel
            .lock()
            .await
            .clone()
            .ok_or_else(|| anyhow!("data channel is not attached"))?;
        info!(
            kind = "native_webrtc.keepalive.heartbeat_sent",
            session_id = %self.session_id,
            role = ?self.role,
            bytes = heartbeat_frame.len(),
            "sending encrypted heartbeat"
        );
        self.send_framed_payload(&data_channel, &heartbeat_frame)
            .await?;
        self.emit_keepalive_event(RuntimeSessionKeepaliveKind::HeartbeatSent, None)
            .await;
        Ok(())
    }

    async fn send_ping_once(self: &Arc<Self>) -> Result<()> {
        let (ping_id, ping_frame) = {
            let mut state = self.state.lock().await;
            let ping_id = state.next_ping_id;
            state.next_ping_id = state.next_ping_id.saturating_add(1);
            let handshake = state
                .handshake
                .as_ref()
                .ok_or_else(|| anyhow!("native handshake missing"))?;
            let ping_frame = handshake.build_ping_frame(ping_id)?;
            (ping_id, ping_frame)
        };
        let data_channel = self
            .data_channel
            .lock()
            .await
            .clone()
            .ok_or_else(|| anyhow!("data channel is not attached"))?;
        info!(
            kind = "native_webrtc.keepalive.ping_sent",
            session_id = %self.session_id,
            role = ?self.role,
            ping_id = ping_id,
            bytes = ping_frame.len(),
            "sending encrypted keepalive ping"
        );
        self.send_framed_payload(&data_channel, &ping_frame).await?;
        self.emit_keepalive_event(RuntimeSessionKeepaliveKind::PingSent, Some(ping_id))
            .await;
        Ok(())
    }

    async fn send_framed_payload(
        &self,
        data_channel: &Arc<dyn DataChannel>,
        payload: &[u8],
    ) -> Result<()> {
        if payload.len() > MAX_FRAMED_PAYLOAD_BYTES {
            bail!("payload too large for framed data channel send");
        }
        let mut framed = Vec::with_capacity(4 + payload.len());
        framed.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        framed.extend_from_slice(payload);
        data_channel
            .send(BytesMut::from(framed.as_slice()))
            .await
            .map_err(|error| anyhow!("failed to send framed data channel payload: {error}"))?;
        Ok(())
    }

    async fn emit_transport_disconnected(&self, reason: Option<String>) {
        let should_emit = {
            let mut state = self.state.lock().await;
            state.established_session_keys = None;
            state.heartbeat_task_started = false;
            state.next_ping_id = 0;
            if state.transport_disconnected_emitted {
                false
            } else {
                state.transport_disconnected_emitted = true;
                true
            }
        };
        if should_emit {
            info!(
                kind = "native_webrtc.transport.disconnected",
                session_id = %self.session_id,
                role = ?self.role,
                reason = reason.as_deref().unwrap_or("unknown"),
                "emitting transport disconnected"
            );
            let _ = self
                .events_tx
                .send(NativeWebRtcEvent::TransportDisconnected { reason })
                .await;
        }
    }

    async fn emit_keepalive_event(&self, kind: RuntimeSessionKeepaliveKind, ping_id: Option<u64>) {
        let _ = self
            .events_tx
            .send(NativeWebRtcEvent::Keepalive { kind, ping_id })
            .await;
    }

    async fn emit_signaling_envelope(
        &self,
        kind: WebRtcMessageType,
        payload: Option<WebRtcSignalingPayload>,
    ) -> Result<()> {
        self.events_tx
            .send(NativeWebRtcEvent::SignalingEnvelope(
                WebRtcSignalingEnvelope {
                    session_id: self.session_id.clone(),
                    from: self.local_device_id.clone(),
                    to: None,
                    kind,
                    payload,
                    auth_token: None,
                    sent_at: now_unix_seconds(),
                },
            ))
            .await
            .map_err(|_| anyhow!("native_webrtc_event_receiver_dropped"))
    }
}
