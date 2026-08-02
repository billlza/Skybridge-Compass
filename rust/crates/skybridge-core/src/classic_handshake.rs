use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use anyhow::{Result, anyhow, bail};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use getrandom::fill as fill_random;
use hkdf::Hkdf;
use hpke::aead::ChaCha20Poly1305;
use hpke::kdf::HkdfSha256;
use hpke::kem::X25519HkdfSha256;
use hpke::{
    Deserializable, Kem as KemTrait, OpModeR, OpModeS, Serializable, setup_receiver, setup_sender,
};
use rand::SeedableRng;
use rand::rngs::StdRng;
use sha2::{Digest, Sha256};

pub use crate::handshake_app_frame::HeartbeatPayload;
use crate::handshake_finished::{
    FINISHED_I2R_INFO_PREFIX, FINISHED_R2I_INFO_PREFIX, derive_finished_mac, verify_finished_mac,
};
use crate::handshake_wire::{
    append_u16_le, encode_hpke_sealed_box, encode_string, encode_string_array, read_exact,
    read_u16_le, unwrap_handshake_padding,
};
use crate::policy::{DowngradePolicy, encode_policy_wire_byte};
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
const IDENTITY_ALGORITHM_ED25519: u8 = 0x01;
const IDENTITY_ALGORITHM_MLDSA65: u8 = 0x02;
const IDENTITY_ALGORITHM_P256: u8 = 0x03;
const IDENTITY_ALGORITHM_MLDSA87: u8 = 0x04;
type ClassicKem = X25519HkdfSha256;
type ClassicAead = ChaCha20Poly1305;
type ClassicKdf = HkdfSha256;

#[derive(Clone)]
pub struct ClassicInitiatorConfig {
    pub local_binding: ProtocolIdentityBinding,
    pub signing_secret_key: Vec<u8>,
    pub local_device_name: Option<String>,
    /// Downgrade posture advertised on the wire. The classic path is the
    /// post-downgrade attempt, so this defaults to [`DowngradePolicy::Default`]
    /// (no PQC mandate), which encodes the same `0x00` policy byte the legacy
    /// `classic_policy_bytes()` emitted.
    pub policy: DowngradePolicy,
}

#[derive(Clone)]
pub struct ClassicResponderConfig {
    pub local_binding: ProtocolIdentityBinding,
    pub signing_secret_key: Vec<u8>,
    pub local_device_name: Option<String>,
    /// Local downgrade posture for accepting the classic business-traffic path.
    pub policy: DowngradePolicy,
}

impl std::fmt::Debug for ClassicInitiatorConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClassicInitiatorConfig")
            .field(
                "local_signing_algorithm",
                &self.local_binding.protocol_signing_algorithm,
            )
            .field("signing_secret_key", &"<redacted>")
            .field(
                "local_device_name_present",
                &self.local_device_name.is_some(),
            )
            .field("policy", &self.policy)
            .finish()
    }
}

impl std::fmt::Debug for ClassicResponderConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClassicResponderConfig")
            .field(
                "local_signing_algorithm",
                &self.local_binding.protocol_signing_algorithm,
            )
            .field("signing_secret_key", &"<redacted>")
            .field(
                "local_device_name_present",
                &self.local_device_name.is_some(),
            )
            .field("policy", &self.policy)
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct ClassicSessionKeys {
    pub send_key: Vec<u8>,
    pub receive_key: Vec<u8>,
    pub negotiated_suite: String,
    /// Fingerprint of the protocol identity whose handshake signature was
    /// verified before these keys were established.
    pub peer_protocol_public_key_fingerprint: String,
    pub transcript_hash: Vec<u8>,
}

impl std::fmt::Debug for ClassicSessionKeys {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ClassicSessionKeys")
            .field("send_key", &"<redacted>")
            .field("receive_key", &"<redacted>")
            .field("negotiated_suite", &self.negotiated_suite)
            .field("peer_protocol_public_key_fingerprint", &"<redacted>")
            .field("transcript_hash", &"<redacted>")
            .finish()
    }
}

#[derive(Debug, Default)]
pub struct ClassicHandleResult {
    pub outbound_frames: Vec<Vec<u8>>,
    pub established: Option<ClassicSessionKeys>,
}

enum InitiatorState {
    Idle,
    WaitingForMessageB(WaitingForMessageBState),
    WaitingForFinished(WaitingForFinishedState),
    Established(ClassicSessionKeys),
}

enum ResponderState {
    Idle,
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

pub struct ClassicResponderHandshake {
    config: ClassicResponderConfig,
    state: ResponderState,
}

impl std::fmt::Debug for ClassicInitiatorHandshake {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClassicInitiatorHandshake")
            .field(
                "local_signing_algorithm",
                &self.config.local_binding.protocol_signing_algorithm,
            )
            .field("state", &self.state_label())
            .finish()
    }
}

impl ClassicInitiatorHandshake {
    pub fn new(config: ClassicInitiatorConfig) -> Result<Self> {
        validate_classic_local_identity(
            &config.local_binding,
            &config.signing_secret_key,
            "initiator",
        )?;
        Ok(Self {
            config,
            state: InitiatorState::Idle,
        })
    }

    pub fn start(&mut self) -> Result<Vec<u8>> {
        match self.state {
            InitiatorState::Idle => {}
            _ => bail!("classic initiator handshake has already started"),
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
        let policy = classic_policy_bytes(self.config.policy);
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
                let pending = waiting.pending_finished.clone();
                self.state = InitiatorState::WaitingForFinished(WaitingForFinishedState {
                    session_keys: keys,
                });
                if let Some(pending) = pending {
                    return self.handle_finished(pending);
                }
                Ok(ClassicHandleResult::default())
            }
            InitiatorState::WaitingForFinished(_) => {
                bail!("unexpected non-Finished frame while waiting for Finished")
            }
            InitiatorState::Established(_) => {
                bail!("unexpected frame after classic handshake establishment")
            }
            InitiatorState::Idle => bail!("received frame before classic handshake started"),
        }
    }

    pub fn established_session_keys(&self) -> Option<&ClassicSessionKeys> {
        match &self.state {
            InitiatorState::Established(keys) => Some(keys),
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
                if waiting.pending_finished.is_some() {
                    bail!("duplicate responder Finished before MessageB");
                }
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
                })
            }
            InitiatorState::Established(_) => bail!("duplicate responder Finished"),
            InitiatorState::Idle => bail!("received Finished before classic handshake started"),
        }
    }
}

impl std::fmt::Debug for ClassicResponderHandshake {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClassicResponderHandshake")
            .field(
                "local_signing_algorithm",
                &self.config.local_binding.protocol_signing_algorithm,
            )
            .field("state", &self.state_label())
            .finish()
    }
}

impl ClassicResponderHandshake {
    pub fn new(config: ClassicResponderConfig) -> Result<Self> {
        validate_classic_local_identity(
            &config.local_binding,
            &config.signing_secret_key,
            "responder",
        )?;
        if !config.policy.allows_classic_business_fallback() {
            bail!("classic responder policy does not permit business traffic");
        }
        Ok(Self {
            config,
            state: ResponderState::Idle,
        })
    }

    pub fn handle_frame(&mut self, frame: &[u8]) -> Result<ClassicHandleResult> {
        let unwrapped = unwrap_handshake_padding(frame);
        if let Ok(finished) = decode_finished_frame(&unwrapped) {
            return self.handle_finished(finished);
        }

        match &mut self.state {
            ResponderState::Idle => {
                let message_a = decode_message_a(&unwrapped)?;
                let (message_b, session_keys) =
                    build_responder_message_b_and_keys(&self.config, &message_a)?;
                let responder_finished = encode_finished_frame(
                    FinishedDirection::ResponderToInitiator,
                    &session_keys.send_key,
                    &session_keys.transcript_hash,
                )?;
                self.state =
                    ResponderState::WaitingForFinished(WaitingForFinishedState { session_keys });
                Ok(ClassicHandleResult {
                    outbound_frames: vec![message_b, responder_finished],
                    ..Default::default()
                })
            }
            ResponderState::WaitingForFinished(_) => {
                bail!("unexpected non-Finished frame while waiting for initiator Finished")
            }
            ResponderState::Established(_) => {
                bail!("unexpected frame after classic handshake establishment")
            }
        }
    }

    pub fn established_session_keys(&self) -> Option<&ClassicSessionKeys> {
        match &self.state {
            ResponderState::Idle => None,
            ResponderState::WaitingForFinished(_) => None,
            ResponderState::Established(keys) => Some(keys),
        }
    }

    fn state_label(&self) -> &'static str {
        match self.state {
            ResponderState::Idle => "idle",
            ResponderState::WaitingForFinished(_) => "waiting_for_finished",
            ResponderState::Established(_) => "established",
        }
    }

    fn handle_finished(&mut self, finished: FinishedFrame) -> Result<ClassicHandleResult> {
        match &mut self.state {
            ResponderState::Idle => {
                bail!("received initiator Finished before classic responder processed MessageA")
            }
            ResponderState::WaitingForFinished(waiting) => {
                verify_finished(
                    &waiting.session_keys,
                    FinishedDirection::InitiatorToResponder,
                    &finished,
                )?;
                let established = waiting.session_keys.clone();
                self.state = ResponderState::Established(established.clone());
                Ok(ClassicHandleResult {
                    established: Some(established),
                    ..Default::default()
                })
            }
            ResponderState::Established(_) => bail!("duplicate initiator Finished"),
        }
    }
}

struct DecodedMessageA {
    initiator_share: Vec<u8>,
    client_nonce: [u8; 32],
    transcript_hash_a: [u8; 32],
    initiator_identity_algorithm: ProtocolSigningAlgorithm,
    initiator_identity_public_key: [u8; 32],
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
    if offered_count != 1 {
        bail!("classic MessageA must offer exactly one suite");
    }
    if read_u16_le(frame, &mut offset)? != CLASSIC_SUITE_WIRE_ID {
        bail!("classic MessageA offered an unknown suite");
    }

    let keyshare_count = read_u16_le(frame, &mut offset)? as usize;
    if keyshare_count != 1 {
        bail!("classic MessageA must contain exactly one key share");
    }
    if read_u16_le(frame, &mut offset)? != CLASSIC_SUITE_WIRE_ID {
        bail!("classic MessageA key share uses an unknown suite");
    }
    let share_len = read_u16_le(frame, &mut offset)? as usize;
    let expected_share_len = <<ClassicKem as KemTrait>::PublicKey as Serializable>::size();
    if share_len != expected_share_len {
        bail!(
            "invalid classic MessageA key share length: expected {expected_share_len} bytes, got {share_len}"
        );
    }
    let initiator_share = read_exact(frame, &mut offset, share_len)?.to_vec();

    let client_nonce_bytes = read_exact(frame, &mut offset, 32)?;
    let mut client_nonce = [0u8; 32];
    client_nonce.copy_from_slice(client_nonce_bytes);

    let capabilities_len = read_u16_le(frame, &mut offset)? as usize;
    let capabilities = read_exact(frame, &mut offset, capabilities_len)?;
    if capabilities.is_empty() {
        bail!("classic MessageA capabilities must not be empty");
    }

    let policy_len = read_u16_le(frame, &mut offset)? as usize;
    let policy = read_exact(frame, &mut offset, policy_len)?;
    validate_classic_policy(policy)?;

    let identity_public_key_len = read_u16_le(frame, &mut offset)? as usize;
    let identity_public_key = read_exact(frame, &mut offset, identity_public_key_len)?.to_vec();
    let unsigned_end = offset;

    let signature_len = read_u16_le(frame, &mut offset)? as usize;
    if signature_len != 64 {
        bail!("classic MessageA Ed25519 signature must be 64 bytes");
    }
    let signature_bytes = read_exact(frame, &mut offset, signature_len)?;
    let mut signature = [0u8; 64];
    signature.copy_from_slice(signature_bytes);

    let secure_enclave_signature_len = read_u16_le(frame, &mut offset)? as usize;
    let _ = read_exact(frame, &mut offset, secure_enclave_signature_len)?;
    if secure_enclave_signature_len != 0 {
        bail!("Secure Enclave proof signatures are not supported by the Rust classic handshake");
    }
    if offset != frame.len() {
        bail!("unexpected trailing bytes in classic MessageA");
    }

    let initiator_identity = decode_identity_public_key(&identity_public_key)?;
    if initiator_identity.algorithm != ProtocolSigningAlgorithm::Ed25519 {
        bail!("classic MessageA requires an Ed25519 protocol identity");
    }
    let mut signature_preimage = Vec::from(HANDSHAKE_A_DOMAIN);
    signature_preimage.extend_from_slice(&frame[..unsigned_end]);
    let verifying_key = VerifyingKey::from_bytes(&initiator_identity.public_key)
        .map_err(|error| anyhow!("invalid initiator Ed25519 public key: {error}"))?;
    verifying_key
        .verify(&signature_preimage, &Signature::from_bytes(&signature))
        .map_err(|error| anyhow!("MessageA signature verification failed: {error}"))?;

    let transcript_hash_a = Sha256::digest(&frame[..unsigned_end]);
    Ok(DecodedMessageA {
        initiator_share,
        client_nonce,
        transcript_hash_a: transcript_hash_a.into(),
        initiator_identity_algorithm: initiator_identity.algorithm,
        initiator_identity_public_key: initiator_identity.public_key,
    })
}

fn build_responder_message_b_and_keys(
    config: &ClassicResponderConfig,
    message_a: &DecodedMessageA,
) -> Result<(Vec<u8>, ClassicSessionKeys)> {
    let initiator_public_key =
        <ClassicKem as KemTrait>::PublicKey::from_bytes(&message_a.initiator_share)
            .map_err(|error| anyhow!("invalid classic MessageA X25519 public key: {error}"))?;
    let mut rng_seed = [0u8; 32];
    fill_random(&mut rng_seed)?;
    let mut rng = StdRng::from_seed(rng_seed);
    let (encapsulated_key, mut sender) = setup_sender::<ClassicAead, ClassicKdf, ClassicKem, _>(
        &OpModeS::Base,
        &initiator_public_key,
        KEM_DEM_INFO,
        &mut rng,
    )
    .map_err(|error| anyhow!("failed to set up classic HPKE sender: {error}"))?;
    let payload_ciphertext = sender
        .seal(&classic_capabilities_bytes(), KEM_DEM_INFO)
        .map_err(|error| anyhow!("failed to seal classic MessageB payload: {error}"))?;

    let mut exporter_context = Vec::from(KEM_DEM_EXPORT_PREFIX);
    append_u16_le(&mut exporter_context, CLASSIC_SUITE_WIRE_ID);
    exporter_context.extend_from_slice(KEM_DEM_INFO);
    let mut session_secret = [0u8; 32];
    sender
        .export(&exporter_context, &mut session_secret)
        .map_err(|error| anyhow!("failed to export classic HPKE session secret: {error}"))?;

    let encapsulated_key = encapsulated_key.to_bytes();
    let encrypted_payload = encode_hpke_sealed_box(
        CLASSIC_SUITE_WIRE_ID,
        encapsulated_key.as_slice(),
        &[],
        &payload_ciphertext,
        &[],
    );
    let responder_identity_public_key = encode_identity_public_key(
        config.local_binding.protocol_signing_algorithm,
        &config.local_binding.protocol_public_key_bytes,
    )?;
    let mut server_nonce = [0u8; 32];
    fill_random(&mut server_nonce)?;

    let mut message_b_unsigned = Vec::new();
    message_b_unsigned.push(HANDSHAKE_VERSION);
    append_u16_le(&mut message_b_unsigned, CLASSIC_SUITE_WIRE_ID);
    append_u16_le(
        &mut message_b_unsigned,
        u16::try_from(encapsulated_key.len())
            .map_err(|_| anyhow!("classic responder share is too large"))?,
    );
    message_b_unsigned.extend_from_slice(encapsulated_key.as_slice());
    message_b_unsigned.extend_from_slice(&server_nonce);
    append_u16_le(
        &mut message_b_unsigned,
        u16::try_from(encrypted_payload.len())
            .map_err(|_| anyhow!("classic responder payload is too large"))?,
    );
    message_b_unsigned.extend_from_slice(&encrypted_payload);
    append_u16_le(
        &mut message_b_unsigned,
        u16::try_from(responder_identity_public_key.len())
            .map_err(|_| anyhow!("classic responder identity is too large"))?,
    );
    message_b_unsigned.extend_from_slice(&responder_identity_public_key);

    let payload_hash = Sha256::digest(&encrypted_payload);
    let mut signature_preimage = Vec::from(HANDSHAKE_B_DOMAIN);
    signature_preimage.extend_from_slice(&message_a.transcript_hash_a);
    append_u16_le(&mut signature_preimage, CLASSIC_SUITE_WIRE_ID);
    append_u16_le(
        &mut signature_preimage,
        u16::try_from(encapsulated_key.len())
            .map_err(|_| anyhow!("classic responder share is too large"))?,
    );
    signature_preimage.extend_from_slice(encapsulated_key.as_slice());
    signature_preimage.extend_from_slice(&server_nonce);
    signature_preimage.extend_from_slice(&payload_hash);
    append_u16_le(
        &mut signature_preimage,
        u16::try_from(responder_identity_public_key.len())
            .map_err(|_| anyhow!("classic responder identity is too large"))?,
    );
    signature_preimage.extend_from_slice(&responder_identity_public_key);

    let signing_key = signing_key_from_bytes(&config.signing_secret_key)?;
    let signature = signing_key.sign(&signature_preimage).to_bytes();
    let transcript_hash_b = Sha256::digest(&message_b_unsigned);
    let peer_protocol_public_key_fingerprint = ProtocolIdentityBinding::compute_fingerprint(
        message_a.initiator_identity_algorithm,
        &message_a.initiator_identity_public_key,
    );
    let session_keys = derive_responder_session_keys(
        &session_secret,
        &message_a.client_nonce,
        &server_nonce,
        &message_a.transcript_hash_a,
        transcript_hash_b.as_ref(),
        peer_protocol_public_key_fingerprint,
    )?;

    let mut message_b = message_b_unsigned;
    append_u16_le(&mut message_b, signature.len() as u16);
    message_b.extend_from_slice(&signature);
    append_u16_le(&mut message_b, 0);
    Ok((message_b, session_keys))
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

    let secure_enclave_signature_len = read_u16_le(frame, &mut offset)? as usize;
    let _ = read_exact(frame, &mut offset, secure_enclave_signature_len)?;
    if secure_enclave_signature_len != 0 {
        bail!("Secure Enclave proof signatures are not supported by the Rust classic handshake");
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
    let expected_share_len = <<ClassicKem as KemTrait>::EncappedKey as Serializable>::size();
    if message_b.responder_share.len() != expected_share_len {
        bail!(
            "invalid classic MessageB responder share length: expected {expected_share_len} bytes, got {}",
            message_b.responder_share.len()
        );
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
    let peer_protocol_public_key_fingerprint =
        ProtocolIdentityBinding::compute_fingerprint(identity.algorithm, &identity.public_key);
    derive_session_keys(
        &session_secret,
        &waiting.client_nonce,
        &message_b.server_nonce,
        &waiting.transcript_hash_a,
        transcript_hash_b.as_ref(),
        peer_protocol_public_key_fingerprint,
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
    peer_protocol_public_key_fingerprint: String,
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
        peer_protocol_public_key_fingerprint,
        transcript_hash: full_transcript_hash.to_vec(),
    })
}

fn derive_responder_session_keys(
    shared_secret: &[u8; 32],
    client_nonce: &[u8; 32],
    server_nonce: &[u8; 32],
    transcript_hash_a: &[u8; 32],
    transcript_hash_b: &[u8],
    peer_protocol_public_key_fingerprint: String,
) -> Result<ClassicSessionKeys> {
    let mut keys = derive_session_keys(
        shared_secret,
        client_nonce,
        server_nonce,
        transcript_hash_a,
        transcript_hash_b,
        peer_protocol_public_key_fingerprint,
    )?;
    std::mem::swap(&mut keys.send_key, &mut keys.receive_key);
    Ok(keys)
}

fn verify_finished(
    session_keys: &ClassicSessionKeys,
    expected_direction: FinishedDirection,
    finished: &FinishedFrame,
) -> Result<()> {
    if finished.direction != expected_direction {
        bail!("unexpected Finished direction");
    }
    let base_key = &session_keys.receive_key;
    let info = match expected_direction {
        FinishedDirection::ResponderToInitiator => FINISHED_R2I_INFO_PREFIX,
        FinishedDirection::InitiatorToResponder => FINISHED_I2R_INFO_PREFIX,
    };
    if !verify_finished_mac(base_key, info, &session_keys.transcript_hash, &finished.mac)? {
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
        FinishedDirection::ResponderToInitiator => FINISHED_R2I_INFO_PREFIX,
        FinishedDirection::InitiatorToResponder => FINISHED_I2R_INFO_PREFIX,
    };
    let mac = derive_finished_mac(base_key, info, transcript_hash)?;
    let mut encoded = Vec::with_capacity(38);
    encoded.extend_from_slice(FINISHED_MAGIC);
    encoded.push(HANDSHAKE_VERSION);
    encoded.push(direction.as_byte());
    encoded.extend_from_slice(&mac);
    Ok(encoded)
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

fn classic_capabilities_bytes() -> Vec<u8> {
    let mut encoded = Vec::new();
    encode_string_array(&mut encoded, &["X25519"]);
    encode_string_array(&mut encoded, &["P-256"]);
    encode_string_array(&mut encoded, &["Classic"]);
    encode_string_array(&mut encoded, &["AES-256-GCM", "ChaCha20-Poly1305"]);
    encoded.push(0x00);
    encode_string(&mut encoded, std::env::consts::OS);
    encode_string(&mut encoded, "CryptoKit-Classic");
    encoded
}

/// Encode the classic MessageA policy block.
///
/// Wire format is unchanged: `[requirePQC: u8][reserved: u8][provider-token:
/// len-prefixed str][trailing: u8]`. The first byte is now derived from the active
/// [`DowngradePolicy`] (for the default `DowngradePolicy::Default` it emits `0x00`,
/// byte-identical to the previous static output).
fn classic_policy_bytes(policy: DowngradePolicy) -> Vec<u8> {
    let mut encoded = Vec::new();
    encoded.push(encode_policy_wire_byte(policy));
    encoded.push(0x00);
    encode_string(&mut encoded, "classic");
    encoded.push(0x00);
    encoded
}

fn validate_classic_policy(policy: &[u8]) -> Result<()> {
    let mut offset = 0usize;
    let require_pqc = *policy
        .get(offset)
        .ok_or_else(|| anyhow!("classic MessageA policy is empty"))?;
    offset += 1;
    if require_pqc != 0 {
        bail!("classic MessageA policy requires PQC");
    }
    let reserved = *policy
        .get(offset)
        .ok_or_else(|| anyhow!("classic MessageA policy is truncated"))?;
    offset += 1;
    if reserved != 0 {
        bail!("classic MessageA policy reserved byte must be zero");
    }
    let provider_length_bytes = read_exact(policy, &mut offset, 4)?;
    let provider_length = u32::from_le_bytes(
        provider_length_bytes
            .try_into()
            .map_err(|_| anyhow!("invalid classic policy provider length"))?,
    ) as usize;
    let provider = read_exact(policy, &mut offset, provider_length)?;
    if provider != b"classic" {
        bail!("classic MessageA policy provider mismatch");
    }
    let trailing = *policy
        .get(offset)
        .ok_or_else(|| anyhow!("classic MessageA policy missing trailing byte"))?;
    offset += 1;
    if trailing != 0 || offset != policy.len() {
        bail!("classic MessageA policy has invalid trailing data");
    }
    Ok(())
}

fn encode_identity_public_key(
    algorithm: ProtocolSigningAlgorithm,
    public_key: &[u8],
) -> Result<Vec<u8>> {
    let algorithm_byte = match algorithm {
        ProtocolSigningAlgorithm::Ed25519 => IDENTITY_ALGORITHM_ED25519,
        ProtocolSigningAlgorithm::MlDsa65 => IDENTITY_ALGORITHM_MLDSA65,
        ProtocolSigningAlgorithm::MlDsa87 => IDENTITY_ALGORITHM_MLDSA87,
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
        IDENTITY_ALGORITHM_MLDSA87 => ProtocolSigningAlgorithm::MlDsa87,
        IDENTITY_ALGORITHM_P256 => {
            bail!("p256 identities are not supported in the Rust classic handshake")
        }
        _ => bail!("unknown identity public key algorithm"),
    };
    let mut offset = 1usize;
    let key_len = read_u16_le(data, &mut offset)? as usize;
    let key_bytes = read_exact(data, &mut offset, key_len)?;
    let has_secure_enclave = *data
        .get(offset)
        .ok_or_else(|| anyhow!("missing secure enclave identity flag"))?;
    offset += 1;
    if has_secure_enclave != 0x00 {
        bail!("secure enclave identity keys are not supported in the Rust classic handshake");
    }
    if algorithm != ProtocolSigningAlgorithm::Ed25519 || key_len != 32 {
        bail!("unsupported identity public key length");
    }
    if offset != data.len() {
        bail!("unexpected trailing bytes in identity public key payload");
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

    let suite_wire_id = u16::from_le_bytes([data[5], data[6]]);
    if suite_wire_id != CLASSIC_SUITE_WIRE_ID {
        bail!("classic hpke sealed box suite mismatch");
    }
    if data[7] != 0 || data[8] != 0 {
        bail!("classic hpke sealed box reserved bytes must be zero");
    }

    let enc_len = u16::from_le_bytes([data[9], data[10]]) as usize;
    let nonce_len = data[11] as usize;
    let tag_len = data[12] as usize;
    let ciphertext_len = u32::from_le_bytes([data[13], data[14], data[15], data[16]]) as usize;
    let expected_enc_len = <<ClassicKem as KemTrait>::EncappedKey as Serializable>::size();
    if enc_len != expected_enc_len {
        bail!(
            "invalid classic hpke encapsulated key length: expected {expected_enc_len} bytes, got {enc_len}"
        );
    }
    match version {
        1 if nonce_len != 12 || tag_len != 16 => {
            bail!("classic hpke version 1 requires a 12-byte nonce and 16-byte tag")
        }
        2 if nonce_len != 0 || tag_len != 0 => {
            bail!("classic hpke version 2 must not carry an external nonce or tag")
        }
        _ => {}
    }
    if ciphertext_len == 0 {
        bail!("classic hpke ciphertext must not be empty");
    }
    let expected_len = 17usize
        .checked_add(enc_len)
        .and_then(|length| length.checked_add(nonce_len))
        .and_then(|length| length.checked_add(ciphertext_len))
        .and_then(|length| length.checked_add(tag_len))
        .ok_or_else(|| anyhow!("classic hpke sealed box length overflow"))?;
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

fn validate_classic_local_identity(
    binding: &ProtocolIdentityBinding,
    signing_secret_key: &[u8],
    role: &str,
) -> Result<()> {
    if binding.protocol_signing_algorithm != ProtocolSigningAlgorithm::Ed25519 {
        bail!("classic {role} handshake only supports Ed25519 identities");
    }
    let normalized_device_id = ProtocolIdentityBinding::normalized_device_id(&binding.device_id)
        .map_err(anyhow::Error::from)?;
    if normalized_device_id != binding.device_id {
        bail!("classic {role} device id is not canonical");
    }
    ProtocolIdentityBinding::validate_key_encoding(
        &binding.protocol_public_key_bytes,
        binding.protocol_signing_algorithm,
    )
    .map_err(anyhow::Error::from)?;
    if signing_secret_key.len() != 32 {
        bail!("Ed25519 signing secret key must be 32 bytes");
    }
    let signing_key = signing_key_from_bytes(signing_secret_key)?;
    if signing_key.verifying_key().to_bytes().as_slice()
        != binding.protocol_public_key_bytes.as_slice()
    {
        bail!("classic {role} signing key does not match the protocol identity binding");
    }
    let computed_fingerprint = ProtocolIdentityBinding::compute_fingerprint(
        binding.protocol_signing_algorithm,
        &binding.protocol_public_key_bytes,
    );
    if binding.protocol_public_key_fingerprint != computed_fingerprint {
        bail!("classic {role} protocol identity fingerprint mismatch");
    }
    Ok(())
}

fn signing_key_from_bytes(bytes: &[u8]) -> Result<SigningKey> {
    let secret: [u8; 32] = bytes
        .try_into()
        .map_err(|_| anyhow!("invalid ed25519 secret key length"))?;
    Ok(SigningKey::from_bytes(&secret))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn classic_identity(device_id: &str, seed: u8) -> Result<(ProtocolIdentityBinding, Vec<u8>)> {
        let signing_key = SigningKey::from_bytes(&[seed; 32]);
        let public_key = signing_key.verifying_key().to_bytes().to_vec();
        let binding = ProtocolIdentityBinding::new(
            device_id,
            ProtocolSigningAlgorithm::Ed25519,
            public_key,
            None,
        )?;
        Ok((binding, signing_key.to_bytes().to_vec()))
    }

    fn classic_handshake_pair() -> Result<(ClassicInitiatorHandshake, ClassicResponderHandshake)> {
        let (initiator_binding, initiator_secret) = classic_identity("device-classic-init", 0x11)?;
        let (responder_binding, responder_secret) = classic_identity("device-classic-resp", 0x22)?;
        Ok((
            ClassicInitiatorHandshake::new(ClassicInitiatorConfig {
                local_binding: initiator_binding,
                signing_secret_key: initiator_secret,
                local_device_name: Some("Classic Initiator".to_owned()),
                policy: DowngradePolicy::Default,
            })?,
            ClassicResponderHandshake::new(ClassicResponderConfig {
                local_binding: responder_binding,
                signing_secret_key: responder_secret,
                local_device_name: Some("Classic Responder".to_owned()),
                policy: DowngradePolicy::Default,
            })?,
        ))
    }

    fn complete_classic_handshake(
        initiator: &mut ClassicInitiatorHandshake,
        responder: &mut ClassicResponderHandshake,
    ) -> Result<(ClassicSessionKeys, ClassicSessionKeys)> {
        let message_a = initiator.start()?;
        let responder_actions = responder.handle_frame(&message_a)?;
        if responder_actions.outbound_frames.len() != 2 {
            bail!("classic responder did not emit MessageB and Finished");
        }
        let message_b_actions = initiator.handle_frame(&responder_actions.outbound_frames[0])?;
        if message_b_actions.established.is_some() {
            bail!("classic initiator established before responder Finished");
        }
        let initiator_actions = initiator.handle_frame(&responder_actions.outbound_frames[1])?;
        let initiator_keys = initiator_actions
            .established
            .ok_or_else(|| anyhow!("classic initiator did not establish"))?;
        let client_finished = initiator_actions
            .outbound_frames
            .first()
            .ok_or_else(|| anyhow!("classic initiator did not emit Finished"))?;
        let responder_actions = responder.handle_frame(client_finished)?;
        let responder_keys = responder_actions
            .established
            .ok_or_else(|| anyhow!("classic responder did not establish"))?;
        Ok((initiator_keys, responder_keys))
    }

    #[test]
    fn finished_round_trip_uses_expected_mac() -> Result<()> {
        let keys = ClassicSessionKeys {
            send_key: vec![0x11; 32],
            receive_key: vec![0x22; 32],
            negotiated_suite: CLASSIC_SUITE_NAME.to_owned(),
            peer_protocol_public_key_fingerprint: "test-peer-fingerprint".to_owned(),
            transcript_hash: vec![0x33; 32],
        };
        let encoded = encode_finished_frame(
            FinishedDirection::ResponderToInitiator,
            &keys.receive_key,
            &keys.transcript_hash,
        )?;
        let decoded = decode_finished_frame(&encoded)?;
        verify_finished(&keys, FinishedDirection::ResponderToInitiator, &decoded)?;
        Ok(())
    }

    #[test]
    fn classic_initiator_and_responder_round_trip_with_mirrored_keys_and_identities() -> Result<()>
    {
        let (mut initiator, mut responder) = classic_handshake_pair()?;
        let expected_initiator_fingerprint = initiator
            .config
            .local_binding
            .protocol_public_key_fingerprint
            .clone();
        let expected_responder_fingerprint = responder
            .config
            .local_binding
            .protocol_public_key_fingerprint
            .clone();
        let (initiator_keys, responder_keys) =
            complete_classic_handshake(&mut initiator, &mut responder)?;

        assert_eq!(initiator_keys.send_key, responder_keys.receive_key);
        assert_eq!(initiator_keys.receive_key, responder_keys.send_key);
        assert_eq!(
            initiator_keys.transcript_hash,
            responder_keys.transcript_hash
        );
        assert_eq!(
            initiator_keys.peer_protocol_public_key_fingerprint,
            expected_responder_fingerprint
        );
        assert_eq!(
            responder_keys.peer_protocol_public_key_fingerprint,
            expected_initiator_fingerprint
        );

        assert!(initiator.handle_frame(b"raw-app-frame").is_err());
        assert!(responder.handle_frame(b"raw-app-frame").is_err());
        Ok(())
    }

    #[test]
    fn classic_responder_rejects_tampered_message_a_signature() -> Result<()> {
        let (mut initiator, mut responder) = classic_handshake_pair()?;
        let mut message_a = initiator.start()?;
        let signature_byte = message_a
            .len()
            .checked_sub(3)
            .ok_or_else(|| anyhow!("MessageA too short for signature"))?;
        message_a[signature_byte] ^= 0x80;
        let error = responder
            .handle_frame(&message_a)
            .expect_err("tampered MessageA signature must fail closed");
        assert!(error.to_string().contains("signature verification failed"));
        Ok(())
    }

    #[test]
    fn classic_responder_rejects_invalid_suite_share_length_and_policy() -> Result<()> {
        let (mut initiator, _) = classic_handshake_pair()?;
        let message_a = initiator.start()?;

        let mut unknown_suite = message_a.clone();
        unknown_suite[3..5].copy_from_slice(&0xFFFF_u16.to_le_bytes());
        let (_, mut responder) = classic_handshake_pair()?;
        assert!(
            responder
                .handle_frame(&unknown_suite)
                .expect_err("unknown classic suite must fail closed")
                .to_string()
                .contains("unknown suite")
        );

        let mut invalid_share_length = message_a.clone();
        invalid_share_length[9..11].copy_from_slice(&31_u16.to_le_bytes());
        let (_, mut responder) = classic_handshake_pair()?;
        assert!(
            responder
                .handle_frame(&invalid_share_length)
                .expect_err("invalid classic key share length must fail closed")
                .to_string()
                .contains("key share length")
        );

        let capabilities_length = u16::from_le_bytes(message_a[75..77].try_into()?) as usize;
        let policy_length_offset = 77usize
            .checked_add(capabilities_length)
            .ok_or_else(|| anyhow!("classic capabilities length overflow"))?;
        let policy_offset = policy_length_offset
            .checked_add(2)
            .ok_or_else(|| anyhow!("classic policy offset overflow"))?;
        let mut pqc_required_policy = message_a;
        *pqc_required_policy
            .get_mut(policy_offset)
            .ok_or_else(|| anyhow!("classic policy byte missing"))? = 1;
        let (_, mut responder) = classic_handshake_pair()?;
        assert!(
            responder
                .handle_frame(&pqc_required_policy)
                .expect_err("classic MessageA requiring PQC must fail closed")
                .to_string()
                .contains("requires PQC")
        );
        Ok(())
    }

    #[test]
    fn classic_finished_tampering_fails_both_directions() -> Result<()> {
        let (mut initiator, mut responder) = classic_handshake_pair()?;
        let message_a = initiator.start()?;
        let responder_actions = responder.handle_frame(&message_a)?;
        let _ = initiator.handle_frame(&responder_actions.outbound_frames[0])?;
        let mut responder_finished = responder_actions.outbound_frames[1].clone();
        *responder_finished
            .last_mut()
            .ok_or_else(|| anyhow!("responder Finished is empty"))? ^= 0x01;
        let error = initiator
            .handle_frame(&responder_finished)
            .expect_err("tampered responder Finished must fail closed");
        assert!(
            error
                .to_string()
                .contains("Finished MAC verification failed")
        );

        let (mut initiator, mut responder) = classic_handshake_pair()?;
        let message_a = initiator.start()?;
        let responder_actions = responder.handle_frame(&message_a)?;
        let _ = initiator.handle_frame(&responder_actions.outbound_frames[0])?;
        let initiator_actions = initiator.handle_frame(&responder_actions.outbound_frames[1])?;
        let mut initiator_finished = initiator_actions.outbound_frames[0].clone();
        *initiator_finished
            .last_mut()
            .ok_or_else(|| anyhow!("initiator Finished is empty"))? ^= 0x01;
        let error = responder
            .handle_frame(&initiator_finished)
            .expect_err("tampered initiator Finished must fail closed");
        assert!(
            error
                .to_string()
                .contains("Finished MAC verification failed")
        );
        Ok(())
    }

    #[test]
    fn classic_message_b_does_not_authorize_app_traffic_before_finished() -> Result<()> {
        let (mut initiator, mut responder) = classic_handshake_pair()?;
        let message_a = initiator.start()?;
        let responder_actions = responder.handle_frame(&message_a)?;
        let message_b_actions = initiator.handle_frame(&responder_actions.outbound_frames[0])?;
        assert!(message_b_actions.established.is_none());
        assert!(message_b_actions.outbound_frames.is_empty());
        assert!(initiator.established_session_keys().is_none());
        assert!(responder.established_session_keys().is_none());
        assert!(initiator.handle_frame(b"pre-finished-app-control").is_err());
        assert!(responder.handle_frame(b"pre-finished-app-control").is_err());
        Ok(())
    }

    #[test]
    fn classic_responder_rejects_repeated_handshake_frames() -> Result<()> {
        let (mut initiator, mut responder) = classic_handshake_pair()?;
        let message_a = initiator.start()?;
        let responder_actions = responder.handle_frame(&message_a)?;
        assert!(responder.handle_frame(&message_a).is_err());
        let _ = initiator.handle_frame(&responder_actions.outbound_frames[0])?;
        let initiator_actions = initiator.handle_frame(&responder_actions.outbound_frames[1])?;
        responder.handle_frame(&initiator_actions.outbound_frames[0])?;
        assert!(
            responder
                .handle_frame(&initiator_actions.outbound_frames[0])
                .is_err()
        );
        assert!(responder.handle_frame(b"unknown-classic-frame").is_err());
        Ok(())
    }
}
