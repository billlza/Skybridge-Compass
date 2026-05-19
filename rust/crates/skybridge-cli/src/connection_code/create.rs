use std::path::PathBuf;

use anyhow::Result;
use serde_json::json;
use skybridge_agent::{
    AgentPaths, ensure_device_identity, resolve_paths, signing_binding,
    upsert_managed_session_control, upsert_session_runtime,
};
use skybridge_core::{
    ManagedSessionControl, RuntimeSessionRecord, RuntimeSessionRole, RuntimeSessionSource,
    RuntimeSessionState, SignalServerClient, make_runtime_id,
};

use crate::{CodeCreateArgs, auth_support};

pub(crate) async fn code_create(state_dir: Option<PathBuf>, args: CodeCreateArgs) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let signal_server = SignalServerClient::from_env()?;
    code_create_with_client(&paths, args, &signal_server).await
}

pub(super) async fn code_create_with_client(
    paths: &AgentPaths,
    args: CodeCreateArgs,
    signal_server: &SignalServerClient,
) -> Result<()> {
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
    let turn_credentials = signal_server
        .fetch_turn_credentials(&lease.turn_admission_lease.token)
        .await?;
    upsert_session_runtime(
        paths,
        RuntimeSessionRecord::new(
            make_runtime_id(&lease.session_id),
            lease.session_id.clone(),
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            lease.signaling_server_origin.clone(),
            identity.state.device.device_id.clone(),
            None,
            None,
            None,
            RuntimeSessionState::Pending,
        ),
    )
    .await?;
    upsert_managed_session_control(
        paths,
        ManagedSessionControl::new(
            lease.session_id.clone(),
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            identity.state.device.device_id.clone(),
            lease.signaling_server_origin.clone(),
            lease.session_token.clone(),
            Some(turn_credentials.clone()),
        ),
    )
    .await?;

    let output = json!({
        "code": lease.code,
        "session_id": lease.session_id,
        "expires_in": lease.expires_in,
        "signaling_server_origin": lease.signaling_server_origin,
        "turn_credential_ttl": turn_credentials.ttl,
        "device_name": device_name,
        "tenant_id": tenant_id,
        "fingerprint": binding.protocol_public_key_fingerprint,
    });
    if args.output.json {
        println!("{}", serde_json::to_string_pretty(&output)?);
    } else {
        println!("Code: {}", output["code"].as_str().unwrap_or_default());
        println!(
            "Session ID: {}",
            output["session_id"].as_str().unwrap_or_default()
        );
        println!(
            "Expires In: {}s",
            output["expires_in"].as_i64().unwrap_or_default()
        );
        println!(
            "Signaling Origin: {}",
            output["signaling_server_origin"]
                .as_str()
                .unwrap_or_default()
        );
    }
    Ok(())
}
