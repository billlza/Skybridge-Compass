use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

use crate::{SignalingBackend, SignalingLifecyclePhase, SignalingSessionHealth};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventLevel {
    Trace,
    Info,
    Warn,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StructuredEvent {
    pub schema_version: u32,
    #[serde(with = "time::serde::rfc3339")]
    pub at: OffsetDateTime,
    pub level: EventLevel,
    pub kind: String,
    pub message: String,
    pub session_id: Option<String>,
    pub role: Option<String>,
    pub backend: Option<SignalingBackend>,
    pub generation: Option<u32>,
    pub lifecycle_phase: Option<SignalingLifecyclePhase>,
    pub signaling_health: Option<SignalingSessionHealth>,
    pub negotiated_suite: Option<String>,
    pub route_source: Option<String>,
    pub transfer_address: Option<String>,
    pub transfer_port: Option<u16>,
    pub reconnect_attempt_count: Option<u32>,
    pub fallback_invocation_count: Option<u32>,
}

impl StructuredEvent {
    pub const SCHEMA_VERSION: u32 = 1;

    pub fn new(level: EventLevel, kind: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            at: OffsetDateTime::now_utc(),
            level,
            kind: kind.into(),
            message: message.into(),
            session_id: None,
            role: None,
            backend: None,
            generation: None,
            lifecycle_phase: None,
            signaling_health: None,
            negotiated_suite: None,
            route_source: None,
            transfer_address: None,
            transfer_port: None,
            reconnect_attempt_count: None,
            fallback_invocation_count: None,
        }
    }

    pub fn with_session(mut self, session_id: impl Into<String>, role: impl Into<String>) -> Self {
        self.session_id = Some(session_id.into());
        self.role = Some(role.into());
        self
    }

    pub fn with_signaling(
        mut self,
        backend: SignalingBackend,
        generation: u32,
        lifecycle_phase: SignalingLifecyclePhase,
        signaling_health: SignalingSessionHealth,
    ) -> Self {
        self.backend = Some(backend);
        self.generation = Some(generation);
        self.lifecycle_phase = Some(lifecycle_phase);
        self.signaling_health = Some(signaling_health);
        self
    }

    pub fn with_route(
        mut self,
        route_source: impl Into<String>,
        transfer_address: impl Into<String>,
        transfer_port: u16,
    ) -> Self {
        self.route_source = Some(route_source.into());
        self.transfer_address = Some(transfer_address.into());
        self.transfer_port = Some(transfer_port);
        self
    }

    pub fn with_fallback_count(mut self, count: u32) -> Self {
        self.fallback_invocation_count = Some(count);
        self
    }
}
