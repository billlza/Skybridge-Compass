use rand_core::{OsRng, RngCore};

const SBP2_MAGIC: &[u8; 4] = b"SBP2";
const SBP2_HEADER_LEN: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrafficPaddingStats {
    pub actual_len: usize,
    pub padded_len: usize,
    pub padding_len: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sbp2DecodedFrame {
    pub payload: Vec<u8>,
    pub stats: TrafficPaddingStats,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Sbp2Error {
    PayloadTooLarge,
    TargetTooSmall {
        actual_len: usize,
        target_len: usize,
    },
    NoBucketForPayload {
        actual_len: usize,
    },
    FrameTooShort,
    BadMagic,
    TruncatedPayload {
        actual_len: usize,
        body_len: usize,
    },
}

pub fn encode_sbp2_fixed(payload: &[u8], padded_payload_len: usize) -> Result<Vec<u8>, Sbp2Error> {
    if payload.len() > u32::MAX as usize {
        return Err(Sbp2Error::PayloadTooLarge);
    }

    if padded_payload_len < payload.len() {
        return Err(Sbp2Error::TargetTooSmall {
            actual_len: payload.len(),
            target_len: padded_payload_len,
        });
    }

    let mut frame = Vec::with_capacity(SBP2_HEADER_LEN + padded_payload_len);
    frame.extend_from_slice(SBP2_MAGIC);
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(payload);

    let padding_len = padded_payload_len - payload.len();
    if padding_len > 0 {
        let mut padding = vec![0u8; padding_len];
        OsRng.fill_bytes(&mut padding);
        frame.extend_from_slice(&padding);
    }

    Ok(frame)
}

pub fn encode_sbp2_bucketed(payload: &[u8], buckets: &[usize]) -> Result<Vec<u8>, Sbp2Error> {
    let target = bucketed_target_len(payload.len(), buckets)?;
    encode_sbp2_fixed(payload, target)
}

pub fn decode_sbp2(frame: &[u8]) -> Result<Sbp2DecodedFrame, Sbp2Error> {
    if frame.len() < SBP2_HEADER_LEN {
        return Err(Sbp2Error::FrameTooShort);
    }

    if &frame[..4] != SBP2_MAGIC {
        return Err(Sbp2Error::BadMagic);
    }

    let actual_len = u32::from_be_bytes(frame[4..8].try_into().expect("slice length")) as usize;
    let body = &frame[SBP2_HEADER_LEN..];
    if actual_len > body.len() {
        return Err(Sbp2Error::TruncatedPayload {
            actual_len,
            body_len: body.len(),
        });
    }

    let padding_len = body.len() - actual_len;
    Ok(Sbp2DecodedFrame {
        payload: body[..actual_len].to_vec(),
        stats: TrafficPaddingStats {
            actual_len,
            padded_len: body.len(),
            padding_len,
        },
    })
}

pub fn bucketed_target_len(actual_len: usize, buckets: &[usize]) -> Result<usize, Sbp2Error> {
    buckets
        .iter()
        .copied()
        .filter(|bucket| *bucket >= actual_len)
        .min()
        .ok_or(Sbp2Error::NoBucketForPayload { actual_len })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_padding_roundtrip_preserves_payload_and_stats() {
        let payload = b"control-frame";
        let frame = encode_sbp2_fixed(payload, 32).expect("encode");

        assert_eq!(&frame[..4], SBP2_MAGIC);
        assert_eq!(frame.len(), SBP2_HEADER_LEN + 32);

        let decoded = decode_sbp2(&frame).expect("decode");
        assert_eq!(decoded.payload, payload);
        assert_eq!(
            decoded.stats,
            TrafficPaddingStats {
                actual_len: payload.len(),
                padded_len: 32,
                padding_len: 32 - payload.len(),
            }
        );
    }

    #[test]
    fn bucketed_padding_uses_smallest_matching_bucket() {
        let payload = vec![7u8; 130];
        let frame = encode_sbp2_bucketed(&payload, &[64, 256, 512]).expect("encode");
        let decoded = decode_sbp2(&frame).expect("decode");

        assert_eq!(decoded.payload, payload);
        assert_eq!(decoded.stats.padded_len, 256);
        assert_eq!(decoded.stats.padding_len, 126);
    }

    #[test]
    fn encode_rejects_too_small_targets_and_missing_buckets() {
        let small = encode_sbp2_fixed(b"abcdef", 3).unwrap_err();
        assert_eq!(
            small,
            Sbp2Error::TargetTooSmall {
                actual_len: 6,
                target_len: 3
            }
        );

        let missing = encode_sbp2_bucketed(b"abcdef", &[2, 4]).unwrap_err();
        assert_eq!(missing, Sbp2Error::NoBucketForPayload { actual_len: 6 });
    }

    #[test]
    fn decode_rejects_malformed_frames() {
        assert_eq!(decode_sbp2(b"SBP").unwrap_err(), Sbp2Error::FrameTooShort);

        let mut bad_magic = encode_sbp2_fixed(b"abc", 8).expect("encode");
        bad_magic[0] = b'X';
        assert_eq!(decode_sbp2(&bad_magic).unwrap_err(), Sbp2Error::BadMagic);

        let mut truncated = Vec::new();
        truncated.extend_from_slice(SBP2_MAGIC);
        truncated.extend_from_slice(&8u32.to_be_bytes());
        truncated.extend_from_slice(b"abc");
        assert_eq!(
            decode_sbp2(&truncated).unwrap_err(),
            Sbp2Error::TruncatedPayload {
                actual_len: 8,
                body_len: 3
            }
        );
    }
}
