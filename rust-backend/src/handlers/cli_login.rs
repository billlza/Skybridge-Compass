use axum::{
    Json,
    extract::{Path, State},
};
use chrono::Utc;
use serde_json::json;
use url::Url;
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    cli_login::{
        CLI_CLIENT_ID, approved_code_expiry, build_browser_url, code_challenge_from_verifier,
        decrypt_secret, encrypt_secret, generate_auth_code, hash_secret,
        pending_session_expiry, validate_cli_login_request,
    },
    db,
    error::{AppError, Result},
    models::{
        ApproveCliLoginSessionRequest, ApproveCliLoginSessionResponse, CliLoginSession,
        CliLoginSessionResponse, CreateCliLoginSessionRequest, CreateCliLoginSessionResponse,
        ExchangeCliLoginTokenRequest, ExchangeCliLoginTokenResponse,
    },
    state::AppState,
};

pub async fn create_cli_login_session(
    State(state): State<AppState>,
    Json(request): Json<CreateCliLoginSessionRequest>,
) -> Result<Json<CreateCliLoginSessionResponse>> {
    db::mark_expired_cli_login_sessions(&state.db).await?;

    validate_cli_login_request(
        &request.client_id,
        &request.redirect_uri,
        &request.code_challenge,
        &request.state,
    )?;

    if !matches!(request.platform.trim(), "macos" | "linux" | "windows") {
        return Err(AppError::bad_request(
            "INVALID_PLATFORM",
            "platform must be macos, linux, or windows",
        ));
    }

    if request.cli_version.trim().is_empty() {
        return Err(AppError::bad_request(
            "INVALID_CLI_VERSION",
            "cli_version is required",
        ));
    }

    let session_id = Uuid::new_v4();
    let now = Utc::now();
    let expires_at = pending_session_expiry();
    let session = CliLoginSession {
        session_id,
        client_id: request.client_id.trim().to_string(),
        code_challenge: request.code_challenge.trim().to_string(),
        redirect_uri: request.redirect_uri.trim().to_string(),
        state: request.state.trim().to_string(),
        status: "pending".to_string(),
        auth_code_hash: None,
        auth_user_id: None,
        encrypted_access_token: None,
        encrypted_refresh_token: None,
        user_identifier: None,
        display_name: None,
        approved_at: None,
        consumed_at: None,
        expires_at,
        created_at: now,
        cli_metadata: json!({
            "platform": request.platform.trim(),
            "cli_version": request.cli_version.trim(),
            "device_name": request.device_name.as_deref().map(str::trim).filter(|value| !value.is_empty()),
        }),
    };

    db::create_cli_login_session(&state.db, &session).await?;

    Ok(Json(CreateCliLoginSessionResponse {
        session_id: session_id.to_string(),
        browser_url: build_browser_url(&state.config.public_site_url, session_id)?,
        expires_at,
    }))
}

pub async fn get_cli_login_session(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> Result<Json<CliLoginSessionResponse>> {
    db::mark_expired_cli_login_sessions(&state.db).await?;

    let session_id = Uuid::parse_str(session_id.trim()).map_err(|_| {
        AppError::bad_request("INVALID_SESSION_ID", "session_id must be a valid UUID")
    })?;

    let session = db::get_cli_login_session(&state.db, session_id)
        .await?
        .ok_or_else(|| AppError::not_found("SESSION_NOT_FOUND", "cli login session not found"))?;

    Ok(Json(map_cli_session_response(&session)))
}

pub async fn approve_cli_login_session(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
    auth_user: AuthUser,
    Json(request): Json<ApproveCliLoginSessionRequest>,
) -> Result<Json<ApproveCliLoginSessionResponse>> {
    db::mark_expired_cli_login_sessions(&state.db).await?;

    let session_id = Uuid::parse_str(session_id.trim()).map_err(|_| {
        AppError::bad_request("INVALID_SESSION_ID", "session_id must be a valid UUID")
    })?;

    let session = db::get_cli_login_session(&state.db, session_id)
        .await?
        .ok_or_else(|| AppError::not_found("SESSION_NOT_FOUND", "cli login session not found"))?;

    if session.status != "pending" {
        return Err(AppError::conflict(
            "SESSION_NOT_PENDING",
            "cli login session is no longer pending",
        ));
    }

    if session.expires_at < Utc::now() {
        return Err(AppError::conflict(
            "SESSION_EXPIRED",
            "cli login session has expired",
        ));
    }

    if session.client_id != CLI_CLIENT_ID {
        return Err(AppError::bad_request(
            "INVALID_CLIENT_ID",
            "unsupported cli client id",
        ));
    }

    if request.access_token.trim().is_empty() || request.refresh_token.trim().is_empty() {
        return Err(AppError::bad_request(
            "INVALID_SESSION",
            "access_token and refresh_token are required",
        ));
    }

    if request.access_token.trim() != auth_user.token {
        return Err(AppError::forbidden(
            "ACCESS_TOKEN_MISMATCH",
            "approval token must match the authenticated website session",
        ));
    }

    let encryption_key = state
        .config
        .cli_login_encryption_key
        .as_deref()
        .ok_or_else(|| AppError::internal("CLI_LOGIN_ENCRYPTION_KEY is not configured"))?;

    let auth_code = generate_auth_code();
    let auth_code_hash = hash_secret(&auth_code);
    let encrypted_access_token = encrypt_secret(encryption_key, request.access_token.trim())?;
    let encrypted_refresh_token = encrypt_secret(encryption_key, request.refresh_token.trim())?;
    let approved_at = Utc::now();
    let expires_at = approved_code_expiry();

    let updated = db::approve_cli_login_session(
        &state.db,
        session_id,
        auth_user.id,
        &auth_code_hash,
        &encrypted_access_token,
        &encrypted_refresh_token,
        &auth_user.id.to_string(),
        &auth_user.display_name,
        approved_at,
        expires_at,
    )
    .await?;

    if !updated {
        return Err(AppError::conflict(
            "SESSION_NOT_PENDING",
            "cli login session is no longer pending",
        ));
    }

    let mut redirect_url = Url::parse(&session.redirect_uri).map_err(|_| {
        AppError::internal("stored cli login redirect URI is invalid")
    })?;
    redirect_url
        .query_pairs_mut()
        .append_pair("code", &auth_code)
        .append_pair("state", &session.state);

    Ok(Json(ApproveCliLoginSessionResponse {
        redirect_to: redirect_url.to_string(),
    }))
}

pub async fn exchange_cli_login_token(
    State(state): State<AppState>,
    Json(request): Json<ExchangeCliLoginTokenRequest>,
) -> Result<Json<ExchangeCliLoginTokenResponse>> {
    db::mark_expired_cli_login_sessions(&state.db).await?;

    if request.client_id.trim() != CLI_CLIENT_ID {
        return Err(AppError::bad_request(
            "INVALID_CLIENT_ID",
            "unsupported cli client id",
        ));
    }

    if request.code.trim().is_empty() || request.code_verifier.trim().is_empty() {
        return Err(AppError::bad_request(
            "INVALID_CODE",
            "code and code_verifier are required",
        ));
    }

    let session_id = Uuid::parse_str(request.session_id.trim()).map_err(|_| {
        AppError::bad_request("INVALID_SESSION_ID", "session_id must be a valid UUID")
    })?;

    let encryption_key = state
        .config
        .cli_login_encryption_key
        .as_deref()
        .ok_or_else(|| AppError::internal("CLI_LOGIN_ENCRYPTION_KEY is not configured"))?;

    let auth_code_hash = hash_secret(request.code.trim());
    let code_challenge = code_challenge_from_verifier(request.code_verifier.trim());
    let session = db::consume_cli_login_approval(
        &state.db,
        session_id,
        request.client_id.trim(),
        &auth_code_hash,
        &code_challenge,
    )
    .await?
    .ok_or_else(|| {
        AppError::unauthorized("cli login code is invalid, expired, or already consumed")
    })?;

    let access_token = decrypt_secret(
        encryption_key,
        session
            .encrypted_access_token
            .as_deref()
            .ok_or_else(|| AppError::internal("approved cli login session is missing access token"))?,
    )?;
    let refresh_token = decrypt_secret(
        encryption_key,
        session
            .encrypted_refresh_token
            .as_deref()
            .ok_or_else(|| AppError::internal("approved cli login session is missing refresh token"))?,
    )?;

    Ok(Json(ExchangeCliLoginTokenResponse {
        access_token,
        refresh_token,
        user_identifier: session.user_identifier.unwrap_or_else(|| session_id.to_string()),
        display_name: session
            .display_name
            .unwrap_or_else(|| "SkyBridge User".to_string()),
        nebula_id: None,
    }))
}

fn map_cli_session_response(session: &CliLoginSession) -> CliLoginSessionResponse {
    CliLoginSessionResponse {
        session_id: session.session_id.to_string(),
        status: session.status.clone(),
        platform: session
            .cli_metadata
            .get("platform")
            .and_then(|value| value.as_str())
            .map(ToOwned::to_owned),
        device_name: session
            .cli_metadata
            .get("device_name")
            .and_then(|value| value.as_str())
            .map(ToOwned::to_owned),
        cli_version: session
            .cli_metadata
            .get("cli_version")
            .and_then(|value| value.as_str())
            .map(ToOwned::to_owned),
        expires_at: session.expires_at,
    }
}
