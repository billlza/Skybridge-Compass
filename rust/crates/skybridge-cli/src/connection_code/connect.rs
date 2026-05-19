use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Result, anyhow, bail};
use serde_json::json;
use skybridge_agent::{
    ensure_device_identity, load_session_registry, resolve_paths, signing_binding,
    upsert_session_runtime,
};
use skybridge_core::{
    CurrentPathOriginPolicy, NativeWebRtcConfig, NativeWebRtcSession, RuntimeSessionRecord,
    RuntimeSessionRole, RuntimeSessionSource, RuntimeSessionState, SignalServerClient,
    SignalingConnection, SignalingRuntimeEvent, make_join_envelope, make_runtime_id,
};

use super::inline_runtime::{
    apply_inline_inbound_runtime_event, apply_inline_native_event, apply_runtime_session_event,
    drain_inline_native_events, should_stop_inline_connect,
};
use super::inline_state::InlineConnectState;
use crate::{ConnectCommand, auth_support};

pub(crate) async fn connect_code(state_dir: Option<PathBuf>, args: ConnectCommand) -> Result<()> {
    let paths = resolve_paths(state_dir)?;
    let auth_session = auth_support::require_auth_session(&paths).await?;
    let tenant_id = auth_support::require_tenant_id(&auth_session)?;
    let identity = ensure_device_identity(&paths).await?;
    let local_binding = signing_binding(&identity)?;
    let pqc_responder =
        auth_support::maybe_inline_pqc_responder_config(&paths, &identity, &local_binding).await?;
    let signal_server = SignalServerClient::from_env()?;
    let admission =
        auth_support::request_admission_lease(&signal_server, &auth_session, &tenant_id, &identity)
            .await?;
    let lookup = signal_server
        .lookup_connection_code(&admission.token, &args.code)
        .await?;
    let turn_credentials = signal_server
        .fetch_turn_credentials(&lookup.turn_admission_lease.token)
        .await?;
    let canonical_origin =
        CurrentPathOriginPolicy::canonical_origin(&lookup.signaling_server_origin)?;
    let ws_url = signal_server.websocket_url(
        &lookup.signaling_server_origin,
        &lookup.session_id,
        &lookup.session_token,
    )?;
    let mut connection = SignalingConnection::connect(ws_url, &lookup.session_id).await?;

    let initial_record = RuntimeSessionRecord::new(
        make_runtime_id(&lookup.session_id),
        lookup.session_id.clone(),
        RuntimeSessionRole::Responder,
        RuntimeSessionSource::Code,
        canonical_origin.clone(),
        identity.state.device.device_id.clone(),
        Some(lookup.initiator_device_id.clone()),
        lookup.initiator_device_name.clone(),
        Some(lookup.initiator_protocol_public_key_fingerprint.clone()),
        RuntimeSessionState::Connecting,
    );
    upsert_session_runtime(&paths, initial_record).await?;
    let mut native_session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: lookup.session_id.clone(),
        local_device_id: identity.state.device.device_id.clone(),
        role: RuntimeSessionRole::Responder,
        turn_credentials: Some(turn_credentials),
        classic_initiator: None,
        pqc_initiator: None,
        pqc_responder,
    })
    .await?;
    native_session.start().await?;

    let bound_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    let hold_deadline = tokio::time::Instant::now() + Duration::from_secs(args.hold_seconds);
    let mut inline_state = InlineConnectState::default();

    loop {
        if !inline_state.signaling_bound && tokio::time::Instant::now() >= bound_deadline {
            bail!("signaling connect timed out before bound");
        }
        if args.hold_seconds > 0
            && inline_state.signaling_bound
            && tokio::time::Instant::now() >= hold_deadline
        {
            break;
        }
        if should_stop_inline_connect(
            &paths,
            &lookup.session_id,
            inline_state.signaling_stream_closed,
        )
        .await?
        {
            break;
        }

        tokio::select! {
            event = connection.next_runtime_event(), if !inline_state.signaling_stream_closed => {
                let Some(event) = event else {
                    inline_state.signaling_stream_closed = true;
                    continue;
                };
                match event {
                    SignalingRuntimeEvent::Lifecycle(lifecycle) => {
                        apply_runtime_session_event(&paths, &lookup.session_id, &lifecycle).await?;
                        let decision = inline_state.apply_lifecycle_phase(lifecycle.phase);
                        if decision.send_join {
                            connection
                                .send(make_join_envelope(
                                    &lookup.session_id,
                                    &identity.state.device.device_id,
                                ))
                                .await?;
                        }
                        drain_inline_native_events(
                            &paths,
                            &connection,
                            &lookup.session_id,
                            &mut native_session,
                        )
                        .await?;
                        if decision.failed_before_bound {
                            bail!(
                                "signaling failed before bound: {}",
                                lifecycle
                                    .error_description
                                    .unwrap_or_else(|| "unknown".to_owned())
                            );
                        }
                    }
                    SignalingRuntimeEvent::Inbound(inbound) => {
                        apply_inline_inbound_runtime_event(
                            &paths,
                            &lookup.session_id,
                            inbound,
                            &native_session,
                        )
                        .await?;
                        drain_inline_native_events(
                            &paths,
                            &connection,
                            &lookup.session_id,
                            &mut native_session,
                        )
                        .await?;
                    }
                }
            }
            event = native_session.next_event() => {
                let Some(event) = event else {
                    continue;
                };
                apply_inline_native_event(
                    &paths,
                    &connection,
                    &lookup.session_id,
                    event,
                )
                .await?;
            }
            _ = tokio::time::sleep(Duration::from_millis(100)) => {}
        }
    }

    let snapshot = connection.snapshot().await;
    let registry = load_session_registry(&paths).await?;
    let record = registry
        .get(&lookup.session_id)
        .cloned()
        .ok_or_else(|| anyhow!("runtime session disappeared"))?;

    let output = json!({
        "signaling_bound": inline_state.signaling_bound,
        "session_id": lookup.session_id,
        "role": record.role,
        "source": record.source,
        "signaling_server_origin": record.signaling_server_origin,
        "lifecycle_phase": record.lifecycle_phase,
        "runtime_state": record.state,
        "signaling_health": record.signaling_health,
        "readiness": record.readiness,
        "transport_preserved": record.transport_preserved,
        "remote_device_id": lookup.initiator_device_id,
        "remote_device_name": lookup.initiator_device_name,
        "remote_protocol_signing_algorithm": lookup.initiator_protocol_signing_algorithm,
        "remote_protocol_public_key_fingerprint": lookup.initiator_protocol_public_key_fingerprint,
        "active_handle": snapshot.active_handle,
    });
    if args.json {
        println!("{}", serde_json::to_string_pretty(&output)?);
    } else {
        println!(
            "Completed signaling plane run for session {}",
            output["session_id"].as_str().unwrap_or_default()
        );
        println!(
            "Lifecycle Phase: {}",
            output["lifecycle_phase"].as_str().unwrap_or_default()
        );
        println!(
            "Remote Device: {}",
            output["remote_device_id"].as_str().unwrap_or_default()
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
