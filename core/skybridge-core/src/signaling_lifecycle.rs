#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum SignalingReadiness {
    Idle,
    TransportReady,
    HandshakeComplete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignalingHealth {
    Healthy,
    DegradedRecoverable,
    DegradedFatal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignalingFailureClass {
    None,
    AuthBindRejected,
    InvalidShardOrSessionMismatch,
    TokenExpired,
    ProtocolViolation,
    TransientNetwork,
    TransientServer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignalingLifecycleEventKind {
    Connecting,
    SocketOpen,
    Bound,
    Reconnecting,
    Closing,
    Closed,
    TransportReady,
    HandshakeComplete,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignalingLifecycleState {
    pub session_id: String,
    pub backend: String,
    pub generation: u64,
    pub lifecycle_phase: SignalingLifecyclePhase,
    pub signaling_health: SignalingHealth,
    pub readiness: SignalingReadiness,
    pub last_established_readiness: SignalingReadiness,
    pub failure_class: SignalingFailureClass,
    pub negotiated_suite: Option<String>,
    pub reconnect_attempt_count: u32,
}

impl SignalingLifecycleState {
    pub fn idle() -> Self {
        Self {
            session_id: String::new(),
            backend: String::new(),
            generation: 0,
            lifecycle_phase: SignalingLifecyclePhase::Idle,
            signaling_health: SignalingHealth::Healthy,
            readiness: SignalingReadiness::Idle,
            last_established_readiness: SignalingReadiness::Idle,
            failure_class: SignalingFailureClass::None,
            negotiated_suite: None,
            reconnect_attempt_count: 0,
        }
    }

    pub fn business_sends_allowed(&self) -> bool {
        self.lifecycle_phase == SignalingLifecyclePhase::Bound
    }

    pub fn can_report_connected(&self) -> bool {
        self.lifecycle_phase == SignalingLifecyclePhase::Bound
            && self.signaling_health != SignalingHealth::DegradedFatal
            && matches!(
                self.readiness,
                SignalingReadiness::TransportReady | SignalingReadiness::HandshakeComplete
            )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignalingLifecycleEvent {
    pub session_id: String,
    pub backend: String,
    pub generation: u64,
    pub kind: SignalingLifecycleEventKind,
    pub failure_class: SignalingFailureClass,
    pub negotiated_suite: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignalingLifecycleError {
    MissingSessionId,
    MissingBackend,
    FailedEventRequiresFailureClass,
    HandshakeCompleteRequiresNegotiatedSuite,
    ReadinessRequiresBound,
}

pub fn project_signaling_lifecycle(
    current: SignalingLifecycleState,
    event: SignalingLifecycleEvent,
) -> Result<SignalingLifecycleState, SignalingLifecycleError> {
    validate_event(&event)?;

    if is_stale_generation(&current, &event) {
        return Ok(current);
    }

    let mut next = if should_replace_handle(&current, &event) {
        SignalingLifecycleState {
            session_id: event.session_id.clone(),
            backend: event.backend.clone(),
            generation: event.generation,
            ..SignalingLifecycleState::idle()
        }
    } else {
        let mut state = current;
        state.session_id = event.session_id.clone();
        state.backend = event.backend.clone();
        state.generation = event.generation;
        state
    };

    if matches!(
        event.kind,
        SignalingLifecycleEventKind::TransportReady
            | SignalingLifecycleEventKind::HandshakeComplete
    ) && next.lifecycle_phase != SignalingLifecyclePhase::Bound
    {
        return Err(SignalingLifecycleError::ReadinessRequiresBound);
    }

    match event.kind {
        SignalingLifecycleEventKind::Connecting => {
            next.lifecycle_phase = SignalingLifecyclePhase::Connecting;
            next.signaling_health = SignalingHealth::Healthy;
            next.readiness = SignalingReadiness::Idle;
            next.failure_class = SignalingFailureClass::None;
            next.negotiated_suite = None;
            next.reconnect_attempt_count = 0;
        }
        SignalingLifecycleEventKind::SocketOpen => {
            next.lifecycle_phase = SignalingLifecyclePhase::SocketOpen;
            next.signaling_health = SignalingHealth::Healthy;
            next.readiness = SignalingReadiness::Idle;
            next.failure_class = SignalingFailureClass::None;
            next.negotiated_suite = None;
        }
        SignalingLifecycleEventKind::Bound => {
            next.lifecycle_phase = SignalingLifecyclePhase::Bound;
            next.signaling_health = SignalingHealth::Healthy;
            next.readiness = SignalingReadiness::Idle;
            next.failure_class = SignalingFailureClass::None;
            next.negotiated_suite = None;
        }
        SignalingLifecycleEventKind::Reconnecting => {
            next.lifecycle_phase = SignalingLifecyclePhase::Reconnecting;
            next.signaling_health = SignalingHealth::DegradedRecoverable;
            next.readiness = SignalingReadiness::Idle;
            next.failure_class = SignalingFailureClass::TransientNetwork;
            next.negotiated_suite = None;
            next.reconnect_attempt_count = next.reconnect_attempt_count.saturating_add(1);
        }
        SignalingLifecycleEventKind::Closing => {
            next.lifecycle_phase = SignalingLifecyclePhase::Closing;
            next.readiness = SignalingReadiness::Idle;
            next.failure_class = SignalingFailureClass::None;
            next.negotiated_suite = None;
        }
        SignalingLifecycleEventKind::Closed => {
            next.lifecycle_phase = SignalingLifecyclePhase::Closed;
            next.signaling_health = SignalingHealth::Healthy;
            next.failure_class = SignalingFailureClass::None;
            next.readiness = SignalingReadiness::Idle;
            next.negotiated_suite = None;
        }
        SignalingLifecycleEventKind::TransportReady => {
            next.readiness = SignalingReadiness::TransportReady;
            next.last_established_readiness = next
                .last_established_readiness
                .max(SignalingReadiness::TransportReady);
        }
        SignalingLifecycleEventKind::HandshakeComplete => {
            next.readiness = SignalingReadiness::HandshakeComplete;
            next.last_established_readiness = SignalingReadiness::HandshakeComplete;
            next.negotiated_suite = event.negotiated_suite;
        }
        SignalingLifecycleEventKind::Failed => {
            next.lifecycle_phase = SignalingLifecyclePhase::Failed;
            next.failure_class = event.failure_class;
            next.signaling_health = classify_health(event.failure_class);
            next.readiness = SignalingReadiness::Idle;
            next.negotiated_suite = None;
        }
    }

    Ok(next)
}

fn validate_event(event: &SignalingLifecycleEvent) -> Result<(), SignalingLifecycleError> {
    if event.session_id.trim().is_empty() {
        return Err(SignalingLifecycleError::MissingSessionId);
    }
    if event.backend.trim().is_empty() {
        return Err(SignalingLifecycleError::MissingBackend);
    }
    if event.kind == SignalingLifecycleEventKind::Failed
        && event.failure_class == SignalingFailureClass::None
    {
        return Err(SignalingLifecycleError::FailedEventRequiresFailureClass);
    }
    if event.kind == SignalingLifecycleEventKind::HandshakeComplete {
        match event.negotiated_suite.as_ref() {
            Some(suite) if !suite.trim().is_empty() => {}
            _ => return Err(SignalingLifecycleError::HandshakeCompleteRequiresNegotiatedSuite),
        }
    }

    Ok(())
}

fn is_stale_generation(current: &SignalingLifecycleState, event: &SignalingLifecycleEvent) -> bool {
    !current.session_id.is_empty()
        && current.session_id == event.session_id
        && current.backend == event.backend
        && event.generation < current.generation
}

fn should_replace_handle(
    current: &SignalingLifecycleState,
    event: &SignalingLifecycleEvent,
) -> bool {
    current.session_id.is_empty()
        || current.backend.is_empty()
        || current.session_id != event.session_id
        || current.backend != event.backend
        || event.generation > current.generation
}

fn classify_health(failure: SignalingFailureClass) -> SignalingHealth {
    match failure {
        SignalingFailureClass::TransientNetwork | SignalingFailureClass::TransientServer => {
            SignalingHealth::DegradedRecoverable
        }
        SignalingFailureClass::AuthBindRejected
        | SignalingFailureClass::InvalidShardOrSessionMismatch
        | SignalingFailureClass::TokenExpired
        | SignalingFailureClass::ProtocolViolation => SignalingHealth::DegradedFatal,
        SignalingFailureClass::None => SignalingHealth::Healthy,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(kind: SignalingLifecycleEventKind, generation: u64) -> SignalingLifecycleEvent {
        SignalingLifecycleEvent {
            session_id: "session-1".to_string(),
            backend: "wss-primary".to_string(),
            generation,
            kind,
            failure_class: SignalingFailureClass::None,
            negotiated_suite: None,
        }
    }

    fn project(
        current: SignalingLifecycleState,
        event: SignalingLifecycleEvent,
    ) -> SignalingLifecycleState {
        project_signaling_lifecycle(current, event).expect("projection")
    }

    fn bound_state() -> SignalingLifecycleState {
        project(
            SignalingLifecycleState::idle(),
            event(SignalingLifecycleEventKind::Bound, 1),
        )
    }

    fn transport_ready_state() -> SignalingLifecycleState {
        project(
            bound_state(),
            event(SignalingLifecycleEventKind::TransportReady, 1),
        )
    }

    #[test]
    fn socket_open_is_not_connected_and_bound_is_send_gate() {
        let connecting = project(
            SignalingLifecycleState::idle(),
            event(SignalingLifecycleEventKind::Connecting, 1),
        );
        let socket_open = project(
            connecting,
            event(SignalingLifecycleEventKind::SocketOpen, 1),
        );

        assert_eq!(
            socket_open.lifecycle_phase,
            SignalingLifecyclePhase::SocketOpen
        );
        assert!(!socket_open.business_sends_allowed());
        assert!(!socket_open.can_report_connected());

        let bound = project(socket_open, event(SignalingLifecycleEventKind::Bound, 1));
        assert_eq!(bound.lifecycle_phase, SignalingLifecyclePhase::Bound);
        assert!(bound.business_sends_allowed());
        assert!(!bound.can_report_connected());
    }

    #[test]
    fn stale_generation_events_do_not_override_current_handle() {
        let current = project(
            SignalingLifecycleState::idle(),
            event(SignalingLifecycleEventKind::Bound, 3),
        );
        let stale = project(
            current.clone(),
            event(SignalingLifecycleEventKind::SocketOpen, 2),
        );

        assert_eq!(stale, current);
    }

    #[test]
    fn readiness_requires_bound_session() {
        let transport_err = project_signaling_lifecycle(
            SignalingLifecycleState::idle(),
            event(SignalingLifecycleEventKind::TransportReady, 1),
        )
        .unwrap_err();
        assert_eq!(
            transport_err,
            SignalingLifecycleError::ReadinessRequiresBound
        );

        let mut handshake = event(SignalingLifecycleEventKind::HandshakeComplete, 1);
        handshake.negotiated_suite = Some("xwing-hybrid".to_string());
        let handshake_err =
            project_signaling_lifecycle(SignalingLifecycleState::idle(), handshake).unwrap_err();
        assert_eq!(
            handshake_err,
            SignalingLifecycleError::ReadinessRequiresBound
        );
    }

    #[test]
    fn fatal_failure_after_handshake_preserves_audit_but_not_current_connected() {
        let mut handshake = event(SignalingLifecycleEventKind::HandshakeComplete, 1);
        handshake.negotiated_suite = Some("xwing-hybrid".to_string());
        let state = project(transport_ready_state(), handshake);
        assert!(state.can_report_connected());

        let mut failed = event(SignalingLifecycleEventKind::Failed, 1);
        failed.failure_class = SignalingFailureClass::TokenExpired;

        let projected = project(state, failed);

        assert_eq!(projected.signaling_health, SignalingHealth::DegradedFatal);
        assert_eq!(projected.readiness, SignalingReadiness::Idle);
        assert_eq!(
            projected.last_established_readiness,
            SignalingReadiness::HandshakeComplete
        );
        assert_eq!(projected.negotiated_suite, None);
        assert!(!projected.can_report_connected());
    }

    #[test]
    fn recoverable_failure_after_transport_preserves_audit_only() {
        let state = transport_ready_state();
        assert!(state.can_report_connected());

        let mut failed = event(SignalingLifecycleEventKind::Failed, 1);
        failed.failure_class = SignalingFailureClass::TransientNetwork;

        let projected = project(state, failed);

        assert_eq!(
            projected.signaling_health,
            SignalingHealth::DegradedRecoverable
        );
        assert_eq!(projected.readiness, SignalingReadiness::Idle);
        assert_eq!(
            projected.last_established_readiness,
            SignalingReadiness::TransportReady
        );
        assert!(!projected.can_report_connected());
    }

    #[test]
    fn reconnecting_closing_and_closed_clear_current_connected() {
        let mut handshake = event(SignalingLifecycleEventKind::HandshakeComplete, 1);
        handshake.negotiated_suite = Some("xwing-hybrid".to_string());
        let connected = project(transport_ready_state(), handshake);
        assert!(connected.can_report_connected());

        for kind in [
            SignalingLifecycleEventKind::Reconnecting,
            SignalingLifecycleEventKind::Closing,
            SignalingLifecycleEventKind::Closed,
        ] {
            let projected = project(connected.clone(), event(kind, 1));
            assert_eq!(projected.readiness, SignalingReadiness::Idle);
            assert_eq!(
                projected.last_established_readiness,
                SignalingReadiness::HandshakeComplete
            );
            assert_eq!(projected.negotiated_suite, None);
            assert!(!projected.can_report_connected());
        }
    }

    #[test]
    fn failed_before_transport_tears_down_live_readiness() {
        let mut failed = event(SignalingLifecycleEventKind::Failed, 1);
        failed.failure_class = SignalingFailureClass::ProtocolViolation;

        let projected = project(SignalingLifecycleState::idle(), failed);

        assert_eq!(projected.readiness, SignalingReadiness::Idle);
        assert_eq!(
            projected.last_established_readiness,
            SignalingReadiness::Idle
        );
    }

    #[test]
    fn handshake_complete_requires_suite() {
        let err = project_signaling_lifecycle(
            SignalingLifecycleState::idle(),
            event(SignalingLifecycleEventKind::HandshakeComplete, 1),
        )
        .unwrap_err();

        assert_eq!(
            err,
            SignalingLifecycleError::HandshakeCompleteRequiresNegotiatedSuite
        );
    }
}
