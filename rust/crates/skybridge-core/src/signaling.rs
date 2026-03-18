use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use thiserror::Error;
use time::OffsetDateTime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SignalingBackend {
    UrlSession,
    Native,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SignalingLifecyclePhase {
    Idle,
    Connecting,
    SocketOpen,
    Bound,
    Reconnecting,
    Closing,
    Closed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SignalingFailureClass {
    AuthBindRejected,
    InvalidShardOrSessionMismatch,
    TokenExpired,
    TransientNetwork,
    TransientServer,
    ProtocolViolation,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SignalingSessionHealth {
    Healthy,
    DegradedRecoverable,
    DegradedFatal,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct SignalingHandleId {
    pub session_id: String,
    pub backend: SignalingBackend,
    pub generation: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignalingLifecycleEvent {
    pub handle_id: SignalingHandleId,
    pub phase: SignalingLifecyclePhase,
    pub server_frame_type: Option<String>,
    pub failure_class: Option<SignalingFailureClass>,
    pub error_description: Option<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub occurred_at: OffsetDateTime,
}

impl SignalingLifecycleEvent {
    pub fn new(handle_id: SignalingHandleId, phase: SignalingLifecyclePhase) -> Self {
        Self {
            handle_id,
            phase,
            server_frame_type: None,
            failure_class: None,
            error_description: None,
            occurred_at: OffsetDateTime::now_utc(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SessionReadiness {
    Idle,
    TransportReady {
        session_id: String,
    },
    HandshakeComplete {
        session_id: String,
        negotiated_suite: String,
    },
}

impl Default for SessionReadiness {
    fn default() -> Self {
        Self::Idle
    }
}

impl SessionReadiness {
    pub fn is_transport_established_for(&self, session_id: &str) -> bool {
        match self {
            SessionReadiness::Idle => false,
            SessionReadiness::TransportReady {
                session_id: current,
            } => current == session_id,
            SessionReadiness::HandshakeComplete {
                session_id: current,
                ..
            } => current == session_id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignalingState {
    pub active_handle: Option<SignalingHandleId>,
    pub lifecycle_phase: SignalingLifecyclePhase,
    pub health: SignalingSessionHealth,
    pub readiness: SessionReadiness,
    pub generation_by_session_id: BTreeMap<String, u32>,
    pub signaling_shard_key: Option<String>,
}

impl Default for SignalingState {
    fn default() -> Self {
        Self {
            active_handle: None,
            lifecycle_phase: SignalingLifecyclePhase::Idle,
            health: SignalingSessionHealth::Healthy,
            readiness: SessionReadiness::Idle,
            generation_by_session_id: BTreeMap::new(),
            signaling_shard_key: None,
        }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SignalingOperationRejection {
    #[error("当前 signaling 处于 degraded-fatal，已封禁新的 signaling 操作: {0}")]
    DegradedFatal(String),
}

impl SignalingState {
    pub fn seed(
        &mut self,
        session_id: impl Into<String>,
        generation: u32,
        handle: SignalingHandleId,
        health: SignalingSessionHealth,
        phase: SignalingLifecyclePhase,
    ) {
        let session_id = session_id.into();
        self.generation_by_session_id
            .insert(session_id.clone(), generation);
        self.signaling_shard_key = Some(session_id);
        self.active_handle = Some(handle);
        self.health = health;
        self.lifecycle_phase = phase;
    }

    pub fn current_generation(&self, session_id: &str) -> u32 {
        self.generation_by_session_id
            .get(session_id)
            .copied()
            .unwrap_or_default()
    }

    pub fn mark_transport_ready(&mut self, session_id: impl Into<String>) {
        self.readiness = SessionReadiness::TransportReady {
            session_id: session_id.into(),
        };
    }

    pub fn mark_handshake_complete(
        &mut self,
        session_id: impl Into<String>,
        negotiated_suite: impl Into<String>,
    ) {
        self.readiness = SessionReadiness::HandshakeComplete {
            session_id: session_id.into(),
            negotiated_suite: negotiated_suite.into(),
        };
    }

    pub fn can_perform_operation(
        &self,
        session_id: &str,
    ) -> Result<(), SignalingOperationRejection> {
        if self.health == SignalingSessionHealth::DegradedFatal
            && self.signaling_shard_key.as_deref() == Some(session_id)
        {
            return Err(SignalingOperationRejection::DegradedFatal(
                session_id.to_owned(),
            ));
        }
        Ok(())
    }

    pub fn apply_lifecycle_event(&mut self, event: SignalingLifecycleEvent) {
        let session_id = event.handle_id.session_id.clone();
        let current_generation = self.current_generation(&session_id);

        if event.handle_id.generation < current_generation {
            return;
        }

        if event.handle_id.generation > current_generation {
            self.generation_by_session_id
                .insert(session_id.clone(), event.handle_id.generation);
        }

        if event.handle_id.generation != self.current_generation(&session_id) {
            return;
        }

        match event.phase {
            SignalingLifecyclePhase::Connecting
            | SignalingLifecyclePhase::SocketOpen
            | SignalingLifecyclePhase::Bound
            | SignalingLifecyclePhase::Reconnecting => {
                self.active_handle = Some(event.handle_id.clone());
                self.signaling_shard_key = Some(session_id.clone());
                self.lifecycle_phase = event.phase;
                if matches!(event.phase, SignalingLifecyclePhase::Bound) {
                    self.health = SignalingSessionHealth::Healthy;
                } else if self.readiness.is_transport_established_for(&session_id) {
                    self.health = SignalingSessionHealth::DegradedRecoverable;
                }
            }
            SignalingLifecyclePhase::Closing | SignalingLifecyclePhase::Closed => {
                if self.active_handle.as_ref() == Some(&event.handle_id) {
                    self.lifecycle_phase = event.phase;
                    if matches!(event.phase, SignalingLifecyclePhase::Closed)
                        && !self.readiness.is_transport_established_for(&session_id)
                    {
                        self.active_handle = None;
                        self.signaling_shard_key = None;
                    }
                }
            }
            SignalingLifecyclePhase::Failed => {
                self.lifecycle_phase = SignalingLifecyclePhase::Failed;
                self.health = failure_to_health(event.failure_class);
                if !self.readiness.is_transport_established_for(&session_id)
                    && self.active_handle.as_ref() == Some(&event.handle_id)
                {
                    self.active_handle = None;
                    self.signaling_shard_key = None;
                    self.readiness = SessionReadiness::Idle;
                }
            }
            SignalingLifecyclePhase::Idle => {}
        }
    }
}

fn failure_to_health(failure: Option<SignalingFailureClass>) -> SignalingSessionHealth {
    match failure {
        Some(
            SignalingFailureClass::AuthBindRejected
            | SignalingFailureClass::InvalidShardOrSessionMismatch
            | SignalingFailureClass::TokenExpired
            | SignalingFailureClass::ProtocolViolation,
        ) => SignalingSessionHealth::DegradedFatal,
        Some(SignalingFailureClass::TransientNetwork | SignalingFailureClass::TransientServer)
        | None => SignalingSessionHealth::DegradedRecoverable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn older_generation_open_and_bound_cannot_override_current_handle() {
        let current_handle = SignalingHandleId {
            session_id: "SESSION-A".to_owned(),
            backend: SignalingBackend::UrlSession,
            generation: 2,
        };
        let mut state = SignalingState::default();
        state.seed(
            "SESSION-A",
            2,
            current_handle.clone(),
            SignalingSessionHealth::Healthy,
            SignalingLifecyclePhase::Connecting,
        );

        state.apply_lifecycle_event(SignalingLifecycleEvent::new(
            SignalingHandleId {
                session_id: "SESSION-A".to_owned(),
                backend: SignalingBackend::Native,
                generation: 1,
            },
            SignalingLifecyclePhase::SocketOpen,
        ));
        assert_eq!(state.active_handle, Some(current_handle.clone()));
        assert_eq!(state.lifecycle_phase, SignalingLifecyclePhase::Connecting);

        state.apply_lifecycle_event(SignalingLifecycleEvent::new(
            SignalingHandleId {
                session_id: "SESSION-A".to_owned(),
                backend: SignalingBackend::Native,
                generation: 1,
            },
            SignalingLifecyclePhase::Bound,
        ));
        assert_eq!(state.active_handle, Some(current_handle));
        assert_eq!(state.lifecycle_phase, SignalingLifecyclePhase::Connecting);
        assert_eq!(state.health, SignalingSessionHealth::Healthy);
    }

    #[test]
    fn post_transport_fatal_failure_becomes_degraded_fatal_without_dropping_readiness() {
        let current_handle = SignalingHandleId {
            session_id: "SESSION-B".to_owned(),
            backend: SignalingBackend::UrlSession,
            generation: 4,
        };
        let mut state = SignalingState::default();
        state.seed(
            "SESSION-B",
            4,
            current_handle.clone(),
            SignalingSessionHealth::Healthy,
            SignalingLifecyclePhase::Bound,
        );
        state.mark_handshake_complete("SESSION-B", "X25519");

        let mut failed =
            SignalingLifecycleEvent::new(current_handle, SignalingLifecyclePhase::Failed);
        failed.failure_class = Some(SignalingFailureClass::AuthBindRejected);
        failed.error_description = Some("unauthorized".to_owned());
        state.apply_lifecycle_event(failed);

        assert_eq!(state.health, SignalingSessionHealth::DegradedFatal);
        assert_eq!(
            state.readiness,
            SessionReadiness::HandshakeComplete {
                session_id: "SESSION-B".to_owned(),
                negotiated_suite: "X25519".to_owned(),
            }
        );
        assert_eq!(
            state.can_perform_operation("SESSION-B"),
            Err(SignalingOperationRejection::DegradedFatal(
                "SESSION-B".to_owned()
            ))
        );
    }
}
