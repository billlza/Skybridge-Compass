//! Agent-owned live file transfer over the encrypted control channel.
//!
//! Sender and receiver use the Apple-compatible flat JSON v1 contract. A
//! sender cannot emit chunks before `metadataAck`, and cannot report success
//! before an exact `completeAck`. A receiver holds metadata in a bounded
//! pending-approval queue, writes approved chunks to private staging storage,
//! and emits `completeAck` only after hash verification, durable no-replace
//! placement, and durable terminal-receipt persistence.
//!
//! No "success" is ever recorded without receipt evidence.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
#[cfg(test)]
use skybridge_core::file_transfer_frame::{self, FileAppFrame};
use skybridge_core::{
    CrossNetworkFileChunkAckV1, CrossNetworkFileChunkV1, CrossNetworkFileCompletionV1,
    CrossNetworkFileMetadataV1, CrossNetworkFileTransferMessageV1, CrossNetworkTransferId,
    FileTransferControlRequest, MAX_CROSS_NETWORK_FILE_BYTES, MAX_CROSS_NETWORK_FILE_CHUNKS,
    MAX_CROSS_NETWORK_FILENAME_BYTES, NativeWebRtcSender,
    encode_cross_network_file_transfer_message_v1,
};
use tokio::fs::File;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

use super::{AgentPaths, RuntimeIncarnationAuthority};
use crate::state::{
    InboundFileTransferApprovalRegistration, authenticated_file_transfer_peer_for_runtime,
    complete_file_transfer_request_for_runtime, fail_file_transfer_request_for_runtime,
    record_file_transfer_progress_for_runtime, register_inbound_file_transfer_approval_for_runtime,
    start_file_transfer_request_for_runtime,
};

/// Apple uses 16 KiB as the minimum DataChannel chunk. At the protocol's 1 GiB
/// file limit this yields exactly the bounded maximum of 65,536 chunks.
const CHUNK_PAYLOAD_BYTES: usize = 16 * 1024;
const MAX_FILENAME_LEN: usize = MAX_CROSS_NETWORK_FILENAME_BYTES;
const MAX_TRANSFER_BYTES: u64 = MAX_CROSS_NETWORK_FILE_BYTES;
#[cfg(test)]
const WINDOW_CHUNKS: u64 = 32;
#[cfg(test)]
const ACK_EVERY_CHUNKS: u32 = 8;
/// Bound on simultaneous outbound transfers owned by one managed session.
pub(super) const MAX_CONCURRENT_SENDS_PER_SESSION: usize = 4;
/// Agent-global bound on simultaneous outbound transfers.
const MAX_GLOBAL_CONCURRENT_SENDS: usize = 4;
/// Agent-global bound on private source snapshots (including zero-byte files).
const MAX_OUTBOUND_SNAPSHOT_FILES: usize = 4;
/// Agent-global bound on bytes reserved for private source snapshots (4 GiB).
const MAX_OUTBOUND_SNAPSHOT_BYTES: u64 = 4 * 1024 * 1024 * 1024;
/// Bound on simultaneous inbound transfers.
const MAX_CONCURRENT_RECEIVES: usize = 4;
/// Pending approvals share the same per-session admission bound as active
/// receivers so an authenticated peer cannot create an unbounded prompt queue.
const MAX_PENDING_RECEIVE_APPROVALS: usize = MAX_CONCURRENT_RECEIVES;
/// Bound on the summed declared size of in-flight inbound transfers (4 GiB).
const MAX_TOTAL_INFLIGHT_BYTES: u64 = 4 * 1024 * 1024 * 1024;
/// Bound on existing received files plus all accepted in-flight declarations.
const MAX_RECEIVED_STORAGE_BYTES: u64 = 4 * 1024 * 1024 * 1024;
/// Bound on stored files, including accepted in-flight transfers that will
/// each materialize one destination entry (protects zero-byte/inode usage).
const MAX_RECEIVED_FILES: usize = 1_024;
/// Bound on auto-suffix attempts when resolving a collision-free name.
const MAX_NAME_COLLISION_ATTEMPTS: u32 = 10_000;
/// Maximum time a sender waits for an ACK or receipt before failing the
/// transfer. Each valid progress event resets this bounded wait.
const INBOUND_PROGRESS_TIMEOUT: Duration = Duration::from_secs(30);
/// Inbound transfers that make no valid write progress are aborted.
const RECEIVER_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const SOURCE_SNAPSHOT_DIR_NAME: &str = "file-transfer-snapshots";
const RECEIPT_DIR_NAME: &str = ".file-transfer-receipts";
const MAX_TERMINAL_RECEIPTS: usize = 1_024;

/// Stable 16-byte transfer id derived from the request id.
pub(super) fn transfer_id_for(request_id: &str) -> [u8; 16] {
    let digest = Sha256::digest(request_id.as_bytes());
    let mut id = [0u8; 16];
    id.copy_from_slice(&digest[..16]);
    id
}

fn wire_transfer_id_for(request_id: &str) -> Result<CrossNetworkTransferId> {
    let wire_value = uuid::Uuid::from_bytes(transfer_id_for(request_id))
        .hyphenated()
        .to_string();
    CrossNetworkTransferId::parse(wire_value).map_err(Into::into)
}

fn transfer_key(transfer_id: &CrossNetworkTransferId) -> [u8; 16] {
    *transfer_id.uuid().as_bytes()
}

fn hex16(id: &[u8; 16]) -> String {
    let mut out = String::with_capacity(32);
    for byte in id {
        use std::fmt::Write as _;
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn hex32(id: &[u8; 32]) -> String {
    let mut out = String::with_capacity(64);
    for byte in id {
        use std::fmt::Write as _;
        let _ = write!(out, "{byte:02x}");
    }
    out
}

fn parse_sha256_hex(hex: &str) -> Result<[u8; 32]> {
    if hex.len() != 64 {
        bail!("source sha256 must be 64 hex chars");
    }
    let mut out = [0u8; 32];
    let bytes = hex.as_bytes();
    for (index, slot) in out.iter_mut().enumerate() {
        let hi = (bytes[index * 2] as char)
            .to_digit(16)
            .ok_or_else(|| anyhow!("invalid sha256 hex"))?;
        let lo = (bytes[index * 2 + 1] as char)
            .to_digit(16)
            .ok_or_else(|| anyhow!("invalid sha256 hex"))?;
        *slot = (hi * 16 + lo) as u8;
    }
    Ok(out)
}

fn source_snapshot_dir(paths: &AgentPaths) -> PathBuf {
    paths.runtime_dir.join(SOURCE_SNAPSHOT_DIR_NAME)
}

async fn ensure_private_directory(path: &Path) -> Result<()> {
    match tokio::fs::symlink_metadata(path).await {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            tokio::fs::create_dir_all(path)
                .await
                .context("failed to create private file-transfer directory")?;
        }
        Err(error) => {
            return Err(error).context("failed to inspect private file-transfer directory");
        }
    }
    let metadata = tokio::fs::symlink_metadata(path)
        .await
        .context("failed to verify private file-transfer directory")?;
    if metadata.file_type().is_symlink() {
        bail!("private file-transfer directory must not be a symlink");
    }
    if !metadata.is_dir() {
        bail!("private file-transfer path exists but is not a directory");
    }
    super::restrict_dir_permissions(path).await
}

/// Removes source snapshots left by an unclean process exit. The single-agent
/// runtime lock guarantees no live sender can own this directory at startup.
pub(super) async fn cleanup_stale_source_snapshots(paths: &AgentPaths) -> Result<()> {
    let snapshot_dir = source_snapshot_dir(paths);
    ensure_private_directory(&snapshot_dir).await?;
    let mut entries = tokio::fs::read_dir(&snapshot_dir)
        .await
        .context("failed to enumerate stale file-transfer snapshots")?;
    while let Some(entry) = entries
        .next_entry()
        .await
        .context("failed to read stale file-transfer snapshot entry")?
    {
        let metadata = tokio::fs::symlink_metadata(entry.path())
            .await
            .context("failed to inspect stale file-transfer snapshot")?;
        if metadata.is_dir() {
            bail!("unexpected directory inside private file-transfer snapshot storage");
        }
        tokio::fs::remove_file(entry.path())
            .await
            .context("failed to remove stale file-transfer snapshot")?;
    }
    Ok(())
}

/// Agent-global owner of outbound transfer and private snapshot capacity.
///
/// Admission is one atomic critical section across transfer count, snapshot
/// count, and snapshot bytes. A reservation is retained until the snapshot has
/// been removed, then explicitly released. Its `Drop` path is only a final
/// cancellation/panic safety net and never reports success.
pub(super) struct OutboundTransferResources {
    state: std::sync::Mutex<OutboundResourceState>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct OutboundResourceState {
    active_transfers: usize,
    snapshot_files: usize,
    snapshot_bytes: u64,
}

struct OutboundTransferReservation {
    owner: Arc<OutboundTransferResources>,
    snapshot_bytes: u64,
    released: bool,
}

impl OutboundTransferResources {
    pub(super) async fn initialize(paths: &AgentPaths) -> Result<Self> {
        cleanup_stale_source_snapshots(paths).await?;
        let snapshot_dir = source_snapshot_dir(paths);
        let mut entries = tokio::fs::read_dir(&snapshot_dir)
            .await
            .context("failed to verify cleaned file-transfer snapshot storage")?;
        if entries
            .next_entry()
            .await
            .context("failed to inspect cleaned file-transfer snapshot storage")?
            .is_some()
        {
            bail!("file-transfer snapshot storage was not empty after startup cleanup");
        }
        Ok(Self {
            state: std::sync::Mutex::new(OutboundResourceState::default()),
        })
    }

    fn reserve(self: &Arc<Self>, snapshot_bytes: u64) -> Result<OutboundTransferReservation> {
        if snapshot_bytes > MAX_TRANSFER_BYTES {
            bail!("queued file-transfer source exceeds the protocol size limit");
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow!("outbound resource reservation lock poisoned"))?;
        let next_active = state
            .active_transfers
            .checked_add(1)
            .ok_or_else(|| anyhow!("outbound active-transfer count overflow"))?;
        let next_files = state
            .snapshot_files
            .checked_add(1)
            .ok_or_else(|| anyhow!("outbound snapshot-file count overflow"))?;
        let next_bytes = state
            .snapshot_bytes
            .checked_add(snapshot_bytes)
            .ok_or_else(|| anyhow!("outbound snapshot-byte count overflow"))?;
        if next_active > MAX_GLOBAL_CONCURRENT_SENDS
            || next_files > MAX_OUTBOUND_SNAPSHOT_FILES
            || next_bytes > MAX_OUTBOUND_SNAPSHOT_BYTES
        {
            bail!("agent outbound resource limit reached");
        }
        state.active_transfers = next_active;
        state.snapshot_files = next_files;
        state.snapshot_bytes = next_bytes;
        drop(state);
        Ok(OutboundTransferReservation {
            owner: Arc::clone(self),
            snapshot_bytes,
            released: false,
        })
    }

    fn release(&self, snapshot_bytes: u64) -> Result<()> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow!("outbound resource reservation lock poisoned"))?;
        let next_active = state
            .active_transfers
            .checked_sub(1)
            .ok_or_else(|| anyhow!("outbound active-transfer accounting invariant violated"))?;
        let next_files = state
            .snapshot_files
            .checked_sub(1)
            .ok_or_else(|| anyhow!("outbound snapshot-file accounting invariant violated"))?;
        let next_bytes = state
            .snapshot_bytes
            .checked_sub(snapshot_bytes)
            .ok_or_else(|| anyhow!("outbound snapshot-byte accounting invariant violated"))?;
        state.active_transfers = next_active;
        state.snapshot_files = next_files;
        state.snapshot_bytes = next_bytes;
        Ok(())
    }

    #[cfg(test)]
    fn usage(&self) -> Result<OutboundResourceState> {
        self.state
            .lock()
            .map(|state| *state)
            .map_err(|_| anyhow!("outbound resource reservation lock poisoned"))
    }
}

impl OutboundTransferReservation {
    fn release(mut self) -> Result<()> {
        self.owner.release(self.snapshot_bytes)?;
        self.released = true;
        Ok(())
    }
}

impl Drop for OutboundTransferReservation {
    fn drop(&mut self) {
        if self.released {
            return;
        }
        match self.owner.release(self.snapshot_bytes) {
            Ok(()) => self.released = true,
            Err(error) => warn!(
                kind = "agent.file_transfer.outbound_reservation_drop_failed",
                error = %error,
                "failed to release outbound reservation during cancellation cleanup"
            ),
        }
    }
}

struct PreparedSourceSnapshot {
    path: PathBuf,
    file: Option<File>,
}

impl PreparedSourceSnapshot {
    fn file_mut(&mut self) -> Result<&mut File> {
        self.file
            .as_mut()
            .ok_or_else(|| anyhow!("prepared source snapshot is already closed"))
    }

    async fn cleanup(mut self) -> Result<()> {
        self.file.take();
        match tokio::fs::remove_file(&self.path).await {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error).context("failed to remove private file-transfer snapshot"),
        }
    }
}

impl Drop for PreparedSourceSnapshot {
    fn drop(&mut self) {
        self.file.take();
        match std::fs::remove_file(&self.path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                warn!(
                    kind = "agent.file_transfer.snapshot_drop_cleanup_failed",
                    error = %error,
                    "failed to remove private source snapshot during drop"
                );
            }
        }
    }
}

async fn prepare_source_snapshot(
    paths: &AgentPaths,
    request: &FileTransferControlRequest,
    expected_sha256: &[u8; 32],
    cancel: &CancellationToken,
    authority: &RuntimeIncarnationAuthority,
) -> Result<PreparedSourceSnapshot> {
    if request.source.size_bytes > MAX_TRANSFER_BYTES {
        bail!("queued file-transfer source exceeds the protocol size limit");
    }
    let snapshot_dir = source_snapshot_dir(paths);
    authority
        .run_external_effect(
            "outbound snapshot directory preparation",
            ensure_private_directory(&snapshot_dir),
        )
        .await?;
    let snapshot_path = snapshot_dir.join(format!(
        "{}-{}.snapshot",
        hex16(&transfer_id_for(&request.request_id)),
        uuid::Uuid::now_v7()
    ));
    let mut options = tokio::fs::OpenOptions::new();
    options.read(true).write(true).create_new(true);
    #[cfg(unix)]
    {
        options.mode(0o600);
    }
    let snapshot_file = authority
        .run_external_effect("outbound snapshot creation", async {
            options
                .open(&snapshot_path)
                .await
                .context("failed to create private file-transfer snapshot")
        })
        .await?;
    let mut snapshot = PreparedSourceSnapshot {
        path: snapshot_path,
        file: Some(snapshot_file),
    };
    authority
        .run_external_effect(
            "outbound snapshot permission restriction",
            super::restrict_file_permissions(&snapshot.path),
        )
        .await?;

    let mut source = File::open(&request.source.source_path)
        .await
        .context("failed to open queued file-transfer source")?;
    let metadata = source
        .metadata()
        .await
        .context("failed to inspect queued file-transfer source")?;
    if !metadata.is_file() {
        bail!("queued file-transfer source is no longer a regular file");
    }

    let mut copied_bytes = 0u64;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let read = tokio::select! {
            _ = cancel.cancelled() => bail!("transfer cancelled while preparing source snapshot"),
            result = source.read(&mut buffer) => {
                result.context("failed to read queued file-transfer source")?
            }
        };
        if read == 0 {
            break;
        }
        copied_bytes = copied_bytes
            .checked_add(read as u64)
            .ok_or_else(|| anyhow!("file-transfer source size overflow"))?;
        if copied_bytes > request.source.size_bytes {
            bail!("queued file-transfer source grew while preparing its private snapshot");
        }
        hasher.update(&buffer[..read]);
        authority
            .run_external_effect(
                "outbound snapshot write",
                async {
                    tokio::select! {
                        _ = cancel.cancelled() => bail!("transfer cancelled while preparing source snapshot"),
                        result = snapshot.file_mut()?.write_all(&buffer[..read]) => {
                            result.context("failed to write private file-transfer snapshot")
                        }
                    }
                },
            )
            .await?;
    }

    let observed_sha256: [u8; 32] = hasher.finalize().into();
    if copied_bytes != request.source.size_bytes || &observed_sha256 != expected_sha256 {
        bail!("queued file-transfer source no longer matches its size and SHA-256 snapshot");
    }
    authority
        .run_external_effect("outbound snapshot flush", async {
            snapshot
                .file_mut()?
                .flush()
                .await
                .context("failed to flush private file-transfer snapshot")
        })
        .await?;
    authority
        .run_external_effect("outbound snapshot sync", async {
            snapshot
                .file_mut()?
                .sync_all()
                .await
                .context("failed to sync private file-transfer snapshot")
        })
        .await?;
    snapshot
        .file_mut()?
        .seek(std::io::SeekFrom::Start(0))
        .await
        .context("failed to rewind private file-transfer snapshot")?;
    Ok(snapshot)
}

/// Agent-global owner of received-file storage.
///
/// Managed sessions retain their own protocol state, while this object owns the
/// one-time staging cleanup, stored-usage snapshot, quota reservations, and
/// collision-safe placement shared by every session in the agent process.
pub(super) struct InboundFileStore {
    received_dir: PathBuf,
    staging_dir: PathBuf,
    receipt_dir: PathBuf,
    state: Mutex<InboundStorageState>,
    placement_lock: Mutex<()>,
    #[cfg(test)]
    fail_next_directory_sync: std::sync::atomic::AtomicBool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ReceivedStorageUsage {
    bytes: u64,
    files: usize,
}

#[derive(Debug)]
struct InboundStorageState {
    stored: ReceivedStorageUsage,
    reserved_bytes: u64,
    reserved_files: usize,
    terminal_receipts: usize,
    reserved_terminal_receipts: usize,
}

#[derive(Debug)]
struct InboundStorageReservation {
    total_size: u64,
    temp_path: PathBuf,
}

#[derive(Debug)]
struct ReceivedPlacementFailure {
    error: anyhow::Error,
    destination_may_exist: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DurableTerminalReceipt {
    schema_version: u32,
    session_namespace: String,
    transfer_id: String,
    metadata_sha256_hex: String,
    received_bytes: u64,
    file_sha256_hex: String,
}

impl DurableTerminalReceipt {
    const SCHEMA_VERSION: u32 = 1;

    fn new(
        session_id: &str,
        metadata: &CrossNetworkFileMetadataV1,
        completion: &CrossNetworkFileCompletionV1,
    ) -> Result<Self> {
        Ok(Self {
            schema_version: Self::SCHEMA_VERSION,
            session_namespace: session_storage_namespace(session_id),
            transfer_id: metadata.transfer_id.uuid().hyphenated().to_string(),
            metadata_sha256_hex: hex32(&metadata_binding_sha256(metadata)?),
            received_bytes: completion.received_bytes,
            file_sha256_hex: hex32(&completion.file_sha256),
        })
    }

    fn validate_for(&self, session_id: &str, transfer_id: &CrossNetworkTransferId) -> Result<()> {
        if self.schema_version != Self::SCHEMA_VERSION
            || self.session_namespace != session_storage_namespace(session_id)
            || self.transfer_id != transfer_id.uuid().hyphenated().to_string()
            || self.received_bytes > MAX_TRANSFER_BYTES
            || parse_sha256_hex(&self.metadata_sha256_hex).is_err()
            || parse_sha256_hex(&self.file_sha256_hex).is_err()
        {
            bail!("invalid durable file-transfer terminal receipt");
        }
        Ok(())
    }

    fn validate_structure(&self) -> Result<()> {
        if self.schema_version != Self::SCHEMA_VERSION
            || self.session_namespace.len() != 32
            || !self
                .session_namespace
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
            || CrossNetworkTransferId::parse(self.transfer_id.clone()).is_err()
            || self.received_bytes > MAX_TRANSFER_BYTES
            || !is_lowercase_sha256_hex(&self.metadata_sha256_hex)
            || !is_lowercase_sha256_hex(&self.file_sha256_hex)
        {
            bail!("invalid durable file-transfer terminal receipt");
        }
        Ok(())
    }

    fn completion(
        &self,
        transfer_id: CrossNetworkTransferId,
    ) -> Result<CrossNetworkFileCompletionV1> {
        Ok(CrossNetworkFileCompletionV1 {
            transfer_id,
            received_bytes: self.received_bytes,
            file_sha256: parse_sha256_hex(&self.file_sha256_hex)?,
        })
    }
}

fn is_lowercase_sha256_hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

impl InboundFileStore {
    pub(super) async fn initialize(received_dir: PathBuf) -> Result<Self> {
        let staging_dir = received_dir.join(".file-transfer-staging");
        let receipt_dir = received_dir.join(RECEIPT_DIR_NAME);
        ensure_private_directory(&received_dir).await?;
        ensure_private_directory(&staging_dir).await?;
        ensure_private_directory(&receipt_dir).await?;
        cleanup_stale_inbound_staging(&staging_dir).await?;
        let stored = scan_received_storage_usage(&received_dir, &staging_dir, &receipt_dir).await?;
        let terminal_receipts = validate_terminal_receipt_storage(&receipt_dir).await?;
        Ok(Self {
            received_dir,
            staging_dir,
            receipt_dir,
            state: Mutex::new(InboundStorageState {
                stored,
                reserved_bytes: 0,
                reserved_files: 0,
                terminal_receipts,
                reserved_terminal_receipts: 0,
            }),
            placement_lock: Mutex::new(()),
            #[cfg(test)]
            fail_next_directory_sync: std::sync::atomic::AtomicBool::new(false),
        })
    }

    async fn reserve(
        &self,
        session_id: &str,
        transfer_id: &[u8; 16],
        total_size: u64,
    ) -> Result<Option<(InboundStorageReservation, File)>> {
        {
            let mut state = self.state.lock().await;
            if state.reserved_files >= MAX_CONCURRENT_RECEIVES
                || state
                    .terminal_receipts
                    .checked_add(state.reserved_terminal_receipts)
                    .is_none_or(|count| count >= MAX_TERMINAL_RECEIPTS)
                || !receive_capacity_allows(
                    state.stored,
                    state.reserved_bytes,
                    state.reserved_files,
                    total_size,
                )
            {
                return Ok(None);
            }
            let reserved_bytes = state
                .reserved_bytes
                .checked_add(total_size)
                .ok_or_else(|| anyhow!("inbound storage reservation size overflow"))?;
            let reserved_files = state
                .reserved_files
                .checked_add(1)
                .ok_or_else(|| anyhow!("inbound storage reservation count overflow"))?;
            let reserved_terminal_receipts = state
                .reserved_terminal_receipts
                .checked_add(1)
                .ok_or_else(|| anyhow!("terminal receipt reservation count overflow"))?;
            state.reserved_bytes = reserved_bytes;
            state.reserved_files = reserved_files;
            state.reserved_terminal_receipts = reserved_terminal_receipts;
        }

        let session_namespace = session_storage_namespace(session_id);
        let temp_path = self.staging_dir.join(format!(
            "{session_namespace}-{}-{}.part",
            hex16(transfer_id),
            uuid::Uuid::now_v7()
        ));
        let mut options = tokio::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            options.mode(0o600);
        }
        let file = match options.open(&temp_path).await {
            Ok(file) => file,
            Err(error) => {
                if let Err(release_error) = self.release_capacity(total_size).await {
                    return Err(anyhow!(
                        "failed to create exclusive inbound staging file: {error}; quota reservation release also failed: {release_error:#}"
                    ));
                }
                return Err(error).context("failed to create exclusive inbound staging file");
            }
        };
        if let Err(permission_error) = super::restrict_file_permissions(&temp_path).await {
            drop(file);
            match remove_file_if_present(&temp_path).await {
                Ok(()) => {
                    if let Err(release_error) = self.release_capacity(total_size).await {
                        return Err(permission_error.context(format!(
                            "failed to restrict inbound staging file permissions and quota reservation release also failed: {release_error:#}"
                        )));
                    }
                }
                Err(cleanup_error) => {
                    return Err(permission_error.context(format!(
                        "failed to restrict inbound staging file permissions and cleanup also failed: {cleanup_error:#}; quota reservation retained fail-closed"
                    )));
                }
            }
            return Err(permission_error)
                .context("failed to restrict inbound staging file permissions");
        }

        Ok(Some((
            InboundStorageReservation {
                total_size,
                temp_path,
            },
            file,
        )))
    }

    async fn place(
        &self,
        reservation: &InboundStorageReservation,
        final_name: &str,
    ) -> std::result::Result<PathBuf, ReceivedPlacementFailure> {
        let _placement_guard = self.placement_lock.lock().await;
        #[cfg(test)]
        let inject_directory_sync_failure = self
            .fail_next_directory_sync
            .swap(false, std::sync::atomic::Ordering::SeqCst);
        #[cfg(not(test))]
        let inject_directory_sync_failure = false;
        place_received_file(
            &self.received_dir,
            &reservation.temp_path,
            final_name,
            inject_directory_sync_failure,
        )
        .await
    }

    async fn commit(&self, reservation: InboundStorageReservation) -> Result<()> {
        let mut state = self.state.lock().await;
        let reserved_bytes = state
            .reserved_bytes
            .checked_sub(reservation.total_size)
            .ok_or_else(|| {
                anyhow!("inbound storage reserved-byte accounting invariant violated")
            })?;
        let reserved_files = state.reserved_files.checked_sub(1).ok_or_else(|| {
            anyhow!("inbound storage reserved-file accounting invariant violated")
        })?;
        let stored_bytes = state
            .stored
            .bytes
            .checked_add(reservation.total_size)
            .ok_or_else(|| anyhow!("inbound storage stored-byte accounting invariant violated"))?;
        let stored_files =
            state.stored.files.checked_add(1).ok_or_else(|| {
                anyhow!("inbound storage stored-file accounting invariant violated")
            })?;
        if state.reserved_terminal_receipts == 0 {
            bail!("inbound storage commit has no reserved terminal receipt capacity");
        }
        let reserved_terminal_receipts = state
            .reserved_terminal_receipts
            .checked_sub(1)
            .ok_or_else(|| anyhow!("terminal receipt reservation invariant violated"))?;
        let terminal_receipts = state
            .terminal_receipts
            .checked_add(1)
            .ok_or_else(|| anyhow!("terminal receipt count overflow"))?;
        state.reserved_bytes = reserved_bytes;
        state.reserved_files = reserved_files;
        state.reserved_terminal_receipts = reserved_terminal_receipts;
        state.terminal_receipts = terminal_receipts;
        state.stored.bytes = stored_bytes;
        state.stored.files = stored_files;
        Ok(())
    }

    async fn discard(&self, reservation: InboundStorageReservation) -> Result<()> {
        match remove_file_if_present(&reservation.temp_path).await {
            Ok(()) => self
                .release_capacity(reservation.total_size)
                .await
                .context("failed to release discarded inbound storage reservation"),
            Err(error) => Err(error.context(
                "failed to discard inbound staging file; quota reservation retained fail-closed",
            )),
        }
    }

    async fn load_terminal_receipt(
        &self,
        session_id: &str,
        transfer_id: &CrossNetworkTransferId,
    ) -> Result<Option<DurableTerminalReceipt>> {
        let path = terminal_receipt_path(&self.receipt_dir, session_id, transfer_id);
        let Some(receipt) = read_terminal_receipt_file(&path).await? else {
            return Ok(None);
        };
        receipt.validate_for(session_id, transfer_id)?;
        ensure_terminal_receipt_durable(&path, &self.receipt_dir).await?;
        Ok(Some(receipt))
    }

    async fn store_terminal_receipt(&self, receipt: &DurableTerminalReceipt) -> Result<()> {
        receipt.validate_structure()?;
        let transfer_id = CrossNetworkTransferId::parse(receipt.transfer_id.clone())?;
        let path = self.receipt_dir.join(format!(
            "{}-{}.json",
            receipt.session_namespace,
            transfer_id.uuid().hyphenated()
        ));
        let body = serde_json::to_vec(receipt)
            .context("failed to serialize durable file-transfer terminal receipt")?;
        if body.len() > 4 * 1024 {
            bail!("durable file-transfer terminal receipt exceeded size limit");
        }

        let state = self.state.lock().await;
        if state.reserved_terminal_receipts == 0 {
            bail!("terminal receipt persistence has no reserved capacity");
        }
        if let Some(existing) = read_terminal_receipt_file(&path).await? {
            if existing != *receipt {
                bail!("conflicting durable file-transfer terminal receipt");
            }
            ensure_terminal_receipt_durable(&path, &self.receipt_dir).await?;
            return Ok(());
        }
        let mut options = tokio::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        let mut file = match options.open(&path).await {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                let existing = read_terminal_receipt_file(&path)
                    .await?
                    .ok_or_else(|| anyhow!("terminal receipt disappeared after create conflict"))?;
                if existing != *receipt {
                    bail!("conflicting durable file-transfer terminal receipt");
                }
                ensure_terminal_receipt_durable(&path, &self.receipt_dir).await?;
                return Ok(());
            }
            Err(error) => {
                return Err(error)
                    .context("failed to create durable file-transfer terminal receipt");
            }
        };
        if let Err(error) = super::restrict_file_permissions(&path).await {
            drop(file);
            let cleanup = remove_file_if_present(&path).await;
            return match cleanup {
                Ok(()) => Err(error).context("failed to restrict terminal receipt permissions"),
                Err(cleanup_error) => Err(error).context(format!(
                    "failed to restrict terminal receipt permissions and cleanup failed: {cleanup_error:#}"
                )),
            };
        }
        if let Err(error) = async {
            file.write_all(&body).await?;
            file.sync_all().await
        }
        .await
        {
            drop(file);
            let cleanup = remove_file_if_present(&path).await;
            return match cleanup {
                Ok(()) => Err(error).context("failed to persist terminal receipt bytes"),
                Err(cleanup_error) => Err(error).context(format!(
                    "failed to persist terminal receipt and cleanup failed: {cleanup_error:#}"
                )),
            };
        }
        drop(file);
        sync_received_directory_metadata(&self.receipt_dir)
            .await
            .context("failed to durably publish terminal receipt directory entry")
    }

    async fn release_capacity(&self, total_size: u64) -> Result<()> {
        let mut state = self.state.lock().await;
        let reserved_bytes = state
            .reserved_bytes
            .checked_sub(total_size)
            .ok_or_else(|| {
                anyhow!("inbound storage reserved-byte accounting invariant violated")
            })?;
        let reserved_files = state.reserved_files.checked_sub(1).ok_or_else(|| {
            anyhow!("inbound storage reserved-file accounting invariant violated")
        })?;
        let reserved_terminal_receipts = state
            .reserved_terminal_receipts
            .checked_sub(1)
            .ok_or_else(|| anyhow!("terminal receipt reservation invariant violated"))?;
        state.reserved_bytes = reserved_bytes;
        state.reserved_files = reserved_files;
        state.reserved_terminal_receipts = reserved_terminal_receipts;
        Ok(())
    }

    #[cfg(test)]
    async fn usage(&self) -> InboundStorageState {
        let state = self.state.lock().await;
        InboundStorageState {
            stored: state.stored,
            reserved_bytes: state.reserved_bytes,
            reserved_files: state.reserved_files,
            terminal_receipts: state.terminal_receipts,
            reserved_terminal_receipts: state.reserved_terminal_receipts,
        }
    }

    #[cfg(test)]
    fn inject_directory_sync_failure_once(&self) {
        self.fail_next_directory_sync
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

async fn cleanup_stale_inbound_staging(staging_dir: &Path) -> Result<()> {
    let mut entries = tokio::fs::read_dir(staging_dir)
        .await
        .context("failed to enumerate inbound file-transfer staging")?;
    while let Some(entry) = entries
        .next_entry()
        .await
        .context("failed to read inbound file-transfer staging entry")?
    {
        let metadata = tokio::fs::symlink_metadata(entry.path())
            .await
            .context("failed to inspect inbound file-transfer staging entry")?;
        if metadata.is_dir() {
            bail!("unexpected directory inside inbound file-transfer staging");
        }
        tokio::fs::remove_file(entry.path())
            .await
            .context("failed to remove stale inbound file-transfer staging entry")?;
    }
    Ok(())
}

fn metadata_binding_sha256(metadata: &CrossNetworkFileMetadataV1) -> Result<[u8; 32]> {
    let mut canonical = metadata.clone();
    // The authenticated peer name is a display snapshot, not transport
    // authority. A later device rename must not change replay identity or turn
    // an otherwise identical transfer into a metadata conflict.
    canonical.sender_device_name = None;
    let encoded = encode_cross_network_file_transfer_message_v1(
        &CrossNetworkFileTransferMessageV1::Metadata(canonical),
    )?;
    Ok(Sha256::digest(encoded).into())
}

fn metadata_contract_equal(
    left: &CrossNetworkFileMetadataV1,
    right: &CrossNetworkFileMetadataV1,
) -> bool {
    let mut left = left.clone();
    let mut right = right.clone();
    left.sender_device_name = None;
    right.sender_device_name = None;
    left == right
}

fn terminal_receipt_path(
    receipt_dir: &Path,
    session_id: &str,
    transfer_id: &CrossNetworkTransferId,
) -> PathBuf {
    receipt_dir.join(format!(
        "{}-{}.json",
        session_storage_namespace(session_id),
        transfer_id.uuid().hyphenated()
    ))
}

async fn read_terminal_receipt_file(path: &Path) -> Result<Option<DurableTerminalReceipt>> {
    let metadata = match tokio::fs::symlink_metadata(path).await {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).context("failed to inspect terminal receipt"),
    };
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 4 * 1024 {
        bail!("terminal receipt storage contains an invalid entry");
    }
    let body = tokio::fs::read(path)
        .await
        .context("failed to read terminal receipt")?;
    let receipt: DurableTerminalReceipt =
        serde_json::from_slice(&body).context("failed to decode terminal receipt")?;
    receipt.validate_structure()?;
    Ok(Some(receipt))
}

async fn ensure_terminal_receipt_durable(path: &Path, receipt_dir: &Path) -> Result<()> {
    let file = tokio::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .await
        .context("failed to reopen terminal receipt for durability verification")?;
    file.sync_all()
        .await
        .context("failed to sync terminal receipt")?;
    sync_received_directory_metadata(receipt_dir)
        .await
        .context("failed to sync terminal receipt directory")
}

async fn validate_terminal_receipt_storage(receipt_dir: &Path) -> Result<usize> {
    let mut entries = tokio::fs::read_dir(receipt_dir)
        .await
        .context("failed to enumerate terminal receipt storage")?;
    let mut count = 0usize;
    while let Some(entry) = entries
        .next_entry()
        .await
        .context("failed to read terminal receipt storage entry")?
    {
        count = count
            .checked_add(1)
            .ok_or_else(|| anyhow!("terminal receipt count overflow"))?;
        if count > MAX_TERMINAL_RECEIPTS {
            bail!("terminal receipt storage exceeds bounded capacity");
        }
        let receipt = read_terminal_receipt_file(&entry.path())
            .await?
            .ok_or_else(|| anyhow!("terminal receipt disappeared during startup validation"))?;
        let transfer_id = CrossNetworkTransferId::parse(receipt.transfer_id.clone())?;
        let expected_name = format!(
            "{}-{}.json",
            receipt.session_namespace,
            transfer_id.uuid().hyphenated()
        );
        if entry.file_name() != std::ffi::OsStr::new(&expected_name) {
            bail!("terminal receipt filename does not match its bound identity");
        }
        ensure_terminal_receipt_durable(&entry.path(), receipt_dir).await?;
    }
    Ok(count)
}

async fn scan_received_storage_usage(
    received_dir: &Path,
    staging_dir: &Path,
    receipt_dir: &Path,
) -> Result<ReceivedStorageUsage> {
    let mut usage = ReceivedStorageUsage { bytes: 0, files: 0 };
    let mut entries = tokio::fs::read_dir(received_dir)
        .await
        .context("failed to enumerate received-file storage")?;
    while let Some(entry) = entries
        .next_entry()
        .await
        .context("failed to read received-file storage entry")?
    {
        let path = entry.path();
        if path == staging_dir || path == receipt_dir {
            continue;
        }
        let metadata = tokio::fs::symlink_metadata(&path)
            .await
            .context("failed to inspect received-file storage entry")?;
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            bail!("received-file storage contains an unexpected non-regular entry");
        }
        usage.bytes = usage
            .bytes
            .checked_add(metadata.len())
            .ok_or_else(|| anyhow!("received-file storage size overflow"))?;
        usage.files = usage
            .files
            .checked_add(1)
            .ok_or_else(|| anyhow!("received-file storage count overflow"))?;
    }
    Ok(usage)
}

fn session_storage_namespace(session_id: &str) -> String {
    let digest = Sha256::digest(session_id.as_bytes());
    hex16(
        digest[..16]
            .try_into()
            .expect("SHA-256 prefix length is fixed"),
    )
}

/// Coordinates authenticated Apple JSON v1 message routing between active
/// outbound senders and this session's approval-aware receiver state machine.
pub(super) struct FileTransferCoordinator {
    session_id: String,
    authority: RuntimeIncarnationAuthority,
    sender_inboxes: Mutex<HashMap<[u8; 16], mpsc::Sender<CrossNetworkFileTransferMessageV1>>>,
    receiver: Mutex<FileReceiver>,
}

impl FileTransferCoordinator {
    pub(super) fn new(
        session_id: String,
        store: Arc<InboundFileStore>,
        authority: RuntimeIncarnationAuthority,
    ) -> Self {
        Self {
            receiver: Mutex::new(FileReceiver::new(session_id.clone(), store)),
            session_id,
            authority,
            sender_inboxes: Mutex::new(HashMap::new()),
        }
    }

    async fn register_sender(
        &self,
        transfer_id: [u8; 16],
    ) -> Result<mpsc::Receiver<CrossNetworkFileTransferMessageV1>> {
        let (tx, rx) = mpsc::channel(64);
        let mut inboxes = self.sender_inboxes.lock().await;
        if inboxes.contains_key(&transfer_id) {
            bail!("file-transfer sender is already registered for this request");
        }
        inboxes.insert(transfer_id, tx);
        Ok(rx)
    }

    async fn unregister_sender(&self, transfer_id: &[u8; 16]) {
        self.sender_inboxes.lock().await.remove(transfer_id);
    }

    pub(super) async fn route_inbound(
        &self,
        message: CrossNetworkFileTransferMessageV1,
        sender: &NativeWebRtcSender,
    ) -> Result<()> {
        if let CrossNetworkFileTransferMessageV1::Metadata(metadata) = message {
            return self.route_inbound_metadata(metadata, sender).await;
        }
        self.authority
            .run_external_effect("inbound file-message handling", async {
                match &message {
                    CrossNetworkFileTransferMessageV1::MetadataAck { transfer_id }
                    | CrossNetworkFileTransferMessageV1::ChunkAck(
                        CrossNetworkFileChunkAckV1::Received { transfer_id, .. }
                        | CrossNetworkFileChunkAckV1::Missing { transfer_id, .. },
                    )
                    | CrossNetworkFileTransferMessageV1::CompleteAck(
                        CrossNetworkFileCompletionV1 { transfer_id, .. },
                    )
                    | CrossNetworkFileTransferMessageV1::Error { transfer_id, .. } => {
                        let inbox = self
                            .sender_inboxes
                            .lock()
                            .await
                            .get(&transfer_key(transfer_id))
                            .cloned();
                        if let Some(inbox) = inbox {
                            inbox.try_send(message).map_err(|error| {
                                anyhow!("failed to route file-transfer acknowledgement: {error}")
                            })?;
                        } else {
                            debug!(
                                kind = "agent.file_transfer.unmatched_receipt",
                                session_id = %self.session_id,
                                "received file-transfer response with no active sender"
                            );
                        }
                        Ok(())
                    }
                    CrossNetworkFileTransferMessageV1::Cancel { transfer_id, .. } => {
                        let inbox = self
                            .sender_inboxes
                            .lock()
                            .await
                            .get(&transfer_key(transfer_id))
                            .cloned();
                        if let Some(inbox) = inbox {
                            inbox.try_send(message).map_err(|error| {
                                anyhow!("failed to route file-transfer cancellation: {error}")
                            })?;
                            return Ok(());
                        }
                        let outbound = self.receiver.lock().await.handle_message(message).await?;
                        send_file_messages(sender, outbound).await
                    }
                    CrossNetworkFileTransferMessageV1::Metadata(_) => {
                        bail!("metadata bypassed authenticated admission routing")
                    }
                    CrossNetworkFileTransferMessageV1::Chunk(_)
                    | CrossNetworkFileTransferMessageV1::Complete(_) => {
                        let outbound = {
                            let mut receiver = self.receiver.lock().await;
                            receiver.handle_message(message).await?
                        };
                        send_file_messages(sender, outbound).await
                    }
                }
            })
            .await
    }

    async fn route_inbound_metadata(
        &self,
        metadata: CrossNetworkFileMetadataV1,
        sender: &NativeWebRtcSender,
    ) -> Result<()> {
        let authenticated_peer = authenticated_file_transfer_peer_for_runtime(
            &self.authority.paths,
            &self.authority.session_id,
            &self.authority.expected_runtime_id,
        )
        .await?;
        let preflight = self
            .receiver
            .lock()
            .await
            .preflight_authenticated_metadata(
                metadata.clone(),
                &authenticated_peer.device_id,
                &authenticated_peer.device_name,
            )
            .await?;
        if let Some(outbound) = preflight {
            return self
                .authority
                .run_external_effect(
                    "inbound file metadata replay response",
                    send_file_messages(sender, outbound),
                )
                .await;
        }

        let metadata_digest = hex32(&metadata_binding_sha256(&metadata)?);
        let approval = register_inbound_file_transfer_approval_for_runtime(
            &self.authority.paths,
            InboundFileTransferApprovalRegistration {
                session_id: self.authority.session_id.clone(),
                expected_runtime_id: self.authority.expected_runtime_id.clone(),
                transfer_id: metadata.transfer_id.as_str().to_owned(),
                metadata_sha256_hex: metadata_digest,
                file_name: metadata.file_name.clone(),
                file_size: metadata.file_size,
                claimed_sender_device_id: metadata.sender_device_id.clone(),
            },
        )
        .await?;
        self.authority
            .run_external_effect("inbound file metadata admission", async {
                let outbound = self
                    .receiver
                    .lock()
                    .await
                    .handle_authenticated_metadata(
                        metadata,
                        approval.authenticated_peer_device_id,
                        approval.authenticated_peer_device_name,
                    )
                    .await?;
                send_file_messages(sender, outbound).await
            })
            .await
    }

    pub(super) async fn expire_idle_receives(&self, sender: &NativeWebRtcSender) -> Result<()> {
        self.authority
            .run_external_effect("inbound file timeout cleanup", async {
                let outbound = {
                    let mut receiver = self.receiver.lock().await;
                    receiver.expire_idle_transfers(Instant::now()).await?
                };
                send_file_messages(sender, outbound).await
            })
            .await
    }

    pub(super) async fn approve_inbound(
        &self,
        transfer_id: &str,
        sender: &NativeWebRtcSender,
    ) -> Result<()> {
        let transfer_id = CrossNetworkTransferId::parse(transfer_id.to_owned())?;
        self.authority
            .run_external_effect("inbound file approval", async {
                let outbound = self
                    .receiver
                    .lock()
                    .await
                    .approve_pending(&transfer_id)
                    .await?;
                send_file_messages(sender, outbound).await
            })
            .await
    }

    pub(super) async fn reject_inbound(
        &self,
        transfer_id: &str,
        sender: &NativeWebRtcSender,
    ) -> Result<()> {
        let transfer_id = CrossNetworkTransferId::parse(transfer_id.to_owned())?;
        self.authority
            .run_external_effect("inbound file rejection", async {
                let outbound = self.receiver.lock().await.reject_pending(&transfer_id)?;
                send_file_messages(sender, outbound).await
            })
            .await
    }

    pub(super) async fn shutdown_receives(&self) -> Result<()> {
        self.receiver.lock().await.abort_all().await
    }
}

async fn send_file_messages(
    sender: &NativeWebRtcSender,
    messages: Vec<CrossNetworkFileTransferMessageV1>,
) -> Result<()> {
    for message in messages {
        let plaintext = encode_cross_network_file_transfer_message_v1(&message)?;
        sender.send_file_app_frame(&plaintext).await?;
    }
    Ok(())
}

async fn send_file_message_or_cancel(
    sender: &NativeWebRtcSender,
    message: &CrossNetworkFileTransferMessageV1,
    cancel: &CancellationToken,
    authority: &RuntimeIncarnationAuthority,
) -> Result<()> {
    let plaintext = encode_cross_network_file_transfer_message_v1(message)?;
    authority
        .run_external_effect("outbound file message send", async {
            tokio::select! {
                _ = cancel.cancelled() => bail!("transfer cancelled"),
                result = sender.send_file_app_frame(&plaintext) => result,
            }
        })
        .await
}

#[derive(Debug)]
pub(super) struct FileSendWorker {
    cancel: CancellationToken,
    handle: JoinHandle<Result<()>>,
}

impl FileSendWorker {
    pub(super) fn cancel(&self) {
        self.cancel.cancel();
    }

    pub(super) fn is_finished(&self) -> bool {
        self.handle.is_finished()
    }

    pub(super) async fn join(self) -> Result<()> {
        match self.handle.await {
            Ok(result) => result,
            Err(error) => Err(anyhow!("file-send task failed to join: {error}")),
        }
    }
}

/// Spawn one tracked send transfer. The owning managed session must retain,
/// cancel, and await the returned worker.
pub(super) fn spawn_file_send_transfer(
    paths: AgentPaths,
    coordinator: Arc<FileTransferCoordinator>,
    request: FileTransferControlRequest,
    sender: NativeWebRtcSender,
    cancel: CancellationToken,
    resources: Arc<OutboundTransferResources>,
) -> FileSendWorker {
    let worker_cancel = cancel.clone();
    let handle = tokio::spawn(run_file_send_task(
        paths,
        coordinator,
        request,
        sender,
        worker_cancel,
        resources,
    ));
    FileSendWorker { cancel, handle }
}

async fn run_file_send_task(
    paths: AgentPaths,
    coordinator: Arc<FileTransferCoordinator>,
    request: FileTransferControlRequest,
    sender: NativeWebRtcSender,
    cancel: CancellationToken,
    resources: Arc<OutboundTransferResources>,
) -> Result<()> {
    let request_id = request.request_id.clone();
    let transfer_id = wire_transfer_id_for(&request_id)?;
    let transfer_key = transfer_key(&transfer_id);
    let transfer_result = match resources.reserve(request.source.size_bytes) {
        Ok(reservation) => {
            let result = match coordinator.register_sender(transfer_key).await {
                Ok(inbox) => {
                    let result = run_cross_network_file_send_transfer(
                        &paths,
                        &request,
                        transfer_id,
                        &sender,
                        inbox,
                        &cancel,
                        &coordinator.authority,
                    )
                    .await;
                    coordinator.unregister_sender(&transfer_key).await;
                    result
                }
                Err(error) => Err(error),
            };
            match (result, reservation.release()) {
                (Ok(bytes), Ok(())) => Ok(bytes),
                (Err(error), Ok(())) => Err(error),
                (Ok(_), Err(release_error)) => Err(release_error
                    .context("verified transfer completed but outbound capacity release failed")),
                (Err(error), Err(release_error)) => Err(error.context(format!(
                    "outbound capacity release also failed: {release_error:#}"
                ))),
            }
        }
        Err(error) => Err(error),
    };

    persist_file_send_terminal(&paths, &request, transfer_result).await
}

async fn persist_file_send_terminal(
    paths: &AgentPaths,
    request: &FileTransferControlRequest,
    transfer_result: Result<u64>,
) -> Result<()> {
    let request_id = request.request_id.clone();
    match transfer_result {
        Ok(bytes) => {
            complete_file_transfer_request_for_runtime(
                paths,
                &request_id,
                &request.target_runtime_id,
                bytes,
            )
            .await
            .context("verified file transfer completed but terminal status persistence failed")?;
            info!(
                kind = "agent.file_transfer.completed",
                session_id = %request.session_id,
                request_id = %request_id,
                bytes_transferred = bytes,
                receipt_verified = true,
                "file transfer completed with verified completeAck"
            );
            Ok(())
        }
        Err(transfer_error) => {
            let reason = generic_failure_reason(&transfer_error);
            fail_file_transfer_request_for_runtime(
                paths,
                &request_id,
                &request.target_runtime_id,
                reason,
            )
            .await
            .map_err(|persist_error| {
                anyhow!(
                    "file transfer failed: {transfer_error:#}; terminal failure persistence also failed: {persist_error:#}"
                )
            })?;
            warn!(
                kind = "agent.file_transfer.failed",
                session_id = %request.session_id,
                request_id = %request_id,
                error = %transfer_error,
                "file transfer did not close with a verified completeAck"
            );
            Ok(())
        }
    }
}

fn generic_failure_reason(error: &anyhow::Error) -> String {
    // Keep persisted reasons coarse and free of path/peer/digest material.
    let text = error.to_string();
    if text.contains("cancel") {
        "transfer cancelled".to_owned()
    } else if text.contains("outbound resource limit") {
        "agent outbound resource limit reached".to_owned()
    } else if text.contains("completeAck") || text.contains("sha256") {
        "receipt verification failed".to_owned()
    } else if text.contains("approval") || text.contains("metadataAck") {
        "receiver approval failed".to_owned()
    } else {
        "transfer transport error".to_owned()
    }
}

async fn run_cross_network_file_send_transfer(
    paths: &AgentPaths,
    request: &FileTransferControlRequest,
    transfer_id: CrossNetworkTransferId,
    sender: &NativeWebRtcSender,
    inbox: mpsc::Receiver<CrossNetworkFileTransferMessageV1>,
    cancel: &CancellationToken,
    authority: &RuntimeIncarnationAuthority,
) -> Result<u64> {
    let expected_sha256 = parse_sha256_hex(&request.source.sha256_hex)?;
    let mut snapshot =
        prepare_source_snapshot(paths, request, &expected_sha256, cancel, authority).await?;
    let context = CrossNetworkOutboundSendContext {
        paths,
        request,
        sender,
        cancel,
        expected_sha256: &expected_sha256,
        authority,
    };
    let transfer_result =
        stream_cross_network_source(&context, transfer_id, inbox, snapshot.file_mut()?).await;
    let cleanup_result = snapshot.cleanup().await;
    match (transfer_result, cleanup_result) {
        (Ok(bytes), Ok(())) => Ok(bytes),
        (Ok(_), Err(cleanup_error)) => {
            Err(cleanup_error.context("verified transfer completed but snapshot cleanup failed"))
        }
        (Err(transfer_error), Ok(())) => Err(transfer_error),
        (Err(transfer_error), Err(cleanup_error)) => Err(transfer_error.context(format!(
            "private source snapshot cleanup also failed: {cleanup_error:#}"
        ))),
    }
}

struct CrossNetworkOutboundSendContext<'a> {
    paths: &'a AgentPaths,
    request: &'a FileTransferControlRequest,
    sender: &'a NativeWebRtcSender,
    cancel: &'a CancellationToken,
    expected_sha256: &'a [u8; 32],
    authority: &'a RuntimeIncarnationAuthority,
}

async fn stream_cross_network_source(
    context: &CrossNetworkOutboundSendContext<'_>,
    transfer_id: CrossNetworkTransferId,
    mut inbox: mpsc::Receiver<CrossNetworkFileTransferMessageV1>,
    file: &mut File,
) -> Result<u64> {
    let request = context.request;
    let total_size = request.source.size_bytes;
    let source_filename = Path::new(&request.source.source_path)
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow!("queued file-transfer source has no valid UTF-8 filename"))?;
    let filename = sanitize_filename(source_filename).ok_or_else(|| {
        anyhow!("queued file-transfer source filename cannot be safely projected")
    })?;
    let total_chunks = cross_network_total_chunks(total_size, CHUNK_PAYLOAD_BYTES as u32)?;

    start_file_transfer_request_for_runtime(
        context.paths,
        &request.request_id,
        &request.target_runtime_id,
    )
    .await?;

    let metadata = CrossNetworkFileMetadataV1 {
        transfer_id: transfer_id.clone(),
        sender_device_id: None,
        sender_device_name: None,
        file_name: filename,
        file_size: total_size,
        chunk_size: CHUNK_PAYLOAD_BYTES as u32,
        total_chunks,
        mime_type: None,
    };
    send_file_message_or_cancel(
        context.sender,
        &CrossNetworkFileTransferMessageV1::Metadata(metadata.clone()),
        context.cancel,
        context.authority,
    )
    .await?;
    expect_metadata_ack(&mut inbox, context.cancel, &transfer_id).await?;

    let mut buffer = vec![0u8; CHUNK_PAYLOAD_BYTES];
    let mut sent_bytes = 0u64;
    let mut chunk_index = 0u32;
    let mut last_checkpoint = 0u64;
    loop {
        let read = tokio::select! {
            _ = context.cancel.cancelled() => bail!("transfer cancelled while reading private source snapshot"),
            result = file.read(&mut buffer) => {
                result.context("failed to read private file-transfer snapshot")?
            }
        };
        if read == 0 {
            break;
        }
        let chunk_data = buffer[..read].to_vec();
        let message = CrossNetworkFileTransferMessageV1::Chunk(CrossNetworkFileChunkV1 {
            transfer_id: transfer_id.clone(),
            chunk_index,
            chunk_sha256: Sha256::digest(&chunk_data).into(),
            raw_size: u32::try_from(read).context("file chunk length exceeded u32")?,
            chunk_data,
        });
        message.validate_against_metadata(&metadata)?;
        send_file_message_or_cancel(context.sender, &message, context.cancel, context.authority)
            .await?;
        let next_sent = sent_bytes
            .checked_add(read as u64)
            .ok_or_else(|| anyhow!("sent byte count overflow"))?;
        expect_chunk_ack(
            &mut inbox,
            context.cancel,
            &metadata,
            chunk_index,
            next_sent,
        )
        .await?;
        sent_bytes = next_sent;
        chunk_index = chunk_index
            .checked_add(1)
            .ok_or_else(|| anyhow!("chunk index overflow"))?;

        if sent_bytes - last_checkpoint >= 16 * 1024 * 1024 {
            last_checkpoint = sent_bytes;
            record_file_transfer_progress_for_runtime(
                context.paths,
                &request.request_id,
                &request.target_runtime_id,
                sent_bytes,
            )
            .await
            .context("failed to persist file-transfer progress checkpoint")?;
        }
    }
    if sent_bytes != total_size || chunk_index != total_chunks {
        bail!("source changed dimensions during transfer");
    }

    let completion = CrossNetworkFileCompletionV1 {
        transfer_id: transfer_id.clone(),
        received_bytes: sent_bytes,
        file_sha256: *context.expected_sha256,
    };
    send_file_message_or_cancel(
        context.sender,
        &CrossNetworkFileTransferMessageV1::Complete(completion.clone()),
        context.cancel,
        context.authority,
    )
    .await?;
    expect_complete_ack(&mut inbox, context.cancel, &metadata, &completion).await?;
    Ok(sent_bytes)
}

fn cross_network_total_chunks(total_size: u64, chunk_size: u32) -> Result<u32> {
    if chunk_size == 0 {
        bail!("file-transfer chunk size must be positive");
    }
    if total_size == 0 {
        return Ok(0);
    }
    let chunks = total_size
        .checked_add(u64::from(chunk_size) - 1)
        .ok_or_else(|| anyhow!("file-transfer chunk count overflow"))?
        / u64::from(chunk_size);
    let chunks = u32::try_from(chunks).context("file-transfer chunk count exceeded u32")?;
    if chunks > MAX_CROSS_NETWORK_FILE_CHUNKS {
        bail!("file-transfer chunk count exceeded protocol limit");
    }
    Ok(chunks)
}

async fn next_sender_message(
    inbox: &mut mpsc::Receiver<CrossNetworkFileTransferMessageV1>,
    cancel: &CancellationToken,
) -> Result<CrossNetworkFileTransferMessageV1> {
    tokio::select! {
        _ = cancel.cancelled() => bail!("transfer cancelled"),
        _ = tokio::time::sleep(INBOUND_PROGRESS_TIMEOUT) => {
            bail!("timed out waiting for file-transfer acknowledgement")
        }
        message = inbox.recv() => message.ok_or_else(|| anyhow!("file-transfer response channel closed")),
    }
}

async fn expect_metadata_ack(
    inbox: &mut mpsc::Receiver<CrossNetworkFileTransferMessageV1>,
    cancel: &CancellationToken,
    transfer_id: &CrossNetworkTransferId,
) -> Result<()> {
    match next_sender_message(inbox, cancel).await? {
        CrossNetworkFileTransferMessageV1::MetadataAck {
            transfer_id: actual,
        } if actual.uuid() == transfer_id.uuid() => Ok(()),
        CrossNetworkFileTransferMessageV1::Error { .. } => {
            bail!("receiver rejected file-transfer approval")
        }
        CrossNetworkFileTransferMessageV1::Cancel { .. } => {
            bail!("receiver cancelled file transfer")
        }
        _ => bail!("expected metadataAck for the active file transfer"),
    }
}

async fn expect_chunk_ack(
    inbox: &mut mpsc::Receiver<CrossNetworkFileTransferMessageV1>,
    cancel: &CancellationToken,
    metadata: &CrossNetworkFileMetadataV1,
    expected_index: u32,
    expected_received_bytes: u64,
) -> Result<()> {
    let message = next_sender_message(inbox, cancel).await?;
    message.validate_against_metadata(metadata)?;
    match message {
        CrossNetworkFileTransferMessageV1::ChunkAck(CrossNetworkFileChunkAckV1::Received {
            chunk_index,
            received_bytes,
            ..
        }) if chunk_index == expected_index && received_bytes == expected_received_bytes => Ok(()),
        CrossNetworkFileTransferMessageV1::ChunkAck(CrossNetworkFileChunkAckV1::Missing {
            ..
        }) => bail!("receiver reported missing chunks during ordered transfer"),
        CrossNetworkFileTransferMessageV1::Error { .. } => {
            bail!("receiver rejected file-transfer chunk")
        }
        CrossNetworkFileTransferMessageV1::Cancel { .. } => {
            bail!("receiver cancelled file transfer")
        }
        _ => bail!("received mismatched file-transfer chunkAck"),
    }
}

async fn expect_complete_ack(
    inbox: &mut mpsc::Receiver<CrossNetworkFileTransferMessageV1>,
    cancel: &CancellationToken,
    metadata: &CrossNetworkFileMetadataV1,
    expected: &CrossNetworkFileCompletionV1,
) -> Result<()> {
    let message = next_sender_message(inbox, cancel).await?;
    message.validate_against_metadata(metadata)?;
    match message {
        CrossNetworkFileTransferMessageV1::CompleteAck(actual)
            if actual.received_bytes == expected.received_bytes
                && actual.file_sha256 == expected.file_sha256 =>
        {
            Ok(())
        }
        CrossNetworkFileTransferMessageV1::Error { .. } => {
            bail!("receiver rejected file-transfer completion")
        }
        CrossNetworkFileTransferMessageV1::Cancel { .. } => {
            bail!("receiver cancelled file transfer")
        }
        _ => bail!("received mismatched file-transfer completeAck"),
    }
}

#[cfg(test)]
async fn run_file_send_transfer(
    paths: &AgentPaths,
    request: &FileTransferControlRequest,
    sender: &NativeWebRtcSender,
    inbox: mpsc::Receiver<FileAppFrame>,
    cancel: &CancellationToken,
    authority: &RuntimeIncarnationAuthority,
) -> Result<u64> {
    let expected_sha256 = parse_sha256_hex(&request.source.sha256_hex)?;
    let mut snapshot =
        prepare_source_snapshot(paths, request, &expected_sha256, cancel, authority).await?;
    let context = OutboundSendContext {
        paths,
        request,
        sender,
        cancel,
        expected_sha256: &expected_sha256,
        authority,
    };
    let transfer_result = stream_prepared_source(&context, inbox, snapshot.file_mut()?).await;
    let cleanup_result = snapshot.cleanup().await;
    match (transfer_result, cleanup_result) {
        (Ok(bytes), Ok(())) => Ok(bytes),
        (Ok(_), Err(cleanup_error)) => {
            Err(cleanup_error.context("verified transfer completed but snapshot cleanup failed"))
        }
        (Err(transfer_error), Ok(())) => Err(transfer_error),
        (Err(transfer_error), Err(cleanup_error)) => Err(transfer_error.context(format!(
            "private source snapshot cleanup also failed: {cleanup_error:#}"
        ))),
    }
}

#[cfg(test)]
struct OutboundSendContext<'a> {
    paths: &'a AgentPaths,
    request: &'a FileTransferControlRequest,
    sender: &'a NativeWebRtcSender,
    cancel: &'a CancellationToken,
    expected_sha256: &'a [u8; 32],
    authority: &'a RuntimeIncarnationAuthority,
}

#[cfg(test)]
async fn stream_prepared_source(
    context: &OutboundSendContext<'_>,
    mut inbox: mpsc::Receiver<FileAppFrame>,
    file: &mut File,
) -> Result<u64> {
    let paths = context.paths;
    let request = context.request;
    let sender = context.sender;
    let cancel = context.cancel;
    let expected_sha256 = context.expected_sha256;
    let authority = context.authority;
    let transfer_id = transfer_id_for(&request.request_id);
    let total_size = request.source.size_bytes;
    let source_filename = Path::new(&request.source.source_path)
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow!("queued file-transfer source has no valid UTF-8 filename"))?;
    let filename = sanitize_filename(source_filename).ok_or_else(|| {
        anyhow!("queued file-transfer source filename cannot be safely projected")
    })?;

    start_file_transfer_request_for_runtime(paths, &request.request_id, &request.target_runtime_id)
        .await?;

    let offer = file_transfer_frame::encode_offer(
        &transfer_id,
        total_size,
        CHUNK_PAYLOAD_BYTES as u32,
        expected_sha256,
        &filename,
    )?;
    send_or_cancel(sender, &offer, cancel, authority).await?;

    let mut buffer = vec![0u8; CHUNK_PAYLOAD_BYTES];
    let mut next_seq: u64 = 0;
    let mut acked_through: Option<u64> = None;
    let mut sent_bytes: u64 = 0;
    let mut last_checkpoint: u64 = 0;
    let mut pending_receipt: Option<(bool, [u8; 32])> = None;

    loop {
        let read = tokio::select! {
            _ = cancel.cancelled() => bail!("transfer cancelled while reading private source snapshot"),
            result = file.read(&mut buffer) => {
                result.context("failed to read private file-transfer snapshot")?
            }
        };
        if read == 0 {
            break;
        }

        // Backpressure: bound the number of unacked chunks in flight.
        while in_flight(next_seq, acked_through) >= WINDOW_CHUNKS {
            match wait_for_inbound(&mut inbox, cancel).await? {
                InboundSignal::Ack(seq) => {
                    apply_ack(next_seq, &mut acked_through, seq)?;
                }
                InboundSignal::Receipt {
                    ok,
                    computed_sha256,
                } => {
                    if sent_bytes < total_size {
                        bail!(
                            "receiver receipt arrived before all declared source bytes were sent"
                        );
                    }
                    pending_receipt = Some((ok, computed_sha256));
                    break;
                }
            }
        }

        let chunk =
            file_transfer_frame::encode_chunk(&transfer_id, next_seq as u32, &buffer[..read])?;
        send_or_cancel(sender, &chunk, cancel, authority).await?;
        next_seq += 1;
        sent_bytes += read as u64;

        // Drain any acks that arrived without blocking, to keep the window moving.
        while let Ok(frame) = inbox.try_recv() {
            match frame {
                FileAppFrame::ChunkAck {
                    acked_through_seq, ..
                } => apply_ack(next_seq, &mut acked_through, acked_through_seq)?,
                FileAppFrame::Receipt {
                    ok,
                    computed_sha256,
                    ..
                } => {
                    if sent_bytes < total_size {
                        bail!(
                            "receiver receipt arrived before all declared source bytes were sent"
                        );
                    }
                    pending_receipt = Some((ok, computed_sha256));
                }
                _ => bail!("unexpected file frame routed to sender inbox"),
            }
        }

        if sent_bytes - last_checkpoint >= 16 * 1024 * 1024 {
            last_checkpoint = sent_bytes;
            record_file_transfer_progress_for_runtime(
                paths,
                &request.request_id,
                &request.target_runtime_id,
                sent_bytes,
            )
            .await
            .context("failed to persist file-transfer progress checkpoint")?;
        }
    }

    if sent_bytes != total_size {
        bail!("source changed size during transfer");
    }

    if let Some((ok, computed_sha256)) = pending_receipt {
        return finalize_receipt(
            ok,
            &computed_sha256,
            expected_sha256,
            sent_bytes,
            total_size,
        );
    }

    // All chunks sent; await the receiver's SHA-256 receipt.
    loop {
        match wait_for_inbound(&mut inbox, cancel).await? {
            InboundSignal::Ack(_) => {}
            InboundSignal::Receipt {
                ok,
                computed_sha256,
            } => {
                return finalize_receipt(
                    ok,
                    &computed_sha256,
                    expected_sha256,
                    sent_bytes,
                    total_size,
                );
            }
        }
    }
}

#[cfg(test)]
fn in_flight(next_seq: u64, acked_through: Option<u64>) -> u64 {
    let acked_count = acked_through.map(|seq| seq + 1).unwrap_or(0);
    next_seq.saturating_sub(acked_count)
}

#[cfg(test)]
fn apply_ack(next_seq: u64, acked_through: &mut Option<u64>, acknowledged: u32) -> Result<()> {
    let acknowledged = u64::from(acknowledged);
    if next_seq == 0 || acknowledged >= next_seq {
        bail!("receiver acknowledged a chunk sequence that was not sent");
    }
    if acked_through.is_none_or(|current| acknowledged > current) {
        *acked_through = Some(acknowledged);
    }
    Ok(())
}

#[cfg(test)]
fn finalize_receipt(
    ok: bool,
    computed_sha256: &[u8; 32],
    expected_sha256: &[u8; 32],
    sent_bytes: u64,
    expected_size: u64,
) -> Result<u64> {
    if sent_bytes != expected_size {
        bail!("receiver receipt arrived before the declared source size was sent")
    }
    if ok && computed_sha256 == expected_sha256 {
        Ok(sent_bytes)
    } else {
        bail!("receiver rejected transfer: receipt sha256 mismatch")
    }
}

#[derive(Debug)]
#[cfg(test)]
enum InboundSignal {
    Ack(u32),
    Receipt { ok: bool, computed_sha256: [u8; 32] },
}

#[cfg(test)]
async fn wait_for_inbound(
    inbox: &mut mpsc::Receiver<FileAppFrame>,
    cancel: &CancellationToken,
) -> Result<InboundSignal> {
    tokio::select! {
        _ = cancel.cancelled() => bail!("transfer cancelled"),
        _ = tokio::time::sleep(INBOUND_PROGRESS_TIMEOUT) => {
            bail!("timed out waiting for file transfer acknowledgement or receipt")
        }
        frame = inbox.recv() => {
            match frame {
                Some(FileAppFrame::ChunkAck { acked_through_seq, .. }) => {
                    Ok(InboundSignal::Ack(acked_through_seq))
                }
                Some(FileAppFrame::Receipt { ok, computed_sha256, .. }) => {
                    Ok(InboundSignal::Receipt {
                        ok,
                        computed_sha256,
                    })
                }
                Some(_) => bail!("unexpected file frame routed to sender inbox"),
                None => bail!("inbound receipt channel closed"),
            }
        }
    }
}

#[cfg(test)]
async fn send_or_cancel(
    sender: &NativeWebRtcSender,
    plaintext: &[u8],
    cancel: &CancellationToken,
    authority: &RuntimeIncarnationAuthority,
) -> Result<()> {
    authority
        .run_external_effect("outbound file frame send", async {
            tokio::select! {
                _ = cancel.cancelled() => bail!("transfer cancelled"),
                result = sender.send_file_app_frame(plaintext) => result,
            }
        })
        .await
}

/// Sanitize an advertised filename into a safe, single-component name.
fn sanitize_filename(raw: &str) -> Option<String> {
    let name = Path::new(raw).file_name()?.to_str()?;
    let cleaned: String = name.chars().filter(|ch| !ch.is_control()).collect();
    let cleaned = cleaned.trim();
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        return None;
    }
    if cleaned.contains('/') || cleaned.contains('\\') || cleaned.contains('\0') {
        return None;
    }
    let mut clamped = cleaned.to_owned();
    if clamped.len() > MAX_FILENAME_LEN {
        let mut end = MAX_FILENAME_LEN;
        while end > 0 && !clamped.is_char_boundary(end) {
            end -= 1;
        }
        clamped.truncate(end);
        if clamped.trim().is_empty() {
            return None;
        }
    }
    Some(clamped)
}

struct PendingInboundTransfer {
    metadata: CrossNetworkFileMetadataV1,
    authenticated_peer_device_id: String,
}

struct CrossNetworkInboundTransfer {
    metadata: CrossNetworkFileMetadataV1,
    reservation: InboundStorageReservation,
    final_name: String,
    file: File,
    hasher: Sha256,
    received_bytes: u64,
    chunk_hashes: Vec<[u8; 32]>,
    chunk_sizes: Vec<u32>,
    last_progress_at: Instant,
}

struct FileReceiver {
    session_id: String,
    store: Arc<InboundFileStore>,
    pending: HashMap<[u8; 16], PendingInboundTransfer>,
    transfers: HashMap<[u8; 16], CrossNetworkInboundTransfer>,
}

impl FileReceiver {
    fn new(session_id: String, store: Arc<InboundFileStore>) -> Self {
        Self {
            session_id,
            store,
            pending: HashMap::new(),
            transfers: HashMap::new(),
        }
    }

    async fn handle_message(
        &mut self,
        message: CrossNetworkFileTransferMessageV1,
    ) -> Result<Vec<CrossNetworkFileTransferMessageV1>> {
        match message {
            CrossNetworkFileTransferMessageV1::Metadata(_) => {
                bail!(
                    "metadata must pass authenticated runtime authority before receiver admission"
                )
            }
            CrossNetworkFileTransferMessageV1::Chunk(chunk) => self.on_chunk(chunk).await,
            CrossNetworkFileTransferMessageV1::Complete(completion) => {
                self.on_complete(completion).await
            }
            CrossNetworkFileTransferMessageV1::Cancel { transfer_id, .. } => {
                self.on_cancel(&transfer_id).await?;
                Ok(Vec::new())
            }
            CrossNetworkFileTransferMessageV1::MetadataAck { .. }
            | CrossNetworkFileTransferMessageV1::ChunkAck(_)
            | CrossNetworkFileTransferMessageV1::CompleteAck(_)
            | CrossNetworkFileTransferMessageV1::Error { .. } => {
                bail!("response operation was routed to the inbound file receiver")
            }
        }
    }

    async fn preflight_authenticated_metadata(
        &self,
        mut metadata: CrossNetworkFileMetadataV1,
        authenticated_peer_device_id: &str,
        authenticated_peer_device_name: &str,
    ) -> Result<Option<Vec<CrossNetworkFileTransferMessageV1>>> {
        if metadata
            .sender_device_id
            .as_deref()
            .is_some_and(|claimed| claimed != authenticated_peer_device_id)
        {
            bail!("metadata senderDeviceId does not match authenticated peer authority");
        }
        metadata.sender_device_id = Some(authenticated_peer_device_id.to_owned());
        metadata.sender_device_name = Some(authenticated_peer_device_name.to_owned());
        let key = transfer_key(&metadata.transfer_id);
        if let Some(receipt) = self
            .store
            .load_terminal_receipt(&self.session_id, &metadata.transfer_id)
            .await?
        {
            if receipt.metadata_sha256_hex != hex32(&metadata_binding_sha256(&metadata)?) {
                return Ok(Some(vec![error_message(
                    metadata.transfer_id,
                    None,
                    "metadata conflicts with completed transfer",
                )]));
            }
            return Ok(Some(vec![CrossNetworkFileTransferMessageV1::CompleteAck(
                receipt.completion(metadata.transfer_id)?,
            )]));
        }
        if let Some(active) = self.transfers.get(&key) {
            if !metadata_contract_equal(&active.metadata, &metadata) {
                return Ok(Some(vec![error_message(
                    metadata.transfer_id,
                    None,
                    "metadata conflicts with active transfer",
                )]));
            }
            return Ok(Some(vec![CrossNetworkFileTransferMessageV1::MetadataAck {
                transfer_id: metadata.transfer_id,
            }]));
        }
        if let Some(pending) = self.pending.get(&key) {
            if !metadata_contract_equal(&pending.metadata, &metadata)
                || pending.authenticated_peer_device_id != authenticated_peer_device_id
            {
                return Ok(Some(vec![error_message(
                    metadata.transfer_id,
                    None,
                    "metadata conflicts with pending transfer",
                )]));
            }
            return Ok(Some(Vec::new()));
        }
        if self.pending.len() >= MAX_PENDING_RECEIVE_APPROVALS
            || self.pending.len() + self.transfers.len() >= MAX_CONCURRENT_RECEIVES
        {
            return Ok(Some(vec![error_message(
                metadata.transfer_id,
                None,
                "too many concurrent inbound file transfers",
            )]));
        }
        Ok(None)
    }

    async fn handle_authenticated_metadata(
        &mut self,
        mut metadata: CrossNetworkFileMetadataV1,
        authenticated_peer_device_id: String,
        authenticated_peer_device_name: String,
    ) -> Result<Vec<CrossNetworkFileTransferMessageV1>> {
        if let Some(outbound) = self
            .preflight_authenticated_metadata(
                metadata.clone(),
                &authenticated_peer_device_id,
                &authenticated_peer_device_name,
            )
            .await?
        {
            return Ok(outbound);
        }
        metadata.sender_device_id = Some(authenticated_peer_device_id.clone());
        metadata.sender_device_name = Some(authenticated_peer_device_name.clone());
        let key = transfer_key(&metadata.transfer_id);
        self.pending.insert(
            key,
            PendingInboundTransfer {
                metadata,
                authenticated_peer_device_id,
            },
        );
        Ok(Vec::new())
    }

    async fn approve_pending(
        &mut self,
        transfer_id: &CrossNetworkTransferId,
    ) -> Result<Vec<CrossNetworkFileTransferMessageV1>> {
        let key = transfer_key(transfer_id);
        let pending = self
            .pending
            .remove(&key)
            .ok_or_else(|| anyhow!("inbound file-transfer approval request not found"))?;
        let metadata = pending.metadata;
        let (reservation, file) = match self
            .store
            .reserve(&self.session_id, &key, metadata.file_size)
            .await
        {
            Ok(Some(reservation)) => reservation,
            Ok(None) => {
                return Ok(vec![error_message(
                    metadata.transfer_id,
                    None,
                    "inbound file storage capacity reached",
                )]);
            }
            Err(error) => return Err(error).context("failed to reserve approved inbound storage"),
        };
        let final_name = metadata.file_name.clone();
        self.transfers.insert(
            key,
            CrossNetworkInboundTransfer {
                metadata: metadata.clone(),
                reservation,
                final_name,
                file,
                hasher: Sha256::new(),
                received_bytes: 0,
                chunk_hashes: Vec::with_capacity(metadata.total_chunks as usize),
                chunk_sizes: Vec::with_capacity(metadata.total_chunks as usize),
                last_progress_at: Instant::now(),
            },
        );
        Ok(vec![CrossNetworkFileTransferMessageV1::MetadataAck {
            transfer_id: metadata.transfer_id,
        }])
    }

    fn reject_pending(
        &mut self,
        transfer_id: &CrossNetworkTransferId,
    ) -> Result<Vec<CrossNetworkFileTransferMessageV1>> {
        let pending = self
            .pending
            .remove(&transfer_key(transfer_id))
            .ok_or_else(|| anyhow!("inbound file-transfer approval request not found"))?;
        Ok(vec![error_message(
            pending.metadata.transfer_id,
            None,
            "inbound file transfer rejected",
        )])
    }

    async fn on_chunk(
        &mut self,
        chunk: CrossNetworkFileChunkV1,
    ) -> Result<Vec<CrossNetworkFileTransferMessageV1>> {
        let key = transfer_key(&chunk.transfer_id);
        let Some(transfer) = self.transfers.get_mut(&key) else {
            return Ok(vec![error_message(
                chunk.transfer_id,
                Some(chunk.chunk_index),
                "unknown transferId or approval pending",
            )]);
        };
        let message = CrossNetworkFileTransferMessageV1::Chunk(chunk.clone());
        if message
            .validate_against_metadata(&transfer.metadata)
            .is_err()
        {
            return self
                .abort_with_error(&key, "chunk does not match approved metadata")
                .await;
        }
        let computed: [u8; 32] = Sha256::digest(&chunk.chunk_data).into();
        if computed != chunk.chunk_sha256 {
            return self.abort_with_error(&key, "chunk hash mismatch").await;
        }
        let expected_index = transfer.chunk_hashes.len() as u32;
        if chunk.chunk_index < expected_index {
            let index = chunk.chunk_index as usize;
            if transfer.chunk_hashes.get(index) != Some(&computed)
                || transfer.chunk_sizes.get(index) != Some(&chunk.raw_size)
            {
                return self
                    .abort_with_error(&key, "duplicate chunk content mismatch")
                    .await;
            }
            return Ok(vec![CrossNetworkFileTransferMessageV1::ChunkAck(
                CrossNetworkFileChunkAckV1::Received {
                    transfer_id: chunk.transfer_id,
                    chunk_index: chunk.chunk_index,
                    received_bytes: received_bytes_through(&transfer.metadata, chunk.chunk_index)?,
                },
            )]);
        }
        if chunk.chunk_index > expected_index {
            let end = chunk.chunk_index.min(
                expected_index.saturating_add(
                    u32::try_from(skybridge_core::MAX_CROSS_NETWORK_MISSING_CHUNKS)
                        .expect("missing chunk limit fits u32"),
                ),
            );
            let missing_chunks = (expected_index..end).collect::<Vec<_>>();
            return Ok(vec![CrossNetworkFileTransferMessageV1::ChunkAck(
                CrossNetworkFileChunkAckV1::Missing {
                    transfer_id: chunk.transfer_id,
                    missing_chunks,
                },
            )]);
        }
        if let Err(error) = transfer.file.write_all(&chunk.chunk_data).await {
            warn!(
                kind = "agent.file_transfer.receive_write_failed",
                error = %error,
                "failed to write approved inbound file chunk"
            );
            return self
                .abort_with_error(&key, "inbound file write failed")
                .await;
        }
        transfer.hasher.update(&chunk.chunk_data);
        transfer.received_bytes = transfer
            .received_bytes
            .checked_add(u64::from(chunk.raw_size))
            .ok_or_else(|| anyhow!("inbound received byte count overflow"))?;
        transfer.chunk_hashes.push(computed);
        transfer.chunk_sizes.push(chunk.raw_size);
        transfer.last_progress_at = Instant::now();
        Ok(vec![CrossNetworkFileTransferMessageV1::ChunkAck(
            CrossNetworkFileChunkAckV1::Received {
                transfer_id: chunk.transfer_id,
                chunk_index: chunk.chunk_index,
                received_bytes: transfer.received_bytes,
            },
        )])
    }

    async fn on_complete(
        &mut self,
        completion: CrossNetworkFileCompletionV1,
    ) -> Result<Vec<CrossNetworkFileTransferMessageV1>> {
        let key = transfer_key(&completion.transfer_id);
        if let Some(receipt) = self
            .store
            .load_terminal_receipt(&self.session_id, &completion.transfer_id)
            .await?
        {
            let cached = receipt.completion(completion.transfer_id)?;
            if cached.received_bytes != completion.received_bytes
                || cached.file_sha256 != completion.file_sha256
            {
                return Ok(vec![error_message(
                    cached.transfer_id,
                    None,
                    "completion conflicts with durable receipt",
                )]);
            }
            return Ok(vec![CrossNetworkFileTransferMessageV1::CompleteAck(cached)]);
        }
        let Some(transfer) = self.transfers.get(&key) else {
            return Ok(vec![error_message(
                completion.transfer_id,
                None,
                "unknown transferId or approval pending",
            )]);
        };
        let message = CrossNetworkFileTransferMessageV1::Complete(completion.clone());
        if message
            .validate_against_metadata(&transfer.metadata)
            .is_err()
        {
            return self
                .abort_with_error(&key, "completion does not match approved metadata")
                .await;
        }
        if transfer.received_bytes != transfer.metadata.file_size
            || transfer.chunk_hashes.len() != transfer.metadata.total_chunks as usize
        {
            let first_missing = transfer.chunk_hashes.len() as u32;
            let end = transfer.metadata.total_chunks.min(
                first_missing.saturating_add(
                    u32::try_from(skybridge_core::MAX_CROSS_NETWORK_MISSING_CHUNKS)
                        .expect("missing chunk limit fits u32"),
                ),
            );
            let missing_chunks = (first_missing..end).collect::<Vec<_>>();
            if missing_chunks.is_empty() {
                return self
                    .abort_with_error(&key, "inbound byte accounting mismatch")
                    .await;
            }
            return Ok(vec![CrossNetworkFileTransferMessageV1::ChunkAck(
                CrossNetworkFileChunkAckV1::Missing {
                    transfer_id: completion.transfer_id,
                    missing_chunks,
                },
            )]);
        }
        let computed: [u8; 32] = transfer.hasher.clone().finalize().into();
        if computed != completion.file_sha256 {
            return self.abort_with_error(&key, "file hash mismatch").await;
        }
        self.finalize_transfer(&key, completion).await
    }

    async fn finalize_transfer(
        &mut self,
        key: &[u8; 16],
        completion: CrossNetworkFileCompletionV1,
    ) -> Result<Vec<CrossNetworkFileTransferMessageV1>> {
        let transfer = self
            .transfers
            .remove(key)
            .ok_or_else(|| anyhow!("inbound transfer disappeared before finalization"))?;
        let CrossNetworkInboundTransfer {
            metadata,
            reservation,
            final_name,
            mut file,
            received_bytes,
            ..
        } = transfer;
        if let Err(error) = file.flush().await {
            drop(file);
            self.finalize_with_error(reservation, error.into(), false)
                .await?;
            return Ok(vec![error_message(
                completion.transfer_id,
                None,
                "inbound file flush failed",
            )]);
        }
        if let Err(error) = file.sync_all().await {
            drop(file);
            self.finalize_with_error(reservation, error.into(), false)
                .await?;
            return Ok(vec![error_message(
                completion.transfer_id,
                None,
                "inbound file sync failed",
            )]);
        }
        drop(file);

        match self.store.place(&reservation, &final_name).await {
            Ok(final_path) => {
                let receipt =
                    DurableTerminalReceipt::new(&self.session_id, &metadata, &completion)?;
                if let Err(error) = self.store.store_terminal_receipt(&receipt).await {
                    self.finalize_with_error(reservation, error, true).await?;
                    return Ok(vec![error_message(
                        completion.transfer_id,
                        None,
                        "terminal receipt persistence failed",
                    )]);
                }
                self.store
                    .commit(reservation)
                    .await
                    .context("failed to commit verified inbound storage accounting")?;
                info!(
                    kind = "agent.file_transfer.received",
                    bytes = received_bytes,
                    receipt_verified = true,
                    "approved inbound file transfer durably stored"
                );
                debug!(
                    kind = "agent.file_transfer.received_path",
                    path = %final_path.display(),
                    "stored received file"
                );
                Ok(vec![CrossNetworkFileTransferMessageV1::CompleteAck(
                    completion,
                )])
            }
            Err(failure) => {
                self.finalize_with_error(reservation, failure.error, failure.destination_may_exist)
                    .await?;
                Ok(vec![error_message(
                    completion.transfer_id,
                    None,
                    "inbound file placement failed",
                )])
            }
        }
    }

    async fn finalize_with_error(
        &self,
        reservation: InboundStorageReservation,
        error: anyhow::Error,
        destination_may_exist: bool,
    ) -> Result<()> {
        let cleanup_result = if destination_may_exist {
            let staging_cleanup = remove_file_if_present(&reservation.temp_path).await;
            let accounting_commit = self.store.commit(reservation).await;
            match (staging_cleanup, accounting_commit) {
                (Ok(()), Ok(())) => Ok(()),
                (Err(cleanup_error), Ok(())) => Err(cleanup_error)
                    .context("failed to clean ambiguous inbound staging link"),
                (Ok(()), Err(accounting_error)) => Err(accounting_error)
                    .context("failed to account ambiguous received destination"),
                (Err(cleanup_error), Err(accounting_error)) => Err(accounting_error).context(
                    format!(
                        "failed to account ambiguous destination and staging cleanup failed: {cleanup_error:#}"
                    ),
                ),
            }
        } else {
            self.store
                .discard(reservation)
                .await
                .context("failed to clean inbound staging after finalization failure")
        };
        warn!(
            kind = "agent.file_transfer.receive_finalize_failed",
            error = %error,
            "inbound file finalization failed"
        );
        cleanup_result.with_context(|| {
            format!("inbound finalization and cleanup did not converge: {error:#}")
        })
    }

    async fn on_cancel(&mut self, transfer_id: &CrossNetworkTransferId) -> Result<()> {
        let key = transfer_key(transfer_id);
        self.pending.remove(&key);
        self.abort_transfer(&key).await
    }

    async fn abort_transfer(&mut self, key: &[u8; 16]) -> Result<()> {
        if let Some(transfer) = self.transfers.remove(key) {
            drop(transfer.file);
            self.store.discard(transfer.reservation).await?;
        }
        Ok(())
    }

    async fn abort_with_error(
        &mut self,
        key: &[u8; 16],
        message: &'static str,
    ) -> Result<Vec<CrossNetworkFileTransferMessageV1>> {
        let transfer_id = self
            .transfers
            .get(key)
            .map(|transfer| transfer.metadata.transfer_id.clone())
            .ok_or_else(|| anyhow!("inbound transfer disappeared while aborting"))?;
        self.abort_transfer(key)
            .await
            .context("failed to clean inbound staging while aborting transfer")?;
        Ok(vec![error_message(transfer_id, None, message)])
    }

    async fn expire_idle_transfers(
        &mut self,
        now: Instant,
    ) -> Result<Vec<CrossNetworkFileTransferMessageV1>> {
        let expired_active = self
            .transfers
            .iter()
            .filter_map(|(key, transfer)| {
                now.checked_duration_since(transfer.last_progress_at)
                    .is_some_and(|idle| idle >= RECEIVER_IDLE_TIMEOUT)
                    .then_some(*key)
            })
            .collect::<Vec<_>>();
        let mut messages = Vec::with_capacity(expired_active.len());
        for key in expired_active {
            let transfer_id = self
                .transfers
                .get(&key)
                .map(|transfer| transfer.metadata.transfer_id.clone())
                .ok_or_else(|| anyhow!("idle inbound transfer disappeared"))?;
            self.abort_transfer(&key)
                .await
                .context("failed to clean idle inbound staging file")?;
            messages.push(error_message(
                transfer_id,
                None,
                "inbound file transfer timed out",
            ));
        }
        Ok(messages)
    }

    async fn abort_all(&mut self) -> Result<()> {
        self.pending.clear();
        let transfer_ids = self.transfers.keys().copied().collect::<Vec<_>>();
        let mut failures = Vec::new();
        for transfer_id in transfer_ids {
            if let Err(error) = self.abort_transfer(&transfer_id).await {
                failures.push(error.to_string());
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            bail!(
                "failed to clean one or more inbound file transfers: {}",
                failures.join("; ")
            )
        }
    }
}

fn received_bytes_through(metadata: &CrossNetworkFileMetadataV1, index: u32) -> Result<u64> {
    if index >= metadata.total_chunks {
        bail!("chunk index exceeded metadata");
    }
    Ok(u64::from(index + 1)
        .checked_mul(u64::from(metadata.chunk_size))
        .ok_or_else(|| anyhow!("chunk acknowledgement byte count overflow"))?
        .min(metadata.file_size))
}

fn error_message(
    transfer_id: CrossNetworkTransferId,
    chunk_index: Option<u32>,
    message: &'static str,
) -> CrossNetworkFileTransferMessageV1 {
    CrossNetworkFileTransferMessageV1::Error {
        transfer_id,
        chunk_index,
        message: message.to_owned(),
    }
}

#[cfg(test)]
struct InboundTransfer {
    total_size: u64,
    expected_sha256: [u8; 32],
    reservation: InboundStorageReservation,
    final_name: String,
    file: File,
    hasher: Sha256,
    received_bytes: u64,
    expected_next_seq: u32,
    last_progress_at: Instant,
}

#[cfg(test)]
struct LegacyFileReceiver {
    session_id: String,
    store: Arc<InboundFileStore>,
    transfers: HashMap<[u8; 16], InboundTransfer>,
}

#[cfg(test)]
impl LegacyFileReceiver {
    fn new(session_id: String, store: Arc<InboundFileStore>) -> Self {
        Self {
            session_id,
            store,
            transfers: HashMap::new(),
        }
    }

    /// Handle an inbound offer/chunk; returns outbound plaintext frames to send.
    async fn handle_frame(&mut self, frame: FileAppFrame) -> Result<Vec<Vec<u8>>> {
        match frame {
            FileAppFrame::Offer {
                transfer_id,
                total_size,
                chunk_size,
                expected_sha256,
                filename,
            } => {
                self.on_offer(
                    transfer_id,
                    total_size,
                    chunk_size,
                    expected_sha256,
                    &filename,
                )
                .await
            }
            FileAppFrame::Chunk {
                transfer_id,
                sequence,
                payload,
            } => self.on_chunk(transfer_id, sequence, &payload).await,
            // Receipts/acks are sender-directed; the coordinator never routes
            // them here, but stay total and ignore defensively.
            FileAppFrame::Receipt { .. } | FileAppFrame::ChunkAck { .. } => Ok(Vec::new()),
        }
    }

    async fn on_offer(
        &mut self,
        transfer_id: [u8; 16],
        total_size: u64,
        chunk_size: u32,
        expected_sha256: [u8; 32],
        filename: &str,
    ) -> Result<Vec<Vec<u8>>> {
        if chunk_size != CHUNK_PAYLOAD_BYTES as u32 {
            return Ok(vec![receipt_err(&transfer_id)?]);
        }
        if total_size > MAX_TRANSFER_BYTES {
            return Ok(vec![receipt_err(&transfer_id)?]);
        }
        if self.transfers.contains_key(&transfer_id) {
            return Ok(vec![receipt_err(&transfer_id)?]);
        }
        let Some(final_name) = sanitize_filename(filename) else {
            return Ok(vec![receipt_err(&transfer_id)?]);
        };

        let (reservation, file) = match self
            .store
            .reserve(&self.session_id, &transfer_id, total_size)
            .await
        {
            Ok(Some(reservation)) => reservation,
            Ok(None) => return Ok(vec![receipt_err(&transfer_id)?]),
            Err(error) => {
                warn!(
                    kind = "agent.file_transfer.receive_storage_admission_failed",
                    session_id = %self.session_id,
                    error = %error,
                    "failed to admit inbound transfer into bounded storage"
                );
                return Ok(vec![receipt_err(&transfer_id)?]);
            }
        };

        self.transfers.insert(
            transfer_id,
            InboundTransfer {
                total_size,
                expected_sha256,
                reservation,
                final_name,
                file,
                hasher: Sha256::new(),
                received_bytes: 0,
                expected_next_seq: 0,
                last_progress_at: Instant::now(),
            },
        );
        if total_size == 0 {
            return self.finalize_transfer(&transfer_id).await;
        }
        Ok(Vec::new())
    }

    async fn on_chunk(
        &mut self,
        transfer_id: [u8; 16],
        sequence: u32,
        payload: &[u8],
    ) -> Result<Vec<Vec<u8>>> {
        let Some(transfer) = self.transfers.get_mut(&transfer_id) else {
            // Chunk before offer / for a closed transfer: drop (no state to write).
            debug!(
                kind = "agent.file_transfer.chunk_without_offer",
                "dropping orphan chunk"
            );
            return Ok(Vec::new());
        };

        if sequence != transfer.expected_next_seq {
            return self.abort_with_error_receipt(&transfer_id).await;
        }
        let Some(remaining_bytes) = transfer.total_size.checked_sub(transfer.received_bytes) else {
            return self.abort_with_error_receipt(&transfer_id).await;
        };
        let expected_payload_len = remaining_bytes.min(CHUNK_PAYLOAD_BYTES as u64) as usize;
        if payload.len() != expected_payload_len {
            return self.abort_with_error_receipt(&transfer_id).await;
        }
        let Some(next_received_bytes) = transfer.received_bytes.checked_add(payload.len() as u64)
        else {
            return self.abort_with_error_receipt(&transfer_id).await;
        };
        let Some(next_sequence) = transfer.expected_next_seq.checked_add(1) else {
            return self.abort_with_error_receipt(&transfer_id).await;
        };

        if let Err(error) = transfer.file.write_all(payload).await {
            warn!(
                kind = "agent.file_transfer.receive_write_failed",
                error = %error,
                "failed to write inbound file chunk; aborting transfer"
            );
            return self.abort_with_error_receipt(&transfer_id).await;
        }
        transfer.hasher.update(payload);
        transfer.received_bytes = next_received_bytes;
        transfer.expected_next_seq = next_sequence;
        transfer.last_progress_at = Instant::now();

        if transfer.received_bytes == transfer.total_size {
            return self.finalize_transfer(&transfer_id).await;
        }
        if transfer.expected_next_seq.is_multiple_of(ACK_EVERY_CHUNKS) {
            return Ok(vec![file_transfer_frame::encode_chunk_ack(
                &transfer_id,
                transfer.expected_next_seq - 1,
            )]);
        }
        Ok(Vec::new())
    }

    async fn finalize_transfer(&mut self, transfer_id: &[u8; 16]) -> Result<Vec<Vec<u8>>> {
        let Some(transfer) = self.transfers.remove(transfer_id) else {
            return Ok(Vec::new());
        };
        let InboundTransfer {
            expected_sha256,
            reservation,
            final_name,
            mut file,
            hasher,
            received_bytes,
            ..
        } = transfer;

        if let Err(error) = file.flush().await {
            drop(file);
            self.finalize_with_error_receipt(transfer_id, reservation, error.into(), false)
                .await?;
            return Ok(vec![receipt_err(transfer_id)?]);
        }
        if let Err(error) = file.sync_all().await {
            drop(file);
            self.finalize_with_error_receipt(transfer_id, reservation, error.into(), false)
                .await?;
            return Ok(vec![receipt_err(transfer_id)?]);
        }
        drop(file);

        let computed: [u8; 32] = hasher.finalize().into();
        if computed != expected_sha256 {
            self.finalize_with_error_receipt(
                transfer_id,
                reservation,
                anyhow!("inbound SHA-256 did not match the advertised digest"),
                false,
            )
            .await?;
            return Ok(vec![receipt_err(transfer_id)?]);
        }

        match self.store.place(&reservation, &final_name).await {
            Ok(final_path) => {
                self.store
                    .commit(reservation)
                    .await
                    .context("failed to commit verified inbound storage accounting")?;
                info!(
                    kind = "agent.file_transfer.received",
                    bytes = received_bytes,
                    receipt_verified = true,
                    "inbound file transfer verified and stored"
                );
                debug!(
                    kind = "agent.file_transfer.received_path",
                    path = %final_path.display(),
                    "stored received file"
                );
                Ok(vec![file_transfer_frame::encode_receipt(
                    transfer_id,
                    true,
                    &computed,
                    "",
                )?])
            }
            Err(failure) => {
                self.finalize_with_error_receipt(
                    transfer_id,
                    reservation,
                    failure.error,
                    failure.destination_may_exist,
                )
                .await?;
                Ok(vec![receipt_err(transfer_id)?])
            }
        }
    }

    async fn finalize_with_error_receipt(
        &self,
        transfer_id: &[u8; 16],
        reservation: InboundStorageReservation,
        error: anyhow::Error,
        destination_may_exist: bool,
    ) -> Result<()> {
        let cleanup_result = if destination_may_exist {
            let staging_cleanup = remove_file_if_present(&reservation.temp_path).await;
            let accounting_commit = self.store.commit(reservation).await;
            match (staging_cleanup, accounting_commit) {
                (Ok(()), Ok(())) => Ok(()),
                (Err(cleanup_error), Ok(())) => Err(cleanup_error)
                    .context("failed to clean ambiguous inbound staging link"),
                (Ok(()), Err(accounting_error)) => Err(accounting_error)
                    .context("failed to account ambiguous received destination"),
                (Err(cleanup_error), Err(accounting_error)) => Err(accounting_error).context(
                    format!(
                        "failed to account ambiguous received destination and staging cleanup also failed: {cleanup_error:#}"
                    ),
                ),
            }
        } else {
            self.store
                .discard(reservation)
                .await
                .context("failed to clean inbound staging after finalization failure")
        };
        warn!(
            kind = "agent.file_transfer.receive_finalize_failed",
            transfer_id = %hex16(transfer_id),
            error = %error,
            "inbound file finalization failed; returning an error receipt"
        );
        cleanup_result.with_context(|| {
            format!(
                "inbound finalization failed and cleanup/accounting did not converge: {error:#}"
            )
        })
    }

    async fn abort_transfer(&mut self, transfer_id: &[u8; 16]) -> Result<()> {
        if let Some(transfer) = self.transfers.remove(transfer_id) {
            drop(transfer.file);
            self.store.discard(transfer.reservation).await?;
        }
        Ok(())
    }

    async fn abort_with_error_receipt(&mut self, transfer_id: &[u8; 16]) -> Result<Vec<Vec<u8>>> {
        self.abort_transfer(transfer_id)
            .await
            .context("failed to clean inbound staging file while aborting transfer")?;
        Ok(vec![receipt_err(transfer_id)?])
    }

    async fn expire_idle_transfers(&mut self, now: Instant) -> Result<Vec<Vec<u8>>> {
        let expired = self
            .transfers
            .iter()
            .filter_map(|(transfer_id, transfer)| {
                now.checked_duration_since(transfer.last_progress_at)
                    .is_some_and(|idle| idle >= RECEIVER_IDLE_TIMEOUT)
                    .then_some(*transfer_id)
            })
            .collect::<Vec<_>>();
        let mut receipts = Vec::with_capacity(expired.len());
        for transfer_id in expired {
            self.abort_transfer(&transfer_id)
                .await
                .context("failed to clean idle inbound staging file")?;
            receipts.push(receipt_err(&transfer_id)?);
        }
        Ok(receipts)
    }

    async fn abort_all(&mut self) -> Result<()> {
        let transfer_ids = self.transfers.keys().copied().collect::<Vec<_>>();
        let mut failures = Vec::new();
        for transfer_id in transfer_ids {
            if let Err(error) = self.abort_transfer(&transfer_id).await {
                failures.push(error.to_string());
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            bail!(
                "failed to clean one or more inbound file transfers: {}",
                failures.join("; ")
            )
        }
    }
}

#[cfg(test)]
fn receipt_err(transfer_id: &[u8; 16]) -> Result<Vec<u8>> {
    file_transfer_frame::encode_receipt(transfer_id, false, &[0u8; 32], "transfer rejected")
}

fn receive_capacity_allows(
    stored: ReceivedStorageUsage,
    inflight_bytes: u64,
    inflight_files: usize,
    offered_bytes: u64,
) -> bool {
    let Some(next_inflight) = inflight_bytes.checked_add(offered_bytes) else {
        return false;
    };
    if next_inflight > MAX_TOTAL_INFLIGHT_BYTES {
        return false;
    }
    let files_allowed = stored
        .files
        .checked_add(inflight_files)
        .and_then(|files| files.checked_add(1))
        .is_some_and(|files| files <= MAX_RECEIVED_FILES);
    files_allowed
        && stored
            .bytes
            .checked_add(next_inflight)
            .is_some_and(|total| total <= MAX_RECEIVED_STORAGE_BYTES)
}

async fn remove_file_if_present(path: &Path) -> Result<()> {
    // Windows filters (Defender, indexers) briefly hold freshly written
    // files, so a first deletion attempt can fail with a sharing violation
    // or access denied even though nothing durable owns the file. Retry for
    // a bounded window before treating the deletion as failed; on unix the
    // first attempt is always authoritative and the loop exits immediately.
    const ERROR_SHARING_VIOLATION: i32 = 32;
    let mut last_error = None;
    for _ in 0..40 {
        match tokio::fs::remove_file(path).await {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error)
                if cfg!(windows)
                    && (error.kind() == std::io::ErrorKind::PermissionDenied
                        || error.raw_os_error() == Some(ERROR_SHARING_VIOLATION)) =>
            {
                last_error = Some(error);
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            }
            Err(error) => {
                return Err(error).context("failed to remove file-transfer staging file");
            }
        }
    }
    Err(last_error.map_or_else(
        || anyhow!("file removal retries exhausted without a recorded error"),
        anyhow::Error::from,
    ))
    .context("failed to remove file-transfer staging file after bounded sharing retries")
}

/// Atomically place the verified temp file under a collision-free name in
/// `received_dir` with no-replace hard-link semantics.
async fn place_received_file(
    received_dir: &Path,
    temp_path: &Path,
    final_name: &str,
    inject_directory_sync_failure: bool,
) -> std::result::Result<PathBuf, ReceivedPlacementFailure> {
    let (stem, extension) = split_name(final_name);
    for attempt in 0..MAX_NAME_COLLISION_ATTEMPTS {
        let candidate_name = collision_candidate_name(final_name, &stem, &extension, attempt);
        let candidate = received_dir.join(&candidate_name);
        // Creating a hard link is an atomic, cross-platform no-replace
        // operation when staging and destination share this directory's
        // filesystem. Unlike reserve-then-rename it works on Windows, where
        // rename correctly rejects the already-reserved destination.
        match tokio::fs::hard_link(temp_path, &candidate).await {
            Ok(()) => match remove_file_if_present(temp_path).await {
                Ok(()) => match if inject_directory_sync_failure {
                    Err(anyhow!("injected received directory sync failure"))
                } else {
                    sync_received_directory_metadata(received_dir).await
                } {
                    Ok(()) => return Ok(candidate),
                    Err(sync_error) => {
                        return Err(ReceivedPlacementFailure {
                            error: sync_error.context(
                                "received destination exists but its directory entry durability could not be established",
                            ),
                            destination_may_exist: true,
                        });
                    }
                },
                Err(unlink_error) => {
                    let rollback = remove_file_if_present(&candidate).await;
                    return match rollback {
                        Ok(()) => Err(ReceivedPlacementFailure {
                            error: unlink_error.context(
                                "failed to unlink staged received file after atomic no-replace placement",
                            ),
                            destination_may_exist: false,
                        }),
                        Err(rollback_error) => Err(ReceivedPlacementFailure {
                            error: unlink_error.context(format!(
                                "failed to unlink staged received file and destination rollback also failed: {rollback_error:#}"
                            )),
                            destination_may_exist: true,
                        }),
                    };
                }
            },
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(ReceivedPlacementFailure {
                    error: anyhow!(error)
                        .context("failed atomic no-replace received-file placement"),
                    destination_may_exist: false,
                });
            }
        }
    }
    Err(ReceivedPlacementFailure {
        error: anyhow!("too many received-file name collisions"),
        destination_may_exist: false,
    })
}

async fn sync_received_directory_metadata(path: &Path) -> Result<()> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        #[cfg(unix)]
        let directory = std::fs::File::open(&path)
            .with_context(|| format!("failed to open {} for directory sync", path.display()))?;

        #[cfg(windows)]
        let directory = {
            use std::os::windows::fs::OpenOptionsExt;
            const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
            std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
                .open(&path)
                .with_context(|| format!("failed to open {} for directory sync", path.display()))?
        };

        directory
            .sync_all()
            .with_context(|| format!("failed to sync received directory {}", path.display()))
    })
    .await
    .context("received directory sync task panicked")?
}

fn collision_candidate_name(final_name: &str, stem: &str, extension: &str, attempt: u32) -> String {
    if attempt == 0 {
        return final_name.to_owned();
    }
    let suffix = format!(" ({attempt})");
    if extension.is_empty() {
        let stem = truncate_utf8(stem, MAX_FILENAME_LEN - suffix.len());
        return format!("{stem}{suffix}");
    }

    // Preserve at least one byte of stem. Very long extensions are truncated
    // before the stem so the auto-suffixed component always remains <=255
    // bytes on common filesystems.
    let max_extension_bytes = MAX_FILENAME_LEN - suffix.len() - 2;
    let extension = truncate_utf8(extension, max_extension_bytes);
    let max_stem_bytes = MAX_FILENAME_LEN - suffix.len() - 1 - extension.len();
    let stem = truncate_utf8(stem, max_stem_bytes);
    format!("{stem}{suffix}.{extension}")
}

fn truncate_utf8(value: &str, max_bytes: usize) -> &str {
    let mut end = value.len().min(max_bytes);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    &value[..end]
}

fn split_name(name: &str) -> (String, String) {
    match name.rfind('.') {
        Some(index) if index > 0 && index + 1 < name.len() => {
            (name[..index].to_owned(), name[index + 1..].to_owned())
        }
        _ => (name.to_owned(), String::new()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("skybridge-ft-{tag}-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        dir
    }

    fn sha256(bytes: &[u8]) -> [u8; 32] {
        Sha256::digest(bytes).into()
    }

    fn sha256_hex(bytes: &[u8]) -> String {
        sha256(bytes)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    fn send_request(source: &Path, bytes: &[u8]) -> FileTransferControlRequest {
        FileTransferControlRequest::pending_send(
            "request-snapshot",
            "session-snapshot",
            "runtime-snapshot",
            skybridge_core::FileTransferSourceSnapshot {
                source_path: source.display().to_string(),
                size_bytes: bytes.len() as u64,
                sha256_hex: sha256_hex(bytes),
            },
            skybridge_core::FileTransferDestinationBinding {
                requested_peer_ref: "peer".to_owned(),
                remote_device_id: "peer".to_owned(),
                remote_protocol_public_key_fingerprint: "fingerprint".to_owned(),
            },
        )
    }

    async fn test_authority(paths: &AgentPaths) -> RuntimeIncarnationAuthority {
        crate::state::upsert_session_runtime(
            paths,
            skybridge_core::RuntimeSessionRecord::new(
                "runtime-snapshot",
                "session-snapshot",
                skybridge_core::RuntimeSessionRole::Initiator,
                skybridge_core::RuntimeSessionSource::Code,
                "https://signal.example.com",
                "local-device",
                None,
                None,
                None,
                skybridge_core::RuntimeSessionState::Connecting,
            ),
        )
        .await
        .expect("seed runtime session authority");
        crate::state::upsert_managed_session_control(
            paths,
            skybridge_core::ManagedSessionControl::new(
                "session-snapshot",
                skybridge_core::RuntimeSessionRole::Initiator,
                skybridge_core::RuntimeSessionSource::Code,
                "local-device",
                "https://signal.example.com",
                "test-token",
                None,
            ),
        )
        .await
        .expect("seed managed session authority");
        RuntimeIncarnationAuthority::new(
            paths.clone(),
            "session-snapshot".to_owned(),
            "runtime-snapshot".to_owned(),
            CancellationToken::new(),
        )
    }

    async fn test_receiver(dir: &Path, session_id: &str) -> LegacyFileReceiver {
        let store = Arc::new(
            InboundFileStore::initialize(dir.to_path_buf())
                .await
                .expect("initialize test inbound storage"),
        );
        LegacyFileReceiver::new(session_id.to_owned(), store)
    }

    async fn test_cross_network_receiver(dir: &Path, session_id: &str) -> FileReceiver {
        let store = Arc::new(
            InboundFileStore::initialize(dir.to_path_buf())
                .await
                .expect("initialize cross-network inbound storage"),
        );
        FileReceiver::new(session_id.to_owned(), store)
    }

    fn cross_network_id(seed: u128) -> CrossNetworkTransferId {
        CrossNetworkTransferId::parse(uuid::Uuid::from_u128(seed).hyphenated().to_string())
            .expect("non-nil test transfer id")
    }

    fn cross_network_metadata(
        transfer_id: CrossNetworkTransferId,
        file_name: &str,
        file_size: u64,
    ) -> CrossNetworkFileMetadataV1 {
        CrossNetworkFileMetadataV1 {
            transfer_id,
            sender_device_id: Some("ios-device".to_owned()),
            sender_device_name: Some("iPhone".to_owned()),
            file_name: file_name.to_owned(),
            file_size,
            chunk_size: CHUNK_PAYLOAD_BYTES as u32,
            total_chunks: cross_network_total_chunks(file_size, CHUNK_PAYLOAD_BYTES as u32)
                .expect("test chunk plan"),
            mime_type: None,
        }
    }

    fn cross_network_chunk(
        transfer_id: CrossNetworkTransferId,
        chunk_index: u32,
        bytes: &[u8],
    ) -> CrossNetworkFileChunkV1 {
        CrossNetworkFileChunkV1 {
            transfer_id,
            chunk_index,
            chunk_data: bytes.to_vec(),
            chunk_sha256: sha256(bytes),
            raw_size: bytes.len() as u32,
        }
    }

    #[tokio::test]
    async fn cross_network_metadata_requires_explicit_approval_before_staging_or_ack() {
        let dir = temp_dir("crossnet-approval");
        let mut receiver = test_cross_network_receiver(&dir, "session-approval").await;
        let metadata = cross_network_metadata(cross_network_id(1), "approved.bin", 4);

        let outbound = receiver
            .handle_authenticated_metadata(
                metadata.clone(),
                "ios-device".to_owned(),
                "Authenticated iPhone".to_owned(),
            )
            .await
            .expect("queue metadata approval");
        assert!(
            outbound.is_empty(),
            "pending approval must not ACK metadata"
        );
        assert!(receiver.transfers.is_empty());
        assert_eq!(receiver.pending.len(), 1);
        let usage = receiver.store.usage().await;
        assert_eq!(usage.reserved_bytes, 0);
        assert_eq!(usage.reserved_files, 0);
        assert!(
            std::fs::read_dir(&receiver.store.staging_dir)
                .expect("read staging")
                .next()
                .is_none(),
            "pending approval must not create staging bytes"
        );

        let approved = receiver
            .approve_pending(&metadata.transfer_id)
            .await
            .expect("approve metadata");
        assert!(matches!(
            approved.as_slice(),
            [CrossNetworkFileTransferMessageV1::MetadataAck { .. }]
        ));
        assert!(receiver.pending.is_empty());
        assert_eq!(receiver.transfers.len(), 1);
        let usage = receiver.store.usage().await;
        assert_eq!(usage.reserved_bytes, 4);
        assert_eq!(usage.reserved_files, 1);
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn cross_network_complete_ack_is_durable_and_replayed_after_restart() {
        let dir = temp_dir("crossnet-durable-receipt");
        let session_id = "session-durable";
        let transfer_id = cross_network_id(2);
        let bytes = b"data";
        let metadata = cross_network_metadata(transfer_id.clone(), "durable.bin", 4);
        let mut receiver = test_cross_network_receiver(&dir, session_id).await;
        receiver
            .handle_authenticated_metadata(
                metadata.clone(),
                "ios-device".to_owned(),
                "Authenticated iPhone".to_owned(),
            )
            .await
            .expect("queue metadata");
        receiver
            .approve_pending(&transfer_id)
            .await
            .expect("approve transfer");

        let chunk_ack = receiver
            .handle_message(CrossNetworkFileTransferMessageV1::Chunk(
                cross_network_chunk(transfer_id.clone(), 0, bytes),
            ))
            .await
            .expect("write chunk");
        assert!(matches!(
            chunk_ack.as_slice(),
            [CrossNetworkFileTransferMessageV1::ChunkAck(
                CrossNetworkFileChunkAckV1::Received { .. }
            )]
        ));
        assert!(
            !dir.join("durable.bin").exists(),
            "last chunk must not commit before complete"
        );

        let completion = CrossNetworkFileCompletionV1 {
            transfer_id: transfer_id.clone(),
            received_bytes: 4,
            file_sha256: sha256(bytes),
        };
        let completed = receiver
            .handle_message(CrossNetworkFileTransferMessageV1::Complete(
                completion.clone(),
            ))
            .await
            .expect("commit transfer");
        assert_eq!(
            completed,
            vec![CrossNetworkFileTransferMessageV1::CompleteAck(
                completion.clone()
            )]
        );
        assert_eq!(
            std::fs::read(dir.join("durable.bin")).expect("saved file"),
            bytes
        );
        drop(receiver);

        let mut restarted = test_cross_network_receiver(&dir, session_id).await;
        let replayed = restarted
            .handle_message(CrossNetworkFileTransferMessageV1::Complete(
                completion.clone(),
            ))
            .await
            .expect("replay durable receipt");
        assert_eq!(
            replayed,
            vec![CrossNetworkFileTransferMessageV1::CompleteAck(completion)]
        );
        assert!(restarted.pending.is_empty());
        assert!(restarted.transfers.is_empty());
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn cross_network_wrong_chunk_hash_aborts_without_success_receipt() {
        let dir = temp_dir("crossnet-wrong-hash");
        let transfer_id = cross_network_id(3);
        let metadata = cross_network_metadata(transfer_id.clone(), "bad.bin", 4);
        let mut receiver = test_cross_network_receiver(&dir, "session-wrong-hash").await;
        receiver
            .handle_authenticated_metadata(
                metadata,
                "ios-device".to_owned(),
                "Authenticated iPhone".to_owned(),
            )
            .await
            .expect("queue metadata");
        receiver
            .approve_pending(&transfer_id)
            .await
            .expect("approve transfer");
        let mut chunk = cross_network_chunk(transfer_id, 0, b"data");
        chunk.chunk_sha256 = sha256(b"evil");
        let outbound = receiver
            .handle_message(CrossNetworkFileTransferMessageV1::Chunk(chunk))
            .await
            .expect("reject forged chunk");
        assert!(matches!(
            outbound.as_slice(),
            [CrossNetworkFileTransferMessageV1::Error { .. }]
        ));
        assert!(receiver.transfers.is_empty());
        assert!(!dir.join("bad.bin").exists());
        assert_eq!(receiver.store.usage().await.reserved_files, 0);
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn cross_network_rejection_discards_pending_without_allocating_storage() {
        let dir = temp_dir("crossnet-reject");
        let transfer_id = cross_network_id(4);
        let metadata = cross_network_metadata(transfer_id.clone(), "reject.bin", 4);
        let mut receiver = test_cross_network_receiver(&dir, "session-reject").await;
        receiver
            .handle_authenticated_metadata(
                metadata,
                "ios-device".to_owned(),
                "Authenticated iPhone".to_owned(),
            )
            .await
            .expect("queue metadata");
        let rejected = receiver
            .reject_pending(&transfer_id)
            .expect("reject pending transfer");
        assert!(matches!(
            rejected.as_slice(),
            [CrossNetworkFileTransferMessageV1::Error { .. }]
        ));
        assert!(receiver.pending.is_empty());
        assert!(receiver.transfers.is_empty());
        let usage = receiver.store.usage().await;
        assert_eq!(usage.reserved_bytes, 0);
        assert_eq!(usage.reserved_files, 0);
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn terminal_receipt_capacity_is_reserved_before_staging_or_placement() {
        let dir = temp_dir("crossnet-receipt-capacity");
        let transfer_id = cross_network_id(5);
        let metadata = cross_network_metadata(transfer_id.clone(), "capacity.bin", 4);
        let mut receiver = test_cross_network_receiver(&dir, "session-capacity").await;
        receiver.store.state.lock().await.terminal_receipts = MAX_TERMINAL_RECEIPTS;
        receiver
            .handle_authenticated_metadata(
                metadata,
                "ios-device".to_owned(),
                "Authenticated iPhone".to_owned(),
            )
            .await
            .expect("queue metadata");
        let response = receiver
            .approve_pending(&transfer_id)
            .await
            .expect("capacity rejection is a protocol response");
        assert!(matches!(
            response.as_slice(),
            [CrossNetworkFileTransferMessageV1::Error { .. }]
        ));
        let usage = receiver.store.usage().await;
        assert_eq!(usage.reserved_files, 0);
        assert_eq!(usage.reserved_terminal_receipts, 0);
        assert!(receiver.transfers.is_empty());
        assert!(
            std::fs::read_dir(&receiver.store.staging_dir)
                .expect("read staging")
                .next()
                .is_none()
        );
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn self_reported_sender_identity_cannot_override_authenticated_peer() {
        let dir = temp_dir("crossnet-peer-spoof");
        let transfer_id = cross_network_id(6);
        let mut metadata = cross_network_metadata(transfer_id, "spoof.bin", 4);
        metadata.sender_device_id = Some("attacker-device".to_owned());
        metadata.sender_device_name = Some("Trusted Looking Name".to_owned());
        let mut receiver = test_cross_network_receiver(&dir, "session-spoof").await;
        let error = receiver
            .handle_authenticated_metadata(
                metadata,
                "ios-device".to_owned(),
                "Authenticated iPhone".to_owned(),
            )
            .await
            .expect_err("spoofed senderDeviceId must fail before pending admission");
        assert!(error.to_string().contains("authenticated peer"));
        assert!(receiver.pending.is_empty());
        assert!(receiver.transfers.is_empty());
        let usage = receiver.store.usage().await;
        assert_eq!(usage.reserved_files, 0);
        assert_eq!(usage.reserved_terminal_receipts, 0);
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn authenticated_peer_rename_does_not_change_pending_transfer_authority() {
        let dir = temp_dir("crossnet-peer-rename");
        let transfer_id = cross_network_id(7);
        let metadata = cross_network_metadata(transfer_id.clone(), "rename.bin", 4);
        let mut receiver = test_cross_network_receiver(&dir, "session-peer-rename").await;
        receiver
            .handle_authenticated_metadata(
                metadata.clone(),
                "ios-device".to_owned(),
                "Old Authenticated Name".to_owned(),
            )
            .await
            .expect("queue metadata before peer rename");

        let duplicate = receiver
            .preflight_authenticated_metadata(
                metadata,
                "ios-device",
                "Renamed Authenticated Device",
            )
            .await
            .expect("peer display rename is not a transfer authority change")
            .expect("duplicate pending metadata is handled in preflight");
        assert!(
            duplicate.is_empty(),
            "pending metadata must remain unacknowledged"
        );
        assert_eq!(receiver.pending.len(), 1);
        let approved = receiver
            .approve_pending(&transfer_id)
            .await
            .expect("approval remains bound to the stable peer id");
        assert!(matches!(
            approved.as_slice(),
            [CrossNetworkFileTransferMessageV1::MetadataAck { .. }]
        ));
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn active_idle_timeout_does_not_expire_pending_approval_authority() {
        let dir = temp_dir("crossnet-pending-timeout-authority");
        let transfer_id = cross_network_id(8);
        let metadata = cross_network_metadata(transfer_id.clone(), "pending-timeout.bin", 4);
        let mut receiver =
            test_cross_network_receiver(&dir, "session-pending-timeout-authority").await;
        receiver
            .handle_authenticated_metadata(
                metadata,
                "ios-device".to_owned(),
                "Authenticated iPhone".to_owned(),
            )
            .await
            .expect("queue pending metadata");

        let messages = receiver
            .expire_idle_transfers(Instant::now() + RECEIVER_IDLE_TIMEOUT + Duration::from_secs(1))
            .await
            .expect("run active-transfer idle timeout");
        assert!(messages.is_empty());
        assert_eq!(receiver.pending.len(), 1);
        let rejected = receiver
            .reject_pending(&transfer_id)
            .expect("persistent approval decision remains the pending timeout authority");
        assert!(matches!(
            rejected.as_slice(),
            [CrossNetworkFileTransferMessageV1::Error { .. }]
        ));
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test]
    async fn fifth_and_later_metadata_frames_fail_preflight_without_pending_pollution() {
        let dir = temp_dir("crossnet-pending-capacity");
        let mut receiver = test_cross_network_receiver(&dir, "session-pending-capacity").await;
        for seed in 10..14 {
            receiver
                .handle_authenticated_metadata(
                    cross_network_metadata(cross_network_id(seed), "pending.bin", 4),
                    "ios-device".to_owned(),
                    "Authenticated iPhone".to_owned(),
                )
                .await
                .expect("admit bounded pending metadata");
        }
        assert_eq!(receiver.pending.len(), MAX_PENDING_RECEIVE_APPROVALS);
        for seed in 14..138 {
            let response = receiver
                .preflight_authenticated_metadata(
                    cross_network_metadata(cross_network_id(seed), "overflow.bin", 4),
                    "ios-device",
                    "Authenticated iPhone",
                )
                .await
                .expect("capacity rejection is a protocol response")
                .expect("fifth and later frames must be rejected before durable registration");
            assert!(matches!(
                response.as_slice(),
                [CrossNetworkFileTransferMessageV1::Error { .. }]
            ));
        }
        assert_eq!(receiver.pending.len(), MAX_PENDING_RECEIVE_APPROVALS);
        assert!(receiver.transfers.is_empty());
        assert_eq!(receiver.store.usage().await.reserved_files, 0);
        std::fs::remove_dir_all(dir).ok();
    }

    fn assert_receipt_status(plaintext: &[u8], expected_ok: bool) {
        match file_transfer_frame::decode_file_app_frame(plaintext).expect("decode receipt") {
            FileAppFrame::Receipt { ok, .. } => assert_eq!(ok, expected_ok),
            other => panic!("expected receipt, got {other:?}"),
        }
    }

    #[test]
    fn sender_receipt_requires_exact_source_digest() {
        let expected = sha256(b"source bytes");
        let forged = sha256(b"forged bytes");

        assert_eq!(
            finalize_receipt(true, &expected, &expected, 12, 12).expect("matching receipt"),
            12
        );
        assert!(
            finalize_receipt(true, &forged, &expected, 12, 12).is_err(),
            "ok=true with a different digest must not complete the transfer"
        );
        assert!(
            finalize_receipt(false, &expected, &expected, 12, 12).is_err(),
            "receiver rejection must stay a failed transfer even if the digest matches"
        );
        assert!(
            finalize_receipt(true, &expected, &expected, 11, 12).is_err(),
            "an early receipt must not complete a partial transfer"
        );
    }

    #[test]
    fn sender_rejects_acknowledgements_for_unsent_chunks() {
        let mut acked_through = None;
        assert!(apply_ack(0, &mut acked_through, 0).is_err());
        assert!(apply_ack(2, &mut acked_through, 2).is_err());
        apply_ack(2, &mut acked_through, 1).expect("sent chunk may be acknowledged");
        assert_eq!(acked_through, Some(1));
        apply_ack(2, &mut acked_through, 0).expect("stale acknowledgement is harmless");
        assert_eq!(acked_through, Some(1));
    }

    #[tokio::test]
    async fn tracked_file_send_worker_is_cancelled_and_awaited() {
        let cancel = CancellationToken::new();
        let task_cancel = cancel.clone();
        let handle = tokio::spawn(async move {
            task_cancel.cancelled().await;
            Ok(())
        });
        let worker = FileSendWorker { cancel, handle };
        worker.cancel();
        worker.join().await.expect("cancelled worker should join");
    }

    #[test]
    fn legacy_offline_sender_harness_remains_compilable_during_wire_cutover() {
        let _legacy_sender = run_file_send_transfer;
    }

    #[tokio::test]
    async fn sender_copies_queued_bytes_to_private_snapshot_before_offer() {
        let dir = temp_dir("source-snapshot");
        let source = dir.join("payload.bin");
        let queued_bytes = b"queued bytes";
        tokio::fs::write(&source, queued_bytes)
            .await
            .expect("write source");
        let paths = super::super::resolve_paths(Some(dir.join("state"))).expect("paths");
        let request = send_request(&source, queued_bytes);
        let expected = sha256(queued_bytes);
        let authority = test_authority(&paths).await;
        let mut snapshot = prepare_source_snapshot(
            &paths,
            &request,
            &expected,
            &CancellationToken::new(),
            &authority,
        )
        .await
        .expect("matching source snapshot");
        let snapshot_path = snapshot.path.clone();

        tokio::fs::write(&source, b"other bytes!")
            .await
            .expect("replace source after snapshot");
        let mut observed = Vec::new();
        snapshot
            .file_mut()
            .expect("snapshot file")
            .read_to_end(&mut observed)
            .await
            .expect("read snapshot");
        assert_eq!(observed, queued_bytes);

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&snapshot_path)
                    .expect("snapshot metadata")
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }

        snapshot.cleanup().await.expect("snapshot cleanup");
        assert!(!snapshot_path.exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn sender_rejects_protocol_oversize_before_creating_private_snapshot() {
        let dir = temp_dir("source-snapshot-oversize");
        let source = dir.join("payload.bin");
        tokio::fs::write(&source, b"small source")
            .await
            .expect("write source");
        let paths = super::super::resolve_paths(Some(dir.join("state"))).expect("paths");
        let mut request = send_request(&source, b"small source");
        request.source.size_bytes = MAX_TRANSFER_BYTES + 1;
        let authority = test_authority(&paths).await;
        let result = prepare_source_snapshot(
            &paths,
            &request,
            &sha256(b"small source"),
            &CancellationToken::new(),
            &authority,
        )
        .await;
        assert!(result.is_err());
        assert!(
            !source_snapshot_dir(&paths).exists(),
            "oversize admission must fail before allocating snapshot storage"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn sender_snapshot_mismatch_and_drop_cleanup_leave_no_private_bytes() {
        let dir = temp_dir("source-snapshot-cleanup");
        let source = dir.join("payload.bin");
        tokio::fs::write(&source, b"other bytes!")
            .await
            .expect("write changed source");
        let paths = super::super::resolve_paths(Some(dir.join("state"))).expect("paths");
        let request = send_request(&source, b"queued bytes");
        let expected = sha256(b"queued bytes");
        let authority = test_authority(&paths).await;
        assert!(
            prepare_source_snapshot(
                &paths,
                &request,
                &expected,
                &CancellationToken::new(),
                &authority,
            )
            .await
            .is_err(),
            "content mismatch must fail before the offer"
        );
        let snapshot_dir = source_snapshot_dir(&paths);
        assert_eq!(
            std::fs::read_dir(&snapshot_dir)
                .expect("snapshot dir")
                .count(),
            0,
            "failed preparation must clean its private snapshot"
        );

        tokio::fs::write(&source, b"queued bytes")
            .await
            .expect("restore queued source");
        let snapshot = prepare_source_snapshot(
            &paths,
            &request,
            &expected,
            &CancellationToken::new(),
            &authority,
        )
        .await
        .expect("prepare snapshot");
        let snapshot_path = snapshot.path.clone();
        drop(snapshot);
        assert!(!snapshot_path.exists(), "drop must remove private snapshot");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn agent_startup_rebuild_removes_stale_snapshots_and_starts_with_zero_reservations() {
        let dir = temp_dir("stale-source-snapshot");
        let paths = super::super::resolve_paths(Some(dir.clone())).expect("paths");
        let snapshot_dir = source_snapshot_dir(&paths);
        ensure_private_directory(&snapshot_dir)
            .await
            .expect("snapshot dir");
        tokio::fs::write(snapshot_dir.join("stale.snapshot"), b"private bytes")
            .await
            .expect("stale snapshot");
        let resources = OutboundTransferResources::initialize(&paths)
            .await
            .expect("startup cleanup");
        assert_eq!(
            std::fs::read_dir(snapshot_dir)
                .expect("snapshot dir")
                .count(),
            0
        );
        assert_eq!(
            resources.usage().expect("outbound resource usage"),
            OutboundResourceState::default()
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn outbound_reservations_are_global_bounded_and_release_on_all_drop_paths() {
        let dir = temp_dir("outbound-global-reservations");
        let paths = super::super::resolve_paths(Some(dir.clone())).expect("paths");
        let resources = Arc::new(
            OutboundTransferResources::initialize(&paths)
                .await
                .expect("initialize outbound resources"),
        );
        let mut reservations = Vec::new();
        for _ in 0..MAX_GLOBAL_CONCURRENT_SENDS {
            reservations.push(
                resources
                    .reserve(MAX_TRANSFER_BYTES)
                    .expect("reserve bounded outbound snapshot"),
            );
        }
        assert_eq!(
            resources.usage().expect("outbound usage"),
            OutboundResourceState {
                active_transfers: MAX_GLOBAL_CONCURRENT_SENDS,
                snapshot_files: MAX_OUTBOUND_SNAPSHOT_FILES,
                snapshot_bytes: MAX_OUTBOUND_SNAPSHOT_BYTES,
            }
        );
        assert!(resources.reserve(0).is_err());

        reservations
            .pop()
            .expect("reservation")
            .release()
            .expect("explicit success/failure release");
        let cancellation_reservation = resources
            .reserve(0)
            .expect("released capacity should be reusable");
        drop(cancellation_reservation);
        drop(reservations);
        assert_eq!(
            resources.usage().expect("released outbound usage"),
            OutboundResourceState::default(),
            "explicit completion and cancellation drop paths must release all capacity"
        );
        assert!(resources.reserve(MAX_TRANSFER_BYTES + 1).is_err());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn terminal_status_persistence_errors_are_returned_to_the_managed_session() {
        let dir = temp_dir("terminal-persist-error");
        let paths = super::super::resolve_paths(Some(dir.clone())).expect("paths");
        let source = dir.join("source.bin");
        let request = send_request(&source, b"x");

        let completion_error = persist_file_send_terminal(&paths, &request, Ok(1))
            .await
            .expect_err("missing registry request must reject completion persistence");
        assert!(
            completion_error
                .to_string()
                .contains("terminal status persistence failed")
        );

        let failure_error =
            persist_file_send_terminal(&paths, &request, Err(anyhow!("transfer cancelled")))
                .await
                .expect_err("missing registry request must reject failure persistence");
        assert!(
            failure_error
                .to_string()
                .contains("terminal failure persistence also failed")
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn sender_inbound_receipt_preserves_receiver_digest_for_local_validation() {
        let (tx, mut rx) = mpsc::channel(1);
        let computed_sha256 = sha256(b"receiver bytes");
        tx.send(FileAppFrame::Receipt {
            transfer_id: [1u8; 16],
            ok: true,
            computed_sha256,
            reason: String::new(),
        })
        .await
        .expect("send receipt");

        match wait_for_inbound(&mut rx, &CancellationToken::new())
            .await
            .expect("receipt signal")
        {
            InboundSignal::Receipt {
                ok,
                computed_sha256: observed,
            } => {
                assert!(ok);
                assert_eq!(observed, computed_sha256);
            }
            other => panic!("expected receipt signal, got {other:?}"),
        }
    }

    #[test]
    fn sanitize_filename_strips_paths_and_traversal() {
        assert_eq!(
            sanitize_filename("../../etc/passwd").as_deref(),
            Some("passwd")
        );
        assert_eq!(
            sanitize_filename("/abs/report.pdf").as_deref(),
            Some("report.pdf")
        );
        assert_eq!(sanitize_filename("plain.txt").as_deref(), Some("plain.txt"));
        assert_eq!(sanitize_filename(".."), None);
        assert_eq!(sanitize_filename("   "), None);
        assert_eq!(sanitize_filename(""), None);
    }

    #[test]
    fn receiver_capacity_bounds_bytes_and_zero_byte_file_count() {
        let almost_full = ReceivedStorageUsage {
            bytes: MAX_RECEIVED_STORAGE_BYTES - 1,
            files: 0,
        };
        assert!(receive_capacity_allows(almost_full, 0, 0, 1));
        assert!(!receive_capacity_allows(almost_full, 0, 0, 2));

        let last_file_slot = ReceivedStorageUsage {
            bytes: 0,
            files: MAX_RECEIVED_FILES - 1,
        };
        assert!(receive_capacity_allows(last_file_slot, 0, 0, 0));
        assert!(!receive_capacity_allows(
            ReceivedStorageUsage {
                bytes: 0,
                files: MAX_RECEIVED_FILES,
            },
            0,
            0,
            0,
        ));
        assert!(!receive_capacity_allows(last_file_slot, 0, 1, 0,));
    }

    #[test]
    fn collision_suffix_preserves_filesystem_component_limit() {
        let ascii_name = format!("{}.txt", "a".repeat(MAX_FILENAME_LEN - 4));
        let (stem, extension) = split_name(&ascii_name);
        let candidate = collision_candidate_name(&ascii_name, &stem, &extension, 9_999);
        assert!(candidate.len() <= MAX_FILENAME_LEN);
        assert!(candidate.ends_with(" (9999).txt"));

        let unicode_name = format!("{}.数据", "界".repeat(82));
        let (stem, extension) = split_name(&unicode_name);
        let candidate = collision_candidate_name(&unicode_name, &stem, &extension, 1);
        assert!(candidate.len() <= MAX_FILENAME_LEN);
        assert!(candidate.is_char_boundary(candidate.len()));
        assert!(candidate.ends_with(" (1).数据"));
    }

    #[tokio::test]
    async fn storage_accounting_invariant_failures_are_errors_without_partial_mutation() {
        let dir = temp_dir("accounting-invariant-errors");
        let store = InboundFileStore::initialize(dir.clone())
            .await
            .expect("initialize inbound storage");
        let before = store.usage().await;
        let release_error = store
            .release_capacity(1)
            .await
            .expect_err("unreserved capacity release must fail explicitly");
        assert!(release_error.to_string().contains("reserved-byte"));
        let commit_error = store
            .commit(InboundStorageReservation {
                total_size: 1,
                temp_path: dir.join("missing.part"),
            })
            .await
            .expect_err("unreserved commit must fail explicitly");
        assert!(commit_error.to_string().contains("reserved-byte"));
        let after = store.usage().await;
        assert_eq!(after.stored, before.stored);
        assert_eq!(after.reserved_bytes, before.reserved_bytes);
        assert_eq!(after.reserved_files, before.reserved_files);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_rejects_offer_above_per_file_limit_without_allocating_slot() {
        let dir = temp_dir("per-file-limit");
        let mut receiver = test_receiver(&dir, "session-per-file-limit").await;
        let out = receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: [2u8; 16],
                total_size: MAX_TRANSFER_BYTES + 1,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: [0u8; 32],
                filename: "too-large.bin".to_owned(),
            })
            .await
            .expect("oversized offer should produce rejection receipt");
        assert_eq!(out.len(), 1);
        assert_receipt_status(&out[0], false);
        assert!(receiver.transfers.is_empty());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_zero_byte_offer_finalizes_immediately_and_counts_as_a_file() {
        let dir = temp_dir("zero-byte");
        let mut receiver = test_receiver(&dir, "session-zero-byte").await;
        let tid = [3u8; 16];
        let empty_digest = sha256(b"");
        let out = receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: 0,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: empty_digest,
                filename: "empty.bin".to_owned(),
            })
            .await
            .expect("zero-byte offer");
        assert_eq!(out.len(), 1);
        assert_receipt_status(&out[0], true);
        assert_eq!(std::fs::metadata(dir.join("empty.bin")).unwrap().len(), 0);
        assert!(receiver.transfers.is_empty());
        let usage = receiver.store.usage().await;
        assert_eq!(usage.stored, ReceivedStorageUsage { bytes: 0, files: 1 });
        assert_eq!(usage.reserved_files, 0);

        let rejected = receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: [4u8; 16],
                total_size: 0,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: sha256(b"not empty"),
                filename: "bad-empty.bin".to_owned(),
            })
            .await
            .expect("bad zero-byte offer");
        assert_eq!(rejected.len(), 1);
        assert_receipt_status(&rejected[0], false);
        assert!(!dir.join("bad-empty.bin").exists());
        assert!(receiver.transfers.is_empty());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_idle_timeout_aborts_slot_removes_temp_and_returns_error_receipt() {
        let dir = temp_dir("idle-timeout");
        let mut receiver = test_receiver(&dir, "session-idle-timeout").await;
        let tid = [11u8; 16];
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: 10,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: sha256(b"0123456789"),
                filename: "idle.bin".to_owned(),
            })
            .await
            .expect("offer");
        let temp_path = receiver
            .transfers
            .get(&tid)
            .expect("transfer")
            .reservation
            .temp_path
            .clone();
        receiver
            .transfers
            .get_mut(&tid)
            .expect("transfer")
            .last_progress_at = Instant::now() - RECEIVER_IDLE_TIMEOUT;
        let receipts = receiver
            .expire_idle_transfers(Instant::now())
            .await
            .expect("idle expiration");
        assert_eq!(receipts.len(), 1);
        assert_receipt_status(&receipts[0], false);
        assert!(receiver.transfers.is_empty());
        assert!(!temp_path.exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_write_error_aborts_slot_and_returns_error_receipt() {
        let dir = temp_dir("write-error");
        let mut receiver = test_receiver(&dir, "session-write-error").await;
        let tid = [12u8; 16];
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: 1,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: sha256(b"x"),
                filename: "write-error.bin".to_owned(),
            })
            .await
            .expect("offer");
        let temp_path = receiver
            .transfers
            .get(&tid)
            .expect("transfer")
            .reservation
            .temp_path
            .clone();
        let read_only = File::open(&temp_path).await.expect("read-only handle");
        receiver.transfers.get_mut(&tid).expect("transfer").file = read_only;
        let out = receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id: tid,
                sequence: 0,
                payload: vec![b'x'],
            })
            .await
            .expect("write error should become receipt rejection");
        assert_eq!(out.len(), 1);
        assert_receipt_status(&out[0], false);
        assert!(receiver.transfers.is_empty());
        assert!(!temp_path.exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_finalize_error_aborts_slot_and_returns_error_receipt() {
        let dir = temp_dir("finalize-error");
        let mut store = InboundFileStore::initialize(dir.clone())
            .await
            .expect("initialize test inbound storage");
        store.received_dir = dir.join("missing-destination");
        let mut receiver =
            LegacyFileReceiver::new("session-finalize-error".to_owned(), Arc::new(store));
        let tid = [13u8; 16];
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: 1,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: sha256(b"x"),
                filename: "finalize-error.bin".to_owned(),
            })
            .await
            .expect("offer");
        let temp_path = receiver
            .transfers
            .get(&tid)
            .expect("transfer")
            .reservation
            .temp_path
            .clone();
        let out = receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id: tid,
                sequence: 0,
                payload: vec![b'x'],
            })
            .await
            .expect("finalize error should become receipt rejection");
        assert_eq!(out.len(), 1);
        assert_receipt_status(&out[0], false);
        assert!(receiver.transfers.is_empty());
        assert!(!temp_path.exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn ambiguous_placement_is_accounted_as_stored_fail_closed() {
        let dir = temp_dir("ambiguous-placement-accounting");
        let mut receiver = test_receiver(&dir, "session-ambiguous-placement").await;
        let transfer_id = [25u8; 16];
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id,
                total_size: 1,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: sha256(b"x"),
                filename: "ambiguous.bin".to_owned(),
            })
            .await
            .expect("offer");
        let transfer = receiver
            .transfers
            .remove(&transfer_id)
            .expect("active transfer");
        drop(transfer.file);
        let destination = dir.join("ambiguous.bin");
        tokio::fs::hard_link(&transfer.reservation.temp_path, &destination)
            .await
            .expect("simulate destination link that could not be rolled back");
        receiver
            .finalize_with_error_receipt(
                &transfer_id,
                transfer.reservation,
                anyhow!("simulated ambiguous placement"),
                true,
            )
            .await
            .expect("ambiguous placement accounting should converge");

        let usage = receiver.store.usage().await;
        assert_eq!(usage.stored, ReceivedStorageUsage { bytes: 1, files: 1 });
        assert_eq!(usage.reserved_bytes, 0);
        assert_eq!(usage.reserved_files, 0);
        assert!(destination.exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_writes_verified_file_and_emits_ok_receipt() {
        let dir = temp_dir("ok");
        let mut receiver = test_receiver(&dir, "session-ok").await;
        let tid = [5u8; 16];
        let payload = b"hello skybridge file transfer".to_vec();
        let digest = sha256(&payload);

        let offer = receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: payload.len() as u64,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: digest,
                filename: "note.txt".to_owned(),
            })
            .await
            .expect("offer");
        assert!(offer.is_empty());

        let out = receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id: tid,
                sequence: 0,
                payload: payload.clone(),
            })
            .await
            .expect("chunk");
        assert_eq!(out.len(), 1);
        match file_transfer_frame::decode_file_app_frame(&out[0]).expect("decode receipt") {
            FileAppFrame::Receipt {
                ok,
                computed_sha256,
                ..
            } => {
                assert!(ok);
                assert_eq!(computed_sha256, digest);
            }
            other => panic!("expected receipt, got {other:?}"),
        }
        let stored = std::fs::read(dir.join("note.txt")).expect("stored file");
        assert_eq!(stored, payload);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_directory_sync_failure_never_emits_success_receipt() {
        let dir = temp_dir("directory-sync-failure");
        let mut receiver = test_receiver(&dir, "session-directory-sync-failure").await;
        let transfer_id = [35u8; 16];
        let payload = b"durability-sensitive payload".to_vec();
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id,
                total_size: payload.len() as u64,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: sha256(&payload),
                filename: "durable.bin".to_owned(),
            })
            .await
            .expect("offer");
        receiver.store.inject_directory_sync_failure_once();

        let receipt = receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id,
                sequence: 0,
                payload: payload.clone(),
            })
            .await
            .expect("directory sync failure becomes a rejection receipt");

        assert_eq!(receipt.len(), 1);
        assert_receipt_status(&receipt[0], false);
        assert_eq!(
            std::fs::read(dir.join("durable.bin")).expect("ambiguous destination is retained"),
            payload
        );
        let usage = receiver.store.usage().await;
        assert_eq!(usage.stored.files, 1);
        assert_eq!(usage.reserved_files, 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_rejects_sha_mismatch_without_storing() {
        let dir = temp_dir("mismatch");
        let mut receiver = test_receiver(&dir, "session-mismatch").await;
        let tid = [6u8; 16];
        let payload = b"actual bytes".to_vec();
        let wrong_digest = sha256(b"different");

        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: payload.len() as u64,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: wrong_digest,
                filename: "x.bin".to_owned(),
            })
            .await
            .expect("offer");
        let out = receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id: tid,
                sequence: 0,
                payload,
            })
            .await
            .expect("chunk");
        match file_transfer_frame::decode_file_app_frame(&out[0]).expect("decode") {
            FileAppFrame::Receipt { ok, .. } => assert!(!ok),
            other => panic!("expected receipt err, got {other:?}"),
        }
        assert!(!dir.join("x.bin").exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_rejects_out_of_order_sequence() {
        let dir = temp_dir("ooo");
        let mut receiver = test_receiver(&dir, "session-ooo").await;
        let tid = [7u8; 16];
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: 10,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: [0u8; 32],
                filename: "y.bin".to_owned(),
            })
            .await
            .expect("offer");
        let out = receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id: tid,
                sequence: 5,
                payload: vec![1, 2, 3],
            })
            .await
            .expect("chunk");
        match file_transfer_frame::decode_file_app_frame(&out[0]).expect("decode") {
            FileAppFrame::Receipt { ok, .. } => assert!(!ok),
            other => panic!("expected receipt err, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_rejects_empty_chunk_and_releases_staging_and_quota() {
        let dir = temp_dir("empty-chunk");
        let mut receiver = test_receiver(&dir, "session-empty-chunk").await;
        let transfer_id = [23u8; 16];
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id,
                total_size: 1,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: sha256(b"x"),
                filename: "empty-chunk.bin".to_owned(),
            })
            .await
            .expect("offer");
        let temp_path = receiver
            .transfers
            .get(&transfer_id)
            .expect("active transfer")
            .reservation
            .temp_path
            .clone();

        let receipt = receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id,
                sequence: 0,
                payload: Vec::new(),
            })
            .await
            .expect("empty chunk rejection");
        assert_eq!(receipt.len(), 1);
        assert_receipt_status(&receipt[0], false);
        assert!(receiver.transfers.is_empty());
        assert!(!temp_path.exists());
        let usage = receiver.store.usage().await;
        assert_eq!(usage.reserved_bytes, 0);
        assert_eq!(usage.reserved_files, 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_rejects_nonfinal_chunk_smaller_than_canonical_size() {
        let dir = temp_dir("tiny-nonfinal-chunk");
        let mut receiver = test_receiver(&dir, "session-tiny-nonfinal").await;
        let transfer_id = [24u8; 16];
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id,
                total_size: CHUNK_PAYLOAD_BYTES as u64 + 1,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: [0u8; 32],
                filename: "tiny-nonfinal.bin".to_owned(),
            })
            .await
            .expect("offer");
        let temp_path = receiver
            .transfers
            .get(&transfer_id)
            .expect("active transfer")
            .reservation
            .temp_path
            .clone();

        let receipt = receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id,
                sequence: 0,
                payload: vec![1],
            })
            .await
            .expect("tiny nonfinal rejection");
        assert_eq!(receipt.len(), 1);
        assert_receipt_status(&receipt[0], false);
        assert!(receiver.transfers.is_empty());
        assert!(!temp_path.exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_auto_suffixes_on_collision_without_overwrite() {
        let dir = temp_dir("collide");
        std::fs::write(dir.join("dup.txt"), b"existing").expect("seed existing");
        let mut receiver = test_receiver(&dir, "session-collide").await;
        let tid = [8u8; 16];
        let payload = b"new content".to_vec();
        let digest = sha256(&payload);
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: payload.len() as u64,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: digest,
                filename: "dup.txt".to_owned(),
            })
            .await
            .expect("offer");
        receiver
            .handle_frame(FileAppFrame::Chunk {
                transfer_id: tid,
                sequence: 0,
                payload: payload.clone(),
            })
            .await
            .expect("chunk");
        assert_eq!(std::fs::read(dir.join("dup.txt")).unwrap(), b"existing");
        assert_eq!(std::fs::read(dir.join("dup (1).txt")).unwrap(), payload);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn receivers_isolate_same_transfer_id_and_session_shutdown() {
        let dir = temp_dir("session-isolation");
        let store = Arc::new(
            InboundFileStore::initialize(dir.clone())
                .await
                .expect("initialize shared inbound storage"),
        );
        let mut receiver_a = LegacyFileReceiver::new("session-a".to_owned(), Arc::clone(&store));
        let mut receiver_b = LegacyFileReceiver::new("session-b".to_owned(), Arc::clone(&store));
        let transfer_id = [21u8; 16];
        let payload_a = b"session-a".to_vec();
        let payload_b = b"session-b".to_vec();

        let (offer_a, offer_b) = tokio::join!(
            receiver_a.handle_frame(FileAppFrame::Offer {
                transfer_id,
                total_size: payload_a.len() as u64,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: sha256(&payload_a),
                filename: "a.bin".to_owned(),
            }),
            receiver_b.handle_frame(FileAppFrame::Offer {
                transfer_id,
                total_size: payload_b.len() as u64,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: sha256(&payload_b),
                filename: "b.bin".to_owned(),
            }),
        );
        assert!(offer_a.expect("session A offer").is_empty());
        assert!(offer_b.expect("session B offer").is_empty());

        let temp_a = receiver_a
            .transfers
            .get(&transfer_id)
            .expect("session A transfer")
            .reservation
            .temp_path
            .clone();
        let temp_b = receiver_b
            .transfers
            .get(&transfer_id)
            .expect("session B transfer")
            .reservation
            .temp_path
            .clone();
        assert_ne!(temp_a, temp_b, "session namespace must isolate staging");
        assert!(temp_a.exists());
        assert!(temp_b.exists());

        receiver_a
            .abort_all()
            .await
            .expect("session A shutdown cleanup");
        assert!(!temp_a.exists());
        assert!(
            temp_b.exists(),
            "one session shutdown must not remove another session's live staging"
        );

        let receipt_b = receiver_b
            .handle_frame(FileAppFrame::Chunk {
                transfer_id,
                sequence: 0,
                payload: payload_b.clone(),
            })
            .await
            .expect("session B chunk");
        assert_eq!(receipt_b.len(), 1);
        assert_receipt_status(&receipt_b[0], true);
        assert_eq!(std::fs::read(dir.join("b.bin")).unwrap(), payload_b);
        assert!(!dir.join("a.bin").exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_sessions_share_atomic_byte_and_file_quota_admission() {
        let dir = temp_dir("global-quota");
        let sparse =
            std::fs::File::create(dir.join("stored-large.bin")).expect("create sparse stored file");
        sparse
            .set_len(MAX_RECEIVED_STORAGE_BYTES - 1)
            .expect("size sparse stored file");
        for index in 0..(MAX_RECEIVED_FILES - 2) {
            std::fs::File::create(dir.join(format!("stored-{index}.bin")))
                .expect("create stored quota entry");
        }

        let store = Arc::new(
            InboundFileStore::initialize(dir.clone())
                .await
                .expect("initialize near-capacity shared storage"),
        );
        let mut receiver_a =
            LegacyFileReceiver::new("quota-session-a".to_owned(), Arc::clone(&store));
        let mut receiver_b =
            LegacyFileReceiver::new("quota-session-b".to_owned(), Arc::clone(&store));
        let transfer_id = [22u8; 16];

        let (offer_a, offer_b) = tokio::join!(
            receiver_a.handle_frame(FileAppFrame::Offer {
                transfer_id,
                total_size: 1,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: sha256(b"a"),
                filename: "quota-a.bin".to_owned(),
            }),
            receiver_b.handle_frame(FileAppFrame::Offer {
                transfer_id,
                total_size: 1,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: sha256(b"b"),
                filename: "quota-b.bin".to_owned(),
            }),
        );
        let offers = [
            offer_a.expect("session A offer"),
            offer_b.expect("session B offer"),
        ];
        assert_eq!(
            offers.iter().filter(|frames| frames.is_empty()).count(),
            1,
            "exactly one concurrent offer may reserve the final byte and file slot"
        );
        assert_eq!(offers.iter().filter(|frames| !frames.is_empty()).count(), 1);
        for frames in offers.iter().filter(|frames| !frames.is_empty()) {
            assert_eq!(frames.len(), 1);
            assert_receipt_status(&frames[0], false);
        }

        let usage = store.usage().await;
        assert_eq!(usage.stored.bytes, MAX_RECEIVED_STORAGE_BYTES - 1);
        assert_eq!(usage.stored.files, MAX_RECEIVED_FILES - 1);
        assert_eq!(usage.reserved_bytes, 1);
        assert_eq!(usage.reserved_files, 1);

        receiver_a.abort_all().await.expect("session A cleanup");
        receiver_b.abort_all().await.expect("session B cleanup");
        let usage = store.usage().await;
        assert_eq!(usage.reserved_bytes, 0);
        assert_eq!(usage.reserved_files, 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn receiver_no_replace_placement_never_follows_existing_symlink() {
        use std::os::unix::fs::symlink;

        let dir = temp_dir("symlink-collision");
        let outside = dir.join("outside.txt");
        std::fs::write(&outside, b"outside").expect("outside file");
        symlink(&outside, dir.join("link.txt")).expect("seed symlink");
        let staging = dir.join("staging.part");
        std::fs::write(&staging, b"verified").expect("staging file");

        let placed = place_received_file(&dir, &staging, "link.txt", false)
            .await
            .expect("collision should auto-suffix without following symlink");
        assert_eq!(placed, dir.join("link (1).txt"));
        assert_eq!(std::fs::read(&outside).unwrap(), b"outside");
        assert_eq!(std::fs::read(&placed).unwrap(), b"verified");
        assert!(!staging.exists());
        assert!(
            std::fs::symlink_metadata(dir.join("link.txt"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn receiver_chunks_across_multiple_frames_and_acks() {
        let dir = temp_dir("multi");
        let mut receiver = test_receiver(&dir, "session-multi").await;
        let tid = [9u8; 16];
        let chunk = vec![42u8; CHUNK_PAYLOAD_BYTES];
        // One chunk past the ack cadence so a mid-stream ack fires before the
        // final completion receipt preempts it.
        let chunk_count = ACK_EVERY_CHUNKS + 1;
        let total = (CHUNK_PAYLOAD_BYTES * (chunk_count as usize)) as u64;
        let mut all = Vec::new();
        for _ in 0..chunk_count {
            all.extend_from_slice(&chunk);
        }
        let digest = sha256(&all);
        receiver
            .handle_frame(FileAppFrame::Offer {
                transfer_id: tid,
                total_size: total,
                chunk_size: CHUNK_PAYLOAD_BYTES as u32,
                expected_sha256: digest,
                filename: "big.bin".to_owned(),
            })
            .await
            .expect("offer");
        let mut got_ack = false;
        let mut got_receipt = false;
        for seq in 0..chunk_count {
            let out = receiver
                .handle_frame(FileAppFrame::Chunk {
                    transfer_id: tid,
                    sequence: seq,
                    payload: chunk.clone(),
                })
                .await
                .expect("chunk");
            for plaintext in out {
                match file_transfer_frame::decode_file_app_frame(&plaintext).expect("decode") {
                    FileAppFrame::ChunkAck { .. } => got_ack = true,
                    FileAppFrame::Receipt { ok, .. } => {
                        assert!(ok);
                        got_receipt = true;
                    }
                    _ => {}
                }
            }
        }
        assert!(got_ack, "expected at least one chunk ack");
        assert!(got_receipt, "expected a final receipt");
        assert_eq!(
            std::fs::read(dir.join("big.bin")).unwrap().len(),
            total as usize
        );
        std::fs::remove_dir_all(&dir).ok();
    }
}
