use std::borrow::Cow;
use std::collections::{BTreeSet, HashMap};

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use getrandom::fill as fill_random;
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::{ClassicSessionKeys, RuntimeSessionRole};

const MAGIC: u32 = 0x5342_5743;
const VERSION: u8 = 1;
pub(super) const HEADER_LENGTH: usize = 52;
const TAG_LENGTH: usize = 16;
const EPOCH: u32 = 0;
const DIRECTION_INITIATOR_TO_RESPONDER: u8 = 1;
const DIRECTION_RESPONDER_TO_INITIATOR: u8 = 2;
const SESSION_ID_DOMAIN: &[u8] = b"SkyBridge-SessionId-v1|";
const APP_SESSION_DOMAIN: &[u8] = b"SkyBridge-WebRTC-App-Session-v1|";
const APP_TRANSCRIPT_DOMAIN: &[u8] = b"SkyBridge-WebRTC-App-Transcript-v1|";
const MAX_SECURE_ENVELOPE_BYTES: usize = 8_000_000;
const MAX_SECURE_PLAINTEXT_BYTES: usize = MAX_SECURE_ENVELOPE_BYTES - HEADER_LENGTH - TAG_LENGTH;
const REPLAY_WINDOW_SIZE: u64 = 1024;
const TRAFFIC_PADDING_MAGIC: &[u8; 4] = b"SBP2";
const TRAFFIC_PADDING_HEADER_LENGTH: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub(super) enum WebRtcAppSecurePacketType {
    AppControl = 1,
    FileTransfer = 2,
    RemoteControl = 3,
    RemoteDesktop = 4,
    RemoteDesktopAudio = 5,
}

impl TryFrom<u8> for WebRtcAppSecurePacketType {
    type Error = WebRtcAppSecureEnvelopeError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::AppControl),
            2 => Ok(Self::FileTransfer),
            3 => Ok(Self::RemoteControl),
            4 => Ok(Self::RemoteDesktop),
            5 => Ok(Self::RemoteDesktopAudio),
            raw => Err(WebRtcAppSecureEnvelopeError::UnsupportedPacketType(raw)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ReplayRejectionReason {
    DuplicateCounter,
    CounterOutsideWindow,
}

impl std::fmt::Display for ReplayRejectionReason {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::DuplicateCounter => formatter.write_str("duplicate-counter"),
            Self::CounterOutsideWindow => formatter.write_str("counter-outside-window"),
        }
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub(super) enum WebRtcAppSecureEnvelopeError {
    #[error("malformed WebRTC secure envelope")]
    Malformed,
    #[error("WebRTC secure envelope exceeds byte limit: {actual} > {maximum}")]
    EnvelopeTooLarge { actual: usize, maximum: usize },
    #[error("unsupported WebRTC secure envelope magic={0}")]
    UnsupportedMagic(u32),
    #[error("unsupported WebRTC secure envelope version={0}")]
    UnsupportedVersion(u8),
    #[error("unsupported WebRTC secure envelope packetType={0}")]
    UnsupportedPacketType(u8),
    #[error("WebRTC secure envelope packetType mismatch actual={actual}")]
    PacketTypeMismatch { actual: u8 },
    #[error("WebRTC secure envelope direction mismatch expected={expected} actual={actual}")]
    DirectionMismatch { expected: u8, actual: u8 },
    #[error("WebRTC secure envelope session mismatch expected={expected} actual={actual}")]
    SessionMismatch { expected: u64, actual: u64 },
    #[error("WebRTC secure envelope transcript mismatch expected={expected} actual={actual}")]
    TranscriptMismatch { expected: u64, actual: u64 },
    #[error("WebRTC secure envelope epoch mismatch expected={expected} actual={actual}")]
    EpochMismatch { expected: u32, actual: u32 },
    #[error(
        "WebRTC secure envelope authentication failed packetType={packet_type} counter={counter}"
    )]
    AuthenticationFailed { packet_type: u8, counter: u64 },
    #[error("WebRTC secure envelope invalid counter={0}")]
    InvalidCounter(u64),
    #[error("WebRTC secure envelope key must be 32 bytes, got {0}")]
    InvalidKeyLength(usize),
    #[error("WebRTC transcript hash must be 32 bytes, got {0}")]
    InvalidTranscriptHashLength(usize),
    #[error("failed to generate WebRTC secure envelope nonce")]
    NonceGenerationFailed,
    #[error(
        "WebRTC secure envelope replay detected packetType={packet_type} counter={counter} highestCounter={highest_counter} reason={reason}"
    )]
    ReplayDetected {
        packet_type: u8,
        counter: u64,
        highest_counter: u64,
        reason: ReplayRejectionReason,
    },
    #[error("malformed SBP2 traffic padding")]
    MalformedTrafficPadding,
    #[error("SBP2 unwrapped payload exceeds byte limit: {actual} > {maximum}")]
    TrafficPaddingPayloadTooLarge { actual: usize, maximum: usize },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct OpenedPayload {
    pub(super) packet_type: WebRtcAppSecurePacketType,
    direction: u8,
    session_hash: u64,
    transcript_prefix: u64,
    epoch: u32,
    pub(super) counter: u64,
    pub(super) payload: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct ReplayScope {
    packet_type: WebRtcAppSecurePacketType,
    direction: u8,
    session_hash: u64,
    transcript_prefix: u64,
    epoch: u32,
}

#[derive(Debug, Default)]
struct ReplayLane {
    highest_counter: u64,
    recorded_counters: BTreeSet<u64>,
}

#[derive(Debug, Default)]
pub(super) struct ReplayWindow {
    lanes: HashMap<ReplayScope, ReplayLane>,
}

impl ReplayWindow {
    pub(super) fn validate_and_record(
        &mut self,
        opened: &OpenedPayload,
    ) -> Result<(), WebRtcAppSecureEnvelopeError> {
        if opened.counter == 0 {
            return Err(WebRtcAppSecureEnvelopeError::InvalidCounter(0));
        }
        let scope = ReplayScope {
            packet_type: opened.packet_type,
            direction: opened.direction,
            session_hash: opened.session_hash,
            transcript_prefix: opened.transcript_prefix,
            epoch: opened.epoch,
        };
        let lane = self.lanes.entry(scope).or_default();
        let highest_counter = lane.highest_counter;
        if opened.counter > highest_counter {
            lane.highest_counter = opened.counter;
            lane.recorded_counters.insert(opened.counter);
            let minimum_counter_to_keep = if lane.highest_counter > REPLAY_WINDOW_SIZE {
                lane.highest_counter - REPLAY_WINDOW_SIZE + 1
            } else {
                1
            };
            lane.recorded_counters
                .retain(|counter| *counter >= minimum_counter_to_keep);
            return Ok(());
        }

        let counter_distance = highest_counter - opened.counter;
        if counter_distance >= REPLAY_WINDOW_SIZE {
            return Err(WebRtcAppSecureEnvelopeError::ReplayDetected {
                packet_type: opened.packet_type as u8,
                counter: opened.counter,
                highest_counter,
                reason: ReplayRejectionReason::CounterOutsideWindow,
            });
        }
        if !lane.recorded_counters.insert(opened.counter) {
            return Err(WebRtcAppSecureEnvelopeError::ReplayDetected {
                packet_type: opened.packet_type as u8,
                counter: opened.counter,
                highest_counter,
                reason: ReplayRejectionReason::DuplicateCounter,
            });
        }
        Ok(())
    }
}

pub(super) fn seal(
    plaintext: &[u8],
    keys: &ClassicSessionKeys,
    role: RuntimeSessionRole,
    packet_type: WebRtcAppSecurePacketType,
    counter: u64,
) -> Result<Vec<u8>, WebRtcAppSecureEnvelopeError> {
    let mut nonce = [0u8; 12];
    fill_random(&mut nonce).map_err(|_| WebRtcAppSecureEnvelopeError::NonceGenerationFailed)?;
    seal_with_nonce(plaintext, keys, role, packet_type, counter, nonce)
}

fn seal_with_nonce(
    plaintext: &[u8],
    keys: &ClassicSessionKeys,
    role: RuntimeSessionRole,
    packet_type: WebRtcAppSecurePacketType,
    counter: u64,
    nonce: [u8; 12],
) -> Result<Vec<u8>, WebRtcAppSecureEnvelopeError> {
    if counter == 0 {
        return Err(WebRtcAppSecureEnvelopeError::InvalidCounter(counter));
    }
    if plaintext.len() > MAX_SECURE_PLAINTEXT_BYTES {
        return Err(WebRtcAppSecureEnvelopeError::EnvelopeTooLarge {
            actual: plaintext.len(),
            maximum: MAX_SECURE_PLAINTEXT_BYTES,
        });
    }
    validate_binding_material(keys)?;
    let payload_length =
        u32::try_from(plaintext.len()).map_err(|_| WebRtcAppSecureEnvelopeError::Malformed)?;
    let mut header = Vec::with_capacity(HEADER_LENGTH);
    header.extend_from_slice(&MAGIC.to_be_bytes());
    header.push(VERSION);
    header.push(HEADER_LENGTH as u8);
    header.push(packet_type as u8);
    header.push(send_direction(role));
    header.extend_from_slice(&session_hash(&keys.transcript_hash)?.to_be_bytes());
    header.extend_from_slice(&transcript_prefix(&keys.transcript_hash)?.to_be_bytes());
    header.extend_from_slice(&EPOCH.to_be_bytes());
    header.extend_from_slice(&counter.to_be_bytes());
    header.extend_from_slice(&payload_length.to_be_bytes());
    header.extend_from_slice(&nonce);
    debug_assert_eq!(header.len(), HEADER_LENGTH);

    let cipher = cipher(&keys.send_key)?;
    let encrypted = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &header,
            },
        )
        .map_err(|_| WebRtcAppSecureEnvelopeError::AuthenticationFailed {
            packet_type: packet_type as u8,
            counter,
        })?;
    let mut packet = header;
    packet.extend_from_slice(&encrypted);
    Ok(packet)
}

pub(super) fn open(
    packet: &[u8],
    keys: &ClassicSessionKeys,
    role: RuntimeSessionRole,
    allowed_packet_types: &[WebRtcAppSecurePacketType],
) -> Result<OpenedPayload, WebRtcAppSecureEnvelopeError> {
    if packet.len() > MAX_SECURE_ENVELOPE_BYTES {
        return Err(WebRtcAppSecureEnvelopeError::EnvelopeTooLarge {
            actual: packet.len(),
            maximum: MAX_SECURE_ENVELOPE_BYTES,
        });
    }
    if packet.len() < HEADER_LENGTH + TAG_LENGTH {
        return Err(WebRtcAppSecureEnvelopeError::Malformed);
    }
    validate_binding_material(keys)?;
    let parsed = parse_header(packet)?;
    let expected_direction = receive_direction(role);
    if parsed.direction != expected_direction {
        return Err(WebRtcAppSecureEnvelopeError::DirectionMismatch {
            expected: expected_direction,
            actual: parsed.direction,
        });
    }
    let expected_session_hash = session_hash(&keys.transcript_hash)?;
    if parsed.session_hash != expected_session_hash {
        return Err(WebRtcAppSecureEnvelopeError::SessionMismatch {
            expected: expected_session_hash,
            actual: parsed.session_hash,
        });
    }
    let expected_transcript_prefix = transcript_prefix(&keys.transcript_hash)?;
    if parsed.transcript_prefix != expected_transcript_prefix {
        return Err(WebRtcAppSecureEnvelopeError::TranscriptMismatch {
            expected: expected_transcript_prefix,
            actual: parsed.transcript_prefix,
        });
    }
    if parsed.epoch != EPOCH {
        return Err(WebRtcAppSecureEnvelopeError::EpochMismatch {
            expected: EPOCH,
            actual: parsed.epoch,
        });
    }
    if parsed.counter == 0 {
        return Err(WebRtcAppSecureEnvelopeError::InvalidCounter(0));
    }

    let cipher = cipher(&keys.receive_key)?;
    let plaintext = cipher
        .decrypt(
            Nonce::from_slice(&parsed.nonce),
            Payload {
                msg: &packet[HEADER_LENGTH..],
                aad: &packet[..HEADER_LENGTH],
            },
        )
        .map_err(|_| WebRtcAppSecureEnvelopeError::AuthenticationFailed {
            packet_type: parsed.packet_type as u8,
            counter: parsed.counter,
        })?;
    if !allowed_packet_types.contains(&parsed.packet_type) {
        return Err(WebRtcAppSecureEnvelopeError::PacketTypeMismatch {
            actual: parsed.packet_type as u8,
        });
    }
    Ok(OpenedPayload {
        packet_type: parsed.packet_type,
        direction: parsed.direction,
        session_hash: parsed.session_hash,
        transcript_prefix: parsed.transcript_prefix,
        epoch: parsed.epoch,
        counter: parsed.counter,
        payload: plaintext,
    })
}

pub(super) fn unwrap_traffic_padding<'a>(
    packet: &'a [u8],
    maximum_unwrapped_bytes: usize,
) -> Result<Cow<'a, [u8]>, WebRtcAppSecureEnvelopeError> {
    if !packet.starts_with(TRAFFIC_PADDING_MAGIC) {
        return Ok(Cow::Borrowed(packet));
    }
    if packet.len() < TRAFFIC_PADDING_HEADER_LENGTH {
        return Err(WebRtcAppSecureEnvelopeError::MalformedTrafficPadding);
    }
    let actual_length = u32::from_be_bytes(
        packet[4..8]
            .try_into()
            .map_err(|_| WebRtcAppSecureEnvelopeError::MalformedTrafficPadding)?,
    ) as usize;
    if actual_length > maximum_unwrapped_bytes {
        return Err(
            WebRtcAppSecureEnvelopeError::TrafficPaddingPayloadTooLarge {
                actual: actual_length,
                maximum: maximum_unwrapped_bytes,
            },
        );
    }
    let payload_end = TRAFFIC_PADDING_HEADER_LENGTH
        .checked_add(actual_length)
        .ok_or(WebRtcAppSecureEnvelopeError::MalformedTrafficPadding)?;
    if payload_end > packet.len() {
        return Err(WebRtcAppSecureEnvelopeError::MalformedTrafficPadding);
    }
    Ok(Cow::Borrowed(
        &packet[TRAFFIC_PADDING_HEADER_LENGTH..payload_end],
    ))
}

#[derive(Debug)]
struct ParsedHeader {
    packet_type: WebRtcAppSecurePacketType,
    direction: u8,
    session_hash: u64,
    transcript_prefix: u64,
    epoch: u32,
    counter: u64,
    nonce: [u8; 12],
}

fn parse_header(packet: &[u8]) -> Result<ParsedHeader, WebRtcAppSecureEnvelopeError> {
    let magic = read_u32(packet, 0)?;
    if magic != MAGIC {
        return Err(WebRtcAppSecureEnvelopeError::UnsupportedMagic(magic));
    }
    if packet[4] != VERSION {
        return Err(WebRtcAppSecureEnvelopeError::UnsupportedVersion(packet[4]));
    }
    if packet[5] as usize != HEADER_LENGTH {
        return Err(WebRtcAppSecureEnvelopeError::Malformed);
    }
    let packet_type = WebRtcAppSecurePacketType::try_from(packet[6])?;
    let payload_length = read_u32(packet, 36)? as usize;
    if payload_length > MAX_SECURE_PLAINTEXT_BYTES {
        return Err(WebRtcAppSecureEnvelopeError::EnvelopeTooLarge {
            actual: payload_length,
            maximum: MAX_SECURE_PLAINTEXT_BYTES,
        });
    }
    let expected_packet_length = HEADER_LENGTH
        .checked_add(payload_length)
        .and_then(|length| length.checked_add(TAG_LENGTH))
        .ok_or(WebRtcAppSecureEnvelopeError::Malformed)?;
    if packet.len() != expected_packet_length {
        return Err(WebRtcAppSecureEnvelopeError::Malformed);
    }
    let mut nonce = [0u8; 12];
    nonce.copy_from_slice(&packet[40..52]);
    Ok(ParsedHeader {
        packet_type,
        direction: packet[7],
        session_hash: read_u64(packet, 8)?,
        transcript_prefix: read_u64(packet, 16)?,
        epoch: read_u32(packet, 24)?,
        counter: read_u64(packet, 28)?,
        nonce,
    })
}

fn cipher(key: &[u8]) -> Result<Aes256Gcm, WebRtcAppSecureEnvelopeError> {
    if key.len() != 32 {
        return Err(WebRtcAppSecureEnvelopeError::InvalidKeyLength(key.len()));
    }
    Aes256Gcm::new_from_slice(key)
        .map_err(|_| WebRtcAppSecureEnvelopeError::InvalidKeyLength(key.len()))
}

fn validate_binding_material(
    keys: &ClassicSessionKeys,
) -> Result<(), WebRtcAppSecureEnvelopeError> {
    if keys.transcript_hash.len() != 32 {
        return Err(WebRtcAppSecureEnvelopeError::InvalidTranscriptHashLength(
            keys.transcript_hash.len(),
        ));
    }
    Ok(())
}

fn send_direction(role: RuntimeSessionRole) -> u8 {
    match role {
        RuntimeSessionRole::Initiator => DIRECTION_INITIATOR_TO_RESPONDER,
        RuntimeSessionRole::Responder => DIRECTION_RESPONDER_TO_INITIATOR,
    }
}

fn receive_direction(role: RuntimeSessionRole) -> u8 {
    match role {
        RuntimeSessionRole::Initiator => DIRECTION_RESPONDER_TO_INITIATOR,
        RuntimeSessionRole::Responder => DIRECTION_INITIATOR_TO_RESPONDER,
    }
}

fn deterministic_handshake_session_id(
    transcript_hash: &[u8],
) -> Result<String, WebRtcAppSecureEnvelopeError> {
    if transcript_hash.len() != 32 {
        return Err(WebRtcAppSecureEnvelopeError::InvalidTranscriptHashLength(
            transcript_hash.len(),
        ));
    }
    let mut hasher = Sha256::new();
    hasher.update(SESSION_ID_DOMAIN);
    hasher.update(transcript_hash);
    let digest = hasher.finalize();
    let mut session_id = String::with_capacity(35);
    session_id.push_str("hs-");
    for byte in &digest[..16] {
        use std::fmt::Write;
        write!(&mut session_id, "{byte:02x}").expect("writing to String cannot fail");
    }
    Ok(session_id)
}

fn session_hash(transcript_hash: &[u8]) -> Result<u64, WebRtcAppSecureEnvelopeError> {
    let session_id = deterministic_handshake_session_id(transcript_hash)?;
    Ok(domain_separated_prefix_u64(
        APP_SESSION_DOMAIN,
        session_id.as_bytes(),
    ))
}

fn transcript_prefix(transcript_hash: &[u8]) -> Result<u64, WebRtcAppSecureEnvelopeError> {
    if transcript_hash.len() != 32 {
        return Err(WebRtcAppSecureEnvelopeError::InvalidTranscriptHashLength(
            transcript_hash.len(),
        ));
    }
    Ok(domain_separated_prefix_u64(
        APP_TRANSCRIPT_DOMAIN,
        transcript_hash,
    ))
}

fn domain_separated_prefix_u64(domain: &[u8], value: &[u8]) -> u64 {
    let mut hasher = Sha256::new();
    hasher.update(domain);
    hasher.update(value);
    let digest = hasher.finalize();
    u64::from_be_bytes(
        digest[..8]
            .try_into()
            .expect("SHA-256 has at least 8 bytes"),
    )
}

fn read_u32(packet: &[u8], offset: usize) -> Result<u32, WebRtcAppSecureEnvelopeError> {
    packet
        .get(offset..offset + 4)
        .ok_or(WebRtcAppSecureEnvelopeError::Malformed)?
        .try_into()
        .map(u32::from_be_bytes)
        .map_err(|_| WebRtcAppSecureEnvelopeError::Malformed)
}

fn read_u64(packet: &[u8], offset: usize) -> Result<u64, WebRtcAppSecureEnvelopeError> {
    packet
        .get(offset..offset + 8)
        .ok_or(WebRtcAppSecureEnvelopeError::Malformed)?
        .try_into()
        .map(u64::from_be_bytes)
        .map_err(|_| WebRtcAppSecureEnvelopeError::Malformed)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXED_PLAINTEXT: &[u8] = b"webrtc-app-message";

    fn fixed_keys(role: RuntimeSessionRole) -> ClassicSessionKeys {
        let (send_key, receive_key) = match role {
            RuntimeSessionRole::Initiator => (vec![0xa1; 32], vec![0xb2; 32]),
            RuntimeSessionRole::Responder => (vec![0xb2; 32], vec![0xa1; 32]),
        };
        ClassicSessionKeys {
            send_key,
            receive_key,
            negotiated_suite: "test".to_owned(),
            peer_protocol_public_key_fingerprint: "test-fingerprint".to_owned(),
            transcript_hash: vec![0xc3; 32],
        }
    }

    fn decode_hex(value: &str) -> Vec<u8> {
        value
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| {
                let text = std::str::from_utf8(pair).expect("hex fixture is ASCII");
                u8::from_str_radix(text, 16).expect("hex fixture is valid")
            })
            .collect()
    }

    fn fixed_packet() -> Vec<u8> {
        decode_hex(concat!(
            "5342574301340101935cb3cb383c118908a5169f1e98ab4e",
            "00000000000000000000000100000012000102030405060708090a0b",
            "db4e6b85933c0e8a7adf8f2c6c0a778d4e7c",
            "75d69faf3b2fb1d20d892c9b45a8aa5f"
        ))
    }

    #[test]
    fn apple_session_binding_and_fixed_packet_vectors_match() {
        let keys = fixed_keys(RuntimeSessionRole::Initiator);
        assert_eq!(
            deterministic_handshake_session_id(&keys.transcript_hash).expect("session id"),
            "hs-a4aced729a2b9b079511cf8eed178f57"
        );
        assert_eq!(
            session_hash(&keys.transcript_hash).expect("session hash"),
            0x935c_b3cb_383c_1189
        );
        assert_eq!(
            transcript_prefix(&keys.transcript_hash).expect("transcript prefix"),
            0x08a5_169f_1e98_ab4e
        );

        let packet = seal_with_nonce(
            FIXED_PLAINTEXT,
            &keys,
            RuntimeSessionRole::Initiator,
            WebRtcAppSecurePacketType::AppControl,
            1,
            [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
        )
        .expect("fixed packet seal");
        assert_eq!(packet, fixed_packet());
        assert_eq!(packet.len(), 86);
        assert_eq!(
            &packet[..HEADER_LENGTH],
            decode_hex(concat!(
                "5342574301340101935cb3cb383c118908a5169f1e98ab4e",
                "00000000000000000000000100000012000102030405060708090a0b"
            ))
        );
    }

    #[test]
    fn apple_fixed_packet_opens_for_responder() {
        let opened = open(
            &fixed_packet(),
            &fixed_keys(RuntimeSessionRole::Responder),
            RuntimeSessionRole::Responder,
            &[WebRtcAppSecurePacketType::AppControl],
        )
        .expect("fixed packet open");
        assert_eq!(opened.packet_type, WebRtcAppSecurePacketType::AppControl);
        assert_eq!(opened.counter, 1);
        assert_eq!(opened.payload, FIXED_PLAINTEXT);
    }

    #[test]
    fn header_bindings_packet_type_and_tag_fail_closed() {
        let keys = fixed_keys(RuntimeSessionRole::Responder);
        let mut direction = fixed_packet();
        direction[7] = DIRECTION_RESPONDER_TO_INITIATOR;
        assert!(matches!(
            open(
                &direction,
                &keys,
                RuntimeSessionRole::Responder,
                &[WebRtcAppSecurePacketType::AppControl]
            ),
            Err(WebRtcAppSecureEnvelopeError::DirectionMismatch { .. })
        ));

        let mut session = fixed_packet();
        session[8] ^= 1;
        assert!(matches!(
            open(
                &session,
                &keys,
                RuntimeSessionRole::Responder,
                &[WebRtcAppSecurePacketType::AppControl]
            ),
            Err(WebRtcAppSecureEnvelopeError::SessionMismatch { .. })
        ));

        let mut transcript = fixed_packet();
        transcript[16] ^= 1;
        assert!(matches!(
            open(
                &transcript,
                &keys,
                RuntimeSessionRole::Responder,
                &[WebRtcAppSecurePacketType::AppControl]
            ),
            Err(WebRtcAppSecureEnvelopeError::TranscriptMismatch { .. })
        ));

        let mut epoch = fixed_packet();
        epoch[27] = 1;
        assert!(matches!(
            open(
                &epoch,
                &keys,
                RuntimeSessionRole::Responder,
                &[WebRtcAppSecurePacketType::AppControl]
            ),
            Err(WebRtcAppSecureEnvelopeError::EpochMismatch { .. })
        ));

        let mut packet_type = fixed_packet();
        packet_type[6] = WebRtcAppSecurePacketType::FileTransfer as u8;
        assert!(matches!(
            open(
                &packet_type,
                &keys,
                RuntimeSessionRole::Responder,
                &[
                    WebRtcAppSecurePacketType::AppControl,
                    WebRtcAppSecurePacketType::FileTransfer,
                ]
            ),
            Err(WebRtcAppSecureEnvelopeError::AuthenticationFailed { .. })
        ));
        assert!(matches!(
            open(
                &fixed_packet(),
                &keys,
                RuntimeSessionRole::Responder,
                &[WebRtcAppSecurePacketType::FileTransfer]
            ),
            Err(WebRtcAppSecureEnvelopeError::PacketTypeMismatch { .. })
        ));

        let mut tag = fixed_packet();
        *tag.last_mut().expect("tag byte") ^= 1;
        assert!(matches!(
            open(
                &tag,
                &keys,
                RuntimeSessionRole::Responder,
                &[WebRtcAppSecurePacketType::AppControl]
            ),
            Err(WebRtcAppSecureEnvelopeError::AuthenticationFailed { .. })
        ));
    }

    #[test]
    fn replay_window_accepts_bounded_reordering_and_rejects_duplicates_and_old_counters() {
        let template = open(
            &fixed_packet(),
            &fixed_keys(RuntimeSessionRole::Responder),
            RuntimeSessionRole::Responder,
            &[WebRtcAppSecurePacketType::AppControl],
        )
        .expect("fixed packet open");
        let mut replay = ReplayWindow::default();
        replay
            .validate_and_record(&template)
            .expect("first counter");
        assert!(matches!(
            replay.validate_and_record(&template),
            Err(WebRtcAppSecureEnvelopeError::ReplayDetected {
                reason: ReplayRejectionReason::DuplicateCounter,
                ..
            })
        ));

        let mut high = template.clone();
        high.counter = 1025;
        let mut reordered = template.clone();
        reordered.counter = 2;
        let mut too_old = template.clone();
        too_old.counter = 1;
        let mut reordered_window = ReplayWindow::default();
        reordered_window
            .validate_and_record(&high)
            .expect("highest counter");
        reordered_window
            .validate_and_record(&reordered)
            .expect("counter inside 1024 window");
        assert!(matches!(
            reordered_window.validate_and_record(&too_old),
            Err(WebRtcAppSecureEnvelopeError::ReplayDetected {
                reason: ReplayRejectionReason::CounterOutsideWindow,
                ..
            })
        ));
    }

    #[test]
    fn strict_sbp2_unwrap_rejects_malformed_lengths_and_preserves_non_magic() {
        let raw = b"not-sbp2";
        assert_eq!(
            unwrap_traffic_padding(raw, 64).expect("non-magic passthrough"),
            Cow::Borrowed(raw.as_slice())
        );

        let mut wrapped = b"SBP2".to_vec();
        wrapped.extend_from_slice(&3_u32.to_be_bytes());
        wrapped.extend_from_slice(b"abc-padding");
        assert_eq!(
            unwrap_traffic_padding(&wrapped, 64).expect("valid SBP2"),
            Cow::Borrowed(b"abc".as_slice())
        );

        assert!(matches!(
            unwrap_traffic_padding(b"SBP2", 64),
            Err(WebRtcAppSecureEnvelopeError::MalformedTrafficPadding)
        ));
        let mut truncated = b"SBP2".to_vec();
        truncated.extend_from_slice(&9_u32.to_be_bytes());
        truncated.extend_from_slice(b"abc");
        assert!(matches!(
            unwrap_traffic_padding(&truncated, 64),
            Err(WebRtcAppSecureEnvelopeError::MalformedTrafficPadding)
        ));
        let mut oversized = b"SBP2".to_vec();
        oversized.extend_from_slice(&65_u32.to_be_bytes());
        oversized.extend_from_slice(&[0u8; 65]);
        assert!(matches!(
            unwrap_traffic_padding(&oversized, 64),
            Err(WebRtcAppSecureEnvelopeError::TrafficPaddingPayloadTooLarge { .. })
        ));
    }
}
