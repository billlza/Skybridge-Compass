use serde::{Deserialize, Serialize};

/// Wire messages for cross-network (WebRTC DataChannel) file transfer.
///
/// This mirrors the macOS/iOS `CrossNetworkFileTransferWire.swift` schema:
/// - JSON codable
/// - `chunkData` is base64 in JSON (Vec<u8> with serde)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CrossNetworkFileTransferMessage {
    pub version: i32,
    pub op: CrossNetworkFileTransferOp,
    pub transfer_id: String,

    // Peer info (optional, used for UI/logging)
    pub sender_device_id: Option<String>,
    pub sender_device_name: Option<String>,

    // Metadata
    pub file_name: Option<String>,
    pub file_size: Option<i64>,
    pub chunk_size: Option<i32>,
    pub total_chunks: Option<i32>,
    pub mime_type: Option<String>,

    // Chunk
    pub chunk_index: Option<i32>,
    #[serde(default)]
    #[serde(with = "super::serde_bytes_flex::opt_bytes")]
    pub chunk_data: Option<Vec<u8>>,
    /// Uncompressed/raw size in bytes (used for progress/offset; optional for compatibility).
    pub raw_size: Option<i32>,
    pub received_bytes: Option<i64>,

    // Error/cancel
    pub message: Option<String>,
}

impl CrossNetworkFileTransferMessage {
    pub fn new(op: CrossNetworkFileTransferOp, transfer_id: String) -> Self {
        Self {
            version: 1,
            op,
            transfer_id,
            sender_device_id: None,
            sender_device_name: None,
            file_name: None,
            file_size: None,
            chunk_size: None,
            total_chunks: None,
            mime_type: None,
            chunk_index: None,
            chunk_data: None,
            raw_size: None,
            received_bytes: None,
            message: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_data_serializes_as_base64_string() {
        let mut msg = CrossNetworkFileTransferMessage::new(
            CrossNetworkFileTransferOp::Chunk,
            "t".to_string(),
        );
        msg.chunk_index = Some(1);
        msg.chunk_data = Some(vec![0x01, 0x02, 0x03]);
        let json = serde_json::to_string(&msg).expect("json");
        assert!(json.contains("\"chunkData\":\"AQID\""));
    }

    #[test]
    fn chunk_data_deserializes_from_array_or_base64() {
        let array_json =
            r#"{"version":1,"op":"chunk","transferId":"t","chunkIndex":1,"chunkData":[1,2,3]}"#;
        let msg: CrossNetworkFileTransferMessage =
            serde_json::from_str(array_json).expect("array decode");
        assert_eq!(msg.chunk_data.unwrap(), vec![1, 2, 3]);

        let b64_json =
            r#"{"version":1,"op":"chunk","transferId":"t","chunkIndex":1,"chunkData":"AQID"}"#;
        let msg: CrossNetworkFileTransferMessage =
            serde_json::from_str(b64_json).expect("b64 decode");
        assert_eq!(msg.chunk_data.unwrap(), vec![1, 2, 3]);
    }
}
