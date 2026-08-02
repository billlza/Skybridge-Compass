use std::collections::BTreeMap;
use std::fs::{File, OpenOptions, TryLockError};
use std::future::Future;
use std::io::{Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use skybridge_core::{
    AgentHealthSnapshot, AgentRuntimeLease, AgentRuntimeStatus, EventLevel,
    InboundFileTransferApprovalDecision, InboundMessage, LocalIdentityState, ManagedSessionControl,
    NativeWebRtcConfig, NativeWebRtcEvent, NativeWebRtcHeartbeatAdvertisement, NativeWebRtcSession,
    NativeWebRtcSignalingDisposition, RuntimeAuthenticatedPeerObservation, RuntimeSessionRole,
    RuntimeSessionState, RuntimeSessionTransportEvent, SessionReadiness, SignalServerClient,
    SignalingConnection, SignalingLifecyclePhase, SignalingRuntimeEvent, StructuredEvent,
    make_explicit_classic_join_envelope, make_join_envelope,
};
use time::OffsetDateTime;
use tokio::task::JoinHandle;
use tokio::time::MissedTickBehavior;
use tokio::time::interval;
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};

use crate::discovery::{build_active_scan_snapshot, scan_nearby_peers};
use crate::state::{
    acquire_runtime_incarnation_permit, apply_signaling_event_for_runtime,
    apply_transport_event_for_runtime, begin_managed_session_incarnation,
    disconnect_session_if_runtime, ensure_device_identity,
    finish_managed_session_incarnation_requests, load_managed_session_controls,
    load_session_registry, mark_inbound_file_transfer_decision_applied_for_runtime,
    mark_inbound_file_transfer_decision_failed_for_runtime,
    observe_file_transfer_requests_for_runtime,
    observe_inbound_file_transfer_decisions_for_runtime,
    observe_remote_desktop_requests_for_runtime, recover_managed_session_state,
    reject_file_transfer_request_for_runtime, remove_managed_session_control_if_runtime,
    signing_binding, stop_managed_session_control_if_runtime,
    update_session_remote_peer_for_runtime, upsert_nearby_discovery_snapshot,
};

mod file_transfer;
mod fs_io;
mod options;
mod paths;
mod pqc_config;
#[cfg(test)]
mod tests;
mod tracing_setup;

pub use options::AgentRuntimeOptions;
pub use paths::{AgentPaths, resolve_paths};

use file_transfer::{
    FileSendWorker, FileTransferCoordinator, InboundFileStore, MAX_CONCURRENT_SENDS_PER_SESSION,
    OutboundTransferResources, spawn_file_send_transfer,
};
use fs_io::{append_event_line, ensure_layout, load_json, write_json};
use pqc_config::{
    build_local_join_bootstrap, build_pqc_initiator_config_from_env, build_pqc_responder_config,
};
use tracing_setup::init_tracing;

const APPLE_REFERENCE_UNIX_SECONDS: f64 = 978_307_200.0;
const MAX_AUTHENTICATED_HEARTBEAT_CLOCK_SKEW_SECONDS: f64 = 300.0;

pub(crate) use fs_io::{restrict_dir_permissions, restrict_file_permissions};

#[derive(Clone)]
struct RuntimeIncarnationAuthority {
    paths: AgentPaths,
    session_id: String,
    expected_runtime_id: String,
    cancel: CancellationToken,
}

impl RuntimeIncarnationAuthority {
    fn new(
        paths: AgentPaths,
        session_id: String,
        expected_runtime_id: String,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            paths,
            session_id,
            expected_runtime_id,
            cancel,
        }
    }

    async fn run_external_effect<T, F>(&self, operation: &str, effect: F) -> Result<T>
    where
        F: Future<Output = Result<T>>,
    {
        if self.cancel.is_cancelled() {
            bail!("managed runtime cancelled before {operation}");
        }
        let permit = match acquire_runtime_incarnation_permit(
            &self.paths,
            &self.session_id,
            &self.expected_runtime_id,
        )
        .await
        {
            Ok(permit) => permit,
            Err(error) => {
                self.cancel.cancel();
                return Err(error)
                    .with_context(|| format!("managed runtime lost authority before {operation}"));
            }
        };

        // Do not drop an in-flight filesystem/network future while releasing
        // the permit: some async backends may continue a submitted operation
        // after their Future is dropped. Waiting for this one effect to
        // resolve keeps the registry mutation linearization guarantee exact.
        let effect_result = effect.await;
        let cancellation_requested = self.cancel.is_cancelled();
        let post_check = permit.validate_after_effect().await;
        drop(permit);

        match (effect_result, post_check) {
            (Ok(_), Ok(())) if cancellation_requested => Err(anyhow!(
                "managed runtime cancelled after {operation} completed"
            )),
            (Err(effect_error), Ok(())) if cancellation_requested => Err(anyhow!(
                "managed runtime cancelled after {operation} failed: {effect_error:#}"
            )),
            (Ok(value), Ok(())) => Ok(value),
            (Err(effect_error), Ok(())) => Err(effect_error),
            (Ok(_), Err(authority_error)) => {
                self.cancel.cancel();
                Err(authority_error)
                    .with_context(|| format!("managed runtime lost authority after {operation}"))
            }
            (Err(effect_error), Err(authority_error)) => {
                self.cancel.cancel();
                Err(authority_error).with_context(|| {
                    format!(
                        "managed runtime lost authority after {operation}; the bounded effect also failed: {effect_error:#}"
                    )
                })
            }
        }
    }
}

#[derive(Debug)]
struct ManagedSessionWorker {
    runtime_id: String,
    cancel: CancellationToken,
    handle: JoinHandle<Result<()>>,
}

impl ManagedSessionWorker {
    fn new(runtime_id: String, cancel: CancellationToken, handle: JoinHandle<Result<()>>) -> Self {
        Self {
            runtime_id,
            cancel,
            handle,
        }
    }

    fn cancel(&self) {
        self.cancel.cancel();
    }

    fn is_finished(&self) -> bool {
        self.handle.is_finished()
    }
}

#[derive(Debug)]
struct AgentRuntimeLock {
    _file: File,
    lease: AgentRuntimeLease,
}

#[derive(Debug)]
struct SupervisorHealthGuard {
    ready: Arc<AtomicBool>,
}

impl Drop for SupervisorHealthGuard {
    fn drop(&mut self) {
        self.ready.store(false, Ordering::SeqCst);
    }
}

fn open_agent_runtime_lock_file(paths: &AgentPaths) -> Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options
        .open(&paths.agent_runtime_lock_file)
        .with_context(|| {
            format!(
                "failed to open agent runtime lock {}",
                paths.agent_runtime_lock_file.display()
            )
        })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .with_context(|| {
                format!(
                    "failed to restrict agent runtime lock {}",
                    paths.agent_runtime_lock_file.display()
                )
            })?;
    }
    Ok(file)
}

fn acquire_agent_runtime_lock(paths: &AgentPaths) -> Result<AgentRuntimeLock> {
    let mut file = open_agent_runtime_lock_file(paths)?;
    match file.try_lock() {
        Ok(()) => {
            let lease = AgentRuntimeLease::new(
                uuid::Uuid::now_v7().to_string(),
                std::process::id(),
                paths.root.display().to_string(),
            );
            write_agent_runtime_lease(&mut file, &paths.agent_runtime_lock_file, &lease)?;
            Ok(AgentRuntimeLock { _file: file, lease })
        }
        Err(TryLockError::WouldBlock) => bail!(
            "an agent runtime is already active for state directory {} (code: agent_runtime_active)",
            paths.root.display()
        ),
        Err(TryLockError::Error(error)) => Err(error).with_context(|| {
            format!(
                "failed to acquire agent runtime lock {}",
                paths.agent_runtime_lock_file.display()
            )
        }),
    }
}

fn write_agent_runtime_lease(
    file: &mut File,
    path: &std::path::Path,
    lease: &AgentRuntimeLease,
) -> Result<()> {
    let body = serde_json::to_vec_pretty(lease).context("failed to encode agent runtime lease")?;
    file.set_len(0)
        .with_context(|| format!("failed to truncate agent runtime lease {}", path.display()))?;
    file.seek(SeekFrom::Start(0))
        .with_context(|| format!("failed to rewind agent runtime lease {}", path.display()))?;
    file.write_all(&body)
        .with_context(|| format!("failed to write agent runtime lease {}", path.display()))?;
    file.sync_all()
        .with_context(|| format!("failed to sync agent runtime lease {}", path.display()))?;
    Ok(())
}

/// Returns whether another process currently owns this state directory's agent runtime lock.
///
/// The probe never waits for the lock. A missing runtime directory is inactive; all other
/// filesystem and locking failures are surfaced explicitly.
pub fn agent_runtime_is_active(paths: &AgentPaths) -> Result<bool> {
    if !paths.runtime_dir.exists() {
        return Ok(false);
    }
    let file = open_agent_runtime_lock_file(paths)?;
    match file.try_lock() {
        Ok(()) => {
            file.unlock().with_context(|| {
                format!(
                    "failed to release agent runtime probe lock {}",
                    paths.agent_runtime_lock_file.display()
                )
            })?;
            Ok(false)
        }
        Err(TryLockError::WouldBlock) => Ok(true),
        Err(TryLockError::Error(error)) => Err(error).with_context(|| {
            format!(
                "failed to probe agent runtime lock {}",
                paths.agent_runtime_lock_file.display()
            )
        }),
    }
}

pub async fn run_agent(options: AgentRuntimeOptions) -> Result<()> {
    let paths = resolve_paths(options.state_dir)?;
    ensure_layout(&paths).await?;
    let runtime_lock = acquire_agent_runtime_lock(&paths)?;
    let mut health = publish_starting_health(&paths, &runtime_lock.lease).await?;
    let registration_journal_state = recover_managed_session_state(&paths)
        .await
        .context("failed to recover managed session registries before supervisor startup")?;
    if registration_journal_state
        == crate::state::ManagedSessionRegistrationJournalState::RecoveryPending
    {
        warn!(
            kind = "agent.session.registration_journal_cleanup_pending",
            state_dir = %paths.root.display(),
            "managed session registration is committed but journal cleanup remains pending"
        );
    }
    let outbound_transfer_resources = Arc::new(
        OutboundTransferResources::initialize(&paths)
            .await
            .context("failed to initialize agent-global outbound transfer resources")?,
    );
    let inbound_file_store = Arc::new(
        InboundFileStore::initialize(paths.received_dir.clone())
            .await
            .context("failed to initialize agent-global inbound file storage")?,
    );
    init_tracing(&paths)?;

    let identity = ensure_device_identity(&paths).await?;

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
    let supervisor_ready = Arc::new(AtomicBool::new(false));
    let heartbeat_task = spawn_heartbeat(
        paths.clone(),
        paths.health_file.clone(),
        health.clone(),
        options.heartbeat_interval,
        Arc::clone(&supervisor_ready),
        cancel.clone(),
    );
    let supervisor_task = spawn_supervisor(
        paths.clone(),
        cancel.clone(),
        Arc::clone(&supervisor_ready),
        inbound_file_store,
        outbound_transfer_resources,
    );
    let scanner_task = options.discovery_scan_enabled.then(|| {
        spawn_nearby_scanner(
            paths.clone(),
            options.discovery_scan_interval,
            options.discovery_scan_window,
            cancel.clone(),
        )
    });

    let shutdown_signal_result = wait_for_shutdown_signal().await;
    cancel.cancel();

    let mut worker_failures = Vec::new();
    if let Err(error) = shutdown_signal_result {
        worker_failures.push(format!("shutdown signal handling failed: {error:#}"));
    }
    if let Err(join_error) = heartbeat_task.await {
        worker_failures.push(format!("heartbeat worker join failed: {join_error}"));
    }
    match supervisor_task.await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => worker_failures.push(format!("supervisor shutdown failed: {error:#}")),
        Err(join_error) => {
            worker_failures.push(format!("supervisor worker join failed: {join_error}"));
        }
    }
    if let Some(scanner_task) = scanner_task
        && let Err(join_error) = scanner_task.await
    {
        worker_failures.push(format!("nearby scanner worker join failed: {join_error}"));
    }

    health.touch(AgentRuntimeStatus::Stopping);
    write_json(&paths.health_file, &health).await?;
    append_event_line(
        &paths.log_file,
        StructuredEvent::new(EventLevel::Info, "agent.stopped", "skybridge-agent stopped"),
    )
    .await?;
    info!(kind = "agent.stopped", state_dir = %paths.root.display(), "skybridge-agent stopped");
    if worker_failures.is_empty() {
        Ok(())
    } else {
        bail!(
            "one or more agent workers failed before shutdown completed: {}",
            worker_failures.join("; ")
        )
    }
}

async fn publish_starting_health(
    paths: &AgentPaths,
    lease: &AgentRuntimeLease,
) -> Result<AgentHealthSnapshot> {
    let health = AgentHealthSnapshot::new_for_instance(
        AgentRuntimeStatus::Starting,
        lease.pid,
        paths.root.display().to_string(),
        lease.instance_id.clone(),
    );
    write_json(&paths.health_file, &health).await?;
    Ok(health)
}

pub async fn load_identity_state(paths: &AgentPaths) -> Result<Option<LocalIdentityState>> {
    load_json::<LocalIdentityState>(&paths.identity_file).await
}

pub async fn load_health_snapshot(paths: &AgentPaths) -> Result<Option<AgentHealthSnapshot>> {
    load_json::<AgentHealthSnapshot>(&paths.health_file).await
}

pub async fn load_agent_runtime_lease(paths: &AgentPaths) -> Result<Option<AgentRuntimeLease>> {
    load_json::<AgentRuntimeLease>(&paths.agent_runtime_lock_file).await
}

fn spawn_heartbeat(
    paths: AgentPaths,
    health_file: PathBuf,
    template: AgentHealthSnapshot,
    heartbeat_interval: Duration,
    supervisor_ready: Arc<AtomicBool>,
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
                    let (active_sessions, registry_ready) = match load_session_registry(&paths).await {
                        Ok(registry) => (registry.active_count(), true),
                        Err(error) => {
                            error!(
                                kind = "agent.health.session_registry_failed",
                                state_dir = %paths.root.display(),
                                error = %error,
                                "agent health could not read the session registry"
                            );
                            (0, false)
                        }
                    };
                    let snapshot = AgentHealthSnapshot {
                        started_at,
                        updated_at: OffsetDateTime::now_utc(),
                        status: runtime_health_status(
                            registry_ready,
                            supervisor_ready.load(Ordering::SeqCst),
                        ),
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

fn runtime_health_status(
    session_registry_ready: bool,
    supervisor_ready: bool,
) -> AgentRuntimeStatus {
    if session_registry_ready && supervisor_ready {
        AgentRuntimeStatus::Healthy
    } else {
        AgentRuntimeStatus::Degraded
    }
}

fn spawn_supervisor(
    paths: AgentPaths,
    cancel: CancellationToken,
    supervisor_ready: Arc<AtomicBool>,
    inbound_file_store: Arc<InboundFileStore>,
    outbound_transfer_resources: Arc<OutboundTransferResources>,
) -> JoinHandle<Result<()>> {
    tokio::spawn(async move {
        let _health_guard = SupervisorHealthGuard {
            ready: Arc::clone(&supervisor_ready),
        };
        let mut ticker = interval(Duration::from_secs(5));
        ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
        let mut workers = BTreeMap::<String, ManagedSessionWorker>::new();
        loop {
            tokio::select! {
                _ = cancel.cancelled() => {
                    supervisor_ready.store(false, Ordering::SeqCst);
                    return shutdown_managed_session_workers(&paths, &mut workers)
                        .await
                        .context("managed session shutdown failed");
                }
                _ = ticker.tick() => {
                    match reconcile_managed_sessions(
                        &paths,
                        &cancel,
                        &mut workers,
                        Arc::clone(&inbound_file_store),
                        Arc::clone(&outbound_transfer_resources),
                    )
                    .await
                    {
                        Ok(()) => supervisor_ready.store(true, Ordering::SeqCst),
                        Err(error) => {
                            supervisor_ready.store(false, Ordering::SeqCst);
                            warn!(
                                kind = "agent.supervisor.reconcile_failed",
                                state_dir = %paths.root.display(),
                                error = %error,
                                "managed session reconcile failed"
                            );
                        }
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
    let snapshot =
        build_active_scan_snapshot(peers, crate::discovery::DEFAULT_ACTIVE_SCAN_TTL_SECONDS);
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
    inbound_file_store: Arc<InboundFileStore>,
    outbound_transfer_resources: Arc<OutboundTransferResources>,
) -> ManagedSessionWorker {
    let runtime_id = control.target_runtime_id.clone();
    let handle = tokio::spawn(run_managed_session(
        paths,
        control,
        cancel.clone(),
        inbound_file_store,
        outbound_transfer_resources,
    ));
    ManagedSessionWorker::new(runtime_id, cancel, handle)
}

async fn await_managed_session_worker_exit(
    paths: &AgentPaths,
    session_id: String,
    worker: ManagedSessionWorker,
) -> Result<()> {
    let expected_runtime_id = worker.runtime_id.clone();
    let cancelled = worker.cancel.is_cancelled();
    let worker_result = match worker.handle.await {
        Ok(result) => result,
        Err(join_error) => Err(anyhow!("managed session worker task failed: {join_error}")),
    };
    let disconnect_reason = match &worker_result {
        Ok(()) if cancelled => Some("managed session worker cancelled".to_owned()),
        Ok(()) => Some("managed session worker exited".to_owned()),
        Err(error) => Some(format!("managed session worker failed: {error}")),
    };

    let request_cleanup =
        finish_managed_session_incarnation_requests(paths, &session_id, &expected_runtime_id).await;
    let stop_cleanup =
        stop_managed_session_control_if_runtime(paths, &session_id, &expected_runtime_id).await;
    let (session_cleanup, control_cleanup) = match stop_cleanup.as_ref() {
        Ok(_) => {
            let session_cleanup = disconnect_session_if_runtime(
                paths,
                &session_id,
                &expected_runtime_id,
                disconnect_reason,
            )
            .await;
            let control_cleanup = match &session_cleanup {
                Ok(true) => remove_managed_session_control_if_runtime(
                    paths,
                    &session_id,
                    &expected_runtime_id,
                )
                .await
                .map(|_| ()),
                Ok(false) | Err(_) => Ok(()),
            };
            (session_cleanup, control_cleanup)
        }
        Err(_) => (Ok(false), Ok(())),
    };

    let mut failures = Vec::new();
    if let Err(error) = worker_result {
        failures.push(format!("runtime: {error}"));
    }
    if let Err(error) = request_cleanup {
        failures.push(format!("request cleanup: {error}"));
    }
    if let Err(error) = stop_cleanup {
        failures.push(format!("control stop: {error}"));
    }
    if let Err(error) = control_cleanup {
        failures.push(format!("control cleanup: {error}"));
    }
    if let Err(error) = session_cleanup {
        failures.push(format!("session cleanup: {error}"));
    }
    if failures.is_empty() {
        info!(
            kind = "agent.session.worker_stopped",
            session_id = %session_id,
            cancelled,
            "managed session worker stopped and its control was removed"
        );
        Ok(())
    } else {
        bail!(
            "managed session worker `{session_id}` exit failed: {}",
            failures.join("; ")
        )
    }
}

async fn drain_finished_managed_session_workers(
    paths: &AgentPaths,
    workers: &mut BTreeMap<String, ManagedSessionWorker>,
) -> Result<()> {
    let finished = workers
        .iter()
        .filter_map(|(session_id, worker)| worker.is_finished().then_some(session_id.clone()))
        .collect::<Vec<_>>();
    await_managed_session_worker_exits(paths, workers, finished).await
}

async fn shutdown_managed_session_workers(
    paths: &AgentPaths,
    workers: &mut BTreeMap<String, ManagedSessionWorker>,
) -> Result<()> {
    for worker in workers.values() {
        worker.cancel();
    }
    let session_ids = workers.keys().cloned().collect::<Vec<_>>();
    await_managed_session_worker_exits(paths, workers, session_ids).await
}

async fn await_managed_session_worker_exits(
    paths: &AgentPaths,
    workers: &mut BTreeMap<String, ManagedSessionWorker>,
    session_ids: Vec<String>,
) -> Result<()> {
    let mut failures = Vec::new();
    for session_id in session_ids {
        if let Some(worker) = workers.remove(&session_id)
            && let Err(error) = await_managed_session_worker_exit(paths, session_id, worker).await
        {
            failures.push(error.to_string());
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        bail!(
            "one or more managed session workers failed during cleanup: {}",
            failures.join("; ")
        )
    }
}

async fn reconcile_managed_sessions(
    paths: &AgentPaths,
    root_cancel: &CancellationToken,
    workers: &mut BTreeMap<String, ManagedSessionWorker>,
    inbound_file_store: Arc<InboundFileStore>,
    outbound_transfer_resources: Arc<OutboundTransferResources>,
) -> Result<()> {
    reconcile_managed_sessions_with_spawner(paths, root_cancel, workers, {
        move |paths, control, cancel| {
            let inbound_file_store = Arc::clone(&inbound_file_store);
            let outbound_transfer_resources = Arc::clone(&outbound_transfer_resources);
            async move {
                let control = begin_managed_session_incarnation(&paths, &control).await?;
                Ok(spawn_managed_session_worker(
                    paths,
                    control,
                    cancel,
                    inbound_file_store,
                    outbound_transfer_resources,
                ))
            }
        }
    })
    .await
}

async fn reconcile_managed_sessions_with_spawner<F, Fut>(
    paths: &AgentPaths,
    root_cancel: &CancellationToken,
    workers: &mut BTreeMap<String, ManagedSessionWorker>,
    spawn_worker: F,
) -> Result<()>
where
    F: Fn(AgentPaths, ManagedSessionControl, CancellationToken) -> Fut,
    Fut: Future<Output = Result<ManagedSessionWorker>>,
{
    drain_finished_managed_session_workers(paths, workers).await?;
    let controls = load_managed_session_controls(paths).await?;
    let desired = controls
        .active_controls()
        .into_iter()
        .map(|control| (control.session_id.clone(), control))
        .collect::<BTreeMap<_, _>>();

    let obsolete_workers = workers
        .iter()
        .filter_map(|(session_id, worker)| {
            desired
                .get(session_id)
                .is_none_or(|control| control.target_runtime_id != worker.runtime_id)
                .then_some(session_id.clone())
        })
        .collect::<Vec<_>>();
    for session_id in &obsolete_workers {
        if let Some(worker) = workers.get(session_id) {
            worker.cancel();
        }
    }
    await_managed_session_worker_exits(paths, workers, obsolete_workers).await?;

    for (session_id, control) in desired {
        if workers.contains_key(&session_id) {
            continue;
        }
        let worker_cancel = root_cancel.child_token();
        let worker = spawn_worker(paths.clone(), control, worker_cancel).await?;
        workers.insert(session_id, worker);
    }

    Ok(())
}

async fn await_file_send_worker(
    session_id: &str,
    request_id: String,
    worker: FileSendWorker,
) -> Result<()> {
    worker.join().await.with_context(|| {
        format!(
            "file-send worker `{request_id}` for session `{session_id}` did not persist a terminal result"
        )
    })
}

async fn drain_finished_file_send_workers(
    session_id: &str,
    workers: &mut BTreeMap<String, FileSendWorker>,
) -> Result<()> {
    let finished = workers
        .iter()
        .filter_map(|(request_id, worker)| worker.is_finished().then_some(request_id.clone()))
        .collect::<Vec<_>>();
    await_file_send_workers(session_id, workers, finished).await
}

async fn shutdown_file_send_workers(
    session_id: &str,
    workers: &mut BTreeMap<String, FileSendWorker>,
) -> Result<()> {
    for worker in workers.values() {
        worker.cancel();
    }
    let request_ids = workers.keys().cloned().collect::<Vec<_>>();
    await_file_send_workers(session_id, workers, request_ids).await
}

async fn await_file_send_workers(
    session_id: &str,
    workers: &mut BTreeMap<String, FileSendWorker>,
    request_ids: Vec<String>,
) -> Result<()> {
    let mut failures = Vec::new();
    for request_id in request_ids {
        if let Some(worker) = workers.remove(&request_id)
            && let Err(error) = await_file_send_worker(session_id, request_id.clone(), worker).await
        {
            failures.push(format!("{request_id}: {error:#}"));
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        bail!(
            "one or more file-send workers failed during managed-session cleanup: {}",
            failures.join("; ")
        )
    }
}

fn file_send_capacity_available(active_workers: usize) -> bool {
    active_workers < MAX_CONCURRENT_SENDS_PER_SESSION
}

async fn reject_file_send_request_at_capacity(
    paths: &AgentPaths,
    request_id: &str,
    expected_runtime_id: &str,
) -> Result<()> {
    reject_file_transfer_request_for_runtime(
        paths,
        request_id,
        expected_runtime_id,
        "agent file-send concurrency limit reached",
    )
    .await
    .map(|_| ())
    .context("failed to persist file-send concurrency rejection")
}

async fn run_managed_session(
    paths: AgentPaths,
    control: ManagedSessionControl,
    cancel: CancellationToken,
    inbound_file_store: Arc<InboundFileStore>,
    outbound_transfer_resources: Arc<OutboundTransferResources>,
) -> Result<()> {
    if control.target_runtime_id.trim().is_empty() {
        bail!("managed session control is missing its runtime incarnation binding");
    }
    let authority = RuntimeIncarnationAuthority::new(
        paths.clone(),
        control.session_id.clone(),
        control.target_runtime_id.clone(),
        cancel.clone(),
    );
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
    let pqc_initiator =
        build_pqc_initiator_config_from_env(&paths, &identity, &local_binding, control.role)
            .await?;
    let pqc_responder =
        build_pqc_responder_config(&paths, &identity, &local_binding, control.role).await?;
    let local_join_bootstrap = build_local_join_bootstrap(
        &paths,
        &local_binding,
        &control.local_device_id,
        pqc_responder.as_ref(),
    )
    .await?;
    let mut connection = authority
        .run_external_effect(
            "signaling connection establishment",
            SignalingConnection::connect(ws_url, &control.session_id),
        )
        .await?;
    let native_config =
        NativeWebRtcConfig {
            session_id: control.session_id.clone(),
            local_device_id: control.local_device_id.clone(),
            role: control.role,
            turn_credentials: control.turn_credentials.clone(),
            classic_initiator: (control.role == RuntimeSessionRole::Initiator
                && pqc_initiator.is_none())
            .then(|| -> Result<skybridge_core::ClassicInitiatorConfig> {
                let signing_secret_key = identity
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
            classic_responder: (control.role == RuntimeSessionRole::Responder
                && pqc_responder.is_none())
            .then(|| -> Result<skybridge_core::ClassicResponderConfig> {
                let signing_secret_key = identity
                    .signing_key
                    .ed25519_secret_key_bytes()
                    .ok_or_else(|| {
                        anyhow!("classic responder requires an Ed25519 protocol identity")
                    })?;
                Ok(skybridge_core::ClassicResponderConfig {
                    local_binding: local_binding.clone(),
                    signing_secret_key,
                    local_device_name: Some(identity.state.device.device_name.clone()),
                    policy: skybridge_core::DowngradePolicy::Default,
                })
            })
            .transpose()?,
            pqc_initiator,
            pqc_responder,
        };
    let coordinator = Arc::new(FileTransferCoordinator::new(
        control.session_id.clone(),
        inbound_file_store,
        authority.clone(),
    ));
    let mut native_session = authority
        .run_external_effect(
            "native transport construction",
            NativeWebRtcSession::new(native_config),
        )
        .await?;
    authority
        .run_external_effect(
            "native file-transfer heartbeat advertisement configuration",
            native_session.configure_heartbeat_advertisement(NativeWebRtcHeartbeatAdvertisement {
                capabilities: Some(vec!["file_transfer".to_owned()]),
                file_transfer_port: None,
                remote_control_port: None,
            }),
        )
        .await?;
    authority
        .run_external_effect("native transport start", native_session.start())
        .await?;
    let file_sender = native_session.sender_handle();
    let mut pending_join_envelope = Some(match local_join_bootstrap {
        Some(bootstrap) => {
            make_join_envelope(&control.session_id, &control.local_device_id, bootstrap)?
        }
        None => make_explicit_classic_join_envelope(&control.session_id, &control.local_device_id)?,
    });
    let mut join_sent = false;
    let mut signaling_stream_closed = false;
    let mut signaling_drop_injected = false;
    let mut control_request_observation_ticker = interval(Duration::from_secs(1));
    control_request_observation_ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut receive_idle_ticker = interval(Duration::from_secs(5));
    receive_idle_ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut file_send_workers = BTreeMap::<String, FileSendWorker>::new();

    let session_result: Result<()> = async {
        loop {
            tokio::select! {
            _ = cancel.cancelled() => {
                info!(
                    kind = "agent.session.worker_cancelled",
                    session_id = %control.session_id,
                    "managed session worker cancelled"
                );
                break;
            }
            event = connection.next_runtime_event(), if !signaling_stream_closed => {
                let Some(event) = event else {
                    signaling_stream_closed = true;
                    if should_stop_worker(
                        &paths,
                        &control.session_id,
                        &control.target_runtime_id,
                        signaling_stream_closed,
                    ).await? {
                        break;
                    }
                    continue;
                };
                match event {
                    SignalingRuntimeEvent::Lifecycle(lifecycle) => {
                        apply_signaling_runtime_event(
                            &paths,
                            &control.session_id,
                            &control.target_runtime_id,
                            &lifecycle,
                        ).await?;
                        if lifecycle.phase == SignalingLifecyclePhase::Bound && !join_sent {
                            let join_envelope = pending_join_envelope
                                .take()
                                .ok_or_else(|| anyhow!("signaling join envelope was already consumed"))?;
                            authority
                                .run_external_effect(
                                    "signaling join send",
                                    connection.send(join_envelope),
                                )
                                .await?;
                            join_sent = true;
                        }
                        let event_context = ManagedRuntimeEventContext {
                            paths: &paths,
                            connection: &connection,
                            session_id: &control.session_id,
                            expected_runtime_id: &control.target_runtime_id,
                            coordinator: coordinator.as_ref(),
                            file_sender: &file_sender,
                            authority: &authority,
                        };
                        drain_native_runtime_events(&event_context, &mut native_session).await?;
                        if matches!(lifecycle.phase, SignalingLifecyclePhase::Closed | SignalingLifecyclePhase::Failed) {
                            signaling_stream_closed = true;
                            if should_stop_worker(
                                &paths,
                                &control.session_id,
                                &control.target_runtime_id,
                                signaling_stream_closed,
                            ).await? {
                                break;
                            }
                        }
                    }
                    SignalingRuntimeEvent::Inbound(inbound) => {
                        apply_inbound_runtime_event(
                            &paths,
                            &control.session_id,
                            &control.target_runtime_id,
                            &control.local_device_id,
                            inbound,
                            &native_session,
                            &authority,
                        )
                        .await?;
                        let event_context = ManagedRuntimeEventContext {
                            paths: &paths,
                            connection: &connection,
                            session_id: &control.session_id,
                            expected_runtime_id: &control.target_runtime_id,
                            coordinator: coordinator.as_ref(),
                            file_sender: &file_sender,
                            authority: &authority,
                        };
                        drain_native_runtime_events(&event_context, &mut native_session).await?;
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
                let event_context = ManagedRuntimeEventContext {
                    paths: &paths,
                    connection: &connection,
                    session_id: &control.session_id,
                    expected_runtime_id: &control.target_runtime_id,
                    coordinator: coordinator.as_ref(),
                    file_sender: &file_sender,
                    authority: &authority,
                };
                apply_native_runtime_event(&event_context, event).await?;
                if should_inject_signaling_drop {
                    inject_signaling_drop_after_handshake(
                        &paths,
                        &control.session_id,
                        &control.target_runtime_id,
                    ).await?;
                    signaling_stream_closed = true;
                    signaling_drop_injected = true;
                    info!(
                        kind = "agent.session.signaling_drop_injected",
                        session_id = %control.session_id,
                        "injected synthetic signaling drop after handshake completion"
                    );
                }
                if should_stop_worker(
                    &paths,
                    &control.session_id,
                    &control.target_runtime_id,
                    signaling_stream_closed,
                ).await? {
                    break;
                }
            }
            _ = control_request_observation_ticker.tick() => {
                drain_finished_file_send_workers(
                    &control.session_id,
                    &mut file_send_workers,
                )
                .await?;
                let inbound_decisions = observe_inbound_file_transfer_decisions_for_runtime(
                    &paths,
                    &control.session_id,
                    &control.target_runtime_id,
                )
                .await?;
                for decision in inbound_decisions {
                    let apply_result = match decision.decision {
                        Some(InboundFileTransferApprovalDecision::Approve) => {
                            coordinator
                                .approve_inbound(&decision.transfer_id, &file_sender)
                                .await
                        }
                        Some(
                            InboundFileTransferApprovalDecision::Reject
                            | InboundFileTransferApprovalDecision::Expire,
                        ) => {
                            coordinator
                                .reject_inbound(&decision.transfer_id, &file_sender)
                                .await
                        }
                        None => bail!(
                            "observed inbound file approval decision without a decision value"
                        ),
                    };
                    match apply_result {
                        Ok(()) => {
                            mark_inbound_file_transfer_decision_applied_for_runtime(
                                &paths,
                                &control.session_id,
                                &decision.transfer_id,
                                &control.target_runtime_id,
                            )
                            .await?;
                        }
                        Err(apply_error) => {
                            mark_inbound_file_transfer_decision_failed_for_runtime(
                                &paths,
                                &control.session_id,
                                &decision.transfer_id,
                                &control.target_runtime_id,
                            )
                            .await
                            .map_err(|persist_error| {
                                anyhow!(
                                    "failed to apply inbound file decision: {apply_error:#}; failure persistence also failed: {persist_error:#}"
                                )
                            })?;
                            return Err(apply_error)
                                .context("failed to apply inbound file approval decision");
                        }
                    }
                }
                match observe_remote_desktop_requests_for_runtime(
                    &paths,
                    &control.session_id,
                    &control.target_runtime_id,
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
                match observe_file_transfer_requests_for_runtime(
                    &paths,
                    &control.session_id,
                    &control.target_runtime_id,
                )
                .await
                {
                    Ok(observed) if !observed.is_empty() => {
                        for request in observed {
                            if !file_send_capacity_available(file_send_workers.len()) {
                                reject_file_send_request_at_capacity(
                                    &paths,
                                    &request.request_id,
                                    &control.target_runtime_id,
                                )
                                .await?;
                                warn!(
                                    kind = "agent.file_transfer.request_rejected_capacity",
                                    session_id = %request.session_id,
                                    request_id = %request.request_id,
                                    max_concurrent_sends = MAX_CONCURRENT_SENDS_PER_SESSION,
                                    "file transfer request rejected at the managed-session concurrency boundary"
                                );
                                continue;
                            }
                            info!(
                                kind = "agent.file_transfer.request_observed",
                                session_id = %request.session_id,
                                request_id = %request.request_id,
                                action = ?request.action,
                                "file transfer request observed by agent; starting live transfer"
                            );
                            let request_id = request.request_id.clone();
                            if file_send_workers.contains_key(&request_id) {
                                bail!("duplicate active file-send worker `{request_id}`");
                            }
                            let worker = spawn_file_send_transfer(
                                paths.clone(),
                                Arc::clone(&coordinator),
                                request,
                                file_sender.clone(),
                                cancel.child_token(),
                                Arc::clone(&outbound_transfer_resources),
                            );
                            file_send_workers.insert(request_id, worker);
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
            _ = receive_idle_ticker.tick() => {
                coordinator.expire_idle_receives(&file_sender).await?;
            }
            }
        }
        Ok(())
    }
    .await;

    let file_send_cleanup =
        shutdown_file_send_workers(&control.session_id, &mut file_send_workers).await;
    let receive_cleanup = coordinator.shutdown_receives().await;
    let native_close = native_session.close().await;
    let mut failures = Vec::new();
    if let Err(error) = session_result {
        failures.push(format!("runtime: {error:#}"));
    }
    if let Err(error) = file_send_cleanup {
        failures.push(format!("file-send cleanup: {error:#}"));
    }
    if let Err(error) = receive_cleanup {
        failures.push(format!("inbound file cleanup: {error:#}"));
    }
    if let Err(error) = native_close {
        failures.push(format!("native session close: {error:#}"));
    }
    if failures.is_empty() {
        Ok(())
    } else {
        bail!(
            "managed session `{}` failed: {}",
            control.session_id,
            failures.join("; ")
        )
    }
}

struct ManagedRuntimeEventContext<'a> {
    paths: &'a AgentPaths,
    connection: &'a SignalingConnection,
    session_id: &'a str,
    expected_runtime_id: &'a str,
    coordinator: &'a FileTransferCoordinator,
    file_sender: &'a skybridge_core::NativeWebRtcSender,
    authority: &'a RuntimeIncarnationAuthority,
}

async fn drain_native_runtime_events(
    context: &ManagedRuntimeEventContext<'_>,
    native_session: &mut NativeWebRtcSession,
) -> Result<()> {
    let mut drained = 0usize;
    while let Some(event) = native_session.try_next_event() {
        drained = drained.saturating_add(1);
        apply_native_runtime_event(context, event).await?;
    }
    if drained > 0 {
        info!(
            kind = "agent.session.native_events_drained",
            session_id = %context.session_id,
            drained = drained,
            "drained pending native runtime events"
        );
    }
    Ok(())
}

async fn apply_signaling_runtime_event(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    event: &skybridge_core::SignalingLifecycleEvent,
) -> Result<()> {
    apply_signaling_event_for_runtime(paths, session_id, expected_runtime_id, event.clone())
        .await
        .map(|_| ())
}

async fn apply_inbound_runtime_event(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    local_device_id: &str,
    inbound: InboundMessage,
    native_session: &NativeWebRtcSession,
    authority: &RuntimeIncarnationAuthority,
) -> Result<()> {
    match inbound {
        InboundMessage::Envelope(envelope) => {
            validate_inbound_signaling_envelope(session_id, local_device_id, &envelope)?;
            validate_persisted_remote_peer(paths, session_id, expected_runtime_id, &envelope.from)
                .await?;
            let disposition = authority
                .run_external_effect(
                    "inbound signaling application",
                    native_session.handle_signaling_envelope(&envelope),
                )
                .await?;
            if disposition == NativeWebRtcSignalingDisposition::AcceptedWithPeerBinding {
                update_session_remote_peer_for_runtime(
                    paths,
                    session_id,
                    expected_runtime_id,
                    envelope.from,
                    None,
                    None,
                )
                .await?;
            }
        }
        InboundMessage::ServerFrame(_) | InboundMessage::Unknown => {}
    }
    Ok(())
}

async fn validate_persisted_remote_peer(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    inbound_remote_device_id: &str,
) -> Result<()> {
    let registry = load_session_registry(paths).await?;
    let record = registry
        .sessions
        .get(session_id)
        .ok_or_else(|| anyhow!("runtime session is missing while validating remote peer"))?;
    if record.runtime_id != expected_runtime_id {
        bail!("managed runtime incarnation no longer owns inbound signaling");
    }
    if record
        .remote_device_id
        .as_deref()
        .is_some_and(|expected| expected != inbound_remote_device_id)
    {
        bail!("remote device id did not match the pre-bound session peer");
    }
    Ok(())
}

fn validate_inbound_signaling_envelope(
    expected_session_id: &str,
    local_device_id: &str,
    envelope: &skybridge_core::WebRtcSignalingEnvelope,
) -> Result<()> {
    if envelope.session_id != expected_session_id {
        bail!("inbound signaling envelope session_id does not match the managed session");
    }
    let remote_device_id = envelope.from.trim();
    if remote_device_id.is_empty()
        || remote_device_id != envelope.from
        || remote_device_id.len() > 256
        || remote_device_id.chars().any(char::is_control)
    {
        bail!("inbound signaling envelope from device id violates the identity boundary");
    }
    if remote_device_id == local_device_id {
        bail!("inbound signaling envelope cannot identify the local device as its sender");
    }
    if envelope
        .to
        .as_deref()
        .is_some_and(|recipient| recipient != local_device_id)
    {
        bail!("inbound signaling envelope recipient does not match the local device");
    }
    Ok(())
}

async fn apply_native_runtime_event(
    context: &ManagedRuntimeEventContext<'_>,
    event: NativeWebRtcEvent,
) -> Result<()> {
    match event {
        NativeWebRtcEvent::SignalingEnvelope(envelope) => {
            context
                .authority
                .run_external_effect("signaling envelope send", context.connection.send(envelope))
                .await?;
        }
        NativeWebRtcEvent::InboundFileFrame(frame) => {
            context
                .coordinator
                .route_inbound(*frame, context.file_sender)
                .await
                .context("failed to route inbound file frame")?;
        }
        NativeWebRtcEvent::TransportReady => {
            info!(
                kind = "agent.session.transport_ready_applied",
                session_id = %context.session_id,
                "applying transport_ready to session registry"
            );
            apply_transport_event_for_runtime(
                context.paths,
                context.session_id,
                context.expected_runtime_id,
                RuntimeSessionTransportEvent::TransportReady,
            )
            .await?;
        }
        NativeWebRtcEvent::HandshakeComplete {
            negotiated_suite,
            peer_protocol_public_key_fingerprint,
        } => {
            info!(
                kind = "agent.session.handshake_complete_applied",
                session_id = %context.session_id,
                negotiated_suite = %negotiated_suite,
                "applying handshake_complete to session registry"
            );
            apply_authenticated_handshake_receipt(
                context.paths,
                context.session_id,
                context.expected_runtime_id,
                &negotiated_suite,
                &peer_protocol_public_key_fingerprint,
            )
            .await?;
        }
        NativeWebRtcEvent::AuthenticatedPeerHeartbeat {
            payload,
            sbwc_counter,
            received_at_unix_seconds,
        } => {
            if !received_at_unix_seconds.is_finite() {
                bail!("authenticated heartbeat has an invalid local receipt time");
            }
            let sent_at_unix_seconds = payload.sent_at + APPLE_REFERENCE_UNIX_SECONDS;
            if !sent_at_unix_seconds.is_finite()
                || (sent_at_unix_seconds - received_at_unix_seconds).abs()
                    > MAX_AUTHENTICATED_HEARTBEAT_CLOCK_SKEW_SECONDS
            {
                bail!("authenticated heartbeat is outside the freshness window");
            }
            let device_id = payload
                .device_id
                .clone()
                .ok_or_else(|| anyhow!("authenticated heartbeat is missing deviceId"))?;
            let device_name = payload
                .device_name
                .clone()
                .ok_or_else(|| anyhow!("authenticated heartbeat is missing deviceName"))?;
            let observation = RuntimeAuthenticatedPeerObservation {
                device_id,
                device_name,
                platform: payload.platform.clone(),
                capabilities: payload.capabilities.clone(),
                file_transfer_port: payload.file_transfer_port,
                remote_control_port: payload.remote_control_port,
                sbwc_counter,
                observed_at: OffsetDateTime::now_utc(),
            };
            info!(
                kind = "agent.session.authenticated_peer_observation_applied",
                session_id = %context.session_id,
                sbwc_counter,
                capability_count = observation.capabilities.as_ref().map(Vec::len),
                "persisting authenticated peer identity and capabilities"
            );
            apply_transport_event_for_runtime(
                context.paths,
                context.session_id,
                context.expected_runtime_id,
                RuntimeSessionTransportEvent::AuthenticatedPeerHeartbeat(Box::new(observation)),
            )
            .await?;
        }
        NativeWebRtcEvent::SelectedIceRoute(observation) => {
            info!(
                kind = "agent.session.selected_ice_route_applied",
                session_id = %context.session_id,
                route_kind = ?observation.kind,
                remote_candidate_type = %observation.remote_candidate_type,
                "persisting selected ICE route observation"
            );
            apply_transport_event_for_runtime(
                context.paths,
                context.session_id,
                context.expected_runtime_id,
                RuntimeSessionTransportEvent::SelectedIceRoute(observation),
            )
            .await?;
        }
        NativeWebRtcEvent::Keepalive { kind, ping_id } => {
            info!(
                kind = "agent.session.keepalive_applied",
                session_id = %context.session_id,
                keepalive_kind = ?kind,
                ping_id = ping_id,
                "applying keepalive event to session registry"
            );
            apply_transport_event_for_runtime(
                context.paths,
                context.session_id,
                context.expected_runtime_id,
                RuntimeSessionTransportEvent::Keepalive { kind, ping_id },
            )
            .await?;
        }
        NativeWebRtcEvent::TransportDisconnected { reason } => {
            info!(
                kind = "agent.session.transport_disconnected_applied",
                session_id = %context.session_id,
                reason = reason.as_deref().unwrap_or("unknown"),
                "applying transport_disconnected to session registry"
            );
            apply_transport_event_for_runtime(
                context.paths,
                context.session_id,
                context.expected_runtime_id,
                RuntimeSessionTransportEvent::TransportDisconnected { reason },
            )
            .await?;
        }
    }
    Ok(())
}

async fn apply_authenticated_handshake_receipt(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    negotiated_suite: &str,
    peer_protocol_public_key_fingerprint: &str,
) -> Result<()> {
    let after = apply_transport_event_for_runtime(
        paths,
        session_id,
        expected_runtime_id,
        RuntimeSessionTransportEvent::HandshakeComplete {
            negotiated_suite: negotiated_suite.to_owned(),
            peer_protocol_public_key_fingerprint: peer_protocol_public_key_fingerprint.to_owned(),
        },
    )
    .await?;
    let record = after
        .get(session_id)
        .ok_or_else(|| anyhow!("runtime session disappeared after handshake apply"))?;
    let stored_fingerprint_matches = record
        .remote_protocol_public_key_fingerprint
        .as_deref()
        .is_some_and(|fingerprint| {
            fingerprint.eq_ignore_ascii_case(peer_protocol_public_key_fingerprint)
        });
    let readiness_matches = matches!(
        &record.readiness,
        SessionReadiness::HandshakeComplete {
            session_id: established_session_id,
            negotiated_suite: established_suite,
        } if established_session_id == session_id && established_suite == negotiated_suite
    );
    if !stored_fingerprint_matches {
        bail!("handshake receipt peer identity mismatched the pre-bound fingerprint");
    }
    if !readiness_matches {
        bail!(
            "handshake receipt did not bind the authenticated peer identity and handshake-complete readiness"
        );
    }
    Ok(())
}

async fn should_stop_worker(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    signaling_stream_closed: bool,
) -> Result<bool> {
    let registry = load_session_registry(paths).await?;
    let Some(record) = registry.get(session_id) else {
        return Ok(true);
    };
    if record.runtime_id != expected_runtime_id {
        return Ok(true);
    }
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

async fn inject_signaling_drop_after_handshake(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
) -> Result<()> {
    let registry = load_session_registry(paths).await?;
    let Some(record) = registry.get(session_id) else {
        return Ok(());
    };
    if record.runtime_id != expected_runtime_id {
        bail!("managed runtime incarnation no longer owns signaling-drop injection");
    }
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
    apply_signaling_runtime_event(paths, session_id, expected_runtime_id, &event).await
}

async fn wait_for_shutdown_signal() -> Result<()> {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};

        let mut terminate =
            signal(SignalKind::terminate()).context("failed to install SIGTERM handler")?;
        tokio::select! {
            result = tokio::signal::ctrl_c() => {
                result.context("failed while waiting for interrupt signal")?;
            }
            received = terminate.recv() => {
                received.ok_or_else(|| anyhow!("SIGTERM signal stream closed unexpectedly"))?;
            }
        }
    }

    #[cfg(not(unix))]
    {
        tokio::signal::ctrl_c()
            .await
            .context("failed while waiting for interrupt signal")?;
    }
    Ok(())
}
