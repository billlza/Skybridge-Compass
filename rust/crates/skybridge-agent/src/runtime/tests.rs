use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use anyhow::anyhow;
use ed25519_dalek::SigningKey;
use skybridge_core::{
    AgentHealthSnapshot, AgentRuntimeStatus, ClassicResponderConfig, DowngradePolicy,
    FileTransferControlRequestStatus, InboundMessage, ManagedSessionControl, NativeWebRtcConfig,
    NativeWebRtcSession, ProtocolIdentityBinding, ProtocolSigningAlgorithm, RuntimeSessionRecord,
    RuntimeSessionRole, RuntimeSessionSource, RuntimeSessionState, SessionReadiness,
    WebRtcMessageType, WebRtcSignalingEnvelope,
};
use tokio_util::sync::CancellationToken;

use super::{
    AgentPaths, ManagedSessionWorker, RuntimeIncarnationAuthority, acquire_agent_runtime_lock,
    agent_runtime_is_active, apply_authenticated_handshake_receipt, apply_inbound_runtime_event,
    file_send_capacity_available, publish_starting_health, reconcile_managed_sessions_with_spawner,
    reject_file_send_request_at_capacity, resolve_paths, runtime_health_status,
    shutdown_managed_session_workers, validate_inbound_signaling_envelope,
};

fn test_paths(name: &str) -> AgentPaths {
    resolve_paths(Some(std::env::temp_dir().join(format!(
        "skybridge-agent-runtime-{name}-{}",
        uuid::Uuid::now_v7()
    ))))
    .expect("temporary paths should resolve")
}

async fn wait_for_worker_terminal_result<T>(handle: &tokio::task::JoinHandle<T>) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while !handle.is_finished() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("managed session worker should reach a terminal result");
}

async fn seed_runtime_session(
    paths: &AgentPaths,
    session_id: &str,
    role: RuntimeSessionRole,
    remote_protocol_public_key_fingerprint: Option<&str>,
) {
    crate::state::upsert_session_runtime(
        paths,
        RuntimeSessionRecord::new(
            format!("runtime-{session_id}"),
            session_id,
            role,
            RuntimeSessionSource::Code,
            "https://signal.example.com",
            "local-device",
            Some("remote-device".to_owned()),
            None,
            remote_protocol_public_key_fingerprint.map(str::to_owned),
            RuntimeSessionState::Connecting,
        ),
    )
    .await
    .expect("runtime session should seed");
}

fn signaling_envelope(session_id: &str, from: &str, to: Option<&str>) -> WebRtcSignalingEnvelope {
    WebRtcSignalingEnvelope {
        session_id: session_id.to_owned(),
        from: from.to_owned(),
        to: to.map(str::to_owned),
        kind: WebRtcMessageType::Offer,
        payload: None,
        auth_token: None,
        sent_at: 0.0,
    }
}

fn classic_responder_config() -> ClassicResponderConfig {
    let signing_key = SigningKey::from_bytes(&[0x55; 32]);
    ClassicResponderConfig {
        local_binding: ProtocolIdentityBinding::new(
            "device-agent-test-responder",
            ProtocolSigningAlgorithm::Ed25519,
            signing_key.verifying_key().to_bytes().to_vec(),
            None,
        )
        .expect("valid classic responder binding"),
        signing_secret_key: signing_key.to_bytes().to_vec(),
        local_device_name: Some("Agent Test Responder".to_owned()),
        policy: DowngradePolicy::Default,
    }
}

#[test]
fn runtime_health_requires_registry_and_supervisor_readiness() {
    assert_eq!(
        runtime_health_status(true, true),
        AgentRuntimeStatus::Healthy
    );
    for (registry_ready, supervisor_ready) in [(false, false), (false, true), (true, false)] {
        assert_eq!(
            runtime_health_status(registry_ready, supervisor_ready),
            AgentRuntimeStatus::Degraded
        );
    }
}

#[tokio::test]
async fn lock_owner_replaces_stale_healthy_snapshot_with_starting_immediately() {
    let paths = test_paths("stale-healthy-starting");
    tokio::fs::create_dir_all(&paths.runtime_dir)
        .await
        .expect("create runtime directory");
    let stale = AgentHealthSnapshot::new(
        AgentRuntimeStatus::Healthy,
        1,
        paths.root.display().to_string(),
    );
    super::write_json(&paths.health_file, &stale)
        .await
        .expect("seed stale healthy snapshot");

    let runtime_lock = acquire_agent_runtime_lock(&paths).expect("acquire runtime ownership");
    let starting = publish_starting_health(&paths, &runtime_lock.lease)
        .await
        .expect("publish current starting snapshot");
    assert_eq!(starting.status, AgentRuntimeStatus::Starting);
    let persisted = super::load_health_snapshot(&paths)
        .await
        .expect("load current health")
        .expect("health snapshot");
    assert_eq!(persisted.status, AgentRuntimeStatus::Starting);
    assert_eq!(persisted.pid, std::process::id());
    assert_eq!(persisted.instance_id, runtime_lock.lease.instance_id);
    let persisted_lease = super::load_agent_runtime_lease(&paths)
        .await
        .expect("load runtime lease")
        .expect("runtime lease");
    assert_eq!(persisted_lease, runtime_lock.lease);

    let _ = tokio::fs::remove_dir_all(&paths.root).await;
}

#[test]
fn inbound_signaling_envelope_requires_bound_session_sender_and_recipient() {
    let valid = signaling_envelope("session-1", "remote-device", Some("local-device"));
    validate_inbound_signaling_envelope("session-1", "local-device", &valid)
        .expect("bound envelope should pass");
    let no_recipient = signaling_envelope("session-1", "remote-device", None);
    validate_inbound_signaling_envelope("session-1", "local-device", &no_recipient)
        .expect("server-routed envelope may omit recipient");

    for invalid in [
        signaling_envelope("other-session", "remote-device", Some("local-device")),
        signaling_envelope("session-1", "", Some("local-device")),
        signaling_envelope("session-1", " remote-device", Some("local-device")),
        signaling_envelope("session-1", "remote\ndevice", Some("local-device")),
        signaling_envelope("session-1", "local-device", Some("local-device")),
        signaling_envelope("session-1", "remote-device", Some("other-device")),
        signaling_envelope("session-1", "remote-device", Some("")),
        signaling_envelope("session-1", &"x".repeat(257), Some("local-device")),
    ] {
        assert!(
            validate_inbound_signaling_envelope("session-1", "local-device", &invalid).is_err(),
            "invalid signaling identity envelope must fail closed: {invalid:?}"
        );
    }
}

#[tokio::test]
async fn invalid_offer_does_not_persist_remote_peer_binding() {
    let paths = test_paths("invalid-offer-peer-binding");
    crate::state::upsert_session_runtime(
        &paths,
        RuntimeSessionRecord::new(
            "runtime-invalid-offer",
            "session-invalid-offer",
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "https://signal.example.com",
            "local-device",
            None,
            None,
            None,
            RuntimeSessionState::Connecting,
        ),
    )
    .await
    .expect("seed unbound runtime session");
    crate::state::upsert_managed_session_control(
        &paths,
        ManagedSessionControl::new(
            "session-invalid-offer",
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "local-device",
            "https://signal.example.com",
            "test-token",
            None,
        ),
    )
    .await
    .expect("seed managed session authority");
    let authority = RuntimeIncarnationAuthority::new(
        paths.clone(),
        "session-invalid-offer".to_owned(),
        "runtime-invalid-offer".to_owned(),
        CancellationToken::new(),
    );
    let native_session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: "session-invalid-offer".to_owned(),
        local_device_id: "local-device".to_owned(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: None,
        classic_initiator: None,
        classic_responder: Some(classic_responder_config()),
        pqc_initiator: None,
        pqc_responder: None,
    })
    .await
    .expect("create native session");

    let error = apply_inbound_runtime_event(
        &paths,
        "session-invalid-offer",
        "runtime-invalid-offer",
        "local-device",
        InboundMessage::Envelope(signaling_envelope(
            "session-invalid-offer",
            "untrusted-first-sender",
            Some("local-device"),
        )),
        &native_session,
        &authority,
    )
    .await
    .expect_err("semantically invalid offer must fail closed");
    assert!(error.to_string().contains("missing its SDP payload"));

    let registry = crate::state::load_session_registry(&paths)
        .await
        .expect("reload runtime session");
    assert_eq!(
        registry
            .sessions
            .get("session-invalid-offer")
            .expect("runtime session")
            .remote_device_id,
        None
    );
    native_session.close().await.expect("close native session");
    let _ = tokio::fs::remove_dir_all(&paths.root).await;
}

#[test]
fn managed_session_file_send_capacity_is_bounded() {
    assert!(file_send_capacity_available(0));
    assert!(file_send_capacity_available(
        super::file_transfer::MAX_CONCURRENT_SENDS_PER_SESSION - 1
    ));
    assert!(!file_send_capacity_available(
        super::file_transfer::MAX_CONCURRENT_SENDS_PER_SESSION
    ));
    assert!(!file_send_capacity_available(usize::MAX));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn replacement_cannot_interleave_with_a_blocked_authorized_sender() {
    let paths = test_paths("incarnation-effect-linearization");
    seed_runtime_session(
        &paths,
        "session-linearized",
        RuntimeSessionRole::Initiator,
        None,
    )
    .await;
    crate::state::upsert_managed_session_control(
        &paths,
        ManagedSessionControl::new(
            "session-linearized",
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "local-device",
            "https://signal.example.com",
            "test-token",
            None,
        ),
    )
    .await
    .expect("seed managed control");
    let old_control = crate::state::load_managed_session_controls(&paths)
        .await
        .expect("load managed controls")
        .get("session-linearized")
        .expect("managed control")
        .clone();
    let cancellation = CancellationToken::new();
    let authority = RuntimeIncarnationAuthority::new(
        paths.clone(),
        "session-linearized".to_owned(),
        old_control.target_runtime_id.clone(),
        cancellation.clone(),
    );
    let (effect_started_tx, effect_started_rx) = tokio::sync::oneshot::channel();
    let (release_effect_tx, release_effect_rx) = tokio::sync::oneshot::channel();
    let sent_frames = Arc::new(AtomicUsize::new(0));
    let effect_frames = Arc::clone(&sent_frames);
    let effect_authority = authority.clone();
    let effect = tokio::spawn(async move {
        effect_authority
            .run_external_effect("controlled fake sender", async move {
                effect_started_tx
                    .send(())
                    .map_err(|_| anyhow!("failed to announce fake sender start"))?;
                release_effect_rx
                    .await
                    .map_err(|_| anyhow!("failed to release fake sender"))?;
                effect_frames.fetch_add(1, Ordering::SeqCst);
                Ok(())
            })
            .await
    });
    effect_started_rx.await.expect("fake sender should block");

    let replacement_paths = paths.clone();
    let replacement = tokio::spawn(async move {
        crate::state::begin_managed_session_incarnation(&replacement_paths, &old_control).await
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(
        !replacement.is_finished(),
        "replacement must wait for the in-flight incarnation permit"
    );
    assert_eq!(sent_frames.load(Ordering::SeqCst), 0);

    release_effect_tx.send(()).expect("release fake sender");
    effect
        .await
        .expect("fake sender task should join")
        .expect("effect linearized before replacement should succeed");
    let replacement_control = replacement
        .await
        .expect("replacement task should join")
        .expect("replacement should commit after the permit releases");
    assert_ne!(
        replacement_control.target_runtime_id,
        authority.expected_runtime_id
    );
    assert_eq!(sent_frames.load(Ordering::SeqCst), 1);

    let rejected_frames = Arc::clone(&sent_frames);
    let stale_result = authority
        .run_external_effect("stale controlled fake sender", async move {
            rejected_frames.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .await;
    assert!(stale_result.is_err());
    assert!(cancellation.is_cancelled());
    assert_eq!(
        sent_frames.load(Ordering::SeqCst),
        1,
        "a stale runtime must fail before invoking the sender"
    );

    let _ = tokio::fs::remove_dir_all(&paths.root).await;
}

#[tokio::test]
async fn file_send_capacity_rejection_persists_explicit_terminal_state() {
    let paths = test_paths("file-send-capacity-rejection");
    let mut session = RuntimeSessionRecord::new(
        "runtime-capacity",
        "session-capacity",
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "https://signal.example.com",
        "local-device",
        Some("remote-device".to_owned()),
        None,
        Some("fingerprint".to_owned()),
        RuntimeSessionState::Bound,
    );
    session.readiness = SessionReadiness::HandshakeComplete {
        session_id: "session-capacity".to_owned(),
        negotiated_suite: "X-Wing".to_owned(),
    };
    crate::state::upsert_session_runtime(&paths, session)
        .await
        .expect("session seed");
    let source = paths.root.join("source.bin");
    tokio::fs::create_dir_all(&paths.root)
        .await
        .expect("state dir");
    tokio::fs::write(&source, b"payload").await.expect("source");
    let request = crate::state::enqueue_file_transfer_send_request_for_established_session(
        &paths,
        "session-capacity",
        "remote-device",
        &source,
    )
    .await
    .expect("enqueue");
    crate::state::observe_file_transfer_requests_for_runtime(
        &paths,
        "session-capacity",
        "runtime-capacity",
    )
    .await
    .expect("observe");

    reject_file_send_request_at_capacity(&paths, &request.request_id, "runtime-capacity")
        .await
        .expect("persist rejection");
    let registry = crate::state::load_file_transfer_request_registry(&paths)
        .await
        .expect("registry");
    let rejected = registry.get(&request.request_id).expect("request");
    assert_eq!(
        rejected.status,
        FileTransferControlRequestStatus::AgentRejected
    );
    assert_eq!(
        rejected.failure_reason.as_deref(),
        Some("agent file-send concurrency limit reached")
    );
    let _ = tokio::fs::remove_dir_all(&paths.root).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn reconcile_removes_finished_worker_control_without_respawn() {
    let paths = test_paths("reconcile-finished-cleanup");
    seed_runtime_session(&paths, "session-1", RuntimeSessionRole::Initiator, None).await;
    crate::state::upsert_managed_session_control(
        &paths,
        ManagedSessionControl::new(
            "session-1",
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "local-device",
            "https://signal.example.com",
            "session-token",
            None,
        ),
    )
    .await
    .expect("managed session control should persist");

    let finished_cancel = CancellationToken::new();
    let finished_handle = tokio::spawn(async { Ok(()) });
    wait_for_worker_terminal_result(&finished_handle).await;

    let mut workers = BTreeMap::from([(
        "session-1".to_owned(),
        ManagedSessionWorker::new(
            "runtime-session-1".to_owned(),
            finished_cancel,
            finished_handle,
        ),
    )]);
    let spawn_count = Arc::new(AtomicUsize::new(0));
    let root_cancel = CancellationToken::new();

    reconcile_managed_sessions_with_spawner(&paths, &root_cancel, &mut workers, {
        let spawn_count = Arc::clone(&spawn_count);
        move |_paths, control, cancel| {
            spawn_count.fetch_add(1, Ordering::SeqCst);
            async move {
                let runtime_id = control.target_runtime_id;
                let worker_cancel = cancel.clone();
                let handle = tokio::spawn(async move {
                    worker_cancel.cancelled().await;
                    Ok(())
                });
                Ok(ManagedSessionWorker::new(runtime_id, cancel, handle))
            }
        }
    })
    .await
    .expect("reconcile should clean up the finished worker");

    assert_eq!(spawn_count.load(Ordering::SeqCst), 0);
    assert!(workers.is_empty());
    let controls = crate::state::load_managed_session_controls(&paths)
        .await
        .expect("managed session controls should reload after worker cleanup");
    assert!(controls.get("session-1").is_none());

    let _ = tokio::fs::remove_dir_all(&paths.root).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn prebound_handshake_mismatch_fails_worker_and_removes_control() {
    let paths = test_paths("failed-worker-cleanup");
    seed_runtime_session(
        &paths,
        "session-failed",
        RuntimeSessionRole::Responder,
        Some("expected-fingerprint"),
    )
    .await;
    crate::state::upsert_managed_session_control(
        &paths,
        ManagedSessionControl::new(
            "session-failed",
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "local-device",
            "https://signal.example.com",
            "session-token",
            None,
        ),
    )
    .await
    .expect("managed session control should persist");

    let cancel = CancellationToken::new();
    let worker_paths = paths.clone();
    let handle = tokio::spawn(async move {
        apply_authenticated_handshake_receipt(
            &worker_paths,
            "session-failed",
            "runtime-session-failed",
            "ML-KEM-768",
            "unexpected-fingerprint",
        )
        .await
    });
    wait_for_worker_terminal_result(&handle).await;
    let mut workers = BTreeMap::from([(
        "session-failed".to_owned(),
        ManagedSessionWorker::new("runtime-session-failed".to_owned(), cancel, handle),
    )]);

    let error = reconcile_managed_sessions_with_spawner(
        &paths,
        &CancellationToken::new(),
        &mut workers,
        |_paths, _control, _cancel| async { panic!("failed control must not be respawned") },
    )
    .await
    .expect_err("worker failure must remain observable");
    assert!(
        error
            .to_string()
            .contains("mismatched the pre-bound fingerprint")
    );
    assert!(workers.is_empty());
    let controls = crate::state::load_managed_session_controls(&paths)
        .await
        .expect("managed session controls should reload after failed worker cleanup");
    assert!(controls.get("session-failed").is_none());
    let registry = crate::state::load_session_registry(&paths)
        .await
        .expect("runtime session should reload after handshake mismatch");
    let record = registry
        .get("session-failed")
        .expect("failed runtime session should remain available for diagnosis");
    assert_eq!(record.state, RuntimeSessionState::Failed);
    assert_eq!(record.readiness, SessionReadiness::Idle);
    assert_eq!(
        record.remote_protocol_public_key_fingerprint.as_deref(),
        Some("expected-fingerprint")
    );

    let _ = tokio::fs::remove_dir_all(&paths.root).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn authenticated_handshake_binds_an_initially_unbound_peer_identity() {
    let paths = test_paths("initial-handshake-bind");
    seed_runtime_session(
        &paths,
        "session-unbound",
        RuntimeSessionRole::Initiator,
        None,
    )
    .await;
    crate::state::upsert_managed_session_control(
        &paths,
        ManagedSessionControl::new(
            "session-unbound",
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "local-device",
            "https://signal.example.com",
            "test-token",
            None,
        ),
    )
    .await
    .expect("seed managed session authority");

    apply_authenticated_handshake_receipt(
        &paths,
        "session-unbound",
        "runtime-session-unbound",
        "X25519+ML-KEM-768",
        "observed-fingerprint",
    )
    .await
    .expect("verified initiator handshake should establish the first peer identity binding");

    let registry = crate::state::load_session_registry(&paths)
        .await
        .expect("runtime session should reload after handshake binding");
    let record = registry
        .get("session-unbound")
        .expect("bound runtime session should remain persisted");
    assert_eq!(
        record.remote_protocol_public_key_fingerprint.as_deref(),
        Some("observed-fingerprint")
    );
    assert_eq!(
        record.readiness,
        SessionReadiness::HandshakeComplete {
            session_id: "session-unbound".to_owned(),
            negotiated_suite: "X25519+ML-KEM-768".to_owned(),
        }
    );

    let _ = tokio::fs::remove_dir_all(&paths.root).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn shutdown_cancellation_removes_worker_control() {
    let paths = test_paths("shutdown-worker-cleanup");
    seed_runtime_session(
        &paths,
        "session-cancelled",
        RuntimeSessionRole::Initiator,
        None,
    )
    .await;
    crate::state::upsert_managed_session_control(
        &paths,
        ManagedSessionControl::new(
            "session-cancelled",
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "local-device",
            "https://signal.example.com",
            "session-token",
            None,
        ),
    )
    .await
    .expect("managed session control should persist");

    let cancel = CancellationToken::new();
    let worker_cancel = cancel.clone();
    let handle = tokio::spawn(async move {
        worker_cancel.cancelled().await;
        Ok(())
    });
    let mut workers = BTreeMap::from([(
        "session-cancelled".to_owned(),
        ManagedSessionWorker::new("runtime-session-cancelled".to_owned(), cancel, handle),
    )]);

    shutdown_managed_session_workers(&paths, &mut workers)
        .await
        .expect("shutdown should cancel workers and remove controls");
    assert!(workers.is_empty());
    let controls = crate::state::load_managed_session_controls(&paths)
        .await
        .expect("managed session controls should reload after shutdown");
    assert!(controls.get("session-cancelled").is_none());

    let _ = tokio::fs::remove_dir_all(&paths.root).await;
}

#[tokio::test]
async fn agent_runtime_lock_is_non_blocking_and_scoped_to_state_dir() {
    let paths = test_paths("runtime-singleton");
    let other_paths = test_paths("runtime-singleton-other-state-dir");
    tokio::fs::create_dir_all(&paths.runtime_dir)
        .await
        .expect("runtime directory should be created");
    tokio::fs::create_dir_all(&other_paths.runtime_dir)
        .await
        .expect("second runtime directory should be created");
    assert!(!agent_runtime_is_active(&paths).expect("inactive runtime should probe cleanly"));
    assert!(
        !agent_runtime_is_active(&other_paths)
            .expect("second inactive runtime should probe cleanly")
    );

    let runtime_lock =
        acquire_agent_runtime_lock(&paths).expect("first runtime lock should succeed");
    assert!(agent_runtime_is_active(&paths).expect("held runtime lock should be observable"));
    assert!(
        !agent_runtime_is_active(&other_paths)
            .expect("a different state directory must remain independently available")
    );
    let other_runtime_lock = acquire_agent_runtime_lock(&other_paths)
        .expect("a different state directory should acquire its own runtime lock");
    assert!(
        agent_runtime_is_active(&other_paths)
            .expect("the second held runtime lock should be observable")
    );
    let started = Instant::now();
    let error = acquire_agent_runtime_lock(&paths)
        .expect_err("a second runtime lock must fail without waiting");
    assert!(started.elapsed() < Duration::from_secs(1));
    assert!(error.to_string().contains("agent_runtime_active"));

    drop(runtime_lock);
    assert!(!agent_runtime_is_active(&paths).expect("released runtime lock should be inactive"));
    assert!(
        agent_runtime_is_active(&other_paths)
            .expect("releasing one state directory must not release another")
    );
    drop(other_runtime_lock);
    assert!(
        !agent_runtime_is_active(&other_paths)
            .expect("released second runtime lock should be inactive")
    );

    let _ = tokio::fs::remove_dir_all(&paths.root).await;
    let _ = tokio::fs::remove_dir_all(&other_paths.root).await;
}
