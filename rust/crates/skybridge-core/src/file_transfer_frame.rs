//! Binary wire codec for live file transfer over the encrypted control channel.
//!
//! These frames are carried as the *plaintext* of the existing AES-256-GCM app
//! frame (see `handshake_app_frame.rs`). They use a self-contained binary layout
//! (no base64 / JSON) to keep bulk transfer at the throughput ceiling of the
//! data channel. Every multi-byte integer is big-endian (network order), to
//! match the 4-byte length prefix used by the transport's `send_framed_payload`.
//!
//! Discrimination from the legacy JSON keepalive frames is total: a JSON object
//! always starts with `{` (`0x7B`), while every file frame starts with the magic
//! `b"SBF1"` (`0x53`). The two are disjoint, so the decrypt path can branch on
//! the first byte without ambiguity.
//!
//! This module is pure (no I/O) so it can be exhaustively unit tested. All
//! decode errors are generic (no path / peer / digest material) so they are safe
//! to surface in logs.

use anyhow::{Result, bail};

/// Magic prefix identifying a SkyBridge binary file frame.
pub const FILE_FRAME_MAGIC: [u8; 4] = *b"SBF1";
/// Wire version of the file frame layout.
pub const FILE_FRAME_VERSION: u8 = 1;

const TYPE_OFFER: u8 = 0x01;
const TYPE_CHUNK: u8 = 0x02;
const TYPE_RECEIPT: u8 = 0x03;
const TYPE_CHUNK_ACK: u8 = 0x04;

/// Common header size: MAGIC(4) + VERSION(1) + TYPE(1) + TRANSFER_ID(16).
const HEADER_LEN: usize = 4 + 1 + 1 + 16;

/// Maximum advertised filename length in bytes.
pub const MAX_FILENAME_LEN: usize = 255;
/// Maximum reason string length in bytes (RECEIPT frames).
pub const MAX_REASON_LEN: usize = 255;
/// Policy cap on a single transfer's declared total size (2 GiB).
pub const MAX_TRANSFER_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// Chunk payload size. Chosen to amortize per-frame overhead to ~0.02% while
/// staying ~3% of the transport's 8 MiB framed cap and keeping reassembly
/// buffers small. See the module-level design notes.
pub const CHUNK_PAYLOAD_BYTES: usize = 256 * 1024;

/// A decoded file transfer frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileAppFrame {
    Offer {
        transfer_id: [u8; 16],
        total_size: u64,
        chunk_size: u32,
        expected_sha256: [u8; 32],
        filename: String,
    },
    Chunk {
        transfer_id: [u8; 16],
        sequence: u32,
        payload: Vec<u8>,
    },
    Receipt {
        transfer_id: [u8; 16],
        ok: bool,
        computed_sha256: [u8; 32],
        reason: String,
    },
    ChunkAck {
        transfer_id: [u8; 16],
        acked_through_seq: u32,
    },
}

/// Returns true if `plaintext` looks like a binary file frame (vs JSON).
pub fn is_file_app_frame(plaintext: &[u8]) -> bool {
    plaintext.len() >= 4 && plaintext[..4] == FILE_FRAME_MAGIC
}

fn push_header(buffer: &mut Vec<u8>, frame_type: u8, transfer_id: &[u8; 16]) {
    buffer.extend_from_slice(&FILE_FRAME_MAGIC);
    buffer.push(FILE_FRAME_VERSION);
    buffer.push(frame_type);
    buffer.extend_from_slice(transfer_id);
}

pub fn encode_offer(
    transfer_id: &[u8; 16],
    total_size: u64,
    chunk_size: u32,
    expected_sha256: &[u8; 32],
    filename: &str,
) -> Result<Vec<u8>> {
    if total_size > MAX_TRANSFER_BYTES {
        bail!("file transfer total size exceeds policy cap");
    }
    let filename_bytes = filename.as_bytes();
    if filename_bytes.is_empty() || filename_bytes.len() > MAX_FILENAME_LEN {
        bail!("file transfer filename length out of range");
    }
    if filename_bytes.contains(&0) {
        bail!("file transfer filename contains NUL");
    }
    let mut buffer = Vec::with_capacity(HEADER_LEN + 8 + 4 + 32 + 2 + filename_bytes.len());
    push_header(&mut buffer, TYPE_OFFER, transfer_id);
    buffer.extend_from_slice(&total_size.to_be_bytes());
    buffer.extend_from_slice(&chunk_size.to_be_bytes());
    buffer.extend_from_slice(expected_sha256);
    buffer.extend_from_slice(&(filename_bytes.len() as u16).to_be_bytes());
    buffer.extend_from_slice(filename_bytes);
    Ok(buffer)
}

pub fn encode_chunk(transfer_id: &[u8; 16], sequence: u32, payload: &[u8]) -> Result<Vec<u8>> {
    if payload.len() > CHUNK_PAYLOAD_BYTES {
        bail!("file transfer chunk payload exceeds chunk size");
    }
    let mut buffer = Vec::with_capacity(HEADER_LEN + 4 + 4 + payload.len());
    push_header(&mut buffer, TYPE_CHUNK, transfer_id);
    buffer.extend_from_slice(&sequence.to_be_bytes());
    buffer.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    buffer.extend_from_slice(payload);
    Ok(buffer)
}

pub fn encode_receipt(
    transfer_id: &[u8; 16],
    ok: bool,
    computed_sha256: &[u8; 32],
    reason: &str,
) -> Result<Vec<u8>> {
    let reason_bytes = reason.as_bytes();
    if reason_bytes.len() > MAX_REASON_LEN {
        bail!("file transfer receipt reason too long");
    }
    if reason_bytes.contains(&0) {
        bail!("file transfer receipt reason contains NUL");
    }
    let mut buffer = Vec::with_capacity(HEADER_LEN + 1 + 32 + 2 + reason_bytes.len());
    push_header(&mut buffer, TYPE_RECEIPT, transfer_id);
    buffer.push(u8::from(ok));
    buffer.extend_from_slice(computed_sha256);
    buffer.extend_from_slice(&(reason_bytes.len() as u16).to_be_bytes());
    buffer.extend_from_slice(reason_bytes);
    Ok(buffer)
}

pub fn encode_chunk_ack(transfer_id: &[u8; 16], acked_through_seq: u32) -> Vec<u8> {
    let mut buffer = Vec::with_capacity(HEADER_LEN + 4);
    push_header(&mut buffer, TYPE_CHUNK_ACK, transfer_id);
    buffer.extend_from_slice(&acked_through_seq.to_be_bytes());
    buffer
}

/// Decode a binary file frame. Fails closed on any malformed input.
pub fn decode_file_app_frame(plaintext: &[u8]) -> Result<FileAppFrame> {
    let mut reader = Reader::new(plaintext);
    let magic = reader.take(4)?;
    if magic != FILE_FRAME_MAGIC {
        bail!("file frame magic mismatch");
    }
    let version = reader.take_u8()?;
    if version != FILE_FRAME_VERSION {
        bail!("unsupported file frame version");
    }
    let frame_type = reader.take_u8()?;
    let mut transfer_id = [0u8; 16];
    transfer_id.copy_from_slice(reader.take(16)?);

    let frame = match frame_type {
        TYPE_OFFER => {
            let total_size = reader.take_u64()?;
            if total_size > MAX_TRANSFER_BYTES {
                bail!("offered transfer size exceeds policy cap");
            }
            let chunk_size = reader.take_u32()?;
            let mut expected_sha256 = [0u8; 32];
            expected_sha256.copy_from_slice(reader.take(32)?);
            let filename_len = reader.take_u16()? as usize;
            if filename_len == 0 || filename_len > MAX_FILENAME_LEN {
                bail!("offered filename length out of range");
            }
            let filename_bytes = reader.take(filename_len)?;
            if filename_bytes.contains(&0) {
                bail!("offered filename contains NUL");
            }
            let filename = std::str::from_utf8(filename_bytes)
                .map_err(|_| anyhow::anyhow!("offered filename is not valid UTF-8"))?
                .to_owned();
            FileAppFrame::Offer {
                transfer_id,
                total_size,
                chunk_size,
                expected_sha256,
                filename,
            }
        }
        TYPE_CHUNK => {
            let sequence = reader.take_u32()?;
            let payload_len = reader.take_u32()? as usize;
            if payload_len > CHUNK_PAYLOAD_BYTES {
                bail!("chunk payload length exceeds chunk size");
            }
            let payload = reader.take(payload_len)?.to_vec();
            FileAppFrame::Chunk {
                transfer_id,
                sequence,
                payload,
            }
        }
        TYPE_RECEIPT => {
            let ok = match reader.take_u8()? {
                0 => false,
                1 => true,
                _ => bail!("invalid receipt status"),
            };
            let mut computed_sha256 = [0u8; 32];
            computed_sha256.copy_from_slice(reader.take(32)?);
            let reason_len = reader.take_u16()? as usize;
            if reason_len > MAX_REASON_LEN {
                bail!("receipt reason length out of range");
            }
            let reason_bytes = reader.take(reason_len)?;
            let reason = std::str::from_utf8(reason_bytes)
                .map_err(|_| anyhow::anyhow!("receipt reason is not valid UTF-8"))?
                .to_owned();
            FileAppFrame::Receipt {
                transfer_id,
                ok,
                computed_sha256,
                reason,
            }
        }
        TYPE_CHUNK_ACK => {
            let acked_through_seq = reader.take_u32()?;
            FileAppFrame::ChunkAck {
                transfer_id,
                acked_through_seq,
            }
        }
        _ => bail!("unknown file frame type"),
    };

    if !reader.is_empty() {
        bail!("trailing bytes in file frame");
    }
    Ok(frame)
}

struct Reader<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, offset: 0 }
    }

    fn take(&mut self, len: usize) -> Result<&'a [u8]> {
        let end = self
            .offset
            .checked_add(len)
            .ok_or_else(|| anyhow::anyhow!("file frame length overflow"))?;
        if end > self.data.len() {
            bail!("file frame truncated");
        }
        let slice = &self.data[self.offset..end];
        self.offset = end;
        Ok(slice)
    }

    fn take_u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }

    fn take_u16(&mut self) -> Result<u16> {
        let bytes = self.take(2)?;
        Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
    }

    fn take_u32(&mut self) -> Result<u32> {
        let bytes = self.take(4)?;
        Ok(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn take_u64(&mut self) -> Result<u64> {
        let bytes = self.take(8)?;
        let mut array = [0u8; 8];
        array.copy_from_slice(bytes);
        Ok(u64::from_be_bytes(array))
    }

    fn is_empty(&self) -> bool {
        self.offset == self.data.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TID: [u8; 16] = [7u8; 16];
    const HASH: [u8; 32] = [9u8; 32];

    #[test]
    fn offer_round_trips() {
        let encoded = encode_offer(&TID, 1024, CHUNK_PAYLOAD_BYTES as u32, &HASH, "report.pdf")
            .expect("encode offer");
        assert!(is_file_app_frame(&encoded));
        match decode_file_app_frame(&encoded).expect("decode offer") {
            FileAppFrame::Offer {
                transfer_id,
                total_size,
                chunk_size,
                expected_sha256,
                filename,
            } => {
                assert_eq!(transfer_id, TID);
                assert_eq!(total_size, 1024);
                assert_eq!(chunk_size, CHUNK_PAYLOAD_BYTES as u32);
                assert_eq!(expected_sha256, HASH);
                assert_eq!(filename, "report.pdf");
            }
            other => panic!("unexpected frame: {other:?}"),
        }
    }

    #[test]
    fn chunk_round_trips() {
        let payload = vec![3u8; 4096];
        let encoded = encode_chunk(&TID, 42, &payload).expect("encode chunk");
        match decode_file_app_frame(&encoded).expect("decode chunk") {
            FileAppFrame::Chunk {
                transfer_id,
                sequence,
                payload: decoded,
            } => {
                assert_eq!(transfer_id, TID);
                assert_eq!(sequence, 42);
                assert_eq!(decoded, payload);
            }
            other => panic!("unexpected frame: {other:?}"),
        }
    }

    #[test]
    fn receipt_round_trips_ok_and_err() {
        let ok = encode_receipt(&TID, true, &HASH, "").expect("encode ok receipt");
        match decode_file_app_frame(&ok).expect("decode ok receipt") {
            FileAppFrame::Receipt {
                ok,
                computed_sha256,
                reason,
                ..
            } => {
                assert!(ok);
                assert_eq!(computed_sha256, HASH);
                assert!(reason.is_empty());
            }
            other => panic!("unexpected frame: {other:?}"),
        }
        let err = encode_receipt(&TID, false, &[0u8; 32], "sha256 mismatch").expect("encode err");
        match decode_file_app_frame(&err).expect("decode err receipt") {
            FileAppFrame::Receipt { ok, reason, .. } => {
                assert!(!ok);
                assert_eq!(reason, "sha256 mismatch");
            }
            other => panic!("unexpected frame: {other:?}"),
        }
    }

    #[test]
    fn chunk_ack_round_trips() {
        let encoded = encode_chunk_ack(&TID, 17);
        match decode_file_app_frame(&encoded).expect("decode ack") {
            FileAppFrame::ChunkAck {
                transfer_id,
                acked_through_seq,
            } => {
                assert_eq!(transfer_id, TID);
                assert_eq!(acked_through_seq, 17);
            }
            other => panic!("unexpected frame: {other:?}"),
        }
    }

    #[test]
    fn json_object_is_not_a_file_frame() {
        assert!(!is_file_app_frame(b"{\"heartbeat\":{}}"));
    }

    #[test]
    fn decode_rejects_truncated_frame() {
        let encoded = encode_chunk(&TID, 1, &[1, 2, 3]).expect("encode");
        assert!(decode_file_app_frame(&encoded[..encoded.len() - 1]).is_err());
    }

    #[test]
    fn decode_rejects_trailing_bytes() {
        let mut encoded = encode_chunk_ack(&TID, 1);
        encoded.push(0xFF);
        assert!(decode_file_app_frame(&encoded).is_err());
    }

    #[test]
    fn decode_rejects_bad_magic_and_version() {
        let mut encoded = encode_chunk_ack(&TID, 1);
        encoded[0] = b'X';
        assert!(decode_file_app_frame(&encoded).is_err());
        let mut encoded = encode_chunk_ack(&TID, 1);
        encoded[4] = 0xFE;
        assert!(decode_file_app_frame(&encoded).is_err());
    }

    #[test]
    fn decode_rejects_unknown_type() {
        let mut encoded = encode_chunk_ack(&TID, 1);
        encoded[5] = 0x7F;
        assert!(decode_file_app_frame(&encoded).is_err());
    }

    #[test]
    fn encode_rejects_oversize_chunk_and_filename_and_total() {
        assert!(encode_chunk(&TID, 0, &vec![0u8; CHUNK_PAYLOAD_BYTES + 1]).is_err());
        assert!(encode_offer(&TID, 1, 1, &HASH, "").is_err());
        let long_name = "a".repeat(MAX_FILENAME_LEN + 1);
        assert!(encode_offer(&TID, 1, 1, &HASH, &long_name).is_err());
        assert!(encode_offer(&TID, MAX_TRANSFER_BYTES + 1, 1, &HASH, "x").is_err());
    }

    #[test]
    fn decode_rejects_oversize_chunk_payload_len() {
        // Hand-craft a chunk frame claiming a payload_len above the cap.
        let mut buffer = Vec::new();
        push_header(&mut buffer, TYPE_CHUNK, &TID);
        buffer.extend_from_slice(&0u32.to_be_bytes());
        buffer.extend_from_slice(&((CHUNK_PAYLOAD_BYTES as u32) + 1).to_be_bytes());
        assert!(decode_file_app_frame(&buffer).is_err());
    }
}
