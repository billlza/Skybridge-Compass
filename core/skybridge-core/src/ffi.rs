use crate::channel::{map_channel, AdapterChannelBinding, ChannelProfile};
use crate::connection::{
    plan_connection, ConnectionPlan, ConnectionPlanError, ConnectionRequest, TrafficPaddingPlan,
};
use crate::crypto::{P256KeyExchange, P256SessionCrypto, SessionCryptoProvider, SessionSecrets};
use crate::discovery::{
    parse_service_kind, parse_txt_advertisement, DiscoveryServiceKind, PeerAdvertisement,
};
use crate::error::{CoreError, CoreResult};
use crate::frame::{
    decode_frame, decode_frame_payload as core_decode_frame_payload, encode_frame,
    encode_sbp2_frame, CoreFrame, FrameFlags, FRAME_HEADER_LEN,
};
use crate::session::{AsyncSessionManager, HeartbeatEmitter, SessionConfig, SessionState};
use crate::stream::{FlowRate, StreamController, StreamMetrics};
use crate::suite::{
    CryptoProviderCapabilities, CryptoSuite, CryptoSuiteAudit, CryptoSuitePolicy,
    CryptoSuiteSelectionError,
};
use crate::transport::{
    NetworkPath, PeerCapabilities, PeerPlatform, RelayPolicy, SkyBridgeChannel,
    SkyBridgeReliability, SkyBridgeTransportKind, TransportAuditReason, TransportSelector,
};
use crate::CoreEngine;
use std::collections::VecDeque;
use std::os::raw::c_char;
use std::str::from_utf8;
use std::sync::{Arc, Mutex};
use tokio::runtime::Runtime;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeErrorCode {
    Ok = 0,
    NullHandle = 1,
    InvalidState = 2,
    MissingConfig = 3,
    RateLimited = 4,
    AlreadyInitialized = 5,
    SessionError = 100,
    StreamError = 101,
    CryptoError = 102,
    InvalidInput = 200,
    UnsupportedTransport = 201,
    NoMutualCryptoSuite = 202,
    UnknownCryptoSuite = 203,
    TimeoutCannotDowngrade = 204,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeSessionState {
    Disconnected = 0,
    Connecting = 1,
    Connected = 2,
    Reconnecting = 3,
    ShuttingDown = 4,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeSessionConfig {
    pub client_id_ptr: *const c_char,
    pub client_id_len: usize,
    pub heartbeat_interval_ms: u64,
    pub peer_public_key_ptr: *const u8,
    pub peer_public_key_len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeEventKind {
    None = 0,
    Connected = 1,
    Disconnected = 2,
    HeartbeatAck = 3,
    InputReceived = 4,
    Reconnected = 5,
    HeartbeatTimeout = 6,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeEvent {
    pub kind: SkybridgeEventKind,
    pub data_ptr: *const u8,
    pub data_len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SkybridgeBuffer {
    pub data_ptr: *const u8,
    pub data_len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeFlowRate {
    pub target_bitrate_bps: u64,
    pub max_latency_ms: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeStreamMetrics {
    pub bitrate_bps: u64,
    pub packet_loss_ppm: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeEngineSnapshot {
    pub state: SkybridgeSessionState,
    pub last_heartbeat_ms: u64,
    pub has_last_heartbeat: bool,
    pub has_secrets: bool,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgePeerPlatform {
    Unknown = 0,
    Apple = 1,
    Windows = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeTransportKind {
    Unsupported = 0,
    AppleNative = 1,
    WindowsNativeMsQuic = 2,
    SkyBridgeIceMsQuic = 3,
    WebRtcDataChannel = 4,
    Relay = 5,
    TcpFallback = 6,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeTransportAuditCode {
    UnsupportedNoCompatibleTransport = 0,
    AppleNativeDefault = 1,
    WindowsNativeMsQuicSameLan = 2,
    WindowsSkyBridgeIceMsQuic = 3,
    WebRtcInterop = 4,
    TcpFallbackSameLan = 5,
    RelayFallback = 6,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgePeerCapabilities {
    pub platform: SkybridgePeerPlatform,
    pub supports_apple_native: u8,
    pub supports_msquic: u8,
    pub supports_skybridge_ice_msquic: u8,
    pub supports_webrtc_data_channel: u8,
    pub supports_tcp_fallback: u8,
    pub supports_relay: u8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeNetworkPath {
    pub same_lan: u8,
    pub cross_nat: u8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SkybridgeTransportSelection {
    pub kind: SkybridgeTransportKind,
    pub audit_code: SkybridgeTransportAuditCode,
    pub priority: u8,
    pub relay_required: u8,
    pub relay_allowed: u8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeChannelKind {
    Control = 1,
    File = 2,
    Clipboard = 3,
    Telemetry = 4,
    Realtime = 5,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeReliabilityKind {
    ReliableOrdered = 1,
    ReliableUnordered = 2,
    PartialReliable = 3,
    Unreliable = 4,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeAdapterBindingKind {
    AppleStream = 1,
    AppleDatagram = 2,
    MsQuicStream = 3,
    MsQuicDatagram = 4,
    WebRtcDataChannel = 5,
    RelayStream = 6,
    TcpStream = 7,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SkybridgeChannelMapping {
    pub channel: SkybridgeChannelKind,
    pub reliability: SkybridgeReliabilityKind,
    pub max_retransmits: u16,
    pub binding_kind: SkybridgeAdapterBindingKind,
    pub head_of_line_isolated: u8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeCryptoSuiteKind {
    Unknown = 0,
    XWingHybrid = 1,
    MlKem768MlDsa65 = 2,
    X25519Ed25519 = 3,
    P256Ecdsa = 4,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeCryptoSuiteAuditCode {
    None = 0,
    HybridPqcPreferred = 1,
    PurePqcPreferred = 2,
    ClassicPolicyFallback = 3,
    LegacyPolicyFallback = 4,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeCryptoProviderCapabilities {
    pub supports_xwing_hybrid: u8,
    pub supports_mlkem_768_mldsa_65: u8,
    pub supports_x25519_ed25519: u8,
    pub supports_p256_ecdsa: u8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeCryptoSuitePolicy {
    pub allow_classic_fallback: u8,
    pub allow_legacy_p256: u8,
    pub timeout_observed: u8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeTrafficPaddingPlan {
    pub sbp2_enabled: u8,
    pub fixed_payload_len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SkybridgeFrameMetadata {
    pub channel: SkybridgeChannelKind,
    pub sequence: u64,
    pub flags: u16,
    pub frame_header_len: usize,
    pub encoded_len: usize,
    pub payload_len: usize,
    pub decoded_payload_len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeConnectionPlan {
    pub transport: SkybridgeTransportSelection,
    pub selected_suite: SkybridgeCryptoSuiteKind,
    pub selected_suite_wire_id: u16,
    pub suite_audit: SkybridgeCryptoSuiteAuditCode,
    pub offered_suites: [SkybridgeCryptoSuiteKind; 4],
    pub offered_suite_wire_ids: [u16; 4],
    pub offered_suite_count: usize,
    pub channel_mappings: [SkybridgeChannelMapping; 5],
    pub channel_mapping_count: usize,
    pub sbp2_enabled: u8,
    pub sbp2_fixed_payload_len: usize,
    pub frame_header_len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeDiscoveryServiceKind {
    Unknown = 0,
    QuicPrimary = 1,
    TcpFallback = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeDiscoveryAdvertisement {
    pub service_kind: SkybridgeDiscoveryServiceKind,
    pub device_id: [u8; 64],
    pub device_id_len: usize,
    pub public_key_fingerprint: [u8; 64],
    pub public_key_fingerprint_len: usize,
    pub platform: SkybridgePeerPlatform,
    pub platform_label: [u8; 32],
    pub platform_label_len: usize,
    pub capabilities: [u8; 256],
    pub capabilities_len: usize,
    pub name: [u8; 128],
    pub name_len: usize,
    pub protocol_version: [u8; 32],
    pub protocol_version_len: usize,
    pub peer_capabilities: SkybridgePeerCapabilities,
}

/// Maximum number of queued events retained by the engine handle.
/// Older events are dropped once this capacity is reached so callers must poll
/// regularly to avoid missing notifications.
pub const SKYBRIDGE_EVENT_CAPACITY: usize = 1024;

fn map_core_error(err: CoreError) -> SkybridgeErrorCode {
    match err {
        CoreError::Session(_) => SkybridgeErrorCode::SessionError,
        CoreError::Stream(_) => SkybridgeErrorCode::StreamError,
        CoreError::Crypto(_) => SkybridgeErrorCode::CryptoError,
        CoreError::CryptoHandshake(_) => SkybridgeErrorCode::CryptoError,
        CoreError::Encrypt(_) => SkybridgeErrorCode::CryptoError,
        CoreError::Decrypt(_) => SkybridgeErrorCode::CryptoError,
        CoreError::AlreadyInitialized => SkybridgeErrorCode::AlreadyInitialized,
        CoreError::MissingConfig => SkybridgeErrorCode::MissingConfig,
        CoreError::MissingCryptoMaterial => SkybridgeErrorCode::CryptoError,
        CoreError::InvalidCryptoKey => SkybridgeErrorCode::CryptoError,
        CoreError::InvalidConfig { .. } => SkybridgeErrorCode::InvalidInput,
        CoreError::NoHeartbeat => SkybridgeErrorCode::InvalidState,
        CoreError::HeartbeatTimeout { .. } => SkybridgeErrorCode::InvalidState,
        CoreError::RateLimited { .. } => SkybridgeErrorCode::RateLimited,
        CoreError::InvalidState { .. } => SkybridgeErrorCode::InvalidState,
    }
}

fn map_session_state(state: SessionState) -> SkybridgeSessionState {
    match state {
        SessionState::Disconnected => SkybridgeSessionState::Disconnected,
        SessionState::Connecting => SkybridgeSessionState::Connecting,
        SessionState::Connected => SkybridgeSessionState::Connected,
        SessionState::Reconnecting => SkybridgeSessionState::Reconnecting,
        SessionState::ShuttingDown => SkybridgeSessionState::ShuttingDown,
    }
}

fn ffi_flag(value: u8) -> bool {
    value != 0
}

fn map_peer_platform(platform: SkybridgePeerPlatform) -> PeerPlatform {
    match platform {
        SkybridgePeerPlatform::Apple => PeerPlatform::Apple,
        SkybridgePeerPlatform::Windows => PeerPlatform::Windows,
        SkybridgePeerPlatform::Unknown => PeerPlatform::Unknown,
    }
}

fn map_peer_capabilities(caps: SkybridgePeerCapabilities) -> PeerCapabilities {
    PeerCapabilities {
        platform: map_peer_platform(caps.platform),
        supports_apple_native: ffi_flag(caps.supports_apple_native),
        supports_msquic: ffi_flag(caps.supports_msquic),
        supports_skybridge_ice_msquic: ffi_flag(caps.supports_skybridge_ice_msquic),
        supports_webrtc_data_channel: ffi_flag(caps.supports_webrtc_data_channel),
        supports_tcp_fallback: ffi_flag(caps.supports_tcp_fallback),
        supports_relay: ffi_flag(caps.supports_relay),
    }
}

fn map_peer_capabilities_to_ffi(caps: PeerCapabilities) -> SkybridgePeerCapabilities {
    SkybridgePeerCapabilities {
        platform: map_platform_to_ffi(caps.platform),
        supports_apple_native: u8::from(caps.supports_apple_native),
        supports_msquic: u8::from(caps.supports_msquic),
        supports_skybridge_ice_msquic: u8::from(caps.supports_skybridge_ice_msquic),
        supports_webrtc_data_channel: u8::from(caps.supports_webrtc_data_channel),
        supports_tcp_fallback: u8::from(caps.supports_tcp_fallback),
        supports_relay: u8::from(caps.supports_relay),
    }
}

fn map_platform_to_ffi(platform: PeerPlatform) -> SkybridgePeerPlatform {
    match platform {
        PeerPlatform::Apple => SkybridgePeerPlatform::Apple,
        PeerPlatform::Windows => SkybridgePeerPlatform::Windows,
        PeerPlatform::Unknown => SkybridgePeerPlatform::Unknown,
    }
}

fn map_network_path(path: SkybridgeNetworkPath) -> NetworkPath {
    NetworkPath {
        same_lan: ffi_flag(path.same_lan),
        cross_nat: ffi_flag(path.cross_nat),
    }
}

fn map_transport_kind(kind: Option<SkyBridgeTransportKind>) -> SkybridgeTransportKind {
    match kind {
        Some(SkyBridgeTransportKind::AppleNative) => SkybridgeTransportKind::AppleNative,
        Some(SkyBridgeTransportKind::WindowsNativeMsQuic) => {
            SkybridgeTransportKind::WindowsNativeMsQuic
        }
        Some(SkyBridgeTransportKind::SkyBridgeIceMsQuic) => {
            SkybridgeTransportKind::SkyBridgeIceMsQuic
        }
        Some(SkyBridgeTransportKind::WebRtcDataChannel) => {
            SkybridgeTransportKind::WebRtcDataChannel
        }
        Some(SkyBridgeTransportKind::Relay) => SkybridgeTransportKind::Relay,
        Some(SkyBridgeTransportKind::TcpFallback) => SkybridgeTransportKind::TcpFallback,
        None => SkybridgeTransportKind::Unsupported,
    }
}

fn map_ffi_transport_kind(kind: SkybridgeTransportKind) -> Option<SkyBridgeTransportKind> {
    match kind {
        SkybridgeTransportKind::AppleNative => Some(SkyBridgeTransportKind::AppleNative),
        SkybridgeTransportKind::WindowsNativeMsQuic => {
            Some(SkyBridgeTransportKind::WindowsNativeMsQuic)
        }
        SkybridgeTransportKind::SkyBridgeIceMsQuic => {
            Some(SkyBridgeTransportKind::SkyBridgeIceMsQuic)
        }
        SkybridgeTransportKind::WebRtcDataChannel => {
            Some(SkyBridgeTransportKind::WebRtcDataChannel)
        }
        SkybridgeTransportKind::Relay => Some(SkyBridgeTransportKind::Relay),
        SkybridgeTransportKind::TcpFallback => Some(SkyBridgeTransportKind::TcpFallback),
        SkybridgeTransportKind::Unsupported => None,
    }
}

fn map_ffi_channel_kind(channel: SkybridgeChannelKind) -> SkyBridgeChannel {
    match channel {
        SkybridgeChannelKind::Control => SkyBridgeChannel::Control,
        SkybridgeChannelKind::File => SkyBridgeChannel::File,
        SkybridgeChannelKind::Clipboard => SkyBridgeChannel::Clipboard,
        SkybridgeChannelKind::Telemetry => SkyBridgeChannel::Telemetry,
        SkybridgeChannelKind::Realtime => SkyBridgeChannel::Realtime,
    }
}

fn map_channel_kind(channel: SkyBridgeChannel) -> SkybridgeChannelKind {
    match channel {
        SkyBridgeChannel::Control => SkybridgeChannelKind::Control,
        SkyBridgeChannel::File => SkybridgeChannelKind::File,
        SkyBridgeChannel::Clipboard => SkybridgeChannelKind::Clipboard,
        SkyBridgeChannel::Telemetry => SkybridgeChannelKind::Telemetry,
        SkyBridgeChannel::Realtime => SkybridgeChannelKind::Realtime,
    }
}

fn map_reliability(reliability: SkyBridgeReliability) -> (SkybridgeReliabilityKind, u16) {
    match reliability {
        SkyBridgeReliability::ReliableOrdered => (SkybridgeReliabilityKind::ReliableOrdered, 0),
        SkyBridgeReliability::ReliableUnordered => (SkybridgeReliabilityKind::ReliableUnordered, 0),
        SkyBridgeReliability::PartialReliable { max_retransmits } => {
            (SkybridgeReliabilityKind::PartialReliable, max_retransmits)
        }
        SkyBridgeReliability::Unreliable => (SkybridgeReliabilityKind::Unreliable, 0),
    }
}

fn map_binding_kind(binding: &AdapterChannelBinding) -> SkybridgeAdapterBindingKind {
    match binding {
        AdapterChannelBinding::AppleStream { .. } => SkybridgeAdapterBindingKind::AppleStream,
        AdapterChannelBinding::AppleDatagram { .. } => SkybridgeAdapterBindingKind::AppleDatagram,
        AdapterChannelBinding::MsQuicStream { .. } => SkybridgeAdapterBindingKind::MsQuicStream,
        AdapterChannelBinding::MsQuicDatagram { .. } => SkybridgeAdapterBindingKind::MsQuicDatagram,
        AdapterChannelBinding::WebRtcDataChannel { .. } => {
            SkybridgeAdapterBindingKind::WebRtcDataChannel
        }
        AdapterChannelBinding::RelayStream { .. } => SkybridgeAdapterBindingKind::RelayStream,
        AdapterChannelBinding::TcpStream { .. } => SkybridgeAdapterBindingKind::TcpStream,
    }
}

fn map_channel_profile(profile: &ChannelProfile) -> SkybridgeChannelMapping {
    let (reliability, max_retransmits) = map_reliability(profile.reliability);
    SkybridgeChannelMapping {
        channel: map_channel_kind(profile.channel),
        reliability,
        max_retransmits,
        binding_kind: map_binding_kind(&profile.binding),
        head_of_line_isolated: u8::from(profile.binding.isolates_head_of_line_blocking()),
    }
}

fn map_frame_metadata(
    frame: &CoreFrame,
    encoded_len: usize,
) -> Result<SkybridgeFrameMetadata, SkybridgeErrorCode> {
    Ok(SkybridgeFrameMetadata {
        channel: map_channel_kind(frame.channel),
        sequence: frame.sequence,
        flags: frame.flags.bits(),
        frame_header_len: FRAME_HEADER_LEN,
        encoded_len,
        payload_len: frame.payload.len(),
        decoded_payload_len: core_decode_frame_payload(frame)
            .map_err(|_| SkybridgeErrorCode::InvalidInput)?
            .len(),
    })
}

fn empty_channel_mapping() -> SkybridgeChannelMapping {
    SkybridgeChannelMapping {
        channel: SkybridgeChannelKind::Control,
        reliability: SkybridgeReliabilityKind::ReliableOrdered,
        max_retransmits: 0,
        binding_kind: SkybridgeAdapterBindingKind::MsQuicStream,
        head_of_line_isolated: 0,
    }
}

fn map_transport_audit(reason: TransportAuditReason) -> SkybridgeTransportAuditCode {
    match reason {
        TransportAuditReason::AppleNativeDefault => SkybridgeTransportAuditCode::AppleNativeDefault,
        TransportAuditReason::WindowsNativeMsQuicSameLan => {
            SkybridgeTransportAuditCode::WindowsNativeMsQuicSameLan
        }
        TransportAuditReason::WindowsSkyBridgeIceMsQuic => {
            SkybridgeTransportAuditCode::WindowsSkyBridgeIceMsQuic
        }
        TransportAuditReason::WebRtcInterop => SkybridgeTransportAuditCode::WebRtcInterop,
        TransportAuditReason::TcpFallbackSameLan => SkybridgeTransportAuditCode::TcpFallbackSameLan,
        TransportAuditReason::RelayFallback => SkybridgeTransportAuditCode::RelayFallback,
        TransportAuditReason::UnsupportedNoCompatibleTransport => {
            SkybridgeTransportAuditCode::UnsupportedNoCompatibleTransport
        }
    }
}

fn map_relay_required(policy: RelayPolicy) -> u8 {
    u8::from(matches!(policy, RelayPolicy::Required))
}

fn map_relay_allowed(policy: RelayPolicy) -> u8 {
    u8::from(matches!(
        policy,
        RelayPolicy::Allowed | RelayPolicy::Required
    ))
}

fn map_transport_selection(plan: crate::transport::TransportPlan) -> SkybridgeTransportSelection {
    SkybridgeTransportSelection {
        kind: map_transport_kind(plan.kind),
        audit_code: map_transport_audit(plan.audit_reason),
        priority: plan.priority,
        relay_required: map_relay_required(plan.relay_policy),
        relay_allowed: map_relay_allowed(plan.relay_policy),
    }
}

fn map_crypto_provider_capabilities(
    caps: SkybridgeCryptoProviderCapabilities,
) -> CryptoProviderCapabilities {
    CryptoProviderCapabilities {
        supports_xwing_hybrid: ffi_flag(caps.supports_xwing_hybrid),
        supports_mlkem_768_mldsa_65: ffi_flag(caps.supports_mlkem_768_mldsa_65),
        supports_x25519_ed25519: ffi_flag(caps.supports_x25519_ed25519),
        supports_p256_ecdsa: ffi_flag(caps.supports_p256_ecdsa),
    }
}

fn map_crypto_suite_policy(policy: SkybridgeCryptoSuitePolicy) -> CryptoSuitePolicy {
    CryptoSuitePolicy {
        allow_classic_fallback: ffi_flag(policy.allow_classic_fallback),
        allow_legacy_p256: ffi_flag(policy.allow_legacy_p256),
        timeout_observed: ffi_flag(policy.timeout_observed),
    }
}

fn map_traffic_padding_plan(plan: SkybridgeTrafficPaddingPlan) -> TrafficPaddingPlan {
    if ffi_flag(plan.sbp2_enabled) {
        TrafficPaddingPlan::sbp2_fixed(plan.fixed_payload_len)
    } else {
        TrafficPaddingPlan::disabled()
    }
}

fn map_crypto_suite(suite: CryptoSuite) -> SkybridgeCryptoSuiteKind {
    match suite {
        CryptoSuite::XWingHybrid => SkybridgeCryptoSuiteKind::XWingHybrid,
        CryptoSuite::MlKem768MlDsa65 => SkybridgeCryptoSuiteKind::MlKem768MlDsa65,
        CryptoSuite::X25519Ed25519 => SkybridgeCryptoSuiteKind::X25519Ed25519,
        CryptoSuite::P256Ecdsa => SkybridgeCryptoSuiteKind::P256Ecdsa,
    }
}

fn map_crypto_suite_audit(audit: CryptoSuiteAudit) -> SkybridgeCryptoSuiteAuditCode {
    match audit {
        CryptoSuiteAudit::HybridPqcPreferred => SkybridgeCryptoSuiteAuditCode::HybridPqcPreferred,
        CryptoSuiteAudit::PurePqcPreferred => SkybridgeCryptoSuiteAuditCode::PurePqcPreferred,
        CryptoSuiteAudit::ClassicPolicyFallback => {
            SkybridgeCryptoSuiteAuditCode::ClassicPolicyFallback
        }
        CryptoSuiteAudit::LegacyPolicyFallback => {
            SkybridgeCryptoSuiteAuditCode::LegacyPolicyFallback
        }
    }
}

fn map_connection_plan(plan: ConnectionPlan) -> SkybridgeConnectionPlan {
    let mut offered_suites = [SkybridgeCryptoSuiteKind::Unknown; 4];
    let mut offered_suite_wire_ids = [0u16; 4];
    for (index, suite) in plan.offered_suites.iter().take(4).enumerate() {
        offered_suites[index] = map_crypto_suite(*suite);
        offered_suite_wire_ids[index] = suite.wire_id();
    }

    let mut channel_mappings = [empty_channel_mapping(); 5];
    for (index, profile) in plan.channels.iter().take(5).enumerate() {
        channel_mappings[index] = map_channel_profile(profile);
    }

    SkybridgeConnectionPlan {
        transport: map_transport_selection(plan.transport),
        selected_suite: map_crypto_suite(plan.selected_suite.suite),
        selected_suite_wire_id: plan.selected_suite.suite.wire_id(),
        suite_audit: map_crypto_suite_audit(plan.selected_suite.audit),
        offered_suites,
        offered_suite_wire_ids,
        offered_suite_count: plan.offered_suites.len().min(4),
        channel_mappings,
        channel_mapping_count: plan.channels.len().min(5),
        sbp2_enabled: u8::from(plan.traffic_padding.sbp2_enabled),
        sbp2_fixed_payload_len: plan.traffic_padding.fixed_payload_len.unwrap_or(0),
        frame_header_len: plan.frame_header_len,
    }
}

fn map_connection_plan_error(err: ConnectionPlanError) -> SkybridgeErrorCode {
    match err {
        ConnectionPlanError::UnsupportedTransport => SkybridgeErrorCode::UnsupportedTransport,
        ConnectionPlanError::ChannelMapping(_) => SkybridgeErrorCode::InvalidInput,
        ConnectionPlanError::CryptoSuite(CryptoSuiteSelectionError::NoMutualSuite) => {
            SkybridgeErrorCode::NoMutualCryptoSuite
        }
        ConnectionPlanError::CryptoSuite(CryptoSuiteSelectionError::UnknownSuiteId(_)) => {
            SkybridgeErrorCode::UnknownCryptoSuite
        }
        ConnectionPlanError::CryptoSuite(CryptoSuiteSelectionError::TimeoutCannotDowngrade) => {
            SkybridgeErrorCode::TimeoutCannotDowngrade
        }
    }
}

fn map_discovery_service(service: DiscoveryServiceKind) -> SkybridgeDiscoveryServiceKind {
    match service {
        DiscoveryServiceKind::QuicPrimary => SkybridgeDiscoveryServiceKind::QuicPrimary,
        DiscoveryServiceKind::TcpFallback => SkybridgeDiscoveryServiceKind::TcpFallback,
    }
}

fn map_discovery_advertisement(
    service: DiscoveryServiceKind,
    advertisement: PeerAdvertisement,
) -> Result<SkybridgeDiscoveryAdvertisement, SkybridgeErrorCode> {
    let mut ffi = SkybridgeDiscoveryAdvertisement {
        service_kind: map_discovery_service(service),
        device_id: [0; 64],
        device_id_len: 0,
        public_key_fingerprint: [0; 64],
        public_key_fingerprint_len: 0,
        platform: map_platform_to_ffi(advertisement.platform),
        platform_label: [0; 32],
        platform_label_len: 0,
        capabilities: [0; 256],
        capabilities_len: 0,
        name: [0; 128],
        name_len: 0,
        protocol_version: [0; 32],
        protocol_version_len: 0,
        peer_capabilities: map_peer_capabilities_to_ffi(advertisement.peer_capabilities()),
    };

    ffi.device_id_len = write_utf8(&mut ffi.device_id, advertisement.device_id.as_bytes())?;
    ffi.public_key_fingerprint_len = write_utf8(
        &mut ffi.public_key_fingerprint,
        advertisement.public_key_fingerprint.as_bytes(),
    )?;
    ffi.platform_label_len = write_utf8(
        &mut ffi.platform_label,
        advertisement.platform_label.as_bytes(),
    )?;
    ffi.capabilities_len = write_utf8(
        &mut ffi.capabilities,
        advertisement.capabilities.join(",").as_bytes(),
    )?;
    ffi.name_len = write_utf8(&mut ffi.name, advertisement.name.as_bytes())?;
    ffi.protocol_version_len = write_utf8(
        &mut ffi.protocol_version,
        advertisement.protocol_version.as_bytes(),
    )?;

    Ok(ffi)
}

fn write_utf8(out: &mut [u8], value: &[u8]) -> Result<usize, SkybridgeErrorCode> {
    if value.len() > out.len() {
        return Err(SkybridgeErrorCode::InvalidInput);
    }

    out[..value.len()].copy_from_slice(value);
    Ok(value.len())
}

unsafe fn read_utf8<'a>(ptr: *const u8, len: usize) -> Result<&'a str, SkybridgeErrorCode> {
    if len > 0 && ptr.is_null() {
        return Err(SkybridgeErrorCode::InvalidInput);
    }

    let bytes = if len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }
    };
    from_utf8(bytes).map_err(|_| SkybridgeErrorCode::InvalidInput)
}

unsafe fn read_bytes<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8], SkybridgeErrorCode> {
    if len > 0 && ptr.is_null() {
        return Err(SkybridgeErrorCode::InvalidInput);
    }

    if len == 0 {
        Ok(&[])
    } else {
        Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
    }
}

unsafe fn write_bytes(
    out_ptr: *mut u8,
    out_capacity: usize,
    data: &[u8],
    out_written_len: *mut usize,
) -> SkybridgeErrorCode {
    if out_written_len.is_null() {
        return SkybridgeErrorCode::InvalidInput;
    }

    unsafe {
        *out_written_len = data.len();
    }

    if data.len() > out_capacity {
        return SkybridgeErrorCode::InvalidInput;
    }
    if data.is_empty() {
        return SkybridgeErrorCode::Ok;
    }
    if out_ptr.is_null() {
        return SkybridgeErrorCode::InvalidInput;
    }

    unsafe {
        std::ptr::copy_nonoverlapping(data.as_ptr(), out_ptr, data.len());
    }
    SkybridgeErrorCode::Ok
}

#[derive(Clone)]
struct FfiSessionManager {
    state: Arc<Mutex<SessionState>>,
}

impl FfiSessionManager {
    fn new() -> Self {
        Self {
            state: Arc::new(Mutex::new(SessionState::Disconnected)),
        }
    }
}

#[async_trait::async_trait(?Send)]
impl AsyncSessionManager for FfiSessionManager {
    async fn establish_async(&self, config: SessionConfig) -> CoreResult<()> {
        let mut guard = self.state.lock().unwrap();
        *guard = SessionState::Connected;
        if config.client_id.is_empty() {
            return Err(CoreError::Session("missing client id".into()));
        }
        Ok(())
    }

    async fn reconnect_async(&self) -> CoreResult<()> {
        *self.state.lock().unwrap() = SessionState::Connected;
        Ok(())
    }

    async fn terminate_async(&self) {
        *self.state.lock().unwrap() = SessionState::Disconnected;
    }

    fn state(&self) -> SessionState {
        *self.state.lock().unwrap()
    }
}

#[derive(Clone)]
struct FfiStreamController {
    last_input: Arc<Mutex<Vec<u8>>>,
    last_rate: Arc<Mutex<Option<FlowRate>>>,
}

impl FfiStreamController {
    fn new(buffer: Arc<Mutex<Vec<u8>>>) -> Self {
        Self {
            last_input: buffer,
            last_rate: Arc::new(Mutex::new(None)),
        }
    }

    fn record_input(&self, data: &[u8]) {
        *self.last_input.lock().unwrap() = data.to_vec();
    }
}

#[async_trait::async_trait(?Send)]
impl StreamController for FfiStreamController {
    async fn adjust_flow(&self, rate: FlowRate) {
        *self.last_rate.lock().unwrap() = Some(rate);
    }

    async fn metrics(&self) -> StreamMetrics {
        let bitrate = self
            .last_rate
            .lock()
            .unwrap()
            .map(|r| r.target_bitrate_bps)
            .unwrap_or(0);
        StreamMetrics {
            bitrate_bps: bitrate,
            packet_loss: 0.0,
        }
    }
}

#[derive(Clone)]
struct FfiCrypto {
    inner: Arc<P256SessionCrypto<P256KeyExchange>>,
}

impl FfiCrypto {
    fn new() -> Self {
        Self {
            inner: Arc::new(P256SessionCrypto::new(P256KeyExchange)),
        }
    }
}

#[async_trait::async_trait(?Send)]
impl SessionCryptoProvider for FfiCrypto {
    async fn validate_device_identity(&self) -> Result<(), CoreError> {
        self.inner.validate_device_identity().await
    }

    async fn begin_handshake(&self) -> Result<Vec<u8>, CoreError> {
        self.inner.begin_handshake().await
    }

    async fn finalize_handshake(
        &self,
        peer_public_key: &[u8],
    ) -> Result<SessionSecrets, CoreError> {
        self.inner.finalize_handshake(peer_public_key).await
    }

    fn local_public_key(&self) -> Option<Vec<u8>> {
        self.inner.local_public_key()
    }

    fn algorithm(&self) -> &'static str {
        self.inner.algorithm()
    }

    fn encrypt(&self, secrets: &SessionSecrets, plaintext: &[u8]) -> Result<Vec<u8>, CoreError> {
        self.inner.encrypt(secrets, plaintext)
    }

    fn decrypt(&self, secrets: &SessionSecrets, ciphertext: &[u8]) -> Result<Vec<u8>, CoreError> {
        self.inner.decrypt(secrets, ciphertext)
    }
}

#[derive(Clone)]
struct FfiHeartbeat;

#[async_trait::async_trait(?Send)]
impl HeartbeatEmitter for FfiHeartbeat {
    async fn emit(&self) -> CoreResult<()> {
        Ok(())
    }
}

pub struct SkybridgeEngineHandle {
    runtime: Runtime,
    engine: CoreEngine<FfiSessionManager, FfiStreamController, FfiCrypto, FfiHeartbeat>,
    input_buffer: Arc<Mutex<Vec<u8>>>,
    events: Arc<Mutex<VecDeque<FfiEvent>>>,
    last_event_payload: Arc<Mutex<Vec<u8>>>,
    last_public_key: Arc<Mutex<Vec<u8>>>,
    last_crypto_output: Arc<Mutex<Vec<u8>>>,
}

impl SkybridgeEngineHandle {
    fn new() -> Self {
        let input_buffer = Arc::new(Mutex::new(Vec::new()));
        let events = Arc::new(Mutex::new(VecDeque::new()));
        let last_event_payload = Arc::new(Mutex::new(Vec::new()));
        let last_public_key = Arc::new(Mutex::new(Vec::new()));
        let last_crypto_output = Arc::new(Mutex::new(Vec::new()));
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .expect("runtime");
        let session_manager = FfiSessionManager::new();
        let stream_controller = FfiStreamController::new(input_buffer.clone());
        let engine = CoreEngine::new(
            session_manager,
            stream_controller,
            FfiCrypto::new(),
            FfiHeartbeat,
        );
        Self {
            runtime,
            engine,
            input_buffer,
            events,
            last_event_payload,
            last_public_key,
            last_crypto_output,
        }
    }

    fn push_event(&self, event: FfiEvent) {
        let mut queue = self.events.lock().unwrap();
        if queue.len() >= SKYBRIDGE_EVENT_CAPACITY {
            queue.pop_front();
        }
        queue.push_back(event);
    }

    fn pop_event(&self) -> SkybridgeEvent {
        let mut queue = self.events.lock().unwrap();
        if let Some(event) = queue.pop_front() {
            let mut payload = self.last_event_payload.lock().unwrap();
            *payload = event.payload;
            let ptr = if payload.is_empty() {
                std::ptr::null()
            } else {
                payload.as_ptr()
            };
            SkybridgeEvent {
                kind: event.kind,
                data_ptr: ptr,
                data_len: payload.len(),
            }
        } else {
            SkybridgeEvent {
                kind: SkybridgeEventKind::None,
                data_ptr: std::ptr::null(),
                data_len: 0,
            }
        }
    }

    fn clear_events(&self) {
        self.events.lock().unwrap().clear();
        self.last_event_payload.lock().unwrap().clear();
    }

    fn write_crypto_output(
        &self,
        data: Vec<u8>,
        out_buffer: *mut SkybridgeBuffer,
    ) -> SkybridgeErrorCode {
        if out_buffer.is_null() {
            return SkybridgeErrorCode::InvalidInput;
        }

        let mut buffer = self.last_crypto_output.lock().unwrap();
        *buffer = data;

        let view = SkybridgeBuffer {
            data_ptr: if buffer.is_empty() {
                std::ptr::null()
            } else {
                buffer.as_ptr()
            },
            data_len: buffer.len(),
        };

        unsafe {
            *out_buffer = view;
        }
        SkybridgeErrorCode::Ok
    }

    fn with_handle<T>(
        handle: *mut SkybridgeEngineHandle,
        f: impl FnOnce(&mut SkybridgeEngineHandle) -> T,
    ) -> Option<T> {
        if handle.is_null() {
            return None;
        }
        let handle = unsafe { &mut *handle };
        Some(f(handle))
    }
}

#[derive(Debug, Clone)]
struct FfiEvent {
    kind: SkybridgeEventKind,
    payload: Vec<u8>,
}

#[no_mangle]
/// Selects the Core-owned transport adapter for a peer pair.
///
/// # Safety
/// `out_selection` must be a valid writable pointer. Unsupported pairs return
/// `Ok` with `kind = Unsupported` so callers can surface an auditable reason.
pub unsafe extern "C" fn skybridge_select_transport(
    local: SkybridgePeerCapabilities,
    remote: SkybridgePeerCapabilities,
    path: SkybridgeNetworkPath,
    out_selection: *mut SkybridgeTransportSelection,
) -> SkybridgeErrorCode {
    if out_selection.is_null() {
        return SkybridgeErrorCode::InvalidInput;
    }

    let plan = TransportSelector::select(
        map_peer_capabilities(local),
        map_peer_capabilities(remote),
        map_network_path(path),
    );

    unsafe {
        *out_selection = map_transport_selection(plan);
    }

    SkybridgeErrorCode::Ok
}

#[no_mangle]
/// Builds the Core-owned pre-adapter connection plan for Windows and diagnostics.
///
/// # Safety
/// `out_plan` must be a valid writable pointer. When `remote_suite_wire_ids_len > 0`,
/// `remote_suite_wire_ids_ptr` must point to that many readable `u16` wire IDs.
pub unsafe extern "C" fn skybridge_plan_connection(
    local: SkybridgePeerCapabilities,
    remote: SkybridgePeerCapabilities,
    path: SkybridgeNetworkPath,
    local_crypto: SkybridgeCryptoProviderCapabilities,
    remote_suite_wire_ids_ptr: *const u16,
    remote_suite_wire_ids_len: usize,
    suite_policy: SkybridgeCryptoSuitePolicy,
    traffic_padding: SkybridgeTrafficPaddingPlan,
    out_plan: *mut SkybridgeConnectionPlan,
) -> SkybridgeErrorCode {
    if out_plan.is_null() {
        return SkybridgeErrorCode::InvalidInput;
    }
    if remote_suite_wire_ids_len > 0 && remote_suite_wire_ids_ptr.is_null() {
        return SkybridgeErrorCode::InvalidInput;
    }

    let remote_suite_wire_ids = if remote_suite_wire_ids_len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(remote_suite_wire_ids_ptr, remote_suite_wire_ids_len) }
            .to_vec()
    };
    let request = ConnectionRequest {
        local: map_peer_capabilities(local),
        remote: map_peer_capabilities(remote),
        path: map_network_path(path),
        local_crypto: map_crypto_provider_capabilities(local_crypto),
        remote_suite_wire_ids,
        suite_policy: map_crypto_suite_policy(suite_policy),
        traffic_padding: map_traffic_padding_plan(traffic_padding),
    };

    match plan_connection(request) {
        Ok(plan) => {
            unsafe {
                *out_plan = map_connection_plan(plan);
            }
            SkybridgeErrorCode::Ok
        }
        Err(err) => map_connection_plan_error(err),
    }
}

#[no_mangle]
/// Maps a Core logical channel to the adapter-specific binding selected by Core.
///
/// # Safety
/// `out_mapping` must be a valid writable pointer.
pub unsafe extern "C" fn skybridge_map_channel(
    transport: SkybridgeTransportKind,
    channel: SkybridgeChannelKind,
    out_mapping: *mut SkybridgeChannelMapping,
) -> SkybridgeErrorCode {
    if out_mapping.is_null() {
        return SkybridgeErrorCode::InvalidInput;
    }

    let Some(transport) = map_ffi_transport_kind(transport) else {
        return SkybridgeErrorCode::InvalidInput;
    };

    let profile = match map_channel(transport, map_ffi_channel_kind(channel)) {
        Ok(profile) => profile,
        Err(_) => return SkybridgeErrorCode::InvalidInput,
    };

    unsafe {
        *out_mapping = map_channel_profile(&profile);
    }

    SkybridgeErrorCode::Ok
}

#[no_mangle]
/// Encodes a Core channel frame into the caller-provided output buffer.
///
/// # Safety
/// `payload_ptr` must point to `payload_len` readable bytes when non-empty.
/// `out_written_len` must be writable. `out_frame_ptr` must be writable for
/// `out_frame_capacity` bytes when the encoded frame is non-empty.
pub unsafe extern "C" fn skybridge_encode_frame(
    channel: SkybridgeChannelKind,
    sequence: u64,
    payload_ptr: *const u8,
    payload_len: usize,
    end_of_message: u8,
    out_frame_ptr: *mut u8,
    out_frame_capacity: usize,
    out_written_len: *mut usize,
) -> SkybridgeErrorCode {
    let payload = match unsafe { read_bytes(payload_ptr, payload_len) } {
        Ok(value) => value,
        Err(err) => return err,
    };
    let flags = if ffi_flag(end_of_message) {
        FrameFlags::END_OF_MESSAGE
    } else {
        FrameFlags::NONE
    };
    let encoded = match encode_frame(&CoreFrame {
        channel: map_ffi_channel_kind(channel),
        sequence,
        flags,
        payload: payload.to_vec(),
    }) {
        Ok(value) => value,
        Err(_) => return SkybridgeErrorCode::InvalidInput,
    };

    unsafe { write_bytes(out_frame_ptr, out_frame_capacity, &encoded, out_written_len) }
}

#[no_mangle]
/// Encodes a Core channel frame whose payload is wrapped in SBP2 padding.
///
/// # Safety
/// `payload_ptr` must point to `payload_len` readable bytes when non-empty.
/// `out_written_len` must be writable. `out_frame_ptr` must be writable for
/// `out_frame_capacity` bytes when the encoded frame is non-empty.
pub unsafe extern "C" fn skybridge_encode_sbp2_frame(
    channel: SkybridgeChannelKind,
    sequence: u64,
    payload_ptr: *const u8,
    payload_len: usize,
    padded_payload_len: usize,
    out_frame_ptr: *mut u8,
    out_frame_capacity: usize,
    out_written_len: *mut usize,
) -> SkybridgeErrorCode {
    let payload = match unsafe { read_bytes(payload_ptr, payload_len) } {
        Ok(value) => value,
        Err(err) => return err,
    };
    let encoded = match encode_sbp2_frame(
        map_ffi_channel_kind(channel),
        sequence,
        payload,
        padded_payload_len,
    ) {
        Ok(value) => value,
        Err(_) => return SkybridgeErrorCode::InvalidInput,
    };

    unsafe { write_bytes(out_frame_ptr, out_frame_capacity, &encoded, out_written_len) }
}

#[no_mangle]
/// Decodes frame metadata without returning the frame payload.
///
/// # Safety
/// `frame_ptr` must point to `frame_len` readable bytes. `out_metadata` must
/// be a valid writable pointer.
pub unsafe extern "C" fn skybridge_decode_frame_metadata(
    frame_ptr: *const u8,
    frame_len: usize,
    out_metadata: *mut SkybridgeFrameMetadata,
) -> SkybridgeErrorCode {
    if out_metadata.is_null() {
        return SkybridgeErrorCode::InvalidInput;
    }

    let encoded = match unsafe { read_bytes(frame_ptr, frame_len) } {
        Ok(value) => value,
        Err(err) => return err,
    };
    let frame = match decode_frame(encoded) {
        Ok(value) => value,
        Err(_) => return SkybridgeErrorCode::InvalidInput,
    };
    let metadata = match map_frame_metadata(&frame, frame_len) {
        Ok(value) => value,
        Err(err) => return err,
    };

    unsafe {
        *out_metadata = metadata;
    }
    SkybridgeErrorCode::Ok
}

#[no_mangle]
/// Decodes the application payload from a Core frame, unwrapping SBP2 when set.
///
/// # Safety
/// `frame_ptr` must point to `frame_len` readable bytes. `out_written_len` must
/// be writable. `out_payload_ptr` must be writable for `out_payload_capacity`
/// bytes when the decoded payload is non-empty.
pub unsafe extern "C" fn skybridge_decode_frame_payload(
    frame_ptr: *const u8,
    frame_len: usize,
    out_payload_ptr: *mut u8,
    out_payload_capacity: usize,
    out_written_len: *mut usize,
) -> SkybridgeErrorCode {
    let encoded = match unsafe { read_bytes(frame_ptr, frame_len) } {
        Ok(value) => value,
        Err(err) => return err,
    };
    let frame = match decode_frame(encoded) {
        Ok(value) => value,
        Err(_) => return SkybridgeErrorCode::InvalidInput,
    };
    let payload = match core_decode_frame_payload(&frame) {
        Ok(value) => value,
        Err(_) => return SkybridgeErrorCode::InvalidInput,
    };

    unsafe {
        write_bytes(
            out_payload_ptr,
            out_payload_capacity,
            &payload,
            out_written_len,
        )
    }
}

#[no_mangle]
/// Parses a DNS-SD discovery advertisement using the Core-owned TXT contract.
///
/// # Safety
/// `service_ptr` and `txt_ptr` must point to readable UTF-8 buffers when their
/// lengths are greater than zero. `out_advertisement` must be a valid writable
/// pointer.
pub unsafe extern "C" fn skybridge_parse_discovery_advertisement(
    service_ptr: *const u8,
    service_len: usize,
    txt_ptr: *const u8,
    txt_len: usize,
    out_advertisement: *mut SkybridgeDiscoveryAdvertisement,
) -> SkybridgeErrorCode {
    if out_advertisement.is_null() {
        return SkybridgeErrorCode::InvalidInput;
    }

    let service = match unsafe { read_utf8(service_ptr, service_len) } {
        Ok(value) => value,
        Err(err) => return err,
    };
    let txt = match unsafe { read_utf8(txt_ptr, txt_len) } {
        Ok(value) => value,
        Err(err) => return err,
    };

    let Some(service_kind) = parse_service_kind(service) else {
        return SkybridgeErrorCode::InvalidInput;
    };
    let advertisement = match parse_txt_advertisement(txt) {
        Ok(value) => value,
        Err(_) => return SkybridgeErrorCode::InvalidInput,
    };

    match map_discovery_advertisement(service_kind, advertisement) {
        Ok(advertisement) => {
            unsafe {
                *out_advertisement = advertisement;
            }
            SkybridgeErrorCode::Ok
        }
        Err(err) => err,
    }
}

#[no_mangle]
pub extern "C" fn skybridge_engine_new() -> *mut SkybridgeEngineHandle {
    let handle = SkybridgeEngineHandle::new();
    Box::into_raw(Box::new(handle))
}

#[no_mangle]
/// # Safety
/// The caller must ensure `handle` either originates from `skybridge_engine_new` or is null.
pub unsafe extern "C" fn skybridge_engine_free(handle: *mut SkybridgeEngineHandle) {
    if handle.is_null() {
        return;
    }
    drop(Box::from_raw(handle));
}

fn parse_config(config: SkybridgeSessionConfig) -> Result<SessionConfig, SkybridgeErrorCode> {
    if config.client_id_ptr.is_null() && config.client_id_len > 0 {
        return Err(SkybridgeErrorCode::InvalidInput);
    }
    let slice = if config.client_id_len == 0 {
        &[]
    } else {
        unsafe {
            std::slice::from_raw_parts(config.client_id_ptr as *const u8, config.client_id_len)
        }
    };
    let client_id = from_utf8(slice)
        .map_err(|_| SkybridgeErrorCode::InvalidInput)?
        .to_string();
    let peer_public_key = if config.peer_public_key_len == 0 {
        None
    } else {
        if config.peer_public_key_ptr.is_null() {
            return Err(SkybridgeErrorCode::InvalidInput);
        }
        Some(
            unsafe {
                std::slice::from_raw_parts(config.peer_public_key_ptr, config.peer_public_key_len)
            }
            .to_vec(),
        )
    };
    let config = SessionConfig {
        client_id,
        heartbeat_interval_ms: config.heartbeat_interval_ms,
        peer_public_key,
    };

    config
        .validate()
        .map_err(|_| SkybridgeErrorCode::InvalidInput)?;
    Ok(config)
}

#[no_mangle]
pub extern "C" fn skybridge_engine_connect(
    handle: *mut SkybridgeEngineHandle,
    config: SkybridgeSessionConfig,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| match parse_config(config) {
        Ok(config) => handle
            .runtime
            .block_on(handle.engine.initialize(config))
            .map(|_| {
                handle.push_event(FfiEvent {
                    kind: SkybridgeEventKind::Connected,
                    payload: Vec::new(),
                });
                SkybridgeErrorCode::Ok
            })
            .unwrap_or_else(map_core_error),
        Err(code) => code,
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
pub extern "C" fn skybridge_engine_reconnect(
    handle: *mut SkybridgeEngineHandle,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        handle
            .runtime
            .block_on(handle.engine.reconnect())
            .map(|_| {
                handle.push_event(FfiEvent {
                    kind: SkybridgeEventKind::Reconnected,
                    payload: Vec::new(),
                });
                SkybridgeErrorCode::Ok
            })
            .unwrap_or_else(map_core_error)
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
/// Returns the engine's local public key, generating one if necessary.
///
/// # Safety
/// `out_buffer` must be a valid pointer to writable `SkybridgeBuffer`. The returned
/// `data_ptr` remains valid until the next call to this function or until the handle is freed.
pub unsafe extern "C" fn skybridge_engine_local_public_key(
    handle: *mut SkybridgeEngineHandle,
    out_buffer: *mut SkybridgeBuffer,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        if out_buffer.is_null() {
            return SkybridgeErrorCode::InvalidInput;
        }
        let result = handle.runtime.block_on(async {
            if let Some(existing) = handle.engine.crypto.local_public_key() {
                Ok(existing)
            } else {
                handle.engine.crypto.begin_handshake().await
            }
        });

        match result {
            Ok(key) => {
                let mut buffer = handle.last_public_key.lock().unwrap();
                *buffer = key;
                let view = SkybridgeBuffer {
                    data_ptr: if buffer.is_empty() {
                        std::ptr::null()
                    } else {
                        buffer.as_ptr()
                    },
                    data_len: buffer.len(),
                };
                unsafe {
                    *out_buffer = view;
                }
                SkybridgeErrorCode::Ok
            }
            Err(err) => map_core_error(err),
        }
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
pub extern "C" fn skybridge_engine_send_heartbeat(
    handle: *mut SkybridgeEngineHandle,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        handle
            .runtime
            .block_on(handle.engine.send_heartbeat())
            .map(|_| {
                handle.push_event(FfiEvent {
                    kind: SkybridgeEventKind::HeartbeatAck,
                    payload: Vec::new(),
                });
                SkybridgeErrorCode::Ok
            })
            .unwrap_or_else(map_core_error)
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
pub extern "C" fn skybridge_engine_check_liveness(
    handle: *mut SkybridgeEngineHandle,
    grace_multiplier: u32,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        handle
            .runtime
            .block_on(handle.engine.check_liveness(grace_multiplier))
            .map(|_| SkybridgeErrorCode::Ok)
            .unwrap_or_else(|err| {
                if let CoreError::HeartbeatTimeout { .. } = err {
                    handle.push_event(FfiEvent {
                        kind: SkybridgeEventKind::HeartbeatTimeout,
                        payload: Vec::new(),
                    });
                }
                map_core_error(err)
            })
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
pub extern "C" fn skybridge_engine_throttle_stream(
    handle: *mut SkybridgeEngineHandle,
    flow: SkybridgeFlowRate,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        handle
            .runtime
            .block_on(handle.engine.throttle_stream(FlowRate {
                target_bitrate_bps: flow.target_bitrate_bps,
                max_latency_ms: flow.max_latency_ms,
            }));
        SkybridgeErrorCode::Ok
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
/// # Safety
/// The caller must provide a valid handle and a non-null pointer to writable metrics output.
pub unsafe extern "C" fn skybridge_engine_metrics(
    handle: *mut SkybridgeEngineHandle,
    out_metrics: *mut SkybridgeStreamMetrics,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        if out_metrics.is_null() {
            return SkybridgeErrorCode::InvalidInput;
        }
        let metrics = handle.runtime.block_on(handle.engine.metrics());
        let ppm = (metrics.packet_loss * 1_000_000.0) as u32;
        unsafe {
            *out_metrics = SkybridgeStreamMetrics {
                bitrate_bps: metrics.bitrate_bps,
                packet_loss_ppm: ppm,
            };
        }
        SkybridgeErrorCode::Ok
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
/// # Safety
/// The caller must provide a valid engine handle and, when `input_len > 0`, a non-null pointer
/// to at least `input_len` bytes of readable memory.
pub unsafe extern "C" fn skybridge_engine_send_input(
    handle: *mut SkybridgeEngineHandle,
    input_ptr: *const u8,
    input_len: usize,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        if input_len > 0 && input_ptr.is_null() {
            return SkybridgeErrorCode::InvalidInput;
        }
        let data = if input_len == 0 {
            &[]
        } else {
            std::slice::from_raw_parts(input_ptr, input_len)
        };
        handle.engine.stream_controller.record_input(data);
        handle.push_event(FfiEvent {
            kind: SkybridgeEventKind::InputReceived,
            payload: data.to_vec(),
        });
        SkybridgeErrorCode::Ok
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
pub extern "C" fn skybridge_engine_shutdown(
    handle: *mut SkybridgeEngineHandle,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        handle
            .runtime
            .block_on(handle.engine.shutdown())
            .map(|_| {
                handle.push_event(FfiEvent {
                    kind: SkybridgeEventKind::Disconnected,
                    payload: Vec::new(),
                });
                SkybridgeErrorCode::Ok
            })
            .unwrap_or_else(map_core_error)
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
pub extern "C" fn skybridge_engine_disconnect(
    handle: *mut SkybridgeEngineHandle,
) -> SkybridgeErrorCode {
    skybridge_engine_shutdown(handle)
}

#[no_mangle]
/// # Safety
/// `out_buffer` must be a valid, writable pointer to `SkybridgeBuffer`. The returned pointer
/// remains valid until the next call to encrypt/decrypt or the engine handle is freed.
pub unsafe extern "C" fn skybridge_engine_encrypt_payload(
    handle: *mut SkybridgeEngineHandle,
    plaintext_ptr: *const u8,
    plaintext_len: usize,
    out_buffer: *mut SkybridgeBuffer,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        if plaintext_len > 0 && plaintext_ptr.is_null() {
            return SkybridgeErrorCode::InvalidInput;
        }
        let plaintext = if plaintext_len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(plaintext_ptr, plaintext_len) }
        };
        handle
            .engine
            .encrypt_payload(plaintext)
            .map(|ciphertext| handle.write_crypto_output(ciphertext, out_buffer))
            .unwrap_or_else(map_core_error)
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
/// # Safety
/// `out_buffer` must be a valid, writable pointer to `SkybridgeBuffer`. The returned pointer
/// remains valid until the next encrypt/decrypt call or engine destruction.
pub unsafe extern "C" fn skybridge_engine_decrypt_payload(
    handle: *mut SkybridgeEngineHandle,
    ciphertext_ptr: *const u8,
    ciphertext_len: usize,
    out_buffer: *mut SkybridgeBuffer,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        if ciphertext_len > 0 && ciphertext_ptr.is_null() {
            return SkybridgeErrorCode::InvalidInput;
        }
        let ciphertext = if ciphertext_len == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(ciphertext_ptr, ciphertext_len) }
        };
        handle
            .engine
            .decrypt_payload(ciphertext)
            .map(|plaintext| handle.write_crypto_output(plaintext, out_buffer))
            .unwrap_or_else(map_core_error)
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
pub extern "C" fn skybridge_engine_clear_events(
    handle: *mut SkybridgeEngineHandle,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        handle.clear_events();
        SkybridgeErrorCode::Ok
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
pub extern "C" fn skybridge_engine_state(
    handle: *mut SkybridgeEngineHandle,
) -> SkybridgeSessionState {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        map_session_state(handle.engine.state.state())
    })
    .unwrap_or(SkybridgeSessionState::Disconnected)
}

#[no_mangle]
/// # Safety
/// `out_snapshot` must be a valid writable pointer. The caller owns the memory
/// and must ensure the handle is not freed while the snapshot is being
/// written.
pub unsafe extern "C" fn skybridge_engine_snapshot(
    handle: *mut SkybridgeEngineHandle,
    out_snapshot: *mut SkybridgeEngineSnapshot,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        if out_snapshot.is_null() {
            return SkybridgeErrorCode::InvalidInput;
        }

        let snapshot = handle.engine.snapshot();
        let ffi_snapshot = SkybridgeEngineSnapshot {
            state: map_session_state(snapshot.state),
            last_heartbeat_ms: snapshot.last_heartbeat_ms.unwrap_or(0),
            has_last_heartbeat: snapshot.last_heartbeat_ms.is_some(),
            has_secrets: snapshot.has_secrets,
        };

        unsafe {
            *out_snapshot = ffi_snapshot;
        }

        SkybridgeErrorCode::Ok
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}

#[no_mangle]
pub extern "C" fn skybridge_engine_last_input_len(handle: *mut SkybridgeEngineHandle) -> usize {
    SkybridgeEngineHandle::with_handle(handle, |handle| handle.input_buffer.lock().unwrap().len())
        .unwrap_or(0)
}

#[no_mangle]
/// # Safety
/// `out_event` must be a valid, writable pointer to `SkybridgeEvent` and is populated
/// with the next queued event. The returned payload pointer remains valid until the
/// next call to `skybridge_engine_poll_events` or until the engine handle is freed.
pub unsafe extern "C" fn skybridge_engine_poll_events(
    handle: *mut SkybridgeEngineHandle,
    out_event: *mut SkybridgeEvent,
) -> SkybridgeErrorCode {
    SkybridgeEngineHandle::with_handle(handle, |handle| {
        if out_event.is_null() {
            return SkybridgeErrorCode::InvalidInput;
        }
        let event = handle.pop_event();
        unsafe {
            *out_event = event;
        }
        SkybridgeErrorCode::Ok
    })
    .unwrap_or(SkybridgeErrorCode::NullHandle)
}
