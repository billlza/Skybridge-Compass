//! Length-framed byte transport helpers.
//!
//! This matches the macOS/iOS cross-network WebRTC DataChannel pattern:
//! - 4-byte big-endian length prefix
//! - payload bytes
//!
//! QUIC streams in this repo already use the same framing. This module extracts a shared codec
//! so we can plug in a future WebRTC DataChannel transport without changing handshake logic.

use crate::p2p::types::P2PError;

/// Default maximum frame size for cross-network transports (matches macOS/iOS guardrail).
pub const DEFAULT_MAX_FRAME_SIZE: usize = 8_000_000;

/// Encode a single frame: 4-byte big-endian length + payload.
pub fn encode_frame(payload: &[u8]) -> Result<Vec<u8>, P2PError> {
    encode_frame_with_limit(payload, DEFAULT_MAX_FRAME_SIZE)
}

/// Encode a single frame with a custom maximum size.
pub fn encode_frame_with_limit(payload: &[u8], max_frame_size: usize) -> Result<Vec<u8>, P2PError> {
    if payload.is_empty() {
        return Err(P2PError::InvalidMessage("empty frame".to_string()));
    }
    if payload.len() > max_frame_size {
        return Err(P2PError::InvalidMessage("frame too large".to_string()));
    }
    let mut out = Vec::with_capacity(4 + payload.len());
    let len = payload.len() as u32;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(payload);
    Ok(out)
}

/// Streaming frame decoder for length-prefixed frames.
///
/// This is meant for chunked transports like WebRTC DataChannel where an incoming "message"
/// might contain partial frames or multiple frames.
#[derive(Debug, Default)]
pub struct FrameDecoder {
    buf: Vec<u8>,
    max_frame_size: usize,
}

impl FrameDecoder {
    /// Create a new decoder with default max frame size.
    pub fn new() -> Self {
        Self::with_limit(DEFAULT_MAX_FRAME_SIZE)
    }

    /// Create a new decoder with a custom max frame size.
    pub fn with_limit(max_frame_size: usize) -> Self {
        Self {
            buf: Vec::new(),
            max_frame_size,
        }
    }

    /// Push raw bytes into the decoder and return any fully decoded frames.
    pub fn push(&mut self, data: &[u8]) -> Result<Vec<Vec<u8>>, P2PError> {
        if data.is_empty() {
            return Ok(Vec::new());
        }
        self.buf.extend_from_slice(data);

        let mut frames = Vec::new();
        loop {
            if self.buf.len() < 4 {
                break;
            }
            let len =
                u32::from_be_bytes([self.buf[0], self.buf[1], self.buf[2], self.buf[3]]) as usize;
            if len == 0 || len > self.max_frame_size {
                return Err(P2PError::InvalidMessage(format!(
                    "invalid frame length: {}",
                    len
                )));
            }
            if self.buf.len() < 4 + len {
                break;
            }
            let payload = self.buf[4..4 + len].to_vec();
            self.buf.drain(0..4 + len);
            frames.push(payload);
        }

        Ok(frames)
    }

    /// Push raw bytes into the decoder and recover from invalid length prefixes by
    /// clearing the buffered stream state.
    ///
    /// This is intended for already-established sessions where a single corrupted
    /// chunk should not tear down the entire connection.
    pub fn push_lossy(&mut self, data: &[u8]) -> Result<Vec<Vec<u8>>, P2PError> {
        match self.push(data) {
            Ok(frames) => Ok(frames),
            Err(P2PError::InvalidMessage(message))
                if message.starts_with("invalid frame length:") =>
            {
                self.clear();
                Ok(Vec::new())
            }
            Err(err) => Err(err),
        }
    }

    /// Clear any buffered partial data (e.g., on transport reset).
    pub fn clear(&mut self) {
        self.buf.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::RngExt;

    #[test]
    fn frame_decoder_reassembles_random_chunks() {
        let payload = b"hello framed world";
        let framed = encode_frame(payload).unwrap();

        for _ in 0..1_000 {
            let mut decoder = FrameDecoder::with_limit(DEFAULT_MAX_FRAME_SIZE);
            let mut offset = 0usize;
            let mut out = Vec::new();

            while offset < framed.len() {
                let mut step = [0u8; 1];
                rand::rng().fill(&mut step);
                let chunk_len = (step[0] as usize % 7).max(1);
                let end = (offset + chunk_len).min(framed.len());
                let frames = decoder.push(&framed[offset..end]).unwrap();
                out.extend(frames);
                offset = end;
            }

            assert_eq!(out.len(), 1);
            assert_eq!(out[0], payload);
        }
    }

    #[test]
    fn lossy_decoder_clears_invalid_length_and_recovers() {
        let mut decoder = FrameDecoder::with_limit(DEFAULT_MAX_FRAME_SIZE);
        let invalid = [0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03, 0x04];
        let frames = decoder.push_lossy(&invalid).unwrap();
        assert!(frames.is_empty());

        let payload = b"recovered";
        let framed = encode_frame(payload).unwrap();
        let frames = decoder.push_lossy(&framed).unwrap();
        assert_eq!(frames, vec![payload.to_vec()]);
    }
}
