use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use directories::ProjectDirs;
use skybridge_core::{
    AgentHealthSnapshot, AgentRuntimeStatus, CryptoSuite, EventLevel, InboundMessage,
    LocalIdentityState, ManagedSessionControl, NativeWebRtcConfig, NativeWebRtcEvent,
    NativeWebRtcSession, PqcInitiatorConfig, PqcResponderConfig, RuntimeSessionRole,
    RuntimeSessionState, RuntimeSessionTransportEvent, SignalServerClient, SignalingConnection,
    SignalingLifecyclePhase, SignalingRuntimeEvent, StructuredEvent, make_join_envelope,
};
use time::OffsetDateTime;
use tokio::fs;
use tokio::task::JoinHandle;
use tokio::time::MissedTickBehavior;
use tokio::time::interval;
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::fmt::time::UtcTime;

use crate::state::{
    DeviceIdentityMaterial, ensure_device_identity, ensure_rust_pqc_identity,
    load_managed_session_controls, load_session_registry, remove_managed_session_control,
    signing_binding, store_session_registry,
};

static TRACING_GUARD: OnceLock<WorkerGuard> = OnceLock::new();

const ENV_PEER_MLKEM768_PUBLIC_KEY_B64: &str = "SKYBRIDGE_PQC_PEER_MLKEM768_PUBLIC_KEY_BASE64";
const ENV_PEER_XWING_PUBLIC_KEY_B64: &str = "SKYBRIDGE_PQC_PEER_XWING_PUBLIC_KEY_BASE64";
const ENV_PQC_PREFERRED_SUITE: &str = "SKYBRIDGE_PQC_PREFERRED_SUITE";
const ENV_PQC_BRIDGE_IDENTITY: &str = "SKYBRIDGE_PQC_BRIDGE_IDENTITY";

#[derive(Debug, Clone)]
pub struct AgentRuntimeOptions {
    pub state_dir: Option<PathBuf>,
    pub heartbeat_interval: Duration,
}

impl Default for AgentRuntimeOptions {
    fn default() -> Self {
        Self {
            state_dir: None,
            heartbeat_interval: Duration::from_secs(2),
        }
    }
}

#[derive(Debug, Clone)]
pub struct AgentPaths {
    pub root: PathBuf,
    pub identity_dir: PathBuf,
    pub runtime_dir: PathBuf,
    pub logs_dir: PathBuf,
    pub identity_file: PathBuf,
    pub session_controls_file: PathBuf,
    pub health_file: PathBuf,
    pub log_file: PathBuf,
}

pub fn resolve_paths(state_dir_override: Option<PathBuf>) -> Result<AgentPaths> {
    let root = if let Some(explicit) = state_dir_override {
        explicit
    } else if let Some(from_env) = std::env::var_os("SKYBRIDGE_STATE_DIR") {
        PathBuf::from(from_env)
    } else {
        let dirs = ProjectDirs::from("com", "SkyBridge", "skybridge")
            .ok_or_else(|| anyhow!("failed to resolve platform state directory"))?;
        dirs.state_dir()
            .ok_or_else(|| anyhow!("platform state directory is unavailable"))?
            .to_path_buf()
    };

    Ok(AgentPaths {
        identity_dir: root.join("identity"),
        runtime_dir: root.join("runtime"),
        logs_dir: root.join("logs"),
        identity_file: root.join("identity").join("device.json"),
        session_controls_file: root.join("runtime").join("session-controls.json"),
        health_file: root.join("runtime").join("health.json"),
        log_file: root.join("logs").join("agent.log"),
        root,
    })
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

    wait_for_shutdown_signal().await;
    cancel.cancel();

    if let Err(join_error) = heartbeat_task.await {
        warn!(kind = "agent.heartbeat.join_failed", error = %join_error, "heartbeat worker stopped unexpectedly");
    }
    if let Err(join_error) = supervisor_task.await {
        warn!(kind = "agent.supervisor.join_failed", error = %join_error, "supervisor worker stopped unexpectedly");
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

async fn ensure_layout(paths: &AgentPaths) -> Result<()> {
    ensure_dir(&paths.root).await?;
    ensure_dir(&paths.identity_dir).await?;
    ensure_dir(&paths.runtime_dir).await?;
    ensure_dir(&paths.logs_dir).await?;
    Ok(())
}

async fn ensure_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)
        .await
        .with_context(|| format!("failed to create directory {}", path.display()))?;
    restrict_dir_permissions(path).await
}

async fn write_json<T>(path: &Path, value: &T) -> Result<()>
where
    T: serde::Serialize,
{
    let body = serde_json::to_vec_pretty(value).context("failed to encode json")?;
    fs::write(path, body)
        .await
        .with_context(|| format!("failed to write {}", path.display()))?;
    restrict_file_permissions(path).await
}

async fn append_event_line(path: &Path, event: StructuredEvent) -> Result<()> {
    let body = serde_json::to_vec(&event).context("failed to encode structured event")?;
    let mut line = body;
    line.push(b'\n');
    use tokio::io::AsyncWriteExt;

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .await
        .with_context(|| format!("failed to open {}", path.display()))?;
    file.write_all(&line)
        .await
        .with_context(|| format!("failed to append {}", path.display()))?;
    file.flush()
        .await
        .with_context(|| format!("failed to flush {}", path.display()))?;
    restrict_file_permissions(path).await
}

async fn load_json<T>(path: &Path) -> Result<Option<T>>
where
    T: for<'de> serde::Deserialize<'de>,
{
    match fs::read_to_string(path).await {
        Ok(body) => {
            let decoded = serde_json::from_str(&body)
                .with_context(|| format!("failed to decode {}", path.display()))?;
            Ok(Some(decoded))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("failed to read {}", path.display())),
    }
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
        let mut workers = std::collections::BTreeMap::<String, CancellationToken>::new();
        loop {
            tokio::select! {
                _ = cancel.cancelled() => {
                    for worker_cancel in workers.values() {
                        worker_cancel.cancel();
                    }
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

fn pqc_bridge_identity_enabled() -> bool {
    std::env::var(ENV_PQC_BRIDGE_IDENTITY)
        .ok()
        .is_some_and(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes"
            )
        })
}

async fn build_pqc_initiator_config_from_env(
    paths: &AgentPaths,
    identity: &DeviceIdentityMaterial,
    local_binding: &skybridge_core::ProtocolIdentityBinding,
    role: RuntimeSessionRole,
) -> Result<Option<PqcInitiatorConfig>> {
    if role != RuntimeSessionRole::Initiator {
        return Ok(None);
    }

    let mut peer_kem_public_keys = BTreeMap::new();
    if let Some(value) = std::env::var(ENV_PEER_XWING_PUBLIC_KEY_B64)
        .ok()
        .filter(|value| !value.trim().is_empty())
    {
        peer_kem_public_keys.insert(
            CryptoSuite::XWING_MLDSA,
            STANDARD
                .decode(value.trim().as_bytes())
                .map_err(|error| anyhow!("invalid X-Wing peer public key: {error}"))?,
        );
    }
    if let Some(value) = std::env::var(ENV_PEER_MLKEM768_PUBLIC_KEY_B64)
        .ok()
        .filter(|value| !value.trim().is_empty())
    {
        peer_kem_public_keys.insert(
            CryptoSuite::MLKEM768_MLDSA65,
            STANDARD
                .decode(value.trim().as_bytes())
                .map_err(|error| anyhow!("invalid ML-KEM-768 peer public key: {error}"))?,
        );
    }

    let bridge_identity = pqc_bridge_identity_enabled();

    if peer_kem_public_keys.is_empty() {
        if local_binding.protocol_signing_algorithm
            == skybridge_core::ProtocolSigningAlgorithm::MlDsa65
            || bridge_identity
        {
            bail!(
                "ML-DSA-65 protocol identity selected but no peer PQC public keys are configured via {} or {}",
                ENV_PEER_XWING_PUBLIC_KEY_B64,
                ENV_PEER_MLKEM768_PUBLIC_KEY_B64
            );
        }
        return Ok(None);
    }

    let (pqc_binding, signing_secret_key) = if local_binding.protocol_signing_algorithm
        == skybridge_core::ProtocolSigningAlgorithm::MlDsa65
    {
        let signing_secret_key = identity
            .signing_key
            .mldsa65_secret_key_bytes()
            .ok_or_else(|| anyhow!("missing ML-DSA-65 signing secret key"))?;
        (local_binding.clone(), signing_secret_key)
    } else if bridge_identity {
        let pqc_identity = ensure_rust_pqc_identity(paths).await?;
        warn!(
            kind = "agent.session.pqc_bridge_identity_enabled",
            device_id = %local_binding.device_id,
            control_plane_algorithm = %local_binding.protocol_signing_algorithm,
            handshake_algorithm = %pqc_identity.signing_algorithm,
            "using bridge PQC handshake identity separate from control-plane identity"
        );
        (
            skybridge_core::ProtocolIdentityBinding::new(
                local_binding.device_id.clone(),
                pqc_identity.signing_algorithm,
                pqc_identity.signing_public_key.clone(),
                None,
            )
            .map_err(anyhow::Error::from)?,
            pqc_identity.signing_secret_key,
        )
    } else {
        bail!(
            "peer PQC public keys are configured, but the local protocol identity is {}; set SKYBRIDGE_PROTOCOL_SIGNING_ALGORITHM=ML-DSA-65 first",
            local_binding.protocol_signing_algorithm
        );
    };
    let preferred_suite = std::env::var(ENV_PQC_PREFERRED_SUITE)
        .ok()
        .and_then(|value| CryptoSuite::from_name(&value));
    let mut preferred_suites = Vec::new();
    if let Some(preferred_suite) = preferred_suite {
        if peer_kem_public_keys.contains_key(&preferred_suite) {
            preferred_suites.push(preferred_suite);
        }
    }
    for candidate in [CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65] {
        if peer_kem_public_keys.contains_key(&candidate) && !preferred_suites.contains(&candidate) {
            preferred_suites.push(candidate);
        }
    }

    Ok(Some(PqcInitiatorConfig {
        local_binding: pqc_binding,
        signing_secret_key,
        local_device_name: Some(identity.state.device.device_name.clone()),
        preferred_suites,
        peer_kem_public_keys,
    }))
}

async fn build_pqc_responder_config(
    paths: &AgentPaths,
    identity: &DeviceIdentityMaterial,
    local_binding: &skybridge_core::ProtocolIdentityBinding,
    role: RuntimeSessionRole,
) -> Result<Option<PqcResponderConfig>> {
    if role != RuntimeSessionRole::Responder {
        return Ok(None);
    }
    let bridge_identity = pqc_bridge_identity_enabled();
    if local_binding.protocol_signing_algorithm != skybridge_core::ProtocolSigningAlgorithm::MlDsa65
        && !bridge_identity
    {
        return Ok(None);
    }

    let pqc_identity = ensure_rust_pqc_identity(paths).await?;
    let pqc_binding = if local_binding.protocol_signing_algorithm
        == skybridge_core::ProtocolSigningAlgorithm::MlDsa65
    {
        local_binding.clone()
    } else {
        warn!(
            kind = "agent.session.pqc_bridge_identity_enabled",
            device_id = %local_binding.device_id,
            control_plane_algorithm = %local_binding.protocol_signing_algorithm,
            handshake_algorithm = %pqc_identity.signing_algorithm,
            "using bridge PQC responder identity separate from control-plane identity"
        );
        skybridge_core::ProtocolIdentityBinding::new(
            local_binding.device_id.clone(),
            pqc_identity.signing_algorithm,
            pqc_identity.signing_public_key.clone(),
            None,
        )
        .map_err(anyhow::Error::from)?
    };
    Ok(Some(PqcResponderConfig {
        local_binding: pqc_binding,
        local_device_name: Some(identity.state.device.device_name.clone()),
        identity: pqc_identity,
        supported_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
    }))
}

async fn reconcile_managed_sessions(
    paths: &AgentPaths,
    root_cancel: &CancellationToken,
    workers: &mut std::collections::BTreeMap<String, CancellationToken>,
) -> Result<()> {
    let controls = load_managed_session_controls(paths).await?;
    let desired = controls
        .active_controls()
        .into_iter()
        .map(|control| (control.session_id.clone(), control))
        .collect::<std::collections::BTreeMap<_, _>>();

    for session_id in workers
        .keys()
        .filter(|session_id| !desired.contains_key(*session_id))
        .cloned()
        .collect::<Vec<_>>()
    {
        if let Some(worker_cancel) = workers.remove(&session_id) {
            worker_cancel.cancel();
        }
    }

    for (session_id, control) in desired {
        if workers.contains_key(&session_id) {
            continue;
        }
        let worker_cancel = root_cancel.child_token();
        workers.insert(session_id.clone(), worker_cancel.clone());
        let worker_paths = paths.clone();
        tokio::spawn(async move {
            if let Err(error) =
                run_managed_session(worker_paths, control, worker_cancel.clone()).await
            {
                warn!(
                    kind = "agent.session.worker_failed",
                    session_id = %session_id,
                    error = %error,
                    "managed session worker failed"
                );
            }
        });
    }

    Ok(())
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
    let pqc_initiator =
        build_pqc_initiator_config_from_env(&paths, &identity, &local_binding, control.role)
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
            })
        })
        .transpose()?,
        pqc_initiator,
        pqc_responder,
    })
    .await?;
    native_session.start().await?;
    let mut join_sent = false;
    let mut signaling_stream_closed = false;
    let mut signaling_drop_injected = false;

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
                apply_native_runtime_event(&paths, &connection, &control.session_id, event).await?;
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
        }
    }

    Ok(())
}

async fn drain_native_runtime_events(
    paths: &AgentPaths,
    connection: &SignalingConnection,
    session_id: &str,
    native_session: &mut NativeWebRtcSession,
) -> Result<()> {
    let mut drained = 0usize;
    while let Some(event) = native_session.try_next_event() {
        drained = drained.saturating_add(1);
        apply_native_runtime_event(paths, connection, session_id, event).await?;
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
    let mut registry = load_session_registry(paths).await?;
    registry.apply_signaling_event(session_id, event);
    store_session_registry(paths, &registry).await
}

async fn apply_inbound_runtime_event(
    paths: &AgentPaths,
    session_id: &str,
    inbound: InboundMessage,
    native_session: &NativeWebRtcSession,
) -> Result<()> {
    match inbound {
        InboundMessage::Envelope(envelope) => {
            let mut registry = load_session_registry(paths).await?;
            registry.update_remote_peer(session_id, envelope.from.clone(), None, None);
            store_session_registry(paths, &registry).await?;
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
) -> Result<()> {
    match event {
        NativeWebRtcEvent::SignalingEnvelope(envelope) => {
            connection.send(envelope).await?;
        }
        NativeWebRtcEvent::TransportReady => {
            info!(
                kind = "agent.session.transport_ready_applied",
                session_id = %session_id,
                "applying transport_ready to session registry"
            );
            let mut registry = load_session_registry(paths).await?;
            registry
                .apply_transport_event(session_id, RuntimeSessionTransportEvent::TransportReady);
            store_session_registry(paths, &registry).await?;
        }
        NativeWebRtcEvent::HandshakeComplete { negotiated_suite } => {
            info!(
                kind = "agent.session.handshake_complete_applied",
                session_id = %session_id,
                negotiated_suite = %negotiated_suite,
                "applying handshake_complete to session registry"
            );
            let mut registry = load_session_registry(paths).await?;
            registry.apply_transport_event(
                session_id,
                RuntimeSessionTransportEvent::HandshakeComplete { negotiated_suite },
            );
            store_session_registry(paths, &registry).await?;
        }
        NativeWebRtcEvent::Keepalive { kind, ping_id } => {
            info!(
                kind = "agent.session.keepalive_applied",
                session_id = %session_id,
                keepalive_kind = ?kind,
                ping_id = ping_id,
                "applying keepalive event to session registry"
            );
            let mut registry = load_session_registry(paths).await?;
            registry.apply_transport_event(
                session_id,
                RuntimeSessionTransportEvent::Keepalive { kind, ping_id },
            );
            store_session_registry(paths, &registry).await?;
        }
        NativeWebRtcEvent::TransportDisconnected { reason } => {
            info!(
                kind = "agent.session.transport_disconnected_applied",
                session_id = %session_id,
                reason = reason.as_deref().unwrap_or("unknown"),
                "applying transport_disconnected to session registry"
            );
            let mut registry = load_session_registry(paths).await?;
            registry.apply_transport_event(
                session_id,
                RuntimeSessionTransportEvent::TransportDisconnected { reason },
            );
            store_session_registry(paths, &registry).await?;
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

fn init_tracing(paths: &AgentPaths) -> Result<()> {
    if TRACING_GUARD.get().is_some() {
        return Ok(());
    }

    let file_appender = tracing_appender::rolling::never(&paths.logs_dir, "agent.log");
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);
    TRACING_GUARD
        .set(guard)
        .map_err(|_| anyhow!("tracing guard already initialised"))?;

    let timer = UtcTime::rfc_3339();
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,skybridge_agent=info")),
        )
        .with_timer(timer)
        .with_writer(non_blocking)
        .json()
        .with_current_span(false)
        .with_span_list(false)
        .try_init()
        .map_err(|error| anyhow!("failed to initialize tracing subscriber: {error}"))?;
    Ok(())
}

pub(crate) async fn restrict_dir_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let permissions = std::fs::Permissions::from_mode(0o700);
        fs::set_permissions(path, permissions)
            .await
            .with_context(|| format!("failed to set permissions on {}", path.display()))?;
    }

    Ok(())
}

pub(crate) async fn restrict_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let permissions = std::fs::Permissions::from_mode(0o600);
        fs::set_permissions(path, permissions)
            .await
            .with_context(|| format!("failed to set permissions on {}", path.display()))?;
    }

    Ok(())
}
