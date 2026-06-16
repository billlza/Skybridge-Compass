use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::{
    SessionReadiness, SignalingBackend, SignalingLifecyclePhase, SignalingSessionHealth,
    TurnCredentials,
};

mod file_transfer;
mod registry;
mod remote_desktop;
#[cfg(test)]
mod tests;

pub use file_transfer::{
    FileTransferControlAction, FileTransferControlRequest, FileTransferControlRequestRegistry,
    FileTransferControlRequestStatus, FileTransferDestinationBinding, FileTransferSourceSnapshot,
};
pub use registry::{ManagedSessionControlRegistry, SessionRegistry, make_runtime_id};
pub use remote_desktop::{
    REMOTE_DESKTOP_FPS_REQUEST_CONTRACT, REMOTE_DESKTOP_RESOLUTION_REQUEST_CONTRACT,
    RemoteDesktopCapabilitySnapshot, RemoteDesktopCapabilitySnapshotRegistry,
    RemoteDesktopControlAction, RemoteDesktopControlRequest, RemoteDesktopControlRequestPayload,
    RemoteDesktopControlRequestRegistry, RemoteDesktopControlRequestStatus,
    RemoteDesktopObservedMode, RemoteDesktopResolutionPreset, RemoteDesktopResolutionRequest,
    remote_desktop_fps_request_supported, remote_desktop_resolution_preset_matches,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeSessionRole {
    Initiator,
    Responder,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeSessionSource {
    Code,
    Qr,
    Recovered,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ManagedSessionDesiredState {
    Active,
    Stopped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeSessionState {
    Pending,
    Connecting,
    Bound,
    Degraded,
    Disconnected,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeSessionKeepaliveKind {
    HeartbeatSent,
    HeartbeatReceived,
    PingSent,
    PongReceived,
    PongReplied,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct RuntimeSessionKeepaliveStatus {
    #[serde(default)]
    pub heartbeat_sent_count: u64,
    #[serde(default)]
    pub heartbeat_received_count: u64,
    #[serde(default)]
    pub ping_sent_count: u64,
    #[serde(default)]
    pub pong_received_count: u64,
    #[serde(default)]
    pub pong_replied_count: u64,
    #[serde(default)]
    pub last_ping_id: Option<u64>,
    #[serde(default)]
    pub last_pong_id: Option<u64>,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub last_heartbeat_sent_at: Option<OffsetDateTime>,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub last_heartbeat_received_at: Option<OffsetDateTime>,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub last_ping_sent_at: Option<OffsetDateTime>,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub last_pong_received_at: Option<OffsetDateTime>,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub last_pong_replied_at: Option<OffsetDateTime>,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub last_activity_at: Option<OffsetDateTime>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeSessionRecord {
    pub runtime_id: String,
    pub session_id: String,
    pub role: RuntimeSessionRole,
    pub source: RuntimeSessionSource,
    pub signaling_server_origin: String,
    pub local_device_id: String,
    pub remote_device_id: Option<String>,
    pub remote_device_name: Option<String>,
    pub remote_protocol_public_key_fingerprint: Option<String>,
    pub state: RuntimeSessionState,
    pub lifecycle_phase: SignalingLifecyclePhase,
    pub signaling_health: SignalingSessionHealth,
    pub signaling_backend: Option<SignalingBackend>,
    pub signaling_generation: Option<u32>,
    #[serde(default)]
    pub readiness: SessionReadiness,
    #[serde(default)]
    pub last_established_readiness: Option<SessionReadiness>,
    #[serde(default)]
    pub transport_preserved: bool,
    #[serde(default)]
    pub keepalive: RuntimeSessionKeepaliveStatus,
    pub last_error: Option<String>,
    #[serde(default)]
    pub last_transport_error: Option<String>,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub transport_ready_at: Option<OffsetDateTime>,
    #[serde(default, with = "time::serde::rfc3339::option")]
    pub handshake_completed_at: Option<OffsetDateTime>,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339::option")]
    pub closed_at: Option<OffsetDateTime>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManagedSessionControl {
    pub schema_version: u32,
    pub session_id: String,
    pub role: RuntimeSessionRole,
    pub source: RuntimeSessionSource,
    pub local_device_id: String,
    pub signaling_server_origin: String,
    pub signaling_session_token: String,
    #[serde(default)]
    pub turn_credentials: Option<TurnCredentials>,
    pub desired_state: ManagedSessionDesiredState,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntimeSessionTransportEvent {
    TransportReady,
    HandshakeComplete {
        negotiated_suite: String,
    },
    Keepalive {
        kind: RuntimeSessionKeepaliveKind,
        ping_id: Option<u64>,
    },
    TransportDisconnected {
        reason: Option<String>,
    },
}

impl RuntimeSessionRecord {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        runtime_id: impl Into<String>,
        session_id: impl Into<String>,
        role: RuntimeSessionRole,
        source: RuntimeSessionSource,
        signaling_server_origin: impl Into<String>,
        local_device_id: impl Into<String>,
        remote_device_id: Option<String>,
        remote_device_name: Option<String>,
        remote_protocol_public_key_fingerprint: Option<String>,
        state: RuntimeSessionState,
    ) -> Self {
        let now = OffsetDateTime::now_utc();
        Self {
            runtime_id: runtime_id.into(),
            session_id: session_id.into(),
            role,
            source,
            signaling_server_origin: signaling_server_origin.into(),
            local_device_id: local_device_id.into(),
            remote_device_id,
            remote_device_name,
            remote_protocol_public_key_fingerprint,
            state,
            lifecycle_phase: SignalingLifecyclePhase::Idle,
            signaling_health: SignalingSessionHealth::Healthy,
            signaling_backend: None,
            signaling_generation: None,
            readiness: SessionReadiness::Idle,
            last_established_readiness: None,
            transport_preserved: false,
            keepalive: RuntimeSessionKeepaliveStatus::default(),
            last_error: None,
            last_transport_error: None,
            transport_ready_at: None,
            handshake_completed_at: None,
            created_at: now,
            updated_at: now,
            closed_at: None,
        }
    }

    pub fn is_active(&self) -> bool {
        matches!(
            self.state,
            RuntimeSessionState::Pending
                | RuntimeSessionState::Connecting
                | RuntimeSessionState::Bound
                | RuntimeSessionState::Degraded
        )
    }

    pub fn effective_established_readiness(&self) -> Option<&SessionReadiness> {
        if self
            .readiness
            .is_transport_established_for(&self.session_id)
        {
            Some(&self.readiness)
        } else {
            self.last_established_readiness.as_ref()
        }
    }
}

impl ManagedSessionControl {
    pub const SCHEMA_VERSION: u32 = 2;

    pub fn new(
        session_id: impl Into<String>,
        role: RuntimeSessionRole,
        source: RuntimeSessionSource,
        local_device_id: impl Into<String>,
        signaling_server_origin: impl Into<String>,
        signaling_session_token: impl Into<String>,
        turn_credentials: Option<TurnCredentials>,
    ) -> Self {
        let now = OffsetDateTime::now_utc();
        Self {
            schema_version: Self::SCHEMA_VERSION,
            session_id: session_id.into(),
            role,
            source,
            local_device_id: local_device_id.into(),
            signaling_server_origin: signaling_server_origin.into(),
            signaling_session_token: signaling_session_token.into(),
            turn_credentials,
            desired_state: ManagedSessionDesiredState::Active,
            created_at: now,
            updated_at: now,
        }
    }
}
