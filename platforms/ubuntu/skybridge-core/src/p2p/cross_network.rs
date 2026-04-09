//! Cross-network (WebRTC-style) framed channel.
//!
//! This module mirrors the macOS/iOS approach:
//! - Transport provides a byte stream (e.g. WebRTC DataChannel) delivering arbitrary chunks.
//! - We apply 4-byte big-endian length framing to obtain message frames.
//! - Before handshake completion: frames are raw handshake bytes (`HandshakeMessage` encoding).
//! - After handshake completion: frames are application-encrypted (AES-GCM) using `SessionKeys`.
//!
//! Note: macOS/iOS optionally apply traffic padding (SBP2) around ciphertext/frames. We always
//! accept unwrapping SBP2 on inbound frames for interoperability.

use crate::crypto::aead::EncryptedData;
use crate::crypto::provider::CryptoProvider;
use crate::crypto::suite::CryptoSuiteId;
use crate::p2p::driver::{HandshakeDriver, LocalIdentity};
use crate::p2p::framing::{DEFAULT_MAX_FRAME_SIZE, FrameDecoder};
use crate::p2p::messages::HandshakeMessage;
use crate::p2p::types::{HandshakePolicy, P2PError, PeerIdentity, SessionKeys};
use std::collections::HashMap;
use tracing::{info, warn};

const TRAFFIC_PADDING_MAGIC_P2: &[u8; 4] = b"SBP2";
const TRAFFIC_PADDING_HEADER_LEN: usize = 8; // magic + u32(actualLen, big-endian)
const HANDSHAKE_PADDING_MAGIC_P1: &[u8; 4] = b"SBP1";
const HANDSHAKE_PADDING_HEADER_LEN: usize = 8; // magic + u32(actualLen, big-endian)
const APPLE_MAX_MESSAGE_A_LEN: usize = 8192;

fn unwrap_traffic_padding_p2_if_needed(data: &[u8]) -> &[u8] {
    if data.len() < TRAFFIC_PADDING_HEADER_LEN {
        return data;
    }
    if &data[0..4] != TRAFFIC_PADDING_MAGIC_P2 {
        return data;
    }
    let actual_len = u32::from_be_bytes([data[4], data[5], data[6], data[7]]) as usize;
    if actual_len > data.len().saturating_sub(TRAFFIC_PADDING_HEADER_LEN) {
        return data;
    }
    &data[TRAFFIC_PADDING_HEADER_LEN..TRAFFIC_PADDING_HEADER_LEN + actual_len]
}

fn unwrap_handshake_padding_p1_if_needed(data: &[u8]) -> &[u8] {
    if data.len() < HANDSHAKE_PADDING_HEADER_LEN {
        return data;
    }
    if &data[0..4] != HANDSHAKE_PADDING_MAGIC_P1 {
        return data;
    }
    let actual_len = u32::from_be_bytes([data[4], data[5], data[6], data[7]]) as usize;
    if actual_len > data.len().saturating_sub(HANDSHAKE_PADDING_HEADER_LEN) {
        return data;
    }
    &data[HANDSHAKE_PADDING_HEADER_LEN..HANDSHAKE_PADDING_HEADER_LEN + actual_len]
}

fn select_outbound_rekey_suite(
    peer_kem_public_keys: &HashMap<CryptoSuiteId, Vec<u8>>,
) -> Option<(CryptoSuiteId, Vec<u8>)> {
    if let Ok(raw_override) = std::env::var("SKYBRIDGE_SMOKE_PQC_REKEY_SUITE") {
        let normalized = raw_override.trim().to_ascii_lowercase();
        let override_suite = match normalized.as_str() {
            "0x0101" | "0101" | "ml-kem-768" | "mlkem768" => {
                Some(CryptoSuiteId::MlKem768_AES256GCM_MlDsa65)
            }
            "0x0102" | "0102" | "ml-kem-768-fs" | "mlkem768fs" | "mlkem768-fs" => {
                Some(CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65)
            }
            "0x0001" | "0001" | "x-wing" | "xwing" => Some(CryptoSuiteId::XWing_AES256GCM_MlDsa65),
            _ => None,
        };

        if let Some(override_suite) = override_suite
            && let Some(key) = peer_kem_public_keys.get(&override_suite)
        {
            return Some((override_suite, key.clone()));
        }
    }

    // Rekey is already running on an established channel, so we can afford to be
    // precise here. On the current Apple mainline, Ubuntu-advertised PQC
    // capabilities are interpreted through the liboqs path; pure ML-KEM suites
    // therefore interoperate more reliably than X-Wing on inbound rekeys today.
    let preferred = [
        CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65,
        CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
        CryptoSuiteId::XWing_AES256GCM_MlDsa65,
    ];

    for suite in preferred {
        if let Some(key) = peer_kem_public_keys.get(&suite) {
            return Some((suite, key.clone()));
        }
    }

    let mut fallback: Vec<(CryptoSuiteId, Vec<u8>)> = peer_kem_public_keys
        .iter()
        .filter(|(suite, _)| suite.is_pqc())
        .map(|(suite, key)| (*suite, key.clone()))
        .collect();
    fallback.sort_by_key(|(suite, _)| suite.wire_id());
    fallback.into_iter().next()
}

fn handshake_message_label(message: &HandshakeMessage) -> &'static str {
    match message {
        HandshakeMessage::MessageA(_) => "messageA",
        HandshakeMessage::MessageB(_) => "messageB",
        HandshakeMessage::Finished(_) => "finished",
        HandshakeMessage::Error(_) => "error",
    }
}

/// Output produced by [`CrossNetworkChannel::push_inbound_chunk`].
#[derive(Debug)]
pub enum CrossNetworkInbound {
    /// A decrypted application payload (post-handshake).
    AppPayload(Vec<u8>),
    /// Outbound raw bytes that should be sent over the transport.
    ///
    /// - Handshake frames are **not encrypted** (macOS/iOS behavior).
    /// - Application frames are AES-GCM encrypted.
    OutboundFrame(Vec<u8>),
    /// Handshake has just been established (session keys are now available).
    HandshakeEstablished(SessionKeys),
}

/// A transport-agnostic cross-network channel.
///
/// Feed it raw bytes from a transport (e.g. DataChannel `onData`) and it will:
/// - decode frames
/// - run the handshake state machine
/// - decrypt/encrypt application payloads once the handshake is established
pub struct CrossNetworkChannel {
    decoder: FrameDecoder,
    driver: HandshakeDriver,
    keys: Option<SessionKeys>,
    crypto: Option<CryptoProvider>,
    local_identity: LocalIdentity,
    policy: HandshakePolicy,
    peer_device_id: Option<String>,
    expected_peer_fingerprint: Option<String>,
    peer_kem_public_keys: HashMap<CryptoSuiteId, Vec<u8>>,
    rekey_driver: Option<HandshakeDriver>,
}

impl CrossNetworkChannel {
    /// Create an initiator channel.
    pub fn new_initiator(identity: LocalIdentity, policy: HandshakePolicy) -> Self {
        Self::new_initiator_with_limit(identity, policy, DEFAULT_MAX_FRAME_SIZE)
    }

    /// Create an initiator channel with a custom max frame size.
    pub fn new_initiator_with_limit(
        identity: LocalIdentity,
        policy: HandshakePolicy,
        max_frame_size: usize,
    ) -> Self {
        let local_identity = identity.clone();
        Self {
            decoder: FrameDecoder::with_limit(max_frame_size),
            driver: HandshakeDriver::new_initiator_with_policy(identity, policy),
            keys: None,
            crypto: None,
            local_identity,
            policy,
            peer_device_id: None,
            expected_peer_fingerprint: None,
            peer_kem_public_keys: HashMap::new(),
            rekey_driver: None,
        }
    }

    /// Create a responder channel.
    pub fn new_responder(identity: LocalIdentity, policy: HandshakePolicy) -> Self {
        Self::new_responder_with_limit(identity, policy, DEFAULT_MAX_FRAME_SIZE)
    }

    /// Create a responder channel with a custom max frame size.
    pub fn new_responder_with_limit(
        identity: LocalIdentity,
        policy: HandshakePolicy,
        max_frame_size: usize,
    ) -> Self {
        let local_identity = identity.clone();
        Self {
            decoder: FrameDecoder::with_limit(max_frame_size),
            driver: HandshakeDriver::new_responder_with_policy(identity, policy),
            keys: None,
            crypto: None,
            local_identity,
            policy,
            peer_device_id: None,
            expected_peer_fingerprint: None,
            peer_kem_public_keys: HashMap::new(),
            rekey_driver: None,
        }
    }

    /// Start handshake as initiator and return the first outbound frame (MessageA).
    pub async fn start_handshake(&mut self) -> Result<Vec<u8>, P2PError> {
        let msg = self.driver.start().await?;
        Ok(msg.to_bytes())
    }

    /// True if the handshake is established.
    pub fn is_established(&self) -> bool {
        self.driver.state().is_established() && self.keys.is_some()
    }

    /// Current session keys (if established).
    pub fn session_keys(&self) -> Option<&SessionKeys> {
        self.keys.as_ref()
    }

    /// Current peer identity (once available).
    ///
    /// Note: identity becomes available during the handshake and persists after establishment.
    pub fn peer_identity(&self) -> Option<&PeerIdentity> {
        self.driver.peer_identity()
    }

    /// Provide a peer device id hint (from discovery) for trust store indexing / logging.
    pub fn set_peer_device_id(&mut self, device_id: Option<String>) {
        self.peer_device_id = device_id.clone();
        self.driver.set_peer_device_id(device_id.clone());
        if let Some(driver) = self.rekey_driver.as_mut() {
            driver.set_peer_device_id(device_id);
        }
    }

    /// Provide an expected peer fingerprint for local verification.
    pub fn set_expected_peer_fingerprint(&mut self, fingerprint: Option<String>) {
        self.expected_peer_fingerprint = fingerprint.clone();
        self.driver
            .set_expected_peer_fingerprint(fingerprint.clone());
        if let Some(driver) = self.rekey_driver.as_mut() {
            driver.set_expected_peer_fingerprint(fingerprint);
        }
    }

    /// Provide peer KEM public keys to enable PQC handshake.
    ///
    /// Must be called before `start_handshake()` on initiator.
    pub fn set_peer_kem_public_keys(&mut self, keys: HashMap<CryptoSuiteId, Vec<u8>>) {
        self.peer_kem_public_keys = keys.clone();
        self.driver.set_peer_kem_public_keys(keys.clone());
        if let Some(driver) = self.rekey_driver.as_mut() {
            driver.set_peer_kem_public_keys(keys);
        }
    }

    /// Provide outbound MessageA extensions TLV bytes (will be container-wrapped on the wire).
    ///
    /// IMPORTANT: Must be set before `start_handshake()` on initiator.
    pub fn set_outbound_extensions_raw(&mut self, extensions_raw: Vec<u8>) {
        self.driver
            .set_outbound_extensions_raw(extensions_raw.clone());
        if let Some(driver) = self.rekey_driver.as_mut() {
            driver.set_outbound_extensions_raw(extensions_raw);
        }
    }

    pub fn soa_pair_key(&self) -> Option<[u8; 64]> {
        self.driver.soa_pair_key()
    }

    fn ensure_rekey_responder_driver(&mut self) -> &mut HandshakeDriver {
        if self.rekey_driver.is_none() {
            let mut driver = HandshakeDriver::new_responder_with_policy(
                self.local_identity.clone(),
                self.policy,
            );
            driver.disable_soa();
            driver.set_peer_device_id(self.peer_device_id.clone());
            // Rekey runs over an already authenticated session. Apple currently
            // allows the peer to rotate from the bootstrap signing identity into
            // the PQC authority during this phase, so we do not pre-pin the
            // rekey driver to the bootstrap fingerprint here.
            driver.set_expected_peer_fingerprint(None);
            driver.set_peer_kem_public_keys(self.peer_kem_public_keys.clone());
            self.rekey_driver = Some(driver);
        }
        self.rekey_driver.as_mut().unwrap()
    }

    /// Start an outbound strict-PQC rekey on an already-established channel.
    ///
    /// Returns `Ok(Some(message_a))` when a new rekey handshake should be sent.
    /// Returns `Ok(None)` when the session is already PQC or a rekey is already in progress.
    pub async fn start_outbound_pqc_rekey(
        &mut self,
        peer_device_id: Option<String>,
        peer_kem_public_keys: HashMap<CryptoSuiteId, Vec<u8>>,
    ) -> Result<Option<Vec<u8>>, P2PError> {
        if self.keys.is_none() {
            return Err(P2PError::SessionNotEstablished);
        }
        if self
            .keys
            .as_ref()
            .is_some_and(|keys| keys.suite_id.is_pqc())
        {
            return Ok(None);
        }
        if self.rekey_driver.is_some() {
            return Ok(None);
        }
        if peer_kem_public_keys.is_empty() {
            return Err(P2PError::Protocol(
                "Missing peer KEM public keys for outbound PQC rekey".to_string(),
            ));
        }

        let (selected_suite, selected_key) = select_outbound_rekey_suite(&peer_kem_public_keys)
            .ok_or_else(|| {
                P2PError::Protocol(
                    "Missing compatible peer KEM public key for outbound PQC rekey".to_string(),
                )
            })?;
        let peer_kem_public_keys = HashMap::from([(selected_suite, selected_key)]);

        self.set_peer_device_id(peer_device_id);
        self.set_peer_kem_public_keys(peer_kem_public_keys.clone());

        let mut driver = HandshakeDriver::new_initiator_with_policy(
            self.local_identity.clone(),
            HandshakePolicy::strict_pqc(),
        );
        driver.disable_soa();
        driver.set_peer_device_id(self.peer_device_id.clone());
        // Rekey is anchored by the established classic/current-path session, so
        // we allow the responder to present its PQC signing identity without
        // forcing it to equal the bootstrap fingerprint.
        driver.set_expected_peer_fingerprint(None);
        driver.set_explicit_offered_suites(vec![selected_suite]);
        driver.set_peer_kem_public_keys(peer_kem_public_keys);

        let msg = driver.start().await?;
        let msg_bytes = msg.to_bytes();
        if msg_bytes.len() > APPLE_MAX_MESSAGE_A_LEN {
            return Err(P2PError::Protocol(format!(
                "Outbound PQC rekey MessageA too large for Apple parser: {} bytes",
                msg_bytes.len()
            )));
        }
        info!(
            suite = ?selected_suite,
            bytes = msg_bytes.len(),
            "starting outbound PQC rekey"
        );
        self.rekey_driver = Some(driver);
        Ok(Some(msg_bytes))
    }

    /// Encrypt an application payload into a frame payload.
    ///
    /// The output of this function should be wrapped with the 4-byte length framing at the
    /// transport boundary (see `p2p::framing::encode_frame`).
    pub fn encrypt_app_payload(&self, plaintext: &[u8]) -> Result<Vec<u8>, P2PError> {
        let keys = self.keys.as_ref().ok_or(P2PError::SessionNotEstablished)?;
        let crypto = self
            .crypto
            .as_ref()
            .ok_or_else(|| P2PError::Protocol("crypto provider missing".to_string()))?;

        // IMPORTANT: macOS/iOS use AES-GCM without AAD for cross-network payloads.
        let sealed = crypto.encrypt(&keys.send_control_key, plaintext, &[])?;
        Ok(sealed.to_bytes())
    }

    /// Try decrypting an application payload frame payload.
    fn try_decrypt_app_payload(&self, ciphertext: &[u8]) -> Result<Vec<u8>, P2PError> {
        let keys = self.keys.as_ref().ok_or(P2PError::SessionNotEstablished)?;
        let crypto = self
            .crypto
            .as_ref()
            .ok_or_else(|| P2PError::Protocol("crypto provider missing".to_string()))?;

        let encrypted = EncryptedData::from_bytes(ciphertext, 12)
            .ok_or_else(|| P2PError::InvalidMessage("invalid encrypted payload".to_string()))?;

        // IMPORTANT: empty AAD for macOS/iOS compatibility.
        crypto
            .decrypt(&keys.recv_control_key, &encrypted, &[])
            .map_err(P2PError::from)
    }

    /// Push an inbound transport chunk (may contain partial frames / multiple frames).
    ///
    /// Returns a sequence of events: outbound frames and/or decrypted app payloads.
    pub async fn push_inbound_chunk(
        &mut self,
        chunk: &[u8],
    ) -> Result<Vec<CrossNetworkInbound>, P2PError> {
        let frames = if self.keys.is_some() {
            self.decoder.push_lossy(chunk)?
        } else {
            self.decoder.push(chunk)?
        };
        let mut out = Vec::new();

        for frame in frames {
            // Phase C2: optional post-handshake traffic padding (SBP2).
            let frame = unwrap_traffic_padding_p2_if_needed(&frame);
            let frame = unwrap_handshake_padding_p1_if_needed(frame);

            // If we have keys, attempt decrypt-first (macOS/iOS behavior).
            if self.keys.is_some() {
                if let Ok(plaintext) = self.try_decrypt_app_payload(frame) {
                    out.push(CrossNetworkInbound::AppPayload(plaintext));
                    continue;
                }

                // Best-effort: treat undecipherable frames as potential rekey handshake packets.
                // Never fail the whole session just because one frame can't be parsed.
                let Ok(hm) = HandshakeMessage::from_bytes(frame) else {
                    continue;
                };
                let message_label = handshake_message_label(&hm);
                info!(
                    message = message_label,
                    bytes = frame.len(),
                    rekey = self.rekey_driver.is_some(),
                    "received post-handshake control frame"
                );

                if matches!(hm, HandshakeMessage::MessageA(_)) {
                    let _ = self.ensure_rekey_responder_driver();
                }

                let use_rekey = self.rekey_driver.is_some();
                let response = if use_rekey {
                    self.rekey_driver
                        .as_mut()
                        .unwrap()
                        .process_message(hm)
                        .await
                } else {
                    self.driver.process_message(hm).await
                };

                let response = match response {
                    Ok(response) => response,
                    Err(err) => {
                        // Rekey failed; clear state and continue receiving on old keys.
                        warn!(
                            message = message_label,
                            rekey = use_rekey,
                            error = %err,
                            "post-handshake control frame rejected"
                        );
                        if use_rekey {
                            self.rekey_driver = None;
                        }
                        continue;
                    }
                };

                if let Some(response) = response {
                    out.push(CrossNetworkInbound::OutboundFrame(response.to_bytes()));
                }

                // macOS/iOS switch to newly derived rekey session keys as soon as the
                // driver produces them (for example while waiting to transmit Finished).
                let maybe_keys = if use_rekey {
                    self.rekey_driver
                        .as_ref()
                        .and_then(|d| d.session_keys())
                        .cloned()
                } else {
                    self.driver.session_keys().cloned()
                };

                if let Some(keys) = maybe_keys {
                    let should_update = self
                        .keys
                        .as_ref()
                        .map(|k| k.transcript_hash != keys.transcript_hash)
                        .unwrap_or(true);

                    if should_update {
                        self.crypto = Some(CryptoProvider::new(keys.suite_id));
                        self.keys = Some(keys.clone());
                        out.push(CrossNetworkInbound::HandshakeEstablished(keys));
                    }
                }

                if use_rekey
                    && self
                        .rekey_driver
                        .as_ref()
                        .is_some_and(|driver| driver.state().is_established())
                    && let Some(driver) = self.rekey_driver.take()
                {
                    self.driver = driver;
                }

                continue;
            }

            // Pre-handshake: strict processing (errors are fatal).
            let hm = HandshakeMessage::from_bytes(frame)?;
            let response = self.driver.process_message(hm).await?;
            if let Some(response) = response {
                out.push(CrossNetworkInbound::OutboundFrame(response.to_bytes()));
            }

            // If handshake just completed, publish keys.
            if self.driver.state().is_established() {
                let Some(keys) = self.driver.session_keys().cloned() else {
                    continue;
                };
                let should_update = self
                    .keys
                    .as_ref()
                    .map(|k| k.transcript_hash != keys.transcript_hash)
                    .unwrap_or(true);
                if should_update {
                    self.crypto = Some(CryptoProvider::new(keys.suite_id));
                    self.keys = Some(keys.clone());
                    out.push(CrossNetworkInbound::HandshakeEstablished(keys));
                }
            }
        }

        Ok(out)
    }

    /// Reset framing buffer (e.g., after transport reset).
    pub fn clear_buffer(&mut self) {
        self.decoder.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::suite::CryptoSuiteId;
    use crate::p2p::framing::encode_frame;
    use crate::p2p::types::HandshakePolicy;

    fn make_identity(id: &str) -> LocalIdentity {
        // Keep suites minimal for test speed.
        LocalIdentity::generate(id.to_string(), &[CryptoSuiteId::X25519_AES256GCM_Ed25519]).unwrap()
    }

    fn wrap_handshake_padding_p1(payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(HANDSHAKE_PADDING_HEADER_LEN + payload.len());
        out.extend_from_slice(HANDSHAKE_PADDING_MAGIC_P1);
        out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        out.extend_from_slice(payload);
        out
    }

    #[tokio::test]
    async fn cross_network_framing_handshake_and_app_crypto_roundtrip() {
        let policy = HandshakePolicy::default();

        let mut initiator = CrossNetworkChannel::new_initiator(make_identity("initiator"), policy);
        let mut responder = CrossNetworkChannel::new_responder(make_identity("responder"), policy);

        // Start handshake (initiator -> responder)
        let msg_a = initiator.start_handshake().await.unwrap();
        let framed_a = encode_frame(&msg_a).unwrap();
        let out = responder.push_inbound_chunk(&framed_a).await.unwrap();

        // responder should respond with at least one handshake frame
        let mut pending_to_initiator: Vec<Vec<u8>> = out
            .into_iter()
            .filter_map(|e| match e {
                CrossNetworkInbound::OutboundFrame(b) => Some(b),
                _ => None,
            })
            .collect();
        assert!(!pending_to_initiator.is_empty());

        // drive handshake until initiator reports established
        let mut established = false;
        for _ in 0..10 {
            if pending_to_initiator.is_empty() {
                break;
            }
            let frame = pending_to_initiator.remove(0);
            let framed = encode_frame(&frame).unwrap();
            let out_i = initiator.push_inbound_chunk(&framed).await.unwrap();
            for e in out_i {
                match e {
                    CrossNetworkInbound::OutboundFrame(b) => {
                        let framed = encode_frame(&b).unwrap();
                        let out_r = responder.push_inbound_chunk(&framed).await.unwrap();
                        for er in out_r {
                            match er {
                                CrossNetworkInbound::OutboundFrame(bb) => {
                                    pending_to_initiator.push(bb);
                                }
                                CrossNetworkInbound::HandshakeEstablished(_) => {
                                    // responder established
                                }
                                _ => {}
                            }
                        }
                    }
                    CrossNetworkInbound::HandshakeEstablished(_) => {
                        established = true;
                    }
                    _ => {}
                }
            }
            if established {
                break;
            }
        }

        assert!(initiator.is_established());
        assert!(responder.is_established());

        // App payload encryption (initiator -> responder)
        let plaintext = b"hello over webrtc-like channel";
        let sealed = initiator.encrypt_app_payload(plaintext).unwrap();
        let framed = encode_frame(&sealed).unwrap();
        let out_r = responder.push_inbound_chunk(&framed).await.unwrap();
        let mut got = None;
        for e in out_r {
            if let CrossNetworkInbound::AppPayload(p) = e {
                got = Some(p);
            }
        }
        assert_eq!(got.unwrap(), plaintext);
    }

    #[tokio::test]
    async fn cross_network_accepts_rekey_message_a_after_established() {
        let policy = HandshakePolicy::default();
        let init_identity = make_identity("initiator");
        let resp_identity = make_identity("responder");

        let mut initiator = CrossNetworkChannel::new_initiator(init_identity.clone(), policy);
        let mut responder = CrossNetworkChannel::new_responder(resp_identity, policy);

        // Establish initial session.
        let msg_a = initiator.start_handshake().await.unwrap();
        let framed_a = encode_frame(&msg_a).unwrap();
        let mut pending_to_initiator: Vec<Vec<u8>> = responder
            .push_inbound_chunk(&framed_a)
            .await
            .unwrap()
            .into_iter()
            .filter_map(|e| match e {
                CrossNetworkInbound::OutboundFrame(b) => Some(b),
                _ => None,
            })
            .collect();

        for _ in 0..10 {
            if pending_to_initiator.is_empty() {
                break;
            }
            let frame = pending_to_initiator.remove(0);
            let framed = encode_frame(&frame).unwrap();
            let out_i = initiator.push_inbound_chunk(&framed).await.unwrap();
            for e in out_i {
                if let CrossNetworkInbound::OutboundFrame(b) = e {
                    let framed = encode_frame(&b).unwrap();
                    let out_r = responder.push_inbound_chunk(&framed).await.unwrap();
                    for er in out_r {
                        if let CrossNetworkInbound::OutboundFrame(bb) = er {
                            pending_to_initiator.push(bb);
                        }
                    }
                }
            }
            if initiator.is_established() && responder.is_established() {
                break;
            }
        }

        assert!(initiator.is_established());
        assert!(responder.is_established());

        let before = responder.session_keys().unwrap().transcript_hash.clone();

        // Simulate macOS strict-PQC bootstrap: peer sends a fresh MessageA on an already established channel.
        let mut rekey_initiator = CrossNetworkChannel::new_initiator(init_identity, policy);
        let msg_a2 = wrap_handshake_padding_p1(&rekey_initiator.start_handshake().await.unwrap());
        let mut pending_to_responder = vec![msg_a2];

        let mut rekeyed = false;
        for _ in 0..20 {
            if pending_to_responder.is_empty() {
                break;
            }

            // deliver to responder (already established)
            let frame = pending_to_responder.remove(0);
            let framed = encode_frame(&frame).unwrap();
            let out_r = responder.push_inbound_chunk(&framed).await.unwrap();

            let mut pending_to_rekey_initiator: Vec<Vec<u8>> = Vec::new();
            for e in out_r {
                match e {
                    CrossNetworkInbound::OutboundFrame(b) => pending_to_rekey_initiator.push(b),
                    CrossNetworkInbound::HandshakeEstablished(_) => rekeyed = true,
                    _ => {}
                }
            }

            // deliver responder replies to rekey initiator
            for frame in pending_to_rekey_initiator {
                let framed = encode_frame(&frame).unwrap();
                let out_i = rekey_initiator.push_inbound_chunk(&framed).await.unwrap();
                for e in out_i {
                    if let CrossNetworkInbound::OutboundFrame(b) = e {
                        pending_to_responder.push(b);
                    }
                }
            }

            if rekeyed && rekey_initiator.is_established() {
                break;
            }
        }

        assert!(rekeyed);
        assert!(rekey_initiator.is_established());

        let after = responder.session_keys().unwrap().transcript_hash.clone();
        assert_ne!(before, after);

        // Validate that application encryption still works with the newly negotiated keys.
        let plaintext = b"hello after rekey";
        let sealed = rekey_initiator.encrypt_app_payload(plaintext).unwrap();
        let framed = encode_frame(&sealed).unwrap();
        let out_r = responder.push_inbound_chunk(&framed).await.unwrap();
        let mut got = None;
        for e in out_r {
            if let CrossNetworkInbound::AppPayload(p) = e {
                got = Some(p);
            }
        }
        assert_eq!(got.unwrap(), plaintext);
    }

    #[tokio::test]
    async fn cross_network_can_initiate_outbound_pqc_rekey_after_bootstrap() {
        let policy = HandshakePolicy::default();
        let unique_suffix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let initiator_id = format!("initiator-{unique_suffix}");
        let responder_id = format!("responder-{unique_suffix}");
        let initiator_identity = LocalIdentity::generate(
            initiator_id.clone(),
            &[
                CryptoSuiteId::X25519_AES256GCM_Ed25519,
                CryptoSuiteId::XWing_AES256GCM_MlDsa65,
                CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65,
                CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
            ],
        )
        .unwrap();
        let responder_identity = LocalIdentity::generate(
            responder_id.clone(),
            &[
                CryptoSuiteId::X25519_AES256GCM_Ed25519,
                CryptoSuiteId::XWing_AES256GCM_MlDsa65,
                CryptoSuiteId::MlKem768FsCompat_AES256GCM_MlDsa65,
                CryptoSuiteId::MlKem768_AES256GCM_MlDsa65,
            ],
        )
        .unwrap();

        let mut initiator = CrossNetworkChannel::new_initiator(initiator_identity.clone(), policy);
        let mut responder = CrossNetworkChannel::new_responder(responder_identity.clone(), policy);

        let msg_a = initiator.start_handshake().await.unwrap();
        let framed_a = encode_frame(&msg_a).unwrap();
        let mut pending_to_initiator: Vec<Vec<u8>> = responder
            .push_inbound_chunk(&framed_a)
            .await
            .unwrap()
            .into_iter()
            .filter_map(|e| match e {
                CrossNetworkInbound::OutboundFrame(b) => Some(b),
                _ => None,
            })
            .collect();

        for _ in 0..10 {
            if pending_to_initiator.is_empty() {
                break;
            }
            let frame = pending_to_initiator.remove(0);
            let framed = encode_frame(&frame).unwrap();
            let out_i = initiator.push_inbound_chunk(&framed).await.unwrap();
            for e in out_i {
                if let CrossNetworkInbound::OutboundFrame(b) = e {
                    let framed = encode_frame(&b).unwrap();
                    let out_r = responder.push_inbound_chunk(&framed).await.unwrap();
                    for er in out_r {
                        if let CrossNetworkInbound::OutboundFrame(bb) = er {
                            pending_to_initiator.push(bb);
                        }
                    }
                }
            }
            if initiator.is_established() && responder.is_established() {
                break;
            }
        }

        assert_eq!(
            initiator.session_keys().unwrap().suite_id,
            CryptoSuiteId::X25519_AES256GCM_Ed25519
        );
        assert_eq!(
            responder.session_keys().unwrap().suite_id,
            CryptoSuiteId::X25519_AES256GCM_Ed25519
        );

        let expected_rekey_suite =
            select_outbound_rekey_suite(&responder_identity.kem_public_key_map())
                .map(|(suite, _)| suite)
                .expect("expected exact outbound PQC rekey suite");
        let message_a = initiator
            .start_outbound_pqc_rekey(Some(responder_id), responder_identity.kem_public_key_map())
            .await
            .unwrap()
            .expect("message_a");
        assert!(
            message_a.len() <= APPLE_MAX_MESSAGE_A_LEN,
            "outbound PQC rekey MessageA should fit Apple parser limit"
        );
        match HandshakeMessage::from_bytes(&message_a).unwrap() {
            HandshakeMessage::MessageA(msg_a) => {
                assert_eq!(msg_a.supported_suites, vec![expected_rekey_suite.wire_id()]);
                assert_eq!(msg_a.key_shares.len(), 1);
                assert_eq!(msg_a.key_shares[0].suite_id, expected_rekey_suite.wire_id());
            }
            other => panic!("expected MessageA, got {:?}", other),
        }
        responder.set_peer_kem_public_keys(initiator_identity.kem_public_key_map());

        let mut pending_to_responder = vec![message_a];
        let mut pending_to_initiator = Vec::new();

        for _ in 0..20 {
            while let Some(frame) = pending_to_responder.pop() {
                let framed = encode_frame(&frame).unwrap();
                let out_r = responder.push_inbound_chunk(&framed).await.unwrap();
                for event in out_r {
                    if let CrossNetworkInbound::OutboundFrame(bytes) = event {
                        pending_to_initiator.push(bytes);
                    }
                }
            }

            while let Some(frame) = pending_to_initiator.pop() {
                let framed = encode_frame(&frame).unwrap();
                let out_i = initiator.push_inbound_chunk(&framed).await.unwrap();
                for event in out_i {
                    if let CrossNetworkInbound::OutboundFrame(bytes) = event {
                        pending_to_responder.push(bytes);
                    }
                }
            }

            if initiator
                .session_keys()
                .is_some_and(|keys| keys.suite_id.is_pqc())
                && responder
                    .session_keys()
                    .is_some_and(|keys| keys.suite_id.is_pqc())
            {
                break;
            }
        }

        assert!(initiator.session_keys().unwrap().suite_id.is_pqc());
        assert!(responder.session_keys().unwrap().suite_id.is_pqc());
    }

    #[tokio::test]
    async fn cross_network_drops_invalid_framing_after_established() {
        let policy = HandshakePolicy::default();
        let mut initiator = CrossNetworkChannel::new_initiator(make_identity("initiator"), policy);
        let mut responder = CrossNetworkChannel::new_responder(make_identity("responder"), policy);

        let msg_a = initiator.start_handshake().await.unwrap();
        let framed_a = encode_frame(&msg_a).unwrap();
        let mut pending_to_initiator: Vec<Vec<u8>> = responder
            .push_inbound_chunk(&framed_a)
            .await
            .unwrap()
            .into_iter()
            .filter_map(|e| match e {
                CrossNetworkInbound::OutboundFrame(b) => Some(b),
                _ => None,
            })
            .collect();

        for _ in 0..10 {
            if pending_to_initiator.is_empty() {
                break;
            }
            let frame = pending_to_initiator.remove(0);
            let framed = encode_frame(&frame).unwrap();
            let out_i = initiator.push_inbound_chunk(&framed).await.unwrap();
            for e in out_i {
                if let CrossNetworkInbound::OutboundFrame(b) = e {
                    let framed = encode_frame(&b).unwrap();
                    let out_r = responder.push_inbound_chunk(&framed).await.unwrap();
                    for er in out_r {
                        if let CrossNetworkInbound::OutboundFrame(bb) = er {
                            pending_to_initiator.push(bb);
                        }
                    }
                }
            }
            if initiator.is_established() && responder.is_established() {
                break;
            }
        }

        assert!(initiator.is_established());
        assert!(responder.is_established());

        let invalid = [0xD9, 0xB5, 0x05, 0x77, 0x00, 0x11, 0x22, 0x33];
        let events = responder.push_inbound_chunk(&invalid).await.unwrap();
        assert!(events.is_empty());

        let plaintext = b"recovered after invalid";
        let sealed = initiator.encrypt_app_payload(plaintext).unwrap();
        let framed = encode_frame(&sealed).unwrap();
        let out_r = responder.push_inbound_chunk(&framed).await.unwrap();
        let mut got = None;
        for event in out_r {
            if let CrossNetworkInbound::AppPayload(payload) = event {
                got = Some(payload);
            }
        }
        assert_eq!(got.unwrap(), plaintext);
    }
}
