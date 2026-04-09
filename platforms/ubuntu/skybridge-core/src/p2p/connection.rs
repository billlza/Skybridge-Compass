//! P2P Connection
//!
//! Connection management and session handling.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::Once;
use std::time::Duration;

use bytes::Bytes;
use parking_lot::Mutex;
use quinn::crypto::rustls::QuicClientConfig;
use quinn::{Endpoint, RecvStream, SendStream};
use rcgen::generate_simple_self_signed;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use tokio::io::AsyncWriteExt;
use tokio::sync::{RwLock, mpsc};
use tracing::{debug, info, warn};

use super::TrustStore;
use super::driver::{HandshakeDriver, LocalIdentity};
use super::messages::{HandshakeMessage, P2PMessage, P2PMessageType};
use super::types::{HandshakePolicy, LogicalChannel, P2PError, SessionKeys};
use crate::crypto::provider::CryptoProvider;
use crate::remote::{
    UltraStreamCodec, UltraStreamDecoder, UltraStreamReceiver, UltraStreamSender,
    UltraStreamSession, UltraStreamSink,
};
use crate::transfer::TransferKeyStore;

const QUIC_SERVER_NAME: &str = "skybridge";
const MAX_P2P_MESSAGE_SIZE: usize = 16 * 1024 * 1024;
type ConnectionEstablishedCallback = Arc<dyn Fn(String, Option<String>) + Send + Sync>;
static RUSTLS_PROVIDER_INIT: Once = Once::new();

#[derive(Debug)]
struct SkipServerVerification;

impl ServerCertVerifier for SkipServerVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::ED25519,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PKCS1_SHA256,
        ]
    }
}

/// P2P connection state
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionState {
    /// Connection is being established
    Connecting,
    /// Handshake in progress
    Handshaking,
    /// Connection is established
    Connected,
    /// Connection is closing
    Closing,
    /// Connection is closed
    Closed,
}

/// A P2P connection
pub struct P2PConnection {
    /// Connection ID
    pub id: String,
    /// Remote address
    pub remote_addr: SocketAddr,
    /// Connection state
    state: ConnectionState,
    /// Session keys (after handshake)
    session_keys: Option<SessionKeys>,
    /// Handshake driver (while in progress)
    handshake: Option<HandshakeDriver>,
    /// UltraStream session (video channel)
    ultrastream: Option<Arc<Mutex<UltraStreamSession>>>,
    /// Peer device ID (if known)
    peer_id: Option<String>,
    /// Transfer key store (optional)
    transfer_keys: Option<Arc<TransferKeyStore>>,
    /// Crypto provider
    crypto: Option<CryptoProvider>,
    /// Message sender
    tx: mpsc::Sender<P2PMessage>,
    /// Sequence counters per channel
    sequence_counters: HashMap<LogicalChannel, u32>,
}

impl P2PConnection {
    /// Create a new connection
    pub fn new(id: String, remote_addr: SocketAddr, tx: mpsc::Sender<P2PMessage>) -> Self {
        Self {
            id,
            remote_addr,
            state: ConnectionState::Connecting,
            session_keys: None,
            peer_id: None,
            transfer_keys: None,
            ultrastream: None,
            handshake: None,
            crypto: None,
            tx,
            sequence_counters: HashMap::new(),
        }
    }

    /// Get connection state
    pub fn state(&self) -> ConnectionState {
        self.state
    }

    /// Check if connection is established
    pub fn is_connected(&self) -> bool {
        self.state == ConnectionState::Connected
    }

    /// Set session keys after handshake
    pub fn set_session_keys(&mut self, keys: SessionKeys) {
        let crypto = CryptoProvider::new(keys.suite_id);
        self.crypto = Some(crypto);
        self.session_keys = Some(keys);
        self.state = ConnectionState::Connected;

        if let (Some(peer_id), Some(store)) = (self.peer_id.as_ref(), self.transfer_keys.as_ref())
            && let Some(session_keys) = self.session_keys.as_ref()
        {
            store.register(peer_id.clone(), session_keys.clone());
        }
    }

    /// Get session keys if established
    pub fn session_keys(&self) -> Option<&SessionKeys> {
        self.session_keys.as_ref()
    }

    /// Set peer device ID (for transfer key registration).
    pub fn set_peer_id(&mut self, peer_id: impl Into<String>) {
        self.peer_id = Some(peer_id.into());
    }

    /// Get peer device ID if known.
    pub fn peer_id(&self) -> Option<&str> {
        self.peer_id.as_deref()
    }

    /// Bind a transfer key store for automatic registration.
    pub fn set_transfer_key_store(&mut self, store: Arc<TransferKeyStore>) {
        self.transfer_keys = Some(store);
    }

    /// Store a handshake driver (in-progress).
    pub fn set_handshake_driver(&mut self, driver: HandshakeDriver) {
        self.handshake = Some(driver);
    }

    /// Take the handshake driver out of the connection.
    pub fn take_handshake_driver(&mut self) -> Option<HandshakeDriver> {
        self.handshake.take()
    }

    /// Get a sender for raw P2P messages (used before encryption is established).
    pub fn sender(&self) -> mpsc::Sender<P2PMessage> {
        self.tx.clone()
    }

    /// Enable UltraStream video decoding for this connection.
    pub fn enable_ultrastream(
        &mut self,
        decoder: Box<dyn UltraStreamDecoder + Send>,
        sink: Box<dyn UltraStreamSink + Send>,
    ) -> Result<(), P2PError> {
        let keys = self
            .session_keys
            .as_ref()
            .ok_or(P2PError::SessionNotEstablished)?;
        let receiver = UltraStreamReceiver::new_with_session_keys(keys)
            .map_err(|err| P2PError::Protocol(format!("UltraStream init failed: {}", err)))?;
        self.ultrastream = Some(Arc::new(Mutex::new(UltraStreamSession::new(
            receiver, decoder, sink,
        ))));
        Ok(())
    }

    /// Send a message on a channel
    pub async fn send(
        &mut self,
        channel: LogicalChannel,
        payload: Vec<u8>,
    ) -> Result<(), P2PError> {
        self.send_with_type(P2PMessageType::FileChunk, channel, payload)
            .await
    }

    /// Send a message with an explicit message type.
    pub async fn send_with_type(
        &mut self,
        message_type: P2PMessageType,
        channel: LogicalChannel,
        payload: Vec<u8>,
    ) -> Result<(), P2PError> {
        if !self.is_connected() {
            return Err(P2PError::SessionNotEstablished);
        }

        let keys = self.session_keys.as_ref().unwrap();
        let crypto = self.crypto.as_ref().unwrap();

        // Get sequence number
        let seq = self.sequence_counters.entry(channel).or_insert(0);
        *seq = seq.wrapping_add(1);

        // Encrypt payload
        let encrypted = crypto.encrypt(
            keys.send_key_for_channel(channel),
            &payload,
            &[channel.channel_id()],
        )?;

        let message = P2PMessage {
            message_type,
            channel: channel.channel_id(),
            sequence: *seq,
            payload: encrypted.to_bytes(),
        };

        self.tx
            .send(message)
            .await
            .map_err(|_| P2PError::ChannelClosed)?;

        Ok(())
    }

    /// Send UltraStream packets over the video channel.
    pub async fn send_ultrastream_packets(
        &mut self,
        packets: Vec<Vec<u8>>,
    ) -> Result<(), P2PError> {
        for packet in packets {
            self.send_with_type(P2PMessageType::VideoFrame, LogicalChannel::Video, packet)
                .await?;
        }
        Ok(())
    }

    /// Encode and send a single UltraStream frame.
    pub async fn send_ultrastream_frame(
        &mut self,
        sender: &mut UltraStreamSender,
        codec: UltraStreamCodec,
        width: u16,
        height: u16,
        timestamp_ms: u32,
        data: &[u8],
    ) -> Result<(), P2PError> {
        let packets = sender
            .encode_frame(codec, width, height, timestamp_ms, data)
            .map_err(|err| P2PError::Protocol(format!("UltraStream encode: {}", err)))?;
        self.send_ultrastream_packets(packets).await
    }

    /// Receive and decrypt a message
    pub fn decrypt_message(&self, message: &P2PMessage) -> Result<Vec<u8>, P2PError> {
        if !self.is_connected() {
            return Err(P2PError::SessionNotEstablished);
        }

        let keys = self.session_keys.as_ref().unwrap();
        let crypto = self.crypto.as_ref().unwrap();

        let channel = LogicalChannel::from_channel_id(message.channel)
            .ok_or_else(|| P2PError::InvalidMessage("Unknown channel".to_string()))?;

        let encrypted = crate::crypto::aead::EncryptedData::from_bytes(
            &message.payload,
            12, // nonce size
        )
        .ok_or_else(|| P2PError::InvalidMessage("Invalid encrypted data".to_string()))?;

        crypto
            .decrypt(
                keys.recv_key_for_channel(channel),
                &encrypted,
                &[channel.channel_id()],
            )
            .map_err(P2PError::from)
    }

    /// Handle an incoming video message (UltraStream payload).
    pub fn handle_video_message(&mut self, message: &P2PMessage) -> Result<(), P2PError> {
        if message.message_type != P2PMessageType::VideoFrame {
            return Err(P2PError::InvalidMessage(
                "Expected video frame message".to_string(),
            ));
        }
        let channel = LogicalChannel::from_channel_id(message.channel)
            .ok_or_else(|| P2PError::InvalidMessage("Unknown channel".to_string()))?;
        if channel != LogicalChannel::Video {
            return Err(P2PError::InvalidMessage(
                "Video message on non-video channel".to_string(),
            ));
        }

        let payload = self.decrypt_message(message)?;
        let session = self
            .ultrastream
            .as_ref()
            .ok_or_else(|| P2PError::Protocol("UltraStream session not initialized".to_string()))?;
        let mut guard = session.lock();
        guard
            .handle_packet(&payload)
            .map_err(|err| P2PError::Protocol(format!("UltraStream error: {}", err)))?;
        Ok(())
    }

    /// Send a handshake message over the control channel (unencrypted).
    pub async fn send_handshake_message(&self, message: HandshakeMessage) -> Result<(), P2PError> {
        let msg = P2PMessage {
            message_type: message.message_type(),
            channel: LogicalChannel::Control.channel_id(),
            sequence: 0,
            payload: message.to_bytes(),
        };
        self.tx.send(msg).await.map_err(|_| P2PError::ChannelClosed)
    }

    /// Close the connection
    pub async fn close(&mut self) -> Result<(), P2PError> {
        self.state = ConnectionState::Closing;

        let message = P2PMessage::new(P2PMessageType::Close, 0, Vec::new());
        let _ = self.tx.send(message).await;

        self.state = ConnectionState::Closed;
        Ok(())
    }
}

/// Connection manager
pub struct P2PConnectionManager {
    /// Local identity
    identity: Arc<LocalIdentity>,
    /// Active connections
    connections: Arc<RwLock<HashMap<String, Arc<RwLock<P2PConnection>>>>>,
    /// QUIC endpoint (simplified for now)
    local_addr: SocketAddr,
    /// QUIC endpoint for transport
    endpoint: Arc<Endpoint>,
    /// Optional transfer key store for auto-registration
    transfer_keys: Option<Arc<TransferKeyStore>>,
    /// Connection established callback
    on_connection_established: Option<ConnectionEstablishedCallback>,
}

impl P2PConnectionManager {
    /// Create a new connection manager
    pub fn new(identity: LocalIdentity, bind_addr: SocketAddr) -> Result<Self, P2PError> {
        let identity = Arc::new(identity);
        let endpoint = Self::build_endpoint(&identity, bind_addr)?;
        Ok(Self {
            identity,
            connections: Arc::new(RwLock::new(HashMap::new())),
            local_addr: bind_addr,
            endpoint,
            transfer_keys: None,
            on_connection_established: None,
        })
    }

    /// Set a callback invoked when a connection becomes established.
    pub fn on_connection_established<F>(&mut self, callback: F)
    where
        F: Fn(String, Option<String>) + Send + Sync + 'static,
    {
        self.on_connection_established = Some(Arc::new(callback));
    }

    fn build_endpoint(
        identity: &Arc<LocalIdentity>,
        bind_addr: SocketAddr,
    ) -> Result<Arc<Endpoint>, P2PError> {
        Self::ensure_rustls_crypto_provider();
        let server_config = Self::build_server_config(identity)?;
        let mut endpoint = Endpoint::server(server_config, bind_addr)
            .map_err(|err| P2PError::ConnectionFailed(format!("QUIC bind failed: {}", err)))?;

        let client_config = Self::build_client_config()?;
        endpoint.set_default_client_config(client_config);
        Ok(Arc::new(endpoint))
    }

    fn ensure_rustls_crypto_provider() {
        RUSTLS_PROVIDER_INIT.call_once(|| {
            let _ = rustls::crypto::ring::default_provider().install_default();
        });
    }

    fn build_server_config(identity: &LocalIdentity) -> Result<quinn::ServerConfig, P2PError> {
        let subject = format!("{}@skybridge", identity.device_id);
        let rcgen::CertifiedKey { cert, signing_key } = generate_simple_self_signed(vec![subject])
            .map_err(|err| {
                P2PError::Protocol(format!("QUIC certificate generation failed: {}", err))
            })?;
        let cert_der = cert.der().to_vec();
        let key_der = signing_key.serialize_der();
        let cert_chain = vec![CertificateDer::from(cert_der)];
        let key = PrivateKeyDer::from(PrivatePkcs8KeyDer::from(key_der));

        let mut server_config = quinn::ServerConfig::with_single_cert(cert_chain, key)
            .map_err(|err| P2PError::Protocol(format!("QUIC server config failed: {}", err)))?;
        let mut transport = quinn::TransportConfig::default();
        transport.keep_alive_interval(Some(Duration::from_secs(5)));
        transport.max_concurrent_bidi_streams(64_u32.into());
        transport.max_concurrent_uni_streams(64_u32.into());
        transport.datagram_receive_buffer_size(Some(1_048_576));
        transport.datagram_send_buffer_size(1_048_576);
        server_config.transport = Arc::new(transport);
        Ok(server_config)
    }

    fn build_client_config() -> Result<quinn::ClientConfig, P2PError> {
        let mut crypto = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(SkipServerVerification))
            .with_no_client_auth();
        crypto.alpn_protocols = vec![b"skybridge-p2p".to_vec()];

        let quic_crypto = QuicClientConfig::try_from(crypto)
            .map_err(|err| P2PError::Protocol(format!("QUIC client config failed: {}", err)))?;
        let mut config = quinn::ClientConfig::new(Arc::new(quic_crypto));
        let mut transport = quinn::TransportConfig::default();
        transport.keep_alive_interval(Some(Duration::from_secs(5)));
        transport.datagram_receive_buffer_size(Some(1_048_576));
        transport.datagram_send_buffer_size(1_048_576);
        config.transport_config(Arc::new(transport));
        Ok(config)
    }

    /// Start accepting incoming QUIC connections.
    pub fn start(&self) -> Result<(), P2PError> {
        let endpoint = Arc::clone(&self.endpoint);
        let connections = Arc::clone(&self.connections);
        let identity = Arc::clone(&self.identity);
        let transfer_keys = self.transfer_keys.clone();
        let on_connection_established = self.on_connection_established.clone();

        tokio::spawn(async move {
            loop {
                let incoming = match endpoint.accept().await {
                    Some(incoming) => incoming,
                    None => break,
                };
                let connections = Arc::clone(&connections);
                let identity = Arc::clone(&identity);
                let transfer_keys = transfer_keys.clone();
                let on_connection_established = on_connection_established.clone();
                tokio::spawn(async move {
                    let remote = incoming.remote_address();
                    match incoming.await {
                        Ok(connection) => {
                            let connection_id = uuid::Uuid::new_v4().to_string();
                            let (tx, rx) = mpsc::channel(256);
                            let mut p2p_connection =
                                P2PConnection::new(connection_id.clone(), remote, tx);
                            if let Some(store) = transfer_keys.as_ref() {
                                p2p_connection.set_transfer_key_store(Arc::clone(store));
                            }

                            let connection_arc = Arc::new(RwLock::new(p2p_connection));
                            {
                                let mut map = connections.write().await;
                                map.insert(connection_id.clone(), Arc::clone(&connection_arc));
                            }

                            Self::spawn_quic_tasks(
                                connection_id,
                                connection,
                                rx,
                                connections,
                                identity,
                                on_connection_established,
                            );
                        }
                        Err(err) => {
                            warn!("QUIC accept failed: {}", err);
                        }
                    }
                });
            }
        });

        Ok(())
    }

    /// Attach a transfer key store for new connections.
    pub fn set_transfer_key_store(&mut self, store: Arc<TransferKeyStore>) {
        self.transfer_keys = Some(store);
    }

    /// Get local address
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// Connect to a peer
    pub async fn connect(&self, addr: SocketAddr) -> Result<String, P2PError> {
        info!("Connecting to peer at {}", addr);
        let connecting = self
            .endpoint
            .connect(addr, QUIC_SERVER_NAME)
            .map_err(|err| P2PError::ConnectionFailed(format!("QUIC connect failed: {}", err)))?;
        let connection = connecting
            .await
            .map_err(|err| P2PError::ConnectionFailed(format!("QUIC handshake failed: {}", err)))?;

        let connection_id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = mpsc::channel(256);

        let mut p2p_connection =
            P2PConnection::new(connection_id.clone(), connection.remote_address(), tx);
        if let Some(store) = self.transfer_keys.as_ref() {
            p2p_connection.set_transfer_key_store(Arc::clone(store));
        }

        let connection_arc = Arc::new(RwLock::new(p2p_connection));
        {
            let mut connections = self.connections.write().await;
            connections.insert(connection_id.clone(), Arc::clone(&connection_arc));
        }

        Self::spawn_quic_tasks(
            connection_id.clone(),
            connection,
            rx,
            Arc::clone(&self.connections),
            Arc::clone(&self.identity),
            self.on_connection_established.clone(),
        );

        Ok(connection_id)
    }

    /// Get a connection by ID
    pub async fn get_connection(&self, id: &str) -> Option<Arc<RwLock<P2PConnection>>> {
        let connections = self.connections.read().await;
        connections.get(id).cloned()
    }

    /// Remove a connection
    pub async fn remove_connection(&self, id: &str) {
        let mut connections = self.connections.write().await;
        connections.remove(id);
    }

    /// Get all connection IDs
    pub async fn connection_ids(&self) -> Vec<String> {
        let connections = self.connections.read().await;
        connections.keys().cloned().collect()
    }

    /// Perform handshake on a connection
    pub async fn handshake(&self, connection_id: &str) -> Result<(), P2PError> {
        self.handshake_with_peer_hint(connection_id, None, None, HandshakePolicy::default())
            .await
    }

    /// Perform handshake with optional peer device ID (enables PQC KEM pre-share)
    pub async fn handshake_with_peer(
        &self,
        connection_id: &str,
        peer_device_id: Option<&str>,
        policy: HandshakePolicy,
    ) -> Result<(), P2PError> {
        self.handshake_with_peer_hint(connection_id, peer_device_id, None, policy)
            .await
    }

    /// Perform handshake with optional peer device ID and expected fingerprint hints.
    pub async fn handshake_with_peer_hint(
        &self,
        connection_id: &str,
        peer_device_id: Option<&str>,
        expected_peer_fingerprint: Option<&str>,
        policy: HandshakePolicy,
    ) -> Result<(), P2PError> {
        let connection = self
            .get_connection(connection_id)
            .await
            .ok_or_else(|| P2PError::ConnectionFailed("Connection not found".to_string()))?;

        if let Some(peer_id) = peer_device_id {
            let mut conn = connection.write().await;
            conn.set_peer_id(peer_id.to_string());
            if let Some(store) = self.transfer_keys.as_ref() {
                conn.set_transfer_key_store(Arc::clone(store));
            }
        }

        let peer_id_hint = peer_device_id.map(|id| id.to_string());

        // Create handshake driver
        let identity = self.identity.as_ref().clone();

        let mut driver = if let Some(peer_id) = peer_device_id {
            let peer_keys = TrustStore::load()
                .ok()
                .map(|store| store.peer_kem_keys(peer_id))
                .unwrap_or_default();
            if peer_keys.is_empty() {
                HandshakeDriver::new_initiator_with_policy(identity, policy)
            } else {
                HandshakeDriver::new_initiator_with_peer_keys(identity, policy, peer_keys)
            }
        } else {
            HandshakeDriver::new_initiator_with_policy(identity, policy)
        };

        driver.set_peer_device_id(peer_id_hint.clone());
        driver.set_expected_peer_fingerprint(expected_peer_fingerprint.map(|s| s.to_string()));

        // Start handshake
        let message_a = driver.start().await?;

        {
            let mut conn = connection.write().await;
            conn.set_handshake_driver(driver);
        }

        let tx = {
            let conn = connection.read().await;
            conn.sender()
        };

        let outgoing = Self::wrap_handshake_message(message_a);
        tx.send(outgoing)
            .await
            .map_err(|_| P2PError::ChannelClosed)?;

        debug!("Handshake started for connection {}", connection_id);

        Ok(())
    }

    /// Handle an incoming P2P message.
    pub async fn handle_incoming_message(
        &self,
        connection_id: &str,
        message: P2PMessage,
    ) -> Result<(), P2PError> {
        Self::handle_incoming_message_with(
            Arc::clone(&self.connections),
            Arc::clone(&self.identity),
            self.on_connection_established.clone(),
            connection_id,
            message,
        )
        .await
    }

    async fn handle_incoming_message_with(
        connections: Arc<RwLock<HashMap<String, Arc<RwLock<P2PConnection>>>>>,
        identity: Arc<LocalIdentity>,
        on_connection_established: Option<ConnectionEstablishedCallback>,
        connection_id: &str,
        message: P2PMessage,
    ) -> Result<(), P2PError> {
        let connection = {
            let map = connections.read().await;
            map.get(connection_id).cloned()
        }
        .ok_or_else(|| P2PError::ConnectionFailed("Connection not found".to_string()))?;

        match message.message_type {
            P2PMessageType::HandshakeInit
            | P2PMessageType::HandshakeResponse
            | P2PMessageType::HandshakeFinished
            | P2PMessageType::HandshakeError => {
                let (established, peer_id) =
                    Self::handle_handshake_message_with(identity, connection, message).await?;
                if established && let Some(callback) = on_connection_established {
                    callback(connection_id.to_string(), peer_id);
                }
                Ok(())
            }
            P2PMessageType::VideoFrame => {
                let mut conn = connection.write().await;
                conn.handle_video_message(&message)?;
                Ok(())
            }
            _ => {
                let conn = connection.read().await;
                let _ = conn.decrypt_message(&message)?;
                Ok(())
            }
        }
    }

    async fn handle_handshake_message_with(
        identity: Arc<LocalIdentity>,
        connection: Arc<RwLock<P2PConnection>>,
        message: P2PMessage,
    ) -> Result<(bool, Option<String>), P2PError> {
        let handshake_message = HandshakeMessage::from_bytes(&message.payload)?;
        let is_init = message.message_type == P2PMessageType::HandshakeInit;

        let mut driver = {
            let mut conn = connection.write().await;
            if let Some(driver) = conn.take_handshake_driver() {
                driver
            } else if is_init {
                let mut responder = HandshakeDriver::new_responder_with_policy(
                    identity.as_ref().clone(),
                    HandshakePolicy::default(),
                );
                if let Some(peer_id) = conn.peer_id() {
                    responder.set_peer_device_id(Some(peer_id.to_string()));
                }
                responder
            } else {
                return Err(P2PError::Protocol("Handshake not initiated".to_string()));
            }
        };

        let response = driver.process_message(handshake_message).await?;
        let established = driver.state().is_established();
        let session_keys = driver.session_keys().cloned();
        let peer_identity = driver.peer_identity().cloned();

        let mut established_peer: Option<String> = None;
        {
            let mut conn = connection.write().await;
            if let Some(identity) = peer_identity.as_ref()
                && !identity.device_id.is_empty()
                && conn.peer_id().is_none()
            {
                conn.set_peer_id(identity.device_id.clone());
            }
            if established {
                if let Some(keys) = session_keys {
                    conn.set_session_keys(keys);
                }
                established_peer = conn.peer_id().map(|id| id.to_string()).or_else(|| {
                    peer_identity
                        .as_ref()
                        .map(|peer| peer.device_id.clone())
                        .filter(|id| !id.is_empty())
                });
            } else {
                conn.set_handshake_driver(driver);
            }
        }

        if let Some(outgoing) = response {
            let tx = {
                let conn = connection.read().await;
                conn.sender()
            };
            tx.send(Self::wrap_handshake_message(outgoing))
                .await
                .map_err(|_| P2PError::ChannelClosed)?;
        }

        Ok((established, established_peer))
    }

    fn wrap_handshake_message(message: HandshakeMessage) -> P2PMessage {
        P2PMessage {
            message_type: message.message_type(),
            channel: LogicalChannel::Control.channel_id(),
            sequence: 0,
            payload: message.to_bytes(),
        }
    }

    fn spawn_quic_tasks(
        connection_id: String,
        connection: quinn::Connection,
        rx: mpsc::Receiver<P2PMessage>,
        connections: Arc<RwLock<HashMap<String, Arc<RwLock<P2PConnection>>>>>,
        identity: Arc<LocalIdentity>,
        on_connection_established: Option<ConnectionEstablishedCallback>,
    ) {
        let send_conn = connection.clone();
        tokio::spawn(async move {
            if let Err(err) = Self::send_loop(send_conn, rx).await {
                warn!("QUIC send loop ended: {}", err);
            }
        });

        tokio::spawn(async move {
            Self::recv_loop(
                connection_id,
                connection,
                connections,
                identity,
                on_connection_established,
            )
            .await;
        });
    }

    async fn send_loop(
        connection: quinn::Connection,
        mut rx: mpsc::Receiver<P2PMessage>,
    ) -> Result<(), P2PError> {
        let mut stream = connection
            .open_uni()
            .await
            .map_err(|err| P2PError::ConnectionFailed(format!("Open stream failed: {}", err)))?;

        while let Some(message) = rx.recv().await {
            let bytes = message.to_bytes();
            if message.message_type == P2PMessageType::VideoFrame {
                if let Err(err) = connection.send_datagram(Bytes::from(bytes)) {
                    warn!("Failed to send video datagram: {}", err);
                }
                continue;
            }

            Self::write_framed(&mut stream, &bytes).await?;
        }

        let _ = stream.finish();
        Ok(())
    }

    async fn recv_loop(
        connection_id: String,
        connection: quinn::Connection,
        connections: Arc<RwLock<HashMap<String, Arc<RwLock<P2PConnection>>>>>,
        identity: Arc<LocalIdentity>,
        on_connection_established: Option<ConnectionEstablishedCallback>,
    ) {
        loop {
            tokio::select! {
                uni = connection.accept_uni() => {
                    match uni {
                        Ok(stream) => {
                            let connections = Arc::clone(&connections);
                            let identity = Arc::clone(&identity);
                            let id = connection_id.clone();
                            let on_connection_established = on_connection_established.clone();
                            tokio::spawn(async move {
                                Self::read_stream(
                                    id,
                                    stream,
                                    connections,
                                    identity,
                                    on_connection_established.clone(),
                                )
                                .await;
                            });
                        }
                        Err(err) => {
                            warn!("QUIC accept_uni failed: {}", err);
                            break;
                        }
                    }
                }
                bi = connection.accept_bi() => {
                    match bi {
                        Ok((_send, recv)) => {
                            let connections = Arc::clone(&connections);
                            let identity = Arc::clone(&identity);
                            let id = connection_id.clone();
                            let on_connection_established = on_connection_established.clone();
                            tokio::spawn(async move {
                                Self::read_stream(
                                    id,
                                    recv,
                                    connections,
                                    identity,
                                    on_connection_established.clone(),
                                )
                                .await;
                            });
                        }
                        Err(err) => {
                            warn!("QUIC accept_bi failed: {}", err);
                            break;
                        }
                    }
                }
                datagram = connection.read_datagram() => {
                    match datagram {
                        Ok(bytes) => {
                            if let Ok(message) = P2PMessage::from_bytes(&bytes) {
                                let _ = Self::handle_incoming_message_with(
                                    Arc::clone(&connections),
                                    Arc::clone(&identity),
                                    on_connection_established.clone(),
                                    &connection_id,
                                    message,
                                ).await;
                            } else {
                                warn!("Dropped invalid QUIC datagram");
                            }
                        }
                        Err(err) => {
                            warn!("QUIC datagram receive failed: {}", err);
                            break;
                        }
                    }
                }
            }
        }
    }

    async fn read_stream(
        connection_id: String,
        mut stream: RecvStream,
        connections: Arc<RwLock<HashMap<String, Arc<RwLock<P2PConnection>>>>>,
        identity: Arc<LocalIdentity>,
        on_connection_established: Option<ConnectionEstablishedCallback>,
    ) {
        loop {
            let mut len_buf = [0u8; 4];
            if let Err(err) = stream.read_exact(&mut len_buf).await {
                debug!("QUIC stream closed: {}", err);
                break;
            }
            let len = u32::from_be_bytes(len_buf) as usize;
            if len == 0 || len > MAX_P2P_MESSAGE_SIZE {
                warn!("Invalid P2P message length: {}", len);
                break;
            }

            let mut buf = vec![0u8; len];
            if let Err(err) = stream.read_exact(&mut buf).await {
                debug!("QUIC stream read failed: {}", err);
                break;
            }

            match P2PMessage::from_bytes(&buf) {
                Ok(message) => {
                    let _ = Self::handle_incoming_message_with(
                        Arc::clone(&connections),
                        Arc::clone(&identity),
                        on_connection_established.clone(),
                        &connection_id,
                        message,
                    )
                    .await;
                }
                Err(err) => {
                    warn!("Dropped invalid P2P message: {}", err);
                }
            }
        }
    }

    async fn write_framed(stream: &mut SendStream, payload: &[u8]) -> Result<(), P2PError> {
        if payload.len() > MAX_P2P_MESSAGE_SIZE {
            return Err(P2PError::InvalidMessage("message too large".to_string()));
        }
        let len = payload.len() as u32;
        stream
            .write_all(&len.to_be_bytes())
            .await
            .map_err(|err| P2PError::Protocol(format!("QUIC write failed: {}", err)))?;
        stream
            .write_all(payload)
            .await
            .map_err(|err| P2PError::Protocol(format!("QUIC write failed: {}", err)))?;
        stream
            .flush()
            .await
            .map_err(|err| P2PError::Protocol(format!("QUIC flush failed: {}", err)))?;
        Ok(())
    }
}
