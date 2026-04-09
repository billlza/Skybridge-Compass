//! SkyBridge Core Library
//!
//! Core functionality for SkyBridge Compass Ubuntu - a cross-platform
//! P2P file transfer and remote desktop application.
//!
//! ## Features
//! - Cross-platform device discovery via mDNS
//! - Post-quantum secure P2P connections
//! - File transfer with resumption support
//! - Remote desktop (VNC/RDP)
//!
//! ## Interoperability
//! Compatible with SkyBridge Compass on macOS and Android.

#![warn(missing_docs)]
#![warn(clippy::all)]

pub mod auth;
pub mod crypto;
pub mod discovery;
pub mod p2p;
pub mod remote;
pub mod transfer;
pub mod webrtc;

pub use auth::{AuthSession, AuthenticationService, NebulaId, NebulaIdGenerator};
pub use crypto::{CryptoProvider, CryptoSuite};
pub use discovery::{DeviceDiscoveryManager, DiscoveredDevice, Platform};
pub use p2p::{
    HandshakeDriver, LocalIdentity, LocalIdentityError, LocalIdentityStore, P2PConnection,
    P2PConnectionManager, TrustStore,
};
pub use remote::RemoteDesktopManager;
pub use transfer::FileTransferEngine;

/// Protocol version for cross-platform compatibility
pub const PROTOCOL_VERSION: &str = "1.0.0";

/// Service type for mDNS discovery
pub const MDNS_SERVICE_TYPE: &str = "_skybridge._tcp.local.";

/// QUIC service type for mDNS discovery
pub const MDNS_QUIC_SERVICE_TYPE: &str = "_skybridge._udp.local.";

/// Default QUIC port
pub const DEFAULT_QUIC_PORT: u16 = 51820;

/// Default TCP port
pub const DEFAULT_TCP_PORT: u16 = 51821;

/// Domain separators for cryptographic operations
pub mod domain_separator {
    /// Protocol domain separator
    pub const PROTOCOL: &[u8] = b"SkyBridge-P2P-v1";
    /// Transcript domain separator
    pub const TRANSCRIPT: &[u8] = b"SkyBridge-P2P-Transcript-v1";
    /// Key derivation domain separator
    pub const KEY_DERIVATION: &[u8] = b"SkyBridge-P2P-KDF-v1";
    /// Signature domain separator
    pub const SIGNATURE: &[u8] = b"SkyBridge-P2P-Sig-v1";
    /// Pairing domain separator
    pub const PAIRING: &[u8] = b"SkyBridge-P2P-Pairing-v1";
}
