//! P2P module
//!
//! Provides peer-to-peer connection management, handshake protocol,
//! and secure channel establishment.

#![allow(missing_docs)]

mod business;
mod connection;
mod cross_network;
mod driver;
mod encoding;
mod framing;
mod identity;
mod messages;
mod soa;
mod tcp_control;
mod trust;
mod types;

pub use business::{
    AppMessage, BusinessEnvelope, BusinessEnvelopeKind, ClipboardPayload, HeartbeatPayload,
    KemPublicKeyInfo, PairingIdentityExchangePayload, PingPayload, PongPayload, SwiftDateSeconds,
};
pub use connection::{P2PConnection, P2PConnectionManager};
pub use cross_network::{CrossNetworkChannel, CrossNetworkInbound};
pub use driver::{HandshakeDriver, LocalIdentity};
pub use framing::{DEFAULT_MAX_FRAME_SIZE, FrameDecoder, encode_frame, encode_frame_with_limit};
pub use identity::{LocalIdentityError, LocalIdentityStore};
pub use messages::{HandshakeMessage, P2PMessage, P2PMessageType};
pub use tcp_control::{
    DEFAULT_MAX_CONTROL_FRAME_SIZE, TcpControlEvent, TcpControlHandle, TcpControlService,
};
pub use trust::{
    ConnectionTrustPolicy, TrustError, TrustStore, TrustedPeerSummary,
    enforce_inbound_trust_policy, enforce_outbound_trust_policy,
};
pub use types::{
    CryptoTier, HandshakeAttemptStrategy, HandshakePolicy, HandshakeRole, HandshakeState,
    LogicalChannel, P2PError, PeerIdentity, SessionKeys,
};
