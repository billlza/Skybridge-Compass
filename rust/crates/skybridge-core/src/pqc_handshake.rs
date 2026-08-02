use std::collections::BTreeMap;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use anyhow::{Result, anyhow, bail};
use getrandom::fill as fill_random;
use hkdf::Hkdf;
use sha2::{Digest, Sha256};

use crate::handshake_finished::{
    FINISHED_I2R_INFO_PREFIX, FINISHED_R2I_INFO_PREFIX, derive_finished_mac, verify_finished_mac,
};
use crate::policy::{DowngradePolicy, encode_policy_wire_byte};
use crate::{
    ClassicHandleResult, ClassicSessionKeys, CryptoSuite, ProtocolIdentityBinding,
    ProtocolSigningAlgorithm, RustPqcIdentityMaterial, mldsa_secret_key_bytes, mldsa_sign_detached,
    mldsa_verify_detached, mlkem768_decapsulate, mlkem768_encapsulate, xwing_decapsulate,
    xwing_encapsulate,
};
#[cfg(feature = "q-periapt")]
use crate::{qperiapt_contextbound_decapsulate, qperiapt_contextbound_encapsulate};

pub use crate::handshake_app_frame::HeartbeatPayload;
use crate::handshake_wire::{
    append_u16_le, encode_string, encode_string_array, unwrap_handshake_padding,
};
use wire::{
    DecodedMessageA, DecodedMessageB, decode_identity_public_key, decode_message_a,
    decode_message_b, encode_hpke_sealed_box, encode_identity_public_key,
    message_b_encoded_without_signature,
};

mod wire;

const HANDSHAKE_VERSION: u8 = 1;
const HANDSHAKE_A_DOMAIN: &[u8] = b"SkyBridge-A";
const HANDSHAKE_B_DOMAIN: &[u8] = b"SkyBridge-B";
const FINISHED_MAGIC: &[u8; 4] = b"FIN1";
const KDF_COMPOSITION_LABEL: &[u8] = b"v1-single";
const HANDSHAKE_PAYLOAD_INFO: &[u8] = b"handshake-payload";

#[derive(Clone)]
pub struct PqcInitiatorConfig {
    pub local_binding: ProtocolIdentityBinding,
    pub signing_secret_key: Vec<u8>,
    pub local_device_name: Option<String>,
    pub preferred_suites: Vec<CryptoSuite>,
    pub peer_kem_public_keys: BTreeMap<CryptoSuite, Vec<u8>>,
    /// Downgrade posture advertised on the wire (governs the policy byte) and
    /// consulted locally before any PQC -> Classic fallback. Defaults to
    /// [`DowngradePolicy::PreferPqc`].
    pub policy: DowngradePolicy,
}

impl std::fmt::Debug for PqcInitiatorConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PqcInitiatorConfig")
            .field(
                "local_signing_algorithm",
                &self.local_binding.protocol_signing_algorithm,
            )
            .field("signing_secret_key", &"<redacted>")
            .field(
                "local_device_name_present",
                &self.local_device_name.is_some(),
            )
            .field("preferred_suites", &self.preferred_suites)
            .field(
                "peer_kem_public_key_suites",
                &self.peer_kem_public_keys.keys().collect::<Vec<_>>(),
            )
            .field("policy", &self.policy)
            .finish()
    }
}

#[derive(Clone)]
pub struct PqcResponderConfig {
    pub local_binding: ProtocolIdentityBinding,
    pub local_device_name: Option<String>,
    pub identity: RustPqcIdentityMaterial,
    pub supported_suites: Vec<CryptoSuite>,
    /// Downgrade posture this responder enforces. Defaults to
    /// [`DowngradePolicy::PreferPqc`].
    pub policy: DowngradePolicy,
}

impl std::fmt::Debug for PqcResponderConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PqcResponderConfig")
            .field(
                "local_signing_algorithm",
                &self.local_binding.protocol_signing_algorithm,
            )
            .field(
                "local_device_name_present",
                &self.local_device_name.is_some(),
            )
            .field("identity", &self.identity)
            .field("supported_suites", &self.supported_suites)
            .field("policy", &self.policy)
            .finish()
    }
}

#[derive(Clone)]
pub struct PqcInitiatorHandshake {
    config: PqcInitiatorConfig,
    state: PqcInitiatorState,
}

impl std::fmt::Debug for PqcInitiatorHandshake {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let state = match &self.state {
            PqcInitiatorState::Idle => "idle",
            PqcInitiatorState::WaitingForMessageB(_) => "waiting_for_message_b",
            PqcInitiatorState::WaitingForFinished(_) => "waiting_for_finished",
            PqcInitiatorState::Established(_) => "established",
        };
        formatter
            .debug_struct("PqcInitiatorHandshake")
            .field(
                "local_signing_algorithm",
                &self.config.local_binding.protocol_signing_algorithm,
            )
            .field("state", &state)
            .finish()
    }
}

#[derive(Clone)]
pub struct PqcResponderHandshake {
    config: PqcResponderConfig,
    state: PqcResponderState,
}

impl std::fmt::Debug for PqcResponderHandshake {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let state = match &self.state {
            PqcResponderState::Idle => "idle",
            PqcResponderState::WaitingForFinished(_) => "waiting_for_finished",
            PqcResponderState::Established(_) => "established",
        };
        formatter
            .debug_struct("PqcResponderHandshake")
            .field(
                "local_signing_algorithm",
                &self.config.local_binding.protocol_signing_algorithm,
            )
            .field("state", &state)
            .finish()
    }
}

#[derive(Clone)]
enum PqcInitiatorState {
    Idle,
    WaitingForMessageB(WaitingForMessageBState),
    WaitingForFinished(WaitingForFinishedState),
    Established(ClassicSessionKeys),
}

#[derive(Clone)]
enum PqcResponderState {
    Idle,
    WaitingForFinished(WaitingForFinishedState),
    Established(ClassicSessionKeys),
}

#[derive(Clone)]
struct WaitingForMessageBState {
    offered_suites: Vec<CryptoSuite>,
    shared_secret_by_suite: BTreeMap<CryptoSuite, Vec<u8>>,
    client_nonce: [u8; 32],
    transcript_hash_a: [u8; 32],
    pending_finished: Option<FinishedFrame>,
}

#[derive(Clone)]
struct WaitingForFinishedState {
    session_keys: ClassicSessionKeys,
}

#[derive(Clone)]
struct FinishedFrame {
    direction: FinishedDirection,
    mac: [u8; 32],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FinishedDirection {
    ResponderToInitiator,
    InitiatorToResponder,
}

impl PqcInitiatorHandshake {
    pub fn new(config: PqcInitiatorConfig) -> Result<Self> {
        let signing_algorithm = config.local_binding.protocol_signing_algorithm;
        if !signing_algorithm.is_ml_dsa() {
            bail!("pqc initiator handshake requires an ML-DSA protocol identity");
        }
        let expected_secret_key_bytes = mldsa_secret_key_bytes(signing_algorithm)
            .ok_or_else(|| anyhow!("unsupported PQC signing algorithm {signing_algorithm}"))?;
        if config.signing_secret_key.len() != expected_secret_key_bytes {
            bail!(
                "invalid {signing_algorithm} signing secret key length: expected {expected_secret_key_bytes} bytes, got {}",
                config.signing_secret_key.len()
            );
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
                #[cfg(feature = "q-periapt")]
                0x0011 => qperiapt_contextbound_encapsulate(peer_public_key)?,
                _ => bail!("unsupported PQC initiator suite {}", suite),
            };
            key_shares.push((*suite, key_share));
            shared_secret_by_suite.insert(*suite, shared_secret);
        }

        let mut client_nonce = [0u8; 32];
        fill_random(&mut client_nonce)?;

        let signing_algorithm = self.config.local_binding.protocol_signing_algorithm;
        let capabilities = pqc_capabilities_bytes(&offered_suites, signing_algorithm);
        let policy = pqc_policy_bytes(self.config.policy);
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
        let signature = mldsa_sign_detached(
            signing_algorithm,
            &preimage,
            &self.config.signing_secret_key,
        )?;
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
                let pending_finished = waiting.pending_finished.clone();
                self.state = PqcInitiatorState::WaitingForFinished(WaitingForFinishedState {
                    session_keys: keys,
                });
                if let Some(pending_finished) = pending_finished {
                    return self.handle_finished(pending_finished);
                }
                Ok(ClassicHandleResult::default())
            }
            PqcInitiatorState::WaitingForFinished(_) => {
                bail!("unexpected non-Finished frame while waiting for PQC Finished")
            }
            PqcInitiatorState::Established(_) => {
                bail!("unexpected frame after PQC handshake establishment")
            }
            PqcInitiatorState::Idle => bail!("received frame before PQC handshake started"),
        }
    }

    pub fn established_session_keys(&self) -> Option<&ClassicSessionKeys> {
        match &self.state {
            PqcInitiatorState::Established(keys) => Some(keys),
            PqcInitiatorState::Idle
            | PqcInitiatorState::WaitingForMessageB(_)
            | PqcInitiatorState::WaitingForFinished(_) => None,
        }
    }

    fn handle_finished(&mut self, finished: FinishedFrame) -> Result<ClassicHandleResult> {
        match &mut self.state {
            PqcInitiatorState::WaitingForMessageB(waiting) => {
                if waiting.pending_finished.is_some() {
                    bail!("duplicate responder Finished before MessageB");
                }
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
                })
            }
            PqcInitiatorState::Established(_) => bail!("duplicate responder Finished"),
            PqcInitiatorState::Idle => bail!("received Finished before PQC handshake started"),
        }
    }

    /// The active downgrade posture for this initiator.
    pub fn policy(&self) -> DowngradePolicy {
        self.config.policy
    }

    /// Decide — *locally, before sending any Classic MessageA* — whether this
    /// failed PQC attempt may downgrade to a Classic handshake with `peer`.
    ///
    /// This is the portable realization of the Swift `attemptFallback` gate
    /// (`TwoAttemptHandshakeManager`). It is the single authority a caller (agent /
    /// CLI orchestrator) must consult before constructing a
    /// [`crate::classic_handshake::ClassicInitiatorHandshake`] in response to a PQC
    /// failure. Because the decision is taken here, on the initiator, off the wire,
    /// a remote attacker cannot induce the downgrade.
    ///
    /// On authorization the returned [`crate::policy::DowngradeDecision::Allowed`]
    /// carries a structured, serde-serializable [`crate::policy::DowngradeEvent`]
    /// anchored to this handshake's MessageA transcript — the replayable audit
    /// record. Denials (BLOCKED reason / strict policy / rate limit) are typed and
    /// carry no event.
    ///
    /// `to_suite` is the Classic suite the caller would downgrade to (typically
    /// [`CryptoSuite::X25519_ED25519`]).
    pub fn authorize_classic_fallback(
        &self,
        gate: &mut crate::policy::PolicyGate,
        peer: &str,
        reason: crate::policy::FallbackReason,
        to_suite: CryptoSuite,
    ) -> crate::policy::DowngradeDecision {
        // `from_suite`: the PQC suite we attempted (the first/preferred offered
        // suite this initiator was configured with).
        let from_suite = self
            .config
            .preferred_suites
            .iter()
            .copied()
            .find(|suite| suite.is_pqc())
            .unwrap_or(CryptoSuite::MLKEM768_MLDSA65);
        // Bind the audit record to this handshake's MessageA transcript when known.
        let transcript_anchor = match &self.state {
            PqcInitiatorState::WaitingForMessageB(waiting) => Some(waiting.transcript_hash_a),
            _ => None,
        };
        gate.authorize_downgrade(
            peer,
            from_suite,
            to_suite,
            reason,
            transcript_anchor.as_ref().map(|hash| hash.as_slice()),
        )
    }
}

impl PqcResponderHandshake {
    pub fn new(config: PqcResponderConfig) -> Result<Self> {
        let signing_algorithm = config.local_binding.protocol_signing_algorithm;
        if !signing_algorithm.is_ml_dsa() {
            bail!("pqc responder handshake requires an ML-DSA protocol identity");
        }
        if config.identity.signing_algorithm != signing_algorithm {
            bail!(
                "pqc responder identity algorithm {} does not match local binding {signing_algorithm}",
                config.identity.signing_algorithm
            );
        }
        let expected_secret_key_bytes = mldsa_secret_key_bytes(signing_algorithm)
            .ok_or_else(|| anyhow!("unsupported PQC signing algorithm {signing_algorithm}"))?;
        if config.identity.signing_secret_key.len() != expected_secret_key_bytes {
            bail!(
                "invalid {signing_algorithm} responder signing secret key length: expected {expected_secret_key_bytes} bytes, got {}",
                config.identity.signing_secret_key.len()
            );
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
            PqcResponderState::WaitingForFinished(_) => {
                bail!("unexpected non-Finished frame while waiting for initiator Finished")
            }
            PqcResponderState::Established(_) => {
                bail!("unexpected frame after PQC responder handshake establishment")
            }
        }
    }

    pub fn established_session_keys(&self) -> Option<&ClassicSessionKeys> {
        match &self.state {
            PqcResponderState::Established(keys) => Some(keys),
            PqcResponderState::Idle | PqcResponderState::WaitingForFinished(_) => None,
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
                    ..Default::default()
                })
            }
            PqcResponderState::Established(_) => bail!("duplicate initiator Finished"),
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
    mldsa_verify_detached(
        identity.algorithm,
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
    let peer_protocol_public_key_fingerprint =
        ProtocolIdentityBinding::compute_fingerprint(identity.algorithm, &identity.public_key);
    derive_session_keys(
        suite,
        KDF_COMPOSITION_LABEL,
        shared_secret,
        SessionKeyDerivationContext {
            client_nonce: &waiting.client_nonce,
            server_nonce: &message_b.server_nonce,
            transcript_hash_a: &waiting.transcript_hash_a,
            transcript_hash_b: transcript_hash_b.as_ref(),
            peer_protocol_public_key_fingerprint,
        },
    )
}

fn build_responder_message_b_and_keys(
    config: &PqcResponderConfig,
    message_a: &DecodedMessageA,
) -> Result<(Vec<u8>, ClassicSessionKeys)> {
    // Policy gate (responder side): a strict-PQC responder MUST NOT continue if the
    // initiator advertises a non-PQC-mandatory posture on the wire while we require
    // PQC. This is the responder's structural refusal of an induced downgrade; it
    // is intentionally NOT a fallback (PQC has no classic path on this wire), so it
    // emits a typed failure rather than a DowngradeEvent.
    if config.policy.requires_pqc() && !message_a.initiator_requires_pqc {
        // Surfaced honestly: the responder enforces PQC; it does not silently
        // downgrade. (PreferPqc tolerates this for interop; only the strict modes
        // hard-refuse.)
        if !config.policy.allows_classic_business_fallback()
            && !config.policy.allows_bootstrap_control_channel()
        {
            bail!(
                "strict-PQC responder policy refuses peer advertising a non-PQC posture \
                 (no classic fallback path)"
            );
        }
    }

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
        #[cfg(feature = "q-periapt")]
        0x0011 => qperiapt_contextbound_decapsulate(
            selected_key_share,
            &config.identity.qperiapt_secret_key,
        )?,
        _ => bail!("unsupported PQC responder suite {}", selected_suite),
    };

    let mut server_nonce = [0u8; 32];
    fill_random(&mut server_nonce)?;
    let signing_algorithm = config.identity.signing_algorithm;
    let payload_plaintext = pqc_capabilities_bytes(&[selected_suite], signing_algorithm);
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
    let responder_identity_public_key =
        encode_identity_public_key(signing_algorithm, &config.identity.signing_public_key)?;
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
    let signature = mldsa_sign_detached(
        signing_algorithm,
        &message_b_preimage,
        &config.identity.signing_secret_key,
    )?;

    let mut message_b = message_b_unsigned.clone();
    append_u16_le(&mut message_b, signature.len() as u16);
    message_b.extend_from_slice(&signature);
    append_u16_le(&mut message_b, 0);

    let transcript_hash_b = Sha256::digest(&message_b_unsigned);
    let peer_protocol_public_key_fingerprint = ProtocolIdentityBinding::compute_fingerprint(
        message_a.initiator_identity_algorithm,
        &message_a.initiator_identity_public_key,
    );
    let responder_session_keys = derive_responder_session_keys(
        selected_suite,
        &shared_secret,
        &message_a.client_nonce,
        &server_nonce,
        &message_a.transcript_hash_a,
        transcript_hash_b.as_ref(),
        peer_protocol_public_key_fingerprint,
    )?;
    Ok((message_b, responder_session_keys))
}

fn pqc_capabilities_bytes(
    offered_suites: &[CryptoSuite],
    signing_algorithm: ProtocolSigningAlgorithm,
) -> Vec<u8> {
    let mut kem_algorithms = Vec::new();
    if offered_suites.iter().any(|suite| suite.wire_id == 0x0001) {
        kem_algorithms.push("X-Wing");
    }
    #[cfg(feature = "q-periapt")]
    if offered_suites.iter().any(|suite| suite.wire_id == 0x0011) {
        kem_algorithms.push("Q-Periapt-ContextBound");
    }
    if offered_suites
        .iter()
        .any(|suite| suite.canonical_kem_suite().wire_id == 0x0101)
    {
        kem_algorithms.push("ML-KEM-768");
    }

    let mut encoded = Vec::new();
    encode_string_array(&mut encoded, &kem_algorithms);
    encode_string_array(&mut encoded, &[signing_algorithm.as_str()]);
    encode_string_array(&mut encoded, &["PQC"]);
    encode_string_array(&mut encoded, &["AES-256-GCM", "ChaCha20-Poly1305"]);
    encoded.push(0x01);
    encode_string(&mut encoded, std::env::consts::OS);
    // Cross-platform provider-token: kept as the fixed wire string "liboqs" for
    // interop with existing Swift/Apple peers that match on this token. The actual
    // Rust PQC backend is the pure-Rust FIPS 203/204 provider (see
    // PQC_PROVIDER_BACKEND below), NOT
    // liboqs; the on-wire token is a compatibility tag, not a truthful claim about
    // this implementation.
    encode_string(&mut encoded, PQC_PROVIDER_WIRE_TOKEN);
    encoded
}

/// On-wire provider compatibility token. Existing peers match on the literal
/// string "liboqs"/"liboqsPQC"; this implementation's true backend is
/// [`PQC_PROVIDER_BACKEND`].
const PQC_PROVIDER_WIRE_TOKEN: &str = "liboqs";
/// On-wire policy provider compatibility token (see [`PQC_PROVIDER_WIRE_TOKEN`]).
const PQC_POLICY_PROVIDER_WIRE_TOKEN: &str = "liboqsPQC";
/// The accurate, honest name of the pure-Rust FIPS 203/204 backend.
/// Surfaced for diagnostics; not sent on the wire to preserve interop.
pub const PQC_PROVIDER_BACKEND: &str = "fips203/fips204";

/// Encode the MessageA policy block.
///
/// Wire format is unchanged from the legacy `pqc_policy_bytes()`:
/// `[requirePQC: u8][reserved: u8][provider-token: len-prefixed str][trailing: u8]`.
/// The first byte (`requirePQC`) is now *derived from the active
/// [`DowngradePolicy`]* via [`encode_policy_wire_byte`] instead of being a hardcoded
/// literal, so the policy layer actually governs what goes on the wire. For
/// `DowngradePolicy::PreferPqc` (the default) it emits `0x01`, byte-identical to
/// the previous static output, preserving compatibility with existing peers.
fn pqc_policy_bytes(policy: DowngradePolicy) -> Vec<u8> {
    let mut encoded = Vec::new();
    encoded.push(encode_policy_wire_byte(policy));
    encoded.push(0x00);
    encode_string(&mut encoded, PQC_POLICY_PROVIDER_WIRE_TOKEN);
    encoded.push(0x00);
    encoded
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
    let nonce = Nonce::try_from(nonce)
        .map_err(|_| anyhow!("invalid PQC MessageB payload nonce length"))?;
    let mut combined = ciphertext.to_vec();
    combined.extend_from_slice(tag);
    cipher
        .decrypt(&nonce, combined.as_ref())
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
        .encrypt(&Nonce::from(nonce_bytes), plaintext)
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

struct SessionKeyDerivationContext<'a> {
    client_nonce: &'a [u8; 32],
    server_nonce: &'a [u8; 32],
    transcript_hash_a: &'a [u8; 32],
    transcript_hash_b: &'a [u8],
    peer_protocol_public_key_fingerprint: String,
}

fn derive_session_keys(
    suite: CryptoSuite,
    composition_label: &[u8],
    shared_secret: &[u8],
    context: SessionKeyDerivationContext<'_>,
) -> Result<ClassicSessionKeys> {
    let mut kdf_info = Vec::from(b"SkyBridge-KDF".as_slice());
    kdf_info.push(0x01);
    append_u16_le(&mut kdf_info, suite.wire_id);
    kdf_info.extend_from_slice(composition_label);
    kdf_info.extend_from_slice(context.transcript_hash_a);
    kdf_info.extend_from_slice(context.transcript_hash_b);
    kdf_info.extend_from_slice(context.client_nonce);
    kdf_info.extend_from_slice(context.server_nonce);

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
    transcript_input.extend_from_slice(context.transcript_hash_a);
    transcript_input.extend_from_slice(context.transcript_hash_b);
    let transcript_hash = Sha256::digest(&transcript_input);

    Ok(ClassicSessionKeys {
        send_key: send_key.to_vec(),
        receive_key: receive_key.to_vec(),
        negotiated_suite: suite.to_string(),
        peer_protocol_public_key_fingerprint: context.peer_protocol_public_key_fingerprint,
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
    peer_protocol_public_key_fingerprint: String,
) -> Result<ClassicSessionKeys> {
    let mut keys = derive_session_keys(
        suite,
        KDF_COMPOSITION_LABEL,
        shared_secret,
        SessionKeyDerivationContext {
            client_nonce,
            server_nonce,
            transcript_hash_a,
            transcript_hash_b,
            peer_protocol_public_key_fingerprint,
        },
    )?;
    std::mem::swap(&mut keys.send_key, &mut keys.receive_key);
    Ok(keys)
}

fn encode_finished_frame(
    direction: FinishedDirection,
    mac_key: &[u8],
    transcript_hash: &[u8],
) -> Result<Vec<u8>> {
    let info_prefix = match direction {
        FinishedDirection::ResponderToInitiator => FINISHED_R2I_INFO_PREFIX,
        FinishedDirection::InitiatorToResponder => FINISHED_I2R_INFO_PREFIX,
    };
    let mac = derive_finished_mac(mac_key, info_prefix, transcript_hash)?;
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
    let info_prefix = match expected_direction {
        FinishedDirection::ResponderToInitiator => FINISHED_R2I_INFO_PREFIX,
        FinishedDirection::InitiatorToResponder => FINISHED_I2R_INFO_PREFIX,
    };
    if !verify_finished_mac(
        &session_keys.receive_key,
        info_prefix,
        &session_keys.transcript_hash,
        &frame.mac,
    )? {
        bail!("Finished MAC verification failed");
    }
    Ok(())
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

    fn mlkem768_handshake_pair() -> Result<(PqcInitiatorHandshake, PqcResponderHandshake)> {
        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;
        let initiator = PqcInitiatorHandshake::new(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-finished-init",
                initiator_identity.signing_algorithm,
                initiator_identity.signing_public_key.clone(),
                None,
            )?,
            signing_secret_key: initiator_identity.signing_secret_key,
            local_device_name: Some("Rust PQC Initiator".to_owned()),
            preferred_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::MLKEM768_MLDSA65,
                responder_identity.mlkem768_public_key.clone(),
            )]),
            policy: DowngradePolicy::PreferPqc,
        })?;
        let responder = PqcResponderHandshake::new(PqcResponderConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-finished-resp",
                responder_identity.signing_algorithm,
                responder_identity.signing_public_key.clone(),
                None,
            )?,
            local_device_name: Some("Rust PQC Responder".to_owned()),
            identity: responder_identity,
            supported_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            policy: DowngradePolicy::PreferPqc,
        })?;
        Ok((initiator, responder))
    }

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
            local_binding: local_binding.clone(),
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: Some("Rust PQC Agent".to_owned()),
            preferred_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::MLKEM768_MLDSA65,
                responder_identity.mlkem768_public_key.clone(),
            )]),
            policy: DowngradePolicy::PreferPqc,
        })?;

        let message_a = handshake.start()?;
        let responder_binding = ProtocolIdentityBinding::new(
            "device-fedcba0987654321",
            responder_identity.signing_algorithm,
            responder_identity.signing_public_key.clone(),
            None,
        )?;
        let expected_initiator_fingerprint = local_binding.protocol_public_key_fingerprint.clone();
        let expected_responder_fingerprint =
            responder_binding.protocol_public_key_fingerprint.clone();
        let responder_message_a = decode_message_a(&message_a)?;
        let (message_b, responder_keys) = build_responder_message_b_and_keys(
            &PqcResponderConfig {
                local_binding: responder_binding,
                local_device_name: Some("Rust PQC Responder".to_owned()),
                identity: responder_identity,
                supported_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
                policy: DowngradePolicy::PreferPqc,
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
        assert_eq!(
            established.peer_protocol_public_key_fingerprint,
            expected_responder_fingerprint
        );
        assert_eq!(
            responder_keys.peer_protocol_public_key_fingerprint,
            expected_initiator_fingerprint
        );
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
            policy: DowngradePolicy::PreferPqc,
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
                policy: DowngradePolicy::PreferPqc,
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
            policy: DowngradePolicy::PreferPqc,
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
            policy: DowngradePolicy::PreferPqc,
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
        assert!(
            initiator
                .handle_frame(b"unknown-established-frame")
                .is_err(),
            "PQC initiator must fail closed on unknown established frames"
        );
        assert!(
            responder
                .handle_frame(b"unknown-established-frame")
                .is_err(),
            "PQC responder must fail closed on unknown established frames"
        );
        Ok(())
    }

    #[test]
    fn pqc_finished_tampering_fails_both_directions() -> Result<()> {
        let (mut initiator, mut responder) = mlkem768_handshake_pair()?;
        let message_a = initiator.start()?;
        let responder_actions = responder.handle_frame(&message_a)?;
        let message_b = &responder_actions.outbound_frames[0];
        let responder_finished = &responder_actions.outbound_frames[1];
        let _ = initiator.handle_frame(message_b)?;

        let mut tampered_responder_finished = responder_finished.clone();
        *tampered_responder_finished
            .last_mut()
            .ok_or_else(|| anyhow!("responder Finished is empty"))? ^= 0x01;
        let error = initiator
            .handle_frame(&tampered_responder_finished)
            .expect_err("tampered responder Finished must fail closed");
        assert!(
            error
                .to_string()
                .contains("Finished MAC verification failed")
        );

        let initiator_actions = initiator.handle_frame(responder_finished)?;
        let initiator_finished = &initiator_actions.outbound_frames[0];
        let mut tampered_initiator_finished = initiator_finished.clone();
        *tampered_initiator_finished
            .last_mut()
            .ok_or_else(|| anyhow!("initiator Finished is empty"))? ^= 0x01;
        let error = responder
            .handle_frame(&tampered_initiator_finished)
            .expect_err("tampered initiator Finished must fail closed");
        assert!(
            error
                .to_string()
                .contains("Finished MAC verification failed")
        );
        assert!(
            responder
                .handle_frame(initiator_finished)?
                .established
                .is_some()
        );
        Ok(())
    }

    #[test]
    fn pqc_message_b_does_not_authorize_app_traffic_before_finished() -> Result<()> {
        let (mut initiator, mut responder) = mlkem768_handshake_pair()?;
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
    fn pqc_established_states_reject_duplicate_finished_in_both_directions() -> Result<()> {
        let (mut initiator, mut responder) = mlkem768_handshake_pair()?;
        let message_a = initiator.start()?;
        let responder_actions = responder.handle_frame(&message_a)?;
        let responder_finished = responder_actions.outbound_frames[1].clone();
        let _ = initiator.handle_frame(&responder_actions.outbound_frames[0])?;
        let initiator_actions = initiator.handle_frame(&responder_finished)?;
        let initiator_finished = initiator_actions.outbound_frames[0].clone();
        assert!(
            responder
                .handle_frame(&initiator_finished)?
                .established
                .is_some()
        );

        let initiator_error = initiator
            .handle_frame(&responder_finished)
            .expect_err("established initiator must reject duplicate responder Finished");
        assert_eq!(initiator_error.to_string(), "duplicate responder Finished");

        let responder_error = responder
            .handle_frame(&initiator_finished)
            .expect_err("established responder must reject duplicate initiator Finished");
        assert_eq!(responder_error.to_string(), "duplicate initiator Finished");
        Ok(())
    }

    #[test]
    fn pqc_rejects_duplicate_responder_finished_before_message_b() -> Result<()> {
        let (mut initiator, mut responder) = mlkem768_handshake_pair()?;
        let message_a = initiator.start()?;
        let responder_actions = responder.handle_frame(&message_a)?;
        let responder_finished = &responder_actions.outbound_frames[1];

        assert!(
            initiator
                .handle_frame(responder_finished)?
                .established
                .is_none()
        );
        let error = initiator
            .handle_frame(responder_finished)
            .expect_err("duplicate responder Finished before MessageB must fail closed");
        assert_eq!(
            error.to_string(),
            "duplicate responder Finished before MessageB"
        );
        Ok(())
    }

    #[test]
    fn mldsa87_identity_round_trips_full_pqc_handshake_without_fallback() -> Result<()> {
        let initiator_identity =
            RustPqcIdentityMaterial::generate_for_algorithm(ProtocolSigningAlgorithm::MlDsa87)?;
        let responder_identity =
            RustPqcIdentityMaterial::generate_for_algorithm(ProtocolSigningAlgorithm::MlDsa87)?;
        let mut initiator = PqcInitiatorHandshake::new(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-mldsa87-init",
                initiator_identity.signing_algorithm,
                initiator_identity.signing_public_key.clone(),
                None,
            )?,
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: Some("Rust ML-DSA-87 Initiator".to_owned()),
            preferred_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::MLKEM768_MLDSA65,
                responder_identity.mlkem768_public_key.clone(),
            )]),
            policy: DowngradePolicy::StrictPqcCompliance,
        })?;
        let mut responder = PqcResponderHandshake::new(PqcResponderConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-mldsa87-resp",
                responder_identity.signing_algorithm,
                responder_identity.signing_public_key.clone(),
                None,
            )?,
            local_device_name: Some("Rust ML-DSA-87 Responder".to_owned()),
            identity: responder_identity,
            supported_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            policy: DowngradePolicy::StrictPqcCompliance,
        })?;

        let message_a = initiator.start()?;
        assert!(message_a.len() > 8 * 1_024);

        let responder_actions = responder.handle_frame(&message_a)?;
        assert_eq!(responder_actions.outbound_frames.len(), 2);
        let message_b = &responder_actions.outbound_frames[0];
        assert!(message_b.len() > 7 * 1_024);
        let message_b_identity =
            decode_identity_public_key(&decode_message_b(message_b)?.identity_public_key)?;
        assert_eq!(
            message_b_identity.algorithm,
            ProtocolSigningAlgorithm::MlDsa87
        );

        let _ = initiator.handle_frame(message_b)?;
        let initiator_actions = initiator.handle_frame(&responder_actions.outbound_frames[1])?;
        assert!(initiator_actions.established.is_some());
        let responder_finish = responder.handle_frame(&initiator_actions.outbound_frames[0])?;
        assert!(responder_finish.established.is_some());
        Ok(())
    }

    #[test]
    fn rust_pqc_rejects_unverifiable_secure_enclave_proof_instead_of_ignoring_it() -> Result<()> {
        let initiator_identity =
            RustPqcIdentityMaterial::generate_for_algorithm(ProtocolSigningAlgorithm::MlDsa87)?;
        let responder_identity =
            RustPqcIdentityMaterial::generate_for_algorithm(ProtocolSigningAlgorithm::MlDsa87)?;
        let mut initiator = PqcInitiatorHandshake::new(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-se-proof-init",
                initiator_identity.signing_algorithm,
                initiator_identity.signing_public_key.clone(),
                None,
            )?,
            signing_secret_key: initiator_identity.signing_secret_key,
            local_device_name: None,
            preferred_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::MLKEM768_MLDSA65,
                responder_identity.mlkem768_public_key,
            )]),
            policy: DowngradePolicy::StrictPqcCompliance,
        })?;
        let mut message_a = initiator.start()?;
        let se_length_offset = message_a
            .len()
            .checked_sub(2)
            .ok_or_else(|| anyhow!("MessageA missing SE signature length"))?;
        message_a[se_length_offset..].copy_from_slice(&1_u16.to_le_bytes());
        message_a.push(0x01);

        let error = decode_message_a(&message_a)
            .expect_err("unverifiable Secure Enclave proof must fail closed")
            .to_string();
        assert!(error.contains("Secure Enclave proof signatures are not supported"));
        Ok(())
    }

    #[test]
    fn mldsa87_identity_wire_rejects_trailing_bytes() -> Result<()> {
        let identity =
            RustPqcIdentityMaterial::generate_for_algorithm(ProtocolSigningAlgorithm::MlDsa87)?;
        let mut encoded =
            encode_identity_public_key(identity.signing_algorithm, &identity.signing_public_key)?;
        encoded.push(0x00);
        assert!(decode_identity_public_key(&encoded).is_err());
        Ok(())
    }

    /// EXPERIMENTAL, DEFAULT-OFF (`q-periapt` feature): drive the REAL initiator
    /// and responder state machines end-to-end with the Q-Periapt ContextBound
    /// suite (0x0011). Assert both sides derive identical, mirrored session keys
    /// and that a real AES-256-GCM application message (a ping) round-trips
    /// through the established channel.
    #[cfg(feature = "q-periapt")]
    #[test]
    fn qperiapt_contextbound_real_handshake_round_trips_and_aead_round_trips() -> Result<()> {
        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;

        let mut initiator = PqcInitiatorHandshake::new(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-qperiapt-inittr",
                initiator_identity.signing_algorithm,
                initiator_identity.signing_public_key.clone(),
                None,
            )?,
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: Some("Rust Q-Periapt Initiator".to_owned()),
            preferred_suites: vec![CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65,
                responder_identity.qperiapt_public_key.clone(),
            )]),
            policy: DowngradePolicy::PreferPqc,
        })?;
        let mut responder = PqcResponderHandshake::new(PqcResponderConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-qperiapt-respnd",
                responder_identity.signing_algorithm,
                responder_identity.signing_public_key.clone(),
                None,
            )?,
            local_device_name: Some("Rust Q-Periapt Responder".to_owned()),
            identity: responder_identity,
            supported_suites: vec![CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65],
            policy: DowngradePolicy::PreferPqc,
        })?;

        // Real MessageA -> (MessageB + responder Finished) -> initiator Finished.
        let message_a = initiator.start()?;
        let responder_actions = responder.handle_frame(&message_a)?;
        assert_eq!(responder_actions.outbound_frames.len(), 2);

        let _ = initiator.handle_frame(&responder_actions.outbound_frames[0])?;
        let initiator_actions = initiator.handle_frame(&responder_actions.outbound_frames[1])?;
        assert!(initiator_actions.established.is_some());
        assert_eq!(initiator_actions.outbound_frames.len(), 1);

        let responder_finish = responder.handle_frame(&initiator_actions.outbound_frames[0])?;
        assert!(responder_finish.established.is_some());

        // Both sides derived identical, mirrored directional keys over the
        // Q-Periapt ContextBound shared secret.
        let initiator_keys = initiator
            .established_session_keys()
            .ok_or_else(|| anyhow!("expected initiator keys"))?;
        let responder_keys = responder
            .established_session_keys()
            .ok_or_else(|| anyhow!("expected responder keys"))?;
        assert_eq!(initiator_keys.send_key, responder_keys.receive_key);
        assert_eq!(initiator_keys.receive_key, responder_keys.send_key);
        assert_eq!(responder_keys.negotiated_suite, "Q-Periapt-ContextBound");

        assert!(initiator.handle_frame(b"raw-app-frame").is_err());
        assert!(responder.handle_frame(b"raw-app-frame").is_err());
        Ok(())
    }

    /// Realistic multi-suite negotiation: the responder advertises the agent's real suite set
    /// (X-Wing, ML-KEM-768, AND Q-Periapt ContextBound). When the initiator prefers Q-Periapt,
    /// the real handshake must negotiate it and complete — proving the agent's `supported_suites`
    /// reaches Q-Periapt end to end, not just a forced single-suite pairing.
    #[cfg(feature = "q-periapt")]
    #[test]
    fn qperiapt_negotiated_from_realistic_multi_suite_responder() -> Result<()> {
        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;

        let mut initiator = PqcInitiatorHandshake::new(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-qperiapt-neg-init",
                initiator_identity.signing_algorithm,
                initiator_identity.signing_public_key.clone(),
                None,
            )?,
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: Some("Rust Q-Periapt Initiator (neg)".to_owned()),
            preferred_suites: vec![CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65,
                responder_identity.qperiapt_public_key.clone(),
            )]),
            policy: DowngradePolicy::PreferPqc,
        })?;
        // The responder advertises the agent's real suite set, Q-Periapt included.
        let mut responder = PqcResponderHandshake::new(PqcResponderConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-qperiapt-neg-resp",
                responder_identity.signing_algorithm,
                responder_identity.signing_public_key.clone(),
                None,
            )?,
            local_device_name: Some("Rust Q-Periapt Responder (neg)".to_owned()),
            identity: responder_identity,
            supported_suites: vec![
                CryptoSuite::XWING_MLDSA,
                CryptoSuite::MLKEM768_MLDSA65,
                CryptoSuite::QPERIAPT_CONTEXTBOUND_MLDSA65,
            ],
            policy: DowngradePolicy::PreferPqc,
        })?;

        let message_a = initiator.start()?;
        let responder_actions = responder.handle_frame(&message_a)?;
        assert_eq!(responder_actions.outbound_frames.len(), 2);
        let _ = initiator.handle_frame(&responder_actions.outbound_frames[0])?;
        let initiator_actions = initiator.handle_frame(&responder_actions.outbound_frames[1])?;
        assert!(initiator_actions.established.is_some());
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
        assert_eq!(
            responder_keys.negotiated_suite, "Q-Periapt-ContextBound",
            "a responder advertising X-Wing/ML-KEM/Q-Periapt must negotiate Q-Periapt when the initiator prefers it"
        );
        Ok(())
    }

    /// The policy byte is now derived from the active policy, but the default
    /// `PreferPqc` posture must produce the exact legacy wire bytes so existing
    /// peers keep parsing it.
    #[test]
    fn pqc_policy_bytes_preserve_legacy_wire_format() {
        // Legacy literal: [0x01, 0x00, <u32 LE len=9>"liboqsPQC", 0x00].
        let mut expected = Vec::new();
        expected.push(0x01);
        expected.push(0x00);
        crate::handshake_wire::encode_string(&mut expected, "liboqsPQC");
        expected.push(0x00);
        assert_eq!(pqc_policy_bytes(DowngradePolicy::PreferPqc), expected);
        // Strict realizations also advertise requirePQC=1.
        assert_eq!(
            pqc_policy_bytes(DowngradePolicy::StrictPqcCompliance)[0],
            0x01
        );
        // A non-PQC posture flips the first byte to 0x00.
        assert_eq!(pqc_policy_bytes(DowngradePolicy::Default)[0], 0x00);
    }

    /// The responder now decodes (rather than discards) the initiator's advertised
    /// `requirePQC` posture from MessageA.
    #[test]
    fn responder_decodes_initiator_policy_posture() -> Result<()> {
        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;
        let mut handshake = PqcInitiatorHandshake::new(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-1234567890abcd",
                initiator_identity.signing_algorithm,
                initiator_identity.signing_public_key.clone(),
                None,
            )?,
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: None,
            preferred_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::MLKEM768_MLDSA65,
                responder_identity.mlkem768_public_key.clone(),
            )]),
            policy: DowngradePolicy::PreferPqc,
        })?;
        let message_a = handshake.start()?;
        let decoded = decode_message_a(&message_a)?;
        assert!(
            decoded.initiator_requires_pqc,
            "PreferPqc must advertise requirePQC=1 and be observed by the responder"
        );
        Ok(())
    }

    /// End-to-end initiator-side fallback gate: BLOCKED reasons denied, ALLOWED
    /// reason authorized with a transcript-anchored DowngradeEvent, and the per-peer
    /// 300 s cooldown then denies an immediate second fallback.
    #[test]
    fn initiator_fallback_gate_enforces_taxonomy_and_cooldown() -> Result<()> {
        use crate::policy::{DowngradeDecision, FallbackReason, PolicyGate};

        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;
        let mut handshake = PqcInitiatorHandshake::new(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-1234567890abcd",
                initiator_identity.signing_algorithm,
                initiator_identity.signing_public_key.clone(),
                None,
            )?,
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: None,
            preferred_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::MLKEM768_MLDSA65,
                responder_identity.mlkem768_public_key.clone(),
            )]),
            policy: DowngradePolicy::PreferPqc,
        })?;
        // Drive into WaitingForMessageB so a transcript anchor is available.
        let _message_a = handshake.start()?;

        let mut gate = PolicyGate::new(handshake.policy());
        let peer = "device-fedcba0987654321";

        // BLOCKED: a timeout must never authorize a fallback.
        let blocked = handshake.authorize_classic_fallback(
            &mut gate,
            peer,
            FallbackReason::Timeout,
            CryptoSuite::X25519_ED25519,
        );
        assert_eq!(
            blocked,
            DowngradeDecision::DeniedReasonIneligible(FallbackReason::Timeout)
        );

        // ALLOWED: pqcProviderUnavailable authorizes a transcript-anchored event.
        let allowed = handshake.authorize_classic_fallback(
            &mut gate,
            peer,
            FallbackReason::PqcProviderUnavailable,
            CryptoSuite::X25519_ED25519,
        );
        let event = allowed.event().expect("eligible reason => authorized");
        assert_eq!(event.from_suite, CryptoSuite::MLKEM768_MLDSA65.wire_id);
        assert_eq!(event.to_suite, CryptoSuite::X25519_ED25519.wire_id);
        assert!(
            event.transcript_anchor.is_some(),
            "fallback authorized in-handshake must anchor to the MessageA transcript"
        );

        // COOLDOWN: a second eligible fallback to the same peer is rate-limited.
        let second = handshake.authorize_classic_fallback(
            &mut gate,
            peer,
            FallbackReason::PqcProviderUnavailable,
            CryptoSuite::X25519_ED25519,
        );
        assert!(matches!(
            second,
            DowngradeDecision::DeniedRateLimited { .. }
        ));
        Ok(())
    }

    /// A strict-PQC responder refuses an initiator that advertises a non-PQC
    /// (downgrade-friendly) posture, rather than silently proceeding.
    #[test]
    fn strict_responder_refuses_non_pqc_initiator_posture() -> Result<()> {
        let initiator_identity = RustPqcIdentityMaterial::generate()?;
        let responder_identity = RustPqcIdentityMaterial::generate()?;
        // Initiator advertises Default posture (requirePQC=0) on the wire.
        let mut handshake = PqcInitiatorHandshake::new(PqcInitiatorConfig {
            local_binding: ProtocolIdentityBinding::new(
                "device-1234567890abcd",
                initiator_identity.signing_algorithm,
                initiator_identity.signing_public_key.clone(),
                None,
            )?,
            signing_secret_key: initiator_identity.signing_secret_key.clone(),
            local_device_name: None,
            preferred_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
            peer_kem_public_keys: BTreeMap::from([(
                CryptoSuite::MLKEM768_MLDSA65,
                responder_identity.mlkem768_public_key.clone(),
            )]),
            policy: DowngradePolicy::Default,
        })?;
        let message_a = handshake.start()?;
        let decoded = decode_message_a(&message_a)?;
        assert!(!decoded.initiator_requires_pqc);

        let responder_binding = ProtocolIdentityBinding::new(
            "device-fedcba0987654321",
            responder_identity.signing_algorithm,
            responder_identity.signing_public_key.clone(),
            None,
        )?;
        let result = build_responder_message_b_and_keys(
            &PqcResponderConfig {
                local_binding: responder_binding,
                local_device_name: None,
                identity: responder_identity,
                supported_suites: vec![CryptoSuite::MLKEM768_MLDSA65],
                policy: DowngradePolicy::StrictPqcCompliance,
            },
            &decoded,
        );
        assert!(
            result.is_err(),
            "strict-PQC responder must refuse a non-PQC-posture initiator"
        );
        Ok(())
    }
}
