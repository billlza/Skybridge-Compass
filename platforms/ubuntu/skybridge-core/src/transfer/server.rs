//! File transfer TCP server for macOS/iOS interoperability.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use bytes::BytesMut;
use flate2::read::ZlibDecoder;
use sha2::Digest;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use tracing::{error, info};

use super::keys::TransferKeyStore;
use super::{
    FileTransferEngine, FileTransferMetadataWire, IncomingTransferCompleted,
    IncomingTransferDecision, IncomingTransferPromptConfig, IncomingTransferPromptRequest,
    IncomingTransferRequest, IncomingTransferSource,
};

const MAC_LAN_MAX_MESSAGE_BYTES: usize = 2_000_000;

/// File transfer server configuration.
#[derive(Debug, Clone)]
pub struct FileTransferServerConfig {
    pub bind_addr: SocketAddr,
    pub target_dir: PathBuf,
    pub incoming_prompt: Option<IncomingTransferPromptConfig>,
}

impl Default for FileTransferServerConfig {
    fn default() -> Self {
        let default_dir = directories::UserDirs::new()
            .and_then(|dirs| dirs.download_dir().map(|d| d.to_path_buf()))
            .unwrap_or_else(|| PathBuf::from("/tmp"));
        Self {
            // Pro-release compatible LAN transfer default (matches macOS/iOS `FileTransferListenerService`).
            bind_addr: "0.0.0.0:8080".parse().unwrap(),
            target_dir: default_dir,
            incoming_prompt: None,
        }
    }
}

/// File transfer server.
pub struct FileTransferServer {
    config: FileTransferServerConfig,
    engine: Arc<FileTransferEngine>,
    key_store: Arc<TransferKeyStore>,
}

impl FileTransferServer {
    /// Create a new file transfer server.
    pub fn new(
        config: FileTransferServerConfig,
        engine: Arc<FileTransferEngine>,
        key_store: Arc<TransferKeyStore>,
    ) -> Self {
        Self {
            config,
            engine,
            key_store,
        }
    }

    /// Start serving incoming file transfers.
    pub async fn serve(&self) -> Result<(), std::io::Error> {
        let listener = TcpListener::bind(self.config.bind_addr).await?;
        info!(
            "File transfer server listening on {}",
            self.config.bind_addr
        );

        loop {
            let (stream, addr) = listener.accept().await?;
            let engine = Arc::clone(&self.engine);
            let key_store = Arc::clone(&self.key_store);
            let target_dir = self.config.target_dir.clone();
            let incoming_prompt = self.config.incoming_prompt.clone();

            tokio::spawn(async move {
                if let Err(err) =
                    handle_connection(engine, key_store, target_dir, incoming_prompt, stream).await
                {
                    error!("Transfer connection {} failed: {}", addr, err);
                }
            });
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TransferWireFlavor {
    /// Pro release `_skybridge-transfer._tcp` JSON wire used by `FileTransferManager`.
    MacLanJson,
    /// Ubuntu "quantum" wire (fixed binary chunk headers).
    QuantumWire,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
enum MacLanMessageType {
    Metadata = 1,
    Chunk = 2,
    Complete = 3,
    Receipt = 4,
}

impl MacLanMessageType {
    fn from_raw(raw: u32) -> Option<Self> {
        match raw {
            1 => Some(Self::Metadata),
            2 => Some(Self::Chunk),
            3 => Some(Self::Complete),
            4 => Some(Self::Receipt),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct MacLanFileMetadata {
    transfer_id: String,
    file_name: String,
    file_size: i64,
    file_hash: String,
    chunk_size: i32,
    compression: Option<String>,
    sender_device_id: Option<String>,
    sender_device_name: Option<String>,
    sender_platform: Option<String>,
    sender_os_version: Option<String>,
    sender_model_name: Option<String>,
    sender_chip: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct MacLanFileChunk {
    index: i32,
    #[serde(with = "serde_base64")]
    data: Vec<u8>,
    size: i32,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct MacLanFileTransferReceipt {
    transfer_id: String,
    success: bool,
    received_bytes: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_hash: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

mod serde_base64 {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    use serde::Deserialize;

    pub fn serialize<S>(bytes: &Vec<u8>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let encoded = STANDARD.encode(bytes);
        serializer.serialize_str(&encoded)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        STANDARD
            .decode(s.as_bytes())
            .map_err(serde::de::Error::custom)
    }
}

struct PrefixedStream<S> {
    prefix: std::io::Cursor<Vec<u8>>,
    inner: S,
}

impl<S> PrefixedStream<S> {
    fn new(prefix: Vec<u8>, inner: S) -> Self {
        Self {
            prefix: std::io::Cursor::new(prefix),
            inner,
        }
    }
}

impl<S> AsyncRead for PrefixedStream<S>
where
    S: AsyncRead + Unpin,
{
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        if (self.prefix.position() as usize) < self.prefix.get_ref().len() {
            let remaining = self.prefix.get_ref().len() - (self.prefix.position() as usize);
            if remaining == 0 {
                return std::pin::Pin::new(&mut self.inner).poll_read(cx, buf);
            }
            let to_copy = remaining.min(buf.remaining());
            let start = self.prefix.position() as usize;
            let end = start + to_copy;
            buf.put_slice(&self.prefix.get_ref()[start..end]);
            self.prefix.set_position(end as u64);
            return std::task::Poll::Ready(Ok(()));
        }
        std::pin::Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl<S> AsyncWrite for PrefixedStream<S>
where
    S: AsyncWrite + Unpin,
{
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<Result<usize, std::io::Error>> {
        std::pin::Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<(), std::io::Error>> {
        std::pin::Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<(), std::io::Error>> {
        std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

async fn handle_connection(
    engine: Arc<FileTransferEngine>,
    key_store: Arc<TransferKeyStore>,
    target_dir: PathBuf,
    incoming_prompt: Option<IncomingTransferPromptConfig>,
    mut stream: tokio::net::TcpStream,
) -> Result<(), std::io::Error> {
    let (flavor, prefix) = sniff_wire_flavor(&mut stream).await?;
    let stream = PrefixedStream::new(prefix, stream);

    match flavor {
        TransferWireFlavor::MacLanJson => {
            handle_mac_lan_json(engine, target_dir, incoming_prompt, stream).await?;
        }
        TransferWireFlavor::QuantumWire => {
            let key_provider = move |meta: &FileTransferMetadataWire| -> Option<Vec<u8>> {
                meta.signer_peer_id
                    .as_ref()
                    .and_then(|peer| key_store.recv_file_key(peer))
            };
            let _ = engine
                .receive_file_over_wire_with_key_provider_and_prompt(
                    stream,
                    target_dir,
                    key_provider,
                    incoming_prompt,
                )
                .await?;
        }
    }
    Ok(())
}

async fn sniff_wire_flavor(
    stream: &mut tokio::net::TcpStream,
) -> Result<(TransferWireFlavor, Vec<u8>), std::io::Error> {
    let mut header = [0u8; 8];
    stream.read_exact(&mut header).await?;
    let raw_type = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
    let len = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;
    if len > MAC_LAN_MAX_MESSAGE_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "initial message too large",
        ));
    }
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload).await?;

    let mut prefix = Vec::with_capacity(8 + payload.len());
    prefix.extend_from_slice(&header);
    prefix.extend_from_slice(&payload);

    let Some(msg_type) = MacLanMessageType::from_raw(raw_type) else {
        return Ok((TransferWireFlavor::QuantumWire, prefix));
    };
    if msg_type != MacLanMessageType::Metadata {
        return Ok((TransferWireFlavor::QuantumWire, prefix));
    }

    // If the metadata matches the Pro-release JSON schema, handle it as Mac LAN.
    if serde_json::from_slice::<MacLanFileMetadata>(&payload).is_ok() {
        return Ok((TransferWireFlavor::MacLanJson, prefix));
    }

    Ok((TransferWireFlavor::QuantumWire, prefix))
}

async fn handle_mac_lan_json<S>(
    _engine: Arc<FileTransferEngine>,
    target_dir: PathBuf,
    incoming_prompt: Option<IncomingTransferPromptConfig>,
    mut stream: S,
) -> Result<(), std::io::Error>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let (msg_type, meta_payload) = read_mac_lan_frame(&mut stream).await?;
    if msg_type != MacLanMessageType::Metadata {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "expected metadata",
        ));
    }
    let meta: MacLanFileMetadata = serde_json::from_slice(&meta_payload).map_err(map_serde_err)?;

    let file_name = sanitize_file_name(&meta.file_name)
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "invalid file name"))?;
    let file_size = meta.file_size.max(0) as u64;
    let chunk_size = meta.chunk_size.max(1) as usize;
    if chunk_size > MAC_LAN_MAX_MESSAGE_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "chunkSize too large",
        ));
    }

    let compression = meta
        .compression
        .as_deref()
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty());
    if let Some(c) = compression.as_deref()
        && c != "zlib"
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "unsupported compression",
        ));
    }

    let mut selected_path: Option<PathBuf> = None;
    let mut overwrite = true;

    if let Some(prompt) = incoming_prompt.as_ref() {
        let request = IncomingTransferRequest {
            source: IncomingTransferSource::MacLanJson,
            transfer_id: meta.transfer_id.clone(),
            file_name: file_name.clone(),
            file_size,
            sender_device_id: meta.sender_device_id.clone(),
            sender_device_name: meta.sender_device_name.clone(),
            target_dir: target_dir.clone(),
        };

        let decision = prompt_incoming_transfer(prompt, request).await;
        if !decision.accept {
            send_mac_lan_receipt(
                &mut stream,
                &meta.transfer_id,
                false,
                0,
                None,
                Some("declined".to_string()),
            )
            .await?;
            if let Some(tx) = prompt.completed_tx.as_ref() {
                let _ = tx.send(IncomingTransferCompleted {
                    source: IncomingTransferSource::MacLanJson,
                    transfer_id: meta.transfer_id.clone(),
                    file_name,
                    save_path: None,
                    success: false,
                    received_bytes: 0,
                    error: Some("declined".to_string()),
                    sender_device_id: meta.sender_device_id.clone(),
                    sender_device_name: meta.sender_device_name.clone(),
                });
            }
            return Ok(());
        }
        selected_path = decision.save_path;
        overwrite = decision.overwrite;
        if selected_path.is_none() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "missing save path",
            ));
        }
    }

    tokio::fs::create_dir_all(&target_dir).await?;
    let path = if let Some(path) = selected_path {
        if let Some(parent) = path.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        path
    } else {
        choose_unique_path(&target_dir, &file_name).await?
    };

    let mut open = tokio::fs::OpenOptions::new();
    open.write(true);
    if overwrite {
        open.create(true).truncate(true);
    } else {
        open.create_new(true);
    }
    let mut file = open.open(&path).await?;

    let mut received_bytes: u64 = 0;
    let mut expected_index: i32 = 0;
    let mut hasher = sha2::Sha256::new();

    while received_bytes < file_size {
        let (t, payload) = read_mac_lan_frame(&mut stream).await?;
        if t != MacLanMessageType::Chunk {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "expected chunk",
            ));
        }
        let chunk: MacLanFileChunk = serde_json::from_slice(&payload).map_err(map_serde_err)?;

        if chunk.index != expected_index {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "unexpected chunk index",
            ));
        }
        expected_index = expected_index.saturating_add(1);

        let raw_size = chunk.size.max(0) as usize;
        if raw_size == 0 && file_size > 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "empty chunk size",
            ));
        }

        let mut data = if compression.is_some() {
            decompress_zlib(&chunk.data)?
        } else {
            chunk.data
        };
        if data.len() != raw_size {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "chunk size mismatch",
            ));
        }

        // Prevent writing past declared size. Sender should not exceed, but cap defensively.
        let remaining = (file_size - received_bytes).min(data.len() as u64) as usize;
        data.truncate(remaining);
        file.write_all(&data).await?;
        hasher.update(&data);
        received_bytes = received_bytes
            .saturating_add(raw_size as u64)
            .min(file_size);
    }

    let (t, _) = read_mac_lan_frame(&mut stream).await?;
    if t != MacLanMessageType::Complete {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "expected complete",
        ));
    }
    file.flush().await?;
    let _ = file.sync_all().await;

    let computed_hash = hex::encode(hasher.finalize());
    let expected_hash = meta.file_hash.trim().to_ascii_lowercase();
    let ok = !expected_hash.is_empty() && computed_hash == expected_hash;

    send_mac_lan_receipt(
        &mut stream,
        &meta.transfer_id,
        ok,
        received_bytes,
        if ok { Some(computed_hash) } else { None },
        if ok {
            None
        } else {
            Some("file hash mismatch".to_string())
        },
    )
    .await?;

    if let Some(prompt) = incoming_prompt.as_ref()
        && let Some(tx) = prompt.completed_tx.as_ref()
    {
        let _ = tx.send(IncomingTransferCompleted {
            source: IncomingTransferSource::MacLanJson,
            transfer_id: meta.transfer_id.clone(),
            file_name,
            save_path: Some(path.clone()),
            success: ok,
            received_bytes,
            error: if ok {
                None
            } else {
                Some("file hash mismatch".to_string())
            },
            sender_device_id: meta.sender_device_id.clone(),
            sender_device_name: meta.sender_device_name.clone(),
        });
    }

    Ok(())
}

async fn prompt_incoming_transfer(
    prompt: &IncomingTransferPromptConfig,
    request: IncomingTransferRequest,
) -> IncomingTransferDecision {
    let (tx, rx) = tokio::sync::oneshot::channel::<IncomingTransferDecision>();
    if prompt
        .request_tx
        .send(IncomingTransferPromptRequest {
            request,
            decision_tx: tx,
        })
        .is_err()
    {
        return IncomingTransferDecision::decline();
    }
    match tokio::time::timeout(prompt.decision_timeout, rx).await {
        Ok(Ok(decision)) => decision,
        Ok(Err(_)) => IncomingTransferDecision::decline(),
        Err(_) => IncomingTransferDecision::decline(),
    }
}

async fn send_mac_lan_receipt<S>(
    stream: &mut S,
    transfer_id: &str,
    success: bool,
    received_bytes: u64,
    file_hash: Option<String>,
    error: Option<String>,
) -> Result<(), std::io::Error>
where
    S: AsyncWrite + Unpin,
{
    let receipt = MacLanFileTransferReceipt {
        transfer_id: transfer_id.to_string(),
        success,
        received_bytes: received_bytes as i64,
        file_hash,
        error,
    };
    let receipt_json = serde_json::to_vec(&receipt).map_err(map_serde_err)?;
    write_mac_lan_frame(stream, MacLanMessageType::Receipt, &receipt_json).await
}

async fn read_mac_lan_frame<S>(
    stream: &mut S,
) -> Result<(MacLanMessageType, Vec<u8>), std::io::Error>
where
    S: AsyncRead + Unpin,
{
    let mut header = [0u8; 8];
    stream.read_exact(&mut header).await?;
    let raw_type = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
    let len = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;
    let msg_type = MacLanMessageType::from_raw(raw_type).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "unknown message type")
    })?;
    if len > MAC_LAN_MAX_MESSAGE_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "message too large",
        ));
    }
    let mut payload = vec![0u8; len];
    if len > 0 {
        stream.read_exact(&mut payload).await?;
    }
    Ok((msg_type, payload))
}

async fn write_mac_lan_frame<S>(
    stream: &mut S,
    msg_type: MacLanMessageType,
    payload: &[u8],
) -> Result<(), std::io::Error>
where
    S: AsyncWrite + Unpin,
{
    let len = payload.len();
    if len > MAC_LAN_MAX_MESSAGE_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "payload too large",
        ));
    }
    let mut out = BytesMut::with_capacity(8 + len);
    out.extend_from_slice(&(msg_type as u32).to_be_bytes());
    out.extend_from_slice(&(len as u32).to_be_bytes());
    out.extend_from_slice(payload);
    stream.write_all(&out).await?;
    stream.flush().await?;
    Ok(())
}

fn decompress_zlib(input: &[u8]) -> Result<Vec<u8>, std::io::Error> {
    use std::io::Read;
    let mut decoder = ZlibDecoder::new(input);
    let mut out = Vec::new();
    decoder.read_to_end(&mut out)?;
    Ok(out)
}

fn sanitize_file_name(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let file_name = std::path::Path::new(trimmed)
        .file_name()
        .and_then(|s| s.to_str())?;
    let sanitized = file_name
        .chars()
        .map(|c| if c == '/' || c == '\\' { '_' } else { c })
        .collect::<String>()
        .trim()
        .to_string();
    if sanitized.is_empty() {
        None
    } else {
        Some(sanitized)
    }
}

async fn choose_unique_path(dir: &Path, file_name: &str) -> Result<PathBuf, std::io::Error> {
    let mut candidate = dir.join(file_name);
    if tokio::fs::try_exists(&candidate).await.unwrap_or(false) {
        let stem = std::path::Path::new(file_name)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("file");
        let ext = std::path::Path::new(file_name)
            .extension()
            .and_then(|s| s.to_str());
        for idx in 1..=999 {
            let name = if let Some(ext) = ext {
                format!("{} ({}){}.{}", stem, idx, "", ext)
            } else {
                format!("{} ({})", stem, idx)
            };
            let p = dir.join(name);
            if !tokio::fs::try_exists(&p).await.unwrap_or(false) {
                candidate = p;
                break;
            }
        }
    }
    Ok(candidate)
}

fn map_serde_err(err: impl std::fmt::Display) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, err.to_string())
}
