use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use anyhow::{Result, anyhow, bail};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use getrandom::fill as fill_random;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use hpke::aead::ChaCha20Poly1305;
use hpke::kdf::HkdfSha256;
use hpke::kem::X25519HkdfSha256;
use hpke::{Deserializable, Kem as KemTrait, OpModeR, Serializable, setup_receiver};
use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use time::OffsetDateTime;

use crate::{ProtocolIdentityBinding, ProtocolSigningAlgorithm};

const HANDSHAKE_VERSION: u8 = 1;
const HANDSHAKE_A_DOMAIN: &[u8] = b"SkyBridge-A";
const HANDSHAKE_B_DOMAIN: &[u8] = b"SkyBridge-B";
const FINISHED_MAGIC: &[u8; 4] = b"FIN1";
const CLASSIC_SUITE_WIRE_ID: u16 = 0x1001;
const CLASSIC_SUITE_NAME: &str = "X25519";
const KDF_COMPOSITION_LABEL: &[u8] = b"v1-single";
const KEM_DEM_INFO: &[u8] = b"handshake-payload";
const KEM_DEM_EXPORT_PREFIX: &[u8] = b"SkyBridge-KEMDEM-SessionRoot-v1|";
const FINISHED_I2R_INFO: &[u8] = b"SkyBridge-FINISHED|I2R|";
const FINISHED_R2I_INFO: &[u8] = b"SkyBridge-FINISHED|R2I|";
const IDENTITY_ALGORITHM_ED25519: u8 = 0x01;
const IDENTITY_ALGORITHM_MLDSA65: u8 = 0x02;
const IDENTITY_ALGORITHM_P256: u8 = 0x03;
const HEARTBEAT_PLATFORM: &str = std::env::consts::OS;
const HEARTBEAT_REMOTE_VIDEO_FORMAT: &str = "bgra";
const REFERENCE_UNIX_SECONDS: i64 = 978_307_200;

type ClassicKem = X25519HkdfSha256;
type ClassicAead = ChaCha20Poly1305;
type ClassicKdf = HkdfSha256;
type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone)]
pub struct ClassicInitiatorConfig {
    pub local_binding: ProtocolIdentityBinding,
    pub signing_secret_key: Vec<u8>,
    pub local_device_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClassicSessionKeys {
    pub send_key: Vec<u8>,
    pub receive_key: Vec<u8>,
    pub negotiated_suite: String,
    pub transcript_hash: Vec<u8>,
}

#[derive(Debug, Default)]
pub struct ClassicHandleResult {
    pub outbound_frames: Vec<Vec<u8>>,
    pub established: Option<ClassicSessionKeys>,
    pub heartbeat_requested: bool,
    pub pong_id: Option<u64>,
    pub observed_pong_id: Option<u64>,
    pub observed_heartbeat: bool,
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

enum InitiatorState {
    Idle,
    WaitingForMessageB(WaitingForMessageBState),
    WaitingForFinished(WaitingForFinishedState),
    Established(ClassicSessionKeys),
}

struct WaitingForMessageBState {
    ephemeral_private_key: <ClassicKem as KemTrait>::PrivateKey,
    client_nonce: [u8; 32],
    transcript_hash_a: [u8; 32],
    pending_finished: Option<FinishedFrame>,
}

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

impl FinishedDirection {
    fn from_byte(byte: u8) -> Result<Self> {
        match byte {
            0x01 => Ok(Self::ResponderToInitiator),
            0x02 => Ok(Self::InitiatorToResponder),
            _ => bail!("unknown finished direction"),
        }
    }

    fn as_byte(self) -> u8 {
        match self {
            Self::ResponderToInitiator => 0x01,
            Self::InitiatorToResponder => 0x02,
        }
    }
}

pub struct ClassicInitiatorHandshake {
    config: ClassicInitiatorConfig,
    state: InitiatorState,
}

impl std::fmt::Debug for ClassicInitiatorHandshake {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClassicInitiatorHandshake")
            .field("device_id", &self.config.local_binding.device_id)
            .field("state", &self.state_label())
            .finish()
    }
}

impl ClassicInitiatorHandshake {
    pub fn new(config: ClassicInitiatorConfig) -> Result<Self> {
        if config.local_binding.protocol_signing_algorithm != ProtocolSigningAlgorithm::Ed25519 {
            bail!("classic initiator handshake only supports Ed25519 identities");
        }
        if config.signing_secret_key.len() != 32 {
            bail!("ed25519 signing secret key must be 32 bytes");
        }
        Ok(Self {
            config,
            state: InitiatorState::Idle,
        })
    }

    pub fn start(&mut self) -> Result<Vec<u8>> {
        match self.state {
            InitiatorState::Idle => {}
            _ => return Ok(Vec::new()),
        }

        let signing_key = signing_key_from_bytes(&self.config.signing_secret_key)?;
        let mut key_material = [0u8; 32];
        fill_random(&mut key_material)?;
        let (ephemeral_private_key, ephemeral_public_key) =
            ClassicKem::derive_keypair(&key_material);

        let mut client_nonce = [0u8; 32];
        fill_random(&mut client_nonce)?;

        let supported_suites = [CLASSIC_SUITE_WIRE_ID];
        let capabilities = classic_capabilities_bytes();
        let policy = classic_policy_bytes();
        let identity_public_key = encode_identity_public_key(
            self.config.local_binding.protocol_signing_algorithm,
            &self.config.local_binding.protocol_public_key_bytes,
        )?;

        let mut unsigned = Vec::new();
        unsigned.push(HANDSHAKE_VERSION);
        append_u16_le(&mut unsigned, supported_suites.len() as u16);
        for wire_id in supported_suites {
            append_u16_le(&mut unsigned, wire_id);
        }
        append_u16_le(&mut unsigned, 1);
        append_u16_le(&mut unsigned, CLASSIC_SUITE_WIRE_ID);
        append_u16_le(
            &mut unsigned,
            <<ClassicKem as KemTrait>::PublicKey as Serializable>::size() as u16,
        );
        unsigned.extend_from_slice(ephemeral_public_key.to_bytes().as_slice());
        unsigned.extend_from_slice(&client_nonce);
        append_u16_le(&mut unsigned, capabilities.len() as u16);
        unsigned.extend_from_slice(&capabilities);
        append_u16_le(&mut unsigned, policy.len() as u16);
        unsigned.extend_from_slice(&policy);
        append_u16_le(&mut unsigned, identity_public_key.len() as u16);
        unsigned.extend_from_slice(&identity_public_key);

        let mut preimage = Vec::from(HANDSHAKE_A_DOMAIN);
        preimage.extend_from_slice(&unsigned);
        let signature = signing_key.sign(&preimage).to_bytes();
        let transcript_hash_a = Sha256::digest(&unsigned);

        let mut message = unsigned;
        append_u16_le(&mut message, signature.len() as u16);
        message.extend_from_slice(&signature);
        append_u16_le(&mut message, 0);

        self.state = InitiatorState::WaitingForMessageB(WaitingForMessageBState {
            ephemeral_private_key,
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
            InitiatorState::WaitingForMessageB(waiting) => {
                let parsed = decode_message_b(&unwrapped)?;
                let keys = process_message_b(&self.config, waiting, parsed)?;
                let mut result = ClassicHandleResult::default();
                let pending = waiting.pending_finished.clone();
                self.state = InitiatorState::WaitingForFinished(WaitingForFinishedState {
                    session_keys: keys.clone(),
                });
                if let Some(pending) = pending {
                    return self.handle_finished(pending);
                }
                result.heartbeat_requested = true;
                Ok(result)
            }
            InitiatorState::WaitingForFinished(waiting) => {
                if let Some(message) =
                    try_handle_encrypted_app_message(&unwrapped, &waiting.session_keys)?
                {
                    return Ok(message);
                }
                bail!("unexpected frame while waiting for Finished")
            }
            InitiatorState::Established(keys) => {
                if let Some(message) = try_handle_encrypted_app_message(&unwrapped, keys)? {
                    return Ok(message);
                }
                Ok(ClassicHandleResult::default())
            }
            InitiatorState::Idle => bail!("received frame before classic handshake started"),
        }
    }

    pub fn build_heartbeat_frame(&self) -> Result<Vec<u8>> {
        let session_keys = self
            .established_session_keys()
            .ok_or_else(|| anyhow!("classic handshake is not established"))?;
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
            .ok_or_else(|| anyhow!("classic handshake is not established"))?;
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
            .ok_or_else(|| anyhow!("classic handshake is not established"))?;
        build_encrypted_app_frame(
            session_keys,
            &PingEnvelope {
                ping: PingPayload { id },
            },
        )
    }

    pub fn established_session_keys(&self) -> Option<&ClassicSessionKeys> {
        match &self.state {
            InitiatorState::Established(keys) => Some(keys),
            InitiatorState::WaitingForFinished(waiting) => Some(&waiting.session_keys),
            _ => None,
        }
    }

    fn state_label(&self) -> &'static str {
        match self.state {
            InitiatorState::Idle => "idle",
            InitiatorState::WaitingForMessageB(_) => "waiting_for_message_b",
            InitiatorState::WaitingForFinished(_) => "waiting_for_finished",
            InitiatorState::Established(_) => "established",
        }
    }

    fn handle_finished(&mut self, finished: FinishedFrame) -> Result<ClassicHandleResult> {
        match &mut self.state {
            InitiatorState::WaitingForMessageB(waiting) => {
                waiting.pending_finished = Some(finished);
                Ok(ClassicHandleResult::default())
            }
            InitiatorState::WaitingForFinished(waiting) => {
                verify_finished(
                    &waiting.session_keys,
                    FinishedDirection::ResponderToInitiator,
                    &finished,
                )?;
                let client_finished = encode_finished_frame(
                    FinishedDirection::InitiatorToResponder,
                    &waiting.session_keys.send_key,
                    &waiting.session_keys.transcript_hash,
                )?;
                let established = waiting.session_keys.clone();
                self.state = InitiatorState::Established(established.clone());
                Ok(ClassicHandleResult {
                    outbound_frames: vec![client_finished],
                    established: Some(established),
                    heartbeat_requested: true,
                    pong_id: None,
                    observed_pong_id: None,
                    observed_heartbeat: false,
                })
            }
            InitiatorState::Established(_) => Ok(ClassicHandleResult::default()),
            InitiatorState::Idle => bail!("received Finished before classic handshake started"),
        }
    }
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

struct DecodedMessageB {
    selected_suite_wire_id: u16,
    responder_share: Vec<u8>,
    server_nonce: [u8; 32],
    encrypted_payload_combined: Vec<u8>,
    encrypted_payload_ciphertext: Vec<u8>,
    encrypted_payload_encapsulated_key: Vec<u8>,
    encrypted_payload_nonce: Vec<u8>,
    encrypted_payload_tag: Vec<u8>,
    identity_public_key: Vec<u8>,
    signature: [u8; 64],
}

fn decode_message_b(frame: &[u8]) -> Result<DecodedMessageB> {
    let mut offset = 0usize;
    let version = *frame
        .get(offset)
        .ok_or_else(|| anyhow!("messageB too short"))?;
    offset += 1;
    if version != HANDSHAKE_VERSION {
        bail!("messageB version mismatch");
    }

    let selected_suite_wire_id = read_u16_le(frame, &mut offset)?;
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
    if signature_len != 64 {
        bail!("unsupported messageB signature length");
    }
    let signature_bytes = read_exact(frame, &mut offset, signature_len)?;
    let mut signature = [0u8; 64];
    signature.copy_from_slice(signature_bytes);

    if offset < frame.len() {
        let secure_enclave_signature_len = read_u16_le(frame, &mut offset)? as usize;
        let _ = read_exact(frame, &mut offset, secure_enclave_signature_len)?;
    }
    if offset != frame.len() {
        bail!("unexpected trailing bytes in messageB");
    }

    Ok(DecodedMessageB {
        selected_suite_wire_id,
        responder_share,
        server_nonce,
        encrypted_payload_combined,
        encrypted_payload_ciphertext: payload.ciphertext,
        encrypted_payload_encapsulated_key: payload.encapsulated_key,
        encrypted_payload_nonce: payload.nonce,
        encrypted_payload_tag: payload.tag,
        identity_public_key,
        signature,
    })
}

fn process_message_b(
    _config: &ClassicInitiatorConfig,
    waiting: &WaitingForMessageBState,
    message_b: DecodedMessageB,
) -> Result<ClassicSessionKeys> {
    if message_b.selected_suite_wire_id != CLASSIC_SUITE_WIRE_ID {
        bail!("unsupported classic suite in MessageB");
    }
    if message_b.responder_share != message_b.encrypted_payload_encapsulated_key {
        bail!("responder share mismatch");
    }
    let identity = decode_identity_public_key(&message_b.identity_public_key)?;
    if identity.algorithm != ProtocolSigningAlgorithm::Ed25519 {
        bail!("unsupported messageB identity algorithm");
    }

    let payload_hash = Sha256::digest(&message_b.encrypted_payload_combined);
    let mut signature_preimage = Vec::from(HANDSHAKE_B_DOMAIN);
    signature_preimage.extend_from_slice(&waiting.transcript_hash_a);
    append_u16_le(&mut signature_preimage, message_b.selected_suite_wire_id);
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

    let verifying_key = VerifyingKey::from_bytes(&identity.public_key)
        .map_err(|error| anyhow!("invalid responder ed25519 public key: {error}"))?;
    verifying_key
        .verify(
            &signature_preimage,
            &Signature::from_bytes(&message_b.signature),
        )
        .map_err(|error| anyhow!("messageB signature verification failed: {error}"))?;

    let encapsulated_key = <<ClassicKem as KemTrait>::EncappedKey as Deserializable>::from_bytes(
        &message_b.encrypted_payload_encapsulated_key,
    )
    .map_err(|error| anyhow!("invalid MessageB encapsulated key: {error}"))?;
    let session_secret = if message_b.encrypted_payload_nonce.is_empty()
        && message_b.encrypted_payload_tag.is_empty()
    {
        let mut receiver = setup_receiver::<ClassicAead, ClassicKdf, ClassicKem>(
            &OpModeR::Base,
            &waiting.ephemeral_private_key,
            &encapsulated_key,
            KEM_DEM_INFO,
        )
        .map_err(|error| anyhow!("failed to set up classic HPKE receiver: {error}"))?;

        let _peer_capabilities_plaintext = receiver
            .open(&message_b.encrypted_payload_ciphertext, KEM_DEM_INFO)
            .map_err(|error| anyhow!("failed to open classic MessageB payload: {error}"))?;

        let mut exporter_context = Vec::from(KEM_DEM_EXPORT_PREFIX);
        append_u16_le(&mut exporter_context, CLASSIC_SUITE_WIRE_ID);
        exporter_context.extend_from_slice(KEM_DEM_INFO);
        let mut session_secret = [0u8; 32];
        receiver
            .export(&exporter_context, &mut session_secret)
            .map_err(|error| anyhow!("failed to export classic HPKE session secret: {error}"))?;
        session_secret
    } else {
        let shared_secret =
            ClassicKem::decap(&waiting.ephemeral_private_key, None, &encapsulated_key).map_err(
                |error| anyhow!("failed to decapsulate classic MessageB share: {error}"),
            )?;
        let mut payload_key = [0u8; 32];
        Hkdf::<Sha256>::new(None, shared_secret.0.as_slice())
            .expand(KEM_DEM_INFO, &mut payload_key)
            .map_err(|_| anyhow!("failed to derive fallback MessageB payload key"))?;
        let cipher = Aes256Gcm::new_from_slice(&payload_key)
            .map_err(|error| anyhow!("invalid fallback payload key: {error}"))?;
        let mut combined = message_b.encrypted_payload_ciphertext.clone();
        combined.extend_from_slice(&message_b.encrypted_payload_tag);
        let _peer_capabilities_plaintext = cipher
            .decrypt(
                Nonce::from_slice(&message_b.encrypted_payload_nonce),
                combined.as_ref(),
            )
            .map_err(|error| anyhow!("failed to open fallback MessageB payload: {error}"))?;
        let mut session_secret = [0u8; 32];
        session_secret.copy_from_slice(shared_secret.0.as_slice());
        session_secret
    };

    let transcript_hash_b = Sha256::digest(message_b_encoded_without_signature(&message_b));
    derive_session_keys(
        &session_secret,
        &waiting.client_nonce,
        &message_b.server_nonce,
        &waiting.transcript_hash_a,
        transcript_hash_b.as_ref(),
    )
}

fn message_b_encoded_without_signature(message_b: &DecodedMessageB) -> Vec<u8> {
    let mut encoded = Vec::new();
    encoded.push(HANDSHAKE_VERSION);
    append_u16_le(&mut encoded, message_b.selected_suite_wire_id);
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

fn derive_session_keys(
    shared_secret: &[u8; 32],
    client_nonce: &[u8; 32],
    server_nonce: &[u8; 32],
    transcript_hash_a: &[u8; 32],
    transcript_hash_b: &[u8],
) -> Result<ClassicSessionKeys> {
    let mut kdf_info = Vec::from(b"SkyBridge-KDF".as_slice());
    kdf_info.push(0x01);
    append_u16_le(&mut kdf_info, CLASSIC_SUITE_WIRE_ID);
    kdf_info.extend_from_slice(KDF_COMPOSITION_LABEL);
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
    let full_transcript_hash = Sha256::digest(&transcript_input);

    Ok(ClassicSessionKeys {
        send_key: send_key.to_vec(),
        receive_key: receive_key.to_vec(),
        negotiated_suite: CLASSIC_SUITE_NAME.to_owned(),
        transcript_hash: full_transcript_hash.to_vec(),
    })
}

fn verify_finished(
    session_keys: &ClassicSessionKeys,
    expected_direction: FinishedDirection,
    finished: &FinishedFrame,
) -> Result<()> {
    if finished.direction != expected_direction {
        bail!("unexpected Finished direction");
    }
    let base_key = match expected_direction {
        FinishedDirection::ResponderToInitiator => &session_keys.receive_key,
        FinishedDirection::InitiatorToResponder => &session_keys.send_key,
    };
    let info = match expected_direction {
        FinishedDirection::ResponderToInitiator => FINISHED_R2I_INFO,
        FinishedDirection::InitiatorToResponder => FINISHED_I2R_INFO,
    };
    let mac = finished_mac(base_key, info, &session_keys.transcript_hash)?;
    if mac != finished.mac {
        bail!("Finished MAC verification failed");
    }
    Ok(())
}

fn encode_finished_frame(
    direction: FinishedDirection,
    base_key: &[u8],
    transcript_hash: &[u8],
) -> Result<Vec<u8>> {
    let info = match direction {
        FinishedDirection::ResponderToInitiator => FINISHED_R2I_INFO,
        FinishedDirection::InitiatorToResponder => FINISHED_I2R_INFO,
    };
    let mac = finished_mac(base_key, info, transcript_hash)?;
    let mut encoded = Vec::with_capacity(38);
    encoded.extend_from_slice(FINISHED_MAGIC);
    encoded.push(HANDSHAKE_VERSION);
    encoded.push(direction.as_byte());
    encoded.extend_from_slice(&mac);
    Ok(encoded)
}

fn finished_mac(base_key: &[u8], info_prefix: &[u8], transcript_hash: &[u8]) -> Result<[u8; 32]> {
    let hkdf = Hkdf::<Sha256>::new(None, base_key);
    let mut mac_key = [0u8; 32];
    let mut info = Vec::from(info_prefix);
    info.extend_from_slice(transcript_hash);
    hkdf.expand(&info, &mut mac_key)
        .map_err(|_| anyhow!("failed to derive Finished MAC key"))?;
    let mut hmac = <HmacSha256 as Mac>::new_from_slice(&mac_key)
        .map_err(|error| anyhow!("failed to construct Finished HMAC: {error}"))?;
    hmac.update(transcript_hash);
    let tag = hmac.finalize().into_bytes();
    let mut mac = [0u8; 32];
    mac.copy_from_slice(&tag);
    Ok(mac)
}

fn decode_finished_frame(frame: &[u8]) -> Result<FinishedFrame> {
    if frame.len() != 38 {
        bail!("invalid Finished length");
    }
    if frame[..4] != *FINISHED_MAGIC {
        bail!("invalid Finished magic");
    }
    if frame[4] != HANDSHAKE_VERSION {
        bail!("invalid Finished version");
    }
    let direction = FinishedDirection::from_byte(frame[5])?;
    let mut mac = [0u8; 32];
    mac.copy_from_slice(&frame[6..]);
    Ok(FinishedFrame { direction, mac })
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

fn classic_capabilities_bytes() -> Vec<u8> {
    let mut encoded = Vec::new();
    encode_string_array(&mut encoded, &["X25519"]);
    encode_string_array(&mut encoded, &["P-256"]);
    encode_string_array(&mut encoded, &["Classic"]);
    encode_string_array(&mut encoded, &["AES-256-GCM", "ChaCha20-Poly1305"]);
    encoded.push(0x00);
    encode_string(&mut encoded, HEARTBEAT_PLATFORM);
    encode_string(&mut encoded, "CryptoKit-Classic");
    encoded
}

fn classic_policy_bytes() -> Vec<u8> {
    let mut encoded = Vec::new();
    encoded.push(0x00);
    encoded.push(0x00);
    encode_string(&mut encoded, "classic");
    encoded.push(0x00);
    encoded
}

fn encode_identity_public_key(
    algorithm: ProtocolSigningAlgorithm,
    public_key: &[u8],
) -> Result<Vec<u8>> {
    let algorithm_byte = match algorithm {
        ProtocolSigningAlgorithm::Ed25519 => IDENTITY_ALGORITHM_ED25519,
        ProtocolSigningAlgorithm::MlDsa65 => IDENTITY_ALGORITHM_MLDSA65,
    };
    let mut encoded = Vec::new();
    encoded.push(algorithm_byte);
    append_u16_le(&mut encoded, public_key.len() as u16);
    encoded.extend_from_slice(public_key);
    encoded.push(0x00);
    Ok(encoded)
}

struct DecodedIdentityPublicKey {
    algorithm: ProtocolSigningAlgorithm,
    public_key: [u8; 32],
}

fn decode_identity_public_key(data: &[u8]) -> Result<DecodedIdentityPublicKey> {
    if data.len() < 1 + 2 + 32 + 1 {
        bail!("identity public key payload too short");
    }
    let algorithm = match data[0] {
        IDENTITY_ALGORITHM_ED25519 => ProtocolSigningAlgorithm::Ed25519,
        IDENTITY_ALGORITHM_MLDSA65 => ProtocolSigningAlgorithm::MlDsa65,
        IDENTITY_ALGORITHM_P256 => {
            bail!("p256 identities are not supported in classic rust initiator")
        }
        _ => bail!("unknown identity public key algorithm"),
    };
    let mut offset = 1usize;
    let key_len = read_u16_le(data, &mut offset)? as usize;
    let key_bytes = read_exact(data, &mut offset, key_len)?;
    let has_secure_enclave = *data
        .get(offset)
        .ok_or_else(|| anyhow!("missing secure enclave identity flag"))?;
    if has_secure_enclave != 0x00 {
        bail!("secure enclave identity keys are not supported in classic rust initiator");
    }
    if algorithm != ProtocolSigningAlgorithm::Ed25519 || key_len != 32 {
        bail!("unsupported identity public key length");
    }
    let mut public_key = [0u8; 32];
    public_key.copy_from_slice(key_bytes);
    Ok(DecodedIdentityPublicKey {
        algorithm,
        public_key,
    })
}

struct DecodedHpkeSealedBox {
    encapsulated_key: Vec<u8>,
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
    tag: Vec<u8>,
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

fn signing_key_from_bytes(bytes: &[u8]) -> Result<SigningKey> {
    let secret: [u8; 32] = bytes
        .try_into()
        .map_err(|_| anyhow!("invalid ed25519 secret key length"))?;
    Ok(SigningKey::from_bytes(&secret))
}

fn apple_reference_seconds_now() -> f64 {
    let now = OffsetDateTime::now_utc().unix_timestamp_nanos() as f64 / 1_000_000_000.0;
    now - REFERENCE_UNIX_SECONDS as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finished_round_trip_uses_expected_mac() -> Result<()> {
        let keys = ClassicSessionKeys {
            send_key: vec![0x11; 32],
            receive_key: vec![0x22; 32],
            negotiated_suite: CLASSIC_SUITE_NAME.to_owned(),
            transcript_hash: vec![0x33; 32],
        };
        let encoded = encode_finished_frame(
            FinishedDirection::InitiatorToResponder,
            &keys.send_key,
            &keys.transcript_hash,
        )?;
        let decoded = decode_finished_frame(&encoded)?;
        verify_finished(&keys, FinishedDirection::InitiatorToResponder, &decoded)?;
        Ok(())
    }

    #[test]
    fn heartbeat_payload_uses_apple_reference_date() -> Result<()> {
        let config = ClassicInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-1234567890abcd",
                ProtocolSigningAlgorithm::Ed25519,
                vec![7; 32],
                None,
            )?,
            signing_secret_key: vec![9; 32],
            local_device_name: Some("Rust Agent".to_owned()),
        };
        let handshake = ClassicInitiatorHandshake::new(config)?;
        let timestamp = apple_reference_seconds_now();
        assert!(timestamp > 700_000_000.0);
        assert!(handshake.established_session_keys().is_none());
        Ok(())
    }

    #[test]
    fn encrypted_heartbeat_frame_round_trips_through_app_message_parser() -> Result<()> {
        let session_keys = ClassicSessionKeys {
            send_key: vec![0x42; 32],
            receive_key: vec![0x42; 32],
            negotiated_suite: CLASSIC_SUITE_NAME.to_owned(),
            transcript_hash: vec![0x24; 32],
        };
        let frame = build_encrypted_app_frame(
            &session_keys,
            &HeartbeatEnvelope {
                heartbeat: HeartbeatPayload {
                    sent_at: 123.0,
                    device_id: Some("device-1234567890abcd".to_owned()),
                    device_name: Some("Rust Agent".to_owned()),
                    platform: "macos".to_owned(),
                    remote_video_formats: vec!["bgra".to_owned()],
                },
            },
        )?;

        let parsed = try_handle_encrypted_app_message(&frame, &session_keys)?
            .ok_or_else(|| anyhow!("expected encrypted heartbeat payload to parse"))?;
        assert!(parsed.heartbeat_requested);
        assert!(parsed.observed_heartbeat);
        assert_eq!(parsed.pong_id, None);
        assert_eq!(parsed.observed_pong_id, None);
        Ok(())
    }

    #[test]
    fn encrypted_ping_and_pong_frames_round_trip_through_app_message_parser() -> Result<()> {
        let session_keys = ClassicSessionKeys {
            send_key: vec![0x77; 32],
            receive_key: vec![0x77; 32],
            negotiated_suite: CLASSIC_SUITE_NAME.to_owned(),
            transcript_hash: vec![0x11; 32],
        };
        let ping = build_encrypted_app_frame(
            &session_keys,
            &PingEnvelope {
                ping: PingPayload { id: 9 },
            },
        )?;
        let pong = build_encrypted_app_frame(
            &session_keys,
            &PongEnvelope {
                pong: PongPayload { id: 9 },
            },
        )?;

        let parsed_ping = try_handle_encrypted_app_message(&ping, &session_keys)?
            .ok_or_else(|| anyhow!("expected encrypted ping payload to parse"))?;
        assert_eq!(parsed_ping.pong_id, Some(9));
        assert_eq!(parsed_ping.observed_pong_id, None);

        let parsed_pong = try_handle_encrypted_app_message(&pong, &session_keys)?
            .ok_or_else(|| anyhow!("expected encrypted pong payload to parse"))?;
        assert_eq!(parsed_pong.pong_id, None);
        assert_eq!(parsed_pong.observed_pong_id, Some(9));
        Ok(())
    }
}
