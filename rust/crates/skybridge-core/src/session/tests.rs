use time::OffsetDateTime;

use super::*;
use crate::{SignalingFailureClass, SignalingHandleId, SignalingLifecycleEvent};

#[test]
fn registry_applies_bound_and_failure_transitions() {
    let mut registry = SessionRegistry::default();
    registry
        .insert(RuntimeSessionRecord::new(
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
        ))
        .expect("insert session");

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
    registry
        .insert(RuntimeSessionRecord::new(
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
        ))
        .expect("insert active session");
    registry
        .insert(RuntimeSessionRecord::new(
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
        ))
        .expect("insert disconnected session");
    assert_eq!(registry.active_count(), 1);
}

#[test]
fn terminal_runtime_records_ignore_queued_runtime_events() {
    for terminal_state in [
        RuntimeSessionState::Disconnected,
        RuntimeSessionState::Failed,
    ] {
        let session_id = format!("terminal-{terminal_state:?}");
        let mut registry = SessionRegistry::default();
        registry
            .insert(RuntimeSessionRecord::new(
                make_runtime_id(&session_id),
                session_id.clone(),
                RuntimeSessionRole::Responder,
                RuntimeSessionSource::Code,
                "https://api.example.com",
                "device-local",
                Some("device-remote".to_owned()),
                None,
                Some("peer-fingerprint".to_owned()),
                terminal_state,
            ))
            .expect("insert terminal session");
        let before = registry
            .get(&session_id)
            .expect("terminal session exists")
            .clone();
        let handle = SignalingHandleId {
            session_id: session_id.clone(),
            backend: SignalingBackend::Native,
            generation: 9,
        };

        registry.apply_signaling_event(
            &session_id,
            &SignalingLifecycleEvent::new(handle, SignalingLifecyclePhase::Bound),
        );
        assert!(!registry.apply_transport_event(
            &session_id,
            RuntimeSessionTransportEvent::HandshakeComplete {
                negotiated_suite: "X25519+ML-KEM-768".to_owned(),
                peer_protocol_public_key_fingerprint: "peer-fingerprint".to_owned(),
            },
        ));
        assert!(!registry.mark_transport_ready(&session_id));
        assert!(!registry.record_keepalive(
            &session_id,
            RuntimeSessionKeepaliveKind::HeartbeatReceived,
            None,
        ));
        assert!(!registry.update_remote_peer(
            &session_id,
            "replacement-peer",
            Some("Replacement".to_owned()),
            Some("replacement-fingerprint".to_owned()),
        ));
        assert_eq!(registry.get(&session_id), Some(&before));
    }
}

#[test]
fn closed_signaling_preserves_established_transport() {
    let mut registry = SessionRegistry::default();
    registry
        .insert(RuntimeSessionRecord::new(
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
        ))
        .expect("insert session");

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
    registry
        .insert(RuntimeSessionRecord::new(
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
        ))
        .expect("insert session");

    let handle = SignalingHandleId {
        session_id: "session-suite".to_owned(),
        backend: SignalingBackend::Native,
        generation: 1,
    };
    registry.apply_signaling_event(
        "session-suite",
        &SignalingLifecycleEvent::new(handle, SignalingLifecyclePhase::Bound),
    );
    assert!(registry.mark_handshake_complete(
        "session-suite",
        "X25519+ML-KEM-768",
        "observed-fingerprint"
    ));

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
    assert_eq!(
        record.remote_protocol_public_key_fingerprint.as_deref(),
        Some("observed-fingerprint")
    );
}

#[test]
fn handshake_completion_rejects_a_mismatched_pinned_peer_identity() {
    let mut registry = SessionRegistry::default();
    registry
        .insert(RuntimeSessionRecord::new(
            make_runtime_id("session-identity-mismatch"),
            "session-identity-mismatch",
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            Some("remote".to_owned()),
            None,
            Some("expected-fingerprint".to_owned()),
            RuntimeSessionState::Connecting,
        ))
        .expect("insert session");

    assert!(!registry.mark_handshake_complete(
        "session-identity-mismatch",
        "ML-KEM-768",
        "unexpected-fingerprint"
    ));

    let record = registry.get("session-identity-mismatch").unwrap();
    assert_eq!(record.state, RuntimeSessionState::Failed);
    assert_eq!(record.readiness, SessionReadiness::Idle);
    assert_eq!(
        record.remote_protocol_public_key_fingerprint.as_deref(),
        Some("expected-fingerprint")
    );
    assert_eq!(
        record.last_error.as_deref(),
        Some("peer protocol identity fingerprint mismatch")
    );
}

#[test]
fn authenticated_peer_and_selected_route_are_bound_to_current_handshake() {
    let mut registry = SessionRegistry::default();
    registry
        .insert(RuntimeSessionRecord::new(
            make_runtime_id("session-observed"),
            "session-observed",
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            Some("remote".to_owned()),
            Some("Untrusted Lookup Name".to_owned()),
            Some("peer-fingerprint".to_owned()),
            RuntimeSessionState::Connecting,
        ))
        .expect("insert session");
    assert!(registry.mark_handshake_complete(
        "session-observed",
        "X25519+ML-KEM-768",
        "peer-fingerprint"
    ));
    let observed_at = OffsetDateTime::now_utc();
    assert!(registry.record_authenticated_peer_heartbeat(
        "session-observed",
        RuntimeAuthenticatedPeerObservation {
            device_id: "remote".to_owned(),
            device_name: "Authenticated Peer".to_owned(),
            platform: Some("ios".to_owned()),
            capabilities: Some(vec![
                "file_transfer".to_owned(),
                "clipboard_sync".to_owned(),
                "file_transfer".to_owned(),
            ]),
            file_transfer_port: Some(8080),
            remote_control_port: None,
            sbwc_counter: 7,
            observed_at,
        }
    ));
    assert!(registry.record_selected_ice_route(
        "session-observed",
        RuntimeSelectedIceRouteObservation {
            remote_address: "192.0.2.25".to_owned(),
            remote_port: 49152,
            protocol: "udp".to_owned(),
            local_candidate_type: "host".to_owned(),
            remote_candidate_type: "srflx".to_owned(),
            kind: RuntimeSessionRouteKind::Direct,
            observed_at,
        }
    ));

    let record = registry.get("session-observed").expect("observed session");
    assert_eq!(
        record.remote_device_name.as_deref(),
        Some("Authenticated Peer")
    );
    assert_eq!(
        record
            .authenticated_peer
            .as_ref()
            .expect("authenticated peer")
            .capabilities,
        Some(vec![
            "clipboard_sync".to_owned(),
            "file_transfer".to_owned()
        ])
    );
    assert_eq!(
        record
            .selected_ice_route
            .as_ref()
            .expect("selected route")
            .kind,
        RuntimeSessionRouteKind::Direct
    );
}

#[test]
fn authenticated_peer_mismatch_fails_the_session_without_fallback() {
    let mut registry = SessionRegistry::default();
    registry
        .insert(RuntimeSessionRecord::new(
            make_runtime_id("session-observation-mismatch"),
            "session-observation-mismatch",
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            Some("expected-remote".to_owned()),
            None,
            Some("peer-fingerprint".to_owned()),
            RuntimeSessionState::Connecting,
        ))
        .expect("insert session");
    assert!(registry.mark_handshake_complete(
        "session-observation-mismatch",
        "X-Wing",
        "peer-fingerprint"
    ));
    assert!(!registry.record_authenticated_peer_heartbeat(
        "session-observation-mismatch",
        RuntimeAuthenticatedPeerObservation {
            device_id: "other-remote".to_owned(),
            device_name: "Other".to_owned(),
            platform: Some("ios".to_owned()),
            capabilities: Some(vec!["file_transfer".to_owned()]),
            file_transfer_port: Some(8080),
            remote_control_port: None,
            sbwc_counter: 1,
            observed_at: OffsetDateTime::now_utc(),
        }
    ));
    let record = registry
        .get("session-observation-mismatch")
        .expect("failed session retained");
    assert_eq!(record.state, RuntimeSessionState::Failed);
    assert!(record.authenticated_peer.is_none());
    assert_eq!(
        record.last_error.as_deref(),
        Some("authenticated peer heartbeat did not match the session peer identity")
    );
}

#[test]
fn transport_disconnect_clears_preservation_and_closes_session() {
    let mut registry = SessionRegistry::default();
    registry
        .insert(RuntimeSessionRecord::new(
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
        ))
        .expect("insert session");
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
    registry
        .insert(RuntimeSessionRecord::new(
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
        ))
        .expect("insert session");

    let handle = SignalingHandleId {
        session_id: "session-keepalive".to_owned(),
        backend: SignalingBackend::Native,
        generation: 1,
    };
    registry.apply_signaling_event(
        "session-keepalive",
        &SignalingLifecycleEvent::new(handle, SignalingLifecyclePhase::Bound),
    );
    assert!(registry.mark_handshake_complete(
        "session-keepalive",
        "X25519",
        "keepalive-peer-fingerprint"
    ));
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
    registry
        .insert(RuntimeSessionRecord::new(
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
        ))
        .expect("insert session");

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
    registry
        .insert(RuntimeSessionRecord::new(
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
        ))
        .expect("insert session");
    let handle = SignalingHandleId {
        session_id: "session-explicit-stop".to_owned(),
        backend: SignalingBackend::Native,
        generation: 7,
    };
    registry.apply_signaling_event(
        "session-explicit-stop",
        &SignalingLifecycleEvent::new(handle, SignalingLifecyclePhase::Bound),
    );
    assert!(registry.mark_handshake_complete(
        "session-explicit-stop",
        "X-Wing",
        "disconnect-peer-fingerprint"
    ));
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

#[test]
fn managed_session_registry_rejects_all_active_capacity_and_evicts_only_stopped() {
    let mut registry = ManagedSessionControlRegistry::default();
    let base = OffsetDateTime::UNIX_EPOCH;
    for index in 0..ManagedSessionControlRegistry::MAX_SESSIONS {
        let mut control = ManagedSessionControl::new(
            format!("session-{index:02}"),
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "local",
            "https://api.example.com",
            "secret-token",
            None,
        );
        control.updated_at = base + time::Duration::seconds(index as i64);
        registry.insert(control).expect("insert active control");
    }

    let overflow = ManagedSessionControl::new(
        "session-overflow",
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "local",
        "https://api.example.com",
        "secret-token",
        None,
    );
    assert!(registry.insert(overflow.clone()).is_err());
    assert_eq!(
        registry.sessions.len(),
        ManagedSessionControlRegistry::MAX_SESSIONS
    );

    let stopped = registry
        .sessions
        .get_mut("session-00")
        .expect("oldest control");
    stopped.desired_state = ManagedSessionDesiredState::Stopped;
    registry
        .insert(overflow)
        .expect("stopped control may be evicted for a new active control");
    assert!(!registry.sessions.contains_key("session-00"));
    assert!(registry.sessions.contains_key("session-overflow"));
}

#[test]
fn runtime_session_registry_rejects_all_active_capacity_and_evicts_only_terminal() {
    let mut registry = SessionRegistry::default();
    let base = OffsetDateTime::UNIX_EPOCH;
    for index in 0..SessionRegistry::MAX_SESSIONS {
        let mut record = RuntimeSessionRecord::new(
            format!("runtime-{index:02}"),
            format!("session-{index:02}"),
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "https://api.example.com",
            "local",
            None,
            None,
            None,
            RuntimeSessionState::Connecting,
        );
        record.updated_at = base + time::Duration::seconds(index as i64);
        registry.insert(record).expect("insert active runtime");
    }

    let overflow = RuntimeSessionRecord::new(
        "runtime-overflow",
        "session-overflow",
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "https://api.example.com",
        "local",
        None,
        None,
        None,
        RuntimeSessionState::Connecting,
    );
    assert!(registry.insert(overflow.clone()).is_err());

    registry
        .sessions
        .get_mut("session-00")
        .expect("oldest runtime")
        .state = RuntimeSessionState::Disconnected;
    registry
        .insert(overflow)
        .expect("terminal runtime may be evicted for a new active runtime");
    assert!(!registry.sessions.contains_key("session-00"));
    assert!(registry.sessions.contains_key("session-overflow"));
}

#[test]
fn managed_session_debug_redacts_transport_credentials() {
    let control = ManagedSessionControl::new(
        "session-redacted",
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "local",
        "https://api.example.com",
        "signaling-secret",
        None,
    );
    let registration_id = control.registration_id.clone();
    let debug = format!("{control:?}");
    assert!(debug.contains("<redacted>"));
    assert!(!debug.contains("signaling-secret"));
    assert!(!debug.contains(&registration_id));
}

#[test]
fn managed_session_control_mints_distinct_canonical_registration_owners() {
    let first = ManagedSessionControl::new(
        "session-owner",
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "local",
        "https://api.example.com",
        "signaling-secret",
        None,
    );
    let second = ManagedSessionControl::new(
        "session-owner",
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "local",
        "https://api.example.com",
        "signaling-secret",
        None,
    );
    let parsed = uuid::Uuid::parse_str(&first.registration_id).expect("registration UUID");
    assert_eq!(parsed.get_version_num(), 7);
    assert_eq!(parsed.hyphenated().to_string(), first.registration_id);
    assert_ne!(first.registration_id, second.registration_id);
}

#[test]
fn ownerless_managed_session_control_deserializes_only_for_fail_closed_migration() {
    let control = ManagedSessionControl::new(
        "session-legacy-owner",
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "local",
        "https://api.example.com",
        "signaling-secret",
        None,
    );
    let mut payload = serde_json::to_value(control).expect("serialize control");
    payload
        .as_object_mut()
        .expect("control object")
        .remove("registration_id");
    let decoded: ManagedSessionControl =
        serde_json::from_value(payload).expect("legacy control shape decodes");
    assert!(decoded.registration_id.is_empty());
}

/// Regression: the route observation is stamped by the transport task, the
/// handshake receipt by the registry writer — two clocks, milliseconds apart,
/// same establishment. A strict ordering check killed healthy sessions
/// whenever the observation clock landed first. Slightly-early observations
/// must apply; genuinely stale ones (a previous handshake) must still fail
/// closed.
#[test]
fn selected_ice_route_tolerates_millisecond_observation_skew_but_rejects_stale_routes() {
    let mut registry = SessionRegistry::default();
    let mut record = RuntimeSessionRecord::new(
        "runtime-skew",
        "session-skew",
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "https://signal.example.com",
        "local-device",
        Some("remote-device".to_owned()),
        Some("Remote Device".to_owned()),
        Some("peer-fingerprint".to_owned()),
        RuntimeSessionState::Connecting,
    );
    let handshake_completed_at = OffsetDateTime::now_utc();
    record.readiness = SessionReadiness::HandshakeComplete {
        session_id: "session-skew".to_owned(),
        negotiated_suite: "X25519".to_owned(),
    };
    record.handshake_completed_at = Some(handshake_completed_at);
    registry.insert(record).expect("insert session");

    let route = |observed_at: OffsetDateTime| RuntimeSelectedIceRouteObservation {
        remote_address: "127.0.0.1".to_owned(),
        remote_port: 61000,
        protocol: "udp".to_owned(),
        local_candidate_type: "host".to_owned(),
        remote_candidate_type: "host".to_owned(),
        kind: RuntimeSessionRouteKind::Direct,
        observed_at,
    };

    // Observed 800ms before the handshake receipt was persisted: same
    // establishment, benign clock skew — must apply.
    assert!(registry.record_selected_ice_route(
        "session-skew",
        route(handshake_completed_at - time::Duration::milliseconds(800)),
    ));
    let record = registry.get("session-skew").expect("session");
    assert_eq!(record.state, RuntimeSessionState::Connecting);
    assert!(record.selected_ice_route.is_some());

    // A route from a genuinely earlier handshake must still fail closed.
    let mut registry = SessionRegistry::default();
    let mut stale = RuntimeSessionRecord::new(
        "runtime-stale",
        "session-stale",
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "https://signal.example.com",
        "local-device",
        Some("remote-device".to_owned()),
        Some("Remote Device".to_owned()),
        Some("peer-fingerprint".to_owned()),
        RuntimeSessionState::Connecting,
    );
    stale.readiness = SessionReadiness::HandshakeComplete {
        session_id: "session-stale".to_owned(),
        negotiated_suite: "X25519".to_owned(),
    };
    stale.handshake_completed_at = Some(handshake_completed_at);
    registry.insert(stale).expect("insert stale session");
    assert!(!registry.record_selected_ice_route(
        "session-stale",
        route(handshake_completed_at - time::Duration::minutes(10)),
    ));
    let record = registry.get("session-stale").expect("stale session");
    assert_eq!(record.state, RuntimeSessionState::Failed);
    assert_eq!(
        record.last_error.as_deref(),
        Some("selected ICE route observation predates the current handshake")
    );
}
