//! Apple-compatible cross-network file-transfer wire codec.
//!
//! The wire format is the flat JSON `CrossNetworkFileTransferMessage` v1
//! contract used by the Apple WebRTC control channel. The flat DTO stays
//! private so invalid combinations of optional fields do not leak into the
//! rest of the Rust codebase. Public callers work with typed operations, and
//! both decoding and encoding validate the complete operation contract.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::hash::{Hash, Hasher};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use uuid::Uuid;

pub const CROSS_NETWORK_FILE_TRANSFER_VERSION: i64 = 1;
pub const MAX_CROSS_NETWORK_FILE_JSON_BYTES: usize = 1024 * 1024;
pub const MAX_CROSS_NETWORK_FILE_BYTES: u64 = 1024 * 1024 * 1024;
pub const MAX_CROSS_NETWORK_FILE_CHUNK_BYTES: usize = 512 * 1024;
pub const MAX_CROSS_NETWORK_FILE_CHUNKS: u32 = 65_536;
pub const MAX_CROSS_NETWORK_MISSING_CHUNKS: usize = 512;
pub const MAX_CROSS_NETWORK_FILENAME_BYTES: usize = 255;
pub const MAX_CROSS_NETWORK_STATUS_MESSAGE_BYTES: usize = 512;

// Forward-compatible fields must be reviewed and named here individually.
// An empty list is intentional for the shipping v1 profile: arbitrary unknown
// JSON is never silently swallowed merely because the version is unchanged.
const FORWARD_COMPATIBLE_OPTIONAL_FIELDS_V1: &[&str] = &[];

const OP_METADATA: &str = "metadata";
const OP_METADATA_ACK: &str = "metadataAck";
const OP_CHUNK: &str = "chunk";
const OP_CHUNK_ACK: &str = "chunkAck";
const OP_COMPLETE: &str = "complete";
const OP_COMPLETE_ACK: &str = "completeAck";
const OP_CANCEL: &str = "cancel";
const OP_ERROR: &str = "error";
const MISSING_CHUNKS_MESSAGE: &str = "missingChunks";

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum CrossNetworkFileTransferWireError {
    #[error("cross-network file-transfer JSON exceeds the {maximum}-byte limit")]
    InputTooLarge { maximum: usize },
    #[error("invalid cross-network file-transfer JSON: {0}")]
    InvalidJson(String),
    #[error("missing required cross-network file-transfer field `{0}`")]
    MissingField(&'static str),
    #[error("unsupported cross-network file-transfer version {0}")]
    UnsupportedVersion(i64),
    #[error("unsupported cross-network file-transfer operation `{0}`")]
    UnsupportedOperation(String),
    #[error("unknown cross-network file-transfer field `{0}`")]
    UnknownField(String),
    #[error("field `{field}` is forbidden for cross-network file-transfer operation `{operation}`")]
    ForbiddenField {
        operation: &'static str,
        field: &'static str,
    },
    #[error("cross-network file-transfer field combination is invalid: {0}")]
    FieldConflict(&'static str),
    #[error("cross-network file-transfer transferId is not a canonical 36-character UUID")]
    InvalidTransferId,
    #[error("cross-network file-transfer numeric field `{field}` is out of range")]
    NumericOutOfRange { field: &'static str },
    #[error("cross-network file-transfer base64 field `{field}` is not canonical padded base64")]
    InvalidBase64 { field: &'static str },
    #[error("cross-network file-transfer digest field `{field}` must contain exactly 32 bytes")]
    InvalidDigestLength { field: &'static str },
    #[error("cross-network file-transfer filename is not a safe single path component")]
    InvalidFileName,
    #[error("cross-network file-transfer status message is invalid")]
    InvalidStatusMessage,
    #[error("cross-network file-transfer metadata dimensions are inconsistent")]
    InconsistentMetadata,
    #[error("cross-network file-transfer message does not match the bound metadata: {0}")]
    MetadataMismatch(&'static str),
    #[error("failed to encode cross-network file-transfer JSON: {0}")]
    Encoding(String),
}

/// A canonical UUID wire token that preserves the peer's original hex case.
#[derive(Clone)]
pub struct CrossNetworkTransferId {
    wire_value: String,
    value: Uuid,
}

impl CrossNetworkTransferId {
    pub fn parse(wire_value: impl Into<String>) -> Result<Self, CrossNetworkFileTransferWireError> {
        let wire_value = wire_value.into();
        if wire_value.len() != 36 || !wire_value.is_ascii() {
            return Err(CrossNetworkFileTransferWireError::InvalidTransferId);
        }
        let value = Uuid::parse_str(&wire_value)
            .map_err(|_| CrossNetworkFileTransferWireError::InvalidTransferId)?;
        if value.is_nil() {
            return Err(CrossNetworkFileTransferWireError::InvalidTransferId);
        }
        let canonical = value.hyphenated().to_string();
        if !wire_value.eq_ignore_ascii_case(&canonical) {
            return Err(CrossNetworkFileTransferWireError::InvalidTransferId);
        }
        Ok(Self { wire_value, value })
    }

    pub fn as_str(&self) -> &str {
        &self.wire_value
    }

    pub fn uuid(&self) -> Uuid {
        self.value
    }
}

impl PartialEq for CrossNetworkTransferId {
    fn eq(&self, other: &Self) -> bool {
        self.value == other.value
    }
}

impl Eq for CrossNetworkTransferId {}

impl Hash for CrossNetworkTransferId {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.value.hash(state);
    }
}

impl PartialOrd for CrossNetworkTransferId {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for CrossNetworkTransferId {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.value.cmp(&other.value)
    }
}

impl fmt::Debug for CrossNetworkTransferId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CrossNetworkTransferId(<redacted>)")
    }
}

impl fmt::Display for CrossNetworkTransferId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.wire_value)
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct CrossNetworkFileMetadataV1 {
    pub transfer_id: CrossNetworkTransferId,
    pub sender_device_id: Option<String>,
    pub sender_device_name: Option<String>,
    pub file_name: String,
    pub file_size: u64,
    pub chunk_size: u32,
    pub total_chunks: u32,
    pub mime_type: Option<String>,
}

#[derive(Clone, PartialEq, Eq)]
pub struct CrossNetworkFileChunkV1 {
    pub transfer_id: CrossNetworkTransferId,
    pub chunk_index: u32,
    pub chunk_data: Vec<u8>,
    pub chunk_sha256: [u8; 32],
    pub raw_size: u32,
}

#[derive(Clone, PartialEq, Eq)]
pub enum CrossNetworkFileChunkAckV1 {
    Received {
        transfer_id: CrossNetworkTransferId,
        chunk_index: u32,
        received_bytes: u64,
    },
    Missing {
        transfer_id: CrossNetworkTransferId,
        missing_chunks: Vec<u32>,
    },
}

#[derive(Clone, PartialEq, Eq)]
pub struct CrossNetworkFileCompletionV1 {
    pub transfer_id: CrossNetworkTransferId,
    pub received_bytes: u64,
    pub file_sha256: [u8; 32],
}

#[derive(Clone, PartialEq, Eq)]
pub enum CrossNetworkFileTransferMessageV1 {
    Metadata(CrossNetworkFileMetadataV1),
    MetadataAck {
        transfer_id: CrossNetworkTransferId,
    },
    Chunk(CrossNetworkFileChunkV1),
    ChunkAck(CrossNetworkFileChunkAckV1),
    Complete(CrossNetworkFileCompletionV1),
    CompleteAck(CrossNetworkFileCompletionV1),
    Cancel {
        transfer_id: CrossNetworkTransferId,
        message: Option<String>,
    },
    Error {
        transfer_id: CrossNetworkTransferId,
        chunk_index: Option<u32>,
        message: String,
    },
}

impl fmt::Debug for CrossNetworkFileTransferMessageV1 {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Metadata(metadata) => formatter
                .debug_struct("Metadata")
                .field("transfer_id", &metadata.transfer_id)
                .field("file_name", &"<redacted>")
                .field("file_size", &metadata.file_size)
                .field("chunk_size", &metadata.chunk_size)
                .field("total_chunks", &metadata.total_chunks)
                .finish(),
            Self::MetadataAck { transfer_id } => formatter
                .debug_struct("MetadataAck")
                .field("transfer_id", transfer_id)
                .finish(),
            Self::Chunk(chunk) => formatter
                .debug_struct("Chunk")
                .field("transfer_id", &chunk.transfer_id)
                .field("chunk_index", &chunk.chunk_index)
                .field("chunk_bytes", &chunk.chunk_data.len())
                .finish(),
            Self::ChunkAck(ack) => match ack {
                CrossNetworkFileChunkAckV1::Received {
                    transfer_id,
                    chunk_index,
                    received_bytes,
                } => formatter
                    .debug_struct("ChunkAck::Received")
                    .field("transfer_id", transfer_id)
                    .field("chunk_index", chunk_index)
                    .field("received_bytes", received_bytes)
                    .finish(),
                CrossNetworkFileChunkAckV1::Missing {
                    transfer_id,
                    missing_chunks,
                } => formatter
                    .debug_struct("ChunkAck::Missing")
                    .field("transfer_id", transfer_id)
                    .field("missing_chunk_count", &missing_chunks.len())
                    .finish(),
            },
            Self::Complete(completion) => debug_completion(formatter, "Complete", completion),
            Self::CompleteAck(completion) => debug_completion(formatter, "CompleteAck", completion),
            Self::Cancel { transfer_id, .. } => formatter
                .debug_struct("Cancel")
                .field("transfer_id", transfer_id)
                .field("message", &"<redacted>")
                .finish(),
            Self::Error {
                transfer_id,
                chunk_index,
                ..
            } => formatter
                .debug_struct("Error")
                .field("transfer_id", transfer_id)
                .field("chunk_index", chunk_index)
                .field("message", &"<redacted>")
                .finish(),
        }
    }
}

fn debug_completion(
    formatter: &mut fmt::Formatter<'_>,
    name: &str,
    completion: &CrossNetworkFileCompletionV1,
) -> fmt::Result {
    formatter
        .debug_struct(name)
        .field("transfer_id", &completion.transfer_id)
        .field("received_bytes", &completion.received_bytes)
        .field("file_sha256", &"<redacted>")
        .finish()
}

impl CrossNetworkFileTransferMessageV1 {
    pub fn transfer_id(&self) -> &CrossNetworkTransferId {
        match self {
            Self::Metadata(metadata) => &metadata.transfer_id,
            Self::MetadataAck { transfer_id }
            | Self::Cancel { transfer_id, .. }
            | Self::Error { transfer_id, .. } => transfer_id,
            Self::Chunk(chunk) => &chunk.transfer_id,
            Self::ChunkAck(ack) => match ack {
                CrossNetworkFileChunkAckV1::Received { transfer_id, .. }
                | CrossNetworkFileChunkAckV1::Missing { transfer_id, .. } => transfer_id,
            },
            Self::Complete(completion) | Self::CompleteAck(completion) => &completion.transfer_id,
        }
    }

    /// Validates state-dependent dimensions that cannot be proven from one
    /// flat wire message alone.
    pub fn validate_against_metadata(
        &self,
        metadata: &CrossNetworkFileMetadataV1,
    ) -> Result<(), CrossNetworkFileTransferWireError> {
        validate_metadata(metadata)?;
        if self.transfer_id().uuid() != metadata.transfer_id.uuid() {
            return Err(CrossNetworkFileTransferWireError::MetadataMismatch(
                "transferId",
            ));
        }
        match self {
            Self::Metadata(candidate) => {
                if candidate != metadata {
                    return Err(CrossNetworkFileTransferWireError::MetadataMismatch(
                        "metadata binding",
                    ));
                }
            }
            Self::Chunk(chunk) => {
                let expected = expected_chunk_size(metadata, chunk.chunk_index).ok_or(
                    CrossNetworkFileTransferWireError::MetadataMismatch("chunk index"),
                )?;
                if chunk.chunk_data.len() != expected
                    || usize::try_from(chunk.raw_size) != Ok(expected)
                {
                    return Err(CrossNetworkFileTransferWireError::MetadataMismatch(
                        "chunk length",
                    ));
                }
            }
            Self::ChunkAck(CrossNetworkFileChunkAckV1::Received {
                chunk_index,
                received_bytes,
                ..
            }) => {
                let expected = expected_received_bytes(metadata, *chunk_index).ok_or(
                    CrossNetworkFileTransferWireError::MetadataMismatch("chunk ACK index"),
                )?;
                if *received_bytes != expected {
                    return Err(CrossNetworkFileTransferWireError::MetadataMismatch(
                        "chunk ACK receivedBytes",
                    ));
                }
            }
            Self::ChunkAck(CrossNetworkFileChunkAckV1::Missing { missing_chunks, .. }) => {
                if missing_chunks
                    .iter()
                    .any(|index| *index >= metadata.total_chunks)
                {
                    return Err(CrossNetworkFileTransferWireError::MetadataMismatch(
                        "missing chunk index",
                    ));
                }
            }
            Self::Complete(completion) | Self::CompleteAck(completion) => {
                if completion.received_bytes != metadata.file_size {
                    return Err(CrossNetworkFileTransferWireError::MetadataMismatch(
                        "completion receivedBytes",
                    ));
                }
            }
            Self::MetadataAck { .. } | Self::Cancel { .. } | Self::Error { .. } => {}
        }
        Ok(())
    }
}

pub fn decode_cross_network_file_transfer_message_v1(
    bytes: &[u8],
) -> Result<CrossNetworkFileTransferMessageV1, CrossNetworkFileTransferWireError> {
    if bytes.len() > MAX_CROSS_NETWORK_FILE_JSON_BYTES {
        return Err(CrossNetworkFileTransferWireError::InputTooLarge {
            maximum: MAX_CROSS_NETWORK_FILE_JSON_BYTES,
        });
    }
    let raw: RawCrossNetworkFileTransferMessage = serde_json::from_slice(bytes)
        .map_err(|error| CrossNetworkFileTransferWireError::InvalidJson(error.to_string()))?;
    raw.into_typed()
}

pub fn encode_cross_network_file_transfer_message_v1(
    message: &CrossNetworkFileTransferMessageV1,
) -> Result<Vec<u8>, CrossNetworkFileTransferWireError> {
    validate_typed_message(message)?;
    let encoded = serde_json::to_vec(&RawCrossNetworkFileTransferMessage::from_typed(message))
        .map_err(|error| CrossNetworkFileTransferWireError::Encoding(error.to_string()))?;
    if encoded.len() > MAX_CROSS_NETWORK_FILE_JSON_BYTES {
        return Err(CrossNetworkFileTransferWireError::InputTooLarge {
            maximum: MAX_CROSS_NETWORK_FILE_JSON_BYTES,
        });
    }
    Ok(encoded)
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct RawCrossNetworkFileTransferMessage {
    #[serde(skip_serializing_if = "Option::is_none")]
    version: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    op: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    transfer_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sender_device_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sender_device_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_size: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    chunk_size: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    total_chunks: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mime_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    chunk_index: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    chunk_data: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    chunk_sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    nonce: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    raw_size: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    received_bytes: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    encryption: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    merkle_root: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    merkle_root_signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    merkle_root_signature_alg: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    missing_chunks: Option<Vec<i64>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    batch_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    batch_index: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    batch_total: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    relative_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
    #[serde(flatten, skip_serializing_if = "BTreeMap::is_empty")]
    extra_fields: BTreeMap<String, Value>,
}

impl RawCrossNetworkFileTransferMessage {
    fn base(op: &str, transfer_id: &CrossNetworkTransferId) -> Self {
        Self {
            version: Some(CROSS_NETWORK_FILE_TRANSFER_VERSION),
            op: Some(op.to_owned()),
            transfer_id: Some(transfer_id.as_str().to_owned()),
            ..Self::default()
        }
    }

    fn from_typed(message: &CrossNetworkFileTransferMessageV1) -> Self {
        match message {
            CrossNetworkFileTransferMessageV1::Metadata(metadata) => {
                let mut raw = Self::base(OP_METADATA, &metadata.transfer_id);
                raw.sender_device_id = metadata.sender_device_id.clone();
                raw.sender_device_name = metadata.sender_device_name.clone();
                raw.file_name = Some(metadata.file_name.clone());
                raw.file_size = Some(metadata.file_size as i64);
                raw.chunk_size = Some(i64::from(metadata.chunk_size));
                raw.total_chunks = Some(i64::from(metadata.total_chunks));
                raw.mime_type = metadata.mime_type.clone();
                raw
            }
            CrossNetworkFileTransferMessageV1::MetadataAck { transfer_id } => {
                Self::base(OP_METADATA_ACK, transfer_id)
            }
            CrossNetworkFileTransferMessageV1::Chunk(chunk) => {
                let mut raw = Self::base(OP_CHUNK, &chunk.transfer_id);
                raw.chunk_index = Some(i64::from(chunk.chunk_index));
                raw.chunk_data = Some(BASE64_STANDARD.encode(&chunk.chunk_data));
                raw.chunk_sha256 = Some(BASE64_STANDARD.encode(chunk.chunk_sha256));
                raw.raw_size = Some(i64::from(chunk.raw_size));
                raw
            }
            CrossNetworkFileTransferMessageV1::ChunkAck(ack) => match ack {
                CrossNetworkFileChunkAckV1::Received {
                    transfer_id,
                    chunk_index,
                    received_bytes,
                } => {
                    let mut raw = Self::base(OP_CHUNK_ACK, transfer_id);
                    raw.chunk_index = Some(i64::from(*chunk_index));
                    raw.received_bytes = Some(*received_bytes as i64);
                    raw
                }
                CrossNetworkFileChunkAckV1::Missing {
                    transfer_id,
                    missing_chunks,
                } => {
                    let mut raw = Self::base(OP_CHUNK_ACK, transfer_id);
                    raw.missing_chunks =
                        Some(missing_chunks.iter().copied().map(i64::from).collect());
                    raw.message = Some(MISSING_CHUNKS_MESSAGE.to_owned());
                    raw
                }
            },
            CrossNetworkFileTransferMessageV1::Complete(completion) => {
                raw_completion(OP_COMPLETE, completion)
            }
            CrossNetworkFileTransferMessageV1::CompleteAck(completion) => {
                raw_completion(OP_COMPLETE_ACK, completion)
            }
            CrossNetworkFileTransferMessageV1::Cancel {
                transfer_id,
                message,
            } => {
                let mut raw = Self::base(OP_CANCEL, transfer_id);
                raw.message = message.clone();
                raw
            }
            CrossNetworkFileTransferMessageV1::Error {
                transfer_id,
                chunk_index,
                message,
            } => {
                let mut raw = Self::base(OP_ERROR, transfer_id);
                raw.chunk_index = chunk_index.map(i64::from);
                raw.message = Some(message.clone());
                raw
            }
        }
    }

    fn into_typed(
        self,
    ) -> Result<CrossNetworkFileTransferMessageV1, CrossNetworkFileTransferWireError> {
        let version = self
            .version
            .ok_or(CrossNetworkFileTransferWireError::MissingField("version"))?;
        if version != CROSS_NETWORK_FILE_TRANSFER_VERSION {
            return Err(CrossNetworkFileTransferWireError::UnsupportedVersion(
                version,
            ));
        }
        validate_extra_fields(&self.extra_fields)?;
        let operation = self
            .op
            .as_deref()
            .ok_or(CrossNetworkFileTransferWireError::MissingField("op"))?;
        let transfer_id = CrossNetworkTransferId::parse(self.transfer_id.clone().ok_or(
            CrossNetworkFileTransferWireError::MissingField("transferId"),
        )?)?;

        match operation {
            OP_METADATA => self.decode_metadata(transfer_id),
            OP_METADATA_ACK => {
                self.require_allowed_fields(OP_METADATA_ACK, &[])?;
                Ok(CrossNetworkFileTransferMessageV1::MetadataAck { transfer_id })
            }
            OP_CHUNK => self.decode_chunk(transfer_id),
            OP_CHUNK_ACK => self.decode_chunk_ack(transfer_id),
            OP_COMPLETE => self.decode_completion(transfer_id, false),
            OP_COMPLETE_ACK => self.decode_completion(transfer_id, true),
            OP_CANCEL => {
                self.require_allowed_fields(OP_CANCEL, &["message"])?;
                if let Some(message) = self.message.as_deref() {
                    validate_status_message(message)?;
                }
                Ok(CrossNetworkFileTransferMessageV1::Cancel {
                    transfer_id,
                    message: self.message,
                })
            }
            OP_ERROR => {
                self.require_allowed_fields(OP_ERROR, &["chunkIndex", "message"])?;
                let chunk_index = self
                    .chunk_index
                    .map(|value| {
                        required_u32(Some(value), "chunkIndex", MAX_CROSS_NETWORK_FILE_CHUNKS - 1)
                    })
                    .transpose()?;
                let message = self
                    .message
                    .ok_or(CrossNetworkFileTransferWireError::MissingField("message"))?;
                validate_status_message(&message)?;
                Ok(CrossNetworkFileTransferMessageV1::Error {
                    transfer_id,
                    chunk_index,
                    message,
                })
            }
            other => Err(CrossNetworkFileTransferWireError::UnsupportedOperation(
                other.to_owned(),
            )),
        }
    }

    fn decode_metadata(
        self,
        transfer_id: CrossNetworkTransferId,
    ) -> Result<CrossNetworkFileTransferMessageV1, CrossNetworkFileTransferWireError> {
        self.require_allowed_fields(
            OP_METADATA,
            &[
                "senderDeviceId",
                "senderDeviceName",
                "fileName",
                "fileSize",
                "chunkSize",
                "totalChunks",
                "mimeType",
            ],
        )?;
        let metadata = CrossNetworkFileMetadataV1 {
            transfer_id,
            sender_device_id: validate_optional_token(self.sender_device_id, "senderDeviceId")?,
            sender_device_name: validate_optional_token(
                self.sender_device_name,
                "senderDeviceName",
            )?,
            file_name: self
                .file_name
                .ok_or(CrossNetworkFileTransferWireError::MissingField("fileName"))?,
            file_size: required_u64(self.file_size, "fileSize", MAX_CROSS_NETWORK_FILE_BYTES)?,
            chunk_size: required_u32(
                self.chunk_size,
                "chunkSize",
                MAX_CROSS_NETWORK_FILE_CHUNK_BYTES as u32,
            )?,
            total_chunks: required_u32(
                self.total_chunks,
                "totalChunks",
                MAX_CROSS_NETWORK_FILE_CHUNKS,
            )?,
            mime_type: validate_optional_token(self.mime_type, "mimeType")?,
        };
        validate_metadata(&metadata)?;
        Ok(CrossNetworkFileTransferMessageV1::Metadata(metadata))
    }

    fn decode_chunk(
        self,
        transfer_id: CrossNetworkTransferId,
    ) -> Result<CrossNetworkFileTransferMessageV1, CrossNetworkFileTransferWireError> {
        self.require_allowed_fields(
            OP_CHUNK,
            &["chunkIndex", "chunkData", "chunkSha256", "rawSize"],
        )?;
        let chunk_data = decode_canonical_base64(
            self.chunk_data
                .as_deref()
                .ok_or(CrossNetworkFileTransferWireError::MissingField("chunkData"))?,
            "chunkData",
        )?;
        let chunk_sha256 =
            decode_digest(
                self.chunk_sha256.as_deref().ok_or(
                    CrossNetworkFileTransferWireError::MissingField("chunkSha256"),
                )?,
                "chunkSha256",
            )?;
        let chunk = CrossNetworkFileChunkV1 {
            transfer_id,
            chunk_index: required_u32(
                self.chunk_index,
                "chunkIndex",
                MAX_CROSS_NETWORK_FILE_CHUNKS - 1,
            )?,
            raw_size: required_u32(
                self.raw_size,
                "rawSize",
                MAX_CROSS_NETWORK_FILE_CHUNK_BYTES as u32,
            )?,
            chunk_data,
            chunk_sha256,
        };
        validate_chunk(&chunk)?;
        Ok(CrossNetworkFileTransferMessageV1::Chunk(chunk))
    }

    fn decode_chunk_ack(
        self,
        transfer_id: CrossNetworkTransferId,
    ) -> Result<CrossNetworkFileTransferMessageV1, CrossNetworkFileTransferWireError> {
        self.require_allowed_fields(
            OP_CHUNK_ACK,
            &["chunkIndex", "receivedBytes", "missingChunks", "message"],
        )?;
        let has_regular = self.chunk_index.is_some() || self.received_bytes.is_some();
        let has_missing = self.missing_chunks.is_some() || self.message.is_some();
        let ack = match (has_regular, has_missing) {
            (true, false) => CrossNetworkFileChunkAckV1::Received {
                transfer_id,
                chunk_index: required_u32(
                    self.chunk_index,
                    "chunkIndex",
                    MAX_CROSS_NETWORK_FILE_CHUNKS - 1,
                )?,
                received_bytes: required_u64(
                    self.received_bytes,
                    "receivedBytes",
                    MAX_CROSS_NETWORK_FILE_BYTES,
                )?,
            },
            (false, true) => {
                if self.message.as_deref() != Some(MISSING_CHUNKS_MESSAGE) {
                    return Err(CrossNetworkFileTransferWireError::FieldConflict(
                        "missing chunk ACK requires message=missingChunks",
                    ));
                }
                CrossNetworkFileChunkAckV1::Missing {
                    transfer_id,
                    missing_chunks: decode_missing_chunks(self.missing_chunks)?,
                }
            }
            _ => {
                return Err(CrossNetworkFileTransferWireError::FieldConflict(
                    "chunkAck must be either a received ACK or a missing-chunk request",
                ));
            }
        };
        validate_chunk_ack(&ack)?;
        Ok(CrossNetworkFileTransferMessageV1::ChunkAck(ack))
    }

    fn decode_completion(
        self,
        transfer_id: CrossNetworkTransferId,
        acknowledgement: bool,
    ) -> Result<CrossNetworkFileTransferMessageV1, CrossNetworkFileTransferWireError> {
        let operation = if acknowledgement {
            OP_COMPLETE_ACK
        } else {
            OP_COMPLETE
        };
        self.require_allowed_fields(operation, &["receivedBytes", "fileSha256"])?;
        let completion = CrossNetworkFileCompletionV1 {
            transfer_id,
            received_bytes: required_u64(
                self.received_bytes,
                "receivedBytes",
                MAX_CROSS_NETWORK_FILE_BYTES,
            )?,
            file_sha256: decode_digest(
                self.file_sha256.as_deref().ok_or(
                    CrossNetworkFileTransferWireError::MissingField("fileSha256"),
                )?,
                "fileSha256",
            )?,
        };
        validate_completion(&completion)?;
        if acknowledgement {
            Ok(CrossNetworkFileTransferMessageV1::CompleteAck(completion))
        } else {
            Ok(CrossNetworkFileTransferMessageV1::Complete(completion))
        }
    }

    fn require_allowed_fields(
        &self,
        operation: &'static str,
        allowed: &[&str],
    ) -> Result<(), CrossNetworkFileTransferWireError> {
        for field in self.present_optional_fields() {
            if !allowed.contains(&field) {
                return Err(CrossNetworkFileTransferWireError::ForbiddenField { operation, field });
            }
        }
        Ok(())
    }

    fn present_optional_fields(&self) -> Vec<&'static str> {
        let candidates = [
            ("senderDeviceId", self.sender_device_id.is_some()),
            ("senderDeviceName", self.sender_device_name.is_some()),
            ("fileName", self.file_name.is_some()),
            ("fileSize", self.file_size.is_some()),
            ("chunkSize", self.chunk_size.is_some()),
            ("totalChunks", self.total_chunks.is_some()),
            ("mimeType", self.mime_type.is_some()),
            ("chunkIndex", self.chunk_index.is_some()),
            ("chunkData", self.chunk_data.is_some()),
            ("chunkSha256", self.chunk_sha256.is_some()),
            ("nonce", self.nonce.is_some()),
            ("rawSize", self.raw_size.is_some()),
            ("receivedBytes", self.received_bytes.is_some()),
            ("encryption", self.encryption.is_some()),
            ("fileSha256", self.file_sha256.is_some()),
            ("merkleRoot", self.merkle_root.is_some()),
            ("merkleRootSignature", self.merkle_root_signature.is_some()),
            (
                "merkleRootSignatureAlg",
                self.merkle_root_signature_alg.is_some(),
            ),
            ("missingChunks", self.missing_chunks.is_some()),
            ("batchId", self.batch_id.is_some()),
            ("batchIndex", self.batch_index.is_some()),
            ("batchTotal", self.batch_total.is_some()),
            ("relativePath", self.relative_path.is_some()),
            ("message", self.message.is_some()),
        ];
        candidates
            .into_iter()
            .filter_map(|(name, present)| present.then_some(name))
            .collect()
    }
}

fn raw_completion(
    operation: &str,
    completion: &CrossNetworkFileCompletionV1,
) -> RawCrossNetworkFileTransferMessage {
    let mut raw = RawCrossNetworkFileTransferMessage::base(operation, &completion.transfer_id);
    raw.received_bytes = Some(completion.received_bytes as i64);
    raw.file_sha256 = Some(BASE64_STANDARD.encode(completion.file_sha256));
    raw
}

fn validate_typed_message(
    message: &CrossNetworkFileTransferMessageV1,
) -> Result<(), CrossNetworkFileTransferWireError> {
    match message {
        CrossNetworkFileTransferMessageV1::Metadata(metadata) => validate_metadata(metadata),
        CrossNetworkFileTransferMessageV1::MetadataAck { .. } => Ok(()),
        CrossNetworkFileTransferMessageV1::Chunk(chunk) => validate_chunk(chunk),
        CrossNetworkFileTransferMessageV1::ChunkAck(ack) => validate_chunk_ack(ack),
        CrossNetworkFileTransferMessageV1::Complete(completion)
        | CrossNetworkFileTransferMessageV1::CompleteAck(completion) => {
            validate_completion(completion)
        }
        CrossNetworkFileTransferMessageV1::Cancel { message, .. } => {
            if let Some(message) = message {
                validate_status_message(message)?;
            }
            Ok(())
        }
        CrossNetworkFileTransferMessageV1::Error {
            chunk_index,
            message,
            ..
        } => {
            if chunk_index.is_some_and(|index| index >= MAX_CROSS_NETWORK_FILE_CHUNKS) {
                return Err(CrossNetworkFileTransferWireError::NumericOutOfRange {
                    field: "chunkIndex",
                });
            }
            validate_status_message(message)
        }
    }
}

fn validate_metadata(
    metadata: &CrossNetworkFileMetadataV1,
) -> Result<(), CrossNetworkFileTransferWireError> {
    validate_file_name(&metadata.file_name)?;
    if metadata.file_size > MAX_CROSS_NETWORK_FILE_BYTES
        || metadata.chunk_size == 0
        || metadata.chunk_size as usize > MAX_CROSS_NETWORK_FILE_CHUNK_BYTES
        || metadata.total_chunks > MAX_CROSS_NETWORK_FILE_CHUNKS
    {
        return Err(CrossNetworkFileTransferWireError::InconsistentMetadata);
    }
    let expected_chunks = expected_total_chunks(metadata.file_size, metadata.chunk_size)
        .ok_or(CrossNetworkFileTransferWireError::InconsistentMetadata)?;
    if expected_chunks != metadata.total_chunks {
        return Err(CrossNetworkFileTransferWireError::InconsistentMetadata);
    }
    if let Some(value) = metadata.sender_device_id.as_deref() {
        validate_token(value, "senderDeviceId")?;
    }
    if let Some(value) = metadata.sender_device_name.as_deref() {
        validate_token(value, "senderDeviceName")?;
    }
    if let Some(value) = metadata.mime_type.as_deref() {
        validate_token(value, "mimeType")?;
    }
    Ok(())
}

fn validate_chunk(
    chunk: &CrossNetworkFileChunkV1,
) -> Result<(), CrossNetworkFileTransferWireError> {
    if chunk.chunk_index >= MAX_CROSS_NETWORK_FILE_CHUNKS
        || chunk.chunk_data.is_empty()
        || chunk.chunk_data.len() > MAX_CROSS_NETWORK_FILE_CHUNK_BYTES
        || usize::try_from(chunk.raw_size) != Ok(chunk.chunk_data.len())
    {
        return Err(CrossNetworkFileTransferWireError::FieldConflict(
            "chunk index/data/rawSize are inconsistent",
        ));
    }
    Ok(())
}

fn validate_chunk_ack(
    ack: &CrossNetworkFileChunkAckV1,
) -> Result<(), CrossNetworkFileTransferWireError> {
    match ack {
        CrossNetworkFileChunkAckV1::Received {
            chunk_index,
            received_bytes,
            ..
        } => {
            if *chunk_index >= MAX_CROSS_NETWORK_FILE_CHUNKS
                || *received_bytes > MAX_CROSS_NETWORK_FILE_BYTES
            {
                return Err(CrossNetworkFileTransferWireError::FieldConflict(
                    "chunk ACK dimensions are out of range",
                ));
            }
        }
        CrossNetworkFileChunkAckV1::Missing { missing_chunks, .. } => {
            validate_missing_chunks(missing_chunks)?;
        }
    }
    Ok(())
}

fn validate_completion(
    completion: &CrossNetworkFileCompletionV1,
) -> Result<(), CrossNetworkFileTransferWireError> {
    if completion.received_bytes > MAX_CROSS_NETWORK_FILE_BYTES {
        return Err(CrossNetworkFileTransferWireError::NumericOutOfRange {
            field: "receivedBytes",
        });
    }
    Ok(())
}

fn validate_extra_fields(
    fields: &BTreeMap<String, Value>,
) -> Result<(), CrossNetworkFileTransferWireError> {
    if let Some(field) = fields
        .keys()
        .find(|field| !FORWARD_COMPATIBLE_OPTIONAL_FIELDS_V1.contains(&field.as_str()))
    {
        return Err(CrossNetworkFileTransferWireError::UnknownField(
            field.clone(),
        ));
    }
    Ok(())
}

fn validate_optional_token(
    value: Option<String>,
    field: &'static str,
) -> Result<Option<String>, CrossNetworkFileTransferWireError> {
    if let Some(value) = value.as_deref() {
        validate_token(value, field)?;
    }
    Ok(value)
}

fn validate_token(
    value: &str,
    field: &'static str,
) -> Result<(), CrossNetworkFileTransferWireError> {
    if value.is_empty()
        || value.trim() != value
        || value.len() > 1024
        || value.chars().any(char::is_control)
    {
        return Err(CrossNetworkFileTransferWireError::FieldConflict(field));
    }
    Ok(())
}

fn validate_file_name(value: &str) -> Result<(), CrossNetworkFileTransferWireError> {
    if value.is_empty()
        || value.trim() != value
        || value == "."
        || value == ".."
        || value.len() > MAX_CROSS_NETWORK_FILENAME_BYTES
        || value.chars().any(|character| {
            character.is_control() || matches!(character, '/' | '\\' | '\u{2044}' | '\u{2215}')
        })
    {
        return Err(CrossNetworkFileTransferWireError::InvalidFileName);
    }
    Ok(())
}

fn validate_status_message(value: &str) -> Result<(), CrossNetworkFileTransferWireError> {
    if value.is_empty()
        || value.trim().is_empty()
        || value.len() > MAX_CROSS_NETWORK_STATUS_MESSAGE_BYTES
        || value.chars().any(char::is_control)
    {
        return Err(CrossNetworkFileTransferWireError::InvalidStatusMessage);
    }
    Ok(())
}

fn required_u64(
    value: Option<i64>,
    field: &'static str,
    maximum: u64,
) -> Result<u64, CrossNetworkFileTransferWireError> {
    let value = value.ok_or(CrossNetworkFileTransferWireError::MissingField(field))?;
    let converted = u64::try_from(value)
        .map_err(|_| CrossNetworkFileTransferWireError::NumericOutOfRange { field })?;
    if converted > maximum {
        return Err(CrossNetworkFileTransferWireError::NumericOutOfRange { field });
    }
    Ok(converted)
}

fn required_u32(
    value: Option<i64>,
    field: &'static str,
    maximum: u32,
) -> Result<u32, CrossNetworkFileTransferWireError> {
    let value = value.ok_or(CrossNetworkFileTransferWireError::MissingField(field))?;
    let converted = u32::try_from(value)
        .map_err(|_| CrossNetworkFileTransferWireError::NumericOutOfRange { field })?;
    if converted > maximum {
        return Err(CrossNetworkFileTransferWireError::NumericOutOfRange { field });
    }
    Ok(converted)
}

fn decode_canonical_base64(
    encoded: &str,
    field: &'static str,
) -> Result<Vec<u8>, CrossNetworkFileTransferWireError> {
    let decoded = BASE64_STANDARD
        .decode(encoded)
        .map_err(|_| CrossNetworkFileTransferWireError::InvalidBase64 { field })?;
    if BASE64_STANDARD.encode(&decoded) != encoded {
        return Err(CrossNetworkFileTransferWireError::InvalidBase64 { field });
    }
    Ok(decoded)
}

fn decode_digest(
    encoded: &str,
    field: &'static str,
) -> Result<[u8; 32], CrossNetworkFileTransferWireError> {
    let decoded = decode_canonical_base64(encoded, field)?;
    decoded
        .try_into()
        .map_err(|_| CrossNetworkFileTransferWireError::InvalidDigestLength { field })
}

fn decode_missing_chunks(
    values: Option<Vec<i64>>,
) -> Result<Vec<u32>, CrossNetworkFileTransferWireError> {
    let values = values.ok_or(CrossNetworkFileTransferWireError::MissingField(
        "missingChunks",
    ))?;
    if values.is_empty() || values.len() > MAX_CROSS_NETWORK_MISSING_CHUNKS {
        return Err(CrossNetworkFileTransferWireError::FieldConflict(
            "missingChunks count is out of range",
        ));
    }
    values
        .into_iter()
        .map(|value| {
            required_u32(
                Some(value),
                "missingChunks",
                MAX_CROSS_NETWORK_FILE_CHUNKS - 1,
            )
        })
        .collect()
}

fn validate_missing_chunks(values: &[u32]) -> Result<(), CrossNetworkFileTransferWireError> {
    if values.is_empty()
        || values.len() > MAX_CROSS_NETWORK_MISSING_CHUNKS
        || values
            .iter()
            .any(|value| *value >= MAX_CROSS_NETWORK_FILE_CHUNKS)
    {
        return Err(CrossNetworkFileTransferWireError::FieldConflict(
            "missingChunks count or index is out of range",
        ));
    }
    let unique = values.iter().copied().collect::<BTreeSet<_>>();
    if unique.len() != values.len() || !values.windows(2).all(|pair| pair[0] < pair[1]) {
        return Err(CrossNetworkFileTransferWireError::FieldConflict(
            "missingChunks must be strictly increasing and unique",
        ));
    }
    Ok(())
}

fn expected_total_chunks(file_size: u64, chunk_size: u32) -> Option<u32> {
    if chunk_size == 0 {
        return None;
    }
    if file_size == 0 {
        return Some(0);
    }
    let chunk_size = u64::from(chunk_size);
    let total = file_size
        .checked_sub(1)?
        .checked_div(chunk_size)?
        .checked_add(1)?;
    u32::try_from(total).ok()
}

fn expected_chunk_size(metadata: &CrossNetworkFileMetadataV1, index: u32) -> Option<usize> {
    if index >= metadata.total_chunks {
        return None;
    }
    let offset = u64::from(index).checked_mul(u64::from(metadata.chunk_size))?;
    let remaining = metadata.file_size.checked_sub(offset)?;
    usize::try_from(remaining.min(u64::from(metadata.chunk_size))).ok()
}

fn expected_received_bytes(metadata: &CrossNetworkFileMetadataV1, index: u32) -> Option<u64> {
    expected_chunk_size(metadata, index)?;
    let chunk_count = u64::from(index).checked_add(1)?;
    chunk_count
        .checked_mul(u64::from(metadata.chunk_size))
        .map(|bytes| bytes.min(metadata.file_size))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    const LOWER_ID: &str = "018f82d0-5b4a-7d1c-8a2e-1234567890ab";
    const UPPER_ID: &str = "018F82D0-5B4A-7D1C-8A2E-1234567890AB";

    fn transfer_id(raw: &str) -> CrossNetworkTransferId {
        CrossNetworkTransferId::parse(raw).expect("valid transfer id")
    }

    fn digest(byte: u8) -> [u8; 32] {
        [byte; 32]
    }

    fn metadata(file_name: &str, file_size: u64, chunk_size: u32) -> CrossNetworkFileMetadataV1 {
        CrossNetworkFileMetadataV1 {
            transfer_id: transfer_id(LOWER_ID),
            sender_device_id: Some("ios-device-1".to_owned()),
            sender_device_name: Some("Ziang的iPad".to_owned()),
            file_name: file_name.to_owned(),
            file_size,
            chunk_size,
            total_chunks: expected_total_chunks(file_size, chunk_size).expect("chunk count"),
            mime_type: Some("application/octet-stream".to_owned()),
        }
    }

    fn assert_ast_round_trip(message: CrossNetworkFileTransferMessageV1) {
        let encoded = encode_cross_network_file_transfer_message_v1(&message).expect("encode");
        let decoded = decode_cross_network_file_transfer_message_v1(&encoded).expect("decode");
        assert_eq!(decoded, message);
        let first_ast: Value = serde_json::from_slice(&encoded).expect("first AST");
        let reencoded = encode_cross_network_file_transfer_message_v1(&decoded).expect("reencode");
        let second_ast: Value = serde_json::from_slice(&reencoded).expect("second AST");
        assert_eq!(first_ast, second_ast);
    }

    #[test]
    fn apple_produced_metadata_decodes_and_preserves_uppercase_uuid() {
        let apple_json = format!(
            r#"{{"version":1,"op":"metadata","transferId":"{UPPER_ID}","senderDeviceId":"ios-device-1","senderDeviceName":"Ziang的iPad","fileName":"报告 资料.pdf","fileSize":3,"chunkSize":2,"totalChunks":2,"mimeType":"application/pdf"}}"#
        );
        let decoded = decode_cross_network_file_transfer_message_v1(apple_json.as_bytes())
            .expect("decode Apple JSON");
        let CrossNetworkFileTransferMessageV1::Metadata(metadata) = &decoded else {
            panic!("expected metadata")
        };
        assert_eq!(metadata.transfer_id.as_str(), UPPER_ID);
        assert_eq!(metadata.file_name, "报告 资料.pdf");

        let encoded = encode_cross_network_file_transfer_message_v1(&decoded).expect("encode");
        let ast: Value = serde_json::from_slice(&encoded).expect("AST");
        assert_eq!(ast["transferId"], UPPER_ID);
        assert_eq!(ast["fileName"], "报告 资料.pdf");
    }

    #[test]
    fn apple_produced_asts_cover_all_eight_operations() {
        let chunk_hash = BASE64_STANDARD.encode(digest(0x10));
        let file_hash = BASE64_STANDARD.encode(digest(0x20));
        let apple_asts = vec![
            json!({
                "version": 1,
                "op": "metadata",
                "transferId": UPPER_ID,
                "senderDeviceId": "ios-device-1",
                "senderDeviceName": "Ziang的iPad",
                "fileName": "报告.pdf",
                "fileSize": 3,
                "chunkSize": 2,
                "totalChunks": 2,
                "mimeType": "application/pdf"
            }),
            json!({"version": 1, "op": "metadataAck", "transferId": UPPER_ID}),
            json!({
                "version": 1,
                "op": "chunk",
                "transferId": UPPER_ID,
                "chunkIndex": 0,
                "chunkData": "AQI=",
                "chunkSha256": chunk_hash,
                "rawSize": 2
            }),
            json!({
                "version": 1,
                "op": "chunkAck",
                "transferId": UPPER_ID,
                "chunkIndex": 0,
                "receivedBytes": 2
            }),
            json!({
                "version": 1,
                "op": "complete",
                "transferId": UPPER_ID,
                "receivedBytes": 3,
                "fileSha256": file_hash
            }),
            json!({
                "version": 1,
                "op": "completeAck",
                "transferId": UPPER_ID,
                "receivedBytes": 3,
                "fileSha256": BASE64_STANDARD.encode(digest(0x20))
            }),
            json!({
                "version": 1,
                "op": "cancel",
                "transferId": UPPER_ID,
                "message": "sender terminated before commit request"
            }),
            json!({
                "version": 1,
                "op": "error",
                "transferId": UPPER_ID,
                "chunkIndex": 1,
                "message": "chunk hash mismatch"
            }),
        ];

        for apple_ast in apple_asts {
            let apple_bytes = serde_json::to_vec(&apple_ast).expect("Apple fixture JSON");
            let decoded = decode_cross_network_file_transfer_message_v1(&apple_bytes)
                .expect("decode Apple AST");
            let rust_bytes =
                encode_cross_network_file_transfer_message_v1(&decoded).expect("Rust encode");
            let rust_ast: Value = serde_json::from_slice(&rust_bytes).expect("Rust AST");
            assert_eq!(rust_ast, apple_ast);
        }
    }

    #[test]
    fn rust_produced_messages_round_trip_all_eight_operations() {
        let metadata = metadata("payload.bin", 3, 2);
        let id = metadata.transfer_id.clone();
        let messages = vec![
            CrossNetworkFileTransferMessageV1::Metadata(metadata.clone()),
            CrossNetworkFileTransferMessageV1::MetadataAck {
                transfer_id: id.clone(),
            },
            CrossNetworkFileTransferMessageV1::Chunk(CrossNetworkFileChunkV1 {
                transfer_id: id.clone(),
                chunk_index: 0,
                chunk_data: vec![1, 2],
                chunk_sha256: digest(0x11),
                raw_size: 2,
            }),
            CrossNetworkFileTransferMessageV1::ChunkAck(CrossNetworkFileChunkAckV1::Received {
                transfer_id: id.clone(),
                chunk_index: 0,
                received_bytes: 2,
            }),
            CrossNetworkFileTransferMessageV1::Complete(CrossNetworkFileCompletionV1 {
                transfer_id: id.clone(),
                received_bytes: 3,
                file_sha256: digest(0x22),
            }),
            CrossNetworkFileTransferMessageV1::CompleteAck(CrossNetworkFileCompletionV1 {
                transfer_id: id.clone(),
                received_bytes: 3,
                file_sha256: digest(0x22),
            }),
            CrossNetworkFileTransferMessageV1::Cancel {
                transfer_id: id.clone(),
                message: Some("sender terminated before commit request".to_owned()),
            },
            CrossNetworkFileTransferMessageV1::Error {
                transfer_id: id,
                chunk_index: Some(1),
                message: "receiver rejected transfer".to_owned(),
            },
        ];
        for message in messages {
            assert_ast_round_trip(message);
        }
    }

    #[test]
    fn empty_file_uses_zero_chunks_and_exact_completion_receipt() {
        let metadata = metadata("empty.txt", 0, 16 * 1024);
        assert_eq!(metadata.total_chunks, 0);
        let completion =
            CrossNetworkFileTransferMessageV1::Complete(CrossNetworkFileCompletionV1 {
                transfer_id: metadata.transfer_id.clone(),
                received_bytes: 0,
                file_sha256: digest(0x33),
            });
        completion
            .validate_against_metadata(&metadata)
            .expect("exact zero-byte completion");
        assert_ast_round_trip(CrossNetworkFileTransferMessageV1::Metadata(metadata));
        assert_ast_round_trip(completion);
    }

    #[test]
    fn chunk_and_ack_are_checked_against_metadata_dimensions() {
        let metadata = metadata("payload.bin", 3, 2);
        let final_chunk = CrossNetworkFileTransferMessageV1::Chunk(CrossNetworkFileChunkV1 {
            transfer_id: metadata.transfer_id.clone(),
            chunk_index: 1,
            chunk_data: vec![3],
            chunk_sha256: digest(0x44),
            raw_size: 1,
        });
        final_chunk
            .validate_against_metadata(&metadata)
            .expect("short final chunk");

        let ack =
            CrossNetworkFileTransferMessageV1::ChunkAck(CrossNetworkFileChunkAckV1::Received {
                transfer_id: metadata.transfer_id.clone(),
                chunk_index: 1,
                received_bytes: 3,
            });
        ack.validate_against_metadata(&metadata)
            .expect("exact cumulative ACK");

        let wrong = CrossNetworkFileTransferMessageV1::Complete(CrossNetworkFileCompletionV1 {
            transfer_id: metadata.transfer_id.clone(),
            received_bytes: 2,
            file_sha256: digest(0x55),
        });
        assert_eq!(
            wrong.validate_against_metadata(&metadata),
            Err(CrossNetworkFileTransferWireError::MetadataMismatch(
                "completion receivedBytes"
            ))
        );
    }

    #[test]
    fn canonical_base64_matches_swift_data_encoding() {
        let message = CrossNetworkFileTransferMessageV1::Chunk(CrossNetworkFileChunkV1 {
            transfer_id: transfer_id(LOWER_ID),
            chunk_index: 0,
            chunk_data: vec![0x00, 0x01, 0xfe, 0xff],
            chunk_sha256: digest(0xaa),
            raw_size: 4,
        });
        let encoded = encode_cross_network_file_transfer_message_v1(&message).expect("encode");
        let ast: Value = serde_json::from_slice(&encoded).expect("AST");
        assert_eq!(ast["chunkData"], "AAH+/w==");
        assert_eq!(ast["chunkSha256"], BASE64_STANDARD.encode(digest(0xaa)));

        let noncanonical = format!(
            r#"{{"version":1,"op":"chunk","transferId":"{LOWER_ID}","chunkIndex":0,"chunkData":"AAH+/w","chunkSha256":"{}","rawSize":4}}"#,
            BASE64_STANDARD.encode(digest(0xaa))
        );
        assert!(matches!(
            decode_cross_network_file_transfer_message_v1(noncanonical.as_bytes()),
            Err(CrossNetworkFileTransferWireError::InvalidBase64 { field: "chunkData" })
        ));
    }

    #[test]
    fn missing_chunk_ack_is_bounded_sorted_and_unique() {
        let valid =
            CrossNetworkFileTransferMessageV1::ChunkAck(CrossNetworkFileChunkAckV1::Missing {
                transfer_id: transfer_id(LOWER_ID),
                missing_chunks: vec![0, 2, 4],
            });
        assert_ast_round_trip(valid);

        for invalid in [vec![], vec![2, 1], vec![1, 1]] {
            let message =
                CrossNetworkFileTransferMessageV1::ChunkAck(CrossNetworkFileChunkAckV1::Missing {
                    transfer_id: transfer_id(LOWER_ID),
                    missing_chunks: invalid,
                });
            assert!(encode_cross_network_file_transfer_message_v1(&message).is_err());
        }
    }

    #[test]
    fn rejects_unknown_versions_operations_fields_and_forbidden_known_fields() {
        let cases = [
            (
                json!({"version": 2, "op": "metadataAck", "transferId": LOWER_ID}),
                "version",
            ),
            (
                json!({"version": 1, "op": "future", "transferId": LOWER_ID}),
                "operation",
            ),
            (
                json!({"version": 1, "op": "metadataAck", "transferId": LOWER_ID, "futureField": true}),
                "unknown",
            ),
            (
                json!({"version": 1, "op": "metadataAck", "transferId": LOWER_ID, "fileName": "x"}),
                "forbidden",
            ),
            (
                json!({"version": 1, "op": "metadata", "transferId": LOWER_ID, "fileName": "x", "fileSize": 1, "chunkSize": 1, "totalChunks": 1, "encryption": "aes-gcm-256-v1"}),
                "unsupported-known-field",
            ),
        ];
        for (value, label) in cases {
            let result = decode_cross_network_file_transfer_message_v1(
                &serde_json::to_vec(&value).expect("JSON"),
            );
            assert!(result.is_err(), "{label} must fail");
        }
    }

    #[test]
    fn rejects_negative_overflow_and_inconsistent_numeric_boundaries() {
        let digest = BASE64_STANDARD.encode(digest(0x66));
        let cases = [
            format!(
                r#"{{"version":1,"op":"metadata","transferId":"{LOWER_ID}","fileName":"x","fileSize":-1,"chunkSize":1,"totalChunks":0}}"#
            ),
            format!(
                r#"{{"version":1,"op":"metadata","transferId":"{LOWER_ID}","fileName":"x","fileSize":{},"chunkSize":1,"totalChunks":1}}"#,
                MAX_CROSS_NETWORK_FILE_BYTES + 1
            ),
            format!(
                r#"{{"version":1,"op":"metadata","transferId":"{LOWER_ID}","fileName":"x","fileSize":2,"chunkSize":1,"totalChunks":1}}"#
            ),
            format!(
                r#"{{"version":1,"op":"chunk","transferId":"{LOWER_ID}","chunkIndex":-1,"chunkData":"AQ==","chunkSha256":"{digest}","rawSize":1}}"#
            ),
            format!(
                r#"{{"version":1,"op":"complete","transferId":"{LOWER_ID}","receivedBytes":9223372036854775808,"fileSha256":"{digest}"}}"#
            ),
        ];
        for input in cases {
            assert!(
                decode_cross_network_file_transfer_message_v1(input.as_bytes()).is_err(),
                "numeric boundary must fail: {input}"
            );
        }
    }

    #[test]
    fn rejects_unsafe_filenames_bad_digests_and_field_conflicts() {
        for file_name in ["", ".", "..", "../x", "a/b", "a\\b", "a\u{2044}b", " x"] {
            let value = json!({
                "version": 1,
                "op": "metadata",
                "transferId": LOWER_ID,
                "fileName": file_name,
                "fileSize": 1,
                "chunkSize": 1,
                "totalChunks": 1
            });
            assert!(
                decode_cross_network_file_transfer_message_v1(
                    &serde_json::to_vec(&value).expect("JSON")
                )
                .is_err(),
                "unsafe filename must fail: {file_name:?}"
            );
        }

        let short_digest = BASE64_STANDARD.encode([0u8; 31]);
        let bad_digest = format!(
            r#"{{"version":1,"op":"complete","transferId":"{LOWER_ID}","receivedBytes":1,"fileSha256":"{short_digest}"}}"#
        );
        assert!(matches!(
            decode_cross_network_file_transfer_message_v1(bad_digest.as_bytes()),
            Err(CrossNetworkFileTransferWireError::InvalidDigestLength {
                field: "fileSha256"
            })
        ));

        let conflict = json!({
            "version": 1,
            "op": "chunkAck",
            "transferId": LOWER_ID,
            "chunkIndex": 0,
            "receivedBytes": 1,
            "missingChunks": [0],
            "message": "missingChunks"
        });
        assert!(matches!(
            decode_cross_network_file_transfer_message_v1(
                &serde_json::to_vec(&conflict).expect("JSON")
            ),
            Err(CrossNetworkFileTransferWireError::FieldConflict(_))
        ));
    }

    #[test]
    fn rejects_invalid_uuid_forms_without_normalizing_wire_case() {
        for invalid in [
            "018f82d05b4a7d1c8a2e1234567890ab",
            "{018f82d0-5b4a-7d1c-8a2e-1234567890ab}",
            "018f82d0-5b4a-7d1c-8a2e-1234567890ag",
            "00000000-0000-0000-0000-000000000000",
        ] {
            assert_eq!(
                CrossNetworkTransferId::parse(invalid),
                Err(CrossNetworkFileTransferWireError::InvalidTransferId)
            );
        }
        assert_eq!(transfer_id(UPPER_ID).as_str(), UPPER_ID);
        assert_eq!(transfer_id(UPPER_ID), transfer_id(LOWER_ID));
    }

    #[test]
    fn maximum_file_chunk_count_filename_and_missing_list_boundaries_are_supported() {
        let max_metadata = metadata(&"名".repeat(85), MAX_CROSS_NETWORK_FILE_BYTES, 16 * 1024);
        assert_eq!(
            max_metadata.file_name.len(),
            MAX_CROSS_NETWORK_FILENAME_BYTES
        );
        assert_eq!(max_metadata.total_chunks, MAX_CROSS_NETWORK_FILE_CHUNKS);
        assert_ast_round_trip(CrossNetworkFileTransferMessageV1::Metadata(max_metadata));

        let max_chunk = CrossNetworkFileTransferMessageV1::Chunk(CrossNetworkFileChunkV1 {
            transfer_id: transfer_id(LOWER_ID),
            chunk_index: 0,
            chunk_data: vec![0x5a; MAX_CROSS_NETWORK_FILE_CHUNK_BYTES],
            chunk_sha256: digest(0x88),
            raw_size: MAX_CROSS_NETWORK_FILE_CHUNK_BYTES as u32,
        });
        assert_ast_round_trip(max_chunk);

        let max_missing =
            CrossNetworkFileTransferMessageV1::ChunkAck(CrossNetworkFileChunkAckV1::Missing {
                transfer_id: transfer_id(LOWER_ID),
                missing_chunks: (0..MAX_CROSS_NETWORK_MISSING_CHUNKS as u32).collect(),
            });
        assert_ast_round_trip(max_missing);

        let too_many_missing =
            CrossNetworkFileTransferMessageV1::ChunkAck(CrossNetworkFileChunkAckV1::Missing {
                transfer_id: transfer_id(LOWER_ID),
                missing_chunks: (0..=MAX_CROSS_NETWORK_MISSING_CHUNKS as u32).collect(),
            });
        assert!(encode_cross_network_file_transfer_message_v1(&too_many_missing).is_err());

        let too_long_name = metadata(&format!("{}a", "名".repeat(85)), 1, 1);
        assert!(
            encode_cross_network_file_transfer_message_v1(
                &CrossNetworkFileTransferMessageV1::Metadata(too_long_name)
            )
            .is_err()
        );
    }

    #[test]
    fn fuzz_style_truncation_and_size_boundaries_fail_closed() {
        let message = CrossNetworkFileTransferMessageV1::Chunk(CrossNetworkFileChunkV1 {
            transfer_id: transfer_id(LOWER_ID),
            chunk_index: 0,
            chunk_data: vec![0x5a; 257],
            chunk_sha256: digest(0x77),
            raw_size: 257,
        });
        let encoded = encode_cross_network_file_transfer_message_v1(&message).expect("encode");
        for end in 0..encoded.len() {
            assert!(
                decode_cross_network_file_transfer_message_v1(&encoded[..end]).is_err(),
                "truncated JSON at {end} must fail"
            );
        }

        let oversized = vec![b' '; MAX_CROSS_NETWORK_FILE_JSON_BYTES + 1];
        assert_eq!(
            decode_cross_network_file_transfer_message_v1(&oversized),
            Err(CrossNetworkFileTransferWireError::InputTooLarge {
                maximum: MAX_CROSS_NETWORK_FILE_JSON_BYTES
            })
        );

        let max_metadata = metadata(
            "边界.bin",
            MAX_CROSS_NETWORK_FILE_BYTES,
            MAX_CROSS_NETWORK_FILE_CHUNK_BYTES as u32,
        );
        assert_ast_round_trip(CrossNetworkFileTransferMessageV1::Metadata(max_metadata));
    }

    #[test]
    fn duplicate_known_json_fields_fail_instead_of_last_value_winning() {
        let duplicate =
            format!(r#"{{"version":1,"version":1,"op":"metadataAck","transferId":"{LOWER_ID}"}}"#);
        assert!(matches!(
            decode_cross_network_file_transfer_message_v1(duplicate.as_bytes()),
            Err(CrossNetworkFileTransferWireError::InvalidJson(_))
        ));
    }

    #[test]
    fn status_messages_are_bounded_and_control_free() {
        let id = transfer_id(LOWER_ID);
        let valid = CrossNetworkFileTransferMessageV1::Error {
            transfer_id: id.clone(),
            chunk_index: None,
            message: "接收端拒绝文件".to_owned(),
        };
        assert_ast_round_trip(valid);

        for message in ["".to_owned(), "bad\nmessage".to_owned(), "x".repeat(513)] {
            let invalid = CrossNetworkFileTransferMessageV1::Error {
                transfer_id: id.clone(),
                chunk_index: None,
                message,
            };
            assert!(encode_cross_network_file_transfer_message_v1(&invalid).is_err());
        }
    }
}
