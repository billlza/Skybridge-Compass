use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use bytes::BytesMut;
use rtc::peer_connection::transport::RTCIceCandidateType;
use rtc::statistics::StatsSelector;
use rtc::statistics::report::RTCStatsReportEntry;
use rtc::statistics::stats::ice_candidate_pair::RTCStatsIceCandidatePairState;
use time::OffsetDateTime;
use tokio::sync::{Mutex, mpsc};
use tokio::time::{Instant, MissedTickBehavior, timeout};
use tracing::{debug, info, warn};
use webrtc::data_channel::{DataChannel, DataChannelEvent, RTCDataChannelMessage};
use webrtc::peer_connection::{
    MediaEngine, PeerConnection, PeerConnectionBuilder, PeerConnectionEventHandler,
    RTCConfigurationBuilder, RTCIceCandidateInit, RTCIceGatheringState, RTCPeerConnectionState,
    RTCSessionDescription,
};

use crate::{
    ClassicInitiatorConfig, ClassicResponderConfig, ClassicSessionKeys,
    CrossNetworkFileTransferMessageV1, PqcInitiatorConfig, PqcResponderConfig,
    RuntimeSessionKeepaliveKind, RuntimeSessionRole, TurnCredentials, WebRtcJoinBootstrap,
    WebRtcMessageType, WebRtcSignalingEnvelope, WebRtcSignalingPayload,
};

mod app_secure;
mod handshake;
mod support;
#[cfg(test)]
mod tests;

use app_secure::{
    OpenedPayload, ReplayWindow, WebRtcAppSecurePacketType, open as open_secure_app_payload,
    seal as seal_secure_app_payload, unwrap_traffic_padding,
};
use handshake::NativeSessionHandshake;
use support::{build_ice_servers, native_webrtc_udp_bind_addrs, now_unix_seconds};

const CONTROL_CHANNEL_LABEL: &str = "skybridge";
const MAX_FRAMED_PAYLOAD_BYTES: usize = 8_000_000;
const MAX_INBOUND_FRAMED_BUFFER_BYTES: usize = MAX_FRAMED_PAYLOAD_BYTES + 4;
const MAX_INBOUND_FRAMES_PER_DATA_MESSAGE: usize = 256;
const DATA_CHANNEL_FRAME_CHUNK_BYTES: usize = 8 * 1024;
const MAX_SIGNALING_SDP_BYTES: usize = 256 * 1024;
const MAX_ICE_CANDIDATE_BYTES: usize = 4 * 1024;
const MAX_ICE_SDP_MID_BYTES: usize = 256;
const MAX_REMOTE_ICE_CANDIDATES: usize = 256;
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(2);
const HEARTBEAT_EVERY_TICKS: u64 = 3;
const PONG_TIMEOUT: Duration = Duration::from_secs(6);
// Keep a blocked channel write inside the liveness budget so the keepalive
// monitor can fail the transport before it remains observably established.
const DATA_CHANNEL_SEND_TIMEOUT: Duration = Duration::from_secs(5);
// Complete and release setup state before the agent's 10-second incarnation
// effect deadline so replacement can acquire its authority locks deterministically.
const NATIVE_WEBRTC_SETUP_TIMEOUT: Duration = Duration::from_secs(8);
const SELECTED_ICE_ROUTE_OBSERVATION_TIMEOUT: Duration = Duration::from_secs(5);
const SELECTED_ICE_ROUTE_POLL_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, Copy)]
struct OutstandingPing {
    id: u64,
    sent_at: Instant,
}

#[derive(Debug)]
struct NativeAppSecureRuntime {
    session_keys: ClassicSessionKeys,
    last_send_counter: u64,
    receive_replay_window: ReplayWindow,
}

impl NativeAppSecureRuntime {
    fn new(session_keys: ClassicSessionKeys) -> Self {
        Self {
            session_keys,
            last_send_counter: 0,
            receive_replay_window: ReplayWindow::default(),
        }
    }

    fn seal(
        &mut self,
        role: RuntimeSessionRole,
        packet_type: WebRtcAppSecurePacketType,
        plaintext: &[u8],
    ) -> Result<Vec<u8>> {
        let counter = self
            .last_send_counter
            .checked_add(1)
            .ok_or_else(|| anyhow!("WebRTC secure envelope counter exhausted"))?;
        // Reserve before encryption/send. A later failure must never reuse this
        // nonce/counter lane.
        self.last_send_counter = counter;
        Ok(seal_secure_app_payload(
            plaintext,
            &self.session_keys,
            role,
            packet_type,
            counter,
        )?)
    }

    fn open_and_record(
        &mut self,
        role: RuntimeSessionRole,
        packet: &[u8],
    ) -> Result<OpenedPayload> {
        let unwrapped = unwrap_traffic_padding(packet, MAX_FRAMED_PAYLOAD_BYTES)?;
        let opened = open_secure_app_payload(
            &unwrapped,
            &self.session_keys,
            role,
            &[
                WebRtcAppSecurePacketType::AppControl,
                WebRtcAppSecurePacketType::FileTransfer,
            ],
        )?;
        // Authentication and all binding checks completed above. Recording now,
        // while NativeWebRtcState remains locked, makes replay admission atomic.
        self.receive_replay_window.validate_and_record(&opened)?;
        Ok(opened)
    }
}

#[derive(Debug)]
enum NativeAuthenticatedAppPayload {
    AppControl(crate::handshake_app_frame::AppControlMessage),
    FileTransfer(Box<CrossNetworkFileTransferMessageV1>),
}

fn decode_authenticated_app_payload(
    opened: OpenedPayload,
) -> Result<NativeAuthenticatedAppPayload> {
    match opened.packet_type {
        WebRtcAppSecurePacketType::AppControl => Ok(NativeAuthenticatedAppPayload::AppControl(
            crate::handshake_app_frame::decode_app_control_message(&opened.payload)?,
        )),
        WebRtcAppSecurePacketType::FileTransfer => {
            Ok(NativeAuthenticatedAppPayload::FileTransfer(Box::new(
                crate::decode_cross_network_file_transfer_message_v1(&opened.payload)?,
            )))
        }
        packet_type => bail!(
            "unsupported authenticated packet type after admission: {}",
            packet_type as u8
        ),
    }
}

#[derive(Debug, Clone)]
pub struct NativeWebRtcConfig {
    pub session_id: String,
    pub local_device_id: String,
    pub role: RuntimeSessionRole,
    pub turn_credentials: Option<TurnCredentials>,
    pub classic_initiator: Option<ClassicInitiatorConfig>,
    pub classic_responder: Option<ClassicResponderConfig>,
    pub pqc_initiator: Option<PqcInitiatorConfig>,
    pub pqc_responder: Option<PqcResponderConfig>,
}

/// Optional services explicitly backed by consumers attached to this native
/// session. The default advertises nothing; callers must configure this before
/// [`NativeWebRtcSession::start`] once the corresponding consumer is ready.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NativeWebRtcHeartbeatAdvertisement {
    pub capabilities: Option<Vec<String>>,
    pub file_transfer_port: Option<u16>,
    pub remote_control_port: Option<u16>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum NativeWebRtcEvent {
    SignalingEnvelope(WebRtcSignalingEnvelope),
    TransportReady,
    HandshakeComplete {
        negotiated_suite: String,
        peer_protocol_public_key_fingerprint: String,
    },
    Keepalive {
        kind: RuntimeSessionKeepaliveKind,
        ping_id: Option<u64>,
    },
    AuthenticatedPeerHeartbeat {
        payload: Box<crate::HeartbeatPayload>,
        sbwc_counter: u64,
        received_at_unix_seconds: f64,
    },
    SelectedIceRoute(Box<crate::RuntimeSelectedIceRouteObservation>),
    TransportDisconnected {
        reason: Option<String>,
    },
    /// A decoded inbound cross-network file-transfer message received over the
    /// encrypted control channel after the handshake completed.
    InboundFileFrame(Box<CrossNetworkFileTransferMessageV1>),
}

/// Whether an inbound signaling envelope was semantically accepted by the
/// native WebRTC state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NativeWebRtcSignalingDisposition {
    AcceptedWithPeerBinding,
    AcceptedWithoutPeerBinding,
    Ignored,
}

#[derive(Debug, Default)]
struct NativeWebRtcState {
    offer_started: bool,
    answer_sent: bool,
    remote_description_set: bool,
    transport_ready_emitted: bool,
    transport_disconnected_emitted: bool,
    handshake_complete_emitted: bool,
    inbound_framed_buffer: BytesMut,
    handshake: Option<NativeSessionHandshake>,
    pending_pqc_initiator: Option<PqcInitiatorConfig>,
    remote_join_bootstrap: Option<WebRtcJoinBootstrap>,
    remote_join_observed: bool,
    requires_pqc_join_bootstrap: bool,
    app_secure_runtime: Option<NativeAppSecureRuntime>,
    remote_device_id: Option<String>,
    heartbeat_task_started: bool,
    heartbeat_advertisement_frozen: bool,
    selected_ice_route_task_started: bool,
    selected_ice_route_emitted: bool,
    next_ping_id: u64,
    outstanding_ping: Option<OutstandingPing>,
    remote_candidate_count: usize,
    pending_remote_candidates: Vec<RTCIceCandidateInit>,
}

struct NativeWebRtcInner {
    session_id: String,
    local_device_id: String,
    local_device_name: Option<String>,
    heartbeat_advertisement: Mutex<NativeWebRtcHeartbeatAdvertisement>,
    role: RuntimeSessionRole,
    peer: Arc<dyn PeerConnection>,
    events_tx: mpsc::Sender<NativeWebRtcEvent>,
    data_channel: Mutex<Option<Arc<dyn DataChannel>>>,
    outbound_frame_gate: Mutex<()>,
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

fn validate_text_size(name: &str, value: &str, maximum_bytes: usize) -> Result<()> {
    if value.len() > maximum_bytes {
        bail!(
            "{name} exceeds byte limit: {} > {maximum_bytes}",
            value.len()
        );
    }
    Ok(())
}

fn ice_candidate_type_label(candidate_type: RTCIceCandidateType) -> Option<&'static str> {
    match candidate_type {
        RTCIceCandidateType::Host => Some("host"),
        RTCIceCandidateType::Srflx => Some("srflx"),
        RTCIceCandidateType::Prflx => Some("prflx"),
        RTCIceCandidateType::Relay => Some("relay"),
        RTCIceCandidateType::Unspecified => None,
    }
}

fn validate_signaling_payload_bounds(payload: &WebRtcSignalingPayload) -> Result<()> {
    if let Some(sdp) = payload.sdp.as_deref() {
        validate_text_size("signaling SDP", sdp, MAX_SIGNALING_SDP_BYTES)?;
    }
    if let Some(candidate) = payload.candidate.as_deref() {
        validate_text_size(
            "signaling ICE candidate",
            candidate,
            MAX_ICE_CANDIDATE_BYTES,
        )?;
    }
    if let Some(sdp_mid) = payload.sdp_mid.as_deref() {
        validate_text_size("signaling ICE SDP mid", sdp_mid, MAX_ICE_SDP_MID_BYTES)?;
    }
    if let Some(sdp_m_line_index) = payload.sdp_m_line_index {
        u16::try_from(sdp_m_line_index)
            .map_err(|_| anyhow!("signaling ICE SDP m-line index is out of range"))?;
    }
    Ok(())
}

async fn close_rejected_data_channel(data_channel: &Arc<dyn DataChannel>) -> Result<()> {
    run_native_setup_with_timeout(
        "rejected_data_channel_close",
        NATIVE_WEBRTC_SETUP_TIMEOUT,
        async { Ok(data_channel.close().await?) },
    )
    .await
    .map_err(|error| anyhow!("failed to close rejected data channel: {error}"))
}

async fn run_native_setup_with_timeout<T, F>(
    operation: &'static str,
    setup_timeout: Duration,
    setup: F,
) -> Result<T>
where
    F: Future<Output = Result<T>>,
{
    timeout(setup_timeout, setup)
        .await
        .map_err(|_| anyhow!("{operation}_timeout"))?
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
        if state == RTCIceGatheringState::Complete
            && self.gather_complete_tx.send(()).await.is_err()
        {
            warn!(
                kind = "native_webrtc.ice_gathering.receiver_dropped",
                session_id = %self.session_id,
                role = ?self.role,
                "ICE gathering completion receiver was dropped"
            );
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
        ) && self
            .disconnect_tx
            .send(Some(format!("peer_connection_state_{state:?}")))
            .await
            .is_err()
        {
            warn!(
                kind = "native_webrtc.disconnect.receiver_dropped",
                session_id = %self.session_id,
                role = ?self.role,
                "peer connection disconnect receiver was dropped"
            );
        }
    }

    async fn on_data_channel(&self, data_channel: Arc<dyn DataChannel>) {
        info!(
            kind = "native_webrtc.data_channel.discovered",
            session_id = %self.session_id,
            role = ?self.role,
            id = data_channel.id(),
            "received remote-created data channel"
        );
        if let Err(error) = self.data_channel_tx.send(data_channel).await {
            let rejected = error.0;
            warn!(
                kind = "native_webrtc.data_channel.receiver_dropped",
                session_id = %self.session_id,
                role = ?self.role,
                id = rejected.id(),
                "data channel receiver was dropped"
            );
            if let Err(close_error) = rejected.close().await {
                warn!(
                    kind = "native_webrtc.data_channel.reject_close_failed",
                    session_id = %self.session_id,
                    role = ?self.role,
                    id = rejected.id(),
                    error = %close_error,
                    "failed to close unhandled data channel"
                );
            }
        }
    }
}

impl NativeWebRtcSession {
    pub async fn new(config: NativeWebRtcConfig) -> Result<Self> {
        let local_device_name = config
            .classic_initiator
            .as_ref()
            .and_then(|config| config.local_device_name.clone())
            .or_else(|| {
                config
                    .classic_responder
                    .as_ref()
                    .and_then(|config| config.local_device_name.clone())
            })
            .or_else(|| {
                config
                    .pqc_initiator
                    .as_ref()
                    .and_then(|config| config.local_device_name.clone())
            })
            .or_else(|| {
                config
                    .pqc_responder
                    .as_ref()
                    .and_then(|config| config.local_device_name.clone())
            });
        let (handshake, pending_pqc_initiator, requires_pqc_join_bootstrap) = match (
            config.role,
            config.classic_initiator,
            config.classic_responder,
            config.pqc_initiator,
            config.pqc_responder,
        ) {
            (RuntimeSessionRole::Initiator, Some(config), None, None, None) => (
                Some(NativeSessionHandshake::classic_initiator(config)?),
                None,
                false,
            ),
            (RuntimeSessionRole::Initiator, None, None, Some(config), None) => {
                (None, Some(config), true)
            }
            (RuntimeSessionRole::Responder, None, Some(config), None, None) => (
                Some(NativeSessionHandshake::classic_responder(config)?),
                None,
                false,
            ),
            (RuntimeSessionRole::Responder, None, None, None, Some(config)) => (
                Some(NativeSessionHandshake::pqc_responder(config)?),
                None,
                true,
            ),
            (RuntimeSessionRole::Initiator, _, _, _, _) => {
                bail!("native WebRTC initiator requires exactly one initiator handshake config")
            }
            (RuntimeSessionRole::Responder, _, _, _, _) => {
                bail!("native WebRTC responder requires exactly one responder handshake config")
            }
        };
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
        let peer_builder = PeerConnectionBuilder::new()
            .with_configuration(rtc_configuration)
            .with_media_engine(media_engine)
            .with_handler(handler)
            .with_udp_addrs(udp_bind_addrs);
        let peer = Arc::new(
            run_native_setup_with_timeout(
                "native_peer_connection_build",
                NATIVE_WEBRTC_SETUP_TIMEOUT,
                async { Ok(peer_builder.build().await?) },
            )
            .await?,
        ) as Arc<dyn PeerConnection>;

        let inner = Arc::new(NativeWebRtcInner {
            session_id: config.session_id,
            local_device_id: config.local_device_id,
            local_device_name,
            heartbeat_advertisement: Mutex::new(NativeWebRtcHeartbeatAdvertisement::default()),
            role: config.role,
            peer,
            events_tx,
            data_channel: Mutex::new(None),
            outbound_frame_gate: Mutex::new(()),
            gather_complete_rx: Mutex::new(gather_complete_rx),
            state: Mutex::new(NativeWebRtcState {
                handshake,
                pending_pqc_initiator,
                requires_pqc_join_bootstrap,
                ..NativeWebRtcState::default()
            }),
        });
        let remote_channel_inner = Arc::clone(&inner);
        tokio::spawn(async move {
            while let Some(data_channel) = data_channel_rx.recv().await {
                if let Err(error) = remote_channel_inner.attach_data_channel(data_channel).await {
                    warn!(
                        kind = "native_webrtc.data_channel.attach_failed",
                        session_id = %remote_channel_inner.session_id,
                        role = ?remote_channel_inner.role,
                        error = %error,
                        "failed to attach remote-created data channel"
                    );
                    if let Err(emit_error) = remote_channel_inner
                        .emit_transport_disconnected(Some(format!(
                            "data_channel_attach_failed:{error}"
                        )))
                        .await
                    {
                        warn!(
                            kind = "native_webrtc.transport.disconnect_event_failed",
                            session_id = %remote_channel_inner.session_id,
                            role = ?remote_channel_inner.role,
                            error = %emit_error,
                            "failed to publish data channel attach failure"
                        );
                    }
                    break;
                }
            }
        });
        let disconnect_inner = Arc::clone(&inner);
        tokio::spawn(async move {
            while let Some(reason) = disconnect_rx.recv().await {
                if let Err(error) = disconnect_inner.emit_transport_disconnected(reason).await {
                    warn!(
                        kind = "native_webrtc.transport.disconnect_event_failed",
                        session_id = %disconnect_inner.session_id,
                        role = ?disconnect_inner.role,
                        error = %error,
                        "failed to publish peer connection disconnect"
                    );
                    break;
                }
            }
        });

        Ok(Self { inner, events_rx })
    }

    pub async fn start(&self) -> Result<()> {
        self.inner.state.lock().await.heartbeat_advertisement_frozen = true;
        if self.inner.role == RuntimeSessionRole::Initiator {
            info!(
                kind = "native_webrtc.data_channel.create",
                session_id = %self.inner.session_id,
                role = ?self.inner.role,
                label = CONTROL_CHANNEL_LABEL,
                "creating native WebRTC control channel"
            );
            run_native_setup_with_timeout(
                "native_control_channel_setup",
                NATIVE_WEBRTC_SETUP_TIMEOUT,
                async {
                    let data_channel = self
                        .inner
                        .peer
                        .create_data_channel(CONTROL_CHANNEL_LABEL, None)
                        .await?;
                    self.inner.attach_data_channel(data_channel).await
                },
            )
            .await?;
        }
        Ok(())
    }

    /// Configures the authenticated heartbeat advertisement before transport
    /// startup. This is intentionally separate from core protocol defaults so
    /// a raw native session with no service consumer advertises no capability.
    pub async fn configure_heartbeat_advertisement(
        &self,
        advertisement: NativeWebRtcHeartbeatAdvertisement,
    ) -> Result<()> {
        let state = self.inner.state.lock().await;
        if state.heartbeat_advertisement_frozen {
            bail!("native heartbeat advertisement is frozen after session start");
        }
        crate::handshake_app_frame::build_heartbeat_plaintext_with_advertisement(
            &self.inner.local_device_id,
            self.inner.local_device_name.as_deref(),
            advertisement.capabilities.as_deref(),
            advertisement.file_transfer_port,
            advertisement.remote_control_port,
        )?;
        *self.inner.heartbeat_advertisement.lock().await = advertisement;
        drop(state);
        Ok(())
    }

    pub async fn notify_remote_join(&self, remote_device_id: &str) -> Result<()> {
        self.inner.bind_remote_device_id(remote_device_id).await?;
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
    ) -> Result<NativeWebRtcSignalingDisposition> {
        if envelope.session_id != self.inner.session_id
            || envelope.from == self.inner.local_device_id
        {
            return Ok(NativeWebRtcSignalingDisposition::Ignored);
        }
        let validated_join_bootstrap = if let Some(payload) = envelope.payload.as_ref() {
            validate_signaling_payload_bounds(payload)?;
            payload.validate_for_message_type(envelope.kind, &envelope.from)?
        } else {
            None
        };

        let disposition = match envelope.kind {
            WebRtcMessageType::Join => {
                self.inner.bind_remote_device_id(&envelope.from).await?;
                self.inner
                    .install_remote_join_bootstrap(validated_join_bootstrap)
                    .await?;
                self.notify_remote_join(&envelope.from).await?;
                NativeWebRtcSignalingDisposition::AcceptedWithPeerBinding
            }
            WebRtcMessageType::Offer => {
                let Some(sdp) = envelope
                    .payload
                    .as_ref()
                    .and_then(|payload| payload.sdp.clone())
                else {
                    bail!("inbound signaling offer is missing its SDP payload");
                };
                if sdp.trim().is_empty() {
                    bail!("inbound signaling offer has an empty SDP payload");
                }
                validate_text_size("inbound signaling offer SDP", &sdp, MAX_SIGNALING_SDP_BYTES)?;
                self.inner.bind_remote_device_id(&envelope.from).await?;
                self.inner.apply_remote_offer(sdp).await?;
                NativeWebRtcSignalingDisposition::AcceptedWithPeerBinding
            }
            WebRtcMessageType::Answer => {
                let Some(sdp) = envelope
                    .payload
                    .as_ref()
                    .and_then(|payload| payload.sdp.clone())
                else {
                    bail!("inbound signaling answer is missing its SDP payload");
                };
                if sdp.trim().is_empty() {
                    bail!("inbound signaling answer has an empty SDP payload");
                }
                validate_text_size(
                    "inbound signaling answer SDP",
                    &sdp,
                    MAX_SIGNALING_SDP_BYTES,
                )?;
                self.inner.bind_remote_device_id(&envelope.from).await?;
                self.inner.apply_remote_answer(sdp).await?;
                NativeWebRtcSignalingDisposition::AcceptedWithPeerBinding
            }
            WebRtcMessageType::IceCandidate => {
                let payload = envelope
                    .payload
                    .as_ref()
                    .ok_or_else(|| anyhow!("inbound ICE signal is missing its payload"))?;
                if payload
                    .candidate
                    .as_deref()
                    .is_none_or(|candidate| candidate.trim().is_empty())
                {
                    bail!("inbound ICE signal is missing its candidate");
                }
                if payload.sdp_mid.as_deref().is_some_and(str::is_empty) {
                    bail!("inbound ICE candidate has an empty SDP mid");
                }
                self.inner.bind_remote_device_id(&envelope.from).await?;
                self.inner.apply_remote_candidate(payload).await?;
                NativeWebRtcSignalingDisposition::AcceptedWithPeerBinding
            }
            WebRtcMessageType::Leave => {
                self.inner.bind_remote_device_id(&envelope.from).await?;
                self.inner
                    .emit_transport_disconnected(Some("remote_leave".to_owned()))
                    .await?;
                NativeWebRtcSignalingDisposition::AcceptedWithoutPeerBinding
            }
        };

        Ok(disposition)
    }

    pub async fn next_event(&mut self) -> Option<NativeWebRtcEvent> {
        self.events_rx.recv().await
    }

    pub fn try_next_event(&mut self) -> Option<NativeWebRtcEvent> {
        self.events_rx.try_recv().ok()
    }

    pub async fn close(&self) -> Result<()> {
        let peer_close_result = run_native_setup_with_timeout(
            "native_peer_connection_close",
            NATIVE_WEBRTC_SETUP_TIMEOUT,
            async { Ok(self.inner.peer.close().await?) },
        )
        .await;
        let event_result = self
            .inner
            .emit_transport_disconnected(Some("local_close".to_owned()))
            .await;
        peer_close_result?;
        event_result
    }

    /// A cheap, cloneable handle for sending file app-frames concurrently while
    /// the session's event loop keeps draining inbound events and keepalives.
    pub fn sender_handle(&self) -> NativeWebRtcSender {
        NativeWebRtcSender {
            inner: Arc::clone(&self.inner),
        }
    }
}

/// Cloneable sender for cross-network file-transfer messages over an established session.
#[derive(Clone)]
pub struct NativeWebRtcSender {
    inner: Arc<NativeWebRtcInner>,
}

impl NativeWebRtcSender {
    /// Encrypt and send one canonical cross-network file-transfer v1 JSON
    /// plaintext. Fails closed if the message is invalid, the session is not
    /// yet established, or the data channel has gone away.
    pub async fn send_file_app_frame(&self, plaintext: &[u8]) -> Result<()> {
        self.inner.send_file_app_frame(plaintext).await
    }
}

impl NativeWebRtcInner {
    async fn bind_remote_device_id(&self, remote_device_id: &str) -> Result<()> {
        if remote_device_id.is_empty()
            || remote_device_id.len() > 1024
            || remote_device_id.chars().any(char::is_control)
        {
            bail!("invalid remote signaling device id");
        }
        let mut state = self.state.lock().await;
        match state.remote_device_id.as_deref() {
            Some(expected) if expected != remote_device_id => {
                bail!(
                    "remote signaling device mismatch: expected={expected} actual={remote_device_id}"
                )
            }
            Some(_) => Ok(()),
            None => {
                state.remote_device_id = Some(remote_device_id.to_owned());
                Ok(())
            }
        }
    }

    async fn install_remote_join_bootstrap(
        &self,
        bootstrap: Option<WebRtcJoinBootstrap>,
    ) -> Result<()> {
        let mut state = self.state.lock().await;
        if state.remote_join_observed {
            if state.remote_join_bootstrap.as_ref() == bootstrap.as_ref() {
                return Ok(());
            }
            bail!("remote signaling Join bootstrap changed within one session incarnation");
        }

        if !state.requires_pqc_join_bootstrap {
            if let Some(bootstrap) = bootstrap.as_ref()
                && bootstrap.protocol_signing_algorithm != crate::ProtocolSigningAlgorithm::Ed25519
            {
                bail!("classic native handshake cannot accept a PQC Join bootstrap");
            }
            state.remote_join_bootstrap = bootstrap;
            state.remote_join_observed = true;
            return Ok(());
        }

        let bootstrap = bootstrap.ok_or_else(|| {
            anyhow!("PQC native handshake requires a complete remote Join bootstrap")
        })?;
        if !bootstrap.protocol_signing_algorithm.is_ml_dsa() {
            bail!("PQC native handshake requires an ML-DSA remote Join identity");
        }

        if let Some(mut config) = state.pending_pqc_initiator.clone() {
            let advertised_keys = bootstrap
                .kem_public_keys
                .iter()
                .map(|key| {
                    (
                        crate::CryptoSuite::from_wire_id(key.suite_wire_id),
                        key.public_key.clone(),
                    )
                })
                .collect::<std::collections::BTreeMap<_, _>>();
            for (suite, pinned_key) in &config.peer_kem_public_keys {
                let advertised_key = advertised_keys
                    .get(suite)
                    .ok_or_else(|| anyhow!("remote Join omitted pinned KEM suite {suite}"))?;
                if advertised_key != pinned_key {
                    bail!(
                        "remote Join KEM public key does not match the configured pin for {suite}"
                    );
                }
            }
            if !config
                .preferred_suites
                .iter()
                .any(|suite| advertised_keys.contains_key(suite))
            {
                bail!("remote Join has no mutually supported preferred PQC KEM suite");
            }
            config.peer_kem_public_keys = advertised_keys;
            let handshake = NativeSessionHandshake::pqc_initiator(config)?;
            state.handshake = Some(handshake);
            state.pending_pqc_initiator = None;
        } else if state.handshake.is_none() {
            bail!("PQC native handshake has no pending initiator or responder state");
        }

        state.remote_join_bootstrap = Some(bootstrap);
        state.remote_join_observed = true;
        Ok(())
    }

    async fn attach_data_channel(
        self: &Arc<Self>,
        data_channel: Arc<dyn DataChannel>,
    ) -> Result<()> {
        let label = match run_native_setup_with_timeout(
            "data_channel_label_read",
            NATIVE_WEBRTC_SETUP_TIMEOUT,
            async { Ok(data_channel.label().await?) },
        )
        .await
        {
            Ok(label) => label,
            Err(error) => {
                close_rejected_data_channel(&data_channel).await?;
                bail!("data_channel_label_read_failed:{error}");
            }
        };
        // The WebRTC implementation can expose an empty label before `OnOpen`.
        // Accept that state only provisionally; `OnOpen` and every message path
        // require the exact control-channel label before processing any payload.
        if !label.is_empty() && label != CONTROL_CHANNEL_LABEL {
            close_rejected_data_channel(&data_channel).await?;
            bail!("unexpected_data_channel_label:{label};expected:{CONTROL_CHANNEL_LABEL}");
        }
        {
            let mut slot = self.data_channel.lock().await;
            if let Some(current) = slot.as_ref() {
                if current.id() == data_channel.id() {
                    debug!(
                        kind = "native_webrtc.data_channel.already_attached",
                        session_id = %self.session_id,
                        role = ?self.role,
                        id = data_channel.id(),
                        "ignoring duplicate callback for the already attached control channel"
                    );
                    return Ok(());
                }
                drop(slot);
                close_rejected_data_channel(&data_channel).await?;
                bail!("duplicate_control_data_channel");
            }
            *slot = Some(Arc::clone(&data_channel));
        }
        info!(
            kind = "native_webrtc.data_channel.attached",
            session_id = %self.session_id,
            role = ?self.role,
            label = %label,
            id = data_channel.id(),
            "attaching native WebRTC data channel callbacks"
        );
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
                            if let Err(emit_error) = channel_self
                                .emit_transport_disconnected(Some(format!(
                                    "data_channel_open_failed:{error}"
                                )))
                                .await
                            {
                                warn!(
                                    kind = "native_webrtc.transport.disconnect_event_failed",
                                    session_id = %channel_self.session_id,
                                    role = ?channel_self.role,
                                    error = %emit_error,
                                    "failed to publish data channel open failure"
                                );
                            }
                            break;
                        }
                    }
                    DataChannelEvent::OnMessage(message) => {
                        let result = async {
                            channel_self
                                .validate_open_control_channel_label(&data_channel)
                                .await?;
                            channel_self.handle_data_channel_message(message).await
                        }
                        .await;
                        if let Err(error) = result {
                            warn!(
                                kind = "native_webrtc.data_channel.message_failed",
                                session_id = %channel_self.session_id,
                                role = ?channel_self.role,
                                error = %error,
                                "failed while handling data channel message"
                            );
                            if let Err(emit_error) = channel_self
                                .emit_transport_disconnected(Some(format!(
                                    "data_channel_message_failed:{error}"
                                )))
                                .await
                            {
                                warn!(
                                    kind = "native_webrtc.transport.disconnect_event_failed",
                                    session_id = %channel_self.session_id,
                                    role = ?channel_self.role,
                                    error = %emit_error,
                                    "failed to publish data channel message failure"
                                );
                            }
                            break;
                        }
                    }
                    DataChannelEvent::OnClose => {
                        info!(
                            kind = "native_webrtc.data_channel.closed",
                            session_id = %channel_self.session_id,
                            role = ?channel_self.role,
                            id = data_channel.id(),
                            "native WebRTC data channel closed"
                        );
                        if channel_self
                            .clear_data_channel_if_current(&data_channel)
                            .await
                            && let Err(error) = channel_self
                                .emit_transport_disconnected(Some("data_channel_closed".to_owned()))
                                .await
                        {
                            warn!(
                                kind = "native_webrtc.transport.disconnect_event_failed",
                                session_id = %channel_self.session_id,
                                role = ?channel_self.role,
                                error = %error,
                                "failed to publish data channel close"
                            );
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
                            && let Err(error) = channel_self
                                .emit_transport_disconnected(Some("data_channel_error".to_owned()))
                                .await
                        {
                            warn!(
                                kind = "native_webrtc.transport.disconnect_event_failed",
                                session_id = %channel_self.session_id,
                                role = ?channel_self.role,
                                error = %error,
                                "failed to publish data channel error"
                            );
                        }
                        break;
                    }
                    DataChannelEvent::OnClosing
                    | DataChannelEvent::OnBufferedAmountLow
                    | DataChannelEvent::OnBufferedAmountHigh => {}
                }
            }
            if channel_self
                .clear_data_channel_if_current(&data_channel)
                .await
                && let Err(error) = channel_self
                    .emit_transport_disconnected(Some("data_channel_event_stream_ended".to_owned()))
                    .await
            {
                warn!(
                    kind = "native_webrtc.transport.disconnect_event_failed",
                    session_id = %channel_self.session_id,
                    role = ?channel_self.role,
                    error = %error,
                    "failed to publish unexpected data channel task exit"
                );
            }
        });
        Ok(())
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

        let result = run_native_setup_with_timeout(
            "native_offer_setup",
            NATIVE_WEBRTC_SETUP_TIMEOUT,
            async {
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
                        ..Default::default()
                    }),
                )
                .await
            },
        )
        .await;

        if result.is_err() {
            let mut state = self.state.lock().await;
            state.offer_started = false;
        }

        result
    }

    async fn apply_remote_offer(&self, sdp: String) -> Result<()> {
        let description = RTCSessionDescription::offer(sdp)?;
        run_native_setup_with_timeout(
            "native_remote_offer_set",
            NATIVE_WEBRTC_SETUP_TIMEOUT,
            async { Ok(self.peer.set_remote_description(description).await?) },
        )
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

        let result = run_native_setup_with_timeout(
            "native_answer_setup",
            NATIVE_WEBRTC_SETUP_TIMEOUT,
            async {
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
                        ..Default::default()
                    }),
                )
                .await
            },
        )
        .await;

        if result.is_err() {
            let mut state = self.state.lock().await;
            state.answer_sent = false;
        }

        result
    }

    async fn wait_for_ice_gathering_complete(&self) -> Result<()> {
        let mut gather_complete_rx = self.gather_complete_rx.lock().await;
        timeout(NATIVE_WEBRTC_SETUP_TIMEOUT, gather_complete_rx.recv())
            .await
            .map_err(|_| anyhow!("ice_gathering_timeout"))?
            .ok_or_else(|| anyhow!("ice_gathering_channel_closed"))?;
        Ok(())
    }

    async fn apply_remote_answer(&self, sdp: String) -> Result<()> {
        let description = RTCSessionDescription::answer(sdp)?;
        run_native_setup_with_timeout(
            "native_remote_answer_set",
            NATIVE_WEBRTC_SETUP_TIMEOUT,
            async { Ok(self.peer.set_remote_description(description).await?) },
        )
        .await?;
        {
            let mut state = self.state.lock().await;
            state.remote_description_set = true;
        }
        self.flush_pending_remote_candidates().await
    }

    async fn apply_remote_candidate(&self, payload: &WebRtcSignalingPayload) -> Result<()> {
        let Some(candidate) = payload.candidate.clone() else {
            bail!("inbound ICE signal is missing its candidate");
        };
        if candidate.trim().is_empty() {
            bail!("inbound ICE signal has an empty candidate");
        }
        validate_text_size("inbound ICE candidate", &candidate, MAX_ICE_CANDIDATE_BYTES)?;
        if let Some(sdp_mid) = payload.sdp_mid.as_deref() {
            if sdp_mid.is_empty() {
                bail!("inbound ICE candidate has an empty SDP mid");
            }
            validate_text_size("inbound ICE SDP mid", sdp_mid, MAX_ICE_SDP_MID_BYTES)?;
        }
        let sdp_mline_index = match payload.sdp_m_line_index {
            Some(value) => Some(
                u16::try_from(value)
                    .map_err(|_| anyhow!("inbound ICE SDP m-line index is out of range"))?,
            ),
            None => None,
        };
        let candidate_init = RTCIceCandidateInit {
            candidate,
            sdp_mid: payload.sdp_mid.clone(),
            sdp_mline_index,
            username_fragment: None,
            url: None,
        };

        {
            let mut state = self.state.lock().await;
            if state.remote_candidate_count >= MAX_REMOTE_ICE_CANDIDATES {
                bail!(
                    "remote ICE candidate limit exceeded: {}",
                    MAX_REMOTE_ICE_CANDIDATES
                );
            }
            state.remote_candidate_count += 1;
            if !state.remote_description_set {
                state.pending_remote_candidates.push(candidate_init);
                return Ok(());
            }
        }
        run_native_setup_with_timeout(
            "native_remote_candidate_add",
            NATIVE_WEBRTC_SETUP_TIMEOUT,
            async { Ok(self.peer.add_ice_candidate(candidate_init).await?) },
        )
        .await?;
        Ok(())
    }

    async fn flush_pending_remote_candidates(&self) -> Result<()> {
        let pending = {
            let mut state = self.state.lock().await;
            std::mem::take(&mut state.pending_remote_candidates)
        };
        for candidate in pending {
            run_native_setup_with_timeout(
                "native_pending_candidate_add",
                NATIVE_WEBRTC_SETUP_TIMEOUT,
                async { Ok(self.peer.add_ice_candidate(candidate).await?) },
            )
            .await?;
        }
        Ok(())
    }

    async fn handle_data_channel_open(
        self: &Arc<Self>,
        data_channel: Arc<dyn DataChannel>,
    ) -> Result<()> {
        let label = self
            .validate_open_control_channel_label(&data_channel)
            .await?;
        let (should_emit_ready, outbound_message_a) = {
            let mut state = self.state.lock().await;
            if state.transport_disconnected_emitted {
                bail!("data_channel_open_after_transport_disconnect");
            }
            let should_emit_ready = if state.transport_ready_emitted {
                false
            } else {
                state.transport_ready_emitted = true;
                true
            };
            let outbound_message_a = if should_emit_ready {
                state
                    .handshake
                    .as_mut()
                    .ok_or_else(|| anyhow!("native handshake missing when data channel opened"))?
                    .start()?
            } else {
                Vec::new()
            };
            (should_emit_ready, outbound_message_a)
        };

        if should_emit_ready {
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

        if !outbound_message_a.is_empty() {
            info!(
                kind = "native_webrtc.handshake.message_a.sent",
                session_id = %self.session_id,
                role = ?self.role,
                bytes = outbound_message_a.len(),
                "sending initial handshake frame over data channel"
            );
            self.send_framed_payload(&data_channel, &outbound_message_a)
                .await?;
        }
        Ok(())
    }

    async fn validate_open_control_channel_label(
        &self,
        data_channel: &Arc<dyn DataChannel>,
    ) -> Result<String> {
        let label = data_channel.label();
        let label = run_native_setup_with_timeout(
            "open_data_channel_label_read",
            NATIVE_WEBRTC_SETUP_TIMEOUT,
            async { Ok(label.await?) },
        )
        .await
        .map_err(|error| anyhow!("data_channel_label_read_failed:{error}"))?;
        if label != CONTROL_CHANNEL_LABEL {
            bail!("unexpected_data_channel_label:{label}");
        }
        Ok(label)
    }

    async fn handle_data_channel_message(
        self: &Arc<Self>,
        message: RTCDataChannelMessage,
    ) -> Result<()> {
        if message.is_string {
            bail!("text_message_rejected_on_binary_control_channel");
        }
        {
            let state = self.state.lock().await;
            if state.transport_disconnected_emitted {
                bail!("data_channel_message_after_transport_disconnect");
            }
        }
        debug!(
            kind = "native_webrtc.data_channel.message_binary",
            session_id = %self.session_id,
            role = ?self.role,
            bytes = message.data.len(),
            "received binary message on native WebRTC data channel"
        );
        if let Err(error) = self.append_inbound_chunk(message.data.as_ref()).await {
            self.clear_inbound_frame_buffer().await;
            return Err(error);
        }
        for frame_count in 0..=MAX_INBOUND_FRAMES_PER_DATA_MESSAGE {
            let frame = match self.take_next_inbound_frame().await {
                Ok(frame) => frame,
                Err(error) => {
                    self.clear_inbound_frame_buffer().await;
                    return Err(error);
                }
            };
            let Some(frame) = frame else {
                return Ok(());
            };
            if frame_count == MAX_INBOUND_FRAMES_PER_DATA_MESSAGE {
                self.clear_inbound_frame_buffer().await;
                bail!(
                    "inbound framed payload count exceeds per-message limit of {MAX_INBOUND_FRAMES_PER_DATA_MESSAGE}"
                );
            }
            if let Err(error) = self.handle_framed_payload(frame).await {
                self.clear_inbound_frame_buffer().await;
                return Err(error);
            }
        }
        unreachable!("bounded inbound frame loop always returns")
    }

    async fn append_inbound_chunk(&self, chunk: &[u8]) -> Result<()> {
        let mut state = self.state.lock().await;
        let buffered_length = state.inbound_framed_buffer.len();
        let combined_length = buffered_length
            .checked_add(chunk.len())
            .ok_or_else(|| anyhow!("inbound framed buffer length overflow"))?;
        if combined_length > MAX_INBOUND_FRAMED_BUFFER_BYTES {
            bail!(
                "inbound framed buffer limit exceeded: {combined_length} > {MAX_INBOUND_FRAMED_BUFFER_BYTES}"
            );
        }
        state.inbound_framed_buffer.extend_from_slice(chunk);
        Ok(())
    }

    async fn take_next_inbound_frame(&self) -> Result<Option<Vec<u8>>> {
        let mut state = self.state.lock().await;
        if state.inbound_framed_buffer.len() < 4 {
            return Ok(None);
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
            return Ok(None);
        }
        let framed = state.inbound_framed_buffer.split_to(4 + length);
        Ok(Some(framed[4..].to_vec()))
    }

    async fn clear_inbound_frame_buffer(&self) {
        self.state.lock().await.inbound_framed_buffer.clear();
    }

    async fn handle_framed_payload(self: &Arc<Self>, payload: Vec<u8>) -> Result<()> {
        let (handshake_actions, opened_app_payload) = {
            let mut state = self.state.lock().await;
            if let Some(runtime) = state.app_secure_runtime.as_mut() {
                (
                    None,
                    Some(runtime.open_and_record(self.role, payload.as_slice())?),
                )
            } else {
                let actions = state
                    .handshake
                    .as_mut()
                    .ok_or_else(|| anyhow!("native handshake missing while handling data"))?
                    .handle_frame(&payload)?;
                (Some(actions), None)
            }
        };

        if let Some(opened) = opened_app_payload {
            let counter = opened.counter;
            let authenticated = decode_authenticated_app_payload(opened)?;
            return self
                .handle_authenticated_app_payload(authenticated, counter)
                .await;
        }
        let actions = handshake_actions
            .ok_or_else(|| anyhow!("native framed payload produced no protocol action"))?;

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

        Ok(())
    }

    async fn handle_authenticated_app_payload(
        self: &Arc<Self>,
        payload: NativeAuthenticatedAppPayload,
        sbwc_counter: u64,
    ) -> Result<()> {
        match payload {
            NativeAuthenticatedAppPayload::AppControl(
                crate::handshake_app_frame::AppControlMessage::Heartbeat(heartbeat),
            ) => {
                self.validate_authenticated_heartbeat_identity(&heartbeat)
                    .await?;
                info!(
                    kind = "native_webrtc.keepalive.heartbeat_received",
                    session_id = %self.session_id,
                    role = ?self.role,
                    sbwc_counter,
                    "received authenticated SBWC heartbeat"
                );
                self.events_tx
                    .send(NativeWebRtcEvent::AuthenticatedPeerHeartbeat {
                        payload: heartbeat,
                        sbwc_counter,
                        received_at_unix_seconds: now_unix_seconds(),
                    })
                    .await
                    .map_err(|_| anyhow!("native_webrtc_event_receiver_dropped"))?;
                self.emit_keepalive_event(RuntimeSessionKeepaliveKind::HeartbeatReceived, None)
                    .await?;
            }
            NativeAuthenticatedAppPayload::AppControl(
                crate::handshake_app_frame::AppControlMessage::Ping(ping),
            ) => {
                let plaintext = crate::handshake_app_frame::build_pong_plaintext(ping.id)?;
                let outbound = self
                    .seal_authenticated_payload(WebRtcAppSecurePacketType::AppControl, &plaintext)
                    .await?;
                let data_channel = self
                    .data_channel
                    .lock()
                    .await
                    .clone()
                    .ok_or_else(|| anyhow!("data channel is not attached"))?;
                self.send_framed_payload(&data_channel, &outbound).await?;
                self.emit_keepalive_event(RuntimeSessionKeepaliveKind::PongReplied, Some(ping.id))
                    .await?;
            }
            NativeAuthenticatedAppPayload::AppControl(
                crate::handshake_app_frame::AppControlMessage::Pong(pong),
            ) => {
                self.acknowledge_outstanding_pong(pong.id).await?;
                self.emit_keepalive_event(RuntimeSessionKeepaliveKind::PongReceived, Some(pong.id))
                    .await?;
            }
            NativeAuthenticatedAppPayload::FileTransfer(file_frame) => {
                self.events_tx
                    .send(NativeWebRtcEvent::InboundFileFrame(file_frame))
                    .await
                    .map_err(|_| anyhow!("native_webrtc_event_receiver_dropped"))?;
            }
        }
        Ok(())
    }

    async fn validate_authenticated_heartbeat_identity(
        &self,
        heartbeat: &crate::handshake_app_frame::HeartbeatPayload,
    ) -> Result<()> {
        let actual = heartbeat
            .device_id
            .as_deref()
            .ok_or_else(|| anyhow!("authenticated heartbeat is missing deviceId"))?;
        let state = self.state.lock().await;
        let expected = state
            .remote_device_id
            .as_deref()
            .ok_or_else(|| anyhow!("authenticated heartbeat arrived before remote binding"))?;
        if actual != expected {
            bail!("authenticated heartbeat device mismatch");
        }
        Ok(())
    }

    async fn seal_authenticated_payload(
        &self,
        packet_type: WebRtcAppSecurePacketType,
        plaintext: &[u8],
    ) -> Result<Vec<u8>> {
        let mut state = self.state.lock().await;
        if state.transport_disconnected_emitted {
            bail!("cannot seal application payload on a disconnected session");
        }
        state
            .app_secure_runtime
            .as_mut()
            .ok_or_else(|| anyhow!("SBWC runtime is not established"))?
            .seal(self.role, packet_type, plaintext)
    }

    /// Encrypt and send one canonical cross-network file-transfer v1 JSON
    /// plaintext over the established control channel. Fails closed if the
    /// message is invalid, the handshake has not completed, or the channel is gone.
    async fn send_file_app_frame(&self, plaintext: &[u8]) -> Result<()> {
        crate::decode_cross_network_file_transfer_message_v1(plaintext)?;
        let frame = self
            .seal_authenticated_payload(WebRtcAppSecurePacketType::FileTransfer, plaintext)
            .await?;
        let data_channel = self
            .data_channel
            .lock()
            .await
            .clone()
            .ok_or_else(|| anyhow!("data channel is not attached"))?;
        self.send_framed_payload(&data_channel, &frame).await
    }

    async fn mark_handshake_complete(
        self: &Arc<Self>,
        established: ClassicSessionKeys,
    ) -> Result<()> {
        let should_emit = {
            let mut state = self.state.lock().await;
            if state.transport_disconnected_emitted {
                bail!("handshake_completed_after_transport_disconnect");
            }
            if state.app_secure_runtime.is_some() {
                bail!("SBWC runtime is already installed");
            }
            if state.requires_pqc_join_bootstrap && !state.remote_join_observed {
                bail!("PQC handshake completed without an authenticated signaling Join binding");
            }
            if let Some(bootstrap) = state.remote_join_bootstrap.as_ref()
                && established.peer_protocol_public_key_fingerprint
                    != bootstrap.protocol_public_key_fingerprint
            {
                bail!("handshake peer identity does not match the signaling Join identity");
            }
            state.app_secure_runtime = Some(NativeAppSecureRuntime::new(established.clone()));
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
                    peer_protocol_public_key_fingerprint: established
                        .peer_protocol_public_key_fingerprint,
                })
                .await
                .map_err(|_| anyhow!("native_webrtc_event_receiver_dropped"))?;
        }
        self.ensure_selected_ice_route_task().await;
        self.ensure_heartbeat_task().await?;
        Ok(())
    }

    async fn ensure_selected_ice_route_task(self: &Arc<Self>) {
        let should_start = {
            let mut state = self.state.lock().await;
            if state.selected_ice_route_task_started
                || state.selected_ice_route_emitted
                || state.transport_disconnected_emitted
            {
                false
            } else {
                state.selected_ice_route_task_started = true;
                true
            }
        };
        if !should_start {
            return;
        }

        let route_worker = Arc::clone(self);
        let route_handle =
            tokio::spawn(async move { route_worker.observe_and_emit_selected_ice_route().await });
        let monitor = Arc::clone(self);
        tokio::spawn(async move {
            let result = match route_handle.await {
                Ok(result) => result,
                Err(error) => Err(anyhow!("selected_ice_route_task_join_failed:{error}")),
            };
            {
                let mut state = monitor.state.lock().await;
                state.selected_ice_route_task_started = false;
            }
            if let Err(error) = result
                && let Err(disconnect_error) = monitor
                    .emit_transport_disconnected(Some(format!(
                        "selected_ice_route_observation_failed:{error}"
                    )))
                    .await
            {
                warn!(
                    kind = "native_webrtc.selected_ice_route.disconnect_event_failed",
                    session_id = %monitor.session_id,
                    role = ?monitor.role,
                    error = %disconnect_error,
                    "failed to publish selected ICE route observation failure"
                );
            }
        });
    }

    async fn observe_and_emit_selected_ice_route(&self) -> Result<()> {
        let deadline = Instant::now() + SELECTED_ICE_ROUTE_OBSERVATION_TIMEOUT;
        loop {
            if self.state.lock().await.transport_disconnected_emitted {
                return Ok(());
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                bail!("selected_ice_route_observation_timeout");
            }
            if let Some(observation) = self.selected_ice_route_observation(remaining).await? {
                if self.state.lock().await.transport_disconnected_emitted {
                    return Ok(());
                }
                self.events_tx
                    .send(NativeWebRtcEvent::SelectedIceRoute(Box::new(observation)))
                    .await
                    .map_err(|_| anyhow!("native_webrtc_event_receiver_dropped"))?;
                self.state.lock().await.selected_ice_route_emitted = true;
                return Ok(());
            }
            if Instant::now() >= deadline {
                bail!("selected_ice_route_observation_timeout");
            }
            tokio::time::sleep(SELECTED_ICE_ROUTE_POLL_INTERVAL).await;
        }
    }

    async fn selected_ice_route_observation(
        &self,
        remaining: Duration,
    ) -> Result<Option<crate::RuntimeSelectedIceRouteObservation>> {
        let report = timeout(
            remaining,
            self.peer
                .get_stats(std::time::Instant::now(), StatsSelector::None),
        )
        .await
        .map_err(|_| anyhow!("selected_ice_route_stats_timeout"))?;
        let Some(transport) = report.transport() else {
            return Ok(None);
        };
        if transport.selected_candidate_pair_id.is_empty() {
            return Ok(None);
        }
        let Some(RTCStatsReportEntry::IceCandidatePair(pair)) =
            report.get(&transport.selected_candidate_pair_id)
        else {
            return Ok(None);
        };
        if !pair.nominated || pair.state != RTCStatsIceCandidatePairState::Succeeded {
            return Ok(None);
        }
        let Some(RTCStatsReportEntry::LocalCandidate(local)) = report.get(&pair.local_candidate_id)
        else {
            return Ok(None);
        };
        let Some(RTCStatsReportEntry::RemoteCandidate(remote)) =
            report.get(&pair.remote_candidate_id)
        else {
            return Ok(None);
        };
        let Some(remote_address) = remote.address.clone() else {
            return Ok(None);
        };
        if remote_address.parse::<std::net::IpAddr>().is_err() || remote.port == 0 {
            return Ok(None);
        }
        let Some(local_candidate_type) = ice_candidate_type_label(local.candidate_type) else {
            return Ok(None);
        };
        let Some(remote_candidate_type) = ice_candidate_type_label(remote.candidate_type) else {
            return Ok(None);
        };
        let protocol = remote.protocol.to_ascii_lowercase();
        if !matches!(protocol.as_str(), "udp" | "tcp") {
            return Ok(None);
        }
        let kind = if local_candidate_type == "relay" || remote_candidate_type == "relay" {
            crate::RuntimeSessionRouteKind::Relay
        } else {
            crate::RuntimeSessionRouteKind::Direct
        };
        Ok(Some(crate::RuntimeSelectedIceRouteObservation {
            remote_address,
            remote_port: remote.port,
            protocol,
            local_candidate_type: local_candidate_type.to_owned(),
            remote_candidate_type: remote_candidate_type.to_owned(),
            kind,
            observed_at: OffsetDateTime::now_utc(),
        }))
    }

    async fn ensure_heartbeat_task(self: &Arc<Self>) -> Result<()> {
        let should_start = {
            let mut state = self.state.lock().await;
            if state.heartbeat_task_started || state.app_secure_runtime.is_none() {
                false
            } else {
                state.heartbeat_task_started = true;
                true
            }
        };
        if !should_start {
            return Ok(());
        }

        let heartbeat_worker = Arc::clone(self);
        let heartbeat_handle =
            tokio::spawn(async move { heartbeat_worker.run_keepalive_loop().await });
        tokio::spawn(Arc::clone(self).monitor_keepalive_task(heartbeat_handle));

        Ok(())
    }

    async fn monitor_keepalive_task(
        self: Arc<Self>,
        heartbeat_handle: tokio::task::JoinHandle<Result<()>>,
    ) {
        let result = match heartbeat_handle.await {
            Ok(result) => result,
            Err(error) => Err(anyhow!("keepalive_task_join_failed:{error}")),
        };
        {
            let mut state = self.state.lock().await;
            state.heartbeat_task_started = false;
        }
        if let Err(error) = result {
            warn!(
                kind = "native_webrtc.keepalive.failed",
                session_id = %self.session_id,
                role = ?self.role,
                error = %error,
                "native WebRTC keepalive task failed"
            );
            if let Err(emit_error) = self
                .emit_transport_disconnected(Some(format!("keepalive_failed:{error}")))
                .await
            {
                warn!(
                    kind = "native_webrtc.transport.disconnect_event_failed",
                    session_id = %self.session_id,
                    role = ?self.role,
                    error = %emit_error,
                    "failed to publish keepalive failure"
                );
            }
        }
    }

    async fn run_keepalive_loop(self: &Arc<Self>) -> Result<()> {
        self.send_heartbeat_once().await?;
        self.send_ping_once().await?;

        let mut interval =
            tokio::time::interval_at(Instant::now() + KEEPALIVE_INTERVAL, KEEPALIVE_INTERVAL);
        interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
        let mut tick_count = 0_u64;
        loop {
            interval.tick().await;
            {
                let state = self.state.lock().await;
                if state.transport_disconnected_emitted {
                    return Ok(());
                }
            }
            self.reject_expired_outstanding_ping().await?;
            tick_count = tick_count
                .checked_add(1)
                .ok_or_else(|| anyhow!("keepalive tick counter overflow"))?;
            if tick_count.is_multiple_of(HEARTBEAT_EVERY_TICKS) {
                self.send_heartbeat_once().await?;
            }
            self.send_ping_once().await?;
        }
    }

    async fn send_heartbeat_once(self: &Arc<Self>) -> Result<()> {
        let advertisement = self.heartbeat_advertisement.lock().await.clone();
        let heartbeat_plaintext =
            crate::handshake_app_frame::build_heartbeat_plaintext_with_advertisement(
                &self.local_device_id,
                self.local_device_name.as_deref(),
                advertisement.capabilities.as_deref(),
                advertisement.file_transfer_port,
                advertisement.remote_control_port,
            )?;
        let heartbeat_frame = self
            .seal_authenticated_payload(WebRtcAppSecurePacketType::AppControl, &heartbeat_plaintext)
            .await?;
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
            .await?;
        Ok(())
    }

    async fn send_ping_once(self: &Arc<Self>) -> Result<()> {
        let maybe_ping = {
            let mut state = self.state.lock().await;
            if state.transport_disconnected_emitted || state.app_secure_runtime.is_none() {
                bail!("cannot send keepalive ping on a disconnected session");
            }
            if state.outstanding_ping.is_some() {
                None
            } else {
                let ping_id = state.next_ping_id;
                state.next_ping_id = state
                    .next_ping_id
                    .checked_add(1)
                    .ok_or_else(|| anyhow!("keepalive ping identifier exhausted"))?;
                let plaintext = crate::handshake_app_frame::build_ping_plaintext(ping_id)?;
                let ping_frame = state
                    .app_secure_runtime
                    .as_mut()
                    .ok_or_else(|| anyhow!("SBWC runtime is not established"))?
                    .seal(self.role, WebRtcAppSecurePacketType::AppControl, &plaintext)?;
                state.outstanding_ping = Some(OutstandingPing {
                    id: ping_id,
                    sent_at: Instant::now(),
                });
                Some((ping_id, ping_frame))
            }
        };
        let Some((ping_id, ping_frame)) = maybe_ping else {
            return Ok(());
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
            .await?;
        Ok(())
    }

    async fn reject_expired_outstanding_ping(&self) -> Result<()> {
        let state = self.state.lock().await;
        if let Some(outstanding) = state.outstanding_ping
            && outstanding.sent_at.elapsed() >= PONG_TIMEOUT
        {
            bail!("keepalive_pong_timeout:ping_id={}", outstanding.id);
        }
        Ok(())
    }

    async fn acknowledge_outstanding_pong(&self, pong_id: u64) -> Result<()> {
        let mut state = self.state.lock().await;
        let Some(outstanding) = state.outstanding_ping else {
            bail!("unsolicited_keepalive_pong:ping_id={pong_id}");
        };
        if outstanding.sent_at.elapsed() >= PONG_TIMEOUT {
            bail!("keepalive_pong_timeout:ping_id={pong_id}");
        }
        if outstanding.id != pong_id {
            bail!(
                "unexpected_keepalive_pong:expected={}:received={pong_id}",
                outstanding.id
            );
        }
        state.outstanding_ping = None;
        Ok(())
    }

    async fn send_framed_payload(
        &self,
        data_channel: &Arc<dyn DataChannel>,
        payload: &[u8],
    ) -> Result<()> {
        self.send_framed_payload_with_timeout(data_channel, payload, DATA_CHANNEL_SEND_TIMEOUT)
            .await
    }

    async fn send_framed_payload_with_timeout(
        &self,
        data_channel: &Arc<dyn DataChannel>,
        payload: &[u8],
        send_timeout: Duration,
    ) -> Result<()> {
        if payload.is_empty() || payload.len() > MAX_FRAMED_PAYLOAD_BYTES {
            bail!(
                "invalid outbound framed payload length: {} (maximum {MAX_FRAMED_PAYLOAD_BYTES})",
                payload.len()
            );
        }
        let payload_length = u32::try_from(payload.len())
            .map_err(|_| anyhow!("outbound framed payload length exceeds u32"))?;
        let mut did_queue_fragment = false;
        let send_result = timeout(send_timeout, async {
            let _frame_guard = self.outbound_frame_gate.lock().await;
            if self.state.lock().await.transport_disconnected_emitted {
                bail!("cannot send framed payload after transport disconnect");
            }
            let mut framed = Vec::with_capacity(4 + payload.len());
            framed.extend_from_slice(&payload_length.to_be_bytes());
            framed.extend_from_slice(payload);
            for chunk in framed.chunks(DATA_CHANNEL_FRAME_CHUNK_BYTES) {
                data_channel
                    .send(BytesMut::from(chunk))
                    .await
                    .map_err(|error| {
                        anyhow!("failed to send framed data channel payload: {error}")
                    })?;
                did_queue_fragment = true;
            }
            Ok(())
        })
        .await
        .map_err(|_| anyhow!("data_channel_send_timeout"))
        .and_then(|result| result);

        if let Err(error) = send_result {
            if did_queue_fragment {
                let reason = Some(format!("partial_outbound_frame_failed:{error}"));
                if let Err(disconnect_error) = self.emit_transport_disconnected(reason).await {
                    warn!(
                        kind = "native_webrtc.transport.disconnect_event_failed",
                        session_id = %self.session_id,
                        role = ?self.role,
                        error = %disconnect_error,
                        "failed to publish partial outbound frame failure"
                    );
                }
            }
            return Err(error);
        }
        Ok(())
    }

    async fn emit_transport_disconnected(&self, reason: Option<String>) -> Result<()> {
        let should_emit = {
            let mut state = self.state.lock().await;
            state.app_secure_runtime = None;
            state.remote_device_id = None;
            state.heartbeat_task_started = false;
            state.next_ping_id = 0;
            state.outstanding_ping = None;
            state.inbound_framed_buffer.clear();
            if state.transport_disconnected_emitted {
                false
            } else {
                state.transport_disconnected_emitted = true;
                true
            }
        };
        *self.data_channel.lock().await = None;
        if should_emit {
            info!(
                kind = "native_webrtc.transport.disconnected",
                session_id = %self.session_id,
                role = ?self.role,
                reason = reason.as_deref().unwrap_or("unknown"),
                "emitting transport disconnected"
            );
            self.events_tx
                .send(NativeWebRtcEvent::TransportDisconnected { reason })
                .await
                .map_err(|_| anyhow!("native_webrtc_event_receiver_dropped"))?;
        }
        Ok(())
    }

    async fn emit_keepalive_event(
        &self,
        kind: RuntimeSessionKeepaliveKind,
        ping_id: Option<u64>,
    ) -> Result<()> {
        self.events_tx
            .send(NativeWebRtcEvent::Keepalive { kind, ping_id })
            .await
            .map_err(|_| anyhow!("native_webrtc_event_receiver_dropped"))
    }

    async fn emit_signaling_envelope(
        &self,
        kind: WebRtcMessageType,
        payload: Option<WebRtcSignalingPayload>,
    ) -> Result<()> {
        if let Some(payload) = payload.as_ref() {
            validate_signaling_payload_bounds(payload)?;
        }
        self.events_tx
            .send(NativeWebRtcEvent::SignalingEnvelope(
                WebRtcSignalingEnvelope {
                    session_id: self.session_id.clone(),
                    from: self.local_device_id.clone(),
                    to: None,
                    kind,
                    payload: payload.map(Box::new),
                    auth_token: None,
                    sent_at: now_unix_seconds(),
                },
            ))
            .await
            .map_err(|_| anyhow!("native_webrtc_event_receiver_dropped"))
    }
}
