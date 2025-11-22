use crate::crypto::{P256KeyExchange, P256SessionCrypto, SessionCryptoProvider, SessionSecrets};
use crate::error::{CoreError, CoreResult};
use crate::session::{AsyncSessionManager, HeartbeatEmitter, SessionConfig, SessionState};
use crate::stream::{FlowRate, StreamController, StreamMetrics};
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
        CoreError::RateLimited { .. } => SkybridgeErrorCode::RateLimited,
        CoreError::InvalidState { .. } => SkybridgeErrorCode::InvalidState,
    }
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
    Ok(SessionConfig {
        client_id,
        heartbeat_interval_ms: config.heartbeat_interval_ms,
        peer_public_key,
    })
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
    SkybridgeEngineHandle::with_handle(handle, |handle| match handle.engine.state.state() {
        SessionState::Disconnected => SkybridgeSessionState::Disconnected,
        SessionState::Connecting => SkybridgeSessionState::Connecting,
        SessionState::Connected => SkybridgeSessionState::Connected,
        SessionState::Reconnecting => SkybridgeSessionState::Reconnecting,
        SessionState::ShuttingDown => SkybridgeSessionState::ShuttingDown,
    })
    .unwrap_or(SkybridgeSessionState::Disconnected)
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
