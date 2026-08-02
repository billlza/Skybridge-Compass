use std::path::PathBuf;

use anyhow::{Result, anyhow, bail};
use serde::Serialize;
use serde_json::json;
use skybridge_agent::{disconnect_managed_session, load_session_registry, resolve_paths};
use skybridge_core::{
    RuntimeSessionRecord, RuntimeSessionRole, RuntimeSessionSource, RuntimeSessionState,
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
            serde_json::to_string_pretty(&json!({
                "schema_version": registry.schema_version,
                "sessions": sessions
                    .iter()
                    .map(session_public_status)
                    .collect::<Vec<_>>()
            }))?
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
        println!(
            "{}",
            serde_json::to_string_pretty(&session_public_status(&session))?
        );
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

#[derive(Debug, Serialize)]
struct SessionPublicStatus {
    session_id: String,
    role: RuntimeSessionRole,
    source: RuntimeSessionSource,
    runtime_state: RuntimeSessionState,
    lifecycle_phase: String,
    signaling_health: String,
    readiness: String,
    last_established_readiness: Option<String>,
    transport_preserved: bool,
    remote_identity_bound: bool,
    remote_display_name_available: bool,
    keepalive: String,
    last_error_present: bool,
    last_transport_error_present: bool,
    transport_ready_at: Option<String>,
    handshake_completed_at: Option<String>,
    updated_at: String,
    closed_at: Option<String>,
}

fn session_public_status(session: &RuntimeSessionRecord) -> SessionPublicStatus {
    SessionPublicStatus {
        session_id: session.session_id.clone(),
        role: session.role,
        source: session.source,
        runtime_state: session.state,
        lifecycle_phase: format!("{:?}", session.lifecycle_phase),
        signaling_health: format!("{:?}", session.signaling_health),
        readiness: describe_readiness(&session.readiness),
        last_established_readiness: session
            .last_established_readiness
            .as_ref()
            .filter(|readiness| **readiness != session.readiness)
            .map(describe_readiness),
        transport_preserved: session.transport_preserved,
        remote_identity_bound: session
            .remote_protocol_public_key_fingerprint
            .as_deref()
            .is_some_and(|fingerprint| !fingerprint.trim().is_empty()),
        remote_display_name_available: session
            .remote_device_name
            .as_deref()
            .is_some_and(|name| !name.trim().is_empty()),
        keepalive: describe_keepalive_brief(&session.keepalive),
        last_error_present: session
            .last_error
            .as_deref()
            .is_some_and(|error| !error.trim().is_empty()),
        last_transport_error_present: session
            .last_transport_error
            .as_deref()
            .is_some_and(|error| !error.trim().is_empty()),
        transport_ready_at: session.transport_ready_at.map(|value| value.to_string()),
        handshake_completed_at: session
            .handshake_completed_at
            .map(|value| value.to_string()),
        updated_at: session.updated_at.to_string(),
        closed_at: session.closed_at.map(|value| value.to_string()),
    }
}

pub(crate) async fn disconnect(state_dir: Option<PathBuf>, session_id: &str) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let registry = load_session_registry(&paths).await?;
    if registry.get(session_id).is_none() {
        bail!("session `{}` not found", session_id);
    }
    disconnect_managed_session(
        &paths,
        session_id,
        Some("disconnected_by_operator".to_owned()),
    )
    .await?;
    println!("Marked session {} as disconnected", session_id);
    Ok(())
}

#[cfg(test)]
mod tests;
