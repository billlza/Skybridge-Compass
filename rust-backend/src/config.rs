//! Configuration module for the Sinan backend
//! 
//! Loads configuration from environment variables with sensible defaults.

use std::env;

const DEFAULT_CORS_ORIGINS: &str = concat!(
    "http://localhost:3000,",
    "http://127.0.0.1:3000,",
    "http://localhost:4173,",
    "http://127.0.0.1:4173,",
    "https://skybridge-compass.vercel.app"
);

/// Application configuration loaded from environment variables
#[derive(Debug, Clone)]
pub struct Config {
    /// Server host address
    pub host: String,
    /// Server port
    pub port: u16,
    /// Database connection URL
    pub database_url: String,
    /// Supabase project URL
    pub supabase_url: String,
    /// Supabase service role key (for admin operations)
    pub supabase_service_key: String,
    /// Supabase anon key (for public operations)
    pub supabase_anon_key: String,
    /// JWT secret for token validation
    pub jwt_secret: String,
    /// CORS allowed origins (comma-separated)
    pub cors_origins: Vec<String>,
    /// Log level
    pub log_level: String,
    /// OpenTelemetry endpoint (optional)
    pub otel_endpoint: Option<String>,
    /// Public website base URL used for CLI browser handoff
    pub public_site_url: String,
    /// Optional encryption key for CLI login token envelopes
    pub cli_login_encryption_key: Option<String>,
}

impl Config {
    /// Load configuration from environment variables
    pub fn from_env() -> Result<Self, ConfigError> {
        dotenvy::dotenv().ok(); // Load .env file if present

        Ok(Self {
            host: env::var("HOST").unwrap_or_else(|_| "0.0.0.0".to_string()),
            port: env::var("PORT")
                .unwrap_or_else(|_| "3000".to_string())
                .parse()
                .map_err(|_| ConfigError::InvalidPort)?,
            database_url: env::var("DATABASE_URL")
                .map_err(|_| ConfigError::MissingEnv("DATABASE_URL"))?,
            supabase_url: env::var("SUPABASE_URL")
                .map_err(|_| ConfigError::MissingEnv("SUPABASE_URL"))?,
            supabase_service_key: env::var("SUPABASE_SERVICE_ROLE_KEY")
                .map_err(|_| ConfigError::MissingEnv("SUPABASE_SERVICE_ROLE_KEY"))?,
            supabase_anon_key: env::var("SUPABASE_ANON_KEY")
                .unwrap_or_default(),
            jwt_secret: env::var("JWT_SECRET")
                .map_err(|_| ConfigError::MissingEnv("JWT_SECRET"))?,
            cors_origins: {
                let origins: Vec<String> = env::var("CORS_ORIGINS")
                    .unwrap_or_else(|_| DEFAULT_CORS_ORIGINS.to_string())
                    .split(',')
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .collect();

                if origins.is_empty() {
                    return Err(ConfigError::MissingEnv("CORS_ORIGINS"));
                }

                if origins.iter().any(|origin| origin == "*") {
                    return Err(ConfigError::WildcardCorsNotAllowed);
                }

                origins
            },
            log_level: env::var("LOG_LEVEL").unwrap_or_else(|_| "info".to_string()),
            otel_endpoint: env::var("OTEL_ENDPOINT").ok(),
            public_site_url: env::var("PUBLIC_SITE_URL")
                .unwrap_or_else(|_| "https://skybridge.com".to_string()),
            cli_login_encryption_key: env::var("CLI_LOGIN_ENCRYPTION_KEY").ok(),
        })
    }

    /// Get the server address as a string
    pub fn server_addr(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}

/// Configuration errors
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("Missing environment variable: {0}")]
    MissingEnv(&'static str),
    #[error("Invalid port number")]
    InvalidPort,
    #[error("CORS_ORIGINS must contain an explicit allowlist and cannot use '*'")]
    WildcardCorsNotAllowed,
}


