use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ed25519_dalek::{Signer, SigningKey};
use getrandom::SysRng;
use rand_core::UnwrapErr;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use skybridge_core::{
    AuthSession, AuthState, CrossNetworkTransferId, EnrollmentStatus, FileTransferControlRequest,
    FileTransferControlRequestRegistry, FileTransferControlRequestStatus,
    FileTransferDestinationBinding, FileTransferSourceSnapshot, InboundFileTransferApprovalBinding,
    InboundFileTransferApprovalDecision, InboundFileTransferApprovalRegistry,
    InboundFileTransferApprovalRequest, InboundFileTransferApprovalStatus, LocalIdentityState,
    MAX_TRANSFER_BYTES, ManagedSessionControl, ManagedSessionControlRegistry,
    ManagedSessionDesiredState, NearbyDiscoveredDevice, NearbyDiscoverySnapshot,
    NearbyDiscoverySnapshotRegistry, NearbyDiscoveryTrustStatus, NebulaOAuthClient,
    ProtocolIdentityBinding, ProtocolSigningAlgorithm, RemoteDesktopCapabilitySnapshot,
    RemoteDesktopCapabilitySnapshotRegistry, RemoteDesktopControlAction,
    RemoteDesktopControlRequest, RemoteDesktopControlRequestPayload,
    RemoteDesktopControlRequestRegistry, RemoteDesktopControlRequestStatus,
    RemoteDesktopObservedMode, RemoteDesktopResolutionRequest, RuntimeAuthenticatedPeerObservation,
    RuntimeSelectedIceRouteObservation, RuntimeSessionKeepaliveStatus, RuntimeSessionRecord,
    RuntimeSessionState, RuntimeSessionTransportEvent, RustPqcIdentityMaterial, SessionReadiness,
    SessionRegistry, SignalingLifecycleEvent, SignalingLifecyclePhase, SignalingSessionHealth,
    make_runtime_id, mldsa_generate_keypair, mldsa_sign_detached, mldsa_verify_detached,
    remote_desktop_fps_request_supported, remote_desktop_resolution_preset_matches,
    should_refresh_access_token, xwing_generate_keypair,
};
use time::OffsetDateTime;
use tokio::fs;

use crate::runtime::{AgentPaths, restrict_dir_permissions};

static SESSION_REGISTRY_PROCESS_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
static MANAGED_SESSION_CONTROLS_PROCESS_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

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
    MlDsa87 {
        public_key: Vec<u8>,
        secret_key: Vec<u8>,
    },
}

impl ProtocolSigningKeyMaterial {
    pub fn algorithm(&self) -> ProtocolSigningAlgorithm {
        match self {
            Self::Ed25519(_) => ProtocolSigningAlgorithm::Ed25519,
            Self::MlDsa65 { .. } => ProtocolSigningAlgorithm::MlDsa65,
            Self::MlDsa87 { .. } => ProtocolSigningAlgorithm::MlDsa87,
        }
    }

    pub fn public_key_bytes(&self) -> Vec<u8> {
        match self {
            Self::Ed25519(signing_key) => signing_key.verifying_key().to_bytes().to_vec(),
            Self::MlDsa65 { public_key, .. } | Self::MlDsa87 { public_key, .. } => {
                public_key.clone()
            }
        }
    }

    pub fn sign(&self, payload: &[u8]) -> Result<Vec<u8>> {
        match self {
            Self::Ed25519(signing_key) => Ok(signing_key.sign(payload).to_bytes().to_vec()),
            Self::MlDsa65 { secret_key, .. } => {
                mldsa_sign_detached(ProtocolSigningAlgorithm::MlDsa65, payload, secret_key)
            }
            Self::MlDsa87 { secret_key, .. } => {
                mldsa_sign_detached(ProtocolSigningAlgorithm::MlDsa87, payload, secret_key)
            }
        }
    }

    pub fn ed25519_secret_key_bytes(&self) -> Option<Vec<u8>> {
        match self {
            Self::Ed25519(signing_key) => Some(signing_key.to_bytes().to_vec()),
            Self::MlDsa65 { .. } | Self::MlDsa87 { .. } => None,
        }
    }

    pub fn mldsa65_secret_key_bytes(&self) -> Option<Vec<u8>> {
        match self {
            Self::Ed25519(_) => None,
            Self::MlDsa65 { secret_key, .. } => Some(secret_key.clone()),
            Self::MlDsa87 { .. } => None,
        }
    }

    pub fn ml_dsa_secret_key_bytes(&self) -> Option<Vec<u8>> {
        match self {
            Self::Ed25519(_) => None,
            Self::MlDsa65 { secret_key, .. } | Self::MlDsa87 { secret_key, .. } => {
                Some(secret_key.clone())
            }
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
struct AuthSessionGeneration {
    schema_version: u32,
    generation: u64,
}

impl AuthSessionGeneration {
    const SCHEMA_VERSION: u32 = 1;

    fn next(self) -> Result<Self> {
        Ok(Self {
            schema_version: Self::SCHEMA_VERSION,
            generation: self
                .generation
                .checked_add(1)
                .ok_or_else(|| anyhow!("auth session generation overflow"))?,
        })
    }
}

impl Default for AuthSessionGeneration {
    fn default() -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            generation: 0,
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ManagedSessionRegistrationJournal {
    schema_version: u32,
    previous_session: Option<RuntimeSessionRecord>,
    previous_control: Option<ManagedSessionControl>,
    session: RuntimeSessionRecord,
    control: ManagedSessionControl,
}

impl ManagedSessionRegistrationJournal {
    const SCHEMA_VERSION: u32 = 3;
}

const LEGACY_MANAGED_SESSION_CONTROL_SCHEMA_VERSION: u32 = 2;
const LEGACY_MANAGED_SESSION_REGISTRATION_JOURNAL_SCHEMA_VERSION: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ManagedSessionRegistrationJournalState {
    RemovedDurably,
    RecoveryPending,
}

#[derive(Debug)]
pub struct ManagedSessionRegistrationCommit {
    pub sessions: SessionRegistry,
    pub controls: ManagedSessionControlRegistry,
    pub journal_state: ManagedSessionRegistrationJournalState,
}

/// Atomically observed state for one immutable managed-session registration.
/// A worker incarnation change remains `Current`; replacing the registration
/// under the same public session id becomes `Replaced`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManagedSessionRegistrationObservation {
    Current(Box<RuntimeSessionRecord>),
    Missing,
    Replaced,
}

pub async fn ensure_device_identity(paths: &AgentPaths) -> Result<DeviceIdentityMaterial> {
    ensure_identity_layout(paths).await?;
    let _identity_lock = acquire_protocol_identity_lock(paths).await?;
    let requested_algorithm = requested_protocol_signing_algorithm()?;
    let identity = crate::runtime::load_identity_state(paths)
        .await?
        .unwrap_or_else(|| LocalIdentityState::placeholder(current_hostname(), new_device_id()));
    let desired_algorithm =
        requested_algorithm.unwrap_or(identity.device.protocol_signing_algorithm);
    let stored_key = load_signing_key(paths).await?;
    if let Some(stored_key) = stored_key.as_ref() {
        validate_stored_signing_key_metadata(stored_key)?;
    }
    let signing_key = match stored_key {
        Some(stored_key) if stored_key.algorithm == desired_algorithm => {
            decode_signing_key(&stored_key)?
        }
        None => {
            let signing_key = load_or_generate_signing_key_slot(paths, desired_algorithm).await?;
            store_signing_key(paths, &signing_key).await?;
            signing_key
        }
        Some(stored_key) => {
            let previous_signing_key = decode_signing_key(&stored_key)?;
            store_signing_key_at(
                &signing_key_slot_file(paths, previous_signing_key.algorithm()),
                &previous_signing_key,
            )
            .await?;
            let signing_key = load_or_generate_signing_key_slot(paths, desired_algorithm).await?;
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
    ensure_rust_pqc_identity_for_algorithm(paths, ProtocolSigningAlgorithm::MlDsa65).await
}

pub async fn ensure_rust_pqc_identity_for_algorithm(
    paths: &AgentPaths,
    signing_algorithm: ProtocolSigningAlgorithm,
) -> Result<RustPqcIdentityMaterial> {
    if !signing_algorithm.is_ml_dsa() {
        bail!("Rust PQC identity requires an ML-DSA signing algorithm");
    }
    ensure_identity_layout(paths).await?;
    let _identity_lock = acquire_protocol_identity_lock(paths).await?;
    let protocol_signing = ensure_mldsa_signing_key(paths, signing_algorithm).await?;
    let mlkem_identity = ensure_kem_identity_key(paths, 0x0101).await?;
    let xwing_identity = ensure_kem_identity_key(paths, 0x0001).await?;
    #[cfg(feature = "q-periapt")]
    let qperiapt_identity = ensure_kem_identity_key(paths, 0x0011).await?;
    Ok(RustPqcIdentityMaterial {
        signing_algorithm,
        signing_public_key: protocol_signing.public_key_bytes(),
        signing_secret_key: protocol_signing
            .ml_dsa_secret_key_bytes()
            .ok_or_else(|| anyhow!("missing {signing_algorithm} signing secret key"))?,
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
    ensure_identity_layout(paths).await?;
    let _identity_lock = acquire_protocol_identity_lock(paths).await?;
    load_auth_session_unlocked(paths).await
}

pub async fn store_auth_session(paths: &AgentPaths, session: &AuthSession) -> Result<()> {
    ensure_identity_layout(paths).await?;
    let _identity_lock = acquire_protocol_identity_lock(paths).await?;
    store_auth_session_unlocked(paths, session).await
}

async fn store_auth_session_unlocked(paths: &AgentPaths, session: &AuthSession) -> Result<()> {
    advance_auth_session_generation_unlocked(paths).await?;
    write_json_atomic_private(&auth_session_file(paths), session).await?;
    let mut identity = crate::runtime::load_identity_state(paths)
        .await?
        .unwrap_or_else(|| LocalIdentityState::placeholder(current_hostname(), new_device_id()));
    identity.account_id = Some(session.user_identifier.clone());
    identity.auth_state = AuthState::LoggedIn;
    persist_identity(paths, &identity).await
}

pub async fn clear_auth_session(paths: &AgentPaths) -> Result<()> {
    ensure_identity_layout(paths).await?;
    let _identity_lock = acquire_protocol_identity_lock(paths).await?;
    advance_auth_session_generation_unlocked(paths).await?;
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
    let (session, expected_generation) = load_auth_session_snapshot(paths).await?;
    let Some(session) = session else {
        return Ok(None);
    };
    let Some(refresh_token) = session.refresh_token.as_deref() else {
        return Ok(Some(session));
    };
    if !should_refresh_access_token(&session.access_token, 300) {
        return Ok(Some(session));
    }
    let expected_session = session.clone();
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
    store_refreshed_auth_session_if_unchanged(
        paths,
        &expected_session,
        expected_generation,
        &refreshed,
    )
    .await?;
    Ok(Some(refreshed))
}

async fn store_refreshed_auth_session_if_unchanged(
    paths: &AgentPaths,
    expected_session: &AuthSession,
    expected_generation: u64,
    refreshed: &AuthSession,
) -> Result<()> {
    ensure_identity_layout(paths).await?;
    let _identity_lock = acquire_protocol_identity_lock(paths).await?;
    let current = load_auth_session_unlocked(paths).await?;
    let current_generation = load_auth_session_generation_unlocked(paths).await?;
    if current.as_ref() != Some(expected_session)
        || current_generation.generation != expected_generation
    {
        bail!("auth session changed while token refresh was in flight");
    }
    store_auth_session_unlocked(paths, refreshed).await
}

pub async fn update_enrollment_status(
    paths: &AgentPaths,
    status: EnrollmentStatus,
    device_name: Option<&str>,
) -> Result<LocalIdentityState> {
    ensure_identity_layout(paths).await?;
    let _identity_lock = acquire_protocol_identity_lock(paths).await?;
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

async fn load_auth_session_unlocked(paths: &AgentPaths) -> Result<Option<AuthSession>> {
    load_json::<AuthSession>(&auth_session_file(paths)).await
}

async fn load_auth_session_snapshot(paths: &AgentPaths) -> Result<(Option<AuthSession>, u64)> {
    ensure_identity_layout(paths).await?;
    let _identity_lock = acquire_protocol_identity_lock(paths).await?;
    let session = load_auth_session_unlocked(paths).await?;
    let generation = load_auth_session_generation_unlocked(paths).await?;
    Ok((session, generation.generation))
}

async fn load_auth_session_generation_unlocked(
    paths: &AgentPaths,
) -> Result<AuthSessionGeneration> {
    let generation = load_json::<AuthSessionGeneration>(&auth_session_generation_file(paths))
        .await?
        .unwrap_or_default();
    if generation.schema_version != AuthSessionGeneration::SCHEMA_VERSION {
        bail!(
            "unsupported auth session generation schema version {}; expected {}",
            generation.schema_version,
            AuthSessionGeneration::SCHEMA_VERSION
        );
    }
    Ok(generation)
}

async fn advance_auth_session_generation_unlocked(
    paths: &AgentPaths,
) -> Result<AuthSessionGeneration> {
    let next = load_auth_session_generation_unlocked(paths).await?.next()?;
    write_json_atomic_private(&auth_session_generation_file(paths), &next).await?;
    Ok(next)
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

pub async fn load_managed_session_controls(
    paths: &AgentPaths,
) -> Result<ManagedSessionControlRegistry> {
    ensure_identity_layout(paths).await?;
    let registry_path = session_controls_file(paths);
    let lock_path = managed_session_controls_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_managed_session_controls_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, false)?;
        load_managed_session_controls_unlocked(&registry_path)
    })
    .await
    .context("managed session controls read task panicked")?
}

/// Reads the runtime record and immutable registration authority under the
/// same shared locks used by registration, worker handoff, and disconnect.
/// This prevents a caller from combining a runtime from one registration with
/// control authority from another registration that reused the session id.
pub async fn observe_managed_session_registration(
    paths: &AgentPaths,
    session_id: &str,
    expected_registration_id: &str,
) -> Result<ManagedSessionRegistrationObservation> {
    validate_registration_id(expected_registration_id)
        .context("expected managed registration id is invalid")?;
    ensure_identity_layout(paths).await?;
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let control_registry_path = session_controls_file(paths);
    let control_registry_lock_path = managed_session_controls_lock_file(paths);
    let session_id = session_id.to_owned();
    let expected_registration_id = expected_registration_id.to_owned();

    tokio::task::spawn_blocking(move || {
        let _session_process_guard = lock_session_registry_process()?;
        let _control_process_guard = lock_managed_session_controls_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, false)?;
        let _control_file_lock = lock_session_registry_file(&control_registry_lock_path, false)?;
        let sessions = load_session_registry_unlocked(&session_registry_path)?;
        let controls = load_managed_session_controls_unlocked(&control_registry_path)?;
        let session = sessions.get(&session_id);
        let control = controls.get(&session_id);

        let Some(control) = control else {
            return Ok(if session.is_some() {
                ManagedSessionRegistrationObservation::Replaced
            } else {
                ManagedSessionRegistrationObservation::Missing
            });
        };
        if control.registration_id != expected_registration_id {
            return Ok(ManagedSessionRegistrationObservation::Replaced);
        }
        if control.desired_state != ManagedSessionDesiredState::Active {
            bail!("managed registration no longer owns active control authority");
        }
        let session = session
            .ok_or_else(|| anyhow!("managed registration has no matching runtime session"))?;
        if control.target_runtime_id != session.runtime_id {
            bail!("managed registration control/runtime incarnation mismatch");
        }
        Ok(ManagedSessionRegistrationObservation::Current(Box::new(
            session.clone(),
        )))
    })
    .await
    .context("managed session registration observation task panicked")?
}

/// A short-lived, cross-process read permit for one managed runtime
/// incarnation. The shared registry locks are held for the permit lifetime, so
/// any replacement/stop mutation (which takes the same locks exclusively)
/// linearizes either before permit acquisition or after permit release.
///
/// Callers must scope this permit to one external side effect. It must never be
/// retained for an entire worker lifetime; operation-specific timeouts belong
/// at boundaries whose cancellation semantics are actually guaranteed.
pub(crate) struct RuntimeIncarnationPermit {
    _session_registry_lock: std::fs::File,
    _control_registry_lock: std::fs::File,
    session_registry_path: PathBuf,
    control_registry_path: PathBuf,
    session_id: String,
    expected_runtime_id: String,
    expected_registration_id: Option<String>,
}

impl RuntimeIncarnationPermit {
    pub(crate) async fn validate_after_effect(self: &std::sync::Arc<Self>) -> Result<()> {
        let permit = std::sync::Arc::clone(self);
        tokio::task::spawn_blocking(move || permit.validate_current_unlocked())
            .await
            .context("runtime incarnation permit validation task panicked")?
    }

    fn validate_current_unlocked(&self) -> Result<()> {
        validate_runtime_incarnation_unlocked(
            &self.session_registry_path,
            &self.control_registry_path,
            &self.session_id,
            &self.expected_runtime_id,
            self.expected_registration_id.as_deref(),
        )
    }
}

pub(crate) async fn acquire_runtime_incarnation_permit(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
) -> Result<std::sync::Arc<RuntimeIncarnationPermit>> {
    acquire_runtime_incarnation_permit_with_registration(
        paths,
        session_id,
        expected_runtime_id,
        None,
    )
    .await
}

async fn acquire_runtime_incarnation_permit_with_registration(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    expected_registration_id: Option<&str>,
) -> Result<std::sync::Arc<RuntimeIncarnationPermit>> {
    if let Some(registration_id) = expected_registration_id {
        validate_registration_id(registration_id)
            .context("expected managed registration id is invalid")?;
    }
    ensure_identity_layout(paths).await?;
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let control_registry_path = session_controls_file(paths);
    let control_registry_lock_path = managed_session_controls_lock_file(paths);
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    let expected_registration_id = expected_registration_id.map(str::to_owned);

    tokio::task::spawn_blocking(move || {
        // This order matches all combined session/control mutations.
        let session_lock = lock_session_registry_file(&session_registry_lock_path, false)?;
        let control_lock = lock_session_registry_file(&control_registry_lock_path, false)?;
        validate_runtime_incarnation_unlocked(
            &session_registry_path,
            &control_registry_path,
            &session_id,
            &expected_runtime_id,
            expected_registration_id.as_deref(),
        )?;
        Ok(std::sync::Arc::new(RuntimeIncarnationPermit {
            _session_registry_lock: session_lock,
            _control_registry_lock: control_lock,
            session_registry_path,
            control_registry_path,
            session_id,
            expected_runtime_id,
            expected_registration_id,
        }))
    })
    .await
    .context("runtime incarnation permit acquisition task panicked")?
}

/// A handshake receipt whose registry authority remains held until the value
/// is dropped. Callers should keep this value alive through their synchronous
/// success serialization/output so a replacement or disconnect cannot
/// linearize between final verification and the reported success.
pub struct VerifiedManagedHandshakeReceipt {
    pub session_id: String,
    pub runtime_id: String,
    pub remote_device_id: String,
    pub remote_device_name: Option<String>,
    pub remote_protocol_public_key_fingerprint: String,
    pub negotiated_suite: String,
    pub authenticated_peer: RuntimeAuthenticatedPeerObservation,
    pub selected_ice_route: RuntimeSelectedIceRouteObservation,
    _permit: std::sync::Arc<RuntimeIncarnationPermit>,
}

struct VerifiedManagedHandshakeEvidence {
    runtime_id: String,
    remote_device_id: String,
    remote_protocol_public_key_fingerprint: String,
    negotiated_suite: String,
    authenticated_peer: RuntimeAuthenticatedPeerObservation,
    selected_ice_route: RuntimeSelectedIceRouteObservation,
}

pub async fn verify_managed_handshake_receipt(
    paths: &AgentPaths,
    session_id: &str,
    expected_registration_id: &str,
    expected_runtime_id: &str,
    expected_negotiated_suite: &str,
) -> Result<VerifiedManagedHandshakeReceipt> {
    let permit = acquire_runtime_incarnation_permit_with_registration(
        paths,
        session_id,
        expected_runtime_id,
        Some(expected_registration_id),
    )
    .await?;
    let session_registry_path = permit.session_registry_path.clone();
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    let expected_negotiated_suite = expected_negotiated_suite.to_owned();
    let receipt = tokio::task::spawn_blocking(move || {
        let sessions = load_session_registry_unlocked(&session_registry_path)?;
        let session = sessions
            .get(&session_id)
            .ok_or_else(|| anyhow!("managed handshake receipt has no runtime session"))?;
        if session.runtime_id != expected_runtime_id || !session.is_active() {
            bail!("managed handshake receipt no longer belongs to an active runtime incarnation");
        }
        let negotiated_suite = match &session.readiness {
            SessionReadiness::HandshakeComplete {
                session_id: receipt_session_id,
                negotiated_suite,
            } if receipt_session_id == &session_id
                && negotiated_suite == &expected_negotiated_suite =>
            {
                negotiated_suite.clone()
            }
            SessionReadiness::HandshakeComplete { .. } => {
                bail!("managed handshake receipt changed before success reporting")
            }
            SessionReadiness::Idle | SessionReadiness::TransportReady { .. } => {
                bail!("managed handshake is not complete at success reporting")
            }
        };
        let remote_device_id = session
            .remote_device_id
            .clone()
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| {
                anyhow!("managed handshake receipt is missing remote device identity")
            })?;
        let remote_protocol_public_key_fingerprint = session
            .remote_protocol_public_key_fingerprint
            .clone()
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| anyhow!("managed handshake receipt is missing peer fingerprint"))?;
        let authenticated_peer = session.authenticated_peer.clone().ok_or_else(|| {
            anyhow!("managed connection receipt is missing authenticated peer capabilities")
        })?;
        if authenticated_peer.device_id != remote_device_id {
            bail!("managed connection receipt peer observation changed identity");
        }
        let selected_ice_route = session.selected_ice_route.clone().ok_or_else(|| {
            anyhow!("managed connection receipt is missing selected ICE route evidence")
        })?;
        let handshake_completed_at = session.handshake_completed_at.ok_or_else(|| {
            anyhow!("managed connection receipt is missing handshake completion time")
        })?;
        if authenticated_peer.observed_at < handshake_completed_at
            || selected_ice_route.observed_at < handshake_completed_at
        {
            bail!("managed connection receipt reused evidence from an earlier handshake");
        }
        let now = OffsetDateTime::now_utc();
        let heartbeat_age = now - authenticated_peer.observed_at;
        let route_age = now - selected_ice_route.observed_at;
        let freshness = time::Duration::seconds(15);
        if heartbeat_age.is_negative() || heartbeat_age > freshness {
            bail!("managed connection receipt authenticated peer observation is stale");
        }
        if route_age.is_negative() || route_age > freshness {
            bail!("managed connection receipt selected ICE route observation is stale");
        }
        Ok(VerifiedManagedHandshakeEvidence {
            runtime_id: session.runtime_id.clone(),
            remote_device_id,
            remote_protocol_public_key_fingerprint,
            negotiated_suite,
            authenticated_peer,
            selected_ice_route,
        })
    })
    .await
    .context("managed handshake receipt verification task panicked")??;

    Ok(VerifiedManagedHandshakeReceipt {
        session_id: permit.session_id.clone(),
        runtime_id: receipt.runtime_id,
        remote_device_id: receipt.remote_device_id,
        remote_device_name: Some(receipt.authenticated_peer.device_name.clone()),
        remote_protocol_public_key_fingerprint: receipt.remote_protocol_public_key_fingerprint,
        negotiated_suite: receipt.negotiated_suite,
        authenticated_peer: receipt.authenticated_peer,
        selected_ice_route: receipt.selected_ice_route,
        _permit: permit,
    })
}

fn validate_runtime_incarnation_unlocked(
    session_registry_path: &Path,
    control_registry_path: &Path,
    session_id: &str,
    expected_runtime_id: &str,
    expected_registration_id: Option<&str>,
) -> Result<()> {
    let controls = load_managed_session_controls_unlocked(control_registry_path)?;
    let control = controls
        .get(session_id)
        .ok_or_else(|| anyhow!("managed runtime incarnation has no control authority"))?;
    if control.target_runtime_id != expected_runtime_id
        || control.desired_state != ManagedSessionDesiredState::Active
    {
        bail!("managed runtime incarnation no longer owns active control authority");
    }
    if expected_registration_id.is_some_and(|expected| control.registration_id != expected) {
        bail!("managed runtime incarnation belongs to a replacement registration");
    }

    let sessions = load_session_registry_unlocked(session_registry_path)?;
    let session = sessions
        .get(session_id)
        .ok_or_else(|| anyhow!("managed runtime incarnation has no runtime session"))?;
    if session.runtime_id != expected_runtime_id || !session.is_active() {
        bail!("managed runtime incarnation no longer owns an active runtime session");
    }
    Ok(())
}

pub async fn upsert_managed_session_control(
    paths: &AgentPaths,
    mut control: ManagedSessionControl,
) -> Result<ManagedSessionControlRegistry> {
    ensure_identity_layout(paths).await?;
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let control_registry_path = session_controls_file(paths);
    let control_registry_lock_path = managed_session_controls_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _session_process_guard = lock_session_registry_process()?;
        let _control_process_guard = lock_managed_session_controls_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, false)?;
        let session_registry = load_session_registry_unlocked(&session_registry_path)?;
        let session = session_registry.get(&control.session_id).ok_or_else(|| {
            anyhow!("managed session control requires a matching runtime session")
        })?;
        if session.role != control.role
            || session.source != control.source
            || session.local_device_id != control.local_device_id
            || session.signaling_server_origin != control.signaling_server_origin
        {
            bail!("managed session control metadata does not match its runtime session");
        }
        control.target_runtime_id = session.runtime_id.clone();
        control.updated_at = OffsetDateTime::now_utc();
        let _control_file_lock = lock_session_registry_file(&control_registry_lock_path, true)?;
        let mut registry = load_managed_session_controls_unlocked(&control_registry_path)?;
        registry.insert(control)?;
        store_managed_session_controls_unlocked(&control_registry_path, &registry)?;
        Ok(registry)
    })
    .await
    .context("managed session control mutation task panicked")?
}

/// Registers the runtime record and its control authority as one journaled
/// operation. Both registry locks remain held until both durable files and the
/// journal commit marker have been synchronized.
pub async fn register_managed_session(
    paths: &AgentPaths,
    session: RuntimeSessionRecord,
    mut control: ManagedSessionControl,
) -> Result<ManagedSessionRegistrationCommit> {
    ensure_identity_layout(paths).await?;
    validate_managed_session_registration(&session, &control, true)?;
    control.target_runtime_id = session.runtime_id.clone();
    control.schema_version = ManagedSessionControl::SCHEMA_VERSION;
    control.updated_at = OffsetDateTime::now_utc();

    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let control_registry_path = session_controls_file(paths);
    let control_registry_lock_path = managed_session_controls_lock_file(paths);
    let journal_path = managed_session_registration_journal_file(paths);
    tokio::task::spawn_blocking(move || {
        let _session_process_guard = lock_session_registry_process()?;
        let _control_process_guard = lock_managed_session_controls_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, true)?;
        let _control_file_lock = lock_session_registry_file(&control_registry_lock_path, true)?;

        recover_registration_journal_unlocked(
            &session_registry_path,
            &control_registry_path,
            &journal_path,
        )?;
        let mut sessions = load_session_registry_unlocked(&session_registry_path)?;
        let mut controls = load_managed_session_controls_unlocked(&control_registry_path)?;
        let previous_session = sessions.get(&session.session_id).cloned();
        let previous_control = controls.get(&control.session_id).cloned();
        // Preflight both bounded registries before publishing the intent.
        sessions.insert(session.clone())?;
        controls.insert(control.clone())?;
        let journal = ManagedSessionRegistrationJournal {
            schema_version: ManagedSessionRegistrationJournal::SCHEMA_VERSION,
            previous_session,
            previous_control,
            session,
            control,
        };
        commit_registration_unlocked(
            &session_registry_path,
            &control_registry_path,
            &journal_path,
            &journal,
            sessions,
            controls,
            remove_private_file_durably,
        )
    })
    .await
    .context("managed session registration task panicked")?
}

/// Repairs only fail-closed registry asymmetry before the supervisor starts.
/// A journaled registration is completed; unjournaled active orphans are
/// disconnected and orphaned controls are removed.
pub(crate) async fn recover_managed_session_state(
    paths: &AgentPaths,
) -> Result<ManagedSessionRegistrationJournalState> {
    ensure_identity_layout(paths).await?;
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let control_registry_path = session_controls_file(paths);
    let control_registry_lock_path = managed_session_controls_lock_file(paths);
    let journal_path = managed_session_registration_journal_file(paths);
    tokio::task::spawn_blocking(move || {
        let _session_process_guard = lock_session_registry_process()?;
        let _control_process_guard = lock_managed_session_controls_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, true)?;
        let _control_file_lock = lock_session_registry_file(&control_registry_lock_path, true)?;

        migrate_legacy_managed_session_controls_unlocked(&control_registry_path)?;
        discard_legacy_registration_journal_unlocked(&journal_path)?;
        let journal_state = recover_registration_journal_unlocked(
            &session_registry_path,
            &control_registry_path,
            &journal_path,
        )?;
        let mut sessions = load_session_registry_unlocked(&session_registry_path)?;
        let mut controls = load_managed_session_controls_unlocked(&control_registry_path)?;
        let orphaned_active_sessions = sessions
            .sessions
            .values()
            .filter(|session| {
                session.is_active()
                    && !controls.get(&session.session_id).is_some_and(|control| {
                        managed_session_registration_matches(session, control)
                    })
            })
            .map(|session| session.session_id.clone())
            .collect::<Vec<_>>();
        for session_id in orphaned_active_sessions {
            if !sessions.mark_disconnected(
                &session_id,
                Some("orphaned managed runtime recovered at agent startup".to_owned()),
            ) {
                bail!("orphaned managed runtime disappeared during startup recovery");
            }
        }
        controls.sessions.retain(|session_id, control| {
            sessions.get(session_id).is_some_and(|session| {
                session.is_active() && managed_session_registration_matches(session, control)
            })
        });

        // Persist the fail-closed runtime state first. A crash before the
        // control cleanup cannot make a terminal runtime runnable again.
        store_session_registry_unlocked(&session_registry_path, &sessions)?;
        store_managed_session_controls_unlocked(&control_registry_path, &controls)?;
        Ok(journal_state)
    })
    .await
    .context("managed session startup recovery task panicked")?
}

fn recover_registration_journal_unlocked(
    session_registry_path: &Path,
    control_registry_path: &Path,
    journal_path: &Path,
) -> Result<ManagedSessionRegistrationJournalState> {
    let Some(journal) = load_registration_journal_unlocked(journal_path)? else {
        return Ok(ManagedSessionRegistrationJournalState::RemovedDurably);
    };
    if journal.schema_version != ManagedSessionRegistrationJournal::SCHEMA_VERSION {
        bail!(
            "unsupported managed session registration journal schema version {}; expected {}",
            journal.schema_version,
            ManagedSessionRegistrationJournal::SCHEMA_VERSION
        );
    }
    validate_managed_session_registration(&journal.session, &journal.control, false)?;
    let mut sessions = load_session_registry_unlocked(session_registry_path)?;
    let mut controls = load_managed_session_controls_unlocked(control_registry_path)?;
    if !registration_entry_is_replayable(
        sessions.get(&journal.session.session_id),
        journal.previous_session.as_ref(),
        &journal.session,
    ) {
        bail!("managed session registration journal conflicts with persisted runtime session");
    }
    if !registration_entry_is_replayable(
        controls.get(&journal.control.session_id),
        journal.previous_control.as_ref(),
        &journal.control,
    ) {
        bail!("managed session registration journal conflicts with persisted control authority");
    }
    sessions.insert(journal.session)?;
    controls.insert(journal.control)?;
    store_session_registry_unlocked(session_registry_path, &sessions)?;
    store_managed_session_controls_unlocked(control_registry_path, &controls)?;
    Ok(match remove_private_file_durably(journal_path) {
        Ok(()) => ManagedSessionRegistrationJournalState::RemovedDurably,
        Err(_) => ManagedSessionRegistrationJournalState::RecoveryPending,
    })
}

/// Schema-v2 registration journals predate immutable registration ownership.
/// Replaying one would mint or overwrite live authority from an ownerless
/// record. Recovery therefore durably discards only that known legacy schema;
/// any partially persisted session/control pair is then handled by the normal
/// fail-closed orphan reconciliation in `recover_managed_session_state`.
fn discard_legacy_registration_journal_unlocked(path: &Path) -> Result<()> {
    let Some(journal) = load_registration_journal_unlocked(path)? else {
        return Ok(());
    };
    if journal.schema_version == LEGACY_MANAGED_SESSION_REGISTRATION_JOURNAL_SCHEMA_VERSION {
        remove_private_file_durably(path)
            .context("failed to discard ownerless legacy managed session registration journal")?;
    }
    Ok(())
}

fn registration_entry_is_replayable<T: PartialEq>(
    current: Option<&T>,
    previous: Option<&T>,
    committed: &T,
) -> bool {
    current == Some(committed) || current == previous
}

fn commit_registration_unlocked<C>(
    session_registry_path: &Path,
    control_registry_path: &Path,
    journal_path: &Path,
    journal: &ManagedSessionRegistrationJournal,
    sessions: SessionRegistry,
    controls: ManagedSessionControlRegistry,
    cleanup_journal: C,
) -> Result<ManagedSessionRegistrationCommit>
where
    C: FnOnce(&Path) -> Result<()>,
{
    let body = serde_json::to_vec_pretty(journal)
        .context("failed to encode managed session registration journal")?;
    write_private_file_atomically(journal_path, &body)?;
    store_session_registry_unlocked(session_registry_path, &sessions)?;
    store_managed_session_controls_unlocked(control_registry_path, &controls)?;
    let journal_state = match cleanup_journal(journal_path) {
        Ok(()) => ManagedSessionRegistrationJournalState::RemovedDurably,
        Err(_) => ManagedSessionRegistrationJournalState::RecoveryPending,
    };
    Ok(ManagedSessionRegistrationCommit {
        sessions,
        controls,
        journal_state,
    })
}

fn load_registration_journal_unlocked(
    path: &Path,
) -> Result<Option<ManagedSessionRegistrationJournal>> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            bail!("managed session registration journal is not a regular file")
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| {
                format!(
                    "failed to inspect managed session registration journal {}",
                    path.display()
                )
            });
        }
    }
    let body = std::fs::read_to_string(path).with_context(|| {
        format!(
            "failed to read managed session registration journal {}",
            path.display()
        )
    })?;
    serde_json::from_str(&body)
        .with_context(|| {
            format!(
                "failed to decode managed session registration journal {}",
                path.display()
            )
        })
        .map(Some)
}

fn validate_managed_session_registration(
    session: &RuntimeSessionRecord,
    control: &ManagedSessionControl,
    allow_unbound_control: bool,
) -> Result<()> {
    if !session.is_active() {
        bail!("managed session registration requires an active runtime session");
    }
    if control.schema_version != ManagedSessionControl::SCHEMA_VERSION
        || control.desired_state != ManagedSessionDesiredState::Active
    {
        bail!("managed session registration requires an active current-schema control");
    }
    validate_registration_id(&control.registration_id)
        .context("managed session registration id is invalid")?;
    if !allow_unbound_control && control.target_runtime_id != session.runtime_id {
        bail!("managed session registration control is not bound to its runtime incarnation");
    }
    if allow_unbound_control
        && !control.target_runtime_id.is_empty()
        && control.target_runtime_id != session.runtime_id
    {
        bail!("managed session registration control targets another runtime incarnation");
    }
    if session.session_id != control.session_id
        || session.role != control.role
        || session.source != control.source
        || session.local_device_id != control.local_device_id
        || session.signaling_server_origin != control.signaling_server_origin
    {
        bail!("managed session registration metadata does not match");
    }
    Ok(())
}

fn managed_session_registration_matches(
    session: &RuntimeSessionRecord,
    control: &ManagedSessionControl,
) -> bool {
    control.desired_state == ManagedSessionDesiredState::Active
        && control.target_runtime_id == session.runtime_id
        && session.session_id == control.session_id
        && session.role == control.role
        && session.source == control.source
        && session.local_device_id == control.local_device_id
        && session.signaling_server_origin == control.signaling_server_origin
}

fn validate_registration_id(registration_id: &str) -> Result<()> {
    let parsed =
        uuid::Uuid::parse_str(registration_id).context("managed registration id must be a UUID")?;
    if parsed.get_version_num() != 7 || parsed.hyphenated().to_string() != registration_id {
        bail!("managed registration id must be a canonical UUIDv7");
    }
    Ok(())
}

/// Starts one fresh managed-worker incarnation and returns its immutable
/// control binding. All persisted transport/readiness evidence belongs to the
/// previous incarnation and is cleared before network work begins.
pub(crate) async fn begin_managed_session_incarnation(
    paths: &AgentPaths,
    expected_control: &ManagedSessionControl,
) -> Result<ManagedSessionControl> {
    ensure_identity_layout(paths).await?;
    let expected_control = expected_control.clone();
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let control_registry_path = session_controls_file(paths);
    let control_registry_lock_path = managed_session_controls_lock_file(paths);
    let remote_registry_path = remote_desktop_request_registry_file(paths);
    let remote_registry_lock_path = remote_desktop_request_registry_lock_file(paths);
    let file_registry_path = file_transfer_request_registry_file(paths);
    let file_registry_lock_path = file_transfer_request_registry_lock_file(paths);
    let inbound_approval_path = inbound_file_transfer_approval_registry_file(paths);
    let inbound_approval_lock_path = inbound_file_transfer_approval_registry_lock_file(paths);

    tokio::task::spawn_blocking(move || {
        let _session_process_guard = lock_session_registry_process()?;
        let _control_process_guard = lock_managed_session_controls_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, true)?;
        let _control_file_lock = lock_session_registry_file(&control_registry_lock_path, true)?;
        let _remote_file_lock = lock_session_registry_file(&remote_registry_lock_path, true)?;
        let _file_transfer_file_lock = lock_session_registry_file(&file_registry_lock_path, true)?;
        let _inbound_approval_file_lock =
            lock_session_registry_file(&inbound_approval_lock_path, true)?;

        let mut sessions = load_session_registry_unlocked(&session_registry_path)?;
        let mut controls = load_managed_session_controls_unlocked(&control_registry_path)?;
        let mut remote_requests =
            load_remote_desktop_request_registry_unlocked(&remote_registry_path)?;
        let mut file_requests = load_file_transfer_request_registry_unlocked(&file_registry_path)?;
        let mut inbound_approvals =
            load_inbound_file_transfer_approval_registry_unlocked(&inbound_approval_path)?;

        let current_control = controls
            .get(&expected_control.session_id)
            .ok_or_else(|| anyhow!("managed session control disappeared before worker start"))?;
        if current_control != &expected_control {
            bail!("managed session control was replaced before worker start");
        }
        let record = sessions
            .sessions
            .get_mut(&expected_control.session_id)
            .ok_or_else(|| anyhow!("managed session runtime disappeared before worker start"))?;
        if record.role != expected_control.role
            || record.source != expected_control.source
            || record.local_device_id != expected_control.local_device_id
            || record.signaling_server_origin != expected_control.signaling_server_origin
        {
            bail!("managed session runtime metadata mismatched its control before worker start");
        }

        let new_runtime_id = make_runtime_id(&expected_control.session_id);
        let now = OffsetDateTime::now_utc();
        for request in file_requests.requests.values_mut().filter(|request| {
            request.session_id == expected_control.session_id && !request.is_terminal()
        }) {
            match request.status {
                FileTransferControlRequestStatus::PendingAgentObservation => {
                    request.status = FileTransferControlRequestStatus::AgentRejected;
                    request.failure_reason =
                        Some("managed runtime ended before agent observation".to_owned());
                    request.updated_at = now;
                }
                FileTransferControlRequestStatus::AgentObserved
                | FileTransferControlRequestStatus::TransferInProgress => {
                    request
                        .mark_transfer_failed("managed runtime ended before verified receipt", now);
                }
                FileTransferControlRequestStatus::TransferCompleted
                | FileTransferControlRequestStatus::TransferFailed
                | FileTransferControlRequestStatus::AgentRejected => {}
            }
        }
        for request in remote_requests.requests.values_mut().filter(|request| {
            request.session_id == expected_control.session_id
                && request.status == RemoteDesktopControlRequestStatus::PendingAgentObservation
        }) {
            request.status = RemoteDesktopControlRequestStatus::AgentRejected;
            request.updated_at = now;
        }
        expire_inbound_file_approvals_for_incarnation(
            &mut inbound_approvals,
            &expected_control.session_id,
            None,
            now,
        )?;

        record.runtime_id = new_runtime_id.clone();
        record.state = RuntimeSessionState::Connecting;
        record.lifecycle_phase = SignalingLifecyclePhase::Idle;
        record.signaling_health = SignalingSessionHealth::Healthy;
        record.signaling_backend = None;
        record.signaling_generation = None;
        record.readiness = SessionReadiness::Idle;
        record.last_established_readiness = None;
        record.transport_preserved = false;
        record.keepalive = RuntimeSessionKeepaliveStatus::default();
        record.authenticated_peer = None;
        record.selected_ice_route = None;
        record.last_error = None;
        record.last_transport_error = None;
        record.transport_ready_at = None;
        record.handshake_completed_at = None;
        record.created_at = now;
        record.updated_at = now;
        record.closed_at = None;

        let mut next_control = expected_control;
        next_control.schema_version = ManagedSessionControl::SCHEMA_VERSION;
        next_control.target_runtime_id = new_runtime_id;
        next_control.updated_at = now;
        controls.insert(next_control.clone())?;

        // Persist requests first so no old claimed work can regain authority if
        // a later registry write fails. A partial multi-file write remains
        // fail-closed because session/control runtime ids must match to spawn.
        store_file_transfer_request_registry_unlocked(&file_registry_path, &file_requests)?;
        store_inbound_file_transfer_approval_registry_unlocked(
            &inbound_approval_path,
            &inbound_approvals,
        )?;
        store_remote_desktop_request_registry_unlocked(&remote_registry_path, &remote_requests)?;
        store_session_registry_unlocked(&session_registry_path, &sessions)?;
        store_managed_session_controls_unlocked(&control_registry_path, &controls)?;
        Ok(next_control)
    })
    .await
    .context("managed session incarnation start task panicked")?
}

pub(crate) async fn finish_managed_session_incarnation_requests(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
) -> Result<()> {
    ensure_identity_layout(paths).await?;
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    let remote_registry_path = remote_desktop_request_registry_file(paths);
    let remote_registry_lock_path = remote_desktop_request_registry_lock_file(paths);
    let file_registry_path = file_transfer_request_registry_file(paths);
    let file_registry_lock_path = file_transfer_request_registry_lock_file(paths);
    let inbound_approval_path = inbound_file_transfer_approval_registry_file(paths);
    let inbound_approval_lock_path = inbound_file_transfer_approval_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _remote_file_lock = lock_session_registry_file(&remote_registry_lock_path, true)?;
        let _file_transfer_file_lock = lock_session_registry_file(&file_registry_lock_path, true)?;
        let _inbound_approval_file_lock =
            lock_session_registry_file(&inbound_approval_lock_path, true)?;
        let mut remote_requests =
            load_remote_desktop_request_registry_unlocked(&remote_registry_path)?;
        let mut file_requests = load_file_transfer_request_registry_unlocked(&file_registry_path)?;
        let mut inbound_approvals =
            load_inbound_file_transfer_approval_registry_unlocked(&inbound_approval_path)?;
        let now = OffsetDateTime::now_utc();

        for request in file_requests.requests.values_mut().filter(|request| {
            request.session_id == session_id
                && request.target_runtime_id == expected_runtime_id
                && !request.is_terminal()
        }) {
            match request.status {
                FileTransferControlRequestStatus::PendingAgentObservation => {
                    request.status = FileTransferControlRequestStatus::AgentRejected;
                    request.failure_reason =
                        Some("managed runtime ended before agent observation".to_owned());
                    request.updated_at = now;
                }
                FileTransferControlRequestStatus::AgentObserved
                | FileTransferControlRequestStatus::TransferInProgress => request
                    .mark_transfer_failed("managed runtime ended before verified receipt", now),
                FileTransferControlRequestStatus::TransferCompleted
                | FileTransferControlRequestStatus::TransferFailed
                | FileTransferControlRequestStatus::AgentRejected => {}
            }
        }
        for request in remote_requests.requests.values_mut().filter(|request| {
            request.session_id == session_id
                && request.target_runtime_id == expected_runtime_id
                && request.status == RemoteDesktopControlRequestStatus::PendingAgentObservation
        }) {
            request.status = RemoteDesktopControlRequestStatus::AgentRejected;
            request.updated_at = now;
        }
        expire_inbound_file_approvals_for_incarnation(
            &mut inbound_approvals,
            &session_id,
            Some(&expected_runtime_id),
            now,
        )?;
        store_file_transfer_request_registry_unlocked(&file_registry_path, &file_requests)?;
        store_inbound_file_transfer_approval_registry_unlocked(
            &inbound_approval_path,
            &inbound_approvals,
        )?;
        store_remote_desktop_request_registry_unlocked(&remote_registry_path, &remote_requests)?;
        Ok(())
    })
    .await
    .context("managed session request finalization task panicked")?
}

pub async fn remove_managed_session_control(
    paths: &AgentPaths,
    session_id: &str,
) -> Result<ManagedSessionControlRegistry> {
    let session_id = session_id.to_owned();
    mutate_managed_session_controls(paths, move |registry| {
        registry.remove(&session_id);
        registry.clone()
    })
    .await
}

/// Operator-visible disconnect transaction.
///
/// A live control is first persisted as `Stopped`, then the runtime record is
/// marked disconnected, and only after both writes succeed is the control
/// removed. Any failure after the first write therefore leaves a durable
/// stopped retry anchor and cannot respawn the worker as active.
pub async fn disconnect_managed_session(
    paths: &AgentPaths,
    session_id: &str,
    reason: Option<String>,
) -> Result<SessionRegistry> {
    let outcome = disconnect_managed_session_transaction(
        paths,
        session_id,
        ManagedSessionDisconnectOwner::Any,
        reason,
    )
    .await?;
    debug_assert!(outcome.matched_owner);
    Ok(outcome.sessions)
}

/// Disconnects only the exact managed runtime incarnation supplied by the caller.
///
/// Session and control registries remain locked for the entire stop/disconnect/remove
/// transaction. A stale CLI attempt therefore cannot disconnect a replacement that
/// reused the same public session id.
pub async fn disconnect_managed_session_if_runtime(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    reason: Option<String>,
) -> Result<bool> {
    if expected_runtime_id.trim().is_empty() {
        bail!("expected managed runtime incarnation must not be empty");
    }
    disconnect_managed_session_transaction(
        paths,
        session_id,
        ManagedSessionDisconnectOwner::Runtime(expected_runtime_id.to_owned()),
        reason,
    )
    .await
    .map(|outcome| outcome.matched_owner)
}

/// Disconnects the current worker incarnation only when it still belongs to
/// the caller's immutable registration. A normal worker handoff is followed
/// through `target_runtime_id`; a replacement registration is never touched.
pub async fn disconnect_managed_session_if_registration(
    paths: &AgentPaths,
    session_id: &str,
    expected_registration_id: &str,
    reason: Option<String>,
) -> Result<bool> {
    validate_registration_id(expected_registration_id)
        .context("expected managed registration id is invalid")?;
    disconnect_managed_session_transaction(
        paths,
        session_id,
        ManagedSessionDisconnectOwner::Registration(expected_registration_id.to_owned()),
        reason,
    )
    .await
    .map(|outcome| outcome.matched_owner)
}

enum ManagedSessionDisconnectOwner {
    Any,
    Runtime(String),
    Registration(String),
}

struct ManagedSessionDisconnectOutcome {
    sessions: SessionRegistry,
    matched_owner: bool,
}

async fn disconnect_managed_session_transaction(
    paths: &AgentPaths,
    session_id: &str,
    expected_owner: ManagedSessionDisconnectOwner,
    reason: Option<String>,
) -> Result<ManagedSessionDisconnectOutcome> {
    ensure_identity_layout(paths).await?;
    let session_id = session_id.to_owned();
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let control_registry_path = session_controls_file(paths);
    let control_registry_lock_path = managed_session_controls_lock_file(paths);

    tokio::task::spawn_blocking(move || {
        let _session_process_guard = lock_session_registry_process()?;
        let _control_process_guard = lock_managed_session_controls_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, true)?;
        let _control_file_lock = lock_session_registry_file(&control_registry_lock_path, true)?;
        let mut sessions = load_session_registry_unlocked(&session_registry_path)?;
        let runtime_id = match sessions.get(&session_id) {
            Some(session) => session.runtime_id.clone(),
            None if !matches!(&expected_owner, ManagedSessionDisconnectOwner::Any) => {
                return Ok(ManagedSessionDisconnectOutcome {
                    sessions,
                    matched_owner: false,
                });
            }
            None => bail!("session `{session_id}` not found"),
        };
        if matches!(
            &expected_owner,
            ManagedSessionDisconnectOwner::Runtime(expected) if expected != &runtime_id
        ) {
            return Ok(ManagedSessionDisconnectOutcome {
                sessions,
                matched_owner: false,
            });
        }
        let mut controls = match load_managed_session_controls_unlocked(&control_registry_path) {
            Ok(controls) => controls,
            Err(control_error) => {
                if matches!(
                    &expected_owner,
                    ManagedSessionDisconnectOwner::Registration(_)
                ) {
                    return Err(control_error.context(
                        "managed registration authority was unavailable; exact cleanup made no runtime change",
                    ));
                }
                if !sessions.mark_disconnected(&session_id, reason) {
                    bail!("session `{session_id}` disappeared during disconnect");
                }
                return match store_session_registry_unlocked(&session_registry_path, &sessions) {
                    Ok(()) => Err(control_error.context(
                        "managed control registry was unavailable; runtime session was still persisted as disconnected fail-closed",
                    )),
                    Err(session_error) => Err(control_error.context(format!(
                        "managed control registry was unavailable and runtime disconnect persistence also failed: {session_error:#}"
                    ))),
                };
            }
        };

        if let ManagedSessionDisconnectOwner::Registration(expected_registration_id) =
            &expected_owner
        {
            let Some(control) = controls.get(&session_id) else {
                return Ok(ManagedSessionDisconnectOutcome {
                    sessions,
                    matched_owner: false,
                });
            };
            if &control.registration_id != expected_registration_id {
                return Ok(ManagedSessionDisconnectOutcome {
                    sessions,
                    matched_owner: false,
                });
            }
            if control.target_runtime_id != runtime_id {
                bail!("managed session control/runtime incarnation mismatch during disconnect");
            }
        }

        let had_control = if let Some(control) = controls.sessions.get_mut(&session_id) {
            if control.target_runtime_id != runtime_id {
                bail!("managed session control/runtime incarnation mismatch during disconnect");
            }
            control.desired_state = ManagedSessionDesiredState::Stopped;
            control.updated_at = OffsetDateTime::now_utc();
            store_managed_session_controls_unlocked(&control_registry_path, &controls)?;
            true
        } else {
            false
        };

        if !sessions.mark_disconnected(&session_id, reason) {
            bail!("session `{session_id}` disappeared during disconnect");
        }
        store_session_registry_unlocked(&session_registry_path, &sessions)?;

        if had_control {
            controls.remove(&session_id);
            store_managed_session_controls_unlocked(&control_registry_path, &controls)?;
        }
        Ok(ManagedSessionDisconnectOutcome {
            sessions,
            matched_owner: true,
        })
    })
    .await
    .context("managed session disconnect task panicked")?
}

pub(crate) async fn remove_managed_session_control_if_runtime(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
) -> Result<bool> {
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    mutate_managed_session_controls(paths, move |registry| {
        let matches_incarnation = registry
            .get(&session_id)
            .is_some_and(|control| control.target_runtime_id == expected_runtime_id);
        if matches_incarnation {
            registry.remove(&session_id);
        }
        matches_incarnation
    })
    .await
}

pub(crate) async fn stop_managed_session_control_if_runtime(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
) -> Result<bool> {
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    mutate_managed_session_controls(paths, move |registry| {
        let Some(control) = registry.sessions.get_mut(&session_id) else {
            return false;
        };
        if control.target_runtime_id != expected_runtime_id {
            return false;
        }
        control.desired_state = ManagedSessionDesiredState::Stopped;
        control.updated_at = OffsetDateTime::now_utc();
        true
    })
    .await
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

pub async fn load_inbound_file_transfer_approval_registry(
    paths: &AgentPaths,
) -> Result<InboundFileTransferApprovalRegistry> {
    ensure_identity_layout(paths).await?;
    let session_registry_path = session_registry_file(paths);
    let session_lock_path = session_registry_lock_file(paths);
    let registry_path = inbound_file_transfer_approval_registry_file(paths);
    let lock_path = inbound_file_transfer_approval_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _session_lock = lock_session_registry_file(&session_lock_path, false)?;
        let _file_lock = lock_session_registry_file(&lock_path, true)?;
        let sessions = load_session_registry_unlocked(&session_registry_path)?;
        let mut registry = load_inbound_file_transfer_approval_registry_unlocked(&registry_path)?;
        if reconcile_inbound_file_approvals(&mut registry, &sessions, OffsetDateTime::now_utc())? {
            store_inbound_file_transfer_approval_registry_unlocked(&registry_path, &registry)?;
        }
        Ok(registry)
    })
    .await
    .context("inbound file approval registry read task panicked")?
}

pub(crate) async fn authenticated_file_transfer_peer_for_runtime(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
) -> Result<RuntimeAuthenticatedPeerObservation> {
    ensure_identity_layout(paths).await?;
    let session_registry_path = session_registry_file(paths);
    let session_lock_path = session_registry_lock_file(paths);
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _session_lock = lock_session_registry_file(&session_lock_path, false)?;
        let sessions = load_session_registry_unlocked(&session_registry_path)?;
        let session = sessions
            .get(&session_id)
            .ok_or_else(|| anyhow!("inbound file metadata has no managed session"))?;
        if session.runtime_id != expected_runtime_id || !session.is_active() {
            bail!("inbound file metadata no longer belongs to the active runtime incarnation");
        }
        match &session.readiness {
            SessionReadiness::HandshakeComplete {
                session_id: receipt_session_id,
                ..
            } if receipt_session_id == &session_id => {}
            _ => bail!("inbound file metadata requires current handshake-complete evidence"),
        }
        let peer = session.authenticated_peer.clone().ok_or_else(|| {
            anyhow!("inbound file metadata is missing authenticated peer evidence")
        })?;
        if session.remote_device_id.as_deref() != Some(peer.device_id.as_str())
            || session
                .remote_protocol_public_key_fingerprint
                .as_deref()
                .is_none_or(str::is_empty)
        {
            bail!("inbound file metadata authenticated peer binding is incomplete");
        }
        Ok(peer)
    })
    .await
    .context("authenticated inbound file peer lookup task panicked")?
}

pub(crate) struct InboundFileTransferApprovalRegistration {
    pub(crate) session_id: String,
    pub(crate) expected_runtime_id: String,
    pub(crate) transfer_id: String,
    pub(crate) metadata_sha256_hex: String,
    pub(crate) file_name: String,
    pub(crate) file_size: u64,
    pub(crate) claimed_sender_device_id: Option<String>,
}

pub(crate) async fn register_inbound_file_transfer_approval_for_runtime(
    paths: &AgentPaths,
    registration: InboundFileTransferApprovalRegistration,
) -> Result<InboundFileTransferApprovalRequest> {
    ensure_identity_layout(paths).await?;
    let session_registry_path = session_registry_file(paths);
    let session_lock_path = session_registry_lock_file(paths);
    let registry_path = inbound_file_transfer_approval_registry_file(paths);
    let registry_lock_path = inbound_file_transfer_approval_registry_lock_file(paths);
    let InboundFileTransferApprovalRegistration {
        session_id,
        expected_runtime_id,
        transfer_id,
        metadata_sha256_hex,
        file_name,
        file_size,
        claimed_sender_device_id,
    } = registration;
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _session_lock = lock_session_registry_file(&session_lock_path, false)?;
        let _approval_lock = lock_session_registry_file(&registry_lock_path, true)?;
        let sessions = load_session_registry_unlocked(&session_registry_path)?;
        let session = sessions
            .get(&session_id)
            .ok_or_else(|| anyhow!("inbound file approval has no managed session"))?;
        if session.runtime_id != expected_runtime_id || !session.is_active() {
            bail!("inbound file approval no longer belongs to the active runtime incarnation");
        }
        match &session.readiness {
            SessionReadiness::HandshakeComplete {
                session_id: receipt_session_id,
                ..
            } if receipt_session_id == &session_id => {}
            _ => bail!("inbound file approval requires current handshake-complete evidence"),
        }
        let handshake_completed_at = session
            .handshake_completed_at
            .ok_or_else(|| anyhow!("inbound file approval is missing handshake completion time"))?;
        let authenticated_peer = session.authenticated_peer.as_ref().ok_or_else(|| {
            anyhow!("inbound file approval is missing authenticated peer evidence")
        })?;
        if authenticated_peer.observed_at < handshake_completed_at
            || session.remote_device_id.as_deref() != Some(authenticated_peer.device_id.as_str())
        {
            bail!("inbound file approval authenticated peer evidence is stale or inconsistent");
        }
        if claimed_sender_device_id
            .as_deref()
            .is_some_and(|claimed| claimed != authenticated_peer.device_id)
        {
            bail!("inbound file metadata senderDeviceId does not match the authenticated peer");
        }
        let authenticated_peer_protocol_fingerprint = session
            .remote_protocol_public_key_fingerprint
            .clone()
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| {
                anyhow!("inbound file approval is missing authenticated peer fingerprint")
            })?;

        let now = OffsetDateTime::now_utc();
        let candidate = InboundFileTransferApprovalRequest::pending(
            InboundFileTransferApprovalBinding {
                transfer_id: transfer_id.clone(),
                session_id: session_id.clone(),
                target_runtime_id: expected_runtime_id.clone(),
                authenticated_peer_device_id: authenticated_peer.device_id.clone(),
                authenticated_peer_device_name: authenticated_peer.device_name.clone(),
                authenticated_peer_protocol_fingerprint,
                metadata_sha256_hex,
                file_name,
                file_size,
            },
            now,
        );
        validate_inbound_file_transfer_approval_request(&candidate)?;
        let mut registry = load_inbound_file_transfer_approval_registry_unlocked(&registry_path)?;
        let reconciled = reconcile_inbound_file_approvals(&mut registry, &sessions, now)?;
        let registry_key = candidate.registry_key();
        if let Some(existing) = registry.requests.get(&registry_key) {
            if inbound_approval_binding(existing) != inbound_approval_binding(&candidate) {
                bail!("inbound file transferId conflicts with an existing approval binding");
            }
            let existing = existing.clone();
            if reconciled {
                store_inbound_file_transfer_approval_registry_unlocked(&registry_path, &registry)?;
            }
            return Ok(existing);
        }
        registry.insert(candidate.clone())?;
        store_inbound_file_transfer_approval_registry_unlocked(&registry_path, &registry)?;
        Ok(candidate)
    })
    .await
    .context("inbound file approval registration task panicked")?
}

pub async fn request_inbound_file_transfer_decision(
    paths: &AgentPaths,
    session_id: &str,
    transfer_id: &str,
    decision: InboundFileTransferApprovalDecision,
) -> Result<InboundFileTransferApprovalRequest> {
    if decision == InboundFileTransferApprovalDecision::Expire {
        bail!("expire is reserved for the agent approval timeout policy");
    }
    ensure_identity_layout(paths).await?;
    let session_registry_path = session_registry_file(paths);
    let session_lock_path = session_registry_lock_file(paths);
    let registry_path = inbound_file_transfer_approval_registry_file(paths);
    let lock_path = inbound_file_transfer_approval_registry_lock_file(paths);
    let session_id = session_id.to_owned();
    let transfer_id = transfer_id.to_owned();
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _session_lock = lock_session_registry_file(&session_lock_path, false)?;
        let _file_lock = lock_session_registry_file(&lock_path, true)?;
        let sessions = load_session_registry_unlocked(&session_registry_path)?;
        let active_runtime_id = sessions
            .get(&session_id)
            .filter(|session| session.is_active())
            .map(|session| session.runtime_id.clone())
            .ok_or_else(|| anyhow!("inbound file approval session is not active"))?;
        let mut registry = load_inbound_file_transfer_approval_registry_unlocked(&registry_path)?;
        let matches = registry
            .requests
            .iter()
            .filter(|(_, request)| {
                request.session_id == session_id
                    && request.target_runtime_id == active_runtime_id
                    && request.transfer_id == transfer_id
            })
            .map(|(key, _)| key.clone())
            .collect::<Vec<_>>();
        let [registry_key] = matches.as_slice() else {
            if matches.is_empty() {
                bail!("inbound file approval request not found");
            }
            bail!("inbound file approval request is ambiguous across runtime incarnations");
        };
        let request = registry
            .requests
            .get_mut(registry_key)
            .ok_or_else(|| anyhow!("inbound file approval request disappeared"))?;
        if request.status == InboundFileTransferApprovalStatus::DecisionRequested
            && request.decision == Some(decision)
        {
            return Ok(request.clone());
        }
        request.request_decision(decision, OffsetDateTime::now_utc())?;
        let result = request.clone();
        store_inbound_file_transfer_approval_registry_unlocked(&registry_path, &registry)?;
        Ok(result)
    })
    .await
    .context("inbound file approval decision task panicked")?
}

pub(crate) async fn observe_inbound_file_transfer_decisions_for_runtime(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
) -> Result<Vec<InboundFileTransferApprovalRequest>> {
    ensure_identity_layout(paths).await?;
    let session_registry_path = session_registry_file(paths);
    let session_lock_path = session_registry_lock_file(paths);
    let registry_path = inbound_file_transfer_approval_registry_file(paths);
    let registry_lock_path = inbound_file_transfer_approval_registry_lock_file(paths);
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _session_lock = lock_session_registry_file(&session_lock_path, false)?;
        let _approval_lock = lock_session_registry_file(&registry_lock_path, true)?;
        let sessions = load_session_registry_unlocked(&session_registry_path)?;
        let session = sessions
            .get(&session_id)
            .ok_or_else(|| anyhow!("inbound file decision has no managed session"))?;
        if session.runtime_id != expected_runtime_id || !session.is_active() {
            bail!("inbound file decision no longer belongs to the active runtime incarnation");
        }
        let authenticated_peer = session.authenticated_peer.as_ref().ok_or_else(|| {
            anyhow!("inbound file decision is missing authenticated peer evidence")
        })?;
        if session.remote_device_id.as_deref() != Some(authenticated_peer.device_id.as_str()) {
            bail!("inbound file decision authenticated peer identity changed");
        }

        let mut registry = load_inbound_file_transfer_approval_registry_unlocked(&registry_path)?;
        let now = OffsetDateTime::now_utc();
        let changed = reconcile_inbound_file_approvals(&mut registry, &sessions, now)?;
        let mut decisions = Vec::new();
        for request in registry.requests.values_mut().filter(|request| {
            request.session_id == session_id && request.target_runtime_id == expected_runtime_id
        }) {
            if request.authenticated_peer_device_id != authenticated_peer.device_id {
                bail!("inbound file decision authenticated peer binding changed");
            }
            if session.remote_protocol_public_key_fingerprint.as_deref()
                != Some(request.authenticated_peer_protocol_fingerprint.as_str())
            {
                bail!("inbound file decision authenticated peer fingerprint changed");
            }
            if request.status == InboundFileTransferApprovalStatus::DecisionRequested {
                decisions.push(request.clone());
            }
        }
        if changed {
            store_inbound_file_transfer_approval_registry_unlocked(&registry_path, &registry)?;
        }
        decisions.sort_by_key(|request| request.updated_at);
        Ok(decisions)
    })
    .await
    .context("inbound file approval observation task panicked")?
}

pub(crate) async fn mark_inbound_file_transfer_decision_applied_for_runtime(
    paths: &AgentPaths,
    session_id: &str,
    transfer_id: &str,
    expected_runtime_id: &str,
) -> Result<InboundFileTransferApprovalRequest> {
    transition_inbound_file_transfer_decision_for_runtime(
        paths,
        session_id,
        transfer_id,
        expected_runtime_id,
        |request| request.mark_applied(OffsetDateTime::now_utc()),
    )
    .await
}

pub(crate) async fn mark_inbound_file_transfer_decision_failed_for_runtime(
    paths: &AgentPaths,
    session_id: &str,
    transfer_id: &str,
    expected_runtime_id: &str,
) -> Result<InboundFileTransferApprovalRequest> {
    transition_inbound_file_transfer_decision_for_runtime(
        paths,
        session_id,
        transfer_id,
        expected_runtime_id,
        |request| {
            request.mark_failed(
                "agent failed to apply inbound file decision",
                OffsetDateTime::now_utc(),
            )
        },
    )
    .await
}

async fn transition_inbound_file_transfer_decision_for_runtime<F>(
    paths: &AgentPaths,
    session_id: &str,
    transfer_id: &str,
    expected_runtime_id: &str,
    transition: F,
) -> Result<InboundFileTransferApprovalRequest>
where
    F: FnOnce(&mut InboundFileTransferApprovalRequest) -> Result<()> + Send + 'static,
{
    ensure_identity_layout(paths).await?;
    let registry_path = inbound_file_transfer_approval_registry_file(paths);
    let lock_path = inbound_file_transfer_approval_registry_lock_file(paths);
    let session_id = session_id.to_owned();
    let transfer_id = transfer_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, true)?;
        let mut registry = load_inbound_file_transfer_approval_registry_unlocked(&registry_path)?;
        let registry_key = registry
            .requests
            .iter()
            .find(|(_, request)| {
                request.session_id == session_id
                    && request.target_runtime_id == expected_runtime_id
                    && request.transfer_id == transfer_id
            })
            .map(|(key, _)| key.clone())
            .ok_or_else(|| anyhow!("inbound file approval request not found"))?;
        let request = registry
            .requests
            .get_mut(&registry_key)
            .ok_or_else(|| anyhow!("inbound file approval request disappeared"))?;
        transition(request)?;
        let result = request.clone();
        store_inbound_file_transfer_approval_registry_unlocked(&registry_path, &registry)?;
        Ok(result)
    })
    .await
    .context("inbound file approval transition task panicked")?
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
        let request = RemoteDesktopControlRequest::pending(
            uuid::Uuid::now_v7().to_string(),
            bound_session_id,
            target_runtime_id,
            action,
            payload,
        );
        request_registry.insert(request.clone())?;
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
    let registry = load_session_registry(paths).await?;
    let runtime_id = registry
        .get(session_id)
        .ok_or_else(|| anyhow!("session `{session_id}` not found"))?
        .runtime_id
        .clone();
    observe_remote_desktop_requests_for_runtime(paths, session_id, &runtime_id).await
}

pub(crate) async fn observe_remote_desktop_requests_for_runtime(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
) -> Result<Vec<RemoteDesktopControlRequest>> {
    ensure_identity_layout(paths).await?;
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
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
        if session.runtime_id != expected_runtime_id {
            bail!("managed runtime incarnation no longer owns remote desktop observation");
        }

        let _request_file_lock = lock_session_registry_file(&request_registry_lock_path, true)?;
        let mut request_registry =
            load_remote_desktop_request_registry_unlocked(&request_registry_path)?;
        let pending = request_registry.pending_for_session(&session_id);
        if pending.is_empty() {
            return Ok(Vec::new());
        }
        let stale_ids = pending
            .iter()
            .filter(|request| request.target_runtime_id != expected_runtime_id)
            .map(|request| request.request_id.clone())
            .collect::<Vec<_>>();
        let now = OffsetDateTime::now_utc();
        for request_id in stale_ids {
            let request = request_registry
                .requests
                .get_mut(&request_id)
                .ok_or_else(|| anyhow!("stale remote desktop request disappeared"))?;
            request.status = RemoteDesktopControlRequestStatus::AgentRejected;
            request.updated_at = now;
        }
        let pending_ids =
            request_registry.pending_ids_for_session_runtime(&session_id, &expected_runtime_id);
        // The standalone Rust runtime does not have a screen-capture/media/input
        // backend. Legacy request files must therefore terminate as rejected;
        // agent observation is not an application receipt and must never be
        // promoted to a success-adjacent state.
        for request_id in pending_ids {
            let request = request_registry
                .requests
                .get_mut(&request_id)
                .ok_or_else(|| {
                    anyhow!("remote desktop pending request `{request_id}` disappeared")
                })?;
            if !request.is_pending_agent_observation() {
                bail!(
                    "remote desktop request `{}` is not pending agent observation",
                    request.request_id
                );
            }
            request.status = RemoteDesktopControlRequestStatus::AgentRejected;
            request.updated_at = now;
        }
        store_remote_desktop_request_registry_unlocked(&request_registry_path, &request_registry)?;
        Ok(Vec::new())
    })
    .await
    .context("remote desktop request observation task panicked")?
}

pub async fn observe_file_transfer_requests_for_established_session(
    paths: &AgentPaths,
    session_id: &str,
) -> Result<Vec<FileTransferControlRequest>> {
    let registry = load_session_registry(paths).await?;
    let runtime_id = registry
        .get(session_id)
        .ok_or_else(|| anyhow!("session `{session_id}` not found"))?
        .runtime_id
        .clone();
    observe_file_transfer_requests_for_runtime(paths, session_id, &runtime_id).await
}

pub(crate) async fn observe_file_transfer_requests_for_runtime(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
) -> Result<Vec<FileTransferControlRequest>> {
    ensure_identity_layout(paths).await?;
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
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
        if session.runtime_id != expected_runtime_id {
            bail!("managed runtime incarnation no longer owns file transfer observation");
        }

        let _request_file_lock = lock_session_registry_file(&request_registry_lock_path, true)?;
        let mut request_registry =
            load_file_transfer_request_registry_unlocked(&request_registry_path)?;
        let pending = request_registry.pending_for_session(&session_id);
        if pending.is_empty() {
            return Ok(Vec::new());
        }
        let stale_ids = pending
            .iter()
            .filter(|request| request.target_runtime_id != expected_runtime_id)
            .map(|request| request.request_id.clone())
            .collect::<Vec<_>>();
        let now = OffsetDateTime::now_utc();
        for request_id in stale_ids {
            let request = request_registry
                .requests
                .get_mut(&request_id)
                .ok_or_else(|| anyhow!("stale file transfer request disappeared"))?;
            request.status = FileTransferControlRequestStatus::AgentRejected;
            request.failure_reason =
                Some("request targets an inactive managed runtime".to_owned());
            request.updated_at = now;
        }
        let pending_ids = request_registry
            .pending_ids_for_session_runtime(&session_id, &expected_runtime_id);
        if pending_ids.is_empty() {
            store_file_transfer_request_registry_unlocked(
                &request_registry_path,
                &request_registry,
            )?;
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

async fn transition_file_transfer_request<F>(
    paths: &AgentPaths,
    request_id: &str,
    expected_runtime_id: &str,
    transition: F,
) -> Result<FileTransferControlRequest>
where
    F: FnOnce(&mut FileTransferControlRequest) -> Result<()> + Send + 'static,
{
    ensure_identity_layout(paths).await?;
    let request_id = request_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let request_registry_path = file_transfer_request_registry_file(paths);
    let request_registry_lock_path = file_transfer_request_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, false)?;
        let session_registry = load_session_registry_unlocked(&session_registry_path)?;
        let _request_file_lock = lock_session_registry_file(&request_registry_lock_path, true)?;
        let mut request_registry =
            load_file_transfer_request_registry_unlocked(&request_registry_path)?;
        let request = request_registry
            .requests
            .get_mut(&request_id)
            .ok_or_else(|| anyhow!("file transfer request `{request_id}` not found"))?;
        require_runtime_incarnation(&session_registry, &request.session_id, &expected_runtime_id)?;
        if request.target_runtime_id != expected_runtime_id {
            bail!("file transfer request belongs to a different runtime incarnation");
        }
        transition(request)?;
        let updated = request.clone();
        store_file_transfer_request_registry_unlocked(&request_registry_path, &request_registry)?;
        Ok(updated)
    })
    .await
    .context("file transfer request transition task panicked")?
}

pub(crate) async fn reject_file_transfer_request_for_runtime(
    paths: &AgentPaths,
    request_id: &str,
    expected_runtime_id: &str,
    reason: &'static str,
) -> Result<FileTransferControlRequest> {
    transition_file_transfer_request(paths, request_id, expected_runtime_id, move |request| {
        if request.status == FileTransferControlRequestStatus::AgentRejected
            && request.failure_reason.as_deref() == Some(reason)
        {
            return Ok(());
        }
        if request.status != FileTransferControlRequestStatus::AgentObserved {
            bail!("file transfer rejection requires an observed request");
        }
        request.status = FileTransferControlRequestStatus::AgentRejected;
        request.failure_reason = Some(reason.to_owned());
        request.updated_at = OffsetDateTime::now_utc();
        Ok(())
    })
    .await
}

pub(crate) async fn start_file_transfer_request_for_runtime(
    paths: &AgentPaths,
    request_id: &str,
    expected_runtime_id: &str,
) -> Result<FileTransferControlRequest> {
    transition_file_transfer_request(paths, request_id, expected_runtime_id, |request| {
        if request.status != FileTransferControlRequestStatus::AgentObserved {
            bail!("file transfer start requires an observed request");
        }
        request.mark_transfer_started(OffsetDateTime::now_utc());
        Ok(())
    })
    .await
}

pub(crate) async fn record_file_transfer_progress_for_runtime(
    paths: &AgentPaths,
    request_id: &str,
    expected_runtime_id: &str,
    bytes_transferred: u64,
) -> Result<FileTransferControlRequest> {
    transition_file_transfer_request(paths, request_id, expected_runtime_id, move |request| {
        if request.status != FileTransferControlRequestStatus::TransferInProgress {
            bail!("file transfer progress requires an in-progress request");
        }
        if bytes_transferred < request.bytes_transferred
            || bytes_transferred > request.source.size_bytes
        {
            bail!("file transfer progress violates the bounded monotonic byte count");
        }
        request.record_bytes_transferred(bytes_transferred, OffsetDateTime::now_utc());
        Ok(())
    })
    .await
}

pub(crate) async fn complete_file_transfer_request_for_runtime(
    paths: &AgentPaths,
    request_id: &str,
    expected_runtime_id: &str,
    bytes_transferred: u64,
) -> Result<FileTransferControlRequest> {
    transition_file_transfer_request(paths, request_id, expected_runtime_id, move |request| {
        if request.status == FileTransferControlRequestStatus::TransferCompleted
            && request.bytes_transferred == bytes_transferred
        {
            return Ok(());
        }
        if request.status != FileTransferControlRequestStatus::TransferInProgress {
            bail!("file transfer completion requires an in-progress request");
        }
        if bytes_transferred != request.source.size_bytes {
            bail!("file transfer completion byte count does not match the source snapshot");
        }
        request.mark_transfer_completed(bytes_transferred, OffsetDateTime::now_utc());
        Ok(())
    })
    .await
}

pub(crate) async fn fail_file_transfer_request_for_runtime(
    paths: &AgentPaths,
    request_id: &str,
    expected_runtime_id: &str,
    reason: String,
) -> Result<FileTransferControlRequest> {
    transition_file_transfer_request(paths, request_id, expected_runtime_id, move |request| {
        if request.status == FileTransferControlRequestStatus::TransferFailed
            && request.failure_reason.as_deref() == Some(reason.as_str())
        {
            return Ok(());
        }
        if !matches!(
            request.status,
            FileTransferControlRequestStatus::AgentObserved
                | FileTransferControlRequestStatus::TransferInProgress
        ) {
            bail!("file transfer failure requires an observed or in-progress request");
        }
        request.mark_transfer_failed(reason, OffsetDateTime::now_utc());
        Ok(())
    })
    .await
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
            if request_registry.requests.len() >= FileTransferControlRequestRegistry::MAX_REQUESTS
                && !request_registry
                    .requests
                    .values()
                    .any(FileTransferControlRequest::is_terminal)
            {
                bail!(
                    "file transfer request registry is full at {} nonterminal entries",
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
        request_registry.insert(request.clone())?;
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
    try_mutate_session_registry(paths, move |registry| {
        registry.insert(record)?;
        Ok(registry.clone())
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

#[cfg(test)]
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

pub(crate) async fn disconnect_session_if_runtime(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    reason: Option<String>,
) -> Result<bool> {
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    mutate_session_registry(paths, move |registry| {
        let Some(record) = registry.get(&session_id) else {
            return false;
        };
        if record.runtime_id != expected_runtime_id {
            return false;
        }
        if matches!(
            record.state,
            RuntimeSessionState::Disconnected | RuntimeSessionState::Failed
        ) {
            return true;
        }
        registry.mark_disconnected(&session_id, reason)
    })
    .await
}

pub(crate) async fn apply_transport_event_for_runtime(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    event: RuntimeSessionTransportEvent,
) -> Result<SessionRegistry> {
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    let event_session_id = session_id.clone();
    try_mutate_authorized_runtime_session(
        paths,
        &session_id,
        &expected_runtime_id,
        move |registry| {
            registry.apply_transport_event(&event_session_id, event);
            Ok(registry.clone())
        },
    )
    .await
}

pub(crate) async fn apply_signaling_event_for_runtime(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    event: SignalingLifecycleEvent,
) -> Result<SessionRegistry> {
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    let event_session_id = session_id.clone();
    try_mutate_authorized_runtime_session(
        paths,
        &session_id,
        &expected_runtime_id,
        move |registry| {
            registry.apply_signaling_event(&event_session_id, &event);
            Ok(registry.clone())
        },
    )
    .await
}

fn require_runtime_incarnation<'a>(
    registry: &'a SessionRegistry,
    session_id: &str,
    expected_runtime_id: &str,
) -> Result<&'a RuntimeSessionRecord> {
    let record = registry
        .get(session_id)
        .ok_or_else(|| anyhow!("managed runtime session is missing"))?;
    if record.runtime_id != expected_runtime_id {
        bail!("managed runtime incarnation no longer owns the session");
    }
    if !record.is_active() {
        bail!("managed runtime incarnation no longer owns an active session");
    }
    Ok(record)
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

pub async fn update_session_remote_peer(
    paths: &AgentPaths,
    session_id: &str,
    remote_device_id: impl Into<String>,
    remote_device_name: Option<String>,
    remote_protocol_public_key_fingerprint: Option<String>,
) -> Result<SessionRegistry> {
    let session_id = session_id.to_owned();
    let remote_device_id = remote_device_id.into().trim().to_owned();
    if remote_device_id.is_empty()
        || remote_device_id.len() > 256
        || remote_device_id
            .chars()
            .any(|character| character.is_control())
    {
        bail!("remote device id is empty or violates the session metadata boundary");
    }
    try_mutate_session_registry(paths, move |registry| {
        let record = registry
            .sessions
            .get_mut(&session_id)
            .ok_or_else(|| anyhow!("runtime session is missing while binding remote peer"))?;
        if record
            .remote_device_id
            .as_deref()
            .is_some_and(|expected| expected != remote_device_id)
        {
            bail!("remote device id did not match the pre-bound session peer");
        }
        if let Some(observed_fingerprint) = remote_protocol_public_key_fingerprint.as_deref()
            && record
                .remote_protocol_public_key_fingerprint
                .as_deref()
                .is_some_and(|expected| !expected.eq_ignore_ascii_case(observed_fingerprint))
        {
            bail!("remote protocol identity did not match the pre-bound session peer");
        }
        record.remote_device_id.get_or_insert(remote_device_id);
        if remote_device_name.is_some() {
            record.remote_device_name = remote_device_name;
        }
        if record.remote_protocol_public_key_fingerprint.is_none() {
            record.remote_protocol_public_key_fingerprint = remote_protocol_public_key_fingerprint;
        }
        record.updated_at = OffsetDateTime::now_utc();
        Ok(registry.clone())
    })
    .await
}

pub(crate) async fn update_session_remote_peer_for_runtime(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    remote_device_id: impl Into<String>,
    remote_device_name: Option<String>,
    remote_protocol_public_key_fingerprint: Option<String>,
) -> Result<SessionRegistry> {
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    let remote_device_id = remote_device_id.into().trim().to_owned();
    if remote_device_id.is_empty()
        || remote_device_id.len() > 256
        || remote_device_id
            .chars()
            .any(|character| character.is_control())
    {
        bail!("remote device id is empty or violates the session metadata boundary");
    }
    try_mutate_session_registry(paths, move |registry| {
        require_runtime_incarnation(registry, &session_id, &expected_runtime_id)?;
        let record = registry
            .sessions
            .get_mut(&session_id)
            .ok_or_else(|| anyhow!("runtime session is missing while binding remote peer"))?;
        if record
            .remote_device_id
            .as_deref()
            .is_some_and(|expected| expected != remote_device_id)
        {
            bail!("remote device id did not match the pre-bound session peer");
        }
        if let Some(observed_fingerprint) = remote_protocol_public_key_fingerprint.as_deref()
            && record
                .remote_protocol_public_key_fingerprint
                .as_deref()
                .is_some_and(|expected| !expected.eq_ignore_ascii_case(observed_fingerprint))
        {
            bail!("remote protocol identity did not match the pre-bound session peer");
        }
        record.remote_device_id.get_or_insert(remote_device_id);
        if remote_device_name.is_some() {
            record.remote_device_name = remote_device_name;
        }
        if record.remote_protocol_public_key_fingerprint.is_none() {
            record.remote_protocol_public_key_fingerprint = remote_protocol_public_key_fingerprint;
        }
        record.updated_at = OffsetDateTime::now_utc();
        Ok(registry.clone())
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
    store_signing_key_at(&signing_key_file(paths), signing_key).await
}

async fn store_signing_key_at(path: &Path, signing_key: &ProtocolSigningKeyMaterial) -> Result<()> {
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
        ProtocolSigningKeyMaterial::MlDsa87 {
            public_key,
            secret_key,
        } => StoredSigningKey {
            schema_version: StoredSigningKey::SCHEMA_VERSION,
            algorithm: ProtocolSigningAlgorithm::MlDsa87,
            public_key_base64: Some(STANDARD.encode(public_key)),
            secret_key_base64: STANDARD.encode(secret_key),
        },
    };
    write_json_atomic_private(path, &stored).await
}

fn decode_signing_key(stored_key: &StoredSigningKey) -> Result<ProtocolSigningKeyMaterial> {
    validate_stored_signing_key_metadata(stored_key)?;
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
            let public_key = STANDARD.decode(public_key.as_bytes())?;
            validate_ml_dsa_keypair(stored_key.algorithm, &public_key, &secret_bytes)?;
            Ok(ProtocolSigningKeyMaterial::MlDsa65 {
                public_key,
                secret_key: secret_bytes,
            })
        }
        ProtocolSigningAlgorithm::MlDsa87 => {
            let public_key = stored_key
                .public_key_base64
                .as_deref()
                .ok_or_else(|| anyhow!("missing ML-DSA-87 public key in stored signing key"))?;
            let public_key = STANDARD.decode(public_key.as_bytes())?;
            validate_ml_dsa_keypair(stored_key.algorithm, &public_key, &secret_bytes)?;
            Ok(ProtocolSigningKeyMaterial::MlDsa87 {
                public_key,
                secret_key: secret_bytes,
            })
        }
    }
}

fn validate_stored_signing_key_metadata(stored_key: &StoredSigningKey) -> Result<()> {
    if stored_key.schema_version != StoredSigningKey::SCHEMA_VERSION {
        bail!(
            "unsupported signing key schema version {}; expected {}",
            stored_key.schema_version,
            StoredSigningKey::SCHEMA_VERSION
        );
    }
    Ok(())
}

fn validate_ml_dsa_keypair(
    algorithm: ProtocolSigningAlgorithm,
    public_key: &[u8],
    secret_key: &[u8],
) -> Result<()> {
    ProtocolIdentityBinding::validate_key_encoding(public_key, algorithm)?;
    const KEYPAIR_SELF_TEST_DOMAIN: &[u8] = b"SkyBridge-Rust-MLDSA-Keypair-Self-Test-v1";
    let signature = mldsa_sign_detached(algorithm, KEYPAIR_SELF_TEST_DOMAIN, secret_key)?;
    mldsa_verify_detached(algorithm, KEYPAIR_SELF_TEST_DOMAIN, &signature, public_key).with_context(
        || format!("stored {algorithm} public and secret keys do not form a valid pair"),
    )
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

fn requested_protocol_signing_algorithm() -> Result<Option<ProtocolSigningAlgorithm>> {
    match std::env::var("SKYBRIDGE_PROTOCOL_SIGNING_ALGORITHM") {
        Ok(value) => parse_optional_protocol_signing_algorithm(Some(&value)),
        Err(std::env::VarError::NotPresent) => Ok(None),
        Err(std::env::VarError::NotUnicode(_)) => {
            bail!("SKYBRIDGE_PROTOCOL_SIGNING_ALGORITHM is not valid Unicode")
        }
    }
}

fn parse_optional_protocol_signing_algorithm(
    raw: Option<&str>,
) -> Result<Option<ProtocolSigningAlgorithm>> {
    let Some(raw) = raw else {
        return Ok(None);
    };
    let value = raw.trim();
    if value.is_empty() {
        bail!("SKYBRIDGE_PROTOCOL_SIGNING_ALGORITHM must not be empty when set");
    }
    value.parse().map(Some).map_err(anyhow::Error::from)
}

fn generate_signing_key(algorithm: ProtocolSigningAlgorithm) -> Result<ProtocolSigningKeyMaterial> {
    match algorithm {
        ProtocolSigningAlgorithm::Ed25519 => Ok(ProtocolSigningKeyMaterial::Ed25519(
            // `UnwrapErr(SysRng)` is the rand_core-0.10 replacement for the removed
            // `rand_core::OsRng`: it panics if the OS CSPRNG fails, matching the
            // previous OsRng behaviour and the pqc.rs randomness convention.
            SigningKey::generate(&mut UnwrapErr(SysRng)),
        )),
        ProtocolSigningAlgorithm::MlDsa65 => {
            let (public_key, secret_key) = mldsa_generate_keypair(algorithm)?;
            Ok(ProtocolSigningKeyMaterial::MlDsa65 {
                public_key,
                secret_key,
            })
        }
        ProtocolSigningAlgorithm::MlDsa87 => {
            let (public_key, secret_key) = mldsa_generate_keypair(algorithm)?;
            Ok(ProtocolSigningKeyMaterial::MlDsa87 {
                public_key,
                secret_key,
            })
        }
    }
}

async fn ensure_mldsa_signing_key(
    paths: &AgentPaths,
    algorithm: ProtocolSigningAlgorithm,
) -> Result<ProtocolSigningKeyMaterial> {
    if !algorithm.is_ml_dsa() {
        bail!("PQC signing key requires an ML-DSA algorithm");
    }
    if let Some(stored_key) = load_signing_key(paths).await? {
        validate_stored_signing_key_metadata(&stored_key)?;
        if stored_key.algorithm == algorithm {
            return decode_signing_key(&stored_key);
        }
    }

    load_or_generate_signing_key_slot(paths, algorithm).await
}

async fn load_or_generate_signing_key_slot(
    paths: &AgentPaths,
    algorithm: ProtocolSigningAlgorithm,
) -> Result<ProtocolSigningKeyMaterial> {
    let path = signing_key_slot_file(paths, algorithm);
    if let Some(stored_key) = load_json::<StoredSigningKey>(&path).await? {
        if stored_key.algorithm != algorithm {
            bail!(
                "signing key slot for {algorithm} contains {} material",
                stored_key.algorithm
            );
        }
        return decode_signing_key(&stored_key);
    }

    let signing_key = generate_signing_key(algorithm)?;
    store_signing_key_at(&path, &signing_key).await?;
    Ok(signing_key)
}

async fn ensure_kem_identity_key(
    paths: &AgentPaths,
    suite_wire_id: u16,
) -> Result<(Vec<u8>, Vec<u8>)> {
    let path = kem_identity_key_file(paths, suite_wire_id);
    if let Some(stored) = load_json::<StoredKemIdentityKey>(&path).await? {
        if stored.schema_version != StoredKemIdentityKey::SCHEMA_VERSION {
            bail!(
                "unsupported KEM identity schema version {}; expected {}",
                stored.schema_version,
                StoredKemIdentityKey::SCHEMA_VERSION
            );
        }
        if stored.suite_wire_id != suite_wire_id {
            bail!(
                "stored KEM identity suite {:#06x} does not match requested suite {suite_wire_id:#06x}",
                stored.suite_wire_id
            );
        }
        let public_key = STANDARD.decode(stored.public_key_base64.as_bytes())?;
        let secret_key = STANDARD.decode(stored.secret_key_base64.as_bytes())?;
        validate_kem_identity_lengths(suite_wire_id, &public_key, &secret_key)?;
        return Ok((public_key, secret_key));
    }

    let (public_key, secret_key) = match suite_wire_id {
        0x0101 => skybridge_core::mlkem768_generate_keypair(),
        0x0001 => xwing_generate_keypair(),
        #[cfg(feature = "q-periapt")]
        0x0011 => skybridge_core::qperiapt_contextbound_generate_keypair(),
        _ => bail!("unsupported KEM identity suite {suite_wire_id:#06x}"),
    };
    validate_kem_identity_lengths(suite_wire_id, &public_key, &secret_key)?;
    let stored = StoredKemIdentityKey {
        schema_version: StoredKemIdentityKey::SCHEMA_VERSION,
        suite_wire_id,
        public_key_base64: STANDARD.encode(&public_key),
        secret_key_base64: STANDARD.encode(&secret_key),
    };
    write_json_atomic_private(&path, &stored).await?;
    Ok((public_key, secret_key))
}

fn validate_kem_identity_lengths(
    suite_wire_id: u16,
    public_key: &[u8],
    secret_key: &[u8],
) -> Result<()> {
    let expected = match suite_wire_id {
        0x0101 => (
            skybridge_core::MLKEM768_PUBLIC_KEY_BYTES,
            skybridge_core::MLKEM768_SECRET_KEY_BYTES,
        ),
        0x0001 => (
            skybridge_core::XWING_PUBLIC_KEY_BYTES,
            skybridge_core::XWING_SECRET_KEY_BYTES,
        ),
        #[cfg(feature = "q-periapt")]
        0x0011 if !public_key.is_empty() && !secret_key.is_empty() => return Ok(()),
        _ => bail!("unsupported KEM identity suite {suite_wire_id:#06x}"),
    };
    if public_key.len() != expected.0 || secret_key.len() != expected.1 {
        bail!(
            "invalid KEM identity lengths for suite {suite_wire_id:#06x}: expected public={} secret={}, got public={} secret={}",
            expected.0,
            expected.1,
            public_key.len(),
            secret_key.len()
        );
    }
    Ok(())
}

async fn persist_identity(paths: &AgentPaths, identity: &LocalIdentityState) -> Result<()> {
    write_json_atomic_private(&paths.identity_file, identity).await
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

async fn acquire_protocol_identity_lock(paths: &AgentPaths) -> Result<std::fs::File> {
    let lock_path = paths.identity_dir.join("protocol-identity.lock");
    tokio::task::spawn_blocking(move || {
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&lock_path)
            .with_context(|| format!("failed to open identity lock {}", lock_path.display()))?;
        restrict_file_permissions_blocking(&lock_path)?;
        file.lock()
            .with_context(|| format!("failed to lock identity state {}", lock_path.display()))?;
        Ok(file)
    })
    .await
    .context("protocol identity lock task panicked")?
}

fn lock_session_registry_process() -> Result<std::sync::MutexGuard<'static, ()>> {
    SESSION_REGISTRY_PROCESS_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| anyhow!("session registry process lock poisoned"))
}

fn lock_managed_session_controls_process() -> Result<std::sync::MutexGuard<'static, ()>> {
    MANAGED_SESSION_CONTROLS_PROCESS_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| anyhow!("managed session controls process lock poisoned"))
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
    if registry.sessions.len() > SessionRegistry::MAX_SESSIONS {
        bail!(
            "session registry has {} entries in {}; max {}",
            registry.sessions.len(),
            path.display(),
            SessionRegistry::MAX_SESSIONS
        );
    }
    registry.schema_version = SessionRegistry::SCHEMA_VERSION;
    Ok(registry)
}

fn load_managed_session_controls_unlocked(path: &Path) -> Result<ManagedSessionControlRegistry> {
    let registry = match std::fs::read_to_string(path) {
        Ok(body) => serde_json::from_str::<ManagedSessionControlRegistry>(&body)
            .with_context(|| format!("failed to decode {}", path.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            ManagedSessionControlRegistry::default()
        }
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    validate_managed_session_control_registry(path, &registry)?;
    Ok(registry)
}

/// Upgrades the only supported legacy control schema while holding the
/// combined session/control recovery locks. A legacy record has no immutable
/// registration owner, so it is deliberately migrated as `Stopped`; startup
/// recovery then disconnects its runtime and removes the retry anchor. Even a
/// transitional legacy payload carrying an id remains stopped because its
/// schema did not establish the immutable-owner contract.
fn migrate_legacy_managed_session_controls_unlocked(path: &Path) -> Result<()> {
    let mut registry = match std::fs::read_to_string(path) {
        Ok(body) => serde_json::from_str::<ManagedSessionControlRegistry>(&body)
            .with_context(|| format!("failed to decode {}", path.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    validate_managed_session_control_registry_shape(path, &registry)?;

    let mut changed = false;
    for (session_id, control) in &mut registry.sessions {
        match control.schema_version {
            ManagedSessionControl::SCHEMA_VERSION => {
                validate_registration_id(&control.registration_id).with_context(|| {
                    format!("managed session control `{session_id}` has an invalid registration id")
                })?;
            }
            LEGACY_MANAGED_SESSION_CONTROL_SCHEMA_VERSION => {
                if control.registration_id.is_empty() {
                    control.registration_id = uuid::Uuid::now_v7().hyphenated().to_string();
                } else {
                    validate_registration_id(&control.registration_id).with_context(|| {
                        format!(
                            "legacy managed session control `{session_id}` has an invalid registration id"
                        )
                    })?;
                }
                control.desired_state = ManagedSessionDesiredState::Stopped;
                control.schema_version = ManagedSessionControl::SCHEMA_VERSION;
                control.updated_at = OffsetDateTime::now_utc();
                changed = true;
            }
            version => {
                bail!(
                    "unsupported managed session control schema version {version} for session `{session_id}`; expected {} or legacy {}",
                    ManagedSessionControl::SCHEMA_VERSION,
                    LEGACY_MANAGED_SESSION_CONTROL_SCHEMA_VERSION
                );
            }
        }
    }
    if changed {
        store_managed_session_controls_unlocked(path, &registry)?;
    }
    Ok(())
}

fn store_managed_session_controls_unlocked(
    path: &Path,
    registry: &ManagedSessionControlRegistry,
) -> Result<()> {
    validate_managed_session_control_registry(path, registry)?;
    let mut registry = registry.clone();
    registry.schema_version = ManagedSessionControlRegistry::SCHEMA_VERSION;
    let body = serde_json::to_vec_pretty(&registry).context("failed to encode json")?;
    write_private_file_atomically(path, &body)
}

fn store_session_registry_unlocked(path: &Path, registry: &SessionRegistry) -> Result<()> {
    let body = serde_json::to_vec_pretty(registry).context("failed to encode json")?;
    write_private_file_atomically(path, &body)
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

fn load_inbound_file_transfer_approval_registry_unlocked(
    path: &Path,
) -> Result<InboundFileTransferApprovalRegistry> {
    let registry = match std::fs::read_to_string(path) {
        Ok(body) => serde_json::from_str::<InboundFileTransferApprovalRegistry>(&body)
            .with_context(|| format!("failed to decode {}", path.display()))?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            InboundFileTransferApprovalRegistry::default()
        }
        Err(error) => {
            return Err(error).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    validate_inbound_file_transfer_approval_registry(path, &registry)?;
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

fn store_inbound_file_transfer_approval_registry_unlocked(
    path: &Path,
    registry: &InboundFileTransferApprovalRegistry,
) -> Result<()> {
    validate_inbound_file_transfer_approval_registry(path, registry)?;
    let mut registry = registry.clone();
    registry.schema_version = InboundFileTransferApprovalRegistry::SCHEMA_VERSION;
    let body = serde_json::to_vec_pretty(&registry).context("failed to encode json")?;
    write_private_file_atomically(path, &body)
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

fn inbound_approval_binding(
    request: &InboundFileTransferApprovalRequest,
) -> (&str, &str, &str, &str, &str, &str, &str, u64) {
    (
        &request.transfer_id,
        &request.session_id,
        &request.target_runtime_id,
        &request.authenticated_peer_device_id,
        &request.authenticated_peer_protocol_fingerprint,
        &request.metadata_sha256_hex,
        &request.file_name,
        request.file_size,
    )
}

fn reconcile_inbound_file_approvals(
    registry: &mut InboundFileTransferApprovalRegistry,
    sessions: &SessionRegistry,
    now: OffsetDateTime,
) -> Result<bool> {
    let mut changed = false;
    let expiry = time::Duration::minutes(5);
    for request in registry
        .requests
        .values_mut()
        .filter(|request| !request.is_terminal())
    {
        let current_authority = sessions
            .get(&request.session_id)
            .filter(|session| {
                session.is_active() && session.runtime_id == request.target_runtime_id
            })
            .and_then(|session| {
                session.authenticated_peer.as_ref().filter(|peer| {
                    session.remote_device_id.as_deref() == Some(peer.device_id.as_str())
                        && peer.device_id == request.authenticated_peer_device_id
                        && session.remote_protocol_public_key_fingerprint.as_deref()
                            == Some(request.authenticated_peer_protocol_fingerprint.as_str())
                })
            })
            .is_some();
        if !current_authority {
            request.status = InboundFileTransferApprovalStatus::DecisionRequested;
            request.decision = Some(InboundFileTransferApprovalDecision::Expire);
            request.applied_at = None;
            request.failure_reason = None;
            request.updated_at = now;
            request.mark_applied(now)?;
            changed = true;
            continue;
        }
        if request.status == InboundFileTransferApprovalStatus::PendingDecision
            && now >= request.created_at
            && now - request.created_at >= expiry
        {
            request.request_decision(InboundFileTransferApprovalDecision::Expire, now)?;
            changed = true;
        }
    }
    Ok(changed)
}

fn expire_inbound_file_approvals_for_incarnation(
    registry: &mut InboundFileTransferApprovalRegistry,
    session_id: &str,
    expected_runtime_id: Option<&str>,
    now: OffsetDateTime,
) -> Result<()> {
    for request in registry.requests.values_mut().filter(|request| {
        request.session_id == session_id
            && expected_runtime_id.is_none_or(|runtime_id| request.target_runtime_id == runtime_id)
            && !request.is_terminal()
    }) {
        request.status = InboundFileTransferApprovalStatus::DecisionRequested;
        request.decision = Some(InboundFileTransferApprovalDecision::Expire);
        request.applied_at = None;
        request.failure_reason = None;
        request.updated_at = now;
        request.mark_applied(now)?;
    }
    Ok(())
}

fn validate_inbound_file_transfer_approval_registry(
    path: &Path,
    registry: &InboundFileTransferApprovalRegistry,
) -> Result<()> {
    if registry.schema_version != InboundFileTransferApprovalRegistry::SCHEMA_VERSION {
        bail!(
            "unsupported inbound file approval registry schema version {} in {}; expected {}",
            registry.schema_version,
            path.display(),
            InboundFileTransferApprovalRegistry::SCHEMA_VERSION
        );
    }
    if registry.requests.len() > InboundFileTransferApprovalRegistry::MAX_REQUESTS {
        bail!("inbound file approval registry exceeds bounded capacity");
    }
    for (registry_key, request) in &registry.requests {
        if registry_key != &request.registry_key() {
            bail!("inbound file approval registry key does not match its bound identities");
        }
        validate_inbound_file_transfer_approval_request(request)?;
    }
    Ok(())
}

fn validate_inbound_file_transfer_approval_request(
    request: &InboundFileTransferApprovalRequest,
) -> Result<()> {
    if request.schema_version != InboundFileTransferApprovalRequest::SCHEMA_VERSION {
        bail!("unsupported inbound file approval request schema version");
    }
    CrossNetworkTransferId::parse(request.transfer_id.clone())?;
    for (field, value) in [
        ("session_id", request.session_id.as_str()),
        ("target_runtime_id", request.target_runtime_id.as_str()),
        (
            "authenticated_peer_device_id",
            request.authenticated_peer_device_id.as_str(),
        ),
        (
            "authenticated_peer_device_name",
            request.authenticated_peer_device_name.as_str(),
        ),
        (
            "authenticated_peer_protocol_fingerprint",
            request.authenticated_peer_protocol_fingerprint.as_str(),
        ),
    ] {
        if value.is_empty()
            || value.trim() != value
            || value.len() > 1024
            || value.chars().any(char::is_control)
        {
            bail!("inbound file approval {field} is invalid");
        }
    }
    if request.metadata_sha256_hex.len() != 64
        || !request
            .metadata_sha256_hex
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
    {
        bail!("inbound file approval metadata digest must be lowercase SHA-256 hex");
    }
    if request.file_name.is_empty()
        || request.file_name.trim() != request.file_name
        || request.file_name.len() > 255
        || request.file_name == "."
        || request.file_name == ".."
        || request.file_name.chars().any(|character| {
            character.is_control() || matches!(character, '/' | '\\' | '\u{2044}' | '\u{2215}')
        })
        || request.file_size > MAX_TRANSFER_BYTES
    {
        bail!("inbound file approval metadata is outside the bounded file contract");
    }
    let state_is_valid = match request.status {
        InboundFileTransferApprovalStatus::PendingDecision => {
            request.decision.is_none()
                && request.applied_at.is_none()
                && request.failure_reason.is_none()
        }
        InboundFileTransferApprovalStatus::DecisionRequested => {
            request.decision.is_some()
                && request.applied_at.is_none()
                && request.failure_reason.is_none()
        }
        InboundFileTransferApprovalStatus::AgentApplied => {
            request.decision.is_some()
                && request.applied_at.is_some()
                && request.failure_reason.is_none()
        }
        InboundFileTransferApprovalStatus::AgentFailed => {
            request.decision.is_some()
                && request.applied_at.is_none()
                && request
                    .failure_reason
                    .as_deref()
                    .is_some_and(|reason| !reason.is_empty() && reason.len() <= 128)
        }
    };
    if !state_is_valid || request.updated_at < request.created_at {
        bail!("inbound file approval state transition is invalid");
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
    if looks_like_network_locator(&device.display_name) {
        bail!(
            "nearby discovery display_name for device_ref in scan `{scan_id}` must not expose a network locator"
        );
    }
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

pub(crate) fn looks_like_network_locator(value: &str) -> bool {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return false;
    }
    let lower = trimmed.to_ascii_lowercase();
    trimmed.parse::<std::net::IpAddr>().is_ok()
        || trimmed.contains(':')
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains('@')
        || lower == "localhost"
        || lower.ends_with(".local")
        || lower.contains("://")
        || looks_like_dns_name(trimmed)
}

fn looks_like_dns_name(value: &str) -> bool {
    let candidate = value.strip_suffix('.').unwrap_or(value);
    if candidate.len() > 253 || !candidate.contains('.') {
        return false;
    }
    let mut labels = candidate.split('.').peekable();
    let mut final_label = None;
    while let Some(label) = labels.next() {
        if label.is_empty()
            || label.len() > 63
            || !label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            || label.starts_with('-')
            || label.ends_with('-')
        {
            return false;
        }
        if labels.peek().is_none() {
            final_label = Some(label);
        }
    }
    final_label.is_some_and(|label| {
        label.len() >= 2 && label.bytes().any(|byte| byte.is_ascii_alphabetic())
    })
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
    validate_file_transfer_source_size(metadata.len())?;
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

fn validate_file_transfer_source_size(size_bytes: u64) -> Result<()> {
    if size_bytes > MAX_TRANSFER_BYTES {
        bail!("file transfer source exceeds the protocol size limit");
    }
    Ok(())
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
    let metadata = std::fs::symlink_metadata(path)
        .with_context(|| format!("failed to inspect file {}", path.display()))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        bail!(
            "private state file {} is not a regular file",
            path.display()
        );
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let permissions = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(path, permissions)
            .with_context(|| format!("failed to set permissions on {}", path.display()))?;
    }

    Ok(())
}

fn validate_managed_session_control_registry(
    path: &Path,
    registry: &ManagedSessionControlRegistry,
) -> Result<()> {
    validate_managed_session_control_registry_shape(path, registry)?;
    for (session_id, control) in &registry.sessions {
        if control.schema_version != ManagedSessionControl::SCHEMA_VERSION {
            bail!(
                "unsupported managed session control schema version {} for session `{}`; expected {}",
                control.schema_version,
                session_id,
                ManagedSessionControl::SCHEMA_VERSION
            );
        }
        validate_registration_id(&control.registration_id).with_context(|| {
            format!("managed session control `{session_id}` has an invalid registration id")
        })?;
    }
    Ok(())
}

fn validate_managed_session_control_registry_shape(
    path: &Path,
    registry: &ManagedSessionControlRegistry,
) -> Result<()> {
    if registry.schema_version != ManagedSessionControlRegistry::SCHEMA_VERSION {
        bail!(
            "unsupported managed session control registry schema version {} in {}; expected {}",
            registry.schema_version,
            path.display(),
            ManagedSessionControlRegistry::SCHEMA_VERSION
        );
    }
    if registry.sessions.len() > ManagedSessionControlRegistry::MAX_SESSIONS {
        bail!(
            "managed session control registry has {} entries in {}; max {}",
            registry.sessions.len(),
            path.display(),
            ManagedSessionControlRegistry::MAX_SESSIONS
        );
    }
    for (session_id, control) in &registry.sessions {
        if session_id.is_empty() || control.session_id.is_empty() {
            bail!("managed session control identifiers must not be empty");
        }
        if session_id != &control.session_id {
            bail!("managed session control key does not match its session identifier");
        }
        if control.local_device_id.trim().is_empty()
            || control.signaling_server_origin.trim().is_empty()
            || control.signaling_session_token.is_empty()
        {
            bail!("managed session control `{session_id}` is missing required runtime authority");
        }
    }
    Ok(())
}

async fn mutate_managed_session_controls<R, F>(paths: &AgentPaths, update: F) -> Result<R>
where
    R: Send + 'static,
    F: FnOnce(&mut ManagedSessionControlRegistry) -> R + Send + 'static,
{
    ensure_identity_layout(paths).await?;
    let registry_path = session_controls_file(paths);
    let lock_path = managed_session_controls_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_managed_session_controls_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, true)?;
        let mut registry = load_managed_session_controls_unlocked(&registry_path)?;
        let output = update(&mut registry);
        registry.schema_version = ManagedSessionControlRegistry::SCHEMA_VERSION;
        store_managed_session_controls_unlocked(&registry_path, &registry)?;
        Ok(output)
    })
    .await
    .context("managed session controls mutation task panicked")?
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

async fn try_mutate_session_registry<R, F>(paths: &AgentPaths, update: F) -> Result<R>
where
    R: Send + 'static,
    F: FnOnce(&mut SessionRegistry) -> Result<R> + Send + 'static,
{
    ensure_identity_layout(paths).await?;
    let registry_path = session_registry_file(paths);
    let lock_path = session_registry_lock_file(paths);
    tokio::task::spawn_blocking(move || {
        let _process_guard = lock_session_registry_process()?;
        let _file_lock = lock_session_registry_file(&lock_path, true)?;
        let mut registry = load_session_registry_unlocked(&registry_path)?;
        let output = update(&mut registry)?;
        registry.schema_version = SessionRegistry::SCHEMA_VERSION;
        store_session_registry_unlocked(&registry_path, &registry)?;
        Ok(output)
    })
    .await
    .context("fallible session registry mutation task panicked")?
}

async fn try_mutate_authorized_runtime_session<R, F>(
    paths: &AgentPaths,
    session_id: &str,
    expected_runtime_id: &str,
    update: F,
) -> Result<R>
where
    R: Send + 'static,
    F: FnOnce(&mut SessionRegistry) -> Result<R> + Send + 'static,
{
    ensure_identity_layout(paths).await?;
    let session_registry_path = session_registry_file(paths);
    let session_registry_lock_path = session_registry_lock_file(paths);
    let control_registry_path = session_controls_file(paths);
    let control_registry_lock_path = managed_session_controls_lock_file(paths);
    let session_id = session_id.to_owned();
    let expected_runtime_id = expected_runtime_id.to_owned();
    tokio::task::spawn_blocking(move || {
        let _session_process_guard = lock_session_registry_process()?;
        let _control_process_guard = lock_managed_session_controls_process()?;
        let _session_file_lock = lock_session_registry_file(&session_registry_lock_path, true)?;
        let _control_file_lock = lock_session_registry_file(&control_registry_lock_path, false)?;
        let controls = load_managed_session_controls_unlocked(&control_registry_path)?;
        let mut sessions = load_session_registry_unlocked(&session_registry_path)?;
        let session = require_runtime_incarnation(&sessions, &session_id, &expected_runtime_id)?;
        let control = controls
            .get(&session_id)
            .ok_or_else(|| anyhow!("managed runtime has no control authority"))?;
        if !managed_session_registration_matches(session, control) {
            bail!("managed runtime no longer owns matching active control authority");
        }
        let output = update(&mut sessions)?;
        sessions.schema_version = SessionRegistry::SCHEMA_VERSION;
        store_session_registry_unlocked(&session_registry_path, &sessions)?;
        Ok(output)
    })
    .await
    .context("authorized runtime session mutation task panicked")?
}

async fn write_json_atomic_private<T>(path: &Path, value: &T) -> Result<()>
where
    T: Serialize,
{
    let body = serde_json::to_vec_pretty(value).context("failed to encode private json")?;
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || write_private_file_atomically(&path, &body))
        .await
        .context("private JSON persistence task panicked")?
}

fn write_private_file_atomically(path: &Path, body: &[u8]) -> Result<()> {
    let file_name = path
        .file_name()
        .ok_or_else(|| anyhow!("private JSON path missing filename"))?
        .to_string_lossy();
    let temp_path = path.with_file_name(format!(".{file_name}.tmp-{}", uuid::Uuid::now_v7()));

    let write_result = (|| -> Result<()> {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temp_path)
            .with_context(|| format!("failed to create {}", temp_path.display()))?;
        file.write_all(body)
            .with_context(|| format!("failed to write {}", temp_path.display()))?;
        file.sync_all()
            .with_context(|| format!("failed to sync {}", temp_path.display()))?;
        restrict_file_permissions_blocking(&temp_path)?;

        std::fs::rename(&temp_path, path)
            .with_context(|| format!("failed to persist {}", path.display()))?;
        restrict_file_permissions_blocking(path)?;

        #[cfg(unix)]
        {
            let parent = path
                .parent()
                .ok_or_else(|| anyhow!("private JSON path missing parent directory"))?;
            std::fs::File::open(parent)
                .with_context(|| format!("failed to open {} for sync", parent.display()))?
                .sync_all()
                .with_context(|| format!("failed to sync {}", parent.display()))?;
        }
        Ok(())
    })();

    if let Err(error) = write_result {
        match std::fs::remove_file(&temp_path) {
            Ok(()) => return Err(error),
            Err(cleanup_error) if cleanup_error.kind() == std::io::ErrorKind::NotFound => {
                return Err(error);
            }
            Err(cleanup_error) => {
                return Err(error.context(format!(
                    "also failed to remove temporary private file {}: {cleanup_error}",
                    temp_path.display()
                )));
            }
        }
    }
    Ok(())
}

fn remove_private_file_durably(path: &Path) -> Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to remove private file {}", path.display()));
        }
    }
    #[cfg(unix)]
    {
        let parent = path
            .parent()
            .ok_or_else(|| anyhow!("private file path missing parent directory"))?;
        std::fs::File::open(parent)
            .with_context(|| format!("failed to open {} for sync", parent.display()))?
            .sync_all()
            .with_context(|| format!("failed to sync {}", parent.display()))?;
    }
    Ok(())
}

async fn load_json<T>(path: &Path) -> Result<Option<T>>
where
    T: for<'de> Deserialize<'de>,
{
    match fs::symlink_metadata(path).await {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            bail!("private JSON path {} is not a regular file", path.display());
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("failed to inspect private JSON {}", path.display()));
        }
    }
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

fn auth_session_generation_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.identity_dir.join("auth-session-generation.json")
}

fn signing_key_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.identity_dir.join("protocol-signing-key.json")
}

fn signing_key_slot_file(
    paths: &AgentPaths,
    algorithm: ProtocolSigningAlgorithm,
) -> std::path::PathBuf {
    paths.identity_dir.join(format!(
        "protocol-signing-key-{:04x}.json",
        algorithm.wire_code()
    ))
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

fn managed_session_registration_journal_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.runtime_dir.join("managed-session-registration.json")
}

fn managed_session_controls_lock_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths.session_controls_lock_file.clone()
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

fn inbound_file_transfer_approval_registry_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths
        .runtime_dir
        .join("inbound-file-transfer-approvals.json")
}

fn inbound_file_transfer_approval_registry_lock_file(paths: &AgentPaths) -> std::path::PathBuf {
    paths
        .runtime_dir
        .join("inbound-file-transfer-approvals.json.lock")
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
    use skybridge_core::{
        RuntimeSessionRole, RuntimeSessionSource, SessionReadiness, SignalingBackend,
        SignalingHandleId,
    };

    fn test_paths(name: &str) -> AgentPaths {
        crate::runtime::resolve_paths(Some(std::env::temp_dir().join(format!(
            "skybridge-agent-state-{name}-{}",
            uuid::Uuid::now_v7()
        ))))
        .expect("temporary paths should resolve")
    }

    #[test]
    fn protocol_signing_algorithm_config_rejects_empty_and_unknown_values() {
        assert_eq!(
            parse_optional_protocol_signing_algorithm(Some("ML-DSA-87")).unwrap(),
            Some(ProtocolSigningAlgorithm::MlDsa87)
        );
        assert!(parse_optional_protocol_signing_algorithm(Some(" ")).is_err());
        assert!(parse_optional_protocol_signing_algorithm(Some("ML-DSA-99")).is_err());
        assert_eq!(
            parse_optional_protocol_signing_algorithm(None).unwrap(),
            None
        );
    }

    #[test]
    fn file_transfer_source_size_enforces_protocol_boundary_before_hashing() {
        validate_file_transfer_source_size(MAX_TRANSFER_BYTES)
            .expect("the protocol limit itself is allowed");
        assert!(validate_file_transfer_source_size(MAX_TRANSFER_BYTES + 1).is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn identity_load_rejects_a_preplaced_symlink_without_touching_its_target() {
        use std::os::unix::fs::symlink;

        let paths = test_paths("identity-symlink");
        ensure_identity_layout(&paths)
            .await
            .expect("create private identity layout");
        let victim = paths.root.join("identity-victim.json");
        let victim_bytes = b"external identity bytes";
        tokio::fs::write(&victim, victim_bytes)
            .await
            .expect("seed victim");
        symlink(&victim, &paths.identity_file).expect("preplace identity symlink");

        let error = crate::runtime::load_identity_state(&paths)
            .await
            .expect_err("identity symlink must fail closed");
        assert!(error.to_string().contains("not a regular file"));
        assert_eq!(
            tokio::fs::read(&victim).await.expect("read victim"),
            victim_bytes
        );
        assert!(
            tokio::fs::symlink_metadata(&paths.identity_file)
                .await
                .expect("identity symlink metadata")
                .file_type()
                .is_symlink()
        );
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn auth_store_atomically_replaces_a_symlink_without_writing_its_target() {
        use std::os::unix::fs::symlink;

        let paths = test_paths("auth-symlink");
        ensure_identity_layout(&paths)
            .await
            .expect("create private identity layout");
        let victim = paths.root.join("auth-victim.json");
        let victim_bytes = b"external auth bytes";
        tokio::fs::write(&victim, victim_bytes)
            .await
            .expect("seed victim");
        let auth_path = auth_session_file(&paths);
        symlink(&victim, &auth_path).expect("preplace auth symlink");
        let session = AuthSession {
            access_token: "access-secret".to_owned(),
            refresh_token: Some("refresh-secret".to_owned()),
            user_identifier: "user-1".to_owned(),
            nebula_id: None,
            display_name: "User".to_owned(),
            issued_at: OffsetDateTime::now_utc(),
        };

        store_auth_session(&paths, &session)
            .await
            .expect("atomic auth replacement");
        assert_eq!(
            tokio::fs::read(&victim).await.expect("read victim"),
            victim_bytes
        );
        let auth_metadata = tokio::fs::symlink_metadata(&auth_path)
            .await
            .expect("auth metadata");
        assert!(auth_metadata.is_file());
        assert!(!auth_metadata.file_type().is_symlink());
        assert_eq!(
            load_auth_session(&paths)
                .await
                .expect("load auth")
                .expect("stored auth"),
            session
        );
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn refresh_cas_cannot_resurrect_a_session_cleared_while_refresh_was_in_flight() {
        let paths = test_paths("auth-refresh-logout-cas");
        ensure_device_identity(&paths)
            .await
            .expect("initialize identity");
        let original = AuthSession {
            access_token: "expired-access".to_owned(),
            refresh_token: Some("refresh-secret".to_owned()),
            user_identifier: "user-1".to_owned(),
            nebula_id: None,
            display_name: "User".to_owned(),
            issued_at: OffsetDateTime::UNIX_EPOCH,
        };
        store_auth_session(&paths, &original)
            .await
            .expect("store original auth");
        let (refresh_snapshot, expected_generation) = load_auth_session_snapshot(&paths)
            .await
            .expect("load refresh CAS snapshot");
        assert_eq!(refresh_snapshot.as_ref(), Some(&original));
        let refreshed = AuthSession {
            access_token: "new-access".to_owned(),
            refresh_token: Some("new-refresh".to_owned()),
            issued_at: OffsetDateTime::now_utc(),
            ..original.clone()
        };

        clear_auth_session(&paths)
            .await
            .expect("logout while refresh is in flight");
        let error = store_refreshed_auth_session_if_unchanged(
            &paths,
            &original,
            expected_generation,
            &refreshed,
        )
        .await
        .expect_err("stale refresh must not recreate a cleared session");
        assert!(error.to_string().contains("changed while token refresh"));
        assert!(
            load_auth_session(&paths)
                .await
                .expect("load auth after logout")
                .is_none()
        );
        let identity = crate::runtime::load_identity_state(&paths)
            .await
            .expect("load identity")
            .expect("identity");
        assert_eq!(identity.auth_state, AuthState::LoggedOut);
        assert!(identity.account_id.is_none());
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_login_and_enrollment_preserve_both_identity_updates() {
        let paths = test_paths("auth-enrollment-serialization");
        ensure_device_identity(&paths)
            .await
            .expect("initialize identity");
        let session = AuthSession {
            access_token: "access-secret".to_owned(),
            refresh_token: None,
            user_identifier: "user-concurrent".to_owned(),
            nebula_id: None,
            display_name: "Concurrent User".to_owned(),
            issued_at: OffsetDateTime::now_utc(),
        };
        let login_paths = paths.clone();
        let enrollment_paths = paths.clone();
        let (login, enrollment) = tokio::join!(
            async move { store_auth_session(&login_paths, &session).await },
            async move {
                update_enrollment_status(
                    &enrollment_paths,
                    EnrollmentStatus::Enrolled,
                    Some("Enrolled Device"),
                )
                .await
            }
        );
        login.expect("concurrent login");
        enrollment.expect("concurrent enrollment");

        let identity = crate::runtime::load_identity_state(&paths)
            .await
            .expect("load identity")
            .expect("identity");
        assert_eq!(identity.auth_state, AuthState::LoggedIn);
        assert_eq!(identity.account_id.as_deref(), Some("user-concurrent"));
        assert_eq!(
            identity.device.enrollment_status,
            EnrollmentStatus::Enrolled
        );
        assert_eq!(identity.device.device_name, "Enrolled Device");
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[test]
    fn atomic_private_write_failure_cleans_temp_and_preserves_existing_destination() {
        let paths = test_paths("atomic-private-failure");
        std::fs::create_dir_all(&paths.identity_dir).expect("create identity directory");
        let destination = paths.identity_dir.join("destination-is-directory");
        std::fs::create_dir(&destination).expect("seed destination directory");

        let error = write_private_file_atomically(&destination, b"secret")
            .expect_err("directory destination must reject atomic file publication");
        assert!(error.to_string().contains("failed to persist"));
        assert!(destination.is_dir());
        let temp_prefix = ".destination-is-directory.tmp-";
        assert!(
            std::fs::read_dir(&paths.identity_dir)
                .expect("list identity directory")
                .filter_map(|entry| entry.ok())
                .all(|entry| !entry.file_name().to_string_lossy().starts_with(temp_prefix)),
            "failed atomic publication must not leave secret temp files"
        );
        std::fs::remove_dir_all(&paths.root).ok();
    }

    #[test]
    fn stored_mldsa87_key_decodes_only_with_exact_schema_and_matching_keypair() {
        let signing_key =
            generate_signing_key(ProtocolSigningAlgorithm::MlDsa87).expect("generate ML-DSA-87");
        let (public_key, secret_key) = match signing_key {
            ProtocolSigningKeyMaterial::MlDsa87 {
                public_key,
                secret_key,
            } => (public_key, secret_key),
            _ => panic!("expected ML-DSA-87 material"),
        };
        let stored = StoredSigningKey {
            schema_version: StoredSigningKey::SCHEMA_VERSION,
            algorithm: ProtocolSigningAlgorithm::MlDsa87,
            public_key_base64: Some(STANDARD.encode(&public_key)),
            secret_key_base64: STANDARD.encode(&secret_key),
        };
        assert!(matches!(
            decode_signing_key(&stored).unwrap(),
            ProtocolSigningKeyMaterial::MlDsa87 { .. }
        ));

        let mut wrong_schema = stored.clone();
        wrong_schema.schema_version += 1;
        assert!(decode_signing_key(&wrong_schema).is_err());

        let (other_public_key, _) = skybridge_core::mldsa87_generate_keypair();
        let mut mismatched = stored;
        mismatched.public_key_base64 = Some(STANDARD.encode(other_public_key));
        assert!(decode_signing_key(&mismatched).is_err());
    }

    #[tokio::test]
    async fn bridge_mldsa_slot_never_overwrites_primary_protocol_identity() {
        let paths = test_paths("bridge-mldsa-slot");
        ensure_identity_layout(&paths)
            .await
            .expect("identity layout should exist");
        let primary = generate_signing_key(ProtocolSigningAlgorithm::Ed25519)
            .expect("generate primary Ed25519 identity");
        store_signing_key(&paths, &primary)
            .await
            .expect("store primary identity");
        let primary_before = tokio::fs::read(signing_key_file(&paths))
            .await
            .expect("read primary identity");

        let bridge = ensure_mldsa_signing_key(&paths, ProtocolSigningAlgorithm::MlDsa87)
            .await
            .expect("create isolated ML-DSA-87 bridge identity");
        assert_eq!(bridge.algorithm(), ProtocolSigningAlgorithm::MlDsa87);
        let primary_after = tokio::fs::read(signing_key_file(&paths))
            .await
            .expect("read primary identity after bridge creation");
        assert_eq!(primary_before, primary_after);
        assert!(signing_key_slot_file(&paths, ProtocolSigningAlgorithm::MlDsa87).exists());

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_mldsa87_identity_initialization_returns_one_persisted_identity() {
        let paths = test_paths("concurrent-mldsa87-identity");
        let first_paths = paths.clone();
        let second_paths = paths.clone();
        let (first, second) = tokio::join!(
            ensure_rust_pqc_identity_for_algorithm(&first_paths, ProtocolSigningAlgorithm::MlDsa87,),
            ensure_rust_pqc_identity_for_algorithm(
                &second_paths,
                ProtocolSigningAlgorithm::MlDsa87,
            )
        );
        let first = first.expect("first identity initialization");
        let second = second.expect("second identity initialization");
        assert_eq!(first, second);

        let stored = load_json::<StoredSigningKey>(&signing_key_slot_file(
            &paths,
            ProtocolSigningAlgorithm::MlDsa87,
        ))
        .await
        .expect("load persisted ML-DSA-87 slot")
        .expect("persisted ML-DSA-87 slot should exist");
        let stored = decode_signing_key(&stored).expect("persisted slot should validate");
        assert_eq!(stored.public_key_bytes(), first.signing_public_key);

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
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

    fn managed_session_control(session_id: &str) -> ManagedSessionControl {
        ManagedSessionControl::new(
            session_id,
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "local-device",
            "https://signal.example.com",
            format!("session-token-{session_id}"),
            None,
        )
    }

    fn managed_registration_pair(
        session_id: &str,
    ) -> (RuntimeSessionRecord, ManagedSessionControl) {
        let session = RuntimeSessionRecord::new(
            format!("runtime-{session_id}"),
            session_id,
            RuntimeSessionRole::Initiator,
            RuntimeSessionSource::Code,
            "https://signal.example.com",
            "local-device",
            Some("remote-device".to_owned()),
            Some("Remote Device".to_owned()),
            Some("peer-fingerprint".to_owned()),
            RuntimeSessionState::Connecting,
        );
        let mut control = managed_session_control(session_id);
        control.target_runtime_id = session.runtime_id.clone();
        (session, control)
    }

    fn attach_verified_connection_evidence(session: &mut RuntimeSessionRecord) {
        let now = OffsetDateTime::now_utc();
        session.handshake_completed_at = Some(now);
        session.authenticated_peer = Some(RuntimeAuthenticatedPeerObservation {
            device_id: "remote-device".to_owned(),
            device_name: "Remote Device".to_owned(),
            platform: Some("ios".to_owned()),
            capabilities: Some(vec!["file_transfer".to_owned()]),
            file_transfer_port: Some(8080),
            remote_control_port: None,
            sbwc_counter: 1,
            observed_at: now,
        });
        session.selected_ice_route = Some(RuntimeSelectedIceRouteObservation {
            remote_address: "192.0.2.10".to_owned(),
            remote_port: 49152,
            protocol: "udp".to_owned(),
            local_candidate_type: "host".to_owned(),
            remote_candidate_type: "host".to_owned(),
            kind: skybridge_core::RuntimeSessionRouteKind::Direct,
            observed_at: now,
        });
    }

    fn inbound_approval_request(
        session_id: &str,
        runtime_id: &str,
        transfer_seed: u128,
        peer_name: &str,
    ) -> InboundFileTransferApprovalRequest {
        InboundFileTransferApprovalRequest::pending(
            InboundFileTransferApprovalBinding {
                transfer_id: uuid::Uuid::from_u128(transfer_seed + 1)
                    .hyphenated()
                    .to_string(),
                session_id: session_id.to_owned(),
                target_runtime_id: runtime_id.to_owned(),
                authenticated_peer_device_id: "remote-device".to_owned(),
                authenticated_peer_device_name: peer_name.to_owned(),
                authenticated_peer_protocol_fingerprint: "peer-fingerprint".to_owned(),
                metadata_sha256_hex: "22".repeat(32),
                file_name: "payload.bin".to_owned(),
                file_size: 4,
            },
            OffsetDateTime::now_utc(),
        )
    }

    #[test]
    fn stale_inbound_approvals_are_terminalized_before_capacity_reuse() {
        let now = OffsetDateTime::now_utc();
        let (mut current, _) = managed_registration_pair("approval-recovery");
        current.runtime_id = "runtime-current".to_owned();
        current.readiness = SessionReadiness::HandshakeComplete {
            session_id: current.session_id.clone(),
            negotiated_suite: "X-Wing".to_owned(),
        };
        attach_verified_connection_evidence(&mut current);
        let mut sessions = SessionRegistry::default();
        sessions.insert(current).expect("insert current session");
        let mut approvals = InboundFileTransferApprovalRegistry::default();
        for index in 0..InboundFileTransferApprovalRegistry::MAX_REQUESTS as u128 {
            approvals
                .insert(inbound_approval_request(
                    "approval-recovery",
                    &format!("runtime-stale-{index}"),
                    index,
                    "Remote Device",
                ))
                .expect("fill stale approval registry");
        }
        assert!(
            reconcile_inbound_file_approvals(&mut approvals, &sessions, now)
                .expect("reconcile stale approvals")
        );
        assert!(
            approvals
                .requests
                .values()
                .all(|request| request.is_terminal())
        );
        let current = inbound_approval_request(
            "approval-recovery",
            "runtime-current",
            10_000,
            "Remote Device",
        );
        let current_key = current.registry_key();
        approvals
            .insert(current)
            .expect("terminal stale entries must be evictable");
        assert_eq!(
            approvals.requests.len(),
            InboundFileTransferApprovalRegistry::MAX_REQUESTS
        );
        assert!(approvals.requests.contains_key(&current_key));
    }

    #[test]
    fn authenticated_peer_rename_does_not_change_approval_authority() {
        let now = OffsetDateTime::now_utc();
        let (mut current, _) = managed_registration_pair("approval-rename");
        current.runtime_id = "runtime-current".to_owned();
        current.readiness = SessionReadiness::HandshakeComplete {
            session_id: current.session_id.clone(),
            negotiated_suite: "X-Wing".to_owned(),
        };
        attach_verified_connection_evidence(&mut current);
        current
            .authenticated_peer
            .as_mut()
            .expect("authenticated peer")
            .device_name = "Renamed Device".to_owned();
        let mut sessions = SessionRegistry::default();
        sessions.insert(current).expect("insert current session");
        let request = inbound_approval_request(
            "approval-rename",
            "runtime-current",
            1,
            "Old Display Snapshot",
        );
        let key = request.registry_key();
        let mut approvals = InboundFileTransferApprovalRegistry::default();
        approvals.insert(request).expect("insert approval");
        assert!(
            !reconcile_inbound_file_approvals(&mut approvals, &sessions, now)
                .expect("rename is not an authority change")
        );
        assert_eq!(
            approvals.requests.get(&key).expect("approval").status,
            InboundFileTransferApprovalStatus::PendingDecision
        );
    }

    #[test]
    fn persistent_approval_registry_is_the_pending_timeout_authority() {
        let now = OffsetDateTime::now_utc();
        let (mut current, _) = managed_registration_pair("approval-timeout");
        current.runtime_id = "runtime-current".to_owned();
        current.readiness = SessionReadiness::HandshakeComplete {
            session_id: current.session_id.clone(),
            negotiated_suite: "X-Wing".to_owned(),
        };
        attach_verified_connection_evidence(&mut current);
        let mut sessions = SessionRegistry::default();
        sessions.insert(current).expect("insert current session");
        let mut request =
            inbound_approval_request("approval-timeout", "runtime-current", 2, "Remote Device");
        request.created_at = now - time::Duration::minutes(6);
        request.updated_at = request.created_at;
        let key = request.registry_key();
        let mut approvals = InboundFileTransferApprovalRegistry::default();
        approvals.insert(request).expect("insert approval");

        assert!(
            reconcile_inbound_file_approvals(&mut approvals, &sessions, now)
                .expect("reconcile expired pending approval")
        );
        let expired = approvals.requests.get(&key).expect("expired approval");
        assert_eq!(
            expired.status,
            InboundFileTransferApprovalStatus::DecisionRequested
        );
        assert_eq!(
            expired.decision,
            Some(InboundFileTransferApprovalDecision::Expire)
        );
        assert!(expired.applied_at.is_none());
    }

    fn persist_registration_journal(
        paths: &AgentPaths,
        session: RuntimeSessionRecord,
        control: ManagedSessionControl,
    ) {
        persist_registration_journal_with_previous(paths, None, None, session, control);
    }

    fn persist_registration_journal_with_previous(
        paths: &AgentPaths,
        previous_session: Option<RuntimeSessionRecord>,
        previous_control: Option<ManagedSessionControl>,
        session: RuntimeSessionRecord,
        control: ManagedSessionControl,
    ) {
        let journal = ManagedSessionRegistrationJournal {
            schema_version: ManagedSessionRegistrationJournal::SCHEMA_VERSION,
            previous_session,
            previous_control,
            session,
            control,
        };
        let body = serde_json::to_vec_pretty(&journal).expect("encode registration journal");
        write_private_file_atomically(&managed_session_registration_journal_file(paths), &body)
            .expect("persist registration journal");
    }

    #[tokio::test]
    async fn startup_recovery_stops_ownerless_legacy_controls() {
        let paths = test_paths("registration-ownerless-legacy-control");
        ensure_identity_layout(&paths).await.expect("create layout");
        let (session, control) = managed_registration_pair("legacy-ownerless");
        let mut sessions = SessionRegistry::default();
        sessions.insert(session).expect("insert legacy session");
        store_session_registry_unlocked(&session_registry_file(&paths), &sessions)
            .expect("persist legacy session");

        let mut controls = ManagedSessionControlRegistry::default();
        controls.insert(control).expect("insert legacy control");
        let mut legacy = serde_json::to_value(controls).expect("encode legacy controls");
        let legacy_control = legacy["sessions"]["legacy-ownerless"]
            .as_object_mut()
            .expect("legacy control object");
        legacy_control.insert(
            "schema_version".to_owned(),
            serde_json::Value::from(LEGACY_MANAGED_SESSION_CONTROL_SCHEMA_VERSION),
        );
        legacy_control.remove("registration_id");
        write_private_file_atomically(
            &session_controls_file(&paths),
            &serde_json::to_vec_pretty(&legacy).expect("serialize legacy controls"),
        )
        .expect("persist legacy controls");

        recover_managed_session_state(&paths)
            .await
            .expect("legacy ownerless state should recover fail-closed");
        let recovered = load_session_registry(&paths).await.expect("load sessions");
        assert_eq!(
            recovered
                .get("legacy-ownerless")
                .expect("legacy runtime audit evidence")
                .state,
            RuntimeSessionState::Disconnected
        );
        assert!(
            load_managed_session_controls(&paths)
                .await
                .expect("load controls")
                .sessions
                .is_empty()
        );
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn current_control_without_registration_id_is_rejected() {
        let paths = test_paths("registration-current-missing-owner");
        ensure_identity_layout(&paths).await.expect("create layout");
        let (_, control) = managed_registration_pair("current-missing-owner");
        let mut controls = ManagedSessionControlRegistry::default();
        controls.insert(control).expect("insert control");
        let mut malformed = serde_json::to_value(controls).expect("encode controls");
        malformed["sessions"]["current-missing-owner"]
            .as_object_mut()
            .expect("control object")
            .remove("registration_id");
        write_private_file_atomically(
            &session_controls_file(&paths),
            &serde_json::to_vec_pretty(&malformed).expect("serialize malformed controls"),
        )
        .expect("persist malformed controls");

        let error = load_managed_session_controls(&paths)
            .await
            .expect_err("current ownerless control must fail closed");
        assert!(error.to_string().contains("invalid registration id"));
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn startup_recovery_discards_ownerless_legacy_registration_journal() {
        let paths = test_paths("registration-ownerless-legacy-journal");
        ensure_identity_layout(&paths).await.expect("create layout");
        let (session, control) = managed_registration_pair("legacy-journal");
        let journal = ManagedSessionRegistrationJournal {
            schema_version: LEGACY_MANAGED_SESSION_REGISTRATION_JOURNAL_SCHEMA_VERSION,
            previous_session: None,
            previous_control: None,
            session,
            control,
        };
        let mut legacy = serde_json::to_value(journal).expect("encode legacy journal");
        legacy["control"]
            .as_object_mut()
            .expect("journal control")
            .remove("registration_id");
        write_private_file_atomically(
            &managed_session_registration_journal_file(&paths),
            &serde_json::to_vec_pretty(&legacy).expect("serialize legacy journal"),
        )
        .expect("persist legacy journal");

        recover_managed_session_state(&paths)
            .await
            .expect("legacy journal should be discarded fail-closed");
        assert!(!managed_session_registration_journal_file(&paths).exists());
        assert!(
            load_session_registry(&paths)
                .await
                .expect("load sessions")
                .sessions
                .is_empty()
        );
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn startup_recovery_completes_journal_only_registration() {
        let paths = test_paths("registration-journal-only");
        ensure_identity_layout(&paths).await.expect("create layout");
        let (session, control) = managed_registration_pair("journal-only");
        persist_registration_journal(&paths, session.clone(), control.clone());

        recover_managed_session_state(&paths)
            .await
            .expect("recover journal-only registration");

        assert_eq!(
            load_session_registry(&paths)
                .await
                .expect("load sessions")
                .get(&session.session_id),
            Some(&session)
        );
        assert_eq!(
            load_managed_session_controls(&paths)
                .await
                .expect("load controls")
                .get(&control.session_id),
            Some(&control)
        );
        assert!(!managed_session_registration_journal_file(&paths).exists());
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn startup_recovery_completes_session_only_journal_stage() {
        let paths = test_paths("registration-session-only");
        ensure_identity_layout(&paths).await.expect("create layout");
        let (session, control) = managed_registration_pair("session-only");
        let mut sessions = SessionRegistry::default();
        sessions.insert(session.clone()).expect("insert session");
        store_session_registry_unlocked(&session_registry_file(&paths), &sessions)
            .expect("persist session-only stage");
        persist_registration_journal(&paths, session.clone(), control.clone());

        recover_managed_session_state(&paths)
            .await
            .expect("recover session-only journal stage");
        assert_eq!(
            load_managed_session_controls(&paths)
                .await
                .expect("load controls")
                .get(&control.session_id),
            Some(&control)
        );
        assert!(!managed_session_registration_journal_file(&paths).exists());
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn startup_recovery_completes_control_only_journal_stage() {
        let paths = test_paths("registration-control-only");
        ensure_identity_layout(&paths).await.expect("create layout");
        let (session, control) = managed_registration_pair("control-only");
        let mut controls = ManagedSessionControlRegistry::default();
        controls.insert(control.clone()).expect("insert control");
        store_managed_session_controls_unlocked(&session_controls_file(&paths), &controls)
            .expect("persist control-only stage");
        persist_registration_journal(&paths, session.clone(), control.clone());

        recover_managed_session_state(&paths)
            .await
            .expect("recover control-only journal stage");
        assert_eq!(
            load_session_registry(&paths)
                .await
                .expect("load sessions")
                .get(&session.session_id),
            Some(&session)
        );
        assert!(!managed_session_registration_journal_file(&paths).exists());
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn startup_recovery_rejects_conflicting_registration_journal() {
        let paths = test_paths("registration-conflict");
        ensure_identity_layout(&paths).await.expect("create layout");
        let (journal_session, control) = managed_registration_pair("conflicting");
        let mut persisted_session = journal_session.clone();
        persisted_session.runtime_id = "runtime-conflicting-replacement".to_owned();
        let mut sessions = SessionRegistry::default();
        sessions
            .insert(persisted_session.clone())
            .expect("insert conflicting session");
        store_session_registry_unlocked(&session_registry_file(&paths), &sessions)
            .expect("persist conflicting session");
        persist_registration_journal(&paths, journal_session, control);

        let error = recover_managed_session_state(&paths)
            .await
            .expect_err("conflicting journal must fail closed");
        assert!(error.to_string().contains("conflicts"));
        assert!(managed_session_registration_journal_file(&paths).exists());
        assert_eq!(
            load_session_registry(&paths)
                .await
                .expect("load sessions")
                .get("conflicting"),
            Some(&persisted_session)
        );
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn replacement_registration_journal_is_redo_safe_at_every_registry_write_window() {
        for (label, session_committed, control_committed) in [
            ("before-writes", false, false),
            ("after-session", true, false),
            ("after-control", false, true),
            ("after-both", true, true),
        ] {
            let paths = test_paths(&format!("registration-replacement-{label}"));
            ensure_identity_layout(&paths).await.expect("create layout");
            let (previous_session, previous_control) =
                managed_registration_pair("replacement-crash");
            let mut committed_session = previous_session.clone();
            committed_session.runtime_id = "runtime-replacement-committed".to_owned();
            let mut committed_control = previous_control.clone();
            committed_control.target_runtime_id = committed_session.runtime_id.clone();
            committed_control.signaling_session_token = "replacement-token".to_owned();

            let mut sessions = SessionRegistry::default();
            sessions
                .insert(if session_committed {
                    committed_session.clone()
                } else {
                    previous_session.clone()
                })
                .expect("insert crash-window session");
            let mut controls = ManagedSessionControlRegistry::default();
            controls
                .insert(if control_committed {
                    committed_control.clone()
                } else {
                    previous_control.clone()
                })
                .expect("insert crash-window control");
            store_session_registry_unlocked(&session_registry_file(&paths), &sessions)
                .expect("persist crash-window session");
            store_managed_session_controls_unlocked(&session_controls_file(&paths), &controls)
                .expect("persist crash-window control");
            persist_registration_journal_with_previous(
                &paths,
                Some(previous_session),
                Some(previous_control),
                committed_session.clone(),
                committed_control.clone(),
            );

            recover_managed_session_state(&paths)
                .await
                .expect("redo replacement registration");
            assert_eq!(
                load_session_registry(&paths)
                    .await
                    .expect("load sessions")
                    .get("replacement-crash"),
                Some(&committed_session),
                "session redo mismatch for {label}"
            );
            assert_eq!(
                load_managed_session_controls(&paths)
                    .await
                    .expect("load controls")
                    .get("replacement-crash"),
                Some(&committed_control),
                "control redo mismatch for {label}"
            );
            assert!(!managed_session_registration_journal_file(&paths).exists());
            let _ = tokio::fs::remove_dir_all(&paths.root).await;
        }
    }

    #[tokio::test]
    async fn committed_registration_reports_cleanup_pending_and_recovers_journal() {
        let paths = test_paths("registration-cleanup-failure");
        ensure_identity_layout(&paths).await.expect("create layout");
        let (session, control) = managed_registration_pair("cleanup-failure");
        let mut sessions = SessionRegistry::default();
        sessions.insert(session.clone()).expect("insert session");
        let mut controls = ManagedSessionControlRegistry::default();
        controls.insert(control.clone()).expect("insert control");
        let journal = ManagedSessionRegistrationJournal {
            schema_version: ManagedSessionRegistrationJournal::SCHEMA_VERSION,
            previous_session: None,
            previous_control: None,
            session: session.clone(),
            control: control.clone(),
        };

        let commit = commit_registration_unlocked(
            &session_registry_file(&paths),
            &session_controls_file(&paths),
            &managed_session_registration_journal_file(&paths),
            &journal,
            sessions,
            controls,
            |_| bail!("injected journal cleanup failure"),
        )
        .expect("committed pair must not be reported as registration failure");
        assert_eq!(
            commit.journal_state,
            ManagedSessionRegistrationJournalState::RecoveryPending
        );
        assert!(managed_session_registration_journal_file(&paths).exists());
        assert_eq!(commit.sessions.get(&session.session_id), Some(&session));
        assert_eq!(commit.controls.get(&control.session_id), Some(&control));

        assert_eq!(
            recover_managed_session_state(&paths)
                .await
                .expect("replay committed journal"),
            ManagedSessionRegistrationJournalState::RemovedDurably
        );
        assert!(!managed_session_registration_journal_file(&paths).exists());
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn startup_recovery_fails_closed_for_unjournaled_orphans_and_mismatch() {
        let paths = test_paths("registration-orphans");
        ensure_identity_layout(&paths).await.expect("create layout");
        let (session_only, _) = managed_registration_pair("orphan-session");
        let (_, control_only) = managed_registration_pair("orphan-control");
        let (mismatched_session, mut mismatched_control) =
            managed_registration_pair("mismatched-pair");
        mismatched_control.target_runtime_id = "runtime-other".to_owned();
        let mut sessions = SessionRegistry::default();
        sessions
            .insert(session_only)
            .expect("insert session orphan");
        sessions
            .insert(mismatched_session)
            .expect("insert mismatched session");
        let mut controls = ManagedSessionControlRegistry::default();
        controls
            .insert(control_only)
            .expect("insert control orphan");
        controls
            .insert(mismatched_control)
            .expect("insert mismatched control");
        store_session_registry_unlocked(&session_registry_file(&paths), &sessions)
            .expect("persist sessions");
        store_managed_session_controls_unlocked(&session_controls_file(&paths), &controls)
            .expect("persist controls");

        recover_managed_session_state(&paths)
            .await
            .expect("recover unjournaled asymmetry");
        let recovered_sessions = load_session_registry(&paths).await.expect("load sessions");
        for session_id in ["orphan-session", "mismatched-pair"] {
            let session = recovered_sessions
                .get(session_id)
                .expect("session retained");
            assert_eq!(session.state, RuntimeSessionState::Disconnected);
            assert_eq!(
                session.last_error.as_deref(),
                Some("orphaned managed runtime recovered at agent startup")
            );
        }
        let recovered_controls = load_managed_session_controls(&paths)
            .await
            .expect("load controls");
        assert!(recovered_controls.sessions.is_empty());
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn startup_recovery_is_idempotent_after_a_consistent_registration() {
        let paths = test_paths("registration-idempotent");
        let (session, control) = managed_registration_pair("idempotent");
        register_managed_session(&paths, session, control)
            .await
            .expect("register consistent pair");

        recover_managed_session_state(&paths)
            .await
            .expect("first recovery");
        let first_sessions = load_session_registry(&paths).await.expect("first sessions");
        let first_controls = load_managed_session_controls(&paths)
            .await
            .expect("first controls");
        recover_managed_session_state(&paths)
            .await
            .expect("second recovery");
        assert_eq!(
            load_session_registry(&paths)
                .await
                .expect("second sessions"),
            first_sessions
        );
        assert_eq!(
            load_managed_session_controls(&paths)
                .await
                .expect("second controls"),
            first_controls
        );
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn queued_runtime_events_cannot_resurrect_an_operator_disconnected_session() {
        let paths = test_paths("queued-event-after-disconnect");
        let (session, control) = managed_registration_pair("queued-terminal");
        let runtime_id = session.runtime_id.clone();
        register_managed_session(&paths, session, control)
            .await
            .expect("register managed session");
        disconnect_managed_session(
            &paths,
            "queued-terminal",
            Some("operator_requested".to_owned()),
        )
        .await
        .expect("disconnect session");

        apply_transport_event_for_runtime(
            &paths,
            "queued-terminal",
            &runtime_id,
            RuntimeSessionTransportEvent::HandshakeComplete {
                negotiated_suite: "X25519+ML-KEM-768".to_owned(),
                peer_protocol_public_key_fingerprint: "peer-fingerprint".to_owned(),
            },
        )
        .await
        .expect_err("queued handshake must lose runtime authority");
        apply_signaling_event_for_runtime(
            &paths,
            "queued-terminal",
            &runtime_id,
            SignalingLifecycleEvent::new(
                SignalingHandleId {
                    session_id: "queued-terminal".to_owned(),
                    backend: SignalingBackend::Native,
                    generation: 7,
                },
                SignalingLifecyclePhase::Bound,
            ),
        )
        .await
        .expect_err("queued bound event must lose runtime authority");

        let registry = load_session_registry(&paths)
            .await
            .expect("load terminal session");
        let terminal = registry.get("queued-terminal").expect("session retained");
        assert_eq!(terminal.state, RuntimeSessionState::Disconnected);
        assert_eq!(terminal.readiness, SessionReadiness::Idle);
        assert_eq!(terminal.last_error.as_deref(), Some("operator_requested"));
        assert!(terminal.closed_at.is_some());
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn verified_receipt_blocks_disconnect_and_replacement_until_drop() {
        let paths = test_paths("verified-receipt-permit");
        let (mut session, control) = managed_registration_pair("receipt-disconnect");
        session.state = RuntimeSessionState::Bound;
        session.readiness = SessionReadiness::HandshakeComplete {
            session_id: session.session_id.clone(),
            negotiated_suite: "X25519+ML-KEM-768".to_owned(),
        };
        attach_verified_connection_evidence(&mut session);
        let runtime_id = session.runtime_id.clone();
        let registration_id = control.registration_id.clone();
        register_managed_session(&paths, session, control)
            .await
            .expect("register receipt session");
        let receipt = verify_managed_handshake_receipt(
            &paths,
            "receipt-disconnect",
            &registration_id,
            &runtime_id,
            "X25519+ML-KEM-768",
        )
        .await
        .expect("verify receipt");
        let disconnect_paths = paths.clone();
        let mut disconnect = tokio::spawn(async move {
            disconnect_managed_session(
                &disconnect_paths,
                "receipt-disconnect",
                Some("operator_requested".to_owned()),
            )
            .await
        });
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(100), &mut disconnect)
                .await
                .is_err(),
            "disconnect must wait for the final receipt permit"
        );
        drop(receipt);
        tokio::time::timeout(std::time::Duration::from_secs(2), disconnect)
            .await
            .expect("disconnect resumes after receipt drop")
            .expect("disconnect task does not panic")
            .expect("disconnect succeeds");

        let (mut replacement, replacement_control) =
            managed_registration_pair("receipt-replacement");
        replacement.state = RuntimeSessionState::Bound;
        replacement.readiness = SessionReadiness::HandshakeComplete {
            session_id: replacement.session_id.clone(),
            negotiated_suite: "X25519+ML-KEM-768".to_owned(),
        };
        attach_verified_connection_evidence(&mut replacement);
        let original_runtime_id = replacement.runtime_id.clone();
        let original_registration_id = replacement_control.registration_id.clone();
        register_managed_session(&paths, replacement, replacement_control)
            .await
            .expect("register replacement target");
        let receipt = verify_managed_handshake_receipt(
            &paths,
            "receipt-replacement",
            &original_registration_id,
            &original_runtime_id,
            "X25519+ML-KEM-768",
        )
        .await
        .expect("verify replacement receipt");
        let (mut replacement, mut replacement_control) =
            managed_registration_pair("receipt-replacement");
        replacement.runtime_id = "runtime-receipt-new".to_owned();
        replacement_control.target_runtime_id = replacement.runtime_id.clone();
        let replacement_paths = paths.clone();
        let mut replacement_task = tokio::spawn(async move {
            register_managed_session(&replacement_paths, replacement, replacement_control).await
        });
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(100), &mut replacement_task,)
                .await
                .is_err(),
            "replacement must wait for the final receipt permit"
        );
        drop(receipt);
        tokio::time::timeout(std::time::Duration::from_secs(2), replacement_task)
            .await
            .expect("replacement resumes after receipt drop")
            .expect("replacement task does not panic")
            .expect("replacement succeeds");
        assert_eq!(
            load_session_registry(&paths)
                .await
                .expect("load replacement")
                .get("receipt-replacement")
                .expect("replacement exists")
                .runtime_id,
            "runtime-receipt-new"
        );
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn verified_receipt_rejects_replaced_registration_even_with_same_runtime_id() {
        let paths = test_paths("verified-receipt-registration-replaced");
        let (mut session, control) = managed_registration_pair("receipt-owner-replaced");
        session.state = RuntimeSessionState::Bound;
        session.readiness = SessionReadiness::HandshakeComplete {
            session_id: session.session_id.clone(),
            negotiated_suite: "X25519+ML-KEM-768".to_owned(),
        };
        attach_verified_connection_evidence(&mut session);
        let runtime_id = session.runtime_id.clone();
        let original_registration_id = control.registration_id.clone();
        register_managed_session(&paths, session.clone(), control)
            .await
            .expect("register original receipt owner");

        let mut replacement_control = managed_session_control("receipt-owner-replaced");
        replacement_control.target_runtime_id = runtime_id.clone();
        assert_ne!(
            replacement_control.registration_id, original_registration_id,
            "replacement must have distinct immutable ownership"
        );
        register_managed_session(&paths, session, replacement_control)
            .await
            .expect("replace registration while retaining runtime id");

        let error = match verify_managed_handshake_receipt(
            &paths,
            "receipt-owner-replaced",
            &original_registration_id,
            &runtime_id,
            "X25519+ML-KEM-768",
        )
        .await
        {
            Ok(_) => panic!("old registration must not receive replacement receipt"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("replacement registration"));
        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_managed_session_control_mutations_are_atomic() {
        let paths = test_paths("concurrent-managed-controls");
        seed_session(&paths, "session-first", RuntimeSessionState::Connecting).await;
        seed_session(&paths, "session-second", RuntimeSessionState::Connecting).await;
        seed_session(
            &paths,
            "session-after-corruption",
            RuntimeSessionState::Connecting,
        )
        .await;
        let first_paths = paths.clone();
        let second_paths = paths.clone();
        let (first, second) = tokio::join!(
            upsert_managed_session_control(&first_paths, managed_session_control("session-first")),
            upsert_managed_session_control(
                &second_paths,
                managed_session_control("session-second")
            )
        );
        first.expect("first managed control mutation should succeed");
        second.expect("second managed control mutation should succeed");

        let registry = load_managed_session_controls(&paths)
            .await
            .expect("managed controls should reload after concurrent mutations");
        assert!(registry.get("session-first").is_some());
        assert!(registry.get("session-second").is_some());
        let persisted: ManagedSessionControlRegistry = serde_json::from_slice(
            &tokio::fs::read(&paths.session_controls_file)
                .await
                .expect("managed control registry should be readable"),
        )
        .expect("managed control registry should remain complete JSON");
        assert_eq!(persisted.sessions.len(), 2);

        let mut entries = tokio::fs::read_dir(&paths.runtime_dir)
            .await
            .expect("runtime directory should be readable");
        while let Some(entry) = entries
            .next_entry()
            .await
            .expect("runtime directory entry should be readable")
        {
            assert!(
                !entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".session-controls.json.tmp-"),
                "atomic persistence must not leave a temporary control registry behind"
            );
        }

        tokio::fs::write(&paths.session_controls_file, b"{not-json")
            .await
            .expect("corrupt managed controls should be seeded");
        let error = upsert_managed_session_control(
            &paths,
            managed_session_control("session-after-corruption"),
        )
        .await
        .expect_err("corrupt managed controls must fail closed");
        assert!(error.to_string().contains("failed to decode"));
        assert_eq!(
            tokio::fs::read_to_string(&paths.session_controls_file)
                .await
                .expect("corrupt managed controls should remain available for diagnosis"),
            "{not-json"
        );

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn managed_session_control_mutation_waits_for_its_dedicated_file_lock() {
        let paths = test_paths("managed-control-lock-contention");
        seed_session(&paths, "session-contended", RuntimeSessionState::Connecting).await;
        ensure_identity_layout(&paths)
            .await
            .expect("managed control layout should be created");
        let blocking_lock = lock_session_registry_file(&paths.session_controls_lock_file, true)
            .expect("test should acquire the managed control file lock");
        let mutation_paths = paths.clone();
        let mut mutation = tokio::spawn(async move {
            upsert_managed_session_control(
                &mutation_paths,
                managed_session_control("session-contended"),
            )
            .await
        });

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(100), &mut mutation)
                .await
                .is_err(),
            "managed control mutation must not bypass its held file lock"
        );
        drop(blocking_lock);
        let registry = tokio::time::timeout(std::time::Duration::from_secs(2), mutation)
            .await
            .expect("managed control mutation should resume after lock release")
            .expect("managed control mutation task should not panic")
            .expect("managed control mutation should succeed after lock release");
        assert!(registry.get("session-contended").is_some());

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn managed_incarnation_resets_evidence_and_terminally_closes_old_requests() {
        let paths = test_paths("managed-incarnation-reset");
        seed_file_transfer_session(&paths, "session-incarnation").await;
        upsert_managed_session_control(&paths, managed_session_control("session-incarnation"))
            .await
            .expect("persist initial managed control");

        let source = paths.root.join("incarnation-source.bin");
        tokio::fs::write(&source, b"payload")
            .await
            .expect("seed transfer source");
        let file_request = enqueue_file_transfer_send_request_for_established_session(
            &paths,
            "session-incarnation",
            "remote-device",
            &source,
        )
        .await
        .expect("enqueue old-incarnation file request");
        observe_file_transfer_requests_for_runtime(
            &paths,
            "session-incarnation",
            "runtime-session-incarnation",
        )
        .await
        .expect("claim old-incarnation file request");
        start_file_transfer_request_for_runtime(
            &paths,
            &file_request.request_id,
            "runtime-session-incarnation",
        )
        .await
        .expect("start old-incarnation file request");
        let remote_request = enqueue_remote_desktop_request_for_established_session(
            &paths,
            "session-incarnation",
            RemoteDesktopControlAction::Stop,
            RemoteDesktopControlRequestPayload::default(),
        )
        .await
        .expect("enqueue old-incarnation remote request");

        let initial_control = load_managed_session_controls(&paths)
            .await
            .expect("load initial control")
            .get("session-incarnation")
            .expect("initial control")
            .clone();
        let next_control = begin_managed_session_incarnation(&paths, &initial_control)
            .await
            .expect("start fresh managed incarnation");
        assert_eq!(
            next_control.registration_id, initial_control.registration_id,
            "worker handoff must preserve immutable registration ownership"
        );
        assert_ne!(
            next_control.target_runtime_id,
            "runtime-session-incarnation"
        );

        let sessions = load_session_registry(&paths)
            .await
            .expect("load reset session");
        let session = sessions.get("session-incarnation").expect("reset session");
        assert_eq!(session.runtime_id, next_control.target_runtime_id);
        assert_eq!(session.state, RuntimeSessionState::Connecting);
        assert_eq!(session.readiness, SessionReadiness::Idle);
        assert!(session.last_established_readiness.is_none());
        assert!(!session.transport_preserved);
        assert!(session.transport_ready_at.is_none());
        assert!(session.handshake_completed_at.is_none());
        assert!(session.authenticated_peer.is_none());
        assert!(session.selected_ice_route.is_none());

        let file_registry = load_file_transfer_request_registry(&paths)
            .await
            .expect("load finalized file requests");
        let finalized_file = file_registry
            .get(&file_request.request_id)
            .expect("old file request");
        assert_eq!(
            finalized_file.status,
            FileTransferControlRequestStatus::TransferFailed
        );
        assert_eq!(
            finalized_file.failure_reason.as_deref(),
            Some("managed runtime ended before verified receipt")
        );
        let remote_registry = load_remote_desktop_request_registry(&paths)
            .await
            .expect("load finalized remote requests");
        assert_eq!(
            remote_registry
                .get(&remote_request.request_id)
                .expect("old remote request")
                .status,
            RemoteDesktopControlRequestStatus::AgentRejected
        );

        let late_completion = complete_file_transfer_request_for_runtime(
            &paths,
            &file_request.request_id,
            "runtime-session-incarnation",
            file_request.source.size_bytes,
        )
        .await;
        assert!(late_completion.is_err());
        assert_eq!(
            load_file_transfer_request_registry(&paths)
                .await
                .expect("reload finalized request")
                .get(&file_request.request_id)
                .expect("old file request")
                .status,
            FileTransferControlRequestStatus::TransferFailed
        );

        assert!(
            disconnect_managed_session_if_registration(
                &paths,
                "session-incarnation",
                &initial_control.registration_id,
                Some("registration-owned cleanup".to_owned()),
            )
            .await
            .expect("registration cleanup follows worker handoff")
        );
        assert_eq!(
            load_session_registry(&paths)
                .await
                .expect("load cleaned session")
                .get("session-incarnation")
                .expect("session audit evidence")
                .state,
            RuntimeSessionState::Disconnected
        );

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn stale_worker_cleanup_cannot_stop_disconnect_or_remove_replacement() {
        let paths = test_paths("managed-incarnation-replacement");
        seed_session(
            &paths,
            "session-replacement",
            RuntimeSessionState::Connecting,
        )
        .await;
        let old_control = managed_session_control("session-replacement");
        let old_registration_id = old_control.registration_id.clone();
        upsert_managed_session_control(&paths, old_control)
            .await
            .expect("persist old control");
        let old_runtime_id = "runtime-session-replacement";

        upsert_session_runtime(
            &paths,
            RuntimeSessionRecord::new(
                "runtime-replacement-new",
                "session-replacement",
                RuntimeSessionRole::Initiator,
                RuntimeSessionSource::Code,
                "https://signal.example.com",
                "local-device",
                None,
                None,
                None,
                RuntimeSessionState::Connecting,
            ),
        )
        .await
        .expect("publish replacement runtime");
        upsert_managed_session_control(&paths, managed_session_control("session-replacement"))
            .await
            .expect("publish replacement control");

        assert_eq!(
            observe_managed_session_registration(
                &paths,
                "session-replacement",
                &old_registration_id,
            )
            .await
            .expect("observe stale registration"),
            ManagedSessionRegistrationObservation::Replaced
        );

        assert!(!stop_managed_session_control_if_runtime(
            &paths,
            "session-replacement",
            old_runtime_id,
        )
        .await
        .expect("stale stop CAS"));
        assert!(
            !disconnect_session_if_runtime(
                &paths,
                "session-replacement",
                old_runtime_id,
                Some("stale worker exit".to_owned()),
            )
            .await
            .expect("stale disconnect CAS")
        );
        assert!(
            !remove_managed_session_control_if_runtime(
                &paths,
                "session-replacement",
                old_runtime_id,
            )
            .await
            .expect("stale remove CAS")
        );
        assert!(
            !disconnect_managed_session_if_runtime(
                &paths,
                "session-replacement",
                old_runtime_id,
                Some("stale CLI cleanup".to_owned()),
            )
            .await
            .expect("stale managed disconnect CAS")
        );
        assert!(
            !disconnect_managed_session_if_registration(
                &paths,
                "session-replacement",
                &old_registration_id,
                Some("stale registration cleanup".to_owned()),
            )
            .await
            .expect("stale registration disconnect CAS")
        );
        assert!(
            apply_transport_event_for_runtime(
                &paths,
                "session-replacement",
                old_runtime_id,
                RuntimeSessionTransportEvent::TransportReady,
            )
            .await
            .is_err()
        );
        assert!(
            update_session_remote_peer_for_runtime(
                &paths,
                "session-replacement",
                old_runtime_id,
                "stale-peer",
                None,
                None,
            )
            .await
            .is_err()
        );

        let controls = load_managed_session_controls(&paths)
            .await
            .expect("load replacement control");
        let control = controls
            .get("session-replacement")
            .expect("replacement control survives");
        assert_eq!(control.target_runtime_id, "runtime-replacement-new");
        assert_ne!(control.registration_id, old_registration_id);
        assert_eq!(control.desired_state, ManagedSessionDesiredState::Active);
        let sessions = load_session_registry(&paths)
            .await
            .expect("load replacement runtime");
        let session = sessions
            .get("session-replacement")
            .expect("replacement runtime survives");
        assert_eq!(session.runtime_id, "runtime-replacement-new");
        assert_eq!(session.state, RuntimeSessionState::Connecting);

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn typed_file_transitions_never_reopen_or_overwrite_terminal_failure() {
        let paths = test_paths("typed-file-terminal");
        seed_file_transfer_session(&paths, "session-terminal").await;
        let source = paths.root.join("terminal-source.bin");
        tokio::fs::write(&source, b"payload")
            .await
            .expect("seed transfer source");
        let request = enqueue_file_transfer_send_request_for_established_session(
            &paths,
            "session-terminal",
            "remote-device",
            &source,
        )
        .await
        .expect("enqueue transfer");
        observe_file_transfer_requests_for_runtime(
            &paths,
            "session-terminal",
            "runtime-session-terminal",
        )
        .await
        .expect("observe transfer");
        fail_file_transfer_request_for_runtime(
            &paths,
            &request.request_id,
            "runtime-session-terminal",
            "transport failed".to_owned(),
        )
        .await
        .expect("persist terminal failure");
        fail_file_transfer_request_for_runtime(
            &paths,
            &request.request_id,
            "runtime-session-terminal",
            "transport failed".to_owned(),
        )
        .await
        .expect("identical terminal failure is idempotent");
        assert!(
            start_file_transfer_request_for_runtime(
                &paths,
                &request.request_id,
                "runtime-session-terminal",
            )
            .await
            .is_err()
        );
        assert!(
            complete_file_transfer_request_for_runtime(
                &paths,
                &request.request_id,
                "runtime-session-terminal",
                request.source.size_bytes,
            )
            .await
            .is_err()
        );
        let stored = load_file_transfer_request_registry(&paths)
            .await
            .expect("load terminal request");
        let stored = stored.get(&request.request_id).expect("terminal request");
        assert_eq!(
            stored.status,
            FileTransferControlRequestStatus::TransferFailed
        );
        assert_eq!(stored.failure_reason.as_deref(), Some("transport failed"));

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn failed_disconnect_cas_leaves_stopped_control_as_retry_anchor() {
        let paths = test_paths("managed-stop-anchor");
        seed_session(&paths, "session-anchor", RuntimeSessionState::Connecting).await;
        upsert_managed_session_control(&paths, managed_session_control("session-anchor"))
            .await
            .expect("persist managed control");
        assert!(
            stop_managed_session_control_if_runtime(
                &paths,
                "session-anchor",
                "runtime-session-anchor",
            )
            .await
            .expect("persist stopped desired state")
        );

        upsert_session_runtime(
            &paths,
            RuntimeSessionRecord::new(
                "runtime-session-anchor-replaced",
                "session-anchor",
                RuntimeSessionRole::Initiator,
                RuntimeSessionSource::Code,
                "https://signal.example.com",
                "local-device",
                None,
                None,
                None,
                RuntimeSessionState::Connecting,
            ),
        )
        .await
        .expect("simulate replacement before disconnect CAS");
        let disconnected = disconnect_session_if_runtime(
            &paths,
            "session-anchor",
            "runtime-session-anchor",
            Some("old worker exit".to_owned()),
        )
        .await
        .expect("disconnect CAS should be observable");
        assert!(!disconnected);
        let control = load_managed_session_controls(&paths)
            .await
            .expect("load stopped control")
            .get("session-anchor")
            .expect("stopped control remains")
            .clone();
        assert_eq!(control.desired_state, ManagedSessionDesiredState::Stopped);
        assert_eq!(control.target_runtime_id, "runtime-session-anchor");

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
    }

    #[tokio::test]
    async fn operator_disconnect_persists_session_terminal_state_before_removing_control() {
        let paths = test_paths("managed-operator-disconnect");
        seed_session(
            &paths,
            "session-operator-disconnect",
            RuntimeSessionState::Connecting,
        )
        .await;
        upsert_managed_session_control(
            &paths,
            managed_session_control("session-operator-disconnect"),
        )
        .await
        .expect("persist managed control");

        let sessions = disconnect_managed_session(
            &paths,
            "session-operator-disconnect",
            Some("operator_requested".to_owned()),
        )
        .await
        .expect("disconnect managed session");
        let session = sessions
            .get("session-operator-disconnect")
            .expect("terminal session remains inspectable");
        assert_eq!(session.state, RuntimeSessionState::Disconnected);
        assert_eq!(session.last_error.as_deref(), Some("operator_requested"));
        assert!(
            load_managed_session_controls(&paths)
                .await
                .expect("load controls")
                .get("session-operator-disconnect")
                .is_none(),
            "control is removed only after terminal session persistence succeeds"
        );

        let _ = tokio::fs::remove_dir_all(&paths.root).await;
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
    async fn prebound_remote_peer_metadata_cannot_be_overwritten() {
        let paths = test_paths("prebound-remote-peer-metadata");
        seed_session(&paths, "session-1", RuntimeSessionState::Connecting).await;

        update_session_remote_peer(
            &paths,
            "session-1",
            "remote-device",
            Some("Trusted Peer".to_owned()),
            Some("trusted-fingerprint".to_owned()),
        )
        .await
        .expect("first observed peer metadata should bind the session");

        let substituted_id =
            update_session_remote_peer(&paths, "session-1", "substituted-device", None, None)
                .await
                .expect_err("a different signaling device id must not replace the bound peer");
        assert!(
            substituted_id
                .to_string()
                .contains("pre-bound session peer")
        );

        let substituted_fingerprint = update_session_remote_peer(
            &paths,
            "session-1",
            "remote-device",
            None,
            Some("substituted-fingerprint".to_owned()),
        )
        .await
        .expect_err("a different protocol fingerprint must not replace the bound peer");
        assert!(
            substituted_fingerprint
                .to_string()
                .contains("pre-bound session peer")
        );

        let registry = load_session_registry(&paths)
            .await
            .expect("session registry should remain readable");
        let record = registry
            .get("session-1")
            .expect("bound session should remain present");
        assert_eq!(record.remote_device_id.as_deref(), Some("remote-device"));
        assert_eq!(
            record.remote_protocol_public_key_fingerprint.as_deref(),
            Some("trusted-fingerprint")
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

        let observed =
            observe_remote_desktop_requests_for_runtime(&paths, "session-1", "runtime-session-1")
                .await
                .expect("standalone runtime should reject legacy pending remote desktop requests");
        assert!(
            observed.is_empty(),
            "backend-unavailable requests must never be reported as agent-observed"
        );
        let registry = load_remote_desktop_request_registry(&paths)
            .await
            .expect("rejected request registry should load");
        assert!(registry.pending_for_session("session-1").is_empty());
        assert_eq!(
            registry
                .values_sorted()
                .first()
                .expect("legacy request should remain auditable")
                .status,
            RemoteDesktopControlRequestStatus::AgentRejected
        );
        assert!(
            observe_remote_desktop_requests_for_runtime(&paths, "session-1", "runtime-session-1",)
                .await
                .expect("rejected session should not produce observations")
                .is_empty()
        );

        seed_session(&paths, "session-stale-runtime", RuntimeSessionState::Bound).await;
        let mut stale_registry = load_remote_desktop_request_registry(&paths)
            .await
            .expect("request registry should load before seeding stale request");
        stale_registry
            .insert(RemoteDesktopControlRequest::pending(
                "stale-request-1",
                "session-stale-runtime",
                "old-runtime",
                RemoteDesktopControlAction::Stop,
                RemoteDesktopControlRequestPayload::default(),
            ))
            .expect("insert stale remote request");
        tokio::fs::write(
            &paths.remote_desktop_requests_file,
            serde_json::to_vec_pretty(&stale_registry).expect("stale registry should serialize"),
        )
        .await
        .expect("stale request registry should be seeded");
        assert!(
            observe_remote_desktop_requests_for_runtime(
                &paths,
                "session-stale-runtime",
                "runtime-session-stale-runtime",
            )
            .await
            .expect("stale request should be terminally rejected")
            .is_empty()
        );
        let stale_registry = load_remote_desktop_request_registry(&paths)
            .await
            .expect("stale registry should remain loadable");
        assert!(
            stale_registry
                .pending_for_session("session-stale-runtime")
                .is_empty()
        );
        assert_eq!(
            stale_registry
                .get("stale-request-1")
                .expect("stale request")
                .status,
            RemoteDesktopControlRequestStatus::AgentRejected
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
        attach_verified_connection_evidence(&mut record);
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

        let observed = observe_file_transfer_requests_for_runtime(
            &paths,
            "session-1",
            "runtime-session-1",
        )
        .await
        .expect("handshake-complete active session should observe pending file transfer requests");
        assert_eq!(observed.len(), 1);
        assert_eq!(observed[0].session_id, "session-1");
        assert!(observed[0].is_agent_observed());
        assert!(!observed[0].is_pending_agent_observation());
        let registry = load_file_transfer_request_registry(&paths)
            .await
            .expect("observed request registry should load");
        assert!(registry.pending_for_session("session-1").is_empty());
        assert!(
            observe_file_transfer_requests_for_runtime(&paths, "session-1", "runtime-session-1",)
                .await
                .expect("observed session should not produce duplicate file transfer observations")
                .is_empty()
        );

        seed_file_transfer_session(&paths, "session-stale-runtime").await;
        let mut stale_registry = load_file_transfer_request_registry(&paths)
            .await
            .expect("file transfer registry should load before seeding stale request");
        stale_registry
            .insert(FileTransferControlRequest::pending_send(
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
            ))
            .expect("insert stale file request");
        store_file_transfer_request_registry_unlocked(
            &paths.file_transfer_requests_file,
            &stale_registry,
        )
        .expect("stale file transfer request should be persisted");
        let stale_observe = observe_file_transfer_requests_for_runtime(
            &paths,
            "session-stale-runtime",
            "runtime-session-stale-runtime",
        )
        .await
        .expect("stale-runtime file transfer request must be rejected terminally");
        assert!(stale_observe.is_empty());
        let stale_registry = load_file_transfer_request_registry(&paths)
            .await
            .expect("file transfer registry should survive stale observe failure");
        assert!(
            stale_registry
                .pending_for_session("session-stale-runtime")
                .is_empty()
        );
        assert_eq!(
            stale_registry
                .get("stale-file-request-1")
                .expect("stale file request")
                .status,
            FileTransferControlRequestStatus::AgentRejected
        );

        seed_session(&paths, "transport-only", RuntimeSessionState::Bound).await;
        let mut transport_only_registry = load_file_transfer_request_registry(&paths)
            .await
            .expect("file transfer registry should load before transport-only pending seed");
        transport_only_registry
            .insert(FileTransferControlRequest::pending_send(
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
            ))
            .expect("insert transport-only file request");
        store_file_transfer_request_registry_unlocked(
            &paths.file_transfer_requests_file,
            &transport_only_registry,
        )
        .expect("transport-only file transfer request should be persisted");
        let transport_only_observe = observe_file_transfer_requests_for_runtime(
            &paths,
            "transport-only",
            "runtime-transport-only",
        )
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
        registry
            .insert(RemoteDesktopControlRequest::pending(
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
            ))
            .expect("insert remote desktop request");
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

        let locator_display_name = upsert_nearby_discovery_snapshot(
            &paths,
            NearbyDiscoverySnapshot::new(
                "scan-4",
                "agent_owned_nearby_discovery_snapshot",
                vec![NearbyDiscoveredDevice::new(
                    "nearby-device-4",
                    "host.example.com",
                    skybridge_core::NearbyDiscoveryEndpointClass::LocalNetwork,
                    NearbyDiscoveryTrustStatus::Candidate,
                    vec!["file_transfer".to_owned()],
                    false,
                )],
                300,
            ),
        )
        .await;
        let error = locator_display_name
            .expect_err("display_name must reject DNS locators")
            .to_string();
        assert!(
            !error.contains("host.example.com"),
            "locator rejection must not echo the raw display name"
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
