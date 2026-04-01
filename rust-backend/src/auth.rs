//! Authentication module for the Sinan backend
//!
//! Handles JWT token validation and user identity verification via Supabase.

use axum::{
    extract::FromRequestParts,
    http::{header::AUTHORIZATION, request::Parts},
};
use reqwest::Client;
use uuid::Uuid;

use crate::{
    cli_login::display_name_from_supabase_user, error::AppError, models::SupabaseUser,
    state::AppState,
};

/// Authenticated user extracted from the request
#[derive(Debug, Clone)]
pub struct AuthUser {
    pub id: Uuid,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub display_name: String,
    pub token: String,
}

impl AuthUser {
    /// Create from Supabase user data
    pub fn from_supabase(user: SupabaseUser, token: String) -> Self {
        let display_name = display_name_from_supabase_user(&user);
        Self {
            id: user.id,
            email: user.email,
            phone: user.phone,
            display_name,
            token,
        }
    }
}

/// Extract authenticated user from request headers
impl FromRequestParts<AppState> for AuthUser {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        // Get Authorization header
        let auth_header = parts
            .headers
            .get(AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or_else(AppError::missing_auth)?;

        // Extract Bearer token
        let token = auth_header
            .strip_prefix("Bearer ")
            .ok_or_else(AppError::missing_auth)?
            .to_string();

        // Verify token with Supabase
        let user = verify_supabase_token(
            &state.http_client,
            &state.config.supabase_url,
            &state.config.supabase_anon_key,
            &token,
        )
        .await?;

        Ok(AuthUser::from_supabase(user, token))
    }
}

/// Verify JWT token with Supabase Auth API
pub async fn verify_supabase_token(
    client: &Client,
    supabase_url: &str,
    public_api_key: &str,
    token: &str,
) -> Result<SupabaseUser, AppError> {
    let url = format!("{}/auth/v1/user", supabase_url);
    
    let response = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", token))
        .header("apikey", public_api_key)
        .send()
        .await?;

    if !response.status().is_success() {
        return Err(AppError::invalid_token());
    }

    let user: SupabaseUser = response.json().await?;
    Ok(user)
}

/// Get client IP from request headers
pub fn get_client_ip(parts: &Parts) -> String {
    // Check X-Forwarded-For first
    if let Some(forwarded) = parts.headers.get("x-forwarded-for") {
        if let Ok(value) = forwarded.to_str() {
            if let Some(ip) = value.split(',').next() {
                return ip.trim().to_string();
            }
        }
    }
    
    // Check X-Real-IP
    if let Some(real_ip) = parts.headers.get("x-real-ip") {
        if let Ok(ip) = real_ip.to_str() {
            return ip.to_string();
        }
    }
    
    "unknown".to_string()
}

/// Get user agent from request headers
pub fn get_user_agent(parts: &Parts) -> String {
    parts
        .headers
        .get("user-agent")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("unknown")
        .to_string()
}
