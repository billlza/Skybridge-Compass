//! Data models for the Sinan backend
//!
//! These models represent database entities and API request/response types.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

// ============================================================================
// Database Models
// ============================================================================

/// User profile stored in the database
#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct UserProfile {
    pub id: Uuid,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub custom_user_id: Option<String>,
    pub nebula_id: Option<String>,
    pub constellation: Option<String>,
    pub constellation_name: Option<String>,
    pub constellation_description: Option<String>,
    pub account_type: Option<String>,
    pub full_name: Option<String>,
    pub avatar_url: Option<String>,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
}

/// Verification code stored in the database
#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct VerificationCode {
    pub id: Uuid,
    pub user_id: Uuid,
    pub code: String,
    #[sqlx(rename = "type")]
    #[serde(rename = "type")]
    pub code_type: Option<String>,
    pub contact: Option<String>,
    pub contact_type: Option<String>,
    pub contact_value: Option<String>,
    pub purpose: Option<String>,
    pub is_used: bool,
    pub attempts: i32,
    pub expires_at: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
    pub ip_address: Option<String>,
}

/// Account binding record
#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct AccountBinding {
    pub id: Uuid,
    pub user_id: Uuid,
    pub contact_type: String,
    pub contact_value: String,
    pub action: String,
    pub ip_address: Option<String>,
    pub user_agent: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// CLI browser-login session stored in the database
#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct CliLoginSession {
    pub session_id: Uuid,
    pub client_id: String,
    pub code_challenge: String,
    pub redirect_uri: String,
    pub state: String,
    pub status: String,
    pub auth_code_hash: Option<String>,
    pub auth_user_id: Option<Uuid>,
    pub encrypted_access_token: Option<String>,
    pub encrypted_refresh_token: Option<String>,
    pub user_identifier: Option<String>,
    pub display_name: Option<String>,
    pub approved_at: Option<DateTime<Utc>>,
    pub consumed_at: Option<DateTime<Utc>>,
    pub expires_at: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
    pub cli_metadata: serde_json::Value,
}

// ============================================================================
// API Request Models
// ============================================================================

/// Request to check user ID availability
#[derive(Debug, Deserialize)]
pub struct CheckUserIdRequest {
    pub custom_user_id: String,
}

/// Request to update custom user ID
#[derive(Debug, Deserialize)]
pub struct UpdateUserIdRequest {
    pub custom_user_id: String,
}

/// Request to bind an account (v1)
#[derive(Debug, Deserialize)]
pub struct BindAccountRequest {
    #[serde(rename = "type")]
    pub bind_type: String,
    pub contact: String,
    pub code: Option<String>,
}

/// Request to bind an account (v2)
#[derive(Debug, Deserialize)]
pub struct BindAccountV2Request {
    pub contact_type: String,
    pub contact_value: String,
    pub verification_code: String,
}

/// Request to unbind an account (v1)
#[derive(Debug, Deserialize)]
pub struct UnbindAccountRequest {
    #[serde(rename = "type")]
    pub unbind_type: String,
    pub code: String,
}

/// Request to unbind an account (v2)
#[derive(Debug, Deserialize)]
pub struct UnbindAccountV2Request {
    pub contact_type: String,
    pub verification_code: String,
}

/// Request to send verification code (v1)
#[derive(Debug, Deserialize)]
pub struct SendVerificationCodeRequest {
    #[serde(rename = "type")]
    pub code_type: String,
    pub contact: String,
}

/// Request to send verification code (v2)
#[derive(Debug, Deserialize)]
pub struct SendVerificationCodeV2Request {
    pub contact_type: String,
    pub contact_value: String,
    #[serde(default = "default_purpose")]
    pub purpose: String,
}

fn default_purpose() -> String {
    "bind".to_string()
}

/// Request to verify a code
#[derive(Debug, Deserialize)]
pub struct VerifyCodeRequest {
    pub code: String,
    #[serde(rename = "type")]
    pub code_type: String,
    pub contact: String,
}

#[derive(Debug, Deserialize)]
pub struct CreateCliLoginSessionRequest {
    pub client_id: String,
    pub code_challenge: String,
    pub redirect_uri: String,
    pub state: String,
    pub platform: String,
    pub cli_version: String,
    pub device_name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ApproveCliLoginSessionRequest {
    pub access_token: String,
    pub refresh_token: String,
}

#[derive(Debug, Deserialize)]
pub struct ExchangeCliLoginTokenRequest {
    pub session_id: String,
    pub client_id: String,
    pub code: String,
    pub code_verifier: String,
}

// ============================================================================
// API Response Models
// ============================================================================

/// Generic success response wrapper
#[derive(Debug, Serialize)]
pub struct DataResponse<T: Serialize> {
    pub data: T,
}

/// Response for user ID availability check
#[derive(Debug, Serialize)]
pub struct CheckUserIdResponse {
    pub available: bool,
    pub reason: String,
}

/// Response for user profile
#[derive(Debug, Serialize)]
pub struct UserProfileResponse {
    pub id: Uuid,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub custom_user_id: Option<String>,
    pub nebula_id: Option<String>,
    pub constellation: Option<String>,
    pub constellation_name: Option<String>,
    pub constellation_description: Option<String>,
    pub account_type: Option<String>,
    pub full_name: Option<String>,
    pub avatar_url: Option<String>,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
}

impl From<UserProfile> for UserProfileResponse {
    fn from(p: UserProfile) -> Self {
        Self {
            id: p.id,
            email: p.email,
            phone: p.phone,
            custom_user_id: p.custom_user_id,
            nebula_id: p.nebula_id,
            constellation: p.constellation,
            constellation_name: p.constellation_name,
            constellation_description: p.constellation_description,
            account_type: p.account_type,
            full_name: p.full_name,
            avatar_url: p.avatar_url,
            created_at: p.created_at,
            updated_at: p.updated_at,
        }
    }
}

/// Response for nebula ID generation
#[derive(Debug, Serialize)]
pub struct GenerateNebulaIdResponse {
    pub nebula_id: String,
    pub message: String,
}

#[derive(Debug, Serialize)]
pub struct CreateCliLoginSessionResponse {
    pub session_id: String,
    pub browser_url: String,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct CliLoginSessionResponse {
    pub session_id: String,
    pub status: String,
    pub platform: Option<String>,
    pub device_name: Option<String>,
    pub cli_version: Option<String>,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct ApproveCliLoginSessionResponse {
    pub redirect_to: String,
}

#[derive(Debug, Serialize)]
pub struct ExchangeCliLoginTokenResponse {
    pub access_token: String,
    pub refresh_token: String,
    pub user_identifier: String,
    pub display_name: String,
    pub nebula_id: Option<String>,
}

/// Response for binding status
#[derive(Debug, Serialize)]
pub struct BindingStatusResponse {
    pub binding_status: serde_json::Value,
    pub binding_history: Vec<BindingHistoryItem>,
    pub pending_verifications: Vec<PendingVerification>,
    pub timestamp: String,
}

#[derive(Debug, Serialize)]
pub struct BindingHistoryItem {
    pub contact_type: String,
    pub action: String,
    pub contact_masked: String,
    pub created_at: DateTime<Utc>,
    pub ip_address: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct PendingVerification {
    pub contact_type: String,
    pub contact_masked: String,
    pub expires_at: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
}

/// Response for bind account operation
#[derive(Debug, Serialize)]
pub struct BindAccountResponse {
    pub message: String,
    pub profile: UserProfileResponse,
}

/// Response for bind account v2 operation
#[derive(Debug, Serialize)]
pub struct BindAccountV2Response {
    pub message: String,
    pub contact_type: String,
    pub contact_value: String,
    pub binding_status: Option<serde_json::Value>,
    pub timestamp: String,
}

/// Response for unbind account operation
#[derive(Debug, Serialize)]
pub struct UnbindAccountResponse {
    pub message: String,
    pub profile: UserProfileResponse,
}

/// Response for unbind account v2 operation
#[derive(Debug, Serialize)]
pub struct UnbindAccountV2Response {
    pub message: String,
    pub contact_type: String,
    pub previous_value: Option<String>,
    pub binding_status: Option<serde_json::Value>,
    pub timestamp: String,
}

/// Response for sending verification code
#[derive(Debug, Serialize)]
pub struct SendVerificationCodeResponse {
    pub message: String,
    pub expires_at: String,
}

/// Response for sending verification code v2
#[derive(Debug, Serialize)]
pub struct SendVerificationCodeV2Response {
    pub message: String,
    pub contact_type: String,
    pub contact_masked: String,
    pub expires_in: i32,
    pub can_resend_after: i32,
}

/// Response for verify code
#[derive(Debug, Serialize)]
pub struct VerifyCodeResponse {
    pub message: String,
    pub verified: bool,
}

/// Response for update user ID
#[derive(Debug, Serialize)]
pub struct UpdateUserIdResponse {
    pub custom_user_id: String,
    pub updated_at: String,
    pub message: String,
}

// ============================================================================
// Supabase Auth Response
// ============================================================================

/// User data from Supabase auth
#[derive(Debug, Deserialize)]
pub struct SupabaseUser {
    pub id: Uuid,
    pub email: Option<String>,
    pub phone: Option<String>,
    #[serde(default)]
    pub app_metadata: serde_json::Value,
    #[serde(default)]
    pub user_metadata: serde_json::Value,
}



