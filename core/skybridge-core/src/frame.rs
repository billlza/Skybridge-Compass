use crate::padding::{decode_sbp2, encode_sbp2_fixed, Sbp2Error};
use crate::transport::SkyBridgeChannel;

const FRAME_MAGIC: &[u8; 4] = b"SBF1";
const FRAME_VERSION: u8 = 1;
pub const FRAME_HEADER_LEN: usize = 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameFlags(u16);

impl FrameFlags {
    pub const NONE: Self = Self(0);
    pub const SBP2_PADDED: Self = Self(0x0001);
    pub const END_OF_MESSAGE: Self = Self(0x0002);

    const KNOWN_MASK: u16 = Self::SBP2_PADDED.0 | Self::END_OF_MESSAGE.0;

    pub const fn bits(self) -> u16 {
        self.0
    }

    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    fn from_bits(bits: u16) -> Result<Self, FrameError> {
        if bits & !Self::KNOWN_MASK != 0 {
            return Err(FrameError::UnknownFlags(bits));
        }
        Ok(Self(bits))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreFrame {
    pub channel: SkyBridgeChannel,
    pub sequence: u64,
    pub flags: FrameFlags,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameError {
    PayloadTooLarge,
    FrameTooShort,
    BadMagic,
    UnsupportedVersion(u8),
    UnknownChannel(u8),
    UnknownFlags(u16),
    TruncatedPayload { expected: usize, actual: usize },
    Padding(Sbp2Error),
}

impl From<Sbp2Error> for FrameError {
    fn from(value: Sbp2Error) -> Self {
        Self::Padding(value)
    }
}

pub fn encode_frame(frame: &CoreFrame) -> Result<Vec<u8>, FrameError> {
    if frame.payload.len() > u32::MAX as usize {
        return Err(FrameError::PayloadTooLarge);
    }

    let mut encoded = Vec::with_capacity(FRAME_HEADER_LEN + frame.payload.len());
    encoded.extend_from_slice(FRAME_MAGIC);
    encoded.push(FRAME_VERSION);
    encoded.push(channel_code(frame.channel));
    encoded.extend_from_slice(&frame.flags.bits().to_be_bytes());
    encoded.extend_from_slice(&frame.sequence.to_be_bytes());
    encoded.extend_from_slice(&(frame.payload.len() as u32).to_be_bytes());
    encoded.extend_from_slice(&frame.payload);
    Ok(encoded)
}

pub fn encode_sbp2_frame(
    channel: SkyBridgeChannel,
    sequence: u64,
    payload: &[u8],
    padded_payload_len: usize,
) -> Result<Vec<u8>, FrameError> {
    let padded = encode_sbp2_fixed(payload, padded_payload_len)?;
    encode_frame(&CoreFrame {
        channel,
        sequence,
        flags: FrameFlags::SBP2_PADDED.union(FrameFlags::END_OF_MESSAGE),
        payload: padded,
    })
}

pub fn decode_frame(encoded: &[u8]) -> Result<CoreFrame, FrameError> {
    if encoded.len() < FRAME_HEADER_LEN {
        return Err(FrameError::FrameTooShort);
    }

    if &encoded[..4] != FRAME_MAGIC {
        return Err(FrameError::BadMagic);
    }

    let version = encoded[4];
    if version != FRAME_VERSION {
        return Err(FrameError::UnsupportedVersion(version));
    }

    let channel = channel_from_code(encoded[5])?;
    let flags = FrameFlags::from_bits(u16::from_be_bytes(
        encoded[6..8].try_into().expect("slice length"),
    ))?;
    let sequence = u64::from_be_bytes(encoded[8..16].try_into().expect("slice length"));
    let payload_len =
        u32::from_be_bytes(encoded[16..20].try_into().expect("slice length")) as usize;
    let actual = encoded.len() - FRAME_HEADER_LEN;
    if payload_len > actual {
        return Err(FrameError::TruncatedPayload {
            expected: payload_len,
            actual,
        });
    }

    Ok(CoreFrame {
        channel,
        sequence,
        flags,
        payload: encoded[FRAME_HEADER_LEN..FRAME_HEADER_LEN + payload_len].to_vec(),
    })
}

pub fn decode_frame_payload(frame: &CoreFrame) -> Result<Vec<u8>, FrameError> {
    if frame.flags.contains(FrameFlags::SBP2_PADDED) {
        return Ok(decode_sbp2(&frame.payload)?.payload);
    }
    Ok(frame.payload.clone())
}

fn channel_code(channel: SkyBridgeChannel) -> u8 {
    match channel {
        SkyBridgeChannel::Control => 1,
        SkyBridgeChannel::File => 2,
        SkyBridgeChannel::Clipboard => 3,
        SkyBridgeChannel::Telemetry => 4,
        SkyBridgeChannel::Realtime => 5,
    }
}

fn channel_from_code(code: u8) -> Result<SkyBridgeChannel, FrameError> {
    match code {
        1 => Ok(SkyBridgeChannel::Control),
        2 => Ok(SkyBridgeChannel::File),
        3 => Ok(SkyBridgeChannel::Clipboard),
        4 => Ok(SkyBridgeChannel::Telemetry),
        5 => Ok(SkyBridgeChannel::Realtime),
        other => Err(FrameError::UnknownChannel(other)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_roundtrip_preserves_channel_sequence_flags_and_payload() {
        let frame = CoreFrame {
            channel: SkyBridgeChannel::File,
            sequence: 42,
            flags: FrameFlags::END_OF_MESSAGE,
            payload: b"file-chunk".to_vec(),
        };

        let encoded = encode_frame(&frame).expect("encode");
        let decoded = decode_frame(&encoded).expect("decode");

        assert_eq!(decoded, frame);
        assert_eq!(decode_frame_payload(&decoded).unwrap(), b"file-chunk");
    }

    #[test]
    fn sbp2_frame_roundtrip_unwraps_padding_when_flagged() {
        let encoded =
            encode_sbp2_frame(SkyBridgeChannel::Control, 7, b"hello", 32).expect("encode");
        let decoded = decode_frame(&encoded).expect("decode");

        assert_eq!(decoded.channel, SkyBridgeChannel::Control);
        assert_eq!(decoded.sequence, 7);
        assert!(decoded.flags.contains(FrameFlags::SBP2_PADDED));
        assert_eq!(decode_frame_payload(&decoded).unwrap(), b"hello");
    }

    #[test]
    fn frame_decode_rejects_malformed_headers() {
        assert_eq!(decode_frame(b"SBF").unwrap_err(), FrameError::FrameTooShort);

        let frame = CoreFrame {
            channel: SkyBridgeChannel::Telemetry,
            sequence: 0,
            flags: FrameFlags::NONE,
            payload: Vec::new(),
        };
        let mut encoded = encode_frame(&frame).expect("encode");

        encoded[0] = b'X';
        assert_eq!(decode_frame(&encoded).unwrap_err(), FrameError::BadMagic);

        encoded[0] = b'S';
        encoded[4] = 2;
        assert_eq!(
            decode_frame(&encoded).unwrap_err(),
            FrameError::UnsupportedVersion(2)
        );

        encoded[4] = FRAME_VERSION;
        encoded[5] = 99;
        assert_eq!(
            decode_frame(&encoded).unwrap_err(),
            FrameError::UnknownChannel(99)
        );
    }

    #[test]
    fn frame_decode_rejects_unknown_flags_and_truncated_payload() {
        let frame = CoreFrame {
            channel: SkyBridgeChannel::Realtime,
            sequence: 9,
            flags: FrameFlags::NONE,
            payload: b"abc".to_vec(),
        };
        let mut encoded = encode_frame(&frame).expect("encode");

        encoded[6] = 0x80;
        encoded[7] = 0x00;
        assert_eq!(
            decode_frame(&encoded).unwrap_err(),
            FrameError::UnknownFlags(0x8000)
        );

        encoded[6] = 0;
        encoded[7] = 0;
        encoded.truncate(encoded.len() - 2);
        assert_eq!(
            decode_frame(&encoded).unwrap_err(),
            FrameError::TruncatedPayload {
                expected: 3,
                actual: 1,
            }
        );
    }
}
