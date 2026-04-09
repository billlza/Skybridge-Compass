//! Authentication Service
//!
//! Provides authentication methods compatible with macOS/Android implementations.
//! Supports email, phone, and Nebula authentication methods.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, Duration, Utc};
use keyring::Entry;
use rand::RngExt;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::time::Duration as TokioDuration;
use tracing::{debug, info};

use super::{AuthSession, NebulaId, NebulaIdGenerator, SessionToken, UserProfile};

/// Authentication errors
#[derive(Debug, Error)]
pub enum AuthError {
    /// Invalid credentials
    #[error("Invalid credentials")]
    InvalidCredentials,

    /// Network error
    #[error("Network error: {0}")]
    Network(#[from] reqwest::Error),

    /// Server error
    #[error("Server error: {status} - {message}")]
    Server { status: u16, message: String },

    /// Token expired
    #[error("Token expired")]
    TokenExpired,

    /// Token refresh failed
    #[error("Token refresh failed: {0}")]
    RefreshFailed(String),

    /// Keyring error
    #[error("Keyring error: {0}")]
    Keyring(#[from] keyring::Error),

    /// Session not found
    #[error("No active session")]
    NoActiveSession,

    /// Serialization error
    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    /// ID generation error
    #[error("ID generation error: {0}")]
    IdGeneration(#[from] super::NebulaIdError),

    /// Supabase configuration missing
    #[error("Supabase configuration missing (SUPABASE_URL / SUPABASE_ANON_KEY)")]
    SupabaseConfigMissing,

    /// Supabase configuration invalid
    #[error("Supabase configuration invalid: {0}")]
    SupabaseConfigInvalid(String),

    /// Email verification required
    #[error("Email verification required. Please check your inbox and verify your account.")]
    EmailVerificationRequired,

    /// OAuth flow failed
    #[error("OAuth flow failed: {0}")]
    OAuth(String),
}

/// Authentication endpoint configuration
#[derive(Debug, Clone)]
pub struct AuthEndpoint {
    /// Base URL for authentication API
    pub base_url: String,
    /// Apple Sign-In endpoint
    pub apple: String,
    /// Nebula login endpoint
    pub nebula: String,
    /// Phone login endpoint
    pub phone: String,
    /// Email login endpoint
    pub email: String,
    /// Registration endpoint
    pub register: String,
    /// Token refresh endpoint
    pub refresh: String,
    /// Logout endpoint
    pub logout: String,
}

/// Supabase configuration (shared with macOS/iOS)
#[derive(Debug, Clone)]
pub struct SupabaseConfig {
    pub url: String,
    pub anon_key: String,
}

impl SupabaseConfig {
    pub fn from_env() -> Option<Self> {
        let url = std::env::var("SUPABASE_URL").ok()?;
        let anon_key = std::env::var("SUPABASE_ANON_KEY").ok()?;
        let config = Self {
            url: url.trim().to_string(),
            anon_key: anon_key.trim().to_string(),
        };
        config.validate().ok()?;
        Some(config)
    }

    /// Built-in default Supabase config for SkyBridge cross-platform auth interoperability.
    ///
    /// This allows Ubuntu builds to work out-of-the-box (aligned with macOS/iOS) while still
    /// permitting overrides via Keyring or environment variables.
    pub fn default_config() -> Option<Self> {
        let config = Self {
            url: "https://hloqytmhjludmuhwyyzb.supabase.co".to_string(),
            anon_key: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb3F5dG1oamx1ZG11aHd5eXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUzNTE3ODUsImV4cCI6MjA3MDkyNzc4NX0.xmDCgBo5IpDlzIerIz7y2jruh34MEYrtcepeK3x_HT0".to_string(),
        };
        config.validate().ok()?;
        Some(config)
    }

    fn is_placeholder(url: &str, anon_key: &str) -> bool {
        let url_lower = url.to_lowercase();
        let key_lower = anon_key.to_lowercase();
        url_lower.contains("your-project.supabase.co") || key_lower == "your-anon-key"
    }

    fn validate(&self) -> Result<(), AuthError> {
        if Self::is_placeholder(&self.url, &self.anon_key) {
            return Err(AuthError::SupabaseConfigInvalid(
                "Placeholder Supabase config".to_string(),
            ));
        }
        let parsed = reqwest::Url::parse(&self.url)
            .map_err(|e| AuthError::SupabaseConfigInvalid(e.to_string()))?;
        if parsed.scheme() != "https" {
            return Err(AuthError::SupabaseConfigInvalid(
                "SUPABASE_URL must use https".to_string(),
            ));
        }
        let host = parsed.host_str().unwrap_or("");
        if !host.contains("supabase.co") {
            return Err(AuthError::SupabaseConfigInvalid(
                "SUPABASE_URL must be a supabase.co domain".to_string(),
            ));
        }
        if self.anon_key.is_empty() {
            return Err(AuthError::SupabaseConfigInvalid(
                "SUPABASE_ANON_KEY is empty".to_string(),
            ));
        }
        Ok(())
    }

    fn endpoint(&self, path: &str) -> String {
        let base = self.url.trim_end_matches('/');
        let tail = path.trim_start_matches('/');
        format!("{}/{}", base, tail)
    }
}

impl Default for AuthEndpoint {
    fn default() -> Self {
        #[cfg(debug_assertions)]
        let base_url = "http://localhost:8080".to_string();
        #[cfg(not(debug_assertions))]
        let base_url = "https://api.skybridge.com".to_string();

        Self {
            base_url: base_url.clone(),
            apple: format!("{}/auth/apple/exchange", base_url),
            nebula: format!("{}/auth/nebula/login", base_url),
            phone: format!("{}/auth/phone/login", base_url),
            email: format!("{}/auth/email/login", base_url),
            register: format!("{}/auth/register", base_url),
            refresh: format!("{}/auth/refresh", base_url),
            logout: format!("{}/auth/logout", base_url),
        }
    }
}

impl AuthEndpoint {
    /// Create endpoints with custom base URL
    pub fn with_base_url(base_url: &str) -> Self {
        let base_url = base_url.trim_end_matches('/').to_string();
        Self {
            apple: format!("{}/auth/apple/exchange", base_url),
            nebula: format!("{}/auth/nebula/login", base_url),
            phone: format!("{}/auth/phone/login", base_url),
            email: format!("{}/auth/email/login", base_url),
            register: format!("{}/auth/register", base_url),
            refresh: format!("{}/auth/refresh", base_url),
            logout: format!("{}/auth/logout", base_url),
            base_url,
        }
    }
}

/// Login request payloads
#[derive(Debug, Serialize)]
#[serde(untagged)]
enum LoginRequest {
    Email { email: String, password: String },
    Phone { phone: String, code: String },
    Nebula { username: String, password: String },
}

/// Registration request
#[derive(Debug, Serialize)]
struct RegisterRequest {
    email: Option<String>,
    phone: Option<String>,
    password: String,
    display_name: Option<String>,
}

/// Token refresh request
#[derive(Debug, Serialize)]
struct RefreshRequest {
    refresh_token: String,
}

/// Authentication response from server
#[derive(Debug, Deserialize)]
struct AuthResponse {
    user_id: String,
    access_token: String,
    refresh_token: Option<String>,
    token_type: String,
    expires_in: i64,
    user: UserResponse,
}

/// User data in auth response
#[derive(Debug, Deserialize)]
struct UserResponse {
    display_name: Option<String>,
    email: Option<String>,
    phone: Option<String>,
    avatar_url: Option<String>,
    created_at: DateTime<Utc>,
    last_login: Option<DateTime<Utc>>,
}

/// Supabase auth response (token)
#[derive(Debug, Deserialize)]
struct SupabaseAuthResponse {
    access_token: String,
    refresh_token: Option<String>,
    token_type: Option<String>,
    expires_in: i64,
    user: SupabaseUser,
}

/// Supabase user payload
#[derive(Debug, Deserialize)]
struct SupabaseUser {
    id: String,
    email: Option<String>,
    phone: Option<String>,
    user_metadata: Option<SupabaseUserMetadata>,
    created_at: Option<DateTime<Utc>>,
    last_sign_in_at: Option<DateTime<Utc>>,
}

/// Supabase user metadata (custom fields)
#[derive(Debug, Deserialize)]
struct SupabaseUserMetadata {
    display_name: Option<String>,
    full_name: Option<String>,
    name: Option<String>,
    avatar_url: Option<String>,
    picture: Option<String>,
    nebula_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SupabaseProfileRow {
    display_name: Option<String>,
    full_name: Option<String>,
    username: Option<String>,
    nebula_id: Option<String>,
    avatar_url: Option<String>,
}

/// Supabase signup response (pending verification)
#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct SupabaseSignUpResponse {
    id: String,
    email: Option<String>,
    phone: Option<String>,
    confirmation_sent_at: Option<String>,
    created_at: Option<String>,
    updated_at: Option<String>,
    is_anonymous: Option<bool>,
}

/// Supabase error response
#[derive(Debug, Deserialize)]
struct SupabaseErrorResponse {
    message: Option<String>,
    error_description: Option<String>,
    hint: Option<String>,
}

/// Keyring service and user names
const KEYRING_SERVICE: &str = "com.skybridge.compass.ubuntu";
const KEYRING_SESSION_USER: &str = "session";
const KEYRING_SUPABASE_URL: &str = "supabase.url";
const KEYRING_SUPABASE_ANON_KEY: &str = "supabase.anonKey";

/// Authentication service for managing user sessions
pub struct AuthenticationService {
    client: Client,
    endpoints: AuthEndpoint,
    id_generator: NebulaIdGenerator,
    current_session: Option<AuthSession>,
    supabase_config: Option<SupabaseConfig>,
}

impl AuthenticationService {
    /// Create a new authentication service
    pub fn new() -> Result<Self, AuthError> {
        Self::with_endpoints(AuthEndpoint::default())
    }

    /// Create with custom endpoints
    pub fn with_endpoints(endpoints: AuthEndpoint) -> Result<Self, AuthError> {
        let client = Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()?;

        let id_generator = NebulaIdGenerator::auto()?;
        let supabase_config = Self::load_supabase_config()
            .ok()
            .flatten()
            .or_else(SupabaseConfig::from_env)
            .or_else(SupabaseConfig::default_config);

        Ok(Self {
            client,
            endpoints,
            id_generator,
            current_session: None,
            supabase_config,
        })
    }

    /// Get current session if available
    pub fn current_session(&self) -> Option<&AuthSession> {
        self.current_session.as_ref()
    }

    /// Check if user is authenticated
    pub fn is_authenticated(&self) -> bool {
        self.current_session
            .as_ref()
            .map(|s| s.is_valid())
            .unwrap_or(false)
    }

    /// Current Supabase configuration (if available)
    pub fn supabase_config(&self) -> Option<&SupabaseConfig> {
        self.supabase_config.as_ref()
    }

    /// Whether Supabase is configured
    pub fn is_supabase_configured(&self) -> bool {
        self.supabase_config.is_some()
    }

    /// Reload Supabase configuration from keyring or environment
    pub fn reload_supabase_config(&mut self) -> Result<(), AuthError> {
        self.supabase_config = Self::load_supabase_config()
            .ok()
            .flatten()
            .or_else(SupabaseConfig::from_env)
            .or_else(SupabaseConfig::default_config);
        Ok(())
    }

    /// Persist Supabase configuration to keyring
    pub fn store_supabase_config(url: &str, anon_key: &str) -> Result<(), AuthError> {
        let config = SupabaseConfig {
            url: url.trim().to_string(),
            anon_key: anon_key.trim().to_string(),
        };
        config.validate()?;

        let url_entry = Entry::new(KEYRING_SERVICE, KEYRING_SUPABASE_URL)?;
        let anon_entry = Entry::new(KEYRING_SERVICE, KEYRING_SUPABASE_ANON_KEY)?;
        url_entry.set_password(&config.url)?;
        anon_entry.set_password(&config.anon_key)?;
        Ok(())
    }

    /// Remove Supabase configuration from keyring
    pub fn clear_supabase_config() -> Result<(), AuthError> {
        let url_entry = Entry::new(KEYRING_SERVICE, KEYRING_SUPABASE_URL)?;
        let anon_entry = Entry::new(KEYRING_SERVICE, KEYRING_SUPABASE_ANON_KEY)?;
        let _ = url_entry.delete_credential();
        let _ = anon_entry.delete_credential();
        Ok(())
    }

    /// Load Supabase configuration from keyring
    pub fn load_supabase_config() -> Result<Option<SupabaseConfig>, AuthError> {
        let url_entry = Entry::new(KEYRING_SERVICE, KEYRING_SUPABASE_URL)?;
        let anon_entry = Entry::new(KEYRING_SERVICE, KEYRING_SUPABASE_ANON_KEY)?;
        let url = match url_entry.get_password() {
            Ok(value) => value,
            Err(keyring::Error::NoEntry) => return Ok(None),
            Err(e) => return Err(AuthError::Keyring(e)),
        };
        let anon_key = match anon_entry.get_password() {
            Ok(value) => value,
            Err(keyring::Error::NoEntry) => return Ok(None),
            Err(e) => return Err(AuthError::Keyring(e)),
        };

        let config = SupabaseConfig { url, anon_key };
        config.validate()?;
        Ok(Some(config))
    }

    /// Authenticate with email and password
    pub async fn login_email(
        &mut self,
        email: &str,
        password: &str,
    ) -> Result<&AuthSession, AuthError> {
        info!("Authenticating with email: {}", email);

        let _ = self.reload_supabase_config();
        if self.supabase_config.is_some() {
            return self.supabase_login_email(email, password).await;
        }

        let request = LoginRequest::Email {
            email: email.to_string(),
            password: password.to_string(),
        };

        self.perform_login(&self.endpoints.email.clone(), request)
            .await
    }

    /// Authenticate with phone and verification code
    pub async fn login_phone(
        &mut self,
        phone: &str,
        code: &str,
    ) -> Result<&AuthSession, AuthError> {
        info!("Authenticating with phone: {}", phone);

        let _ = self.reload_supabase_config();
        if self.supabase_config.is_some() {
            return self.supabase_login_phone(phone, code).await;
        }

        let request = LoginRequest::Phone {
            phone: phone.to_string(),
            code: code.to_string(),
        };

        self.perform_login(&self.endpoints.phone.clone(), request)
            .await
    }

    /// Send phone verification code (Supabase mode only)
    pub async fn send_phone_code(&mut self, phone: &str) -> Result<(), AuthError> {
        let _ = self.reload_supabase_config();
        if self.supabase_config.is_some() {
            return self.supabase_send_phone_otp(phone).await;
        }
        Err(AuthError::SupabaseConfigMissing)
    }

    /// Authenticate with Nebula credentials (username/password)
    pub async fn login_nebula(
        &mut self,
        username: &str,
        password: &str,
    ) -> Result<&AuthSession, AuthError> {
        info!("Authenticating with Nebula: {}", username);

        let request = LoginRequest::Nebula {
            username: username.to_string(),
            password: password.to_string(),
        };

        self.perform_login(&self.endpoints.nebula.clone(), request)
            .await
    }

    /// Register a new account
    pub async fn register(
        &mut self,
        email: Option<&str>,
        phone: Option<&str>,
        password: &str,
        display_name: Option<&str>,
    ) -> Result<&AuthSession, AuthError> {
        info!("Registering new account");

        let _ = self.reload_supabase_config();
        if self.supabase_config.is_some() {
            return self
                .supabase_register(email, phone, password, display_name)
                .await;
        }

        let request = RegisterRequest {
            email: email.map(String::from),
            phone: phone.map(String::from),
            password: password.to_string(),
            display_name: display_name.map(String::from),
        };

        let response = self
            .client
            .post(&self.endpoints.register)
            .json(&request)
            .send()
            .await?;

        self.handle_auth_response(response).await
    }

    /// Authenticate with Apple Sign-In (Supabase OAuth)
    pub async fn login_apple(&mut self) -> Result<&AuthSession, AuthError> {
        let _ = self.reload_supabase_config();
        if self.supabase_config.is_some() {
            let session = self.supabase_login_apple().await?;
            self.current_session = Some(session);
            self.persist_session()?;
            return Ok(self.current_session.as_ref().unwrap());
        }
        Err(AuthError::SupabaseConfigMissing)
    }

    /// Refresh the current session token
    pub async fn refresh_token(&mut self) -> Result<&AuthSession, AuthError> {
        let session = self
            .current_session
            .as_ref()
            .ok_or(AuthError::NoActiveSession)?;
        let refresh_token = session
            .token
            .refresh_token()
            .ok_or_else(|| AuthError::RefreshFailed("No refresh token".to_string()))?
            .to_string();

        debug!("Refreshing authentication token");

        let _ = self.reload_supabase_config();
        if self.supabase_config.is_some() {
            return self.supabase_refresh_token(&refresh_token).await;
        }

        let request = RefreshRequest { refresh_token };

        let response = self
            .client
            .post(&self.endpoints.refresh)
            .json(&request)
            .send()
            .await?;

        self.handle_auth_response(response).await
    }

    /// Logout and clear session
    pub async fn logout(&mut self) -> Result<(), AuthError> {
        if let Some(session) = &self.current_session {
            let _ = self
                .client
                .post(&self.endpoints.logout)
                .header("Authorization", session.authorization_header())
                .send()
                .await;
        }

        self.clear_local_session()?;

        info!("Logged out successfully");
        Ok(())
    }

    /// Clear local session state and remove persisted session from secure storage.
    ///
    /// This is a synchronous helper intended for UI flows where a network call is not required.
    pub fn clear_local_session(&mut self) -> Result<(), AuthError> {
        self.current_session = None;
        self.clear_persisted_session()?;
        Ok(())
    }

    /// Load session from secure storage
    pub fn load_persisted_session(&mut self) -> Result<Option<&AuthSession>, AuthError> {
        let entry = Entry::new(KEYRING_SERVICE, KEYRING_SESSION_USER)?;

        match entry.get_password() {
            Ok(data) => {
                let persisted: super::session::PersistedSession = serde_json::from_str(&data)?;

                let nebula_id = persisted
                    .nebula_id
                    .as_deref()
                    .and_then(|id| NebulaId::parse(id).ok());
                let session = AuthSession::new(
                    NebulaId::parse(&persisted.session_id)?,
                    UserProfile {
                        user_id: persisted.user_id,
                        nebula_id,
                        display_name: None,
                        email: None,
                        phone: None,
                        avatar_url: None,
                        created_at: Utc::now(),
                        last_login: None,
                    },
                    SessionToken::new(
                        persisted.access_token,
                        persisted.refresh_token,
                        persisted.token_type,
                        DateTime::from_timestamp(persisted.expires_at, 0).unwrap_or_else(Utc::now),
                    ),
                );

                if session.is_valid() {
                    self.current_session = Some(session);
                    Ok(self.current_session.as_ref())
                } else {
                    debug!("Persisted session expired");
                    self.clear_persisted_session()?;
                    Ok(None)
                }
            }
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(e) => Err(AuthError::Keyring(e)),
        }
    }

    /// Save current session to secure storage
    pub fn persist_session(&self) -> Result<(), AuthError> {
        let session = self
            .current_session
            .as_ref()
            .ok_or(AuthError::NoActiveSession)?;
        let persisted = super::session::PersistedSession::from(session);
        let data = serde_json::to_string(&persisted)?;

        let entry = match Entry::new(KEYRING_SERVICE, KEYRING_SESSION_USER) {
            Ok(entry) => entry,
            Err(err) => {
                tracing::warn!(
                    "Secure storage unavailable; continuing with in-memory session only: {}",
                    err
                );
                return Ok(());
            }
        };
        if let Err(err) = entry.set_password(&data) {
            tracing::warn!(
                "Failed to persist session to secure storage; keeping in-memory session only: {}",
                err
            );
            return Ok(());
        }

        debug!("Session persisted to secure storage");
        Ok(())
    }

    /// Clear persisted session from secure storage
    fn clear_persisted_session(&self) -> Result<(), AuthError> {
        let entry = match Entry::new(KEYRING_SERVICE, KEYRING_SESSION_USER) {
            Ok(entry) => entry,
            Err(err) => {
                tracing::warn!(
                    "Secure storage unavailable while clearing session; ignoring: {}",
                    err
                );
                return Ok(());
            }
        };
        match entry.delete_credential() {
            Ok(_) => Ok(()),
            Err(keyring::Error::NoEntry) => Ok(()),
            Err(err) => {
                tracing::warn!("Failed to clear secure session storage; ignoring: {}", err);
                Ok(())
            }
        }
    }

    // MARK: - Supabase

    fn require_supabase_config(&self) -> Result<&SupabaseConfig, AuthError> {
        self.supabase_config
            .as_ref()
            .ok_or(AuthError::SupabaseConfigMissing)
    }

    fn normalize_token_type(token_type: Option<&str>) -> String {
        match token_type {
            Some(value) if value.eq_ignore_ascii_case("bearer") => "Bearer".to_string(),
            Some(value) if !value.trim().is_empty() => value.to_string(),
            _ => "Bearer".to_string(),
        }
    }

    fn build_supabase_profile(
        &self,
        user: &SupabaseUser,
        fallback_email: Option<&str>,
    ) -> UserProfile {
        let metadata = user.user_metadata.as_ref();
        let display_name = metadata
            .and_then(|m| m.display_name.clone())
            .or_else(|| metadata.and_then(|m| m.full_name.clone()))
            .or_else(|| metadata.and_then(|m| m.name.clone()))
            .or_else(|| {
                fallback_email
                    .and_then(|email| email.split('@').next())
                    .map(|name| name.to_string())
            });
        let email = user
            .email
            .clone()
            .or_else(|| fallback_email.map(str::to_string));
        let nebula_id = metadata
            .and_then(|m| m.nebula_id.as_ref())
            .and_then(|id| NebulaId::parse(id).ok());
        let avatar_url = metadata
            .and_then(|m| m.avatar_url.clone())
            .or_else(|| metadata.and_then(|m| m.picture.clone()));
        let created_at = user.created_at.unwrap_or_else(Utc::now);

        UserProfile {
            user_id: user.id.clone(),
            nebula_id,
            display_name,
            email,
            phone: user.phone.clone(),
            avatar_url,
            created_at,
            last_login: user.last_sign_in_at,
        }
    }

    fn normalize_avatar_url(&self, base_url: &str, raw: Option<String>) -> Option<String> {
        let raw = raw?.trim().to_string();
        if raw.is_empty() {
            return None;
        }
        if raw.starts_with("http://") || raw.starts_with("https://") {
            return Some(raw);
        }

        let base = base_url.trim_end_matches('/');
        if raw.starts_with('/') {
            return Some(format!("{}{}", base, raw));
        }
        if raw.to_ascii_lowercase().starts_with("storage/")
            || raw.to_ascii_lowercase().starts_with("storage/v1/")
        {
            return Some(format!("{}/{}", base, raw));
        }
        Some(raw)
    }

    fn supabase_public_avatar_url(base_url: &str, user_id: &str) -> String {
        format!(
            "{}/storage/v1/object/public/avatars/{}.jpg",
            base_url.trim_end_matches('/'),
            user_id
        )
    }

    async fn supabase_probe_public_avatar_url(
        &self,
        user_id: &str,
    ) -> Result<Option<String>, AuthError> {
        let config = self.require_supabase_config()?.clone();
        let url = Self::supabase_public_avatar_url(&config.url, user_id);

        match self.client.head(&url).send().await {
            Ok(resp) => {
                let status = resp.status();
                if status.is_success() {
                    return Ok(Some(url));
                }
                if status != reqwest::StatusCode::METHOD_NOT_ALLOWED {
                    debug!("Public avatar probe returned HTTP {}", status.as_u16());
                    return Ok(None);
                }
            }
            Err(err) => {
                debug!("Public avatar probe HEAD failed: {}", err);
            }
        }

        let resp = self
            .client
            .get(&url)
            .header("Range", "bytes=0-0")
            .send()
            .await?;
        let status = resp.status();
        if status.is_success() || status == reqwest::StatusCode::PARTIAL_CONTENT {
            Ok(Some(url))
        } else {
            debug!("Public avatar probe GET returned HTTP {}", status.as_u16());
            Ok(None)
        }
    }

    fn supabase_is_signed_storage_url(url: &str) -> bool {
        url.contains("/storage/v1/object/sign/")
    }

    async fn supabase_create_signed_avatar_url(
        &self,
        user_id: &str,
        access_token: &str,
    ) -> Result<Option<String>, AuthError> {
        let config = self.require_supabase_config()?.clone();
        let endpoint = config.endpoint(&format!("storage/v1/object/sign/avatars/{}.jpg", user_id));

        let response = self
            .client
            .post(endpoint)
            .header("Content-Type", "application/json")
            .header("apikey", &config.anon_key)
            .header("Authorization", format!("Bearer {}", access_token))
            .json(&serde_json::json!({ "expiresIn": 60 * 60 * 24 * 7 }))
            .send()
            .await?;

        let status = response.status();
        if !status.is_success() {
            return Ok(None);
        }

        let body = response.bytes().await?;
        let value: serde_json::Value = serde_json::from_slice(&body)?;
        let signed = value
            .get("signedURL")
            .and_then(|v| v.as_str())
            .or_else(|| value.get("signedUrl").and_then(|v| v.as_str()))
            .or_else(|| value.get("signed_url").and_then(|v| v.as_str()));
        let Some(signed) = signed else {
            return Ok(None);
        };

        Ok(self.normalize_avatar_url(&config.url, Some(signed.to_string())))
    }

    async fn supabase_update_user_metadata(
        &self,
        access_token: &str,
        data: serde_json::Value,
    ) -> Result<(), AuthError> {
        let config = self.require_supabase_config()?.clone();
        let endpoint = config.endpoint("auth/v1/user");
        let response = self
            .client
            .put(endpoint)
            .header("Content-Type", "application/json")
            .header("apikey", &config.anon_key)
            .header("Authorization", format!("Bearer {}", access_token))
            .json(&serde_json::json!({ "data": data }))
            .send()
            .await?;

        let status = response.status();
        if status.is_success() {
            Ok(())
        } else {
            let body = response
                .text()
                .await
                .unwrap_or_else(|_| "Unknown error".to_string());
            Err(AuthError::Server {
                status: status.as_u16(),
                message: body,
            })
        }
    }

    async fn supabase_update_user_avatar_url(
        &self,
        access_token: &str,
        avatar_url: &str,
    ) -> Result<(), AuthError> {
        let trimmed = avatar_url.trim();
        if trimmed.is_empty() {
            return Ok(());
        }
        self.supabase_update_user_metadata(
            access_token,
            serde_json::json!({ "avatar_url": trimmed }),
        )
        .await
    }

    fn merge_profiles_row_into_user(
        &self,
        config: &SupabaseConfig,
        user: &mut UserProfile,
        row: SupabaseProfileRow,
    ) {
        let display = row
            .display_name
            .or(row.full_name)
            .or(row.username)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        if let Some(display) = display {
            user.display_name = Some(display);
        }

        if let Some(nid) = row.nebula_id.as_deref()
            && let Ok(parsed) = NebulaId::parse(nid)
        {
            user.nebula_id = Some(parsed);
        }

        user.avatar_url = self
            .normalize_avatar_url(&config.url, row.avatar_url)
            .or_else(|| user.avatar_url.clone());
    }

    async fn supabase_fetch_profiles_row(
        &self,
        user_id: &str,
        access_token: &str,
    ) -> Result<Option<SupabaseProfileRow>, AuthError> {
        let config = self.require_supabase_config()?.clone();
        let endpoint = config.endpoint("rest/v1/profiles");
        let select = "display_name,full_name,username,nebula_id,avatar_url";

        for filter in [
            format!("id=eq.{}", user_id),
            format!("user_id=eq.{}", user_id),
        ] {
            let url = format!("{endpoint}?{filter}&select={select}&limit=1");
            let response = self
                .client
                .get(&url)
                .header("apikey", &config.anon_key)
                .header("Authorization", format!("Bearer {}", access_token))
                .send()
                .await;

            let Ok(resp) = response else { continue };
            let status = resp.status();
            if status == reqwest::StatusCode::NOT_FOUND
                || status == reqwest::StatusCode::UNAUTHORIZED
                || status == reqwest::StatusCode::FORBIDDEN
            {
                continue;
            }
            if !status.is_success() {
                continue;
            }

            let body = resp.bytes().await?;
            let rows: Vec<SupabaseProfileRow> = serde_json::from_slice(&body).unwrap_or_default();
            if let Some(row) = rows.into_iter().next() {
                return Ok(Some(row));
            }
        }

        Ok(None)
    }

    async fn supabase_upsert_profiles_row(
        &self,
        user: &UserProfile,
        access_token: &str,
    ) -> Result<(), AuthError> {
        let config = self.require_supabase_config()?.clone();
        let endpoint = config.endpoint("rest/v1/profiles?on_conflict=id");

        let mut payload = serde_json::json!({
            "id": user.user_id,
            "updated_at": Utc::now().to_rfc3339(),
        });
        if let Some(name) = user
            .display_name
            .as_deref()
            .filter(|s| !s.trim().is_empty())
        {
            payload["display_name"] = serde_json::Value::String(name.trim().to_string());
        }
        if let Some(nid) = user.nebula_id.as_ref().map(|n| n.formatted.clone()) {
            payload["nebula_id"] = serde_json::Value::String(nid);
        }
        if let Some(avatar) = user
            .avatar_url
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            && !Self::supabase_is_signed_storage_url(avatar)
        {
            payload["avatar_url"] = serde_json::Value::String(avatar.to_string());
        }

        let response = self
            .client
            .post(endpoint)
            .header("Content-Type", "application/json")
            .header("apikey", &config.anon_key)
            .header("Prefer", "return=minimal")
            .header("Authorization", format!("Bearer {}", access_token))
            .json(&payload)
            .send()
            .await?;

        let status = response.status();
        if status.is_success() {
            Ok(())
        } else {
            let body = response
                .text()
                .await
                .unwrap_or_else(|_| "Unknown error".to_string());
            Err(AuthError::Server {
                status: status.as_u16(),
                message: body,
            })
        }
    }

    fn random_base64_url(bytes: usize) -> String {
        let mut buffer = vec![0u8; bytes];
        rand::rng().fill(buffer.as_mut_slice());
        URL_SAFE_NO_PAD.encode(buffer)
    }

    fn pkce_challenge(verifier: &str) -> String {
        let mut hasher = Sha256::new();
        hasher.update(verifier.as_bytes());
        let digest = hasher.finalize();
        URL_SAFE_NO_PAD.encode(digest)
    }

    async fn supabase_login_email(
        &mut self,
        email: &str,
        password: &str,
    ) -> Result<&AuthSession, AuthError> {
        let config = self.require_supabase_config()?.clone();
        let endpoint = config.endpoint("auth/v1/token?grant_type=password");
        let response = self
            .client
            .post(endpoint)
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", config.anon_key))
            .header("apikey", &config.anon_key)
            .json(&serde_json::json!({
                "email": email,
                "password": password
            }))
            .send()
            .await?;

        let session = self
            .handle_supabase_auth_response(response, Some(email))
            .await?;
        // Best-effort: mirror macOS/iOS behavior by saving nebula_id into `rest/v1/users` on login,
        // which also covers the "email verification required" path (no session at signup).
        if let Some(nebula_id) = session.user.nebula_id.as_ref() {
            let _ = self
                .supabase_save_nebula_id(
                    &session.user.user_id,
                    &nebula_id.formatted,
                    session.token.access_token(),
                )
                .await;
        }
        self.current_session = Some(session);
        self.persist_session()?;
        Ok(self.current_session.as_ref().unwrap())
    }

    async fn supabase_login_phone(
        &mut self,
        phone: &str,
        code: &str,
    ) -> Result<&AuthSession, AuthError> {
        let config = self.require_supabase_config()?.clone();
        let endpoint = config.endpoint("auth/v1/token");
        let response = self
            .client
            .post(endpoint)
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", config.anon_key))
            .header("apikey", &config.anon_key)
            .json(&serde_json::json!({
                "phone": phone,
                "token": code,
                "type": "sms",
                "grant_type": "otp"
            }))
            .send()
            .await?;

        let session = self.handle_supabase_auth_response(response, None).await?;
        if let Some(nebula_id) = session.user.nebula_id.as_ref() {
            let _ = self
                .supabase_save_nebula_id(
                    &session.user.user_id,
                    &nebula_id.formatted,
                    session.token.access_token(),
                )
                .await;
        }
        self.current_session = Some(session);
        self.persist_session()?;
        Ok(self.current_session.as_ref().unwrap())
    }

    async fn supabase_send_phone_otp(&self, phone: &str) -> Result<(), AuthError> {
        let config = self.require_supabase_config()?.clone();
        let endpoint = config.endpoint("auth/v1/otp");
        let response = self
            .client
            .post(endpoint)
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", config.anon_key))
            .header("apikey", &config.anon_key)
            .json(&serde_json::json!({
                "phone": phone
            }))
            .send()
            .await?;

        let status = response.status();
        if status.is_success() {
            return Ok(());
        }
        let body = response
            .text()
            .await
            .unwrap_or_else(|_| "Unknown error".to_string());
        Err(AuthError::Server {
            status: status.as_u16(),
            message: body,
        })
    }

    async fn supabase_register(
        &mut self,
        email: Option<&str>,
        phone: Option<&str>,
        password: &str,
        display_name: Option<&str>,
    ) -> Result<&AuthSession, AuthError> {
        let config = self.require_supabase_config()?.clone();
        let email = email.ok_or_else(|| {
            AuthError::SupabaseConfigInvalid("Supabase registration requires an email".to_string())
        })?;

        if phone.is_some() {
            return Err(AuthError::SupabaseConfigInvalid(
                "Phone registration is not supported in Supabase mode".to_string(),
            ));
        }

        let nebula_id = self.id_generator.generate_user_registration_id()?;
        let display = display_name
            .map(str::to_string)
            .or_else(|| email.split('@').next().map(|s| s.to_string()))
            .unwrap_or_else(|| "User".to_string());

        let endpoint = config.endpoint("auth/v1/signup");
        let response = self
            .client
            .post(endpoint)
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", config.anon_key))
            .header("apikey", &config.anon_key)
            .json(&serde_json::json!({
                "email": email,
                "password": password,
                "data": {
                    "display_name": display,
                    "registration_source": "SkyBridge Compass Ubuntu",
                    "nebula_id": nebula_id.formatted
                }
            }))
            .send()
            .await?;

        let status = response.status();
        let body = response.bytes().await?;
        if !status.is_success() {
            return Err(Self::parse_supabase_error(status, &body));
        }

        if let Ok(auth_response) = serde_json::from_slice::<SupabaseAuthResponse>(&body) {
            let session = self.build_session_from_supabase(auth_response, Some(email))?;
            let _ = self
                .supabase_save_nebula_id(
                    &session.user.user_id,
                    &nebula_id.formatted,
                    session.token.access_token(),
                )
                .await;
            self.current_session = Some(session);
            self.persist_session()?;
            return Ok(self.current_session.as_ref().unwrap());
        }

        if serde_json::from_slice::<SupabaseSignUpResponse>(&body).is_ok() {
            return Err(AuthError::EmailVerificationRequired);
        }

        Err(AuthError::Server {
            status: status.as_u16(),
            message: "Supabase returned an unexpected response".to_string(),
        })
    }

    async fn supabase_login_apple(&mut self) -> Result<AuthSession, AuthError> {
        let config = self.require_supabase_config()?.clone();
        let port = std::env::var("SUPABASE_OAUTH_REDIRECT_PORT")
            .ok()
            .and_then(|value| value.parse::<u16>().ok())
            .unwrap_or(54321);
        let listener = TcpListener::bind(("127.0.0.1", port)).await.map_err(|e| {
            AuthError::OAuth(format!("Failed to bind redirect port {}: {}", port, e))
        })?;
        let redirect_uri = format!("http://127.0.0.1:{}/callback", port);

        let code_verifier = Self::random_base64_url(48);
        let code_challenge = Self::pkce_challenge(&code_verifier);
        let state = Self::random_base64_url(16);

        let mut authorize_url = reqwest::Url::parse(&config.endpoint("auth/v1/authorize"))
            .map_err(|e| AuthError::OAuth(e.to_string()))?;
        authorize_url
            .query_pairs_mut()
            .append_pair("provider", "apple")
            .append_pair("redirect_to", &redirect_uri)
            .append_pair("code_challenge", &code_challenge)
            .append_pair("code_challenge_method", "s256")
            .append_pair("state", &state);

        std::process::Command::new("xdg-open")
            .arg(authorize_url.as_str())
            .spawn()
            .map_err(|e| AuthError::OAuth(format!("Failed to open browser: {}", e)))?;

        let auth_code = self.await_oauth_code(listener, &state).await?;
        let token_endpoint = config.endpoint("auth/v1/token?grant_type=pkce");
        let response = self
            .client
            .post(token_endpoint)
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", config.anon_key))
            .header("apikey", &config.anon_key)
            .json(&serde_json::json!({
                "auth_code": auth_code,
                "code": auth_code,
                "code_verifier": code_verifier
            }))
            .send()
            .await?;

        self.handle_supabase_auth_response(response, None).await
    }

    async fn supabase_refresh_token(
        &mut self,
        refresh_token: &str,
    ) -> Result<&AuthSession, AuthError> {
        let config = self.require_supabase_config()?.clone();
        let endpoint = config.endpoint("auth/v1/token?grant_type=refresh_token");
        let response = self
            .client
            .post(endpoint)
            .header("Content-Type", "application/json")
            .header("Authorization", format!("Bearer {}", config.anon_key))
            .header("apikey", &config.anon_key)
            .json(&serde_json::json!({
                "refresh_token": refresh_token
            }))
            .send()
            .await?;

        let session = self.handle_supabase_auth_response(response, None).await?;
        self.current_session = Some(session);
        self.persist_session()?;
        Ok(self.current_session.as_ref().unwrap())
    }

    async fn handle_supabase_auth_response(
        &mut self,
        response: reqwest::Response,
        fallback_email: Option<&str>,
    ) -> Result<AuthSession, AuthError> {
        let status = response.status();
        let body = response.bytes().await?;

        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::BAD_REQUEST
        {
            return Err(AuthError::InvalidCredentials);
        }

        if !status.is_success() {
            return Err(Self::parse_supabase_error(status, &body));
        }

        let auth_response: SupabaseAuthResponse = serde_json::from_slice(&body)?;
        let mut session = self.build_session_from_supabase(auth_response, fallback_email)?;

        if let Some(cfg) = self.supabase_config.as_ref() {
            session.user.avatar_url =
                self.normalize_avatar_url(&cfg.url, session.user.avatar_url.take());
        }

        // Best-effort: merge `profiles` table fields for cross-platform parity (Android/macOS).
        if let Ok(Some(row)) = self
            .supabase_fetch_profiles_row(&session.user.user_id, session.token.access_token())
            .await
            && let Some(cfg) = self.supabase_config.as_ref()
        {
            self.merge_profiles_row_into_user(cfg, &mut session.user, row);
        }

        // Best-effort: macOS may have uploaded the avatar to Storage but failed to persist
        // `user_metadata.avatar_url`. If so, probe the expected public object and repair metadata.
        let avatar_missing = session
            .user
            .avatar_url
            .as_deref()
            .map(|s| s.trim().is_empty())
            .unwrap_or(true);
        if avatar_missing {
            if let Ok(Some(url)) = self
                .supabase_probe_public_avatar_url(&session.user.user_id)
                .await
            {
                session.user.avatar_url = Some(url.clone());
                let _ = self
                    .supabase_update_user_avatar_url(session.token.access_token(), &url)
                    .await;
            } else if let Ok(Some(signed)) = self
                .supabase_create_signed_avatar_url(
                    &session.user.user_id,
                    session.token.access_token(),
                )
                .await
            {
                // UI fallback for private buckets. Do NOT persist into metadata (signed URL expires).
                session.user.avatar_url = Some(signed);
            }
        }

        // macOS parity: some flows may only store nebula_id in `rest/v1/users`, not in user_metadata.
        if session.user.nebula_id.is_none()
            && let Ok(Some(nid)) = self
                .supabase_fetch_users_nebula_id(&session.user.user_id, session.token.access_token())
                .await
            && let Ok(parsed) = NebulaId::parse(&nid)
        {
            session.user.nebula_id = Some(parsed);
        }

        // Best-effort: upsert profiles row so other devices can see display_name/avatar/nebula_id.
        let _ = self
            .supabase_upsert_profiles_row(&session.user, session.token.access_token())
            .await;

        Ok(session)
    }

    fn build_session_from_supabase(
        &mut self,
        auth_response: SupabaseAuthResponse,
        fallback_email: Option<&str>,
    ) -> Result<AuthSession, AuthError> {
        let session_id = self.id_generator.generate_session_id()?;
        let expires_at = Utc::now() + Duration::seconds(auth_response.expires_in);
        let token_type = Self::normalize_token_type(auth_response.token_type.as_deref());
        let token = SessionToken::new(
            auth_response.access_token,
            auth_response.refresh_token,
            token_type,
            expires_at,
        );

        let user_profile = self.build_supabase_profile(&auth_response.user, fallback_email);
        Ok(AuthSession::new(session_id, user_profile, token))
    }

    async fn supabase_save_nebula_id(
        &self,
        user_id: &str,
        nebula_id: &str,
        access_token: &str,
    ) -> Result<(), AuthError> {
        let config = self.require_supabase_config()?.clone();
        let endpoint = config.endpoint("rest/v1/users");
        let url = format!("{}?id=eq.{}", endpoint, user_id);
        let response = self
            .client
            .patch(url)
            .header("Content-Type", "application/json")
            .header("apikey", &config.anon_key)
            .header("Prefer", "return=representation")
            .header("Authorization", format!("Bearer {}", access_token))
            .json(&serde_json::json!({
                "nebula_id": nebula_id,
                "updated_at": Utc::now().to_rfc3339(),
            }))
            .send()
            .await?;

        let status = response.status();
        if status.is_success() {
            return Ok(());
        }

        let body = response
            .text()
            .await
            .unwrap_or_else(|_| "Unknown error".to_string());
        Err(AuthError::Server {
            status: status.as_u16(),
            message: body,
        })
    }

    fn parse_supabase_error(status: reqwest::StatusCode, body: &[u8]) -> AuthError {
        let fallback = String::from_utf8_lossy(body).to_string();
        if let Ok(parsed) = serde_json::from_slice::<SupabaseErrorResponse>(body) {
            let message = parsed
                .message
                .or(parsed.error_description)
                .or(parsed.hint)
                .unwrap_or(fallback);
            return AuthError::Server {
                status: status.as_u16(),
                message,
            };
        }
        AuthError::Server {
            status: status.as_u16(),
            message: fallback,
        }
    }

    async fn supabase_fetch_users_nebula_id(
        &self,
        user_id: &str,
        access_token: &str,
    ) -> Result<Option<String>, AuthError> {
        #[derive(Deserialize)]
        struct UsersRow {
            nebula_id: Option<String>,
        }

        let config = self.require_supabase_config()?.clone();
        let endpoint = config.endpoint("rest/v1/users");
        let url = format!("{}?select=nebula_id&id=eq.{}&limit=1", endpoint, user_id);
        let response = self
            .client
            .get(url)
            .header("apikey", &config.anon_key)
            .header("Authorization", format!("Bearer {}", access_token))
            .send()
            .await?;

        if !response.status().is_success() {
            return Ok(None);
        }

        let rows = response.json::<Vec<UsersRow>>().await.unwrap_or_default();
        Ok(rows.into_iter().next().and_then(|row| row.nebula_id))
    }

    async fn await_oauth_code(
        &self,
        listener: TcpListener,
        expected_state: &str,
    ) -> Result<String, AuthError> {
        let result = tokio::time::timeout(TokioDuration::from_secs(180), listener.accept()).await;
        let (mut stream, _) = result
            .map_err(|_| AuthError::OAuth("OAuth timed out".to_string()))?
            .map_err(|e| AuthError::OAuth(e.to_string()))?;

        let mut buffer = vec![0u8; 4096];
        let n = stream
            .read(&mut buffer)
            .await
            .map_err(|e| AuthError::OAuth(e.to_string()))?;
        let request = String::from_utf8_lossy(&buffer[..n]);
        let line = request.lines().next().unwrap_or("");
        let path = line.split_whitespace().nth(1).unwrap_or("/");
        let url = reqwest::Url::parse(&format!("http://localhost{}", path))
            .map_err(|e| AuthError::OAuth(e.to_string()))?;

        let mut code: Option<String> = None;
        let mut state: Option<String> = None;
        for (key, value) in url.query_pairs() {
            match key.as_ref() {
                "code" => code = Some(value.to_string()),
                "state" => state = Some(value.to_string()),
                _ => {}
            }
        }

        let response_body = if state.as_deref() != Some(expected_state) {
            "Invalid state. You can close this window.".to_string()
        } else if code.is_none() {
            "No code returned. You can close this window.".to_string()
        } else {
            "Sign in completed. You can close this window.".to_string()
        };

        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\n\r\n{}",
            response_body.len(),
            response_body
        );
        let _ = stream.write_all(response.as_bytes()).await;

        if state.as_deref() != Some(expected_state) {
            return Err(AuthError::OAuth("State mismatch".to_string()));
        }
        let code = code.ok_or_else(|| AuthError::OAuth("Missing auth code".to_string()))?;
        Ok(code)
    }

    /// Perform login request
    async fn perform_login(
        &mut self,
        endpoint: &str,
        request: LoginRequest,
    ) -> Result<&AuthSession, AuthError> {
        let response = self.client.post(endpoint).json(&request).send().await?;
        self.handle_auth_response(response).await
    }

    /// Handle authentication response
    async fn handle_auth_response(
        &mut self,
        response: reqwest::Response,
    ) -> Result<&AuthSession, AuthError> {
        let status = response.status();

        if status == reqwest::StatusCode::UNAUTHORIZED {
            return Err(AuthError::InvalidCredentials);
        }

        if !status.is_success() {
            let message = response
                .text()
                .await
                .unwrap_or_else(|_| "Unknown error".to_string());
            return Err(AuthError::Server {
                status: status.as_u16(),
                message,
            });
        }

        let auth_response: AuthResponse = response.json().await?;

        let session_id = self.id_generator.generate_session_id()?;
        let expires_at = Utc::now() + Duration::seconds(auth_response.expires_in);

        let user_profile = UserProfile {
            user_id: auth_response.user_id,
            nebula_id: None,
            display_name: auth_response.user.display_name,
            email: auth_response.user.email,
            phone: auth_response.user.phone,
            avatar_url: auth_response.user.avatar_url,
            created_at: auth_response.user.created_at,
            last_login: auth_response.user.last_login,
        };

        let token = SessionToken::new(
            auth_response.access_token,
            auth_response.refresh_token,
            auth_response.token_type,
            expires_at,
        );

        let session = AuthSession::new(session_id, user_profile, token);

        self.current_session = Some(session);
        self.persist_session()?;

        info!("Authentication successful");
        Ok(self.current_session.as_ref().unwrap())
    }
}

impl Default for AuthenticationService {
    fn default() -> Self {
        Self::new().expect("Failed to create authentication service")
    }
}
