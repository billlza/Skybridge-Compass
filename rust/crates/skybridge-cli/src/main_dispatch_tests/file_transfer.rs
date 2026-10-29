use anyhow::Result;
use skybridge_agent::{
    enqueue_file_transfer_send_request_for_established_session,
    load_file_transfer_request_registry, observe_file_transfer_requests_for_established_session,
    resolve_paths, upsert_session_runtime,
};
use skybridge_core::{
    FileTransferControlAction, RuntimeSessionRecord, RuntimeSessionRole, RuntimeSessionSource,
    RuntimeSessionState, SessionReadiness,
};

use crate::cli_test_support::make_test_dir;

#[tokio::test]
async fn file_transfer_registry_registers_pending_send_without_live_success() -> Result<()> {
    let state_dir = make_test_dir("file-transfer-dispatch")?;
    let paths = resolve_paths(Some(state_dir.clone()))?;
    seed_handshake_complete_session(&paths, "session-1").await?;
    let source_path = state_dir.join("payload.bin");
    tokio::fs::write(&source_path, b"hello").await?;

    enqueue_file_transfer_send_request_for_established_session(
        &paths,
        "session-1",
        "remote-device",
        &source_path,
    )
    .await?;

    let request_registry = load_file_transfer_request_registry(&paths).await?;
    let pending = request_registry.pending_for_session("session-1");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].action, FileTransferControlAction::Send);
    assert_eq!(pending[0].target_runtime_id, "runtime-session-1");
    assert_eq!(pending[0].destination.remote_device_id, "remote-device");
    assert_eq!(
        pending[0]
            .destination
            .remote_protocol_public_key_fingerprint,
        "fingerprint"
    );
    assert_eq!(pending[0].source.size_bytes, 5);
    assert_eq!(
        pending[0].source.sha256_hex,
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    );
    assert!(pending[0].is_pending_agent_observation());

    assert!(
        enqueue_file_transfer_send_request_for_established_session(
            &paths,
            "session-1",
            "remote-device",
            &source_path,
        )
        .await
        .is_err(),
        "duplicate pending file-transfer requests must fail closed"
    );

    let observed =
        observe_file_transfer_requests_for_established_session(&paths, "session-1").await?;
    assert_eq!(observed.len(), 1);
    assert!(observed[0].is_agent_observed());
    let request_registry = load_file_transfer_request_registry(&paths).await?;
    assert!(
        request_registry.pending_for_session("session-1").is_empty(),
        "agent-observed file-transfer request must leave no pending queue item"
    );

    enqueue_file_transfer_send_request_for_established_session(
        &paths,
        "session-1",
        "remote-device",
        &source_path,
    )
    .await?;
    let request_registry = load_file_transfer_request_registry(&paths).await?;
    let pending = request_registry.pending_for_session("session-1");
    assert_eq!(pending.len(), 1);
    assert!(pending[0].is_pending_agent_observation());

    Ok(())
}

#[tokio::test]
async fn file_transfer_dispatch_rejects_session_without_current_handshake() -> Result<()> {
    let state_dir = make_test_dir("file-transfer-dispatch-no-handshake")?;
    let paths = resolve_paths(Some(state_dir.clone()))?;
    seed_transport_only_session(&paths, "session-transport-only").await?;
    let source_path = state_dir.join("payload.bin");
    tokio::fs::write(&source_path, b"hello").await?;

    assert!(
        enqueue_file_transfer_send_request_for_established_session(
            &paths,
            "session-transport-only",
            "remote-device",
            &source_path,
        )
        .await
        .is_err(),
        "file transfer requests must require current handshake-complete evidence"
    );
    let request_registry = load_file_transfer_request_registry(&paths).await?;
    assert!(
        request_registry
            .pending_for_session("session-transport-only")
            .is_empty(),
        "handshake rejection must not register a pending file transfer request"
    );

    Ok(())
}

#[tokio::test]
async fn file_transfer_dispatch_rejects_destination_mismatch_without_peer_leakage() -> Result<()> {
    let state_dir = make_test_dir("file-transfer-dispatch-destination-mismatch")?;
    let paths = resolve_paths(Some(state_dir.clone()))?;
    seed_handshake_complete_session(&paths, "session-1").await?;
    let source_path = state_dir.join("payload.bin");
    tokio::fs::write(&source_path, b"hello").await?;

    assert!(
        enqueue_file_transfer_send_request_for_established_session(
            &paths,
            "session-1",
            "wrong-peer-secret",
            &source_path,
        )
        .await
        .is_err(),
        "destination mismatch must fail closed"
    );
    let request_registry = load_file_transfer_request_registry(&paths).await?;
    assert!(request_registry.pending_for_session("session-1").is_empty());

    Ok(())
}

async fn seed_handshake_complete_session(
    paths: &skybridge_agent::AgentPaths,
    session_id: &str,
) -> Result<()> {
    let mut record = base_session(session_id);
    let readiness = SessionReadiness::HandshakeComplete {
        session_id: session_id.to_owned(),
        negotiated_suite: "X-Wing".to_owned(),
    };
    record.readiness = readiness.clone();
    record.last_established_readiness = Some(readiness);
    upsert_session_runtime(paths, record).await?;
    Ok(())
}

async fn seed_transport_only_session(
    paths: &skybridge_agent::AgentPaths,
    session_id: &str,
) -> Result<()> {
    let mut record = base_session(session_id);
    let readiness = SessionReadiness::TransportReady {
        session_id: session_id.to_owned(),
    };
    record.readiness = readiness.clone();
    record.last_established_readiness = Some(readiness);
    upsert_session_runtime(paths, record).await?;
    Ok(())
}

fn base_session(session_id: &str) -> RuntimeSessionRecord {
    RuntimeSessionRecord::new(
        format!("runtime-{session_id}"),
        session_id.to_owned(),
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "https://signal.example.com",
        "local-device",
        Some("remote-device".to_owned()),
        Some("Remote Device".to_owned()),
        Some("fingerprint".to_owned()),
        RuntimeSessionState::Bound,
    )
}
