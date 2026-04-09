//! P2P Types
//!
//! Core types for P2P connections and handshake protocol.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::crypto::signature::SignatureAlgorithm;
use crate::crypto::suite::CryptoSuiteId;

/// P2P errors
#[derive(Debug, Error)]
pub enum P2PError {
    /// Connection failed
    #[error("Connection failed: {0}")]
    ConnectionFailed(String),

    /// Handshake failed
    #[error("Handshake failed: {reason}")]
    HandshakeFailed { reason: String },

    /// Timeout
    #[error("Operation timed out")]
    Timeout,

    /// Protocol error
    #[error("Protocol error: {0}")]
    Protocol(String),

    /// Crypto error
    #[error("Crypto error: {0}")]
    Crypto(#[from] crate::crypto::provider::CryptoError),

    /// IO error
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    /// Signature verification failed
    #[error("Signature verification failed")]
    SignatureVerificationFailed,

    /// No common crypto suite
    #[error("No common crypto suite available")]
    NoCommonSuite,

    /// Invalid message
    #[error("Invalid message: {0}")]
    InvalidMessage(String),

    /// Session not established
    #[error("Session not established")]
    SessionNotEstablished,

    /// Channel closed
    #[error("Channel closed")]
    ChannelClosed,

    /// Local trust policy rejected the peer or connection attempt.
    #[error("Trust policy violation: {0}")]
    TrustPolicyViolation(String),
}

/// Role in the handshake protocol
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HandshakeRole {
    /// Initiator (sends MessageA first)
    Initiator,
    /// Responder (waits for MessageA)
    Responder,
}

impl HandshakeRole {
    /// Get the opposite role
    pub fn opposite(&self) -> Self {
        match self {
            Self::Initiator => Self::Responder,
            Self::Responder => Self::Initiator,
        }
    }
}

/// Minimum security tier for handshake policy (macOS-compatible strings)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CryptoTier {
    /// Native PQC (iOS 26+/macOS 26+)
    NativePqc,
    /// liboqs PQC
    LiboqsPqc,
    /// Classic-only
    Classic,
}

impl CryptoTier {
    pub fn as_str(&self) -> &'static str {
        match self {
            CryptoTier::NativePqc => "nativePQC",
            CryptoTier::LiboqsPqc => "liboqsPQC",
            CryptoTier::Classic => "classic",
        }
    }

    #[allow(clippy::should_implement_trait)]
    pub fn from_str(value: &str) -> Option<Self> {
        match value {
            "nativePQC" => Some(CryptoTier::NativePqc),
            "liboqsPQC" => Some(CryptoTier::LiboqsPqc),
            "classic" => Some(CryptoTier::Classic),
            _ => None,
        }
    }
}

impl std::str::FromStr for CryptoTier {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        CryptoTier::from_str(s).ok_or(())
    }
}

/// Handshake policy (mirrors macOS/iOS policy gates)
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct HandshakePolicy {
    /// Require PQC (no classic-only negotiation)
    pub require_pqc: bool,
    /// Allow classic-only fallback
    pub allow_classic_fallback: bool,
    /// Minimum acceptable tier
    pub minimum_tier: CryptoTier,
    /// Require Secure Enclave PoP (default false)
    pub require_secure_enclave_pop: bool,
}

impl HandshakePolicy {
    /// Default policy: prefer PQC, allow classic fallback
    pub fn default_policy() -> Self {
        Self {
            require_pqc: false,
            allow_classic_fallback: true,
            minimum_tier: CryptoTier::Classic,
            require_secure_enclave_pop: false,
        }
    }

    /// Strict PQC (no classic fallback)
    pub fn strict_pqc() -> Self {
        Self {
            require_pqc: true,
            allow_classic_fallback: false,
            minimum_tier: CryptoTier::NativePqc,
            require_secure_enclave_pop: false,
        }
    }

    /// Check if a suite is allowed by policy
    pub fn allows_suite(&self, suite: CryptoSuiteId) -> bool {
        if self.require_pqc && !suite.is_pqc() {
            return false;
        }
        match self.minimum_tier {
            CryptoTier::Classic => true,
            CryptoTier::NativePqc | CryptoTier::LiboqsPqc => suite.is_pqc(),
        }
    }

    /// Deterministic encoding for transcript/signature binding
    pub fn encode_bytes(&self) -> Vec<u8> {
        let mut encoder = crate::p2p::encoding::DeterministicEncoder::new();
        encoder.encode_bool(self.require_pqc);
        encoder.encode_bool(self.allow_classic_fallback);
        encoder.encode_string(self.minimum_tier.as_str());
        encoder.encode_bool(self.require_secure_enclave_pop);
        encoder.finalize()
    }

    /// Decode deterministic policy bytes
    pub fn decode_bytes(bytes: &[u8]) -> Option<Self> {
        let mut decoder = crate::p2p::encoding::DeterministicDecoder::new(bytes);
        let require_pqc = decoder.decode_bool()?;
        let allow_classic_fallback = decoder.decode_bool()?;
        let tier_raw = decoder.decode_string()?;
        let minimum_tier = CryptoTier::from_str(&tier_raw)?;
        let require_secure_enclave_pop = if decoder.is_at_end() {
            false
        } else {
            decoder.decode_bool()?
        };
        if !decoder.is_at_end() {
            return None;
        }
        Some(Self {
            require_pqc,
            allow_classic_fallback,
            minimum_tier,
            require_secure_enclave_pop,
        })
    }
}

impl Default for HandshakePolicy {
    fn default() -> Self {
        Self::default_policy()
    }
}

/// Handshake attempt strategy
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HandshakeAttemptStrategy {
    /// PQC/Hybrid only
    PqcOnly,
    /// Classic only
    ClassicOnly,
}

/// Handshake state machine
#[derive(Debug, Clone)]
pub enum HandshakeState {
    /// Initial state
    Idle,
    /// Sending MessageA (initiator only)
    SendingMessageA,
    /// Waiting for MessageB (initiator only)
    WaitingMessageB { deadline: std::time::Instant },
    /// Processing received MessageB
    ProcessingMessageB { epoch: u64 },
    /// Processing received MessageA (responder only)
    ProcessingMessageA,
    /// Sending MessageB (responder only)
    SendingMessageB,
    /// Waiting for FINISHED message
    WaitingFinished {
        deadline: std::time::Instant,
        session_keys: SessionKeys,
        expecting_from: HandshakeRole,
    },
    /// Handshake completed successfully
    Established { session_keys: SessionKeys },
    /// Handshake failed
    Failed { reason: HandshakeFailureReason },
}

impl HandshakeState {
    /// Check if handshake is complete
    pub fn is_established(&self) -> bool {
        matches!(self, Self::Established { .. })
    }

    /// Check if handshake failed
    pub fn is_failed(&self) -> bool {
        matches!(self, Self::Failed { .. })
    }

    /// Get session keys if established
    pub fn session_keys(&self) -> Option<&SessionKeys> {
        match self {
            Self::Established { session_keys } => Some(session_keys),
            Self::WaitingFinished { session_keys, .. } => Some(session_keys),
            _ => None,
        }
    }
}

/// Handshake failure reasons
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum HandshakeFailureReason {
    /// Timeout waiting for response
    Timeout,
    /// Signature verification failed
    SignatureVerificationFailed,
    /// No common crypto suite
    NoCommonSuite,
    /// Invalid message format
    InvalidMessage(String),
    /// Peer identity fingerprint mismatch
    IdentityMismatch { expected: String, actual: String },
    /// Suite negotiation failed
    SuiteNegotiationFailed,
    /// Unknown suite wire id was offered/selected.
    UnknownSuite { wire_id: u16 },
    /// Signature algorithm mismatch with offered suites
    SignatureAlgorithmMismatch,
    /// PQC not available (no suites after filtering)
    PqcUnavailable,
    /// Classic fallback blocked by policy
    ClassicFallbackNotAllowed,
    /// Connection lost
    ConnectionLost,
    /// Rejected by peer
    RejectedByPeer,
    /// Internal error
    InternalError(String),
}

impl std::fmt::Display for HandshakeFailureReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Timeout => write!(f, "Timeout"),
            Self::SignatureVerificationFailed => write!(f, "Signature verification failed"),
            Self::NoCommonSuite => write!(f, "No common crypto suite"),
            Self::InvalidMessage(msg) => write!(f, "Invalid message: {}", msg),
            Self::IdentityMismatch { expected, actual } => write!(
                f,
                "Identity mismatch (expected {}, got {})",
                expected, actual
            ),
            Self::SuiteNegotiationFailed => write!(f, "Suite negotiation failed"),
            Self::UnknownSuite { wire_id } => write!(f, "Unknown suite 0x{:04x}", wire_id),
            Self::SignatureAlgorithmMismatch => write!(f, "Signature algorithm mismatch"),
            Self::PqcUnavailable => write!(f, "PQC unavailable"),
            Self::ClassicFallbackNotAllowed => write!(f, "Classic fallback not allowed"),
            Self::ConnectionLost => write!(f, "Connection lost"),
            Self::RejectedByPeer => write!(f, "Rejected by peer"),
            Self::InternalError(msg) => write!(f, "Internal error: {}", msg),
        }
    }
}

/// Derived session keys
#[derive(Debug, Clone)]
pub struct SessionKeys {
    /// Send key for control channel (reliable, RPC/commands)
    pub send_control_key: Vec<u8>,
    /// Receive key for control channel
    pub recv_control_key: Vec<u8>,
    /// Send key for video channel (unreliable, screen streaming)
    pub send_video_key: Vec<u8>,
    /// Receive key for video channel
    pub recv_video_key: Vec<u8>,
    /// Send key for file channel (reliable, file transfer)
    pub send_file_key: Vec<u8>,
    /// Receive key for file channel
    pub recv_file_key: Vec<u8>,
    /// The negotiated crypto suite
    pub suite_id: crate::crypto::suite::CryptoSuiteId,
    /// Epoch for key rotation
    pub epoch: u64,
    /// Handshake role
    pub role: HandshakeRole,
    /// Transcript hash (SHA256 of transcriptHashA || transcriptHashB)
    pub transcript_hash: Vec<u8>,
}

/// Input bundle for deriving session keys.
pub struct SessionKeyDeriveInput<'a> {
    pub shared_secret: &'a [u8],
    pub transcript_hash_a: &'a [u8],
    pub transcript_hash_b: &'a [u8],
    pub client_nonce: &'a [u8],
    pub server_nonce: &'a [u8],
    pub suite_id: crate::crypto::suite::CryptoSuiteId,
    pub epoch: u64,
    pub role: HandshakeRole,
}

impl SessionKeys {
    pub fn derive_from(input: SessionKeyDeriveInput<'_>) -> Self {
        Self::derive(
            input.shared_secret,
            input.transcript_hash_a,
            input.transcript_hash_b,
            input.client_nonce,
            input.server_nonce,
            input.suite_id,
            input.epoch,
            input.role,
        )
    }

    /// Create new session keys from shared secret
    #[allow(clippy::too_many_arguments)]
    pub fn derive(
        shared_secret: &[u8],
        transcript_hash_a: &[u8],
        transcript_hash_b: &[u8],
        client_nonce: &[u8],
        server_nonce: &[u8],
        suite_id: crate::crypto::suite::CryptoSuiteId,
        epoch: u64,
        role: HandshakeRole,
    ) -> Self {
        let mut kdf_info = Vec::new();
        kdf_info.extend_from_slice(b"SkyBridge-KDF");
        kdf_info.push(0x01);
        kdf_info.extend_from_slice(&suite_id.wire_id().to_le_bytes());
        let composition_label = if suite_id.is_forward_secure_v2() {
            b"v2-static+ephemeral".as_slice()
        } else {
            b"v1-single".as_slice()
        };
        kdf_info.extend_from_slice(composition_label);
        kdf_info.extend_from_slice(transcript_hash_a);
        kdf_info.extend_from_slice(transcript_hash_b);
        kdf_info.extend_from_slice(client_nonce);
        kdf_info.extend_from_slice(server_nonce);

        let mut salt_input = Vec::new();
        salt_input.extend_from_slice(b"SkyBridge-KDF-Salt-v1|");
        salt_input.extend_from_slice(&kdf_info);
        let salt = Sha256::digest(&salt_input);

        let send_label = match role {
            HandshakeRole::Initiator => b"handshake|initiator_to_responder",
            HandshakeRole::Responder => b"handshake|responder_to_initiator",
        };
        let recv_label = match role {
            HandshakeRole::Initiator => b"handshake|responder_to_initiator",
            HandshakeRole::Responder => b"handshake|initiator_to_responder",
        };

        let send_key = crate::crypto::kdf::derive_key(
            shared_secret,
            Some(salt.as_slice()),
            &[kdf_info.as_slice(), send_label].concat(),
            32,
        );
        let recv_key = crate::crypto::kdf::derive_key(
            shared_secret,
            Some(salt.as_slice()),
            &[kdf_info.as_slice(), recv_label].concat(),
            32,
        );

        let mut transcript_digest_input = Vec::with_capacity(
            transcript_hash_a
                .len()
                .saturating_add(transcript_hash_b.len()),
        );
        transcript_digest_input.extend_from_slice(transcript_hash_a);
        transcript_digest_input.extend_from_slice(transcript_hash_b);
        let transcript_hash = Sha256::digest(&transcript_digest_input).to_vec();

        Self {
            send_control_key: send_key.clone(),
            recv_control_key: recv_key.clone(),
            send_video_key: send_key.clone(),
            recv_video_key: recv_key.clone(),
            send_file_key: send_key,
            recv_file_key: recv_key,
            suite_id,
            epoch,
            role,
            transcript_hash,
        }
    }

    /// Get send key for a specific channel
    pub fn send_key_for_channel(&self, channel: LogicalChannel) -> &[u8] {
        match channel {
            LogicalChannel::Control => &self.send_control_key,
            LogicalChannel::Video => &self.send_video_key,
            LogicalChannel::File => &self.send_file_key,
        }
    }

    /// Get receive key for a specific channel
    pub fn recv_key_for_channel(&self, channel: LogicalChannel) -> &[u8] {
        match channel {
            LogicalChannel::Control => &self.recv_control_key,
            LogicalChannel::Video => &self.recv_video_key,
            LogicalChannel::File => &self.recv_file_key,
        }
    }
}

/// Logical channels for different types of traffic
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LogicalChannel {
    /// Control channel - reliable, for RPC and commands
    Control,
    /// Video channel - unreliable (QUIC datagram), for screen streaming
    Video,
    /// File channel - reliable, for file transfer
    File,
}

impl LogicalChannel {
    /// HKDF info string for this channel
    pub fn hkdf_info(&self) -> &'static [u8] {
        match self {
            Self::Control => b"control",
            Self::Video => b"video",
            Self::File => b"file",
        }
    }

    /// Channel ID for wire protocol
    pub fn channel_id(&self) -> u8 {
        match self {
            Self::Control => 0x00,
            Self::Video => 0x01,
            Self::File => 0x02,
        }
    }

    /// Parse from channel ID
    pub fn from_channel_id(id: u8) -> Option<Self> {
        match id {
            0x00 => Some(Self::Control),
            0x01 => Some(Self::Video),
            0x02 => Some(Self::File),
            _ => None,
        }
    }
}

/// Key share for handshake
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyShare {
    /// Suite ID this key share is for
    pub suite_id: u16,
    /// Public key data
    pub public_key: Vec<u8>,
}

/// Peer identity information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerIdentity {
    /// Device ID
    pub device_id: String,
    /// Public key fingerprint (SHA-256, hex)
    pub public_key_fingerprint: String,
    /// Signing algorithm used for the handshake
    pub signing_algorithm: SignatureAlgorithm,
    /// Signing public key
    pub signing_public_key: Vec<u8>,
    /// KEM public key
    pub kem_public_key: Vec<u8>,
    /// Platform
    pub platform: crate::discovery::Platform,
    /// Protocol version
    pub protocol_version: String,
}
