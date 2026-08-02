use std::collections::BTreeMap;

use anyhow::{Result, anyhow, bail};
use sha2::{Digest, Sha256};

use crate::handshake_wire::{
    append_u16_le, encode_hpke_sealed_box as encode_shared_hpke_sealed_box, read_exact, read_u16_le,
};
use crate::{
    CryptoSuite, ProtocolIdentityBinding, ProtocolSigningAlgorithm, mldsa_verify_detached,
};

use super::{HANDSHAKE_A_DOMAIN, HANDSHAKE_VERSION};

const IDENTITY_ALGORITHM_MLDSA65: u8 = 0x02;
const IDENTITY_ALGORITHM_MLDSA87: u8 = 0x04;

#[derive(Debug, Clone)]
pub(super) struct DecodedMessageB {
    pub(super) selected_suite: CryptoSuite,
    pub(super) responder_share: Vec<u8>,
    pub(super) server_nonce: [u8; 32],
    pub(super) encrypted_payload_combined: Vec<u8>,
    pub(super) encrypted_payload_encapsulated_key: Vec<u8>,
    pub(super) encrypted_payload_nonce: Vec<u8>,
    pub(super) encrypted_payload_ciphertext: Vec<u8>,
    pub(super) encrypted_payload_tag: Vec<u8>,
    pub(super) identity_public_key: Vec<u8>,
    pub(super) signature: Vec<u8>,
}

#[derive(Debug, Clone)]
pub(super) struct DecodedIdentityPublicKey {
    pub(super) algorithm: ProtocolSigningAlgorithm,
    pub(super) public_key: Vec<u8>,
}

#[derive(Debug, Clone)]
struct DecodedHpkeSealedBox {
    encapsulated_key: Vec<u8>,
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
    tag: Vec<u8>,
}

#[derive(Debug, Clone)]
pub(super) struct DecodedMessageA {
    pub(super) offered_suites: Vec<CryptoSuite>,
    pub(super) key_shares: BTreeMap<CryptoSuite, Vec<u8>>,
    pub(super) client_nonce: [u8; 32],
    pub(super) transcript_hash_a: [u8; 32],
    pub(super) initiator_identity_algorithm: ProtocolSigningAlgorithm,
    pub(super) initiator_identity_public_key: Vec<u8>,
    /// The initiator's advertised `requirePQC` flag, decoded from the MessageA
    /// policy block (previously discarded). `true` => the initiator claims a
    /// PQC-mandatory posture on the wire.
    pub(super) initiator_requires_pqc: bool,
}

pub(super) fn decode_message_a(frame: &[u8]) -> Result<DecodedMessageA> {
    let mut offset = 0usize;
    let version = *frame
        .get(offset)
        .ok_or_else(|| anyhow!("MessageA too short"))?;
    offset += 1;
    if version != HANDSHAKE_VERSION {
        bail!("MessageA version mismatch");
    }

    let offered_count = read_u16_le(frame, &mut offset)? as usize;
    let mut offered_suites = Vec::with_capacity(offered_count);
    for _ in 0..offered_count {
        offered_suites.push(CryptoSuite::from_wire_id(read_u16_le(frame, &mut offset)?));
    }

    let keyshare_count = read_u16_le(frame, &mut offset)? as usize;
    let mut key_shares = BTreeMap::new();
    for _ in 0..keyshare_count {
        let suite = CryptoSuite::from_wire_id(read_u16_le(frame, &mut offset)?);
        let share_len = read_u16_le(frame, &mut offset)? as usize;
        key_shares.insert(suite, read_exact(frame, &mut offset, share_len)?.to_vec());
    }

    let client_nonce_bytes = read_exact(frame, &mut offset, 32)?;
    let mut client_nonce = [0u8; 32];
    client_nonce.copy_from_slice(client_nonce_bytes);
    let capabilities_len = read_u16_le(frame, &mut offset)? as usize;
    let _capabilities = read_exact(frame, &mut offset, capabilities_len)?;
    let policy_len = read_u16_le(frame, &mut offset)? as usize;
    let policy = read_exact(frame, &mut offset, policy_len)?;
    // The policy block was previously discarded. Decode its first byte
    // (`requirePQC`) so the responder can observe the initiator's advertised
    // downgrade posture. Wire format: see `pqc_policy_bytes()`.
    let initiator_requires_pqc = policy.first().is_some_and(|&flag| flag != 0x00);
    let identity_public_key_len = read_u16_le(frame, &mut offset)? as usize;
    let identity_public_key = read_exact(frame, &mut offset, identity_public_key_len)?.to_vec();
    let unsigned_end = offset;
    let signature_len = read_u16_le(frame, &mut offset)? as usize;
    let signature = read_exact(frame, &mut offset, signature_len)?.to_vec();

    if offset < frame.len() {
        let se_signature_len = read_u16_le(frame, &mut offset)? as usize;
        let _ = read_exact(frame, &mut offset, se_signature_len)?;
        if se_signature_len != 0 {
            bail!("Secure Enclave proof signatures are not supported by the Rust PQC handshake");
        }
    }
    if offset != frame.len() {
        bail!("unexpected trailing bytes in PQC MessageA");
    }

    let unsigned = &frame[..unsigned_end];
    let transcript_hash_a = Sha256::digest(unsigned);
    let mut transcript_hash_a_bytes = [0u8; 32];
    transcript_hash_a_bytes.copy_from_slice(transcript_hash_a.as_ref());

    let initiator_identity = decode_identity_public_key(&identity_public_key)?;
    let mut preimage = Vec::from(HANDSHAKE_A_DOMAIN);
    preimage.extend_from_slice(unsigned);
    mldsa_verify_detached(
        initiator_identity.algorithm,
        &preimage,
        &signature,
        &initiator_identity.public_key,
    )?;

    Ok(DecodedMessageA {
        offered_suites,
        key_shares,
        client_nonce,
        transcript_hash_a: transcript_hash_a_bytes,
        initiator_identity_algorithm: initiator_identity.algorithm,
        initiator_identity_public_key: initiator_identity.public_key,
        initiator_requires_pqc,
    })
}

pub(super) fn decode_message_b(frame: &[u8]) -> Result<DecodedMessageB> {
    let mut offset = 0usize;
    let version = *frame
        .get(offset)
        .ok_or_else(|| anyhow!("MessageB too short"))?;
    offset += 1;
    if version != HANDSHAKE_VERSION {
        bail!("MessageB version mismatch");
    }

    let selected_suite = CryptoSuite::from_wire_id(read_u16_le(frame, &mut offset)?);
    let responder_share_len = read_u16_le(frame, &mut offset)? as usize;
    let responder_share = read_exact(frame, &mut offset, responder_share_len)?.to_vec();
    let server_nonce_bytes = read_exact(frame, &mut offset, 32)?;
    let mut server_nonce = [0u8; 32];
    server_nonce.copy_from_slice(server_nonce_bytes);

    let payload_len = read_u16_le(frame, &mut offset)? as usize;
    let encrypted_payload_combined = read_exact(frame, &mut offset, payload_len)?.to_vec();
    let payload = decode_hpke_sealed_box(&encrypted_payload_combined)?;

    let identity_public_key_len = read_u16_le(frame, &mut offset)? as usize;
    let identity_public_key = read_exact(frame, &mut offset, identity_public_key_len)?.to_vec();

    let signature_len = read_u16_le(frame, &mut offset)? as usize;
    let signature = read_exact(frame, &mut offset, signature_len)?.to_vec();

    if offset < frame.len() {
        let se_signature_len = read_u16_le(frame, &mut offset)? as usize;
        let _ = read_exact(frame, &mut offset, se_signature_len)?;
        if se_signature_len != 0 {
            bail!("Secure Enclave proof signatures are not supported by the Rust PQC handshake");
        }
    }
    if offset != frame.len() {
        bail!("unexpected trailing bytes in PQC MessageB");
    }

    Ok(DecodedMessageB {
        selected_suite,
        responder_share,
        server_nonce,
        encrypted_payload_combined,
        encrypted_payload_encapsulated_key: payload.encapsulated_key,
        encrypted_payload_nonce: payload.nonce,
        encrypted_payload_ciphertext: payload.ciphertext,
        encrypted_payload_tag: payload.tag,
        identity_public_key,
        signature,
    })
}

pub(super) fn encode_identity_public_key(
    algorithm: ProtocolSigningAlgorithm,
    public_key: &[u8],
) -> Result<Vec<u8>> {
    ProtocolIdentityBinding::validate_key_encoding(public_key, algorithm)?;
    let algorithm_byte = match algorithm {
        ProtocolSigningAlgorithm::MlDsa65 => IDENTITY_ALGORITHM_MLDSA65,
        ProtocolSigningAlgorithm::MlDsa87 => IDENTITY_ALGORITHM_MLDSA87,
        ProtocolSigningAlgorithm::Ed25519 => {
            bail!("PQC handshake requires an ML-DSA protocol identity")
        }
    };
    let mut encoded = Vec::new();
    encoded.push(algorithm_byte);
    append_u16_le(&mut encoded, public_key.len() as u16);
    encoded.extend_from_slice(public_key);
    encoded.push(0x00);
    Ok(encoded)
}

pub(super) fn decode_identity_public_key(data: &[u8]) -> Result<DecodedIdentityPublicKey> {
    if data.len() < 1 + 2 + 1 {
        bail!("identity public key payload too short");
    }
    let algorithm = match data[0] {
        IDENTITY_ALGORITHM_MLDSA65 => ProtocolSigningAlgorithm::MlDsa65,
        IDENTITY_ALGORITHM_MLDSA87 => ProtocolSigningAlgorithm::MlDsa87,
        _ => bail!("unsupported identity public key algorithm"),
    };
    let mut offset = 1usize;
    let key_len = read_u16_le(data, &mut offset)? as usize;
    let public_key = read_exact(data, &mut offset, key_len)?.to_vec();
    ProtocolIdentityBinding::validate_key_encoding(&public_key, algorithm)?;
    let has_secure_enclave = *data
        .get(offset)
        .ok_or_else(|| anyhow!("missing secure enclave identity flag"))?;
    offset += 1;
    if has_secure_enclave != 0x00 {
        bail!("Secure Enclave identity keys are not supported by the Rust PQC handshake");
    }
    if offset != data.len() {
        bail!("unexpected trailing bytes in identity public key payload");
    }
    Ok(DecodedIdentityPublicKey {
        algorithm,
        public_key,
    })
}

fn decode_hpke_sealed_box(data: &[u8]) -> Result<DecodedHpkeSealedBox> {
    if data.len() < 17 {
        bail!("hpke sealed box too short");
    }
    if &data[..4] != b"HPKE" {
        bail!("invalid hpke sealed box magic");
    }
    let version = data[4];
    if version != 1 && version != 2 {
        bail!("unsupported hpke sealed box version");
    }
    let enc_len = u16::from_le_bytes([data[9], data[10]]) as usize;
    let nonce_len = data[11] as usize;
    let tag_len = data[12] as usize;
    let ciphertext_len = u32::from_le_bytes([data[13], data[14], data[15], data[16]]) as usize;
    let expected_len = 17 + enc_len + nonce_len + ciphertext_len + tag_len;
    if data.len() != expected_len {
        bail!("hpke sealed box length mismatch");
    }
    let mut offset = 17usize;
    let encapsulated_key = read_exact(data, &mut offset, enc_len)?.to_vec();
    let nonce = read_exact(data, &mut offset, nonce_len)?.to_vec();
    let ciphertext = read_exact(data, &mut offset, ciphertext_len)?.to_vec();
    let tag = read_exact(data, &mut offset, tag_len)?.to_vec();
    Ok(DecodedHpkeSealedBox {
        encapsulated_key,
        nonce,
        ciphertext,
        tag,
    })
}

pub(super) fn message_b_encoded_without_signature(message_b: &DecodedMessageB) -> Vec<u8> {
    let mut encoded = Vec::new();
    encoded.push(HANDSHAKE_VERSION);
    append_u16_le(&mut encoded, message_b.selected_suite.wire_id);
    append_u16_le(&mut encoded, message_b.responder_share.len() as u16);
    encoded.extend_from_slice(&message_b.responder_share);
    encoded.extend_from_slice(&message_b.server_nonce);
    append_u16_le(
        &mut encoded,
        message_b.encrypted_payload_combined.len() as u16,
    );
    encoded.extend_from_slice(&message_b.encrypted_payload_combined);
    append_u16_le(&mut encoded, message_b.identity_public_key.len() as u16);
    encoded.extend_from_slice(&message_b.identity_public_key);
    encoded
}

pub(super) fn encode_hpke_sealed_box(
    suite: CryptoSuite,
    encapsulated_key: &[u8],
    nonce: &[u8],
    ciphertext: &[u8],
    tag: &[u8],
) -> Vec<u8> {
    encode_shared_hpke_sealed_box(suite.wire_id, encapsulated_key, nonce, ciphertext, tag)
}
