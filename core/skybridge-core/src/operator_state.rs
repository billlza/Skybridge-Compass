use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fmt::Write as FmtWrite;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;
use time::OffsetDateTime;

pub const OPERATOR_STATE_SCHEMA_VERSION: u32 = 1;
pub const REMOTE_DESKTOP_REQUEST_REGISTRY_MAX_REQUESTS: usize = 128;
pub const FILE_TRANSFER_REQUEST_REGISTRY_MAX_REQUESTS: usize = 128;
pub const NEARBY_DISCOVERY_SNAPSHOT_REGISTRY_MAX_SNAPSHOTS: usize = 32;
pub const MAX_SESSION_REGISTRY_BYTES: u64 = 256 * 1024;
pub const MAX_REMOTE_DESKTOP_REQUEST_REGISTRY_BYTES: u64 = 256 * 1024;
pub const MAX_FILE_TRANSFER_REQUEST_REGISTRY_BYTES: u64 = 256 * 1024;
pub const NEARBY_DISCOVERY_SNAPSHOT_MAX_DEVICES: usize = 256;
pub const MAX_NEARBY_DISCOVERY_SNAPSHOT_REGISTRY_BYTES: u64 = 256 * 1024;
pub const ACTIVE_SCAN_SOURCE: &str = "agent_owned_active_mdns_scan";
pub const REMOTE_DESKTOP_RESOLUTION_IDS: &[&str] =
    &["auto", "1280x720", "1920x1080", "2056x1329", "2560x1440"];
pub const REMOTE_DESKTOP_FPS_VALUES: &[u16] = &[30, 60, 120];

const RUNTIME_DIR: &str = "runtime";
const SESSIONS_FILE: &str = "sessions.json";
const SESSIONS_LOCK_FILE: &str = "sessions.json.lock";
const REMOTE_DESKTOP_REQUESTS_FILE: &str = "remote-desktop-requests.json";
const REMOTE_DESKTOP_REQUESTS_LOCK_FILE: &str = "remote-desktop-requests.json.lock";
const FILE_TRANSFER_REQUESTS_FILE: &str = "file-transfer-requests.json";
const FILE_TRANSFER_REQUESTS_LOCK_FILE: &str = "file-transfer-requests.json.lock";
const NEARBY_DISCOVERY_SNAPSHOTS_FILE: &str = "nearby-discovery-snapshots.json";
const FILE_TRANSFER_SOURCE_HASH_BUFFER_BYTES: usize = 64 * 1024;
const MAX_OPERATOR_REF_BYTES: usize = 512;
const MAX_DISCOVERY_PUBLIC_TEXT_BYTES: usize = 512;

static REQUEST_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum OperatorStateError {
    #[error("operator state directory is required.")]
    MissingStateDir,
    #[error("operator state directory is unavailable.")]
    StateDirUnavailable,
    #[error("operator state path is not a directory.")]
    StateDirNotDirectory,
    #[error("operator state path contains a symlink or reparse point.")]
    UnsafePath,
    #[error("operator session registry is missing.")]
    SessionRegistryMissing,
    #[error("operator session registry could not be read.")]
    SessionRegistryRead,
    #[error("operator session registry JSON is invalid.")]
    SessionRegistryJson,
    #[error("operator session registry schema is unsupported.")]
    SessionRegistrySchema,
    #[error("operator session registry is internally inconsistent.")]
    SessionRegistryInvalid,
    #[error("operator session registry exceeds the maximum supported size.")]
    SessionRegistryTooLarge,
    #[error("operator session binding is invalid.")]
    InvalidSessionBinding,
    #[error("operator session binding conflicts with an existing session.")]
    SessionBindingConflict,
    #[error("operator session registry could not be written.")]
    SessionRegistryWrite,
    #[error("operator session registry persist verification failed.")]
    SessionRegistryPersistVerify,
    #[error("operator session was not found.")]
    SessionNotFound,
    #[error("operator session is not established for request registration.")]
    SessionNotEstablished,
    #[error("operator session is stale.")]
    SessionStale,
    #[error("remote desktop request registry could not be read.")]
    RequestRegistryRead,
    #[error("remote desktop request registry JSON is invalid.")]
    RequestRegistryJson,
    #[error("remote desktop request registry schema is unsupported.")]
    RequestRegistrySchema,
    #[error("remote desktop request registry is internally inconsistent.")]
    RequestRegistryInvalid,
    #[error("remote desktop request payload is invalid.")]
    InvalidRequestPayload,
    #[error("remote desktop request registry already has a pending request.")]
    PendingRequestExists,
    #[error("remote desktop request registry is full.")]
    RequestRegistryFull,
    #[error("remote desktop operator registry is locked.")]
    RegistryLocked,
    #[error("remote desktop request registry could not be written.")]
    RequestRegistryWrite,
    #[error("remote desktop request registry persist verification failed.")]
    RequestRegistryPersistVerify,
    #[error("file transfer request registry could not be read.")]
    FileTransferRequestRegistryRead,
    #[error("file transfer request registry JSON is invalid.")]
    FileTransferRequestRegistryJson,
    #[error("file transfer request registry schema is unsupported.")]
    FileTransferRequestRegistrySchema,
    #[error("file transfer request registry is internally inconsistent.")]
    FileTransferRequestRegistryInvalid,
    #[error("file transfer destination peer reference is invalid.")]
    InvalidPeerRef,
    #[error("file transfer session is missing a verified peer binding.")]
    PeerBindingMissing,
    #[error("file transfer destination does not match the established session peer.")]
    PeerMismatch,
    #[error("file transfer source is missing.")]
    FileTransferSourceMissing,
    #[error("file transfer source path contains a symlink or reparse point.")]
    FileTransferSourceUnsafe,
    #[error("file transfer source is not a regular file.")]
    FileTransferSourceNotRegularFile,
    #[error("file transfer source could not be read.")]
    FileTransferSourceRead,
    #[error("file transfer source hash could not be computed.")]
    FileTransferHashFailed,
    #[error("file transfer request registry could not be written.")]
    FileTransferRequestRegistryWrite,
    #[error("file transfer request registry persist verification failed.")]
    FileTransferRequestRegistryPersistVerify,
    #[error("nearby discovery snapshot registry is missing.")]
    NearbyDiscoverySnapshotMissing,
    #[error("nearby discovery active scan snapshot is missing.")]
    NearbyDiscoveryActiveScanSnapshotMissing,
    #[error("nearby discovery snapshot is stale.")]
    NearbyDiscoverySnapshotStale,
    #[error("nearby discovery active scan snapshot is stale.")]
    NearbyDiscoveryActiveScanSnapshotStale,
    #[error("nearby discovery snapshot registry could not be read.")]
    NearbyDiscoverySnapshotRegistryRead,
    #[error("nearby discovery snapshot registry JSON is invalid.")]
    NearbyDiscoverySnapshotRegistryJson,
    #[error("nearby discovery snapshot registry schema is unsupported.")]
    NearbyDiscoverySnapshotRegistrySchema,
    #[error("nearby discovery snapshot registry is internally inconsistent.")]
    NearbyDiscoverySnapshotRegistryInvalid,
    #[error("nearby discovery snapshot registry is too large.")]
    NearbyDiscoverySnapshotRegistryTooLarge,
    #[error("system clock is before Unix epoch.")]
    Clock,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NearbyDiscoveryEndpointClass {
    LocalNetwork,
    PeerToPeer,
    Relay,
    Unknown,
}

impl NearbyDiscoveryEndpointClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::LocalNetwork => "local_network",
            Self::PeerToPeer => "peer_to_peer",
            Self::Relay => "relay",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NearbyDiscoveryTrustStatus {
    Unknown,
    Candidate,
    ProtocolIdentityVerified,
    Trusted,
}

impl NearbyDiscoveryTrustStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Candidate => "candidate",
            Self::ProtocolIdentityVerified => "protocol_identity_verified",
            Self::Trusted => "trusted",
        }
    }

    fn permits_connectable_projection(self) -> bool {
        matches!(self, Self::ProtocolIdentityVerified | Self::Trusted)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NearbyDiscoveredDevice {
    pub device_ref: String,
    pub display_name: String,
    pub endpoint_class: NearbyDiscoveryEndpointClass,
    pub trust_status: NearbyDiscoveryTrustStatus,
    #[serde(default)]
    pub capabilities: Vec<String>,
    pub connectable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NearbyDiscoverySnapshot {
    pub schema_version: u32,
    pub scan_id: String,
    pub source: String,
    #[serde(default)]
    pub devices: Vec<NearbyDiscoveredDevice>,
    #[serde(with = "time::serde::rfc3339")]
    pub observed_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub expires_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NearbyDiscoverySnapshotRegistry {
    pub schema_version: u32,
    #[serde(default)]
    pub snapshots: BTreeMap<String, NearbyDiscoverySnapshot>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NearbyDiscoverySnapshotRead {
    pub snapshots_total: usize,
    pub snapshot: NearbyDiscoverySnapshot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RemoteDesktopControlAction {
    #[serde(rename = "start")]
    Start,
    #[serde(rename = "stop")]
    Stop,
    #[serde(rename = "set-resolution")]
    SetResolution,
    #[serde(rename = "set-fps")]
    SetFps,
}

impl RemoteDesktopControlAction {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Stop => "stop",
            Self::SetResolution => "set-resolution",
            Self::SetFps => "set-fps",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RemoteDesktopControlRequestStatus {
    #[serde(rename = "pending_agent_observation")]
    PendingAgentObservation,
    #[serde(rename = "agent_observed")]
    AgentObserved,
    #[serde(rename = "agent_rejected")]
    AgentRejected,
}

impl RemoteDesktopControlRequestStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PendingAgentObservation => "pending_agent_observation",
            Self::AgentObserved => "agent_observed",
            Self::AgentRejected => "agent_rejected",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RemoteDesktopResolutionRequest {
    Auto,
    Preset { id: String, width: u16, height: u16 },
}

impl RemoteDesktopResolutionRequest {
    pub fn id(&self) -> &str {
        match self {
            Self::Auto => "auto",
            Self::Preset { id, .. } => id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct RemoteDesktopControlRequestPayload {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<RemoteDesktopResolutionRequest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fps: Option<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteDesktopControlRequest {
    pub schema_version: u32,
    pub request_id: String,
    pub session_id: String,
    pub target_runtime_id: String,
    pub action: RemoteDesktopControlAction,
    pub payload: RemoteDesktopControlRequestPayload,
    pub status: RemoteDesktopControlRequestStatus,
    pub created_at_unix_ms: i64,
    pub updated_at_unix_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteDesktopControlRequestRegistry {
    pub schema_version: u32,
    #[serde(default)]
    pub requests: BTreeMap<String, RemoteDesktopControlRequest>,
}

impl Default for RemoteDesktopControlRequestRegistry {
    fn default() -> Self {
        Self {
            schema_version: OPERATOR_STATE_SCHEMA_VERSION,
            requests: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteDesktopRequestRegistration {
    pub request: RemoteDesktopControlRequest,
    pub pending_requests_for_session: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteDesktopStatusSnapshot {
    pub sessions_total: usize,
    pub pending_requests: usize,
    pub latest_request: Option<RemoteDesktopControlRequest>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeSessionSummary {
    pub session_ref: String,
    pub session_id_present: bool,
    pub target_runtime_id_present: bool,
    pub remote_device_id_present: bool,
    pub remote_identity_bound: bool,
    pub state: String,
    pub secure_session_state: String,
    pub readiness_kind: String,
    pub expires_at_unix_ms: i64,
    pub expired: bool,
    pub product_control_secure_session_ready: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionInventorySnapshot {
    pub sessions_total: usize,
    pub sessions: Vec<RuntimeSessionSummary>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProductControlSessionRegistration {
    pub session: RuntimeSessionSummary,
    pub inserted: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FileTransferControlAction {
    #[serde(rename = "send")]
    Send,
}

impl FileTransferControlAction {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Send => "send",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FileTransferControlRequestStatus {
    #[serde(rename = "pending_agent_observation")]
    PendingAgentObservation,
    #[serde(rename = "agent_observed")]
    AgentObserved,
    #[serde(rename = "transfer_in_progress")]
    TransferInProgress,
    #[serde(rename = "transfer_completed")]
    TransferCompleted,
    #[serde(rename = "transfer_failed")]
    TransferFailed,
    #[serde(rename = "agent_rejected")]
    AgentRejected,
}

impl FileTransferControlRequestStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PendingAgentObservation => "pending_agent_observation",
            Self::AgentObserved => "agent_observed",
            Self::TransferInProgress => "transfer_in_progress",
            Self::TransferCompleted => "transfer_completed",
            Self::TransferFailed => "transfer_failed",
            Self::AgentRejected => "agent_rejected",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileTransferSourceSnapshot {
    pub source_path: String,
    pub size_bytes: u64,
    pub sha256_hex: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileTransferDestinationBinding {
    pub requested_peer_ref: String,
    pub remote_device_id: String,
    pub remote_protocol_public_key_fingerprint: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileTransferControlRequest {
    pub schema_version: u32,
    pub request_id: String,
    pub session_id: String,
    pub target_runtime_id: String,
    pub action: FileTransferControlAction,
    pub source: FileTransferSourceSnapshot,
    pub destination: FileTransferDestinationBinding,
    pub status: FileTransferControlRequestStatus,
    pub created_at_unix_ms: i64,
    pub updated_at_unix_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transfer_started_at_unix_ms: Option<i64>,
    #[serde(default)]
    pub bytes_transferred: u64,
    #[serde(default)]
    pub receipt_verified: bool,
    #[serde(default)]
    pub receipt_sha256_match: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transfer_completed_at_unix_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileTransferControlRequestRegistry {
    pub schema_version: u32,
    #[serde(default)]
    pub requests: BTreeMap<String, FileTransferControlRequest>,
}

impl Default for FileTransferControlRequestRegistry {
    fn default() -> Self {
        Self {
            schema_version: OPERATOR_STATE_SCHEMA_VERSION,
            requests: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTransferRequestRegistration {
    pub request: FileTransferControlRequest,
    pub pending_requests_for_session: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTransferHistorySnapshot {
    pub sessions_total: usize,
    pub pending_requests: usize,
    pub latest_request: Option<FileTransferControlRequest>,
    pub history: Vec<FileTransferControlRequest>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RuntimeSessionRegistry {
    schema_version: u32,
    #[serde(default)]
    sessions: BTreeMap<String, RuntimeSessionRecord>,
}

impl Default for RuntimeSessionRegistry {
    fn default() -> Self {
        Self {
            schema_version: OPERATOR_STATE_SCHEMA_VERSION,
            sessions: BTreeMap::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RuntimeSessionRecord {
    schema_version: u32,
    session_id: String,
    target_runtime_id: String,
    #[serde(default)]
    remote_device_id: Option<String>,
    #[serde(default)]
    remote_protocol_public_key_fingerprint: Option<String>,
    state: String,
    secure_session_state: String,
    readiness: RuntimeSessionReadiness,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    created_at_unix_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    updated_at_unix_ms: Option<i64>,
    expires_at_unix_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct RuntimeSessionReadiness {
    kind: String,
}

pub fn remote_desktop_resolution_request(
    value: &str,
) -> Result<RemoteDesktopResolutionRequest, OperatorStateError> {
    match value {
        "auto" => Ok(RemoteDesktopResolutionRequest::Auto),
        "1280x720" => Ok(RemoteDesktopResolutionRequest::Preset {
            id: value.to_string(),
            width: 1280,
            height: 720,
        }),
        "1920x1080" => Ok(RemoteDesktopResolutionRequest::Preset {
            id: value.to_string(),
            width: 1920,
            height: 1080,
        }),
        "2056x1329" => Ok(RemoteDesktopResolutionRequest::Preset {
            id: value.to_string(),
            width: 2056,
            height: 1329,
        }),
        "2560x1440" => Ok(RemoteDesktopResolutionRequest::Preset {
            id: value.to_string(),
            width: 2560,
            height: 1440,
        }),
        _ => Err(OperatorStateError::InvalidRequestPayload),
    }
}

pub fn remote_desktop_fps_supported(fps: u16) -> bool {
    REMOTE_DESKTOP_FPS_VALUES.contains(&fps)
}

pub fn register_established_product_control_session(
    state_dir: &str,
    session_id: &str,
    target_runtime_id: &str,
    remote_device_id: &str,
    remote_protocol_public_key_fingerprint: &str,
    expires_at_unix_ms: i64,
) -> Result<ProductControlSessionRegistration, OperatorStateError> {
    let session_id = validate_session_binding_text(session_id)?;
    let target_runtime_id = validate_session_binding_text(target_runtime_id)?;
    let remote_device_id = validate_session_binding_text(remote_device_id)?;
    let remote_protocol_public_key_fingerprint =
        validate_protocol_public_key_fingerprint(remote_protocol_public_key_fingerprint)?;

    let paths = OperatorStatePaths::resolve(state_dir)?;
    let now = now_unix_ms()?;
    if expires_at_unix_ms <= now {
        return Err(OperatorStateError::SessionStale);
    }

    let _session_lock = FileLock::acquire(&paths.session_lock_file)?;
    let mut registry = load_session_registry_for_write(&paths.session_registry_file)?;
    let inserted = match registry.sessions.get(session_id) {
        Some(existing)
            if existing.target_runtime_id != target_runtime_id
                || existing.remote_device_id.as_deref() != Some(remote_device_id)
                || existing.remote_protocol_public_key_fingerprint.as_deref()
                    != Some(remote_protocol_public_key_fingerprint) =>
        {
            return Err(OperatorStateError::SessionBindingConflict);
        }
        Some(_) => false,
        None => true,
    };

    let created_at_unix_ms = registry
        .sessions
        .get(session_id)
        .and_then(|session| session.created_at_unix_ms)
        .unwrap_or(now);
    let record = RuntimeSessionRecord {
        schema_version: OPERATOR_STATE_SCHEMA_VERSION,
        session_id: session_id.to_string(),
        target_runtime_id: target_runtime_id.to_string(),
        remote_device_id: Some(remote_device_id.to_string()),
        remote_protocol_public_key_fingerprint: Some(
            remote_protocol_public_key_fingerprint.to_string(),
        ),
        state: "established".to_string(),
        secure_session_state: "Established".to_string(),
        readiness: RuntimeSessionReadiness {
            kind: "product_control_secure_session".to_string(),
        },
        created_at_unix_ms: Some(created_at_unix_ms),
        updated_at_unix_ms: Some(now),
        expires_at_unix_ms,
    };
    registry
        .sessions
        .insert(session_id.to_string(), record.clone());
    store_session_registry(&paths.session_registry_file, &registry)?;
    let persisted = load_session_registry(&paths.session_registry_file)?;
    let persisted_session = persisted
        .sessions
        .get(session_id)
        .ok_or(OperatorStateError::SessionRegistryPersistVerify)?;
    if persisted_session != &record {
        return Err(OperatorStateError::SessionRegistryPersistVerify);
    }

    Ok(ProductControlSessionRegistration {
        session: session_summary(persisted_session, now),
        inserted,
    })
}

pub fn register_remote_desktop_request_for_established_session(
    state_dir: &str,
    session_id: &str,
    action: RemoteDesktopControlAction,
    payload: RemoteDesktopControlRequestPayload,
) -> Result<RemoteDesktopRequestRegistration, OperatorStateError> {
    validate_remote_desktop_payload(action, &payload)?;
    let paths = OperatorStatePaths::resolve(state_dir)?;
    let now = now_unix_ms()?;
    let _session_lock = FileLock::acquire(&paths.session_lock_file)?;
    let session_registry = load_session_registry(&paths.session_registry_file)?;
    let session = session_registry
        .sessions
        .get(session_id)
        .ok_or(OperatorStateError::SessionNotFound)?;
    validate_session_record(session_id, session, now)?;

    let _request_lock = FileLock::acquire(&paths.remote_desktop_request_lock_file)?;
    let mut request_registry =
        load_remote_desktop_request_registry(&paths.remote_desktop_request_registry_file)?;
    if request_registry.requests.values().any(|request| {
        request.session_id == session_id
            && request.status == RemoteDesktopControlRequestStatus::PendingAgentObservation
    }) {
        return Err(OperatorStateError::PendingRequestExists);
    }
    if request_registry.requests.len() >= REMOTE_DESKTOP_REQUEST_REGISTRY_MAX_REQUESTS {
        return Err(OperatorStateError::RequestRegistryFull);
    }

    let request = RemoteDesktopControlRequest {
        schema_version: OPERATOR_STATE_SCHEMA_VERSION,
        request_id: next_request_id(now),
        session_id: session.session_id.clone(),
        target_runtime_id: session.target_runtime_id.clone(),
        action,
        payload,
        status: RemoteDesktopControlRequestStatus::PendingAgentObservation,
        created_at_unix_ms: now,
        updated_at_unix_ms: now,
    };
    request_registry
        .requests
        .insert(request.request_id.clone(), request.clone());
    store_remote_desktop_request_registry(
        &paths.remote_desktop_request_registry_file,
        &request_registry,
    )?;
    let persisted =
        load_remote_desktop_request_registry(&paths.remote_desktop_request_registry_file)?;
    if persisted.requests.get(&request.request_id) != Some(&request) {
        return Err(OperatorStateError::RequestRegistryPersistVerify);
    }
    let pending_requests_for_session = persisted
        .requests
        .values()
        .filter(|stored| {
            stored.session_id == session_id
                && stored.status == RemoteDesktopControlRequestStatus::PendingAgentObservation
        })
        .count();

    Ok(RemoteDesktopRequestRegistration {
        request,
        pending_requests_for_session,
    })
}

pub fn register_file_transfer_send_request_for_established_session(
    state_dir: &str,
    session_id: &str,
    requested_peer_ref: &str,
    source_path: &str,
) -> Result<FileTransferRequestRegistration, OperatorStateError> {
    let requested_peer_ref = validate_peer_ref(requested_peer_ref)?;
    let paths = OperatorStatePaths::resolve(state_dir)?;

    validate_file_transfer_registration_preconditions(&paths, session_id, requested_peer_ref)?;
    let source = file_transfer_source_snapshot(source_path)?;

    let now = now_unix_ms()?;
    let _session_lock = FileLock::acquire(&paths.session_lock_file)?;
    let session_registry = load_session_registry(&paths.session_registry_file)?;
    let session = session_registry
        .sessions
        .get(session_id)
        .ok_or(OperatorStateError::SessionNotFound)?;
    validate_session_record(session_id, session, now)?;
    let destination = file_transfer_destination_binding(session, requested_peer_ref)?;

    let _request_lock = FileLock::acquire(&paths.file_transfer_request_lock_file)?;
    let mut request_registry =
        load_file_transfer_request_registry(&paths.file_transfer_request_registry_file)?;
    validate_file_transfer_request_capacity(&request_registry, session_id)?;

    let request = FileTransferControlRequest {
        schema_version: OPERATOR_STATE_SCHEMA_VERSION,
        request_id: next_file_transfer_request_id(now),
        session_id: session.session_id.clone(),
        target_runtime_id: session.target_runtime_id.clone(),
        action: FileTransferControlAction::Send,
        source,
        destination,
        status: FileTransferControlRequestStatus::PendingAgentObservation,
        created_at_unix_ms: now,
        updated_at_unix_ms: now,
        transfer_started_at_unix_ms: None,
        bytes_transferred: 0,
        receipt_verified: false,
        receipt_sha256_match: false,
        transfer_completed_at_unix_ms: None,
        failure_reason: None,
    };
    request_registry
        .requests
        .insert(request.request_id.clone(), request.clone());
    store_file_transfer_request_registry(
        &paths.file_transfer_request_registry_file,
        &request_registry,
    )?;
    let persisted =
        load_file_transfer_request_registry(&paths.file_transfer_request_registry_file)?;
    if persisted.requests.get(&request.request_id) != Some(&request) {
        return Err(OperatorStateError::FileTransferRequestRegistryPersistVerify);
    }
    let pending_requests_for_session = file_transfer_pending_count(&persisted, session_id);

    Ok(FileTransferRequestRegistration {
        request,
        pending_requests_for_session,
    })
}

pub fn read_file_transfer_history(
    state_dir: &str,
    session_filter: Option<&str>,
) -> Result<FileTransferHistorySnapshot, OperatorStateError> {
    let paths = OperatorStatePaths::resolve(state_dir)?;
    let now = now_unix_ms()?;
    let _session_lock = FileLock::acquire(&paths.session_lock_file)?;
    let session_registry = load_session_registry(&paths.session_registry_file)?;
    if let Some(session_id) = session_filter {
        let session = session_registry
            .sessions
            .get(session_id)
            .ok_or(OperatorStateError::SessionNotFound)?;
        validate_session_record(session_id, session, now)?;
    }

    let _request_lock = FileLock::acquire(&paths.file_transfer_request_lock_file)?;
    let request_registry =
        load_file_transfer_request_registry(&paths.file_transfer_request_registry_file)?;
    let mut history = request_registry
        .requests
        .values()
        .filter(|request| session_filter.is_none_or(|session_id| request.session_id == session_id))
        .cloned()
        .collect::<Vec<_>>();
    history.sort_by_key(|request| std::cmp::Reverse(request.updated_at_unix_ms));
    let pending_requests = history
        .iter()
        .filter(|request| {
            request.status == FileTransferControlRequestStatus::PendingAgentObservation
        })
        .count();
    Ok(FileTransferHistorySnapshot {
        sessions_total: session_registry.sessions.len(),
        pending_requests,
        latest_request: history.first().cloned(),
        history,
    })
}

pub fn read_session_inventory(
    state_dir: &str,
    session_filter: Option<&str>,
) -> Result<SessionInventorySnapshot, OperatorStateError> {
    let paths = OperatorStatePaths::resolve(state_dir)?;
    let now = now_unix_ms()?;
    let session_registry = load_session_registry(&paths.session_registry_file)?;
    let mut sessions = Vec::new();

    if let Some(session_id) = session_filter {
        let session = session_registry
            .sessions
            .get(session_id)
            .ok_or(OperatorStateError::SessionNotFound)?;
        sessions.push(session_summary(session, now));
    } else {
        sessions.extend(
            session_registry
                .sessions
                .values()
                .map(|session| session_summary(session, now)),
        );
    }

    Ok(SessionInventorySnapshot {
        sessions_total: session_registry.sessions.len(),
        sessions,
    })
}

fn session_summary(session: &RuntimeSessionRecord, now_unix_ms: i64) -> RuntimeSessionSummary {
    let expired = session.expires_at_unix_ms <= now_unix_ms;
    let product_control_secure_session_ready = session.state == "established"
        && session.secure_session_state == "Established"
        && session.readiness.kind == "product_control_secure_session"
        && !expired;
    RuntimeSessionSummary {
        session_ref: session_ref(&session.session_id),
        session_id_present: !session.session_id.trim().is_empty(),
        target_runtime_id_present: !session.target_runtime_id.trim().is_empty(),
        remote_device_id_present: session
            .remote_device_id
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty()),
        remote_identity_bound: session
            .remote_protocol_public_key_fingerprint
            .as_deref()
            .is_some_and(|value| !value.trim().is_empty()),
        state: session.state.clone(),
        secure_session_state: session.secure_session_state.clone(),
        readiness_kind: session.readiness.kind.clone(),
        expires_at_unix_ms: session.expires_at_unix_ms,
        expired,
        product_control_secure_session_ready,
    }
}

fn session_ref(session_id: &str) -> String {
    let digest = Sha256::digest(session_id.as_bytes());
    let mut hex = String::with_capacity(16);
    for byte in digest.iter().take(8) {
        write!(&mut hex, "{byte:02x}").expect("write to string");
    }
    format!("session-{hex}")
}

pub fn read_nearby_discovery_snapshot(
    state_dir: &str,
    active_scan_requested: bool,
) -> Result<NearbyDiscoverySnapshotRead, OperatorStateError> {
    let paths = OperatorStatePaths::resolve(state_dir)?;
    let registry =
        load_nearby_discovery_snapshot_registry(&paths.nearby_discovery_snapshot_registry_file)?;
    let snapshots_total = registry.snapshots.len();
    let now = OffsetDateTime::now_utc();

    let snapshot = if active_scan_requested {
        select_latest_fresh_snapshot(
            registry
                .snapshots
                .values()
                .filter(|snapshot| snapshot.source == ACTIVE_SCAN_SOURCE),
            now,
            OperatorStateError::NearbyDiscoveryActiveScanSnapshotMissing,
            OperatorStateError::NearbyDiscoveryActiveScanSnapshotStale,
        )?
    } else {
        select_latest_fresh_snapshot(
            registry.snapshots.values(),
            now,
            OperatorStateError::NearbyDiscoverySnapshotMissing,
            OperatorStateError::NearbyDiscoverySnapshotStale,
        )?
    };

    Ok(NearbyDiscoverySnapshotRead {
        snapshots_total,
        snapshot,
    })
}

fn validate_file_transfer_registration_preconditions(
    paths: &OperatorStatePaths,
    session_id: &str,
    requested_peer_ref: &str,
) -> Result<(), OperatorStateError> {
    let now = now_unix_ms()?;
    let _session_lock = FileLock::acquire(&paths.session_lock_file)?;
    let session_registry = load_session_registry(&paths.session_registry_file)?;
    let session = session_registry
        .sessions
        .get(session_id)
        .ok_or(OperatorStateError::SessionNotFound)?;
    validate_session_record(session_id, session, now)?;
    file_transfer_destination_binding(session, requested_peer_ref)?;

    let _request_lock = FileLock::acquire(&paths.file_transfer_request_lock_file)?;
    let request_registry =
        load_file_transfer_request_registry(&paths.file_transfer_request_registry_file)?;
    validate_file_transfer_request_capacity(&request_registry, session_id)
}

pub fn read_remote_desktop_status(
    state_dir: &str,
    session_filter: Option<&str>,
) -> Result<RemoteDesktopStatusSnapshot, OperatorStateError> {
    let paths = OperatorStatePaths::resolve(state_dir)?;
    let now = now_unix_ms()?;
    let _session_lock = FileLock::acquire(&paths.session_lock_file)?;
    let session_registry = load_session_registry(&paths.session_registry_file)?;
    if let Some(session_id) = session_filter {
        let session = session_registry
            .sessions
            .get(session_id)
            .ok_or(OperatorStateError::SessionNotFound)?;
        validate_session_record(session_id, session, now)?;
    }

    let _request_lock = FileLock::acquire(&paths.remote_desktop_request_lock_file)?;
    let request_registry =
        load_remote_desktop_request_registry(&paths.remote_desktop_request_registry_file)?;
    let mut requests = request_registry
        .requests
        .values()
        .filter(|request| session_filter.is_none_or(|session_id| request.session_id == session_id))
        .cloned()
        .collect::<Vec<_>>();
    requests.sort_by_key(|request| std::cmp::Reverse(request.updated_at_unix_ms));
    let pending_requests = requests
        .iter()
        .filter(|request| {
            request.status == RemoteDesktopControlRequestStatus::PendingAgentObservation
        })
        .count();
    Ok(RemoteDesktopStatusSnapshot {
        sessions_total: session_registry.sessions.len(),
        pending_requests,
        latest_request: requests.into_iter().next(),
    })
}

fn validate_file_transfer_request_capacity(
    registry: &FileTransferControlRequestRegistry,
    session_id: &str,
) -> Result<(), OperatorStateError> {
    if registry.requests.values().any(|request| {
        request.session_id == session_id
            && request.status == FileTransferControlRequestStatus::PendingAgentObservation
    }) {
        return Err(OperatorStateError::PendingRequestExists);
    }
    if registry.requests.len() >= FILE_TRANSFER_REQUEST_REGISTRY_MAX_REQUESTS {
        return Err(OperatorStateError::RequestRegistryFull);
    }
    Ok(())
}

fn file_transfer_pending_count(
    registry: &FileTransferControlRequestRegistry,
    session_id: &str,
) -> usize {
    registry
        .requests
        .values()
        .filter(|request| {
            request.session_id == session_id
                && request.status == FileTransferControlRequestStatus::PendingAgentObservation
        })
        .count()
}

fn validate_peer_ref(value: &str) -> Result<&str, OperatorStateError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > MAX_OPERATOR_REF_BYTES
        || trimmed.chars().any(char::is_control)
    {
        return Err(OperatorStateError::InvalidPeerRef);
    }
    Ok(trimmed)
}

fn validate_session_binding_text(value: &str) -> Result<&str, OperatorStateError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed != value
        || trimmed.len() > MAX_OPERATOR_REF_BYTES
        || trimmed.chars().any(char::is_control)
    {
        return Err(OperatorStateError::InvalidSessionBinding);
    }
    Ok(trimmed)
}

fn validate_protocol_public_key_fingerprint(value: &str) -> Result<&str, OperatorStateError> {
    let trimmed = value.trim();
    if trimmed.len() == 64
        && trimmed == value
        && trimmed
            .chars()
            .all(|ch| ch.is_ascii_digit() || matches!(ch, 'a'..='f'))
    {
        return Ok(trimmed);
    }
    Err(OperatorStateError::InvalidSessionBinding)
}

fn file_transfer_destination_binding(
    session: &RuntimeSessionRecord,
    requested_peer_ref: &str,
) -> Result<FileTransferDestinationBinding, OperatorStateError> {
    let remote_device_id = session
        .remote_device_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or(OperatorStateError::PeerBindingMissing)?;
    let remote_protocol_public_key_fingerprint = session
        .remote_protocol_public_key_fingerprint
        .as_deref()
        .map(str::trim)
        .filter(|value| validate_protocol_public_key_fingerprint(value).is_ok())
        .ok_or(OperatorStateError::PeerBindingMissing)?;
    if requested_peer_ref != remote_device_id {
        return Err(OperatorStateError::PeerMismatch);
    }
    Ok(FileTransferDestinationBinding {
        requested_peer_ref: requested_peer_ref.to_string(),
        remote_device_id: remote_device_id.to_string(),
        remote_protocol_public_key_fingerprint: remote_protocol_public_key_fingerprint.to_string(),
    })
}

fn file_transfer_source_snapshot(
    source_path: &str,
) -> Result<FileTransferSourceSnapshot, OperatorStateError> {
    let trimmed = source_path.trim();
    if trimmed.is_empty() {
        return Err(OperatorStateError::FileTransferSourceMissing);
    }
    let path = PathBuf::from(trimmed);
    reject_unsafe_path_components(&path)
        .map_err(|_| OperatorStateError::FileTransferSourceUnsafe)?;
    let symlink_metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(OperatorStateError::FileTransferSourceMissing);
        }
        Err(_) => return Err(OperatorStateError::FileTransferSourceRead),
    };
    if metadata_is_unsafe(&symlink_metadata) {
        return Err(OperatorStateError::FileTransferSourceUnsafe);
    }
    if !symlink_metadata.is_file() {
        return Err(OperatorStateError::FileTransferSourceNotRegularFile);
    }

    let mut file = File::open(&path).map_err(|_| OperatorStateError::FileTransferSourceRead)?;
    let metadata = file
        .metadata()
        .map_err(|_| OperatorStateError::FileTransferSourceRead)?;
    if !metadata.is_file() {
        return Err(OperatorStateError::FileTransferSourceNotRegularFile);
    }
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; FILE_TRANSFER_SOURCE_HASH_BUFFER_BYTES];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|_| OperatorStateError::FileTransferHashFailed)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    let mut sha256_hex = String::with_capacity(64);
    for byte in hasher.finalize() {
        write!(&mut sha256_hex, "{byte:02x}")
            .map_err(|_| OperatorStateError::FileTransferHashFailed)?;
    }

    Ok(FileTransferSourceSnapshot {
        source_path: trimmed.to_string(),
        size_bytes: metadata.len(),
        sha256_hex,
    })
}

fn validate_remote_desktop_payload(
    action: RemoteDesktopControlAction,
    payload: &RemoteDesktopControlRequestPayload,
) -> Result<(), OperatorStateError> {
    match action {
        RemoteDesktopControlAction::Start => {
            if payload.resolution.is_none() || payload.fps.is_none() {
                return Err(OperatorStateError::InvalidRequestPayload);
            }
        }
        RemoteDesktopControlAction::Stop => {
            if payload.resolution.is_some() || payload.fps.is_some() {
                return Err(OperatorStateError::InvalidRequestPayload);
            }
        }
        RemoteDesktopControlAction::SetResolution => {
            if payload.resolution.is_none() || payload.fps.is_some() {
                return Err(OperatorStateError::InvalidRequestPayload);
            }
        }
        RemoteDesktopControlAction::SetFps => {
            if payload.resolution.is_some() || payload.fps.is_none() {
                return Err(OperatorStateError::InvalidRequestPayload);
            }
        }
    }
    if let Some(resolution) = &payload.resolution {
        let id = resolution.id();
        if remote_desktop_resolution_request(id).as_ref() != Ok(resolution) {
            return Err(OperatorStateError::InvalidRequestPayload);
        }
    }
    if payload
        .fps
        .is_some_and(|fps| !remote_desktop_fps_supported(fps))
    {
        return Err(OperatorStateError::InvalidRequestPayload);
    }
    Ok(())
}

fn validate_session_record(
    session_key: &str,
    session: &RuntimeSessionRecord,
    now_unix_ms: i64,
) -> Result<(), OperatorStateError> {
    if session.schema_version != OPERATOR_STATE_SCHEMA_VERSION
        || session.session_id.trim().is_empty()
        || session.target_runtime_id.trim().is_empty()
        || session_key != session.session_id
    {
        return Err(OperatorStateError::SessionRegistryInvalid);
    }
    if session.state != "established"
        || session.secure_session_state != "Established"
        || session.readiness.kind != "product_control_secure_session"
    {
        return Err(OperatorStateError::SessionNotEstablished);
    }
    if session.expires_at_unix_ms <= now_unix_ms {
        return Err(OperatorStateError::SessionStale);
    }
    Ok(())
}

fn load_session_registry(path: &Path) -> Result<RuntimeSessionRegistry, OperatorStateError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(OperatorStateError::SessionRegistryMissing);
        }
        Err(_) => return Err(OperatorStateError::SessionRegistryRead),
    };
    if metadata_is_unsafe(&metadata) {
        return Err(OperatorStateError::UnsafePath);
    }
    if !metadata.is_file() {
        return Err(OperatorStateError::SessionRegistryInvalid);
    }
    if metadata.len() > MAX_SESSION_REGISTRY_BYTES {
        return Err(OperatorStateError::SessionRegistryTooLarge);
    }

    let mut file = File::open(path).map_err(|_| OperatorStateError::SessionRegistryRead)?;
    let metadata = file
        .metadata()
        .map_err(|_| OperatorStateError::SessionRegistryRead)?;
    if !metadata.is_file() {
        return Err(OperatorStateError::SessionRegistryInvalid);
    }
    if metadata.len() > MAX_SESSION_REGISTRY_BYTES {
        return Err(OperatorStateError::SessionRegistryTooLarge);
    }

    let mut body = String::new();
    file.read_to_string(&mut body)
        .map_err(|_| OperatorStateError::SessionRegistryRead)?;
    let registry = serde_json::from_str::<RuntimeSessionRegistry>(&body)
        .map_err(|_| OperatorStateError::SessionRegistryJson)?;
    validate_session_registry(&registry)?;
    Ok(registry)
}

fn load_session_registry_for_write(
    path: &Path,
) -> Result<RuntimeSessionRegistry, OperatorStateError> {
    match load_session_registry(path) {
        Ok(registry) => Ok(registry),
        Err(OperatorStateError::SessionRegistryMissing) => Ok(RuntimeSessionRegistry::default()),
        Err(error) => Err(error),
    }
}

fn load_remote_desktop_request_registry(
    path: &Path,
) -> Result<RemoteDesktopControlRequestRegistry, OperatorStateError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(RemoteDesktopControlRequestRegistry::default());
        }
        Err(_) => return Err(OperatorStateError::RequestRegistryRead),
    };
    if metadata_is_unsafe(&metadata) {
        return Err(OperatorStateError::UnsafePath);
    }
    if !metadata.is_file() || metadata.len() > MAX_REMOTE_DESKTOP_REQUEST_REGISTRY_BYTES {
        return Err(OperatorStateError::RequestRegistryInvalid);
    }

    let mut file = File::open(path).map_err(|_| OperatorStateError::RequestRegistryRead)?;
    let metadata = file
        .metadata()
        .map_err(|_| OperatorStateError::RequestRegistryRead)?;
    if !metadata.is_file() || metadata.len() > MAX_REMOTE_DESKTOP_REQUEST_REGISTRY_BYTES {
        return Err(OperatorStateError::RequestRegistryInvalid);
    }

    let mut body = String::new();
    file.read_to_string(&mut body)
        .map_err(|_| OperatorStateError::RequestRegistryRead)?;
    let registry = serde_json::from_str::<RemoteDesktopControlRequestRegistry>(&body)
        .map_err(|_| OperatorStateError::RequestRegistryJson)?;
    validate_remote_desktop_request_registry(&registry)?;
    Ok(registry)
}

fn load_file_transfer_request_registry(
    path: &Path,
) -> Result<FileTransferControlRequestRegistry, OperatorStateError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(FileTransferControlRequestRegistry::default());
        }
        Err(_) => return Err(OperatorStateError::FileTransferRequestRegistryRead),
    };
    if metadata_is_unsafe(&metadata) {
        return Err(OperatorStateError::UnsafePath);
    }
    if !metadata.is_file() || metadata.len() > MAX_FILE_TRANSFER_REQUEST_REGISTRY_BYTES {
        return Err(OperatorStateError::FileTransferRequestRegistryInvalid);
    }

    let mut file =
        File::open(path).map_err(|_| OperatorStateError::FileTransferRequestRegistryRead)?;
    let metadata = file
        .metadata()
        .map_err(|_| OperatorStateError::FileTransferRequestRegistryRead)?;
    if !metadata.is_file() || metadata.len() > MAX_FILE_TRANSFER_REQUEST_REGISTRY_BYTES {
        return Err(OperatorStateError::FileTransferRequestRegistryInvalid);
    }

    let mut body = String::new();
    file.read_to_string(&mut body)
        .map_err(|_| OperatorStateError::FileTransferRequestRegistryRead)?;
    let registry = serde_json::from_str::<FileTransferControlRequestRegistry>(&body)
        .map_err(|_| OperatorStateError::FileTransferRequestRegistryJson)?;
    validate_file_transfer_request_registry(&registry)?;
    Ok(registry)
}

fn load_nearby_discovery_snapshot_registry(
    path: &Path,
) -> Result<NearbyDiscoverySnapshotRegistry, OperatorStateError> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(OperatorStateError::NearbyDiscoverySnapshotMissing);
        }
        Err(_) => return Err(OperatorStateError::NearbyDiscoverySnapshotRegistryRead),
    };
    if metadata_is_unsafe(&metadata) {
        return Err(OperatorStateError::UnsafePath);
    }
    if !metadata.is_file() {
        return Err(OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid);
    }
    if metadata.len() > MAX_NEARBY_DISCOVERY_SNAPSHOT_REGISTRY_BYTES {
        return Err(OperatorStateError::NearbyDiscoverySnapshotRegistryTooLarge);
    }

    let mut file =
        File::open(path).map_err(|_| OperatorStateError::NearbyDiscoverySnapshotRegistryRead)?;
    let metadata = file
        .metadata()
        .map_err(|_| OperatorStateError::NearbyDiscoverySnapshotRegistryRead)?;
    if !metadata.is_file() {
        return Err(OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid);
    }
    if metadata.len() > MAX_NEARBY_DISCOVERY_SNAPSHOT_REGISTRY_BYTES {
        return Err(OperatorStateError::NearbyDiscoverySnapshotRegistryTooLarge);
    }

    let mut body = String::new();
    file.read_to_string(&mut body)
        .map_err(|_| OperatorStateError::NearbyDiscoverySnapshotRegistryRead)?;
    let registry = serde_json::from_str::<NearbyDiscoverySnapshotRegistry>(&body)
        .map_err(|_| OperatorStateError::NearbyDiscoverySnapshotRegistryJson)?;
    validate_nearby_discovery_snapshot_registry(&registry)?;
    Ok(registry)
}

fn store_session_registry(
    path: &Path,
    registry: &RuntimeSessionRegistry,
) -> Result<(), OperatorStateError> {
    reject_existing_unsafe_file(path).map_err(|_| OperatorStateError::UnsafePath)?;
    validate_session_registry(registry)?;
    let body = serde_json::to_vec_pretty(registry)
        .map_err(|_| OperatorStateError::SessionRegistryWrite)?;
    let file_name = path
        .file_name()
        .ok_or(OperatorStateError::SessionRegistryWrite)?
        .to_string_lossy();
    let temp_path = path.with_file_name(format!(
        ".{file_name}.tmp-{}-{}",
        std::process::id(),
        REQUEST_COUNTER.fetch_add(1, Ordering::SeqCst)
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp_path)
        .map_err(|_| OperatorStateError::SessionRegistryWrite)?;
    file.write_all(&body)
        .and_then(|_| file.sync_all())
        .map_err(|_| OperatorStateError::SessionRegistryWrite)?;
    drop(file);
    restrict_file_permissions(&temp_path).map_err(|_| OperatorStateError::SessionRegistryWrite)?;
    persist_temp_file(&temp_path, path).map_err(|_| OperatorStateError::SessionRegistryWrite)?;
    restrict_file_permissions(path).map_err(|_| OperatorStateError::SessionRegistryWrite)
}

fn store_remote_desktop_request_registry(
    path: &Path,
    registry: &RemoteDesktopControlRequestRegistry,
) -> Result<(), OperatorStateError> {
    reject_existing_unsafe_file(path)?;
    validate_remote_desktop_request_registry(registry)?;
    let body = serde_json::to_vec_pretty(registry)
        .map_err(|_| OperatorStateError::RequestRegistryWrite)?;
    let file_name = path
        .file_name()
        .ok_or(OperatorStateError::RequestRegistryWrite)?
        .to_string_lossy();
    let temp_path = path.with_file_name(format!(
        ".{file_name}.tmp-{}-{}",
        std::process::id(),
        REQUEST_COUNTER.fetch_add(1, Ordering::SeqCst)
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp_path)
        .map_err(|_| OperatorStateError::RequestRegistryWrite)?;
    file.write_all(&body)
        .and_then(|_| file.sync_all())
        .map_err(|_| OperatorStateError::RequestRegistryWrite)?;
    drop(file);
    restrict_file_permissions(&temp_path)?;
    persist_temp_file(&temp_path, path)?;
    restrict_file_permissions(path)
}

fn store_file_transfer_request_registry(
    path: &Path,
    registry: &FileTransferControlRequestRegistry,
) -> Result<(), OperatorStateError> {
    reject_existing_unsafe_file(path)?;
    validate_file_transfer_request_registry(registry)?;
    let body = serde_json::to_vec_pretty(registry)
        .map_err(|_| OperatorStateError::FileTransferRequestRegistryWrite)?;
    let file_name = path
        .file_name()
        .ok_or(OperatorStateError::FileTransferRequestRegistryWrite)?
        .to_string_lossy();
    let temp_path = path.with_file_name(format!(
        ".{file_name}.tmp-{}-{}",
        std::process::id(),
        REQUEST_COUNTER.fetch_add(1, Ordering::SeqCst)
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp_path)
        .map_err(|_| OperatorStateError::FileTransferRequestRegistryWrite)?;
    file.write_all(&body)
        .and_then(|_| file.sync_all())
        .map_err(|_| OperatorStateError::FileTransferRequestRegistryWrite)?;
    drop(file);
    restrict_file_permissions(&temp_path)
        .map_err(|_| OperatorStateError::FileTransferRequestRegistryWrite)?;
    persist_temp_file(&temp_path, path)
        .map_err(|_| OperatorStateError::FileTransferRequestRegistryWrite)?;
    restrict_file_permissions(path)
        .map_err(|_| OperatorStateError::FileTransferRequestRegistryWrite)
}

fn validate_remote_desktop_request_registry(
    registry: &RemoteDesktopControlRequestRegistry,
) -> Result<(), OperatorStateError> {
    if registry.schema_version != OPERATOR_STATE_SCHEMA_VERSION {
        return Err(OperatorStateError::RequestRegistrySchema);
    }
    if registry.requests.len() > REMOTE_DESKTOP_REQUEST_REGISTRY_MAX_REQUESTS {
        return Err(OperatorStateError::RequestRegistryInvalid);
    }
    for (request_id, request) in &registry.requests {
        if request_id != &request.request_id
            || request.schema_version != OPERATOR_STATE_SCHEMA_VERSION
            || request.request_id.trim().is_empty()
            || request.session_id.trim().is_empty()
            || request.target_runtime_id.trim().is_empty()
        {
            return Err(OperatorStateError::RequestRegistryInvalid);
        }
        validate_remote_desktop_payload(request.action, &request.payload)?;
    }
    Ok(())
}

fn validate_session_registry(registry: &RuntimeSessionRegistry) -> Result<(), OperatorStateError> {
    if registry.schema_version != OPERATOR_STATE_SCHEMA_VERSION {
        return Err(OperatorStateError::SessionRegistrySchema);
    }
    for (session_id, session) in &registry.sessions {
        if session_id != &session.session_id
            || session.schema_version != OPERATOR_STATE_SCHEMA_VERSION
            || validate_session_binding_text(&session.session_id).is_err()
            || validate_session_binding_text(&session.target_runtime_id).is_err()
        {
            return Err(OperatorStateError::SessionRegistryInvalid);
        }
        if let Some(remote_device_id) = session.remote_device_id.as_deref() {
            validate_session_binding_text(remote_device_id)
                .map_err(|_| OperatorStateError::SessionRegistryInvalid)?;
        }
        if let Some(fingerprint) = session.remote_protocol_public_key_fingerprint.as_deref() {
            validate_protocol_public_key_fingerprint(fingerprint)
                .map_err(|_| OperatorStateError::SessionRegistryInvalid)?;
        }
    }
    Ok(())
}

fn validate_file_transfer_request_registry(
    registry: &FileTransferControlRequestRegistry,
) -> Result<(), OperatorStateError> {
    if registry.schema_version != OPERATOR_STATE_SCHEMA_VERSION {
        return Err(OperatorStateError::FileTransferRequestRegistrySchema);
    }
    if registry.requests.len() > FILE_TRANSFER_REQUEST_REGISTRY_MAX_REQUESTS {
        return Err(OperatorStateError::FileTransferRequestRegistryInvalid);
    }
    for (request_id, request) in &registry.requests {
        if request_id != &request.request_id
            || request.schema_version != OPERATOR_STATE_SCHEMA_VERSION
            || request.request_id.trim().is_empty()
            || request.session_id.trim().is_empty()
            || request.target_runtime_id.trim().is_empty()
        {
            return Err(OperatorStateError::FileTransferRequestRegistryInvalid);
        }
        if request.source.source_path.trim().is_empty()
            || request.source.sha256_hex.len() != 64
            || !request
                .source
                .sha256_hex
                .chars()
                .all(|ch| ch.is_ascii_digit() || matches!(ch, 'a'..='f'))
        {
            return Err(OperatorStateError::FileTransferRequestRegistryInvalid);
        }
        if validate_peer_ref(&request.destination.requested_peer_ref).is_err()
            || request.destination.remote_device_id.trim().is_empty()
            || request
                .destination
                .remote_protocol_public_key_fingerprint
                .len()
                != 64
            || !request
                .destination
                .remote_protocol_public_key_fingerprint
                .chars()
                .all(|ch| ch.is_ascii_digit() || matches!(ch, 'a'..='f'))
        {
            return Err(OperatorStateError::FileTransferRequestRegistryInvalid);
        }
        if request.status == FileTransferControlRequestStatus::PendingAgentObservation
            && (request.transfer_started_at_unix_ms.is_some()
                || request.transfer_completed_at_unix_ms.is_some()
                || request.bytes_transferred != 0
                || request.receipt_verified
                || request.receipt_sha256_match
                || request.failure_reason.is_some())
        {
            return Err(OperatorStateError::FileTransferRequestRegistryInvalid);
        }
        if request.status == FileTransferControlRequestStatus::TransferCompleted
            && (!request.receipt_verified || !request.receipt_sha256_match)
        {
            return Err(OperatorStateError::FileTransferRequestRegistryInvalid);
        }
    }
    Ok(())
}

fn validate_nearby_discovery_snapshot_registry(
    registry: &NearbyDiscoverySnapshotRegistry,
) -> Result<(), OperatorStateError> {
    if registry.schema_version != OPERATOR_STATE_SCHEMA_VERSION {
        return Err(OperatorStateError::NearbyDiscoverySnapshotRegistrySchema);
    }
    if registry.snapshots.len() > NEARBY_DISCOVERY_SNAPSHOT_REGISTRY_MAX_SNAPSHOTS {
        return Err(OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid);
    }
    for (scan_id, snapshot) in &registry.snapshots {
        if scan_id != &snapshot.scan_id {
            return Err(OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid);
        }
        validate_nearby_discovery_snapshot(snapshot)?;
    }
    Ok(())
}

fn validate_nearby_discovery_snapshot(
    snapshot: &NearbyDiscoverySnapshot,
) -> Result<(), OperatorStateError> {
    if snapshot.schema_version != OPERATOR_STATE_SCHEMA_VERSION {
        return Err(OperatorStateError::NearbyDiscoverySnapshotRegistrySchema);
    }
    validate_discovery_public_projection_text(&snapshot.scan_id)?;
    validate_discovery_public_projection_text(&snapshot.source)?;
    if snapshot.expires_at <= snapshot.observed_at || snapshot.updated_at < snapshot.observed_at {
        return Err(OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid);
    }
    if snapshot.devices.len() > NEARBY_DISCOVERY_SNAPSHOT_MAX_DEVICES {
        return Err(OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid);
    }
    for device in &snapshot.devices {
        validate_discovery_device_projection(device)?;
    }
    Ok(())
}

fn validate_discovery_device_projection(
    device: &NearbyDiscoveredDevice,
) -> Result<(), OperatorStateError> {
    validate_discovery_public_projection_text(&device.device_ref)?;
    validate_discovery_public_projection_text(&device.display_name)?;
    for capability in &device.capabilities {
        validate_discovery_public_projection_text(capability)?;
    }
    if device.connectable && !device.trust_status.permits_connectable_projection() {
        return Err(OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid);
    }
    Ok(())
}

fn validate_discovery_public_projection_text(value: &str) -> Result<(), OperatorStateError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed != value
        || value.len() > MAX_DISCOVERY_PUBLIC_TEXT_BYTES
        || value.chars().any(char::is_control)
        || looks_like_private_locator(value)
    {
        return Err(OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid);
    }
    Ok(())
}

fn looks_like_private_locator(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    lower.contains("://")
        || lower.contains(".local")
        || lower.contains("._tcp")
        || lower.contains("._udp")
        || lower.contains('@')
        || lower.contains(':')
        || lower.contains('/')
        || lower.contains('\\')
        || looks_like_hex_fingerprint(value)
        || contains_ipv4_address(value)
}

fn looks_like_hex_fingerprint(value: &str) -> bool {
    value.len() == 64
        && value
            .chars()
            .all(|ch| ch.is_ascii_digit() || matches!(ch, 'a'..='f' | 'A'..='F'))
}

fn contains_ipv4_address(value: &str) -> bool {
    value
        .split(|ch: char| !(ch.is_ascii_digit() || ch == '.'))
        .filter(|token| token.contains('.'))
        .any(looks_like_ipv4_address)
}

fn looks_like_ipv4_address(token: &str) -> bool {
    let parts = token.split('.').collect::<Vec<_>>();
    parts.len() == 4
        && parts.iter().all(|part| {
            !part.is_empty()
                && part.len() <= 3
                && part.chars().all(|ch| ch.is_ascii_digit())
                && part.parse::<u8>().is_ok()
        })
}

fn select_latest_fresh_snapshot<'a>(
    snapshots: impl Iterator<Item = &'a NearbyDiscoverySnapshot>,
    now: OffsetDateTime,
    missing_error: OperatorStateError,
    stale_error: OperatorStateError,
) -> Result<NearbyDiscoverySnapshot, OperatorStateError> {
    let mut latest_fresh: Option<&NearbyDiscoverySnapshot> = None;
    let mut saw_stale = false;

    for snapshot in snapshots {
        if snapshot.expires_at <= now {
            saw_stale = true;
            continue;
        }
        if latest_fresh.is_none_or(|latest| snapshot.updated_at > latest.updated_at) {
            latest_fresh = Some(snapshot);
        }
    }

    if let Some(snapshot) = latest_fresh {
        return Ok(snapshot.clone());
    }
    if saw_stale {
        return Err(stale_error);
    }
    Err(missing_error)
}

fn now_unix_ms() -> Result<i64, OperatorStateError> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| OperatorStateError::Clock)?
        .as_millis() as i64)
}

fn next_request_id(now_unix_ms: i64) -> String {
    let counter = REQUEST_COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("rd-{now_unix_ms}-{}-{counter}", std::process::id())
}

fn next_file_transfer_request_id(now_unix_ms: i64) -> String {
    let counter = REQUEST_COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("ft-{now_unix_ms}-{}-{counter}", std::process::id())
}

struct OperatorStatePaths {
    session_registry_file: PathBuf,
    session_lock_file: PathBuf,
    remote_desktop_request_registry_file: PathBuf,
    remote_desktop_request_lock_file: PathBuf,
    file_transfer_request_registry_file: PathBuf,
    file_transfer_request_lock_file: PathBuf,
    nearby_discovery_snapshot_registry_file: PathBuf,
}

impl OperatorStatePaths {
    fn resolve(state_dir: &str) -> Result<Self, OperatorStateError> {
        let trimmed = state_dir.trim();
        if trimmed.is_empty() {
            return Err(OperatorStateError::MissingStateDir);
        }
        let root = PathBuf::from(trimmed);
        reject_unsafe_path_components(&root)?;
        let metadata = fs::metadata(&root).map_err(|_| OperatorStateError::StateDirUnavailable)?;
        if !metadata.is_dir() {
            return Err(OperatorStateError::StateDirNotDirectory);
        }
        let runtime_dir = root.join(RUNTIME_DIR);
        reject_unsafe_path_components(&runtime_dir)?;
        let metadata =
            fs::metadata(&runtime_dir).map_err(|_| OperatorStateError::SessionRegistryMissing)?;
        if !metadata.is_dir() {
            return Err(OperatorStateError::SessionRegistryMissing);
        }
        Ok(Self {
            session_registry_file: runtime_dir.join(SESSIONS_FILE),
            session_lock_file: runtime_dir.join(SESSIONS_LOCK_FILE),
            remote_desktop_request_registry_file: runtime_dir.join(REMOTE_DESKTOP_REQUESTS_FILE),
            remote_desktop_request_lock_file: runtime_dir.join(REMOTE_DESKTOP_REQUESTS_LOCK_FILE),
            file_transfer_request_registry_file: runtime_dir.join(FILE_TRANSFER_REQUESTS_FILE),
            file_transfer_request_lock_file: runtime_dir.join(FILE_TRANSFER_REQUESTS_LOCK_FILE),
            nearby_discovery_snapshot_registry_file: runtime_dir
                .join(NEARBY_DISCOVERY_SNAPSHOTS_FILE),
        })
    }
}

struct FileLock {
    path: PathBuf,
}

impl FileLock {
    fn acquire(path: &Path) -> Result<Self, OperatorStateError> {
        reject_existing_unsafe_file(path)?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .map_err(|_| OperatorStateError::RegistryLocked)?;
        writeln!(file, "pid={}", std::process::id())
            .and_then(|_| file.sync_all())
            .map_err(|_| OperatorStateError::RegistryLocked)?;
        Ok(Self {
            path: path.to_path_buf(),
        })
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn reject_existing_unsafe_file(path: &Path) -> Result<(), OperatorStateError> {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return Ok(());
    };
    if metadata_is_unsafe(&metadata) {
        return Err(OperatorStateError::UnsafePath);
    }
    Ok(())
}

pub(crate) fn reject_unsafe_path_components(path: &Path) -> Result<(), OperatorStateError> {
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        if current.as_os_str().is_empty() {
            continue;
        }
        let Ok(metadata) = fs::symlink_metadata(&current) else {
            continue;
        };
        if metadata_is_unsafe(&metadata) {
            return Err(OperatorStateError::UnsafePath);
        }
    }
    Ok(())
}

pub(crate) fn metadata_is_unsafe(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;

        const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;

        metadata.file_type().is_symlink()
            || (metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT) != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

fn persist_temp_file(temp_path: &Path, target_path: &Path) -> Result<(), OperatorStateError> {
    #[cfg(windows)]
    {
        if target_path.exists() {
            fs::remove_file(target_path).map_err(|_| OperatorStateError::RequestRegistryWrite)?;
        }
    }
    fs::rename(temp_path, target_path).map_err(|_| OperatorStateError::RequestRegistryWrite)
}

fn restrict_file_permissions(path: &Path) -> Result<(), OperatorStateError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|_| OperatorStateError::RequestRegistryWrite)?;
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_state_dir(name: &str) -> PathBuf {
        let dir = std::env::current_dir()
            .unwrap()
            .join("target")
            .join("test-fixtures")
            .join(format!("operator-state-unit-{}-{name}", std::process::id()));
        if dir.exists() {
            fs::remove_dir_all(&dir).unwrap();
        }
        fs::create_dir_all(dir.join(RUNTIME_DIR)).unwrap();
        dir
    }

    fn write_session_registry(
        state_dir: &Path,
        session_id: &str,
        state: &str,
        readiness_kind: &str,
        expires_at_unix_ms: i64,
    ) {
        let body = format!(
            r#"{{
  "schema_version": 1,
  "sessions": {{
    "{session_id}": {{
      "schema_version": 1,
      "session_id": "{session_id}",
      "target_runtime_id": "runtime-1",
      "remote_device_id": "peer-device-1",
      "remote_protocol_public_key_fingerprint": "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
      "state": "{state}",
      "secure_session_state": "Established",
      "readiness": {{
        "kind": "{readiness_kind}"
      }},
      "expires_at_unix_ms": {expires_at_unix_ms}
    }}
  }}
}}"#
        );
        fs::write(state_dir.join(RUNTIME_DIR).join(SESSIONS_FILE), body).unwrap();
    }

    fn start_payload() -> RemoteDesktopControlRequestPayload {
        RemoteDesktopControlRequestPayload {
            resolution: Some(remote_desktop_resolution_request("1920x1080").unwrap()),
            fps: Some(60),
        }
    }

    fn write_file_transfer_source(state_dir: &Path, name: &str) -> PathBuf {
        let path = state_dir.join(format!("{name}.txt"));
        fs::write(&path, b"operator-state file transfer fixture\n").unwrap();
        path
    }

    #[test]
    fn registers_established_product_control_session_and_refreshes_same_binding() {
        let state_dir = make_state_dir("session-import");
        let state_dir_string = state_dir.to_string_lossy().to_string();

        let registration = register_established_product_control_session(
            &state_dir_string,
            "session-1",
            "runtime-1",
            "peer-device-1",
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
            4_102_444_800_000,
        )
        .expect("session should import");

        assert!(registration.inserted);
        assert!(registration.session.product_control_secure_session_ready);
        assert!(registration.session.remote_identity_bound);
        assert_ne!(registration.session.session_ref, "session-1");

        let refreshed = register_established_product_control_session(
            &state_dir_string,
            "session-1",
            "runtime-1",
            "peer-device-1",
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
            4_102_444_900_000,
        )
        .expect("same binding should refresh");

        assert!(!refreshed.inserted);
        assert_eq!(
            refreshed.session.session_ref,
            registration.session.session_ref
        );
        assert_eq!(refreshed.session.expires_at_unix_ms, 4_102_444_900_000);

        let inventory =
            read_session_inventory(&state_dir_string, Some("session-1")).expect("inventory");
        assert_eq!(inventory.sessions_total, 1);
        assert_eq!(inventory.sessions.len(), 1);
        assert!(inventory.sessions[0].product_control_secure_session_ready);
    }

    #[test]
    fn rejects_conflicting_or_stale_product_control_session_imports() {
        let state_dir = make_state_dir("session-import-conflict");
        let state_dir_string = state_dir.to_string_lossy().to_string();
        register_established_product_control_session(
            &state_dir_string,
            "session-1",
            "runtime-1",
            "peer-device-1",
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
            4_102_444_800_000,
        )
        .expect("session should import");

        assert_eq!(
            register_established_product_control_session(
                &state_dir_string,
                "session-1",
                "runtime-2",
                "peer-device-1",
                "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
                4_102_444_800_000,
            ),
            Err(OperatorStateError::SessionBindingConflict)
        );
        assert_eq!(
            register_established_product_control_session(
                &state_dir_string,
                " session-2 ",
                "runtime-1",
                "peer-device-1",
                "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
                4_102_444_800_000,
            ),
            Err(OperatorStateError::InvalidSessionBinding)
        );
        assert_eq!(
            register_established_product_control_session(
                &state_dir_string,
                "session-2",
                "runtime-1",
                "peer-device-1",
                "001122",
                4_102_444_800_000,
            ),
            Err(OperatorStateError::InvalidSessionBinding)
        );
        assert_eq!(
            register_established_product_control_session(
                &state_dir_string,
                "session-2",
                "runtime-1",
                "peer-device-1",
                "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
                1,
            ),
            Err(OperatorStateError::SessionStale)
        );
    }

    #[test]
    fn reads_session_inventory_without_creating_lock_or_leaking_raw_ids() {
        let state_dir = make_state_dir("session-inventory-read-only");
        write_session_registry(
            &state_dir,
            "session-secret",
            "established",
            "product_control_secure_session",
            4_102_444_800_000,
        );
        let lock_path = state_dir.join(RUNTIME_DIR).join(SESSIONS_LOCK_FILE);
        assert!(!lock_path.exists(), "fixture should start without a lock");
        let state_dir_string = state_dir.to_string_lossy().to_string();

        let inventory =
            read_session_inventory(&state_dir_string, None).expect("session inventory should read");

        assert!(
            !lock_path.exists(),
            "read-only inventory must not create lock files"
        );
        assert_eq!(inventory.sessions_total, 1);
        assert_eq!(inventory.sessions.len(), 1);
        assert_ne!(inventory.sessions[0].session_ref, "session-secret");
        assert!(inventory.sessions[0].session_ref.starts_with("session-"));
        assert!(inventory.sessions[0].session_id_present);
        assert!(inventory.sessions[0].product_control_secure_session_ready);
    }

    #[test]
    fn rejects_oversized_session_registry_for_inventory_reads() {
        let state_dir = make_state_dir("session-inventory-too-large");
        let state_dir_string = state_dir.to_string_lossy().to_string();
        let oversized = vec![b' '; MAX_SESSION_REGISTRY_BYTES as usize + 1];
        fs::write(state_dir.join(RUNTIME_DIR).join(SESSIONS_FILE), oversized).unwrap();

        assert_eq!(
            read_session_inventory(&state_dir_string, None),
            Err(OperatorStateError::SessionRegistryTooLarge)
        );
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_session_registry_for_inventory_reads() {
        use std::os::unix::fs::symlink;

        let state_dir = make_state_dir("session-inventory-symlink");
        let state_dir_string = state_dir.to_string_lossy().to_string();
        let runtime_dir = state_dir.join(RUNTIME_DIR);
        let secret_target = state_dir.join("secret-sessions.json");
        write_session_registry(
            &state_dir,
            "session-secret",
            "established",
            "product_control_secure_session",
            4_102_444_800_000,
        );
        fs::rename(runtime_dir.join(SESSIONS_FILE), &secret_target).unwrap();
        symlink(&secret_target, runtime_dir.join(SESSIONS_FILE)).unwrap();

        assert_eq!(
            read_session_inventory(&state_dir_string, None),
            Err(OperatorStateError::UnsafePath)
        );
    }

    struct NearbyDiscoveryFixture<'a> {
        scan_id: &'a str,
        source: &'a str,
        observed_at: &'a str,
        expires_at: &'a str,
        updated_at: &'a str,
        device_ref: &'a str,
        display_name: &'a str,
        trust_status: &'a str,
        connectable: bool,
    }

    fn write_nearby_discovery_snapshot_registry(
        state_dir: &Path,
        fixture: NearbyDiscoveryFixture<'_>,
    ) {
        let NearbyDiscoveryFixture {
            scan_id,
            source,
            observed_at,
            expires_at,
            updated_at,
            device_ref,
            display_name,
            trust_status,
            connectable,
        } = fixture;
        let body = format!(
            r#"{{
  "schema_version": 1,
  "snapshots": {{
    "{scan_id}": {{
      "schema_version": 1,
      "scan_id": "{scan_id}",
      "source": "{source}",
      "devices": [
        {{
          "device_ref": "{device_ref}",
          "display_name": "{display_name}",
          "endpoint_class": "local_network",
          "trust_status": "{trust_status}",
          "capabilities": ["remote_desktop", "file_transfer"],
          "connectable": {connectable}
        }}
      ],
      "observed_at": "{observed_at}",
      "expires_at": "{expires_at}",
      "updated_at": "{updated_at}"
    }}
  }}
}}"#
        );
        fs::write(
            state_dir
                .join(RUNTIME_DIR)
                .join(NEARBY_DISCOVERY_SNAPSHOTS_FILE),
            body,
        )
        .unwrap();
    }

    #[test]
    fn reads_fresh_nearby_discovery_snapshot_projection() {
        let state_dir = make_state_dir("nearby-discovery-fresh");
        write_nearby_discovery_snapshot_registry(
            &state_dir,
            NearbyDiscoveryFixture {
                scan_id: "scan-1",
                source: "agent_owned_nearby_discovery_snapshot",
                observed_at: "2026-07-06T00:00:00Z",
                expires_at: "2099-01-01T00:00:00Z",
                updated_at: "2026-07-06T00:00:01Z",
                device_ref: "nearby-device-1",
                display_name: "Studio Mac",
                trust_status: "protocol_identity_verified",
                connectable: true,
            },
        );
        let state_dir_string = state_dir.to_string_lossy().to_string();

        let read =
            read_nearby_discovery_snapshot(&state_dir_string, false).expect("snapshot should read");

        assert_eq!(read.snapshots_total, 1);
        assert_eq!(read.snapshot.scan_id, "scan-1");
        assert_eq!(
            read.snapshot.source,
            "agent_owned_nearby_discovery_snapshot"
        );
        assert_eq!(read.snapshot.devices.len(), 1);
        assert_eq!(read.snapshot.devices[0].device_ref, "nearby-device-1");
        assert_eq!(read.snapshot.devices[0].display_name, "Studio Mac");
        assert_eq!(
            read.snapshot.devices[0].trust_status,
            NearbyDiscoveryTrustStatus::ProtocolIdentityVerified
        );
        assert!(read.snapshot.devices[0].connectable);
    }

    #[test]
    fn reads_active_nearby_discovery_snapshot_without_accepting_passive_for_scan() {
        let passive = make_state_dir("nearby-discovery-passive-for-active");
        let passive_string = passive.to_string_lossy().to_string();
        write_nearby_discovery_snapshot_registry(
            &passive,
            NearbyDiscoveryFixture {
                scan_id: "scan-passive",
                source: "agent_owned_nearby_discovery_snapshot",
                observed_at: "2026-07-06T00:00:00Z",
                expires_at: "2099-01-01T00:00:00Z",
                updated_at: "2026-07-06T00:00:01Z",
                device_ref: "passive-device-1",
                display_name: "Passive Mac",
                trust_status: "trusted",
                connectable: true,
            },
        );
        assert_eq!(
            read_nearby_discovery_snapshot(&passive_string, true),
            Err(OperatorStateError::NearbyDiscoveryActiveScanSnapshotMissing)
        );

        let active = make_state_dir("nearby-discovery-active");
        let active_string = active.to_string_lossy().to_string();
        write_nearby_discovery_snapshot_registry(
            &active,
            NearbyDiscoveryFixture {
                scan_id: "scan-active",
                source: ACTIVE_SCAN_SOURCE,
                observed_at: "2026-07-06T00:00:00Z",
                expires_at: "2099-01-01T00:00:00Z",
                updated_at: "2026-07-06T00:00:01Z",
                device_ref: "active-device-1",
                display_name: "Office Mac",
                trust_status: "trusted",
                connectable: true,
            },
        );

        let read = read_nearby_discovery_snapshot(&active_string, true)
            .expect("active snapshot should read");

        assert_eq!(read.snapshot.source, ACTIVE_SCAN_SOURCE);
        assert_eq!(read.snapshot.devices[0].device_ref, "active-device-1");
    }

    #[test]
    fn rejects_stale_and_untrusted_connectable_nearby_discovery_snapshots() {
        let stale = make_state_dir("nearby-discovery-stale");
        let stale_string = stale.to_string_lossy().to_string();
        write_nearby_discovery_snapshot_registry(
            &stale,
            NearbyDiscoveryFixture {
                scan_id: "scan-stale",
                source: "agent_owned_nearby_discovery_snapshot",
                observed_at: "1999-12-31T23:59:58Z",
                expires_at: "2000-01-01T00:00:00Z",
                updated_at: "1999-12-31T23:59:59Z",
                device_ref: "stale-device-1",
                display_name: "Stale Mac",
                trust_status: "trusted",
                connectable: true,
            },
        );
        assert_eq!(
            read_nearby_discovery_snapshot(&stale_string, false),
            Err(OperatorStateError::NearbyDiscoverySnapshotStale)
        );

        let untrusted = make_state_dir("nearby-discovery-untrusted-connectable");
        let untrusted_string = untrusted.to_string_lossy().to_string();
        write_nearby_discovery_snapshot_registry(
            &untrusted,
            NearbyDiscoveryFixture {
                scan_id: "scan-untrusted",
                source: "agent_owned_nearby_discovery_snapshot",
                observed_at: "2026-07-06T00:00:00Z",
                expires_at: "2099-01-01T00:00:00Z",
                updated_at: "2026-07-06T00:00:01Z",
                device_ref: "candidate-device-1",
                display_name: "Candidate Mac",
                trust_status: "candidate",
                connectable: true,
            },
        );
        assert_eq!(
            read_nearby_discovery_snapshot(&untrusted_string, false),
            Err(OperatorStateError::NearbyDiscoverySnapshotRegistryInvalid)
        );
    }

    #[test]
    fn rejects_corrupt_nearby_discovery_snapshot_registry() {
        let state_dir = make_state_dir("nearby-discovery-corrupt");
        let state_dir_string = state_dir.to_string_lossy().to_string();
        fs::write(
            state_dir
                .join(RUNTIME_DIR)
                .join(NEARBY_DISCOVERY_SNAPSHOTS_FILE),
            "{not-json secret-device-ref}",
        )
        .unwrap();

        assert_eq!(
            read_nearby_discovery_snapshot(&state_dir_string, false),
            Err(OperatorStateError::NearbyDiscoverySnapshotRegistryJson)
        );
    }

    #[test]
    fn registers_remote_desktop_request_and_rejects_duplicate_pending() {
        let state_dir = make_state_dir("register");
        write_session_registry(
            &state_dir,
            "session-1",
            "established",
            "product_control_secure_session",
            4_102_444_800_000,
        );
        let state_dir_string = state_dir.to_string_lossy().to_string();

        let registration = register_remote_desktop_request_for_established_session(
            &state_dir_string,
            "session-1",
            RemoteDesktopControlAction::Start,
            start_payload(),
        )
        .expect("request should register");

        assert_eq!(registration.request.session_id, "session-1");
        assert_eq!(registration.request.target_runtime_id, "runtime-1");
        assert_eq!(
            registration.request.status,
            RemoteDesktopControlRequestStatus::PendingAgentObservation
        );
        assert_eq!(registration.pending_requests_for_session, 1);

        let status =
            read_remote_desktop_status(&state_dir_string, Some("session-1")).expect("status");
        assert_eq!(status.sessions_total, 1);
        assert_eq!(status.pending_requests, 1);
        assert_eq!(
            status
                .latest_request
                .as_ref()
                .map(|request| &request.request_id),
            Some(&registration.request.request_id)
        );

        let duplicate = register_remote_desktop_request_for_established_session(
            &state_dir_string,
            "session-1",
            RemoteDesktopControlAction::SetFps,
            RemoteDesktopControlRequestPayload {
                resolution: None,
                fps: Some(60),
            },
        );
        assert_eq!(duplicate, Err(OperatorStateError::PendingRequestExists));
    }

    #[test]
    fn registers_file_transfer_request_and_rejects_duplicate_pending() {
        let state_dir = make_state_dir("file-transfer-register");
        write_session_registry(
            &state_dir,
            "session-1",
            "established",
            "product_control_secure_session",
            4_102_444_800_000,
        );
        let source = write_file_transfer_source(&state_dir, "payload");
        let source_string = source.to_string_lossy().to_string();
        let source_size = fs::metadata(&source).unwrap().len();
        let state_dir_string = state_dir.to_string_lossy().to_string();

        let registration = register_file_transfer_send_request_for_established_session(
            &state_dir_string,
            "session-1",
            "peer-device-1",
            &source_string,
        )
        .expect("file transfer request should register");

        assert_eq!(registration.request.session_id, "session-1");
        assert_eq!(registration.request.target_runtime_id, "runtime-1");
        assert_eq!(registration.request.action, FileTransferControlAction::Send);
        assert_eq!(
            registration.request.status,
            FileTransferControlRequestStatus::PendingAgentObservation
        );
        assert_eq!(registration.request.source.source_path, source_string);
        assert_eq!(registration.request.source.size_bytes, source_size);
        assert_eq!(registration.request.source.sha256_hex.len(), 64);
        assert_eq!(
            registration.request.destination.remote_device_id,
            "peer-device-1"
        );
        assert_eq!(registration.pending_requests_for_session, 1);

        let history =
            read_file_transfer_history(&state_dir_string, Some("session-1")).expect("history");
        assert_eq!(history.sessions_total, 1);
        assert_eq!(history.pending_requests, 1);
        assert_eq!(history.history.len(), 1);
        assert_eq!(
            history
                .latest_request
                .as_ref()
                .map(|request| &request.request_id),
            Some(&registration.request.request_id)
        );

        let duplicate = register_file_transfer_send_request_for_established_session(
            &state_dir_string,
            "session-1",
            "peer-device-1",
            &source_string,
        );
        assert_eq!(duplicate, Err(OperatorStateError::PendingRequestExists));
    }

    #[test]
    fn rejects_file_transfer_peer_mismatch_and_invalid_source() {
        let state_dir = make_state_dir("file-transfer-invalid");
        write_session_registry(
            &state_dir,
            "session-1",
            "established",
            "product_control_secure_session",
            4_102_444_800_000,
        );
        let source = write_file_transfer_source(&state_dir, "payload");
        let source_string = source.to_string_lossy().to_string();
        let state_dir_string = state_dir.to_string_lossy().to_string();

        assert_eq!(
            register_file_transfer_send_request_for_established_session(
                &state_dir_string,
                "session-1",
                "wrong-peer",
                &source_string,
            ),
            Err(OperatorStateError::PeerMismatch)
        );
        assert_eq!(
            register_file_transfer_send_request_for_established_session(
                &state_dir_string,
                "session-1",
                "peer-device-1",
                "",
            ),
            Err(OperatorStateError::FileTransferSourceMissing)
        );
        assert_eq!(
            register_file_transfer_send_request_for_established_session(
                &state_dir_string,
                "session-1",
                "peer-device-1",
                &state_dir_string,
            ),
            Err(OperatorStateError::FileTransferSourceNotRegularFile)
        );
    }

    #[test]
    fn rejects_missing_stale_and_non_established_sessions() {
        let missing_registry = make_state_dir("missing-registry");
        let missing_registry_string = missing_registry.to_string_lossy().to_string();
        assert_eq!(
            register_remote_desktop_request_for_established_session(
                &missing_registry_string,
                "session-1",
                RemoteDesktopControlAction::Start,
                start_payload(),
            ),
            Err(OperatorStateError::SessionRegistryMissing)
        );

        let stale = make_state_dir("stale");
        let stale_string = stale.to_string_lossy().to_string();
        write_session_registry(
            &stale,
            "session-1",
            "established",
            "product_control_secure_session",
            1,
        );
        assert_eq!(
            register_remote_desktop_request_for_established_session(
                &stale_string,
                "session-1",
                RemoteDesktopControlAction::Start,
                start_payload(),
            ),
            Err(OperatorStateError::SessionStale)
        );

        let connecting = make_state_dir("connecting");
        let connecting_string = connecting.to_string_lossy().to_string();
        write_session_registry(
            &connecting,
            "session-1",
            "connecting",
            "product_control_secure_session",
            4_102_444_800_000,
        );
        assert_eq!(
            register_remote_desktop_request_for_established_session(
                &connecting_string,
                "session-1",
                RemoteDesktopControlAction::Start,
                start_payload(),
            ),
            Err(OperatorStateError::SessionNotEstablished)
        );

        let wrong_readiness = make_state_dir("wrong-readiness");
        let wrong_readiness_string = wrong_readiness.to_string_lossy().to_string();
        write_session_registry(
            &wrong_readiness,
            "session-1",
            "established",
            "transport_only",
            4_102_444_800_000,
        );
        assert_eq!(
            register_remote_desktop_request_for_established_session(
                &wrong_readiness_string,
                "session-1",
                RemoteDesktopControlAction::Start,
                start_payload(),
            ),
            Err(OperatorStateError::SessionNotEstablished)
        );
    }

    #[test]
    fn validates_registry_schema_and_payload_contract() {
        let invalid_schema = make_state_dir("invalid-schema");
        let invalid_schema_string = invalid_schema.to_string_lossy().to_string();
        fs::write(
            invalid_schema.join(RUNTIME_DIR).join(SESSIONS_FILE),
            r#"{"schema_version":2,"sessions":{}}"#,
        )
        .unwrap();
        assert_eq!(
            register_remote_desktop_request_for_established_session(
                &invalid_schema_string,
                "session-1",
                RemoteDesktopControlAction::Start,
                start_payload(),
            ),
            Err(OperatorStateError::SessionRegistrySchema)
        );

        assert!(matches!(
            remote_desktop_resolution_request("auto"),
            Ok(RemoteDesktopResolutionRequest::Auto)
        ));
        assert!(remote_desktop_resolution_request("3840x2160").is_err());
        assert!(remote_desktop_fps_supported(120));
        assert!(!remote_desktop_fps_supported(144));

        assert_eq!(
            validate_remote_desktop_payload(
                RemoteDesktopControlAction::Stop,
                &RemoteDesktopControlRequestPayload {
                    resolution: None,
                    fps: Some(60),
                },
            ),
            Err(OperatorStateError::InvalidRequestPayload)
        );
        assert_eq!(
            validate_remote_desktop_payload(
                RemoteDesktopControlAction::SetResolution,
                &RemoteDesktopControlRequestPayload {
                    resolution: None,
                    fps: None,
                },
            ),
            Err(OperatorStateError::InvalidRequestPayload)
        );
        assert_eq!(
            validate_remote_desktop_payload(
                RemoteDesktopControlAction::SetFps,
                &RemoteDesktopControlRequestPayload {
                    resolution: Some(remote_desktop_resolution_request("auto").unwrap()),
                    fps: Some(60),
                },
            ),
            Err(OperatorStateError::InvalidRequestPayload)
        );
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_request_registries() {
        use std::os::unix::fs::symlink;

        let state_dir = make_state_dir("request-registry-symlink");
        let state_dir_string = state_dir.to_string_lossy().to_string();
        write_session_registry(
            &state_dir,
            "session-1",
            "established",
            "product_control_secure_session",
            4_102_444_800_000,
        );
        let runtime_dir = state_dir.join(RUNTIME_DIR);
        let secret_remote = state_dir.join("secret-remote.json");
        fs::write(&secret_remote, r#"{"schema_version":1,"requests":{}}"#).unwrap();
        symlink(
            &secret_remote,
            runtime_dir.join(REMOTE_DESKTOP_REQUESTS_FILE),
        )
        .unwrap();

        assert_eq!(
            register_remote_desktop_request_for_established_session(
                &state_dir_string,
                "session-1",
                RemoteDesktopControlAction::Start,
                start_payload(),
            ),
            Err(OperatorStateError::UnsafePath)
        );

        fs::remove_file(runtime_dir.join(REMOTE_DESKTOP_REQUESTS_FILE)).unwrap();
        let secret_file = state_dir.join("secret-file-transfer.json");
        fs::write(&secret_file, r#"{"schema_version":1,"requests":{}}"#).unwrap();
        symlink(&secret_file, runtime_dir.join(FILE_TRANSFER_REQUESTS_FILE)).unwrap();
        let source = write_file_transfer_source(&state_dir, "payload-after-symlink");
        let source_string = source.to_string_lossy().to_string();

        assert_eq!(
            register_file_transfer_send_request_for_established_session(
                &state_dir_string,
                "session-1",
                "peer-device-1",
                &source_string,
            ),
            Err(OperatorStateError::UnsafePath)
        );
    }

    #[test]
    fn rejects_oversized_request_registries() {
        let remote = make_state_dir("remote-request-too-large");
        let remote_string = remote.to_string_lossy().to_string();
        write_session_registry(
            &remote,
            "session-1",
            "established",
            "product_control_secure_session",
            4_102_444_800_000,
        );
        fs::write(
            remote.join(RUNTIME_DIR).join(REMOTE_DESKTOP_REQUESTS_FILE),
            vec![b' '; MAX_REMOTE_DESKTOP_REQUEST_REGISTRY_BYTES as usize + 1],
        )
        .unwrap();
        assert_eq!(
            register_remote_desktop_request_for_established_session(
                &remote_string,
                "session-1",
                RemoteDesktopControlAction::Start,
                start_payload(),
            ),
            Err(OperatorStateError::RequestRegistryInvalid)
        );

        let file = make_state_dir("file-request-too-large");
        let file_string = file.to_string_lossy().to_string();
        write_session_registry(
            &file,
            "session-1",
            "established",
            "product_control_secure_session",
            4_102_444_800_000,
        );
        fs::write(
            file.join(RUNTIME_DIR).join(FILE_TRANSFER_REQUESTS_FILE),
            vec![b' '; MAX_FILE_TRANSFER_REQUEST_REGISTRY_BYTES as usize + 1],
        )
        .unwrap();
        let source = write_file_transfer_source(&file, "payload-too-large");
        let source_string = source.to_string_lossy().to_string();
        assert_eq!(
            register_file_transfer_send_request_for_established_session(
                &file_string,
                "session-1",
                "peer-device-1",
                &source_string,
            ),
            Err(OperatorStateError::FileTransferRequestRegistryInvalid)
        );
    }
}
