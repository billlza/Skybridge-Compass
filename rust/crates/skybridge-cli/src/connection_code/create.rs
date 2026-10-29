use std::path::PathBuf;

use anyhow::Result;
use serde::Serialize;
use skybridge_agent::{
    AgentPaths, ensure_device_identity, register_managed_session, resolve_paths, signing_binding,
};
use skybridge_core::{
    ManagedSessionControl, RuntimeSessionRecord, RuntimeSessionRole, RuntimeSessionSource,
    RuntimeSessionState, SignalServerClient, make_runtime_id,
};

use crate::{CodeCreateArgs, agent_runtime_guard, auth_support};

#[derive(Debug, Serialize)]
struct CodeCreateReport {
    schema_version: u32,
    capability_id: &'static str,
    success: bool,
    status: &'static str,
    runtime_owner: &'static str,
    peer_connected: bool,
    code: String,
    session_id: String,
    expires_in: i64,
    signaling_server_origin: String,
    turn_credential_ttl: i64,
    device_name: String,
    tenant_id: String,
    fingerprint: String,
}

pub(crate) async fn code_create(state_dir: Option<PathBuf>, args: CodeCreateArgs) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    agent_runtime_guard::require_active_agent(&paths).await?;
    let signal_server = SignalServerClient::from_env()?;
    code_create_with_client(&paths, args, &signal_server)
        .await
        .map(|_| ())
}

pub(super) async fn code_create_with_client(
    paths: &AgentPaths,
    args: CodeCreateArgs,
    signal_server: &SignalServerClient,
) -> Result<serde_json::Value> {
    agent_runtime_guard::require_active_agent(paths).await?;
    let auth_session = auth_support::require_auth_session(paths).await?;
    let tenant_id = auth_support::require_tenant_id(&auth_session)?;
    let identity = ensure_device_identity(paths).await?;
    let binding = signing_binding(&identity)?;
    let admission =
        auth_support::request_admission_lease(signal_server, &auth_session, &tenant_id, &identity)
            .await?;
    let device_name = args
        .device_name
        .clone()
        .unwrap_or_else(|| identity.state.device.device_name.clone());
    let lease = signal_server
        .register_connection_code(&admission.token, &device_name, args.ttl_seconds)
        .await?;
    let canonical_signaling_origin =
        signal_server.canonical_signaling_origin(&lease.signaling_server_origin)?;
    let turn_credentials = signal_server
        .fetch_turn_credentials(&lease.turn_admission_lease.token)
        .await
        .map_err(|error| {
            error.context(
                "failed to fetch TURN credentials after remote code registration; the remote code will expire at its lease TTL",
            )
        })?;
    agent_runtime_guard::require_active_agent(paths)
        .await
        .map_err(anyhow::Error::new)
        .map_err(|error| {
            error.context(
                "the agent stopped after remote code registration; the code was not handed off locally and will expire at its remote lease TTL",
            )
        })?;
    let runtime_id = make_runtime_id(&lease.session_id);
    let session = RuntimeSessionRecord::new(
        runtime_id.clone(),
        lease.session_id.clone(),
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        canonical_signaling_origin.clone(),
        identity.state.device.device_id.clone(),
        None,
        None,
        None,
        RuntimeSessionState::Pending,
    );
    let control = ManagedSessionControl::new(
        lease.session_id.clone(),
        RuntimeSessionRole::Initiator,
        RuntimeSessionSource::Code,
        identity.state.device.device_id.clone(),
        canonical_signaling_origin.clone(),
        lease.session_token.clone(),
        Some(turn_credentials.clone()),
    );
    let registration_id = control.registration_id.clone();
    register_managed_session(paths, session, control)
    .await
    .map_err(|error| {
        error.context(
            "failed to persist the code's journaled session/control transaction after remote registration; the remote code will expire at its lease TTL",
        )
    })?;
    if let Err(error) = agent_runtime_guard::require_active_agent(paths).await {
        let cleanup = super::cleanup_managed_session_attempt(
            paths,
            &lease.session_id,
            &registration_id,
            "agent stopped before code handoff completed",
        )
        .await;
        return match cleanup {
            Ok(_) => Err(anyhow::Error::new(error).context(
                "the agent stopped before local code handoff completed; the remote code will expire at its lease TTL",
            )),
            Err(cleanup_error) => Err(anyhow::Error::new(error).context(format!(
                "the agent stopped before local code handoff completed; cleanup also failed: {cleanup_error:#}; the remote code will expire at its lease TTL"
            ))),
        };
    }

    let report = CodeCreateReport {
        schema_version: 1,
        capability_id: "native.code.create",
        success: true,
        status: "code_registered",
        runtime_owner: "skybridge-agent",
        peer_connected: false,
        code: lease.code,
        session_id: lease.session_id,
        expires_in: lease.expires_in,
        signaling_server_origin: canonical_signaling_origin,
        turn_credential_ttl: turn_credentials.ttl,
        device_name,
        tenant_id,
        fingerprint: binding.protocol_public_key_fingerprint,
    };
    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("Code: {}", report.code);
        println!("Session ID: {}", report.session_id);
        println!("Expires In: {}s", report.expires_in);
        println!("Signaling Origin: {}", report.signaling_server_origin);
        println!("Runtime Owner: {}", report.runtime_owner);
        println!("Peer Status: waiting for a peer; no connection success claimed");
    }
    Ok(serde_json::to_value(report)?)
}
