//! Skybridge core engine primitives.
//! Provides session management, stream pipelines, and crypto abstractions
//! that the Windows client can bind to.

pub mod crypto;
pub mod error;
pub mod ffi;
pub mod session;
pub mod stream;

use crypto::SessionCryptoProvider;
use session::{
    AsyncSessionManager, HeartbeatEmitter, SessionConfig, SessionState, SessionStateMachine,
};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use stream::{FlowRate, StreamController, StreamMetrics};

/// CoreEngine ties together session, streaming, and crypto primitives.
#[derive(Debug)]
pub struct EngineState {
    state_machine: SessionStateMachine,
    last_config: Mutex<Option<SessionConfig>>,
    last_heartbeat: Mutex<Option<Instant>>,
    session_secrets: Mutex<Option<crypto::SessionSecrets>>,
}

impl EngineState {
    pub fn new() -> Self {
        Self {
            state_machine: SessionStateMachine::new(),
            last_config: Mutex::new(None),
            last_heartbeat: Mutex::new(None),
            session_secrets: Mutex::new(None),
        }
    }

    pub fn state(&self) -> SessionState {
        self.state_machine.current()
    }

    fn set_state(&self, next: SessionState) -> Result<(), error::CoreError> {
        self.state_machine.transition(next)
    }

    fn mark_config(&self, config: SessionConfig) {
        *self.last_config.lock().unwrap() = Some(config);
    }

    fn last_config(&self) -> Option<SessionConfig> {
        self.last_config.lock().unwrap().clone()
    }

    fn record_heartbeat(&self, interval_ms: u64) -> Result<(), error::CoreError> {
        let mut last = self.last_heartbeat.lock().unwrap();
        if let Some(previous) = *last {
            let elapsed = previous.elapsed();
            let interval = Duration::from_millis(interval_ms);
            if elapsed < interval {
                let retry_in_ms = interval.saturating_sub(elapsed).as_millis() as u64;
                return Err(error::CoreError::RateLimited { retry_in_ms });
            }
        }

        *last = Some(Instant::now());
        Ok(())
    }

    fn store_secrets(&self, secrets: crypto::SessionSecrets) {
        *self.session_secrets.lock().unwrap() = Some(secrets);
    }

    fn secrets(&self) -> Option<crypto::SessionSecrets> {
        self.session_secrets.lock().unwrap().clone()
    }

    fn clear_secrets(&self) {
        self.session_secrets.lock().unwrap().take();
    }
}

impl Default for EngineState {
    fn default() -> Self {
        Self::new()
    }
}

/// CoreEngine ties together session, streaming, and crypto primitives.
pub struct CoreEngine<S, C, P, H>
where
    S: AsyncSessionManager,
    C: StreamController,
    P: SessionCryptoProvider,
    H: HeartbeatEmitter,
{
    pub session_manager: S,
    pub stream_controller: C,
    pub crypto: P,
    pub heartbeat_emitter: H,
    pub state: EngineState,
}

impl<S, C, P, H> CoreEngine<S, C, P, H>
where
    S: AsyncSessionManager,
    C: StreamController,
    P: SessionCryptoProvider,
    H: HeartbeatEmitter,
{
    /// Creates a new engine with default runtime state tracking.
    pub fn new(session_manager: S, stream_controller: C, crypto: P, heartbeat_emitter: H) -> Self {
        Self {
            session_manager,
            stream_controller,
            crypto,
            heartbeat_emitter,
            state: EngineState::new(),
        }
    }

    /// Bootstraps the engine with the given configuration.
    ///
    /// This async operation performs crypto handshakes and session establishment;
    /// callers must await it to avoid blocking executors.
    pub async fn initialize(&self, config: SessionConfig) -> Result<(), error::CoreError> {
        if self.state.state() != SessionState::Disconnected {
            return Err(error::CoreError::AlreadyInitialized);
        }

        self.state.set_state(SessionState::Connecting)?;

        let config_snapshot = config.clone();
        let init_result = async {
            self.crypto.validate_device_identity().await?;
            let peer_key = config
                .peer_public_key
                .as_deref()
                .ok_or(error::CoreError::MissingCryptoMaterial)?;
            self.crypto.begin_handshake().await?;
            let secrets = self.crypto.finalize_handshake(peer_key).await?;
            self.state.store_secrets(secrets);
            self.session_manager.establish_async(config).await
        }
        .await;

        match init_result {
            Ok(()) => {
                self.state.mark_config(config_snapshot);
                self.state.set_state(SessionState::Connected)?;
                Ok(())
            }
            Err(err) => {
                let _ = self.state.set_state(SessionState::Disconnected);
                self.state.clear_secrets();
                Err(err)
            }
        }
    }

    /// Retrieves stream metrics for diagnostics asynchronously.
    pub async fn metrics(&self) -> StreamMetrics {
        self.stream_controller.metrics().await
    }

    /// Issues a stream flow control adjustment asynchronously.
    pub async fn throttle_stream(&self, rate: FlowRate) {
        self.stream_controller.adjust_flow(rate).await;
    }

    /// Attempts to reconnect an interrupted session.
    ///
    /// The operation awaits the underlying session reconnect and enforces state
    /// preconditions via the explicit state machine.
    pub async fn reconnect(&self) -> Result<(), error::CoreError> {
        let current = self.state.state();
        if current != SessionState::Connected {
            return Err(error::CoreError::InvalidState {
                expected: "Connected".to_string(),
                actual: current,
            });
        }

        let config = self
            .state
            .last_config()
            .ok_or(error::CoreError::MissingConfig)?;

        self.state.set_state(SessionState::Reconnecting)?;

        let reconnect_result = self.session_manager.reconnect_async().await;
        match reconnect_result {
            Ok(()) => {
                // ensure configuration persists for future heartbeats
                self.state.mark_config(config);
                self.state.set_state(SessionState::Connected)?;
                Ok(())
            }
            Err(err) => {
                let _ = self.state.set_state(SessionState::Disconnected);
                Err(err)
            }
        }
    }

    /// Terminates the active session.
    ///
    /// Awaiting this call guarantees the session manager has fully released
    /// resources before the engine returns to `Disconnected`.
    pub async fn shutdown(&self) -> Result<(), error::CoreError> {
        self.state.set_state(SessionState::ShuttingDown)?;
        self.session_manager.terminate_async().await;
        self.state.set_state(SessionState::Disconnected)?;
        self.state.clear_secrets();
        Ok(())
    }

    /// Emits a heartbeat if the session is connected.
    ///
    /// Returns [`CoreError::RateLimited`] when called faster than the configured
    /// heartbeat interval.
    pub async fn send_heartbeat(&self) -> Result<(), error::CoreError> {
        let current = self.state.state();
        if current != SessionState::Connected {
            return Err(error::CoreError::InvalidState {
                expected: "Connected".to_string(),
                actual: current,
            });
        }

        let config = self
            .state
            .last_config()
            .ok_or(error::CoreError::MissingConfig)?;
        self.state.record_heartbeat(config.heartbeat_interval_ms)?;
        self.heartbeat_emitter.emit().await
    }

    /// Encrypts payloads using the negotiated session secrets.
    pub fn encrypt_payload(&self, plaintext: &[u8]) -> Result<Vec<u8>, error::CoreError> {
        if self.state.state() != SessionState::Connected {
            return Err(error::CoreError::InvalidState {
                expected: "Connected".to_string(),
                actual: self.state.state(),
            });
        }
        let secrets = self
            .state
            .secrets()
            .ok_or(error::CoreError::MissingCryptoMaterial)?;
        self.crypto.encrypt(&secrets, plaintext)
    }

    /// Decrypts payloads using the negotiated session secrets.
    pub fn decrypt_payload(&self, ciphertext: &[u8]) -> Result<Vec<u8>, error::CoreError> {
        if self.state.state() != SessionState::Connected {
            return Err(error::CoreError::InvalidState {
                expected: "Connected".to_string(),
                actual: self.state.state(),
            });
        }
        let secrets = self
            .state
            .secrets()
            .ok_or(error::CoreError::MissingCryptoMaterial)?;
        self.crypto.decrypt(&secrets, ciphertext)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::{KeyExchangeProvider, P256KeyExchange, P256SessionCrypto, SessionSecrets};
    use crate::session::{SessionConfig, SessionState};
    use crate::stream::FlowRate;
    use std::sync::{Arc, Mutex};
    use tokio::time::{sleep, Duration};

    #[derive(Clone)]
    struct Recorder(Arc<Mutex<Vec<&'static str>>>);

    impl Recorder {
        fn new() -> Self {
            Self(Arc::new(Mutex::new(Vec::new())))
        }

        fn push(&self, entry: &'static str) {
            self.0.lock().unwrap().push(entry);
        }

        fn entries(&self) -> Vec<&'static str> {
            self.0.lock().unwrap().clone()
        }
    }

    struct DummySessionManager {
        recorder: Recorder,
        state: Arc<Mutex<SessionState>>,
    }

    impl DummySessionManager {
        fn new(recorder: Recorder) -> Self {
            Self {
                recorder,
                state: Arc::new(Mutex::new(SessionState::Disconnected)),
            }
        }
    }

    #[async_trait::async_trait(?Send)]
    impl AsyncSessionManager for DummySessionManager {
        async fn establish_async(&self, _config: SessionConfig) -> Result<(), error::CoreError> {
            self.recorder.push("session_establish");
            *self.state.lock().unwrap() = SessionState::Connected;
            Ok(())
        }

        async fn reconnect_async(&self) -> Result<(), error::CoreError> {
            self.recorder.push("session_reconnect");
            *self.state.lock().unwrap() = SessionState::Connected;
            Ok(())
        }

        async fn terminate_async(&self) {
            self.recorder.push("session_terminate");
            *self.state.lock().unwrap() = SessionState::Disconnected;
        }

        fn state(&self) -> SessionState {
            *self.state.lock().unwrap()
        }
    }

    struct DummyStreamController {
        recorder: Recorder,
    }

    #[async_trait::async_trait(?Send)]
    impl StreamController for DummyStreamController {
        async fn adjust_flow(&self, _rate: FlowRate) {
            self.recorder.push("stream_adjust");
        }

        async fn metrics(&self) -> StreamMetrics {
            self.recorder.push("stream_metrics");
            StreamMetrics {
                bitrate_bps: 0,
                packet_loss: 0.0,
            }
        }
    }

    struct DummyCrypto {
        recorder: Recorder,
        inner: P256SessionCrypto<P256KeyExchange>,
    }

    #[async_trait::async_trait(?Send)]
    impl SessionCryptoProvider for DummyCrypto {
        async fn validate_device_identity(&self) -> Result<(), error::CoreError> {
            self.recorder.push("crypto_validate");
            self.inner.validate_device_identity().await
        }

        async fn begin_handshake(&self) -> Result<Vec<u8>, error::CoreError> {
            self.recorder.push("crypto_begin");
            self.inner.begin_handshake().await
        }

        async fn finalize_handshake(
            &self,
            peer_public_key: &[u8],
        ) -> Result<SessionSecrets, error::CoreError> {
            self.recorder.push("crypto_finalize");
            self.inner.finalize_handshake(peer_public_key).await
        }

        fn local_public_key(&self) -> Option<Vec<u8>> {
            self.inner.local_public_key()
        }

        fn algorithm(&self) -> &'static str {
            self.inner.algorithm()
        }

        fn encrypt(
            &self,
            secrets: &SessionSecrets,
            plaintext: &[u8],
        ) -> Result<Vec<u8>, error::CoreError> {
            self.inner.encrypt(secrets, plaintext)
        }

        fn decrypt(
            &self,
            secrets: &SessionSecrets,
            ciphertext: &[u8],
        ) -> Result<Vec<u8>, error::CoreError> {
            self.inner.decrypt(secrets, ciphertext)
        }
    }

    struct DummyHeartbeatEmitter {
        recorder: Recorder,
    }

    #[async_trait::async_trait(?Send)]
    impl HeartbeatEmitter for DummyHeartbeatEmitter {
        async fn emit(&self) -> Result<(), error::CoreError> {
            self.recorder.push("heartbeat_emit");
            Ok(())
        }
    }

    fn build_engine(
        recorder: Recorder,
    ) -> CoreEngine<DummySessionManager, DummyStreamController, DummyCrypto, DummyHeartbeatEmitter>
    {
        CoreEngine::new(
            DummySessionManager::new(recorder.clone()),
            DummyStreamController {
                recorder: recorder.clone(),
            },
            DummyCrypto {
                recorder: recorder.clone(),
                inner: P256SessionCrypto::new(P256KeyExchange),
            },
            DummyHeartbeatEmitter { recorder },
        )
    }

    async fn sample_peer_key() -> Vec<u8> {
        P256KeyExchange
            .generate()
            .await
            .expect("generate peer key")
            .public_key
    }

    #[tokio::test]
    async fn initializes_engine_invokes_crypto_and_session() {
        let recorder = Recorder::new();
        let engine = build_engine(recorder.clone());

        let config = SessionConfig {
            client_id: "demo".into(),
            heartbeat_interval_ms: 1_000,
            peer_public_key: Some(sample_peer_key().await),
        };

        assert!(engine.initialize(config).await.is_ok());
        assert_eq!(engine.state.state(), SessionState::Connected);

        let entries = recorder.entries();
        assert_eq!(
            entries,
            vec![
                "crypto_validate",
                "crypto_begin",
                "crypto_finalize",
                "session_establish",
            ]
        );
    }

    #[tokio::test]
    async fn initialize_without_peer_key_is_rejected_and_recovers_state() {
        let recorder = Recorder::new();
        let engine = build_engine(recorder);

        let config = SessionConfig {
            client_id: "demo".into(),
            heartbeat_interval_ms: 1_000,
            peer_public_key: None,
        };

        let err = engine.initialize(config).await.unwrap_err();
        assert!(matches!(err, error::CoreError::MissingCryptoMaterial));
        assert_eq!(engine.state.state(), SessionState::Disconnected);
    }

    #[tokio::test]
    async fn heartbeats_require_connected_state() {
        let recorder = Recorder::new();
        let engine = build_engine(recorder.clone());

        // Not yet initialized -> heartbeat should fail.
        let err = engine.send_heartbeat().await.unwrap_err();
        match err {
            error::CoreError::InvalidState { expected, actual } => {
                assert_eq!(expected, "Connected");
                assert_eq!(actual, SessionState::Disconnected);
            }
            other => panic!("unexpected error: {:?}", other),
        }

        // After initialize, heartbeat should emit.
        let config = SessionConfig {
            client_id: "demo".into(),
            heartbeat_interval_ms: 1_000,
            peer_public_key: Some(sample_peer_key().await),
        };
        engine.initialize(config).await.unwrap();
        engine.send_heartbeat().await.unwrap();

        let entries = recorder.entries();
        assert_eq!(entries.last(), Some(&"heartbeat_emit"));
    }

    #[tokio::test]
    async fn flow_control_and_reconnect_are_routed_and_stateful() {
        let recorder = Recorder::new();
        let engine = build_engine(recorder.clone());

        engine
            .throttle_stream(FlowRate {
                target_bitrate_bps: 2_000_000,
                max_latency_ms: 80,
            })
            .await;

        engine
            .initialize(SessionConfig {
                client_id: "demo".into(),
                heartbeat_interval_ms: 1_000,
                peer_public_key: Some(sample_peer_key().await),
            })
            .await
            .unwrap();

        assert_eq!(engine.state.state(), SessionState::Connected);
        engine.reconnect().await.unwrap();
        assert_eq!(engine.state.state(), SessionState::Connected);
        engine.shutdown().await.unwrap();
        assert_eq!(engine.state.state(), SessionState::Disconnected);

        let entries = recorder.entries();
        assert_eq!(
            entries,
            vec![
                "stream_adjust",
                "crypto_validate",
                "crypto_begin",
                "crypto_finalize",
                "session_establish",
                "session_reconnect",
                "session_terminate",
            ]
        );
    }

    #[tokio::test]
    async fn initializing_twice_is_blocked() {
        let recorder = Recorder::new();
        let engine = build_engine(recorder);

        let config = SessionConfig {
            client_id: "demo".into(),
            heartbeat_interval_ms: 1_000,
            peer_public_key: Some(sample_peer_key().await),
        };

        engine.initialize(config.clone()).await.unwrap();
        let err = engine.initialize(config).await.unwrap_err();
        assert!(matches!(err, error::CoreError::AlreadyInitialized));
    }

    #[tokio::test]
    async fn heartbeat_rate_limited_respects_interval() {
        let recorder = Recorder::new();
        let engine = build_engine(recorder.clone());

        let config = SessionConfig {
            client_id: "demo".into(),
            heartbeat_interval_ms: 50,
            peer_public_key: Some(sample_peer_key().await),
        };

        engine.initialize(config).await.unwrap();

        engine.send_heartbeat().await.unwrap();
        let err = engine.send_heartbeat().await.unwrap_err();
        assert!(matches!(err, error::CoreError::RateLimited { .. }));

        sleep(Duration::from_millis(60)).await;
        engine.send_heartbeat().await.unwrap();

        let entries = recorder.entries();
        assert!(entries.iter().filter(|e| **e == "heartbeat_emit").count() >= 2);
    }

    #[tokio::test]
    async fn reconnect_requires_connected_state() {
        let recorder = Recorder::new();
        let engine = build_engine(recorder);

        let err = engine.reconnect().await.unwrap_err();
        match err {
            error::CoreError::InvalidState { expected, actual } => {
                assert_eq!(expected, "Connected");
                assert_eq!(actual, SessionState::Disconnected);
            }
            other => panic!("unexpected error: {:?}", other),
        }
    }

    #[tokio::test]
    async fn encrypt_and_decrypt_require_active_session() {
        let recorder = Recorder::new();
        let engine = build_engine(recorder);

        let err = engine
            .encrypt_payload(b"data")
            .expect_err("cannot encrypt while disconnected");
        match err {
            error::CoreError::InvalidState { expected, actual } => {
                assert_eq!(expected, "Connected");
                assert_eq!(actual, SessionState::Disconnected);
            }
            other => panic!("unexpected error: {:?}", other),
        }

        let config = SessionConfig {
            client_id: "demo".into(),
            heartbeat_interval_ms: 1_000,
            peer_public_key: Some(sample_peer_key().await),
        };

        engine.initialize(config).await.unwrap();
        let ciphertext = engine.encrypt_payload(b"payload").unwrap();
        assert_ne!(ciphertext, b"payload");

        let roundtrip = engine.decrypt_payload(&ciphertext).unwrap();
        assert_eq!(roundtrip, b"payload");
    }
}
