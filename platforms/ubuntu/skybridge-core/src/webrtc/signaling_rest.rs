use base64::Engine;
use tracing::{debug, warn};

use crate::crypto::provider::CryptoProvider;
use crate::crypto::signature::{SignatureAlgorithm, compute_authoritative_public_key_fingerprint};
use crate::crypto::suite::CryptoSuiteId;
use crate::p2p::LocalIdentity;

/// Locally asserted current-path identity binding used for signaling control
/// plane requests.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProtocolIdentityBinding {
    pub device_id: String,
    pub protocol_signing_algorithm: SignatureAlgorithm,
    pub protocol_public_key_bytes: Vec<u8>,
    pub protocol_public_key_fingerprint: String,
}

impl ProtocolIdentityBinding {
    pub fn new(
        device_id: impl Into<String>,
        protocol_signing_algorithm: SignatureAlgorithm,
        protocol_public_key: &[u8],
    ) -> Self {
        let device_id = normalize_device_id(&device_id.into()).unwrap_or_default();
        Self {
            device_id,
            protocol_signing_algorithm,
            protocol_public_key_bytes: protocol_public_key.to_vec(),
            protocol_public_key_fingerprint: compute_authoritative_public_key_fingerprint(
                protocol_signing_algorithm,
                protocol_public_key,
            ),
        }
    }
}

/// Remote authority learned from the control plane for current-path trust.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CurrentPathRemoteAuthority {
    pub device_id: String,
    pub protocol_signing_algorithm: SignatureAlgorithm,
    pub protocol_public_key_fingerprint: String,
    pub device_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterCodeLease {
    pub code: String,
    pub session_id: String,
    #[serde(alias = "sessionToken")]
    pub initiator_token: String,
    #[serde(default)]
    pub turn_admission_token: String,
    pub expires_in: i32,
    pub signaling_server_origin: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LookupLease {
    pub found: bool,
    pub session_id: String,
    #[serde(alias = "sessionToken")]
    pub responder_token: String,
    #[serde(default)]
    pub turn_admission_token: String,
    pub expires_in: i32,
    pub signaling_server_origin: String,
    pub initiator_device_id: String,
    pub initiator_protocol_signing_algorithm: String,
    pub initiator_protocol_public_key_fingerprint: String,
    pub initiator_device_name: Option<String>,
}

impl LookupLease {
    pub fn remote_authority(&self) -> Option<CurrentPathRemoteAuthority> {
        let protocol_signing_algorithm =
            SignatureAlgorithm::from_protocol_name(&self.initiator_protocol_signing_algorithm)?;
        Some(CurrentPathRemoteAuthority {
            device_id: self.initiator_device_id.trim().to_string(),
            protocol_signing_algorithm,
            protocol_public_key_fingerprint: self
                .initiator_protocol_public_key_fingerprint
                .trim()
                .to_ascii_lowercase(),
            device_name: self.initiator_device_name.clone(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterSessionLease {
    pub session_id: String,
    #[serde(alias = "sessionToken")]
    pub initiator_signaling_token: String,
    pub qr_bootstrap_token: String,
    #[serde(default)]
    pub turn_admission_token: String,
    pub expires_in: i32,
    pub signaling_server_origin: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RedeemSessionLease {
    pub session_id: String,
    #[serde(alias = "sessionToken")]
    pub responder_signaling_token: String,
    #[serde(default)]
    pub turn_admission_token: String,
    pub expires_in: i32,
    pub signaling_server_origin: String,
    pub initiator_device_id: String,
    pub initiator_protocol_signing_algorithm: String,
    pub initiator_protocol_public_key_fingerprint: String,
}

impl RedeemSessionLease {
    pub fn remote_authority(&self) -> Option<CurrentPathRemoteAuthority> {
        let protocol_signing_algorithm =
            SignatureAlgorithm::from_protocol_name(&self.initiator_protocol_signing_algorithm)?;
        Some(CurrentPathRemoteAuthority {
            device_id: self.initiator_device_id.trim().to_string(),
            protocol_signing_algorithm,
            protocol_public_key_fingerprint: self
                .initiator_protocol_public_key_fingerprint
                .trim()
                .to_ascii_lowercase(),
            device_name: None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnCredentialResponse {
    pub username: String,
    pub password: String,
    pub ttl: i32,
    #[serde(default)]
    pub expires_at: Option<i64>,
    #[serde(default)]
    pub uris: Vec<String>,
    #[serde(default)]
    pub mode: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdmissionChallenge {
    pub challenge_id: String,
    pub nonce: String,
    pub tenant_id: String,
    pub user_id: String,
    pub device_id: String,
    pub client_ip_hash: String,
    pub client_version: String,
    pub protocol_version: String,
    pub state: String,
    pub issued_at: i64,
    pub expires_at: i64,
}

impl AdmissionChallenge {
    pub fn signature_payload(&self) -> Vec<u8> {
        [
            "SkyBridge-Admission-Challenge",
            self.challenge_id.as_str(),
            self.nonce.as_str(),
            self.tenant_id.as_str(),
            self.user_id.as_str(),
            self.device_id.as_str(),
            self.client_version.as_str(),
            self.protocol_version.as_str(),
        ]
        .join("\n")
        .into_bytes()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdmissionLease {
    pub admission_token: String,
    pub state: String,
    pub issued_at: i64,
    pub expires_at: i64,
}

#[derive(Debug, thiserror::Error)]
pub enum SignalingControlError {
    #[error("invalid signaling base URL")]
    InvalidBaseUrl,
    #[error("invalid device ID")]
    InvalidDeviceId,
    #[error("invalid protocol fingerprint")]
    InvalidFingerprint,
    #[error("invalid signaling origin")]
    InvalidOrigin,
    #[error("missing authenticated user session")]
    MissingAuthentication,
    #[error("missing tenant ID")]
    MissingTenantId,
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("server rejected request ({status}): {body}")]
    ServerRejected { status: u16, body: String },
    #[error("malformed response: {0}")]
    MalformedResponse(String),
}

#[derive(Debug, Clone)]
pub struct SignalingControlClient {
    client: reqwest::Client,
    base_url: String,
    client_api_key: Option<String>,
    bearer_token: Option<String>,
    tenant_id: Option<String>,
    client_version: String,
    protocol_version: String,
}

impl SignalingControlClient {
    pub fn new(base_url: impl Into<String>, client_api_key: Option<String>) -> Self {
        let base_url = base_url.into();
        let client = if base_url_targets_loopback(&base_url) {
            reqwest::Client::builder()
                .no_proxy()
                .build()
                .unwrap_or_else(|_| reqwest::Client::new())
        } else {
            reqwest::Client::new()
        };
        Self {
            client,
            base_url,
            client_api_key: client_api_key
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty()),
            bearer_token: None,
            tenant_id: None,
            client_version: env!("CARGO_PKG_VERSION").to_string(),
            protocol_version: crate::PROTOCOL_VERSION.to_string(),
        }
    }

    pub fn with_user_auth(
        mut self,
        bearer_token: Option<String>,
        tenant_id: Option<String>,
    ) -> Self {
        self.bearer_token = bearer_token
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        self.tenant_id = tenant_id
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        self
    }

    pub fn with_version_info(
        mut self,
        client_version: impl Into<String>,
        protocol_version: impl Into<String>,
    ) -> Self {
        self.client_version = client_version.into().trim().to_string();
        self.protocol_version = protocol_version.into().trim().to_string();
        self
    }

    pub async fn request_admission_challenge(
        &self,
        binding: &ProtocolIdentityBinding,
    ) -> Result<AdmissionChallenge, SignalingControlError> {
        self.validate_binding(binding)?;
        #[derive(serde::Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            device_id: &'a str,
            protocol_signing_algorithm: &'a str,
            protocol_public_key_fingerprint: &'a str,
            client_version: &'a str,
            protocol_version: &'a str,
        }

        self.perform_json_request(
            "/api/webrtc/admission/challenge",
            reqwest::Method::POST,
            &[],
            Some(&RequestBody {
                device_id: &binding.device_id,
                protocol_signing_algorithm: binding.protocol_signing_algorithm.protocol_name(),
                protocol_public_key_fingerprint: &binding.protocol_public_key_fingerprint,
                client_version: &self.client_version,
                protocol_version: &self.protocol_version,
            }),
            true,
            &[],
        )
        .await
    }

    pub async fn complete_admission(
        &self,
        challenge: &AdmissionChallenge,
        binding: &ProtocolIdentityBinding,
        signature: &[u8],
    ) -> Result<AdmissionLease, SignalingControlError> {
        self.validate_binding(binding)?;
        #[derive(serde::Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            challenge_id: &'a str,
            signature: &'a str,
            device_id: &'a str,
            protocol_signing_algorithm: &'a str,
            protocol_public_key_fingerprint: &'a str,
            protocol_public_key_bytes: &'a str,
            client_version: &'a str,
            protocol_version: &'a str,
        }

        let signature_b64 = base64::engine::general_purpose::STANDARD.encode(signature);
        let public_key_b64 =
            base64::engine::general_purpose::STANDARD.encode(&binding.protocol_public_key_bytes);

        self.perform_json_request(
            "/api/webrtc/admission",
            reqwest::Method::POST,
            &[],
            Some(&RequestBody {
                challenge_id: &challenge.challenge_id,
                signature: &signature_b64,
                device_id: &binding.device_id,
                protocol_signing_algorithm: binding.protocol_signing_algorithm.protocol_name(),
                protocol_public_key_fingerprint: &binding.protocol_public_key_fingerprint,
                protocol_public_key_bytes: &public_key_b64,
                client_version: &challenge.client_version,
                protocol_version: &challenge.protocol_version,
            }),
            true,
            &[],
        )
        .await
    }

    pub async fn issue_admission_lease(
        &self,
        binding: &ProtocolIdentityBinding,
        identity: &LocalIdentity,
    ) -> Result<AdmissionLease, SignalingControlError> {
        let challenge = self
            .request_admission_challenge(binding)
            .await
            .map_err(|err| {
                warn!(
                    device_id = %binding.device_id,
                    "signaling admission challenge failed: {}",
                    err
                );
                err
            })?;
        debug!(
            device_id = %binding.device_id,
            challenge_id = %challenge.challenge_id,
            "signaling admission challenge issued"
        );
        let signing_key = identity
            .signing_private_key(binding.protocol_signing_algorithm)
            .ok_or_else(|| {
                SignalingControlError::MalformedResponse(
                    "missing local protocol signing private key".to_string(),
                )
            })?;
        let crypto = CryptoProvider::new(signaling_suite_for_algorithm(
            binding.protocol_signing_algorithm,
        ));
        let signature = crypto
            .sign(&challenge.signature_payload(), signing_key)
            .await
            .map_err(|err| SignalingControlError::MalformedResponse(err.to_string()))?;
        self.complete_admission(&challenge, binding, &signature)
            .await
            .map_err(|err| {
                warn!(
                    device_id = %binding.device_id,
                    challenge_id = %challenge.challenge_id,
                    "signaling admission completion failed: {}",
                    err
                );
                err
            })
    }

    pub async fn register_connection_code(
        &self,
        binding: &ProtocolIdentityBinding,
        identity: &LocalIdentity,
        device_name: &str,
        ttl_seconds: i32,
    ) -> Result<RegisterCodeLease, SignalingControlError> {
        self.validate_binding(binding)?;
        let admission = self.issue_admission_lease(binding, identity).await?;
        #[derive(serde::Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            device_name: &'a str,
            ttl_seconds: i32,
        }

        let body = RequestBody {
            device_name: device_name.trim(),
            ttl_seconds: ttl_seconds.max(60),
        };

        let response: RegisterCodeLease = self
            .perform_json_request(
                "/api/webrtc/register-code",
                reqwest::Method::POST,
                &[],
                Some(&body),
                false,
                &[("X-SkyBridge-Admission", admission.admission_token.as_str())],
            )
            .await?;
        validate_current_path_origin(&response.signaling_server_origin)?;
        Ok(response)
    }

    pub async fn lookup_connection_code(
        &self,
        code: &str,
        binding: &ProtocolIdentityBinding,
        identity: &LocalIdentity,
    ) -> Result<LookupLease, SignalingControlError> {
        self.validate_binding(binding)?;
        let admission = self.issue_admission_lease(binding, identity).await?;
        let path = format!("/api/webrtc/lookup/{}", code.trim());
        let response: LookupLease = self
            .perform_json_request(
                &path,
                reqwest::Method::GET,
                &[],
                Option::<&()>::None,
                false,
                &[("X-SkyBridge-Admission", admission.admission_token.as_str())],
            )
            .await?;
        if !response.found {
            return Err(SignalingControlError::MalformedResponse(
                "lookup reported not found".to_string(),
            ));
        }
        if response.responder_token.trim().is_empty() {
            return Err(SignalingControlError::MalformedResponse(
                "missing responder token".to_string(),
            ));
        }
        validate_current_path_origin(&response.signaling_server_origin)?;
        Ok(response)
    }

    pub async fn register_session(
        &self,
        binding: &ProtocolIdentityBinding,
        identity: &LocalIdentity,
        ttl_seconds: i32,
    ) -> Result<RegisterSessionLease, SignalingControlError> {
        self.validate_binding(binding)?;
        let admission = self.issue_admission_lease(binding, identity).await?;
        #[derive(serde::Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            session_id: Option<&'a str>,
            ttl_seconds: i32,
        }

        let body = RequestBody {
            session_id: None,
            ttl_seconds: ttl_seconds.max(60),
        };

        let response: RegisterSessionLease = self
            .perform_json_request(
                "/api/webrtc/register-session",
                reqwest::Method::POST,
                &[],
                Some(&body),
                false,
                &[("X-SkyBridge-Admission", admission.admission_token.as_str())],
            )
            .await?;
        validate_current_path_origin(&response.signaling_server_origin)?;
        Ok(response)
    }

    pub async fn redeem_session(
        &self,
        session_id: &str,
        qr_bootstrap_token: &str,
        binding: &ProtocolIdentityBinding,
        identity: &LocalIdentity,
    ) -> Result<RedeemSessionLease, SignalingControlError> {
        self.validate_binding(binding)?;
        let admission = self.issue_admission_lease(binding, identity).await?;
        #[derive(serde::Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            session_id: &'a str,
            qr_bootstrap_token: &'a str,
        }

        let body = RequestBody {
            session_id: session_id.trim(),
            qr_bootstrap_token: qr_bootstrap_token.trim(),
        };

        let response: RedeemSessionLease = self
            .perform_json_request(
                "/api/webrtc/redeem-session",
                reqwest::Method::POST,
                &[],
                Some(&body),
                false,
                &[("X-SkyBridge-Admission", admission.admission_token.as_str())],
            )
            .await?;
        validate_current_path_origin(&response.signaling_server_origin)?;
        Ok(response)
    }

    pub async fn fetch_turn_credentials(
        &self,
        turn_admission_token: Option<&str>,
        device_id: Option<&str>,
    ) -> Result<TurnCredentialResponse, SignalingControlError> {
        let url = self.build_url("/api/turn/credentials", &[])?;
        let mut request = self.client.get(url).header("Accept", "application/json");
        if let Some(api_key) = self.client_api_key.as_deref() {
            request = request.header("X-API-Key", api_key);
        }
        if let Some(turn_admission_token) = turn_admission_token
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            request = request.header("X-SkyBridge-Turn-Admission", turn_admission_token);
        }
        if let Some(device_id) = device_id.map(str::trim).filter(|value| !value.is_empty()) {
            request = request.header("X-Device-Id", device_id);
        }
        let response = request.send().await?;
        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(SignalingControlError::ServerRejected {
                status: status.as_u16(),
                body,
            });
        }
        let decoded: TurnCredentialResponse = response
            .json()
            .await
            .map_err(|err| SignalingControlError::MalformedResponse(err.to_string()))?;
        Ok(decoded)
    }

    fn validate_binding(
        &self,
        binding: &ProtocolIdentityBinding,
    ) -> Result<(), SignalingControlError> {
        if normalize_device_id(&binding.device_id).is_none() {
            return Err(SignalingControlError::InvalidDeviceId);
        }
        if binding.protocol_public_key_fingerprint.trim().len() != 64 {
            return Err(SignalingControlError::InvalidFingerprint);
        }
        if binding.protocol_public_key_bytes.is_empty() {
            return Err(SignalingControlError::MalformedResponse(
                "missing protocol signing public key bytes".to_string(),
            ));
        }
        Ok(())
    }

    fn build_url(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<url::Url, SignalingControlError> {
        let mut base = url::Url::parse(self.base_url.trim())
            .map_err(|_| SignalingControlError::InvalidBaseUrl)?;
        if base.scheme() != "https" && base.scheme() != "http" {
            return Err(SignalingControlError::InvalidBaseUrl);
        }
        base.set_query(None);
        base.set_fragment(None);
        let mut path_buf = base.path().trim_end_matches('/').to_string();
        path_buf.push_str(path);
        base.set_path(&path_buf);
        if !query.is_empty() {
            let mut pairs = base.query_pairs_mut();
            pairs.clear();
            for (name, value) in query {
                pairs.append_pair(name, value);
            }
        }
        Ok(base)
    }

    async fn perform_json_request<
        Request: serde::Serialize,
        Response: serde::de::DeserializeOwned,
    >(
        &self,
        path: &str,
        method: reqwest::Method,
        query: &[(&str, &str)],
        body: Option<&Request>,
        requires_user_auth: bool,
        extra_headers: &[(&str, &str)],
    ) -> Result<Response, SignalingControlError> {
        let url = self.build_url(path, query)?;
        let mut request = self
            .client
            .request(method, url)
            .header("Accept", "application/json");
        if let Some(api_key) = self.client_api_key.as_deref() {
            request = request.header("X-API-Key", api_key);
        }
        if let Some(tenant_id) = self.tenant_id.as_deref() {
            request = request.header("X-SkyBridge-Tenant-Id", tenant_id);
        } else if requires_user_auth {
            return Err(SignalingControlError::MissingTenantId);
        }
        if requires_user_auth {
            let bearer_token = self
                .bearer_token
                .as_deref()
                .ok_or(SignalingControlError::MissingAuthentication)?;
            request = request.header("Authorization", format!("Bearer {}", bearer_token));
        }
        if let Some(body) = body {
            request = request.json(body);
        }
        for (field, value) in extra_headers {
            request = request.header(*field, *value);
        }
        let response = request.send().await?;
        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(SignalingControlError::ServerRejected {
                status: status.as_u16(),
                body,
            });
        }
        response
            .json()
            .await
            .map_err(|err| SignalingControlError::MalformedResponse(err.to_string()))
    }
}

fn signaling_suite_for_algorithm(algorithm: SignatureAlgorithm) -> CryptoSuiteId {
    match algorithm {
        SignatureAlgorithm::Ed25519 => CryptoSuiteId::X25519_AES256GCM_Ed25519,
        SignatureAlgorithm::MlDsa65 => CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
        SignatureAlgorithm::P256Ecdsa => CryptoSuiteId::X25519_AES256GCM_Ed25519,
    }
}

fn base_url_targets_loopback(raw: &str) -> bool {
    let Ok(url) = url::Url::parse(raw.trim()) else {
        return false;
    };
    matches!(
        url.host_str(),
        Some("localhost") | Some("127.0.0.1") | Some("::1")
    )
}

pub fn normalize_device_id(raw: &str) -> Option<String> {
    let candidate = raw.trim();
    if !(16..=128).contains(&candidate.len()) {
        return None;
    }
    if !candidate
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | ':' | '-'))
    {
        return None;
    }
    Some(candidate.to_string())
}

pub fn validate_current_path_origin(raw: &str) -> Result<String, SignalingControlError> {
    let url = url::Url::parse(raw.trim()).map_err(|_| SignalingControlError::InvalidOrigin)?;
    if url.scheme() != "https" && url.scheme() != "http" {
        return Err(SignalingControlError::InvalidOrigin);
    }
    if url.host_str().is_none() {
        return Err(SignalingControlError::InvalidOrigin);
    }
    if !(url.path().is_empty() || url.path() == "/")
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(SignalingControlError::InvalidOrigin);
    }
    Ok(canonical_origin_for_url(&url))
}

fn canonical_origin_for_url(url: &url::Url) -> String {
    let scheme = url.scheme().to_ascii_lowercase();
    let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
    match (scheme.as_str(), url.port()) {
        ("https", None) | ("https", Some(443)) | ("http", None) | ("http", Some(80)) => {
            format!("{scheme}://{host}")
        }
        _ => format!("{}://{}:{}", scheme, host, url.port().unwrap_or_default()),
    }
}

pub fn websocket_url_matches_origin(
    ws_url: &url::Url,
    expected_origin: &str,
) -> Result<bool, SignalingControlError> {
    let expected = validate_current_path_origin(expected_origin)?;
    let mut translated = ws_url.clone();
    let translated_scheme = match translated.scheme() {
        "wss" => "https",
        "ws" => "http",
        "https" => "https",
        "http" => "http",
        _ => return Err(SignalingControlError::InvalidOrigin),
    };
    translated
        .set_scheme(translated_scheme)
        .map_err(|_| SignalingControlError::InvalidOrigin)?;
    Ok(canonical_origin_for_url(&translated) == expected)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_path_origin_rejects_extra_components() {
        assert!(validate_current_path_origin("https://api.example.com").is_ok());
        assert!(validate_current_path_origin("https://api.example.com/").is_ok());
        assert!(validate_current_path_origin("https://api.example.com/ws").is_err());
        assert!(validate_current_path_origin("wss://api.example.com").is_err());
    }

    #[test]
    fn websocket_origin_validation_accepts_matching_host() {
        let ws_url = url::Url::parse("wss://api.example.com/ws?shard=ABC12345").unwrap();
        assert!(websocket_url_matches_origin(&ws_url, "https://api.example.com").unwrap());
        assert!(!websocket_url_matches_origin(&ws_url, "https://other.example.com").unwrap());
    }

    #[test]
    fn protocol_identity_binding_uses_authoritative_fingerprint() {
        let key = [0x11_u8; 32];
        let binding = ProtocolIdentityBinding::new(
            "123e4567-e89b-12d3-a456-426614174000",
            SignatureAlgorithm::Ed25519,
            &key,
        );
        assert_eq!(binding.protocol_public_key_fingerprint.len(), 64);
    }
}
