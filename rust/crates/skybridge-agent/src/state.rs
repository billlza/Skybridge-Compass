use std::path::Path;
use std::sync::{Mutex, OnceLock};

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ed25519_dalek::{Signer, SigningKey};
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use skybridge_core::{
    AuthSession, AuthState, EnrollmentStatus, LocalIdentityState, ManagedSessionControl,
    ManagedSessionControlRegistry, NebulaOAuthClient, ProtocolIdentityBinding,
    ProtocolSigningAlgorithm, RuntimeSessionRecord, RuntimeSessionState,
    RuntimeSessionTransportEvent, RustPqcIdentityMaterial, SessionRegistry,
    SignalingLifecycleEvent, mldsa65_generate_keypair, mldsa65_sign_detached,
    should_refresh_access_token, xwing_generate_keypair,
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
    use skybridge_core::{RuntimeSessionRole, RuntimeSessionSource};

    fn test_paths(name: &str) -> AgentPaths {
        crate::runtime::resolve_paths(Some(std::env::temp_dir().join(format!(
            "skybridge-agent-state-{name}-{}",
            uuid::Uuid::now_v7()
        ))))
        .expect("temporary paths should resolve")
    }

    async fn seed_session(paths: &AgentPaths, session_id: &str, state: RuntimeSessionState) {
        upsert_session_runtime(
            paths,
            RuntimeSessionRecord::new(
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
            ),
        )
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
}
