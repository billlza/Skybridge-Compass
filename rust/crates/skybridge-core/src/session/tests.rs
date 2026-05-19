use time::OffsetDateTime;

use super::*;
use crate::{SignalingFailureClass, SignalingHandleId, SignalingLifecycleEvent};

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
        registry
            .mark_transport_disconnected("session-drop", Some("data_channel_closed".to_owned()))
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
