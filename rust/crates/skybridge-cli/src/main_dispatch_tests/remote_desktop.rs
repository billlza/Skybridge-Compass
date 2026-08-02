use anyhow::Result;
use clap::Parser;
use skybridge_agent::{
    load_remote_desktop_request_registry, resolve_paths, upsert_remote_desktop_capability_snapshot,
    upsert_session_runtime,
};
use skybridge_core::{
    RemoteDesktopCapabilitySnapshot, RemoteDesktopObservedMode,
    RuntimeAuthenticatedPeerObservation, RuntimeSessionRecord, RuntimeSessionRole,
    RuntimeSessionSource, RuntimeSessionState, SessionReadiness,
};

use crate::Cli;
use crate::cli_test_support::make_test_dir;

#[tokio::test]
async fn remote_desktop_dispatch_rejects_unverified_peer_without_registry_write() -> Result<()> {
    let state_dir = make_test_dir("remote-desktop-dispatch")?;
    let state = state_dir.display().to_string();
    let paths = resolve_paths(Some(state_dir.clone()))?;
    seed_established_session(&paths, "session-1").await?;

    dispatch_args(["skybridge", "remote-desktop", "contract", "--json"]).await?;
    dispatch_args(["skybridge", "remote-desktop", "resolutions", "--json"]).await?;
    dispatch_args([
        "skybridge",
        "--state-dir",
        &state,
        "remote-desktop",
        "status",
        "--json",
    ])
    .await?;

    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "status",
            "--session-id",
            "missing",
            "--json",
        ])
        .await
        .is_err()
    );
    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "start",
            "--session-id",
            "session-1",
            "--resolution",
            "1920x1080",
            "--fps",
            "60",
            "--json",
        ])
        .await
        .is_err()
    );
    let request_registry = load_remote_desktop_request_registry(&paths).await?;
    assert!(
        request_registry.pending_for_session("session-1").is_empty(),
        "unverified peer capability must fail before registry mutation"
    );

    dispatch_args([
        "skybridge",
        "--state-dir",
        &state,
        "remote-desktop",
        "status",
        "--session-id",
        "session-1",
        "--json",
    ])
    .await?;

    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "start",
            "--session-id",
            "missing",
            "--resolution",
            "1920x1080",
            "--fps",
            "60",
            "--json",
        ])
        .await
        .is_err(),
        "missing sessions must not create remote desktop requests"
    );
    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "set-resolution",
            "--session-id",
            "session-1",
            "--resolution",
            "111x222",
            "--json",
        ])
        .await
        .is_err()
    );
    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "set-fps",
            "--session-id",
            "session-1",
            "--fps",
            "75",
            "--json",
        ])
        .await
        .is_err()
    );

    Ok(())
}

#[tokio::test]
async fn remote_desktop_dispatch_rejects_all_mutations_without_registry_writes() -> Result<()> {
    let state_dir = make_test_dir("remote-desktop-dispatch-payloads")?;
    let state = state_dir.display().to_string();
    let paths = resolve_paths(Some(state_dir.clone()))?;
    seed_established_session_with_capabilities(
        &paths,
        "session-stop",
        Some(vec!["remote_desktop".to_owned()]),
    )
    .await?;
    seed_established_session_with_capabilities(
        &paths,
        "session-resolution",
        Some(vec!["remote_desktop".to_owned()]),
    )
    .await?;
    seed_established_session_with_capabilities(
        &paths,
        "session-fps",
        Some(vec!["remote_desktop".to_owned()]),
    )
    .await?;
    seed_established_session_with_capabilities(
        &paths,
        "session-default-start",
        Some(vec!["remote_desktop".to_owned()]),
    )
    .await?;

    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "start",
            "--session-id",
            "session-default-start",
            "--json",
        ])
        .await
        .is_err()
    );
    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "stop",
            "--session-id",
            "session-stop",
            "--json",
        ])
        .await
        .is_err()
    );
    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "set-resolution",
            "--session-id",
            "session-resolution",
            "--resolution",
            "2056x1329",
            "--json",
        ])
        .await
        .is_err()
    );
    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "set-fps",
            "--session-id",
            "session-fps",
            "--fps",
            "120",
            "--json",
        ])
        .await
        .is_err()
    );

    let request_registry = load_remote_desktop_request_registry(&paths).await?;
    assert!(request_registry.requests.is_empty());

    Ok(())
}

#[tokio::test]
async fn remote_desktop_dispatch_rejects_invalid_start_without_registry_write() -> Result<()> {
    let state_dir = make_test_dir("remote-desktop-dispatch-invalid-start")?;
    let state = state_dir.display().to_string();
    let paths = resolve_paths(Some(state_dir.clone()))?;
    seed_established_session(&paths, "session-invalid-start").await?;

    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "start",
            "--session-id",
            "session-invalid-start",
            "--resolution",
            "1920x1080",
            "--fps",
            "75",
            "--json",
        ])
        .await
        .is_err(),
        "invalid start fps must fail before registry write"
    );
    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "start",
            "--session-id",
            "session-invalid-start",
            "--resolution",
            "../../secret-mode",
            "--fps",
            "60",
            "--json",
        ])
        .await
        .is_err(),
        "invalid start resolution must fail before registry write"
    );
    let request_registry = load_remote_desktop_request_registry(&paths).await?;
    assert!(
        request_registry
            .pending_for_session("session-invalid-start")
            .is_empty(),
        "invalid start requests must not create pending registry entries"
    );

    Ok(())
}

#[tokio::test]
async fn remote_desktop_dispatch_reads_agent_owned_capability_snapshot() -> Result<()> {
    let state_dir = make_test_dir("remote-desktop-dispatch-capability-snapshot")?;
    let state = state_dir.display().to_string();
    let paths = resolve_paths(Some(state_dir.clone()))?;
    seed_established_session(&paths, "session-modes").await?;
    upsert_remote_desktop_capability_snapshot(
        &paths,
        RemoteDesktopCapabilitySnapshot::new(
            "session-modes",
            "runtime-session-modes",
            vec![RemoteDesktopObservedMode::new(
                "1920x1080@60",
                1920,
                1080,
                60,
            )],
            vec![RemoteDesktopObservedMode::new(
                "display-main",
                2056,
                1329,
                60,
            )],
        ),
    )
    .await?;

    dispatch_args([
        "skybridge",
        "--state-dir",
        &state,
        "remote-desktop",
        "resolutions",
        "--session-id",
        "session-modes",
        "--json",
    ])
    .await?;

    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "resolutions",
            "--session-id",
            "missing",
            "--json",
        ])
        .await
        .is_err(),
        "missing sessions must not fall bobserve to fake observed modes"
    );

    Ok(())
}

#[tokio::test]
async fn remote_desktop_dispatch_rejects_active_session_without_established_readiness() -> Result<()>
{
    let state_dir = make_test_dir("remote-desktop-dispatch-no-readiness")?;
    let state = state_dir.display().to_string();
    let paths = resolve_paths(Some(state_dir.clone()))?;
    seed_bound_session_without_established_readiness(&paths, "session-no-readiness").await?;

    assert!(
        dispatch_args([
            "skybridge",
            "--state-dir",
            &state,
            "remote-desktop",
            "start",
            "--session-id",
            "session-no-readiness",
            "--resolution",
            "1920x1080",
            "--fps",
            "60",
            "--json",
        ])
        .await
        .is_err(),
        "active sessions without established transport/handshake evidence must fail closed"
    );
    let request_registry = load_remote_desktop_request_registry(&paths).await?;
    assert!(
        request_registry
            .pending_for_session("session-no-readiness")
            .is_empty(),
        "readiness rejection must not register a pending remote desktop request"
    );

    Ok(())
}

async fn dispatch_args<const N: usize>(args: [&str; N]) -> Result<()> {
    crate::dispatch(Cli::try_parse_from(args)?).await
}

async fn seed_established_session(
    paths: &skybridge_agent::AgentPaths,
    session_id: &str,
) -> Result<()> {
    let mut record = RuntimeSessionRecord::new(
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
    );
    let readiness = SessionReadiness::HandshakeComplete {
        session_id: session_id.to_owned(),
        negotiated_suite: "X-Wing".to_owned(),
    };
    record.readiness = readiness.clone();
    record.last_established_readiness = Some(readiness);
    upsert_session_runtime(paths, record).await?;
    Ok(())
}

async fn seed_established_session_with_capabilities(
    paths: &skybridge_agent::AgentPaths,
    session_id: &str,
    capabilities: Option<Vec<String>>,
) -> Result<()> {
    let mut record = RuntimeSessionRecord::new(
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
    );
    let readiness = SessionReadiness::HandshakeComplete {
        session_id: session_id.to_owned(),
        negotiated_suite: "X-Wing".to_owned(),
    };
    let observed_at = time::OffsetDateTime::now_utc();
    record.readiness = readiness.clone();
    record.last_established_readiness = Some(readiness);
    record.handshake_completed_at = Some(observed_at);
    record.authenticated_peer = Some(RuntimeAuthenticatedPeerObservation {
        device_id: "remote-device".to_owned(),
        device_name: "Remote Device".to_owned(),
        platform: Some("linux".to_owned()),
        capabilities,
        file_transfer_port: None,
        remote_control_port: None,
        sbwc_counter: 1,
        observed_at,
    });
    upsert_session_runtime(paths, record).await?;
    Ok(())
}

async fn seed_bound_session_without_established_readiness(
    paths: &skybridge_agent::AgentPaths,
    session_id: &str,
) -> Result<()> {
    let record = RuntimeSessionRecord::new(
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
    );
    upsert_session_runtime(paths, record).await?;
    Ok(())
}
