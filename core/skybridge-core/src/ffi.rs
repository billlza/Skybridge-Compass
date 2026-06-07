use crate::channel::{map_channel, AdapterChannelBinding};
use crate::crypto::{P256KeyExchange, P256SessionCrypto, SessionCryptoProvider, SessionSecrets};
use crate::error::{CoreError, CoreResult};
use crate::session::{AsyncSessionManager, HeartbeatEmitter, SessionConfig, SessionState};
use crate::stream::{FlowRate, StreamController, StreamMetrics};
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
        *out_selection = SkybridgeTransportSelection {
            kind: map_transport_kind(plan.kind),
            audit_code: map_transport_audit(plan.audit_reason),
            priority: plan.priority,
            relay_required: map_relay_required(plan.relay_policy),
            relay_allowed: map_relay_allowed(plan.relay_policy),
        };
    }

    SkybridgeErrorCode::Ok
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
    let (reliability, max_retransmits) = map_reliability(profile.reliability);

    unsafe {
        *out_mapping = SkybridgeChannelMapping {
            channel: map_channel_kind(profile.channel),
            reliability,
            max_retransmits,
            binding_kind: map_binding_kind(&profile.binding),
            head_of_line_isolated: u8::from(profile.binding.isolates_head_of_line_blocking()),
        };
    }

    SkybridgeErrorCode::Ok
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
