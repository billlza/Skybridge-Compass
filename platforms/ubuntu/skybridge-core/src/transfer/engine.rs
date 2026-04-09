//! File Transfer Engine
//!
//! Handles file transfer with BLAKE3 verification, persistent resumption,
//! adaptive compression (LZ4/Zstd), and parallel chunk processing.

use blake3::Hasher;
use chrono::Utc;
use parking_lot::RwLock as SyncRwLock;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::fs::File;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeekExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::RwLock;
use tracing::{info, warn};

use super::types::{
    ChunkInfo, CompressionStrategy, FileMetadata, FileTransfer, TransferConfig, TransferDirection,
    TransferManifest, TransferState,
};
use super::wire::{FileChunkPacketWire, FileTransferMetadataWire, FileTransferWire};
use super::{
    IncomingTransferCompleted, IncomingTransferDecision, IncomingTransferPromptConfig,
    IncomingTransferPromptRequest, IncomingTransferRequest, IncomingTransferSource,
};
use crate::crypto::aead::{AeadProvider, AesGcmProvider, EncryptedData};

type ProgressCallback = Arc<dyn Fn(&FileTransfer) + Send + Sync>;
type CompletionCallback = Arc<dyn Fn(&FileTransfer) + Send + Sync>;
type ChunkVerifiedCallback = Arc<dyn Fn(&str, u64, &str) + Send + Sync>;

/// Chunk data with metadata for transfer
#[derive(Debug, Clone)]
pub struct ChunkData {
    /// Chunk index
    pub index: u64,
    /// Raw or compressed data
    pub data: Vec<u8>,
    /// BLAKE3 hash of original (uncompressed) data
    pub hash: String,
    /// Whether data is compressed
    pub compressed: bool,
    /// Original size before compression
    pub original_size: usize,
}

/// File transfer engine with enhanced capabilities
pub struct FileTransferEngine {
    /// Configuration
    config: SyncRwLock<TransferConfig>,
    /// Active transfers
    transfers: Arc<RwLock<HashMap<String, FileTransfer>>>,
    /// Transfer manifests for resume support
    manifests: Arc<RwLock<HashMap<String, TransferManifest>>>,
    /// Progress callback
    on_progress: Option<ProgressCallback>,
    /// Completion callback
    on_complete: Option<CompletionCallback>,
    /// Chunk verified callback
    on_chunk_verified: Option<ChunkVerifiedCallback>,
}

impl FileTransferEngine {
    /// Create a new file transfer engine
    pub fn new() -> Self {
        Self::with_config(TransferConfig::default())
    }

    /// Create with custom configuration
    pub fn with_config(config: TransferConfig) -> Self {
        Self {
            config: SyncRwLock::new(config),
            transfers: Arc::new(RwLock::new(HashMap::new())),
            manifests: Arc::new(RwLock::new(HashMap::new())),
            on_progress: None,
            on_complete: None,
            on_chunk_verified: None,
        }
    }

    /// Set progress callback
    pub fn on_progress<F>(&mut self, callback: F)
    where
        F: Fn(&FileTransfer) + Send + Sync + 'static,
    {
        self.on_progress = Some(Arc::new(callback));
    }

    /// Set completion callback
    pub fn on_complete<F>(&mut self, callback: F)
    where
        F: Fn(&FileTransfer) + Send + Sync + 'static,
    {
        self.on_complete = Some(Arc::new(callback));
    }

    /// Set chunk verified callback
    pub fn on_chunk_verified<F>(&mut self, callback: F)
    where
        F: Fn(&str, u64, &str) + Send + Sync + 'static,
    {
        self.on_chunk_verified = Some(Arc::new(callback));
    }

    /// Get transfer configuration
    pub fn config(&self) -> TransferConfig {
        self.config.read().clone()
    }

    /// Update transfer configuration
    pub fn set_config(&self, config: TransferConfig) {
        *self.config.write() = config;
    }

    fn config_snapshot(&self) -> TransferConfig {
        self.config.read().clone()
    }

    /// Get manifest directory
    fn manifest_dir(&self) -> PathBuf {
        let config = self.config_snapshot();
        config.manifest_dir.clone().unwrap_or_else(|| {
            directories::ProjectDirs::from("com", "skybridge", "transfer")
                .map(|d| d.data_dir().to_path_buf())
                .unwrap_or_else(|| PathBuf::from("/tmp/skybridge-transfer"))
        })
    }

    /// Get all transfers
    pub async fn transfers(&self) -> Vec<FileTransfer> {
        let transfers = self.transfers.read().await;
        transfers.values().cloned().collect()
    }

    /// Get transfer by ID
    pub async fn get_transfer(&self, id: &str) -> Option<FileTransfer> {
        let transfers = self.transfers.read().await;
        transfers.get(id).cloned()
    }

    /// Get active transfers
    pub async fn active_transfers(&self) -> Vec<FileTransfer> {
        let transfers = self.transfers.read().await;
        transfers
            .values()
            .filter(|t| t.is_active())
            .cloned()
            .collect()
    }

    /// Compute BLAKE3 hash of data
    pub fn compute_hash(data: &[u8]) -> String {
        let mut hasher = Hasher::new();
        hasher.update(data);
        hasher.finalize().to_hex().to_string()
    }

    /// Compress data based on strategy
    pub fn compress(&self, data: &[u8], latency_ms: Option<u32>) -> (Vec<u8>, bool) {
        let config = self.config_snapshot();
        let strategy = match config.compression {
            CompressionStrategy::None => return (data.to_vec(), false),
            CompressionStrategy::Lz4 => CompressionStrategy::Lz4,
            CompressionStrategy::Zstd => CompressionStrategy::Zstd,
            CompressionStrategy::Adaptive => {
                // Use LZ4 for low-latency (LAN), Zstd for higher latency (WAN)
                if latency_ms.unwrap_or(100) < config.latency_threshold_ms {
                    CompressionStrategy::Lz4
                } else {
                    CompressionStrategy::Zstd
                }
            }
        };

        // Skip compression for small data
        if data.len() < 100 {
            return (data.to_vec(), false);
        }

        match strategy {
            CompressionStrategy::Lz4 => match lz4_flex::compress_prepend_size(data) {
                compressed if compressed.len() < data.len() => (compressed, true),
                _ => (data.to_vec(), false),
            },
            CompressionStrategy::Zstd => match zstd::encode_all(data, config.zstd_level) {
                Ok(compressed) if compressed.len() < data.len() => (compressed, true),
                _ => (data.to_vec(), false),
            },
            _ => (data.to_vec(), false),
        }
    }

    /// Decompress data
    pub fn decompress(&self, data: &[u8], use_lz4: bool) -> Result<Vec<u8>, std::io::Error> {
        if use_lz4 {
            lz4_flex::decompress_size_prepended(data)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
        } else {
            zstd::decode_all(data)
        }
    }

    /// Queue a file for sending with manifest
    pub async fn send_file(
        &self,
        path: PathBuf,
        remote_device_id: String,
    ) -> Result<String, std::io::Error> {
        let config = self.config_snapshot();
        let metadata = FileMetadata::from_path(&path)?;
        let id = uuid::Uuid::new_v4().to_string();

        // Create manifest for resume support
        let manifest = TransferManifest::new(
            id.clone(),
            metadata.clone(),
            TransferDirection::Send,
            path.clone(),
            remote_device_id.clone(),
            config.chunk_size,
            config.compression,
        );

        // Save manifest if resume enabled
        if config.resume_enabled {
            let manifest_dir = self.manifest_dir();
            std::fs::create_dir_all(&manifest_dir)?;
            manifest.save(&manifest_dir)?;
        }

        let transfer = FileTransfer::new_send(id.clone(), path, metadata, remote_device_id);

        let mut transfers = self.transfers.write().await;
        let mut manifests = self.manifests.write().await;
        transfers.insert(id.clone(), transfer);
        manifests.insert(id.clone(), manifest);

        info!("Queued file for sending: {}", id);
        Ok(id)
    }

    /// Accept an incoming file transfer
    pub async fn accept_receive(
        &self,
        id: String,
        metadata: FileMetadata,
        save_path: PathBuf,
        remote_device_id: String,
    ) -> Result<(), std::io::Error> {
        let config = self.config_snapshot();
        // Create manifest
        let manifest = TransferManifest::new(
            id.clone(),
            metadata.clone(),
            TransferDirection::Receive,
            save_path.clone(),
            remote_device_id.clone(),
            config.chunk_size,
            config.compression,
        );

        // Save manifest if resume enabled
        if config.resume_enabled {
            let manifest_dir = self.manifest_dir();
            std::fs::create_dir_all(&manifest_dir)?;
            manifest.save(&manifest_dir)?;
        }

        // Pre-allocate file
        let file = tokio::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&save_path)
            .await?;
        file.set_len(metadata.size).await?;

        let transfer = FileTransfer::new_receive(id.clone(), save_path, metadata, remote_device_id);

        let mut transfers = self.transfers.write().await;
        let mut manifests = self.manifests.write().await;
        transfers.insert(id.clone(), transfer);
        manifests.insert(id.clone(), manifest);

        info!("Accepted incoming transfer: {}", id);
        Ok(())
    }

    /// Try to resume a transfer from manifest
    pub async fn try_resume(&self, id: &str) -> Result<Option<Vec<u64>>, std::io::Error> {
        let manifest_dir = self.manifest_dir();
        match TransferManifest::load(id, &manifest_dir) {
            Ok(manifest) => {
                let pending = manifest.pending_chunks();

                // Restore manifest to memory
                let mut manifests = self.manifests.write().await;
                manifests.insert(id.to_string(), manifest);

                info!(
                    "Resumed transfer {} with {} pending chunks",
                    id,
                    pending.len()
                );
                Ok(Some(pending))
            }
            Err(_) => Ok(None),
        }
    }

    /// Start a transfer
    pub async fn start_transfer(&self, id: &str) -> Result<(), String> {
        let mut transfers = self.transfers.write().await;
        let transfer = transfers
            .get_mut(id)
            .ok_or_else(|| format!("Transfer not found: {}", id))?;

        if transfer.state != TransferState::Pending && transfer.state != TransferState::Paused {
            return Err(format!(
                "Cannot start transfer in state: {:?}",
                transfer.state
            ));
        }

        transfer.state = TransferState::InProgress;
        transfer.started_at = Some(Utc::now());
        transfer.progress.total_bytes = transfer.metadata.size;

        info!("Started transfer: {}", id);
        Ok(())
    }

    /// Pause a transfer
    pub async fn pause_transfer(&self, id: &str) -> Result<(), String> {
        let config = self.config_snapshot();
        let mut transfers = self.transfers.write().await;
        let transfer = transfers
            .get_mut(id)
            .ok_or_else(|| format!("Transfer not found: {}", id))?;

        if transfer.state != TransferState::InProgress {
            return Err(format!(
                "Cannot pause transfer in state: {:?}",
                transfer.state
            ));
        }

        transfer.state = TransferState::Paused;

        // Save manifest state
        if config.resume_enabled {
            let manifests = self.manifests.read().await;
            if let Some(manifest) = manifests.get(id) {
                let _ = manifest.save(&self.manifest_dir());
            }
        }

        info!("Paused transfer: {}", id);
        Ok(())
    }

    /// Resume a transfer
    pub async fn resume_transfer(&self, id: &str) -> Result<(), String> {
        self.start_transfer(id).await
    }

    /// Cancel a transfer
    pub async fn cancel_transfer(&self, id: &str) -> Result<(), String> {
        let config = self.config_snapshot();
        let mut transfers = self.transfers.write().await;
        let transfer = transfers
            .get_mut(id)
            .ok_or_else(|| format!("Transfer not found: {}", id))?;

        transfer.state = TransferState::Cancelled;

        // Remove manifest
        if config.resume_enabled {
            let _ = TransferManifest::delete(id, &self.manifest_dir());
        }

        // Remove from manifests
        let mut manifests = self.manifests.write().await;
        manifests.remove(id);

        info!("Cancelled transfer: {}", id);
        Ok(())
    }

    /// Read a chunk from file for sending with hash
    pub async fn read_chunk(
        &self,
        id: &str,
        chunk_index: u64,
        latency_ms: Option<u32>,
    ) -> Result<ChunkData, std::io::Error> {
        let config = self.config_snapshot();
        let transfers = self.transfers.read().await;
        let transfer = transfers.get(id).ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::NotFound, "Transfer not found")
        })?;

        let offset = chunk_index * config.chunk_size as u64;
        let mut file = File::open(&transfer.local_path).await?;
        file.seek(std::io::SeekFrom::Start(offset)).await?;

        let mut buffer = vec![0u8; config.chunk_size];
        let bytes_read = file.read(&mut buffer).await?;
        buffer.truncate(bytes_read);

        // Compute BLAKE3 hash of original data
        let hash = Self::compute_hash(&buffer);
        let original_size = buffer.len();

        // Compress data
        let (data, compressed) = self.compress(&buffer, latency_ms);

        Ok(ChunkData {
            index: chunk_index,
            data,
            hash,
            compressed,
            original_size,
        })
    }

    /// Write a chunk to file for receiving with verification
    pub async fn write_chunk(
        &self,
        id: &str,
        chunk: &ChunkData,
        use_lz4: bool,
    ) -> Result<bool, std::io::Error> {
        let config = self.config_snapshot();
        let transfers = self.transfers.read().await;
        let transfer = transfers.get(id).ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::NotFound, "Transfer not found")
        })?;

        // Decompress if needed
        let data = if chunk.compressed {
            self.decompress(&chunk.data, use_lz4)?
        } else {
            chunk.data.clone()
        };

        // Verify hash if verification is enabled
        if config.verify_chunks {
            let computed_hash = Self::compute_hash(&data);
            if computed_hash != chunk.hash {
                warn!(
                    "Chunk {} hash mismatch: expected {}, got {}",
                    chunk.index, chunk.hash, computed_hash
                );
                return Ok(false);
            }
        }

        let offset = chunk.index * config.chunk_size as u64;

        let mut file = tokio::fs::OpenOptions::new()
            .write(true)
            .open(&transfer.local_path)
            .await?;

        file.seek(std::io::SeekFrom::Start(offset)).await?;
        file.write_all(&data).await?;
        file.flush().await?;

        // Update manifest
        drop(transfers); // Release read lock
        let mut manifests = self.manifests.write().await;
        if let Some(manifest) = manifests.get_mut(id) {
            let compressed_size = if chunk.compressed {
                Some(chunk.data.len())
            } else {
                None
            };
            manifest.mark_chunk_verified(
                chunk.index,
                chunk.hash.clone(),
                chunk.compressed,
                compressed_size,
            );

            // Save manifest periodically (every 10 chunks or on completion)
            if config.resume_enabled && (chunk.index.is_multiple_of(10) || manifest.is_complete()) {
                let _ = manifest.save(&self.manifest_dir());
            }
        }

        // Call callback
        if let Some(ref callback) = self.on_chunk_verified {
            callback(id, chunk.index, &chunk.hash);
        }

        Ok(true)
    }

    /// Update transfer progress from manifest
    pub async fn sync_progress(&self, id: &str) -> Result<(), String> {
        let config = self.config_snapshot();
        let manifests = self.manifests.read().await;
        let manifest = manifests
            .get(id)
            .ok_or_else(|| format!("Manifest not found: {}", id))?;

        let bytes_transferred = manifest.bytes_transferred();
        let verified_chunks = manifest.verified_count();

        drop(manifests);

        let mut transfers = self.transfers.write().await;
        let transfer = transfers
            .get_mut(id)
            .ok_or_else(|| format!("Transfer not found: {}", id))?;

        transfer.progress.bytes_transferred = bytes_transferred;
        transfer.progress.current_chunk = verified_chunks;

        // Check if complete
        if bytes_transferred >= transfer.metadata.size {
            transfer.state = TransferState::Completed;
            transfer.completed_at = Some(Utc::now());

            // Cleanup manifest
            if config.resume_enabled {
                let _ = TransferManifest::delete(id, &self.manifest_dir());
            }

            if let Some(ref callback) = self.on_complete {
                callback(transfer);
            }
        } else if let Some(ref callback) = self.on_progress {
            callback(transfer);
        }

        Ok(())
    }

    /// Update transfer progress manually
    pub async fn update_progress(
        &self,
        id: &str,
        bytes_transferred: u64,
        speed: u64,
    ) -> Result<(), String> {
        let config = self.config_snapshot();
        let mut transfers = self.transfers.write().await;
        let transfer = transfers
            .get_mut(id)
            .ok_or_else(|| format!("Transfer not found: {}", id))?;

        transfer.progress.bytes_transferred = bytes_transferred;
        transfer.progress.speed = speed;

        if speed > 0 {
            let remaining = transfer.metadata.size.saturating_sub(bytes_transferred);
            transfer.progress.eta_seconds = Some(remaining / speed);
        }

        // Check if complete
        if bytes_transferred >= transfer.metadata.size {
            transfer.state = TransferState::Completed;
            transfer.completed_at = Some(Utc::now());

            // Cleanup manifest
            if config.resume_enabled {
                let _ = TransferManifest::delete(id, &self.manifest_dir());
            }
        }

        Ok(())
    }

    /// Mark transfer as failed
    pub async fn fail_transfer(&self, id: &str, error: String) -> Result<(), String> {
        let config = self.config_snapshot();
        let mut transfers = self.transfers.write().await;
        let transfer = transfers
            .get_mut(id)
            .ok_or_else(|| format!("Transfer not found: {}", id))?;

        transfer.state = TransferState::Failed;
        transfer.error = Some(error);
        transfer.completed_at = Some(Utc::now());

        // Keep manifest for potential retry
        if config.resume_enabled {
            let manifests = self.manifests.read().await;
            if let Some(manifest) = manifests.get(id) {
                let _ = manifest.save(&self.manifest_dir());
            }
        }

        Ok(())
    }

    /// Get pending chunks for a transfer
    pub async fn pending_chunks(&self, id: &str) -> Result<Vec<u64>, String> {
        let manifests = self.manifests.read().await;
        let manifest = manifests
            .get(id)
            .ok_or_else(|| format!("Manifest not found: {}", id))?;
        Ok(manifest.pending_chunks())
    }

    /// Get chunk info for a transfer
    pub async fn chunk_info(&self, id: &str, chunk_index: u64) -> Result<ChunkInfo, String> {
        let manifests = self.manifests.read().await;
        let manifest = manifests
            .get(id)
            .ok_or_else(|| format!("Manifest not found: {}", id))?;
        manifest
            .chunks
            .get(&chunk_index)
            .cloned()
            .ok_or_else(|| format!("Chunk {} not found", chunk_index))
    }

    /// Compute full file BLAKE3 hash
    pub async fn compute_file_hash(&self, id: &str) -> Result<String, std::io::Error> {
        let transfers = self.transfers.read().await;
        let transfer = transfers.get(id).ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::NotFound, "Transfer not found")
        })?;

        let mut file = File::open(&transfer.local_path).await?;
        let mut hasher = Hasher::new();
        let mut buffer = vec![0u8; 64 * 1024]; // 64KB buffer

        loop {
            let bytes_read = file.read(&mut buffer).await?;
            if bytes_read == 0 {
                break;
            }
            hasher.update(&buffer[..bytes_read]);
        }

        let hash = hasher.finalize().to_hex().to_string();

        // Store in manifest
        drop(transfers);
        let mut manifests = self.manifests.write().await;
        if let Some(manifest) = manifests.get_mut(id) {
            manifest.file_hash = Some(hash.clone());
        }

        Ok(hash)
    }

    /// Remove completed transfers older than duration
    pub async fn cleanup_completed(&self, max_age: std::time::Duration) {
        let now = Utc::now();
        let mut transfers = self.transfers.write().await;
        let mut manifests = self.manifests.write().await;

        let to_remove: Vec<_> = transfers
            .iter()
            .filter_map(|(id, transfer)| {
                if let Some(completed_at) = transfer.completed_at {
                    let age = now.signed_duration_since(completed_at);
                    if age.num_seconds() >= max_age.as_secs() as i64 {
                        return Some(id.clone());
                    }
                }
                None
            })
            .collect();

        for id in to_remove {
            transfers.remove(&id);
            manifests.remove(&id);
            let _ = TransferManifest::delete(&id, &self.manifest_dir());
        }
    }

    /// List all resumable transfers from disk
    pub async fn list_resumable(&self) -> Result<Vec<TransferManifest>, std::io::Error> {
        let manifest_dir = self.manifest_dir();
        if !manifest_dir.exists() {
            return Ok(Vec::new());
        }

        let mut manifests = Vec::new();
        let mut dir = tokio::fs::read_dir(&manifest_dir).await?;

        while let Some(entry) = dir.next_entry().await? {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "json")
                && let Ok(json) = tokio::fs::read_to_string(&path).await
                && let Ok(manifest) = serde_json::from_str::<TransferManifest>(&json)
                && !manifest.is_complete()
            {
                manifests.push(manifest);
            }
        }

        Ok(manifests)
    }

    /// Send a file using the macOS/iOS wire format (unencrypted).
    pub async fn send_file_over_wire<T>(
        &self,
        stream: T,
        path: PathBuf,
    ) -> Result<String, std::io::Error>
    where
        T: AsyncRead + AsyncWrite + Unpin,
    {
        self.send_file_over_wire_with_key(stream, path, None, None)
            .await
    }

    /// Send a file using the macOS/iOS wire format with AES-GCM encryption.
    /// The key should be the PQC-derived session key for the file channel.
    pub async fn send_file_over_wire_encrypted<T>(
        &self,
        stream: T,
        path: PathBuf,
        aead_key: &[u8],
    ) -> Result<String, std::io::Error>
    where
        T: AsyncRead + AsyncWrite + Unpin,
    {
        self.send_file_over_wire_with_key(stream, path, Some(aead_key), None)
            .await
    }

    /// Receive a file using the macOS/iOS wire format (unencrypted).
    pub async fn receive_file_over_wire<T>(
        &self,
        stream: T,
        target_dir: PathBuf,
    ) -> Result<String, std::io::Error>
    where
        T: AsyncRead + AsyncWrite + Unpin,
    {
        self.receive_file_over_wire_with_key_provider(stream, target_dir, |_| None)
            .await
    }

    /// Receive a file using the macOS/iOS wire format with AES-GCM decryption.
    /// The key should be the PQC-derived session key for the file channel.
    pub async fn receive_file_over_wire_encrypted<T>(
        &self,
        stream: T,
        target_dir: PathBuf,
        aead_key: &[u8],
    ) -> Result<String, std::io::Error>
    where
        T: AsyncRead + AsyncWrite + Unpin,
    {
        let key = aead_key.to_vec();
        self.receive_file_over_wire_with_key_provider(stream, target_dir, |_| Some(key.clone()))
            .await
    }

    /// Send a file using the macOS/iOS wire format with PQC session keys.
    pub async fn send_file_over_wire_with_session_keys<T>(
        &self,
        stream: T,
        path: PathBuf,
        keys: &crate::p2p::SessionKeys,
        peer_id: &str,
    ) -> Result<String, std::io::Error>
    where
        T: AsyncRead + AsyncWrite + Unpin,
    {
        self.send_file_over_wire_with_key(stream, path, Some(&keys.send_file_key), Some(peer_id))
            .await
    }

    /// Receive a file using the macOS/iOS wire format with PQC session keys.
    pub async fn receive_file_over_wire_with_session_keys<T>(
        &self,
        stream: T,
        target_dir: PathBuf,
        keys: &crate::p2p::SessionKeys,
    ) -> Result<String, std::io::Error>
    where
        T: AsyncRead + AsyncWrite + Unpin,
    {
        self.receive_file_over_wire_encrypted(stream, target_dir, &keys.recv_file_key)
            .await
    }

    async fn send_file_over_wire_with_key<T>(
        &self,
        stream: T,
        path: PathBuf,
        aead_key: Option<&[u8]>,
        signer_peer_id: Option<&str>,
    ) -> Result<String, std::io::Error>
    where
        T: AsyncRead + AsyncWrite + Unpin,
    {
        let config = self.config_snapshot();
        let metadata = FileMetadata::from_path(&path)?;
        if metadata.is_directory {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "directory transfer not supported",
            ));
        }

        let transfer_id = uuid::Uuid::new_v4().to_string();
        let chunk_size = config.chunk_size;
        let checksum = compute_sha256_hex(&path).await?;

        let mut wire = FileTransferWire::new(stream);
        let file_name = metadata.name.clone();
        let mut meta = FileTransferMetadataWire::new(
            transfer_id.clone(),
            file_name,
            metadata.size as i64,
            checksum,
            chunk_size as i32,
        );
        meta.compression_enabled = false;
        meta.encryption_enabled = aead_key.is_some();
        meta.signer_peer_id = signer_peer_id.map(|s| s.to_string());
        wire.send_metadata(&meta).await?;
        wire.recv_transfer_ack().await?;

        let mut file = File::open(path).await?;
        let total_chunks = if metadata.size == 0 {
            1
        } else {
            metadata.size.div_ceil(chunk_size as u64)
        } as u32;

        for idx in 0..total_chunks {
            let mut buf = vec![0u8; chunk_size];
            let read = file.read(&mut buf).await?;
            buf.truncate(read);
            if buf.is_empty() {
                break;
            }

            let (data, nonce, tag, is_encrypted) = if let Some(key) = aead_key {
                let enc = encrypt_chunk_with_key(&buf, key)?;
                (enc.ciphertext, Some(enc.nonce), Some(enc.tag), true)
            } else {
                (buf, None, None, false)
            };

            let checksum = FileChunkPacketWire::checksum_hex(&data);
            let packet = FileChunkPacketWire {
                transfer_id: transfer_id.clone(),
                chunk_index: idx,
                total_chunks,
                data,
                checksum,
                is_compressed: false,
                is_encrypted,
                timestamp: Utc::now(),
                aead_nonce: nonce,
                aead_tag: tag,
            };
            wire.send_chunk_packet(&packet).await?;
            let ack = wire.recv_chunk_ack().await?;
            if ack.transfer_id != transfer_id || ack.chunk_index != idx || ack.status != 0x01 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "chunk ack mismatch",
                ));
            }
        }

        wire.send_transfer_complete(&transfer_id, None).await?;
        wire.recv_final_ack().await?;
        Ok(transfer_id)
    }

    pub async fn receive_file_over_wire_with_key_provider<T, F>(
        &self,
        stream: T,
        target_dir: PathBuf,
        key_provider: F,
    ) -> Result<String, std::io::Error>
    where
        T: AsyncRead + AsyncWrite + Unpin,
        F: Fn(&FileTransferMetadataWire) -> Option<Vec<u8>> + Send + Sync,
    {
        self.receive_file_over_wire_with_key_provider_and_prompt(
            stream,
            target_dir,
            key_provider,
            None,
        )
        .await
    }

    pub async fn receive_file_over_wire_with_key_provider_and_prompt<T, F>(
        &self,
        stream: T,
        target_dir: PathBuf,
        key_provider: F,
        incoming_prompt: Option<IncomingTransferPromptConfig>,
    ) -> Result<String, std::io::Error>
    where
        T: AsyncRead + AsyncWrite + Unpin,
        F: Fn(&FileTransferMetadataWire) -> Option<Vec<u8>> + Send + Sync,
    {
        let mut wire = FileTransferWire::new(stream);
        let meta = wire.recv_metadata().await?;
        if meta.compression_enabled {
            let _ = wire.send_transfer_ack_status(0x00).await;
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "compression not supported in wire receiver",
            ));
        }

        let key = if meta.encryption_enabled {
            key_provider(&meta)
        } else {
            None
        };
        if meta.encryption_enabled && key.is_none() {
            let _ = wire.send_transfer_ack_status(0x00).await;
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "missing AES-GCM session key",
            ));
        }

        let safe_name = sanitize_wire_file_name(&meta.file_name);
        let file_size = meta.file_size.max(0) as u64;

        let mut selected_path: PathBuf = target_dir.join(&safe_name);
        let mut overwrite = true;
        if let Some(prompt) = incoming_prompt.as_ref() {
            let request = IncomingTransferRequest {
                source: IncomingTransferSource::QuantumWire,
                transfer_id: meta.transfer_id.clone(),
                file_name: safe_name.clone(),
                file_size,
                sender_device_id: meta.signer_peer_id.clone(),
                sender_device_name: None,
                target_dir: target_dir.clone(),
            };
            let decision = prompt_incoming_transfer(prompt, request).await;
            if !decision.accept {
                let _ = wire.send_transfer_ack_status(0x00).await;
                if let Some(tx) = prompt.completed_tx.as_ref() {
                    let _ = tx.send(IncomingTransferCompleted {
                        source: IncomingTransferSource::QuantumWire,
                        transfer_id: meta.transfer_id.clone(),
                        file_name: safe_name,
                        save_path: None,
                        success: false,
                        received_bytes: 0,
                        error: Some("declined".to_string()),
                        sender_device_id: meta.signer_peer_id.clone(),
                        sender_device_name: None,
                    });
                }
                return Ok(meta.transfer_id);
            }
            overwrite = decision.overwrite;
            if let Some(path) = decision.save_path {
                selected_path = path;
            } else {
                let _ = wire.send_transfer_ack_status(0x00).await;
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "missing save path",
                ));
            }
        }

        // Try to open the file before acknowledging, so we can reject on failure.
        if let Some(parent) = selected_path.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        let mut open = tokio::fs::OpenOptions::new();
        open.write(true);
        if overwrite {
            open.create(true).truncate(true);
        } else {
            open.create_new(true);
        }
        let mut file = match open.open(&selected_path).await {
            Ok(f) => f,
            Err(err) => {
                let _ = wire.send_transfer_ack_status(0x00).await;
                if err.kind() == std::io::ErrorKind::AlreadyExists {
                    return Ok(meta.transfer_id);
                }
                return Err(err);
            }
        };

        wire.send_transfer_ack_status(0x01).await?;

        let total_chunks = if meta.file_size <= 0 {
            1
        } else {
            (meta.file_size as u64).div_ceil(meta.chunk_size as u64)
        } as u32;

        let mut received = 0u32;
        while received < total_chunks {
            let packet = wire.recv_chunk_packet().await?;
            let checksum = FileChunkPacketWire::checksum_hex(&packet.data);
            if checksum != packet.checksum {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "chunk checksum mismatch",
                ));
            }

            let payload = if packet.is_encrypted {
                let key = key.as_ref().ok_or_else(|| {
                    std::io::Error::new(std::io::ErrorKind::PermissionDenied, "missing AES-GCM key")
                })?;
                let nonce = packet.aead_nonce.as_ref().ok_or_else(|| {
                    std::io::Error::new(std::io::ErrorKind::InvalidData, "missing AEAD nonce")
                })?;
                let tag = packet.aead_tag.as_ref().ok_or_else(|| {
                    std::io::Error::new(std::io::ErrorKind::InvalidData, "missing AEAD tag")
                })?;
                decrypt_chunk_with_key(&packet.data, nonce, tag, key)?
            } else {
                packet.data
            };

            file.write_all(&payload).await?;
            wire.send_chunk_ack(&packet.transfer_id, packet.chunk_index, 0x01)
                .await?;
            received += 1;
        }

        let complete = wire.recv_transfer_complete().await?;
        let computed = compute_sha256_hex(&selected_path).await?;
        if computed != meta.checksum {
            if let Some(prompt) = incoming_prompt.as_ref()
                && let Some(tx) = prompt.completed_tx.as_ref()
            {
                let _ = tx.send(IncomingTransferCompleted {
                    source: IncomingTransferSource::QuantumWire,
                    transfer_id: meta.transfer_id.clone(),
                    file_name: safe_name,
                    save_path: Some(selected_path),
                    success: false,
                    received_bytes: file_size,
                    error: Some("file checksum mismatch".to_string()),
                    sender_device_id: meta.signer_peer_id.clone(),
                    sender_device_name: None,
                });
            }
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "file checksum mismatch",
            ));
        }

        wire.send_final_ack().await?;

        if let Some(prompt) = incoming_prompt.as_ref()
            && let Some(tx) = prompt.completed_tx.as_ref()
        {
            let _ = tx.send(IncomingTransferCompleted {
                source: IncomingTransferSource::QuantumWire,
                transfer_id: meta.transfer_id.clone(),
                file_name: safe_name,
                save_path: Some(selected_path),
                success: true,
                received_bytes: file_size,
                error: None,
                sender_device_id: meta.signer_peer_id.clone(),
                sender_device_name: None,
            });
        }

        Ok(complete.transfer_id)
    }
}

fn sanitize_wire_file_name(raw: &str) -> String {
    let trimmed = raw.trim();
    let file_name = std::path::Path::new(trimmed)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("file");
    let sanitized = file_name
        .chars()
        .map(|c| if c == '/' || c == '\\' { '_' } else { c })
        .collect::<String>()
        .trim()
        .to_string();
    if sanitized.is_empty() {
        "file".to_string()
    } else {
        sanitized
    }
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

impl Default for FileTransferEngine {
    fn default() -> Self {
        Self::new()
    }
}

async fn compute_sha256_hex(path: &std::path::Path) -> Result<String, std::io::Error> {
    use sha2::{Digest, Sha256};
    let mut file = File::open(path).await?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buf).await?;
        if read == 0 {
            break;
        }
        hasher.update(&buf[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

struct EncryptedChunk {
    ciphertext: Vec<u8>,
    nonce: Vec<u8>,
    tag: Vec<u8>,
}

fn encrypt_chunk_with_key(data: &[u8], key: &[u8]) -> Result<EncryptedChunk, std::io::Error> {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;

    let base64 = STANDARD.encode(data);
    let provider = AesGcmProvider::new();
    let encrypted = provider
        .encrypt(key, base64.as_bytes(), &[])
        .map_err(map_aead_error)?;
    let (ciphertext, tag) = split_ciphertext_and_tag(&encrypted.ciphertext)?;
    Ok(EncryptedChunk {
        ciphertext,
        nonce: encrypted.nonce,
        tag,
    })
}

fn decrypt_chunk_with_key(
    data: &[u8],
    nonce: &[u8],
    tag: &[u8],
    key: &[u8],
) -> Result<Vec<u8>, std::io::Error> {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;

    if nonce.len() != 12 || tag.len() != 16 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "invalid AEAD nonce/tag length",
        ));
    }
    let mut combined = Vec::with_capacity(data.len() + tag.len());
    combined.extend_from_slice(data);
    combined.extend_from_slice(tag);
    let encrypted = EncryptedData {
        nonce: nonce.to_vec(),
        ciphertext: combined,
    };
    let provider = AesGcmProvider::new();
    let plaintext = provider
        .decrypt(key, &encrypted, &[])
        .map_err(map_aead_error)?;
    let decoded = STANDARD
        .decode(&plaintext)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    Ok(decoded)
}

fn split_ciphertext_and_tag(data: &[u8]) -> Result<(Vec<u8>, Vec<u8>), std::io::Error> {
    if data.len() < 16 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "ciphertext too short",
        ));
    }
    let split = data.len() - 16;
    Ok((data[..split].to_vec(), data[split..].to_vec()))
}

fn map_aead_error(err: crate::crypto::aead::AeadError) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, err.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[tokio::test]
    async fn test_chunk_hash_verification() {
        let data = b"Hello, SkyBridge! This is test data for BLAKE3 hashing.";
        let hash = FileTransferEngine::compute_hash(data);

        // BLAKE3 hash should be 64 hex characters
        assert_eq!(hash.len(), 64);

        // Same data should produce same hash
        let hash2 = FileTransferEngine::compute_hash(data);
        assert_eq!(hash, hash2);

        // Different data should produce different hash
        let hash3 = FileTransferEngine::compute_hash(b"Different data");
        assert_ne!(hash, hash3);
    }

    #[tokio::test]
    async fn test_compression_strategies() {
        let engine = FileTransferEngine::with_config(TransferConfig {
            compression: CompressionStrategy::Zstd,
            zstd_level: 3,
            ..Default::default()
        });

        // Compressible data
        let data = "Hello, World! ".repeat(1000);
        let (compressed, is_compressed) = engine.compress(data.as_bytes(), None);

        assert!(is_compressed);
        assert!(compressed.len() < data.len());

        // Verify decompression
        let decompressed = engine.decompress(&compressed, false).unwrap();
        assert_eq!(decompressed, data.as_bytes());
    }

    #[tokio::test]
    async fn test_manifest_persistence() {
        let temp_dir = TempDir::new().unwrap();
        let manifest_path = temp_dir.path();

        let metadata = FileMetadata {
            name: "test.txt".to_string(),
            size: 1024 * 1024 * 10, // 10MB
            mime_type: Some("text/plain".to_string()),
            hash: None,
            created: None,
            modified: None,
            is_directory: false,
            relative_path: None,
        };

        let manifest = TransferManifest::new(
            "test-transfer-id".to_string(),
            metadata,
            TransferDirection::Send,
            PathBuf::from("/tmp/test.txt"),
            "remote-device".to_string(),
            2 * 1024 * 1024, // 2MB chunks
            CompressionStrategy::Adaptive,
        );

        // Should have 5 chunks for 10MB file with 2MB chunk size
        assert_eq!(manifest.total_chunks, 5);
        assert_eq!(manifest.pending_chunks().len(), 5);

        // Save and reload
        manifest.save(manifest_path).unwrap();
        let loaded = TransferManifest::load("test-transfer-id", manifest_path).unwrap();

        assert_eq!(loaded.transfer_id, manifest.transfer_id);
        assert_eq!(loaded.total_chunks, manifest.total_chunks);
        assert_eq!(loaded.chunk_size, manifest.chunk_size);

        // Cleanup
        TransferManifest::delete("test-transfer-id", manifest_path).unwrap();
    }

    #[tokio::test]
    async fn test_adaptive_compression() {
        let engine = FileTransferEngine::with_config(TransferConfig {
            compression: CompressionStrategy::Adaptive,
            latency_threshold_ms: 5,
            ..Default::default()
        });

        let data = "Test data for compression ".repeat(100);

        // Low latency (LAN) should use LZ4
        let (_, compressed1) = engine.compress(data.as_bytes(), Some(1));

        // High latency (WAN) should use Zstd
        let (_, compressed2) = engine.compress(data.as_bytes(), Some(100));

        // Both should compress
        assert!(compressed1);
        assert!(compressed2);
    }
}
