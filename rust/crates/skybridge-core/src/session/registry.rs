use std::collections::BTreeMap;

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::{
    SessionReadiness, SignalingLifecycleEvent, SignalingLifecyclePhase, SignalingSessionHealth,
};

use super::{
    ManagedSessionControl, ManagedSessionDesiredState, RuntimeAuthenticatedPeerObservation,
    RuntimeSelectedIceRouteObservation, RuntimeSessionKeepaliveKind, RuntimeSessionRecord,
    RuntimeSessionRouteKind, RuntimeSessionState, RuntimeSessionTransportEvent,
};

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
    /// Agent-global bound on persisted managed-session controls. Stopped
    /// controls are retained as retry/diagnostic anchors until space is needed.
    pub const MAX_SESSIONS: usize = 32;

    pub fn insert(&mut self, control: ManagedSessionControl) -> Result<()> {
        let session_id = control.session_id.clone();
        if !self.sessions.contains_key(&session_id) {
            while self.sessions.len() >= Self::MAX_SESSIONS {
                let Some(oldest_stopped_id) = self
                    .sessions
                    .values()
                    .filter(|existing| {
                        existing.desired_state == ManagedSessionDesiredState::Stopped
                    })
                    .min_by(|left, right| {
                        left.updated_at
                            .cmp(&right.updated_at)
                            .then_with(|| left.session_id.cmp(&right.session_id))
                    })
                    .map(|existing| existing.session_id.clone())
                else {
                    bail!("managed session control registry is full with active sessions");
                };
                self.sessions.remove(&oldest_stopped_id);
            }
        }
        self.sessions.insert(session_id, control);
        Ok(())
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
    /// Agent-global bound on current and retained terminal runtime records.
    pub const MAX_SESSIONS: usize = ManagedSessionControlRegistry::MAX_SESSIONS;

    pub fn insert(&mut self, record: RuntimeSessionRecord) -> Result<()> {
        let session_id = record.session_id.clone();
        if !self.sessions.contains_key(&session_id) {
            while self.sessions.len() >= Self::MAX_SESSIONS {
                let Some(oldest_terminal_id) = self
                    .sessions
                    .values()
                    .filter(|existing| !existing.is_active())
                    .min_by(|left, right| {
                        left.updated_at
                            .cmp(&right.updated_at)
                            .then_with(|| left.session_id.cmp(&right.session_id))
                    })
                    .map(|existing| existing.session_id.clone())
                else {
                    bail!("session registry is full with active sessions");
                };
                self.sessions.remove(&oldest_terminal_id);
            }
        }
        self.sessions.insert(session_id, record);
        Ok(())
    }

    pub fn get(&self, session_id: &str) -> Option<&RuntimeSessionRecord> {
        self.sessions.get(session_id)
    }

    pub fn values_sorted(&self) -> Vec<RuntimeSessionRecord> {
        let mut values = self.sessions.values().cloned().collect::<Vec<_>>();
        values.sort_by_key(|record| std::cmp::Reverse(record.updated_at));
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
        if runtime_session_is_terminal(record) {
            return;
        }
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
        if runtime_session_is_terminal(record) {
            return false;
        }
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
        peer_protocol_public_key_fingerprint: impl Into<String>,
    ) -> bool {
        let Some(record) = self.sessions.get_mut(session_id) else {
            return false;
        };
        if runtime_session_is_terminal(record) {
            return false;
        }
        let observed_fingerprint = peer_protocol_public_key_fingerprint.into();
        if let Some(expected_fingerprint) = record.remote_protocol_public_key_fingerprint.as_deref()
            && !expected_fingerprint.eq_ignore_ascii_case(&observed_fingerprint)
        {
            let now = OffsetDateTime::now_utc();
            let reason = "peer protocol identity fingerprint mismatch".to_owned();
            preserve_established_readiness(record);
            record.readiness = SessionReadiness::Idle;
            record.transport_preserved = false;
            record.state = RuntimeSessionState::Failed;
            record.last_error = Some(reason.clone());
            record.last_transport_error = Some(reason);
            record.updated_at = now;
            record.closed_at = Some(now);
            return false;
        }
        let now = OffsetDateTime::now_utc();
        record.remote_protocol_public_key_fingerprint = Some(observed_fingerprint);
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
        if runtime_session_is_terminal(record) {
            return false;
        }
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

    pub fn record_authenticated_peer_heartbeat(
        &mut self,
        session_id: &str,
        mut observation: RuntimeAuthenticatedPeerObservation,
    ) -> bool {
        let Some(record) = self.sessions.get_mut(session_id) else {
            return false;
        };
        if runtime_session_is_terminal(record) {
            return false;
        }
        let handshake_is_current = matches!(
            &record.readiness,
            SessionReadiness::HandshakeComplete {
                session_id: established_session_id,
                ..
            } if established_session_id == session_id
        );
        if !handshake_is_current {
            return fail_runtime_protocol(
                record,
                "authenticated peer heartbeat arrived before handshake completion",
            );
        }
        let canonical_device_id = observation.device_id.trim();
        if canonical_device_id.is_empty()
            || canonical_device_id != observation.device_id
            || canonical_device_id.len() > 256
            || canonical_device_id.chars().any(char::is_control)
        {
            return fail_runtime_protocol(
                record,
                "authenticated peer heartbeat contained an invalid device identity",
            );
        }
        if record.remote_device_id.as_deref() != Some(canonical_device_id) {
            return fail_runtime_protocol(
                record,
                "authenticated peer heartbeat did not match the session peer identity",
            );
        }
        let canonical_name = observation.device_name.trim();
        if canonical_name.is_empty()
            || canonical_name != observation.device_name
            || canonical_name.len() > 4 * 1024
            || canonical_name.chars().any(char::is_control)
        {
            return fail_runtime_protocol(
                record,
                "authenticated peer heartbeat contained an invalid device name",
            );
        }
        if observation.sbwc_counter == 0
            || record
                .authenticated_peer
                .as_ref()
                .is_some_and(|previous| observation.sbwc_counter <= previous.sbwc_counter)
        {
            return fail_runtime_protocol(
                record,
                "authenticated peer heartbeat counter did not advance",
            );
        }
        if record
            .handshake_completed_at
            .is_none_or(|completed_at| observation.observed_at < completed_at)
        {
            return fail_runtime_protocol(
                record,
                "authenticated peer heartbeat observation predates the current handshake",
            );
        }
        if let Some(capabilities) = observation.capabilities.as_mut() {
            capabilities.sort();
            capabilities.dedup();
        }
        record.remote_device_name = Some(observation.device_name.clone());
        record.authenticated_peer = Some(observation);
        record.updated_at = OffsetDateTime::now_utc();
        true
    }

    pub fn record_selected_ice_route(
        &mut self,
        session_id: &str,
        observation: RuntimeSelectedIceRouteObservation,
    ) -> bool {
        let Some(record) = self.sessions.get_mut(session_id) else {
            return false;
        };
        if runtime_session_is_terminal(record) {
            return false;
        }
        let handshake_is_current = matches!(
            &record.readiness,
            SessionReadiness::HandshakeComplete {
                session_id: established_session_id,
                ..
            } if established_session_id == session_id
        );
        if !handshake_is_current {
            return fail_runtime_protocol(
                record,
                "selected ICE route arrived before handshake completion",
            );
        }
        let Ok(remote_ip) = observation.remote_address.parse::<std::net::IpAddr>() else {
            return fail_runtime_protocol(record, "selected ICE route has no numeric remote IP");
        };
        if remote_ip.is_unspecified() || remote_ip.is_multicast() || observation.remote_port == 0 {
            return fail_runtime_protocol(record, "selected ICE route endpoint is invalid");
        }
        if !matches!(observation.protocol.as_str(), "udp" | "tcp") {
            return fail_runtime_protocol(record, "selected ICE route protocol is unsupported");
        }
        let valid_candidate_type =
            |value: &str| matches!(value, "host" | "srflx" | "prflx" | "relay");
        if !valid_candidate_type(&observation.local_candidate_type)
            || !valid_candidate_type(&observation.remote_candidate_type)
        {
            return fail_runtime_protocol(
                record,
                "selected ICE route contains an unsupported candidate type",
            );
        }
        let expected_kind = if observation.local_candidate_type == "relay"
            || observation.remote_candidate_type == "relay"
        {
            RuntimeSessionRouteKind::Relay
        } else {
            RuntimeSessionRouteKind::Direct
        };
        if observation.kind != expected_kind {
            return fail_runtime_protocol(record, "selected ICE route kind is inconsistent");
        }
        if record
            .handshake_completed_at
            .is_none_or(|completed_at| observation.observed_at < completed_at)
        {
            return fail_runtime_protocol(
                record,
                "selected ICE route observation predates the current handshake",
            );
        }
        record.selected_ice_route = Some(observation);
        record.updated_at = OffsetDateTime::now_utc();
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
        if runtime_session_is_terminal(record) {
            return false;
        }
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
            RuntimeSessionTransportEvent::HandshakeComplete {
                negotiated_suite,
                peer_protocol_public_key_fingerprint,
            } => self.mark_handshake_complete(
                session_id,
                negotiated_suite,
                peer_protocol_public_key_fingerprint,
            ),
            RuntimeSessionTransportEvent::Keepalive { kind, ping_id } => {
                self.record_keepalive(session_id, kind, ping_id)
            }
            RuntimeSessionTransportEvent::AuthenticatedPeerHeartbeat(observation) => {
                self.record_authenticated_peer_heartbeat(session_id, *observation)
            }
            RuntimeSessionTransportEvent::SelectedIceRoute(observation) => {
                self.record_selected_ice_route(session_id, *observation)
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
        if runtime_session_is_terminal(record) {
            return false;
        }
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

fn fail_runtime_protocol(record: &mut RuntimeSessionRecord, reason: &str) -> bool {
    let now = OffsetDateTime::now_utc();
    preserve_established_readiness(record);
    record.readiness = SessionReadiness::Idle;
    record.transport_preserved = false;
    record.state = RuntimeSessionState::Failed;
    record.last_error = Some(reason.to_owned());
    record.last_transport_error = Some(reason.to_owned());
    record.updated_at = now;
    record.closed_at = Some(now);
    false
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
    if runtime_session_is_terminal(record) {
        return;
    }
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

fn runtime_session_is_terminal(record: &RuntimeSessionRecord) -> bool {
    matches!(
        record.state,
        RuntimeSessionState::Disconnected | RuntimeSessionState::Failed
    )
}
