use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use directories::UserDirs;
use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use tokio::fs;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::sync::{Mutex, oneshot};

use skybridge_core::{
    CrossNetworkFileTransferMessage, CrossNetworkFileTransferOp, NativeWebRtcHandle,
    SessionFileTransferRequest, SessionTransferRequestState, TransferDirection,
    TransferHistoryEntry, TransferStatus, sha256_file_hex,
};

use crate::runtime::AgentPaths;
use crate::state::{
    DeviceIdentityMaterial, append_transfer_history_entry, load_pending_transfer_requests_for_session,
    save_session_transfer_request,
};

const SESSION_FILE_TRANSFER_CHUNK_SIZE: usize = 16 * 1024;
const WAIT_TIMEOUT: Duration = Duration::from_secs(30);
const REQUEST_PICKUP_INTERVAL: Duration = Duration::from_millis(250);

#[derive(Debug, Clone, Default)]
pub struct SessionTransferCoordinator {
    inner: Arc<CoordinatorInner>,
}

#[derive(Debug, Default)]
struct CoordinatorInner {
    active_request_ids: Mutex<BTreeSet<String>>,
    waiters: Mutex<BTreeMap<TransferWaitKey, oneshot::Sender<Result<CrossNetworkFileTransferMessage>>>>,
}

#[derive(Debug)]
pub struct SessionTransferRuntime {
    coordinator: SessionTransferCoordinator,
    inbound_transfers: BTreeMap<String, InboundTransferState>,
}

#[derive(Debug)]
struct InboundTransferState {
    transfer_id: String,
    file_name: String,
    file_size: i64,
    chunk_size: usize,
    total_chunks: usize,
    sender_device_id: Option<String>,
    sender_device_name: Option<String>,
    temp_path: PathBuf,
    final_path: PathBuf,
    handle: fs::File,
    received_bytes: i64,
    received_chunk_sizes: BTreeMap<i32, usize>,
    chunk_hashes: BTreeMap<i32, Vec<u8>>,
    expected_file_sha256: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct TransferWaitKey {
    transfer_id: String,
    op: CrossNetworkFileTransferOp,
    chunk_index: Option<i32>,
}

impl SessionTransferRuntime {
    pub fn new() -> Self {
        Self {
            coordinator: SessionTransferCoordinator::default(),
            inbound_transfers: BTreeMap::new(),
        }
    }

    pub async fn poll_outbound_requests(
        &self,
        paths: &AgentPaths,
        session_id: &str,
        session_handle: NativeWebRtcHandle,
        identity: DeviceIdentityMaterial,
    ) -> Result<()> {
        if self.coordinator.has_active_request().await {
            return Ok(());
        }
        let pending = load_pending_transfer_requests_for_session(paths, session_id).await?;
        let Some(request) = pending.into_iter().next() else {
            return Ok(());
        };
        let request_id = request.request_id.clone();
        self.coordinator.add_active_request(&request_id).await;
        let coordinator = self.coordinator.clone();
        let worker_paths = paths.clone();
        tokio::spawn(async move {
            let result = run_outbound_request(
                worker_paths.clone(),
                request,
                session_handle,
                coordinator.clone(),
                identity,
            )
            .await;
            if let Err(error) = result {
                let _ = fail_request_by_id(&worker_paths, &request_id, &error.to_string()).await;
            }
            coordinator.remove_active_request(&request_id).await;
        });
        Ok(())
    }

    pub async fn handle_application_payload(
        &mut self,
        paths: &AgentPaths,
        session_id: &str,
        payload: &[u8],
        session_handle: &NativeWebRtcHandle,
    ) -> Result<bool> {
        let message = match serde_json::from_slice::<CrossNetworkFileTransferMessage>(payload) {
            Ok(message) if message.version == CrossNetworkFileTransferMessage::VERSION => message,
            _ => return Ok(false),
        };

        if message.op == CrossNetworkFileTransferOp::Error {
            self.coordinator
                .fail_transfer(
                    &message.transfer_id,
                    message
                        .message
                        .clone()
                        .unwrap_or_else(|| "remote transfer error".to_owned()),
                )
                .await;
            return Ok(true);
        }

        if self.coordinator.resolve_waiter(&message).await {
            return Ok(true);
        }

        match message.op {
            CrossNetworkFileTransferOp::Metadata => {
                self.handle_inbound_metadata(paths, session_id, message, session_handle)
                    .await?;
                Ok(true)
            }
            CrossNetworkFileTransferOp::Chunk => {
                self.handle_inbound_chunk(paths, message, session_handle).await?;
                Ok(true)
            }
            CrossNetworkFileTransferOp::Complete => {
                self.handle_inbound_complete(paths, message, session_handle).await?;
                Ok(true)
            }
            CrossNetworkFileTransferOp::Cancel => {
                self.handle_inbound_cancel(paths, message).await?;
                Ok(true)
            }
            CrossNetworkFileTransferOp::MetadataAck
            | CrossNetworkFileTransferOp::ChunkAck
            | CrossNetworkFileTransferOp::CompleteAck => Ok(true),
            CrossNetworkFileTransferOp::Error => Ok(true),
        }
    }

    async fn handle_inbound_metadata(
        &mut self,
        _paths: &AgentPaths,
        _session_id: &str,
        message: CrossNetworkFileTransferMessage,
        session_handle: &NativeWebRtcHandle,
    ) -> Result<()> {
        if self.inbound_transfers.contains_key(&message.transfer_id) {
            let ack = CrossNetworkFileTransferMessage::new(
                CrossNetworkFileTransferOp::MetadataAck,
                message.transfer_id,
            );
            send_transfer_message(session_handle, &ack).await?;
            return Ok(());
        }
        let file_name = message
            .file_name
            .clone()
            .filter(|value| !value.trim().is_empty())
            .ok_or_else(|| anyhow!("missing fileName in metadata"))?;
        let file_size = message
            .file_size
            .filter(|value| *value >= 0)
            .ok_or_else(|| anyhow!("missing or invalid fileSize in metadata"))?;
        let chunk_size = message
            .chunk_size
            .filter(|value| *value > 0)
            .ok_or_else(|| anyhow!("missing or invalid chunkSize in metadata"))?;
        let total_chunks = message
            .total_chunks
            .filter(|value| *value > 0)
            .ok_or_else(|| anyhow!("missing or invalid totalChunks in metadata"))?;

        let output_dir = default_receive_directory()?;
        fs::create_dir_all(&output_dir).await?;
        let final_path = unique_destination_path(&output_dir, &file_name).await?;
        let temp_path = output_dir.join(format!(".skybridge-{}.partial", message.transfer_id));
        let handle = fs::File::create(&temp_path)
            .await
            .with_context(|| format!("failed to create {}", temp_path.display()))?;

        self.inbound_transfers.insert(
            message.transfer_id.clone(),
            InboundTransferState {
                transfer_id: message.transfer_id.clone(),
                file_name,
                file_size,
                chunk_size,
                total_chunks,
                sender_device_id: message.sender_device_id.clone(),
                sender_device_name: message.sender_device_name.clone(),
                temp_path,
                final_path,
                handle,
                received_bytes: 0,
                received_chunk_sizes: BTreeMap::new(),
                chunk_hashes: BTreeMap::new(),
                expected_file_sha256: None,
            },
        );
        let ack = CrossNetworkFileTransferMessage::new(
            CrossNetworkFileTransferOp::MetadataAck,
            message.transfer_id,
        );
        send_transfer_message(session_handle, &ack).await
    }

    async fn handle_inbound_chunk(
        &mut self,
        _paths: &AgentPaths,
        message: CrossNetworkFileTransferMessage,
        session_handle: &NativeWebRtcHandle,
    ) -> Result<()> {
        let Some(state) = self.inbound_transfers.get_mut(&message.transfer_id) else {
            let mut error = CrossNetworkFileTransferMessage::new(
                CrossNetworkFileTransferOp::Error,
                message.transfer_id,
            );
            error.message = Some("Unknown transferId".to_owned());
            send_transfer_message(session_handle, &error).await?;
            return Ok(());
        };
        let index = message
            .chunk_index
            .ok_or_else(|| anyhow!("missing chunkIndex"))?;
        let payload = message
            .chunk_data
            .clone()
            .ok_or_else(|| anyhow!("missing chunkData"))?;
        let raw_size = message
            .raw_size
            .ok_or_else(|| anyhow!("missing rawSize"))?;
        if raw_size != payload.len() {
            bail!("chunk rawSize mismatch");
        }
        if index < 0 || index as usize >= state.total_chunks {
            bail!("chunk index out of range");
        }
        let actual_hash = Sha256::digest(&payload).to_vec();
        if let Some(expected_hash) = message.chunk_sha256.as_ref() {
            if *expected_hash != actual_hash {
                let mut error = CrossNetworkFileTransferMessage::new(
                    CrossNetworkFileTransferOp::Error,
                    message.transfer_id,
                );
                error.chunk_index = Some(index);
                error.message = Some("chunk hash mismatch".to_owned());
                send_transfer_message(session_handle, &error).await?;
                return Ok(());
            }
        }

        if let Some(existing_hash) = state.chunk_hashes.get(&index) {
            if existing_hash != &actual_hash {
                let mut error = CrossNetworkFileTransferMessage::new(
                    CrossNetworkFileTransferOp::Error,
                    message.transfer_id,
                );
                error.chunk_index = Some(index);
                error.message = Some("duplicate chunk content mismatch".to_owned());
                send_transfer_message(session_handle, &error).await?;
                return Ok(());
            }
        } else {
            let offset = (index as i64)
                .checked_mul(state.chunk_size as i64)
                .ok_or_else(|| anyhow!("chunk offset overflow"))?;
            state.handle.seek(std::io::SeekFrom::Start(offset as u64)).await?;
            state.handle.write_all(&payload).await?;
            state.received_bytes += raw_size as i64;
            state.received_chunk_sizes.insert(index, raw_size);
            state.chunk_hashes.insert(index, actual_hash);
        }

        let mut ack = CrossNetworkFileTransferMessage::new(
            CrossNetworkFileTransferOp::ChunkAck,
            message.transfer_id,
        );
        ack.chunk_index = Some(index);
        ack.received_bytes = Some(state.received_bytes);
        send_transfer_message(session_handle, &ack).await
    }

    async fn handle_inbound_complete(
        &mut self,
        paths: &AgentPaths,
        message: CrossNetworkFileTransferMessage,
        session_handle: &NativeWebRtcHandle,
    ) -> Result<()> {
        let Some(mut state) = self.inbound_transfers.remove(&message.transfer_id) else {
            return Ok(());
        };
        state.expected_file_sha256 = message.file_sha256.clone();
        state.handle.flush().await?;
        state.handle.shutdown().await?;
        drop(state.handle);

        if state.received_bytes != state.file_size {
            let mut error = CrossNetworkFileTransferMessage::new(
                CrossNetworkFileTransferOp::Error,
                state.transfer_id.clone(),
            );
            error.message = Some(format!(
                "incomplete file: {}/{} bytes",
                state.received_bytes, state.file_size
            ));
            let _ = fs::remove_file(&state.temp_path).await;
            send_transfer_message(session_handle, &error).await?;
            append_transfer_history_entry(
                paths,
                TransferHistoryEntry {
                    transfer_id: state.transfer_id.clone(),
                    direction: TransferDirection::Incoming,
                    status: TransferStatus::Failed,
                    file_name: state.file_name.clone(),
                    file_size: state.file_size,
                    local_path: Some(state.temp_path.display().to_string()),
                    remote_label: state.sender_device_name.clone(),
                    remote_device_id: state.sender_device_id.clone(),
                    remote_address: Some("session-data-channel".to_owned()),
                    route_source: Some("session:data_channel".to_owned()),
                    compression: None,
                    file_hash: None,
                    error: error.message.clone(),
                    started_at: OffsetDateTime::now_utc(),
                    completed_at: Some(OffsetDateTime::now_utc()),
                },
            )
            .await?;
            return Ok(());
        }

        let file_hash = sha256_file_hex(&state.temp_path).await?;
        if let Some(expected_sha256) = state.expected_file_sha256.as_ref() {
            let expected = hex_lower(expected_sha256);
            if !file_hash.eq_ignore_ascii_case(&expected) {
                let mut error = CrossNetworkFileTransferMessage::new(
                    CrossNetworkFileTransferOp::Error,
                    state.transfer_id.clone(),
                );
                error.message = Some("file sha256 mismatch".to_owned());
                let _ = fs::remove_file(&state.temp_path).await;
                send_transfer_message(session_handle, &error).await?;
                append_transfer_history_entry(
                    paths,
                    TransferHistoryEntry {
                        transfer_id: state.transfer_id.clone(),
                        direction: TransferDirection::Incoming,
                        status: TransferStatus::Failed,
                        file_name: state.file_name.clone(),
                        file_size: state.file_size,
                        local_path: Some(state.temp_path.display().to_string()),
                        remote_label: state.sender_device_name.clone(),
                        remote_device_id: state.sender_device_id.clone(),
                        remote_address: Some("session-data-channel".to_owned()),
                        route_source: Some("session:data_channel".to_owned()),
                        compression: None,
                        file_hash: Some(file_hash),
                        error: error.message.clone(),
                        started_at: OffsetDateTime::now_utc(),
                        completed_at: Some(OffsetDateTime::now_utc()),
                    },
                )
                .await?;
                return Ok(());
            }
        }

        if fs::try_exists(&state.final_path).await? {
            let _ = fs::remove_file(&state.final_path).await;
        }
        fs::rename(&state.temp_path, &state.final_path).await?;

        append_transfer_history_entry(
            paths,
            TransferHistoryEntry {
                transfer_id: state.transfer_id.clone(),
                direction: TransferDirection::Incoming,
                status: TransferStatus::Completed,
                file_name: state.file_name.clone(),
                file_size: state.file_size,
                local_path: Some(state.final_path.display().to_string()),
                remote_label: state.sender_device_name.clone(),
                remote_device_id: state.sender_device_id.clone(),
                remote_address: Some("session-data-channel".to_owned()),
                route_source: Some("session:data_channel".to_owned()),
                compression: None,
                file_hash: Some(file_hash.clone()),
                error: None,
                started_at: OffsetDateTime::now_utc(),
                completed_at: Some(OffsetDateTime::now_utc()),
            },
        )
        .await?;

        let ack = CrossNetworkFileTransferMessage::new(
            CrossNetworkFileTransferOp::CompleteAck,
            state.transfer_id,
        );
        send_transfer_message(session_handle, &ack).await
    }

    async fn handle_inbound_cancel(
        &mut self,
        paths: &AgentPaths,
        message: CrossNetworkFileTransferMessage,
    ) -> Result<()> {
        if let Some(state) = self.inbound_transfers.remove(&message.transfer_id) {
            let _ = fs::remove_file(&state.temp_path).await;
            append_transfer_history_entry(
                paths,
                TransferHistoryEntry {
                    transfer_id: state.transfer_id,
                    direction: TransferDirection::Incoming,
                    status: TransferStatus::Failed,
                    file_name: state.file_name,
                    file_size: state.file_size,
                    local_path: Some(state.temp_path.display().to_string()),
                    remote_label: state.sender_device_name,
                    remote_device_id: state.sender_device_id,
                    remote_address: Some("session-data-channel".to_owned()),
                    route_source: Some("session:data_channel".to_owned()),
                    compression: None,
                    file_hash: None,
                    error: Some(message.message.unwrap_or_else(|| "cancelled".to_owned())),
                    started_at: OffsetDateTime::now_utc(),
                    completed_at: Some(OffsetDateTime::now_utc()),
                },
            )
            .await?;
        }
        Ok(())
    }
}

impl SessionTransferCoordinator {
    async fn has_active_request(&self) -> bool {
        !self.inner.active_request_ids.lock().await.is_empty()
    }

    async fn add_active_request(&self, request_id: &str) {
        self.inner
            .active_request_ids
            .lock()
            .await
            .insert(request_id.to_owned());
    }

    async fn remove_active_request(&self, request_id: &str) {
        self.inner.active_request_ids.lock().await.remove(request_id);
        self.fail_transfer(request_id, "request aborted".to_owned()).await;
    }

    async fn wait_for_message(
        &self,
        transfer_id: &str,
        op: CrossNetworkFileTransferOp,
        chunk_index: Option<i32>,
        timeout: Duration,
    ) -> Result<CrossNetworkFileTransferMessage> {
        let key = TransferWaitKey {
            transfer_id: transfer_id.to_owned(),
            op,
            chunk_index,
        };
        let (tx, rx) = oneshot::channel();
        self.inner.waiters.lock().await.insert(key.clone(), tx);
        let received = tokio::time::timeout(timeout, rx)
            .await
            .map_err(|_| anyhow!("timed out waiting for {op:?}"))?;
        self.inner.waiters.lock().await.remove(&key);
        received
            .map_err(|_| anyhow!("transfer waiter dropped"))?
            .map_err(Into::into)
    }

    async fn resolve_waiter(&self, message: &CrossNetworkFileTransferMessage) -> bool {
        let key = TransferWaitKey {
            transfer_id: message.transfer_id.clone(),
            op: message.op,
            chunk_index: message.chunk_index,
        };
        if let Some(waiter) = self.inner.waiters.lock().await.remove(&key) {
            let _ = waiter.send(Ok(message.clone()));
            return true;
        }
        false
    }

    async fn fail_transfer(&self, transfer_id: &str, error: String) {
        let keys = self
            .inner
            .waiters
            .lock()
            .await
            .keys()
            .filter(|key| key.transfer_id == transfer_id)
            .cloned()
            .collect::<Vec<_>>();
        let mut waiters = self.inner.waiters.lock().await;
        for key in keys {
            if let Some(waiter) = waiters.remove(&key) {
                let _ = waiter.send(Err(anyhow!(error.clone())));
            }
        }
    }
}

async fn run_outbound_request(
    paths: AgentPaths,
    mut request: SessionFileTransferRequest,
    session_handle: NativeWebRtcHandle,
    coordinator: SessionTransferCoordinator,
    identity: DeviceIdentityMaterial,
) -> Result<()> {
    request.mark_in_progress();
    save_session_transfer_request(&paths, &request).await?;

    let source_path = PathBuf::from(&request.source_path);
    let file_hash = sha256_file_hex(&source_path).await?;
    let metadata = fs::metadata(&source_path).await?;
    let file_size = i64::try_from(metadata.len()).context("file size overflow")?;
    let transfer_id = request.request_id.clone();
    let total_chunks = ((file_size as usize) + (SESSION_FILE_TRANSFER_CHUNK_SIZE - 1))
        / SESSION_FILE_TRANSFER_CHUNK_SIZE;

    let mut metadata_message =
        CrossNetworkFileTransferMessage::new(CrossNetworkFileTransferOp::Metadata, transfer_id.clone());
    metadata_message.sender_device_id = Some(identity.state.device.device_id.clone());
    metadata_message.sender_device_name = Some(identity.state.device.device_name.clone());
    metadata_message.file_name = Some(request.file_name.clone());
    metadata_message.file_size = Some(file_size);
    metadata_message.chunk_size = Some(SESSION_FILE_TRANSFER_CHUNK_SIZE);
    metadata_message.total_chunks = Some(total_chunks.max(1));
    send_transfer_message(&session_handle, &metadata_message).await?;
    let _ = coordinator
        .wait_for_message(
            &transfer_id,
            CrossNetworkFileTransferOp::MetadataAck,
            None,
            WAIT_TIMEOUT,
        )
        .await?;

    let mut handle = fs::File::open(&source_path).await?;
    let mut buffer = vec![0_u8; SESSION_FILE_TRANSFER_CHUNK_SIZE];
    let mut chunk_index = 0_i32;
    loop {
        let read = handle.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        let payload = buffer[..read].to_vec();
        let mut chunk_message =
            CrossNetworkFileTransferMessage::new(CrossNetworkFileTransferOp::Chunk, transfer_id.clone());
        chunk_message.chunk_index = Some(chunk_index);
        chunk_message.chunk_data = Some(payload.clone());
        chunk_message.chunk_sha256 = Some(Sha256::digest(&payload).to_vec());
        chunk_message.raw_size = Some(payload.len());
        send_transfer_message(&session_handle, &chunk_message).await?;
        let ack = coordinator
            .wait_for_message(
                &transfer_id,
                CrossNetworkFileTransferOp::ChunkAck,
                Some(chunk_index),
                WAIT_TIMEOUT,
            )
            .await?;
        if let Some(missing_chunks) = ack.missing_chunks {
            if !missing_chunks.is_empty() {
                bail!("remote requested retransmit for missing chunks");
            }
        }
        chunk_index += 1;
    }

    let mut complete =
        CrossNetworkFileTransferMessage::new(CrossNetworkFileTransferOp::Complete, transfer_id.clone());
    complete.received_bytes = Some(file_size);
    complete.file_sha256 = Some(hex_to_bytes(&file_hash)?);
    send_transfer_message(&session_handle, &complete).await?;
    let _ = coordinator
        .wait_for_message(
            &transfer_id,
            CrossNetworkFileTransferOp::CompleteAck,
            None,
            WAIT_TIMEOUT,
        )
        .await?;

    request.mark_completed(transfer_id.clone(), file_hash.clone());
    save_session_transfer_request(&paths, &request).await?;
    append_transfer_history_entry(
        &paths,
        TransferHistoryEntry {
            transfer_id,
            direction: TransferDirection::Outgoing,
            status: TransferStatus::Completed,
            file_name: request.file_name.clone(),
            file_size,
            local_path: Some(request.source_path.clone()),
            remote_label: request.remote_device_name.clone(),
            remote_device_id: request.remote_device_id.clone(),
            remote_address: Some("session-data-channel".to_owned()),
            route_source: Some("session:data_channel".to_owned()),
            compression: None,
            file_hash: Some(file_hash),
            error: None,
            started_at: request.started_at.unwrap_or(request.created_at),
            completed_at: request.completed_at,
        },
    )
    .await?;
    Ok(())
}

async fn fail_request_by_id(paths: &AgentPaths, request_id: &str, error: &str) -> Result<()> {
    if let Some(mut request) = crate::state::load_session_transfer_request(paths, request_id).await? {
        request.mark_failed(error.to_owned());
        save_session_transfer_request(paths, &request).await?;
        append_transfer_history_entry(
            paths,
            TransferHistoryEntry {
                transfer_id: request.transfer_id.unwrap_or_else(|| request.request_id.clone()),
                direction: TransferDirection::Outgoing,
                status: TransferStatus::Failed,
                file_name: request.file_name.clone(),
                file_size: request.file_size,
                local_path: Some(request.source_path.clone()),
                remote_label: request.remote_device_name.clone(),
                remote_device_id: request.remote_device_id.clone(),
                remote_address: Some("session-data-channel".to_owned()),
                route_source: Some("session:data_channel".to_owned()),
                compression: None,
                file_hash: request.file_hash.clone(),
                error: Some(error.to_owned()),
                started_at: request.started_at.unwrap_or(request.created_at),
                completed_at: request.completed_at,
            },
        )
        .await?;
    }
    Ok(())
}

async fn send_transfer_message(
    session_handle: &NativeWebRtcHandle,
    message: &CrossNetworkFileTransferMessage,
) -> Result<()> {
    let payload = serde_json::to_vec(message)?;
    session_handle.send_application_payload(&payload).await
}

fn default_receive_directory() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("SKYBRIDGE_FILE_RECEIVE_DIR") {
        let path = PathBuf::from(path);
        if !path.as_os_str().is_empty() {
            return Ok(path);
        }
    }
    if let Some(user_dirs) = UserDirs::new() {
        if let Some(download_dir) = user_dirs.download_dir() {
            return Ok(download_dir.join("SkyBridge"));
        }
    }
    std::env::current_dir()
        .map(|path| path.join("SkyBridge"))
        .context("failed to resolve receive directory")
}

async fn unique_destination_path(base_dir: &Path, file_name: &str) -> Result<PathBuf> {
    let sanitized = Path::new(file_name)
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or("received-file")
        .to_owned();
    let candidate = base_dir.join(&sanitized);
    if !fs::try_exists(&candidate).await? {
        return Ok(candidate);
    }

    let stem = Path::new(&sanitized)
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("received-file");
    let extension = Path::new(&sanitized)
        .extension()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty());
    for index in 1..=999 {
        let name = match extension {
            Some(extension) => format!("{stem}-{index}.{extension}"),
            None => format!("{stem}-{index}"),
        };
        let candidate = base_dir.join(name);
        if !fs::try_exists(&candidate).await? {
            return Ok(candidate);
        }
    }
    bail!("failed to allocate unique receive path")
}

fn hex_to_bytes(hex: &str) -> Result<Vec<u8>> {
    let normalized = hex.trim();
    if normalized.len() % 2 != 0 {
        bail!("hex digest length is invalid");
    }
    let mut bytes = Vec::with_capacity(normalized.len() / 2);
    let mut chars = normalized.chars();
    while let (Some(high), Some(low)) = (chars.next(), chars.next()) {
        let high = high
            .to_digit(16)
            .ok_or_else(|| anyhow!("invalid hex character"))?;
        let low = low
            .to_digit(16)
            .ok_or_else(|| anyhow!("invalid hex character"))?;
        bytes.push(((high << 4) | low) as u8);
    }
    Ok(bytes)
}

fn hex_lower(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
}

pub async fn wait_for_request_terminal_state(
    paths: &AgentPaths,
    request_id: &str,
) -> Result<SessionFileTransferRequest> {
    let pickup_deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let request = crate::state::load_session_transfer_request(paths, request_id)
            .await?
            .ok_or_else(|| anyhow!("file transfer request `{request_id}` disappeared"))?;
        match request.state {
            SessionTransferRequestState::Pending if Instant::now() < pickup_deadline => {
                tokio::time::sleep(REQUEST_PICKUP_INTERVAL).await;
            }
            SessionTransferRequestState::Pending => {
                bail!("agent did not pick up the file transfer request");
            }
            SessionTransferRequestState::InProgress => {
                tokio::time::sleep(REQUEST_PICKUP_INTERVAL).await;
            }
            SessionTransferRequestState::Completed | SessionTransferRequestState::Failed => {
                return Ok(request);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::collections::BTreeMap;

    use skybridge_core::{
        CryptoSuite, NativeWebRtcConfig, NativeWebRtcEvent, NativeWebRtcSession,
        PqcInitiatorConfig, PqcResponderConfig, ProtocolIdentityBinding, RuntimeSessionRole,
        RustPqcIdentityMaterial,
    };

    use crate::runtime::resolve_paths;
    use crate::state::{
        ensure_device_identity, load_session_transfer_request, save_session_transfer_request,
    };

    #[tokio::test]
    async fn session_transfer_runtime_moves_file_over_native_webrtc() -> Result<()> {
        let root = std::env::temp_dir().join(format!("skybridge-session-transfer-{}", uuid::Uuid::now_v7()));
        let sender_root = root.join("sender");
        let receiver_root = root.join("receiver");
        let receive_dir = root.join("downloads");
        fs::create_dir_all(&sender_root).await?;
        fs::create_dir_all(&receiver_root).await?;
        fs::create_dir_all(&receive_dir).await?;
        unsafe {
            std::env::set_var("SKYBRIDGE_FILE_RECEIVE_DIR", &receive_dir);
        }

        let sender_paths = resolve_paths(Some(sender_root))?;
        let receiver_paths = resolve_paths(Some(receiver_root))?;
        let sender_identity = ensure_device_identity(&sender_paths).await?;
        let receiver_identity = ensure_device_identity(&receiver_paths).await?;
        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;

        let mut sender_session = NativeWebRtcSession::new(NativeWebRtcConfig {
            session_id: "session-transfer-test".to_owned(),
            local_device_id: sender_identity.state.device.device_id.clone(),
            role: RuntimeSessionRole::Initiator,
            turn_credentials: None,
            classic_initiator: None,
            pqc_initiator: Some(PqcInitiatorConfig {
                local_binding: ProtocolIdentityBinding::new(
                    sender_identity.state.device.device_id.clone(),
                    initiator_identity.signing_algorithm,
                    initiator_identity.signing_public_key.clone(),
                    None,
                )?,
                signing_secret_key: initiator_identity.signing_secret_key.clone(),
                local_device_name: Some(sender_identity.state.device.device_name.clone()),
                preferred_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
                peer_kem_public_keys: BTreeMap::from([
                    (
                        CryptoSuite::XWING_MLDSA,
                        responder_identity.xwing_public_key.clone(),
                    ),
                    (
                        CryptoSuite::MLKEM768_MLDSA65,
                        responder_identity.mlkem768_public_key.clone(),
                    ),
                ]),
            }),
            pqc_responder: None,
        })
        .await?;
        let mut receiver_session = NativeWebRtcSession::new(NativeWebRtcConfig {
            session_id: "session-transfer-test".to_owned(),
            local_device_id: receiver_identity.state.device.device_id.clone(),
            role: RuntimeSessionRole::Responder,
            turn_credentials: None,
            classic_initiator: None,
            pqc_initiator: None,
            pqc_responder: Some(PqcResponderConfig {
                local_binding: ProtocolIdentityBinding::new(
                    receiver_identity.state.device.device_id.clone(),
                    responder_identity.signing_algorithm,
                    responder_identity.signing_public_key.clone(),
                    None,
                )?,
                local_device_name: Some(receiver_identity.state.device.device_name.clone()),
                identity: responder_identity,
                supported_suites: vec![CryptoSuite::XWING_MLDSA, CryptoSuite::MLKEM768_MLDSA65],
            }),
        })
        .await?;

        sender_session.start().await?;
        receiver_session.start().await?;
        sender_session
            .notify_remote_join(&receiver_identity.state.device.device_id)
            .await?;

        let mut sender_runtime = SessionTransferRuntime::new();
        let mut receiver_runtime = SessionTransferRuntime::new();
        let sender_handle = sender_session.handle();
        let receiver_handle = receiver_session.handle();

        tokio::time::timeout(Duration::from_secs(15), async {
            let mut handshake_count = 0usize;
            while handshake_count < 2 {
                tokio::select! {
                    event = sender_session.next_event() => {
                        if let Some(event) = event {
                            match event {
                                NativeWebRtcEvent::SignalingEnvelope(envelope) => {
                                    receiver_session.handle_signaling_envelope(&envelope).await?;
                                }
                                NativeWebRtcEvent::HandshakeComplete { .. } => {
                                    handshake_count += 1;
                                }
                                NativeWebRtcEvent::TransportReady
                                | NativeWebRtcEvent::ApplicationPayload { .. }
                                | NativeWebRtcEvent::Keepalive { .. }
                                | NativeWebRtcEvent::TransportDisconnected { .. } => {}
                            }
                        }
                    }
                    event = receiver_session.next_event() => {
                        if let Some(event) = event {
                            match event {
                                NativeWebRtcEvent::SignalingEnvelope(envelope) => {
                                    sender_session.handle_signaling_envelope(&envelope).await?;
                                }
                                NativeWebRtcEvent::HandshakeComplete { .. } => {
                                    handshake_count += 1;
                                }
                                NativeWebRtcEvent::TransportReady
                                | NativeWebRtcEvent::ApplicationPayload { .. }
                                | NativeWebRtcEvent::Keepalive { .. }
                                | NativeWebRtcEvent::TransportDisconnected { .. } => {}
                            }
                        }
                    }
                    _ = tokio::time::sleep(Duration::from_millis(25)) => {}
                }
            }
            Ok::<(), anyhow::Error>(())
        })
        .await
        .map_err(|_| anyhow!("timed out waiting for handshake completion"))??;

        let source_path = root.join("payload.txt");
        fs::write(&source_path, b"session data channel file transfer").await?;
        let request = SessionFileTransferRequest::new_outgoing(
            "session-transfer-test",
            source_path.display().to_string(),
            "payload.txt",
            34,
            Some(receiver_identity.state.device.device_id.clone()),
            Some(receiver_identity.state.device.device_name.clone()),
        );
        save_session_transfer_request(&sender_paths, &request).await?;

        let outbound = tokio::spawn(run_outbound_request(
            sender_paths.clone(),
            request.clone(),
            sender_handle.clone(),
            sender_runtime.coordinator.clone(),
            sender_identity.clone(),
        ));

        let loop_result = tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                if outbound.is_finished() {
                    break Ok::<(), anyhow::Error>(());
                }
                tokio::select! {
                    event = sender_session.next_event() => {
                        if let Some(event) = event {
                            match event {
                                NativeWebRtcEvent::SignalingEnvelope(envelope) => {
                                    receiver_session.handle_signaling_envelope(&envelope).await?;
                                }
                                NativeWebRtcEvent::ApplicationPayload { payload } => {
                                    let _ = sender_runtime
                                        .handle_application_payload(
                                            &sender_paths,
                                            "session-transfer-test",
                                            &payload,
                                            &sender_handle,
                                        )
                                        .await?;
                                }
                                NativeWebRtcEvent::TransportReady
                                | NativeWebRtcEvent::HandshakeComplete { .. }
                                | NativeWebRtcEvent::Keepalive { .. }
                                | NativeWebRtcEvent::TransportDisconnected { .. } => {}
                            }
                        }
                    }
                    event = receiver_session.next_event() => {
                        if let Some(event) = event {
                            match event {
                                NativeWebRtcEvent::SignalingEnvelope(envelope) => {
                                    sender_session.handle_signaling_envelope(&envelope).await?;
                                }
                                NativeWebRtcEvent::ApplicationPayload { payload } => {
                                    let _ = receiver_runtime
                                        .handle_application_payload(
                                            &receiver_paths,
                                            "session-transfer-test",
                                            &payload,
                                            &receiver_handle,
                                        )
                                        .await?;
                                }
                                NativeWebRtcEvent::TransportReady
                                | NativeWebRtcEvent::HandshakeComplete { .. }
                                | NativeWebRtcEvent::Keepalive { .. }
                                | NativeWebRtcEvent::TransportDisconnected { .. } => {}
                            }
                        }
                    }
                    _ = tokio::time::sleep(Duration::from_millis(25)) => {}
                }
            }
        }).await;
        loop_result.map_err(|_| anyhow!("session transfer runtime test timed out"))??;
        outbound.await??;

        let completed = load_session_transfer_request(&sender_paths, &request.request_id)
            .await?
            .ok_or_else(|| anyhow!("missing completed request"))?;
        assert_eq!(completed.state, SessionTransferRequestState::Completed);

        let received_path = receive_dir.join("payload.txt");
        let received_body = fs::read_to_string(&received_path).await?;
        assert_eq!(received_body, "session data channel file transfer");

        sender_session.close().await?;
        receiver_session.close().await?;
        unsafe {
            std::env::remove_var("SKYBRIDGE_FILE_RECEIVE_DIR");
        }
        let _ = fs::remove_dir_all(root).await;
        Ok(())
    }
}
