//! File Transfer Module
//!
//! Provides file transfer with BLAKE3 verification, persistent resumption,
//! adaptive compression (LZ4/Zstd), and parallel chunk processing.

#![allow(missing_docs)]

mod engine;
mod incoming;
mod keys;
mod server;
mod types;
mod wire;

pub use engine::{ChunkData, FileTransferEngine};
pub use incoming::{
    IncomingTransferCompleted, IncomingTransferDecision, IncomingTransferPromptConfig,
    IncomingTransferPromptRequest, IncomingTransferRequest, IncomingTransferSource,
};
pub use keys::TransferKeyStore;
pub use server::{FileTransferServer, FileTransferServerConfig};
pub use types::{
    ChunkInfo, ChunkStatus, CompressionStrategy, FileMetadata, FileTransfer, TransferConfig,
    TransferDirection, TransferManifest, TransferProgress, TransferState,
};
pub use wire::{
    ChunkAckWire, FileChunkPacketWire, FileTransferMetadataWire, FileTransferWire,
    TransferCompleteWire,
};
