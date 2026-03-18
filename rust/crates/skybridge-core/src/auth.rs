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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthSession {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub user_identifier: String,
    pub nebula_id: Option<String>,
    pub display_name: String,
    #[serde(with = "time::serde::rfc3339")]
    pub issued_at: OffsetDateTime,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorizationRequest {
    pub authorization_url: String,
    pub state: String,
    pub code_verifier: String,
    pub code_challenge: String,
    pub redirect_uri: String,
    pub scopes: Vec<String>,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserInfo {
    #[serde(rename = "sub")]
    pub subject: String,
    #[serde(rename = "preferred_username")]
    pub preferred_username: Option<String>,
    pub name: Option<String>,
    pub email: Option<String>,
    pub picture: Option<String>,
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
        Self::new(base_url, client_id)
    }

    pub fn new(base_url: impl Into<String>, client_id: impl Into<String>) -> Result<Self> {
        let base_url = base_url.into().trim().trim_end_matches('/').to_owned();
        let client_id = client_id.into().trim().to_owned();
        if Url::parse(&base_url).is_err() {
            bail!("invalid NEBULA_BASE_URL");
        }
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
        let response = self.client.get(url).send().await?;
        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            bail!("discovery failed ({}): {}", status, body);
        }
        Ok(response.json::<DiscoveryDocument>().await?)
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
            .await?;
        decode_token_response(response).await
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
            .await?;
        decode_token_response(response).await
    }

    pub async fn fetch_user_info(&self, access_token: &str) -> Result<UserInfo> {
        let response = self
            .client
            .get(format!("{}/oauth/userinfo", self.base_url))
            .header("Authorization", format!("Bearer {access_token}"))
            .header("Accept", "application/json")
            .send()
            .await?;
        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            bail!("userinfo failed ({}): {}", status, body);
        }
        Ok(response.json::<UserInfo>().await?)
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

async fn decode_token_response(response: reqwest::Response) -> Result<TokenResponse> {
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        bail!("token exchange failed ({}): {}", status, body);
    }
    Ok(response.json::<TokenResponse>().await?)
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
        let description = pairs
            .get("error_description")
            .cloned()
            .unwrap_or_else(|| error.to_string());
        bail!(description);
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

fn is_loopback_redirect(redirect_uri: &str) -> bool {
    Url::parse(redirect_uri).ok().is_some_and(|url| {
        matches!(url.scheme(), "http" | "https")
            && url
                .host_str()
                .is_some_and(|host| host == "127.0.0.1" || host.eq_ignore_ascii_case("localhost"))
            && url.port().is_some()
    })
}
