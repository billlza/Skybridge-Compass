use anyhow::Result;
use clap::Parser;
use skybridge_agent::{
    load_remote_desktop_request_registry, observe_remote_desktop_requests_for_established_session,
    resolve_paths, upsert_remote_desktop_capability_snapshot, upsert_session_runtime,
};
use skybridge_core::{
    RemoteDesktopCapabilitySnapshot, RemoteDesktopControlAction,
    RemoteDesktopControlRequestPayload, RemoteDesktopObservedMode, RemoteDesktopResolutionRequest,
    RuntimeSessionRecord, RuntimeSessionRole, RuntimeSessionSource, RuntimeSessionState,
    SessionReadiness,
};

use crate::Cli;
use crate::cli_test_support::make_test_dir;

#[tokio::test]
async fn remote_desktop_dispatch_registers_pending_request_without_live_success() -> Result<()> {
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
    .await?;
    let request_registry = load_remote_desktop_request_registry(&paths).await?;
    let pending = request_registry.pending_for_session("session-1");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].target_runtime_id, "runtime-session-1");

    let observed =
        observe_remote_desktop_requests_for_established_session(&paths, "session-1").await?;
    assert_eq!(observed.len(), 1);
    assert!(observed[0].is_agent_observed());
    assert!(!observed[0].is_pending_agent_observation());
    let request_registry = load_remote_desktop_request_registry(&paths).await?;
    assert!(
        request_registry.pending_for_session("session-1").is_empty(),
        "observed remote desktop requests must leave the pending queue"
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
async fn remote_desktop_dispatch_persists_distinct_request_payloads() -> Result<()> {
    let state_dir = make_test_dir("remote-desktop-dispatch-payloads")?;
    let state = state_dir.display().to_string();
    let paths = resolve_paths(Some(state_dir.clone()))?;
    seed_established_session(&paths, "session-stop").await?;
    seed_established_session(&paths, "session-resolution").await?;
    seed_established_session(&paths, "session-fps").await?;
    seed_established_session(&paths, "session-default-start").await?;

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
    .await?;
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
    .await?;
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
    .await?;
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
    .await?;

    let request_registry = load_remote_desktop_request_registry(&paths).await?;
    let default_start = request_registry.pending_for_session("session-default-start");
    assert_eq!(default_start.len(), 1);
    assert_eq!(default_start[0].action, RemoteDesktopControlAction::Start);
    assert_eq!(
        default_start[0].payload.resolution,
        Some(RemoteDesktopResolutionRequest::Auto)
    );
    assert_eq!(default_start[0].payload.fps, Some(60));
    assert_eq!(
        default_start[0].target_runtime_id,
        "runtime-session-default-start"
    );

    let stop = request_registry.pending_for_session("session-stop");
    assert_eq!(stop.len(), 1);
    assert_eq!(stop[0].action, RemoteDesktopControlAction::Stop);
    assert_eq!(
        stop[0].payload,
        RemoteDesktopControlRequestPayload::default()
    );
    assert_eq!(stop[0].target_runtime_id, "runtime-session-stop");

    let set_resolution = request_registry.pending_for_session("session-resolution");
    assert_eq!(set_resolution.len(), 1);
    assert_eq!(
        set_resolution[0].action,
        RemoteDesktopControlAction::SetResolution
    );
    assert_eq!(set_resolution[0].payload.fps, None);
    assert_eq!(
        set_resolution[0].payload.resolution,
        Some(RemoteDesktopResolutionRequest::Preset {
            id: "2056x1329".to_owned(),
            width: 2056,
            height: 1329,
        })
    );
    assert_eq!(
        set_resolution[0].target_runtime_id,
        "runtime-session-resolution"
    );

    let set_fps = request_registry.pending_for_session("session-fps");
    assert_eq!(set_fps.len(), 1);
    assert_eq!(set_fps[0].action, RemoteDesktopControlAction::SetFps);
    assert_eq!(set_fps[0].payload.resolution, None);
    assert_eq!(set_fps[0].payload.fps, Some(120));
    assert_eq!(set_fps[0].target_runtime_id, "runtime-session-fps");

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
