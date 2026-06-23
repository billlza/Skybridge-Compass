use crate::channel::{map_channel, AdapterChannelBinding, ChannelProfile};
use crate::connection::{
    plan_connection, ConnectionPlan, ConnectionPlanError, ConnectionRequest, TrafficPaddingPlan,
};
use crate::crypto::{P256KeyExchange, P256SessionCrypto, SessionCryptoProvider, SessionSecrets};
use crate::discovery::{
    parse_service_kind, parse_txt_advertisement, DiscoveryServiceKind, PeerAdvertisement,
};
use crate::error::{CoreError, CoreResult};
use crate::file_transfer::{
    plan_file_transfer_readiness, FileTransferAddressClass, FileTransferChannelBindingKind,
    FileTransferChannelMapping, FileTransferManifestFile, FileTransferManifestMode,
    FileTransferPortProvenance, FileTransferReadinessCode, FileTransferReadinessRequest,
    FileTransferReadinessStatus, FileTransferReadinessVerdict, FileTransferRouteCandidate,
    FileTransferRouteSource, MAX_FILE_TRANSFER_CANDIDATES, MAX_FILE_TRANSFER_MANIFEST_FILES,
};
use crate::frame::{
    decode_frame, decode_frame_payload as core_decode_frame_payload, encode_frame,
    encode_sbp2_frame, CoreFrame, FrameFlags, FRAME_HEADER_LEN,
};
use crate::session::{
    AsyncSessionManager, HeartbeatEmitter, SessionAdapterBindingKind, SessionChannelBinding,
    SessionConfig, SessionState, SessionTransportBinding,
};
use crate::signaling_lifecycle::{
    project_signaling_lifecycle, SignalingFailureClass, SignalingHealth, SignalingLifecycleEvent,
    SignalingLifecycleEventKind, SignalingLifecyclePhase, SignalingLifecycleState,
    SignalingReadiness,
};
use crate::stream::{FlowRate, StreamController, StreamMetrics};
use crate::suite::{
    CryptoProviderCapabilities, CryptoSuite, CryptoSuiteAudit, CryptoSuitePolicy,
    CryptoSuiteSelectionError,
};
use crate::transport::{
    NetworkPath, PeerCapabilities, PeerPlatform, RelayPolicy, SkyBridgeChannel,
    SkyBridgeReliability, SkyBridgeTransportKind, TransportAuditReason, TransportBindingMaterial,
    TransportSelector,
};
use crate::webrtc_proof::{
    verify_webrtc_session_launch_json, VerifiedWebRtcSessionLaunch, WebRtcProofError,
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
    pub transport: SkybridgeTransportKind,
    pub transport_audit: SkybridgeTransportAuditCode,
    pub relay_required: u8,
    pub relay_allowed: u8,
    pub selected_suite: SkybridgeCryptoSuiteKind,
    pub selected_suite_wire_id: u16,
    pub suite_audit: SkybridgeCryptoSuiteAuditCode,
    pub sbp2_enabled: u8,
    pub sbp2_fixed_payload_len: usize,
    pub frame_header_len: usize,
    pub transport_binding_digest_ptr: *const u8,
    pub transport_binding_digest_len: usize,
    pub adapter_kind: SkybridgeTransportKind,
    pub is_live_adapter_ready: u8,
    pub adapter_binding_ptr: *const u8,
    pub adapter_binding_len: usize,
    pub local_endpoint_ptr: *const u8,
    pub local_endpoint_len: usize,
    pub remote_endpoint_ptr: *const u8,
    pub remote_endpoint_len: usize,
    pub selected_candidate_pair_ptr: *const u8,
    pub selected_candidate_pair_len: usize,
    pub relay_id_ptr: *const u8,
    pub relay_id_len: usize,
    pub timestamp_window_ms: u64,
    pub channel_mappings_ptr: *const SkybridgeChannelMapping,
    pub channel_mapping_count: usize,
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
    pub has_transport_binding: bool,
    pub transport_kind: SkybridgeTransportKind,
    pub adapter_kind: SkybridgeTransportKind,
    pub transport_binding_digest: [u8; 32],
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
pub struct SkybridgeTransportBindingDigest {
    pub digest: [u8; 32],
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

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeVerifiedWebRtcSessionLaunch {
    pub peer_device_id: [u8; 64],
    pub peer_device_id_len: usize,
    pub peer_public_key_fingerprint: [u8; 64],
    pub peer_public_key_fingerprint_len: usize,
    pub helper_name: [u8; 128],
    pub helper_name_len: usize,
    pub adapter_binding: [u8; 256],
    pub adapter_binding_len: usize,
    pub local_endpoint: [u8; 256],
    pub local_endpoint_len: usize,
    pub remote_endpoint: [u8; 256],
    pub remote_endpoint_len: usize,
    pub selected_candidate_pair: [u8; 256],
    pub selected_candidate_pair_len: usize,
    pub relay_id: [u8; 128],
    pub relay_id_len: usize,
    pub timestamp_window_ms: u64,
    pub captured_at_unix_ms: i64,
    pub proof_age_ms: u64,
    pub transport_secret_fingerprint: [u8; 32],
    pub capability_digest: [u8; 32],
    pub transport_binding_digest: [u8; 32],
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeSignalingLifecyclePhase {
    Idle = 0,
    Connecting = 1,
    SocketOpen = 2,
    Bound = 3,
    Reconnecting = 4,
    Closing = 5,
    Closed = 6,
    Failed = 7,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeSignalingReadiness {
    Idle = 0,
    TransportReady = 1,
    HandshakeComplete = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeSignalingHealth {
    Healthy = 0,
    DegradedRecoverable = 1,
    DegradedFatal = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeSignalingFailureClass {
    None = 0,
    AuthBindRejected = 1,
    InvalidShardOrSessionMismatch = 2,
    TokenExpired = 3,
    ProtocolViolation = 4,
    TransientNetwork = 5,
    TransientServer = 6,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeSignalingLifecycleEventKind {
    Connecting = 1,
    SocketOpen = 2,
    Bound = 3,
    Reconnecting = 4,
    Closing = 5,
    Closed = 6,
    TransportReady = 7,
    HandshakeComplete = 8,
    Failed = 9,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeSignalingLifecycleState {
    pub session_id: [u8; 128],
    pub session_id_len: usize,
    pub backend: [u8; 128],
    pub backend_len: usize,
    pub generation: u64,
    pub lifecycle_phase: SkybridgeSignalingLifecyclePhase,
    pub signaling_health: SkybridgeSignalingHealth,
    pub readiness: SkybridgeSignalingReadiness,
    pub last_established_readiness: SkybridgeSignalingReadiness,
    pub failure_class: SkybridgeSignalingFailureClass,
    pub negotiated_suite: [u8; 64],
    pub negotiated_suite_len: usize,
    pub reconnect_attempt_count: u32,
    pub business_sends_allowed: u8,
    pub can_report_connected: u8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeSignalingLifecycleEvent {
    pub session_id: [u8; 128],
    pub session_id_len: usize,
    pub backend: [u8; 128],
    pub backend_len: usize,
    pub generation: u64,
    pub kind: SkybridgeSignalingLifecycleEventKind,
    pub failure_class: SkybridgeSignalingFailureClass,
    pub negotiated_suite: [u8; 64],
    pub negotiated_suite_len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeFileTransferReadinessStatus {
    Blocked = 0,
    IntentOnly = 1,
    Ready = 2,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeFileTransferReadinessCode {
    Ok = 0,
    IntentOnlyNoFiles = 1,
    MissingRoute = 2,
    TooManyCandidates = 3,
    MissingIdentity = 4,
    TargetPeerMismatch = 5,
    UnsupportedServiceType = 6,
    InvalidHost = 7,
    RequestedPeerToPeerRoute = 8,
    UnresolvedBonjourRoute = 9,
    ResolvedPeerToPeerRoute = 10,
    InvalidPort = 11,
    RouteStalePort = 12,
    RouteProvenanceMismatch = 13,
    MissingFileChannel = 14,
    InvalidManifest = 15,
    ManifestPathRejected = 16,
    ManifestHashRejected = 17,
    ManifestTooLarge = 18,
    ByteCountOverflow = 19,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeFileTransferAddressClass {
    Invalid = 0,
    BonjourService = 1,
    LinkLocal = 2,
    LanDirect = 3,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeFileTransferRouteSource {
    AuthenticatedSession = 0,
    RecentAuthenticatedInboundTransfer = 1,
    ClassicSessionRegistry = 2,
    PresenceOutbound = 3,
    PresenceInbound = 4,
    Unified = 5,
    Manual = 6,
    BonjourResolved = 7,
    Unknown = 8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeFileTransferPortProvenance {
    Unknown = 0,
    ListenerTruth = 1,
    PresenceDescriptor = 2,
    PairingPayload = 3,
    HeartbeatPayload = 4,
    RegistryState = 5,
    ManualInput = 6,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkybridgeFileTransferManifestMode {
    IntentOnly = 0,
    Transfer = 1,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeFileTransferRouteCandidate {
    pub peer_id: [u8; 128],
    pub peer_id_len: usize,
    pub device_name: [u8; 128],
    pub device_name_len: usize,
    pub requested_host: [u8; 128],
    pub requested_host_len: usize,
    pub resolved_host: [u8; 128],
    pub resolved_host_len: usize,
    pub service_type: [u8; 64],
    pub service_type_len: usize,
    pub port: u16,
    pub has_port: u8,
    pub route_source: SkybridgeFileTransferRouteSource,
    pub port_provenance: SkybridgeFileTransferPortProvenance,
    pub listener_generation: u64,
    pub has_listener_generation: u8,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeFileTransferManifestFile {
    pub display_name: [u8; 128],
    pub display_name_len: usize,
    pub relative_path: [u8; 256],
    pub relative_path_len: usize,
    pub byte_len: u64,
    pub sha256_hex: [u8; 64],
    pub sha256_hex_len: usize,
    pub mime_type: [u8; 64],
    pub mime_type_len: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SkybridgeFileTransferPlannerVerdict {
    pub status: SkybridgeFileTransferReadinessStatus,
    pub code: SkybridgeFileTransferReadinessCode,
    pub selected_address_class: SkybridgeFileTransferAddressClass,
    pub selected_route_source: SkybridgeFileTransferRouteSource,
    pub selected_peer_id: [u8; 128],
    pub selected_peer_id_len: usize,
    pub selected_device_name: [u8; 128],
    pub selected_device_name_len: usize,
    pub selected_host: [u8; 128],
    pub selected_host_len: usize,
    pub selected_port: u16,
    pub selected_listener_generation: u64,
    pub has_selected_listener_generation: u8,
    pub manifest_version: u16,
    pub manifest_file_count: usize,
    pub manifest_total_bytes: u64,
    pub manifest_total_chunks: u64,
    pub manifest_chunk_size: u64,
    pub manifest_digest: [u8; 32],
    pub has_manifest_digest: u8,
    pub file_channel_binding_kind: SkybridgeAdapterBindingKind,
    pub has_file_channel: u8,
    pub file_channel_head_of_line_isolated: u8,
    pub frame_header_len: usize,
    pub audit: [u8; 256],
    pub audit_len: usize,
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

fn map_ffi_transport_audit(audit: SkybridgeTransportAuditCode) -> Option<TransportAuditReason> {
    match audit {
        SkybridgeTransportAuditCode::AppleNativeDefault => {
            Some(TransportAuditReason::AppleNativeDefault)
        }
        SkybridgeTransportAuditCode::WindowsNativeMsQuicSameLan => {
            Some(TransportAuditReason::WindowsNativeMsQuicSameLan)
        }
        SkybridgeTransportAuditCode::WindowsSkyBridgeIceMsQuic => {
            Some(TransportAuditReason::WindowsSkyBridgeIceMsQuic)
        }
        SkybridgeTransportAuditCode::WebRtcInterop => Some(TransportAuditReason::WebRtcInterop),
        SkybridgeTransportAuditCode::TcpFallbackSameLan => {
            Some(TransportAuditReason::TcpFallbackSameLan)
        }
        SkybridgeTransportAuditCode::RelayFallback => Some(TransportAuditReason::RelayFallback),
        SkybridgeTransportAuditCode::UnsupportedNoCompatibleTransport => None,
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

fn map_ffi_crypto_suite(suite: SkybridgeCryptoSuiteKind) -> Option<CryptoSuite> {
    match suite {
        SkybridgeCryptoSuiteKind::XWingHybrid => Some(CryptoSuite::XWingHybrid),
        SkybridgeCryptoSuiteKind::MlKem768MlDsa65 => Some(CryptoSuite::MlKem768MlDsa65),
        SkybridgeCryptoSuiteKind::X25519Ed25519 => Some(CryptoSuite::X25519Ed25519),
        SkybridgeCryptoSuiteKind::P256Ecdsa => Some(CryptoSuite::P256Ecdsa),
        SkybridgeCryptoSuiteKind::Unknown => None,
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

fn map_ffi_crypto_suite_audit(audit: SkybridgeCryptoSuiteAuditCode) -> Option<CryptoSuiteAudit> {
    match audit {
        SkybridgeCryptoSuiteAuditCode::HybridPqcPreferred => {
            Some(CryptoSuiteAudit::HybridPqcPreferred)
        }
        SkybridgeCryptoSuiteAuditCode::PurePqcPreferred => Some(CryptoSuiteAudit::PurePqcPreferred),
        SkybridgeCryptoSuiteAuditCode::ClassicPolicyFallback => {
            Some(CryptoSuiteAudit::ClassicPolicyFallback)
        }
        SkybridgeCryptoSuiteAuditCode::LegacyPolicyFallback => {
            Some(CryptoSuiteAudit::LegacyPolicyFallback)
        }
        SkybridgeCryptoSuiteAuditCode::None => None,
    }
}

fn map_ffi_reliability(
    reliability: SkybridgeReliabilityKind,
    max_retransmits: u16,
) -> Result<SkyBridgeReliability, SkybridgeErrorCode> {
    match reliability {
        SkybridgeReliabilityKind::ReliableOrdered => {
            if max_retransmits != 0 {
                return Err(SkybridgeErrorCode::InvalidInput);
            }
            Ok(SkyBridgeReliability::ReliableOrdered)
        }
        SkybridgeReliabilityKind::ReliableUnordered => {
            if max_retransmits != 0 {
                return Err(SkybridgeErrorCode::InvalidInput);
            }
            Ok(SkyBridgeReliability::ReliableUnordered)
        }
        SkybridgeReliabilityKind::PartialReliable => {
            if max_retransmits == 0 {
                return Err(SkybridgeErrorCode::InvalidInput);
            }
            Ok(SkyBridgeReliability::PartialReliable { max_retransmits })
        }
        SkybridgeReliabilityKind::Unreliable => {
            if max_retransmits != 0 {
                return Err(SkybridgeErrorCode::InvalidInput);
            }
            Ok(SkyBridgeReliability::Unreliable)
        }
    }
}

fn map_ffi_adapter_binding_kind(
    binding_kind: SkybridgeAdapterBindingKind,
) -> SessionAdapterBindingKind {
    match binding_kind {
        SkybridgeAdapterBindingKind::AppleStream => SessionAdapterBindingKind::AppleStream,
        SkybridgeAdapterBindingKind::AppleDatagram => SessionAdapterBindingKind::AppleDatagram,
        SkybridgeAdapterBindingKind::MsQuicStream => SessionAdapterBindingKind::MsQuicStream,
        SkybridgeAdapterBindingKind::MsQuicDatagram => SessionAdapterBindingKind::MsQuicDatagram,
        SkybridgeAdapterBindingKind::WebRtcDataChannel => {
            SessionAdapterBindingKind::WebRtcDataChannel
        }
        SkybridgeAdapterBindingKind::RelayStream => SessionAdapterBindingKind::RelayStream,
        SkybridgeAdapterBindingKind::TcpStream => SessionAdapterBindingKind::TcpStream,
    }
}

fn map_ffi_session_channel_mapping(
    mapping: SkybridgeChannelMapping,
) -> Result<SessionChannelBinding, SkybridgeErrorCode> {
    Ok(SessionChannelBinding {
        channel: map_ffi_channel_kind(mapping.channel),
        reliability: map_ffi_reliability(mapping.reliability, mapping.max_retransmits)?,
        max_retransmits: mapping.max_retransmits,
        binding_kind: map_ffi_adapter_binding_kind(mapping.binding_kind),
        head_of_line_isolated: ffi_flag(mapping.head_of_line_isolated),
    })
}

fn parse_channel_mappings(
    config: SkybridgeSessionConfig,
) -> Result<Vec<SessionChannelBinding>, SkybridgeErrorCode> {
    if config.channel_mapping_count != 5 {
        return Err(SkybridgeErrorCode::InvalidInput);
    }
    if config.channel_mappings_ptr.is_null() {
        return Err(SkybridgeErrorCode::InvalidInput);
    }

    let mappings = unsafe {
        std::slice::from_raw_parts(config.channel_mappings_ptr, config.channel_mapping_count)
    };
    mappings
        .iter()
        .map(|mapping| map_ffi_session_channel_mapping(*mapping))
        .collect()
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

fn map_webrtc_proof_error(err: WebRtcProofError) -> SkybridgeErrorCode {
    match err {
        WebRtcProofError::UnsupportedTransport => SkybridgeErrorCode::UnsupportedTransport,
        _ => SkybridgeErrorCode::InvalidInput,
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

fn empty_verified_webrtc_session_launch() -> SkybridgeVerifiedWebRtcSessionLaunch {
    SkybridgeVerifiedWebRtcSessionLaunch {
        peer_device_id: [0; 64],
        peer_device_id_len: 0,
        peer_public_key_fingerprint: [0; 64],
        peer_public_key_fingerprint_len: 0,
        helper_name: [0; 128],
        helper_name_len: 0,
        adapter_binding: [0; 256],
        adapter_binding_len: 0,
        local_endpoint: [0; 256],
        local_endpoint_len: 0,
        remote_endpoint: [0; 256],
        remote_endpoint_len: 0,
        selected_candidate_pair: [0; 256],
        selected_candidate_pair_len: 0,
        relay_id: [0; 128],
        relay_id_len: 0,
        timestamp_window_ms: 0,
        captured_at_unix_ms: 0,
        proof_age_ms: 0,
        transport_secret_fingerprint: [0; 32],
        capability_digest: [0; 32],
        transport_binding_digest: [0; 32],
    }
}

fn map_verified_webrtc_session_launch(
    launch: VerifiedWebRtcSessionLaunch,
) -> Result<SkybridgeVerifiedWebRtcSessionLaunch, SkybridgeErrorCode> {
    let proof = launch.proof;
    let mut ffi = empty_verified_webrtc_session_launch();

    ffi.peer_device_id_len = write_utf8(&mut ffi.peer_device_id, proof.peer_device_id.as_bytes())?;
    ffi.peer_public_key_fingerprint_len = write_utf8(
        &mut ffi.peer_public_key_fingerprint,
        proof.peer_public_key_fingerprint.as_bytes(),
    )?;
    ffi.helper_name_len = write_utf8(&mut ffi.helper_name, proof.helper_name.as_bytes())?;
    ffi.adapter_binding_len =
        write_utf8(&mut ffi.adapter_binding, proof.adapter_binding.as_bytes())?;
    ffi.local_endpoint_len = write_utf8(&mut ffi.local_endpoint, proof.local_endpoint.as_bytes())?;
    ffi.remote_endpoint_len =
        write_utf8(&mut ffi.remote_endpoint, proof.remote_endpoint.as_bytes())?;
    ffi.selected_candidate_pair_len = write_utf8(
        &mut ffi.selected_candidate_pair,
        proof.selected_candidate_pair.as_bytes(),
    )?;
    if let Some(relay_id) = proof.relay_id {
        ffi.relay_id_len = write_utf8(&mut ffi.relay_id, relay_id.as_bytes())?;
    }
    ffi.timestamp_window_ms = proof.timestamp_window_ms;
    ffi.captured_at_unix_ms = proof.captured_at_unix_ms;
    ffi.proof_age_ms = proof.proof_age_ms;
    ffi.transport_secret_fingerprint = proof.transport_secret_fingerprint;
    ffi.capability_digest = proof.capability_digest;
    ffi.transport_binding_digest = launch.transport_binding_digest;

    Ok(ffi)
}

fn empty_signaling_lifecycle_state() -> SkybridgeSignalingLifecycleState {
    SkybridgeSignalingLifecycleState {
        session_id: [0; 128],
        session_id_len: 0,
        backend: [0; 128],
        backend_len: 0,
        generation: 0,
        lifecycle_phase: SkybridgeSignalingLifecyclePhase::Idle,
        signaling_health: SkybridgeSignalingHealth::Healthy,
        readiness: SkybridgeSignalingReadiness::Idle,
        last_established_readiness: SkybridgeSignalingReadiness::Idle,
        failure_class: SkybridgeSignalingFailureClass::None,
        negotiated_suite: [0; 64],
        negotiated_suite_len: 0,
        reconnect_attempt_count: 0,
        business_sends_allowed: 0,
        can_report_connected: 0,
    }
}

fn map_signaling_lifecycle_state_to_ffi(
    state: SignalingLifecycleState,
) -> Result<SkybridgeSignalingLifecycleState, SkybridgeErrorCode> {
    let mut ffi = empty_signaling_lifecycle_state();
    ffi.session_id_len = write_utf8(&mut ffi.session_id, state.session_id.as_bytes())?;
    ffi.backend_len = write_utf8(&mut ffi.backend, state.backend.as_bytes())?;
    ffi.generation = state.generation;
    ffi.lifecycle_phase = map_signaling_phase_to_ffi(state.lifecycle_phase);
    ffi.signaling_health = map_signaling_health_to_ffi(state.signaling_health);
    ffi.readiness = map_signaling_readiness_to_ffi(state.readiness);
    ffi.last_established_readiness =
        map_signaling_readiness_to_ffi(state.last_established_readiness);
    ffi.failure_class = map_signaling_failure_class_to_ffi(state.failure_class);
    if let Some(negotiated_suite) = state.negotiated_suite.as_ref() {
        ffi.negotiated_suite_len =
            write_utf8(&mut ffi.negotiated_suite, negotiated_suite.as_bytes())?;
    }
    ffi.reconnect_attempt_count = state.reconnect_attempt_count;
    ffi.business_sends_allowed = u8::from(state.business_sends_allowed());
    ffi.can_report_connected = u8::from(state.can_report_connected());
    Ok(ffi)
}

fn map_ffi_signaling_lifecycle_state(
    state: SkybridgeSignalingLifecycleState,
) -> Result<SignalingLifecycleState, SkybridgeErrorCode> {
    Ok(SignalingLifecycleState {
        session_id: read_fixed_utf8(&state.session_id, state.session_id_len)?.to_string(),
        backend: read_fixed_utf8(&state.backend, state.backend_len)?.to_string(),
        generation: state.generation,
        lifecycle_phase: map_ffi_signaling_phase(state.lifecycle_phase),
        signaling_health: map_ffi_signaling_health(state.signaling_health),
        readiness: map_ffi_signaling_readiness(state.readiness),
        last_established_readiness: map_ffi_signaling_readiness(state.last_established_readiness),
        failure_class: map_ffi_signaling_failure_class(state.failure_class),
        negotiated_suite: optional_fixed_utf8(&state.negotiated_suite, state.negotiated_suite_len)?,
        reconnect_attempt_count: state.reconnect_attempt_count,
    })
}

fn map_ffi_signaling_lifecycle_event(
    event: SkybridgeSignalingLifecycleEvent,
) -> Result<SignalingLifecycleEvent, SkybridgeErrorCode> {
    Ok(SignalingLifecycleEvent {
        session_id: read_fixed_utf8(&event.session_id, event.session_id_len)?.to_string(),
        backend: read_fixed_utf8(&event.backend, event.backend_len)?.to_string(),
        generation: event.generation,
        kind: map_ffi_signaling_event_kind(event.kind),
        failure_class: map_ffi_signaling_failure_class(event.failure_class),
        negotiated_suite: optional_fixed_utf8(&event.negotiated_suite, event.negotiated_suite_len)?,
    })
}

fn read_fixed_utf8(buffer: &[u8], len: usize) -> Result<&str, SkybridgeErrorCode> {
    if len > buffer.len() {
        return Err(SkybridgeErrorCode::InvalidInput);
    }

    from_utf8(&buffer[..len]).map_err(|_| SkybridgeErrorCode::InvalidInput)
}

fn optional_fixed_utf8(buffer: &[u8], len: usize) -> Result<Option<String>, SkybridgeErrorCode> {
    if len == 0 {
        return Ok(None);
    }

    Ok(Some(read_fixed_utf8(buffer, len)?.to_string()))
}

fn map_signaling_phase_to_ffi(phase: SignalingLifecyclePhase) -> SkybridgeSignalingLifecyclePhase {
    match phase {
        SignalingLifecyclePhase::Idle => SkybridgeSignalingLifecyclePhase::Idle,
        SignalingLifecyclePhase::Connecting => SkybridgeSignalingLifecyclePhase::Connecting,
        SignalingLifecyclePhase::SocketOpen => SkybridgeSignalingLifecyclePhase::SocketOpen,
        SignalingLifecyclePhase::Bound => SkybridgeSignalingLifecyclePhase::Bound,
        SignalingLifecyclePhase::Reconnecting => SkybridgeSignalingLifecyclePhase::Reconnecting,
        SignalingLifecyclePhase::Closing => SkybridgeSignalingLifecyclePhase::Closing,
        SignalingLifecyclePhase::Closed => SkybridgeSignalingLifecyclePhase::Closed,
        SignalingLifecyclePhase::Failed => SkybridgeSignalingLifecyclePhase::Failed,
    }
}

fn map_ffi_signaling_phase(phase: SkybridgeSignalingLifecyclePhase) -> SignalingLifecyclePhase {
    match phase {
        SkybridgeSignalingLifecyclePhase::Idle => SignalingLifecyclePhase::Idle,
        SkybridgeSignalingLifecyclePhase::Connecting => SignalingLifecyclePhase::Connecting,
        SkybridgeSignalingLifecyclePhase::SocketOpen => SignalingLifecyclePhase::SocketOpen,
        SkybridgeSignalingLifecyclePhase::Bound => SignalingLifecyclePhase::Bound,
        SkybridgeSignalingLifecyclePhase::Reconnecting => SignalingLifecyclePhase::Reconnecting,
        SkybridgeSignalingLifecyclePhase::Closing => SignalingLifecyclePhase::Closing,
        SkybridgeSignalingLifecyclePhase::Closed => SignalingLifecyclePhase::Closed,
        SkybridgeSignalingLifecyclePhase::Failed => SignalingLifecyclePhase::Failed,
    }
}

fn map_signaling_readiness_to_ffi(readiness: SignalingReadiness) -> SkybridgeSignalingReadiness {
    match readiness {
        SignalingReadiness::Idle => SkybridgeSignalingReadiness::Idle,
        SignalingReadiness::TransportReady => SkybridgeSignalingReadiness::TransportReady,
        SignalingReadiness::HandshakeComplete => SkybridgeSignalingReadiness::HandshakeComplete,
    }
}

fn map_ffi_signaling_readiness(readiness: SkybridgeSignalingReadiness) -> SignalingReadiness {
    match readiness {
        SkybridgeSignalingReadiness::Idle => SignalingReadiness::Idle,
        SkybridgeSignalingReadiness::TransportReady => SignalingReadiness::TransportReady,
        SkybridgeSignalingReadiness::HandshakeComplete => SignalingReadiness::HandshakeComplete,
    }
}

fn map_signaling_health_to_ffi(health: SignalingHealth) -> SkybridgeSignalingHealth {
    match health {
        SignalingHealth::Healthy => SkybridgeSignalingHealth::Healthy,
        SignalingHealth::DegradedRecoverable => SkybridgeSignalingHealth::DegradedRecoverable,
        SignalingHealth::DegradedFatal => SkybridgeSignalingHealth::DegradedFatal,
    }
}

fn map_ffi_signaling_health(health: SkybridgeSignalingHealth) -> SignalingHealth {
    match health {
        SkybridgeSignalingHealth::Healthy => SignalingHealth::Healthy,
        SkybridgeSignalingHealth::DegradedRecoverable => SignalingHealth::DegradedRecoverable,
        SkybridgeSignalingHealth::DegradedFatal => SignalingHealth::DegradedFatal,
    }
}

fn map_signaling_failure_class_to_ffi(
    failure: SignalingFailureClass,
) -> SkybridgeSignalingFailureClass {
    match failure {
        SignalingFailureClass::None => SkybridgeSignalingFailureClass::None,
        SignalingFailureClass::AuthBindRejected => SkybridgeSignalingFailureClass::AuthBindRejected,
        SignalingFailureClass::InvalidShardOrSessionMismatch => {
            SkybridgeSignalingFailureClass::InvalidShardOrSessionMismatch
        }
        SignalingFailureClass::TokenExpired => SkybridgeSignalingFailureClass::TokenExpired,
        SignalingFailureClass::ProtocolViolation => {
            SkybridgeSignalingFailureClass::ProtocolViolation
        }
        SignalingFailureClass::TransientNetwork => SkybridgeSignalingFailureClass::TransientNetwork,
        SignalingFailureClass::TransientServer => SkybridgeSignalingFailureClass::TransientServer,
    }
}

fn map_ffi_signaling_failure_class(
    failure: SkybridgeSignalingFailureClass,
) -> SignalingFailureClass {
    match failure {
        SkybridgeSignalingFailureClass::None => SignalingFailureClass::None,
        SkybridgeSignalingFailureClass::AuthBindRejected => SignalingFailureClass::AuthBindRejected,
        SkybridgeSignalingFailureClass::InvalidShardOrSessionMismatch => {
            SignalingFailureClass::InvalidShardOrSessionMismatch
        }
        SkybridgeSignalingFailureClass::TokenExpired => SignalingFailureClass::TokenExpired,
        SkybridgeSignalingFailureClass::ProtocolViolation => {
            SignalingFailureClass::ProtocolViolation
        }
        SkybridgeSignalingFailureClass::TransientNetwork => SignalingFailureClass::TransientNetwork,
        SkybridgeSignalingFailureClass::TransientServer => SignalingFailureClass::TransientServer,
    }
}

fn map_ffi_signaling_event_kind(
    kind: SkybridgeSignalingLifecycleEventKind,
) -> SignalingLifecycleEventKind {
    match kind {
        SkybridgeSignalingLifecycleEventKind::Connecting => SignalingLifecycleEventKind::Connecting,
        SkybridgeSignalingLifecycleEventKind::SocketOpen => SignalingLifecycleEventKind::SocketOpen,
        SkybridgeSignalingLifecycleEventKind::Bound => SignalingLifecycleEventKind::Bound,
        SkybridgeSignalingLifecycleEventKind::Reconnecting => {
            SignalingLifecycleEventKind::Reconnecting
        }
        SkybridgeSignalingLifecycleEventKind::Closing => SignalingLifecycleEventKind::Closing,
        SkybridgeSignalingLifecycleEventKind::Closed => SignalingLifecycleEventKind::Closed,
        SkybridgeSignalingLifecycleEventKind::TransportReady => {
            SignalingLifecycleEventKind::TransportReady
        }
        SkybridgeSignalingLifecycleEventKind::HandshakeComplete => {
            SignalingLifecycleEventKind::HandshakeComplete
        }
        SkybridgeSignalingLifecycleEventKind::Failed => SignalingLifecycleEventKind::Failed,
    }
}

fn empty_file_transfer_planner_verdict() -> SkybridgeFileTransferPlannerVerdict {
    SkybridgeFileTransferPlannerVerdict {
        status: SkybridgeFileTransferReadinessStatus::Blocked,
        code: SkybridgeFileTransferReadinessCode::MissingRoute,
        selected_address_class: SkybridgeFileTransferAddressClass::Invalid,
        selected_route_source: SkybridgeFileTransferRouteSource::Unknown,
        selected_peer_id: [0; 128],
        selected_peer_id_len: 0,
        selected_device_name: [0; 128],
        selected_device_name_len: 0,
        selected_host: [0; 128],
        selected_host_len: 0,
        selected_port: 0,
        selected_listener_generation: 0,
        has_selected_listener_generation: 0,
        manifest_version: 0,
        manifest_file_count: 0,
        manifest_total_bytes: 0,
        manifest_total_chunks: 0,
        manifest_chunk_size: 0,
        manifest_digest: [0; 32],
        has_manifest_digest: 0,
        file_channel_binding_kind: SkybridgeAdapterBindingKind::WebRtcDataChannel,
        has_file_channel: 0,
        file_channel_head_of_line_isolated: 0,
        frame_header_len: FRAME_HEADER_LEN,
        audit: [0; 256],
        audit_len: 0,
    }
}

fn map_file_transfer_status(
    status: FileTransferReadinessStatus,
) -> SkybridgeFileTransferReadinessStatus {
    match status {
        FileTransferReadinessStatus::Blocked => SkybridgeFileTransferReadinessStatus::Blocked,
        FileTransferReadinessStatus::IntentOnly => SkybridgeFileTransferReadinessStatus::IntentOnly,
        FileTransferReadinessStatus::Ready => SkybridgeFileTransferReadinessStatus::Ready,
    }
}

fn map_file_transfer_code(code: FileTransferReadinessCode) -> SkybridgeFileTransferReadinessCode {
    match code {
        FileTransferReadinessCode::Ok => SkybridgeFileTransferReadinessCode::Ok,
        FileTransferReadinessCode::IntentOnlyNoFiles => {
            SkybridgeFileTransferReadinessCode::IntentOnlyNoFiles
        }
        FileTransferReadinessCode::MissingRoute => SkybridgeFileTransferReadinessCode::MissingRoute,
        FileTransferReadinessCode::TooManyCandidates => {
            SkybridgeFileTransferReadinessCode::TooManyCandidates
        }
        FileTransferReadinessCode::MissingIdentity => {
            SkybridgeFileTransferReadinessCode::MissingIdentity
        }
        FileTransferReadinessCode::TargetPeerMismatch => {
            SkybridgeFileTransferReadinessCode::TargetPeerMismatch
        }
        FileTransferReadinessCode::UnsupportedServiceType => {
            SkybridgeFileTransferReadinessCode::UnsupportedServiceType
        }
        FileTransferReadinessCode::InvalidHost => SkybridgeFileTransferReadinessCode::InvalidHost,
        FileTransferReadinessCode::RequestedPeerToPeerRoute => {
            SkybridgeFileTransferReadinessCode::RequestedPeerToPeerRoute
        }
        FileTransferReadinessCode::UnresolvedBonjourRoute => {
            SkybridgeFileTransferReadinessCode::UnresolvedBonjourRoute
        }
        FileTransferReadinessCode::ResolvedPeerToPeerRoute => {
            SkybridgeFileTransferReadinessCode::ResolvedPeerToPeerRoute
        }
        FileTransferReadinessCode::InvalidPort => SkybridgeFileTransferReadinessCode::InvalidPort,
        FileTransferReadinessCode::RouteStalePort => {
            SkybridgeFileTransferReadinessCode::RouteStalePort
        }
        FileTransferReadinessCode::RouteProvenanceMismatch => {
            SkybridgeFileTransferReadinessCode::RouteProvenanceMismatch
        }
        FileTransferReadinessCode::MissingFileChannel => {
            SkybridgeFileTransferReadinessCode::MissingFileChannel
        }
        FileTransferReadinessCode::InvalidManifest => {
            SkybridgeFileTransferReadinessCode::InvalidManifest
        }
        FileTransferReadinessCode::ManifestPathRejected => {
            SkybridgeFileTransferReadinessCode::ManifestPathRejected
        }
        FileTransferReadinessCode::ManifestHashRejected => {
            SkybridgeFileTransferReadinessCode::ManifestHashRejected
        }
        FileTransferReadinessCode::ManifestTooLarge => {
            SkybridgeFileTransferReadinessCode::ManifestTooLarge
        }
        FileTransferReadinessCode::ByteCountOverflow => {
            SkybridgeFileTransferReadinessCode::ByteCountOverflow
        }
    }
}

fn map_file_transfer_address_class(
    class: FileTransferAddressClass,
) -> SkybridgeFileTransferAddressClass {
    match class {
        FileTransferAddressClass::Invalid => SkybridgeFileTransferAddressClass::Invalid,
        FileTransferAddressClass::BonjourService => {
            SkybridgeFileTransferAddressClass::BonjourService
        }
        FileTransferAddressClass::LinkLocal => SkybridgeFileTransferAddressClass::LinkLocal,
        FileTransferAddressClass::LanDirect => SkybridgeFileTransferAddressClass::LanDirect,
    }
}

fn map_file_transfer_route_source(
    source: FileTransferRouteSource,
) -> SkybridgeFileTransferRouteSource {
    match source {
        FileTransferRouteSource::AuthenticatedSession => {
            SkybridgeFileTransferRouteSource::AuthenticatedSession
        }
        FileTransferRouteSource::RecentAuthenticatedInboundTransfer => {
            SkybridgeFileTransferRouteSource::RecentAuthenticatedInboundTransfer
        }
        FileTransferRouteSource::ClassicSessionRegistry => {
            SkybridgeFileTransferRouteSource::ClassicSessionRegistry
        }
        FileTransferRouteSource::PresenceOutbound => {
            SkybridgeFileTransferRouteSource::PresenceOutbound
        }
        FileTransferRouteSource::PresenceInbound => {
            SkybridgeFileTransferRouteSource::PresenceInbound
        }
        FileTransferRouteSource::Unified => SkybridgeFileTransferRouteSource::Unified,
        FileTransferRouteSource::Manual => SkybridgeFileTransferRouteSource::Manual,
        FileTransferRouteSource::BonjourResolved => {
            SkybridgeFileTransferRouteSource::BonjourResolved
        }
        FileTransferRouteSource::Unknown => SkybridgeFileTransferRouteSource::Unknown,
    }
}

fn map_ffi_file_transfer_route_source(
    source: SkybridgeFileTransferRouteSource,
) -> FileTransferRouteSource {
    match source {
        SkybridgeFileTransferRouteSource::AuthenticatedSession => {
            FileTransferRouteSource::AuthenticatedSession
        }
        SkybridgeFileTransferRouteSource::RecentAuthenticatedInboundTransfer => {
            FileTransferRouteSource::RecentAuthenticatedInboundTransfer
        }
        SkybridgeFileTransferRouteSource::ClassicSessionRegistry => {
            FileTransferRouteSource::ClassicSessionRegistry
        }
        SkybridgeFileTransferRouteSource::PresenceOutbound => {
            FileTransferRouteSource::PresenceOutbound
        }
        SkybridgeFileTransferRouteSource::PresenceInbound => {
            FileTransferRouteSource::PresenceInbound
        }
        SkybridgeFileTransferRouteSource::Unified => FileTransferRouteSource::Unified,
        SkybridgeFileTransferRouteSource::Manual => FileTransferRouteSource::Manual,
        SkybridgeFileTransferRouteSource::BonjourResolved => {
            FileTransferRouteSource::BonjourResolved
        }
        SkybridgeFileTransferRouteSource::Unknown => FileTransferRouteSource::Unknown,
    }
}

fn map_ffi_file_transfer_port_provenance(
    provenance: SkybridgeFileTransferPortProvenance,
) -> FileTransferPortProvenance {
    match provenance {
        SkybridgeFileTransferPortProvenance::Unknown => FileTransferPortProvenance::Unknown,
        SkybridgeFileTransferPortProvenance::ListenerTruth => {
            FileTransferPortProvenance::ListenerTruth
        }
        SkybridgeFileTransferPortProvenance::PresenceDescriptor => {
            FileTransferPortProvenance::PresenceDescriptor
        }
        SkybridgeFileTransferPortProvenance::PairingPayload => {
            FileTransferPortProvenance::PairingPayload
        }
        SkybridgeFileTransferPortProvenance::HeartbeatPayload => {
            FileTransferPortProvenance::HeartbeatPayload
        }
        SkybridgeFileTransferPortProvenance::RegistryState => {
            FileTransferPortProvenance::RegistryState
        }
        SkybridgeFileTransferPortProvenance::ManualInput => FileTransferPortProvenance::ManualInput,
    }
}

fn map_ffi_file_transfer_manifest_mode(
    mode: SkybridgeFileTransferManifestMode,
) -> FileTransferManifestMode {
    match mode {
        SkybridgeFileTransferManifestMode::IntentOnly => FileTransferManifestMode::IntentOnly,
        SkybridgeFileTransferManifestMode::Transfer => FileTransferManifestMode::Transfer,
    }
}

fn map_file_transfer_channel_binding_kind(
    kind: FileTransferChannelBindingKind,
) -> SkybridgeAdapterBindingKind {
    match kind {
        FileTransferChannelBindingKind::AppleStream => SkybridgeAdapterBindingKind::AppleStream,
        FileTransferChannelBindingKind::AppleDatagram => SkybridgeAdapterBindingKind::AppleDatagram,
        FileTransferChannelBindingKind::MsQuicStream => SkybridgeAdapterBindingKind::MsQuicStream,
        FileTransferChannelBindingKind::MsQuicDatagram => {
            SkybridgeAdapterBindingKind::MsQuicDatagram
        }
        FileTransferChannelBindingKind::WebRtcDataChannel => {
            SkybridgeAdapterBindingKind::WebRtcDataChannel
        }
        FileTransferChannelBindingKind::RelayStream => SkybridgeAdapterBindingKind::RelayStream,
        FileTransferChannelBindingKind::TcpStream => SkybridgeAdapterBindingKind::TcpStream,
    }
}

fn map_ffi_file_transfer_channel_binding_kind(
    kind: SkybridgeAdapterBindingKind,
) -> FileTransferChannelBindingKind {
    match kind {
        SkybridgeAdapterBindingKind::AppleStream => FileTransferChannelBindingKind::AppleStream,
        SkybridgeAdapterBindingKind::AppleDatagram => FileTransferChannelBindingKind::AppleDatagram,
        SkybridgeAdapterBindingKind::MsQuicStream => FileTransferChannelBindingKind::MsQuicStream,
        SkybridgeAdapterBindingKind::MsQuicDatagram => {
            FileTransferChannelBindingKind::MsQuicDatagram
        }
        SkybridgeAdapterBindingKind::WebRtcDataChannel => {
            FileTransferChannelBindingKind::WebRtcDataChannel
        }
        SkybridgeAdapterBindingKind::RelayStream => FileTransferChannelBindingKind::RelayStream,
        SkybridgeAdapterBindingKind::TcpStream => FileTransferChannelBindingKind::TcpStream,
    }
}

fn map_ffi_file_transfer_channel_mapping(
    mapping: SkybridgeChannelMapping,
) -> Result<FileTransferChannelMapping, SkybridgeErrorCode> {
    Ok(FileTransferChannelMapping {
        channel: map_ffi_channel_kind(mapping.channel),
        reliability: map_ffi_reliability(mapping.reliability, mapping.max_retransmits)?,
        binding_kind: map_ffi_file_transfer_channel_binding_kind(mapping.binding_kind),
        head_of_line_isolated: ffi_flag(mapping.head_of_line_isolated),
    })
}

fn map_ffi_file_transfer_candidate(
    candidate: SkybridgeFileTransferRouteCandidate,
) -> Result<FileTransferRouteCandidate, SkybridgeErrorCode> {
    Ok(FileTransferRouteCandidate {
        peer_id: read_fixed_utf8(&candidate.peer_id, candidate.peer_id_len)?.to_string(),
        device_name: read_fixed_utf8(&candidate.device_name, candidate.device_name_len)?
            .to_string(),
        requested_host: read_fixed_utf8(&candidate.requested_host, candidate.requested_host_len)?
            .to_string(),
        resolved_host: optional_fixed_utf8(&candidate.resolved_host, candidate.resolved_host_len)?,
        service_type: optional_fixed_utf8(&candidate.service_type, candidate.service_type_len)?,
        port: ffi_flag(candidate.has_port).then_some(candidate.port),
        route_source: map_ffi_file_transfer_route_source(candidate.route_source),
        port_provenance: map_ffi_file_transfer_port_provenance(candidate.port_provenance),
        listener_generation: ffi_flag(candidate.has_listener_generation)
            .then_some(candidate.listener_generation),
    })
}

fn map_ffi_file_transfer_manifest_file(
    file: SkybridgeFileTransferManifestFile,
) -> Result<FileTransferManifestFile, SkybridgeErrorCode> {
    Ok(FileTransferManifestFile {
        display_name: read_fixed_utf8(&file.display_name, file.display_name_len)?.to_string(),
        relative_path: read_fixed_utf8(&file.relative_path, file.relative_path_len)?.to_string(),
        byte_len: file.byte_len,
        sha256_hex: read_fixed_utf8(&file.sha256_hex, file.sha256_hex_len)?.to_string(),
        mime_type: optional_fixed_utf8(&file.mime_type, file.mime_type_len)?,
    })
}

fn map_file_transfer_verdict(
    verdict: FileTransferReadinessVerdict,
) -> Result<SkybridgeFileTransferPlannerVerdict, SkybridgeErrorCode> {
    let mut ffi = empty_file_transfer_planner_verdict();
    ffi.status = map_file_transfer_status(verdict.status);
    ffi.code = map_file_transfer_code(verdict.code);
    ffi.frame_header_len = verdict.frame_header_len;
    ffi.audit_len = write_utf8(&mut ffi.audit, verdict.audit.as_bytes())?;

    if let Some(route) = verdict.selected_route {
        ffi.selected_address_class = map_file_transfer_address_class(route.address_class);
        ffi.selected_route_source = map_file_transfer_route_source(route.route_source);
        ffi.selected_peer_id_len = write_utf8(&mut ffi.selected_peer_id, route.peer_id.as_bytes())?;
        ffi.selected_device_name_len =
            write_utf8(&mut ffi.selected_device_name, route.device_name.as_bytes())?;
        ffi.selected_host_len = write_utf8(&mut ffi.selected_host, route.host.as_bytes())?;
        ffi.selected_port = route.port;
        if let Some(generation) = route.listener_generation {
            ffi.selected_listener_generation = generation;
            ffi.has_selected_listener_generation = 1;
        }
    }

    if let Some(manifest) = verdict.manifest {
        ffi.manifest_version = manifest.version;
        ffi.manifest_file_count = manifest.file_count;
        ffi.manifest_total_bytes = manifest.total_bytes;
        ffi.manifest_total_chunks = manifest.total_chunks;
        ffi.manifest_chunk_size = manifest.chunk_size;
        ffi.manifest_digest = manifest.digest;
        ffi.has_manifest_digest = 1;
    }

    if let Some(file_channel) = verdict.file_channel {
        ffi.file_channel_binding_kind =
            map_file_transfer_channel_binding_kind(file_channel.binding_kind);
        ffi.has_file_channel = 1;
        ffi.file_channel_head_of_line_isolated = u8::from(file_channel.head_of_line_isolated);
    }

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
/// Computes the Core transcript digest that binds a selected transport adapter
/// and candidate pair to the session handshake.
///
/// # Safety
/// UTF-8 pointer/length pairs must be readable when their length is non-zero.
/// Binary pointer/length pairs must be readable when their length is non-zero.
/// `out_digest` must be a valid writable pointer.
pub unsafe extern "C" fn skybridge_transport_binding_digest(
    transport: SkybridgeTransportKind,
    local_endpoint_ptr: *const u8,
    local_endpoint_len: usize,
    remote_endpoint_ptr: *const u8,
    remote_endpoint_len: usize,
    selected_candidate_pair_ptr: *const u8,
    selected_candidate_pair_len: usize,
    transport_secret_fingerprint_ptr: *const u8,
    transport_secret_fingerprint_len: usize,
    relay_id_ptr: *const u8,
    relay_id_len: usize,
    timestamp_window_ms: u64,
    capability_digest_ptr: *const u8,
    capability_digest_len: usize,
    out_digest: *mut SkybridgeTransportBindingDigest,
) -> SkybridgeErrorCode {
    if out_digest.is_null() {
        return SkybridgeErrorCode::InvalidInput;
    }

    let Some(transport_kind) = map_ffi_transport_kind(transport) else {
        return SkybridgeErrorCode::InvalidInput;
    };
    let local_endpoint = match unsafe { read_utf8(local_endpoint_ptr, local_endpoint_len) } {
        Ok(value) => value,
        Err(err) => return err,
    };
    let remote_endpoint = match unsafe { read_utf8(remote_endpoint_ptr, remote_endpoint_len) } {
        Ok(value) => value,
        Err(err) => return err,
    };
    let selected_candidate_pair =
        match unsafe { read_utf8(selected_candidate_pair_ptr, selected_candidate_pair_len) } {
            Ok(value) => value,
            Err(err) => return err,
        };
    let transport_secret_fingerprint = match unsafe {
        read_bytes(
            transport_secret_fingerprint_ptr,
            transport_secret_fingerprint_len,
        )
    } {
        Ok(value) => value,
        Err(err) => return err,
    };
    let relay_id = if relay_id_len == 0 {
        None
    } else {
        match unsafe { read_utf8(relay_id_ptr, relay_id_len) } {
            Ok(value) => Some(value.to_string()),
            Err(err) => return err,
        }
    };
    let capability_digest =
        match unsafe { read_bytes(capability_digest_ptr, capability_digest_len) } {
            Ok(value) => value,
            Err(err) => return err,
        };

    let material = TransportBindingMaterial {
        transport_kind,
        local_endpoint: local_endpoint.to_string(),
        remote_endpoint: remote_endpoint.to_string(),
        selected_candidate_pair: selected_candidate_pair.to_string(),
        transport_secret_fingerprint: transport_secret_fingerprint.to_vec(),
        relay_id,
        timestamp_window_ms,
        capability_digest: capability_digest.to_vec(),
    };

    unsafe {
        *out_digest = SkybridgeTransportBindingDigest {
            digest: material.transcript_digest(),
        };
    }

    SkybridgeErrorCode::Ok
}

#[no_mangle]
/// Verifies a WebRTC helper proof and returns Core-owned session launch facts.
///
/// This is the Windows interop boundary for adapter proof material: the helper
/// can report ICE/DataChannel facts, but Core verifies identity/freshness,
/// enforces the WebRtcInterop transport selection, and computes the transcript
/// digest that binds the adapter to the SkyBridge session.
///
/// # Safety
/// UTF-8 pointer/length pairs must be readable when their length is non-zero.
/// `out_launch` must be a valid writable pointer.
pub unsafe extern "C" fn skybridge_verify_webrtc_session_launch(
    proof_json_ptr: *const u8,
    proof_json_len: usize,
    expected_device_id_ptr: *const u8,
    expected_device_id_len: usize,
    expected_fingerprint_ptr: *const u8,
    expected_fingerprint_len: usize,
    transport: SkybridgeTransportKind,
    transport_audit: SkybridgeTransportAuditCode,
    max_age_ms: u64,
    out_launch: *mut SkybridgeVerifiedWebRtcSessionLaunch,
) -> SkybridgeErrorCode {
    if out_launch.is_null() {
        return SkybridgeErrorCode::InvalidInput;
    }

    let proof_json = match unsafe { read_utf8(proof_json_ptr, proof_json_len) } {
        Ok(value) => value,
        Err(err) => return err,
    };
    let expected_device_id =
        match unsafe { read_utf8(expected_device_id_ptr, expected_device_id_len) } {
            Ok(value) => value,
            Err(err) => return err,
        };
    let expected_fingerprint =
        match unsafe { read_utf8(expected_fingerprint_ptr, expected_fingerprint_len) } {
            Ok(value) => value,
            Err(err) => return err,
        };
    let Some(transport) = map_ffi_transport_kind(transport) else {
        return SkybridgeErrorCode::InvalidInput;
    };
    let Some(transport_audit) = map_ffi_transport_audit(transport_audit) else {
        return SkybridgeErrorCode::InvalidInput;
    };

    let launch = match verify_webrtc_session_launch_json(
        proof_json,
        expected_device_id,
        expected_fingerprint,
        max_age_ms,
        transport,
        transport_audit,
    ) {
        Ok(value) => value,
        Err(err) => return map_webrtc_proof_error(err),
    };

    match map_verified_webrtc_session_launch(launch) {
        Ok(value) => {
            unsafe {
                *out_launch = value;
            }
            SkybridgeErrorCode::Ok
        }
        Err(err) => err,
    }
}

#[no_mangle]
/// Projects one signaling lifecycle event through the shared Core contract.
///
/// This function intentionally separates signaling lifecycle (`socket_open`,
/// `bound`) from transport/session readiness (`transport_ready`,
/// `handshake_complete`). Callers must use the returned verdict fields rather
/// than equating WebSocket/helper liveness with a connected SkyBridge session.
///
/// # Safety
/// `out_state` must be a valid writable pointer.
pub unsafe extern "C" fn skybridge_project_signaling_lifecycle_state(
    current: SkybridgeSignalingLifecycleState,
    event: SkybridgeSignalingLifecycleEvent,
    out_state: *mut SkybridgeSignalingLifecycleState,
) -> SkybridgeErrorCode {
    if out_state.is_null() {
        return SkybridgeErrorCode::InvalidInput;
    }

    let current = match map_ffi_signaling_lifecycle_state(current) {
        Ok(value) => value,
        Err(err) => return err,
    };
    let event = match map_ffi_signaling_lifecycle_event(event) {
        Ok(value) => value,
        Err(err) => return err,
    };
    let projected = match project_signaling_lifecycle(current, event) {
        Ok(value) => value,
        Err(_) => return SkybridgeErrorCode::InvalidInput,
    };
    let ffi = match map_signaling_lifecycle_state_to_ffi(projected) {
        Ok(value) => value,
        Err(err) => return err,
    };

    unsafe {
        *out_state = ffi;
    }

    SkybridgeErrorCode::Ok
}

#[no_mangle]
/// Plans Core-owned File Transfer route readiness and manifest metadata.
///
/// This is a pure planner. It does not open file paths, start Bonjour, start
/// HTTP/WebRTC/MsQuic transport, render QR images, or read local files.
///
/// # Safety
/// Array pointers must be readable for their declared element counts when the
/// count is non-zero. UTF-8 fields inside fixed structs must have valid lengths.
/// `out_verdict` must be a valid writable pointer.
pub unsafe extern "C" fn skybridge_plan_file_transfer_readiness(
    route_candidates_ptr: *const SkybridgeFileTransferRouteCandidate,
    route_candidate_count: usize,
    target_peer_id_ptr: *const u8,
    target_peer_id_len: usize,
    required_listener_generation: u64,
    has_required_listener_generation: u8,
    manifest_mode: SkybridgeFileTransferManifestMode,
    manifest_files_ptr: *const SkybridgeFileTransferManifestFile,
    manifest_file_count: usize,
    chunk_size: u64,
    channel_mappings_ptr: *const SkybridgeChannelMapping,
    channel_mapping_count: usize,
    out_verdict: *mut SkybridgeFileTransferPlannerVerdict,
) -> SkybridgeErrorCode {
    if out_verdict.is_null()
        || route_candidate_count > MAX_FILE_TRANSFER_CANDIDATES
        || manifest_file_count > MAX_FILE_TRANSFER_MANIFEST_FILES
        || (route_candidate_count > 0 && route_candidates_ptr.is_null())
        || (manifest_file_count > 0 && manifest_files_ptr.is_null())
        || (channel_mapping_count > 0 && channel_mappings_ptr.is_null())
    {
        return SkybridgeErrorCode::InvalidInput;
    }

    let target_peer_id = match unsafe { read_utf8(target_peer_id_ptr, target_peer_id_len) } {
        Ok(value) if value.trim().is_empty() => None,
        Ok(value) => Some(value.to_string()),
        Err(err) => return err,
    };

    let route_candidates = if route_candidate_count == 0 {
        Vec::new()
    } else {
        let candidates =
            unsafe { std::slice::from_raw_parts(route_candidates_ptr, route_candidate_count) };
        let mut mapped = Vec::with_capacity(route_candidate_count);
        for candidate in candidates {
            match map_ffi_file_transfer_candidate(*candidate) {
                Ok(value) => mapped.push(value),
                Err(err) => return err,
            }
        }
        mapped
    };

    let files = if manifest_file_count == 0 {
        Vec::new()
    } else {
        let manifest_files =
            unsafe { std::slice::from_raw_parts(manifest_files_ptr, manifest_file_count) };
        let mut mapped = Vec::with_capacity(manifest_file_count);
        for file in manifest_files {
            match map_ffi_file_transfer_manifest_file(*file) {
                Ok(value) => mapped.push(value),
                Err(err) => return err,
            }
        }
        mapped
    };

    let channel_mappings = if channel_mapping_count == 0 {
        Vec::new()
    } else {
        let mappings =
            unsafe { std::slice::from_raw_parts(channel_mappings_ptr, channel_mapping_count) };
        let mut mapped = Vec::with_capacity(channel_mapping_count);
        for mapping in mappings {
            match map_ffi_file_transfer_channel_mapping(*mapping) {
                Ok(value) => mapped.push(value),
                Err(err) => return err,
            }
        }
        mapped
    };

    let verdict = plan_file_transfer_readiness(FileTransferReadinessRequest {
        target_peer_id,
        required_listener_generation: ffi_flag(has_required_listener_generation)
            .then_some(required_listener_generation),
        route_candidates,
        manifest_mode: map_ffi_file_transfer_manifest_mode(manifest_mode),
        files,
        chunk_size,
        channel_mappings,
    });
    let ffi = match map_file_transfer_verdict(verdict) {
        Ok(value) => value,
        Err(err) => return err,
    };

    unsafe {
        *out_verdict = ffi;
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

fn parse_transport_binding(
    config: SkybridgeSessionConfig,
) -> Result<SessionTransportBinding, SkybridgeErrorCode> {
    if !ffi_flag(config.is_live_adapter_ready) {
        return Err(SkybridgeErrorCode::InvalidInput);
    }

    let Some(transport) = map_ffi_transport_kind(config.transport) else {
        return Err(SkybridgeErrorCode::InvalidInput);
    };
    let Some(adapter_kind) = map_ffi_transport_kind(config.adapter_kind) else {
        return Err(SkybridgeErrorCode::InvalidInput);
    };
    if adapter_kind != transport {
        return Err(SkybridgeErrorCode::InvalidInput);
    }

    let Some(transport_audit) = map_ffi_transport_audit(config.transport_audit) else {
        return Err(SkybridgeErrorCode::InvalidInput);
    };
    let Some(selected_suite) = map_ffi_crypto_suite(config.selected_suite) else {
        return Err(SkybridgeErrorCode::InvalidInput);
    };
    if selected_suite.wire_id() != config.selected_suite_wire_id {
        return Err(SkybridgeErrorCode::InvalidInput);
    }

    let Some(suite_audit) = map_ffi_crypto_suite_audit(config.suite_audit) else {
        return Err(SkybridgeErrorCode::InvalidInput);
    };

    let digest = unsafe {
        read_bytes(
            config.transport_binding_digest_ptr,
            config.transport_binding_digest_len,
        )
    }?;
    if digest.len() != 32 {
        return Err(SkybridgeErrorCode::InvalidInput);
    }
    let mut transport_binding_digest = [0u8; 32];
    transport_binding_digest.copy_from_slice(digest);

    let adapter_binding =
        unsafe { read_utf8(config.adapter_binding_ptr, config.adapter_binding_len) }?.to_string();
    let local_endpoint =
        unsafe { read_utf8(config.local_endpoint_ptr, config.local_endpoint_len) }?.to_string();
    let remote_endpoint =
        unsafe { read_utf8(config.remote_endpoint_ptr, config.remote_endpoint_len) }?.to_string();
    let selected_candidate_pair = unsafe {
        read_utf8(
            config.selected_candidate_pair_ptr,
            config.selected_candidate_pair_len,
        )
    }?
    .to_string();
    let relay_id = if config.relay_id_len == 0 {
        None
    } else {
        Some(unsafe { read_utf8(config.relay_id_ptr, config.relay_id_len) }?.to_string())
    };
    let channel_mappings = parse_channel_mappings(config)?;

    let binding = SessionTransportBinding {
        transport,
        transport_audit,
        relay_required: ffi_flag(config.relay_required),
        relay_allowed: ffi_flag(config.relay_allowed),
        selected_suite,
        selected_suite_wire_id: config.selected_suite_wire_id,
        suite_audit,
        sbp2_enabled: ffi_flag(config.sbp2_enabled),
        sbp2_fixed_payload_len: config.sbp2_fixed_payload_len,
        frame_header_len: config.frame_header_len,
        transport_binding_digest,
        adapter_kind,
        adapter_binding,
        local_endpoint,
        remote_endpoint,
        selected_candidate_pair,
        relay_id,
        timestamp_window_ms: config.timestamp_window_ms,
        channel_mappings,
    };
    binding
        .validate()
        .map_err(|_| SkybridgeErrorCode::InvalidInput)?;
    Ok(binding)
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
    let transport_binding = parse_transport_binding(config)?;

    let config = SessionConfig {
        client_id,
        heartbeat_interval_ms: config.heartbeat_interval_ms,
        peer_public_key,
        transport_binding: Some(transport_binding),
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
            has_transport_binding: snapshot.has_transport_binding,
            transport_kind: map_transport_kind(snapshot.transport_kind),
            adapter_kind: map_transport_kind(snapshot.adapter_kind),
            transport_binding_digest: snapshot.transport_binding_digest.unwrap_or([0; 32]),
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
