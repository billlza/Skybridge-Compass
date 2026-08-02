use super::*;
use skybridge_agent::{load_session_registry, resolve_paths, upsert_session_runtime};
use skybridge_core::{
    RuntimeSessionKeepaliveStatus, RuntimeSessionRecord, RuntimeSessionRole, RuntimeSessionSource,
    RuntimeSessionState, SessionReadiness,
};
use time::OffsetDateTime;

#[tokio::test]
async fn session_commands_cover_list_inspect_disconnect_and_missing_records() -> Result<()> {
    let state_dir = make_test_dir("session-commands")?;

    session_ls(Some(state_dir.clone()), false).await?;
    assert!(
        disconnect(Some(state_dir.clone()), "missing-session")
            .await
            .is_err()
    );

    let paths = resolve_paths(Some(state_dir.clone()))?;
    let mut record = RuntimeSessionRecord::new(
        "runtime-1",
        "SESSION1",
        RuntimeSessionRole::Responder,
        RuntimeSessionSource::Code,
        "https://signal.example",
        "local-device",
        Some("remote-device".to_owned()),
        Some("Remote Device".to_owned()),
        Some("fingerprint".to_owned()),
        RuntimeSessionState::Bound,
    );
    record.readiness = SessionReadiness::HandshakeComplete {
        session_id: "SESSION1".to_owned(),
        negotiated_suite: "X-Wing".to_owned(),
    };
    record.keepalive.heartbeat_sent_count = 2;
    record.keepalive.heartbeat_received_count = 2;
    upsert_session_runtime(&paths, record).await?;
    let registry = load_session_registry(&paths).await?;
    let public_session = session_public_status(registry.get("SESSION1").expect("session exists"));
    let public_json = serde_json::to_string(&public_session)?;
    assert!(public_session.remote_identity_bound);
    assert!(public_session.remote_display_name_available);
    assert!(
        !public_json.contains("remote-device")
            && !public_json.contains("fingerprint")
            && !public_json.contains("local-device"),
        "session JSON projection must not leak raw local/remote identities"
    );

    session_ls(Some(state_dir.clone()), false).await?;
    session_ls(Some(state_dir.clone()), true).await?;
    session_inspect(
        Some(state_dir.clone()),
        crate::SessionInspectArgs {
            id: "SESSION1".to_owned(),
            output: crate::OutputOptions { json: false },
        },
    )
    .await?;
    session_inspect(
        Some(state_dir.clone()),
        crate::SessionInspectArgs {
            id: "SESSION1".to_owned(),
            output: crate::OutputOptions { json: true },
        },
    )
    .await?;
    assert!(
        session_inspect(
            Some(state_dir.clone()),
            crate::SessionInspectArgs {
                id: "missing-session".to_owned(),
                output: crate::OutputOptions { json: false },
            },
        )
        .await
        .is_err()
    );

    disconnect(Some(state_dir), "SESSION1").await?;
    let registry = load_session_registry(&paths).await?;
    let session = registry.get("SESSION1").expect("session remains recorded");
    assert_eq!(session.state, RuntimeSessionState::Disconnected);
    assert_eq!(
        session.last_error.as_deref(),
        Some("disconnected_by_operator")
    );

    Ok(())
}

#[tokio::test]
async fn disconnect_fails_observably_but_closes_runtime_when_control_registry_is_unavailable()
-> Result<()> {
    let state_dir = make_test_dir("session-disconnect-control-cleanup-failure")?;
    let paths = resolve_paths(Some(state_dir.clone()))?;
    upsert_session_runtime(
        &paths,
        RuntimeSessionRecord::new(
            "runtime-1",
            "SESSION1",
            RuntimeSessionRole::Responder,
            RuntimeSessionSource::Code,
            "https://signal.example",
            "local-device",
            Some("remote-device".to_owned()),
            Some("Remote Device".to_owned()),
            Some("fingerprint".to_owned()),
            RuntimeSessionState::Bound,
        ),
    )
    .await?;
    std::fs::create_dir_all(&paths.session_controls_file)?;

    let result = disconnect(Some(state_dir), "SESSION1").await;
    assert!(
        result.is_err(),
        "disconnect must fail when managed session control cleanup cannot be persisted"
    );
    assert!(
        result
            .expect_err("control registry failure")
            .to_string()
            .contains("managed control registry was unavailable"),
        "the control-registry failure must remain explicit"
    );
    let registry = load_session_registry(&paths).await?;
    let session = registry.get("SESSION1").expect("runtime record remains");
    assert_eq!(session.state, RuntimeSessionState::Disconnected);
    assert_eq!(
        session.last_error.as_deref(),
        Some("disconnected_by_operator"),
        "runtime authority must fail closed even when corrupt control state cannot be cleaned"
    );

    Ok(())
}

#[test]
fn runtime_descriptions_cover_state_transitions_and_keepalive() -> Result<()> {
    assert_eq!(describe_readiness(&SessionReadiness::Idle), "idle");
    assert_eq!(
        describe_readiness(&SessionReadiness::TransportReady {
            session_id: "SESSION1".to_owned()
        }),
        "transport_ready(SESSION1)"
    );
    assert_eq!(
        describe_readiness(&SessionReadiness::HandshakeComplete {
            session_id: "SESSION1".to_owned(),
            negotiated_suite: "X-Wing".to_owned()
        }),
        "handshake_complete(SESSION1, suite=X-Wing)"
    );

    let mut session = RuntimeSessionRecord::new(
        "runtime-1",
        "SESSION1",
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        "https://signal.example",
        "local-device",
        None,
        None,
        None,
        RuntimeSessionState::Disconnected,
    );
    session.readiness = SessionReadiness::Idle;
    session.last_established_readiness = Some(SessionReadiness::HandshakeComplete {
        session_id: "SESSION1".to_owned(),
        negotiated_suite: "X-Wing".to_owned(),
    });
    session.last_transport_error = Some("network-lost".to_owned());
    assert_eq!(
        describe_runtime_readiness(&session),
        "idle (last_established=handshake_complete(SESSION1, suite=X-Wing))"
    );
    let terminal = describe_terminal_runtime_summary(&session).expect("terminal summary");
    assert!(terminal.contains("disconnected after handshake_complete"));
    assert!(terminal.contains("network-lost"));

    session.state = RuntimeSessionState::Pending;
    assert!(describe_terminal_runtime_summary(&session).is_none());

    let keepalive = RuntimeSessionKeepaliveStatus {
        heartbeat_sent_count: 3,
        heartbeat_received_count: 2,
        ping_sent_count: 4,
        pong_received_count: 3,
        pong_replied_count: 1,
        last_ping_id: Some(9),
        last_pong_id: Some(8),
        last_activity_at: Some(OffsetDateTime::from_unix_timestamp(1_700_000_000)?),
        ..Default::default()
    };
    let keepalive_summary = describe_keepalive_brief(&keepalive);
    assert!(keepalive_summary.contains("hb 3/2"));
    assert!(keepalive_summary.contains("last_ping=9"));

    Ok(())
}

fn make_test_dir(name: &str) -> Result<PathBuf> {
    let dir = std::env::temp_dir().join(format!("skybridge-cli-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}
