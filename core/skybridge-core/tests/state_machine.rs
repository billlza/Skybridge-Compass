use skybridge_core::crypto::{
    KeyExchangeProvider, P256KeyExchange, P256SessionCrypto, SessionCryptoProvider, SessionSecrets,
};
use skybridge_core::error::{CoreError, CoreResult};
use skybridge_core::session::{AsyncSessionManager, HeartbeatEmitter, SessionConfig, SessionState};
use skybridge_core::stream::{FlowRate, StreamController, StreamMetrics};
use skybridge_core::CoreEngine;
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

struct TrackingSession {
    recorder: Recorder,
    state: Arc<Mutex<SessionState>>,
}

impl TrackingSession {
    fn new(recorder: Recorder) -> Self {
        Self {
            recorder,
            state: Arc::new(Mutex::new(SessionState::Disconnected)),
        }
    }
}

#[async_trait::async_trait(?Send)]
impl AsyncSessionManager for TrackingSession {
    async fn establish_async(&self, _config: SessionConfig) -> CoreResult<()> {
        self.recorder.push("establish");
        *self.state.lock().unwrap() = SessionState::Connected;
        Ok(())
    }

    async fn reconnect_async(&self) -> CoreResult<()> {
        self.recorder.push("reconnect");
        *self.state.lock().unwrap() = SessionState::Connected;
        Ok(())
    }

    async fn terminate_async(&self) {
        self.recorder.push("terminate");
        *self.state.lock().unwrap() = SessionState::Disconnected;
    }

    fn state(&self) -> SessionState {
        *self.state.lock().unwrap()
    }
}

struct TrackingStream {
    recorder: Recorder,
}

#[async_trait::async_trait(?Send)]
impl StreamController for TrackingStream {
    async fn adjust_flow(&self, _rate: FlowRate) {
        self.recorder.push("flow");
    }

    async fn metrics(&self) -> StreamMetrics {
        self.recorder.push("metrics");
        StreamMetrics {
            bitrate_bps: 777,
            packet_loss: 0.1,
        }
    }
}

struct TrackingCrypto {
    recorder: Recorder,
    inner: P256SessionCrypto<P256KeyExchange>,
}

#[async_trait::async_trait(?Send)]
impl SessionCryptoProvider for TrackingCrypto {
    async fn validate_device_identity(&self) -> Result<(), CoreError> {
        self.recorder.push("validate");
        self.inner.validate_device_identity().await
    }

    async fn begin_handshake(&self) -> Result<Vec<u8>, CoreError> {
        self.recorder.push("begin");
        self.inner.begin_handshake().await
    }

    async fn finalize_handshake(
        &self,
        peer_public_key: &[u8],
    ) -> Result<SessionSecrets, CoreError> {
        self.recorder.push("finalize");
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

struct TrackingHeartbeat {
    recorder: Recorder,
}

#[async_trait::async_trait(?Send)]
impl HeartbeatEmitter for TrackingHeartbeat {
    async fn emit(&self) -> Result<(), CoreError> {
        self.recorder.push("heartbeat");
        Ok(())
    }
}

async fn sample_peer_key() -> Vec<u8> {
    P256KeyExchange
        .generate()
        .await
        .expect("generate peer key")
        .public_key
}

#[tokio::test]
async fn state_machine_transitions_and_metrics() {
    let recorder = Recorder::new();
    let engine = CoreEngine::new(
        TrackingSession::new(recorder.clone()),
        TrackingStream {
            recorder: recorder.clone(),
        },
        TrackingCrypto {
            recorder: recorder.clone(),
            inner: P256SessionCrypto::new(P256KeyExchange),
        },
        TrackingHeartbeat {
            recorder: recorder.clone(),
        },
    );

    let config = SessionConfig {
        client_id: "integration".into(),
        heartbeat_interval_ms: 25,
        peer_public_key: Some(sample_peer_key().await),
    };

    engine.initialize(config).await.unwrap();
    assert_eq!(engine.state.state(), SessionState::Connected);

    let metrics = engine.metrics().await;
    assert_eq!(metrics.bitrate_bps, 777);

    engine
        .throttle_stream(FlowRate {
            target_bitrate_bps: 3_000_000,
            max_latency_ms: 50,
        })
        .await;

    engine.send_heartbeat().await.unwrap();
    engine.reconnect().await.unwrap();
    assert_eq!(engine.state.state(), SessionState::Connected);

    engine.shutdown().await.unwrap();
    assert_eq!(engine.state.state(), SessionState::Disconnected);

    let entries = recorder.entries();
    assert_eq!(
        entries,
        vec![
            "validate",
            "begin",
            "finalize",
            "establish",
            "metrics",
            "flow",
            "heartbeat",
            "reconnect",
            "terminate",
        ]
    );
}

#[tokio::test]
async fn integration_heartbeat_throttle_is_enforced() {
    let recorder = Recorder::new();
    let engine = CoreEngine::new(
        TrackingSession::new(recorder.clone()),
        TrackingStream {
            recorder: recorder.clone(),
        },
        TrackingCrypto {
            recorder: recorder.clone(),
            inner: P256SessionCrypto::new(P256KeyExchange),
        },
        TrackingHeartbeat { recorder },
    );

    engine
        .initialize(SessionConfig {
            client_id: "integration".into(),
            heartbeat_interval_ms: 100,
            peer_public_key: Some(sample_peer_key().await),
        })
        .await
        .unwrap();

    engine.send_heartbeat().await.unwrap();
    let err = engine.send_heartbeat().await.unwrap_err();
    assert!(matches!(err, CoreError::RateLimited { .. }));

    sleep(Duration::from_millis(110)).await;
    engine.send_heartbeat().await.unwrap();
}
