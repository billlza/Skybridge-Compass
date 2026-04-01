//! Database operations module for the Sinan backend
//!
//! Provides typed database queries using SQLx.

use chrono::{DateTime, Duration, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::{
    error::{AppError, Result},
    models::{AccountBinding, CliLoginSession, UserProfile, VerificationCode},
};

// ============================================================================
// User Profile Operations
// ============================================================================

/// Get user profile by ID
pub async fn get_user_profile(pool: &PgPool, user_id: Uuid) -> Result<Option<UserProfile>> {
    let profile = sqlx::query_as::<_, UserProfile>(
        r#"
        SELECT id, email, phone, custom_user_id, nebula_id, constellation,
               constellation_name, constellation_description, account_type,
               full_name, avatar_url, created_at, updated_at
        FROM user_profiles
        WHERE id = $1
        "#,
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await?;

    Ok(profile)
}

/// Create a new user profile
pub async fn create_user_profile(
    pool: &PgPool,
    user_id: Uuid,
    email: Option<&str>,
    account_type: &str,
) -> Result<UserProfile> {
    let profile = sqlx::query_as::<_, UserProfile>(
        r#"
        INSERT INTO user_profiles (id, email, account_type)
        VALUES ($1, $2, $3)
        RETURNING id, email, phone, custom_user_id, nebula_id, constellation,
                  constellation_name, constellation_description, account_type,
                  full_name, avatar_url, created_at, updated_at
        "#,
    )
    .bind(user_id)
    .bind(email)
    .bind(account_type)
    .fetch_one(pool)
    .await?;

    Ok(profile)
}

/// Update user profile fields
pub async fn update_user_profile(
    pool: &PgPool,
    user_id: Uuid,
    email: Option<&str>,
    phone: Option<&str>,
    nebula_id: Option<&str>,
    custom_user_id: Option<&str>,
) -> Result<UserProfile> {
    let profile = sqlx::query_as::<_, UserProfile>(
        r#"
        UPDATE user_profiles
        SET email = COALESCE($2, email),
            phone = COALESCE($3, phone),
            nebula_id = COALESCE($4, nebula_id),
            custom_user_id = COALESCE($5, custom_user_id),
            updated_at = NOW()
        WHERE id = $1
        RETURNING id, email, phone, custom_user_id, nebula_id, constellation,
                  constellation_name, constellation_description, account_type,
                  full_name, avatar_url, created_at, updated_at
        "#,
    )
    .bind(user_id)
    .bind(email)
    .bind(phone)
    .bind(nebula_id)
    .bind(custom_user_id)
    .fetch_one(pool)
    .await?;

    Ok(profile)
}

/// Set email or phone to NULL (for unbinding)
pub async fn clear_user_contact(
    pool: &PgPool,
    user_id: Uuid,
    contact_type: &str,
) -> Result<UserProfile> {
    let query = match contact_type {
        "email" => {
            r#"
            UPDATE user_profiles
            SET email = NULL, updated_at = NOW()
            WHERE id = $1
            RETURNING id, email, phone, custom_user_id, nebula_id, constellation,
                      constellation_name, constellation_description, account_type,
                      full_name, avatar_url, created_at, updated_at
            "#
        }
        "phone" => {
            r#"
            UPDATE user_profiles
            SET phone = NULL, updated_at = NOW()
            WHERE id = $1
            RETURNING id, email, phone, custom_user_id, nebula_id, constellation,
                      constellation_name, constellation_description, account_type,
                      full_name, avatar_url, created_at, updated_at
            "#
        }
        _ => return Err(AppError::bad_request("INVALID_TYPE", "Invalid contact type")),
    };

    let profile = sqlx::query_as::<_, UserProfile>(query)
        .bind(user_id)
        .fetch_one(pool)
        .await?;

    Ok(profile)
}

/// Check if custom_user_id is available
pub async fn is_custom_user_id_available(
    pool: &PgPool,
    custom_user_id: &str,
    exclude_user_id: Uuid,
) -> Result<bool> {
    let count: (i64,) = sqlx::query_as(
        r#"
        SELECT COUNT(*) FROM user_profiles
        WHERE custom_user_id = $1 AND id != $2
        "#,
    )
    .bind(custom_user_id)
    .bind(exclude_user_id)
    .fetch_one(pool)
    .await?;

    Ok(count.0 == 0)
}

/// Check if email/phone is bound to another user
pub async fn is_contact_bound_to_other(
    pool: &PgPool,
    contact_type: &str,
    contact_value: &str,
    exclude_user_id: Uuid,
) -> Result<bool> {
    let query = match contact_type {
        "email" => {
            r#"SELECT COUNT(*) FROM user_profiles WHERE email = $1 AND id != $2"#
        }
        "phone" => {
            r#"SELECT COUNT(*) FROM user_profiles WHERE phone = $1 AND id != $2"#
        }
        _ => return Err(AppError::bad_request("INVALID_TYPE", "Invalid contact type")),
    };

    let count: (i64,) = sqlx::query_as(query)
        .bind(contact_value)
        .bind(exclude_user_id)
        .fetch_one(pool)
        .await?;

    Ok(count.0 > 0)
}

/// Update custom_user_id
pub async fn update_custom_user_id(
    pool: &PgPool,
    user_id: Uuid,
    custom_user_id: &str,
) -> Result<UserProfile> {
    let profile = sqlx::query_as::<_, UserProfile>(
        r#"
        UPDATE user_profiles
        SET custom_user_id = $2, updated_at = NOW()
        WHERE id = $1
        RETURNING id, email, phone, custom_user_id, nebula_id, constellation,
                  constellation_name, constellation_description, account_type,
                  full_name, avatar_url, created_at, updated_at
        "#,
    )
    .bind(user_id)
    .bind(custom_user_id)
    .fetch_one(pool)
    .await?;

    Ok(profile)
}

/// Generate and set nebula_id for user
pub async fn generate_nebula_id(pool: &PgPool, user_id: Uuid) -> Result<String> {
    for _ in 0..8 {
        let nebula_id = crate::utils::generate_nebula_id();
        let existing: (i64,) = sqlx::query_as(
            r#"
            SELECT COUNT(*) FROM user_profiles
            WHERE nebula_id = $1
            "#,
        )
        .bind(&nebula_id)
        .fetch_one(pool)
        .await?;

        if existing.0 != 0 {
            continue;
        }

        sqlx::query(
            r#"
            UPDATE user_profiles
            SET nebula_id = $2, updated_at = NOW()
            WHERE id = $1
            "#,
        )
        .bind(user_id)
        .bind(&nebula_id)
        .execute(pool)
        .await?;

        return Ok(nebula_id);
    }

    Err(AppError::internal("Failed to generate a unique Nebula ID"))
}

// ============================================================================
// Verification Code Operations
// ============================================================================

/// Check if a verification code was sent recently (within cooldown period)
pub async fn has_recent_code(
    pool: &PgPool,
    user_id: Uuid,
    contact_type: &str,
    contact_value: &str,
    cooldown_seconds: i64,
) -> Result<bool> {
    let since = Utc::now() - Duration::seconds(cooldown_seconds);
    
    let count: (i64,) = sqlx::query_as(
        r#"
        SELECT COUNT(*) FROM verification_codes
        WHERE user_id = $1 
          AND (contact_type = $2 OR type = $2)
          AND (contact_value = $3 OR contact = $3)
          AND created_at >= $4
        "#,
    )
    .bind(user_id)
    .bind(contact_type)
    .bind(contact_value)
    .bind(since)
    .fetch_one(pool)
    .await?;

    Ok(count.0 > 0)
}

/// Create a new verification code
pub async fn create_verification_code(
    pool: &PgPool,
    user_id: Uuid,
    code: &str,
    code_type: &str,
    contact: &str,
    expires_at: DateTime<Utc>,
    ip_address: Option<&str>,
) -> Result<Uuid> {
    let id: (Uuid,) = sqlx::query_as(
        r#"
        INSERT INTO verification_codes 
            (user_id, code, type, contact, contact_type, contact_value, expires_at, ip_address)
        VALUES ($1, $2, $3, $4, $3, $4, $5, $6)
        RETURNING id
        "#,
    )
    .bind(user_id)
    .bind(code)
    .bind(code_type)
    .bind(contact)
    .bind(expires_at)
    .bind(ip_address)
    .fetch_one(pool)
    .await?;

    Ok(id.0)
}

/// Find valid verification code
pub async fn find_valid_code(
    pool: &PgPool,
    user_id: Uuid,
    code_type: &str,
    contact: &str,
    code: &str,
) -> Result<Option<VerificationCode>> {
    let verification = sqlx::query_as::<_, VerificationCode>(
        r#"
        SELECT id, user_id, code, type, contact, contact_type, contact_value,
               purpose, is_used, attempts, expires_at, created_at, ip_address
        FROM verification_codes
        WHERE user_id = $1
          AND (type = $2 OR contact_type = $2)
          AND (contact = $3 OR contact_value = $3)
          AND code = $4
          AND is_used = false
          AND expires_at >= NOW()
        ORDER BY created_at DESC
        LIMIT 1
        "#,
    )
    .bind(user_id)
    .bind(code_type)
    .bind(contact)
    .bind(code)
    .fetch_optional(pool)
    .await?;

    Ok(verification)
}

/// Find the latest pending verification code for a specific contact.
pub async fn find_latest_pending_code(
    pool: &PgPool,
    user_id: Uuid,
    code_type: &str,
    contact: &str,
) -> Result<Option<VerificationCode>> {
    let verification = sqlx::query_as::<_, VerificationCode>(
        r#"
        SELECT id, user_id, code, type, contact, contact_type, contact_value,
               purpose, is_used, attempts, expires_at, created_at, ip_address
        FROM verification_codes
        WHERE user_id = $1
          AND (type = $2 OR contact_type = $2)
          AND (contact = $3 OR contact_value = $3)
          AND is_used = false
          AND expires_at >= NOW()
        ORDER BY created_at DESC
        LIMIT 1
        "#,
    )
    .bind(user_id)
    .bind(code_type)
    .bind(contact)
    .fetch_optional(pool)
    .await?;

    Ok(verification)
}

/// Mark verification code as used
pub async fn mark_code_used(pool: &PgPool, code_id: Uuid) -> Result<()> {
    sqlx::query(
        r#"
        UPDATE verification_codes
        SET is_used = true
        WHERE id = $1
        "#,
    )
    .bind(code_id)
    .execute(pool)
    .await?;

    Ok(())
}

/// Increment code attempts
pub async fn increment_code_attempts(pool: &PgPool, code_id: Uuid) -> Result<i32> {
    let result: (i32,) = sqlx::query_as(
        r#"
        UPDATE verification_codes
        SET attempts = attempts + 1
        WHERE id = $1
        RETURNING attempts
        "#,
    )
    .bind(code_id)
    .fetch_one(pool)
    .await?;

    Ok(result.0)
}

/// Delete verification code
pub async fn delete_verification_code(
    pool: &PgPool,
    user_id: Uuid,
    contact_value: &str,
    code: &str,
) -> Result<()> {
    sqlx::query(
        r#"
        DELETE FROM verification_codes
        WHERE user_id = $1 
          AND (contact_value = $2 OR contact = $2)
          AND code = $3
        "#,
    )
    .bind(user_id)
    .bind(contact_value)
    .bind(code)
    .execute(pool)
    .await?;

    Ok(())
}

/// Get pending verification codes for a user
pub async fn get_pending_codes(
    pool: &PgPool,
    user_id: Uuid,
) -> Result<Vec<VerificationCode>> {
    let codes = sqlx::query_as::<_, VerificationCode>(
        r#"
        SELECT id, user_id, code, type, contact, contact_type, contact_value,
               purpose, is_used, attempts, expires_at, created_at, ip_address
        FROM verification_codes
        WHERE user_id = $1
          AND is_used = false
          AND expires_at >= NOW()
        "#,
    )
    .bind(user_id)
    .fetch_all(pool)
    .await?;

    Ok(codes)
}

// ============================================================================
// Account Binding History Operations
// ============================================================================

/// Record a binding action
pub async fn record_binding_action(
    pool: &PgPool,
    user_id: Uuid,
    contact_type: &str,
    contact_value: &str,
    action: &str,
    ip_address: Option<&str>,
    user_agent: Option<&str>,
) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO account_bindings (user_id, contact_type, contact_value, action, ip_address, user_agent)
        VALUES ($1, $2, $3, $4, $5, $6)
        "#,
    )
    .bind(user_id)
    .bind(contact_type)
    .bind(contact_value)
    .bind(action)
    .bind(ip_address)
    .bind(user_agent)
    .execute(pool)
    .await?;

    Ok(())
}

/// Get binding history for a user
pub async fn get_binding_history(
    pool: &PgPool,
    user_id: Uuid,
    limit: i64,
) -> Result<Vec<AccountBinding>> {
    let bindings = sqlx::query_as::<_, AccountBinding>(
        r#"
        SELECT id, user_id, contact_type, contact_value, action, ip_address, user_agent, created_at
        FROM account_bindings
        WHERE user_id = $1
        ORDER BY created_at DESC
        LIMIT $2
        "#,
    )
    .bind(user_id)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    Ok(bindings)
}

// ============================================================================
// RPC Operations (calling Supabase stored procedures)
// ============================================================================

/// Call get_user_binding_status RPC
pub async fn call_get_binding_status(
    http_client: &reqwest::Client,
    supabase_url: &str,
    service_key: &str,
    token: &str,
    user_id: Uuid,
) -> Result<serde_json::Value> {
    let url = format!("{}/rest/v1/rpc/get_user_binding_status", supabase_url);
    
    let response = http_client
        .post(&url)
        .header("Authorization", format!("Bearer {}", token))
        .header("apikey", service_key)
        .header("Content-Type", "application/json")
        .json(&serde_json::json!({ "target_user_id": user_id }))
        .send()
        .await?;

    if response.status().is_success() {
        let data: serde_json::Value = response.json().await?;
        Ok(data)
    } else {
        Ok(serde_json::json!(null))
    }
}

/// Call bind_contact_method RPC
pub async fn call_bind_contact_method(
    http_client: &reqwest::Client,
    supabase_url: &str,
    service_key: &str,
    contact_type: &str,
    contact_value: &str,
    verification_code: &str,
    client_ip: &str,
    user_agent: &str,
) -> Result<serde_json::Value> {
    let url = format!("{}/rest/v1/rpc/bind_contact_method", supabase_url);
    
    let response = http_client
        .post(&url)
        .header("Authorization", format!("Bearer {}", service_key))
        .header("apikey", service_key)
        .header("Content-Type", "application/json")
        .json(&serde_json::json!({
            "contact_type_param": contact_type,
            "contact_value_param": contact_value,
            "verification_code_param": verification_code,
            "client_ip_param": client_ip,
            "client_user_agent_param": user_agent
        }))
        .send()
        .await?;

    let data: serde_json::Value = response.json().await?;
    Ok(data)
}

/// Call unbind_contact_method RPC
pub async fn call_unbind_contact_method(
    http_client: &reqwest::Client,
    supabase_url: &str,
    service_key: &str,
    contact_type: &str,
    verification_code: &str,
    client_ip: &str,
    user_agent: &str,
) -> Result<serde_json::Value> {
    let url = format!("{}/rest/v1/rpc/unbind_contact_method", supabase_url);
    
    let response = http_client
        .post(&url)
        .header("Authorization", format!("Bearer {}", service_key))
        .header("apikey", service_key)
        .header("Content-Type", "application/json")
        .json(&serde_json::json!({
            "contact_type_param": contact_type,
            "verification_code_param": verification_code,
            "client_ip_param": client_ip,
            "client_user_agent_param": user_agent
        }))
        .send()
        .await?;

    let data: serde_json::Value = response.json().await?;
    Ok(data)
}

// ============================================================================
// CLI Browser Login Operations
// ============================================================================

pub async fn mark_expired_cli_login_sessions(pool: &PgPool) -> Result<()> {
    sqlx::query(
        r#"
        UPDATE cli_login_sessions
        SET status = 'expired',
            encrypted_access_token = NULL,
            encrypted_refresh_token = NULL,
            auth_code_hash = NULL
        WHERE status IN ('pending', 'approved')
          AND expires_at < NOW()
        "#,
    )
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn create_cli_login_session(
    pool: &PgPool,
    session: &CliLoginSession,
) -> Result<()> {
    sqlx::query(
        r#"
        INSERT INTO cli_login_sessions (
            session_id,
            client_id,
            code_challenge,
            redirect_uri,
            state,
            status,
            expires_at,
            created_at,
            cli_metadata
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        "#,
    )
    .bind(session.session_id)
    .bind(&session.client_id)
    .bind(&session.code_challenge)
    .bind(&session.redirect_uri)
    .bind(&session.state)
    .bind(&session.status)
    .bind(session.expires_at)
    .bind(session.created_at)
    .bind(&session.cli_metadata)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn get_cli_login_session(
    pool: &PgPool,
    session_id: Uuid,
) -> Result<Option<CliLoginSession>> {
    let session = sqlx::query_as::<_, CliLoginSession>(
        r#"
        SELECT
            session_id,
            client_id,
            code_challenge,
            redirect_uri,
            state,
            status,
            auth_code_hash,
            auth_user_id,
            encrypted_access_token,
            encrypted_refresh_token,
            user_identifier,
            display_name,
            approved_at,
            consumed_at,
            expires_at,
            created_at,
            cli_metadata
        FROM cli_login_sessions
        WHERE session_id = $1
        "#,
    )
    .bind(session_id)
    .fetch_optional(pool)
    .await?;

    Ok(session)
}

pub async fn approve_cli_login_session(
    pool: &PgPool,
    session_id: Uuid,
    auth_user_id: Uuid,
    auth_code_hash: &str,
    encrypted_access_token: &str,
    encrypted_refresh_token: &str,
    user_identifier: &str,
    display_name: &str,
    approved_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
) -> Result<bool> {
    let updated = sqlx::query(
        r#"
        UPDATE cli_login_sessions
        SET status = 'approved',
            auth_code_hash = $2,
            auth_user_id = $3,
            encrypted_access_token = $4,
            encrypted_refresh_token = $5,
            user_identifier = $6,
            display_name = $7,
            approved_at = $8,
            expires_at = $9
        WHERE session_id = $1
          AND status = 'pending'
          AND expires_at >= NOW()
        "#,
    )
    .bind(session_id)
    .bind(auth_code_hash)
    .bind(auth_user_id)
    .bind(encrypted_access_token)
    .bind(encrypted_refresh_token)
    .bind(user_identifier)
    .bind(display_name)
    .bind(approved_at)
    .bind(expires_at)
    .execute(pool)
    .await?
    .rows_affected();

    Ok(updated == 1)
}

pub async fn consume_cli_login_approval(
    pool: &PgPool,
    session_id: Uuid,
    client_id: &str,
    auth_code_hash: &str,
    code_challenge: &str,
) -> Result<Option<CliLoginSession>> {
    let mut tx = pool.begin().await?;

    let session = sqlx::query_as::<_, CliLoginSession>(
        r#"
        SELECT
            session_id,
            client_id,
            code_challenge,
            redirect_uri,
            state,
            status,
            auth_code_hash,
            auth_user_id,
            encrypted_access_token,
            encrypted_refresh_token,
            user_identifier,
            display_name,
            approved_at,
            consumed_at,
            expires_at,
            created_at,
            cli_metadata
        FROM cli_login_sessions
        WHERE session_id = $1
          AND client_id = $2
          AND status = 'approved'
          AND consumed_at IS NULL
          AND expires_at >= NOW()
          AND auth_code_hash = $3
          AND code_challenge = $4
        FOR UPDATE
        "#,
    )
    .bind(session_id)
    .bind(client_id)
    .bind(auth_code_hash)
    .bind(code_challenge)
    .fetch_optional(&mut *tx)
    .await?;

    if session.is_none() {
        tx.rollback().await?;
        return Ok(None);
    }

    sqlx::query(
        r#"
        UPDATE cli_login_sessions
        SET consumed_at = NOW(),
            encrypted_access_token = NULL,
            encrypted_refresh_token = NULL,
            auth_code_hash = NULL
        WHERE session_id = $1
        "#,
    )
    .bind(session_id)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(session)
}

