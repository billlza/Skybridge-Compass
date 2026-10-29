use anyhow::{Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::external_http::{decode_json_response, inspect_json_response, transport_error};
use crate::{
    AuthSession, CurrentPathOriginPolicy, OriginTransportPolicy, ProtocolIdentityBinding,
    ProtocolSigningAlgorithm, SignalingWebSocketRequest, base64_url_encode,
};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    pub issued_at_millis: i64,
    pub expires_at_millis: i64,
}

impl std::fmt::Debug for AdmissionChallenge {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AdmissionChallenge")
            .field("challenge_id", &"<redacted>")
            .field("nonce", &"<redacted>")
            .field("tenant_id", &"<redacted>")
            .field("user_id", &"<redacted>")
            .field("device_id", &"<redacted>")
            .field("client_ip_hash", &"<redacted>")
            .field("client_version", &self.client_version)
            .field("protocol_version", &self.protocol_version)
            .field("state", &self.state)
            .field("issued_at_millis", &self.issued_at_millis)
            .field("expires_at_millis", &self.expires_at_millis)
            .finish()
    }
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

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdmissionLease {
    pub token: String,
    pub state: String,
    pub issued_at: OffsetDateTime,
    pub expires_at: OffsetDateTime,
}

impl std::fmt::Debug for AdmissionLease {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AdmissionLease")
            .field("token", &"<redacted>")
            .field("state", &self.state)
            .field("issued_at", &self.issued_at)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnAdmissionLease {
    pub token: String,
    pub expires_in: i64,
}

impl std::fmt::Debug for TurnAdmissionLease {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TurnAdmissionLease")
            .field("token", &"<redacted>")
            .field("expires_in", &self.expires_in)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TurnCredentials {
    pub username: String,
    pub password: String,
    pub ttl: i64,
    #[serde(default)]
    pub uris: Vec<String>,
    #[serde(with = "time::serde::rfc3339::option")]
    pub expires_at: Option<OffsetDateTime>,
    #[serde(default)]
    pub mode: Option<String>,
}

impl std::fmt::Debug for TurnCredentials {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TurnCredentials")
            .field("username", &"<redacted>")
            .field("password", &"<redacted>")
            .field("ttl", &self.ttl)
            .field("uri_count", &self.uris.len())
            .field("expires_at", &self.expires_at)
            .field("mode", &self.mode)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionCodeLease {
    pub code: String,
    pub session_id: String,
    pub session_token: String,
    pub turn_admission_lease: TurnAdmissionLease,
    pub expires_in: i64,
    pub signaling_server_origin: String,
}

impl std::fmt::Debug for ConnectionCodeLease {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ConnectionCodeLease")
            .field("code", &"<redacted>")
            .field("session_id", &"<redacted>")
            .field("session_token", &"<redacted>")
            .field("turn_admission_lease", &self.turn_admission_lease)
            .field("expires_in", &self.expires_in)
            .field("signaling_server_origin", &self.signaling_server_origin)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectionCodeLookup {
    pub session_id: String,
    pub session_token: String,
    pub turn_admission_lease: TurnAdmissionLease,
    pub expires_in: i64,
    pub signaling_server_origin: String,
    pub initiator_device_id: String,
    pub initiator_protocol_signing_algorithm: ProtocolSigningAlgorithm,
    pub initiator_protocol_public_key_fingerprint: String,
    pub initiator_device_name: Option<String>,
}

impl std::fmt::Debug for ConnectionCodeLookup {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ConnectionCodeLookup")
            .field("session_id", &"<redacted>")
            .field("session_token", &"<redacted>")
            .field("turn_admission_lease", &self.turn_admission_lease)
            .field("expires_in", &self.expires_in)
            .field("signaling_server_origin", &self.signaling_server_origin)
            .field("initiator_device_id", &"<redacted>")
            .field(
                "initiator_protocol_signing_algorithm",
                &self.initiator_protocol_signing_algorithm,
            )
            .field("initiator_protocol_public_key_fingerprint", &"<redacted>")
            .field(
                "initiator_device_name_present",
                &self.initiator_device_name.is_some(),
            )
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionLease {
    pub session_id: String,
    pub session_token: String,
    pub qr_bootstrap_token: String,
    pub turn_admission_lease: TurnAdmissionLease,
    pub expires_in: i64,
    pub signaling_server_origin: String,
}

impl std::fmt::Debug for SessionLease {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SessionLease")
            .field("session_id", &"<redacted>")
            .field("session_token", &"<redacted>")
            .field("qr_bootstrap_token", &"<redacted>")
            .field("turn_admission_lease", &self.turn_admission_lease)
            .field("expires_in", &self.expires_in)
            .field("signaling_server_origin", &self.signaling_server_origin)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RedeemedSessionLease {
    pub session_id: String,
    pub session_token: String,
    pub turn_admission_lease: TurnAdmissionLease,
    pub expires_in: i64,
    pub signaling_server_origin: String,
    pub initiator_device_id: String,
    pub initiator_protocol_signing_algorithm: ProtocolSigningAlgorithm,
    pub initiator_protocol_public_key_fingerprint: String,
}

impl std::fmt::Debug for RedeemedSessionLease {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RedeemedSessionLease")
            .field("session_id", &"<redacted>")
            .field("session_token", &"<redacted>")
            .field("turn_admission_lease", &self.turn_admission_lease)
            .field("expires_in", &self.expires_in)
            .field("signaling_server_origin", &self.signaling_server_origin)
            .field("initiator_device_id", &"<redacted>")
            .field(
                "initiator_protocol_signing_algorithm",
                &self.initiator_protocol_signing_algorithm,
            )
            .field("initiator_protocol_public_key_fingerprint", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegisteredDevice {
    pub id: serde_json::Value,
    pub tenant_id: String,
    pub user_id: String,
    pub device_id: String,
    pub protocol_signing_algorithm: String,
    pub protocol_public_key_fingerprint: String,
    pub device_name: String,
    pub status: String,
}

impl std::fmt::Debug for RegisteredDevice {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RegisteredDevice")
            .field("id", &"<redacted>")
            .field("tenant_id", &"<redacted>")
            .field("user_id", &"<redacted>")
            .field("device_id", &"<redacted>")
            .field(
                "protocol_signing_algorithm",
                &self.protocol_signing_algorithm,
            )
            .field("protocol_public_key_fingerprint", &"<redacted>")
            .field("device_name", &"<redacted>")
            .field("status", &self.status)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlPlaneHealthSnapshot {
    pub status: String,
    #[serde(default)]
    pub ready: Option<bool>,
    #[serde(rename = "instanceId")]
    pub instance_id: Option<String>,
    #[serde(rename = "serverBuildFingerprint")]
    pub server_build_fingerprint: Option<String>,
    #[serde(rename = "supportsMediaAdmissionRefresh")]
    pub supports_media_admission_refresh: Option<bool>,
    #[serde(rename = "stateBackend")]
    pub state_backend: Option<String>,
    #[serde(rename = "backendHealth")]
    pub backend_health: Option<serde_json::Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlPlaneRawProbe {
    pub status_code: u16,
    pub success: bool,
    pub body: serde_json::Value,
}

#[derive(Clone)]
pub struct SignalServerClient {
    client: Client,
    pub base_url: String,
    pub api_key: String,
    pub client_version: String,
    pub protocol_version: String,
    transport_policy: OriginTransportPolicy,
}

impl std::fmt::Debug for SignalServerClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SignalServerClient")
            .field("base_url", &self.base_url)
            .field("api_key", &"<redacted>")
            .field("client_version", &self.client_version)
            .field("protocol_version", &self.protocol_version)
            .field("transport_policy", &self.transport_policy)
            .finish_non_exhaustive()
    }
}

impl SignalServerClient {
    pub fn from_env() -> Result<Self> {
        let base_url = std::env::var("SKYBRIDGE_SIGNALING_SERVER_URL")
            .or_else(|_| std::env::var("SKYBRIDGE_SIGNALING_BASE_URL"))
            .unwrap_or_else(|_| "https://api.nebula-technologies.net".to_owned());
        let api_key = std::env::var("SKYBRIDGE_CLIENT_API_KEY")
            .unwrap_or_else(|_| "skybridge-client-v1".to_owned());
        let client_version = std::env::var("SKYBRIDGE_CLIENT_VERSION")
            .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_owned());
        let protocol_version =
            std::env::var("SKYBRIDGE_PROTOCOL_VERSION").unwrap_or_else(|_| "1".to_owned());
        Self::new_with_transport_policy(
            base_url,
            api_key,
            client_version,
            protocol_version,
            OriginTransportPolicy::from_environment()?,
        )
    }

    pub fn new(
        base_url: impl Into<String>,
        api_key: impl Into<String>,
        client_version: impl Into<String>,
        protocol_version: impl Into<String>,
    ) -> Result<Self> {
        Self::new_with_transport_policy(
            base_url,
            api_key,
            client_version,
            protocol_version,
            OriginTransportPolicy::SecureOnly,
        )
    }

    pub fn new_with_transport_policy(
        base_url: impl Into<String>,
        api_key: impl Into<String>,
        client_version: impl Into<String>,
        protocol_version: impl Into<String>,
        transport_policy: OriginTransportPolicy,
    ) -> Result<Self> {
        let base_url = CurrentPathOriginPolicy::canonical_origin_with_policy(
            base_url.into().trim(),
            transport_policy,
        )?;
        let api_key = api_key.into().trim().to_owned();
        let client = Client::builder()
            .timeout(std::time::Duration::from_secs(20))
            .no_proxy()
            .build()?;
        Ok(Self {
            client,
            base_url,
            api_key,
            client_version: client_version.into(),
            protocol_version: protocol_version.into(),
            transport_policy,
        })
    }

    pub fn canonical_signaling_origin(&self, origin: &str) -> Result<String> {
        CurrentPathOriginPolicy::canonical_websocket_origin_with_policy(
            origin,
            self.transport_policy,
        )
        .map_err(Into::into)
    }

    pub async fn request_admission_challenge(
        &self,
        auth_session: &AuthSession,
        tenant_id: &str,
        binding: &ProtocolIdentityBinding,
    ) -> Result<AdmissionChallenge> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            device_id: &'a str,
            protocol_signing_algorithm: ProtocolSigningAlgorithm,
            protocol_public_key_fingerprint: &'a str,
            client_version: &'a str,
            protocol_version: &'a str,
        }

        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ResponseBody {
            challenge_id: String,
            nonce: String,
            tenant_id: String,
            user_id: String,
            device_id: String,
            client_ip_hash: String,
            client_version: String,
            protocol_version: String,
            state: String,
            issued_at: i64,
            expires_at: i64,
        }

        let response: ResponseBody = self
            .json_request(
                "/api/webrtc/admission/challenge",
                reqwest::Method::POST,
                Some(&RequestBody {
                    device_id: &binding.device_id,
                    protocol_signing_algorithm: binding.protocol_signing_algorithm,
                    protocol_public_key_fingerprint: &binding.protocol_public_key_fingerprint,
                    client_version: &self.client_version,
                    protocol_version: &self.protocol_version,
                }),
                auth_session,
                tenant_id,
                None,
            )
            .await?;
        Ok(AdmissionChallenge {
            challenge_id: response.challenge_id,
            nonce: response.nonce,
            tenant_id: response.tenant_id,
            user_id: response.user_id,
            device_id: response.device_id,
            client_ip_hash: response.client_ip_hash,
            client_version: response.client_version,
            protocol_version: response.protocol_version,
            state: response.state,
            issued_at_millis: response.issued_at,
            expires_at_millis: response.expires_at,
        })
    }

    pub async fn probe_health(&self) -> Result<ControlPlaneHealthSnapshot> {
        self.json_request(
            "/health",
            reqwest::Method::GET,
            Option::<&()>::None,
            &anonymous_session(),
            "",
            None,
        )
        .await
    }

    pub async fn probe_json_endpoint(&self, path: &str) -> Result<ControlPlaneRawProbe> {
        self.raw_json_request(path, reqwest::Method::GET, Option::<&()>::None, None)
            .await
    }

    pub async fn probe_media_lease(
        &self,
        media_admission_token: &str,
    ) -> Result<ControlPlaneRawProbe> {
        self.raw_json_request(
            "/api/media/lease",
            reqwest::Method::POST,
            Some(&serde_json::json!({})),
            Some(vec![(
                "X-SkyBridge-Media-Admission".to_owned(),
                media_admission_token.trim().to_owned(),
            )]),
        )
        .await
    }

    pub async fn probe_media_lease_without_token(&self) -> Result<ControlPlaneRawProbe> {
        self.raw_json_request(
            "/api/media/lease",
            reqwest::Method::POST,
            Some(&serde_json::json!({})),
            None,
        )
        .await
    }

    pub async fn complete_admission(
        &self,
        auth_session: &AuthSession,
        tenant_id: &str,
        challenge: &AdmissionChallenge,
        binding: &ProtocolIdentityBinding,
        signature: &[u8],
    ) -> Result<AdmissionLease> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            challenge_id: &'a str,
            signature: String,
            device_id: &'a str,
            protocol_signing_algorithm: ProtocolSigningAlgorithm,
            protocol_public_key_fingerprint: &'a str,
            protocol_public_key_bytes: String,
            client_version: &'a str,
            protocol_version: &'a str,
        }

        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ResponseBody {
            admission_token: String,
            state: String,
            issued_at: i64,
            expires_at: i64,
        }

        let response: ResponseBody = self
            .json_request(
                "/api/webrtc/admission",
                reqwest::Method::POST,
                Some(&RequestBody {
                    challenge_id: &challenge.challenge_id,
                    signature: STANDARD.encode(signature),
                    device_id: &binding.device_id,
                    protocol_signing_algorithm: binding.protocol_signing_algorithm,
                    protocol_public_key_fingerprint: &binding.protocol_public_key_fingerprint,
                    protocol_public_key_bytes: STANDARD.encode(&binding.protocol_public_key_bytes),
                    client_version: &challenge.client_version,
                    protocol_version: &challenge.protocol_version,
                }),
                auth_session,
                tenant_id,
                None,
            )
            .await?;
        Ok(AdmissionLease {
            token: response.admission_token,
            state: response.state,
            issued_at: millis_to_time(response.issued_at)?,
            expires_at: millis_to_time(response.expires_at)?,
        })
    }

    pub async fn register_connection_code(
        &self,
        admission_token: &str,
        device_name: &str,
        ttl_seconds: i64,
    ) -> Result<ConnectionCodeLease> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            device_name: &'a str,
            ttl_seconds: i64,
        }

        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ResponseBody {
            code: String,
            session_id: String,
            session_token: String,
            turn_admission_token: String,
            expires_in: i64,
            signaling_server_origin: String,
        }

        let response: ResponseBody = self
            .json_request(
                "/api/webrtc/register-code",
                reqwest::Method::POST,
                Some(&RequestBody {
                    device_name,
                    ttl_seconds,
                }),
                &anonymous_session(),
                "",
                Some(vec![(
                    "X-SkyBridge-Admission".to_owned(),
                    admission_token.to_owned(),
                )]),
            )
            .await?;
        Ok(ConnectionCodeLease {
            code: response.code,
            session_id: response.session_id,
            session_token: response.session_token,
            turn_admission_lease: TurnAdmissionLease {
                token: response.turn_admission_token,
                expires_in: response.expires_in.min(60),
            },
            expires_in: response.expires_in,
            signaling_server_origin: response.signaling_server_origin,
        })
    }

    pub async fn lookup_connection_code(
        &self,
        admission_token: &str,
        code: &str,
    ) -> Result<ConnectionCodeLookup> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ResponseBody {
            found: bool,
            session_id: String,
            session_token: String,
            turn_admission_token: String,
            expires_in: i64,
            signaling_server_origin: String,
            initiator_device_id: String,
            initiator_protocol_signing_algorithm: ProtocolSigningAlgorithm,
            initiator_protocol_public_key_fingerprint: String,
            initiator_device_name: Option<String>,
        }

        let path = format!("/api/webrtc/lookup/{}", code.to_ascii_uppercase());
        let response: ResponseBody = self
            .json_request(
                &path,
                reqwest::Method::GET,
                Option::<&()>::None,
                &anonymous_session(),
                "",
                Some(vec![(
                    "X-SkyBridge-Admission".to_owned(),
                    admission_token.to_owned(),
                )]),
            )
            .await?;
        if !response.found {
            bail!("code_not_found");
        }
        Ok(ConnectionCodeLookup {
            session_id: response.session_id,
            session_token: response.session_token,
            turn_admission_lease: TurnAdmissionLease {
                token: response.turn_admission_token,
                expires_in: response.expires_in.min(60),
            },
            expires_in: response.expires_in,
            signaling_server_origin: response.signaling_server_origin,
            initiator_device_id: response.initiator_device_id,
            initiator_protocol_signing_algorithm: response.initiator_protocol_signing_algorithm,
            initiator_protocol_public_key_fingerprint: response
                .initiator_protocol_public_key_fingerprint,
            initiator_device_name: response.initiator_device_name,
        })
    }

    pub async fn register_session(
        &self,
        admission_token: &str,
        session_id: Option<&str>,
        ttl_seconds: i64,
    ) -> Result<SessionLease> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            session_id: Option<&'a str>,
            ttl_seconds: i64,
        }

        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ResponseBody {
            session_id: String,
            session_token: String,
            qr_bootstrap_token: String,
            turn_admission_token: String,
            expires_in: i64,
            signaling_server_origin: String,
        }

        let response: ResponseBody = self
            .json_request(
                "/api/webrtc/register-session",
                reqwest::Method::POST,
                Some(&RequestBody {
                    session_id,
                    ttl_seconds,
                }),
                &anonymous_session(),
                "",
                Some(vec![(
                    "X-SkyBridge-Admission".to_owned(),
                    admission_token.to_owned(),
                )]),
            )
            .await?;
        Ok(SessionLease {
            session_id: response.session_id,
            session_token: response.session_token,
            qr_bootstrap_token: response.qr_bootstrap_token,
            turn_admission_lease: TurnAdmissionLease {
                token: response.turn_admission_token,
                expires_in: response.expires_in.min(60),
            },
            expires_in: response.expires_in,
            signaling_server_origin: response.signaling_server_origin,
        })
    }

    pub async fn redeem_session(
        &self,
        admission_token: &str,
        session_id: &str,
        qr_bootstrap_token: &str,
        idempotency_key: Option<&str>,
    ) -> Result<RedeemedSessionLease> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            session_id: &'a str,
            qr_bootstrap_token: &'a str,
        }

        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ResponseBody {
            session_id: String,
            session_token: String,
            turn_admission_token: String,
            expires_in: i64,
            signaling_server_origin: String,
            initiator_device_id: String,
            initiator_protocol_signing_algorithm: ProtocolSigningAlgorithm,
            initiator_protocol_public_key_fingerprint: String,
        }

        let mut headers = vec![(
            "X-SkyBridge-Admission".to_owned(),
            admission_token.to_owned(),
        )];
        if let Some(key) = idempotency_key.filter(|value| !value.trim().is_empty()) {
            headers.push(("Idempotency-Key".to_owned(), key.to_owned()));
        }
        let response: ResponseBody = self
            .json_request(
                "/api/webrtc/redeem-session",
                reqwest::Method::POST,
                Some(&RequestBody {
                    session_id,
                    qr_bootstrap_token,
                }),
                &anonymous_session(),
                "",
                Some(headers),
            )
            .await?;
        Ok(RedeemedSessionLease {
            session_id: response.session_id,
            session_token: response.session_token,
            turn_admission_lease: TurnAdmissionLease {
                token: response.turn_admission_token,
                expires_in: response.expires_in.min(60),
            },
            expires_in: response.expires_in,
            signaling_server_origin: response.signaling_server_origin,
            initiator_device_id: response.initiator_device_id,
            initiator_protocol_signing_algorithm: response.initiator_protocol_signing_algorithm,
            initiator_protocol_public_key_fingerprint: response
                .initiator_protocol_public_key_fingerprint,
        })
    }

    pub async fn fetch_turn_credentials(
        &self,
        turn_admission_token: &str,
    ) -> Result<TurnCredentials> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ResponseBody {
            username: String,
            password: String,
            ttl: i64,
            uris: Option<Vec<String>>,
            expires_at: Option<i64>,
            mode: Option<String>,
        }

        let response: ResponseBody = self
            .json_request(
                "/api/turn/credentials",
                reqwest::Method::GET,
                Option::<&()>::None,
                &anonymous_session(),
                "",
                Some(vec![(
                    "X-SkyBridge-Turn-Admission".to_owned(),
                    turn_admission_token.trim().to_owned(),
                )]),
            )
            .await?;

        Ok(TurnCredentials {
            username: response.username,
            password: response.password,
            ttl: response.ttl,
            uris: response.uris.unwrap_or_default(),
            expires_at: response.expires_at.map(seconds_to_time).transpose()?,
            mode: response.mode,
        })
    }

    pub async fn enroll_first_device(
        &self,
        auth_session: &AuthSession,
        tenant_id: &str,
        binding: &ProtocolIdentityBinding,
        invite_token: &str,
        device_name: &str,
    ) -> Result<RegisteredDevice> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            invite_token: &'a str,
            device_id: &'a str,
            protocol_signing_algorithm: ProtocolSigningAlgorithm,
            protocol_public_key_fingerprint: &'a str,
            protocol_public_key_bytes: String,
            client_version: &'a str,
            protocol_version: &'a str,
            device_name: &'a str,
        }

        #[derive(Deserialize)]
        struct ResponseBody {
            enrolled: bool,
            device: RegisteredDevice,
        }

        let response: ResponseBody = self
            .json_request(
                "/api/devices/enroll/first",
                reqwest::Method::POST,
                Some(&RequestBody {
                    invite_token,
                    device_id: &binding.device_id,
                    protocol_signing_algorithm: binding.protocol_signing_algorithm,
                    protocol_public_key_fingerprint: &binding.protocol_public_key_fingerprint,
                    protocol_public_key_bytes: STANDARD.encode(&binding.protocol_public_key_bytes),
                    client_version: &self.client_version,
                    protocol_version: &self.protocol_version,
                    device_name,
                }),
                auth_session,
                tenant_id,
                None,
            )
            .await?;
        if !response.enrolled {
            bail!("device_not_enrolled");
        }
        Ok(response.device)
    }

    pub async fn confirm_device_enrollment(
        &self,
        auth_session: &AuthSession,
        tenant_id: &str,
        approver_binding: &ProtocolIdentityBinding,
        pending_binding: &ProtocolIdentityBinding,
        device_name: &str,
    ) -> Result<RegisteredDevice> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct RequestBody<'a> {
            device_id: &'a str,
            protocol_signing_algorithm: ProtocolSigningAlgorithm,
            protocol_public_key_fingerprint: &'a str,
            client_version: &'a str,
            protocol_version: &'a str,
            pending_device_id: &'a str,
            pending_protocol_signing_algorithm: ProtocolSigningAlgorithm,
            pending_protocol_public_key_fingerprint: &'a str,
            device_name: &'a str,
        }

        #[derive(Deserialize)]
        struct ResponseBody {
            confirmed: bool,
            device: RegisteredDevice,
        }

        let response: ResponseBody = self
            .json_request(
                "/api/devices/enroll/confirm",
                reqwest::Method::POST,
                Some(&RequestBody {
                    device_id: &approver_binding.device_id,
                    protocol_signing_algorithm: approver_binding.protocol_signing_algorithm,
                    protocol_public_key_fingerprint: &approver_binding
                        .protocol_public_key_fingerprint,
                    client_version: &self.client_version,
                    protocol_version: &self.protocol_version,
                    pending_device_id: &pending_binding.device_id,
                    pending_protocol_signing_algorithm: pending_binding.protocol_signing_algorithm,
                    pending_protocol_public_key_fingerprint: &pending_binding
                        .protocol_public_key_fingerprint,
                    device_name,
                }),
                auth_session,
                tenant_id,
                None,
            )
            .await?;
        if !response.confirmed {
            bail!("device_not_confirmed");
        }
        Ok(response.device)
    }

    pub fn websocket_url(
        &self,
        signaling_server_origin: &str,
        session_id: &str,
        session_token: &str,
    ) -> Result<SignalingWebSocketRequest> {
        let canonical_origin = self.canonical_signaling_origin(signaling_server_origin)?;
        let mut url = url::Url::parse(&canonical_origin)?;
        let websocket_scheme = match url.scheme() {
            "https" => "wss",
            "http" => "ws",
            "wss" => "wss",
            "ws" => "ws",
            _ => bail!("invalid signaling websocket origin"),
        };
        url.set_scheme(websocket_scheme)
            .map_err(|_| anyhow!("invalid signaling websocket origin"))?;
        url.set_path("/ws");
        url.query_pairs_mut()
            .append_pair("shard", session_id)
            .append_pair("cv", &self.client_version)
            .append_pair("pv", &self.protocol_version);
        SignalingWebSocketRequest::new(url, session_id, session_token)
    }

    async fn json_request<RequestBody, ResponseBody>(
        &self,
        path: &str,
        method: reqwest::Method,
        body: Option<&RequestBody>,
        auth_session: &AuthSession,
        tenant_id: &str,
        extra_headers: Option<Vec<(String, String)>>,
    ) -> Result<ResponseBody>
    where
        RequestBody: Serialize + ?Sized,
        ResponseBody: for<'de> Deserialize<'de>,
    {
        let method_label = method.as_str().to_owned();
        let url = format!("{}{}", self.base_url, path);
        let mut request = self
            .client
            .request(method, url)
            .header("Accept", "application/json")
            .header("X-API-Key", &self.api_key);
        if !tenant_id.trim().is_empty() {
            request = request.header("X-SkyBridge-Tenant-Id", tenant_id.trim());
        }
        if !auth_session.access_token.trim().is_empty() {
            request = request.header(
                "Authorization",
                format!("Bearer {}", auth_session.access_token),
            );
        }
        if let Some(extra_headers) = extra_headers {
            for (field, value) in extra_headers {
                request = request.header(field, value);
            }
        }
        if let Some(body) = body {
            request = request.json(body);
        }
        let response = request.send().await.map_err(|error| {
            let transport = transport_error("control plane", "request", &error);
            anyhow!(
                "control-plane {method_label} {} failed: {transport}",
                safe_path(path)
            )
        })?;
        decode_json_response(response, "control plane", "request")
            .await
            .map_err(|error| {
                anyhow!(
                    "control-plane {method_label} {} failed: {error}",
                    safe_path(path)
                )
            })
    }

    async fn raw_json_request<RequestBody>(
        &self,
        path: &str,
        method: reqwest::Method,
        body: Option<&RequestBody>,
        extra_headers: Option<Vec<(String, String)>>,
    ) -> Result<ControlPlaneRawProbe>
    where
        RequestBody: Serialize + ?Sized,
    {
        let method_label = method.as_str().to_owned();
        let url = format!("{}{}", self.base_url, path);
        let mut request = self
            .client
            .request(method, url)
            .header("Accept", "application/json")
            .header("X-API-Key", &self.api_key);
        if let Some(extra_headers) = extra_headers {
            for (field, value) in extra_headers {
                request = request.header(field, value);
            }
        }
        if let Some(body) = body {
            request = request.json(body);
        }

        let response = request.send().await.map_err(|error| {
            let transport = transport_error("control plane", "diagnostic probe", &error);
            anyhow!(
                "control-plane {method_label} {} probe failed: {transport}",
                safe_path(path)
            )
        })?;
        let inspected = inspect_json_response(response, "control plane", "diagnostic probe")
            .await
            .map_err(|error| {
                anyhow!(
                    "control-plane {method_label} {} probe failed: {error}",
                    safe_path(path)
                )
            })?;
        Ok(ControlPlaneRawProbe {
            status_code: inspected.status.as_u16(),
            success: inspected.status.is_success(),
            body: inspected.body,
        })
    }
}

fn safe_path(path: &str) -> &str {
    if path.starts_with('/')
        && path.len() <= 256
        && !path.contains('?')
        && !path.contains('#')
        && path
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"/-_.".contains(&byte))
    {
        path
    } else {
        "<redacted-path>"
    }
}

fn millis_to_time(value: i64) -> Result<OffsetDateTime> {
    let seconds = value / 1_000;
    let millis = value % 1_000;
    Ok(OffsetDateTime::from_unix_timestamp(seconds)? + time::Duration::milliseconds(millis))
}

fn seconds_to_time(value: i64) -> Result<OffsetDateTime> {
    OffsetDateTime::from_unix_timestamp(value).map_err(Into::into)
}

fn anonymous_session() -> AuthSession {
    AuthSession {
        access_token: String::new(),
        refresh_token: None,
        user_identifier: String::new(),
        nebula_id: None,
        display_name: String::new(),
        issued_at: OffsetDateTime::now_utc(),
    }
}

pub fn make_room_session_bootstrap_idempotency_key(
    session_id: &str,
    binding: &ProtocolIdentityBinding,
) -> String {
    base64_url_encode(
        format!(
            "redeem:{}:{}:{}",
            session_id, binding.device_id, binding.protocol_public_key_fingerprint
        )
        .as_bytes(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    async fn spawn_one_shot_response(status: &str, body: String) -> Result<String> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = listener.local_addr()?;
        let status = status.to_owned();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept mock request");
            let mut request = vec![0_u8; 8192];
            let _ = stream.read(&mut request).await.expect("read mock request");
            let response = format!(
                "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            );
            stream
                .write_all(response.as_bytes())
                .await
                .expect("write mock response");
        });
        Ok(format!("http://{address}"))
    }

    fn loopback_client(base_url: &str) -> Result<SignalServerClient> {
        SignalServerClient::new_with_transport_policy(
            base_url,
            "api-key-secret",
            "test-client",
            "1",
            OriginTransportPolicy::AllowPlaintextLoopback,
        )
    }

    #[test]
    fn signal_server_origin_is_secure_by_default_and_plaintext_is_loopback_only() {
        assert!(SignalServerClient::new("http://127.0.0.1:8080", "key", "client", "1").is_err());
        assert!(
            SignalServerClient::new_with_transport_policy(
                "http://127.0.0.1:8080",
                "key",
                "client",
                "1",
                OriginTransportPolicy::AllowPlaintextLoopback,
            )
            .is_ok()
        );
        assert!(
            SignalServerClient::new_with_transport_policy(
                "http://192.168.1.20:8080",
                "key",
                "client",
                "1",
                OriginTransportPolicy::AllowPlaintextLoopback,
            )
            .is_err()
        );
    }

    #[test]
    fn credential_debug_output_is_redacted() {
        let credentials = TurnCredentials {
            username: "turn-user-secret".to_owned(),
            password: "turn-password-secret".to_owned(),
            ttl: 60,
            uris: vec!["turns:turn.example:5349".to_owned()],
            expires_at: None,
            mode: Some("relay".to_owned()),
        };
        let lease = SessionLease {
            session_id: "session-1".to_owned(),
            session_token: "session-token-secret".to_owned(),
            qr_bootstrap_token: "qr-bootstrap-secret".to_owned(),
            turn_admission_lease: TurnAdmissionLease {
                token: "turn-admission-secret".to_owned(),
                expires_in: 60,
            },
            expires_in: 60,
            signaling_server_origin: "https://signal.example".to_owned(),
        };
        let client = SignalServerClient::new(
            "https://signal.example",
            "api-key-secret",
            "test-client",
            "1",
        )
        .expect("secure client");
        let debug = format!("{credentials:?}\n{lease:?}\n{client:?}");
        for secret in [
            "turn-user-secret",
            "turn-password-secret",
            "session-token-secret",
            "qr-bootstrap-secret",
            "turn-admission-secret",
            "api-key-secret",
        ] {
            assert!(!debug.contains(secret), "debug output leaked {secret}");
        }
    }

    #[tokio::test]
    async fn rejected_control_plane_body_is_bounded_and_not_echoed() -> Result<()> {
        let secret = "response-token-secret";
        let padding = "x".repeat(crate::external_http::MAX_EXTERNAL_ERROR_BODY_BYTES * 2);
        let base_url = spawn_one_shot_response(
            "401 Unauthorized",
            serde_json::json!({
                "error": "invalid_session",
                "sessionToken": secret,
                "message": padding,
            })
            .to_string(),
        )
        .await?;
        let error = loopback_client(&base_url)?
            .probe_health()
            .await
            .expect_err("rejected health probe must fail");
        let message = format!("{error:#}");
        assert!(message.contains("HTTP 401"));
        assert!(message.contains("body_truncated=true"));
        assert!(!message.contains(secret));
        assert!(!message.contains(&padding));
        Ok(())
    }

    #[tokio::test]
    async fn diagnostic_probe_redacts_credentials_and_rejects_invalid_success_json() -> Result<()> {
        let base_url = spawn_one_shot_response(
            "401 Unauthorized",
            serde_json::json!({
                "error": "invalid_session",
                "sessionToken": "response-token-secret",
                "rejectReason": "expired",
            })
            .to_string(),
        )
        .await?;
        let probe = loopback_client(&base_url)?
            .probe_json_endpoint("/health")
            .await?;
        assert!(!probe.success);
        assert!(probe.body.get("sessionToken").is_none());
        assert_eq!(probe.body["rejectReason"], "expired");

        let invalid_json_url =
            spawn_one_shot_response("200 OK", "not-json-response".to_owned()).await?;
        let error = loopback_client(&invalid_json_url)?
            .probe_json_endpoint("/health")
            .await
            .expect_err("2xx non-JSON diagnostic response must fail closed");
        assert!(error.to_string().contains("invalid JSON"));
        Ok(())
    }
}
