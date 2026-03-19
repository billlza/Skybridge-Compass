use std::collections::BTreeMap;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use anyhow::{Result, anyhow, bail};
use getrandom::fill as fill_random;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use time::OffsetDateTime;

use crate::{
    ClassicHandleResult, ClassicSessionKeys, CryptoSuite, ProtocolIdentityBinding,
    ProtocolSigningAlgorithm, RustPqcIdentityMaterial, mldsa65_sign_detached,
    mldsa65_verify_detached, mlkem768_decapsulate, mlkem768_encapsulate, xwing_decapsulate,
    xwing_encapsulate,
};

const HANDSHAKE_VERSION: u8 = 1;
const HANDSHAKE_A_DOMAIN: &[u8] = b"SkyBridge-A";
const HANDSHAKE_B_DOMAIN: &[u8] = b"SkyBridge-B";
const FINISHED_MAGIC: &[u8; 4] = b"FIN1";
const KDF_COMPOSITION_LABEL: &[u8] = b"v1-single";
const HANDSHAKE_PAYLOAD_INFO: &[u8] = b"handshake-payload";
const IDENTITY_ALGORITHM_MLDSA65: u8 = 0x02;
const HEARTBEAT_PLATFORM: &str = std::env::consts::OS;
const HEARTBEAT_REMOTE_VIDEO_FORMAT: &str = "bgra";
const REFERENCE_UNIX_SECONDS: i64 = 978_307_200;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone)]
pub struct PqcInitiatorConfig {
    pub local_binding: ProtocolIdentityBinding,
    pub signing_secret_key: Vec<u8>,
    pub local_device_name: Option<String>,
    pub preferred_suites: Vec<CryptoSuite>,
    pub peer_kem_public_keys: BTreeMap<CryptoSuite, Vec<u8>>,
}

#[derive(Debug, Clone)]
pub struct PqcResponderConfig {
    pub local_binding: ProtocolIdentityBinding,
    pub local_device_name: Option<String>,
    pub identity: RustPqcIdentityMaterial,
    pub supported_suites: Vec<CryptoSuite>,
}

#[derive(Debug, Clone)]
pub struct PqcInitiatorHandshake {
    config: PqcInitiatorConfig,
    state: PqcInitiatorState,
}

#[derive(Debug, Clone)]
pub struct PqcResponderHandshake {
    config: PqcResponderConfig,
    state: PqcResponderState,
}

#[derive(Debug, Clone)]
enum PqcInitiatorState {
    Idle,
    WaitingForMessageB(WaitingForMessageBState),
    WaitingForFinished(WaitingForFinishedState),
    Established(ClassicSessionKeys),
}

#[derive(Debug, Clone)]
enum PqcResponderState {
    Idle,
    WaitingForFinished(WaitingForFinishedState),
    Established(ClassicSessionKeys),
}

#[derive(Debug, Clone)]
struct WaitingForMessageBState {
    offered_suites: Vec<CryptoSuite>,
    shared_secret_by_suite: BTreeMap<CryptoSuite, Vec<u8>>,
    client_nonce: [u8; 32],
    transcript_hash_a: [u8; 32],
    pending_finished: Option<FinishedFrame>,
}

#[derive(Debug, Clone)]
struct WaitingForFinishedState {
    session_keys: ClassicSessionKeys,
}

#[derive(Debug, Clone)]
struct FinishedFrame {
    direction: FinishedDirection,
    mac: [u8; 32],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FinishedDirection {
    ResponderToInitiator,
    InitiatorToResponder,
}

#[derive(Debug, Clone, Serialize)]
pub struct HeartbeatPayload {
    #[serde(rename = "sentAt")]
    pub sent_at: f64,
    #[serde(rename = "deviceId", skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(rename = "deviceName", skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    #[serde(rename = "platform")]
    pub platform: String,
    #[serde(rename = "remoteVideoFormats")]
    pub remote_video_formats: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
struct HeartbeatEnvelope {
    heartbeat: HeartbeatPayload,
}

#[derive(Debug, Clone, Serialize)]
struct PongEnvelope {
    pong: PongPayload,
}

#[derive(Debug, Clone, Serialize)]
struct PingEnvelope {
    ping: PingPayload,
}

#[derive(Debug, Clone, Serialize)]
struct PingPayload {
    id: u64,
}

#[derive(Debug, Clone, Serialize)]
struct PongPayload {
    id: u64,
}

#[derive(Debug, Clone)]
struct DecodedMessageB {
    selected_suite: CryptoSuite,
    responder_share: Vec<u8>,
    server_nonce: [u8; 32],
    encrypted_payload_combined: Vec<u8>,
    encrypted_payload_encapsulated_key: Vec<u8>,
    encrypted_payload_nonce: Vec<u8>,
    encrypted_payload_ciphertext: Vec<u8>,
    encrypted_payload_tag: Vec<u8>,
    identity_public_key: Vec<u8>,
    signature: Vec<u8>,
}

#[derive(Debug, Clone)]
struct DecodedIdentityPublicKey {
    algorithm: ProtocolSigningAlgorithm,
    public_key: Vec<u8>,
}

#[derive(Debug, Clone)]
struct DecodedHpkeSealedBox {
    encapsulated_key: Vec<u8>,
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
    tag: Vec<u8>,
}

#[derive(Debug, Clone)]
struct DecodedMessageA {
    offered_suites: Vec<CryptoSuite>,
    key_shares: BTreeMap<CryptoSuite, Vec<u8>>,
    client_nonce: [u8; 32],
    transcript_hash_a: [u8; 32],
}

impl PqcInitiatorHandshake {
    pub fn new(config: PqcInitiatorConfig) -> Result<Self> {
        if config.local_binding.protocol_signing_algorithm != ProtocolSigningAlgorithm::MlDsa65 {
            bail!("pqc initiator handshake requires an ML-DSA-65 protocol identity");
        }
        if config.signing_secret_key.is_empty() {
            bail!("missing ML-DSA-65 signing secret key");
        }
        if config.preferred_suites.is_empty() {
            bail!("missing preferred PQC suites");
        }
        Ok(Self {
            config,
            state: PqcInitiatorState::Idle,
        })
    }

    pub fn start(&mut self) -> Result<Vec<u8>> {
        if !matches!(self.state, PqcInitiatorState::Idle) {
            return Ok(Vec::new());
        }

        let offered_suites = self
            .config
            .preferred_suites
            .iter()
            .copied()
            .filter(|suite| suite.is_pqc())
            .filter(|suite| self.config.peer_kem_public_keys.contains_key(suite))
            .collect::<Vec<_>>();
        if offered_suites.is_empty() {
            bail!("no peer PQC KEM public keys available for preferred suites");
        }

        let mut shared_secret_by_suite = BTreeMap::new();
        let mut key_shares = Vec::new();
        for suite in &offered_suites {
            let peer_public_key = self
                .config
                .peer_kem_public_keys
                .get(suite)
                .ok_or_else(|| anyhow!("missing peer KEM public key for suite {}", suite))?;
            let (key_share, shared_secret) = match suite.wire_id {
                0x0101 => mlkem768_encapsulate(peer_public_key)?,
                0x0001 => xwing_encapsulate(peer_public_key)?,
                _ => bail!("unsupported PQC initiator suite {}", suite),
            };
            key_shares.push((*suite, key_share));
            shared_secret_by_suite.insert(*suite, shared_secret);
        }

        let mut client_nonce = [0u8; 32];
        fill_random(&mut client_nonce)?;

        let capabilities = pqc_capabilities_bytes(&offered_suites);
        let policy = pqc_policy_bytes();
        let identity_public_key = encode_identity_public_key(
            self.config.local_binding.protocol_signing_algorithm,
            &self.config.local_binding.protocol_public_key_bytes,
        )?;

        let mut unsigned = Vec::new();
        unsigned.push(HANDSHAKE_VERSION);
        append_u16_le(&mut unsigned, offered_suites.len() as u16);
        for suite in &offered_suites {
            append_u16_le(&mut unsigned, suite.wire_id);
        }
        append_u16_le(&mut unsigned, key_shares.len() as u16);
        for (suite, share) in &key_shares {
            append_u16_le(&mut unsigned, suite.wire_id);
            append_u16_le(&mut unsigned, share.len() as u16);
            unsigned.extend_from_slice(share);
        }
        unsigned.extend_from_slice(&client_nonce);
        append_u16_le(&mut unsigned, capabilities.len() as u16);
        unsigned.extend_from_slice(&capabilities);
        append_u16_le(&mut unsigned, policy.len() as u16);
        unsigned.extend_from_slice(&policy);
        append_u16_le(&mut unsigned, identity_public_key.len() as u16);
        unsigned.extend_from_slice(&identity_public_key);

        let mut preimage = Vec::from(HANDSHAKE_A_DOMAIN);
        preimage.extend_from_slice(&unsigned);
        let signature = mldsa65_sign_detached(&preimage, &self.config.signing_secret_key)?;
        let transcript_hash_a = Sha256::digest(&unsigned);

        let mut message = unsigned;
        append_u16_le(&mut message, signature.len() as u16);
        message.extend_from_slice(&signature);
        append_u16_le(&mut message, 0);

        self.state = PqcInitiatorState::WaitingForMessageB(WaitingForMessageBState {
            offered_suites,
            shared_secret_by_suite,
            client_nonce,
            transcript_hash_a: transcript_hash_a.into(),
            pending_finished: None,
        });
        Ok(message)
    }

    pub fn handle_frame(&mut self, frame: &[u8]) -> Result<ClassicHandleResult> {
        let unwrapped = unwrap_handshake_padding(frame);
        if let Ok(finished) = decode_finished_frame(&unwrapped) {
            return self.handle_finished(finished);
        }

        match &mut self.state {
            PqcInitiatorState::WaitingForMessageB(waiting) => {
                let message_b = decode_message_b(&unwrapped)?;
                let keys = process_message_b(&self.config, waiting, message_b)?;
                let mut result = ClassicHandleResult::default();
                let pending_finished = waiting.pending_finished.clone();
                self.state = PqcInitiatorState::WaitingForFinished(WaitingForFinishedState {
                    session_keys: keys.clone(),
                });
                if let Some(pending_finished) = pending_finished {
                    return self.handle_finished(pending_finished);
                }
                result.heartbeat_requested = true;
                Ok(result)
            }
            PqcInitiatorState::WaitingForFinished(waiting) => {
                if let Some(message) =
                    try_handle_encrypted_app_message(&unwrapped, &waiting.session_keys)?
                {
                    return Ok(message);
                }
                bail!("unexpected frame while waiting for PQC Finished")
            }
            PqcInitiatorState::Established(keys) => {
                if let Some(message) = try_handle_encrypted_app_message(&unwrapped, keys)? {
                    return Ok(message);
                }
                Ok(ClassicHandleResult::default())
            }
            PqcInitiatorState::Idle => bail!("received frame before PQC handshake started"),
        }
    }

    pub fn is_waiting_for_message_b(&self) -> bool {
        matches!(self.state, PqcInitiatorState::WaitingForMessageB(_))
    }

    pub fn build_heartbeat_frame(&self) -> Result<Vec<u8>> {
        let session_keys = self
            .established_session_keys()
            .ok_or_else(|| anyhow!("PQC handshake is not established"))?;
        let payload = HeartbeatEnvelope {
            heartbeat: HeartbeatPayload {
                sent_at: apple_reference_seconds_now(),
                device_id: Some(self.config.local_binding.device_id.clone()),
                device_name: self.config.local_device_name.clone(),
                platform: HEARTBEAT_PLATFORM.to_owned(),
                remote_video_formats: vec![HEARTBEAT_REMOTE_VIDEO_FORMAT.to_owned()],
            },
        };
        build_encrypted_app_frame(session_keys, &payload)
    }

    pub fn build_pong_frame(&self, id: u64) -> Result<Vec<u8>> {
        let session_keys = self
            .established_session_keys()
            .ok_or_else(|| anyhow!("PQC handshake is not established"))?;
        build_encrypted_app_frame(
            session_keys,
            &PongEnvelope {
                pong: PongPayload { id },
            },
        )
    }

    pub fn build_ping_frame(&self, id: u64) -> Result<Vec<u8>> {
        let session_keys = self
            .established_session_keys()
            .ok_or_else(|| anyhow!("PQC handshake is not established"))?;
        build_encrypted_app_frame(
            session_keys,
            &PingEnvelope {
                ping: PingPayload { id },
            },
        )
    }

    pub fn established_session_keys(&self) -> Option<&ClassicSessionKeys> {
        match &self.state {
            PqcInitiatorState::WaitingForFinished(waiting) => Some(&waiting.session_keys),
            PqcInitiatorState::Established(keys) => Some(keys),
            PqcInitiatorState::Idle | PqcInitiatorState::WaitingForMessageB(_) => None,
        }
    }

    fn handle_finished(&mut self, finished: FinishedFrame) -> Result<ClassicHandleResult> {
        match &mut self.state {
            PqcInitiatorState::WaitingForMessageB(waiting) => {
                waiting.pending_finished = Some(finished);
                Ok(ClassicHandleResult::default())
            }
            PqcInitiatorState::WaitingForFinished(waiting) => {
                verify_finished(
                    &waiting.session_keys,
                    FinishedDirection::ResponderToInitiator,
                    &finished,
                )?;
                let initiator_finished = encode_finished_frame(
                    FinishedDirection::InitiatorToResponder,
                    &waiting.session_keys.send_key,
                    &waiting.session_keys.transcript_hash,
                )?;
                let established = waiting.session_keys.clone();
                self.state = PqcInitiatorState::Established(established.clone());
                Ok(ClassicHandleResult {
                    outbound_frames: vec![initiator_finished],
                    established: Some(established),
                    heartbeat_requested: true,
                    pong_id: None,
                    observed_pong_id: None,
                    observed_heartbeat: false,
                })
            }
            PqcInitiatorState::Established(_) => Ok(ClassicHandleResult::default()),
            PqcInitiatorState::Idle => bail!("received Finished before PQC handshake started"),
        }
    }
}

impl PqcResponderHandshake {
    pub fn new(config: PqcResponderConfig) -> Result<Self> {
        if config.local_binding.protocol_signing_algorithm != ProtocolSigningAlgorithm::MlDsa65 {
            bail!("pqc responder handshake requires an ML-DSA-65 protocol identity");
        }
        if config.identity.signing_algorithm != ProtocolSigningAlgorithm::MlDsa65 {
            bail!("pqc responder identity bundle must use ML-DSA-65");
        }
        if config.identity.signing_secret_key.is_empty() {
            bail!("missing ML-DSA-65 responder signing secret key");
        }
        if config.identity.signing_public_key != config.local_binding.protocol_public_key_bytes {
            bail!("pqc responder identity bundle does not match the local protocol binding");
        }
        if config.supported_suites.is_empty() {
            bail!("missing supported PQC responder suites");
        }
        Ok(Self {
            config,
            state: PqcResponderState::Idle,
        })
    }

    pub fn handle_frame(&mut self, frame: &[u8]) -> Result<ClassicHandleResult> {
        let unwrapped = unwrap_handshake_padding(frame);
        if let Ok(finished) = decode_finished_frame(&unwrapped) {
            return self.handle_finished(finished);
        }

        match &mut self.state {
            PqcResponderState::Idle => {
                let message_a = decode_message_a(&unwrapped)?;
                let (message_b, session_keys) =
                    build_responder_message_b_and_keys(&self.config, &message_a)?;
                let responder_finished = encode_finished_frame(
                    FinishedDirection::ResponderToInitiator,
                    &session_keys.send_key,
                    &session_keys.transcript_hash,
                )?;
                self.state =
                    PqcResponderState::WaitingForFinished(WaitingForFinishedState { session_keys });
                Ok(ClassicHandleResult {
                    outbound_frames: vec![message_b, responder_finished],
                    ..Default::default()
                })
            }
            PqcResponderState::WaitingForFinished(waiting) => {
                if let Some(message) =
                    try_handle_encrypted_app_message(&unwrapped, &waiting.session_keys)?
                {
                    return Ok(message);
                }
                bail!("unexpected frame while waiting for initiator Finished")
            }
            PqcResponderState::Established(keys) => {
                if let Some(message) = try_handle_encrypted_app_message(&unwrapped, keys)? {
                    return Ok(message);
                }
                Ok(ClassicHandleResult::default())
            }
        }
    }

    pub fn build_heartbeat_frame(&self) -> Result<Vec<u8>> {
        let session_keys = self
            .established_session_keys()
            .ok_or_else(|| anyhow!("PQC responder handshake is not established"))?;
        let payload = HeartbeatEnvelope {
            heartbeat: HeartbeatPayload {
                sent_at: apple_reference_seconds_now(),
                device_id: Some(self.config.local_binding.device_id.clone()),
                device_name: self.config.local_device_name.clone(),
                platform: HEARTBEAT_PLATFORM.to_owned(),
                remote_video_formats: vec![HEARTBEAT_REMOTE_VIDEO_FORMAT.to_owned()],
            },
        };
        build_encrypted_app_frame(session_keys, &payload)
    }

    pub fn build_pong_frame(&self, id: u64) -> Result<Vec<u8>> {
        let session_keys = self
            .established_session_keys()
            .ok_or_else(|| anyhow!("PQC responder handshake is not established"))?;
        build_encrypted_app_frame(
            session_keys,
            &PongEnvelope {
                pong: PongPayload { id },
            },
        )
    }

    pub fn build_ping_frame(&self, id: u64) -> Result<Vec<u8>> {
        let session_keys = self
            .established_session_keys()
            .ok_or_else(|| anyhow!("PQC responder handshake is not established"))?;
        build_encrypted_app_frame(
            session_keys,
            &PingEnvelope {
                ping: PingPayload { id },
            },
        )
    }

    pub fn established_session_keys(&self) -> Option<&ClassicSessionKeys> {
        match &self.state {
            PqcResponderState::WaitingForFinished(waiting) => Some(&waiting.session_keys),
            PqcResponderState::Established(keys) => Some(keys),
            PqcResponderState::Idle => None,
        }
    }

    fn handle_finished(&mut self, finished: FinishedFrame) -> Result<ClassicHandleResult> {
        match &mut self.state {
            PqcResponderState::Idle => {
                bail!("received initiator Finished before PQC responder processed MessageA")
            }
            PqcResponderState::WaitingForFinished(waiting) => {
                verify_finished(
                    &waiting.session_keys,
                    FinishedDirection::InitiatorToResponder,
                    &finished,
                )?;
                let established = waiting.session_keys.clone();
                self.state = PqcResponderState::Established(established.clone());
                Ok(ClassicHandleResult {
                    established: Some(established),
                    heartbeat_requested: true,
                    ..Default::default()
                })
            }
            PqcResponderState::Established(_) => Ok(ClassicHandleResult::default()),
        }
    }
}

fn process_message_b(
    _config: &PqcInitiatorConfig,
    waiting: &WaitingForMessageBState,
    message_b: DecodedMessageB,
) -> Result<ClassicSessionKeys> {
    let suite = message_b.selected_suite;
    if !waiting.offered_suites.contains(&suite) {
        bail!("responder selected unsupported suite {}", suite);
    }
    if !suite.is_pqc() {
        bail!("responder selected non-PQC suite for PQC initiator");
    }
    if !message_b.responder_share.is_empty() {
        bail!("unexpected responder share for PQC MessageB");
    }
    if !message_b.encrypted_payload_encapsulated_key.is_empty() {
        bail!("unexpected encapsulated key in PQC MessageB payload");
    }

    let identity = decode_identity_public_key(&message_b.identity_public_key)?;
    if identity.algorithm != ProtocolSigningAlgorithm::MlDsa65 {
        bail!("unsupported responder identity algorithm for PQC MessageB");
    }

    let payload_hash = Sha256::digest(&message_b.encrypted_payload_combined);
    let mut signature_preimage = Vec::from(HANDSHAKE_B_DOMAIN);
    signature_preimage.extend_from_slice(&waiting.transcript_hash_a);
    append_u16_le(&mut signature_preimage, suite.wire_id);
    append_u16_le(
        &mut signature_preimage,
        message_b.responder_share.len() as u16,
    );
    signature_preimage.extend_from_slice(&message_b.responder_share);
    signature_preimage.extend_from_slice(&message_b.server_nonce);
    signature_preimage.extend_from_slice(&payload_hash);
    append_u16_le(
        &mut signature_preimage,
        message_b.identity_public_key.len() as u16,
    );
    signature_preimage.extend_from_slice(&message_b.identity_public_key);
    mldsa65_verify_detached(
        &signature_preimage,
        &message_b.signature,
        &identity.public_key,
    )?;

    let shared_secret = waiting
        .shared_secret_by_suite
        .get(&suite)
        .ok_or_else(|| anyhow!("missing shared secret for selected suite {}", suite))?;
    let _payload = open_payload_with_shared_secret(
        &message_b.encrypted_payload_nonce,
        &message_b.encrypted_payload_ciphertext,
        &message_b.encrypted_payload_tag,
        shared_secret,
        &waiting.transcript_hash_a,
    )?;

    let transcript_hash_b = Sha256::digest(message_b_encoded_without_signature(&message_b));
    derive_session_keys(
        suite,
        KDF_COMPOSITION_LABEL,
        shared_secret,
        &waiting.client_nonce,
        &message_b.server_nonce,
        &waiting.transcript_hash_a,
        transcript_hash_b.as_ref(),
    )
}

fn decode_message_a(frame: &[u8]) -> Result<DecodedMessageA> {
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
    let _policy = read_exact(frame, &mut offset, policy_len)?;
    let identity_public_key_len = read_u16_le(frame, &mut offset)? as usize;
    let identity_public_key = read_exact(frame, &mut offset, identity_public_key_len)?.to_vec();
    let unsigned_end = offset;
    let signature_len = read_u16_le(frame, &mut offset)? as usize;
    let signature = read_exact(frame, &mut offset, signature_len)?.to_vec();

    if offset < frame.len() {
        let se_signature_len = read_u16_le(frame, &mut offset)? as usize;
        let _ = read_exact(frame, &mut offset, se_signature_len)?;
    }
    if offset != frame.len() {
        bail!("unexpected trailing bytes in PQC MessageA");
    }

    let unsigned = &frame[..unsigned_end];
    let transcript_hash_a = Sha256::digest(unsigned);
    let mut transcript_hash_a_bytes = [0u8; 32];
    transcript_hash_a_bytes.copy_from_slice(transcript_hash_a.as_ref());

    let initiator_identity = decode_identity_public_key(&identity_public_key)?;
    if initiator_identity.algorithm != ProtocolSigningAlgorithm::MlDsa65 {
        bail!("unsupported PQC initiator identity algorithm");
    }
    let mut preimage = Vec::from(HANDSHAKE_A_DOMAIN);
    preimage.extend_from_slice(unsigned);
    mldsa65_verify_detached(&preimage, &signature, &initiator_identity.public_key)?;

    Ok(DecodedMessageA {
        offered_suites,
        key_shares,
        client_nonce,
        transcript_hash_a: transcript_hash_a_bytes,
    })
}

fn build_responder_message_b_and_keys(
    config: &PqcResponderConfig,
    message_a: &DecodedMessageA,
) -> Result<(Vec<u8>, ClassicSessionKeys)> {
    let selected_suite = config
        .supported_suites
        .iter()
        .copied()
        .find(|suite| {
            suite.is_pqc()
                && message_a.offered_suites.contains(suite)
                && message_a.key_shares.contains_key(suite)
        })
        .ok_or_else(|| anyhow!("no mutually supported PQC suite found in MessageA"))?;
    let selected_key_share = message_a
        .key_shares
        .get(&selected_suite)
        .ok_or_else(|| anyhow!("missing initiator key share for suite {}", selected_suite))?;

    let shared_secret = match selected_suite.wire_id {
        0x0101 => mlkem768_decapsulate(selected_key_share, &config.identity.mlkem768_secret_key)?,
        0x0001 => xwing_decapsulate(selected_key_share, &config.identity.xwing_secret_key)?,
        _ => bail!("unsupported PQC responder suite {}", selected_suite),
    };

    let mut server_nonce = [0u8; 32];
    fill_random(&mut server_nonce)?;
    let payload_plaintext = pqc_capabilities_bytes(&[selected_suite]);
    let (payload_nonce, payload_ciphertext, payload_tag) = seal_payload_with_shared_secret(
        &payload_plaintext,
        &shared_secret,
        &message_a.transcript_hash_a,
    )?;

    let encrypted_payload = encode_hpke_sealed_box(
        selected_suite,
        &[],
        &payload_nonce,
        &payload_ciphertext,
        &payload_tag,
    );
    let responder_identity_public_key = encode_identity_public_key(
        ProtocolSigningAlgorithm::MlDsa65,
        &config.identity.signing_public_key,
    )?;
    let mut message_b_unsigned = Vec::new();
    message_b_unsigned.push(HANDSHAKE_VERSION);
    append_u16_le(&mut message_b_unsigned, selected_suite.wire_id);
    append_u16_le(&mut message_b_unsigned, 0);
    message_b_unsigned.extend_from_slice(&server_nonce);
    append_u16_le(&mut message_b_unsigned, encrypted_payload.len() as u16);
    message_b_unsigned.extend_from_slice(&encrypted_payload);
    append_u16_le(
        &mut message_b_unsigned,
        responder_identity_public_key.len() as u16,
    );
    message_b_unsigned.extend_from_slice(&responder_identity_public_key);

    let payload_hash = Sha256::digest(&encrypted_payload);
    let mut message_b_preimage = Vec::from(HANDSHAKE_B_DOMAIN);
    message_b_preimage.extend_from_slice(&message_a.transcript_hash_a);
    append_u16_le(&mut message_b_preimage, selected_suite.wire_id);
    append_u16_le(&mut message_b_preimage, 0);
    message_b_preimage.extend_from_slice(&server_nonce);
    message_b_preimage.extend_from_slice(&payload_hash);
    append_u16_le(
        &mut message_b_preimage,
        responder_identity_public_key.len() as u16,
    );
    message_b_preimage.extend_from_slice(&responder_identity_public_key);
    let signature =
        mldsa65_sign_detached(&message_b_preimage, &config.identity.signing_secret_key)?;

    let mut message_b = message_b_unsigned.clone();
    append_u16_le(&mut message_b, signature.len() as u16);
    message_b.extend_from_slice(&signature);
    append_u16_le(&mut message_b, 0);

    let transcript_hash_b = Sha256::digest(&message_b_unsigned);
    let responder_session_keys = derive_responder_session_keys(
        selected_suite,
        &shared_secret,
        &message_a.client_nonce,
        &server_nonce,
        &message_a.transcript_hash_a,
        transcript_hash_b.as_ref(),
    )?;
    Ok((message_b, responder_session_keys))
}

fn decode_message_b(frame: &[u8]) -> Result<DecodedMessageB> {
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

fn pqc_capabilities_bytes(offered_suites: &[CryptoSuite]) -> Vec<u8> {
    let mut kem_algorithms = Vec::new();
    if offered_suites.iter().any(|suite| suite.wire_id == 0x0001) {
        kem_algorithms.push("X-Wing");
    }
    if offered_suites
        .iter()
        .any(|suite| suite.canonical_kem_suite().wire_id == 0x0101)
    {
        kem_algorithms.push("ML-KEM-768");
    }

    let mut encoded = Vec::new();
    encode_string_array(&mut encoded, &kem_algorithms);
    encode_string_array(&mut encoded, &["ML-DSA-65"]);
    encode_string_array(&mut encoded, &["PQC"]);
    encode_string_array(&mut encoded, &["AES-256-GCM", "ChaCha20-Poly1305"]);
    encoded.push(0x01);
    encode_string(&mut encoded, HEARTBEAT_PLATFORM);
    encode_string(&mut encoded, "liboqs");
    encoded
}

fn pqc_policy_bytes() -> Vec<u8> {
    let mut encoded = Vec::new();
    encoded.push(0x01);
    encoded.push(0x00);
    encode_string(&mut encoded, "liboqsPQC");
    encoded.push(0x00);
    encoded
}

fn encode_identity_public_key(
    algorithm: ProtocolSigningAlgorithm,
    public_key: &[u8],
) -> Result<Vec<u8>> {
    if algorithm != ProtocolSigningAlgorithm::MlDsa65 {
        bail!("PQC handshake only supports ML-DSA-65 protocol identities");
    }
    let mut encoded = Vec::new();
    encoded.push(IDENTITY_ALGORITHM_MLDSA65);
    append_u16_le(&mut encoded, public_key.len() as u16);
    encoded.extend_from_slice(public_key);
    encoded.push(0x00);
    Ok(encoded)
}

fn decode_identity_public_key(data: &[u8]) -> Result<DecodedIdentityPublicKey> {
    if data.len() < 1 + 2 + 1 {
        bail!("identity public key payload too short");
    }
    let algorithm = match data[0] {
        IDENTITY_ALGORITHM_MLDSA65 => ProtocolSigningAlgorithm::MlDsa65,
        _ => bail!("unsupported identity public key algorithm"),
    };
    let mut offset = 1usize;
    let key_len = read_u16_le(data, &mut offset)? as usize;
    let public_key = read_exact(data, &mut offset, key_len)?.to_vec();
    let has_secure_enclave = *data
        .get(offset)
        .ok_or_else(|| anyhow!("missing secure enclave identity flag"))?;
    if has_secure_enclave != 0x00 {
        bail!("secure enclave identity keys are not supported in PQC rust initiator");
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

fn open_payload_with_shared_secret(
    nonce: &[u8],
    ciphertext: &[u8],
    tag: &[u8],
    shared_secret: &[u8],
    transcript_hash_a: &[u8; 32],
) -> Result<Vec<u8>> {
    let mut payload_key = [0u8; 32];
    Hkdf::<Sha256>::new(Some(transcript_hash_a), shared_secret)
        .expand(HANDSHAKE_PAYLOAD_INFO, &mut payload_key)
        .map_err(|_| anyhow!("failed to derive PQC payload key"))?;
    let cipher = Aes256Gcm::new_from_slice(&payload_key)
        .map_err(|error| anyhow!("invalid AES-256 key: {error}"))?;
    let mut combined = ciphertext.to_vec();
    combined.extend_from_slice(tag);
    cipher
        .decrypt(Nonce::from_slice(nonce), combined.as_ref())
        .map_err(|error| anyhow!("failed to decrypt PQC MessageB payload: {error}"))
}

fn seal_payload_with_shared_secret(
    plaintext: &[u8],
    shared_secret: &[u8],
    transcript_hash_a: &[u8; 32],
) -> Result<(Vec<u8>, Vec<u8>, Vec<u8>)> {
    let mut payload_key = [0u8; 32];
    Hkdf::<Sha256>::new(Some(transcript_hash_a), shared_secret)
        .expand(HANDSHAKE_PAYLOAD_INFO, &mut payload_key)
        .map_err(|_| anyhow!("failed to derive PQC payload key"))?;
    let cipher = Aes256Gcm::new_from_slice(&payload_key)
        .map_err(|error| anyhow!("invalid AES-256 key: {error}"))?;
    let mut nonce_bytes = [0u8; 12];
    fill_random(&mut nonce_bytes)?;
    let combined = cipher
        .encrypt(Nonce::from_slice(&nonce_bytes), plaintext)
        .map_err(|error| anyhow!("failed to encrypt PQC payload: {error}"))?;
    let split = combined
        .len()
        .checked_sub(16)
        .ok_or_else(|| anyhow!("invalid encrypted payload length"))?;
    Ok((
        nonce_bytes.to_vec(),
        combined[..split].to_vec(),
        combined[split..].to_vec(),
    ))
}

fn derive_session_keys(
    suite: CryptoSuite,
    composition_label: &[u8],
    shared_secret: &[u8],
    client_nonce: &[u8; 32],
    server_nonce: &[u8; 32],
    transcript_hash_a: &[u8; 32],
    transcript_hash_b: &[u8],
) -> Result<ClassicSessionKeys> {
    let mut kdf_info = Vec::from(b"SkyBridge-KDF".as_slice());
    kdf_info.push(0x01);
    append_u16_le(&mut kdf_info, suite.wire_id);
    kdf_info.extend_from_slice(composition_label);
    kdf_info.extend_from_slice(transcript_hash_a);
    kdf_info.extend_from_slice(transcript_hash_b);
    kdf_info.extend_from_slice(client_nonce);
    kdf_info.extend_from_slice(server_nonce);

    let mut salt_input = Vec::from(b"SkyBridge-KDF-Salt-v1|".as_slice());
    salt_input.extend_from_slice(&kdf_info);
    let salt = Sha256::digest(&salt_input);

    let mut i2r_info = kdf_info.clone();
    i2r_info.extend_from_slice(b"handshake|initiator_to_responder");
    let mut r2i_info = kdf_info;
    r2i_info.extend_from_slice(b"handshake|responder_to_initiator");

    let hkdf_i2r = Hkdf::<Sha256>::new(Some(&salt), shared_secret);
    let hkdf_r2i = Hkdf::<Sha256>::new(Some(&salt), shared_secret);
    let mut send_key = [0u8; 32];
    let mut receive_key = [0u8; 32];
    hkdf_i2r
        .expand(&i2r_info, &mut send_key)
        .map_err(|_| anyhow!("failed to derive initiator send key"))?;
    hkdf_r2i
        .expand(&r2i_info, &mut receive_key)
        .map_err(|_| anyhow!("failed to derive initiator receive key"))?;

    let mut transcript_input = Vec::new();
    transcript_input.extend_from_slice(transcript_hash_a);
    transcript_input.extend_from_slice(transcript_hash_b);
    let transcript_hash = Sha256::digest(&transcript_input);

    Ok(ClassicSessionKeys {
        send_key: send_key.to_vec(),
        receive_key: receive_key.to_vec(),
        negotiated_suite: suite.to_string(),
        transcript_hash: transcript_hash.to_vec(),
    })
}

fn derive_responder_session_keys(
    suite: CryptoSuite,
    shared_secret: &[u8],
    client_nonce: &[u8; 32],
    server_nonce: &[u8; 32],
    transcript_hash_a: &[u8; 32],
    transcript_hash_b: &[u8],
) -> Result<ClassicSessionKeys> {
    let mut keys = derive_session_keys(
        suite,
        KDF_COMPOSITION_LABEL,
        shared_secret,
        client_nonce,
        server_nonce,
        transcript_hash_a,
        transcript_hash_b,
    )?;
    std::mem::swap(&mut keys.send_key, &mut keys.receive_key);
    Ok(keys)
}

fn message_b_encoded_without_signature(message_b: &DecodedMessageB) -> Vec<u8> {
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

fn encode_hpke_sealed_box(
    suite: CryptoSuite,
    encapsulated_key: &[u8],
    nonce: &[u8],
    ciphertext: &[u8],
    tag: &[u8],
) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"HPKE");
    let version = if nonce.is_empty() && tag.is_empty() {
        2
    } else {
        1
    };
    out.push(version);
    out.push((suite.wire_id & 0xFF) as u8);
    out.push((suite.wire_id >> 8) as u8);
    out.extend_from_slice(&[0, 0]);
    out.push((encapsulated_key.len() & 0xFF) as u8);
    out.push((encapsulated_key.len() >> 8) as u8);
    out.push((nonce.len() & 0xFF) as u8);
    out.push((tag.len() & 0xFF) as u8);
    out.extend_from_slice(&(ciphertext.len() as u32).to_le_bytes());
    out.extend_from_slice(encapsulated_key);
    out.extend_from_slice(nonce);
    out.extend_from_slice(ciphertext);
    out.extend_from_slice(tag);
    out
}

fn build_encrypted_app_frame<T: Serialize>(
    session_keys: &ClassicSessionKeys,
    payload: &T,
) -> Result<Vec<u8>> {
    let plaintext = serde_json::to_vec(payload)?;
    let cipher = Aes256Gcm::new_from_slice(&session_keys.send_key)
        .map_err(|error| anyhow!("invalid AES-256 key: {error}"))?;
    let mut nonce_bytes = [0u8; 12];
    fill_random(&mut nonce_bytes)?;
    let ciphertext_and_tag = cipher
        .encrypt(Nonce::from_slice(&nonce_bytes), plaintext.as_ref())
        .map_err(|error| anyhow!("failed to encrypt app payload: {error}"))?;
    let mut combined = nonce_bytes.to_vec();
    combined.extend_from_slice(&ciphertext_and_tag);
    Ok(combined)
}

fn try_handle_encrypted_app_message(
    frame: &[u8],
    session_keys: &ClassicSessionKeys,
) -> Result<Option<ClassicHandleResult>> {
    if frame.len() < 12 + 16 {
        return Ok(None);
    }
    let cipher = Aes256Gcm::new_from_slice(&session_keys.receive_key)
        .map_err(|error| anyhow!("invalid AES-256 key: {error}"))?;
    let plaintext = match cipher.decrypt(Nonce::from_slice(&frame[..12]), &frame[12..]) {
        Ok(plaintext) => plaintext,
        Err(_) => return Ok(None),
    };
    let value: Value = match serde_json::from_slice(&plaintext) {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };
    let pong_id = value
        .get("ping")
        .and_then(|ping| ping.get("id"))
        .and_then(Value::as_u64);
    let observed_pong_id = value
        .get("pong")
        .and_then(|pong| pong.get("id"))
        .and_then(Value::as_u64);
    Ok(Some(ClassicHandleResult {
        outbound_frames: Vec::new(),
        established: None,
        heartbeat_requested: value.get("heartbeat").is_some(),
        pong_id,
        observed_pong_id,
        observed_heartbeat: value.get("heartbeat").is_some(),
    }))
}

fn encode_finished_frame(
    direction: FinishedDirection,
    mac_key: &[u8],
    transcript_hash: &[u8],
) -> Result<Vec<u8>> {
    let mac = compute_finished_mac(mac_key, direction, transcript_hash)?;
    let mut encoded = Vec::with_capacity(38);
    encoded.extend_from_slice(FINISHED_MAGIC);
    encoded.push(HANDSHAKE_VERSION);
    encoded.push(direction.as_byte());
    encoded.extend_from_slice(&mac);
    Ok(encoded)
}

fn decode_finished_frame(frame: &[u8]) -> Result<FinishedFrame> {
    if frame.len() != 38 {
        bail!("Finished frame length mismatch");
    }
    if &frame[..4] != FINISHED_MAGIC {
        bail!("Finished magic mismatch");
    }
    if frame[4] != HANDSHAKE_VERSION {
        bail!("Finished version mismatch");
    }
    let direction = FinishedDirection::from_byte(frame[5])?;
    let mut mac = [0u8; 32];
    mac.copy_from_slice(&frame[6..]);
    Ok(FinishedFrame { direction, mac })
}

fn verify_finished(
    session_keys: &ClassicSessionKeys,
    expected_direction: FinishedDirection,
    frame: &FinishedFrame,
) -> Result<()> {
    if frame.direction != expected_direction {
        bail!("Finished direction mismatch");
    }
    let expected_mac = compute_finished_mac(
        &session_keys.receive_key,
        expected_direction,
        &session_keys.transcript_hash,
    )?;
    if frame.mac != expected_mac {
        bail!("Finished MAC verification failed");
    }
    Ok(())
}

fn compute_finished_mac(
    base_key: &[u8],
    direction: FinishedDirection,
    transcript_hash: &[u8],
) -> Result<[u8; 32]> {
    let info = match direction {
        FinishedDirection::ResponderToInitiator => b"SkyBridge-FINISHED|R2I|".as_slice(),
        FinishedDirection::InitiatorToResponder => b"SkyBridge-FINISHED|I2R|".as_slice(),
    };
    let hkdf = Hkdf::<Sha256>::new(None, base_key);
    let mut mac_key = [0u8; 32];
    hkdf.expand(info, &mut mac_key)
        .map_err(|_| anyhow!("failed to derive Finished MAC key"))?;
    let mut mac = <HmacSha256 as Mac>::new_from_slice(&mac_key)
        .map_err(|error| anyhow!("invalid Finished MAC key: {error}"))?;
    mac.update(transcript_hash);
    let output = mac.finalize().into_bytes();
    let mut encoded = [0u8; 32];
    encoded.copy_from_slice(&output);
    Ok(encoded)
}

fn unwrap_handshake_padding(data: &[u8]) -> Vec<u8> {
    const HANDSHAKE_PADDING_MAGIC: &[u8; 4] = b"SBP1";
    if data.len() < 8 || &data[..4] != HANDSHAKE_PADDING_MAGIC {
        return data.to_vec();
    }
    let actual_len = u32::from_be_bytes([data[4], data[5], data[6], data[7]]) as usize;
    if actual_len > data.len().saturating_sub(8) {
        return data.to_vec();
    }
    data[8..(8 + actual_len)].to_vec()
}

fn encode_string(out: &mut Vec<u8>, value: &str) {
    let bytes = value.as_bytes();
    out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    out.extend_from_slice(bytes);
}

fn encode_string_array(out: &mut Vec<u8>, values: &[&str]) {
    out.extend_from_slice(&(values.len() as u32).to_le_bytes());
    for value in values {
        encode_string(out, value);
    }
}

fn append_u16_le(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn read_u16_le(data: &[u8], offset: &mut usize) -> Result<u16> {
    let bytes = read_exact(data, offset, 2)?;
    Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
}

fn read_exact<'a>(data: &'a [u8], offset: &mut usize, len: usize) -> Result<&'a [u8]> {
    let end = offset
        .checked_add(len)
        .ok_or_else(|| anyhow!("length overflow"))?;
    let slice = data
        .get(*offset..end)
        .ok_or_else(|| anyhow!("truncated frame"))?;
    *offset = end;
    Ok(slice)
}

fn apple_reference_seconds_now() -> f64 {
    let now = OffsetDateTime::now_utc().unix_timestamp_nanos() as f64 / 1_000_000_000.0;
    now - REFERENCE_UNIX_SECONDS as f64
}

impl FinishedDirection {
    fn from_byte(byte: u8) -> Result<Self> {
        match byte {
            0x01 => Ok(Self::ResponderToInitiator),
            0x02 => Ok(Self::InitiatorToResponder),
            _ => bail!("unknown Finished direction"),
        }
    }

    fn as_byte(self) -> u8 {
        match self {
            Self::ResponderToInitiator => 0x01,
            Self::InitiatorToResponder => 0x02,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::RustPqcIdentityMaterial;

    #[test]
    fn mlkem768_initiator_handshake_round_trips() -> Result<()> {
        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;
        let local_binding = ProtocolIdentityBinding::new(
            "device-1234567890abcd",
            initiator_identity.signing_algorithm,
            initiator_identity.signing_public_key.clone(),
            None,
        )?;
        let mut handshake = PqcInitiatorHandshake::new(PqcInitiatorConfig {
            local_binding,
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: Some("Rust PQC Agent".to_owned()),
            preferred_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::MLKEM768_MLDSA65,
                responder_identity.mlkem768_public_key.clone(),
            )]),
        })?;

        let message_a = handshake.start()?;
        let responder_binding = ProtocolIdentityBinding::new(
            "device-fedcba0987654321",
            responder_identity.signing_algorithm,
            responder_identity.signing_public_key.clone(),
            None,
        )?;
        let responder_message_a = decode_message_a(&message_a)?;
        let (message_b, responder_keys) = build_responder_message_b_and_keys(
            &PqcResponderConfig {
                local_binding: responder_binding,
                local_device_name: Some("Rust PQC Responder".to_owned()),
                identity: responder_identity,
                supported_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            },
            &responder_message_a,
        )?;
        let responder_finished = encode_finished_frame(
            FinishedDirection::ResponderToInitiator,
            &responder_keys.send_key,
            &responder_keys.transcript_hash,
        )?;
        let result = handshake.handle_frame(&message_b)?;
        assert!(result.established.is_none());
        let result = handshake.handle_frame(&responder_finished)?;
        let established = result
            .established
            .ok_or_else(|| anyhow!("expected established PQC session keys"))?;
        assert_eq!(established.negotiated_suite, "ML-KEM-768");
        Ok(())
    }

    #[test]
    fn xwing_initiator_handshake_round_trips() -> Result<()> {
        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;
        let local_binding = ProtocolIdentityBinding::new(
            "device-abcdef1234567890",
            initiator_identity.signing_algorithm,
            initiator_identity.signing_public_key.clone(),
            None,
        )?;
        let mut handshake = PqcInitiatorHandshake::new(PqcInitiatorConfig {
            local_binding,
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: Some("Rust Hybrid Agent".to_owned()),
            preferred_suites: vec![CryptoSuite::XWING_MLDSA],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::XWING_MLDSA,
                responder_identity.xwing_public_key.clone(),
            )]),
        })?;

        let message_a = handshake.start()?;
        let responder_binding = ProtocolIdentityBinding::new(
            "device-0123456789fedcba",
            responder_identity.signing_algorithm,
            responder_identity.signing_public_key.clone(),
            None,
        )?;
        let responder_message_a = decode_message_a(&message_a)?;
        let (message_b, responder_keys) = build_responder_message_b_and_keys(
            &PqcResponderConfig {
                local_binding: responder_binding,
                local_device_name: Some("Rust Hybrid Responder".to_owned()),
                identity: responder_identity,
                supported_suites: vec![CryptoSuite::XWING_MLDSA],
            },
            &responder_message_a,
        )?;
        let responder_finished = encode_finished_frame(
            FinishedDirection::ResponderToInitiator,
            &responder_keys.send_key,
            &responder_keys.transcript_hash,
        )?;
        let _ = handshake.handle_frame(&message_b)?;
        let result = handshake.handle_frame(&responder_finished)?;
        let established = result
            .established
            .ok_or_else(|| anyhow!("expected established X-Wing session keys"))?;
        assert_eq!(established.negotiated_suite, "X-Wing");
        Ok(())
    }

    #[test]
    fn pqc_responder_handshake_round_trips_mlkem768() -> Result<()> {
        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;
        let mut initiator = PqcInitiatorHandshake::new(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-1234567890abcd",
                initiator_identity.signing_algorithm,
                initiator_identity.signing_public_key.clone(),
                None,
            )?,
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: Some("Rust PQC Initiator".to_owned()),
            preferred_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::MLKEM768_MLDSA65,
                responder_identity.mlkem768_public_key.clone(),
            )]),
        })?;
        let mut responder = PqcResponderHandshake::new(PqcResponderConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-fedcba0987654321",
                responder_identity.signing_algorithm,
                responder_identity.signing_public_key.clone(),
                None,
            )?,
            local_device_name: Some("Rust PQC Responder".to_owned()),
            identity: responder_identity,
            supported_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
        })?;

        let message_a = initiator.start()?;
        let responder_actions = responder.handle_frame(&message_a)?;
        assert_eq!(responder_actions.outbound_frames.len(), 2);

        let _ = initiator.handle_frame(&responder_actions.outbound_frames[0])?;
        let initiator_actions = initiator.handle_frame(&responder_actions.outbound_frames[1])?;
        assert!(initiator_actions.established.is_some());
        assert_eq!(initiator_actions.outbound_frames.len(), 1);

        let responder_finish = responder.handle_frame(&initiator_actions.outbound_frames[0])?;
        assert!(responder_finish.established.is_some());

        let initiator_keys = initiator
            .established_session_keys()
            .ok_or_else(|| anyhow!("expected initiator keys"))?;
        let responder_keys = responder
            .established_session_keys()
            .ok_or_else(|| anyhow!("expected responder keys"))?;
        assert_eq!(initiator_keys.send_key, responder_keys.receive_key);
        assert_eq!(initiator_keys.receive_key, responder_keys.send_key);
        assert_eq!(responder_keys.negotiated_suite, "ML-KEM-768");
        Ok(())
    }
}
