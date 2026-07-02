use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ed25519_dalek::{Signer, SigningKey};
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use skybridge_core::{
    AuthSession, AuthState, EnrollmentStatus, FileTransferControlRequest,
    FileTransferControlRequestRegistry, FileTransferDestinationBinding, FileTransferSourceSnapshot,
    LocalIdentityState, ManagedSessionControl, ManagedSessionControlRegistry,
    NearbyDiscoveredDevice, NearbyDiscoverySnapshot, NearbyDiscoverySnapshotRegistry,
    NearbyDiscoveryTrustStatus, NebulaOAuthClient, ProtocolIdentityBinding,
    ProtocolSigningAlgorithm, RemoteDesktopCapabilitySnapshot,
    RemoteDesktopCapabilitySnapshotRegistry, RemoteDesktopControlAction,
    RemoteDesktopControlRequest, RemoteDesktopControlRequestPayload,
    RemoteDesktopControlRequestRegistry, RemoteDesktopObservedMode, RemoteDesktopResolutionRequest,
    RuntimeSessionRecord, RuntimeSessionState, RuntimeSessionTransportEvent,
    RustPqcIdentityMaterial, SessionReadiness, SessionRegistry, SignalingLifecycleEvent,
    mldsa65_generate_keypair, mldsa65_sign_detached, remote_desktop_fps_request_supported,
    remote_desktop_resolution_preset_matches, should_refresh_access_token, xwing_generate_keypair,
};
use time::OffsetDateTime;
use tokio::fs;

use crate::runtime::{AgentPaths, restrict_dir_permissions, restrict_file_permissions};

static SESSION_REGISTRY_PROCESS_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

#[derive(Debug, Clone)]
pub struct DeviceIdentityMaterial {
    pub state: LocalIdentityState,
    pub signing_key: ProtocolSigningKeyMaterial,
}

#[derive(Debug, Clone)]
pub enum ProtocolSigningKeyMaterial {
    Ed25519(SigningKey),
    MlDsa65 {
        public_key: Vec<u8>,
        secret_key: Vec<u8>,
    },
}

impl ProtocolSigningKeyMaterial {
    pub fn algorithm(&self) -> ProtocolSigningAlgorithm {
        match self {
            Self::Ed25519(_) => ProtocolSigningAlgorithm::Ed25519,
            Self::MlDsa65 { .. } => ProtocolSigningAlgorithm::MlDsa65,
        }
    }

    pub fn public_key_bytes(&self) -> Vec<u8> {
        match self {
            Self::Ed25519(signing_key) => signing_key.verifying_key().to_bytes().to_vec(),
            Self::MlDsa65 { public_key, .. } => public_key.clone(),
        }
    }

    pub fn sign(&self, payload: &[u8]) -> Result<Vec<u8>> {
        match self {
            Self::Ed25519(signing_key) => Ok(signing_key.sign(payload).to_bytes().to_vec()),
            Self::MlDsa65 { secret_key, .. } => mldsa65_sign_detached(payload, secret_key),
        }
    }

    pub fn ed25519_secret_key_bytes(&self) -> Option<Vec<u8>> {
        match self {
            Self::Ed25519(signing_key) => Some(signing_key.to_bytes().to_vec()),
            Self::MlDsa65 { .. } => None,
        }
    }

    pub fn mldsa65_secret_key_bytes(&self) -> Option<Vec<u8>> {
        match self {
            Self::Ed25519(_) => None,
            Self::MlDsa65 { secret_key, .. } => Some(secret_key.clone()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredSigningKey {
    schema_version: u32,
    algorithm: ProtocolSigningAlgorithm,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    public_key_base64: Option<String>,
    secret_key_base64: String,
}

impl StoredSigningKey {
    const SCHEMA_VERSION: u32 = 2;
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredKemIdentityKey {
    schema_version: u32,
    suite_wire_id: u16,
    public_key_base64: String,
    secret_key_base64: String,
}

impl StoredKemIdentityKey {
    const SCHEMA_VERSION: u32 = 1;
}

pub async fn ensure_device_identity(paths: &AgentPaths) -> Result<DeviceIdentityMaterial> {
    ensure_identity_layout(paths).await?;
    let requested_algorithm = requested_protocol_signing_algorithm();
    let identity = crate::runtime::load_identity_state(paths)
        .await?
        .unwrap_or_else(|| LocalIdentityState::placeholder(current_hostname(), new_device_id()));
    let desired_algorithm =
        requested_algorithm.unwrap_or(identity.device.protocol_signing_algorithm);
    let stored_key = load_signing_key(paths).await?;
    let signing_key = match stored_key {
        Some(stored_key) if stored_key.algorithm == desired_algorithm => {
            decode_signing_key(&stored_key)?
        }
        None => {
            let signing_key = generate_signing_key(desired_algorithm)?;
            store_signing_key(paths, &signing_key).await?;
            signing_key
        }
        Some(_) => {
            let signing_key = generate_signing_key(desired_algorithm)?;
            store_signing_key(paths, &signing_key).await?;
            signing_key
        }
    };
    let identity = sync_identity_binding(identity, &signing_key);
    persist_identity(paths, &identity).await?;
    Ok(DeviceIdentityMaterial {
        state: identity,
        signing_key,
    })
}

pub fn signing_binding(identity: &DeviceIdentityMaterial) -> Result<ProtocolIdentityBinding> {
    ProtocolIdentityBinding::new(
        identity.state.device.device_id.clone(),
        identity.signing_key.algorithm(),
        identity.signing_key.public_key_bytes(),
        identity.state.device.public_key_fingerprint.clone(),
    )
    .map_err(Into::into)
}

pub fn signing_signature(identity: &DeviceIdentityMaterial, payload: &[u8]) -> Result<Vec<u8>> {
    identity.signing_key.sign(payload)
}

pub async fn ensure_rust_pqc_identity(paths: &AgentPaths) -> Result<RustPqcIdentityMaterial> {
    ensure_identity_layout(paths).await?;
    let protocol_signing = ensure_mldsa65_signing_key(paths).await?;
    let mlkem_identity = ensure_kem_identity_key(paths, 0x0101).await?;
    let xwing_identity = ensure_kem_identity_key(paths, 0x0001).await?;
    #[cfg(feature = "q-periapt")]
    let qperiapt_identity = ensure_kem_identity_key(paths, 0x0011).await?;
    Ok(RustPqcIdentityMaterial {
        signing_algorithm: ProtocolSigningAlgorithm::MlDsa65,
        signing_public_key: protocol_signing.public_key_bytes(),
        signing_secret_key: protocol_signing
            .mldsa65_secret_key_bytes()
            .ok_or_else(|| anyhow!("missing ML-DSA-65 signing secret key"))?,
        mlkem768_public_key: mlkem_identity.0,
        mlkem768_secret_key: mlkem_identity.1,
        xwing_public_key: xwing_identity.0,
        xwing_secret_key: xwing_identity.1,
        #[cfg(feature = "q-periapt")]
        qperiapt_public_key: qperiapt_identity.0,
        #[cfg(feature = "q-periapt")]
        qperiapt_secret_key: qperiapt_identity.1,
    })
}

pub async fn load_auth_session(paths: &AgentPaths) -> Result<Option<AuthSession>> {
    load_json::<AuthSession>(&auth_session_file(paths)).await
}

pub async fn store_auth_session(paths: &AgentPaths, session: &AuthSession) -> Result<()> {
    ensure_identity_layout(paths).await?;
    write_json(&auth_session_file(paths), session).await?;
    let mut identity = crate::runtime::load_identity_state(paths)
        .await?
        .unwrap_or_else(|| LocalIdentityState::placeholder(current_hostname(), new_device_id()));
    identity.account_id = Some(session.user_identifier.clone());
    identity.auth_state = AuthState::LoggedIn;
    persist_identity(paths, &identity).await
}

pub async fn clear_auth_session(paths: &AgentPaths) -> Result<()> {
    ensure_identity_layout(paths).await?;
    match fs::remove_file(auth_session_file(paths)).await {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).context("failed to clear auth session"),
    }
    if let Some(mut identity) = crate::runtime::load_identity_state(paths).await? {
        identity.account_id = None;
        identity.auth_state = AuthState::LoggedOut;
        persist_identity(paths, &identity).await?;
    }
    Ok(())
}

pub async fn refresh_auth_session_if_needed(paths: &AgentPaths) -> Result<Option<AuthSession>> {
    let Some(session) = load_auth_session(paths).await? else {
        return Ok(None);
    };
    let Some(refresh_token) = session.refresh_token.as_deref() else {
        return Ok(Some(session));
    };
    if !should_refresh_access_token(&session.access_token, 300) {
        return Ok(Some(session));
    }
    let oauth = NebulaOAuthClient::from_env()?;
    let token = oauth.refresh_token(refresh_token).await?;
    let refreshed = AuthSession {
        access_token: token.access_token,
        refresh_token: token.refresh_token.or(session.refresh_token),
        user_identifier: session.user_identifier,
        nebula_id: session.nebula_id,
        display_name: session.display_name,
        issued_at: OffsetDateTime::now_utc(),
    };
    store_auth_session(paths, &refreshed).await?;
    Ok(Some(refreshed))
}

pub async fn update_enrollment_status(
    paths: &AgentPaths,
    status: EnrollmentStatus,
    device_name: Option<&str>,
) -> Result<LocalIdentityState> {
    let mut identity = crate::runtime::load_identity_state(paths)
        .await?
        .ok_or_else(|| anyhow!("device identity not initialized"))?;
    identity.device.enrollment_status = status;
    if let Some(device_name) = device_name.filter(|value| !value.trim().is_empty()) {
        identity.device.device_name = device_name.trim().to_owned();
    }
    identity.device.updated_at = OffsetDateTime::now_utc();
    persist_identity(paths, &identity).await?;
    Ok(identity)
}

pub async fn load_session_registry(paths: &AgentPaths) -> Result<SessionRegistry> {
    ensure_identity_layout(paths).await?;
    let registry_path = session_registry_file(paths);
    let lock_path = session_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, false)?;
        load_session_registry_unlocked(&registry_path)
    })
    .await
    .context("session registry read task panicked")?
}

pub async fn store_session_registry(paths: &AgentPaths, registry: &SessionRegistry) -> Result<()> {
    ensure_identity_layout(paths).await?;
    let registry_path = session_registry_file(paths);
    let lock_path = session_registry_lock_file(paths);
    let registry = registry.clone();
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, true)?;
        store_session_registry_unlocked(&registry_path, &registry)
    })
    .await
    .context("session registry write task panicked")?
}

pub async fn load_managed_session_controls(
    paths: &AgentPaths,
) -> Result<ManagedSessionControlRegistry> {
    ensure_identity_layout(paths).await?;
    Ok(
        load_json::<ManagedSessionControlRegistry>(&session_controls_file(paths))
            .await?
            .unwrap_or_default(),
    )
}

pub async fn store_managed_session_controls(
    paths: &AgentPaths,
    registry: &ManagedSessionControlRegistry,
) -> Result<()> {
    ensure_identity_layout(paths).await?;
    write_json(&session_controls_file(paths), registry).await
}

pub async fn upsert_managed_session_control(
    paths: &AgentPaths,
    mut control: ManagedSessionControl,
) -> Result<ManagedSessionControlRegistry> {
    let mut registry = load_managed_session_controls(paths).await?;
    control.updated_at = OffsetDateTime::now_utc();
    registry.insert(control);
    store_managed_session_controls(paths, &registry).await?;
    Ok(registry)
}

pub async fn remove_managed_session_control(
    paths: &AgentPaths,
    session_id: &str,
) -> Result<ManagedSessionControlRegistry> {
    let mut registry = load_managed_session_controls(paths).await?;
    registry.remove(session_id);
    store_managed_session_controls(paths, &registry).await?;
    Ok(registry)
}

pub async fn load_remote_desktop_request_registry(
    paths: &AgentPaths,
) -> Result<RemoteDesktopControlRequestRegistry> {
    ensure_identity_layout(paths).await?;
    let registry_path = remote_desktop_request_registry_file(paths);
    let lock_path = remote_desktop_request_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, false)?;
        load_remote_desktop_request_registry_unlocked(&registry_path)
    })
    .await
    .context("remote desktop request registry read task panicked")?
}

pub async fn load_file_transfer_request_registry(
    paths: &AgentPaths,
) -> Result<FileTransferControlRequestRegistry> {
    ensure_identity_layout(paths).await?;
    let registry_path = file_transfer_request_registry_file(paths);
    let lock_path = file_transfer_request_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, false)?;
        load_file_transfer_request_registry_unlocked(&registry_path)
    })
    .await
    .context("file transfer request registry read task panicked")?
}

pub async fn load_nearby_discovery_snapshot_registry(
    paths: &AgentPaths,
) -> Result<NearbyDiscoverySnapshotRegistry> {
    ensure_identity_layout(paths).await?;
    let registry_path = nearby_discovery_snapshot_registry_file(paths);
    let lock_path = nearby_discovery_snapshot_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, false)?;
        load_nearby_discovery_snapshot_registry_unlocked(&registry_path)
    })
    .await
    .context("nearby discovery snapshot registry read task panicked")?
}

pub async fn upsert_nearby_discovery_snapshot(
    paths: &AgentPaths,
    snapshot: NearbyDiscoverySnapshot,
) -> Result<NearbyDiscoverySnapshotRegistry> {
    ensure_identity_layout(paths).await?;
    let registry_path = nearby_discovery_snapshot_registry_file(paths);
    let lock_path = nearby_discovery_snapshot_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        validate_nearby_discovery_snapshot(&snapshot)?;
        let _process_guard = lock_session_registry_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, true)?;
        let mut registry = load_nearby_discovery_snapshot_registry_unlocked(&registry_path)?;
        if registry.snapshots.len() >= NearbyDiscoverySnapshotRegistry::MAX_SNAPSHOTS
            && !registry.snapshots.contains_key(&snapshot.scan_id)
        {
            bail!(
                "nearby discovery snapshot registry is full at {} entries",
                NearbyDiscoverySnapshotRegistry::MAX_SNAPSHOTS
            );
        }
        registry.insert(snapshot);
        store_nearby_discovery_snapshot_registry_unlocked(&registry_path, &registry)?;
        Ok(registry)
    })
    .await
    .context("nearby discovery snapshot registry mutation task panicked")?
}

pub async fn load_remote_desktop_capability_snapshot_registry(
    paths: &AgentPaths,
) -> Result<RemoteDesktopCapabilitySnapshotRegistry> {
    ensure_identity_layout(paths).await?;
    let registry_path = remote_desktop_capability_snapshot_registry_file(paths);
    let lock_path = remote_desktop_capability_snapshot_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, false)?;
        load_remote_desktop_capability_snapshot_registry_unlocked(&registry_path)
    })
    .await
    .context("remote desktop capability snapshot registry read task panicked")?
}

pub async fn upsert_remote_desktop_capability_snapshot(
    paths: &AgentPaths,
    snapshot: RemoteDesktopCapabilitySnapshot,
) -> Result<RemoteDesktopCapabilitySnapshotRegistry> {
    ensure_identity_layout(paths).await?;
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let capability_registry_path = remote_desktop_capability_snapshot_registry_file(paths);
    let capability_registry_lock_path =
        remote_desktop_capability_snapshot_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        validate_remote_desktop_capability_snapshot(&snapshot)?;
        let _process_guard = lock_session_registry_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, false)?;
        let session_registry = load_session_registry_unlocked(&session_registry_path)?;
        let session = session_registry
            .get(&snapshot.session_id)
            .ok_or_else(|| anyhow!("session `{}` not found", snapshot.session_id))?;
        if !session.is_active() {
            bail!(
                "session `{}` is not active for remote desktop capability snapshot: {:?}",
                snapshot.session_id,
                session.state
            );
        }
        if session.effective_established_readiness().is_none() {
            bail!(
                "session `{}` has no established transport or handshake evidence for remote desktop capability snapshot",
                snapshot.session_id
            );
        }
        if snapshot.target_runtime_id != session.runtime_id {
            bail!(
                "remote desktop capability snapshot runtime `{}` does not match active session runtime `{}` for session `{}`",
                snapshot.target_runtime_id,
                session.runtime_id,
                snapshot.session_id
            );
        }

        let _capability_file_lock =
            lock_session_registry_file(&capability_registry_lock_path, true)?;
        let mut registry =
            load_remote_desktop_capability_snapshot_registry_unlocked(&capability_registry_path)?;
        if registry.snapshots.len() >= RemoteDesktopCapabilitySnapshotRegistry::MAX_SNAPSHOTS
            && !registry.snapshots.contains_key(&snapshot.session_id)
        {
            bail!(
                "remote desktop capability snapshot registry is full at {} entries",
                RemoteDesktopCapabilitySnapshotRegistry::MAX_SNAPSHOTS
            );
        }
        registry.insert(snapshot);
        store_remote_desktop_capability_snapshot_registry_unlocked(
            &capability_registry_path,
            &registry,
        )?;
        Ok(registry)
    })
    .await
    .context("remote desktop capability snapshot registry mutation task panicked")?
}

pub async fn enqueue_remote_desktop_request_for_established_session(
    paths: &AgentPaths,
    session_id: &str,
    action: RemoteDesktopControlAction,
    payload: RemoteDesktopControlRequestPayload,
) -> Result<RemoteDesktopControlRequest> {
    ensure_identity_layout(paths).await?;
    let session_id = session_id.to_owned();
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let request_registry_path = remote_desktop_request_registry_file(paths);
    let request_registry_lock_path = remote_desktop_request_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        validate_remote_desktop_request_payload(action, &payload)?;
        let _process_guard = lock_session_registry_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, false)?;
        let session_registry = load_session_registry_unlocked(&session_registry_path)?;
        let session = session_registry
            .get(&session_id)
            .ok_or_else(|| anyhow!("session `{session_id}` not found"))?;
        if !session.is_active() {
            bail!(
                "session `{session_id}` is not active for remote desktop control: {:?}",
                session.state
            );
        }
        if session.effective_established_readiness().is_none() {
            bail!(
                "session `{session_id}` has no established transport or handshake evidence for remote desktop control"
            );
        }
        let bound_session_id = session.session_id.clone();
        let target_runtime_id = session.runtime_id.clone();

        let _request_file_lock = lock_session_registry_file(&request_registry_lock_path, true)?;
        let mut request_registry =
            load_remote_desktop_request_registry_unlocked(&request_registry_path)?;
        if let Some(existing) = request_registry.pending_for_session(&session_id).first() {
            bail!(
                "session `{session_id}` already has pending remote desktop request `{}` awaiting agent observation",
                existing.request_id
            );
        }
        if request_registry.requests.len() >= RemoteDesktopControlRequestRegistry::MAX_REQUESTS {
            bail!(
                "remote desktop request registry is full at {} entries; wait for agent observation before adding more requests",
                RemoteDesktopControlRequestRegistry::MAX_REQUESTS
            );
        }

        let request = RemoteDesktopControlRequest::pending(
            uuid::Uuid::now_v7().to_string(),
            bound_session_id,
            target_runtime_id,
            action,
            payload,
        );
        request_registry.insert(request.clone());
        store_remote_desktop_request_registry_unlocked(
            &request_registry_path,
            &request_registry,
        )?;
        Ok(request)
    })
    .await
    .context("remote desktop request registry mutation task panicked")?
}

pub async fn observe_remote_desktop_requests_for_established_session(
    paths: &AgentPaths,
    session_id: &str,
) -> Result<Vec<RemoteDesktopControlRequest>> {
    ensure_identity_layout(paths).await?;
    let session_id = session_id.to_owned();
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let request_registry_path = remote_desktop_request_registry_file(paths);
    let request_registry_lock_path = remote_desktop_request_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, false)?;
        let session_registry = load_session_registry_unlocked(&session_registry_path)?;
        let session = session_registry
            .get(&session_id)
            .ok_or_else(|| anyhow!("session `{session_id}` not found"))?;
        if !session.is_active() {
            bail!(
                "session `{session_id}` is not active for remote desktop request observation: {:?}",
                session.state
            );
        }
        let target_runtime_id = session.runtime_id.clone();

        let _request_file_lock = lock_session_registry_file(&request_registry_lock_path, true)?;
        let mut request_registry =
            load_remote_desktop_request_registry_unlocked(&request_registry_path)?;
        if request_registry.pending_for_session(&session_id).is_empty() {
            return Ok(Vec::new());
        }
        if session.effective_established_readiness().is_none() {
            bail!(
                "session `{session_id}` has no established transport or handshake evidence for remote desktop request observation"
            );
        }
        let stale_pending = request_registry
            .pending_for_session(&session_id)
            .into_iter()
            .find(|request| request.target_runtime_id != target_runtime_id);
        if let Some(request) = stale_pending {
            bail!(
                "remote desktop request `{}` targets stale runtime for session `{session_id}`",
                request.request_id
            );
        }

        let pending_ids =
            request_registry.pending_ids_for_session_runtime(&session_id, &target_runtime_id);
        if pending_ids.is_empty() {
            return Ok(Vec::new());
        }
        let now = OffsetDateTime::now_utc();
        let mut observed = Vec::with_capacity(pending_ids.len());
        for request_id in pending_ids {
            let request = request_registry
                .requests
                .get_mut(&request_id)
                .ok_or_else(|| anyhow!("remote desktop pending request `{request_id}` disappeared"))?;
            if !request.is_pending_agent_observation() {
                bail!(
                    "remote desktop request `{}` is not pending agent observation",
                    request.request_id
                );
            }
            request.mark_agent_observed(now);
            observed.push(request.clone());
        }
        store_remote_desktop_request_registry_unlocked(
            &request_registry_path,
            &request_registry,
        )?;
        Ok(observed)
    })
    .await
    .context("remote desktop request observation task panicked")?
}

pub async fn observe_file_transfer_requests_for_established_session(
    paths: &AgentPaths,
    session_id: &str,
) -> Result<Vec<FileTransferControlRequest>> {
    ensure_identity_layout(paths).await?;
    let session_id = session_id.to_owned();
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let request_registry_path = file_transfer_request_registry_file(paths);
    let request_registry_lock_path = file_transfer_request_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, false)?;
        let session_registry = load_session_registry_unlocked(&session_registry_path)?;
        let session = session_registry
            .get(&session_id)
            .ok_or_else(|| anyhow!("session `{session_id}` not found"))?;
        if !session.is_active() {
            bail!(
                "session `{session_id}` is not active for file transfer request observation: {:?}",
                session.state
            );
        }
        let target_runtime_id = session.runtime_id.clone();

        let _request_file_lock = lock_session_registry_file(&request_registry_lock_path, true)?;
        let mut request_registry =
            load_file_transfer_request_registry_unlocked(&request_registry_path)?;
        if request_registry.pending_for_session(&session_id).is_empty() {
            return Ok(Vec::new());
        }
        if !matches!(
            &session.readiness,
            SessionReadiness::HandshakeComplete {
                session_id: current,
                ..
            } if current == &session_id
        ) {
            bail!(
                "session `{session_id}` has no current handshake-complete evidence for file transfer request observation"
            );
        }
        let stale_pending = request_registry
            .pending_for_session(&session_id)
            .into_iter()
            .find(|request| request.target_runtime_id != target_runtime_id);
        if let Some(request) = stale_pending {
            bail!(
                "file transfer request `{}` targets stale runtime for session `{session_id}`",
                request.request_id
            );
        }

        let pending_ids =
            request_registry.pending_ids_for_session_runtime(&session_id, &target_runtime_id);
        if pending_ids.is_empty() {
            return Ok(Vec::new());
        }
        let now = OffsetDateTime::now_utc();
        let mut observed = Vec::with_capacity(pending_ids.len());
        for request_id in pending_ids {
            let request = request_registry
                .requests
                .get_mut(&request_id)
                .ok_or_else(|| anyhow!("file transfer pending request `{request_id}` disappeared"))?;
            if !request.is_pending_agent_observation() {
                bail!(
                    "file transfer request `{}` is not pending agent observation",
                    request.request_id
                );
            }
            request.mark_agent_observed(now);
            observed.push(request.clone());
        }
        store_file_transfer_request_registry_unlocked(
            &request_registry_path,
            &request_registry,
        )?;
        Ok(observed)
    })
    .await
    .context("file transfer request observation task panicked")?
}

/// Apply an in-place mutation to a single file transfer request (status /
/// evidence transitions) under the registry lock, then persist. Fails closed if
/// the request no longer exists.
pub async fn update_file_transfer_request<F>(
    paths: &AgentPaths,
    request_id: &str,
    mutate: F,
) -> Result<FileTransferControlRequest>
where
    F: FnOnce(&mut FileTransferControlRequest) + Send + 'static,
{
    ensure_identity_layout(paths).await?;
    let request_id = request_id.to_owned();
    let request_registry_path = file_transfer_request_registry_file(paths);
    let request_registry_lock_path = file_transfer_request_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _request_file_lock = lock_session_registry_file(&request_registry_lock_path, true)?;
        let mut request_registry =
            load_file_transfer_request_registry_unlocked(&request_registry_path)?;
        let request = request_registry
            .requests
            .get_mut(&request_id)
            .ok_or_else(|| anyhow!("file transfer request `{request_id}` not found"))?;
        mutate(request);
        let updated = request.clone();
        store_file_transfer_request_registry_unlocked(&request_registry_path, &request_registry)?;
        Ok(updated)
    })
    .await
    .context("file transfer request update task panicked")?
}

pub async fn enqueue_file_transfer_send_request_for_established_session(
    paths: &AgentPaths,
    session_id: &str,
    requested_peer_ref: &str,
    source_path: &Path,
) -> Result<FileTransferControlRequest> {
    ensure_identity_layout(paths).await?;
    let session_id = session_id.to_owned();
    let requested_peer_ref = requested_peer_ref.trim().to_owned();
    let source_path = source_path.to_path_buf();
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let request_registry_path = file_transfer_request_registry_file(paths);
    let request_registry_lock_path = file_transfer_request_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        if requested_peer_ref.is_empty() {
            bail!("file transfer destination peer reference is required");
        }
        validate_file_transfer_session_target(
            &session_registry_path,
            &session_registry_lock_path,
            &session_id,
            &requested_peer_ref,
        )?;
        {
            let _process_guard = lock_session_registry_process()?;
            let _request_file_lock =
                lock_session_registry_file(&request_registry_lock_path, true)?;
            let request_registry =
                load_file_transfer_request_registry_unlocked(&request_registry_path)?;
            if let Some(existing) = request_registry.pending_for_session(&session_id).first() {
                bail!(
                    "session `{session_id}` already has pending file transfer request `{}` awaiting agent observation",
                    existing.request_id
                );
            }
            if request_registry.requests.len() >= FileTransferControlRequestRegistry::MAX_REQUESTS {
                bail!(
                    "file transfer request registry is full at {} entries; wait for agent observation before adding more requests",
                    FileTransferControlRequestRegistry::MAX_REQUESTS
                );
            }
        }

        let source = file_transfer_source_snapshot(&source_path)?;

        let _process_guard = lock_session_registry_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, false)?;
        let session_registry = load_session_registry_unlocked(&session_registry_path)?;
        let session_binding =
            bind_file_transfer_session_target(&session_registry, &session_id, &requested_peer_ref)?;
        let _request_file_lock = lock_session_registry_file(&request_registry_lock_path, true)?;
        let mut request_registry =
            load_file_transfer_request_registry_unlocked(&request_registry_path)?;
        if let Some(existing) = request_registry.pending_for_session(&session_id).first() {
            bail!(
                "session `{session_id}` already has pending file transfer request `{}` awaiting agent observation",
                existing.request_id
            );
        }
        if request_registry.requests.len() >= FileTransferControlRequestRegistry::MAX_REQUESTS {
            bail!(
                "file transfer request registry is full at {} entries; wait for agent observation before adding more requests",
                FileTransferControlRequestRegistry::MAX_REQUESTS
            );
        }

        let request = FileTransferControlRequest::pending_send(
            uuid::Uuid::now_v7().to_string(),
            session_binding.session_id,
            session_binding.runtime_id,
            source,
            FileTransferDestinationBinding {
                requested_peer_ref,
                remote_device_id: session_binding.remote_device_id,
                remote_protocol_public_key_fingerprint:
                    session_binding.remote_protocol_public_key_fingerprint,
            },
        );
        request_registry.insert(request.clone());
        store_file_transfer_request_registry_unlocked(
            &request_registry_path,
            &request_registry,
        )?;
        Ok(request)
    })
    .await
    .context("file transfer request registry mutation task panicked")?
}

struct FileTransferSessionBinding {
    session_id: String,
    runtime_id: String,
    remote_device_id: String,
    remote_protocol_public_key_fingerprint: String,
}

fn validate_file_transfer_session_target(
    session_registry_path: &Path,
    session_registry_lock_path: &Path,
    session_id: &str,
    requested_peer_ref: &str,
) -> Result<FileTransferSessionBinding> {
    let _process_guard = lock_session_registry_process()?;
    let _session_file_lock = lock_session_registry_file(session_registry_lock_path, false)?;
    let session_registry = load_session_registry_unlocked(session_registry_path)?;
    bind_file_transfer_session_target(&session_registry, session_id, requested_peer_ref)
}

fn bind_file_transfer_session_target(
    session_registry: &SessionRegistry,
    session_id: &str,
    requested_peer_ref: &str,
) -> Result<FileTransferSessionBinding> {
    let session = session_registry
        .get(session_id)
        .ok_or_else(|| anyhow!("session `{session_id}` not found"))?;
    if !session.is_active() {
        bail!(
            "session `{session_id}` is not active for file transfer request: {:?}",
            session.state
        );
    }
    if !matches!(
        &session.readiness,
        SessionReadiness::HandshakeComplete {
            session_id: current,
            ..
        } if current == session_id
    ) {
        bail!(
            "session `{session_id}` has no current handshake-complete evidence for file transfer request"
        );
    }
    let remote_device_id = session
        .remote_device_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("file transfer request requires bound remote device identity"))?;
    let remote_protocol_public_key_fingerprint = session
        .remote_protocol_public_key_fingerprint
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("file transfer request requires bound remote protocol identity"))?;
    if requested_peer_ref != remote_device_id {
        bail!("file transfer destination does not match the established session peer");
    }
    Ok(FileTransferSessionBinding {
        session_id: session.session_id.clone(),
        runtime_id: session.runtime_id.clone(),
        remote_device_id: remote_device_id.to_owned(),
        remote_protocol_public_key_fingerprint: remote_protocol_public_key_fingerprint.to_owned(),
    })
}

pub async fn upsert_session_runtime(
    paths: &AgentPaths,
    record: RuntimeSessionRecord,
) -> Result<SessionRegistry> {
    mutate_session_registry(paths, move |registry| {
        registry.insert(record);
        registry.clone()
    })
    .await
}

pub async fn remove_session_runtime(
    paths: &AgentPaths,
    session_id: &str,
    reason: Option<String>,
) -> Result<SessionRegistry> {
    let session_id = session_id.to_owned();
    mutate_session_registry(paths, move |registry| {
        registry.mark_disconnected(&session_id, reason);
        registry.clone()
    })
    .await
}

pub(crate) async fn disconnect_session_if_active(
    paths: &AgentPaths,
    session_id: &str,
    reason: Option<String>,
) -> Result<bool> {
    let session_id = session_id.to_owned();
    mutate_session_registry(paths, move |registry| {
        let Some(record) = registry.get(&session_id) else {
            return false;
        };
        if matches!(
            record.state,
            RuntimeSessionState::Disconnected | RuntimeSessionState::Failed
        ) {
            return false;
        }
        registry.mark_disconnected(&session_id, reason)
    })
    .await
}

pub async fn apply_transport_event(
    paths: &AgentPaths,
    session_id: &str,
    event: RuntimeSessionTransportEvent,
) -> Result<SessionRegistry> {
    let session_id = session_id.to_owned();
    mutate_session_registry(paths, move |registry| {
        registry.apply_transport_event(&session_id, event);
        registry.clone()
    })
    .await
}

pub(crate) async fn apply_signaling_event(
    paths: &AgentPaths,
    session_id: &str,
    event: SignalingLifecycleEvent,
) -> Result<SessionRegistry> {
    let session_id = session_id.to_owned();
    mutate_session_registry(paths, move |registry| {
        registry.apply_signaling_event(&session_id, &event);
        registry.clone()
    })
    .await
}

pub async fn update_session_remote_peer(
    paths: &AgentPaths,
    session_id: &str,
    remote_device_id: impl Into<String>,
    remote_device_name: Option<String>,
    remote_protocol_public_key_fingerprint: Option<String>,
) -> Result<SessionRegistry> {
    let session_id = session_id.to_owned();
    let remote_device_id = remote_device_id.into();
    mutate_session_registry(paths, move |registry| {
        registry.update_remote_peer(
            &session_id,
            remote_device_id,
            remote_device_name,
            remote_protocol_public_key_fingerprint,
        );
        registry.clone()
    })
    .await
}

async fn load_signing_key(paths: &AgentPaths) -> Result<Option<StoredSigningKey>> {
    load_json::<StoredSigningKey>(&signing_key_file(paths)).await
}

async fn store_signing_key(
    paths: &AgentPaths,
    signing_key: &ProtocolSigningKeyMaterial,
) -> Result<()> {
    let stored = match signing_key {
        ProtocolSigningKeyMaterial::Ed25519(signing_key) => StoredSigningKey {
            schema_version: StoredSigningKey::SCHEMA_VERSION,
            algorithm: ProtocolSigningAlgorithm::Ed25519,
            public_key_base64: None,
            secret_key_base64: STANDARD.encode(signing_key.to_bytes()),
        },
        ProtocolSigningKeyMaterial::MlDsa65 {
            public_key,
            secret_key,
        } => StoredSigningKey {
            schema_version: StoredSigningKey::SCHEMA_VERSION,
            algorithm: ProtocolSigningAlgorithm::MlDsa65,
            public_key_base64: Some(STANDARD.encode(public_key)),
            secret_key_base64: STANDARD.encode(secret_key),
        },
    };
    write_json(&signing_key_file(paths), &stored).await
}

fn decode_signing_key(stored_key: &StoredSigningKey) -> Result<ProtocolSigningKeyMaterial> {
    let secret_bytes = STANDARD.decode(stored_key.secret_key_base64.as_bytes())?;
    match stored_key.algorithm {
        ProtocolSigningAlgorithm::Ed25519 => {
            let secret: [u8; 32] = secret_bytes
                .try_into()
                .map_err(|_| anyhow!("invalid ed25519 secret key length"))?;
            Ok(ProtocolSigningKeyMaterial::Ed25519(SigningKey::from_bytes(
                &secret,
            )))
        }
        ProtocolSigningAlgorithm::MlDsa65 => {
            let public_key = stored_key
                .public_key_base64
                .as_deref()
                .ok_or_else(|| anyhow!("missing ML-DSA-65 public key in stored signing key"))?;
            Ok(ProtocolSigningKeyMaterial::MlDsa65 {
                public_key: STANDARD.decode(public_key.as_bytes())?,
                secret_key: secret_bytes,
            })
        }
    }
}

fn sync_identity_binding(
    mut identity: LocalIdentityState,
    signing_key: &ProtocolSigningKeyMaterial,
) -> LocalIdentityState {
    let algorithm = signing_key.algorithm();
    let public_key_bytes = signing_key.public_key_bytes();
    let fingerprint = ProtocolIdentityBinding::compute_fingerprint(algorithm, &public_key_bytes);
    identity.device.protocol_signing_algorithm = algorithm;
    identity.device.protocol_public_key_bytes = Some(public_key_bytes);
    identity.device.public_key_fingerprint = Some(fingerprint);
    identity.device.updated_at = OffsetDateTime::now_utc();
    identity
}

fn requested_protocol_signing_algorithm() -> Option<ProtocolSigningAlgorithm> {
    std::env::var("SKYBRIDGE_PROTOCOL_SIGNING_ALGORITHM")
        .ok()
        .and_then(|value| value.parse().ok())
}

fn generate_signing_key(algorithm: ProtocolSigningAlgorithm) -> Result<ProtocolSigningKeyMaterial> {
    match algorithm {
        ProtocolSigningAlgorithm::Ed25519 => Ok(ProtocolSigningKeyMaterial::Ed25519(
            SigningKey::generate(&mut OsRng),
        )),
        ProtocolSigningAlgorithm::MlDsa65 => {
            let (public_key, secret_key) = mldsa65_generate_keypair();
            Ok(ProtocolSigningKeyMaterial::MlDsa65 {
                public_key,
                secret_key,
            })
        }
    }
}

async fn ensure_mldsa65_signing_key(paths: &AgentPaths) -> Result<ProtocolSigningKeyMaterial> {
    let stored_key = load_signing_key(paths).await?;
    match stored_key {
        Some(stored_key) if stored_key.algorithm == ProtocolSigningAlgorithm::MlDsa65 => {
            decode_signing_key(&stored_key)
        }
        _ => {
            let signing_key = generate_signing_key(ProtocolSigningAlgorithm::MlDsa65)?;
            store_signing_key(paths, &signing_key).await?;
            Ok(signing_key)
        }
    }
}

async fn ensure_kem_identity_key(
    paths: &AgentPaths,
    suite_wire_id: u16,
) -> Result<(Vec<u8>, Vec<u8>)> {
    let path = kem_identity_key_file(paths, suite_wire_id);
    if let Some(stored) = load_json::<StoredKemIdentityKey>(&path).await? {
        let public_key = STANDARD.decode(stored.public_key_base64.as_bytes())?;
        let secret_key = STANDARD.decode(stored.secret_key_base64.as_bytes())?;
        return Ok((public_key, secret_key));
    }

    let (public_key, secret_key) = match suite_wire_id {
        0x0101 => skybridge_core::mlkem768_generate_keypair(),
        0x0001 => xwing_generate_keypair(),
        #[cfg(feature = "q-periapt")]
        0x0011 => skybridge_core::qperiapt_contextbound_generate_keypair(),
        _ => bail!("unsupported KEM identity suite {suite_wire_id:#06x}"),
    };
    let stored = StoredKemIdentityKey {
        schema_version: StoredKemIdentityKey::SCHEMA_VERSION,
        suite_wire_id,
        public_key_base64: STANDARD.encode(&public_key),
        secret_key_base64: STANDARD.encode(&secret_key),
    };
    write_json(&path, &stored).await?;
    Ok((public_key, secret_key))
}

async fn persist_identity(paths: &AgentPaths, identity: &LocalIdentityState) -> Result<()> {
    write_json(&paths.identity_file, identity).await
}

async fn ensure_identity_layout(paths: &AgentPaths) -> Result<()> {
    for directory in [
        &paths.root,
        &paths.identity_dir,
        &paths.runtime_dir,
        &paths.logs_dir,
    ] {
        tokio::fs::create_dir_all(directory)
            .await
            .with_context(|| format!("failed to create directory {}", directory.display()))?;
        restrict_dir_permissions(directory).await?;
    }
    Ok(())
}

fn lock_session_registry_process() -> Result<std::sync::MutexGuard<'static, ()>> {
    SESSION_REGISTRY_PROCESS_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| anyhow!("session registry process lock poisoned"))
}

fn lock_session_registry_file(path: &Path, exclusive: bool) -> Result<std::fs::File> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .with_context(|| format!("failed to open session registry lock {}", path.display()))?;
    restrict_file_permissions_blocking(path)?;
    if exclusive {
        file.lock()
            .with_context(|| format!("failed to exclusively lock {}", path.display()))?;
    } else {
        file.lock_shared()
            .with_context(|| format!("failed to shared-lock {}", path.display()))?;
    }
    Ok(file)
}

fn load_session_registry_unlocked(path: &Path) -> Result<SessionRegistry> {
    let mut registry = match std::fs::read_to_string(path) {
        Ok(body) => serde_json::from_str(&body)
            .with_context(|| format!("failed to decode {}", path.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => SessionRegistry::default(),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    registry.schema_version = SessionRegistry::SCHEMA_VERSION;
    Ok(registry)
}

fn store_session_registry_unlocked(path: &Path, registry: &SessionRegistry) -> Result<()> {
    let body = serde_json::to_vec_pretty(registry).context("failed to encode json")?;
    let file_name = path
        .file_name()
        .ok_or_else(|| anyhow!("session registry path missing filename"))?
        .to_string_lossy();
    let temp_path = path.with_file_name(format!(".{file_name}.tmp-{}", uuid::Uuid::now_v7()));
    std::fs::write(&temp_path, body)
        .with_context(|| format!("failed to write {}", temp_path.display()))?;
    restrict_file_permissions_blocking(&temp_path)?;
    #[cfg(windows)]
    if path.exists() {
        std::fs::remove_file(path)
            .with_context(|| format!("failed to replace {}", path.display()))?;
    }
    std::fs::rename(&temp_path, path)
        .with_context(|| format!("failed to persist {}", path.display()))?;
    restrict_file_permissions_blocking(path)
}

fn load_remote_desktop_request_registry_unlocked(
    path: &Path,
) -> Result<RemoteDesktopControlRequestRegistry> {
    let registry = match std::fs::read_to_string(path) {
        Ok(body) => serde_json::from_str::<RemoteDesktopControlRequestRegistry>(&body)
            .with_context(|| format!("failed to decode {}", path.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            RemoteDesktopControlRequestRegistry::default()
        }
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    validate_remote_desktop_request_registry(path, &registry)?;
    Ok(registry)
}

fn load_file_transfer_request_registry_unlocked(
    path: &Path,
) -> Result<FileTransferControlRequestRegistry> {
    let registry = match std::fs::read_to_string(path) {
        Ok(body) => serde_json::from_str::<FileTransferControlRequestRegistry>(&body)
            .with_context(|| format!("failed to decode {}", path.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            FileTransferControlRequestRegistry::default()
        }
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    validate_file_transfer_request_registry(path, &registry)?;
    Ok(registry)
}

fn load_nearby_discovery_snapshot_registry_unlocked(
    path: &Path,
) -> Result<NearbyDiscoverySnapshotRegistry> {
    let registry = match std::fs::read_to_string(path) {
        Ok(body) => serde_json::from_str::<NearbyDiscoverySnapshotRegistry>(&body)
            .with_context(|| format!("failed to decode {}", path.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            NearbyDiscoverySnapshotRegistry::default()
        }
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    validate_nearby_discovery_snapshot_registry(path, &registry)?;
    Ok(registry)
}

fn load_remote_desktop_capability_snapshot_registry_unlocked(
    path: &Path,
) -> Result<RemoteDesktopCapabilitySnapshotRegistry> {
    let registry = match std::fs::read_to_string(path) {
        Ok(body) => serde_json::from_str::<RemoteDesktopCapabilitySnapshotRegistry>(&body)
            .with_context(|| format!("failed to decode {}", path.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            RemoteDesktopCapabilitySnapshotRegistry::default()
        }
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    validate_remote_desktop_capability_snapshot_registry(path, &registry)?;
    Ok(registry)
}

fn store_remote_desktop_request_registry_unlocked(
    path: &Path,
    registry: &RemoteDesktopControlRequestRegistry,
) -> Result<()> {
    validate_remote_desktop_request_registry(path, registry)?;
    let mut registry = registry.clone();
    registry.schema_version = RemoteDesktopControlRequestRegistry::SCHEMA_VERSION;
    let body = serde_json::to_vec_pretty(&registry).context("failed to encode json")?;
    let file_name = path
        .file_name()
        .ok_or_else(|| anyhow!("remote desktop request registry path missing filename"))?
        .to_string_lossy();
    let temp_path = path.with_file_name(format!(".{file_name}.tmp-{}", uuid::Uuid::now_v7()));
    std::fs::write(&temp_path, body)
        .with_context(|| format!("failed to write {}", temp_path.display()))?;
    restrict_file_permissions_blocking(&temp_path)?;
    #[cfg(windows)]
    if path.exists() {
        std::fs::remove_file(path)
            .with_context(|| format!("failed to replace {}", path.display()))?;
    }
    std::fs::rename(&temp_path, path)
        .with_context(|| format!("failed to persist {}", path.display()))?;
    restrict_file_permissions_blocking(path)
}

fn store_file_transfer_request_registry_unlocked(
    path: &Path,
    registry: &FileTransferControlRequestRegistry,
) -> Result<()> {
    validate_file_transfer_request_registry(path, registry)?;
    let mut registry = registry.clone();
    registry.schema_version = FileTransferControlRequestRegistry::SCHEMA_VERSION;
    let body = serde_json::to_vec_pretty(&registry).context("failed to encode json")?;
    let file_name = path
        .file_name()
        .ok_or_else(|| anyhow!("file transfer request registry path missing filename"))?
        .to_string_lossy();
    let temp_path = path.with_file_name(format!(".{file_name}.tmp-{}", uuid::Uuid::now_v7()));
    std::fs::write(&temp_path, body)
        .with_context(|| format!("failed to write {}", temp_path.display()))?;
    restrict_file_permissions_blocking(&temp_path)?;
    #[cfg(windows)]
    if path.exists() {
        std::fs::remove_file(path)
            .with_context(|| format!("failed to replace {}", path.display()))?;
    }
    std::fs::rename(&temp_path, path)
        .with_context(|| format!("failed to persist {}", path.display()))?;
    restrict_file_permissions_blocking(path)
}

fn store_nearby_discovery_snapshot_registry_unlocked(
    path: &Path,
    registry: &NearbyDiscoverySnapshotRegistry,
) -> Result<()> {
    validate_nearby_discovery_snapshot_registry(path, registry)?;
    let mut registry = registry.clone();
    registry.schema_version = NearbyDiscoverySnapshotRegistry::SCHEMA_VERSION;
    let body = serde_json::to_vec_pretty(&registry).context("failed to encode json")?;
    let file_name = path
        .file_name()
        .ok_or_else(|| anyhow!("nearby discovery snapshot registry path missing filename"))?
        .to_string_lossy();
    let temp_path = path.with_file_name(format!(".{file_name}.tmp-{}", uuid::Uuid::now_v7()));
    std::fs::write(&temp_path, body)
        .with_context(|| format!("failed to write {}", temp_path.display()))?;
    restrict_file_permissions_blocking(&temp_path)?;
    #[cfg(windows)]
    if path.exists() {
        std::fs::remove_file(path)
            .with_context(|| format!("failed to replace {}", path.display()))?;
    }
    std::fs::rename(&temp_path, path)
        .with_context(|| format!("failed to persist {}", path.display()))?;
    restrict_file_permissions_blocking(path)
}

fn store_remote_desktop_capability_snapshot_registry_unlocked(
    path: &Path,
    registry: &RemoteDesktopCapabilitySnapshotRegistry,
) -> Result<()> {
    validate_remote_desktop_capability_snapshot_registry(path, registry)?;
    let mut registry = registry.clone();
    registry.schema_version = RemoteDesktopCapabilitySnapshotRegistry::SCHEMA_VERSION;
    let body = serde_json::to_vec_pretty(&registry).context("failed to encode json")?;
    let file_name = path
        .file_name()
        .ok_or_else(|| {
            anyhow!("remote desktop capability snapshot registry path missing filename")
        })?
        .to_string_lossy();
    let temp_path = path.with_file_name(format!(".{file_name}.tmp-{}", uuid::Uuid::now_v7()));
    std::fs::write(&temp_path, body)
        .with_context(|| format!("failed to write {}", temp_path.display()))?;
    restrict_file_permissions_blocking(&temp_path)?;
    #[cfg(windows)]
    if path.exists() {
        std::fs::remove_file(path)
            .with_context(|| format!("failed to replace {}", path.display()))?;
    }
    std::fs::rename(&temp_path, path)
        .with_context(|| format!("failed to persist {}", path.display()))?;
    restrict_file_permissions_blocking(path)
}

fn validate_nearby_discovery_snapshot_registry(
    path: &Path,
    registry: &NearbyDiscoverySnapshotRegistry,
) -> Result<()> {
    if registry.schema_version != NearbyDiscoverySnapshotRegistry::SCHEMA_VERSION {
        bail!(
            "unsupported nearby discovery snapshot registry schema version {} in {}; expected {}",
            registry.schema_version,
            path.display(),
            NearbyDiscoverySnapshotRegistry::SCHEMA_VERSION
        );
    }
    if registry.snapshots.len() > NearbyDiscoverySnapshotRegistry::MAX_SNAPSHOTS {
        bail!(
            "nearby discovery snapshot registry has {} entries in {}; max {}",
            registry.snapshots.len(),
            path.display(),
            NearbyDiscoverySnapshotRegistry::MAX_SNAPSHOTS
        );
    }
    for (scan_id, snapshot) in &registry.snapshots {
        if scan_id != &snapshot.scan_id {
            bail!(
                "nearby discovery snapshot key `{}` does not match scan_id `{}` in {}",
                scan_id,
                snapshot.scan_id,
                path.display()
            );
        }
        validate_nearby_discovery_snapshot(snapshot)?;
    }
    Ok(())
}

fn validate_remote_desktop_request_registry(
    path: &Path,
    registry: &RemoteDesktopControlRequestRegistry,
) -> Result<()> {
    if registry.schema_version != RemoteDesktopControlRequestRegistry::SCHEMA_VERSION {
        bail!(
            "unsupported remote desktop request registry schema version {} in {}; expected {}",
            registry.schema_version,
            path.display(),
            RemoteDesktopControlRequestRegistry::SCHEMA_VERSION
        );
    }
    if registry.requests.len() > RemoteDesktopControlRequestRegistry::MAX_REQUESTS {
        bail!(
            "remote desktop request registry has {} entries in {}; max {}",
            registry.requests.len(),
            path.display(),
            RemoteDesktopControlRequestRegistry::MAX_REQUESTS
        );
    }
    for (request_id, request) in &registry.requests {
        if request_id != &request.request_id {
            bail!(
                "remote desktop request key `{}` does not match request_id `{}` in {}",
                request_id,
                request.request_id,
                path.display()
            );
        }
        validate_remote_desktop_request(request)?;
    }
    Ok(())
}

fn validate_remote_desktop_request(request: &RemoteDesktopControlRequest) -> Result<()> {
    if request.schema_version != RemoteDesktopControlRequest::SCHEMA_VERSION {
        bail!(
            "unsupported remote desktop request schema version {} for request `{}`; expected {}",
            request.schema_version,
            request.request_id,
            RemoteDesktopControlRequest::SCHEMA_VERSION
        );
    }
    if request.request_id.trim().is_empty() {
        bail!("remote desktop request_id must not be empty");
    }
    if request.session_id.trim().is_empty() {
        bail!(
            "remote desktop request `{}` session_id must not be empty",
            request.request_id
        );
    }
    if request.target_runtime_id.trim().is_empty() {
        bail!(
            "remote desktop request `{}` target_runtime_id must not be empty",
            request.request_id
        );
    }
    validate_remote_desktop_request_payload(request.action, &request.payload)
}

fn validate_remote_desktop_request_payload(
    action: RemoteDesktopControlAction,
    payload: &RemoteDesktopControlRequestPayload,
) -> Result<()> {
    match action {
        RemoteDesktopControlAction::Start => {
            let Some(resolution) = payload.resolution.as_ref() else {
                bail!("remote desktop start request requires a resolution payload");
            };
            validate_remote_desktop_resolution_request(resolution)?;
            let Some(fps) = payload.fps else {
                bail!("remote desktop start request requires an fps payload");
            };
            validate_remote_desktop_request_fps(fps)?;
        }
        RemoteDesktopControlAction::Stop => {
            if payload.resolution.is_some() || payload.fps.is_some() {
                bail!("remote desktop stop request must not include resolution or fps payload");
            }
        }
        RemoteDesktopControlAction::SetResolution => {
            let Some(resolution) = payload.resolution.as_ref() else {
                bail!("remote desktop set-resolution request requires a resolution payload");
            };
            validate_remote_desktop_resolution_request(resolution)?;
            if payload.fps.is_some() {
                bail!("remote desktop set-resolution request must not include an fps payload");
            }
        }
        RemoteDesktopControlAction::SetFps => {
            if payload.resolution.is_some() {
                bail!("remote desktop set-fps request must not include a resolution payload");
            }
            let Some(fps) = payload.fps else {
                bail!("remote desktop set-fps request requires an fps payload");
            };
            validate_remote_desktop_request_fps(fps)?;
        }
    }
    Ok(())
}

fn validate_remote_desktop_resolution_request(
    resolution: &RemoteDesktopResolutionRequest,
) -> Result<()> {
    match resolution {
        RemoteDesktopResolutionRequest::Auto => Ok(()),
        RemoteDesktopResolutionRequest::Preset { id, width, height } => {
            if remote_desktop_resolution_preset_matches(id, *width, *height) {
                Ok(())
            } else {
                bail!("remote desktop resolution request preset is outside the bounded contract")
            }
        }
    }
}

fn validate_remote_desktop_request_fps(fps: u16) -> Result<()> {
    if remote_desktop_fps_request_supported(fps) {
        Ok(())
    } else {
        bail!("remote desktop fps request is outside the bounded contract")
    }
}

fn validate_file_transfer_request_registry(
    path: &Path,
    registry: &FileTransferControlRequestRegistry,
) -> Result<()> {
    if registry.schema_version != FileTransferControlRequestRegistry::SCHEMA_VERSION {
        bail!(
            "unsupported file transfer request registry schema version {} in {}; expected {}",
            registry.schema_version,
            path.display(),
            FileTransferControlRequestRegistry::SCHEMA_VERSION
        );
    }
    if registry.requests.len() > FileTransferControlRequestRegistry::MAX_REQUESTS {
        bail!(
            "file transfer request registry has {} entries in {}; max {}",
            registry.requests.len(),
            path.display(),
            FileTransferControlRequestRegistry::MAX_REQUESTS
        );
    }
    for (request_id, request) in &registry.requests {
        if request_id != &request.request_id {
            bail!(
                "file transfer request key `{}` does not match request_id `{}` in {}",
                request_id,
                request.request_id,
                path.display()
            );
        }
        validate_file_transfer_request(request)?;
    }
    Ok(())
}

fn validate_file_transfer_request(request: &FileTransferControlRequest) -> Result<()> {
    if request.schema_version != FileTransferControlRequest::SCHEMA_VERSION {
        bail!(
            "unsupported file transfer request schema version {} for request `{}`; expected {}",
            request.schema_version,
            request.request_id,
            FileTransferControlRequest::SCHEMA_VERSION
        );
    }
    if request.request_id.trim().is_empty() {
        bail!("file transfer request_id must not be empty");
    }
    if request.session_id.trim().is_empty() {
        bail!(
            "file transfer request `{}` session_id must not be empty",
            request.request_id
        );
    }
    if request.target_runtime_id.trim().is_empty() {
        bail!(
            "file transfer request `{}` target_runtime_id must not be empty",
            request.request_id
        );
    }
    if request.source.source_path.trim().is_empty() {
        bail!(
            "file transfer request `{}` source path must not be empty",
            request.request_id
        );
    }
    if request.source.sha256_hex.len() != 64
        || !request
            .source
            .sha256_hex
            .chars()
            .all(|ch| ch.is_ascii_digit() || matches!(ch, 'a'..='f'))
    {
        bail!(
            "file transfer request `{}` source sha256 must be lowercase hex",
            request.request_id
        );
    }
    if request.destination.requested_peer_ref.trim().is_empty()
        || request.destination.remote_device_id.trim().is_empty()
        || request
            .destination
            .remote_protocol_public_key_fingerprint
            .trim()
            .is_empty()
    {
        bail!(
            "file transfer request `{}` destination binding must be complete",
            request.request_id
        );
    }
    Ok(())
}

fn validate_nearby_discovery_snapshot(snapshot: &NearbyDiscoverySnapshot) -> Result<()> {
    if snapshot.schema_version != NearbyDiscoverySnapshot::SCHEMA_VERSION {
        bail!(
            "unsupported nearby discovery snapshot schema version {} for scan `{}`; expected {}",
            snapshot.schema_version,
            snapshot.scan_id,
            NearbyDiscoverySnapshot::SCHEMA_VERSION
        );
    }
    if snapshot.scan_id.trim().is_empty() {
        bail!("nearby discovery snapshot scan_id must not be empty");
    }
    if snapshot.source.trim().is_empty() {
        bail!(
            "nearby discovery snapshot source must not be empty for scan `{}`",
            snapshot.scan_id
        );
    }
    validate_public_snapshot_text("source", &snapshot.source)?;
    if looks_like_network_locator(&snapshot.source) {
        bail!("nearby discovery snapshot source must not expose a network locator");
    }
    if snapshot.expires_at <= snapshot.observed_at {
        bail!(
            "nearby discovery snapshot `{}` expires before or at observed_at",
            snapshot.scan_id
        );
    }
    if snapshot.devices.len() > NearbyDiscoverySnapshotRegistry::MAX_DEVICES_PER_SNAPSHOT {
        bail!(
            "nearby discovery snapshot `{}` has {} devices; max {}",
            snapshot.scan_id,
            snapshot.devices.len(),
            NearbyDiscoverySnapshotRegistry::MAX_DEVICES_PER_SNAPSHOT
        );
    }
    for device in &snapshot.devices {
        validate_nearby_discovered_device(&snapshot.scan_id, device)?;
    }
    Ok(())
}

fn validate_nearby_discovered_device(scan_id: &str, device: &NearbyDiscoveredDevice) -> Result<()> {
    if device.device_ref.trim().is_empty() {
        bail!("nearby discovery device_ref must not be empty for scan `{scan_id}`");
    }
    validate_public_snapshot_text("device_ref", &device.device_ref)?;
    if looks_like_network_locator(&device.device_ref) {
        bail!("nearby discovery device_ref for scan `{scan_id}` must not expose a network locator");
    }
    if device.display_name.trim().is_empty() {
        bail!(
            "nearby discovery display_name must not be empty for device_ref `{}` in scan `{}`",
            device.device_ref,
            scan_id
        );
    }
    validate_public_snapshot_text("display_name", &device.display_name)?;
    if device.connectable
        && !matches!(
            device.trust_status,
            NearbyDiscoveryTrustStatus::ProtocolIdentityVerified
                | NearbyDiscoveryTrustStatus::Trusted
        )
    {
        bail!(
            "nearby discovery device in scan `{scan_id}` cannot be connectable without verified or trusted protocol identity"
        );
    }
    for capability in &device.capabilities {
        if capability.trim().is_empty() {
            bail!(
                "nearby discovery capability must not be empty for device_ref `{}` in scan `{}`",
                device.device_ref,
                scan_id
            );
        }
        validate_public_snapshot_text("capability", capability)?;
        if looks_like_network_locator(capability) {
            bail!(
                "nearby discovery capability for scan `{scan_id}` must not expose a network locator"
            );
        }
    }
    Ok(())
}

fn validate_public_snapshot_text(field: &str, value: &str) -> Result<()> {
    if value.len() > 128 {
        bail!("nearby discovery {field} exceeds 128 bytes");
    }
    if value.chars().any(|ch| ch.is_control()) {
        bail!("nearby discovery {field} must not contain control characters");
    }
    Ok(())
}

fn looks_like_network_locator(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.contains(':')
        || trimmed.contains('/')
        || trimmed.ends_with(".local")
        || trimmed
            .split('.')
            .all(|segment| !segment.is_empty() && segment.chars().all(|ch| ch.is_ascii_digit()))
}

fn file_transfer_source_snapshot(source_path: &PathBuf) -> Result<FileTransferSourceSnapshot> {
    if source_path.as_os_str().is_empty() {
        bail!("file transfer source path is required");
    }
    let canonical_source = std::fs::canonicalize(source_path)
        .map_err(|_| anyhow!("file transfer source path is unavailable or not readable"))?;
    let mut file = std::fs::File::open(&canonical_source)
        .map_err(|_| anyhow!("file transfer source is unreadable"))?;
    let metadata = file
        .metadata()
        .map_err(|_| anyhow!("file transfer source metadata is unavailable"))?;
    if !metadata.is_file() {
        bail!("file transfer source path must refer to a regular file");
    }
    let source_path = canonical_source
        .to_str()
        .ok_or_else(|| anyhow!("file transfer source path must be valid UTF-8"))?
        .to_owned();
    Ok(FileTransferSourceSnapshot {
        source_path,
        size_bytes: metadata.len(),
        sha256_hex: sha256_file_hex(&mut file)?,
    })
}

fn sha256_file_hex(file: &mut std::fs::File) -> Result<String> {
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|_| anyhow!("failed to read file transfer source for hashing"))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn validate_remote_desktop_capability_snapshot_registry(
    path: &Path,
    registry: &RemoteDesktopCapabilitySnapshotRegistry,
) -> Result<()> {
    if registry.schema_version != RemoteDesktopCapabilitySnapshotRegistry::SCHEMA_VERSION {
        bail!(
            "unsupported remote desktop capability snapshot registry schema version {} in {}; expected {}",
            registry.schema_version,
            path.display(),
            RemoteDesktopCapabilitySnapshotRegistry::SCHEMA_VERSION
        );
    }
    if registry.snapshots.len() > RemoteDesktopCapabilitySnapshotRegistry::MAX_SNAPSHOTS {
        bail!(
            "remote desktop capability snapshot registry has {} entries in {}; max {}",
            registry.snapshots.len(),
            path.display(),
            RemoteDesktopCapabilitySnapshotRegistry::MAX_SNAPSHOTS
        );
    }
    for (session_id, snapshot) in &registry.snapshots {
        if session_id != &snapshot.session_id {
            bail!(
                "remote desktop capability snapshot key `{}` does not match session_id `{}` in {}",
                session_id,
                snapshot.session_id,
                path.display()
            );
        }
        validate_remote_desktop_capability_snapshot(snapshot)?;
    }
    Ok(())
}

fn validate_remote_desktop_capability_snapshot(
    snapshot: &RemoteDesktopCapabilitySnapshot,
) -> Result<()> {
    const MAX_REMOTE_DESKTOP_CAPABILITY_TTL_SECONDS: i64 = 300;
    const MAX_REMOTE_DESKTOP_MODES_PER_LIST: usize = 64;

    if snapshot.schema_version != RemoteDesktopCapabilitySnapshot::SCHEMA_VERSION {
        bail!(
            "unsupported remote desktop capability snapshot schema version {} for session `{}`; expected {}",
            snapshot.schema_version,
            snapshot.session_id,
            RemoteDesktopCapabilitySnapshot::SCHEMA_VERSION
        );
    }
    if snapshot.session_id.trim().is_empty() {
        bail!("remote desktop capability snapshot session_id must not be empty");
    }
    if snapshot.target_runtime_id.trim().is_empty() {
        bail!(
            "remote desktop capability snapshot target_runtime_id must not be empty for session `{}`",
            snapshot.session_id
        );
    }
    if snapshot.sender_modes.is_empty() {
        bail!(
            "remote desktop capability snapshot for session `{}` must include at least one sender mode",
            snapshot.session_id
        );
    }
    if snapshot.expires_at != OffsetDateTime::UNIX_EPOCH
        && snapshot.expires_at <= snapshot.observed_at
    {
        bail!(
            "remote desktop capability snapshot for session `{}` expires before or at observed_at",
            snapshot.session_id
        );
    }
    if snapshot.expires_at != OffsetDateTime::UNIX_EPOCH
        && snapshot.expires_at - snapshot.observed_at
            > time::Duration::seconds(MAX_REMOTE_DESKTOP_CAPABILITY_TTL_SECONDS)
    {
        bail!(
            "remote desktop capability snapshot for session `{}` exceeds max freshness window",
            snapshot.session_id
        );
    }
    if snapshot.sender_modes.len() > MAX_REMOTE_DESKTOP_MODES_PER_LIST
        || snapshot.display_modes.len() > MAX_REMOTE_DESKTOP_MODES_PER_LIST
    {
        bail!(
            "remote desktop capability snapshot for session `{}` has too many observed modes",
            snapshot.session_id
        );
    }
    for mode in snapshot
        .sender_modes
        .iter()
        .chain(snapshot.display_modes.iter())
    {
        validate_remote_desktop_observed_mode(&snapshot.session_id, mode)?;
    }
    Ok(())
}

fn validate_remote_desktop_observed_mode(
    session_id: &str,
    mode: &RemoteDesktopObservedMode,
) -> Result<()> {
    if mode.id.trim().is_empty() {
        bail!("remote desktop capability mode id must not be empty for session `{session_id}`");
    }
    if mode.id.len() > 64 || mode.id.chars().any(|ch| ch.is_control()) {
        bail!("remote desktop capability mode id is outside the public text contract");
    }
    if mode.width == 0 || mode.height == 0 || mode.fps == 0 {
        bail!(
            "remote desktop capability mode `{}` for session `{}` must have positive width, height, and fps",
            mode.id,
            session_id
        );
    }
    if mode.width > 7680 || mode.height > 4320 || mode.fps > 240 {
        bail!(
            "remote desktop capability mode `{}` for session `{}` is outside bounded display limits",
            mode.id,
            session_id
        );
    }
    Ok(())
}

fn restrict_file_permissions_blocking(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let permissions = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(path, permissions)
            .with_context(|| format!("failed to set permissions on {}", path.display()))?;
    }

    Ok(())
}

async fn mutate_session_registry<R, F>(paths: &AgentPaths, update: F) -> Result<R>
where
    R: Send + 'static,
    F: FnOnce(&mut SessionRegistry) -> R + Send + 'static,
{
    ensure_identity_layout(paths).await?;
    let registry_path = session_registry_file(paths);
    let lock_path = session_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, true)?;
        let mut registry = load_session_registry_unlocked(&registry_path)?;
        let output = update(&mut registry);
        registry.schema_version = SessionRegistry::SCHEMA_VERSION;
        store_session_registry_unlocked(&registry_path, &registry)?;
        Ok(output)
    })
    .await
    .context("session registry mutation task panicked")?
}

async fn write_json<T>(path: &Path, value: &T) -> Result<()>
where
    T: Serialize,
{
    let body = serde_json::to_vec_pretty(value).context("failed to encode json")?;
    fs::write(path, body)
        .await
        .with_context(|| format!("failed to write {}", path.display()))?;
    restrict_file_permissions(path).await
}

async fn load_json<T>(path: &Path) -> Result<Option<T>>
where
    T: for<'de> Deserialize<'de>,
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

fn auth_session_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.identity_dir.join("auth-session.json")
}

fn signing_key_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.identity_dir.join("protocol-signing-key.json")
}

fn kem_identity_key_file(paths: &AgentPaths, suite_wire_id: u16) -> std::path::PathBuf {
    paths
        .identity_dir
        .join(format!("kem-identity-{suite_wire_id:04x}.json"))
}

fn session_registry_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.runtime_dir.join("sessions.json")
}

fn session_registry_lock_file(paths: &AgentPaths) -> std::path::PathBuf {
    session_registry_file(paths).with_file_name("sessions.json.lock")
}

fn session_controls_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.session_controls_file.clone()
}

fn nearby_discovery_snapshot_registry_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.nearby_discovery_snapshots_file.clone()
}

fn nearby_discovery_snapshot_registry_lock_file(paths: &AgentPaths) -> std::path::PathBuf {
    nearby_discovery_snapshot_registry_file(paths)
        .with_file_name("nearby-discovery-snapshots.json.lock")
}

fn file_transfer_request_registry_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.file_transfer_requests_file.clone()
}

fn file_transfer_request_registry_lock_file(paths: &AgentPaths) -> std::path::PathBuf {
    file_transfer_request_registry_file(paths).with_file_name("file-transfer-requests.json.lock")
}

fn remote_desktop_request_registry_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.remote_desktop_requests_file.clone()
}

fn remote_desktop_request_registry_lock_file(paths: &AgentPaths) -> std::path::PathBuf {
    remote_desktop_request_registry_file(paths).with_file_name("remote-desktop-requests.json.lock")
}

fn remote_desktop_capability_snapshot_registry_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.remote_desktop_capabilities_file.clone()
}

fn remote_desktop_capability_snapshot_registry_lock_file(paths: &AgentPaths) -> std::path::PathBuf {
    remote_desktop_capability_snapshot_registry_file(paths)
        .with_file_name("remote-desktop-capabilities.json.lock")
}

fn current_hostname() -> String {
    hostname::get()
        .ok()
        .and_then(|value| value.into_string().ok())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "skybridge-host".to_owned())
}

fn new_device_id() -> String {
    uuid::Uuid::now_v7().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use skybridge_core::{RuntimeSessionRole, RuntimeSessionSource, SessionReadiness};

    fn test_paths(name: &str) -> AgentPaths {
        crate::runtime::resolve_paths(Some(std::env::temp_dir().join(format!(
            "skybridge-agent-state-{name}-{}",
            uuid::Uuid::now_v7()
        ))))
        .expect("temporary paths should resolve")
    }

    async fn seed_session(paths: &AgentPaths, session_id: &str, state: RuntimeSessionState) {
        let mut record = RuntimeSessionRecord::new(
            format!("runtime-{session_id}"),
            session_id.to_owned(),
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "https://signal.example.com",
            "local-device",
            None,
            None,
            None,
            state,
        );
        if record.is_active() {
            let readiness = SessionReadiness::TransportReady {
                session_id: session_id.to_owned(),
            };
            record.readiness = readiness.clone();
            record.last_established_readiness = Some(readiness);
        }
        upsert_session_runtime(paths, record)
            .await
            .expect("session should seed");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_registry_updates_preserve_both_mutations() {
        let paths = test_paths("concurrent-registry-updates");
        seed_session(&paths, "session-1", RuntimeSessionState::Connecting).await;

        let transport_paths = paths.clone();
        let peer_paths = paths.clone();
        let (transport_result, peer_result) = tokio::join!(
            apply_transport_event(
                &transport_paths,
                "session-1",
                RuntimeSessionTransportEvent::TransportReady,
            ),
            update_session_remote_peer(
                &peer_paths,
                "session-1",
                "remote-device",
                Some("Peer".to_owned()),
                Some("fingerprint".to_owned()),
            )
        );
        transport_result.expect("transport update should succeed");
        peer_result.expect("peer update should succeed");

        let registry = load_session_registry(&paths)
            .await
            .expect("session registry should load");
        let record = registry
            .get("session-1")
            .expect("session record should exist");
        assert!(record.readiness.is_transport_established_for("session-1"));
        assert_eq!(record.remote_device_id.as_deref(), Some("remote-device"));
        assert_eq!(record.remote_device_name.as_deref(), Some("Peer"));
        assert_eq!(
            record.remote_protocol_public_key_fingerprint.as_deref(),
            Some("fingerprint")
        );

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn disconnect_session_if_active_clears_only_live_records() {
        let paths = test_paths("disconnect-session-cleanup");
        seed_session(&paths, "active-session", RuntimeSessionState::Bound).await;
        seed_session(&paths, "failed-session", RuntimeSessionState::Failed).await;

        assert!(
            disconnect_session_if_active(
                &paths,
                "active-session",
                Some("worker exited".to_owned()),
            )
            .await
            .expect("active cleanup should succeed")
        );
        assert!(
            !disconnect_session_if_active(
                &paths,
                "failed-session",
                Some("worker exited".to_owned()),
            )
            .await
            .expect("failed cleanup should succeed")
        );

        let registry = load_session_registry(&paths)
            .await
            .expect("session registry should load");
        assert_eq!(
            registry
                .get("active-session")
                .expect("active session should exist")
                .state,
            RuntimeSessionState::Disconnected
        );
        assert_eq!(
            registry
                .get("failed-session")
                .expect("failed session should exist")
                .state,
            RuntimeSessionState::Failed
        );

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn remote_desktop_request_requires_established_active_session() {
        let paths = test_paths("remote-desktop-request-established");
        seed_session(&paths, "session-1", RuntimeSessionState::Bound).await;

        let request = enqueue_remote_desktop_request_for_established_session(
            &paths,
            "session-1",
            RemoteDesktopControlAction::Start,
            RemoteDesktopControlRequestPayload {
                resolution: Some(skybridge_core::RemoteDesktopResolutionRequest::Preset {
                    id: "1920x1080".to_owned(),
                    width: 1920,
                    height: 1080,
                }),
                fps: Some(60),
            },
        )
        .await
        .expect("established active session should accept a pending request");
        assert_eq!(request.session_id, "session-1");
        assert_eq!(request.target_runtime_id, "runtime-session-1");
        assert!(request.is_pending_agent_observation());

        let registry = load_remote_desktop_request_registry(&paths)
            .await
            .expect("request registry should load");
        assert_eq!(registry.pending_for_session("session-1").len(), 1);

        let duplicate = enqueue_remote_desktop_request_for_established_session(
            &paths,
            "session-1",
            RemoteDesktopControlAction::SetFps,
            RemoteDesktopControlRequestPayload {
                resolution: None,
                fps: Some(120),
            },
        )
        .await;
        assert!(
            duplicate.is_err(),
            "a session must not accept an unbounded queue of pending requests"
        );

        let observed = observe_remote_desktop_requests_for_established_session(&paths, "session-1")
            .await
            .expect("established active session should observe pending remote desktop requests");
        assert_eq!(observed.len(), 1);
        assert_eq!(observed[0].session_id, "session-1");
        assert!(observed[0].is_agent_observed());
        assert!(!observed[0].is_pending_agent_observation());
        let registry = load_remote_desktop_request_registry(&paths)
            .await
            .expect("observed request registry should load");
        assert!(registry.pending_for_session("session-1").is_empty());
        assert!(
            observe_remote_desktop_requests_for_established_session(&paths, "session-1")
                .await
                .expect("observed session should not produce duplicate observations")
                .is_empty()
        );

        seed_session(&paths, "session-stale-runtime", RuntimeSessionState::Bound).await;
        let mut stale_registry = load_remote_desktop_request_registry(&paths)
            .await
            .expect("request registry should load before seeding stale request");
        stale_registry.insert(RemoteDesktopControlRequest::pending(
            "stale-request-1",
            "session-stale-runtime",
            "old-runtime",
            RemoteDesktopControlAction::Stop,
            RemoteDesktopControlRequestPayload::default(),
        ));
        tokio::fs::write(
            &paths.remote_desktop_requests_file,
            serde_json::to_vec_pretty(&stale_registry).expect("stale registry should serialize"),
        )
        .await
        .expect("stale request registry should be seeded");
        assert!(
            observe_remote_desktop_requests_for_established_session(
                &paths,
                "session-stale-runtime"
            )
            .await
            .is_err(),
            "agent observe must reject stale-runtime pending requests"
        );
        let stale_registry = load_remote_desktop_request_registry(&paths)
            .await
            .expect("stale registry should remain loadable");
        assert_eq!(
            stale_registry
                .pending_for_session("session-stale-runtime")
                .len(),
            1
        );

        seed_session(&paths, "session-2", RuntimeSessionState::Disconnected).await;
        let inactive = enqueue_remote_desktop_request_for_established_session(
            &paths,
            "session-2",
            RemoteDesktopControlAction::Stop,
            RemoteDesktopControlRequestPayload::default(),
        )
        .await;
        assert!(
            inactive.is_err(),
            "disconnected sessions must not create remote desktop pending requests"
        );

        let missing = enqueue_remote_desktop_request_for_established_session(
            &paths,
            "missing",
            RemoteDesktopControlAction::Stop,
            RemoteDesktopControlRequestPayload::default(),
        )
        .await;
        assert!(
            missing.is_err(),
            "missing sessions must not create remote desktop pending requests"
        );

        seed_session(&paths, "session-invalid-start", RuntimeSessionState::Bound).await;
        let invalid_start_payload = enqueue_remote_desktop_request_for_established_session(
            &paths,
            "session-invalid-start",
            RemoteDesktopControlAction::Start,
            RemoteDesktopControlRequestPayload::default(),
        )
        .await;
        assert!(
            invalid_start_payload.is_err(),
            "start requests must be rejected without bounded resolution and fps payload"
        );

        seed_session(&paths, "session-invalid-stop", RuntimeSessionState::Bound).await;
        let invalid_stop_payload = enqueue_remote_desktop_request_for_established_session(
            &paths,
            "session-invalid-stop",
            RemoteDesktopControlAction::Stop,
            RemoteDesktopControlRequestPayload {
                resolution: None,
                fps: Some(60),
            },
        )
        .await;
        assert!(
            invalid_stop_payload.is_err(),
            "stop requests must be rejected when they smuggle mode payload"
        );

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    async fn seed_file_transfer_session(paths: &AgentPaths, session_id: &str) {
        let mut record = RuntimeSessionRecord::new(
            format!("runtime-{session_id}"),
            session_id.to_owned(),
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "https://signal.example.com",
            "local-device",
            Some("remote-device".to_owned()),
            Some("Peer".to_owned()),
            Some("fingerprint".to_owned()),
            RuntimeSessionState::Bound,
        );
        let readiness = SessionReadiness::HandshakeComplete {
            session_id: session_id.to_owned(),
            negotiated_suite: "xwing".to_owned(),
        };
        record.readiness = readiness.clone();
        record.last_established_readiness = Some(readiness);
        upsert_session_runtime(paths, record)
            .await
            .expect("file transfer session should seed");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn file_transfer_request_registry_loads_empty_missing_file() {
        let paths = test_paths("file-transfer-request-missing");
        let registry = load_file_transfer_request_registry(&paths)
            .await
            .expect("missing file transfer request registry should load as empty");
        assert!(registry.requests.is_empty());

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn file_transfer_send_request_requires_handshake_peer_and_file_proof() {
        let paths = test_paths("file-transfer-request-established");
        ensure_identity_layout(&paths)
            .await
            .expect("identity layout should be created");
        seed_file_transfer_session(&paths, "session-1").await;
        let source_path = paths.root.join("payload.bin");
        tokio::fs::write(&source_path, b"hello")
            .await
            .expect("source file should be seeded");

        let request = enqueue_file_transfer_send_request_for_established_session(
            &paths,
            "session-1",
            "remote-device",
            &source_path,
        )
        .await
        .expect("handshake-complete bound peer should accept a pending send request");
        assert_eq!(request.session_id, "session-1");
        assert_eq!(request.target_runtime_id, "runtime-session-1");
        assert!(request.is_pending_agent_observation());
        assert_eq!(request.source.size_bytes, 5);
        assert_eq!(
            request.source.sha256_hex,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
        assert_eq!(request.destination.remote_device_id, "remote-device");
        assert_eq!(
            request.destination.remote_protocol_public_key_fingerprint,
            "fingerprint"
        );

        let registry = load_file_transfer_request_registry(&paths)
            .await
            .expect("request registry should load");
        assert_eq!(registry.pending_for_session("session-1").len(), 1);

        let duplicate = enqueue_file_transfer_send_request_for_established_session(
            &paths,
            "session-1",
            "remote-device",
            &source_path,
        )
        .await;
        assert!(
            duplicate.is_err(),
            "a session must not accept an unbounded queue of pending file transfer requests"
        );

        let observed = observe_file_transfer_requests_for_established_session(&paths, "session-1")
            .await
            .expect(
                "handshake-complete active session should observe pending file transfer requests",
            );
        assert_eq!(observed.len(), 1);
        assert_eq!(observed[0].session_id, "session-1");
        assert!(observed[0].is_agent_observed());
        assert!(!observed[0].is_pending_agent_observation());
        let registry = load_file_transfer_request_registry(&paths)
            .await
            .expect("observed request registry should load");
        assert!(registry.pending_for_session("session-1").is_empty());
        assert!(
            observe_file_transfer_requests_for_established_session(&paths, "session-1")
                .await
                .expect("observed session should not produce duplicate file transfer observations")
                .is_empty()
        );

        seed_file_transfer_session(&paths, "session-stale-runtime").await;
        let mut stale_registry = load_file_transfer_request_registry(&paths)
            .await
            .expect("file transfer registry should load before seeding stale request");
        stale_registry.insert(FileTransferControlRequest::pending_send(
            "stale-file-request-1",
            "session-stale-runtime",
            "old-runtime",
            FileTransferSourceSnapshot {
                source_path: "/private/stale.bin".to_owned(),
                size_bytes: 5,
                sha256_hex: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                    .to_owned(),
            },
            FileTransferDestinationBinding {
                requested_peer_ref: "remote-device".to_owned(),
                remote_device_id: "remote-device".to_owned(),
                remote_protocol_public_key_fingerprint: "fingerprint".to_owned(),
            },
        ));
        store_file_transfer_request_registry_unlocked(
            &paths.file_transfer_requests_file,
            &stale_registry,
        )
        .expect("stale file transfer request should be persisted");
        let stale_observe =
            observe_file_transfer_requests_for_established_session(&paths, "session-stale-runtime")
                .await
                .expect_err("stale-runtime file transfer request must fail closed");
        assert!(
            stale_observe.to_string().contains("stale runtime"),
            "stale runtime failure should be explicit: {stale_observe}"
        );
        let stale_registry = load_file_transfer_request_registry(&paths)
            .await
            .expect("file transfer registry should survive stale observe failure");
        assert_eq!(
            stale_registry
                .pending_for_session("session-stale-runtime")
                .len(),
            1
        );

        seed_session(&paths, "transport-only", RuntimeSessionState::Bound).await;
        let mut transport_only_registry = load_file_transfer_request_registry(&paths)
            .await
            .expect("file transfer registry should load before transport-only pending seed");
        transport_only_registry.insert(FileTransferControlRequest::pending_send(
            "transport-only-file-request-1",
            "transport-only",
            "runtime-transport-only",
            FileTransferSourceSnapshot {
                source_path: "/private/transport-only.bin".to_owned(),
                size_bytes: 5,
                sha256_hex: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                    .to_owned(),
            },
            FileTransferDestinationBinding {
                requested_peer_ref: "remote-device".to_owned(),
                remote_device_id: "remote-device".to_owned(),
                remote_protocol_public_key_fingerprint: "fingerprint".to_owned(),
            },
        ));
        store_file_transfer_request_registry_unlocked(
            &paths.file_transfer_requests_file,
            &transport_only_registry,
        )
        .expect("transport-only file transfer request should be persisted");
        let transport_only_observe =
            observe_file_transfer_requests_for_established_session(&paths, "transport-only")
                .await
                .expect_err("transport-only file transfer pending request must fail closed");
        assert!(
            transport_only_observe
                .to_string()
                .contains("current handshake-complete"),
            "transport-only observe failure should explain missing handshake proof: {transport_only_observe}"
        );

        let transport_only = enqueue_file_transfer_send_request_for_established_session(
            &paths,
            "transport-only",
            "remote-device",
            &source_path,
        )
        .await;
        assert!(
            transport_only.is_err(),
            "file transfer send requests must require current handshake-complete evidence"
        );

        let destination_mismatch = enqueue_file_transfer_send_request_for_established_session(
            &paths,
            "session-1",
            "wrong-peer-secret",
            &source_path,
        )
        .await
        .expect_err("destination mismatch must be rejected");
        assert!(
            !destination_mismatch
                .to_string()
                .contains("wrong-peer-secret"),
            "destination mismatch must not echo raw peer refs"
        );

        let missing_path = paths.root.join("missing-secret-name.bin");
        let missing = enqueue_file_transfer_send_request_for_established_session(
            &paths,
            "session-1",
            "remote-device",
            &missing_path,
        )
        .await
        .expect_err("missing source file must be rejected");
        assert!(
            !missing.to_string().contains("missing-secret-name"),
            "source path errors must not echo raw local paths"
        );

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn corrupt_file_transfer_request_registry_fails_closed() {
        let paths = test_paths("file-transfer-request-corrupt-registry");
        ensure_identity_layout(&paths)
            .await
            .expect("identity layout should be created");
        seed_file_transfer_session(&paths, "session-1").await;
        let source_path = paths.root.join("payload.bin");
        tokio::fs::write(&source_path, b"hello")
            .await
            .expect("source file should be seeded");
        tokio::fs::write(&paths.file_transfer_requests_file, b"{not-json")
            .await
            .expect("corrupt file transfer request registry should be seeded");

        let result = enqueue_file_transfer_send_request_for_established_session(
            &paths,
            "session-1",
            "remote-device",
            &source_path,
        )
        .await;
        assert!(
            result.is_err(),
            "corrupt request registry must not be replaced with a pending file transfer request"
        );
        let body = tokio::fs::read_to_string(&paths.file_transfer_requests_file)
            .await
            .expect("corrupt registry should remain for diagnosis");
        assert_eq!(body, "{not-json");

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn corrupt_remote_desktop_request_registry_fails_closed() {
        let paths = test_paths("remote-desktop-request-corrupt-registry");
        seed_session(&paths, "session-1", RuntimeSessionState::Bound).await;
        tokio::fs::write(&paths.remote_desktop_requests_file, b"{not-json")
            .await
            .expect("corrupt request registry should be seeded");

        let result = enqueue_remote_desktop_request_for_established_session(
            &paths,
            "session-1",
            RemoteDesktopControlAction::Start,
            RemoteDesktopControlRequestPayload {
                resolution: None,
                fps: Some(60),
            },
        )
        .await;
        assert!(
            result.is_err(),
            "corrupt request registry must not be replaced with a new pending request"
        );
        let body = tokio::fs::read_to_string(&paths.remote_desktop_requests_file)
            .await
            .expect("corrupt registry should remain for diagnosis");
        assert_eq!(body, "{not-json");

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn malformed_remote_desktop_request_registry_fails_closed() {
        let paths = test_paths("remote-desktop-request-malformed-registry");
        seed_session(&paths, "session-1", RuntimeSessionState::Bound).await;
        let mut registry = RemoteDesktopControlRequestRegistry::default();
        registry.insert(RemoteDesktopControlRequest::pending(
            "request-1",
            "session-1",
            "runtime-session-1",
            RemoteDesktopControlAction::SetFps,
            RemoteDesktopControlRequestPayload {
                resolution: Some(RemoteDesktopResolutionRequest::Preset {
                    id: "1920x1080".to_owned(),
                    width: 1920,
                    height: 1080,
                }),
                fps: Some(60),
            },
        ));
        tokio::fs::write(
            &paths.remote_desktop_requests_file,
            serde_json::to_vec_pretty(&registry).expect("malformed registry should serialize"),
        )
        .await
        .expect("malformed registry should be seeded");

        let load = load_remote_desktop_request_registry(&paths).await;
        assert!(
            load.is_err(),
            "remote desktop request registry must reject action/payload mismatches"
        );
        let result = enqueue_remote_desktop_request_for_established_session(
            &paths,
            "session-1",
            RemoteDesktopControlAction::Start,
            RemoteDesktopControlRequestPayload {
                resolution: Some(RemoteDesktopResolutionRequest::Preset {
                    id: "1920x1080".to_owned(),
                    width: 1920,
                    height: 1080,
                }),
                fps: Some(60),
            },
        )
        .await;
        assert!(
            result.is_err(),
            "malformed request registry must not be replaced with a new pending request"
        );

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn nearby_discovery_snapshot_registry_loads_empty_missing_file() {
        let paths = test_paths("nearby-discovery-missing");
        let registry = load_nearby_discovery_snapshot_registry(&paths)
            .await
            .expect("missing nearby discovery snapshot registry should load as empty");
        assert!(registry.snapshots.is_empty());

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn nearby_discovery_snapshot_persists_and_rejects_untrusted_connectable_devices() {
        let paths = test_paths("nearby-discovery-upsert");
        let registry = upsert_nearby_discovery_snapshot(
            &paths,
            NearbyDiscoverySnapshot::new(
                "scan-1",
                "agent_owned_nearby_discovery_snapshot",
                vec![NearbyDiscoveredDevice::new(
                    "nearby-device-1",
                    "Studio Mac",
                    skybridge_core::NearbyDiscoveryEndpointClass::LocalNetwork,
                    NearbyDiscoveryTrustStatus::ProtocolIdentityVerified,
                    vec!["remote_desktop".to_owned(), "file_transfer".to_owned()],
                    true,
                )],
                300,
            ),
        )
        .await
        .expect("fresh nearby discovery snapshot should persist");
        assert_eq!(registry.snapshots.len(), 1);
        let reloaded = load_nearby_discovery_snapshot_registry(&paths)
            .await
            .expect("nearby discovery snapshot registry should reload");
        let snapshot = reloaded
            .latest_fresh(OffsetDateTime::now_utc())
            .expect("fresh snapshot should reload");
        assert_eq!(snapshot.devices[0].device_ref, "nearby-device-1");

        let untrusted_connectable = upsert_nearby_discovery_snapshot(
            &paths,
            NearbyDiscoverySnapshot::new(
                "scan-2",
                "agent_owned_nearby_discovery_snapshot",
                vec![NearbyDiscoveredDevice::new(
                    "nearby-device-2",
                    "Candidate Mac",
                    skybridge_core::NearbyDiscoveryEndpointClass::LocalNetwork,
                    NearbyDiscoveryTrustStatus::Candidate,
                    vec!["file_transfer".to_owned()],
                    true,
                )],
                300,
            ),
        )
        .await;
        assert!(
            untrusted_connectable.is_err(),
            "connectable nearby devices must require verified or trusted protocol identity"
        );

        let locator_ref = upsert_nearby_discovery_snapshot(
            &paths,
            NearbyDiscoverySnapshot::new(
                "scan-3",
                "agent_owned_nearby_discovery_snapshot",
                vec![NearbyDiscoveredDevice::new(
                    "192.168.0.10",
                    "Leaky Mac",
                    skybridge_core::NearbyDiscoveryEndpointClass::LocalNetwork,
                    NearbyDiscoveryTrustStatus::Trusted,
                    vec!["remote_desktop".to_owned()],
                    true,
                )],
                300,
            ),
        )
        .await;
        let error = locator_ref
            .expect_err("device_ref must reject network locators")
            .to_string();
        assert!(
            !error.contains("192.168.0.10"),
            "locator rejection must not echo the raw locator"
        );

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn corrupt_nearby_discovery_snapshot_registry_fails_closed() {
        let paths = test_paths("nearby-discovery-corrupt-registry");
        ensure_identity_layout(&paths)
            .await
            .expect("identity layout should be created");
        tokio::fs::write(&paths.nearby_discovery_snapshots_file, b"{not-json")
            .await
            .expect("corrupt nearby discovery snapshot registry should be seeded");

        let result = upsert_nearby_discovery_snapshot(
            &paths,
            NearbyDiscoverySnapshot::new(
                "scan-1",
                "agent_owned_nearby_discovery_snapshot",
                vec![NearbyDiscoveredDevice::new(
                    "nearby-device-1",
                    "Studio Mac",
                    skybridge_core::NearbyDiscoveryEndpointClass::LocalNetwork,
                    NearbyDiscoveryTrustStatus::Trusted,
                    vec!["remote_desktop".to_owned()],
                    true,
                )],
                300,
            ),
        )
        .await;
        assert!(
            result.is_err(),
            "corrupt nearby discovery snapshot registry must not be replaced"
        );
        let body = tokio::fs::read_to_string(&paths.nearby_discovery_snapshots_file)
            .await
            .expect("corrupt registry should remain for diagnosis");
        assert_eq!(body, "{not-json");

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn remote_desktop_capability_snapshot_registry_loads_empty_missing_file() {
        let paths = test_paths("remote-desktop-capability-missing");
        let registry = load_remote_desktop_capability_snapshot_registry(&paths)
            .await
            .expect("missing capability snapshot registry should load as empty");
        assert!(registry.snapshots.is_empty());

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn remote_desktop_capability_snapshot_requires_bound_established_session() {
        let paths = test_paths("remote-desktop-capability-upsert");
        seed_session(&paths, "session-1", RuntimeSessionState::Bound).await;

        let registry = upsert_remote_desktop_capability_snapshot(
            &paths,
            RemoteDesktopCapabilitySnapshot::new(
                "session-1",
                "runtime-session-1",
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
        .await
        .expect("established session should accept observed capability snapshot");
        let snapshot = registry
            .get_for_session("session-1")
            .expect("snapshot should be indexed by session id");
        assert_eq!(snapshot.target_runtime_id, "runtime-session-1");
        assert_eq!(snapshot.sender_modes[0].id, "1920x1080@60");
        assert_eq!(snapshot.display_modes[0].width, 2056);

        let reloaded = load_remote_desktop_capability_snapshot_registry(&paths)
            .await
            .expect("capability snapshot registry should reload");
        assert_eq!(
            reloaded
                .get_for_session("session-1")
                .expect("snapshot should reload")
                .sender_modes[0]
                .fps,
            60
        );

        let runtime_mismatch = upsert_remote_desktop_capability_snapshot(
            &paths,
            RemoteDesktopCapabilitySnapshot::new(
                "session-1",
                "runtime-other",
                vec![RemoteDesktopObservedMode::new(
                    "1920x1080@60",
                    1920,
                    1080,
                    60,
                )],
                vec![],
            ),
        )
        .await;
        assert!(
            runtime_mismatch.is_err(),
            "capability snapshots must stay bound to the active runtime id"
        );

        let invalid_mode = upsert_remote_desktop_capability_snapshot(
            &paths,
            RemoteDesktopCapabilitySnapshot::new(
                "session-1",
                "runtime-session-1",
                vec![RemoteDesktopObservedMode::new("", 1920, 1080, 60)],
                vec![],
            ),
        )
        .await;
        assert!(
            invalid_mode.is_err(),
            "capability snapshots must reject malformed observed modes"
        );

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn corrupt_remote_desktop_capability_snapshot_registry_fails_closed() {
        let paths = test_paths("remote-desktop-capability-corrupt-registry");
        seed_session(&paths, "session-1", RuntimeSessionState::Bound).await;
        tokio::fs::write(&paths.remote_desktop_capabilities_file, b"{not-json")
            .await
            .expect("corrupt capability snapshot registry should be seeded");

        let result = upsert_remote_desktop_capability_snapshot(
            &paths,
            RemoteDesktopCapabilitySnapshot::new(
                "session-1",
                "runtime-session-1",
                vec![RemoteDesktopObservedMode::new(
                    "1920x1080@60",
                    1920,
                    1080,
                    60,
                )],
                vec![],
            ),
        )
        .await;
        assert!(
            result.is_err(),
            "corrupt capability snapshot registry must not be replaced"
        );
        let body = tokio::fs::read_to_string(&paths.remote_desktop_capabilities_file)
            .await
            .expect("corrupt registry should remain for diagnosis");
        assert_eq!(body, "{not-json");

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }
}
