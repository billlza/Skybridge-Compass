use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use flate2::Compression;
use flate2::read::ZlibDecoder;
use flate2::write::ZlibEncoder;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use uuid::Uuid;

pub const DEFAULT_FILE_TRANSFER_PORT: u16 = 8080;
pub const DEFAULT_CHUNK_SIZE_BYTES: usize = 512 * 1024;
pub const MAX_CHUNK_SIZE_BYTES: usize = 512 * 1024;
pub const MAX_MESSAGE_BYTES: usize = 2_000_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransferDirection {
    Incoming,
    Outgoing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TransferStatus {
    Completed,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransferHistoryEntry {
    pub transfer_id: String,
    pub direction: TransferDirection,
    pub status: TransferStatus,
    pub file_name: String,
    pub file_size: i64,
    pub local_path: Option<String>,
    pub remote_label: Option<String>,
    pub remote_device_id: Option<String>,
    pub remote_address: Option<String>,
    pub route_source: Option<String>,
    pub compression: Option<String>,
    pub file_hash: Option<String>,
    pub error: Option<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub started_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339::option")]
    pub completed_at: Option<OffsetDateTime>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TransferHistoryRegistry {
    pub schema_version: u32,
    pub entries: Vec<TransferHistoryEntry>,
}

impl Default for TransferHistoryRegistry {
    fn default() -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            entries: Vec::new(),
        }
    }
}

impl TransferHistoryRegistry {
    pub const SCHEMA_VERSION: u32 = 1;
    pub const MAX_ENTRIES: usize = 200;

    pub fn push(&mut self, entry: TransferHistoryEntry) {
        self.entries.push(entry);
        self.entries.sort_by(|lhs, rhs| rhs.started_at.cmp(&lhs.started_at));
        if self.entries.len() > Self::MAX_ENTRIES {
            self.entries.truncate(Self::MAX_ENTRIES);
        }
        self.schema_version = Self::SCHEMA_VERSION;
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileTransferMetadata {
    pub transfer_id: String,
    pub file_name: String,
    pub file_size: i64,
    pub file_hash: String,
    pub chunk_size: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compression: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_device_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_device_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_platform: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_os_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_model_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_chip: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileChunk {
    pub index: u32,
    #[serde(with = "base64_data")]
    pub data: Vec<u8>,
    pub size: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileTransferReceipt {
    pub transfer_id: String,
    pub success: bool,
    pub received_bytes: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_hash: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SendFileOptions {
    pub sender_device_id: Option<String>,
    pub sender_device_name: Option<String>,
    pub sender_platform: Option<String>,
    pub sender_os_version: Option<String>,
    pub sender_model_name: Option<String>,
    pub sender_chip: Option<String>,
    pub chunk_size: usize,
    pub compression: Option<String>,
    pub receipt_timeout: Duration,
}

impl Default for SendFileOptions {
    fn default() -> Self {
        Self {
            sender_device_id: None,
            sender_device_name: None,
            sender_platform: None,
            sender_os_version: None,
            sender_model_name: None,
            sender_chip: None,
            chunk_size: DEFAULT_CHUNK_SIZE_BYTES,
            compression: None,
            receipt_timeout: Duration::from_secs(15),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendFileResult {
    pub transfer_id: String,
    pub file_name: String,
    pub file_size: i64,
    pub file_hash: String,
    pub compression: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReceiveFileOptions {
    pub output_dir: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReceiveFileResult {
    pub transfer_id: String,
    pub sender_device_id: Option<String>,
    pub sender_device_name: Option<String>,
    pub file_name: String,
    pub file_size: i64,
    pub file_hash: String,
    pub saved_path: PathBuf,
    pub compression: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CrossNetworkFileTransferOp {
    Metadata,
    MetadataAck,
    Chunk,
    ChunkAck,
    Complete,
    CompleteAck,
    Cancel,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CrossNetworkFileTransferMessage {
    pub version: u32,
    pub op: CrossNetworkFileTransferOp,
    pub transfer_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_device_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_device_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_size: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chunk_size: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_chunks: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chunk_index: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "base64_option")]
    pub chunk_data: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "base64_option")]
    pub chunk_sha256: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "base64_option")]
    pub nonce: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw_size: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub received_bytes: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encryption: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "base64_option")]
    pub file_sha256: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "base64_option")]
    pub merkle_root: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "base64_option")]
    pub merkle_root_signature: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub merkle_root_signature_alg: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub missing_chunks: Option<Vec<i32>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch_index: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub batch_total: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relative_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

impl CrossNetworkFileTransferMessage {
    pub const VERSION: u32 = 1;

    pub fn new(op: CrossNetworkFileTransferOp, transfer_id: impl Into<String>) -> Self {
        Self {
            version: Self::VERSION,
            op,
            transfer_id: transfer_id.into(),
            sender_device_id: None,
            sender_device_name: None,
            file_name: None,
            file_size: None,
            chunk_size: None,
            total_chunks: None,
            mime_type: None,
            chunk_index: None,
            chunk_data: None,
            chunk_sha256: None,
            nonce: None,
            raw_size: None,
            received_bytes: None,
            encryption: None,
            file_sha256: None,
            merkle_root: None,
            merkle_root_signature: None,
            merkle_root_signature_alg: None,
            missing_chunks: None,
            batch_id: None,
            batch_index: None,
            batch_total: None,
            relative_path: None,
            message: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionTransferRequestState {
    Pending,
    InProgress,
    Completed,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionFileTransferRequest {
    pub schema_version: u32,
    pub request_id: String,
    pub session_id: String,
    pub source_path: String,
    pub file_name: String,
    pub file_size: i64,
    pub remote_device_id: Option<String>,
    pub remote_device_name: Option<String>,
    pub state: SessionTransferRequestState,
    pub transfer_id: Option<String>,
    pub file_hash: Option<String>,
    pub error: Option<String>,
    #[serde(with = "time::serde::rfc3339")]
    pub created_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub updated_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339::option")]
    pub started_at: Option<OffsetDateTime>,
    #[serde(with = "time::serde::rfc3339::option")]
    pub completed_at: Option<OffsetDateTime>,
}

impl SessionFileTransferRequest {
    pub const SCHEMA_VERSION: u32 = 1;

    pub fn new_outgoing(
        session_id: impl Into<String>,
        source_path: impl Into<String>,
        file_name: impl Into<String>,
        file_size: i64,
        remote_device_id: Option<String>,
        remote_device_name: Option<String>,
    ) -> Self {
        let now = OffsetDateTime::now_utc();
        Self {
            schema_version: Self::SCHEMA_VERSION,
            request_id: Uuid::now_v7().to_string(),
            session_id: session_id.into(),
            source_path: source_path.into(),
            file_name: file_name.into(),
            file_size,
            remote_device_id,
            remote_device_name,
            state: SessionTransferRequestState::Pending,
            transfer_id: None,
            file_hash: None,
            error: None,
            created_at: now,
            updated_at: now,
            started_at: None,
            completed_at: None,
        }
    }

    pub fn mark_in_progress(&mut self) {
        self.state = SessionTransferRequestState::InProgress;
        self.started_at = Some(OffsetDateTime::now_utc());
        self.updated_at = OffsetDateTime::now_utc();
        self.error = None;
    }

    pub fn mark_completed(
        &mut self,
        transfer_id: impl Into<String>,
        file_hash: impl Into<String>,
    ) {
        self.state = SessionTransferRequestState::Completed;
        self.transfer_id = Some(transfer_id.into());
        self.file_hash = Some(file_hash.into());
        self.error = None;
        self.completed_at = Some(OffsetDateTime::now_utc());
        self.updated_at = OffsetDateTime::now_utc();
    }

    pub fn mark_failed(&mut self, error: impl Into<String>) {
        self.state = SessionTransferRequestState::Failed;
        self.error = Some(error.into());
        self.completed_at = Some(OffsetDateTime::now_utc());
        self.updated_at = OffsetDateTime::now_utc();
    }
}

impl ReceiveFileOptions {
    pub fn new(output_dir: PathBuf) -> Self {
        Self { output_dir }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MessageType {
    Metadata = 1,
    Chunk = 2,
    Complete = 3,
    Receipt = 4,
}

impl MessageType {
    fn from_wire(value: u32) -> Option<Self> {
        match value {
            1 => Some(Self::Metadata),
            2 => Some(Self::Chunk),
            3 => Some(Self::Complete),
            4 => Some(Self::Receipt),
            _ => None,
        }
    }
}

pub async fn send_file_over_stream<S>(
    stream: &mut S,
    source_path: &Path,
    options: &SendFileOptions,
) -> Result<SendFileResult>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let metadata = tokio::fs::metadata(source_path)
        .await
        .with_context(|| format!("failed to stat {}", source_path.display()))?;
    if !metadata.is_file() {
        bail!("{} is not a regular file", source_path.display());
    }
    let file_name = source_path
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("source path has no valid file name"))?
        .to_owned();
    let file_size = i64::try_from(metadata.len()).context("file is too large to transfer")?;
    let file_hash = sha256_file_hex(source_path).await?;
    let transfer_id = Uuid::now_v7().to_string();
    let chunk_size = options.chunk_size.clamp(1, MAX_CHUNK_SIZE_BYTES);
    let metadata_payload = FileTransferMetadata {
        transfer_id: transfer_id.clone(),
        file_name: file_name.clone(),
        file_size,
        file_hash: file_hash.clone(),
        chunk_size,
        compression: normalized_compression(options.compression.as_deref()),
        sender_device_id: options.sender_device_id.clone(),
        sender_device_name: options.sender_device_name.clone(),
        sender_platform: options.sender_platform.clone(),
        sender_os_version: options.sender_os_version.clone(),
        sender_model_name: options.sender_model_name.clone(),
        sender_chip: options.sender_chip.clone(),
    };
    write_message(stream, MessageType::Metadata, &metadata_payload).await?;

    let mut handle = tokio::fs::File::open(source_path)
        .await
        .with_context(|| format!("failed to open {}", source_path.display()))?;
    let mut buffer = vec![0_u8; chunk_size];
    let mut index = 0_u32;
    loop {
        let read = handle.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        let raw = &buffer[..read];
        let payload = maybe_compress(raw, metadata_payload.compression.as_deref())?;
        let chunk = FileChunk {
            index,
            data: payload,
            size: raw.len(),
        };
        write_message(stream, MessageType::Chunk, &chunk).await?;
        index = index.saturating_add(1);
    }

    write_header(stream, MessageType::Complete, 0).await?;
    let receipt = tokio::time::timeout(
        options.receipt_timeout,
        read_message::<S, FileTransferReceipt>(stream, MessageType::Receipt),
    )
    .await
    .map_err(|_| anyhow!("timed out waiting for receiver receipt"))??;
    if receipt.transfer_id != transfer_id {
        bail!("receiver returned mismatched transfer id");
    }
    if !receipt.success {
        bail!(
            "receiver rejected transfer: {}",
            receipt.error.unwrap_or_else(|| "unknown error".to_owned())
        );
    }
    if receipt.received_bytes != file_size {
        bail!(
            "receiver reported {} bytes, expected {}",
            receipt.received_bytes,
            file_size
        );
    }
    if let Some(peer_hash) = receipt.file_hash.as_deref() {
        if !peer_hash.eq_ignore_ascii_case(&file_hash) {
            bail!("receiver reported a mismatched file hash");
        }
    }

    Ok(SendFileResult {
        transfer_id,
        file_name,
        file_size,
        file_hash,
        compression: metadata_payload.compression,
    })
}

pub async fn receive_file_over_stream<S>(
    stream: &mut S,
    options: &ReceiveFileOptions,
) -> Result<ReceiveFileResult>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let metadata = read_message::<S, FileTransferMetadata>(stream, MessageType::Metadata).await?;
    let transfer_id = metadata.transfer_id.clone();
    let receive_result = receive_file_over_stream_inner(stream, &metadata, options).await;
    if let Err(error) = &receive_result {
        let receipt = FileTransferReceipt {
            transfer_id,
            success: false,
            received_bytes: 0,
            file_hash: None,
            error: Some(error.to_string()),
        };
        let _ = write_message(stream, MessageType::Receipt, &receipt).await;
    }
    receive_result
}

async fn receive_file_over_stream_inner<S>(
    stream: &mut S,
    metadata: &FileTransferMetadata,
    options: &ReceiveFileOptions,
) -> Result<ReceiveFileResult>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    if metadata.file_size < 0 {
        bail!("negative file size is invalid");
    }
    if metadata.chunk_size == 0 || metadata.chunk_size > MAX_CHUNK_SIZE_BYTES {
        bail!("chunk size {} is invalid", metadata.chunk_size);
    }

    tokio::fs::create_dir_all(&options.output_dir)
        .await
        .with_context(|| {
            format!(
                "failed to create output directory {}",
                options.output_dir.display()
            )
        })?;

    let final_name = sanitized_file_name(&metadata.file_name);
    let final_path = unique_output_path(&options.output_dir, &final_name).await?;
    let temp_path = temporary_output_path(&final_path, &metadata.transfer_id);
    let mut file = tokio::fs::File::create(&temp_path)
        .await
        .with_context(|| format!("failed to create {}", temp_path.display()))?;

    let mut received_bytes = 0_i64;
    while received_bytes < metadata.file_size {
        let chunk = read_message::<S, FileChunk>(stream, MessageType::Chunk).await?;
        if chunk.size == 0 || chunk.size > MAX_CHUNK_SIZE_BYTES {
            bail!("received invalid chunk size {}", chunk.size);
        }
        let payload = maybe_decompress(&chunk.data, metadata.compression.as_deref())?;
        if payload.len() != chunk.size {
            bail!(
                "decoded chunk {} length mismatch: got {}, expected {}",
                chunk.index,
                payload.len(),
                chunk.size
            );
        }
        file.write_all(&payload).await?;
        received_bytes = received_bytes
            .checked_add(i64::try_from(chunk.size).context("chunk size overflow")?)
            .ok_or_else(|| anyhow!("received byte count overflow"))?;
    }
    file.flush().await?;
    drop(file);

    read_complete(stream).await?;

    let file_hash = sha256_file_hex(&temp_path).await?;
    if !file_hash.eq_ignore_ascii_case(&metadata.file_hash) {
        let _ = tokio::fs::remove_file(&temp_path).await;
        bail!("file integrity check failed");
    }
    tokio::fs::rename(&temp_path, &final_path)
        .await
        .with_context(|| {
            format!(
                "failed to move {} into {}",
                temp_path.display(),
                final_path.display()
            )
        })?;

    let receipt = FileTransferReceipt {
        transfer_id: metadata.transfer_id.clone(),
        success: true,
        received_bytes,
        file_hash: Some(file_hash.clone()),
        error: None,
    };
    write_message(stream, MessageType::Receipt, &receipt).await?;

    Ok(ReceiveFileResult {
        transfer_id: metadata.transfer_id.clone(),
        sender_device_id: metadata.sender_device_id.clone(),
        sender_device_name: metadata.sender_device_name.clone(),
        file_name: final_name,
        file_size: metadata.file_size,
        file_hash,
        saved_path: final_path,
        compression: metadata.compression.clone(),
    })
}

pub async fn sha256_file_hex(path: &Path) -> Result<String> {
    let mut file = tokio::fs::File::open(path)
        .await
        .with_context(|| format!("failed to open {}", path.display()))?;
    let mut buffer = vec![0_u8; DEFAULT_CHUNK_SIZE_BYTES];
    let mut hasher = Sha256::new();
    loop {
        let read = file.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hex_lower(&hasher.finalize()))
}

async fn write_message<S, T>(stream: &mut S, kind: MessageType, payload: &T) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
    T: Serialize,
{
    let body = serde_json::to_vec(payload).context("failed to encode transfer payload")?;
    if body.len() > MAX_MESSAGE_BYTES {
        bail!("transfer payload exceeds {} bytes", MAX_MESSAGE_BYTES);
    }
    write_header(stream, kind, body.len()).await?;
    stream.write_all(&body).await?;
    stream.flush().await?;
    Ok(())
}

async fn read_message<S, T>(stream: &mut S, expected: MessageType) -> Result<T>
where
    S: AsyncRead + AsyncWrite + Unpin,
    T: for<'de> Deserialize<'de>,
{
    let (kind, length) = read_header(stream).await?;
    if kind != expected {
        bail!("unexpected message type {}", kind as u32);
    }
    let mut body = vec![0_u8; length];
    stream.read_exact(&mut body).await?;
    Ok(serde_json::from_slice(&body).context("failed to decode transfer payload")?)
}

async fn read_complete<S>(stream: &mut S) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let (kind, length) = read_header(stream).await?;
    if kind != MessageType::Complete || length != 0 {
        bail!("unexpected transfer completion frame");
    }
    Ok(())
}

async fn write_header<S>(stream: &mut S, kind: MessageType, length: usize) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    if length > MAX_MESSAGE_BYTES {
        bail!("transfer frame exceeds {} bytes", MAX_MESSAGE_BYTES);
    }
    let mut header = [0_u8; 8];
    header[..4].copy_from_slice(&(kind as u32).to_be_bytes());
    header[4..].copy_from_slice(&(length as u32).to_be_bytes());
    stream.write_all(&header).await?;
    Ok(())
}

async fn read_header<S>(stream: &mut S) -> Result<(MessageType, usize)>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut header = [0_u8; 8];
    stream.read_exact(&mut header).await?;
    let kind = u32::from_be_bytes(header[..4].try_into().expect("header type slice"));
    let length = u32::from_be_bytes(header[4..].try_into().expect("header length slice"));
    let kind = MessageType::from_wire(kind).ok_or_else(|| anyhow!("unknown message type"))?;
    let length = usize::try_from(length).context("message length overflow")?;
    if length > MAX_MESSAGE_BYTES {
        bail!("message length {} exceeds limit", length);
    }
    Ok((kind, length))
}

fn normalized_compression(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_ascii_lowercase())
}

fn maybe_compress(data: &[u8], compression: Option<&str>) -> Result<Vec<u8>> {
    match normalized_compression(compression).as_deref() {
        Some("zlib") => {
            let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
            std::io::Write::write_all(&mut encoder, data)?;
            encoder.finish().context("failed to finish zlib compression")
        }
        Some(other) => bail!("unsupported compression `{other}`"),
        None => Ok(data.to_vec()),
    }
}

fn maybe_decompress(data: &[u8], compression: Option<&str>) -> Result<Vec<u8>> {
    match normalized_compression(compression).as_deref() {
        Some("zlib") => {
            let mut decoder = ZlibDecoder::new(data);
            let mut decoded = Vec::new();
            std::io::Read::read_to_end(&mut decoder, &mut decoded)
                .context("failed to inflate zlib payload")?;
            Ok(decoded)
        }
        Some(other) => bail!("unsupported compression `{other}`"),
        None => Ok(data.to_vec()),
    }
}

fn sanitized_file_name(file_name: &str) -> String {
    Path::new(file_name)
        .file_name()
        .and_then(|value| value.to_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| "received-file".to_owned())
}

async fn unique_output_path(output_dir: &Path, file_name: &str) -> Result<PathBuf> {
    let candidate = output_dir.join(file_name);
    if !tokio::fs::try_exists(&candidate).await? {
        return Ok(candidate);
    }

    let stem = Path::new(file_name)
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("received-file");
    let extension = Path::new(file_name)
        .extension()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty());

    for index in 1..=999 {
        let candidate_name = match extension {
            Some(extension) => format!("{stem}-{index}.{extension}"),
            None => format!("{stem}-{index}"),
        };
        let candidate = output_dir.join(candidate_name);
        if !tokio::fs::try_exists(&candidate).await? {
            return Ok(candidate);
        }
    }

    bail!("failed to allocate a unique output file name");
}

fn temporary_output_path(final_path: &Path, transfer_id: &str) -> PathBuf {
    let suffix = transfer_id
        .chars()
        .take(8)
        .collect::<String>()
        .chars()
        .map(|value| {
            if value.is_ascii_alphanumeric() {
                value
            } else {
                'x'
            }
        })
        .collect::<String>();
    let mut extension = final_path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_owned();
    if extension.is_empty() {
        extension = format!("part-{suffix}");
    } else {
        extension = format!("{extension}.part-{suffix}");
    }
    final_path.with_extension(extension)
}

fn hex_lower(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
}

mod base64_data {
    use super::*;

    pub fn serialize<S>(value: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&STANDARD.encode(value))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        STANDARD
            .decode(value.as_bytes())
            .map_err(serde::de::Error::custom)
    }
}

mod base64_option {
    use super::*;

    pub fn serialize<S>(value: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match value {
            Some(value) => serializer.serialize_some(&STANDARD.encode(value)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = Option::<String>::deserialize(deserializer)?;
        value
            .map(|encoded| {
                STANDARD
                    .decode(encoded.as_bytes())
                    .map_err(serde::de::Error::custom)
            })
            .transpose()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::{TcpListener, TcpStream};

    #[tokio::test]
    async fn tcp_file_transfer_round_trip_completes() -> Result<()> {
        let root = std::env::temp_dir().join(format!("skybridge-file-transfer-{}", Uuid::now_v7()));
        let source_dir = root.join("source");
        let sink_dir = root.join("sink");
        tokio::fs::create_dir_all(&source_dir).await?;
        tokio::fs::create_dir_all(&sink_dir).await?;
        let source_path = source_dir.join("hello.txt");
        tokio::fs::write(&source_path, b"hello from skybridge").await?;

        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let address = listener.local_addr()?;
        let receive_task = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await?;
            receive_file_over_stream(&mut socket, &ReceiveFileOptions::new(sink_dir)).await
        });

        let mut client = TcpStream::connect(address).await?;
        let sent = send_file_over_stream(&mut client, &source_path, &SendFileOptions::default()).await?;
        let received = receive_task.await??;
        let saved = tokio::fs::read(&received.saved_path).await?;

        assert_eq!(sent.transfer_id, received.transfer_id);
        assert_eq!(received.file_name, "hello.txt");
        assert_eq!(saved, b"hello from skybridge");
        assert_eq!(sent.file_hash, received.file_hash);

        let _ = tokio::fs::remove_dir_all(root).await;
        Ok(())
    }

    #[tokio::test]
    async fn tcp_file_transfer_round_trip_with_zlib_compression() -> Result<()> {
        let root = std::env::temp_dir().join(format!("skybridge-file-transfer-zlib-{}", Uuid::now_v7()));
        let source_dir = root.join("source");
        let sink_dir = root.join("sink");
        tokio::fs::create_dir_all(&source_dir).await?;
        tokio::fs::create_dir_all(&sink_dir).await?;
        let source_path = source_dir.join("payload.bin");
        tokio::fs::write(&source_path, vec![42_u8; 256 * 1024]).await?;

        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let address = listener.local_addr()?;
        let receive_task = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await?;
            receive_file_over_stream(&mut socket, &ReceiveFileOptions::new(sink_dir)).await
        });

        let mut client = TcpStream::connect(address).await?;
        let sent = send_file_over_stream(
            &mut client,
            &source_path,
            &SendFileOptions {
                compression: Some("zlib".to_owned()),
                ..SendFileOptions::default()
            },
        )
        .await?;
        let received = receive_task.await??;
        let saved = tokio::fs::read(&received.saved_path).await?;

        assert_eq!(saved.len(), 256 * 1024);
        assert!(saved.iter().all(|byte| *byte == 42));
        assert_eq!(sent.file_hash, received.file_hash);

        let _ = tokio::fs::remove_dir_all(root).await;
        Ok(())
    }
}
