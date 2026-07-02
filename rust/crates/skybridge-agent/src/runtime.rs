use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Result, anyhow};
use skybridge_core::{
    AgentHealthSnapshot, AgentRuntimeStatus, EventLevel, InboundMessage, LocalIdentityState,
    ManagedSessionControl, NativeWebRtcConfig, NativeWebRtcEvent, NativeWebRtcSession,
    RuntimeSessionRole, RuntimeSessionState, RuntimeSessionTransportEvent, SignalServerClient,
    SignalingConnection, SignalingLifecyclePhase, SignalingRuntimeEvent, StructuredEvent,
    make_join_envelope,
};
use time::OffsetDateTime;
use tokio::task::JoinHandle;
use tokio::time::MissedTickBehavior;
use tokio::time::interval;
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};

use crate::discovery::{build_active_scan_snapshot, scan_nearby_peers};
use crate::state::{
    apply_signaling_event, apply_transport_event, disconnect_session_if_active,
    ensure_device_identity, load_managed_session_controls, load_session_registry,
    observe_file_transfer_requests_for_established_session,
    observe_remote_desktop_requests_for_established_session, remove_managed_session_control,
    signing_binding, update_session_remote_peer, upsert_nearby_discovery_snapshot,
};

mod file_transfer;
mod fs_io;
mod options;
mod paths;
mod pqc_config;
#[cfg(test)]
mod tests;
mod tracing_setup;
mod two_attempt_connect;

pub use options::AgentRuntimeOptions;
pub use paths::{AgentPaths, resolve_paths};

use file_transfer::{FileTransferCoordinator, spawn_file_send_transfer};
use fs_io::{append_event_line, ensure_layout, load_json, write_json};
use pqc_config::{build_pqc_initiator_config_from_env, build_pqc_responder_config};
use tracing_setup::init_tracing;

pub(crate) use fs_io::{restrict_dir_permissions, restrict_file_permissions};

#[derive(Debug)]
struct ManagedSessionWorker {
    cancel: CancellationToken,
    handle: JoinHandle<()>,
}

impl ManagedSessionWorker {
    fn new(cancel: CancellationToken, handle: JoinHandle<()>) -> Self {
        Self { cancel, handle }
    }

    fn cancel(&self) {
        self.cancel.cancel();
    }

    fn is_finished(&self) -> bool {
        self.handle.is_finished()
    }
}

pub async fn run_agent(options: AgentRuntimeOptions) -> Result<()> {
    let paths = resolve_paths(options.state_dir)?;
    ensure_layout(&paths).await?;
    init_tracing(&paths)?;

    let identity = ensure_device_identity(&paths).await?;
    let mut health = AgentHealthSnapshot::new(
        AgentRuntimeStatus::Starting,
        std::process::id(),
        paths.root.display().to_string(),
    );
    write_json(&paths.health_file, &health).await?;

    info!(
        kind = "agent.started",
        state_dir = %paths.root.display(),
        device_id = %identity.state.device.device_id,
        device_name = %identity.state.device.device_name,
        "skybridge-agent started"
    );
    append_event_line(
        &paths.log_file,
        StructuredEvent::new(EventLevel::Info, "agent.started", "skybridge-agent started"),
    )
    .await?;

    let cancel = CancellationToken::new();
    let heartbeat_task = spawn_heartbeat(
        paths.clone(),
        paths.health_file.clone(),
        health.clone(),
        options.heartbeat_interval,
        cancel.clone(),
    );
    let supervisor_task = spawn_supervisor(paths.clone(), cancel.clone());
    let scanner_task = options.discovery_scan_enabled.then(|| {
        spawn_nearby_scanner(
            paths.clone(),
            options.discovery_scan_interval,
            options.discovery_scan_window,
            cancel.clone(),
        )
    });

    wait_for_shutdown_signal().await;
    cancel.cancel();

    if let Err(join_error) = heartbeat_task.await {
        warn!(kind = "agent.heartbeat.join_failed", error = %join_error, "heartbeat worker stopped unexpectedly");
    }
    if let Err(join_error) = supervisor_task.await {
        warn!(kind = "agent.supervisor.join_failed", error = %join_error, "supervisor worker stopped unexpectedly");
    }
    if let Some(scanner_task) = scanner_task
        && let Err(join_error) = scanner_task.await
    {
        warn!(kind = "agent.discovery.join_failed", error = %join_error, "nearby scanner worker stopped unexpectedly");
    }

    health.touch(AgentRuntimeStatus::Stopping);
    write_json(&paths.health_file, &health).await?;
    append_event_line(
        &paths.log_file,
        StructuredEvent::new(EventLevel::Info, "agent.stopped", "skybridge-agent stopped"),
    )
    .await?;
    info!(kind = "agent.stopped", state_dir = %paths.root.display(), "skybridge-agent stopped");
    Ok(())
}

pub async fn load_identity_state(paths: &AgentPaths) -> Result<Option<LocalIdentityState>> {
    load_json::<LocalIdentityState>(&paths.identity_file).await
}

pub async fn load_health_snapshot(paths: &AgentPaths) -> Result<Option<AgentHealthSnapshot>> {
    load_json::<AgentHealthSnapshot>(&paths.health_file).await
}

fn spawn_heartbeat(
    paths: AgentPaths,
    health_file: PathBuf,
    template: AgentHealthSnapshot,
    heartbeat_interval: Duration,
    cancel: CancellationToken,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = interval(heartbeat_interval);
        let started_at = template.started_at;
        loop {
            tokio::select! {
                _ = cancel.cancelled() => {
                    break;
                }
                _ = ticker.tick() => {
                    let active_sessions = load_session_registry(&paths)
                        .await
                        .map(|registry| registry.active_count())
                        .unwrap_or(0);
                    let snapshot = AgentHealthSnapshot {
                        started_at,
                        updated_at: OffsetDateTime::now_utc(),
                        status: AgentRuntimeStatus::Healthy,
                        active_sessions,
                        ..template.clone()
                    };

                    if let Err(error) = write_json(&health_file, &snapshot).await {
                        error!(
                            kind = "agent.health.write_failed",
                            file = %health_file.display(),
                            error = %error,
                            "failed to persist agent health"
                        );
                    }
                }
            }
        }
    })
}

fn spawn_supervisor(paths: AgentPaths, cancel: CancellationToken) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = interval(Duration::from_secs(5));
        ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
        let mut workers = BTreeMap::<String, ManagedSessionWorker>::new();
        loop {
            tokio::select! {
                _ = cancel.cancelled() => {
                    shutdown_managed_session_workers(&mut workers).await;
                    break;
                }
                _ = ticker.tick() => {
                    if let Err(error) = reconcile_managed_sessions(&paths, &cancel, &mut workers).await {
                        warn!(
                            kind = "agent.supervisor.reconcile_failed",
                            state_dir = %paths.root.display(),
                            error = %error,
                            "managed session reconcile failed"
                        );
                    }
                    info!(
                        kind = "agent.supervisor.tick",
                        workers = workers.len(),
                        "agent supervisor heartbeat"
                    );
                }
            }
        }
    })
}

fn spawn_nearby_scanner(
    paths: AgentPaths,
    scan_interval: Duration,
    scan_window: Duration,
    cancel: CancellationToken,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        // The first tick fires immediately so a fresh snapshot exists shortly
        // after startup; subsequent ticks pace the active scans.
        let mut ticker = interval(scan_interval);
        ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = cancel.cancelled() => break,
                _ = ticker.tick() => {
                    run_nearby_scan_pass(&paths, scan_window).await;
                }
            }
        }
    })
}

async fn run_nearby_scan_pass(paths: &AgentPaths, scan_window: Duration) {
    let peers = match scan_nearby_peers(scan_window).await {
        Ok(peers) => peers,
        Err(error) => {
            warn!(
                kind = "agent.discovery.scan_failed",
                error = %error,
                "active nearby scan failed"
            );
            return;
        }
    };

    // Conservative trust projection: the agent does not yet maintain a
    // peer-identity -> trust index keyed by the advertised protocol key, so
    // every freshly observed peer is a Candidate and is never marked
    // connectable. Discovery never authorizes a connection on its own; an
    // actual connection still requires the explicit request + handshake gates.
    let trusted_identities = BTreeMap::new();
    let snapshot = build_active_scan_snapshot(
        peers,
        &trusted_identities,
        crate::discovery::DEFAULT_ACTIVE_SCAN_TTL_SECONDS,
    );
    let device_count = snapshot.devices.len();

    if let Err(error) = upsert_nearby_discovery_snapshot(paths, snapshot).await {
        warn!(
            kind = "agent.discovery.snapshot_write_failed",
            error = %error,
            "failed to persist active nearby scan snapshot"
        );
        return;
    }

    info!(
        kind = "agent.discovery.scan_completed",
        devices = device_count,
        "active nearby scan completed"
    );
}

fn spawn_managed_session_worker(
    paths: AgentPaths,
    control: ManagedSessionControl,
    cancel: CancellationToken,
) -> ManagedSessionWorker {
    let session_id = control.session_id.clone();
    let worker_paths = paths.clone();
    let worker_cancel = cancel.clone();
    let handle = tokio::spawn(async move {
        let result =
            run_managed_session(worker_paths.clone(), control, worker_cancel.clone()).await;
        let disconnect_reason = match &result {
            Ok(()) if worker_cancel.is_cancelled() => {
                Some("managed session worker cancelled".to_owned())
            }
            Ok(()) => Some("managed session worker exited".to_owned()),
            Err(error) => Some(format!("managed session worker failed: {error}")),
        };
        if let Err(error) =
            disconnect_session_if_active(&worker_paths, &session_id, disconnect_reason).await
        {
            warn!(
                kind = "agent.session.worker_cleanup_failed",
                session_id = %session_id,
                error = %error,
                "managed session worker cleanup failed"
            );
        }
        match result {
            Ok(()) => {
                info!(
                    kind = "agent.session.worker_stopped",
                    session_id = %session_id,
                    cancelled = worker_cancel.is_cancelled(),
                    "managed session worker stopped"
                );
            }
            Err(error) => {
                warn!(
                    kind = "agent.session.worker_failed",
                    session_id = %session_id,
                    error = %error,
                    "managed session worker failed"
                );
            }
        }
    });
    ManagedSessionWorker::new(cancel, handle)
}

async fn await_managed_session_worker_exit(session_id: String, worker: ManagedSessionWorker) {
    if let Err(join_error) = worker.handle.await {
        warn!(
            kind = "agent.session.worker_join_failed",
            session_id = %session_id,
            error = %join_error,
            "managed session worker join failed"
        );
    }
}

async fn drain_finished_managed_session_workers(
    workers: &mut BTreeMap<String, ManagedSessionWorker>,
) {
    let finished = workers
        .iter()
        .filter_map(|(session_id, worker)| worker.is_finished().then_some(session_id.clone()))
        .collect::<Vec<_>>();
    for session_id in finished {
        if let Some(worker) = workers.remove(&session_id) {
            await_managed_session_worker_exit(session_id, worker).await;
        }
    }
}

async fn shutdown_managed_session_workers(workers: &mut BTreeMap<String, ManagedSessionWorker>) {
    for worker in workers.values() {
        worker.cancel();
    }
    let session_ids = workers.keys().cloned().collect::<Vec<_>>();
    for session_id in session_ids {
        if let Some(worker) = workers.remove(&session_id) {
            await_managed_session_worker_exit(session_id, worker).await;
        }
    }
}

async fn reconcile_managed_sessions(
    paths: &AgentPaths,
    root_cancel: &CancellationToken,
    workers: &mut BTreeMap<String, ManagedSessionWorker>,
) -> Result<()> {
    reconcile_managed_sessions_with_spawner(
        paths,
        root_cancel,
        workers,
        spawn_managed_session_worker,
    )
    .await
}

async fn reconcile_managed_sessions_with_spawner<F>(
    paths: &AgentPaths,
    root_cancel: &CancellationToken,
    workers: &mut BTreeMap<String, ManagedSessionWorker>,
    spawn_worker: F,
) -> Result<()>
where
    F: Fn(AgentPaths, ManagedSessionControl, CancellationToken) -> ManagedSessionWorker,
{
    drain_finished_managed_session_workers(workers).await;
    let controls = load_managed_session_controls(paths).await?;
    let desired = controls
        .active_controls()
        .into_iter()
        .map(|control| (control.session_id.clone(), control))
        .collect::<BTreeMap<_, _>>();

    for session_id in workers
        .keys()
        .filter(|session_id| !desired.contains_key(*session_id))
        .cloned()
        .collect::<Vec<_>>()
    {
        if let Some(worker) = workers.get(&session_id) {
            worker.cancel();
        }
    }

    for (session_id, control) in desired {
        if workers
            .get(&session_id)
            .is_some_and(ManagedSessionWorker::is_finished)
            && let Some(worker) = workers.remove(&session_id)
        {
            await_managed_session_worker_exit(session_id.clone(), worker).await;
        }
        if workers.contains_key(&session_id) {
            continue;
        }
        let worker_cancel = root_cancel.child_token();
        let worker = spawn_worker(paths.clone(), control, worker_cancel);
        workers.insert(session_id, worker);
    }

    Ok(())
}

/// Resolve the PQC initiator config, routing a *PQC-provider-unavailable* failure
/// through the live two-attempt downgrade driver.
///
/// This is the runtime call site that finally exercises the policy gate on a real
/// PQC failure (the gap this work closes): for an ML-DSA-65 *initiator*, building
/// the PQC initiator config can fail because no peer PQC KEM public keys are
/// configured — the canonical `PqcProviderUnavailable` condition. Rather than
/// blindly `?`-propagating, we drive it through
/// [`two_attempt_connect::drive_two_attempt_handshake`], which classifies the
/// failure, consults the [`PolicyGate`] (posture + per-peer cooldown), and — only
/// on an authorized downgrade — emits a signed [`skybridge_core::DowngradeEvent`]
/// to the audit sink. The classic *attempt* closure honestly reports that the
/// agent has no Ed25519 classic identity to actually fall back to when running an
/// ML-DSA-65 identity, so a permitted downgrade is recorded but the typed
/// classic-unavailable error is surfaced rather than silently proceeding.
///
/// For every non-initiator role, a non-ML-DSA identity, or a PQC config that builds
/// cleanly, this is a thin pass-through with no behavioral change.
async fn resolve_pqc_initiator_with_two_attempt_fallback(
    paths: &AgentPaths,
    identity: &crate::state::DeviceIdentityMaterial,
    local_binding: &skybridge_core::ProtocolIdentityBinding,
    control: &ManagedSessionControl,
) -> Result<Option<skybridge_core::PqcInitiatorConfig>> {
    use skybridge_core::PolicyGate;

    match build_pqc_initiator_config_from_env(paths, identity, local_binding, control.role).await {
        Ok(config) => Ok(config),
        Err(pqc_error) => {
            // Only an ML-DSA-65 initiator can produce an auditable, signable
            // downgrade decision; anything else just propagates the original error.
            let signing_identity = match two_attempt_connect::signing_identity_from_device(identity)
            {
                Ok(signing_identity) if control.role == RuntimeSessionRole::Initiator => {
                    signing_identity
                }
                _ => return Err(pqc_error),
            };

            let mut gate = PolicyGate::new(two_attempt_connect::AGENT_DEFAULT_DOWNGRADE_POLICY);
            // `ManagedSessionControl` does not carry a resolved remote device id, so
            // the per-peer cooldown is keyed on the stable session id (one fallback
            // decision per session attempt).
            let peer = control.session_id.clone();

            // Live two-attempt drive: attempt 1 is the PQC config build that just
            // failed; attempt 2 (classic) is gated behind policy authorization.
            let outcome = two_attempt_connect::drive_two_attempt_handshake::<(), _, _>(
                &mut gate,
                &signing_identity,
                &peer,
                &control.session_id,
                skybridge_core::CryptoSuite::MLKEM768_MLDSA65,
                two_attempt_connect::AGENT_CLASSIC_FALLBACK_SUITE,
                None,
                || Err(anyhow!("{pqc_error}")),
                || {
                    // The agent's ML-DSA-65 identity carries no Ed25519 classic key,
                    // so there is no classic identity to actually downgrade to here.
                    // The downgrade was authorized + audited above; surface the
                    // honest typed error instead of silently establishing nothing.
                    Err(anyhow!(
                        "classic fallback authorized but the ML-DSA-65 agent identity has no Ed25519 classic key"
                    ))
                },
            );

            match outcome {
                // Unreachable here (PQC build already failed), but handle for totality.
                Ok(_) => Ok(None),
                Err(error) => {
                    warn!(
                        kind = "agent.session.two_attempt_fallback_outcome",
                        session_id = %control.session_id,
                        outcome = %error,
                        "PQC initiator unavailable; two-attempt downgrade driver evaluated the failure"
                    );
                    // Preserve fail-closed behavior: propagate the original PQC error
                    // so the session does not silently start with no handshake.
                    Err(pqc_error)
                }
            }
        }
    }
}

async fn run_managed_session(
    paths: AgentPaths,
    control: ManagedSessionControl,
    cancel: CancellationToken,
) -> Result<()> {
    info!(
        kind = "agent.session.worker_started",
        session_id = %control.session_id,
        role = ?control.role,
        source = ?control.source,
        "managed session worker started"
    );
    let signal_server = SignalServerClient::from_env()?;
    let ws_url = signal_server.websocket_url(
        &control.signaling_server_origin,
        &control.session_id,
        &control.signaling_session_token,
    )?;
    let identity = ensure_device_identity(&paths).await?;
    let local_binding = signing_binding(&identity)?;
    let pqc_initiator = resolve_pqc_initiator_with_two_attempt_fallback(
        &paths,
        &identity,
        &local_binding,
        &control,
    )
    .await?;
    let pqc_responder =
        build_pqc_responder_config(&paths, &identity, &local_binding, control.role).await?;
    let mut connection = SignalingConnection::connect(ws_url, &control.session_id).await?;
    let mut native_session = NativeWebRtcSession::new(NativeWebRtcConfig {
        session_id: control.session_id.clone(),
        local_device_id: control.local_device_id.clone(),
        role: control.role,
        turn_credentials: control.turn_credentials.clone(),
        classic_initiator: (control.role == RuntimeSessionRole::Initiator
            && pqc_initiator.is_none())
        .then(|| -> Result<skybridge_core::ClassicInitiatorConfig> {
            let signing_secret_key =
                identity
                    .signing_key
                    .ed25519_secret_key_bytes()
                    .ok_or_else(|| {
                        anyhow!("classic initiator requires an Ed25519 protocol identity")
                    })?;
            Ok(skybridge_core::ClassicInitiatorConfig {
                local_binding: local_binding.clone(),
                signing_secret_key,
                local_device_name: Some(identity.state.device.device_name.clone()),
                // Classic path is the post-downgrade attempt: no PQC mandate.
                policy: skybridge_core::DowngradePolicy::Default,
            })
        })
        .transpose()?,
        pqc_initiator,
        pqc_responder,
    })
    .await?;
    native_session.start().await?;
    let file_sender = native_session.sender_handle();
    let coordinator = Arc::new(FileTransferCoordinator::new(
        control.session_id.clone(),
        paths.received_dir.clone(),
    ));
    let mut join_sent = false;
    let mut signaling_stream_closed = false;
    let mut signaling_drop_injected = false;
    let mut control_request_observation_ticker = interval(Duration::from_secs(1));
    control_request_observation_ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            _ = cancel.cancelled() => {
                info!(
                    kind = "agent.session.worker_cancelled",
                    session_id = %control.session_id,
                    "managed session worker cancelled"
                );
                let _ = native_session.close().await;
                break;
            }
            event = connection.next_runtime_event(), if !signaling_stream_closed => {
                let Some(event) = event else {
                    signaling_stream_closed = true;
                    if should_stop_worker(&paths, &control.session_id, signaling_stream_closed).await? {
                        let _ = remove_managed_session_control(&paths, &control.session_id).await;
                        let _ = native_session.close().await;
                        break;
                    }
                    continue;
                };
                match event {
                    SignalingRuntimeEvent::Lifecycle(lifecycle) => {
                        apply_signaling_runtime_event(&paths, &control.session_id, &lifecycle).await?;
                        if lifecycle.phase == SignalingLifecyclePhase::Bound && !join_sent {
                            connection
                                .send(make_join_envelope(&control.session_id, &control.local_device_id))
                                .await?;
                            join_sent = true;
                        }
                        drain_native_runtime_events(
                            &paths,
                            &connection,
                            &control.session_id,
                            &mut native_session,
                            &coordinator,
                            &file_sender,
                        )
                        .await?;
                        if matches!(lifecycle.phase, SignalingLifecyclePhase::Closed | SignalingLifecyclePhase::Failed) {
                            signaling_stream_closed = true;
                            if should_stop_worker(&paths, &control.session_id, signaling_stream_closed).await? {
                                let _ = remove_managed_session_control(&paths, &control.session_id).await;
                                let _ = native_session.close().await;
                                break;
                            }
                        }
                    }
                    SignalingRuntimeEvent::Inbound(inbound) => {
                        apply_inbound_runtime_event(
                            &paths,
                            &control.session_id,
                            inbound,
                            &native_session,
                        )
                        .await?;
                        drain_native_runtime_events(
                            &paths,
                            &connection,
                            &control.session_id,
                            &mut native_session,
                            &coordinator,
                            &file_sender,
                        )
                        .await?;
                    }
                }
            }
            event = native_session.next_event() => {
                let Some(event) = event else {
                    continue;
                };
                let should_inject_signaling_drop = matches!(
                    &event,
                    NativeWebRtcEvent::HandshakeComplete { .. }
                ) && !signaling_drop_injected
                    && std::env::var("SKYBRIDGE_TEST_SIGNALING_DROP_AFTER_HANDSHAKE")
                        .map(|value| value == "1")
                        .unwrap_or(false);
                apply_native_runtime_event(
                    &paths,
                    &connection,
                    &control.session_id,
                    event,
                    &coordinator,
                    &file_sender,
                )
                .await?;
                if should_inject_signaling_drop {
                    inject_signaling_drop_after_handshake(&paths, &control.session_id).await?;
                    signaling_stream_closed = true;
                    signaling_drop_injected = true;
                    info!(
                        kind = "agent.session.signaling_drop_injected",
                        session_id = %control.session_id,
                        "injected synthetic signaling drop after handshake completion"
                    );
                }
                if should_stop_worker(&paths, &control.session_id, signaling_stream_closed).await? {
                    let _ = remove_managed_session_control(&paths, &control.session_id).await;
                    let _ = native_session.close().await;
                    break;
                }
            }
            _ = control_request_observation_ticker.tick() => {
                match observe_remote_desktop_requests_for_established_session(
                    &paths,
                    &control.session_id,
                )
                .await
                {
                    Ok(observed) if !observed.is_empty() => {
                        for request in observed {
                            info!(
                                kind = "agent.remote_desktop.request_observed",
                                session_id = %request.session_id,
                                request_id = %request.request_id,
                                action = ?request.action,
                                applied = false,
                                "remote desktop request observed by agent but not live-applied"
                            );
                        }
                    }
                    Ok(_) => {}
                    Err(error) => {
                        warn!(
                            kind = "agent.remote_desktop.request_observation_failed",
                            session_id = %control.session_id,
                            error = %error,
                            "failed to observe remote desktop request"
                        );
                    }
                }
                match observe_file_transfer_requests_for_established_session(
                    &paths,
                    &control.session_id,
                )
                .await
                {
                    Ok(observed) if !observed.is_empty() => {
                        for request in observed {
                            info!(
                                kind = "agent.file_transfer.request_observed",
                                session_id = %request.session_id,
                                request_id = %request.request_id,
                                action = ?request.action,
                                "file transfer request observed by agent; starting live transfer"
                            );
                            spawn_file_send_transfer(
                                paths.clone(),
                                Arc::clone(&coordinator),
                                request,
                                file_sender.clone(),
                                cancel.child_token(),
                            );
                        }
                    }
                    Ok(_) => {}
                    Err(error) => {
                        warn!(
                            kind = "agent.file_transfer.request_observation_failed",
                            session_id = %control.session_id,
                            error = %error,
                            "failed to observe file transfer request"
                        );
                    }
                }
            }
        }
    }

    Ok(())
}

async fn drain_native_runtime_events(
    paths: &AgentPaths,
    connection: &SignalingConnection,
    session_id: &str,
    native_session: &mut NativeWebRtcSession,
    coordinator: &Arc<FileTransferCoordinator>,
    file_sender: &skybridge_core::NativeWebRtcSender,
) -> Result<()> {
    let mut drained = 0usize;
    while let Some(event) = native_session.try_next_event() {
        drained = drained.saturating_add(1);
        apply_native_runtime_event(
            paths,
            connection,
            session_id,
            event,
            coordinator,
            file_sender,
        )
        .await?;
    }
    if drained > 0 {
        info!(
            kind = "agent.session.native_events_drained",
            session_id = %session_id,
            drained = drained,
            "drained pending native runtime events"
        );
    }
    Ok(())
}

async fn apply_signaling_runtime_event(
    paths: &AgentPaths,
    session_id: &str,
    event: &skybridge_core::SignalingLifecycleEvent,
) -> Result<()> {
    apply_signaling_event(paths, session_id, event.clone())
        .await
        .map(|_| ())
}

async fn apply_inbound_runtime_event(
    paths: &AgentPaths,
    session_id: &str,
    inbound: InboundMessage,
    native_session: &NativeWebRtcSession,
) -> Result<()> {
    match inbound {
        InboundMessage::Envelope(envelope) => {
            update_session_remote_peer(paths, session_id, envelope.from.clone(), None, None)
                .await?;
            native_session.handle_signaling_envelope(&envelope).await?;
        }
        InboundMessage::ServerFrame(_) | InboundMessage::Unknown => {}
    }
    Ok(())
}

async fn apply_native_runtime_event(
    paths: &AgentPaths,
    connection: &SignalingConnection,
    session_id: &str,
    event: NativeWebRtcEvent,
    coordinator: &Arc<FileTransferCoordinator>,
    file_sender: &skybridge_core::NativeWebRtcSender,
) -> Result<()> {
    match event {
        NativeWebRtcEvent::SignalingEnvelope(envelope) => {
            connection.send(envelope).await?;
        }
        NativeWebRtcEvent::InboundFileFrame(frame) => {
            if let Err(error) = coordinator.route_inbound(frame, file_sender).await {
                warn!(
                    kind = "agent.file_transfer.inbound_frame_failed",
                    session_id = %session_id,
                    error = %error,
                    "failed to route inbound file frame"
                );
            }
        }
        NativeWebRtcEvent::TransportReady => {
            info!(
                kind = "agent.session.transport_ready_applied",
                session_id = %session_id,
                "applying transport_ready to session registry"
            );
            apply_transport_event(
                paths,
                session_id,
                RuntimeSessionTransportEvent::TransportReady,
            )
            .await?;
        }
        NativeWebRtcEvent::HandshakeComplete { negotiated_suite } => {
            info!(
                kind = "agent.session.handshake_complete_applied",
                session_id = %session_id,
                negotiated_suite = %negotiated_suite,
                "applying handshake_complete to session registry"
            );
            apply_transport_event(
                paths,
                session_id,
                RuntimeSessionTransportEvent::HandshakeComplete { negotiated_suite },
            )
            .await?;
        }
        NativeWebRtcEvent::Keepalive { kind, ping_id } => {
            info!(
                kind = "agent.session.keepalive_applied",
                session_id = %session_id,
                keepalive_kind = ?kind,
                ping_id = ping_id,
                "applying keepalive event to session registry"
            );
            apply_transport_event(
                paths,
                session_id,
                RuntimeSessionTransportEvent::Keepalive { kind, ping_id },
            )
            .await?;
        }
        NativeWebRtcEvent::TransportDisconnected { reason } => {
            info!(
                kind = "agent.session.transport_disconnected_applied",
                session_id = %session_id,
                reason = reason.as_deref().unwrap_or("unknown"),
                "applying transport_disconnected to session registry"
            );
            apply_transport_event(
                paths,
                session_id,
                RuntimeSessionTransportEvent::TransportDisconnected { reason },
            )
            .await?;
        }
    }
    Ok(())
}

async fn should_stop_worker(
    paths: &AgentPaths,
    session_id: &str,
    signaling_stream_closed: bool,
) -> Result<bool> {
    let registry = load_session_registry(paths).await?;
    let Some(record) = registry.get(session_id) else {
        return Ok(true);
    };
    if matches!(
        record.state,
        RuntimeSessionState::Disconnected | RuntimeSessionState::Failed
    ) {
        return Ok(true);
    }
    if signaling_stream_closed && !record.readiness.is_transport_established_for(session_id) {
        return Ok(true);
    }
    Ok(false)
}

async fn inject_signaling_drop_after_handshake(paths: &AgentPaths, session_id: &str) -> Result<()> {
    let registry = load_session_registry(paths).await?;
    let Some(record) = registry.get(session_id) else {
        return Ok(());
    };
    let handle_id = skybridge_core::SignalingHandleId {
        session_id: session_id.to_owned(),
        backend: record
            .signaling_backend
            .unwrap_or(skybridge_core::SignalingBackend::Native),
        generation: record.signaling_generation.unwrap_or(1),
    };
    let event = skybridge_core::SignalingLifecycleEvent {
        handle_id,
        phase: skybridge_core::SignalingLifecyclePhase::Closed,
        server_frame_type: Some("synthetic_test_drop".to_owned()),
        failure_class: Some(skybridge_core::SignalingFailureClass::TransientNetwork),
        error_description: Some("synthetic_signaling_drop_after_handshake".to_owned()),
        occurred_at: time::OffsetDateTime::now_utc(),
    };
    apply_signaling_runtime_event(paths, session_id, &event).await
}

async fn wait_for_shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};

        let mut terminate = signal(SignalKind::terminate()).expect("SIGTERM handler must install");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
    }

    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
