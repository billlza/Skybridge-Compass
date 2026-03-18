use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::{
    SessionReadiness, SignalingBackend, SignalingLifecycleEvent, SignalingLifecyclePhase,
    SignalingSessionHealth, TurnCredentials,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManagedSessionControlRegistry {
    pub schema_version: u32,
    pub sessions: BTreeMap<String, ManagedSessionControl>,
}

impl Default for ManagedSessionControlRegistry {
    fn default() -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            sessions: BTreeMap::new(),
        }
    }
}

impl ManagedSessionControlRegistry {
    pub const SCHEMA_VERSION: u32 = 1;

    pub fn insert(&mut self, control: ManagedSessionControl) {
        self.sessions.insert(control.session_id.clone(), control);
    }

    pub fn remove(&mut self, session_id: &str) -> Option<ManagedSessionControl> {
        self.sessions.remove(session_id)
    }

    pub fn get(&self, session_id: &str) -> Option<&ManagedSessionControl> {
        self.sessions.get(session_id)
    }

    pub fn active_controls(&self) -> Vec<ManagedSessionControl> {
        self.sessions
            .values()
            .filter(|control| control.desired_state == ManagedSessionDesiredState::Active)
            .cloned()
            .collect()
    }
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionRegistry {
    pub schema_version: u32,
    pub sessions: BTreeMap<String, RuntimeSessionRecord>,
}

impl Default for SessionRegistry {
    fn default() -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            sessions: BTreeMap::new(),
        }
    }
}

impl SessionRegistry {
    pub const SCHEMA_VERSION: u32 = 2;

    pub fn insert(&mut self, record: RuntimeSessionRecord) {
        self.sessions.insert(record.session_id.clone(), record);
    }

    pub fn get(&self, session_id: &str) -> Option<&RuntimeSessionRecord> {
        self.sessions.get(session_id)
    }

    pub fn values_sorted(&self) -> Vec<RuntimeSessionRecord> {
        let mut values = self.sessions.values().cloned().collect::<Vec<_>>();
        values.sort_by(|lhs, rhs| rhs.updated_at.cmp(&lhs.updated_at));
        values
    }

    pub fn active_count(&self) -> usize {
        self.sessions
            .values()
            .filter(|session| session.is_active())
            .count()
    }

    pub fn apply_signaling_event(&mut self, session_id: &str, event: &SignalingLifecycleEvent) {
        let Some(record) = self.sessions.get_mut(session_id) else {
            return;
        };
        record.lifecycle_phase = event.phase;
        record.signaling_backend = Some(event.handle_id.backend);
        record.signaling_generation = Some(event.handle_id.generation);
        record.updated_at = event.occurred_at;
        if let Some(error_description) = event.error_description.clone() {
            record.last_error = Some(error_description);
        }
        match event.phase {
            SignalingLifecyclePhase::Idle => {
                record.signaling_health = SignalingSessionHealth::Healthy;
            }
            SignalingLifecyclePhase::Connecting
            | SignalingLifecyclePhase::SocketOpen
            | SignalingLifecyclePhase::Reconnecting => {
                record.signaling_health = if transport_established(record) {
                    SignalingSessionHealth::DegradedRecoverable
                } else {
                    SignalingSessionHealth::Healthy
                };
            }
            SignalingLifecyclePhase::Bound => {
                record.signaling_health = SignalingSessionHealth::Healthy;
                record.last_error = None;
            }
            SignalingLifecyclePhase::Closing | SignalingLifecyclePhase::Closed => {
                record.signaling_health = SignalingSessionHealth::DegradedRecoverable;
            }
            SignalingLifecyclePhase::Failed => {
                record.signaling_health = classify_health(event.failure_class);
            }
        }
        reconcile_runtime_state(record);
    }

    pub fn mark_disconnected(&mut self, session_id: &str, reason: Option<String>) -> bool {
        let Some(record) = self.sessions.get_mut(session_id) else {
            return false;
        };
        preserve_established_readiness(record);
        record.readiness = SessionReadiness::Idle;
        record.transport_preserved = false;
        record.state = RuntimeSessionState::Disconnected;
        record.lifecycle_phase = SignalingLifecyclePhase::Closed;
        record.signaling_health = SignalingSessionHealth::DegradedRecoverable;
        record.last_error = reason;
        record.last_transport_error = None;
        record.updated_at = OffsetDateTime::now_utc();
        record.closed_at = Some(record.updated_at);
        true
    }

    pub fn mark_transport_ready(&mut self, session_id: &str) -> bool {
        let Some(record) = self.sessions.get_mut(session_id) else {
            return false;
        };
        let now = OffsetDateTime::now_utc();
        let readiness = SessionReadiness::TransportReady {
            session_id: record.session_id.clone(),
        };
        record.readiness = readiness.clone();
        record.last_established_readiness = Some(readiness);
        record.transport_ready_at.get_or_insert(now);
        record.keepalive.last_activity_at = Some(now);
        record.updated_at = now;
        record.last_transport_error = None;
        reconcile_runtime_state(record);
        true
    }

    pub fn mark_handshake_complete(
        &mut self,
        session_id: &str,
        negotiated_suite: impl Into<String>,
    ) -> bool {
        let Some(record) = self.sessions.get_mut(session_id) else {
            return false;
        };
        let now = OffsetDateTime::now_utc();
        let readiness = SessionReadiness::HandshakeComplete {
            session_id: record.session_id.clone(),
            negotiated_suite: negotiated_suite.into(),
        };
        record.readiness = readiness.clone();
        record.last_established_readiness = Some(readiness);
        record.transport_ready_at.get_or_insert(now);
        record.handshake_completed_at.get_or_insert(now);
        record.keepalive.last_activity_at = Some(now);
        record.updated_at = now;
        record.last_transport_error = None;
        reconcile_runtime_state(record);
        true
    }

    pub fn record_keepalive(
        &mut self,
        session_id: &str,
        kind: RuntimeSessionKeepaliveKind,
        ping_id: Option<u64>,
    ) -> bool {
        let Some(record) = self.sessions.get_mut(session_id) else {
            return false;
        };
        let now = OffsetDateTime::now_utc();
        record.keepalive.last_activity_at = Some(now);
        match kind {
            RuntimeSessionKeepaliveKind::HeartbeatSent => {
                record.keepalive.heartbeat_sent_count =
                    record.keepalive.heartbeat_sent_count.saturating_add(1);
                record.keepalive.last_heartbeat_sent_at = Some(now);
            }
            RuntimeSessionKeepaliveKind::HeartbeatReceived => {
                record.keepalive.heartbeat_received_count =
                    record.keepalive.heartbeat_received_count.saturating_add(1);
                record.keepalive.last_heartbeat_received_at = Some(now);
            }
            RuntimeSessionKeepaliveKind::PingSent => {
                record.keepalive.ping_sent_count =
                    record.keepalive.ping_sent_count.saturating_add(1);
                record.keepalive.last_ping_sent_at = Some(now);
                record.keepalive.last_ping_id = ping_id;
            }
            RuntimeSessionKeepaliveKind::PongReceived => {
                record.keepalive.pong_received_count =
                    record.keepalive.pong_received_count.saturating_add(1);
                record.keepalive.last_pong_received_at = Some(now);
                record.keepalive.last_pong_id = ping_id;
            }
            RuntimeSessionKeepaliveKind::PongReplied => {
                record.keepalive.pong_replied_count =
                    record.keepalive.pong_replied_count.saturating_add(1);
                record.keepalive.last_pong_replied_at = Some(now);
                record.keepalive.last_pong_id = ping_id;
            }
        }
        record.updated_at = now;
        reconcile_runtime_state(record);
        true
    }

    pub fn mark_transport_disconnected(
        &mut self,
        session_id: &str,
        reason: Option<String>,
    ) -> bool {
        let Some(record) = self.sessions.get_mut(session_id) else {
            return false;
        };
        preserve_established_readiness(record);
        record.readiness = SessionReadiness::Idle;
        record.transport_preserved = false;
        record.last_transport_error = reason.clone();
        record.last_error = reason;
        record.updated_at = OffsetDateTime::now_utc();
        record.state = RuntimeSessionState::Disconnected;
        record.closed_at = Some(record.updated_at);
        true
    }

    pub fn apply_transport_event(
        &mut self,
        session_id: &str,
        event: RuntimeSessionTransportEvent,
    ) -> bool {
        match event {
            RuntimeSessionTransportEvent::TransportReady => self.mark_transport_ready(session_id),
            RuntimeSessionTransportEvent::HandshakeComplete { negotiated_suite } => {
                self.mark_handshake_complete(session_id, negotiated_suite)
            }
            RuntimeSessionTransportEvent::Keepalive { kind, ping_id } => {
                self.record_keepalive(session_id, kind, ping_id)
            }
            RuntimeSessionTransportEvent::TransportDisconnected { reason } => {
                self.mark_transport_disconnected(session_id, reason)
            }
        }
    }

    pub fn update_remote_peer(
        &mut self,
        session_id: &str,
        remote_device_id: impl Into<String>,
        remote_device_name: Option<String>,
        remote_protocol_public_key_fingerprint: Option<String>,
    ) -> bool {
        let Some(record) = self.sessions.get_mut(session_id) else {
            return false;
        };
        record.remote_device_id = Some(remote_device_id.into());
        if remote_device_name.is_some() {
            record.remote_device_name = remote_device_name;
        }
        if remote_protocol_public_key_fingerprint.is_some() {
            record.remote_protocol_public_key_fingerprint = remote_protocol_public_key_fingerprint;
        }
        record.updated_at = OffsetDateTime::now_utc();
        true
    }
}

fn classify_health(failure_class: Option<crate::SignalingFailureClass>) -> SignalingSessionHealth {
    match failure_class {
        Some(
            crate::SignalingFailureClass::AuthBindRejected
            | crate::SignalingFailureClass::InvalidShardOrSessionMismatch
            | crate::SignalingFailureClass::TokenExpired
            | crate::SignalingFailureClass::ProtocolViolation,
        ) => SignalingSessionHealth::DegradedFatal,
        Some(
            crate::SignalingFailureClass::TransientNetwork
            | crate::SignalingFailureClass::TransientServer,
        )
        | None => SignalingSessionHealth::DegradedRecoverable,
    }
}

pub fn make_runtime_id(session_id: &str) -> String {
    format!("session-runtime:{session_id}:{}", uuid::Uuid::now_v7())
}

fn transport_established(record: &RuntimeSessionRecord) -> bool {
    record
        .readiness
        .is_transport_established_for(&record.session_id)
}

fn preserve_established_readiness(record: &mut RuntimeSessionRecord) {
    if record
        .readiness
        .is_transport_established_for(&record.session_id)
    {
        record.last_established_readiness = Some(record.readiness.clone());
    }
}

fn reconcile_runtime_state(record: &mut RuntimeSessionRecord) {
    let transport_established = transport_established(record);
    record.transport_preserved =
        transport_established && record.lifecycle_phase != SignalingLifecyclePhase::Bound;

    if transport_established {
        record.state = if record.lifecycle_phase == SignalingLifecyclePhase::Bound {
            RuntimeSessionState::Bound
        } else {
            RuntimeSessionState::Degraded
        };
        record.closed_at = None;
        return;
    }

    match record.lifecycle_phase {
        SignalingLifecyclePhase::Idle => {
            record.state = RuntimeSessionState::Pending;
            record.closed_at = None;
        }
        SignalingLifecyclePhase::Connecting
        | SignalingLifecyclePhase::SocketOpen
        | SignalingLifecyclePhase::Reconnecting => {
            record.state = RuntimeSessionState::Connecting;
            record.closed_at = None;
        }
        SignalingLifecyclePhase::Bound => {
            record.state = RuntimeSessionState::Bound;
            record.closed_at = None;
        }
        SignalingLifecyclePhase::Closing | SignalingLifecyclePhase::Closed => {
            record.state = RuntimeSessionState::Disconnected;
            record.closed_at = Some(record.updated_at);
        }
        SignalingLifecyclePhase::Failed => {
            record.state = RuntimeSessionState::Failed;
            record.closed_at = Some(record.updated_at);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{SignalingFailureClass, SignalingHandleId};

    #[test]
    fn registry_applies_bound_and_failure_transitions() {
        let mut registry = SessionRegistry::default();
        registry.insert(RuntimeSessionRecord::new(
            make_runtime_id("session-1"),
            "session-1",
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "device-local",
            Some("device-remote".to_owned()),
            None,
            None,
            RuntimeSessionState::Connecting,
        ));

        let handle = SignalingHandleId {
            session_id: "session-1".to_owned(),
            backend: SignalingBackend::Native,
            generation: 1,
        };
        registry.apply_signaling_event(
            "session-1",
            &SignalingLifecycleEvent::new(handle.clone(), SignalingLifecyclePhase::Bound),
        );
        let record = registry.get("session-1").unwrap();
        assert_eq!(record.state, RuntimeSessionState::Bound);
        assert_eq!(record.signaling_backend, Some(SignalingBackend::Native));

        registry.apply_signaling_event(
            "session-1",
            &SignalingLifecycleEvent {
                handle_id: handle,
                phase: SignalingLifecyclePhase::Failed,
                server_frame_type: None,
                failure_class: Some(SignalingFailureClass::TransientNetwork),
                error_description: Some("network".to_owned()),
                occurred_at: OffsetDateTime::now_utc(),
            },
        );
        let record = registry.get("session-1").unwrap();
        assert_eq!(record.state, RuntimeSessionState::Failed);
    }

    #[test]
    fn active_count_ignores_disconnected_sessions() {
        let mut registry = SessionRegistry::default();
        registry.insert(RuntimeSessionRecord::new(
            make_runtime_id("a"),
            "a",
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            None,
            None,
            None,
            RuntimeSessionState::Connecting,
        ));
        registry.insert(RuntimeSessionRecord::new(
            make_runtime_id("b"),
            "b",
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            None,
            None,
            None,
            RuntimeSessionState::Disconnected,
        ));
        assert_eq!(registry.active_count(), 1);
    }

    #[test]
    fn closed_signaling_preserves_established_transport() {
        let mut registry = SessionRegistry::default();
        registry.insert(RuntimeSessionRecord::new(
            make_runtime_id("session-preserved"),
            "session-preserved",
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            Some("remote".to_owned()),
            None,
            None,
            RuntimeSessionState::Connecting,
        ));

        let handle = SignalingHandleId {
            session_id: "session-preserved".to_owned(),
            backend: SignalingBackend::Native,
            generation: 3,
        };
        registry.apply_signaling_event(
            "session-preserved",
            &SignalingLifecycleEvent::new(handle.clone(), SignalingLifecyclePhase::Bound),
        );
        assert!(registry.mark_transport_ready("session-preserved"));

        registry.apply_signaling_event(
            "session-preserved",
            &SignalingLifecycleEvent::new(handle, SignalingLifecyclePhase::Closed),
        );

        let record = registry.get("session-preserved").unwrap();
        assert_eq!(record.state, RuntimeSessionState::Degraded);
        assert!(record.transport_preserved);
        assert_eq!(
            record.readiness,
            SessionReadiness::TransportReady {
                session_id: "session-preserved".to_owned(),
            }
        );
        assert_eq!(
            record.last_established_readiness,
            Some(SessionReadiness::TransportReady {
                session_id: "session-preserved".to_owned(),
            })
        );
        assert!(record.closed_at.is_none());
    }

    #[test]
    fn handshake_completion_persists_negotiated_suite() {
        let mut registry = SessionRegistry::default();
        registry.insert(RuntimeSessionRecord::new(
            make_runtime_id("session-suite"),
            "session-suite",
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            Some("remote".to_owned()),
            None,
            None,
            RuntimeSessionState::Connecting,
        ));

        let handle = SignalingHandleId {
            session_id: "session-suite".to_owned(),
            backend: SignalingBackend::Native,
            generation: 1,
        };
        registry.apply_signaling_event(
            "session-suite",
            &SignalingLifecycleEvent::new(handle, SignalingLifecyclePhase::Bound),
        );
        assert!(registry.mark_handshake_complete("session-suite", "X25519+ML-KEM-768"));

        let record = registry.get("session-suite").unwrap();
        assert_eq!(record.state, RuntimeSessionState::Bound);
        assert_eq!(
            record.readiness,
            SessionReadiness::HandshakeComplete {
                session_id: "session-suite".to_owned(),
                negotiated_suite: "X25519+ML-KEM-768".to_owned(),
            }
        );
        assert_eq!(
            record.last_established_readiness,
            Some(SessionReadiness::HandshakeComplete {
                session_id: "session-suite".to_owned(),
                negotiated_suite: "X25519+ML-KEM-768".to_owned(),
            })
        );
    }

    #[test]
    fn transport_disconnect_clears_preservation_and_closes_session() {
        let mut registry = SessionRegistry::default();
        registry.insert(RuntimeSessionRecord::new(
            make_runtime_id("session-drop"),
            "session-drop",
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            Some("remote".to_owned()),
            None,
            None,
            RuntimeSessionState::Connecting,
        ));
        let handle = SignalingHandleId {
            session_id: "session-drop".to_owned(),
            backend: SignalingBackend::Native,
            generation: 1,
        };
        registry.apply_signaling_event(
            "session-drop",
            &SignalingLifecycleEvent::new(handle, SignalingLifecyclePhase::Bound),
        );
        assert!(registry.mark_transport_ready("session-drop"));
        assert!(
            registry.mark_transport_disconnected(
                "session-drop",
                Some("data_channel_closed".to_owned())
            )
        );

        let record = registry.get("session-drop").unwrap();
        assert_eq!(record.state, RuntimeSessionState::Disconnected);
        assert!(!record.transport_preserved);
        assert_eq!(record.readiness, SessionReadiness::Idle);
        assert_eq!(
            record.last_established_readiness,
            Some(SessionReadiness::TransportReady {
                session_id: "session-drop".to_owned(),
            })
        );
        assert_eq!(
            record.last_transport_error.as_deref(),
            Some("data_channel_closed")
        );
        assert!(record.closed_at.is_some());
    }

    #[test]
    fn keepalive_activity_is_recorded_for_established_transport() {
        let mut registry = SessionRegistry::default();
        registry.insert(RuntimeSessionRecord::new(
            make_runtime_id("session-keepalive"),
            "session-keepalive",
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            Some("remote".to_owned()),
            None,
            None,
            RuntimeSessionState::Connecting,
        ));

        let handle = SignalingHandleId {
            session_id: "session-keepalive".to_owned(),
            backend: SignalingBackend::Native,
            generation: 1,
        };
        registry.apply_signaling_event(
            "session-keepalive",
            &SignalingLifecycleEvent::new(handle, SignalingLifecyclePhase::Bound),
        );
        assert!(registry.mark_handshake_complete("session-keepalive", "X25519"));
        assert!(registry.record_keepalive(
            "session-keepalive",
            RuntimeSessionKeepaliveKind::HeartbeatSent,
            None,
        ));
        assert!(registry.record_keepalive(
            "session-keepalive",
            RuntimeSessionKeepaliveKind::PingSent,
            Some(7),
        ));
        assert!(registry.record_keepalive(
            "session-keepalive",
            RuntimeSessionKeepaliveKind::PongReceived,
            Some(7),
        ));

        let record = registry.get("session-keepalive").unwrap();
        assert_eq!(record.state, RuntimeSessionState::Bound);
        assert!(record.transport_ready_at.is_some());
        assert!(record.handshake_completed_at.is_some());
        assert_eq!(record.keepalive.heartbeat_sent_count, 1);
        assert_eq!(record.keepalive.ping_sent_count, 1);
        assert_eq!(record.keepalive.pong_received_count, 1);
        assert_eq!(record.keepalive.last_ping_id, Some(7));
        assert_eq!(record.keepalive.last_pong_id, Some(7));
        assert!(record.keepalive.last_activity_at.is_some());
    }

    #[test]
    fn keepalive_after_signaling_close_preserves_transport_state() {
        let mut registry = SessionRegistry::default();
        registry.insert(RuntimeSessionRecord::new(
            make_runtime_id("session-keepalive-preserved"),
            "session-keepalive-preserved",
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            Some("remote".to_owned()),
            None,
            None,
            RuntimeSessionState::Connecting,
        ));

        let handle = SignalingHandleId {
            session_id: "session-keepalive-preserved".to_owned(),
            backend: SignalingBackend::Native,
            generation: 2,
        };
        registry.apply_signaling_event(
            "session-keepalive-preserved",
            &SignalingLifecycleEvent::new(handle.clone(), SignalingLifecyclePhase::Bound),
        );
        assert!(registry.mark_transport_ready("session-keepalive-preserved"));
        registry.apply_signaling_event(
            "session-keepalive-preserved",
            &SignalingLifecycleEvent::new(handle, SignalingLifecyclePhase::Closed),
        );
        assert!(registry.record_keepalive(
            "session-keepalive-preserved",
            RuntimeSessionKeepaliveKind::HeartbeatReceived,
            None,
        ));

        let record = registry.get("session-keepalive-preserved").unwrap();
        assert_eq!(record.state, RuntimeSessionState::Degraded);
        assert!(record.transport_preserved);
        assert_eq!(record.keepalive.heartbeat_received_count, 1);
        assert!(record.keepalive.last_heartbeat_received_at.is_some());
        assert!(record.keepalive.last_activity_at.is_some());
    }

    #[test]
    fn explicit_disconnect_keeps_last_established_readiness_for_inspection() {
        let mut registry = SessionRegistry::default();
        registry.insert(RuntimeSessionRecord::new(
            make_runtime_id("session-explicit-stop"),
            "session-explicit-stop",
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            Some("remote".to_owned()),
            None,
            None,
            RuntimeSessionState::Connecting,
        ));
        let handle = SignalingHandleId {
            session_id: "session-explicit-stop".to_owned(),
            backend: SignalingBackend::Native,
            generation: 7,
        };
        registry.apply_signaling_event(
            "session-explicit-stop",
            &SignalingLifecycleEvent::new(handle, SignalingLifecyclePhase::Bound),
        );
        assert!(registry.mark_handshake_complete("session-explicit-stop", "X-Wing"));
        assert!(registry.mark_disconnected(
            "session-explicit-stop",
            Some("operator_requested".to_owned())
        ));

        let record = registry.get("session-explicit-stop").unwrap();
        assert_eq!(record.state, RuntimeSessionState::Disconnected);
        assert_eq!(record.readiness, SessionReadiness::Idle);
        assert_eq!(
            record.last_established_readiness,
            Some(SessionReadiness::HandshakeComplete {
                session_id: "session-explicit-stop".to_owned(),
                negotiated_suite: "X-Wing".to_owned(),
            })
        );
        assert_eq!(
            record.effective_established_readiness(),
            record.last_established_readiness.as_ref()
        );
    }
}
