//! Plain TCP control channel compatible with macOS/iOS "SkyBridge control endpoint".
//!
//! Wire contract (mirrors macOS/iOS Pro release control channel):
//! - 4-byte big-endian length prefix framing (`p2p::framing`)
//! - Pre-handshake: raw handshake frames (`HandshakeMessage` encoding)
//! - Post-handshake: AES-GCM encrypted payloads (`EncryptedData` bytes, empty AAD)
//! - Business payloads: `AppMessage` JSON and/or `BusinessEnvelope` binary.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use rand::RngExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Notify;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::warn;

use crate::crypto::suite::CryptoSuiteId;
use crate::p2p::soa::{OutgoingAttempt, PeerSessionArbiter, RegisterDecision, SoaExtension};
use crate::p2p::{
    AppMessage, BusinessEnvelope, BusinessEnvelopeKind, ConnectionTrustPolicy, CrossNetworkChannel,
    CrossNetworkInbound, HandshakePolicy, KemPublicKeyInfo, LocalIdentity, P2PError,
    PairingIdentityExchangePayload, SessionKeys, SwiftDateSeconds, TrustStore,
    encode_frame_with_limit, enforce_inbound_trust_policy, enforce_outbound_trust_policy,
};
use crate::remote::supported_remote_video_formats;
use crate::transfer::TransferKeyStore;

/// Default maximum application frame size on the control channel (16 MiB).
pub const DEFAULT_MAX_CONTROL_FRAME_SIZE: usize = 16 * 1024 * 1024;

/// Events emitted by [`TcpControlService`].
#[derive(Debug, Clone)]
pub enum TcpControlEvent {
    Listening {
        bind: SocketAddr,
    },
    IncomingAccepted {
        peer_addr: SocketAddr,
        connection_id: String,
    },
    OutgoingConnected {
        peer_addr: SocketAddr,
        connection_id: String,
    },
    HandshakeEstablished {
        peer_addr: SocketAddr,
        connection_id: String,
        peer_device_id: Option<String>,
        suite: CryptoSuiteId,
        session_keys: SessionKeys,
    },
    RemoteDesktopFrame {
        peer_addr: SocketAddr,
        connection_id: String,
        peer_device_id: Option<String>,
        timestamp_ns: u64,
        payload: Vec<u8>,
    },
    Disconnected {
        peer_addr: SocketAddr,
        connection_id: String,
    },
    Failed {
        peer_addr: SocketAddr,
        connection_id: String,
        error: String,
    },
}

pub type TcpControlCallback = Arc<dyn Fn(TcpControlEvent) + Send + Sync>;

/// A running TCP control connection handle (post-handshake app payload sender).
#[derive(Clone)]
pub struct TcpControlHandle {
    pub connection_id: String,
    pub peer_addr: SocketAddr,
    app_send: mpsc::UnboundedSender<Vec<u8>>,
}

impl TcpControlHandle {
    /// Send an application plaintext payload (will be encrypted + framed by the connection task).
    pub fn send_app_payload(&self, data: Vec<u8>) -> Result<(), P2PError> {
        self.app_send
            .send(data)
            .map_err(|_| P2PError::ChannelClosed)
    }

    /// Send an `AppMessage` over the encrypted channel.
    pub fn send_app_message(&self, msg: &AppMessage) -> Result<(), P2PError> {
        let data = serde_json::to_vec(msg)
            .map_err(|e| P2PError::Protocol(format!("encode AppMessage: {}", e)))?;
        self.send_app_payload(data)
    }

    /// Send a remote desktop business envelope.
    pub fn send_remote_desktop_frame(
        &self,
        timestamp_ns: u64,
        payload: Vec<u8>,
    ) -> Result<(), P2PError> {
        let env = BusinessEnvelope::remote_desktop_frame(timestamp_ns, payload);
        self.send_app_payload(env.encode())
    }
}

/// TCP control service (listener + outgoing connector).
pub struct TcpControlService {
    identity: LocalIdentity,
    policy: HandshakePolicy,
    trust_policy: ConnectionTrustPolicy,
    max_frame_size: usize,
    transfer_keys: Option<Arc<TransferKeyStore>>,
    callback: Option<TcpControlCallback>,
}

impl TcpControlService {
    pub fn new(identity: LocalIdentity, policy: HandshakePolicy) -> Self {
        Self {
            identity,
            policy,
            trust_policy: ConnectionTrustPolicy::default(),
            max_frame_size: DEFAULT_MAX_CONTROL_FRAME_SIZE,
            transfer_keys: None,
            callback: None,
        }
    }

    pub fn set_max_frame_size(&mut self, bytes: usize) {
        self.max_frame_size = bytes.max(64 * 1024);
    }

    pub fn set_transfer_key_store(&mut self, store: Arc<TransferKeyStore>) {
        self.transfer_keys = Some(store);
    }

    pub fn set_trust_policy(&mut self, policy: ConnectionTrustPolicy) {
        self.trust_policy = policy;
    }

    pub fn on_event<F>(&mut self, cb: F)
    where
        F: Fn(TcpControlEvent) + Send + Sync + 'static,
    {
        self.callback = Some(Arc::new(cb));
    }

    fn emit(&self, evt: TcpControlEvent) {
        if let Some(cb) = &self.callback {
            cb(evt);
        }
    }

    /// Start a TCP listener accept loop.
    pub async fn start_listening(&self, bind: SocketAddr) -> Result<JoinHandle<()>, P2PError> {
        let listener = TcpListener::bind(bind)
            .await
            .map_err(|e| P2PError::ConnectionFailed(format!("tcp bind failed: {}", e)))?;

        self.emit(TcpControlEvent::Listening { bind });

        let identity = self.identity.clone();
        let policy = self.policy;
        let trust_policy = self.trust_policy;
        let max_frame_size = self.max_frame_size;
        let transfer_keys = self.transfer_keys.clone();
        let cb = self.callback.clone();

        Ok(tokio::spawn(async move {
            loop {
                let (stream, peer_addr) = match listener.accept().await {
                    Ok(v) => v,
                    Err(e) => {
                        warn!("TCP accept failed: {}", e);
                        break;
                    }
                };
                let connection_id = uuid::Uuid::new_v4().to_string();
                if let Some(cb) = &cb {
                    cb(TcpControlEvent::IncomingAccepted {
                        peer_addr,
                        connection_id: connection_id.clone(),
                    });
                }

                let identity = identity.clone();
                let cb = cb.clone();
                let transfer_keys = transfer_keys.clone();
                tokio::spawn(async move {
                    if let Err(err) = run_tcp_control_connection(
                        stream,
                        peer_addr,
                        connection_id.clone(),
                        ConnectionRole::Responder,
                        identity,
                        policy,
                        trust_policy,
                        max_frame_size,
                        transfer_keys,
                        cb.clone(),
                        None,
                        None,
                        None,
                    )
                    .await
                        && let Some(cb) = &cb
                    {
                        cb(TcpControlEvent::Failed {
                            peer_addr,
                            connection_id,
                            error: format!("{}", err),
                        });
                    }
                });
            }
        }))
    }

    /// Connect to a peer over TCP and return a handle for sending app payloads.
    pub async fn connect(&self, peer_addr: SocketAddr) -> Result<TcpControlHandle, P2PError> {
        self.connect_with_peer(peer_addr, None).await
    }

    /// Connect to a peer over TCP with an optional peer device id hint (from discovery).
    ///
    /// If the peer device id is provided and we already have stored KEM public keys for it,
    /// the initiator will attempt a PQC handshake immediately.
    pub async fn connect_with_peer(
        &self,
        peer_addr: SocketAddr,
        peer_device_id: Option<&str>,
    ) -> Result<TcpControlHandle, P2PError> {
        self.connect_with_peer_hint(peer_addr, peer_device_id, None)
            .await
    }

    /// Connect to a peer with optional device-id and discovery fingerprint hints.
    pub async fn connect_with_peer_hint(
        &self,
        peer_addr: SocketAddr,
        peer_device_id: Option<&str>,
        expected_peer_fingerprint: Option<&str>,
    ) -> Result<TcpControlHandle, P2PError> {
        enforce_outbound_trust_policy(
            self.trust_policy,
            peer_device_id,
            expected_peer_fingerprint,
        )?;

        let stream = TcpStream::connect(peer_addr)
            .await
            .map_err(|e| P2PError::ConnectionFailed(format!("tcp connect failed: {}", e)))?;

        let connection_id = uuid::Uuid::new_v4().to_string();
        self.emit(TcpControlEvent::OutgoingConnected {
            peer_addr,
            connection_id: connection_id.clone(),
        });

        let (app_tx, app_rx) = mpsc::unbounded_channel::<Vec<u8>>();

        let identity = self.identity.clone();
        let policy = self.policy;
        let trust_policy = self.trust_policy;
        let max_frame_size = self.max_frame_size;
        let transfer_keys = self.transfer_keys.clone();
        let cb = self.callback.clone();
        let peer_device_id = peer_device_id.map(|s| s.to_string());
        let expected_peer_fingerprint = expected_peer_fingerprint.map(|s| s.to_string());
        let connection_id_task = connection_id.clone();

        tokio::spawn(async move {
            let connection_id_for_run = connection_id_task.clone();
            if let Err(err) = run_tcp_control_connection(
                stream,
                peer_addr,
                connection_id_for_run,
                ConnectionRole::Initiator,
                identity,
                policy,
                trust_policy,
                max_frame_size,
                transfer_keys,
                cb.clone(),
                Some(app_rx),
                peer_device_id,
                expected_peer_fingerprint,
            )
            .await
                && let Some(cb) = &cb
            {
                cb(TcpControlEvent::Failed {
                    peer_addr,
                    connection_id: connection_id_task,
                    error: format!("{}", err),
                });
            }
        });

        Ok(TcpControlHandle {
            connection_id,
            peer_addr,
            app_send: app_tx,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ConnectionRole {
    Responder,
    Initiator,
}

fn build_pairing_identity_exchange(identity: &LocalIdentity) -> AppMessage {
    let kem_public_keys = identity
        .kem_public_keys
        .iter()
        .filter(|(suite, _)| suite.is_pqc())
        .map(|(suite, public_key)| KemPublicKeyInfo {
            suite_wire_id: suite.wire_id(),
            public_key: public_key.clone(),
        })
        .collect();

    AppMessage::PairingIdentityExchange(PairingIdentityExchangePayload {
        device_id: identity.device_id.clone(),
        kem_public_keys,
        device_name: None,
        model_name: None,
        platform: Some("Ubuntu".to_string()),
        os_version: std::env::var("SKYBRIDGE_OS_VERSION").ok(),
        chip: None,
        remote_video_formats: Some(supported_remote_video_formats()),
        sent_at: SwiftDateSeconds::now(),
    })
}

fn persist_peer_kem_keys(payload: &PairingIdentityExchangePayload) {
    if payload.device_id.trim().is_empty() {
        return;
    }
    let Ok(mut store) = TrustStore::load() else {
        return;
    };

    for key in &payload.kem_public_keys {
        let Some(suite) = CryptoSuiteId::from_wire_id(key.suite_wire_id) else {
            continue;
        };
        let _ = store.upsert_peer_kem_key(&payload.device_id, suite, key.public_key.clone());
    }
}

async fn send_raw_frame(
    writer: &mut tokio::net::tcp::OwnedWriteHalf,
    raw: &[u8],
    max_frame_size: usize,
) -> Result<(), P2PError> {
    use tokio::io::AsyncWriteExt;

    let framed = encode_frame_with_limit(raw, max_frame_size)?;
    writer
        .write_all(&framed)
        .await
        .map_err(|e| P2PError::Protocol(format!("tcp write failed: {}", e)))?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn run_tcp_control_connection(
    stream: TcpStream,
    peer_addr: SocketAddr,
    connection_id: String,
    role: ConnectionRole,
    identity: LocalIdentity,
    policy: HandshakePolicy,
    trust_policy: ConnectionTrustPolicy,
    max_frame_size: usize,
    transfer_keys: Option<Arc<TransferKeyStore>>,
    callback: Option<TcpControlCallback>,
    mut app_rx: Option<mpsc::UnboundedReceiver<Vec<u8>>>,
    peer_device_id_hint: Option<String>,
    expected_peer_fingerprint_hint: Option<String>,
) -> Result<(), P2PError> {
    use tokio::io::AsyncReadExt;

    let (mut reader, mut writer) = stream.into_split();

    let superseded_notify = Arc::new(Notify::new());
    let mut outgoing_guard: Option<SoaOutgoingGuard> = None;
    let mut established_pair_key: Option<[u8; 64]> = None;

    let mut channel = match role {
        ConnectionRole::Responder => {
            CrossNetworkChannel::new_responder_with_limit(identity.clone(), policy, max_frame_size)
        }
        ConnectionRole::Initiator => {
            CrossNetworkChannel::new_initiator_with_limit(identity.clone(), policy, max_frame_size)
        }
    };

    // Initiator starts handshake immediately (MessageA).
    if role == ConnectionRole::Initiator {
        if let Some(peer_device_id) = peer_device_id_hint.as_deref() {
            channel.set_peer_device_id(Some(peer_device_id.to_string()));
            if let Ok(store) = TrustStore::load() {
                let keys = store.peer_kem_keys(peer_device_id);
                if !keys.is_empty() {
                    channel.set_peer_kem_public_keys(keys);
                }
            }
        }
        channel.set_expected_peer_fingerprint(expected_peer_fingerprint_hint.clone());

        if let Some(peer_device_id) = peer_device_id_hint
            .as_deref()
            .map(str::trim)
            .filter(|id| !id.is_empty() && uuid::Uuid::parse_str(id).is_ok())
        {
            let local_peer_id = super::soa::canonical_peer_id_bytes(&identity.device_id);
            let target_peer_id = super::soa::canonical_peer_id_bytes(peer_device_id);
            let mut attempt_id = [0u8; 16];
            rand::rng().fill(&mut attempt_id);

            let ext = SoaExtension {
                version: super::soa::SOA_VERSION,
                initiator_peer_id: local_peer_id,
                target_peer_id,
                attempt_id,
            };
            channel.set_outbound_extensions_raw(ext.encode_tlv());

            let pair_key = super::soa::pair_key(local_peer_id, target_peer_id);
            let notify = superseded_notify.clone();
            let decision = PeerSessionArbiter::shared().register_outgoing(OutgoingAttempt {
                pair_key,
                initiator_peer_id: local_peer_id,
                attempt_id,
                started_at: Instant::now(),
                on_superseded: Box::new(move |_winner_peer_id, _winner_attempt_id| {
                    notify.notify_one();
                }),
            });

            match decision {
                RegisterDecision::Accepted => {
                    outgoing_guard = Some(SoaOutgoingGuard {
                        pair_key,
                        attempt_id,
                    });
                }
                RegisterDecision::AlreadyConnected => {
                    return Err(P2PError::HandshakeFailed {
                        reason: "SOA: already connected".to_string(),
                    });
                }
                RegisterDecision::AlreadyInProgress => {
                    return Err(P2PError::HandshakeFailed {
                        reason: "SOA: already in progress".to_string(),
                    });
                }
            }
        }

        let msg_a = channel.start_handshake().await?;
        send_raw_frame(&mut writer, &msg_a, max_frame_size).await?;
    }

    let mut established = false;
    let mut established_session_keys: Option<SessionKeys> = None;
    let mut peer_device_id: Option<String> = None;
    let mut peer_fingerprint: Option<String> = None;
    let mut peer_signing_algorithm = None;
    let mut pending_pairing_reply = false;
    let mut queued_app_plaintexts: Vec<Vec<u8>> = Vec::new();

    let mut buf = vec![0u8; 64 * 1024];

    loop {
        tokio::select! {
            _ = superseded_notify.notified(), if outgoing_guard.is_some() && !established => {
                return Err(P2PError::HandshakeFailed { reason: "SOA superseded by concurrent attempt".to_string() });
            }
            read_res = reader.read(&mut buf) => {
                let n = read_res.map_err(|e| P2PError::Protocol(format!("tcp read failed: {}", e)))?;
                if n == 0 {
                    break;
                }
                let events = channel.push_inbound_chunk(&buf[..n]).await?;
                for evt in events {
                    match evt {
                        CrossNetworkInbound::OutboundFrame(raw) => {
                            send_raw_frame(&mut writer, &raw, max_frame_size).await?;
                        }
                        CrossNetworkInbound::HandshakeEstablished(keys) => {
                            established = true;
                            established_session_keys = Some(keys.clone());
                            if let Some(peer_identity) = channel.peer_identity().cloned() {
                                peer_device_id = Some(peer_identity.device_id.clone())
                                    .filter(|s| !s.trim().is_empty());
                                peer_fingerprint = Some(peer_identity.public_key_fingerprint.clone());
                                peer_signing_algorithm = Some(peer_identity.signing_algorithm);
                            }

                            if established_pair_key.is_none()
                                && let Some(pair_key) = channel.soa_pair_key() {
                                    established_pair_key = Some(pair_key);
                                    PeerSessionArbiter::shared().mark_established(pair_key);
                                }
                            outgoing_guard = None;

                            if let (Some(peer_id), Some(store)) = (peer_device_id.as_ref(), transfer_keys.as_ref()) {
                                store.register(peer_id.clone(), keys.clone());
                            }

                            if let Some(cb) = &callback {
                                cb(TcpControlEvent::HandshakeEstablished {
                                    peer_addr,
                                    connection_id: connection_id.clone(),
                                    peer_device_id: peer_device_id.clone(),
                                    suite: keys.suite_id,
                                    session_keys: keys.clone(),
                                });
                            }

                            // Best-effort: send our PQC KEM identity bundle for bootstrap.
                            if identity.supported_suites.iter().any(|s| s.is_pqc())
                                && let Ok(bytes) = serde_json::to_vec(&build_pairing_identity_exchange(&identity)) {
                                    queued_app_plaintexts.push(bytes);
                                }
                            pending_pairing_reply = true;

                            // Flush any queued plaintexts.
                            let pending = std::mem::take(&mut queued_app_plaintexts);
                            for plaintext in pending {
                                let sealed = channel.encrypt_app_payload(&plaintext)?;
                                send_raw_frame(&mut writer, &sealed, max_frame_size).await?;
                            }
                        }
                        CrossNetworkInbound::AppPayload(plaintext) => {
                            // Business envelope first (binary).
                            if let Some(env) = BusinessEnvelope::decode(&plaintext)
                                && env.kind == BusinessEnvelopeKind::RemoteDesktopFrame {
                                    if let Some(cb) = &callback {
                                        cb(TcpControlEvent::RemoteDesktopFrame {
                                            peer_addr,
                                            connection_id: connection_id.clone(),
                                            peer_device_id: peer_device_id.clone(),
                                            timestamp_ns: env.timestamp_ns,
                                            payload: env.payload,
                                        });
                                    }
                                    continue;
                                }

                            // JSON AppMessage.
                            if let Ok(msg) = serde_json::from_slice::<AppMessage>(&plaintext) {
                                match msg {
                                    AppMessage::PairingIdentityExchange(payload) => {
                                        let device_id = payload.device_id.trim().to_string();
                                        if !device_id.is_empty() {
                                            let actual_fingerprint =
                                                peer_fingerprint.as_deref().unwrap_or_default();
                                            enforce_inbound_trust_policy(
                                                trust_policy,
                                                &device_id,
                                                actual_fingerprint,
                                            )?;
                                            peer_device_id = Some(device_id.clone());
                                            channel.set_peer_device_id(Some(device_id.clone()));

                                            if let (Some(signing_algorithm), Some(fingerprint)) =
                                                (peer_signing_algorithm, peer_fingerprint.as_ref())
                                            {
                                                let mut store = TrustStore::load().map_err(|err| {
                                                    P2PError::Protocol(format!(
                                                        "trust store unavailable: {}",
                                                        err
                                                    ))
                                                })?;
                                                let peer_identity = crate::p2p::types::PeerIdentity {
                                                    device_id: device_id.clone(),
                                                    public_key_fingerprint: fingerprint.clone(),
                                                    signing_algorithm,
                                                    signing_public_key: Vec::new(),
                                                    kem_public_key: Vec::new(),
                                                    platform: crate::discovery::Platform::Unknown,
                                                    protocol_version: "tcp-control".to_string(),
                                                };
                                                let _ = store.upsert_peer_identity(&peer_identity);
                                            }

                                            if let (Some(store), Some(peer_id), Some(session_keys)) =
                                                (
                                                    transfer_keys.as_ref(),
                                                    peer_device_id.as_ref(),
                                                    established_session_keys.as_ref(),
                                                )
                                            {
                                                store.register(peer_id.clone(), session_keys.clone());
                                            }
                                        } else if trust_policy.block_unknown {
                                            return Err(P2PError::TrustPolicyViolation(
                                                "Unknown device blocked: missing pairing device ID"
                                                    .to_string(),
                                            ));
                                        }
                                        persist_peer_kem_keys(&payload);
                                        // Best-effort: reply with our bundle (idempotent).
                                        if pending_pairing_reply
                                            && identity.supported_suites.iter().any(|s| s.is_pqc())
                                            && let Ok(bytes) = serde_json::to_vec(&build_pairing_identity_exchange(&identity)) {
                                                let sealed = channel.encrypt_app_payload(&bytes)?;
                                                send_raw_frame(&mut writer, &sealed, max_frame_size).await?;
                                                pending_pairing_reply = false;
                                            }
                                    }
                                    AppMessage::Ping(p) => {
                                        let pong = AppMessage::Pong(crate::p2p::PongPayload { id: p.id });
                                        if let Ok(bytes) = serde_json::to_vec(&pong) {
                                            let sealed = channel.encrypt_app_payload(&bytes)?;
                                            send_raw_frame(&mut writer, &sealed, max_frame_size).await?;
                                        }
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }
                }
            }
            msg_opt = async {
                match app_rx.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => None,
                }
            }, if app_rx.is_some() => {
                match msg_opt {
                    Some(msg) => {
                        if !established {
                            queued_app_plaintexts.push(msg);
                            continue;
                        }
                        let sealed = channel.encrypt_app_payload(&msg)?;
                        send_raw_frame(&mut writer, &sealed, max_frame_size).await?;
                    }
                    None => {
                        // Sender dropped; disable branch.
                        app_rx = None;
                    }
                }
            }
        }
    }

    if let Some(pair_key) = established_pair_key {
        PeerSessionArbiter::shared().clear_established(pair_key);
    }

    if let Some(cb) = &callback {
        cb(TcpControlEvent::Disconnected {
            peer_addr,
            connection_id,
        });
    }
    Ok(())
}

struct SoaOutgoingGuard {
    pair_key: [u8; 64],
    attempt_id: [u8; 16],
}

impl Drop for SoaOutgoingGuard {
    fn drop(&mut self) {
        PeerSessionArbiter::shared().clear_outgoing(self.pair_key, Some(self.attempt_id));
    }
}
