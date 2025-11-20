use crate::session::SessionState;
use thiserror::Error;

/// Core engine errors.
#[derive(Debug, Error)]
pub enum CoreError {
    #[error("session error: {0}")]
    Session(String),
    #[error("stream error: {0}")]
    Stream(String),
    #[error("crypto error: {0}")]
    Crypto(String),
    #[error("missing crypto material for handshake")]
    MissingCryptoMaterial,
    #[error("invalid crypto key material")]
    InvalidCryptoKey,
    #[error("engine already initialized")]
    AlreadyInitialized,
    #[error("no active session configuration available")]
    MissingConfig,
    #[error("heartbeat rate limited, retry in {retry_in_ms} ms")]
    RateLimited { retry_in_ms: u64 },
    #[error("invalid session state: expected {expected}, got {actual:?}")]
    InvalidState {
        expected: &'static str,
        actual: SessionState,
    },
}

pub type CoreResult<T> = Result<T, CoreError>;
