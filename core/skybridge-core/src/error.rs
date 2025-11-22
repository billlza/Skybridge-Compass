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
    #[error("crypto handshake failed: {0}")]
    CryptoHandshake(String),
    #[error("encryption failed: {0}")]
    Encrypt(String),
    #[error("decryption failed: {0}")]
    Decrypt(String),
    #[error("missing crypto material for handshake")]
    MissingCryptoMaterial,
    #[error("invalid crypto key material")]
    InvalidCryptoKey,
    #[error("engine already initialized")]
    AlreadyInitialized,
    #[error("no active session configuration available")]
    MissingConfig,
    #[error("no heartbeat has been recorded yet")]
    NoHeartbeat,
    #[error("heartbeat timeout after {elapsed_ms} ms")]
    HeartbeatTimeout { elapsed_ms: u64 },
    #[error("heartbeat rate limited, retry in {retry_in_ms} ms")]
    RateLimited { retry_in_ms: u64 },
    #[error("invalid configuration: {reason}")]
    InvalidConfig { reason: String },
    #[error("invalid session state: expected {expected}, got {actual:?}")]
    InvalidState {
        expected: String,
        actual: SessionState,
    },
}

pub type CoreResult<T> = Result<T, CoreError>;
