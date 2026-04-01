//! Application state module
//!
//! Contains shared state that is passed to all handlers.

use reqwest::Client;
use sqlx::PgPool;
use std::sync::Arc;
use std::time::Duration;

use crate::config::Config;

/// Shared application state
#[derive(Clone)]
pub struct AppState {
    /// Database connection pool
    pub db: PgPool,
    /// HTTP client for external requests
    pub http_client: Client,
    /// Application configuration
    pub config: Arc<Config>,
}

impl AppState {
    /// Create a new application state
    pub fn new(db: PgPool, config: Config) -> Result<Self, reqwest::Error> {
        let http_client = Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(10))
            .pool_idle_timeout(Duration::from_secs(30))
            .user_agent("sinan-backend/0.1")
            .build()?;

        Ok(Self {
            db,
            http_client,
            config: Arc::new(config),
        })
    }
}



