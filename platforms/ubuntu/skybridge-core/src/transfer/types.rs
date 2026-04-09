//! File Transfer Types

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

/// Transfer direction
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferDirection {
    /// Sending to peer
    Send,
    /// Receiving from peer
    Receive,
}

/// Transfer state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferState {
    /// Pending start
    Pending,
    /// In progress
    InProgress,
    /// Paused
    Paused,
    /// Completed successfully
    Completed,
    /// Failed
    Failed,
    /// Cancelled
    Cancelled,
}

/// Compression strategy
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum CompressionStrategy {
    /// No compression
    None,
    /// LZ4 for LAN/low-latency (fast, moderate ratio)
    Lz4,
    /// Zstd for WAN/internet (balanced speed/ratio)
    Zstd,
    /// Adaptive based on connection type
    #[default]
    Adaptive,
}

/// Chunk status for tracking transfer progress
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ChunkStatus {
    /// Not yet transferred
    Pending,
    /// Currently transferring
    InProgress,
    /// Successfully transferred and verified
    Verified,
    /// Failed to transfer
    Failed,
}

/// Individual chunk information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkInfo {
    /// Chunk index
    pub index: u64,
    /// Offset in file
    pub offset: u64,
    /// Chunk size in bytes
    pub size: usize,
    /// BLAKE3 hash of chunk data (32 bytes, hex encoded)
    pub hash: Option<String>,
    /// Chunk status
    pub status: ChunkStatus,
    /// Whether chunk was compressed
    pub compressed: bool,
    /// Compressed size (if compressed)
    pub compressed_size: Option<usize>,
}

/// Transfer manifest for persistent resume
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferManifest {
    /// Transfer ID
    pub transfer_id: String,
    /// File metadata
    pub metadata: FileMetadata,
    /// Direction
    pub direction: TransferDirection,
    /// Local file path
    pub local_path: PathBuf,
    /// Remote device ID
    pub remote_device_id: String,
    /// Chunk information map (index -> ChunkInfo)
    pub chunks: HashMap<u64, ChunkInfo>,
    /// Total chunks
    pub total_chunks: u64,
    /// Chunk size used
    pub chunk_size: usize,
    /// Compression strategy used
    pub compression: CompressionStrategy,
    /// Created timestamp
    pub created_at: DateTime<Utc>,
    /// Last updated timestamp
    pub updated_at: DateTime<Utc>,
    /// File BLAKE3 hash (computed after all chunks verified)
    pub file_hash: Option<String>,
}

impl TransferManifest {
    /// Create a new manifest for a transfer
    pub fn new(
        transfer_id: String,
        metadata: FileMetadata,
        direction: TransferDirection,
        local_path: PathBuf,
        remote_device_id: String,
        chunk_size: usize,
        compression: CompressionStrategy,
    ) -> Self {
        let total_chunks = if metadata.size == 0 {
            1
        } else {
            metadata.size.div_ceil(chunk_size as u64)
        };

        let mut chunks = HashMap::new();
        for i in 0..total_chunks {
            let offset = i * chunk_size as u64;
            let size = std::cmp::min(chunk_size, (metadata.size - offset) as usize);
            chunks.insert(
                i,
                ChunkInfo {
                    index: i,
                    offset,
                    size,
                    hash: None,
                    status: ChunkStatus::Pending,
                    compressed: false,
                    compressed_size: None,
                },
            );
        }

        let now = Utc::now();
        Self {
            transfer_id,
            metadata,
            direction,
            local_path,
            remote_device_id,
            chunks,
            total_chunks,
            chunk_size,
            compression,
            created_at: now,
            updated_at: now,
            file_hash: None,
        }
    }

    /// Get the manifest file path for a transfer
    pub fn manifest_path(transfer_id: &str, base_dir: &std::path::Path) -> PathBuf {
        base_dir.join(format!("{}.manifest.json", transfer_id))
    }

    /// Save manifest to disk
    pub fn save(&self, base_dir: &std::path::Path) -> std::io::Result<()> {
        let path = Self::manifest_path(&self.transfer_id, base_dir);
        let json = serde_json::to_string_pretty(self).map_err(std::io::Error::other)?;
        std::fs::write(path, json)
    }

    /// Load manifest from disk
    pub fn load(transfer_id: &str, base_dir: &std::path::Path) -> std::io::Result<Self> {
        let path = Self::manifest_path(transfer_id, base_dir);
        let json = std::fs::read_to_string(path)?;
        serde_json::from_str(&json).map_err(std::io::Error::other)
    }

    /// Delete manifest from disk
    pub fn delete(transfer_id: &str, base_dir: &std::path::Path) -> std::io::Result<()> {
        let path = Self::manifest_path(transfer_id, base_dir);
        if path.exists() {
            std::fs::remove_file(path)?;
        }
        Ok(())
    }

    /// Mark a chunk as verified
    pub fn mark_chunk_verified(
        &mut self,
        index: u64,
        hash: String,
        compressed: bool,
        compressed_size: Option<usize>,
    ) {
        if let Some(chunk) = self.chunks.get_mut(&index) {
            chunk.hash = Some(hash);
            chunk.status = ChunkStatus::Verified;
            chunk.compressed = compressed;
            chunk.compressed_size = compressed_size;
        }
        self.updated_at = Utc::now();
    }

    /// Get next pending chunk index
    pub fn next_pending_chunk(&self) -> Option<u64> {
        for i in 0..self.total_chunks {
            if let Some(chunk) = self.chunks.get(&i)
                && chunk.status == ChunkStatus::Pending
            {
                return Some(i);
            }
        }
        None
    }

    /// Get all pending chunk indices
    pub fn pending_chunks(&self) -> Vec<u64> {
        let mut pending = Vec::new();
        for i in 0..self.total_chunks {
            if let Some(chunk) = self.chunks.get(&i)
                && (chunk.status == ChunkStatus::Pending || chunk.status == ChunkStatus::Failed)
            {
                pending.push(i);
            }
        }
        pending
    }

    /// Get count of verified chunks
    pub fn verified_count(&self) -> u64 {
        self.chunks
            .values()
            .filter(|c| c.status == ChunkStatus::Verified)
            .count() as u64
    }

    /// Get bytes transferred (verified chunks only)
    pub fn bytes_transferred(&self) -> u64 {
        self.chunks
            .values()
            .filter(|c| c.status == ChunkStatus::Verified)
            .map(|c| c.size as u64)
            .sum()
    }

    /// Check if transfer is complete
    pub fn is_complete(&self) -> bool {
        self.verified_count() == self.total_chunks
    }
}

/// Transfer configuration
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TransferConfig {
    /// Chunk size in bytes (default: 2MB for optimal resume/overhead balance)
    pub chunk_size: usize,
    /// Maximum concurrent transfers
    pub max_concurrent: usize,
    /// Maximum parallel chunks per transfer
    pub max_parallel_chunks: usize,
    /// Compression strategy
    pub compression: CompressionStrategy,
    /// Zstd compression level (1-22, default: 10)
    pub zstd_level: i32,
    /// Enable encryption (always true for P2P)
    pub encryption_enabled: bool,
    /// Enable resumption with manifest files
    pub resume_enabled: bool,
    /// Directory for storing manifest files
    pub manifest_dir: Option<PathBuf>,
    /// Verify chunks with BLAKE3 hash
    pub verify_chunks: bool,
    /// Connection latency threshold for compression strategy (ms)
    pub latency_threshold_ms: u32,
}

impl Default for TransferConfig {
    fn default() -> Self {
        Self {
            chunk_size: 2 * 1024 * 1024, // 2MB - good balance for resume granularity
            max_concurrent: 4,
            max_parallel_chunks: 4,
            compression: CompressionStrategy::Adaptive,
            zstd_level: 10,
            encryption_enabled: true,
            resume_enabled: true,
            manifest_dir: None,
            verify_chunks: true,
            latency_threshold_ms: 5, // Use LZ4 if latency < 5ms (LAN)
        }
    }
}

/// File metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileMetadata {
    /// File name
    pub name: String,
    /// File size in bytes
    pub size: u64,
    /// MIME type
    pub mime_type: Option<String>,
    /// SHA-256 hash
    pub hash: Option<String>,
    /// Creation time
    pub created: Option<DateTime<Utc>>,
    /// Modification time
    pub modified: Option<DateTime<Utc>>,
    /// Is directory
    pub is_directory: bool,
    /// Relative path (for directory transfers)
    pub relative_path: Option<String>,
}

impl FileMetadata {
    /// Create metadata from file path
    pub fn from_path(path: &std::path::Path) -> std::io::Result<Self> {
        let metadata = std::fs::metadata(path)?;
        let name = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();

        Ok(Self {
            name,
            size: metadata.len(),
            mime_type: mime_guess::from_path(path)
                .first_raw()
                .map(ToOwned::to_owned),
            hash: None, // Computed during transfer
            created: metadata.created().ok().map(|t| t.into()),
            modified: metadata.modified().ok().map(|t| t.into()),
            is_directory: metadata.is_dir(),
            relative_path: None,
        })
    }
}

/// Transfer progress
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferProgress {
    /// Bytes transferred
    pub bytes_transferred: u64,
    /// Total bytes
    pub total_bytes: u64,
    /// Transfer speed in bytes/sec
    pub speed: u64,
    /// Estimated time remaining in seconds
    pub eta_seconds: Option<u64>,
    /// Current chunk index
    pub current_chunk: u64,
    /// Total chunks
    pub total_chunks: u64,
}

impl TransferProgress {
    /// Get progress percentage (0-100)
    pub fn percentage(&self) -> f64 {
        if self.total_bytes == 0 {
            0.0
        } else {
            (self.bytes_transferred as f64 / self.total_bytes as f64) * 100.0
        }
    }

    /// Format progress as string
    pub fn format(&self) -> String {
        format!(
            "{:.1}% ({} / {}) - {} /s",
            self.percentage(),
            Self::format_size(self.bytes_transferred),
            Self::format_size(self.total_bytes),
            Self::format_size(self.speed),
        )
    }

    /// Format size with units
    fn format_size(bytes: u64) -> String {
        const KB: u64 = 1024;
        const MB: u64 = KB * 1024;
        const GB: u64 = MB * 1024;

        if bytes >= GB {
            format!("{:.2} GB", bytes as f64 / GB as f64)
        } else if bytes >= MB {
            format!("{:.2} MB", bytes as f64 / MB as f64)
        } else if bytes >= KB {
            format!("{:.2} KB", bytes as f64 / KB as f64)
        } else {
            format!("{} B", bytes)
        }
    }
}

/// A file transfer
#[derive(Debug, Clone)]
pub struct FileTransfer {
    /// Transfer ID
    pub id: String,
    /// Direction
    pub direction: TransferDirection,
    /// State
    pub state: TransferState,
    /// File metadata
    pub metadata: FileMetadata,
    /// Local path
    pub local_path: PathBuf,
    /// Remote device ID
    pub remote_device_id: String,
    /// Progress
    pub progress: TransferProgress,
    /// Started at
    pub started_at: Option<DateTime<Utc>>,
    /// Completed at
    pub completed_at: Option<DateTime<Utc>>,
    /// Error message if failed
    pub error: Option<String>,
}

impl FileTransfer {
    /// Create a new send transfer
    pub fn new_send(
        id: String,
        local_path: PathBuf,
        metadata: FileMetadata,
        remote_device_id: String,
    ) -> Self {
        let total_chunks = metadata.size.div_ceil(1024 * 1024);

        Self {
            id,
            direction: TransferDirection::Send,
            state: TransferState::Pending,
            metadata,
            local_path,
            remote_device_id,
            progress: TransferProgress {
                bytes_transferred: 0,
                total_bytes: 0,
                speed: 0,
                eta_seconds: None,
                current_chunk: 0,
                total_chunks,
            },
            started_at: None,
            completed_at: None,
            error: None,
        }
    }

    /// Create a new receive transfer
    pub fn new_receive(
        id: String,
        local_path: PathBuf,
        metadata: FileMetadata,
        remote_device_id: String,
    ) -> Self {
        let total_chunks = metadata.size.div_ceil(1024 * 1024);

        Self {
            id,
            direction: TransferDirection::Receive,
            state: TransferState::Pending,
            metadata,
            local_path,
            remote_device_id,
            progress: TransferProgress {
                bytes_transferred: 0,
                total_bytes: 0,
                speed: 0,
                eta_seconds: None,
                current_chunk: 0,
                total_chunks,
            },
            started_at: None,
            completed_at: None,
            error: None,
        }
    }

    /// Check if transfer is active
    pub fn is_active(&self) -> bool {
        matches!(
            self.state,
            TransferState::InProgress | TransferState::Paused
        )
    }

    /// Check if transfer is complete
    pub fn is_complete(&self) -> bool {
        matches!(
            self.state,
            TransferState::Completed | TransferState::Failed | TransferState::Cancelled
        )
    }
}

#[cfg(test)]
mod tests {
    use super::FileMetadata;
    use std::io::Write;

    #[test]
    fn file_metadata_detects_mime_type_from_path() {
        let mut file = tempfile::NamedTempFile::new().expect("temp file");
        writeln!(file, "hello skybridge").expect("write temp file");

        let txt_path = file.path().with_extension("txt");
        std::fs::rename(file.path(), &txt_path).expect("rename temp file");

        let metadata = FileMetadata::from_path(&txt_path).expect("metadata from path");
        assert_eq!(metadata.mime_type.as_deref(), Some("text/plain"));
    }
}
