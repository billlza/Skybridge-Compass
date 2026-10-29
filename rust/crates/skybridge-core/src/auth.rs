use std::collections::HashMap;
use std::io::{self, Write};
use std::net::SocketAddr;

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use url::Url;

use crate::external_http::{decode_json_response, transport_error};
use crate::{CurrentPathOriginPolicy, OriginTransportPolicy};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthSession {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub user_identifier: String,
    pub nebula_id: Option<String>,
    pub display_name: String,
    #[serde(with = "time::serde::rfc3339")]
    pub issued_at: OffsetDateTime,
}

impl std::fmt::Debug for AuthSession {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AuthSession")
            .field("access_token", &"<redacted>")
            .field("refresh_token_present", &self.refresh_token.is_some())
            .field("user_identifier", &"<redacted>")
            .field("nebula_id_present", &self.nebula_id.is_some())
            .field("display_name", &"<redacted>")
            .field("issued_at", &self.issued_at)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorizationRequest {
    pub authorization_url: String,
    pub state: String,
    pub code_verifier: String,
    pub code_challenge: String,
    pub redirect_uri: String,
    pub scopes: Vec<String>,
}

impl std::fmt::Debug for AuthorizationRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AuthorizationRequest")
            .field("authorization_url", &"<redacted>")
            .field("state", &"<redacted>")
            .field("code_verifier", &"<redacted>")
            .field("code_challenge", &"<redacted>")
            .field("redirect_uri", &"<redacted>")
            .field("scopes", &self.scopes)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiscoveryDocument {
    pub issuer: String,
    #[serde(rename = "authorization_endpoint")]
    pub authorization_endpoint: String,
    #[serde(rename = "token_endpoint")]
    pub token_endpoint: String,
    #[serde(rename = "userinfo_endpoint")]
    pub userinfo_endpoint: Option<String>,
    #[serde(rename = "revocation_endpoint")]
    pub revocation_endpoint: Option<String>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenResponse {
    #[serde(rename = "access_token")]
    pub access_token: String,
    #[serde(rename = "token_type")]
    pub token_type: String,
    #[serde(rename = "expires_in")]
    pub expires_in: Option<i64>,
    #[serde(rename = "refresh_token")]
    pub refresh_token: Option<String>,
    pub scope: Option<String>,
    #[serde(rename = "id_token")]
    pub id_token: Option<String>,
}

impl std::fmt::Debug for TokenResponse {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TokenResponse")
            .field("access_token", &"<redacted>")
            .field("token_type", &self.token_type)
            .field("expires_in", &self.expires_in)
            .field(
                "refresh_token",
                &self.refresh_token.as_ref().map(|_| "<redacted>"),
            )
            .field("scope", &self.scope)
            .field("id_token", &self.id_token.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserInfo {
    #[serde(rename = "sub")]
    pub subject: String,
    #[serde(rename = "preferred_username")]
    pub preferred_username: Option<String>,
    pub name: Option<String>,
    pub email: Option<String>,
    pub picture: Option<String>,
}

impl std::fmt::Debug for UserInfo {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("UserInfo")
            .field("subject", &"<redacted>")
            .field(
                "preferred_username_present",
                &self.preferred_username.is_some(),
            )
            .field("name_present", &self.name.is_some())
            .field("email_present", &self.email.is_some())
            .field("picture_present", &self.picture.is_some())
            .finish()
    }
}

#[derive(Debug, Clone)]
pub struct NebulaOAuthClient {
    client: Client,
    base_url: String,
    client_id: String,
}

impl NebulaOAuthClient {
    pub fn from_env() -> Result<Self> {
        let base_url = std::env::var("NEBULA_BASE_URL")
            .or_else(|_| std::env::var("SKYBRIDGE_NEBULA_BASE_URL"))
            .context("missing NEBULA_BASE_URL")?;
        let client_id = std::env::var("NEBULA_CLIENT_ID")
            .or_else(|_| std::env::var("SKYBRIDGE_NEBULA_CLIENT_ID"))
            .context("missing NEBULA_CLIENT_ID")?;
        Self::new_with_transport_policy(
            base_url,
            client_id,
            OriginTransportPolicy::from_environment()?,
        )
    }

    pub fn new(base_url: impl Into<String>, client_id: impl Into<String>) -> Result<Self> {
        Self::new_with_transport_policy(base_url, client_id, OriginTransportPolicy::SecureOnly)
    }

    pub fn new_with_transport_policy(
        base_url: impl Into<String>,
        client_id: impl Into<String>,
        transport_policy: OriginTransportPolicy,
    ) -> Result<Self> {
        let base_url = CurrentPathOriginPolicy::canonical_origin_with_policy(
            base_url.into().trim(),
            transport_policy,
        )
        .context("invalid NEBULA_BASE_URL")?;
        let client_id = client_id.into().trim().to_owned();
        if client_id.is_empty() {
            bail!("missing NEBULA_CLIENT_ID");
        }
        let client = Client::builder()
            .timeout(std::time::Duration::from_secs(20))
            .build()
            .context("failed to build oauth http client")?;
        Ok(Self {
            client,
            base_url,
            client_id,
        })
    }

    pub async fn fetch_discovery_document(&self) -> Result<DiscoveryDocument> {
        let url = format!("{}/.well-known/openid-configuration", self.base_url);
        let response = self
            .client
            .get(url)
            .send()
            .await
            .map_err(|error| transport_error("nebula oauth", "discovery", &error))?;
        decode_json_response(response, "nebula oauth", "discovery").await
    }

    pub fn make_authorization_request(
        &self,
        redirect_uri: &str,
        scopes: &[&str],
        additional_parameters: &[(&str, &str)],
    ) -> Result<AuthorizationRequest> {
        let code_verifier = generate_code_verifier();
        let code_challenge = code_challenge(&code_verifier);
        let state = generate_state();
        let mut url = Url::parse(&format!("{}/oauth/authorize", self.base_url))
            .context("invalid authorization endpoint")?;
        {
            let mut query = url.query_pairs_mut();
            query.append_pair("response_type", "code");
            query.append_pair("client_id", &self.client_id);
            query.append_pair("redirect_uri", redirect_uri);
            query.append_pair("scope", &scopes.join(" "));
            query.append_pair("state", &state);
            query.append_pair("code_challenge", &code_challenge);
            query.append_pair("code_challenge_method", "S256");
            for (key, value) in additional_parameters {
                query.append_pair(key, value);
            }
        }
        Ok(AuthorizationRequest {
            authorization_url: url.to_string(),
            state,
            code_verifier,
            code_challenge,
            redirect_uri: redirect_uri.to_owned(),
            scopes: scopes.iter().map(|scope| (*scope).to_owned()).collect(),
        })
    }

    pub async fn exchange_authorization_code(
        &self,
        code: &str,
        authorization_request: &AuthorizationRequest,
    ) -> Result<TokenResponse> {
        let response = self
            .client
            .post(format!("{}/oauth/token", self.base_url))
            .header("Accept", "application/json")
            .form(&[
                ("grant_type", "authorization_code"),
                ("client_id", self.client_id.as_str()),
                ("code", code),
                ("redirect_uri", authorization_request.redirect_uri.as_str()),
                (
                    "code_verifier",
                    authorization_request.code_verifier.as_str(),
                ),
            ])
            .send()
            .await
            .map_err(|error| transport_error("nebula oauth", "token exchange", &error))?;
        decode_token_response(response, "token exchange").await
    }

    pub async fn refresh_token(&self, refresh_token: &str) -> Result<TokenResponse> {
        let response = self
            .client
            .post(format!("{}/oauth/token", self.base_url))
            .header("Accept", "application/json")
            .form(&[
                ("grant_type", "refresh_token"),
                ("client_id", self.client_id.as_str()),
                ("refresh_token", refresh_token),
            ])
            .send()
            .await
            .map_err(|error| transport_error("nebula oauth", "token refresh", &error))?;
        decode_token_response(response, "token refresh").await
    }

    pub async fn fetch_user_info(&self, access_token: &str) -> Result<UserInfo> {
        let response = self
            .client
            .get(format!("{}/oauth/userinfo", self.base_url))
            .header("Authorization", format!("Bearer {access_token}"))
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(|error| transport_error("nebula oauth", "userinfo", &error))?;
        decode_json_response(response, "nebula oauth", "userinfo").await
    }

    pub async fn complete_authorization_interactively(
        &self,
        authorization_request: &AuthorizationRequest,
        open_browser: bool,
        callback_url_override: Option<String>,
        authorization_code_override: Option<String>,
    ) -> Result<AuthSession> {
        let code = if let Some(code) = authorization_code_override {
            code
        } else if let Some(callback_url) = callback_url_override {
            parse_authorization_callback(&callback_url, &authorization_request.state)?
        } else if is_loopback_redirect(&authorization_request.redirect_uri) {
            if open_browser {
                let _ = webbrowser::open(&authorization_request.authorization_url);
            }
            capture_authorization_code_via_loopback(authorization_request).await?
        } else {
            println!("Open the following URL in your browser to continue login:");
            println!("{}", authorization_request.authorization_url);
            if open_browser {
                let _ = webbrowser::open(&authorization_request.authorization_url);
            }
            print!("Paste the full callback URL or the authorization code: ");
            io::stdout().flush().ok();
            let mut input = String::new();
            io::stdin().read_line(&mut input)?;
            parse_authorization_callback(input.trim(), &authorization_request.state)?
        };

        let token_response = self
            .exchange_authorization_code(&code, authorization_request)
            .await?;
        let user_info = self.fetch_user_info(&token_response.access_token).await?;
        let display_name = user_info
            .name
            .clone()
            .or(user_info.preferred_username.clone())
            .or(user_info.email.clone())
            .unwrap_or_else(|| "Nebula User".to_owned());
        Ok(AuthSession {
            access_token: token_response.access_token,
            refresh_token: token_response.refresh_token,
            user_identifier: user_info.subject,
            nebula_id: None,
            display_name,
            issued_at: OffsetDateTime::now_utc(),
        })
    }
}

pub fn derive_tenant_identifier(access_token: &str) -> Option<String> {
    let explicit = std::env::var("SKYBRIDGE_TENANT_ID")
        .ok()
        .map(|value| value.trim().to_owned());
    if let Some(explicit) = explicit.filter(|value| !value.is_empty()) {
        return Some(explicit);
    }

    let payload = access_token.split('.').nth(1)?;
    let decoded = URL_SAFE_NO_PAD.decode(payload.as_bytes()).ok()?;
    let object = serde_json::from_slice::<serde_json::Value>(&decoded).ok()?;
    for candidate in [
        object.pointer("/app_metadata/tenant_id"),
        object.pointer("/app_metadata/tenantId"),
        object.pointer("/app_metadata/org_id"),
        object.pointer("/app_metadata/workspace_id"),
        object.pointer("/user_metadata/tenant_id"),
        object.pointer("/user_metadata/tenantId"),
        object.pointer("/user_metadata/org_id"),
        object.pointer("/user_metadata/workspace_id"),
        object.pointer("/tenant_id"),
        object.pointer("/tenantId"),
        object.pointer("/sub"),
    ] {
        if let Some(value) = candidate.and_then(|item| item.as_str()) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_owned());
            }
        }
    }
    None
}

pub fn should_refresh_access_token(access_token: &str, skew_seconds: i64) -> bool {
    let payload = match access_token.split('.').nth(1) {
        Some(value) => value,
        None => return false,
    };
    let decoded = match URL_SAFE_NO_PAD.decode(payload.as_bytes()) {
        Ok(value) => value,
        Err(_) => return false,
    };
    let object = match serde_json::from_slice::<serde_json::Value>(&decoded) {
        Ok(value) => value,
        Err(_) => return false,
    };
    let exp = match object.get("exp").and_then(|value| value.as_i64()) {
        Some(value) => value,
        None => return false,
    };
    let expiry = OffsetDateTime::from_unix_timestamp(exp).ok();
    expiry.is_some_and(|expiry| {
        expiry <= OffsetDateTime::now_utc() + time::Duration::seconds(skew_seconds)
    })
}

fn generate_code_verifier() -> String {
    URL_SAFE_NO_PAD.encode(random_bytes(32))
}

fn code_challenge(verifier: &str) -> String {
    let digest = Sha256::digest(verifier.as_bytes());
    URL_SAFE_NO_PAD.encode(digest)
}

fn generate_state() -> String {
    URL_SAFE_NO_PAD.encode(random_bytes(24))
}

fn random_bytes(length: usize) -> Vec<u8> {
    let mut bytes = vec![0_u8; length];
    getrandom::fill(&mut bytes).expect("secure random generation must succeed");
    bytes
}

async fn decode_token_response(
    response: reqwest::Response,
    operation: &'static str,
) -> Result<TokenResponse> {
    decode_json_response(response, "nebula oauth", operation).await
}

async fn capture_authorization_code_via_loopback(
    authorization_request: &AuthorizationRequest,
) -> Result<String> {
    let redirect =
        Url::parse(&authorization_request.redirect_uri).context("invalid redirect uri")?;
    let host = redirect.host_str().unwrap_or("127.0.0.1");
    let port = redirect
        .port_or_known_default()
        .ok_or_else(|| anyhow!("redirect uri is missing port"))?;
    let path = redirect.path().to_owned();
    let addr: SocketAddr = format!("{host}:{port}")
        .parse()
        .context("invalid redirect host/port")?;
    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("failed to bind oauth callback listener on {addr}"))?;
    let (mut stream, _) = listener
        .accept()
        .await
        .context("oauth callback wait failed")?;
    let mut request = vec![0_u8; 4096];
    let read = stream.read(&mut request).await?;
    let text = String::from_utf8_lossy(&request[..read]);
    let request_line = text
        .lines()
        .next()
        .ok_or_else(|| anyhow!("empty callback request"))?;
    let target = request_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| anyhow!("invalid callback request line"))?;
    let callback_url = format!("http://{host}:{port}{target}");
    let code = parse_authorization_callback(&callback_url, &authorization_request.state)?;
    let body = b"SkyBridge CLI login complete. You can close this tab.\n";
    let response = format!(
        "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(response.as_bytes()).await.ok();
    stream.write_all(body).await.ok();
    stream.shutdown().await.ok();
    if !path.is_empty() && path != "/" && !target.starts_with(&path) {
        bail!("oauth callback path mismatch");
    }
    Ok(code)
}

fn parse_authorization_callback(value: &str, expected_state: &str) -> Result<String> {
    if !value.contains("://") && !value.contains('?') {
        let code = value.trim();
        if code.is_empty() {
            bail!("empty authorization code");
        }
        return Ok(code.to_owned());
    }

    let callback = Url::parse(value).context("invalid callback url")?;
    let pairs = callback
        .query_pairs()
        .map(|(key, value)| (key.to_string(), value.to_string()))
        .collect::<HashMap<String, String>>();
    if let Some(error) = pairs.get("error") {
        let error_code = allowlisted_oauth_error_code(error).unwrap_or("unclassified");
        bail!("oauth authorization failed ({error_code})");
    }
    let returned_state = pairs.get("state").map(String::as_str).unwrap_or("");
    if returned_state != expected_state {
        bail!("nebula login state validation failed");
    }
    let code = pairs
        .get("code")
        .cloned()
        .ok_or_else(|| anyhow!("nebula callback did not include an authorization code"))?;
    if code.trim().is_empty() {
        bail!("empty authorization code");
    }
    Ok(code)
}

fn allowlisted_oauth_error_code(value: &str) -> Option<&'static str> {
    Some(match value {
        "access_denied" => "access_denied",
        "account_selection_required" => "account_selection_required",
        "consent_required" => "consent_required",
        "interaction_required" => "interaction_required",
        "invalid_request" => "invalid_request",
        "invalid_request_object" => "invalid_request_object",
        "invalid_request_uri" => "invalid_request_uri",
        "invalid_scope" => "invalid_scope",
        "login_required" => "login_required",
        "request_not_supported" => "request_not_supported",
        "request_uri_not_supported" => "request_uri_not_supported",
        "server_error" => "server_error",
        "temporarily_unavailable" => "temporarily_unavailable",
        "unauthorized_client" => "unauthorized_client",
        "unsupported_response_type" => "unsupported_response_type",
        _ => return None,
    })
}

fn is_loopback_redirect(redirect_uri: &str) -> bool {
    Url::parse(redirect_uri).ok().is_some_and(|url| {
        matches!(url.scheme(), "http" | "https")
            && url
                .host_str()
                .is_some_and(|host| host == "127.0.0.1" || host.eq_ignore_ascii_case("localhost"))
            && url.port().is_some()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_debug_output_redacts_tokens_and_pkce_material() {
        let session = AuthSession {
            access_token: "access-secret".to_owned(),
            refresh_token: Some("refresh-secret".to_owned()),
            user_identifier: "user-1".to_owned(),
            nebula_id: None,
            display_name: "User".to_owned(),
            issued_at: OffsetDateTime::UNIX_EPOCH,
        };
        let request = AuthorizationRequest {
            authorization_url:
                "https://id.example/oauth/authorize?state=state-secret&code_challenge=challenge-secret"
                    .to_owned(),
            state: "state-secret".to_owned(),
            code_verifier: "verifier-secret".to_owned(),
            code_challenge: "challenge-secret".to_owned(),
            redirect_uri: "http://127.0.0.1:49152/callback-secret".to_owned(),
            scopes: vec!["openid".to_owned()],
        };
        let token = TokenResponse {
            access_token: "access-secret".to_owned(),
            token_type: "Bearer".to_owned(),
            expires_in: Some(60),
            refresh_token: Some("refresh-secret".to_owned()),
            scope: Some("openid".to_owned()),
            id_token: Some("id-secret".to_owned()),
        };

        let debug = format!("{session:?}\n{request:?}\n{token:?}");
        for secret in [
            "access-secret",
            "refresh-secret",
            "user-1",
            "User",
            "state-secret",
            "verifier-secret",
            "challenge-secret",
            "callback-secret",
            "id-secret",
        ] {
            assert!(!debug.contains(secret), "debug output leaked {secret}");
        }

        let user_info = UserInfo {
            subject: "subject-secret".to_owned(),
            preferred_username: Some("username-secret".to_owned()),
            name: Some("name-secret".to_owned()),
            email: Some("email-secret@example.com".to_owned()),
            picture: Some("https://example.com/private-picture".to_owned()),
        };
        let debug = format!("{user_info:?}");
        for pii in [
            "subject-secret",
            "username-secret",
            "name-secret",
            "email-secret@example.com",
            "private-picture",
        ] {
            assert!(!debug.contains(pii), "debug output leaked {pii}");
        }
    }

    #[test]
    fn oauth_client_origin_is_secure_by_default_and_loopback_opt_in_is_explicit() {
        assert!(NebulaOAuthClient::new("http://127.0.0.1:8080", "client").is_err());
        assert!(
            NebulaOAuthClient::new_with_transport_policy(
                "http://127.0.0.1:8080",
                "client",
                OriginTransportPolicy::AllowPlaintextLoopback,
            )
            .is_ok()
        );
        assert!(
            NebulaOAuthClient::new_with_transport_policy(
                "http://192.168.1.2:8080",
                "client",
                OriginTransportPolicy::AllowPlaintextLoopback,
            )
            .is_err()
        );
    }

    #[test]
    fn oauth_callback_errors_do_not_echo_external_descriptions() {
        let error = parse_authorization_callback(
            "http://127.0.0.1:49152/callback?error=access_denied&error_description=Bearer%20access-secret",
            "expected-state",
        )
        .expect_err("oauth error callback must fail");
        let message = error.to_string();
        assert!(message.contains("access_denied"));
        assert!(!message.contains("access-secret"));
        assert!(!message.contains("Bearer"));

        let reflected_secret = "sk_live_Q7wE9rT2uI4oP6aS8dF0gH1jK3lZ5xC7";
        let error = parse_authorization_callback(
            &format!("http://127.0.0.1:49152/callback?error={reflected_secret}"),
            "expected-state",
        )
        .expect_err("unknown OAuth error must fail");
        let message = error.to_string();
        assert!(message.contains("unclassified"));
        assert!(!message.contains(reflected_secret));
    }
}
