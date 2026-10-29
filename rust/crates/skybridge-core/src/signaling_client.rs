use std::collections::VecDeque;
use std::fmt::{Debug, Formatter};
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use base64::engine::general_purpose::STANDARD as STANDARD_BASE64;
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::sync::{Mutex, Notify, mpsc, oneshot, watch};
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue, Request};
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{Error as WebSocketError, protocol::Message, protocol::WebSocketConfig},
};
use uuid::Uuid;

use crate::{
    CryptoSuite, ProtocolIdentityBinding, ProtocolSigningAlgorithm, SignalingBackend,
    SignalingFailureClass, SignalingHandleId, SignalingLifecycleEvent, SignalingLifecyclePhase,
    SignalingState,
};

const MAX_SIGNALING_WEBSOCKET_MESSAGE_BYTES: usize = 512 * 1024;
const SIGNALING_WEBSOCKET_BUFFER_BYTES: usize = 16 * 1024;
// A signaling writer is fail-stop: an ambiguous timed-out send is never retried.
const SIGNALING_SINK_SEND_TIMEOUT: Duration = Duration::from_secs(5);
// Complete before the agent's 10-second incarnation effect budget so timeout
// cleanup and the authority post-check still run while the permit is held.
const SIGNALING_CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const MAX_BUFFERED_RUNTIME_EVENTS: usize = 128;
const MAX_SIGNALING_SESSION_ID_BYTES: usize = 512;
const MAX_SIGNALING_SESSION_TOKEN_BYTES: usize = 4096;
const MAX_JOIN_BOOTSTRAP_KEM_KEYS: usize = 4;
const MAX_JOIN_BOOTSTRAP_PLATFORM_BYTES: usize = 64;
const MAX_JOIN_BOOTSTRAP_OS_VERSION_BYTES: usize = 128;
const SESSION_ID_HEADER: HeaderName = HeaderName::from_static("x-skybridge-session-id");
const SESSION_TOKEN_HEADER: HeaderName = HeaderName::from_static("x-skybridge-session");

#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct WebRtcSignalingEnvelope {
    pub session_id: String,
    pub from: String,
    pub to: Option<String>,
    pub kind: WebRtcMessageType,
    pub payload: Option<Box<WebRtcSignalingPayload>>,
    pub auth_token: Option<String>,
    pub sent_at: f64,
}

impl Debug for WebRtcSignalingEnvelope {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("WebRtcSignalingEnvelope")
            .field("session_id", &"<redacted>")
            .field("from", &"<redacted>")
            .field("to_present", &self.to.is_some())
            .field("kind", &self.kind)
            .field("payload_present", &self.payload.is_some())
            .field(
                "auth_token",
                &self.auth_token.as_ref().map(|_| "<redacted>"),
            )
            .field("sent_at", &self.sent_at)
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WebRtcMessageType {
    Join,
    Offer,
    Answer,
    IceCandidate,
    Leave,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BootstrapKemPublicKey {
    pub suite_wire_id: u16,
    #[serde(with = "base64_bytes")]
    pub public_key: Vec<u8>,
}

impl Debug for BootstrapKemPublicKey {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("BootstrapKemPublicKey")
            .field("suite_wire_id", &self.suite_wire_id)
            .field("public_key", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct WebRtcJoinBootstrap {
    pub protocol_signing_algorithm: ProtocolSigningAlgorithm,
    pub protocol_public_key_fingerprint: String,
    pub protocol_public_key_bytes: Vec<u8>,
    pub kem_public_keys: Vec<BootstrapKemPublicKey>,
    pub platform: Option<String>,
    pub os_version: Option<String>,
}

impl Debug for WebRtcJoinBootstrap {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("WebRtcJoinBootstrap")
            .field(
                "protocol_signing_algorithm",
                &self.protocol_signing_algorithm,
            )
            .field("protocol_public_key_fingerprint", &"<redacted>")
            .field("protocol_public_key_bytes", &"<redacted>")
            .field("kem_public_keys", &self.kem_public_keys)
            .field("platform", &self.platform)
            .field("os_version", &self.os_version)
            .finish()
    }
}

impl WebRtcJoinBootstrap {
    pub fn new(
        device_id: &str,
        protocol_signing_algorithm: ProtocolSigningAlgorithm,
        protocol_public_key_fingerprint: String,
        protocol_public_key_bytes: Vec<u8>,
        kem_public_keys: Vec<BootstrapKemPublicKey>,
        platform: Option<String>,
        os_version: Option<String>,
    ) -> Result<Self> {
        let binding = ProtocolIdentityBinding::new(
            device_id.to_owned(),
            protocol_signing_algorithm,
            protocol_public_key_bytes,
            Some(protocol_public_key_fingerprint),
        )?;
        if binding.device_id != device_id {
            bail!("join bootstrap device id is not canonical");
        }
        let computed_fingerprint = ProtocolIdentityBinding::compute_fingerprint(
            binding.protocol_signing_algorithm,
            &binding.protocol_public_key_bytes,
        );
        if binding.protocol_public_key_fingerprint != computed_fingerprint {
            bail!("join bootstrap protocol public key fingerprint mismatch");
        }
        validate_bootstrap_kem_keys(protocol_signing_algorithm, &kem_public_keys)?;
        validate_optional_bootstrap_text(
            "join bootstrap platform",
            platform.as_deref(),
            MAX_JOIN_BOOTSTRAP_PLATFORM_BYTES,
        )?;
        validate_optional_bootstrap_text(
            "join bootstrap OS version",
            os_version.as_deref(),
            MAX_JOIN_BOOTSTRAP_OS_VERSION_BYTES,
        )?;
        Ok(Self {
            protocol_signing_algorithm: binding.protocol_signing_algorithm,
            protocol_public_key_fingerprint: binding.protocol_public_key_fingerprint,
            protocol_public_key_bytes: binding.protocol_public_key_bytes,
            kem_public_keys,
            platform,
            os_version,
        })
    }
}

#[derive(Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WebRtcSignalingPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdp: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidate: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdp_mid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdp_m_line_index: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol_signing_algorithm: Option<ProtocolSigningAlgorithm>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub protocol_public_key_fingerprint: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "optional_base64_bytes"
    )]
    pub protocol_public_key_bytes: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kem_public_keys: Option<Vec<BootstrapKemPublicKey>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
}

impl Debug for WebRtcSignalingPayload {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("WebRtcSignalingPayload")
            .field("sdp_present", &self.sdp.is_some())
            .field("candidate_present", &self.candidate.is_some())
            .field("sdp_mid_present", &self.sdp_mid.is_some())
            .field("sdp_m_line_index", &self.sdp_m_line_index)
            .field(
                "join_protocol_signing_algorithm",
                &self.protocol_signing_algorithm,
            )
            .field(
                "join_protocol_identity_present",
                &self.protocol_public_key_bytes.is_some(),
            )
            .field(
                "join_kem_public_key_count",
                &self.kem_public_keys.as_ref().map(Vec::len),
            )
            .field("join_platform", &self.platform)
            .field("join_os_version", &self.os_version)
            .finish()
    }
}

impl WebRtcSignalingPayload {
    pub fn from_join_bootstrap(bootstrap: WebRtcJoinBootstrap) -> Self {
        Self {
            protocol_signing_algorithm: Some(bootstrap.protocol_signing_algorithm),
            protocol_public_key_fingerprint: Some(bootstrap.protocol_public_key_fingerprint),
            protocol_public_key_bytes: Some(bootstrap.protocol_public_key_bytes),
            kem_public_keys: Some(bootstrap.kem_public_keys),
            platform: bootstrap.platform,
            os_version: bootstrap.os_version,
            ..Self::default()
        }
    }

    pub fn validated_join_bootstrap(
        &self,
        remote_device_id: &str,
    ) -> Result<Option<WebRtcJoinBootstrap>> {
        if !self.has_join_bootstrap_fields() {
            return Ok(None);
        }
        let protocol_signing_algorithm = self
            .protocol_signing_algorithm
            .ok_or_else(|| anyhow!("join bootstrap is missing protocol signing algorithm"))?;
        let protocol_public_key_fingerprint = self
            .protocol_public_key_fingerprint
            .clone()
            .ok_or_else(|| anyhow!("join bootstrap is missing protocol public key fingerprint"))?;
        let protocol_public_key_bytes = self
            .protocol_public_key_bytes
            .clone()
            .ok_or_else(|| anyhow!("join bootstrap is missing protocol public key bytes"))?;
        let kem_public_keys = self.kem_public_keys.clone().unwrap_or_default();
        WebRtcJoinBootstrap::new(
            remote_device_id,
            protocol_signing_algorithm,
            protocol_public_key_fingerprint,
            protocol_public_key_bytes,
            kem_public_keys,
            self.platform.clone(),
            self.os_version.clone(),
        )
        .map(Some)
    }

    pub fn validate_for_message_type(
        &self,
        message_type: WebRtcMessageType,
        sender_device_id: &str,
    ) -> Result<Option<WebRtcJoinBootstrap>> {
        let has_negotiation_fields = self.sdp.is_some()
            || self.candidate.is_some()
            || self.sdp_mid.is_some()
            || self.sdp_m_line_index.is_some();
        match message_type {
            WebRtcMessageType::Join => {
                if has_negotiation_fields {
                    bail!("join signaling payload contains SDP or ICE fields");
                }
                self.validated_join_bootstrap(sender_device_id)
            }
            WebRtcMessageType::Offer
            | WebRtcMessageType::Answer
            | WebRtcMessageType::IceCandidate => {
                if self.has_join_bootstrap_fields() {
                    bail!("join bootstrap fields are forbidden on SDP or ICE signaling");
                }
                Ok(None)
            }
            WebRtcMessageType::Leave => {
                bail!("leave signaling envelopes must not contain a payload")
            }
        }
    }

    fn has_join_bootstrap_fields(&self) -> bool {
        self.protocol_signing_algorithm.is_some()
            || self.protocol_public_key_fingerprint.is_some()
            || self.protocol_public_key_bytes.is_some()
            || self.kem_public_keys.is_some()
            || self.platform.is_some()
            || self.os_version.is_some()
    }
}

fn validate_optional_bootstrap_text(
    field: &str,
    value: Option<&str>,
    maximum_bytes: usize,
) -> Result<()> {
    let Some(value) = value else {
        return Ok(());
    };
    if value.is_empty()
        || value.trim() != value
        || value.len() > maximum_bytes
        || value.chars().any(char::is_control)
    {
        bail!("{field} is invalid");
    }
    Ok(())
}

fn validate_bootstrap_kem_keys(
    signing_algorithm: ProtocolSigningAlgorithm,
    keys: &[BootstrapKemPublicKey],
) -> Result<()> {
    if signing_algorithm == ProtocolSigningAlgorithm::Ed25519 {
        if !keys.is_empty() {
            bail!("classic join bootstrap must not advertise PQC KEM public keys");
        }
        return Ok(());
    }
    if keys.is_empty() {
        bail!("PQC join bootstrap requires at least one KEM public key");
    }
    if keys.len() > MAX_JOIN_BOOTSTRAP_KEM_KEYS {
        bail!("join bootstrap advertises too many KEM public keys");
    }
    let mut observed_suites = std::collections::BTreeSet::new();
    for key in keys {
        let suite = CryptoSuite::from_wire_id(key.suite_wire_id);
        if !suite.is_known() || !suite.is_pqc() {
            bail!("join bootstrap contains an unsupported KEM suite");
        }
        if !observed_suites.insert(suite.wire_id) {
            bail!("join bootstrap contains a duplicate KEM suite");
        }
        let expected_bytes = match suite.canonical_kem_suite().wire_id {
            0x0001 => crate::pqc::XWING_PUBLIC_KEY_BYTES,
            0x0101 => crate::pqc::MLKEM768_PUBLIC_KEY_BYTES,
            #[cfg(feature = "q-periapt")]
            0x0011 => crate::pqc::XWING_PUBLIC_KEY_BYTES,
            _ => bail!("join bootstrap KEM suite is not enabled in this build"),
        };
        if key.public_key.len() != expected_bytes {
            bail!(
                "join bootstrap KEM public key length mismatch for suite {}",
                key.suite_wire_id
            );
        }
    }
    Ok(())
}

mod base64_bytes {
    use super::{STANDARD_BASE64, Serialize};
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer, de::Error as _};

    pub fn serialize<S>(value: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        STANDARD_BASE64.encode(value).serialize(serializer)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded = String::deserialize(deserializer)?;
        let decoded = STANDARD_BASE64
            .decode(encoded.as_bytes())
            .map_err(D::Error::custom)?;
        if STANDARD_BASE64.encode(&decoded) != encoded {
            return Err(D::Error::custom("non-canonical base64 encoding"));
        }
        Ok(decoded)
    }
}

mod optional_base64_bytes {
    use super::{STANDARD_BASE64, Serialize};
    use base64::Engine;
    use serde::{Deserialize, Deserializer, Serializer, de::Error as _};

    pub fn serialize<S>(value: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        value
            .as_ref()
            .map(|bytes| STANDARD_BASE64.encode(bytes))
            .serialize(serializer)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let Some(encoded) = Option::<String>::deserialize(deserializer)? else {
            return Ok(None);
        };
        let decoded = STANDARD_BASE64
            .decode(encoded.as_bytes())
            .map_err(D::Error::custom)?;
        if STANDARD_BASE64.encode(&decoded) != encoded {
            return Err(D::Error::custom("non-canonical base64 encoding"));
        }
        Ok(Some(decoded))
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignalingServerFrame {
    #[serde(rename = "type")]
    pub kind: String,
    pub error: Option<String>,
    pub session_id: Option<String>,
    pub what: Option<String>,
}

impl Debug for SignalingServerFrame {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SignalingServerFrame")
            .field("kind", &sanitize_server_error_code(&self.kind))
            .field(
                "error",
                &self.error.as_deref().map(sanitize_server_error_code),
            )
            .field("session_id_present", &self.session_id.is_some())
            .field(
                "what",
                &self.what.as_deref().map(sanitize_server_error_code),
            )
            .finish()
    }
}

/// Credential-bearing WebSocket handshake request. The identity and token are stored only in
/// sensitive authentication headers and are never inserted into the request URL or rendered by
/// `Debug`.
#[derive(Clone)]
pub struct SignalingWebSocketRequest {
    endpoint: url::Url,
    session_id: HeaderValue,
    session_token: HeaderValue,
}

impl SignalingWebSocketRequest {
    pub(crate) fn new(endpoint: url::Url, session_id: &str, session_token: &str) -> Result<Self> {
        if endpoint.query_pairs().any(|(key, _)| {
            matches!(
                key.to_ascii_lowercase().as_ref(),
                "st" | "session_token" | "sessiontoken" | "token" | "access_token"
            )
        }) {
            bail!("signaling websocket endpoint must not contain a session token");
        }
        let session_id = session_id.trim();
        let session_token = session_token.trim();
        if session_id.is_empty() {
            bail!("missing signaling session id");
        }
        if session_id.len() > MAX_SIGNALING_SESSION_ID_BYTES {
            bail!("signaling session id exceeds handshake header limit");
        }
        if session_token.is_empty() {
            bail!("missing signaling session token");
        }
        if session_token.len() > MAX_SIGNALING_SESSION_TOKEN_BYTES {
            bail!("signaling session token exceeds handshake header limit");
        }
        let mut session_id = HeaderValue::from_str(session_id)
            .map_err(|_| anyhow!("invalid signaling session id for WebSocket authentication"))?;
        let mut session_token = HeaderValue::from_str(session_token)
            .map_err(|_| anyhow!("invalid signaling session token for WebSocket authentication"))?;
        session_id.set_sensitive(true);
        session_token.set_sensitive(true);
        Ok(Self {
            endpoint,
            session_id,
            session_token,
        })
    }

    fn into_http_request(self) -> Result<Request<()>> {
        let mut request = self
            .endpoint
            .as_str()
            .into_client_request()
            .map_err(|_| anyhow!("invalid signaling websocket handshake request"))?;
        request
            .headers_mut()
            .insert(SESSION_ID_HEADER, self.session_id);
        request
            .headers_mut()
            .insert(SESSION_TOKEN_HEADER, self.session_token);
        Ok(request)
    }

    fn authenticates_session(&self, session_id: &str) -> bool {
        self.session_id.as_bytes() == session_id.as_bytes()
    }
}

impl Debug for SignalingWebSocketRequest {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SignalingWebSocketRequest")
            .field(
                "endpoint_origin",
                &self.endpoint.origin().ascii_serialization(),
            )
            .field("session_authentication", &"<redacted>")
            .finish()
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SignalingConnectError {
    #[error("signaling websocket connection timed out")]
    TimedOut,
    #[error("signaling websocket handshake was rejected (HTTP {status})")]
    HandshakeRejected { status: u16 },
    #[error("signaling websocket connection failed ({failure_class})")]
    Transport { failure_class: &'static str },
}

struct OutboundSignalingRequest {
    envelope: WebRtcSignalingEnvelope,
    completion: oneshot::Sender<Result<()>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SignalingEventAdmission {
    Queued,
    QueueFull,
    RuntimeReceiverClosed,
    TerminalAlreadySelected,
}

#[derive(Debug)]
struct SignalingCoordinatorState {
    terminal_selected: bool,
    runtime_receiver_open: bool,
    pending_events: VecDeque<SignalingRuntimeEvent>,
}

#[derive(Debug)]
struct SignalingConnectionCoordinator {
    state: Arc<Mutex<SignalingState>>,
    coordination: Mutex<SignalingCoordinatorState>,
    event_available: Notify,
    cancellation: watch::Sender<bool>,
    max_buffered_events: usize,
}

impl SignalingConnectionCoordinator {
    fn new(
        state: Arc<Mutex<SignalingState>>,
        max_buffered_events: usize,
    ) -> (Arc<Self>, watch::Receiver<bool>) {
        assert!(
            max_buffered_events > 0,
            "signaling runtime event buffer must be non-zero"
        );
        let (cancellation, cancellation_receiver) = watch::channel(false);
        (
            Arc::new(Self {
                state,
                coordination: Mutex::new(SignalingCoordinatorState {
                    terminal_selected: false,
                    runtime_receiver_open: true,
                    pending_events: VecDeque::with_capacity(max_buffered_events + 1),
                }),
                event_available: Notify::new(),
                cancellation,
                max_buffered_events,
            }),
            cancellation_receiver,
        )
    }

    async fn publish_lifecycle(&self, event: SignalingLifecycleEvent) -> SignalingEventAdmission {
        let is_terminal = is_terminal_lifecycle_phase(event.phase);
        let mut coordination = self.coordination.lock().await;
        if coordination.terminal_selected {
            return SignalingEventAdmission::TerminalAlreadySelected;
        }
        if !is_terminal && coordination.pending_events.len() >= self.max_buffered_events {
            return SignalingEventAdmission::QueueFull;
        }

        {
            let mut state = self.state.lock().await;
            state.apply_lifecycle_event(event.clone());
        }
        if is_terminal {
            coordination.terminal_selected = true;
            self.cancellation.send_replace(true);
        }
        if !coordination.runtime_receiver_open {
            return SignalingEventAdmission::RuntimeReceiverClosed;
        }

        // One extra slot is reserved exclusively for the first terminal event. This keeps
        // memory bounded while ensuring public-event backpressure cannot block termination.
        coordination
            .pending_events
            .push_back(SignalingRuntimeEvent::Lifecycle(event));
        drop(coordination);
        self.event_available.notify_one();
        SignalingEventAdmission::Queued
    }

    async fn publish_inbound(&self, inbound: InboundMessage) -> SignalingEventAdmission {
        let mut coordination = self.coordination.lock().await;
        if coordination.terminal_selected {
            return SignalingEventAdmission::TerminalAlreadySelected;
        }
        if coordination.pending_events.len() >= self.max_buffered_events {
            return SignalingEventAdmission::QueueFull;
        }
        if !coordination.runtime_receiver_open {
            return SignalingEventAdmission::RuntimeReceiverClosed;
        }
        coordination
            .pending_events
            .push_back(SignalingRuntimeEvent::Inbound(inbound));
        drop(coordination);
        self.event_available.notify_one();
        SignalingEventAdmission::Queued
    }

    async fn next_event_for_publication(&self) -> Option<SignalingRuntimeEvent> {
        loop {
            let notified = self.event_available.notified();
            {
                let mut coordination = self.coordination.lock().await;
                if let Some(event) = coordination.pending_events.pop_front() {
                    return Some(event);
                }
                if coordination.terminal_selected || !coordination.runtime_receiver_open {
                    return None;
                }
            }
            notified.await;
        }
    }

    async fn mark_runtime_receiver_dropped(&self, handle_id: &SignalingHandleId) {
        let mut coordination = self.coordination.lock().await;
        coordination.runtime_receiver_open = false;
        coordination.pending_events.clear();
        if !coordination.terminal_selected {
            let event = SignalingLifecycleEvent {
                handle_id: handle_id.clone(),
                phase: SignalingLifecyclePhase::Failed,
                server_frame_type: None,
                failure_class: Some(SignalingFailureClass::TransientNetwork),
                error_description: Some("runtime_event_receiver_dropped".to_owned()),
                occurred_at: time::OffsetDateTime::now_utc(),
            };
            {
                let mut state = self.state.lock().await;
                state.apply_lifecycle_event(event);
            }
            coordination.terminal_selected = true;
            self.cancellation.send_replace(true);
        }
        drop(coordination);
        self.event_available.notify_waiters();
    }
}

fn is_terminal_lifecycle_phase(phase: SignalingLifecyclePhase) -> bool {
    matches!(
        phase,
        SignalingLifecyclePhase::Closed | SignalingLifecyclePhase::Failed
    )
}

#[derive(Debug)]
enum SignalingSinkSendFailure {
    TimedOut,
    Transport(WebSocketError),
}

enum SignalingWriterSendOutcome {
    CallerCancelled,
    ConnectionTerminated,
    Completed(std::result::Result<(), SignalingSinkSendFailure>),
}

impl SignalingSinkSendFailure {
    fn failure_class(&self) -> SignalingFailureClass {
        match self {
            Self::TimedOut => SignalingFailureClass::TransientNetwork,
            Self::Transport(error) => classify_websocket_error(error),
        }
    }

    fn error_code(&self) -> &'static str {
        match self {
            Self::TimedOut => "send_timeout",
            Self::Transport(error) => websocket_runtime_error_code(error),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum InboundMessage {
    Envelope(WebRtcSignalingEnvelope),
    ServerFrame(SignalingServerFrame),
    Unknown,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SignalingRuntimeEvent {
    Lifecycle(SignalingLifecycleEvent),
    Inbound(InboundMessage),
}

pub struct SignalingConnection {
    outgoing: mpsc::Sender<OutboundSignalingRequest>,
    runtime_events: mpsc::Receiver<SignalingRuntimeEvent>,
    state: Arc<Mutex<SignalingState>>,
}

impl Debug for SignalingConnection {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SignalingConnection")
            .field("outgoing_closed", &self.outgoing.is_closed())
            .field("runtime_event_stream", &"<redacted>")
            .field("state", &"<redacted>")
            .finish()
    }
}

impl SignalingConnection {
    pub async fn connect(request: SignalingWebSocketRequest, session_id: &str) -> Result<Self> {
        Self::connect_with_timeout(request, session_id, SIGNALING_CONNECT_TIMEOUT).await
    }

    async fn connect_with_timeout(
        request: SignalingWebSocketRequest,
        session_id: &str,
        connect_timeout: Duration,
    ) -> Result<Self> {
        let session_id = session_id.trim();
        if !request.authenticates_session(session_id) {
            bail!("signaling_connection_session_mismatch");
        }
        let request = request.into_http_request()?;
        let (ws_stream, _) = timeout(
            connect_timeout,
            connect_async_with_config(request, Some(signaling_websocket_config()), false),
        )
        .await
        .map_err(|_| anyhow::Error::new(SignalingConnectError::TimedOut))?
        .map_err(|error| anyhow::Error::new(classify_connect_error(&error)))?;
        let (mut sink, mut stream) = ws_stream.split();

        let generation = 1_u32;
        let handle_id = SignalingHandleId {
            session_id: session_id.to_owned(),
            backend: SignalingBackend::Native,
            generation,
        };
        let state = Arc::new(Mutex::new(SignalingState::default()));
        {
            let mut state_guard = state.lock().await;
            state_guard.seed(
                session_id.to_owned(),
                generation,
                handle_id.clone(),
                crate::SignalingSessionHealth::Healthy,
                SignalingLifecyclePhase::Connecting,
            );
        }

        let (out_tx, mut out_rx) = mpsc::channel::<OutboundSignalingRequest>(32);
        let (event_tx, event_rx) =
            mpsc::channel::<SignalingRuntimeEvent>(MAX_BUFFERED_RUNTIME_EVENTS);
        let (coordinator, cancellation) =
            SignalingConnectionCoordinator::new(Arc::clone(&state), MAX_BUFFERED_RUNTIME_EVENTS);

        tokio::spawn({
            let coordinator = Arc::clone(&coordinator);
            let handle_id = handle_id.clone();
            publish_runtime_events(coordinator, event_tx, handle_id)
        });

        for event in [
            SignalingLifecycleEvent::new(handle_id.clone(), SignalingLifecyclePhase::Connecting),
            SignalingLifecycleEvent::new(handle_id.clone(), SignalingLifecyclePhase::SocketOpen),
        ] {
            if coordinator.publish_lifecycle(event).await != SignalingEventAdmission::Queued {
                bail!("signaling_runtime_event_initialization_failed");
            }
        }

        tokio::spawn({
            let coordinator = Arc::clone(&coordinator);
            let handle_id = handle_id.clone();
            let mut cancellation = cancellation.clone();
            async move {
                loop {
                    let request = tokio::select! {
                        biased;
                        _ = wait_for_signaling_cancellation(&mut cancellation) => {
                            close_and_fail_pending_outbound_requests(
                                &mut out_rx,
                                "signaling_connection_terminated",
                            );
                            break;
                        }
                        request = out_rx.recv() => request,
                    };
                    let Some(request) = request else {
                        publish_signaling_terminal(
                            &coordinator,
                            SignalingLifecycleEvent {
                                handle_id: handle_id.clone(),
                                phase: SignalingLifecyclePhase::Closed,
                                server_frame_type: None,
                                failure_class: Some(SignalingFailureClass::TransientNetwork),
                                error_description: Some(
                                    "signaling_connection_owner_dropped".to_owned(),
                                ),
                                occurred_at: time::OffsetDateTime::now_utc(),
                            },
                        )
                        .await;
                        close_and_fail_pending_outbound_requests(
                            &mut out_rx,
                            "signaling_connection_terminated",
                        );
                        break;
                    };
                    let OutboundSignalingRequest {
                        envelope,
                        mut completion,
                    } = request;
                    if completion.is_closed() {
                        continue;
                    }
                    let body = match serde_json::to_string(&SerializableEnvelope::from(envelope)) {
                        Ok(value) => value,
                        Err(_) => {
                            publish_signaling_writer_failure(
                                &coordinator,
                                &handle_id,
                                SignalingFailureClass::ProtocolViolation,
                                "outbound_serialization_failed",
                            )
                            .await;
                            resolve_outbound_completion(
                                completion,
                                Err(anyhow!("signaling_outbound_serialization_failed")),
                                "serialization_failure",
                            );
                            close_and_fail_pending_outbound_requests(
                                &mut out_rx,
                                "signaling_writer_serialization_failed",
                            );
                            break;
                        }
                    };
                    let send_outcome = tokio::select! {
                        biased;
                        _ = wait_for_signaling_cancellation(&mut cancellation) => {
                            SignalingWriterSendOutcome::ConnectionTerminated
                        }
                        _ = completion.closed() => SignalingWriterSendOutcome::CallerCancelled,
                        result = send_signaling_message_with_timeout(
                            sink.send(Message::Text(body.into())),
                            SIGNALING_SINK_SEND_TIMEOUT,
                        ) => SignalingWriterSendOutcome::Completed(result),
                    };
                    match send_outcome {
                        SignalingWriterSendOutcome::ConnectionTerminated => {
                            resolve_outbound_completion(
                                completion,
                                Err(anyhow!("signaling_connection_terminated")),
                                "connection_terminated",
                            );
                            close_and_fail_pending_outbound_requests(
                                &mut out_rx,
                                "signaling_connection_terminated",
                            );
                            break;
                        }
                        SignalingWriterSendOutcome::CallerCancelled => {
                            // Cancellation can race a partially advanced sink send. Never
                            // reuse or retry this writer after the authority-owning caller exits.
                            publish_signaling_writer_failure(
                                &coordinator,
                                &handle_id,
                                SignalingFailureClass::TransientNetwork,
                                "send_cancelled",
                            )
                            .await;
                            close_and_fail_pending_outbound_requests(
                                &mut out_rx,
                                "signaling_writer_send_cancelled",
                            );
                            break;
                        }
                        SignalingWriterSendOutcome::Completed(Ok(())) => {
                            if completion.send(Ok(())).is_err() {
                                publish_signaling_writer_failure(
                                    &coordinator,
                                    &handle_id,
                                    SignalingFailureClass::TransientNetwork,
                                    "send_completion_dropped",
                                )
                                .await;
                                close_and_fail_pending_outbound_requests(
                                    &mut out_rx,
                                    "signaling_writer_completion_dropped",
                                );
                                break;
                            }
                        }
                        SignalingWriterSendOutcome::Completed(Err(send_failure)) => {
                            let failure_class = send_failure.failure_class();
                            let error_code = send_failure.error_code();
                            publish_signaling_writer_failure(
                                &coordinator,
                                &handle_id,
                                failure_class,
                                error_code,
                            )
                            .await;
                            resolve_outbound_completion(
                                completion,
                                Err(anyhow!("signaling_sink_{error_code}")),
                                error_code,
                            );
                            close_and_fail_pending_outbound_requests(
                                &mut out_rx,
                                "signaling_writer_failed",
                            );
                            break;
                        }
                    }
                }
            }
        });

        tokio::spawn({
            let coordinator = Arc::clone(&coordinator);
            let handle_id = handle_id.clone();
            let mut cancellation = cancellation;
            async move {
                loop {
                    let message_result = tokio::select! {
                        biased;
                        _ = wait_for_signaling_cancellation(&mut cancellation) => break,
                        message_result = stream.next() => message_result,
                    };
                    let Some(message_result) = message_result else {
                        publish_signaling_terminal(
                            &coordinator,
                            SignalingLifecycleEvent {
                                handle_id: handle_id.clone(),
                                phase: SignalingLifecyclePhase::Closed,
                                server_frame_type: None,
                                failure_class: Some(SignalingFailureClass::TransientNetwork),
                                error_description: Some("websocket_stream_ended".to_owned()),
                                occurred_at: time::OffsetDateTime::now_utc(),
                            },
                        )
                        .await;
                        break;
                    };
                    match message_result {
                        Ok(Message::Text(text)) => {
                            let inbound = match parse_inbound_message(&text) {
                                Ok(inbound) => inbound,
                                Err(error) => {
                                    publish_signaling_terminal(
                                        &coordinator,
                                        SignalingLifecycleEvent {
                                            handle_id: handle_id.clone(),
                                            phase: SignalingLifecyclePhase::Failed,
                                            server_frame_type: None,
                                            failure_class: Some(
                                                SignalingFailureClass::ProtocolViolation,
                                            ),
                                            error_description: Some(error.to_string()),
                                            occurred_at: time::OffsetDateTime::now_utc(),
                                        },
                                    )
                                    .await;
                                    break;
                                }
                            };
                            if let InboundMessage::ServerFrame(frame) = &inbound {
                                if frame.kind == "bound" {
                                    match validate_bound_server_frame(frame, &handle_id.session_id)
                                    {
                                        Ok(()) => {
                                            if !publish_nonterminal_lifecycle(
                                                &coordinator,
                                                &handle_id,
                                                SignalingLifecycleEvent {
                                                    handle_id: handle_id.clone(),
                                                    phase: SignalingLifecyclePhase::Bound,
                                                    server_frame_type: Some("bound".to_owned()),
                                                    failure_class: None,
                                                    error_description: None,
                                                    occurred_at: time::OffsetDateTime::now_utc(),
                                                },
                                            )
                                            .await
                                            {
                                                break;
                                            }
                                        }
                                        Err((failure_class, error_code)) => {
                                            publish_signaling_terminal(
                                                &coordinator,
                                                SignalingLifecycleEvent {
                                                    handle_id: handle_id.clone(),
                                                    phase: SignalingLifecyclePhase::Failed,
                                                    server_frame_type: Some("bound".to_owned()),
                                                    failure_class: Some(failure_class),
                                                    error_description: Some(error_code.to_owned()),
                                                    occurred_at: time::OffsetDateTime::now_utc(),
                                                },
                                            )
                                            .await;
                                            break;
                                        }
                                    }
                                } else if let Some(error) = frame.error.as_deref() {
                                    publish_signaling_terminal(
                                        &coordinator,
                                        SignalingLifecycleEvent {
                                            handle_id: handle_id.clone(),
                                            phase: SignalingLifecyclePhase::Failed,
                                            server_frame_type: Some(
                                                sanitize_server_error_code(&frame.kind).to_owned(),
                                            ),
                                            failure_class: Some(classify_server_error(error)),
                                            error_description: Some(
                                                sanitize_server_error_code(error).to_owned(),
                                            ),
                                            occurred_at: time::OffsetDateTime::now_utc(),
                                        },
                                    )
                                    .await;
                                    break;
                                }
                            }
                            if !publish_inbound_message(&coordinator, &handle_id, inbound).await {
                                break;
                            }
                        }
                        Ok(Message::Close(_)) => {
                            publish_signaling_terminal(
                                &coordinator,
                                SignalingLifecycleEvent {
                                    handle_id: handle_id.clone(),
                                    phase: SignalingLifecyclePhase::Closed,
                                    server_frame_type: None,
                                    failure_class: Some(SignalingFailureClass::TransientNetwork),
                                    error_description: Some("websocket_closed".to_owned()),
                                    occurred_at: time::OffsetDateTime::now_utc(),
                                },
                            )
                            .await;
                            break;
                        }
                        Ok(Message::Binary(_)) => {
                            publish_signaling_terminal(
                                &coordinator,
                                SignalingLifecycleEvent {
                                    handle_id: handle_id.clone(),
                                    phase: SignalingLifecyclePhase::Failed,
                                    server_frame_type: None,
                                    failure_class: Some(SignalingFailureClass::ProtocolViolation),
                                    error_description: Some(
                                        "binary_websocket_message_rejected".to_owned(),
                                    ),
                                    occurred_at: time::OffsetDateTime::now_utc(),
                                },
                            )
                            .await;
                            break;
                        }
                        Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_)) => {}
                        Err(error) => {
                            publish_signaling_terminal(
                                &coordinator,
                                SignalingLifecycleEvent {
                                    handle_id: handle_id.clone(),
                                    phase: SignalingLifecyclePhase::Failed,
                                    server_frame_type: None,
                                    failure_class: Some(classify_websocket_error(&error)),
                                    error_description: Some(
                                        websocket_runtime_error_code(&error).to_owned(),
                                    ),
                                    occurred_at: time::OffsetDateTime::now_utc(),
                                },
                            )
                            .await;
                            break;
                        }
                    }
                }
            }
        });

        Ok(Self {
            outgoing: out_tx,
            runtime_events: event_rx,
            state,
        })
    }

    pub async fn send(&self, envelope: WebRtcSignalingEnvelope) -> Result<()> {
        validate_outbound_envelope_size(&envelope)?;
        let state = self.state.lock().await;
        let active_handle = state
            .active_handle
            .as_ref()
            .ok_or_else(|| anyhow!("signaling_handle_missing"))?;
        if state.lifecycle_phase != SignalingLifecyclePhase::Bound {
            bail!("signaling_send_requires_bound_handle");
        }
        if envelope.session_id != active_handle.session_id {
            bail!("signaling_outbound_session_mismatch");
        }
        drop(state);
        let (completion_tx, completion_rx) = oneshot::channel();
        self.outgoing
            .send(OutboundSignalingRequest {
                envelope,
                completion: completion_tx,
            })
            .await
            .map_err(|_| anyhow!("signaling send queue closed"))?;
        completion_rx
            .await
            .map_err(|_| anyhow!("signaling writer dropped without a send result"))?
    }

    pub async fn next_runtime_event(&mut self) -> Option<SignalingRuntimeEvent> {
        self.runtime_events.recv().await
    }

    pub async fn snapshot(&self) -> SignalingState {
        self.state.lock().await.clone()
    }
}

fn resolve_outbound_completion(
    completion: oneshot::Sender<Result<()>>,
    result: Result<()>,
    outcome: &'static str,
) {
    if completion.send(result).is_err() {
        tracing::debug!(
            outcome,
            "outbound signaling caller dropped before writer completion"
        );
    }
}

fn close_and_fail_pending_outbound_requests(
    outgoing: &mut mpsc::Receiver<OutboundSignalingRequest>,
    error_code: &'static str,
) {
    outgoing.close();
    while let Ok(request) = outgoing.try_recv() {
        resolve_outbound_completion(
            request.completion,
            Err(anyhow!(error_code)),
            "writer_fail_stop",
        );
    }
}

async fn publish_signaling_writer_failure(
    coordinator: &SignalingConnectionCoordinator,
    handle_id: &SignalingHandleId,
    failure_class: SignalingFailureClass,
    error_code: &'static str,
) {
    publish_signaling_terminal(
        coordinator,
        SignalingLifecycleEvent {
            handle_id: handle_id.clone(),
            phase: SignalingLifecyclePhase::Failed,
            server_frame_type: None,
            failure_class: Some(failure_class),
            error_description: Some(error_code.to_owned()),
            occurred_at: time::OffsetDateTime::now_utc(),
        },
    )
    .await;
}

async fn publish_runtime_events(
    coordinator: Arc<SignalingConnectionCoordinator>,
    runtime_sender: mpsc::Sender<SignalingRuntimeEvent>,
    handle_id: SignalingHandleId,
) {
    while let Some(event) = coordinator.next_event_for_publication().await {
        if runtime_sender.send(event).await.is_err() {
            coordinator.mark_runtime_receiver_dropped(&handle_id).await;
            break;
        }
    }
}

async fn publish_signaling_terminal(
    coordinator: &SignalingConnectionCoordinator,
    event: SignalingLifecycleEvent,
) {
    debug_assert!(is_terminal_lifecycle_phase(event.phase));
    match coordinator.publish_lifecycle(event).await {
        SignalingEventAdmission::Queued
        | SignalingEventAdmission::RuntimeReceiverClosed
        | SignalingEventAdmission::TerminalAlreadySelected => {}
        SignalingEventAdmission::QueueFull => {
            unreachable!("the coordinator reserves capacity for the first terminal event")
        }
    }
}

async fn publish_nonterminal_lifecycle(
    coordinator: &SignalingConnectionCoordinator,
    handle_id: &SignalingHandleId,
    event: SignalingLifecycleEvent,
) -> bool {
    debug_assert!(!is_terminal_lifecycle_phase(event.phase));
    match coordinator.publish_lifecycle(event).await {
        SignalingEventAdmission::Queued => true,
        SignalingEventAdmission::QueueFull => {
            publish_runtime_event_buffer_failure(coordinator, handle_id).await;
            false
        }
        SignalingEventAdmission::RuntimeReceiverClosed
        | SignalingEventAdmission::TerminalAlreadySelected => false,
    }
}

async fn publish_inbound_message(
    coordinator: &SignalingConnectionCoordinator,
    handle_id: &SignalingHandleId,
    inbound: InboundMessage,
) -> bool {
    match coordinator.publish_inbound(inbound).await {
        SignalingEventAdmission::Queued => true,
        SignalingEventAdmission::QueueFull => {
            publish_runtime_event_buffer_failure(coordinator, handle_id).await;
            false
        }
        SignalingEventAdmission::RuntimeReceiverClosed
        | SignalingEventAdmission::TerminalAlreadySelected => false,
    }
}

async fn publish_runtime_event_buffer_failure(
    coordinator: &SignalingConnectionCoordinator,
    handle_id: &SignalingHandleId,
) {
    publish_signaling_terminal(
        coordinator,
        SignalingLifecycleEvent {
            handle_id: handle_id.clone(),
            phase: SignalingLifecyclePhase::Failed,
            server_frame_type: None,
            failure_class: Some(SignalingFailureClass::TransientNetwork),
            error_description: Some("runtime_event_buffer_full".to_owned()),
            occurred_at: time::OffsetDateTime::now_utc(),
        },
    )
    .await;
}

async fn wait_for_signaling_cancellation(cancellation: &mut watch::Receiver<bool>) {
    if *cancellation.borrow() {
        return;
    }
    while cancellation.changed().await.is_ok() {
        if *cancellation.borrow() {
            return;
        }
    }
}

async fn send_signaling_message_with_timeout<F>(
    send_future: F,
    send_timeout: Duration,
) -> std::result::Result<(), SignalingSinkSendFailure>
where
    F: Future<Output = std::result::Result<(), WebSocketError>>,
{
    timeout(send_timeout, send_future)
        .await
        .map_err(|_| SignalingSinkSendFailure::TimedOut)?
        .map_err(SignalingSinkSendFailure::Transport)
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SerializableEnvelope {
    session_id: String,
    from: String,
    to: Option<String>,
    #[serde(rename = "type")]
    kind: WebRtcMessageType,
    payload: Option<WebRtcSignalingPayload>,
    auth_token: Option<String>,
    sent_at: f64,
}

impl From<WebRtcSignalingEnvelope> for SerializableEnvelope {
    fn from(value: WebRtcSignalingEnvelope) -> Self {
        Self {
            session_id: value.session_id,
            from: value.from,
            to: value.to,
            kind: value.kind,
            payload: value.payload.map(|payload| *payload),
            auth_token: value.auth_token,
            sent_at: value.sent_at,
        }
    }
}

fn parse_inbound_message(text: &str) -> Result<InboundMessage> {
    validate_websocket_payload_size(text.len())?;
    match serde_json::from_str::<SerializableEnvelope>(text) {
        Ok(envelope) => {
            if envelope.auth_token.is_some() {
                bail!(
                    "per-message signaling auth tokens are forbidden; authenticate in the WebSocket handshake"
                );
            }
            return Ok(InboundMessage::Envelope(WebRtcSignalingEnvelope {
                session_id: envelope.session_id,
                from: envelope.from,
                to: envelope.to,
                kind: envelope.kind,
                payload: envelope.payload.map(Box::new),
                auth_token: envelope.auth_token,
                sent_at: envelope.sent_at,
            }));
        }
        Err(envelope_error) => {
            if json_declares_webrtc_envelope(text) {
                bail!("malformed signaling envelope: {envelope_error}");
            }
        }
    }
    if let Ok(frame) = serde_json::from_str::<SignalingServerFrame>(text) {
        return Ok(InboundMessage::ServerFrame(frame));
    }
    Ok(InboundMessage::Unknown)
}

fn json_declares_webrtc_envelope(text: &str) -> bool {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return false;
    };
    value
        .get("type")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|message_type| {
            matches!(
                message_type,
                "join" | "offer" | "answer" | "iceCandidate" | "leave"
            )
        })
}

fn signaling_websocket_config() -> WebSocketConfig {
    WebSocketConfig::default()
        .read_buffer_size(SIGNALING_WEBSOCKET_BUFFER_BYTES)
        .write_buffer_size(SIGNALING_WEBSOCKET_BUFFER_BYTES)
        .max_write_buffer_size(
            MAX_SIGNALING_WEBSOCKET_MESSAGE_BYTES + SIGNALING_WEBSOCKET_BUFFER_BYTES,
        )
        .max_message_size(Some(MAX_SIGNALING_WEBSOCKET_MESSAGE_BYTES))
        .max_frame_size(Some(MAX_SIGNALING_WEBSOCKET_MESSAGE_BYTES))
}

fn validate_outbound_envelope_size(envelope: &WebRtcSignalingEnvelope) -> Result<()> {
    if envelope.auth_token.is_some() {
        bail!(
            "per-message signaling auth tokens are forbidden; authenticate in the WebSocket handshake"
        );
    }
    let serialized = serde_json::to_vec(&SerializableEnvelope::from(envelope.clone()))?;
    validate_websocket_payload_size(serialized.len())
}

fn validate_websocket_payload_size(payload_bytes: usize) -> Result<()> {
    if payload_bytes > MAX_SIGNALING_WEBSOCKET_MESSAGE_BYTES {
        bail!(
            "signaling_websocket_payload_limit_exceeded:{payload_bytes}>{MAX_SIGNALING_WEBSOCKET_MESSAGE_BYTES}"
        );
    }
    Ok(())
}

fn classify_websocket_error(error: &WebSocketError) -> SignalingFailureClass {
    match error {
        WebSocketError::Capacity(_)
        | WebSocketError::Protocol(_)
        | WebSocketError::Utf8(_)
        | WebSocketError::AttackAttempt => SignalingFailureClass::ProtocolViolation,
        _ => SignalingFailureClass::TransientNetwork,
    }
}

fn classify_connect_error(error: &WebSocketError) -> SignalingConnectError {
    match error {
        WebSocketError::Http(response) => SignalingConnectError::HandshakeRejected {
            status: response.status().as_u16(),
        },
        WebSocketError::ConnectionClosed | WebSocketError::AlreadyClosed => {
            SignalingConnectError::Transport {
                failure_class: "closed",
            }
        }
        WebSocketError::Io(_) => SignalingConnectError::Transport {
            failure_class: "io",
        },
        WebSocketError::Tls(_) => SignalingConnectError::Transport {
            failure_class: "tls",
        },
        WebSocketError::Capacity(_) => SignalingConnectError::Transport {
            failure_class: "capacity",
        },
        WebSocketError::Protocol(_) => SignalingConnectError::Transport {
            failure_class: "protocol",
        },
        WebSocketError::WriteBufferFull(_) => SignalingConnectError::Transport {
            failure_class: "write_buffer_full",
        },
        WebSocketError::Utf8(_) => SignalingConnectError::Transport {
            failure_class: "utf8",
        },
        WebSocketError::AttackAttempt => SignalingConnectError::Transport {
            failure_class: "attack_attempt",
        },
        WebSocketError::Url(_) | WebSocketError::HttpFormat(_) => {
            SignalingConnectError::Transport {
                failure_class: "invalid_request",
            }
        }
    }
}

fn websocket_runtime_error_code(error: &WebSocketError) -> &'static str {
    match classify_connect_error(error) {
        SignalingConnectError::TimedOut => "connect_timeout",
        SignalingConnectError::HandshakeRejected { .. } => "handshake_rejected",
        SignalingConnectError::Transport { failure_class } => failure_class,
    }
}

fn classify_server_error(reason: &str) -> SignalingFailureClass {
    let normalized = reason.trim().to_ascii_lowercase();
    if normalized.contains("token") && normalized.contains("expired") {
        SignalingFailureClass::TokenExpired
    } else if normalized.contains("auth")
        || normalized.contains("unauthorized")
        || normalized.contains("forbidden")
        || normalized.contains("bind_rejected")
    {
        SignalingFailureClass::AuthBindRejected
    } else if normalized.contains("invalid shard")
        || normalized.contains("invalid session")
        || normalized.contains("session mismatch")
        || normalized.contains("unknown shard")
        || normalized.contains("room_full")
    {
        SignalingFailureClass::InvalidShardOrSessionMismatch
    } else if normalized.contains("protocol") || normalized.contains("malformed") {
        SignalingFailureClass::ProtocolViolation
    } else {
        SignalingFailureClass::TransientServer
    }
}

fn validate_bound_server_frame(
    frame: &SignalingServerFrame,
    expected_session_id: &str,
) -> std::result::Result<(), (SignalingFailureClass, &'static str)> {
    if let Some(error) = frame.error.as_deref() {
        return Err((
            classify_server_error(error),
            sanitize_server_error_code(error),
        ));
    }
    match frame.session_id.as_deref() {
        None | Some("") => Err((
            SignalingFailureClass::ProtocolViolation,
            "bound_missing_session_id",
        )),
        Some(session_id) if session_id != expected_session_id => Err((
            SignalingFailureClass::InvalidShardOrSessionMismatch,
            "bound_session_mismatch",
        )),
        Some(_) => Ok(()),
    }
}

fn sanitize_server_error_code(reason: &str) -> &'static str {
    match reason {
        "bad_candidate" => "bad_candidate",
        "bad_envelope" => "bad_envelope",
        "bad_from" => "bad_from",
        "bad_json" => "bad_json",
        "bad_payload" => "bad_payload",
        "bad_sdp" => "bad_sdp",
        "bad_sdp_mid" => "bad_sdp_mid",
        "bad_session_id" => "bad_session_id",
        "bad_to" => "bad_to",
        "bad_type" => "bad_type",
        "bind_rejected" => "bind_rejected",
        "bound" => "bound",
        "error" => "error",
        "forbidden" => "forbidden",
        "ice_candidate_dropped" => "ice_candidate_dropped",
        "invalid_session" => "invalid_session",
        "malformed" => "malformed",
        "protocol_error" => "protocol_error",
        "room_full" => "room_full",
        "server_error" => "server_error",
        "session_mismatch" => "session_mismatch",
        "session_token_expired" => "session_token_expired",
        "unauthorized" => "unauthorized",
        "unknown_shard" => "unknown_shard",
        _ => "unclassified_server_error",
    }
}

pub fn make_join_envelope(
    session_id: &str,
    device_id: &str,
    bootstrap: WebRtcJoinBootstrap,
) -> Result<WebRtcSignalingEnvelope> {
    make_join_envelope_with_payload(
        session_id,
        device_id,
        Some(WebRtcSignalingPayload::from_join_bootstrap(bootstrap)),
    )
}

pub fn make_explicit_classic_join_envelope(
    session_id: &str,
    device_id: &str,
) -> Result<WebRtcSignalingEnvelope> {
    make_join_envelope_with_payload(session_id, device_id, None)
}

fn make_join_envelope_with_payload(
    session_id: &str,
    device_id: &str,
    payload: Option<WebRtcSignalingPayload>,
) -> Result<WebRtcSignalingEnvelope> {
    let sent_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| anyhow!("system clock is before the Unix epoch"))?
        .as_secs_f64();
    Ok(WebRtcSignalingEnvelope {
        session_id: session_id.to_owned(),
        from: device_id.to_owned(),
        to: None,
        kind: WebRtcMessageType::Join,
        payload: payload.map(Box::new),
        auth_token: None,
        sent_at,
    })
}

pub fn make_session_runtime_id(session_id: &str) -> String {
    format!("session-runtime:{}:{}", session_id, Uuid::now_v7())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_envelope(payload: Option<WebRtcSignalingPayload>) -> WebRtcSignalingEnvelope {
        WebRtcSignalingEnvelope {
            session_id: "bounded-websocket".to_owned(),
            from: "device-a".to_owned(),
            to: Some("device-b".to_owned()),
            kind: WebRtcMessageType::Offer,
            payload: payload.map(Box::new),
            auth_token: None,
            sent_at: 0.0,
        }
    }

    fn pqc_join_bootstrap(device_id: &str) -> WebRtcJoinBootstrap {
        let protocol_public_key_bytes = vec![0x41; crate::pqc::MLDSA65_PUBLIC_KEY_BYTES];
        let protocol_public_key_fingerprint = ProtocolIdentityBinding::compute_fingerprint(
            ProtocolSigningAlgorithm::MlDsa65,
            &protocol_public_key_bytes,
        );
        WebRtcJoinBootstrap::new(
            device_id,
            ProtocolSigningAlgorithm::MlDsa65,
            protocol_public_key_fingerprint,
            protocol_public_key_bytes,
            vec![BootstrapKemPublicKey {
                suite_wire_id: CryptoSuite::XWING_MLDSA.wire_id,
                public_key: vec![0x52; crate::pqc::XWING_PUBLIC_KEY_BYTES],
            }],
            Some("iOS".to_owned()),
            Some("iOS 27.0".to_owned()),
        )
        .expect("valid PQC bootstrap")
    }

    #[test]
    fn strict_pqc_join_bootstrap_is_swift_codable_wire_compatible() -> Result<()> {
        let envelope = make_join_envelope(
            "interop-session",
            "device-alpha-0001",
            pqc_join_bootstrap("device-alpha-0001"),
        )?;
        let encoded = serde_json::to_string(&SerializableEnvelope::from(envelope))?;
        let value: serde_json::Value = serde_json::from_str(&encoded)?;
        let payload = value
            .get("payload")
            .and_then(serde_json::Value::as_object)
            .ok_or_else(|| anyhow!("missing encoded join payload"))?;
        assert_eq!(
            payload
                .get("protocolSigningAlgorithm")
                .and_then(serde_json::Value::as_str),
            Some("ML-DSA-65")
        );
        assert!(
            payload
                .get("protocolPublicKeyBytes")
                .is_some_and(serde_json::Value::is_string)
        );
        assert!(
            payload
                .get("kemPublicKeys")
                .and_then(serde_json::Value::as_array)
                .and_then(|keys| keys.first())
                .and_then(|key| key.get("publicKey"))
                .is_some_and(serde_json::Value::is_string)
        );
        assert!(payload.get("protocol_public_key_bytes").is_none());
        assert!(payload.get("kem_public_keys").is_none());

        let InboundMessage::Envelope(decoded) = parse_inbound_message(&encoded)? else {
            bail!("encoded join did not parse as a signaling envelope");
        };
        let decoded_bootstrap = decoded
            .payload
            .as_ref()
            .ok_or_else(|| anyhow!("decoded join payload is missing"))?
            .validate_for_message_type(decoded.kind, &decoded.from)?
            .ok_or_else(|| anyhow!("decoded join bootstrap is missing"))?;
        assert_eq!(decoded_bootstrap, pqc_join_bootstrap("device-alpha-0001"));
        Ok(())
    }

    #[test]
    fn payload_uses_swift_camel_case_for_ice_fields() -> Result<()> {
        let payload = WebRtcSignalingPayload {
            candidate: Some("candidate:1".to_owned()),
            sdp_mid: Some("0".to_owned()),
            sdp_m_line_index: Some(1),
            ..Default::default()
        };
        let value = serde_json::to_value(payload)?;
        assert_eq!(
            value.get("sdpMid").and_then(serde_json::Value::as_str),
            Some("0")
        );
        assert_eq!(
            value
                .get("sdpMLineIndex")
                .and_then(serde_json::Value::as_i64),
            Some(1)
        );
        assert!(value.get("sdp_mid").is_none());
        Ok(())
    }

    #[test]
    fn join_bootstrap_rejects_partial_identity_and_wrong_message_type() {
        let partial = WebRtcSignalingPayload {
            platform: Some("iOS".to_owned()),
            ..Default::default()
        };
        assert!(
            partial
                .validate_for_message_type(WebRtcMessageType::Join, "device-a")
                .is_err()
        );

        let complete =
            WebRtcSignalingPayload::from_join_bootstrap(pqc_join_bootstrap("device-alpha-0001"));
        assert!(
            complete
                .validate_for_message_type(WebRtcMessageType::Offer, "device-a")
                .is_err()
        );
    }

    #[test]
    fn join_bootstrap_rejects_invalid_kem_sets() {
        let protocol_public_key_bytes = vec![0x41; crate::pqc::MLDSA65_PUBLIC_KEY_BYTES];
        let fingerprint = ProtocolIdentityBinding::compute_fingerprint(
            ProtocolSigningAlgorithm::MlDsa65,
            &protocol_public_key_bytes,
        );
        let build = |keys| {
            WebRtcJoinBootstrap::new(
                "device-alpha-0001",
                ProtocolSigningAlgorithm::MlDsa65,
                fingerprint.clone(),
                protocol_public_key_bytes.clone(),
                keys,
                None,
                None,
            )
        };
        assert!(build(Vec::new()).is_err());
        let valid_key = BootstrapKemPublicKey {
            suite_wire_id: CryptoSuite::XWING_MLDSA.wire_id,
            public_key: vec![0x52; crate::pqc::XWING_PUBLIC_KEY_BYTES],
        };
        assert!(build(vec![valid_key.clone(), valid_key]).is_err());
        assert!(
            build(vec![BootstrapKemPublicKey {
                suite_wire_id: CryptoSuite::XWING_MLDSA.wire_id,
                public_key: vec![0x52; crate::pqc::XWING_PUBLIC_KEY_BYTES - 1],
            }])
            .is_err()
        );
        assert!(
            build(vec![BootstrapKemPublicKey {
                suite_wire_id: CryptoSuite::X25519_ED25519.wire_id,
                public_key: vec![0x52; 32],
            }])
            .is_err()
        );
    }

    #[test]
    fn signaling_parser_rejects_declared_envelope_with_noncanonical_base64() {
        let encoded = r#"{
            "sessionId":"interop-session",
            "from":"device-a",
            "type":"join",
            "payload":{
                "protocolSigningAlgorithm":"ML-DSA-65",
                "protocolPublicKeyFingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "protocolPublicKeyBytes":"QQ",
                "kemPublicKeys":[]
            },
            "sentAt":1
        }"#;
        let error = parse_inbound_message(encoded)
            .expect_err("declared signaling envelope with noncanonical base64 must fail");
        assert!(error.to_string().contains("malformed signaling envelope"));
    }

    #[test]
    fn signaling_parser_rejects_unknown_join_payload_fields() {
        let encoded = r#"{
            "sessionId":"interop-session",
            "from":"device-a",
            "type":"join",
            "payload":{"futureImplicitDowngrade":true},
            "sentAt":1
        }"#;
        let error = parse_inbound_message(encoded)
            .expect_err("unknown join payload fields must not be silently ignored");
        assert!(error.to_string().contains("malformed signaling envelope"));
    }

    fn bound_test_connection(
        outgoing: mpsc::Sender<OutboundSignalingRequest>,
    ) -> SignalingConnection {
        let handle_id = SignalingHandleId {
            session_id: "bounded-websocket".to_owned(),
            backend: SignalingBackend::Native,
            generation: 1,
        };
        let mut state = SignalingState::default();
        state.seed(
            "bounded-websocket".to_owned(),
            1,
            handle_id,
            crate::SignalingSessionHealth::Healthy,
            SignalingLifecyclePhase::Bound,
        );
        let (_, runtime_events) = mpsc::channel(1);
        SignalingConnection {
            outgoing,
            runtime_events,
            state: Arc::new(Mutex::new(state)),
        }
    }

    fn test_handle_id() -> SignalingHandleId {
        SignalingHandleId {
            session_id: "bounded-websocket".to_owned(),
            backend: SignalingBackend::Native,
            generation: 1,
        }
    }

    fn test_coordinator(
        phase: SignalingLifecyclePhase,
        max_buffered_events: usize,
    ) -> (
        Arc<SignalingConnectionCoordinator>,
        Arc<Mutex<SignalingState>>,
        watch::Receiver<bool>,
    ) {
        let handle_id = test_handle_id();
        let mut state = SignalingState::default();
        state.seed(
            handle_id.session_id.clone(),
            handle_id.generation,
            handle_id,
            crate::SignalingSessionHealth::Healthy,
            phase,
        );
        let state = Arc::new(Mutex::new(state));
        let (coordinator, cancellation) =
            SignalingConnectionCoordinator::new(Arc::clone(&state), max_buffered_events);
        (coordinator, state, cancellation)
    }

    fn test_lifecycle_event(
        phase: SignalingLifecyclePhase,
        error_code: Option<&str>,
    ) -> SignalingLifecycleEvent {
        SignalingLifecycleEvent {
            handle_id: test_handle_id(),
            phase,
            server_frame_type: None,
            failure_class: error_code.map(|_| SignalingFailureClass::TransientNetwork),
            error_description: error_code.map(str::to_owned),
            occurred_at: time::OffsetDateTime::now_utc(),
        }
    }

    async fn wait_until_outbound_writer_closed(connection: &SignalingConnection) -> Result<()> {
        timeout(Duration::from_secs(1), async {
            while !connection.outgoing.is_closed() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .map_err(|_| anyhow!("outbound signaling writer remained open after terminal event"))
    }

    async fn assert_reader_terminal_stops_writer(
        terminal_message: Message,
        expected_phase: SignalingLifecyclePhase,
    ) -> Result<()> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = listener.local_addr()?;
        let (release_terminal_tx, release_terminal_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let (socket, _) = listener
                .accept()
                .await
                .map_err(|error| anyhow!("test WebSocket accept failed: {error}"))?;
            let mut websocket = tokio_tungstenite::accept_async(socket)
                .await
                .map_err(|error| anyhow!("test WebSocket upgrade failed: {error}"))?;
            websocket
                .send(Message::Text(
                    r#"{"type":"bound","sessionId":"bounded-websocket"}"#.into(),
                ))
                .await
                .map_err(|error| anyhow!("test bound frame send failed: {error}"))?;
            release_terminal_rx
                .await
                .map_err(|_| anyhow!("test client dropped terminal release signal"))?;
            websocket
                .send(terminal_message)
                .await
                .map_err(|error| anyhow!("test terminal frame send failed: {error}"))?;
            Ok::<(), anyhow::Error>(())
        });

        let request = SignalingWebSocketRequest::new(
            url::Url::parse(&format!("ws://{address}/ws"))?,
            "bounded-websocket",
            "session-token",
        )?;
        let mut connection = SignalingConnection::connect_with_timeout(
            request,
            "bounded-websocket",
            Duration::from_secs(1),
        )
        .await?;

        timeout(Duration::from_secs(1), async {
            loop {
                let event = connection
                    .next_runtime_event()
                    .await
                    .ok_or_else(|| anyhow!("runtime event stream ended before bound"))?;
                if matches!(
                    event,
                    SignalingRuntimeEvent::Lifecycle(SignalingLifecycleEvent {
                        phase: SignalingLifecyclePhase::Bound,
                        ..
                    })
                ) {
                    return Ok::<(), anyhow::Error>(());
                }
            }
        })
        .await
        .map_err(|_| anyhow!("signaling connection did not become bound"))??;
        release_terminal_tx
            .send(())
            .map_err(|_| anyhow!("test WebSocket server dropped terminal release receiver"))?;

        let terminal_event = timeout(Duration::from_secs(1), async {
            loop {
                let event = connection
                    .next_runtime_event()
                    .await
                    .ok_or_else(|| anyhow!("runtime event stream ended before terminal event"))?;
                if let SignalingRuntimeEvent::Lifecycle(event) = event
                    && is_terminal_lifecycle_phase(event.phase)
                {
                    return Ok::<SignalingLifecycleEvent, anyhow::Error>(event);
                }
            }
        })
        .await
        .map_err(|_| anyhow!("reader terminal event was not published"))??;
        assert_eq!(terminal_event.phase, expected_phase);
        assert_eq!(connection.snapshot().await.lifecycle_phase, expected_phase);
        wait_until_outbound_writer_closed(&connection).await?;
        server
            .await
            .map_err(|error| anyhow!("test WebSocket server join failed: {error}"))??;
        Ok(())
    }

    #[tokio::test]
    async fn signaling_send_waits_for_actual_writer_completion() -> Result<()> {
        let (outgoing, mut writer_rx) = mpsc::channel(1);
        let connection = Arc::new(bound_test_connection(outgoing));
        let send_connection = Arc::clone(&connection);
        let mut send_task =
            tokio::spawn(async move { send_connection.send(test_envelope(None)).await });
        let request = timeout(Duration::from_secs(1), writer_rx.recv())
            .await
            .map_err(|_| anyhow!("writer did not receive queued signaling envelope"))?
            .ok_or_else(|| anyhow!("outbound signaling queue closed"))?;

        assert!(
            timeout(Duration::from_millis(20), &mut send_task)
                .await
                .is_err(),
            "send returned before the writer completed the local sink write"
        );
        request
            .completion
            .send(Ok(()))
            .map_err(|_| anyhow!("send caller dropped before local writer completion"))?;
        send_task
            .await
            .map_err(|error| anyhow!("send task join failed: {error}"))??;
        Ok(())
    }

    #[tokio::test]
    async fn cancelled_signaling_send_closes_local_writer_completion() -> Result<()> {
        let (outgoing, mut writer_rx) = mpsc::channel(1);
        let connection = Arc::new(bound_test_connection(outgoing));
        let send_connection = Arc::clone(&connection);
        let send_task =
            tokio::spawn(async move { send_connection.send(test_envelope(None)).await });
        let mut request = timeout(Duration::from_secs(1), writer_rx.recv())
            .await
            .map_err(|_| anyhow!("writer did not receive queued signaling envelope"))?
            .ok_or_else(|| anyhow!("outbound signaling queue closed"))?;

        send_task.abort();
        let join_error = send_task
            .await
            .expect_err("aborted signaling send unexpectedly completed");
        assert!(join_error.is_cancelled());
        timeout(Duration::from_secs(1), request.completion.closed())
            .await
            .map_err(|_| anyhow!("local writer completion did not observe caller cancellation"))?;
        assert!(request.completion.is_closed());
        Ok(())
    }

    #[tokio::test]
    async fn outbound_session_mismatch_is_rejected_without_identifier_disclosure() -> Result<()> {
        let (outgoing, mut writer_rx) = mpsc::channel(1);
        let connection = bound_test_connection(outgoing);
        let mut envelope = test_envelope(None);
        envelope.session_id = "high-entropy-mismatched-session-secret".to_owned();

        let error = connection
            .send(envelope)
            .await
            .expect_err("mismatched outbound signaling session must fail closed");
        assert_eq!(error.to_string(), "signaling_outbound_session_mismatch");
        assert!(!error.to_string().contains("high-entropy"));
        assert!(matches!(
            writer_rx.try_recv(),
            Err(mpsc::error::TryRecvError::Empty)
        ));
        Ok(())
    }

    #[tokio::test]
    async fn handshake_and_connection_session_mismatch_fails_before_network_io() -> Result<()> {
        let request = SignalingWebSocketRequest::new(
            url::Url::parse("ws://127.0.0.1:9/ws")?,
            "authenticated-session-secret",
            "session-token",
        )?;
        let error = SignalingConnection::connect_with_timeout(
            request,
            "different-session-secret",
            Duration::from_millis(20),
        )
        .await
        .expect_err("connection session mismatch must fail before dialing");
        assert_eq!(error.to_string(), "signaling_connection_session_mismatch");
        assert!(!error.to_string().contains("session-secret"));
        Ok(())
    }

    #[tokio::test]
    async fn reader_close_stops_outbound_writer() -> Result<()> {
        assert_reader_terminal_stops_writer(Message::Close(None), SignalingLifecyclePhase::Closed)
            .await
    }

    #[tokio::test]
    async fn reader_protocol_violation_stops_outbound_writer() -> Result<()> {
        assert_reader_terminal_stops_writer(
            Message::Binary(Vec::new().into()),
            SignalingLifecyclePhase::Failed,
        )
        .await
    }

    #[tokio::test]
    async fn writer_failure_is_terminal_and_late_bound_cannot_revive_connection() {
        let (coordinator, state, cancellation) =
            test_coordinator(SignalingLifecyclePhase::Bound, 4);
        publish_signaling_writer_failure(
            &coordinator,
            &test_handle_id(),
            SignalingFailureClass::TransientNetwork,
            "send_timeout",
        )
        .await;

        assert!(*cancellation.borrow());
        assert_eq!(
            coordinator
                .publish_lifecycle(test_lifecycle_event(SignalingLifecyclePhase::Bound, None,))
                .await,
            SignalingEventAdmission::TerminalAlreadySelected
        );
        assert_eq!(
            state.lock().await.lifecycle_phase,
            SignalingLifecyclePhase::Failed
        );
        let Some(SignalingRuntimeEvent::Lifecycle(event)) =
            coordinator.next_event_for_publication().await
        else {
            panic!("writer failure terminal event was not queued");
        };
        assert_eq!(event.phase, SignalingLifecyclePhase::Failed);
        assert!(coordinator.next_event_for_publication().await.is_none());
    }

    #[tokio::test]
    async fn simultaneous_terminal_events_are_first_wins_and_strictly_ordered() -> Result<()> {
        let (coordinator, state, _) = test_coordinator(SignalingLifecyclePhase::Bound, 4);
        let barrier = Arc::new(tokio::sync::Barrier::new(3));
        let close_task = tokio::spawn({
            let coordinator = Arc::clone(&coordinator);
            let barrier = Arc::clone(&barrier);
            async move {
                barrier.wait().await;
                coordinator
                    .publish_lifecycle(test_lifecycle_event(
                        SignalingLifecyclePhase::Closed,
                        Some("reader_closed"),
                    ))
                    .await
            }
        });
        let failure_task = tokio::spawn({
            let coordinator = Arc::clone(&coordinator);
            let barrier = Arc::clone(&barrier);
            async move {
                barrier.wait().await;
                coordinator
                    .publish_lifecycle(test_lifecycle_event(
                        SignalingLifecyclePhase::Failed,
                        Some("writer_failed"),
                    ))
                    .await
            }
        });
        barrier.wait().await;
        let admissions = [
            close_task
                .await
                .map_err(|error| anyhow!("close terminal task failed: {error}"))?,
            failure_task
                .await
                .map_err(|error| anyhow!("failure terminal task failed: {error}"))?,
        ];
        assert_eq!(
            admissions
                .iter()
                .filter(|admission| **admission == SignalingEventAdmission::Queued)
                .count(),
            1
        );
        assert_eq!(
            admissions
                .iter()
                .filter(|admission| {
                    **admission == SignalingEventAdmission::TerminalAlreadySelected
                })
                .count(),
            1
        );

        let Some(SignalingRuntimeEvent::Lifecycle(event)) =
            coordinator.next_event_for_publication().await
        else {
            return Err(anyhow!("winning terminal event was not queued"));
        };
        assert!(is_terminal_lifecycle_phase(event.phase));
        assert_eq!(state.lock().await.lifecycle_phase, event.phase);
        assert!(coordinator.next_event_for_publication().await.is_none());
        Ok(())
    }

    #[tokio::test]
    async fn full_public_event_queue_does_not_block_terminal_state_or_event_order() -> Result<()> {
        let (coordinator, state, _) = test_coordinator(SignalingLifecyclePhase::Bound, 1);
        let (runtime_tx, mut runtime_rx) = mpsc::channel(1);
        let publisher = tokio::spawn(publish_runtime_events(
            Arc::clone(&coordinator),
            runtime_tx,
            test_handle_id(),
        ));

        assert_eq!(
            coordinator.publish_inbound(InboundMessage::Unknown).await,
            SignalingEventAdmission::Queued
        );
        timeout(Duration::from_secs(1), async {
            while runtime_rx.len() != 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .map_err(|_| anyhow!("publisher did not fill public runtime event queue"))?;

        assert_eq!(
            coordinator.publish_inbound(InboundMessage::Unknown).await,
            SignalingEventAdmission::Queued
        );
        timeout(Duration::from_secs(1), async {
            loop {
                if coordinator
                    .coordination
                    .lock()
                    .await
                    .pending_events
                    .is_empty()
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .map_err(|_| anyhow!("publisher did not block on the full public queue"))?;

        assert_eq!(
            coordinator.publish_inbound(InboundMessage::Unknown).await,
            SignalingEventAdmission::Queued
        );
        let terminal_admission = timeout(
            Duration::from_millis(50),
            coordinator.publish_lifecycle(test_lifecycle_event(
                SignalingLifecyclePhase::Failed,
                Some("reader_failed"),
            )),
        )
        .await
        .map_err(|_| anyhow!("public event backpressure blocked terminal state"))?;
        assert_eq!(terminal_admission, SignalingEventAdmission::Queued);
        assert_eq!(
            state.lock().await.lifecycle_phase,
            SignalingLifecyclePhase::Failed
        );

        for expected_index in 0..4 {
            let event = timeout(Duration::from_secs(1), runtime_rx.recv())
                .await
                .map_err(|_| anyhow!("runtime event {expected_index} was not published"))?
                .ok_or_else(|| anyhow!("runtime event stream ended before {expected_index}"))?;
            if expected_index < 3 {
                assert_eq!(
                    event,
                    SignalingRuntimeEvent::Inbound(InboundMessage::Unknown)
                );
            } else {
                assert!(matches!(
                    event,
                    SignalingRuntimeEvent::Lifecycle(SignalingLifecycleEvent {
                        phase: SignalingLifecyclePhase::Failed,
                        ..
                    })
                ));
            }
        }
        publisher
            .await
            .map_err(|error| anyhow!("runtime publisher task failed: {error}"))?;
        Ok(())
    }

    #[tokio::test]
    async fn writer_fail_stop_resolves_all_pending_signaling_callers() -> Result<()> {
        let (outgoing, mut writer_rx) = mpsc::channel(4);
        let mut completions = Vec::new();
        for _ in 0..3 {
            let (completion, result) = oneshot::channel();
            outgoing
                .send(OutboundSignalingRequest {
                    envelope: test_envelope(None),
                    completion,
                })
                .await
                .map_err(|_| anyhow!("failed to seed outbound signaling queue"))?;
            completions.push(result);
        }

        close_and_fail_pending_outbound_requests(&mut writer_rx, "writer_replaced");
        for completion in completions {
            let result = completion
                .await
                .map_err(|_| anyhow!("pending signaling completion sender dropped"))?;
            let error = result.expect_err("pending signaling call unexpectedly succeeded");
            assert_eq!(error.to_string(), "writer_replaced");
        }
        assert!(
            outgoing
                .send(OutboundSignalingRequest {
                    envelope: test_envelope(None),
                    completion: oneshot::channel().0,
                })
                .await
                .is_err()
        );
        Ok(())
    }

    #[test]
    fn signaling_websocket_config_bounds_frames_messages_and_write_buffer() {
        let config = signaling_websocket_config();
        assert_eq!(
            config.max_message_size,
            Some(MAX_SIGNALING_WEBSOCKET_MESSAGE_BYTES)
        );
        assert_eq!(
            config.max_frame_size,
            Some(MAX_SIGNALING_WEBSOCKET_MESSAGE_BYTES)
        );
        assert_eq!(config.read_buffer_size, SIGNALING_WEBSOCKET_BUFFER_BYTES);
        assert_eq!(config.write_buffer_size, SIGNALING_WEBSOCKET_BUFFER_BYTES);
        assert!(config.max_write_buffer_size > config.write_buffer_size);
    }

    #[tokio::test]
    async fn signaling_sink_send_timeout_is_bounded_and_classified_fail_stop() {
        let failure = timeout(
            Duration::from_secs(1),
            send_signaling_message_with_timeout(
                std::future::pending::<std::result::Result<(), WebSocketError>>(),
                Duration::from_millis(20),
            ),
        )
        .await
        .expect("bounded signaling sink test timed out")
        .expect_err("never-resolving signaling sink must time out");
        assert!(matches!(&failure, SignalingSinkSendFailure::TimedOut));
        assert_eq!(
            failure.failure_class(),
            SignalingFailureClass::TransientNetwork
        );
        assert_eq!(failure.error_code(), "send_timeout");
    }

    #[tokio::test]
    async fn signaling_sink_transport_error_remains_explicit() {
        let failure = send_signaling_message_with_timeout(
            async { Err(WebSocketError::ConnectionClosed) },
            Duration::from_secs(1),
        )
        .await
        .expect_err("closed signaling sink must fail");
        assert!(matches!(
            &failure,
            SignalingSinkSendFailure::Transport(WebSocketError::ConnectionClosed)
        ));
        assert_eq!(
            failure.failure_class(),
            SignalingFailureClass::TransientNetwork
        );
        assert_eq!(failure.error_code(), "closed");
    }

    #[tokio::test]
    async fn websocket_connect_timeout_bounds_accepted_socket_without_http_upgrade() -> Result<()> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = listener.local_addr()?;
        let (accepted_tx, accepted_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let Ok((_socket, _)) = listener.accept().await else {
                return;
            };
            if accepted_tx.send(()).is_err() {
                return;
            }
            std::future::pending::<()>().await;
        });
        let request = SignalingWebSocketRequest::new(
            url::Url::parse(&format!("ws://{address}/ws"))?,
            "connect-timeout",
            "session-token",
        )?;

        let error = SignalingConnection::connect_with_timeout(
            request,
            "connect-timeout",
            Duration::from_millis(50),
        )
        .await
        .expect_err("accepted TCP socket without HTTP upgrade must time out");
        timeout(Duration::from_secs(1), accepted_rx)
            .await
            .map_err(|_| anyhow!("test server did not accept the WebSocket TCP connection"))?
            .map_err(|_| anyhow!("test server dropped its acceptance signal"))?;
        assert!(matches!(
            error.downcast_ref::<SignalingConnectError>(),
            Some(SignalingConnectError::TimedOut)
        ));
        server.abort();
        Ok(())
    }

    #[tokio::test]
    async fn runtime_event_stream_delivers_more_than_legacy_fanout_capacity() -> Result<()> {
        const INBOUND_EVENT_COUNT: usize = 70;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = listener.local_addr()?;
        let server = tokio::spawn(async move {
            let (socket, _) = listener
                .accept()
                .await
                .map_err(|error| anyhow!("test WebSocket accept failed: {error}"))?;
            let mut websocket = tokio_tungstenite::accept_async(socket)
                .await
                .map_err(|error| anyhow!("test WebSocket upgrade failed: {error}"))?;
            for index in 0..INBOUND_EVENT_COUNT {
                let body = serde_json::json!({
                    "type": "notice",
                    "session_id": format!("event-{index}"),
                })
                .to_string();
                websocket
                    .send(Message::Text(body.into()))
                    .await
                    .map_err(|error| anyhow!("test WebSocket send failed: {error}"))?;
            }
            websocket
                .close(None)
                .await
                .map_err(|error| anyhow!("test WebSocket close failed: {error}"))?;
            Ok::<(), anyhow::Error>(())
        });
        let request = SignalingWebSocketRequest::new(
            url::Url::parse(&format!("ws://{address}/ws"))?,
            "fanout-capacity",
            "session-token",
        )?;
        let mut connection = SignalingConnection::connect_with_timeout(
            request,
            "fanout-capacity",
            Duration::from_secs(1),
        )
        .await?;

        timeout(Duration::from_secs(3), async {
            let mut inbound_count = 0;
            while inbound_count < INBOUND_EVENT_COUNT {
                let event = connection
                    .next_runtime_event()
                    .await
                    .ok_or_else(|| anyhow!("runtime signaling event stream ended early"))?;
                if matches!(event, SignalingRuntimeEvent::Inbound(_)) {
                    inbound_count += 1;
                }
            }
            Ok::<(), anyhow::Error>(())
        })
        .await
        .map_err(|_| anyhow!("runtime event stream stalled before event 65"))??;
        server
            .await
            .map_err(|error| anyhow!("test WebSocket server join failed: {error}"))??;
        Ok(())
    }

    #[test]
    fn inbound_signaling_parser_rejects_oversized_websocket_payload() {
        let oversized = "x".repeat(MAX_SIGNALING_WEBSOCKET_MESSAGE_BYTES + 1);
        let error = parse_inbound_message(&oversized)
            .expect_err("oversized websocket text must be rejected");
        assert!(error.to_string().contains("payload_limit_exceeded"));
    }

    #[test]
    fn outbound_signaling_queue_rejects_oversized_serialized_envelope() {
        let envelope = test_envelope(Some(WebRtcSignalingPayload {
            sdp: Some("s".repeat(MAX_SIGNALING_WEBSOCKET_MESSAGE_BYTES)),
            ..Default::default()
        }));
        let error = validate_outbound_envelope_size(&envelope)
            .expect_err("serialized envelope beyond websocket limit must be rejected");
        assert!(error.to_string().contains("payload_limit_exceeded"));
    }

    #[test]
    fn normal_signaling_envelope_and_server_frame_still_parse() -> Result<()> {
        let envelope_text = serde_json::to_string(&SerializableEnvelope::from(test_envelope(
            Some(WebRtcSignalingPayload {
                sdp: Some("v=0".to_owned()),
                ..Default::default()
            }),
        )))?;
        assert!(matches!(
            parse_inbound_message(&envelope_text)?,
            InboundMessage::Envelope(_)
        ));
        assert!(matches!(
            parse_inbound_message(r#"{"type":"bound","sessionId":"bounded-websocket"}"#)?,
            InboundMessage::ServerFrame(SignalingServerFrame { kind, .. }) if kind == "bound"
        ));
        Ok(())
    }

    #[test]
    fn bound_server_frame_requires_camel_case_matching_session_and_no_error() -> Result<()> {
        let InboundMessage::ServerFrame(valid) =
            parse_inbound_message(r#"{"type":"bound","sessionId":"expected-session"}"#)?
        else {
            return Err(anyhow!("camelCase bound frame did not parse"));
        };
        assert_eq!(valid.session_id.as_deref(), Some("expected-session"));
        assert_eq!(
            validate_bound_server_frame(&valid, "expected-session"),
            Ok(())
        );

        let missing = SignalingServerFrame {
            kind: "bound".to_owned(),
            error: None,
            session_id: None,
            what: None,
        };
        assert_eq!(
            validate_bound_server_frame(&missing, "expected-session"),
            Err((
                SignalingFailureClass::ProtocolViolation,
                "bound_missing_session_id"
            ))
        );
        let mismatched = SignalingServerFrame {
            session_id: Some("other-session".to_owned()),
            ..missing.clone()
        };
        assert_eq!(
            validate_bound_server_frame(&mismatched, "expected-session"),
            Err((
                SignalingFailureClass::InvalidShardOrSessionMismatch,
                "bound_session_mismatch"
            ))
        );
        let error_bound = SignalingServerFrame {
            error: Some("bind_rejected".to_owned()),
            session_id: Some("expected-session".to_owned()),
            ..missing
        };
        assert_eq!(
            validate_bound_server_frame(&error_bound, "expected-session"),
            Err((SignalingFailureClass::AuthBindRejected, "bind_rejected"))
        );
        Ok(())
    }

    #[test]
    fn snake_case_bound_session_id_does_not_satisfy_wire_contract() -> Result<()> {
        let InboundMessage::ServerFrame(frame) =
            parse_inbound_message(r#"{"type":"bound","session_id":"expected-session"}"#)?
        else {
            return Err(anyhow!(
                "snake_case bound frame did not parse as a server frame"
            ));
        };
        assert!(frame.session_id.is_none());
        assert_eq!(
            validate_bound_server_frame(&frame, "expected-session"),
            Err((
                SignalingFailureClass::ProtocolViolation,
                "bound_missing_session_id"
            ))
        );
        Ok(())
    }

    #[test]
    fn websocket_request_uses_sensitive_authentication_headers_not_query_token() -> Result<()> {
        let secret = "session-token-secret";
        let request = SignalingWebSocketRequest::new(
            url::Url::parse("wss://signal.example/ws?shard=session-1&cv=0.3.0&pv=1")?,
            "session-1",
            secret,
        )?;
        let debug = format!("{request:?}");
        assert!(!debug.contains(secret));
        assert!(!debug.contains("shard=session-1"));

        let request = request.into_http_request()?;
        let session_id = request
            .headers()
            .get(&SESSION_ID_HEADER)
            .expect("session id header missing");
        let session_token = request
            .headers()
            .get(&SESSION_TOKEN_HEADER)
            .expect("session token header missing");
        assert_eq!(session_id, HeaderValue::from_static("session-1"));
        assert_eq!(
            session_token,
            HeaderValue::from_static("session-token-secret")
        );
        assert!(session_id.is_sensitive());
        assert!(session_token.is_sensitive());
        let uri = request.uri().to_string();
        assert!(!uri.contains(secret));
        assert!(!uri.contains("st="));
        Ok(())
    }

    #[test]
    fn credential_query_parameters_are_rejected_case_insensitively() {
        for query in [
            "st=session-token-secret",
            "ST=session-token-secret",
            "Session_Token=session-token-secret",
            "access_token=session-token-secret",
        ] {
            let endpoint = url::Url::parse(&format!("wss://signal.example/ws?{query}")).unwrap();
            let error =
                SignalingWebSocketRequest::new(endpoint, "session-1", "session-token-secret")
                    .expect_err("credential-bearing URL must fail");
            assert!(!error.to_string().contains("session-token-secret"));
        }
    }

    #[test]
    fn signaling_debug_output_redacts_credentials_identifiers_and_payloads() {
        let envelope = WebRtcSignalingEnvelope {
            session_id: "session-id-secret".to_owned(),
            from: "source-device-secret".to_owned(),
            to: Some("target-device-secret".to_owned()),
            kind: WebRtcMessageType::Offer,
            payload: Some(Box::new(WebRtcSignalingPayload {
                sdp: Some("sdp-private-address-secret".to_owned()),
                candidate: Some("candidate-private-address-secret".to_owned()),
                ..Default::default()
            })),
            auth_token: Some("message-token-secret".to_owned()),
            sent_at: 0.0,
        };
        let frame = SignalingServerFrame {
            kind: "error".to_owned(),
            error: Some("Bearer server-reflected-secret".to_owned()),
            session_id: Some("frame-session-secret".to_owned()),
            what: Some("Bearer frame-what-secret".to_owned()),
        };
        let (outgoing, _writer_rx) = mpsc::channel(1);
        let connection = bound_test_connection(outgoing);
        let debug = format!("{envelope:?}\n{frame:?}\n{connection:?}");
        for secret in [
            "session-id-secret",
            "source-device-secret",
            "target-device-secret",
            "sdp-private-address-secret",
            "candidate-private-address-secret",
            "message-token-secret",
            "server-reflected-secret",
            "frame-session-secret",
            "frame-what-secret",
            "bounded-websocket",
        ] {
            assert!(!debug.contains(secret), "debug output leaked {secret}");
        }

        let reflected_secret = "sk_live_Q7wE9rT2uI4oP6aS8dF0gH1jK3lZ5xC7";
        assert_eq!(
            sanitize_server_error_code(reflected_secret),
            "unclassified_server_error"
        );
        let frame = SignalingServerFrame {
            kind: "error".to_owned(),
            error: Some(reflected_secret.to_owned()),
            session_id: None,
            what: None,
        };
        assert!(!format!("{frame:?}").contains(reflected_secret));
    }

    #[test]
    fn per_message_auth_tokens_fail_closed_in_both_directions() {
        let mut envelope = test_envelope(None);
        envelope.auth_token = Some("message-token-secret".to_owned());
        let outbound_error = validate_outbound_envelope_size(&envelope)
            .expect_err("outbound per-message token must fail");
        assert!(!outbound_error.to_string().contains("message-token-secret"));

        let inbound = serde_json::to_string(&SerializableEnvelope::from(envelope)).unwrap();
        let inbound_error =
            parse_inbound_message(&inbound).expect_err("inbound per-message token must fail");
        assert!(!inbound_error.to_string().contains("message-token-secret"));
    }
}
