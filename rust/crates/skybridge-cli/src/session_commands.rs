use std::path::PathBuf;

use anyhow::{Result, anyhow, bail};
use serde_json::json;
use skybridge_agent::{
    load_session_registry, remove_managed_session_control, remove_session_runtime, resolve_paths,
};

use crate::{
    OutputOptions, PerformanceCheckArgs, PerformanceKindArg, RemoteDesktopProveArgs,
    performance_commands::run_performance_check,
};

mod presentation;

use presentation::{
    describe_keepalive_brief, describe_readiness, describe_runtime_readiness,
    describe_terminal_runtime_summary,
};

pub(crate) async fn session_ls(state_dir: Option<PathBuf>, as_json: bool) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let registry = load_session_registry(&paths).await?;
    let sessions = registry.values_sorted();
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(
                &json!({ "schema_version": registry.schema_version, "sessions": sessions }),
            )?
        );
        return Ok(());
    }
    if sessions.is_empty() {
        println!("No recorded sessions");
        return Ok(());
    }
    for session in sessions {
        println!(
            "{} [{:?}] {:?} {:?} readiness={} preserved={} keepalive={}",
            session.session_id,
            session.role,
            session.state,
            session.signaling_health,
            describe_runtime_readiness(&session),
            session.transport_preserved,
            describe_keepalive_brief(&session.keepalive),
        );
    }
    Ok(())
}

pub(crate) async fn session_inspect(
    state_dir: Option<PathBuf>,
    args: crate::SessionInspectArgs,
) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let registry = load_session_registry(&paths).await?;
    let session = registry
        .get(&args.id)
        .cloned()
        .ok_or_else(|| anyhow!("session `{}` not found", args.id))?;
    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&session)?);
    } else {
        println!("Session ID: {}", session.session_id);
        println!("Role: {:?}", session.role);
        println!("Source: {:?}", session.source);
        println!("Lifecycle Phase: {:?}", session.lifecycle_phase);
        println!("Signaling Health: {:?}", session.signaling_health);
        println!(
            "Current Readiness: {}",
            describe_readiness(&session.readiness)
        );
        if let Some(last_established) = session.last_established_readiness.as_ref()
            && session.readiness != *last_established
        {
            println!(
                "Last Established Readiness: {}",
                describe_readiness(last_established)
            );
        }
        println!("Transport Preserved: {}", session.transport_preserved);
        if let Some(summary) = describe_terminal_runtime_summary(&session) {
            println!("Runtime Summary: {summary}");
        }
        if let Some(transport_ready_at) = session.transport_ready_at {
            println!("Transport Ready At: {transport_ready_at}");
        }
        if let Some(handshake_completed_at) = session.handshake_completed_at {
            println!("Handshake Completed At: {handshake_completed_at}");
        }
        println!(
            "Keepalive: {}",
            describe_keepalive_brief(&session.keepalive)
        );
        if let Some(last_activity_at) = session.keepalive.last_activity_at {
            println!("Last Data-plane Activity: {last_activity_at}");
        }
        if let Some(error) = session.last_transport_error.as_deref() {
            println!("Last Transport Error: {error}");
        }
        println!("Updated At: {}", session.updated_at);
    }
    Ok(())
}

pub(crate) async fn disconnect(state_dir: Option<PathBuf>, session_id: &str) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let registry = load_session_registry(&paths).await?;
    if registry.get(session_id).is_none() {
        bail!("session `{}` not found", session_id);
    }
    remove_managed_session_control(&paths, session_id).await?;
    remove_session_runtime(
        &paths,
        session_id,
        Some("disconnected_by_operator".to_owned()),
    )
    .await?;
    println!("Marked session {} as disconnected", session_id);
    Ok(())
}

pub(crate) async fn prove_remote_desktop(args: RemoteDesktopProveArgs) -> Result<()> {
    run_performance_check(
        PerformanceCheckArgs {
            kind: PerformanceKindArg::P2pRemote,
            session_id: None,
            latest: false,
            artifact_dir: Some(args.artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: args.min_fps,
            min_width: args.min_width,
            min_height: args.min_height,
            exact_video_size: args.exact_video_size,
            require_audio: args.require_audio,
            strict_fps_floor: args.strict_fps_floor,
            min_pass_window_seconds: args.min_pass_window_seconds,
            manual_artifact: args.manual_artifact,
            output: OutputOptions {
                json: args.output.json,
            },
        },
        "remote-desktop proof failed",
    )
    .await
}

#[cfg(test)]
mod tests;
