use std::collections::HashMap;

use axum::{
    extract::{Form, Json, Query, State},
    http::{header::AUTHORIZATION, HeaderMap, StatusCode},
    response::{Html, IntoResponse, Redirect, Response},
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{Duration, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    handlers,
    models::{LoginMethod, RegisterRequest},
    state::AppState,
    supabase::SupabaseAuthResponse,
};

const AUTHORIZATION_CODE_TTL_MINUTES: i64 = 5;
const REVOKED_REFRESH_TOKEN_RETENTION_DAYS: i64 = 60;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicClientRegistration {
    #[serde(alias = "redirect_uris")]
    pub redirect_uris: Vec<String>,
    pub scopes: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct AuthorizationCodeRecord {
    pub client_id: String,
    pub redirect_uri: String,
    pub scope: String,
    pub code_challenge: String,
    pub code_challenge_method: String,
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub issued_at: chrono::DateTime<Utc>,
    pub expires_at: chrono::DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct PendingMfaSessionRecord {
    pub(crate) request: ValidatedAuthorizeRequest,
    pub(crate) access_token: String,
    pub(crate) refresh_token: Option<String>,
    pub(crate) expires_at: chrono::DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
pub struct OAuthAuthorizeQuery {
    pub response_type: String,
    pub client_id: String,
    pub redirect_uri: String,
    pub scope: Option<String>,
    pub state: Option<String>,
    pub code_challenge: Option<String>,
    pub code_challenge_method: Option<String>,
    pub flow: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct OAuthAuthorizeForm {
    pub response_type: String,
    pub client_id: String,
    pub redirect_uri: String,
    pub scope: Option<String>,
    pub state: Option<String>,
    pub code_challenge: Option<String>,
    pub code_challenge_method: Option<String>,
    pub flow: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub confirm_password: Option<String>,
    pub display_name: Option<String>,
    pub mfa_session_id: Option<String>,
    pub mfa_code: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct OAuthTokenForm {
    pub grant_type: String,
    pub client_id: String,
    pub client_secret: Option<String>,
    pub code: Option<String>,
    pub redirect_uri: Option<String>,
    pub code_verifier: Option<String>,
    pub refresh_token: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct OAuthRevokeForm {
    pub token: String,
    #[allow(dead_code)]
    pub token_type_hint: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct OAuthDevAuthorizeRequest {
    pub response_type: String,
    pub client_id: String,
    pub redirect_uri: String,
    pub scope: Option<String>,
    pub state: Option<String>,
    pub code_challenge: Option<String>,
    pub code_challenge_method: Option<String>,
    pub username: String,
    pub password: String,
    pub mfa_code: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct OAuthDiscoveryDocument {
    pub issuer: String,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub userinfo_endpoint: String,
    pub revocation_endpoint: String,
    pub response_types_supported: Vec<&'static str>,
    pub grant_types_supported: Vec<&'static str>,
    pub token_endpoint_auth_methods_supported: Vec<&'static str>,
    pub code_challenge_methods_supported: Vec<&'static str>,
    pub scopes_supported: Vec<&'static str>,
}

#[derive(Debug, Serialize)]
pub struct OAuthTokenResponse {
    pub access_token: String,
    pub token_type: &'static str,
    pub expires_in: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    pub scope: String,
}

#[derive(Debug, Serialize)]
pub struct OAuthUserInfoResponse {
    pub sub: String,
    pub preferred_username: Option<String>,
    pub name: Option<String>,
    pub email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub picture: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct ValidatedAuthorizeRequest {
    client_id: String,
    redirect_uri: String,
    scope: String,
    state: String,
    code_challenge: String,
    code_challenge_method: String,
}

#[derive(Debug)]
struct OAuthError {
    status: StatusCode,
    error: &'static str,
    message: String,
    redirect_uri: Option<String>,
    state: Option<String>,
}

impl OAuthError {
    fn new(status: StatusCode, error: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            error,
            message: message.into(),
            redirect_uri: None,
            state: None,
        }
    }

    fn with_redirect(mut self, redirect_uri: Option<String>, state: Option<String>) -> Self {
        self.redirect_uri = redirect_uri;
        self.state = state;
        self
    }
}

pub async fn discovery(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    let issuer = resolved_issuer(&state, &headers);
    Json(OAuthDiscoveryDocument {
        issuer: issuer.clone(),
        authorization_endpoint: format!("{}/oauth/authorize", issuer),
        token_endpoint: format!("{}/oauth/token", issuer),
        userinfo_endpoint: format!("{}/oauth/userinfo", issuer),
        revocation_endpoint: format!("{}/oauth/revoke", issuer),
        response_types_supported: vec!["code"],
        grant_types_supported: vec!["authorization_code", "refresh_token"],
        token_endpoint_auth_methods_supported: vec!["none"],
        code_challenge_methods_supported: vec!["S256"],
        scopes_supported: vec!["openid", "profile", "email", "offline_access"],
    })
}

fn resolved_issuer(state: &AppState, headers: &HeaderMap) -> String {
    if let Ok(explicit) = std::env::var("NEBULA_ISSUER") {
        let trimmed = explicit.trim().trim_end_matches('/');
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }

    let host = forwarded_header(headers, "x-forwarded-host")
        .or_else(|| forwarded_header(headers, "host"));
    let proto = forwarded_header(headers, "x-forwarded-proto").unwrap_or_else(|| {
        if host
            .as_deref()
            .map(|value| value.starts_with("127.0.0.1") || value.starts_with("localhost"))
            .unwrap_or(false)
        {
            "http".to_string()
        } else {
            "https".to_string()
        }
    });

    if let Some(host) = host {
        return format!("{}://{}", proto, host);
    }

    state.nebula_issuer.clone()
}

fn forwarded_header(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

pub async fn authorize(
    State(state): State<AppState>,
    Query(query): Query<OAuthAuthorizeQuery>,
) -> Response {
    state.cleanup_expired_oauth_artifacts();
    let flow = normalize_browser_flow(query.flow.as_deref());

    match validate_authorize_request(
        &state.oauth_public_clients,
        &query.response_type,
        &query.client_id,
        &query.redirect_uri,
        query.scope.as_deref(),
        query.state.as_deref(),
        query.code_challenge.as_deref(),
        query.code_challenge_method.as_deref(),
    ) {
        Ok(validated) => Html(render_authorize_page(&validated, flow, None)).into_response(),
        Err(err) => oauth_error_response(err),
    }
}

pub async fn authorize_submit(
    State(state): State<AppState>,
    Form(form): Form<OAuthAuthorizeForm>,
) -> Response {
    state.cleanup_expired_oauth_artifacts();

    let validated = match validate_authorize_request(
        &state.oauth_public_clients,
        &form.response_type,
        &form.client_id,
        &form.redirect_uri,
        form.scope.as_deref(),
        form.state.as_deref(),
        form.code_challenge.as_deref(),
        form.code_challenge_method.as_deref(),
    ) {
        Ok(validated) => validated,
        Err(err) => return oauth_error_response(err),
    };

    let flow = normalize_browser_flow(form.flow.as_deref());

    if let Some(expected_mfa_code) = state.oauth_browser_mfa_code.as_ref() {
        if let Some(session_id) = form
            .mfa_session_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            let submitted_code = form.mfa_code.as_deref().map(str::trim).unwrap_or_default();

            let Some((_, session)) = state.oauth_pending_mfa_sessions.remove(session_id) else {
                return Html(render_authorize_page(
                    &validated,
                    flow,
                    Some("MFA session expired. Please restart sign-in."),
                ))
                .into_response();
            };

            if session.expires_at <= Utc::now() {
                return Html(render_authorize_page(
                    &validated,
                    flow,
                    Some("MFA session expired. Please restart sign-in."),
                ))
                .into_response();
            }

            if submitted_code != expected_mfa_code {
                state
                    .oauth_pending_mfa_sessions
                    .insert(session_id.to_string(), session.clone());
                return Html(render_mfa_page(
                    session_id,
                    &session.request,
                    flow,
                    Some("Invalid verification code."),
                ))
                .into_response();
            }

            let code = issue_authorization_code_from_tokens(
                &state,
                &session.request,
                session.access_token,
                session.refresh_token,
            );
            return Redirect::to(&redirect_with_query(
                &session.request.redirect_uri,
                &[("code", &code), ("state", &session.request.state)],
            ))
            .into_response();
        }
    }

    let username = form.username.as_deref().map(str::trim).unwrap_or_default();
    let password = form.password.as_deref().unwrap_or_default();
    if username.is_empty() || password.is_empty() {
        return Html(render_authorize_page(
            &validated,
            flow,
            Some("Username/email and password are required."),
        ))
        .into_response();
    }

    let auth = if flow == "register" {
        let confirm_password = form.confirm_password.as_deref().unwrap_or_default();
        if password != confirm_password {
            return Html(render_authorize_page(
                &validated,
                flow,
                Some("Passwords do not match."),
            ))
            .into_response();
        }

        let register_response = handlers::register(
            State(state.clone()),
            Json(RegisterRequest {
                method: LoginMethod::Nebula,
                identifier: username.to_string(),
                password: Some(password.to_string()),
                code: String::new(),
                device_fingerprint: "oauth-browser-registration".to_string(),
                display_name: form.display_name.clone(),
            }),
        )
        .await;

        let status = register_response.status();
        let body = axum::body::to_bytes(register_response.into_body(), usize::MAX)
            .await
            .unwrap_or_default();
        if !status.is_success() {
            let message = serde_json::from_slice::<serde_json::Value>(&body)
                .ok()
                .and_then(|value| {
                    value
                        .get("message")
                        .and_then(|v| v.as_str())
                        .map(str::to_string)
                })
                .unwrap_or_else(|| "Registration failed.".to_string());
            return Html(render_authorize_page(&validated, flow, Some(&message))).into_response();
        }

        let payload: serde_json::Value = match serde_json::from_slice(&body) {
            Ok(value) => value,
            Err(_) => {
                return Html(render_authorize_page(
                    &validated,
                    flow,
                    Some("Registration succeeded but the authorization response was invalid."),
                ))
                .into_response()
            }
        };

        if payload
            .get("requires_email_verification")
            .and_then(|value| value.as_bool())
            .unwrap_or(false)
        {
            return Redirect::to(&redirect_with_query(
                &validated.redirect_uri,
                &[
                    ("error", "registration_pending_verification"),
                    (
                        "error_description",
                        "Registration succeeded. Please verify your email, then sign in to continue.",
                    ),
                    ("state", &validated.state),
                ],
            ))
            .into_response();
        }

        let token = payload
            .get("token")
            .and_then(|value| value.as_str())
            .unwrap_or_default()
            .to_string();
        let refresh_token = payload
            .get("refresh_token")
            .and_then(|value| value.as_str())
            .map(str::to_string);

        let user = match state.supabase.get_user(&token).await {
            Ok(user) => user,
            Err(err) => {
                tracing::warn!("OAuth authorize register user fetch failed: {}", err);
                return Html(render_authorize_page(
                    &validated,
                    flow,
                    Some("Registration completed, but user lookup failed."),
                ))
                .into_response();
            }
        };

        SupabaseAuthResponse {
            access_token: token,
            refresh_token,
            user,
        }
    } else {
        match state
            .supabase
            .sign_in_with_password(username, password)
            .await
        {
            Ok(auth) => auth,
            Err(err) => {
                tracing::warn!(
                    "OAuth authorize login failed for client {}: {}",
                    validated.client_id,
                    err
                );
                return Html(render_authorize_page(
                    &validated,
                    flow,
                    Some("Invalid account or password."),
                ))
                .into_response();
            }
        }
    };

    if state.oauth_browser_mfa_code.is_some() {
        let session_id = Uuid::new_v4().simple().to_string();
        let expires_at = Utc::now() + Duration::minutes(AUTHORIZATION_CODE_TTL_MINUTES);
        state.oauth_pending_mfa_sessions.insert(
            session_id.clone(),
            PendingMfaSessionRecord {
                request: validated.clone(),
                access_token: auth.access_token,
                refresh_token: auth.refresh_token,
                expires_at,
            },
        );

        return Html(render_mfa_page(&session_id, &validated, flow, None)).into_response();
    }

    let code = issue_authorization_code(&state, &validated, auth);
    Redirect::to(&redirect_with_query(
        &validated.redirect_uri,
        &[("code", &code), ("state", &validated.state)],
    ))
    .into_response()
}

pub async fn token(State(state): State<AppState>, Form(form): Form<OAuthTokenForm>) -> Response {
    state.cleanup_expired_oauth_artifacts();

    if form
        .client_secret
        .as_deref()
        .is_some_and(|value| !value.trim().is_empty())
    {
        return oauth_json_error(
            StatusCode::BAD_REQUEST,
            "invalid_client",
            "Public clients must not send client_secret.",
        );
    }

    let client = match state.oauth_public_clients.get(&form.client_id) {
        Some(client) => client.clone(),
        None => {
            return oauth_json_error(
                StatusCode::UNAUTHORIZED,
                "unauthorized_client",
                "Unknown client_id.",
            )
        }
    };

    match form.grant_type.as_str() {
        "authorization_code" => {
            let code = match form
                .code
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                Some(code) => code.to_string(),
                None => {
                    return oauth_json_error(
                        StatusCode::BAD_REQUEST,
                        "invalid_request",
                        "Missing authorization code.",
                    )
                }
            };
            let redirect_uri = match form
                .redirect_uri
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                Some(uri) => uri.to_string(),
                None => {
                    return oauth_json_error(
                        StatusCode::BAD_REQUEST,
                        "invalid_request",
                        "Missing redirect_uri.",
                    )
                }
            };
            let code_verifier = match form
                .code_verifier
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                Some(verifier) => verifier.to_string(),
                None => {
                    return oauth_json_error(
                        StatusCode::BAD_REQUEST,
                        "invalid_request",
                        "Missing code_verifier.",
                    )
                }
            };

            if !client
                .redirect_uris
                .iter()
                .any(|candidate| candidate == &redirect_uri)
            {
                return oauth_json_error(
                    StatusCode::BAD_REQUEST,
                    "invalid_grant",
                    "redirect_uri mismatch.",
                );
            }

            let Some((_, record)) = state.oauth_authorization_codes.remove(&code) else {
                return oauth_json_error(
                    StatusCode::BAD_REQUEST,
                    "invalid_grant",
                    "Authorization code is invalid or already used.",
                );
            };

            if record.expires_at <= Utc::now() {
                return oauth_json_error(
                    StatusCode::BAD_REQUEST,
                    "invalid_grant",
                    "Authorization code expired.",
                );
            }
            if record.client_id != form.client_id || record.redirect_uri != redirect_uri {
                return oauth_json_error(
                    StatusCode::BAD_REQUEST,
                    "invalid_grant",
                    "Authorization code does not match the client or redirect URI.",
                );
            }
            if record.code_challenge_method != "S256" {
                return oauth_json_error(
                    StatusCode::BAD_REQUEST,
                    "invalid_grant",
                    "Unsupported PKCE method.",
                );
            }
            if sha256_base64url(&code_verifier) != record.code_challenge {
                return oauth_json_error(
                    StatusCode::BAD_REQUEST,
                    "invalid_grant",
                    "Invalid code_verifier.",
                );
            }

            Json(token_response_from_supabase(
                record.access_token,
                record.refresh_token,
                record.scope,
            ))
            .into_response()
        }
        "refresh_token" => {
            let refresh_token = match form
                .refresh_token
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                Some(token) => token.to_string(),
                None => {
                    return oauth_json_error(
                        StatusCode::BAD_REQUEST,
                        "invalid_request",
                        "Missing refresh_token.",
                    )
                }
            };

            let refresh_token_hash = token_hash(&refresh_token);
            if state
                .oauth_revoked_refresh_tokens
                .contains_key(&refresh_token_hash)
            {
                return oauth_json_error(
                    StatusCode::BAD_REQUEST,
                    "invalid_grant",
                    "Refresh token has been revoked.",
                );
            }

            let auth = match state.supabase.refresh_session(&refresh_token).await {
                Ok(auth) => auth,
                Err(err) => {
                    tracing::warn!(
                        "OAuth refresh failed for client {}: {}",
                        form.client_id,
                        err
                    );
                    return oauth_json_error(
                        StatusCode::BAD_REQUEST,
                        "invalid_grant",
                        "Refresh token rejected by upstream identity provider.",
                    );
                }
            };

            state
                .oauth_revoked_refresh_tokens
                .insert(refresh_token_hash, Utc::now());

            let scope = client.scopes.join(" ");
            Json(token_response_from_supabase(
                auth.access_token,
                auth.refresh_token,
                scope,
            ))
            .into_response()
        }
        _ => oauth_json_error(
            StatusCode::BAD_REQUEST,
            "unsupported_grant_type",
            "Unsupported grant_type.",
        ),
    }
}

pub async fn userinfo(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let token = bearer_token(&headers);
    let Some(token) = token else {
        return oauth_json_error(
            StatusCode::UNAUTHORIZED,
            "invalid_token",
            "Missing Bearer token.",
        );
    };

    match state.supabase.get_user(&token).await {
        Ok(user) => Json(userinfo_response_from_supabase(user)).into_response(),
        Err(err) => {
            tracing::warn!("OAuth userinfo rejected token: {}", err);
            oauth_json_error(
                StatusCode::UNAUTHORIZED,
                "invalid_token",
                "Access token rejected by upstream identity provider.",
            )
        }
    }
}

pub async fn revoke(State(state): State<AppState>, Form(form): Form<OAuthRevokeForm>) -> Response {
    if !form.token.trim().is_empty() {
        state
            .oauth_revoked_refresh_tokens
            .insert(token_hash(form.token.trim()), Utc::now());
    }
    Json(serde_json::json!({ "revoked": true })).into_response()
}

pub async fn dev_authorize(
    State(state): State<AppState>,
    Json(payload): Json<OAuthDevAuthorizeRequest>,
) -> Response {
    if !state.oauth_dev_headless_authorize_enabled {
        return (StatusCode::NOT_FOUND, "Not Found").into_response();
    }

    let validated = match validate_authorize_request(
        &state.oauth_public_clients,
        &payload.response_type,
        &payload.client_id,
        &payload.redirect_uri,
        payload.scope.as_deref(),
        payload.state.as_deref(),
        payload.code_challenge.as_deref(),
        payload.code_challenge_method.as_deref(),
    ) {
        Ok(validated) => validated,
        Err(err) => return oauth_error_response(err),
    };

    let auth = match state
        .supabase
        .sign_in_with_password(payload.username.trim(), &payload.password)
        .await
    {
        Ok(auth) => auth,
        Err(_) => {
            return oauth_json_error(
                StatusCode::UNAUTHORIZED,
                "invalid_credentials",
                "Invalid account or password.",
            )
        }
    };

    if let Some(expected_mfa_code) = state.oauth_browser_mfa_code.as_ref() {
        if payload.mfa_code.as_deref().map(str::trim) != Some(expected_mfa_code.as_str()) {
            return oauth_json_error(
                StatusCode::UNAUTHORIZED,
                "invalid_mfa_code",
                "Valid mfa_code is required for this client.",
            );
        }
    }

    let code = issue_authorization_code(&state, &validated, auth);
    Json(serde_json::json!({
        "code": code,
        "state": validated.state,
        "redirect_to": redirect_with_query(
            &validated.redirect_uri,
            &[("code", &code), ("state", &validated.state)]
        )
    }))
    .into_response()
}

fn validate_authorize_request(
    clients: &HashMap<String, PublicClientRegistration>,
    response_type: &str,
    client_id: &str,
    redirect_uri: &str,
    scope: Option<&str>,
    state: Option<&str>,
    code_challenge: Option<&str>,
    code_challenge_method: Option<&str>,
) -> Result<ValidatedAuthorizeRequest, OAuthError> {
    let client_id = client_id.trim();
    let redirect_uri = redirect_uri.trim();
    let scope = scope
        .unwrap_or("openid profile email offline_access")
        .trim();
    let state = state.unwrap_or("").trim();
    let code_challenge = code_challenge.unwrap_or("").trim();
    let code_challenge_method = code_challenge_method.unwrap_or("").trim().to_uppercase();

    if client_id.is_empty() {
        return Err(OAuthError::new(
            StatusCode::BAD_REQUEST,
            "invalid_client",
            "client_id is required.",
        ));
    }
    let Some(client) = clients.get(client_id) else {
        return Err(OAuthError::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized_client",
            "Unknown client_id.",
        ));
    };
    if redirect_uri.is_empty() {
        return Err(OAuthError::new(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "redirect_uri is required.",
        ));
    }
    if !client
        .redirect_uris
        .iter()
        .any(|candidate| candidate == redirect_uri)
    {
        return Err(OAuthError::new(
            StatusCode::BAD_REQUEST,
            "invalid_redirect_uri",
            "redirect_uri is not registered for this client.",
        ));
    }
    if response_type.trim() != "code" {
        return Err(OAuthError::new(
            StatusCode::BAD_REQUEST,
            "unsupported_response_type",
            "response_type must be `code`.",
        )
        .with_redirect(Some(redirect_uri.to_string()), non_empty(state)));
    }
    if state.is_empty() {
        return Err(OAuthError::new(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "state is required.",
        )
        .with_redirect(Some(redirect_uri.to_string()), None));
    }
    if code_challenge.is_empty() {
        return Err(OAuthError::new(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "code_challenge is required.",
        )
        .with_redirect(Some(redirect_uri.to_string()), non_empty(state)));
    }
    if code_challenge_method != "S256" {
        return Err(OAuthError::new(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "Only S256 code_challenge_method is supported.",
        )
        .with_redirect(Some(redirect_uri.to_string()), non_empty(state)));
    }
    let requested_scopes: Vec<&str> = scope
        .split_whitespace()
        .filter(|value| !value.is_empty())
        .collect();
    if requested_scopes.is_empty() {
        return Err(OAuthError::new(
            StatusCode::BAD_REQUEST,
            "invalid_scope",
            "At least one scope is required.",
        )
        .with_redirect(Some(redirect_uri.to_string()), non_empty(state)));
    }
    if requested_scopes
        .iter()
        .any(|requested| !client.scopes.iter().any(|allowed| allowed == requested))
    {
        return Err(OAuthError::new(
            StatusCode::BAD_REQUEST,
            "invalid_scope",
            "Requested scope is not allowed for this client.",
        )
        .with_redirect(Some(redirect_uri.to_string()), non_empty(state)));
    }

    Ok(ValidatedAuthorizeRequest {
        client_id: client_id.to_string(),
        redirect_uri: redirect_uri.to_string(),
        scope: requested_scopes.join(" "),
        state: state.to_string(),
        code_challenge: code_challenge.to_string(),
        code_challenge_method,
    })
}

fn issue_authorization_code(
    state: &AppState,
    request: &ValidatedAuthorizeRequest,
    auth: SupabaseAuthResponse,
) -> String {
    issue_authorization_code_from_tokens(state, request, auth.access_token, auth.refresh_token)
}

fn issue_authorization_code_from_tokens(
    state: &AppState,
    request: &ValidatedAuthorizeRequest,
    access_token: String,
    refresh_token: Option<String>,
) -> String {
    let code = Uuid::new_v4().simple().to_string();
    let issued_at = Utc::now();
    let expires_at = issued_at + Duration::minutes(AUTHORIZATION_CODE_TTL_MINUTES);
    state.oauth_authorization_codes.insert(
        code.clone(),
        AuthorizationCodeRecord {
            client_id: request.client_id.clone(),
            redirect_uri: request.redirect_uri.clone(),
            scope: request.scope.clone(),
            code_challenge: request.code_challenge.clone(),
            code_challenge_method: request.code_challenge_method.clone(),
            access_token,
            refresh_token,
            issued_at,
            expires_at,
        },
    );
    code
}

fn oauth_error_response(error: OAuthError) -> Response {
    if let Some(redirect_uri) = error.redirect_uri {
        let mut query: Vec<(&str, &str)> = vec![("error", error.error)];
        if let Some(state) = error.state.as_deref() {
            query.push(("state", state));
        }
        query.push(("error_description", error.message.as_str()));
        return Redirect::to(&redirect_with_query(&redirect_uri, &query)).into_response();
    }

    oauth_json_error(error.status, error.error, &error.message)
}

fn oauth_json_error(status: StatusCode, error: &str, message: &str) -> Response {
    (
        status,
        Json(serde_json::json!({
            "error": error,
            "error_description": message,
        })),
    )
        .into_response()
}

fn render_authorize_page(
    request: &ValidatedAuthorizeRequest,
    flow: &str,
    error_message: Option<&str>,
) -> String {
    let flow = normalize_browser_flow(Some(flow));
    let is_register = flow == "register";
    let title = if is_register {
        "Nebula Register"
    } else {
        "Nebula Sign In"
    };
    let subtitle = if is_register {
        "Create your Nebula account in the system browser, then continue the OAuth authorization with PKCE."
    } else {
        "Public-client OAuth 2.1 authorization powered by server-side login and PKCE."
    };
    let submit_label = if is_register {
        "Create account and authorize"
    } else {
        "Authorize"
    };
    let register_fields_display = if is_register { "block" } else { "none" };
    let password_autocomplete = if is_register {
        "new-password"
    } else {
        "current-password"
    };

    let error_block = error_message
        .map(|message| {
            format!(
                r#"<p style="color:#fecaca;margin-top:16px;">{}</p>"#,
                escape_html(message)
            )
        })
        .unwrap_or_default();

    format!(
        r#"<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>{title}</title>
    <style>
      body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #020617; color: #e2e8f0; display: flex; justify-content: center; padding: 48px 16px; }}
      .card {{ width: 100%; max-width: 420px; border-radius: 16px; background: #0f172a; border: 1px solid #1e293b; box-shadow: 0 18px 60px rgba(2, 6, 23, 0.45); padding: 24px; }}
      h1 {{ margin: 0 0 8px; font-size: 24px; }}
      p {{ color: #94a3b8; line-height: 1.5; }}
      label {{ display: block; margin-top: 16px; margin-bottom: 8px; font-size: 14px; }}
      input {{ width: 100%; box-sizing: border-box; padding: 12px; border-radius: 10px; border: 1px solid #334155; background: #020617; color: #e2e8f0; }}
      button {{ width: 100%; border: none; border-radius: 10px; margin-top: 20px; padding: 12px; font-weight: 700; background: #38bdf8; color: #082f49; cursor: pointer; }}
      code {{ color: #bae6fd; }}
      .meta {{ font-size: 12px; color: #64748b; margin-top: 16px; line-height: 1.6; }}
      .flow-toggle {{ flex:1;border-radius:10px;border:1px solid #334155;background:#111827;color:#e2e8f0;padding:10px; }}
    </style>
  </head>
  <body>
    <div class="card">
      <h1>{title}</h1>
      <p>{subtitle}</p>
      <div style="display:flex;gap:8px;margin:16px 0 4px;">
        <button id="login-toggle" class="flow-toggle" type="button" onclick="toggleFlow('login')">Sign In</button>
        <button id="register-toggle" class="flow-toggle" type="button" onclick="toggleFlow('register')">Register</button>
      </div>
      <form method="post" action="/oauth/authorize">
        <input type="hidden" name="response_type" value="code" />
        <input type="hidden" name="client_id" value="{client_id}" />
        <input type="hidden" name="redirect_uri" value="{redirect_uri}" />
        <input type="hidden" name="scope" value="{scope}" />
        <input type="hidden" name="state" value="{state}" />
        <input type="hidden" name="code_challenge" value="{code_challenge}" />
        <input type="hidden" name="code_challenge_method" value="{code_challenge_method}" />
        <input type="hidden" id="flow" name="flow" value="{flow}" />
        <label for="username">Username or Email</label>
        <input id="username" name="username" type="text" autocomplete="username" />
        <label for="password">Password</label>
        <input id="password" name="password" type="password" autocomplete="{password_autocomplete}" />
        <div id="register-fields" style="display:{register_fields_display};">
          <label for="confirm_password">Confirm Password</label>
          <input id="confirm_password" name="confirm_password" type="password" autocomplete="new-password" />
          <label for="display_name">Display Name</label>
          <input id="display_name" name="display_name" type="text" autocomplete="name" />
        </div>
        <button id="submit-button" type="submit">{submit_label}</button>
      </form>
      {error_block}
      <div class="meta">
        Client: <code>{client_id}</code><br />
        Redirect URI: <code>{redirect_uri}</code><br />
        Scope: <code>{scope}</code>
      </div>
    </div>
    <script>
      function toggleFlow(flow) {{
        const field = document.getElementById('flow');
        const registerFields = document.getElementById('register-fields');
        const password = document.getElementById('password');
        const submitButton = document.getElementById('submit-button');
        const loginToggle = document.getElementById('login-toggle');
        const registerToggle = document.getElementById('register-toggle');
        field.value = flow;
        if (flow === 'register') {{
          registerFields.style.display = 'block';
          password.setAttribute('autocomplete', 'new-password');
          submitButton.textContent = 'Create account and authorize';
          loginToggle.style.background = '#111827';
          loginToggle.style.color = '#e2e8f0';
          registerToggle.style.background = '#38bdf8';
          registerToggle.style.color = '#082f49';
        }} else {{
          registerFields.style.display = 'none';
          password.setAttribute('autocomplete', 'current-password');
          submitButton.textContent = 'Authorize';
          loginToggle.style.background = '#38bdf8';
          loginToggle.style.color = '#082f49';
          registerToggle.style.background = '#111827';
          registerToggle.style.color = '#e2e8f0';
        }}
      }}
      toggleFlow('{flow}');
    </script>
  </body>
</html>"#,
        title = escape_html(title),
        subtitle = escape_html(subtitle),
        client_id = escape_html(&request.client_id),
        redirect_uri = escape_html(&request.redirect_uri),
        scope = escape_html(&request.scope),
        state = escape_html(&request.state),
        code_challenge = escape_html(&request.code_challenge),
        code_challenge_method = escape_html(&request.code_challenge_method),
        flow = escape_html(flow),
        password_autocomplete = password_autocomplete,
        register_fields_display = register_fields_display,
        submit_label = escape_html(submit_label),
        error_block = error_block,
    )
}

fn render_mfa_page(
    session_id: &str,
    request: &ValidatedAuthorizeRequest,
    flow: &str,
    error_message: Option<&str>,
) -> String {
    let error_block = error_message
        .map(|message| {
            format!(
                r#"<p style="color:#fecaca;margin-top:16px;">{}</p>"#,
                escape_html(message)
            )
        })
        .unwrap_or_default();

    format!(
        r#"<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Nebula MFA Verification</title>
    <style>
      body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #020617; color: #e2e8f0; display: flex; justify-content: center; padding: 48px 16px; }}
      .card {{ width: 100%; max-width: 420px; border-radius: 16px; background: #0f172a; border: 1px solid #1e293b; box-shadow: 0 18px 60px rgba(2, 6, 23, 0.45); padding: 24px; }}
      h1 {{ margin: 0 0 8px; font-size: 24px; }}
      p {{ color: #94a3b8; line-height: 1.5; }}
      label {{ display: block; margin-top: 16px; margin-bottom: 8px; font-size: 14px; }}
      input {{ width: 100%; box-sizing: border-box; padding: 12px; border-radius: 10px; border: 1px solid #334155; background: #020617; color: #e2e8f0; letter-spacing: 0.24em; text-align: center; }}
      button {{ width: 100%; border: none; border-radius: 10px; margin-top: 20px; padding: 12px; font-weight: 700; background: #38bdf8; color: #082f49; cursor: pointer; }}
      code {{ color: #bae6fd; }}
      .meta {{ font-size: 12px; color: #64748b; margin-top: 16px; line-height: 1.6; }}
    </style>
  </head>
  <body>
    <div class="card">
      <h1>Nebula MFA Verification</h1>
      <p>Complete the second verification step to finish your authorization session.</p>
      <form method="post" action="/oauth/authorize">
        <input type="hidden" name="response_type" value="code" />
        <input type="hidden" name="client_id" value="{client_id}" />
        <input type="hidden" name="redirect_uri" value="{redirect_uri}" />
        <input type="hidden" name="scope" value="{scope}" />
        <input type="hidden" name="state" value="{state}" />
        <input type="hidden" name="code_challenge" value="{code_challenge}" />
        <input type="hidden" name="code_challenge_method" value="{code_challenge_method}" />
        <input type="hidden" name="flow" value="{flow}" />
        <input type="hidden" name="mfa_session_id" value="{session_id}" />
        <label for="mfa_code">Verification Code</label>
        <input id="mfa_code" name="mfa_code" type="text" inputmode="numeric" autocomplete="one-time-code" />
        <button type="submit">Verify and Continue</button>
      </form>
      {error_block}
      <div class="meta">
        Client: <code>{client_id}</code><br />
        Redirect URI: <code>{redirect_uri}</code>
      </div>
    </div>
  </body>
</html>"#,
        client_id = escape_html(&request.client_id),
        redirect_uri = escape_html(&request.redirect_uri),
        scope = escape_html(&request.scope),
        state = escape_html(&request.state),
        code_challenge = escape_html(&request.code_challenge),
        code_challenge_method = escape_html(&request.code_challenge_method),
        flow = escape_html(flow),
        session_id = escape_html(session_id),
        error_block = error_block,
    )
}

fn redirect_with_query(base: &str, pairs: &[(&str, &str)]) -> String {
    let separator = if base.contains('?') { '&' } else { '?' };
    let encoded = pairs
        .iter()
        .map(|(key, value)| {
            format!(
                "{}={}",
                urlencoding::encode(key),
                urlencoding::encode(value)
            )
        })
        .collect::<Vec<_>>()
        .join("&");
    format!("{base}{separator}{encoded}")
}

fn token_response_from_supabase(
    access_token: String,
    refresh_token: Option<String>,
    scope: String,
) -> OAuthTokenResponse {
    OAuthTokenResponse {
        expires_in: jwt_expires_in(&access_token).unwrap_or(3600),
        access_token,
        token_type: "Bearer",
        refresh_token,
        scope,
    }
}

fn userinfo_response_from_supabase(user: crate::supabase::SupabaseUser) -> OAuthUserInfoResponse {
    let metadata = user.user_metadata.unwrap_or_else(|| serde_json::json!({}));
    let preferred_username = metadata
        .get("preferred_username")
        .and_then(|value| value.as_str())
        .map(str::to_string)
        .or_else(|| {
            metadata
                .get("username")
                .and_then(|value| value.as_str())
                .map(str::to_string)
        })
        .or_else(|| {
            user.email
                .as_ref()
                .and_then(|email| email.split('@').next())
                .map(str::to_string)
        });
    let name = metadata
        .get("display_name")
        .and_then(|value| value.as_str())
        .map(str::to_string);
    let picture = metadata
        .get("avatar_url")
        .and_then(|value| value.as_str())
        .map(str::to_string)
        .or_else(|| {
            metadata
                .get("picture")
                .and_then(|value| value.as_str())
                .map(str::to_string)
        });

    OAuthUserInfoResponse {
        sub: user.id,
        preferred_username,
        name,
        email: user.email,
        picture,
    }
}

fn bearer_token(headers: &HeaderMap) -> Option<String> {
    headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn normalize_browser_flow(flow: Option<&str>) -> &str {
    if flow
        .unwrap_or("login")
        .trim()
        .eq_ignore_ascii_case("register")
    {
        "register"
    } else {
        "login"
    }
}

fn token_hash(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::encode(hasher.finalize())
}

fn sha256_base64url(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    URL_SAFE_NO_PAD.encode(hasher.finalize())
}

fn jwt_expires_in(access_token: &str) -> Option<i64> {
    let mut segments = access_token.split('.');
    let _header = segments.next()?;
    let payload = segments.next()?;
    let decoded = URL_SAFE_NO_PAD.decode(payload).ok()?;
    let value: serde_json::Value = serde_json::from_slice(&decoded).ok()?;
    let exp = value.get("exp")?.as_i64()?;
    Some((exp - Utc::now().timestamp()).max(0))
}

fn non_empty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

pub fn default_public_clients() -> HashMap<String, PublicClientRegistration> {
    HashMap::from([
        (
            "skybridge_compass_pro".to_string(),
            PublicClientRegistration {
                redirect_uris: vec!["skybridge://auth/nebula".to_string()],
                scopes: vec![
                    "openid".to_string(),
                    "profile".to_string(),
                    "email".to_string(),
                    "offline_access".to_string(),
                ],
            },
        ),
        (
            "skybridge_compass_ios".to_string(),
            PublicClientRegistration {
                redirect_uris: vec!["skybridge://auth/nebula".to_string()],
                scopes: vec![
                    "openid".to_string(),
                    "profile".to_string(),
                    "email".to_string(),
                    "offline_access".to_string(),
                ],
            },
        ),
        (
            "skybridge_compass_web".to_string(),
            PublicClientRegistration {
                redirect_uris: vec![
                    "http://localhost:5173/auth/callback".to_string(),
                    "http://127.0.0.1:5173/auth/callback".to_string(),
                    "https://skybridge-compass.vercel.app/auth/callback".to_string(),
                    "https://nebula-technologies.net/auth/callback".to_string(),
                    "https://www.nebula-technologies.net/auth/callback".to_string(),
                ],
                scopes: vec![
                    "openid".to_string(),
                    "profile".to_string(),
                    "email".to_string(),
                    "offline_access".to_string(),
                ],
            },
        ),
    ])
}

pub fn revoked_refresh_token_retention() -> Duration {
    Duration::days(REVOKED_REFRESH_TOKEN_RETENTION_DAYS)
}

#[cfg(test)]
mod tests {
    use axum::{
        body::{to_bytes, Body},
        http::{Request, StatusCode},
    };
    use tower::ServiceExt;

    use super::*;
    use crate::{build_test_app, state::AppState};

    fn pkce_challenge(verifier: &str) -> String {
        sha256_base64url(verifier)
    }

    #[tokio::test]
    async fn discovery_exposes_public_client_metadata() {
        let response = build_test_app(AppState::new())
            .oneshot(
                Request::builder()
                    .uri("/.well-known/openid-configuration")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(
            value["token_endpoint_auth_methods_supported"],
            serde_json::json!(["none"])
        );
        assert_eq!(
            value["code_challenge_methods_supported"],
            serde_json::json!(["S256"])
        );
    }

    #[tokio::test]
    async fn authorize_requires_registered_redirect_uri() {
        let response = build_test_app(AppState::new())
            .oneshot(
                Request::builder()
                    .uri("/oauth/authorize?response_type=code&client_id=skybridge_compass_pro&redirect_uri=https://evil.example.com&scope=openid&state=abc&code_challenge=xyz&code_challenge_method=S256")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn authorize_register_flow_renders_registration_state() {
        let response = build_test_app(AppState::new())
            .oneshot(
                Request::builder()
                    .uri("/oauth/authorize?response_type=code&client_id=skybridge_compass_pro&redirect_uri=skybridge%3A%2F%2Fauth%2Fnebula&scope=openid%20profile%20email%20offline_access&state=abc&code_challenge=xyz&code_challenge_method=S256&flow=register")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let html = String::from_utf8(body.to_vec()).unwrap();
        assert!(html.contains("<title>Nebula Register</title>"));
        assert!(html.contains("name=\"flow\" value=\"register\""));
        assert!(html.contains("Create account and authorize"));
    }

    #[tokio::test]
    async fn token_exchange_requires_matching_code_verifier() {
        let state = AppState::new();
        state.oauth_authorization_codes.insert(
            "code-1".to_string(),
            AuthorizationCodeRecord {
                client_id: "skybridge_compass_pro".to_string(),
                redirect_uri: "skybridge://auth/nebula".to_string(),
                scope: "openid profile".to_string(),
                code_challenge: pkce_challenge("expected-verifier"),
                code_challenge_method: "S256".to_string(),
                access_token: "header.payload.signature".to_string(),
                refresh_token: Some("refresh-1".to_string()),
                issued_at: Utc::now(),
                expires_at: Utc::now() + Duration::minutes(5),
            },
        );

        let response = build_test_app(state)
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/oauth/token")
                    .header("content-type", "application/x-www-form-urlencoded")
                    .body(Body::from("grant_type=authorization_code&client_id=skybridge_compass_pro&code=code-1&redirect_uri=skybridge%3A%2F%2Fauth%2Fnebula&code_verifier=wrong-verifier"))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["error"], "invalid_grant");
    }

    #[tokio::test]
    async fn token_exchange_returns_stored_tokens_when_pkce_matches() {
        let state = AppState::new();
        state.oauth_authorization_codes.insert(
            "code-2".to_string(),
            AuthorizationCodeRecord {
                client_id: "skybridge_compass_pro".to_string(),
                redirect_uri: "skybridge://auth/nebula".to_string(),
                scope: "openid profile offline_access".to_string(),
                code_challenge: pkce_challenge("expected-verifier"),
                code_challenge_method: "S256".to_string(),
                access_token: "header.payload.signature".to_string(),
                refresh_token: Some("refresh-2".to_string()),
                issued_at: Utc::now(),
                expires_at: Utc::now() + Duration::minutes(5),
            },
        );

        let response = build_test_app(state)
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/oauth/token")
                    .header("content-type", "application/x-www-form-urlencoded")
                    .body(Body::from("grant_type=authorization_code&client_id=skybridge_compass_pro&code=code-2&redirect_uri=skybridge%3A%2F%2Fauth%2Fnebula&code_verifier=expected-verifier"))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["access_token"], "header.payload.signature");
        assert_eq!(value["refresh_token"], "refresh-2");
    }

    #[tokio::test]
    async fn revoked_refresh_token_is_rejected_without_upstream_call() {
        let state = AppState::new();
        state
            .oauth_revoked_refresh_tokens
            .insert(token_hash("revoked-refresh"), Utc::now());

        let response = build_test_app(state)
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/oauth/token")
                    .header("content-type", "application/x-www-form-urlencoded")
                    .body(Body::from("grant_type=refresh_token&client_id=skybridge_compass_pro&refresh_token=revoked-refresh"))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let value: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(value["error"], "invalid_grant");
    }
}
