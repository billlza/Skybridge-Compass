use crate::error::CoreResult;

/// Represents runtime state of a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Disconnected,
    Connecting,
    Connected,
    Reconnecting,
    ShuttingDown,
}

/// Configuration for establishing a new session.
#[derive(Debug, Clone)]
pub struct SessionConfig {
    pub client_id: String,
    pub heartbeat_interval_ms: u64,
    pub peer_public_key: Option<Vec<u8>>,
}

/// Trait to be implemented by session managers.
#[async_trait::async_trait(?Send)]
pub trait AsyncSessionManager {
    async fn establish_async(&self, config: SessionConfig) -> CoreResult<()>;
    async fn reconnect_async(&self) -> CoreResult<()>;
    async fn terminate_async(&self);
    fn state(&self) -> SessionState;
}

/// Heartbeat hook for the platform layer.
#[async_trait::async_trait(?Send)]
pub trait HeartbeatEmitter {
    async fn emit(&self) -> CoreResult<()>;
}
