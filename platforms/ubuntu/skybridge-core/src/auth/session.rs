//! Authentication Session
//!
//! Session management compatible with macOS/Android implementations.

use chrono::{DateTime, Utc};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};

use super::NebulaId;

/// Session token with expiration
#[derive(Clone)]
pub struct SessionToken {
    /// Access token
    access_token: SecretString,
    /// Refresh token
    refresh_token: Option<SecretString>,
    /// Token type (usually "Bearer")
    pub token_type: String,
    /// Expiration time
    pub expires_at: DateTime<Utc>,
}

impl SessionToken {
    /// Create a new session token
    pub fn new(
        access_token: String,
        refresh_token: Option<String>,
        token_type: String,
        expires_at: DateTime<Utc>,
    ) -> Self {
        Self {
            access_token: SecretString::from(access_token),
            refresh_token: refresh_token.map(SecretString::from),
            token_type,
            expires_at,
        }
    }

    /// Get the access token (exposed for API calls)
    pub fn access_token(&self) -> &str {
        self.access_token.expose_secret()
    }

    /// Get the refresh token if available
    pub fn refresh_token(&self) -> Option<&str> {
        self.refresh_token.as_ref().map(|t| t.expose_secret())
    }

    /// Check if the token is expired
    pub fn is_expired(&self) -> bool {
        Utc::now() >= self.expires_at
    }

    /// Check if the token will expire within the given duration
    pub fn expires_within(&self, duration: chrono::Duration) -> bool {
        Utc::now() + duration >= self.expires_at
    }

    /// Get authorization header value
    pub fn authorization_header(&self) -> String {
        format!("{} {}", self.token_type, self.access_token.expose_secret())
    }
}

impl std::fmt::Debug for SessionToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionToken")
            .field("token_type", &self.token_type)
            .field("expires_at", &self.expires_at)
            .field("access_token", &"[REDACTED]")
            .field(
                "refresh_token",
                &self.refresh_token.as_ref().map(|_| "[REDACTED]"),
            )
            .finish()
    }
}

/// User profile information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserProfile {
    /// User ID (Supabase UUID or legacy NebulaID string)
    pub user_id: String,
    /// Optional NebulaID stored in Supabase metadata
    pub nebula_id: Option<NebulaId>,
    /// Display name
    pub display_name: Option<String>,
    /// Email address
    pub email: Option<String>,
    /// Phone number
    pub phone: Option<String>,
    /// Avatar URL
    pub avatar_url: Option<String>,
    /// Account creation date
    pub created_at: DateTime<Utc>,
    /// Last login date
    pub last_login: Option<DateTime<Utc>>,
}

/// Authenticated session
#[derive(Debug, Clone)]
pub struct AuthSession {
    /// Session ID
    pub session_id: NebulaId,
    /// User profile
    pub user: UserProfile,
    /// Session token
    pub token: SessionToken,
    /// Device ID this session is associated with
    pub device_id: Option<NebulaId>,
}

impl AuthSession {
    /// Create a new authenticated session
    pub fn new(session_id: NebulaId, user: UserProfile, token: SessionToken) -> Self {
        Self {
            session_id,
            user,
            token,
            device_id: None,
        }
    }

    /// Associate a device with this session
    pub fn with_device(mut self, device_id: NebulaId) -> Self {
        self.device_id = Some(device_id);
        self
    }

    /// Check if the session is still valid
    pub fn is_valid(&self) -> bool {
        !self.token.is_expired()
    }

    /// Get authorization header for API requests
    pub fn authorization_header(&self) -> String {
        self.token.authorization_header()
    }
}

/// Session persistence for secure storage
#[derive(Serialize, Deserialize)]
pub struct PersistedSession {
    /// Session ID
    pub session_id: String,
    /// User ID (Supabase UUID or legacy NebulaID string)
    pub user_id: String,
    /// NebulaID stored in profile metadata (if available)
    #[serde(default)]
    pub nebula_id: Option<String>,
    /// Access token (encrypted when stored)
    pub access_token: String,
    /// Refresh token (encrypted when stored)
    pub refresh_token: Option<String>,
    /// Token type
    pub token_type: String,
    /// Expiration timestamp
    pub expires_at: i64,
    /// Device ID
    pub device_id: Option<String>,
}

impl From<&AuthSession> for PersistedSession {
    fn from(session: &AuthSession) -> Self {
        Self {
            session_id: session.session_id.formatted.clone(),
            user_id: session.user.user_id.clone(),
            nebula_id: session
                .user
                .nebula_id
                .as_ref()
                .map(|id| id.formatted.clone()),
            access_token: session.token.access_token().to_string(),
            refresh_token: session.token.refresh_token().map(String::from),
            token_type: session.token.token_type.clone(),
            expires_at: session.token.expires_at.timestamp(),
            device_id: session.device_id.as_ref().map(|id| id.formatted.clone()),
        }
    }
}
