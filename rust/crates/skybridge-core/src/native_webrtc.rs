use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Result, anyhow, bail};
use bytes::Bytes;
use tokio::sync::{Mutex, mpsc};
use tokio::time::timeout;
use tracing::{debug, info, warn};
use webrtc::api::APIBuilder;
use webrtc::api::media_engine::MediaEngine;
use webrtc::data_channel::RTCDataChannel;
use webrtc::data_channel::data_channel_message::DataChannelMessage;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

use crate::{
    ClassicHandleResult, ClassicInitiatorConfig, ClassicInitiatorHandshake, ClassicSessionKeys,
    PqcInitiatorConfig, PqcInitiatorHandshake, PqcResponderConfig, PqcResponderHandshake,
    RuntimeSessionKeepaliveKind, RuntimeSessionRole, TurnCredentials, WebRtcMessageType,
    WebRtcSignalingEnvelope, WebRtcSignalingPayload,
};

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
    ApplicationPayload {
        payload: Vec<u8>,
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

#[derive(Debug)]
enum NativeInitiatorHandshake {
    Classic(ClassicInitiatorHandshake),
    Pqc(PqcInitiatorHandshake),
}

#[derive(Debug)]
enum NativeResponderHandshake {
    Pqc(PqcResponderHandshake),
}

#[derive(Debug)]
enum NativeSessionHandshake {
    Initiator(NativeInitiatorHandshake),
    Responder(NativeResponderHandshake),
}

impl NativeInitiatorHandshake {
    fn start(&mut self) -> Result<Vec<u8>> {
        match self {
            Self::Classic(handshake) => handshake.start(),
            Self::Pqc(handshake) => handshake.start(),
        }
    }

    fn handle_frame(&mut self, frame: &[u8]) -> Result<ClassicHandleResult> {
        match self {
            Self::Classic(handshake) => handshake.handle_frame(frame),
            Self::Pqc(handshake) => handshake.handle_frame(frame),
        }
    }

    fn build_heartbeat_frame(&self) -> Result<Vec<u8>> {
        match self {
            Self::Classic(handshake) => handshake.build_heartbeat_frame(),
            Self::Pqc(handshake) => handshake.build_heartbeat_frame(),
        }
    }

    fn build_pong_frame(&self, id: u64) -> Result<Vec<u8>> {
        match self {
            Self::Classic(handshake) => handshake.build_pong_frame(id),
            Self::Pqc(handshake) => handshake.build_pong_frame(id),
        }
    }

    fn build_ping_frame(&self, id: u64) -> Result<Vec<u8>> {
        match self {
            Self::Classic(handshake) => handshake.build_ping_frame(id),
            Self::Pqc(handshake) => handshake.build_ping_frame(id),
        }
    }

    fn build_application_frame(&self, payload: &[u8]) -> Result<Vec<u8>> {
        match self {
            Self::Classic(handshake) => handshake.build_application_frame(payload),
            Self::Pqc(handshake) => handshake.build_application_frame(payload),
        }
    }
}

impl NativeResponderHandshake {
    fn handle_frame(&mut self, frame: &[u8]) -> Result<ClassicHandleResult> {
        match self {
            Self::Pqc(handshake) => handshake.handle_frame(frame),
        }
    }

    fn build_heartbeat_frame(&self) -> Result<Vec<u8>> {
        match self {
            Self::Pqc(handshake) => handshake.build_heartbeat_frame(),
        }
    }

    fn build_pong_frame(&self, id: u64) -> Result<Vec<u8>> {
        match self {
            Self::Pqc(handshake) => handshake.build_pong_frame(id),
        }
    }

    fn build_ping_frame(&self, id: u64) -> Result<Vec<u8>> {
        match self {
            Self::Pqc(handshake) => handshake.build_ping_frame(id),
        }
    }

    fn build_application_frame(&self, payload: &[u8]) -> Result<Vec<u8>> {
        match self {
            Self::Pqc(handshake) => handshake.build_application_frame(payload),
        }
    }
}

impl NativeSessionHandshake {
    fn start(&mut self) -> Result<Vec<u8>> {
        match self {
            Self::Initiator(handshake) => handshake.start(),
            Self::Responder(_) => Ok(Vec::new()),
        }
    }

    fn handle_frame(&mut self, frame: &[u8]) -> Result<ClassicHandleResult> {
        match self {
            Self::Initiator(handshake) => handshake.handle_frame(frame),
            Self::Responder(handshake) => handshake.handle_frame(frame),
        }
    }

    fn build_heartbeat_frame(&self) -> Result<Vec<u8>> {
        match self {
            Self::Initiator(handshake) => handshake.build_heartbeat_frame(),
            Self::Responder(handshake) => handshake.build_heartbeat_frame(),
        }
    }

    fn build_pong_frame(&self, id: u64) -> Result<Vec<u8>> {
        match self {
            Self::Initiator(handshake) => handshake.build_pong_frame(id),
            Self::Responder(handshake) => handshake.build_pong_frame(id),
        }
    }

    fn build_ping_frame(&self, id: u64) -> Result<Vec<u8>> {
        match self {
            Self::Initiator(handshake) => handshake.build_ping_frame(id),
            Self::Responder(handshake) => handshake.build_ping_frame(id),
        }
    }

    fn build_application_frame(&self, payload: &[u8]) -> Result<Vec<u8>> {
        match self {
            Self::Initiator(handshake) => handshake.build_application_frame(payload),
            Self::Responder(handshake) => handshake.build_application_frame(payload),
        }
    }
}

struct NativeWebRtcInner {
    session_id: String,
    local_device_id: String,
    role: RuntimeSessionRole,
    peer: RTCPeerConnection,
    events_tx: mpsc::Sender<NativeWebRtcEvent>,
    data_channel: Mutex<Option<Arc<RTCDataChannel>>>,
    state: Mutex<NativeWebRtcState>,
}

pub struct NativeWebRtcSession {
    inner: Arc<NativeWebRtcInner>,
    events_rx: mpsc::Receiver<NativeWebRtcEvent>,
}

#[derive(Clone)]
pub struct NativeWebRtcHandle {
    inner: Arc<NativeWebRtcInner>,
}

impl NativeWebRtcSession {
    pub async fn new(config: NativeWebRtcConfig) -> Result<Self> {
        let mut media_engine = MediaEngine::default();
        media_engine.register_default_codecs()?;
        let api = APIBuilder::new().with_media_engine(media_engine).build();
        let peer = api
            .new_peer_connection(RTCConfiguration {
                ice_servers: build_ice_servers(config.turn_credentials.as_ref()),
                ..Default::default()
            })
            .await?;

        let (events_tx, events_rx) = mpsc::channel(128);
        let inner = Arc::new(NativeWebRtcInner {
            session_id: config.session_id,
            local_device_id: config.local_device_id,
            role: config.role,
            peer,
            events_tx,
            data_channel: Mutex::new(None),
            state: Mutex::new(NativeWebRtcState {
                handshake: match (
                    config.classic_initiator,
                    config.pqc_initiator,
                    config.pqc_responder,
                ) {
                    (_, Some(config), _) => Some(NativeSessionHandshake::Initiator(
                        NativeInitiatorHandshake::Pqc(PqcInitiatorHandshake::new(config)?),
                    )),
                    (Some(config), None, _) => Some(NativeSessionHandshake::Initiator(
                        NativeInitiatorHandshake::Classic(ClassicInitiatorHandshake::new(config)?),
                    )),
                    (None, None, Some(config)) => Some(NativeSessionHandshake::Responder(
                        NativeResponderHandshake::Pqc(PqcResponderHandshake::new(config)?),
                    )),
                    (None, None, None) => None,
                },
                ..NativeWebRtcState::default()
            }),
        });
        inner.install_callbacks().await;

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

    pub fn handle(&self) -> NativeWebRtcHandle {
        NativeWebRtcHandle {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl NativeWebRtcHandle {
    pub async fn send_application_payload(&self, payload: &[u8]) -> Result<()> {
        self.inner.send_application_payload(payload).await
    }
}

impl NativeWebRtcInner {
    async fn install_callbacks(self: &Arc<Self>) {
        let on_data_channel_self = Arc::clone(self);
        self.peer
            .on_data_channel(Box::new(move |data_channel: Arc<RTCDataChannel>| {
                let on_data_channel_self = Arc::clone(&on_data_channel_self);
                Box::pin(async move {
                    info!(
                        kind = "native_webrtc.data_channel.discovered",
                        session_id = %on_data_channel_self.session_id,
                        role = ?on_data_channel_self.role,
                        label = %data_channel.label(),
                        id = data_channel.id(),
                        "received remote-created data channel"
                    );
                    on_data_channel_self.attach_data_channel(data_channel).await;
                })
            }));

        let on_state_self = Arc::clone(self);
        self.peer.on_peer_connection_state_change(Box::new(
            move |state: RTCPeerConnectionState| {
                let on_state_self = Arc::clone(&on_state_self);
                Box::pin(async move {
                    info!(
                        kind = "native_webrtc.peer_connection.state_changed",
                        session_id = %on_state_self.session_id,
                        role = ?on_state_self.role,
                        state = ?state,
                        "peer connection state changed"
                    );
                    if matches!(
                        state,
                        RTCPeerConnectionState::Failed
                            | RTCPeerConnectionState::Disconnected
                            | RTCPeerConnectionState::Closed
                    ) {
                        on_state_self
                            .emit_transport_disconnected(Some(format!(
                                "peer_connection_state_{state:?}"
                            )))
                            .await;
                    }
                })
            },
        ));
    }

    async fn attach_data_channel(self: &Arc<Self>, data_channel: Arc<RTCDataChannel>) {
        info!(
            kind = "native_webrtc.data_channel.attached",
            session_id = %self.session_id,
            role = ?self.role,
            label = %data_channel.label(),
            id = data_channel.id(),
            "attaching native WebRTC data channel callbacks"
        );
        {
            let mut slot = self.data_channel.lock().await;
            *slot = Some(Arc::clone(&data_channel));
        }

        let on_open_self = Arc::clone(self);
        let on_open_channel = Arc::clone(&data_channel);
        data_channel.on_open(Box::new(move || {
            let on_open_self = Arc::clone(&on_open_self);
            let on_open_channel = Arc::clone(&on_open_channel);
            Box::pin(async move {
                if let Err(error) = on_open_self.handle_data_channel_open(on_open_channel).await {
                    warn!(
                        kind = "native_webrtc.data_channel.open_failed",
                        session_id = %on_open_self.session_id,
                        role = ?on_open_self.role,
                        error = %error,
                        "failed while handling data channel open"
                    );
                }
            })
        }));

        let on_message_self = Arc::clone(self);
        data_channel.on_message(Box::new(move |message: DataChannelMessage| {
            let on_message_self = Arc::clone(&on_message_self);
            Box::pin(async move {
                if let Err(error) = on_message_self.handle_data_channel_message(message).await {
                    warn!(
                        kind = "native_webrtc.data_channel.message_failed",
                        session_id = %on_message_self.session_id,
                        role = ?on_message_self.role,
                        error = %error,
                        "failed while handling data channel message"
                    );
                }
            })
        }));

        let on_close_self = Arc::clone(self);
        let on_close_channel = Arc::clone(&data_channel);
        data_channel.on_close(Box::new(move || {
            let on_close_self = Arc::clone(&on_close_self);
            let on_close_channel = Arc::clone(&on_close_channel);
            Box::pin(async move {
                info!(
                    kind = "native_webrtc.data_channel.closed",
                    session_id = %on_close_self.session_id,
                    role = ?on_close_self.role,
                    label = %on_close_channel.label(),
                    id = on_close_channel.id(),
                    "native WebRTC data channel closed"
                );
                on_close_self
                    .emit_transport_disconnected(Some("data_channel_closed".to_owned()))
                    .await;
            })
        }));
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
            let mut gather_complete = self.peer.gathering_complete_promise().await;
            self.peer.set_local_description(offer).await?;
            let _ = timeout(Duration::from_secs(10), gather_complete.recv())
                .await
                .map_err(|_| anyhow!("ice_gathering_timeout"))?;
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
            let mut gather_complete = self.peer.gathering_complete_promise().await;
            self.peer.set_local_description(answer).await?;
            let _ = timeout(Duration::from_secs(10), gather_complete.recv())
                .await
                .map_err(|_| anyhow!("ice_gathering_timeout"))?;
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
        data_channel: Arc<RTCDataChannel>,
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
            info!(
                kind = "native_webrtc.transport.ready",
                session_id = %self.session_id,
                role = ?self.role,
                label = %data_channel.label(),
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
        message: DataChannelMessage,
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
        let payload = unwrap_traffic_padding_if_needed(&payload);
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

        if let Some(payload) = actions.app_payload {
            self.events_tx
                .send(NativeWebRtcEvent::ApplicationPayload { payload })
                .await
                .map_err(|_| anyhow!("native_webrtc_event_receiver_dropped"))?;
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
                if tick_count % 3 == 0 {
                    if let Err(error) = heartbeat_self.send_heartbeat_once().await {
                        warn!(
                            kind = "native_webrtc.heartbeat.stopped",
                            session_id = %heartbeat_self.session_id,
                            role = ?heartbeat_self.role,
                            error = %error,
                            "stopping handshake heartbeat loop"
                        );
                        break;
                    }
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
        data_channel: &Arc<RTCDataChannel>,
        payload: &[u8],
    ) -> Result<()> {
        if payload.len() > MAX_FRAMED_PAYLOAD_BYTES {
            bail!("payload too large for framed data channel send");
        }
        let mut framed = Vec::with_capacity(4 + payload.len());
        framed.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        framed.extend_from_slice(payload);
        data_channel
            .send(&Bytes::from(framed))
            .await
            .map_err(|error| anyhow!("failed to send framed data channel payload: {error}"))?;
        Ok(())
    }

    async fn send_application_payload(&self, payload: &[u8]) -> Result<()> {
        let outbound = {
            let state = self.state.lock().await;
            let handshake = state
                .handshake
                .as_ref()
                .ok_or_else(|| anyhow!("native handshake missing"))?;
            handshake.build_application_frame(payload)?
        };
        let data_channel = self
            .data_channel
            .lock()
            .await
            .clone()
            .ok_or_else(|| anyhow!("data channel is not attached"))?;
        self.send_framed_payload(&data_channel, &outbound).await
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

fn build_ice_servers(turn_credentials: Option<&TurnCredentials>) -> Vec<RTCIceServer> {
    match turn_credentials {
        Some(credentials) if !credentials.uris.is_empty() => vec![RTCIceServer {
            urls: credentials.uris.clone(),
            username: credentials.username.clone(),
            credential: credentials.password.clone(),
        }],
        _ => Vec::new(),
    }
}

fn now_unix_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or_default()
}

fn unwrap_traffic_padding_if_needed(data: &[u8]) -> Vec<u8> {
    const TRAFFIC_PADDING_MAGIC: &[u8; 4] = b"SBP2";
    if data.len() < 8 || &data[..4] != TRAFFIC_PADDING_MAGIC {
        return data.to_vec();
    }
    let actual_len = u32::from_be_bytes([data[4], data[5], data[6], data[7]]) as usize;
    if actual_len > data.len().saturating_sub(8) {
        return data.to_vec();
    }
    data[8..(8 + actual_len)].to_vec()
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use anyhow::Result;

    use super::*;
    use crate::{
        CryptoSuite, PqcInitiatorConfig, PqcResponderConfig, ProtocolIdentityBinding,
        RustPqcIdentityMaterial,
    };

    async fn pump_events(
        initiator: &mut NativeWebRtcSession,
        responder: &mut NativeWebRtcSession,
        min_ready: usize,
        min_handshake: usize,
    ) -> Result<Vec<NativeWebRtcEvent>> {
        let mut observed = Vec::new();
        let mut ready_count = 0usize;
        let mut handshake_count = 0usize;

        for _ in 0..256 {
            tokio::select! {
                event = initiator.next_event() => {
                    if let Some(event) = event {
                        match &event {
                            NativeWebRtcEvent::SignalingEnvelope(envelope) => responder.handle_signaling_envelope(envelope).await?,
                            NativeWebRtcEvent::TransportReady => {
                                ready_count += 1;
                                observed.push(event);
                            }
                            NativeWebRtcEvent::HandshakeComplete { .. } => {
                                handshake_count += 1;
                                observed.push(event);
                            }
                            NativeWebRtcEvent::ApplicationPayload { .. } => observed.push(event),
                            NativeWebRtcEvent::Keepalive { .. } => {}
                            NativeWebRtcEvent::TransportDisconnected { .. } => observed.push(event),
                        }
                    }
                }
                event = responder.next_event() => {
                    if let Some(event) = event {
                        match &event {
                            NativeWebRtcEvent::SignalingEnvelope(envelope) => initiator.handle_signaling_envelope(envelope).await?,
                            NativeWebRtcEvent::TransportReady => {
                                ready_count += 1;
                                observed.push(event);
                            }
                            NativeWebRtcEvent::HandshakeComplete { .. } => {
                                handshake_count += 1;
                                observed.push(event);
                            }
                            NativeWebRtcEvent::ApplicationPayload { .. } => observed.push(event),
                            NativeWebRtcEvent::Keepalive { .. } => {}
                            NativeWebRtcEvent::TransportDisconnected { .. } => observed.push(event),
                        }
                    }
                }
                _ = tokio::time::sleep(Duration::from_millis(50)) => {}
            }

            if ready_count >= min_ready && handshake_count >= min_handshake {
                break;
            }
        }

        Ok(observed)
    }

    #[tokio::test]
    async fn native_webrtc_marks_ready_from_real_data_channel_open_without_faking_handshake()
    -> Result<()> {
        let mut initiator = NativeWebRtcSession::new(NativeWebRtcConfig {
            session_id: "native-test".to_owned(),
            local_device_id: "device-a".to_owned(),
            role: RuntimeSessionRole::Initiator,
            turn_credentials: None,
            classic_initiator: None,
            pqc_initiator: None,
            pqc_responder: None,
        })
        .await?;
        let mut responder = NativeWebRtcSession::new(NativeWebRtcConfig {
            session_id: "native-test".to_owned(),
            local_device_id: "device-b".to_owned(),
            role: RuntimeSessionRole::Responder,
            turn_credentials: None,
            classic_initiator: None,
            pqc_initiator: None,
            pqc_responder: None,
        })
        .await?;

        initiator.start().await?;
        responder.start().await?;
        initiator.notify_remote_join("device-b").await?;

        let observed = timeout(
            Duration::from_secs(15),
            pump_events(&mut initiator, &mut responder, 2, 0),
        )
        .await
        .map_err(|_| anyhow!("native_webrtc_test_timeout"))??;

        let ready_count = observed
            .iter()
            .filter(|event| matches!(event, NativeWebRtcEvent::TransportReady))
            .count();
        let handshake_count = observed
            .iter()
            .filter(|event| matches!(event, NativeWebRtcEvent::HandshakeComplete { .. }))
            .count();

        assert_eq!(ready_count, 2);
        assert_eq!(handshake_count, 0);
        assert!(
            observed
                .iter()
                .all(|event| { !matches!(event, NativeWebRtcEvent::TransportDisconnected { .. }) })
        );

        initiator.close().await?;
        responder.close().await?;
        Ok(())
    }

    #[tokio::test]
    async fn native_webrtc_completes_rust_to_rust_pqc_handshake() -> Result<()> {
        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;
        let mut initiator = NativeWebRtcSession::new(NativeWebRtcConfig {
            session_id: "native-pqc-test".to_owned(),
            local_device_id: "device-a".to_owned(),
            role: RuntimeSessionRole::Initiator,
            turn_credentials: None,
            classic_initiator: None,
            pqc_initiator: Some(PqcInitiatorConfig {
                local_binding: ProtocolIdentityBinding::new(
                    "device-1234567890abcd",
                    initiator_identity.signing_algorithm,
                    initiator_identity.signing_public_key.clone(),
                    None,
                )?,
                signing_secret_key: initiator_identity.signing_secret_key.clone(),
                local_device_name: Some("Rust PQC Initiator".to_owned()),
                preferred_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
                peer_kem_public_keys: BTreeMap::from([
                    (
                        CryptoSuite::XWING_MLDSA,
                        responder_identity.xwing_public_key.clone(),
                    ),
                    (
                        CryptoSuite::MLKEM768_MLDSA65,
                        responder_identity.mlkem768_public_key.clone(),
                    ),
                ]),
            }),
            pqc_responder: None,
        })
        .await?;
        let mut responder = NativeWebRtcSession::new(NativeWebRtcConfig {
            session_id: "native-pqc-test".to_owned(),
            local_device_id: "device-b".to_owned(),
            role: RuntimeSessionRole::Responder,
            turn_credentials: None,
            classic_initiator: None,
            pqc_initiator: None,
            pqc_responder: Some(PqcResponderConfig {
                local_binding: ProtocolIdentityBinding::new(
                    "device-fedcba0987654321",
                    responder_identity.signing_algorithm,
                    responder_identity.signing_public_key.clone(),
                    None,
                )?,
                local_device_name: Some("Rust PQC Responder".to_owned()),
                identity: responder_identity,
                supported_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
            }),
        })
        .await?;

        initiator.start().await?;
        responder.start().await?;
        initiator.notify_remote_join("device-b").await?;

        let observed = timeout(
            Duration::from_secs(20),
            pump_events(&mut initiator, &mut responder, 2, 2),
        )
        .await
        .map_err(|_| anyhow!("native_webrtc_pqc_test_timeout"))??;

        let ready_count = observed
            .iter()
            .filter(|event| matches!(event, NativeWebRtcEvent::TransportReady))
            .count();
        let handshake_events = observed
            .iter()
            .filter_map(|event| match event {
                NativeWebRtcEvent::HandshakeComplete { negotiated_suite } => {
                    Some(negotiated_suite.as_str())
                }
                _ => None,
            })
            .collect::<Vec<_>>();

        assert_eq!(ready_count, 2);
        assert_eq!(handshake_events.len(), 2);
        assert!(
            handshake_events
                .iter()
                .all(|suite| { *suite == "X-Wing" || *suite == "ML-KEM-768" })
        );
        assert!(
            observed
                .iter()
                .all(|event| !matches!(event, NativeWebRtcEvent::TransportDisconnected { .. }))
        );

        initiator.close().await?;
        responder.close().await?;
        Ok(())
    }

    #[tokio::test]
    async fn native_webrtc_delivers_application_payload_after_pqc_handshake() -> Result<()> {
        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;
        let mut initiator = NativeWebRtcSession::new(NativeWebRtcConfig {
            session_id: "native-app-payload-test".to_owned(),
            local_device_id: "device-a".to_owned(),
            role: RuntimeSessionRole::Initiator,
            turn_credentials: None,
            classic_initiator: None,
            pqc_initiator: Some(PqcInitiatorConfig {
                local_binding: ProtocolIdentityBinding::new(
                    "device-1234567890abcd",
                    initiator_identity.signing_algorithm,
                    initiator_identity.signing_public_key.clone(),
                    None,
                )?,
                signing_secret_key: initiator_identity.signing_secret_key.clone(),
                local_device_name: Some("Rust PQC Initiator".to_owned()),
                preferred_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
                peer_kem_public_keys: BTreeMap::from([
                    (
                        CryptoSuite::XWING_MLDSA,
                        responder_identity.xwing_public_key.clone(),
                    ),
                    (
                        CryptoSuite::MLKEM768_MLDSA65,
                        responder_identity.mlkem768_public_key.clone(),
                    ),
                ]),
            }),
            pqc_responder: None,
        })
        .await?;
        let mut responder = NativeWebRtcSession::new(NativeWebRtcConfig {
            session_id: "native-app-payload-test".to_owned(),
            local_device_id: "device-b".to_owned(),
            role: RuntimeSessionRole::Responder,
            turn_credentials: None,
            classic_initiator: None,
            pqc_initiator: None,
            pqc_responder: Some(PqcResponderConfig {
                local_binding: ProtocolIdentityBinding::new(
                    "device-fedcba0987654321",
                    responder_identity.signing_algorithm,
                    responder_identity.signing_public_key.clone(),
                    None,
                )?,
                local_device_name: Some("Rust PQC Responder".to_owned()),
                identity: responder_identity,
                supported_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
            }),
        })
        .await?;

        initiator.start().await?;
        responder.start().await?;
        initiator.notify_remote_join("device-b").await?;

        let _ = timeout(
            Duration::from_secs(20),
            pump_events(&mut initiator, &mut responder, 2, 2),
        )
        .await
        .map_err(|_| anyhow!("native_webrtc_app_payload_test_timeout"))??;

        initiator
            .handle()
            .send_application_payload(br#"{"op":"ping_file_channel"}"#)
            .await?;

        let observed = timeout(Duration::from_secs(10), async {
            loop {
                tokio::select! {
                    event = initiator.next_event() => {
                        if let Some(NativeWebRtcEvent::SignalingEnvelope(envelope)) = event {
                            responder.handle_signaling_envelope(&envelope).await?;
                        }
                    }
                    event = responder.next_event() => {
                        if let Some(event) = event {
                            match event {
                                NativeWebRtcEvent::SignalingEnvelope(envelope) => {
                                    initiator.handle_signaling_envelope(&envelope).await?;
                                }
                                NativeWebRtcEvent::ApplicationPayload { payload } => {
                                    return Ok::<Vec<u8>, anyhow::Error>(payload);
                                }
                                NativeWebRtcEvent::TransportReady
                                | NativeWebRtcEvent::HandshakeComplete { .. }
                                | NativeWebRtcEvent::Keepalive { .. }
                                | NativeWebRtcEvent::TransportDisconnected { .. } => {}
                            }
                        }
                    }
                    _ = tokio::time::sleep(Duration::from_millis(50)) => {}
                }
            }
        })
        .await
        .map_err(|_| anyhow!("timed out waiting for application payload"))??;

        assert_eq!(observed, br#"{"op":"ping_file_channel"}"#.to_vec());

        initiator.close().await?;
        responder.close().await?;
        Ok(())
    }
}
