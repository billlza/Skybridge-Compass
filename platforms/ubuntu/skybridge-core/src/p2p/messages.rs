//! P2P Messages
//!
//! Message types for the P2P protocol.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::types::{HandshakePolicy, KeyShare};
use crate::crypto::signature::SignatureAlgorithm;
use crate::p2p::encoding::{DeterministicDecoder, DeterministicEncoder};

pub const HANDSHAKE_VERSION: u8 = 1;
const FINISHED_MAGIC: &[u8; 4] = b"FIN1";
const HPKE_MAGIC: &[u8; 4] = b"HPKE";
const HANDSHAKE_PADDING_MAGIC: &[u8; 4] = b"SBP1";
const HANDSHAKE_PADDING_HEADER_LEN: usize = 8; // magic + u32(actualLen, big-endian)
const EXTENSION_CONTAINER_MAGIC: &[u8; 4] = b"SOA1";
const EXTENSION_CONTAINER_HEADER_LEN: usize = 6; // magic + u16(len, little-endian)
const SUITE_MLKEM768_FS_COMPAT_WIRE_ID: u16 = 0x0102;
const SUITE_P256_COMPAT_WIRE_ID: u16 = 0x1002;

fn unwrap_handshake_padding_p1_if_needed(data: &[u8]) -> &[u8] {
    if data.len() < HANDSHAKE_PADDING_HEADER_LEN {
        return data;
    }
    if &data[0..4] != HANDSHAKE_PADDING_MAGIC {
        return data;
    }
    let actual_len = u32::from_be_bytes([data[4], data[5], data[6], data[7]]) as usize;
    if actual_len > data.len().saturating_sub(HANDSHAKE_PADDING_HEADER_LEN) {
        return data;
    }
    &data[HANDSHAKE_PADDING_HEADER_LEN..HANDSHAKE_PADDING_HEADER_LEN + actual_len]
}

fn append_u16_le(value: u16, out: &mut Vec<u8>) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn read_u16_le(data: &[u8], offset: &mut usize) -> Result<u16, super::P2PError> {
    if *offset + 2 > data.len() {
        return Err(super::P2PError::InvalidMessage(
            "Unexpected end of data".to_string(),
        ));
    }
    let value = u16::from_le_bytes([data[*offset], data[*offset + 1]]);
    *offset += 2;
    Ok(value)
}

fn read_u32_le(data: &[u8], offset: &mut usize) -> Result<u32, super::P2PError> {
    if *offset + 4 > data.len() {
        return Err(super::P2PError::InvalidMessage(
            "Unexpected end of data".to_string(),
        ));
    }
    let value = u32::from_le_bytes([
        data[*offset],
        data[*offset + 1],
        data[*offset + 2],
        data[*offset + 3],
    ]);
    *offset += 4;
    Ok(value)
}

fn read_bytes_u16(data: &[u8], offset: &mut usize) -> Result<Vec<u8>, super::P2PError> {
    let len = read_u16_le(data, offset)? as usize;
    if *offset + len > data.len() {
        return Err(super::P2PError::InvalidMessage(
            "Invalid length prefix".to_string(),
        ));
    }
    let bytes = data[*offset..*offset + len].to_vec();
    *offset += len;
    Ok(bytes)
}

fn append_bytes_u16(value: &[u8], out: &mut Vec<u8>) {
    append_u16_le(value.len() as u16, out);
    out.extend_from_slice(value);
}

fn read_fixed_32(data: &[u8], offset: &mut usize) -> Result<[u8; 32], super::P2PError> {
    if *offset + 32 > data.len() {
        return Err(super::P2PError::InvalidMessage(
            "Missing fixed-length field".to_string(),
        ));
    }
    let slice = &data[*offset..*offset + 32];
    *offset += 32;
    let mut out = [0u8; 32];
    out.copy_from_slice(slice);
    Ok(out)
}

fn expected_key_share_length(suite_wire_id: u16) -> Option<usize> {
    match suite_wire_id {
        0x0001 => Some(1120), // X-Wing: X25519(32) + ML-KEM-768(1088)
        0x0101 | SUITE_MLKEM768_FS_COMPAT_WIRE_ID => Some(1088), // ML-KEM-768 / ML-KEM-768-FS
        0x1001 => Some(32),   // X25519
        SUITE_P256_COMPAT_WIRE_ID => Some(65), // P-256 uncompressed public key
        _ => None,
    }
}

fn validate_key_share_length(suite_wire_id: u16, length: usize) -> Result<(), super::P2PError> {
    if let Some(expected) = expected_key_share_length(suite_wire_id)
        && expected != length
    {
        return Err(super::P2PError::InvalidMessage(
            "KeyShare length mismatch".to_string(),
        ));
    }
    Ok(())
}

fn expected_responder_share_length(suite_wire_id: u16) -> Option<usize> {
    match suite_wire_id {
        0x0102 => Some(32), // v2 responder ephemeral contribution
        0x0001 | 0x0101 => Some(0),
        _ => expected_key_share_length(suite_wire_id),
    }
}

fn validate_responder_share_length(
    suite_wire_id: u16,
    length: usize,
) -> Result<(), super::P2PError> {
    if let Some(expected) = expected_responder_share_length(suite_wire_id)
        && expected != length
    {
        return Err(super::P2PError::InvalidMessage(
            "ResponderShare length mismatch".to_string(),
        ));
    }
    Ok(())
}

fn validate_initiator_contribution_length(
    supported_suites: &[u16],
    length: usize,
) -> Result<(), super::P2PError> {
    if !supported_suites.contains(&SUITE_MLKEM768_FS_COMPAT_WIRE_ID) {
        return Ok(());
    }
    if length == 0 || length == 32 {
        return Ok(());
    }
    Err(super::P2PError::InvalidMessage(
        "v2 initiator contribution length mismatch".to_string(),
    ))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IdentityPublicKeys {
    pub protocol_public_key: Vec<u8>,
    pub protocol_algorithm: SignatureAlgorithm,
    pub secure_enclave_public_key: Option<Vec<u8>>,
}

impl IdentityPublicKeys {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.push(self.protocol_algorithm.wire_id());
        append_bytes_u16(&self.protocol_public_key, &mut out);
        match &self.secure_enclave_public_key {
            Some(key) => {
                out.push(0x01);
                append_bytes_u16(key, &mut out);
            }
            None => out.push(0x00),
        }
        out
    }

    pub fn decode(data: &[u8]) -> Result<Self, super::P2PError> {
        let mut offset = 0usize;
        if data.is_empty() {
            return Err(super::P2PError::InvalidMessage(
                "IdentityPublicKeys empty".to_string(),
            ));
        }
        let algorithm = SignatureAlgorithm::from_wire_id(data[0]).ok_or_else(|| {
            super::P2PError::InvalidMessage("Invalid identity algorithm".to_string())
        })?;
        offset += 1;
        let protocol_public_key = read_bytes_u16(data, &mut offset)?;
        if offset >= data.len() {
            return Err(super::P2PError::InvalidMessage(
                "IdentityPublicKeys truncated".to_string(),
            ));
        }
        let has_se = data[offset];
        offset += 1;
        let secure_enclave_public_key = if has_se != 0 {
            Some(read_bytes_u16(data, &mut offset)?)
        } else {
            None
        };
        if offset != data.len() {
            return Err(super::P2PError::InvalidMessage(
                "Trailing bytes in IdentityPublicKeys".to_string(),
            ));
        }
        Ok(Self {
            protocol_public_key,
            protocol_algorithm: algorithm,
            secure_enclave_public_key,
        })
    }

    pub fn decode_with_legacy_fallback(data: &[u8]) -> Result<Self, super::P2PError> {
        if data.len() >= 4 {
            let algorithm_byte = data[0];
            if (0x01..=0x03).contains(&algorithm_byte)
                && let Ok(decoded) = Self::decode(data)
            {
                return Ok(decoded);
            }
        }

        if data.len() == 65 && data.first() == Some(&0x04) {
            return Ok(Self {
                protocol_public_key: data.to_vec(),
                protocol_algorithm: SignatureAlgorithm::P256Ecdsa,
                secure_enclave_public_key: None,
            });
        }

        Err(super::P2PError::InvalidMessage(format!(
            "IdentityPublicKeys not decodable: expected new format or legacy P-256 uncompressed public key (65 bytes starting with 0x04), got {} bytes",
            data.len()
        )))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CryptoCapabilities {
    pub supported_kem: Vec<String>,
    pub supported_signature: Vec<String>,
    pub supported_auth_profiles: Vec<String>,
    pub supported_aead: Vec<String>,
    pub pqc_available: bool,
    pub platform_version: String,
    pub provider_type: String,
}

impl CryptoCapabilities {
    pub fn deterministic_encode(&self) -> Vec<u8> {
        let mut encoder = DeterministicEncoder::new();
        encoder.encode_string_array(&self.supported_kem);
        encoder.encode_string_array(&self.supported_signature);
        encoder.encode_string_array(&self.supported_auth_profiles);
        encoder.encode_string_array(&self.supported_aead);
        encoder.encode_bool(self.pqc_available);
        encoder.encode_string(&self.platform_version);
        encoder.encode_string(&self.provider_type);
        encoder.finalize()
    }

    pub fn deterministic_decode(data: &[u8]) -> Result<Self, super::P2PError> {
        let mut decoder = DeterministicDecoder::new(data);
        let supported_kem = decoder
            .decode_string_array()
            .ok_or_else(|| super::P2PError::InvalidMessage("Capabilities KEM".to_string()))?;
        let supported_signature = decoder
            .decode_string_array()
            .ok_or_else(|| super::P2PError::InvalidMessage("Capabilities signature".to_string()))?;
        let supported_auth_profiles = decoder
            .decode_string_array()
            .ok_or_else(|| super::P2PError::InvalidMessage("Capabilities profiles".to_string()))?;
        let supported_aead = decoder
            .decode_string_array()
            .ok_or_else(|| super::P2PError::InvalidMessage("Capabilities AEAD".to_string()))?;
        let pqc_available = decoder
            .decode_bool()
            .ok_or_else(|| super::P2PError::InvalidMessage("Capabilities pqc".to_string()))?;
        let platform_version = decoder
            .decode_string()
            .ok_or_else(|| super::P2PError::InvalidMessage("Capabilities platform".to_string()))?;
        let provider_type = decoder
            .decode_string()
            .ok_or_else(|| super::P2PError::InvalidMessage("Capabilities provider".to_string()))?;
        if !decoder.is_at_end() {
            return Err(super::P2PError::InvalidMessage(
                "Trailing bytes in capabilities".to_string(),
            ));
        }
        Ok(Self {
            supported_kem,
            supported_signature,
            supported_auth_profiles,
            supported_aead,
            pqc_available,
            platform_version,
            provider_type,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandshakeSealedBox {
    pub encapsulated_key: Vec<u8>,
    pub nonce: Vec<u8>,
    pub ciphertext: Vec<u8>,
    pub tag: Vec<u8>,
}

impl HandshakeSealedBox {
    pub fn combined_with_header(&self, suite_wire_id: u16) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(HPKE_MAGIC);
        // v1: AES-GCM payload (nonce=12, tag=16)
        // v2: HPKE ciphertext payload (nonce/tag may be empty)
        let version = if self.nonce.len() == 12 && self.tag.len() == 16 {
            1u8
        } else {
            2u8
        };
        out.push(version);
        append_u16_le(suite_wire_id, &mut out);
        out.extend_from_slice(&[0x00, 0x00]);
        append_u16_le(self.encapsulated_key.len() as u16, &mut out);
        out.push(self.nonce.len() as u8);
        out.push(self.tag.len() as u8);
        out.extend_from_slice(&(self.ciphertext.len() as u32).to_le_bytes());
        out.extend_from_slice(&self.encapsulated_key);
        out.extend_from_slice(&self.nonce);
        out.extend_from_slice(&self.ciphertext);
        out.extend_from_slice(&self.tag);
        out
    }

    pub fn from_combined(data: &[u8]) -> Result<Self, super::P2PError> {
        if data.len() < 17 {
            return Err(super::P2PError::InvalidMessage(
                "HPKE payload too short".to_string(),
            ));
        }
        if &data[0..4] != HPKE_MAGIC {
            return Err(super::P2PError::InvalidMessage(
                "HPKE magic mismatch".to_string(),
            ));
        }
        let version = data[4];
        if version != 1 && version != 2 {
            return Err(super::P2PError::InvalidMessage(
                "HPKE version unsupported".to_string(),
            ));
        }
        let mut offset = 5usize;
        let _suite_wire_id = read_u16_le(data, &mut offset)?;
        let _flags = read_u16_le(data, &mut offset)?;
        let enc_len = read_u16_le(data, &mut offset)? as usize;
        if enc_len > 4096 {
            return Err(super::P2PError::InvalidMessage(
                "HPKE encLen too large".to_string(),
            ));
        }
        let nonce_len = data[offset] as usize;
        let tag_len = data[offset + 1] as usize;
        offset += 2;
        let ct_len = read_u32_le(data, &mut offset)? as usize;
        if version == 1 {
            if nonce_len != 12 || tag_len != 16 {
                return Err(super::P2PError::InvalidMessage(
                    "HPKE v1 nonce/tag length mismatch".to_string(),
                ));
            }
        } else if !(nonce_len == 0 || nonce_len == 12) || !(tag_len == 0 || tag_len == 16) {
            return Err(super::P2PError::InvalidMessage(
                "HPKE v2 nonce/tag length invalid".to_string(),
            ));
        }

        // Handshake stage DoS limit: <= 64KB ciphertext.
        if ct_len > 64 * 1024 {
            return Err(super::P2PError::InvalidMessage(
                "HPKE ciphertext too large".to_string(),
            ));
        }

        let expected_total = 17usize
            .checked_add(enc_len)
            .and_then(|v| v.checked_add(nonce_len))
            .and_then(|v| v.checked_add(ct_len))
            .and_then(|v| v.checked_add(tag_len))
            .ok_or_else(|| {
                super::P2PError::InvalidMessage("HPKE payload length overflow".to_string())
            })?;
        if data.len() != expected_total {
            return Err(super::P2PError::InvalidMessage(
                "HPKE payload length mismatch".to_string(),
            ));
        }

        let encapsulated_key = data[offset..offset + enc_len].to_vec();
        offset += enc_len;
        let nonce = data[offset..offset + nonce_len].to_vec();
        offset += nonce_len;
        let ciphertext = data[offset..offset + ct_len].to_vec();
        offset += ct_len;
        let tag = data[offset..offset + tag_len].to_vec();
        Ok(Self {
            encapsulated_key,
            nonce,
            ciphertext,
            tag,
        })
    }
}

/// P2P message types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum P2PMessageType {
    // Handshake messages (0x01-0x1F)
    /// MessageA - Initiator hello
    HandshakeInit = 0x01,
    /// MessageB - Responder reply
    HandshakeResponse = 0x02,
    /// Finished - Handshake confirmation
    HandshakeFinished = 0x03,
    /// Error during handshake
    HandshakeError = 0x04,

    // Pairing messages (0x20-0x3F)
    /// QR code data for pairing
    PairingQRData = 0x20,
    /// PAKE message A
    PairingPakeMessageA = 0x21,
    /// PAKE message B
    PairingPakeMessageB = 0x22,
    /// Pairing confirmation
    PairingConfirmation = 0x23,

    // Data messages (0x80-0x9F)
    /// Video frame
    VideoFrame = 0x80,
    /// File metadata
    FileMetadata = 0x81,
    /// File chunk
    FileChunk = 0x82,
    /// File acknowledgment
    FileAck = 0x83,
    /// Clipboard data
    Clipboard = 0x84,
    /// Input event (mouse/keyboard)
    InputEvent = 0x85,

    // Control messages (0xC0-0xDF)
    /// Ping
    Ping = 0xC0,
    /// Pong
    Pong = 0xC1,
    /// Close connection
    Close = 0xC2,
    /// Keep-alive
    KeepAlive = 0xC3,
}

impl P2PMessageType {
    /// Parse from byte
    pub fn from_byte(b: u8) -> Option<Self> {
        match b {
            0x01 => Some(Self::HandshakeInit),
            0x02 => Some(Self::HandshakeResponse),
            0x03 => Some(Self::HandshakeFinished),
            0x04 => Some(Self::HandshakeError),
            0x20 => Some(Self::PairingQRData),
            0x21 => Some(Self::PairingPakeMessageA),
            0x22 => Some(Self::PairingPakeMessageB),
            0x23 => Some(Self::PairingConfirmation),
            0x80 => Some(Self::VideoFrame),
            0x81 => Some(Self::FileMetadata),
            0x82 => Some(Self::FileChunk),
            0x83 => Some(Self::FileAck),
            0x84 => Some(Self::Clipboard),
            0x85 => Some(Self::InputEvent),
            0xC0 => Some(Self::Ping),
            0xC1 => Some(Self::Pong),
            0xC2 => Some(Self::Close),
            0xC3 => Some(Self::KeepAlive),
            _ => None,
        }
    }
}

/// Handshake messages
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum HandshakeMessage {
    /// MessageA: Initiator's hello
    MessageA(MessageA),
    /// MessageB: Responder's reply
    MessageB(MessageB),
    /// Finished: Confirmation
    Finished(FinishedMessage),
    /// Error
    Error(HandshakeErrorMessage),
}

impl HandshakeMessage {
    /// Get message type
    pub fn message_type(&self) -> P2PMessageType {
        match self {
            Self::MessageA(_) => P2PMessageType::HandshakeInit,
            Self::MessageB(_) => P2PMessageType::HandshakeResponse,
            Self::Finished(_) => P2PMessageType::HandshakeFinished,
            Self::Error(_) => P2PMessageType::HandshakeError,
        }
    }

    /// Serialize to bytes
    pub fn to_bytes(&self) -> Vec<u8> {
        match self {
            Self::MessageA(msg) => msg.encode(),
            Self::MessageB(msg) => msg.encode(),
            Self::Finished(msg) => msg.encode(),
            Self::Error(msg) => msg.encode(),
        }
    }

    /// Deserialize from bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self, super::P2PError> {
        let data = unwrap_handshake_padding_p1_if_needed(data);
        if data.is_empty() {
            return Err(super::P2PError::InvalidMessage("Empty message".to_string()));
        }
        if data.len() >= 4 && &data[0..4] == FINISHED_MAGIC {
            return Ok(Self::Finished(FinishedMessage::decode(data)?));
        }
        if let Ok(message_a) = MessageA::decode(data) {
            return Ok(Self::MessageA(message_a));
        }
        if let Ok(message_b) = MessageB::decode(data) {
            return Ok(Self::MessageB(message_b));
        }
        Err(super::P2PError::InvalidMessage(
            "Unknown handshake payload".to_string(),
        ))
    }
}

/// MessageA - Initiator's hello message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageA {
    /// Protocol version
    pub version: u8,
    /// Supported crypto suites (ordered by preference)
    pub supported_suites: Vec<u16>,
    /// Key shares for supported KEMs
    pub key_shares: Vec<KeyShare>,
    /// Client nonce
    pub client_nonce: [u8; 32],
    /// Capabilities
    pub capabilities: CryptoCapabilities,
    /// Handshake policy (for downgrade resistance)
    pub policy: HandshakePolicy,
    /// Encoded identity public key set
    pub identity_public_key: Vec<u8>,
    /// Optional v2 initiator ephemeral contribution (e.g., FS suite X25519 pubkey).
    ///
    /// Per macOS/iOS wire format this field is present (as a length-prefixed blob)
    /// iff the supported suites include the v2-FS compat marker `0x0102`.
    pub initiator_contribution: Option<Vec<u8>>,
    /// Optional extension TLV bytes (container-wrapped on the wire).
    ///
    /// Wire format (only when non-empty):
    /// - magic "SOA1" (4 bytes)
    /// - length u16 little-endian (bytes)
    /// - extensionsRaw (TLV bytes)
    pub extensions_raw: Vec<u8>,
    /// Signature over the message (excluding this field)
    pub signature: Vec<u8>,
    /// Secure Enclave signature (optional)
    pub secure_enclave_signature: Option<Vec<u8>>,
}

impl MessageA {
    /// Deterministic transcript bytes (without signatures)
    pub fn transcript_bytes(&self) -> Vec<u8> {
        let mut data = Vec::new();
        data.push(self.version);
        append_u16_le(self.supported_suites.len() as u16, &mut data);
        for suite in &self.supported_suites {
            append_u16_le(*suite, &mut data);
        }
        append_u16_le(self.key_shares.len() as u16, &mut data);
        for share in &self.key_shares {
            append_u16_le(share.suite_id, &mut data);
            append_bytes_u16(&share.public_key, &mut data);
        }
        data.extend_from_slice(&self.client_nonce);
        let capabilities = self.capabilities.deterministic_encode();
        append_bytes_u16(&capabilities, &mut data);
        let policy = self.policy.encode_bytes();
        append_bytes_u16(&policy, &mut data);
        append_bytes_u16(&self.identity_public_key, &mut data);
        if self
            .supported_suites
            .contains(&SUITE_MLKEM768_FS_COMPAT_WIRE_ID)
        {
            let contribution = self.initiator_contribution.as_deref().unwrap_or(&[]);
            append_bytes_u16(contribution, &mut data);
        }
        if !self.extensions_raw.is_empty() {
            debug_assert!(self.extensions_raw.len() <= u16::MAX as usize);
            let ext_len = self.extensions_raw.len() as u16;
            data.extend_from_slice(EXTENSION_CONTAINER_MAGIC);
            append_u16_le(ext_len, &mut data);
            data.extend_from_slice(&self.extensions_raw);
        }
        data
    }

    /// Signature preimage (domain separated)
    pub fn signature_preimage(&self) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(b"SkyBridge-A");
        data.extend_from_slice(&self.transcript_bytes());
        data
    }

    /// Encode to wire bytes (macOS-compatible)
    pub fn encode(&self) -> Vec<u8> {
        let mut data = self.transcript_bytes();
        append_bytes_u16(&self.signature, &mut data);
        let se_sig = self.secure_enclave_signature.as_deref().unwrap_or(&[]);
        append_bytes_u16(se_sig, &mut data);
        data
    }

    /// Decode from wire bytes (macOS-compatible)
    pub fn decode(data: &[u8]) -> Result<Self, super::P2PError> {
        let mut offset = 0usize;
        if data.is_empty() {
            return Err(super::P2PError::InvalidMessage(
                "MessageA too short".to_string(),
            ));
        }
        let version = data[offset];
        offset += 1;
        if version != HANDSHAKE_VERSION {
            return Err(super::P2PError::InvalidMessage(
                "Handshake version mismatch".to_string(),
            ));
        }
        let suites_count = read_u16_le(data, &mut offset)? as usize;
        if suites_count == 0 {
            return Err(super::P2PError::InvalidMessage(
                "Invalid supportedSuites count".to_string(),
            ));
        }
        let mut supported_suites = Vec::with_capacity(suites_count);
        for _ in 0..suites_count {
            supported_suites.push(read_u16_le(data, &mut offset)?);
        }
        let key_share_count = read_u16_le(data, &mut offset)? as usize;
        if key_share_count > suites_count {
            return Err(super::P2PError::InvalidMessage(
                "Too many keyShares".to_string(),
            ));
        }
        let mut key_shares = Vec::with_capacity(key_share_count);
        let mut seen_key_share_suites = std::collections::HashSet::new();
        for _ in 0..key_share_count {
            let suite_id = read_u16_le(data, &mut offset)?;
            let share_bytes = read_bytes_u16(data, &mut offset)?;
            if !seen_key_share_suites.insert(suite_id) {
                return Err(super::P2PError::InvalidMessage(
                    "Duplicate keyShare suite".to_string(),
                ));
            }
            validate_key_share_length(suite_id, share_bytes.len())?;
            key_shares.push(KeyShare {
                suite_id,
                public_key: share_bytes,
            });
        }

        let mut last_index: Option<usize> = None;
        for share in &key_shares {
            let Some(index) = supported_suites
                .iter()
                .position(|suite| *suite == share.suite_id)
            else {
                return Err(super::P2PError::InvalidMessage(
                    "keyShare suite not in supportedSuites".to_string(),
                ));
            };
            if let Some(prev) = last_index
                && index < prev
            {
                return Err(super::P2PError::InvalidMessage(
                    "keyShares out of order".to_string(),
                ));
            }
            last_index = Some(index);
        }

        let client_nonce = read_fixed_32(data, &mut offset)?;
        let capabilities_bytes = read_bytes_u16(data, &mut offset)?;
        let capabilities = CryptoCapabilities::deterministic_decode(&capabilities_bytes)?;
        let policy_bytes = read_bytes_u16(data, &mut offset)?;
        let policy = HandshakePolicy::decode_bytes(&policy_bytes)
            .ok_or_else(|| super::P2PError::InvalidMessage("Invalid policy bytes".to_string()))?;
        let identity_public_key = read_bytes_u16(data, &mut offset)?;
        let initiator_contribution = if supported_suites.contains(&SUITE_MLKEM768_FS_COMPAT_WIRE_ID)
        {
            let contrib = read_bytes_u16(data, &mut offset)?;
            validate_initiator_contribution_length(&supported_suites, contrib.len())?;
            if contrib.is_empty() {
                None
            } else {
                Some(contrib)
            }
        } else {
            None
        };

        // Optional extensions container ("SOA1" + len + TLVs)
        let mut extensions_raw = Vec::new();
        if offset + EXTENSION_CONTAINER_HEADER_LEN <= data.len()
            && &data[offset..offset + 4] == EXTENSION_CONTAINER_MAGIC
        {
            offset += 4;
            let ext_len = read_u16_le(data, &mut offset)? as usize;
            if offset + ext_len > data.len() {
                return Err(super::P2PError::InvalidMessage(
                    "Extensions truncated".to_string(),
                ));
            }
            if ext_len > 0 {
                extensions_raw = data[offset..offset + ext_len].to_vec();
            }
            offset += ext_len;
        }

        let signature = read_bytes_u16(data, &mut offset)?;
        let secure_enclave_signature = if offset < data.len() {
            let se_sig = read_bytes_u16(data, &mut offset)?;
            if se_sig.is_empty() {
                None
            } else {
                Some(se_sig)
            }
        } else {
            None
        };
        if offset != data.len() {
            return Err(super::P2PError::InvalidMessage(
                "Trailing bytes in MessageA".to_string(),
            ));
        }
        Ok(Self {
            version,
            supported_suites,
            key_shares,
            client_nonce,
            capabilities,
            policy,
            identity_public_key,
            initiator_contribution,
            extensions_raw,
            signature,
            secure_enclave_signature,
        })
    }
}

/// MessageB - Responder's reply message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageB {
    /// Protocol version
    pub version: u8,
    /// Selected crypto suite
    pub selected_suite: u16,
    /// Responder share (classic) or empty for PQC
    pub responder_share: Vec<u8>,
    /// Server nonce
    pub server_nonce: [u8; 32],
    /// Encrypted payload (handshake capabilities)
    pub encrypted_payload: HandshakeSealedBox,
    /// Encoded identity public key set
    pub identity_public_key: Vec<u8>,
    /// Signature over MessageB preimage
    pub signature: Vec<u8>,
    /// Secure Enclave signature (optional)
    pub secure_enclave_signature: Option<Vec<u8>>,
}

impl MessageB {
    /// Deterministic transcript bytes (without signatures)
    pub fn transcript_bytes(&self) -> Vec<u8> {
        let mut data = Vec::new();
        data.push(self.version);
        append_u16_le(self.selected_suite, &mut data);
        append_bytes_u16(&self.responder_share, &mut data);
        data.extend_from_slice(&self.server_nonce);
        let payload = self
            .encrypted_payload
            .combined_with_header(self.selected_suite);
        append_bytes_u16(&payload, &mut data);
        append_bytes_u16(&self.identity_public_key, &mut data);
        data
    }

    /// Signature preimage (domain separated)
    pub fn signature_preimage(&self, transcript_hash_a: &[u8]) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(b"SkyBridge-B");
        data.extend_from_slice(transcript_hash_a);
        append_u16_le(self.selected_suite, &mut data);
        append_bytes_u16(&self.responder_share, &mut data);
        data.extend_from_slice(&self.server_nonce);
        let payload = self
            .encrypted_payload
            .combined_with_header(self.selected_suite);
        let payload_hash = Sha256::digest(&payload);
        data.extend_from_slice(&payload_hash);
        append_bytes_u16(&self.identity_public_key, &mut data);
        data
    }

    /// Encode to wire bytes (macOS-compatible)
    pub fn encode(&self) -> Vec<u8> {
        let mut data = self.transcript_bytes();
        append_bytes_u16(&self.signature, &mut data);
        let se_sig = self.secure_enclave_signature.as_deref().unwrap_or(&[]);
        append_bytes_u16(se_sig, &mut data);
        data
    }

    /// Decode from wire bytes (macOS-compatible)
    pub fn decode(data: &[u8]) -> Result<Self, super::P2PError> {
        let mut offset = 0usize;
        if data.is_empty() {
            return Err(super::P2PError::InvalidMessage(
                "MessageB too short".to_string(),
            ));
        }
        let version = data[offset];
        offset += 1;
        if version != HANDSHAKE_VERSION {
            return Err(super::P2PError::InvalidMessage(
                "Handshake version mismatch".to_string(),
            ));
        }
        let selected_suite = read_u16_le(data, &mut offset)?;
        let responder_share = read_bytes_u16(data, &mut offset)?;
        validate_responder_share_length(selected_suite, responder_share.len())?;
        let server_nonce = read_fixed_32(data, &mut offset)?;
        let payload_bytes = read_bytes_u16(data, &mut offset)?;
        let encrypted_payload = HandshakeSealedBox::from_combined(&payload_bytes)?;
        let identity_public_key = read_bytes_u16(data, &mut offset)?;
        let signature = read_bytes_u16(data, &mut offset)?;
        let secure_enclave_signature = if offset < data.len() {
            let se_sig = read_bytes_u16(data, &mut offset)?;
            if se_sig.is_empty() {
                None
            } else {
                Some(se_sig)
            }
        } else {
            None
        };
        if offset != data.len() {
            return Err(super::P2PError::InvalidMessage(
                "Trailing bytes in MessageB".to_string(),
            ));
        }
        Ok(Self {
            version,
            selected_suite,
            responder_share,
            server_nonce,
            encrypted_payload,
            identity_public_key,
            signature,
            secure_enclave_signature,
        })
    }
}

/// Finished direction
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum FinishedDirection {
    ResponderToInitiator = 1,
    InitiatorToResponder = 2,
}

/// Finished message - Handshake confirmation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FinishedMessage {
    /// Protocol version
    pub version: u8,
    /// Direction
    pub direction: FinishedDirection,
    /// MAC over transcript hash
    pub mac: Vec<u8>,
}

impl FinishedMessage {
    /// Create finished message from transcript hash
    pub fn new(base_key: &[u8], transcript_hash: &[u8], direction: FinishedDirection) -> Self {
        let label = match direction {
            FinishedDirection::ResponderToInitiator => "R2I",
            FinishedDirection::InitiatorToResponder => "I2R",
        };
        let mut info = Vec::new();
        info.extend_from_slice(b"SkyBridge-FINISHED|");
        info.extend_from_slice(label.as_bytes());
        info.push(b'|');
        info.extend_from_slice(transcript_hash);

        let hk = hkdf::Hkdf::<Sha256>::new(Some(&[]), base_key);
        let mut okm = [0u8; 32];
        hk.expand(&info, &mut okm).expect("HKDF expand failed");

        let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &okm);
        let mac = ring::hmac::sign(&key, transcript_hash);
        Self {
            version: HANDSHAKE_VERSION,
            direction,
            mac: mac.as_ref().to_vec(),
        }
    }

    /// Verify the finished message
    pub fn verify(&self, base_key: &[u8], transcript_hash: &[u8]) -> bool {
        let expected = Self::new(base_key, transcript_hash, self.direction);
        self.mac == expected.mac
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(FINISHED_MAGIC);
        data.push(self.version);
        data.push(self.direction as u8);
        data.extend_from_slice(&self.mac);
        data
    }

    pub fn decode(data: &[u8]) -> Result<Self, super::P2PError> {
        if data.len() < 6 {
            return Err(super::P2PError::InvalidMessage(
                "Finished too short".to_string(),
            ));
        }
        if &data[0..4] != FINISHED_MAGIC {
            return Err(super::P2PError::InvalidMessage(
                "Finished magic mismatch".to_string(),
            ));
        }
        let version = data[4];
        if version != HANDSHAKE_VERSION {
            return Err(super::P2PError::InvalidMessage(
                "Finished version mismatch".to_string(),
            ));
        }
        let direction = match data[5] {
            1 => FinishedDirection::ResponderToInitiator,
            2 => FinishedDirection::InitiatorToResponder,
            _ => {
                return Err(super::P2PError::InvalidMessage(
                    "Finished direction invalid".to_string(),
                ));
            }
        };
        let mac = data[6..].to_vec();
        Ok(Self {
            version,
            direction,
            mac,
        })
    }
}

/// Handshake error message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HandshakeErrorMessage {
    /// Error code
    pub code: u16,
    /// Error description
    pub message: String,
}

impl HandshakeErrorMessage {
    /// No common suite error
    pub fn no_common_suite() -> Self {
        Self {
            code: 1,
            message: "No common crypto suite".to_string(),
        }
    }

    /// Signature verification failed
    pub fn signature_failed() -> Self {
        Self {
            code: 2,
            message: "Signature verification failed".to_string(),
        }
    }

    /// Invalid message
    pub fn invalid_message(msg: &str) -> Self {
        Self {
            code: 3,
            message: format!("Invalid message: {}", msg),
        }
    }

    /// Unsupported suite / compatibility contract failure
    pub fn unsupported_suite(msg: &str) -> Self {
        Self {
            code: 4,
            message: format!("Unsupported suite: {}", msg),
        }
    }

    /// Internal error
    pub fn internal_error(msg: &str) -> Self {
        Self {
            code: 255,
            message: format!("Internal error: {}", msg),
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut data = Vec::new();
        append_u16_le(self.code, &mut data);
        append_bytes_u16(self.message.as_bytes(), &mut data);
        data
    }

    pub fn decode(data: &[u8]) -> Result<Self, super::P2PError> {
        let mut offset = 0usize;
        let code = read_u16_le(data, &mut offset)?;
        let message_bytes = read_bytes_u16(data, &mut offset)?;
        let message = String::from_utf8(message_bytes)
            .map_err(|_| super::P2PError::InvalidMessage("Invalid error message".to_string()))?;
        if offset != data.len() {
            return Err(super::P2PError::InvalidMessage(
                "Trailing bytes in error message".to_string(),
            ));
        }
        Ok(Self { code, message })
    }
}

/// Generic P2P message wrapper
#[derive(Debug, Clone)]
pub struct P2PMessage {
    /// Message type
    pub message_type: P2PMessageType,
    /// Channel ID
    pub channel: u8,
    /// Sequence number (for reliable delivery)
    pub sequence: u32,
    /// Payload
    pub payload: Vec<u8>,
}

impl P2PMessage {
    /// Create a new message
    pub fn new(message_type: P2PMessageType, channel: u8, payload: Vec<u8>) -> Self {
        Self {
            message_type,
            channel,
            sequence: 0,
            payload,
        }
    }

    /// Serialize to bytes
    /// Format: type (1) | channel (1) | sequence (4) | length (4) | payload
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut result = Vec::with_capacity(10 + self.payload.len());
        result.push(self.message_type as u8);
        result.push(self.channel);
        result.extend_from_slice(&self.sequence.to_be_bytes());
        result.extend_from_slice(&(self.payload.len() as u32).to_be_bytes());
        result.extend_from_slice(&self.payload);
        result
    }

    /// Deserialize from bytes
    pub fn from_bytes(data: &[u8]) -> Result<Self, super::P2PError> {
        if data.len() < 10 {
            return Err(super::P2PError::InvalidMessage(
                "Message too short".to_string(),
            ));
        }

        let message_type = P2PMessageType::from_byte(data[0])
            .ok_or_else(|| super::P2PError::InvalidMessage("Unknown message type".to_string()))?;

        let channel = data[1];
        let sequence = u32::from_be_bytes([data[2], data[3], data[4], data[5]]);
        let length = u32::from_be_bytes([data[6], data[7], data[8], data[9]]) as usize;

        if data.len() < 10 + length {
            return Err(super::P2PError::InvalidMessage(
                "Truncated payload".to_string(),
            ));
        }

        let payload = data[10..10 + length].to_vec();

        Ok(Self {
            message_type,
            channel,
            sequence,
            payload,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_message_roundtrip() {
        let msg = P2PMessage::new(P2PMessageType::Ping, 0, vec![1, 2, 3, 4, 5]);

        let bytes = msg.to_bytes();
        let parsed = P2PMessage::from_bytes(&bytes).unwrap();

        assert_eq!(parsed.message_type, msg.message_type);
        assert_eq!(parsed.channel, msg.channel);
        assert_eq!(parsed.payload, msg.payload);
    }

    #[test]
    fn test_finished_verify() {
        let key = [0u8; 32];
        let transcript_hash = Sha256::digest(b"test transcript");

        let finished = FinishedMessage::new(
            &key,
            &transcript_hash,
            FinishedDirection::InitiatorToResponder,
        );
        assert!(finished.verify(&key, &transcript_hash));
        let wrong_hash = Sha256::digest(b"wrong transcript");
        assert!(!finished.verify(&key, &wrong_hash));
    }

    fn wrap_sbp1(payload: &[u8], total_len: usize) -> Vec<u8> {
        let min_len = HANDSHAKE_PADDING_HEADER_LEN + payload.len();
        let total_len = total_len.max(min_len);
        let mut out = Vec::with_capacity(total_len);
        out.extend_from_slice(HANDSHAKE_PADDING_MAGIC);
        out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        out.extend_from_slice(payload);
        if out.len() < total_len {
            out.resize(total_len, 0xA5);
        }
        out
    }

    fn minimal_capabilities() -> CryptoCapabilities {
        CryptoCapabilities {
            supported_kem: vec!["X25519".to_string()],
            supported_signature: vec!["P-256".to_string()],
            supported_auth_profiles: vec!["Classic".to_string()],
            supported_aead: vec!["AES-256-GCM".to_string()],
            pqc_available: false,
            platform_version: "test".to_string(),
            provider_type: "CryptoKit-Classic".to_string(),
        }
    }

    #[test]
    fn test_handshake_message_sbp1_unwrap_message_a() {
        let identity_public_key = IdentityPublicKeys {
            protocol_public_key: vec![0x11; 32],
            protocol_algorithm: SignatureAlgorithm::Ed25519,
            secure_enclave_public_key: None,
        }
        .encode();

        let msg = MessageA {
            version: HANDSHAKE_VERSION,
            supported_suites: vec![0x1001],
            key_shares: vec![KeyShare {
                suite_id: 0x1001,
                public_key: vec![0x22; 32],
            }],
            client_nonce: [0x33; 32],
            capabilities: minimal_capabilities(),
            policy: HandshakePolicy::default(),
            identity_public_key,
            initiator_contribution: None,
            extensions_raw: Vec::new(),
            signature: vec![0x44; 8],
            secure_enclave_signature: None,
        };

        let raw = msg.encode();
        let wrapped = wrap_sbp1(&raw, raw.len() + 64);
        let parsed = HandshakeMessage::from_bytes(&wrapped).unwrap();
        match parsed {
            HandshakeMessage::MessageA(a) => assert_eq!(a.encode(), raw),
            other => panic!("expected MessageA, got {:?}", other),
        }
    }

    #[test]
    fn test_message_a_roundtrip_with_v2_initiator_contribution() {
        let identity_public_key = IdentityPublicKeys {
            protocol_public_key: vec![0x55; 32],
            protocol_algorithm: SignatureAlgorithm::MlDsa65,
            secure_enclave_public_key: None,
        }
        .encode();

        let msg = MessageA {
            version: HANDSHAKE_VERSION,
            supported_suites: vec![SUITE_MLKEM768_FS_COMPAT_WIRE_ID],
            key_shares: vec![KeyShare {
                suite_id: SUITE_MLKEM768_FS_COMPAT_WIRE_ID,
                public_key: vec![0x66; 1088],
            }],
            client_nonce: [0x77; 32],
            capabilities: CryptoCapabilities {
                supported_kem: vec!["ML-KEM-768-FS".to_string()],
                supported_signature: vec!["ML-DSA-65".to_string()],
                supported_auth_profiles: vec!["PQC".to_string()],
                supported_aead: vec!["AES-256-GCM".to_string()],
                pqc_available: true,
                platform_version: "test".to_string(),
                provider_type: "liboqs".to_string(),
            },
            policy: HandshakePolicy::default(),
            identity_public_key,
            initiator_contribution: Some(vec![0x88; 32]),
            extensions_raw: Vec::new(),
            signature: vec![0x99; 16],
            secure_enclave_signature: None,
        };

        let raw = msg.encode();
        let decoded = MessageA::decode(&raw).unwrap();
        assert_eq!(decoded.initiator_contribution, Some(vec![0x88; 32]));
        assert_eq!(decoded.encode(), raw);
    }

    #[test]
    fn test_message_a_roundtrip_with_extensions_raw() {
        let identity_public_key = IdentityPublicKeys {
            protocol_public_key: vec![0x11; 32],
            protocol_algorithm: SignatureAlgorithm::Ed25519,
            secure_enclave_public_key: None,
        }
        .encode();

        let msg = MessageA {
            version: HANDSHAKE_VERSION,
            supported_suites: vec![0x1001],
            key_shares: vec![KeyShare {
                suite_id: 0x1001,
                public_key: vec![0x22; 32],
            }],
            client_nonce: [0x33; 32],
            capabilities: minimal_capabilities(),
            policy: HandshakePolicy::default(),
            identity_public_key,
            initiator_contribution: None,
            extensions_raw: vec![0x01, 0x00, 0x51, 0x00, 0x01],
            signature: vec![0x44; 8],
            secure_enclave_signature: None,
        };

        let raw = msg.encode();
        let decoded = MessageA::decode(&raw).unwrap();
        assert_eq!(decoded.extensions_raw, msg.extensions_raw);
        assert_eq!(decoded.encode(), raw);
    }

    #[test]
    fn test_identity_public_keys_decode_legacy_fallback() {
        let mut legacy = vec![0x04];
        legacy.extend_from_slice(&[0x11; 64]);
        let decoded = IdentityPublicKeys::decode_with_legacy_fallback(&legacy).unwrap();
        assert_eq!(decoded.protocol_algorithm, SignatureAlgorithm::P256Ecdsa);
        assert_eq!(decoded.protocol_public_key, legacy);
        assert!(decoded.secure_enclave_public_key.is_none());
    }

    #[test]
    fn test_message_a_decode_rejects_invalid_keyshare_length() {
        let identity_public_key = IdentityPublicKeys {
            protocol_public_key: vec![0x11; 32],
            protocol_algorithm: SignatureAlgorithm::Ed25519,
            secure_enclave_public_key: None,
        }
        .encode();

        let msg = MessageA {
            version: HANDSHAKE_VERSION,
            supported_suites: vec![0x1001],
            key_shares: vec![KeyShare {
                suite_id: 0x1001,
                public_key: vec![0x22; 31], // should be 32 for X25519
            }],
            client_nonce: [0x33; 32],
            capabilities: minimal_capabilities(),
            policy: HandshakePolicy::default(),
            identity_public_key,
            initiator_contribution: None,
            extensions_raw: Vec::new(),
            signature: vec![0x44; 8],
            secure_enclave_signature: None,
        };

        let raw = msg.encode();
        let err = MessageA::decode(&raw).unwrap_err();
        assert!(format!("{err}").contains("KeyShare length mismatch"));
    }

    #[test]
    fn test_message_b_decode_rejects_invalid_responder_share_length() {
        let identity_public_key = IdentityPublicKeys {
            protocol_public_key: vec![0x55; 32],
            protocol_algorithm: SignatureAlgorithm::MlDsa65,
            secure_enclave_public_key: None,
        }
        .encode();

        let msg = MessageB {
            version: HANDSHAKE_VERSION,
            selected_suite: SUITE_MLKEM768_FS_COMPAT_WIRE_ID,
            responder_share: vec![0x66; 16], // should be 32 for 0x0102
            server_nonce: [0x77; 32],
            encrypted_payload: HandshakeSealedBox {
                encapsulated_key: vec![0x88; 1088],
                nonce: Vec::new(),
                ciphertext: vec![0x99; 64],
                tag: Vec::new(),
            },
            identity_public_key,
            signature: vec![0xAA; 16],
            secure_enclave_signature: None,
        };

        let raw = msg.encode();
        let err = MessageB::decode(&raw).unwrap_err();
        assert!(format!("{err}").contains("ResponderShare length mismatch"));
    }
}
