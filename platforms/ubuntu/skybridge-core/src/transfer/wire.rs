//! File transfer wire protocol (macOS/iOS interop).
//!
//! This mirrors the SkyBridge Compass Pro transfer framing:
//! - Metadata: JSON (ISO-8601 timestamps) with a 8-byte header.
//! - Chunk packets: fixed-size binary header + payload (+ optional AEAD info).
//! - ACK/complete/final-ack control bytes.

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const METADATA_TYPE: u32 = 0x01;
const TRANSFER_ACK: u8 = 0x01;
const TRANSFER_COMPLETE: u8 = 0x02;
const FINAL_ACK: u8 = 0x03;

const TRANSFER_ID_LEN: usize = 36;
const CHECKSUM_LEN: usize = 64;
const CHUNK_HEADER_LEN: usize = 36 + 4 + 4 + 8 + 64 + 1 + 8;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileTransferMetadataWire {
    pub transfer_id: String,
    pub file_name: String,
    pub file_size: i64,
    pub checksum: String,
    pub merkle_root: Option<String>,
    pub hash_algorithm: Option<String>,
    pub compression_enabled: bool,
    pub encryption_enabled: bool,
    pub chunk_size: i32,
    pub timestamp: String,
    pub file_signature: Option<String>,
    pub signature_algorithm: Option<String>,
    pub signer_peer_id: Option<String>,
}

impl FileTransferMetadataWire {
    pub fn new(
        transfer_id: String,
        file_name: String,
        file_size: i64,
        checksum: String,
        chunk_size: i32,
    ) -> Self {
        Self {
            transfer_id,
            file_name,
            file_size,
            checksum,
            merkle_root: None,
            hash_algorithm: Some("SHA256".to_string()),
            compression_enabled: false,
            encryption_enabled: false,
            chunk_size,
            timestamp: now_iso8601(),
            file_signature: None,
            signature_algorithm: None,
            signer_peer_id: None,
        }
    }

    pub fn parsed_timestamp(&self) -> Option<DateTime<Utc>> {
        DateTime::parse_from_rfc3339(&self.timestamp)
            .ok()
            .map(|dt| dt.with_timezone(&Utc))
    }
}

#[derive(Debug, Clone)]
pub struct FileChunkPacketWire {
    pub transfer_id: String,
    pub chunk_index: u32,
    pub total_chunks: u32,
    pub data: Vec<u8>,
    pub checksum: String,
    pub is_compressed: bool,
    pub is_encrypted: bool,
    pub timestamp: DateTime<Utc>,
    pub aead_nonce: Option<Vec<u8>>,
    pub aead_tag: Option<Vec<u8>>,
}

impl FileChunkPacketWire {
    pub fn checksum_hex(data: &[u8]) -> String {
        use sha2::{Digest, Sha256};
        let hash = Sha256::digest(data);
        hex::encode(hash)
    }
}

#[derive(Debug, Clone)]
pub struct ChunkAckWire {
    pub transfer_id: String,
    pub chunk_index: u32,
    pub status: u8,
}

#[derive(Debug, Clone)]
pub struct TransferCompleteWire {
    pub transfer_id: String,
    pub hmac_tag: Option<Vec<u8>>,
}

pub struct FileTransferWire<T>
where
    T: AsyncRead + AsyncWrite + Unpin,
{
    stream: T,
}

impl<T> FileTransferWire<T>
where
    T: AsyncRead + AsyncWrite + Unpin,
{
    pub fn new(stream: T) -> Self {
        Self { stream }
    }

    pub fn into_inner(self) -> T {
        self.stream
    }

    pub async fn send_metadata(
        &mut self,
        metadata: &FileTransferMetadataWire,
    ) -> std::io::Result<()> {
        let mut encoder = serde_json::Serializer::new(Vec::new());
        metadata.serialize(&mut encoder).map_err(map_serde_err)?;
        let metadata_data = encoder.into_inner();

        let mut header = Vec::with_capacity(8);
        header.extend_from_slice(&METADATA_TYPE.to_be_bytes());
        header.extend_from_slice(&(metadata_data.len() as u32).to_be_bytes());

        self.stream.write_all(&header).await?;
        self.stream.write_all(&metadata_data).await?;
        self.stream.flush().await?;
        Ok(())
    }

    pub async fn recv_metadata(&mut self) -> std::io::Result<FileTransferMetadataWire> {
        let mut header = [0u8; 8];
        self.stream.read_exact(&mut header).await?;
        let message_type = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
        if message_type != METADATA_TYPE {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "unexpected metadata message type",
            ));
        }
        let length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;
        let mut payload = vec![0u8; length];
        self.stream.read_exact(&mut payload).await?;
        serde_json::from_slice(&payload).map_err(map_serde_err)
    }

    pub async fn send_transfer_ack(&mut self) -> std::io::Result<()> {
        self.send_transfer_ack_status(TRANSFER_ACK).await
    }

    pub async fn recv_transfer_ack(&mut self) -> std::io::Result<()> {
        let mut buf = [0u8; 1];
        self.stream.read_exact(&mut buf).await?;
        if buf[0] != TRANSFER_ACK {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "transfer rejected",
            ));
        }
        Ok(())
    }

    pub async fn send_transfer_ack_status(&mut self, status: u8) -> std::io::Result<()> {
        self.stream.write_all(&[status]).await?;
        self.stream.flush().await?;
        Ok(())
    }

    pub async fn send_chunk_packet(&mut self, packet: &FileChunkPacketWire) -> std::io::Result<()> {
        let mut header = Vec::with_capacity(CHUNK_HEADER_LEN);
        write_fixed_id(&mut header, &packet.transfer_id);
        header.extend_from_slice(&packet.chunk_index.to_be_bytes());
        header.extend_from_slice(&packet.total_chunks.to_be_bytes());
        header.extend_from_slice(&(packet.data.len() as u64).to_be_bytes());
        write_checksum(&mut header, &packet.checksum);
        let mut flags = 0u8;
        if packet.is_compressed {
            flags |= 0x01;
        }
        if packet.is_encrypted {
            flags |= 0x02;
        }
        header.push(flags);
        let ts = packet.timestamp.timestamp() as f64
            + (packet.timestamp.timestamp_subsec_nanos() as f64 / 1_000_000_000.0);
        header.extend_from_slice(&ts.to_le_bytes());

        self.stream.write_all(&header).await?;
        self.stream.write_all(&packet.data).await?;
        if packet.is_encrypted {
            let nonce = packet.aead_nonce.as_ref().ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, "missing AEAD nonce")
            })?;
            let tag = packet.aead_tag.as_ref().ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::InvalidData, "missing AEAD tag")
            })?;
            if nonce.len() != 12 || tag.len() != 16 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "invalid AEAD nonce/tag size",
                ));
            }
            self.stream.write_all(nonce).await?;
            self.stream.write_all(tag).await?;
        }
        self.stream.flush().await?;
        Ok(())
    }

    pub async fn recv_chunk_packet(&mut self) -> std::io::Result<FileChunkPacketWire> {
        let mut header = vec![0u8; CHUNK_HEADER_LEN];
        self.stream.read_exact(&mut header).await?;
        let mut offset = 0;
        let transfer_id = read_fixed_id(&header[offset..offset + TRANSFER_ID_LEN]);
        offset += TRANSFER_ID_LEN;
        let chunk_index = u32::from_be_bytes(read_u32(&header, &mut offset));
        let total_chunks = u32::from_be_bytes(read_u32(&header, &mut offset));
        let data_len = u64::from_be_bytes(read_u64(&header, &mut offset)) as usize;
        let checksum = read_checksum(&header[offset..offset + CHECKSUM_LEN]);
        offset += CHECKSUM_LEN;
        let flags = header[offset];
        offset += 1;
        let is_compressed = (flags & 0x01) != 0;
        let is_encrypted = (flags & 0x02) != 0;

        let ts_f64 = f64::from_le_bytes(read_f64(&header, &mut offset));
        let (secs, frac) = if ts_f64.is_finite() && ts_f64 >= 0.0 {
            let secs = ts_f64.trunc() as i64;
            let nanos = ((ts_f64.fract()) * 1_000_000_000.0).round() as u32;
            (secs, nanos)
        } else {
            (0, 0)
        };
        let timestamp = DateTime::<Utc>::from_timestamp(secs, frac)
            .unwrap_or_else(|| DateTime::<Utc>::from_timestamp(0, 0).unwrap());

        let mut data = vec![0u8; data_len];
        self.stream.read_exact(&mut data).await?;

        let mut aead_nonce = None;
        let mut aead_tag = None;
        if is_encrypted {
            let mut nonce = vec![0u8; 12];
            let mut tag = vec![0u8; 16];
            self.stream.read_exact(&mut nonce).await?;
            self.stream.read_exact(&mut tag).await?;
            aead_nonce = Some(nonce);
            aead_tag = Some(tag);
        }

        Ok(FileChunkPacketWire {
            transfer_id,
            chunk_index,
            total_chunks,
            data,
            checksum,
            is_compressed,
            is_encrypted,
            timestamp,
            aead_nonce,
            aead_tag,
        })
    }

    pub async fn send_chunk_ack(
        &mut self,
        transfer_id: &str,
        chunk_index: u32,
        status: u8,
    ) -> std::io::Result<()> {
        let mut buf = Vec::with_capacity(41);
        write_fixed_id(&mut buf, transfer_id);
        buf.extend_from_slice(&chunk_index.to_be_bytes());
        buf.push(status);
        self.stream.write_all(&buf).await?;
        self.stream.flush().await?;
        Ok(())
    }

    pub async fn recv_chunk_ack(&mut self) -> std::io::Result<ChunkAckWire> {
        let mut buf = [0u8; 41];
        self.stream.read_exact(&mut buf).await?;
        let transfer_id = read_fixed_id(&buf[..TRANSFER_ID_LEN]);
        let chunk_index = u32::from_be_bytes([buf[36], buf[37], buf[38], buf[39]]);
        let status = buf[40];
        Ok(ChunkAckWire {
            transfer_id,
            chunk_index,
            status,
        })
    }

    pub async fn send_transfer_complete(
        &mut self,
        transfer_id: &str,
        hmac_tag: Option<&[u8]>,
    ) -> std::io::Result<()> {
        let mut payload = vec![TRANSFER_COMPLETE];
        write_fixed_id(&mut payload, transfer_id);
        let tag_len = hmac_tag.map(|t| t.len()).unwrap_or(0) as u16;
        payload.extend_from_slice(&tag_len.to_be_bytes());
        if let Some(tag) = hmac_tag {
            payload.extend_from_slice(tag);
        }
        self.stream.write_all(&payload).await?;
        self.stream.flush().await?;
        Ok(())
    }

    pub async fn recv_transfer_complete(&mut self) -> std::io::Result<TransferCompleteWire> {
        let mut code = [0u8; 1];
        self.stream.read_exact(&mut code).await?;
        if code[0] != TRANSFER_COMPLETE {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "invalid transfer complete code",
            ));
        }
        let mut ext = [0u8; 38];
        self.stream.read_exact(&mut ext).await?;
        let transfer_id = read_fixed_id(&ext[..TRANSFER_ID_LEN]);
        let tag_len = u16::from_be_bytes([ext[36], ext[37]]) as usize;
        let mut tag = vec![0u8; tag_len];
        if tag_len > 0 {
            self.stream.read_exact(&mut tag).await?;
        }
        Ok(TransferCompleteWire {
            transfer_id,
            hmac_tag: if tag_len > 0 { Some(tag) } else { None },
        })
    }

    pub async fn send_final_ack(&mut self) -> std::io::Result<()> {
        self.stream.write_all(&[FINAL_ACK]).await?;
        self.stream.flush().await?;
        Ok(())
    }

    pub async fn recv_final_ack(&mut self) -> std::io::Result<()> {
        let mut buf = [0u8; 1];
        self.stream.read_exact(&mut buf).await?;
        if buf[0] != FINAL_ACK {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "invalid final ack code",
            ));
        }
        Ok(())
    }
}

fn now_iso8601() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn map_serde_err(err: impl std::fmt::Display) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, err.to_string())
}

fn write_fixed_id(buf: &mut Vec<u8>, transfer_id: &str) {
    let mut bytes = transfer_id.as_bytes().to_vec();
    bytes.resize(TRANSFER_ID_LEN, 0);
    buf.extend_from_slice(&bytes);
}

fn read_fixed_id(bytes: &[u8]) -> String {
    let raw = String::from_utf8_lossy(bytes);
    raw.trim_matches(|c| c == '\0' || c == ' ').to_string()
}

fn write_checksum(buf: &mut Vec<u8>, checksum: &str) {
    let mut bytes = checksum.as_bytes().to_vec();
    bytes.resize(CHECKSUM_LEN, b' ');
    buf.extend_from_slice(&bytes);
}

fn read_checksum(bytes: &[u8]) -> String {
    let raw = String::from_utf8_lossy(bytes);
    raw.trim_matches(|c| c == '\0' || c == ' ').to_string()
}

fn read_u32(buf: &[u8], offset: &mut usize) -> [u8; 4] {
    let out = [
        buf[*offset],
        buf[*offset + 1],
        buf[*offset + 2],
        buf[*offset + 3],
    ];
    *offset += 4;
    out
}

fn read_u64(buf: &[u8], offset: &mut usize) -> [u8; 8] {
    let out = [
        buf[*offset],
        buf[*offset + 1],
        buf[*offset + 2],
        buf[*offset + 3],
        buf[*offset + 4],
        buf[*offset + 5],
        buf[*offset + 6],
        buf[*offset + 7],
    ];
    *offset += 8;
    out
}

fn read_f64(buf: &[u8], offset: &mut usize) -> [u8; 8] {
    read_u64(buf, offset)
}
