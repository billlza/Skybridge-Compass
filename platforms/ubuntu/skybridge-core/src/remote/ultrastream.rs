//! UltraStream (USTR) receiver for macOS 26+ interoperability.
//!
//! This module implements:
//! - USTR v1 header parsing (28 bytes, big-endian fields)
//! - Frame reassembly from chunks
//! - AES-GCM decryption using PQC-derived session keys
//! - A pluggable decode chain

use std::collections::HashMap;
use std::time::{Duration, Instant};

#[cfg(all(target_os = "linux", feature = "ffmpeg"))]
use ffmpeg::software::scaling;
#[cfg(all(target_os = "linux", feature = "ffmpeg"))]
use ffmpeg::util::format::pixel::Pixel;
#[cfg(all(target_os = "linux", feature = "ffmpeg"))]
use ffmpeg_next as ffmpeg;
#[cfg(all(target_os = "linux", feature = "ffmpeg"))]
use libc::{EAGAIN, EWOULDBLOCK};
#[cfg(target_os = "linux")]
use openh264::formats::YUVSource;

use crate::crypto::aead::{AeadProvider, AesGcmProvider, EncryptedData};

const USTR_MAGIC: u32 = 0x5553_5452; // "USTR"
const USTR_HEADER_LEN: usize = 28;
const USTR_NONCE_LEN: usize = 12;
const USTR_VERSION: u8 = 1;
const USTR_DEFAULT_MAX_PAYLOAD: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UltraStreamCodec {
    H264,
    Hevc,
    Unknown(u8),
}

impl UltraStreamCodec {
    fn from_raw(raw: u8) -> Self {
        match raw {
            1 => Self::H264,
            2 => Self::Hevc,
            other => Self::Unknown(other),
        }
    }

    fn to_raw(self) -> u8 {
        match self {
            Self::H264 => 1,
            Self::Hevc => 2,
            Self::Unknown(raw) => raw,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UltraStreamFlags {
    raw: u8,
}

impl UltraStreamFlags {
    pub const HANDSHAKE: u8 = 1 << 0;
    pub const KEY_FRAME: u8 = 1 << 1;

    pub fn from_raw(raw: u8) -> Self {
        Self { raw }
    }

    pub fn is_handshake(&self) -> bool {
        self.raw & Self::HANDSHAKE != 0
    }

    pub fn raw(&self) -> u8 {
        self.raw
    }
}

#[derive(Debug, Clone)]
pub struct UltraStreamHeader {
    pub version: u8,
    pub flags: UltraStreamFlags,
    pub codec_raw: u8,
    pub reserved: u8,
    pub frame_id: u32,
    pub timestamp_ms: u32,
    pub width: u16,
    pub height: u16,
    pub chunk_index: u16,
    pub chunk_count: u16,
    pub payload_len: u32,
}

impl UltraStreamHeader {
    pub fn decode(data: &[u8]) -> Result<Self, UltraStreamError> {
        if data.len() < USTR_HEADER_LEN {
            return Err(UltraStreamError::InvalidPacket("short header".to_string()));
        }

        let mut offset = 0;
        let magic = read_u32_be(data, &mut offset);
        if magic != USTR_MAGIC {
            return Err(UltraStreamError::InvalidPacket("bad magic".to_string()));
        }

        let version = data[offset];
        offset += 1;
        let flags = UltraStreamFlags::from_raw(data[offset]);
        offset += 1;
        let codec_raw = data[offset];
        offset += 1;
        let reserved = data[offset];
        offset += 1;

        let frame_id = read_u32_be(data, &mut offset);
        let timestamp_ms = read_u32_be(data, &mut offset);
        let width = read_u16_be(data, &mut offset);
        let height = read_u16_be(data, &mut offset);
        let chunk_index = read_u16_be(data, &mut offset);
        let chunk_count = read_u16_be(data, &mut offset);
        let payload_len = read_u32_be(data, &mut offset);

        Ok(Self {
            version,
            flags,
            codec_raw,
            reserved,
            frame_id,
            timestamp_ms,
            width,
            height,
            chunk_index,
            chunk_count,
            payload_len,
        })
    }

    pub fn aad_data_for_frame(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(4 + 1 + 1 + 1 + 1 + 4 + 4 + 2 + 2 + 2 + 2);
        out.extend_from_slice(&USTR_MAGIC.to_be_bytes());
        out.push(self.version);
        out.push(self.flags.raw());
        out.push(self.codec_raw);
        out.push(self.reserved);
        out.extend_from_slice(&self.frame_id.to_be_bytes());
        out.extend_from_slice(&self.timestamp_ms.to_be_bytes());
        out.extend_from_slice(&self.width.to_be_bytes());
        out.extend_from_slice(&self.height.to_be_bytes());
        out.extend_from_slice(&0u16.to_be_bytes()); // chunkIndex for AAD
        out.extend_from_slice(&0u16.to_be_bytes()); // chunkCount for AAD
        out
    }
}

fn encode_header(header: &UltraStreamHeader) -> Vec<u8> {
    let mut out = Vec::with_capacity(USTR_HEADER_LEN);
    out.extend_from_slice(&USTR_MAGIC.to_be_bytes());
    out.push(header.version);
    out.push(header.flags.raw());
    out.push(header.codec_raw);
    out.push(header.reserved);
    out.extend_from_slice(&header.frame_id.to_be_bytes());
    out.extend_from_slice(&header.timestamp_ms.to_be_bytes());
    out.extend_from_slice(&header.width.to_be_bytes());
    out.extend_from_slice(&header.height.to_be_bytes());
    out.extend_from_slice(&header.chunk_index.to_be_bytes());
    out.extend_from_slice(&header.chunk_count.to_be_bytes());
    out.extend_from_slice(&header.payload_len.to_be_bytes());
    out
}

#[derive(Debug, Clone)]
pub struct UltraStreamFrame {
    pub codec: UltraStreamCodec,
    pub frame_id: u32,
    pub timestamp_ms: u32,
    pub width: u16,
    pub height: u16,
    pub data: Vec<u8>,
}

#[derive(Debug)]
pub enum UltraStreamDecodedFrame {
    Encoded(UltraStreamFrame),
    Bgra {
        width: u16,
        height: u16,
        data: Vec<u8>,
    },
}

pub trait UltraStreamDecoder {
    fn decode(
        &mut self,
        frame: &UltraStreamFrame,
    ) -> Result<UltraStreamDecodedFrame, UltraStreamError>;
}

pub struct PassthroughDecoder;

impl UltraStreamDecoder for PassthroughDecoder {
    fn decode(
        &mut self,
        frame: &UltraStreamFrame,
    ) -> Result<UltraStreamDecodedFrame, UltraStreamError> {
        Ok(UltraStreamDecodedFrame::Encoded(frame.clone()))
    }
}

#[cfg(target_os = "linux")]
fn looks_like_annexb(data: &[u8]) -> bool {
    data.starts_with(&[0x00, 0x00, 0x00, 0x01]) || data.starts_with(&[0x00, 0x00, 0x01])
}

/// Convert H.264/H.265 AVCC-style length-prefixed NAL units into Annex-B start code bytestream.
///
/// Returns `None` if the input is not a valid length-prefixed stream.
#[cfg(any(target_os = "linux", test))]
fn avcc_to_annexb(data: &[u8]) -> Option<Vec<u8>> {
    if data.len() < 4 {
        return None;
    }
    let mut out = Vec::with_capacity(data.len() + 4);
    let mut offset = 0usize;
    while offset + 4 <= data.len() {
        let len = u32::from_be_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]) as usize;
        offset += 4;
        if len == 0 || offset + len > data.len() {
            return None;
        }
        out.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
        out.extend_from_slice(&data[offset..offset + len]);
        offset += len;
    }
    if offset != data.len() {
        return None;
    }
    Some(out)
}

#[cfg(target_os = "linux")]
fn split_annexb_nals(data: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut i;

    fn find_start_code(data: &[u8], from: usize) -> Option<(usize, usize)> {
        let mut j = from;
        while j + 3 <= data.len() {
            if j + 4 <= data.len() && data[j..j + 4] == [0, 0, 0, 1] {
                return Some((j, 4));
            }
            if data[j..j + 3] == [0, 0, 1] {
                return Some((j, 3));
            }
            j += 1;
        }
        None
    }

    let Some((mut start, mut start_len)) = find_start_code(data, 0) else {
        return out;
    };
    i = start + start_len;

    while let Some((next, next_len)) = find_start_code(data, i) {
        if i < next {
            out.push(&data[i..next]);
        }
        start = next;
        start_len = next_len;
        i = start + start_len;
    }
    if i < data.len() {
        out.push(&data[i..]);
    }
    out
}

#[cfg(target_os = "linux")]
fn normalize_h264_bytestream(data: &[u8]) -> Vec<u8> {
    if looks_like_annexb(data) {
        return data.to_vec();
    }
    avcc_to_annexb(data).unwrap_or_else(|| data.to_vec())
}

#[cfg(target_os = "linux")]
pub struct OpenH264Decoder {
    decoder: openh264::decoder::Decoder,
    cached_param_sets: Option<Vec<u8>>,
}

#[cfg(target_os = "linux")]
impl OpenH264Decoder {
    pub fn new() -> Result<Self, UltraStreamError> {
        let decoder = openh264::decoder::Decoder::new()
            .map_err(|err| UltraStreamError::Decode(err.to_string()))?;
        Ok(Self {
            decoder,
            cached_param_sets: None,
        })
    }

    fn decoded_to_frame(
        yuv: openh264::decoder::DecodedYUV<'_>,
    ) -> Result<UltraStreamDecodedFrame, UltraStreamError> {
        let (width, height) = yuv.dimensions();
        let rgb_len = width * height * 3;
        let mut rgb = vec![0u8; rgb_len];
        yuv.write_rgb8(&mut rgb);

        let mut bgra = Vec::with_capacity(rgb_len / 3 * 4);
        for chunk in rgb.chunks_exact(3) {
            let r = chunk[0];
            let g = chunk[1];
            let b = chunk[2];
            bgra.extend_from_slice(&[b, g, r, 255]);
        }

        Ok(UltraStreamDecodedFrame::Bgra {
            width: width as u16,
            height: height as u16,
            data: bgra,
        })
    }
}

#[cfg(target_os = "linux")]
impl UltraStreamDecoder for OpenH264Decoder {
    fn decode(
        &mut self,
        frame: &UltraStreamFrame,
    ) -> Result<UltraStreamDecodedFrame, UltraStreamError> {
        if frame.codec != UltraStreamCodec::H264 {
            return Err(UltraStreamError::UnsupportedCodec(format!(
                "{:?}",
                frame.codec
            )));
        }

        // macOS VideoToolbox commonly outputs AVCC (length-prefixed) H.264.
        // Convert to Annex-B for OpenH264 and cache SPS/PPS when present.
        let mut decode_bytes = normalize_h264_bytestream(&frame.data);
        let has_param_in_frame = {
            let nals = split_annexb_nals(&decode_bytes);
            let mut saw_param = false;
            let mut param_out: Vec<u8> = Vec::new();
            for nal in &nals {
                let Some(first) = nal.first() else {
                    continue;
                };
                let nal_type = first & 0x1F;
                if nal_type == 7 || nal_type == 8 {
                    saw_param = true;
                    param_out.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
                    param_out.extend_from_slice(nal);
                }
            }
            if saw_param && !param_out.is_empty() {
                self.cached_param_sets = Some(param_out);
            }
            nals.iter().any(|nal| {
                nal.first()
                    .is_some_and(|b| (b & 0x1F) == 7 || (b & 0x1F) == 8)
            })
        };
        if !has_param_in_frame && let Some(ps) = self.cached_param_sets.as_ref() {
            let mut merged = Vec::with_capacity(ps.len() + decode_bytes.len());
            merged.extend_from_slice(ps);
            merged.extend_from_slice(&decode_bytes);
            decode_bytes = merged;
        }

        for packet in openh264::nal_units(&decode_bytes) {
            match self.decoder.decode(packet) {
                Ok(Some(yuv)) => return Self::decoded_to_frame(yuv),
                Ok(None) => {}
                Err(err) => return Err(UltraStreamError::Decode(err.to_string())),
            }
        }

        match self.decoder.decode(&decode_bytes) {
            Ok(Some(yuv)) => Self::decoded_to_frame(yuv),
            Ok(None) => Err(UltraStreamError::FrameIncomplete),
            Err(err) => Err(UltraStreamError::Decode(err.to_string())),
        }
    }
}

#[cfg(all(target_os = "linux", feature = "ffmpeg"))]
pub struct HevcDecoder {
    decoder: ffmpeg::decoder::Video,
    scaler: Option<scaling::Context>,
}

#[cfg(all(target_os = "linux", feature = "ffmpeg"))]
impl HevcDecoder {
    pub fn new() -> Result<Self, UltraStreamError> {
        ffmpeg::init().map_err(|err| UltraStreamError::Decode(err.to_string()))?;
        let codec = ffmpeg::codec::decoder::find(ffmpeg::codec::Id::HEVC).ok_or_else(|| {
            UltraStreamError::UnsupportedCodec("HEVC decoder not found".to_string())
        })?;
        let context = ffmpeg::codec::Context::new();
        let decoder = context
            .decoder()
            .open_as(codec)
            .map_err(|err| UltraStreamError::Decode(err.to_string()))?
            .video()
            .map_err(|err| UltraStreamError::Decode(err.to_string()))?;

        Ok(Self {
            decoder,
            scaler: None,
        })
    }

    fn decode_packet(
        &mut self,
        packet_data: &[u8],
    ) -> Result<Option<UltraStreamDecodedFrame>, UltraStreamError> {
        let packet = ffmpeg::Packet::copy(packet_data);
        self.decoder
            .send_packet(&packet)
            .map_err(|err| UltraStreamError::Decode(err.to_string()))?;

        let mut decoded = ffmpeg::frame::Video::empty();
        match self.decoder.receive_frame(&mut decoded) {
            Ok(()) => Ok(Some(self.decode_to_bgra(decoded)?)),
            Err(err) if is_ffmpeg_again(&err) || matches!(err, ffmpeg::Error::Eof) => Ok(None),
            Err(err) => Err(UltraStreamError::Decode(err.to_string())),
        }
    }

    fn decode_to_bgra(
        &mut self,
        decoded: ffmpeg::frame::Video,
    ) -> Result<UltraStreamDecodedFrame, UltraStreamError> {
        let width = decoded.width();
        let height = decoded.height();
        let src_format = decoded.format();

        let needs_scaler = self.scaler.as_ref().is_none_or(|ctx| {
            ctx.input().format != src_format
                || ctx.input().width != width
                || ctx.input().height != height
        });
        if needs_scaler {
            self.scaler = Some(
                scaling::Context::get(
                    src_format,
                    width,
                    height,
                    Pixel::BGRA,
                    width,
                    height,
                    scaling::Flags::FAST_BILINEAR,
                )
                .map_err(|err| UltraStreamError::Decode(err.to_string()))?,
            );
        }

        let scaler = self
            .scaler
            .as_mut()
            .ok_or_else(|| UltraStreamError::Decode("scaler unavailable".to_string()))?;
        let mut output = ffmpeg::frame::Video::new(Pixel::BGRA, width, height);
        scaler
            .run(&decoded, &mut output)
            .map_err(|err| UltraStreamError::Decode(err.to_string()))?;

        let stride = output.stride(0);
        let row_bytes = width as usize * 4;
        if stride < row_bytes {
            return Err(UltraStreamError::Decode("invalid BGRA stride".to_string()));
        }

        let data = output.data(0);
        let mut bgra = vec![0u8; row_bytes * height as usize];
        for y in 0..height as usize {
            let src_offset = y * stride;
            let dst_offset = y * row_bytes;
            let src_row = &data[src_offset..src_offset + row_bytes];
            let dst_row = &mut bgra[dst_offset..dst_offset + row_bytes];
            dst_row.copy_from_slice(src_row);
        }

        Ok(UltraStreamDecodedFrame::Bgra {
            width: width as u16,
            height: height as u16,
            data: bgra,
        })
    }
}

#[cfg(all(target_os = "linux", feature = "ffmpeg"))]
impl UltraStreamDecoder for HevcDecoder {
    fn decode(
        &mut self,
        frame: &UltraStreamFrame,
    ) -> Result<UltraStreamDecodedFrame, UltraStreamError> {
        if frame.codec != UltraStreamCodec::Hevc {
            return Err(UltraStreamError::UnsupportedCodec(format!(
                "{:?}",
                frame.codec
            )));
        }

        let mut decoded = None;
        for packet in openh264::nal_units(&frame.data) {
            if let Some(frame) = self.decode_packet(packet)? {
                decoded = Some(frame);
            }
        }

        if decoded.is_none() {
            decoded = self.decode_packet(&frame.data)?;
        }

        decoded.ok_or(UltraStreamError::FrameIncomplete)
    }
}

#[cfg(all(target_os = "linux", feature = "ffmpeg"))]
fn is_ffmpeg_again(err: &ffmpeg::Error) -> bool {
    matches!(
        err,
        ffmpeg::Error::Other { errno }
            if *errno == EAGAIN || *errno == EWOULDBLOCK
    )
}

#[cfg(not(all(target_os = "linux", feature = "ffmpeg")))]
pub struct HevcDecoder;

#[cfg(not(all(target_os = "linux", feature = "ffmpeg")))]
impl HevcDecoder {
    pub fn new() -> Result<Self, UltraStreamError> {
        Err(UltraStreamError::UnsupportedCodec(
            "HEVC decoder requires ffmpeg feature".to_string(),
        ))
    }
}

#[cfg(not(all(target_os = "linux", feature = "ffmpeg")))]
impl UltraStreamDecoder for HevcDecoder {
    fn decode(
        &mut self,
        _frame: &UltraStreamFrame,
    ) -> Result<UltraStreamDecodedFrame, UltraStreamError> {
        Err(UltraStreamError::UnsupportedCodec(
            "HEVC decoder requires ffmpeg feature".to_string(),
        ))
    }
}

pub struct AutoDecoder {
    h264: Option<OpenH264Decoder>,
    hevc: Option<HevcDecoder>,
}

impl AutoDecoder {
    pub fn new() -> Result<Self, UltraStreamError> {
        let h264 = OpenH264Decoder::new().ok();
        let hevc = HevcDecoder::new().ok();
        if h264.is_none() && hevc.is_none() {
            return Err(UltraStreamError::UnsupportedCodec(
                "no video decoders available".to_string(),
            ));
        }
        Ok(Self { h264, hevc })
    }
}

impl UltraStreamDecoder for AutoDecoder {
    fn decode(
        &mut self,
        frame: &UltraStreamFrame,
    ) -> Result<UltraStreamDecodedFrame, UltraStreamError> {
        match frame.codec {
            UltraStreamCodec::H264 => self
                .h264
                .as_mut()
                .ok_or_else(|| {
                    UltraStreamError::UnsupportedCodec("H264 decoder unavailable".to_string())
                })?
                .decode(frame),
            UltraStreamCodec::Hevc => self
                .hevc
                .as_mut()
                .ok_or_else(|| {
                    UltraStreamError::UnsupportedCodec("HEVC decoder unavailable".to_string())
                })?
                .decode(frame),
            UltraStreamCodec::Unknown(raw) => Err(UltraStreamError::UnsupportedCodec(format!(
                "unknown codec {}",
                raw
            ))),
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub struct OpenH264Decoder;

#[cfg(not(target_os = "linux"))]
impl OpenH264Decoder {
    pub fn new() -> Result<Self, UltraStreamError> {
        Err(UltraStreamError::UnsupportedCodec(
            "OpenH264 decoder is only available on Linux".to_string(),
        ))
    }
}

#[cfg(not(target_os = "linux"))]
impl UltraStreamDecoder for OpenH264Decoder {
    fn decode(
        &mut self,
        _frame: &UltraStreamFrame,
    ) -> Result<UltraStreamDecodedFrame, UltraStreamError> {
        Err(UltraStreamError::UnsupportedCodec(
            "OpenH264 decoder is only available on Linux".to_string(),
        ))
    }
}

pub trait UltraStreamSink {
    fn on_frame(&mut self, frame: UltraStreamDecodedFrame) -> Result<(), UltraStreamError>;
}

pub struct NullSink;

impl UltraStreamSink for NullSink {
    fn on_frame(&mut self, _frame: UltraStreamDecodedFrame) -> Result<(), UltraStreamError> {
        Ok(())
    }
}

pub struct UltraStreamReceiver {
    key: Vec<u8>,
    assemblies: HashMap<u32, FrameAssembly>,
    frame_timestamps: HashMap<u32, Instant>,
    frame_timeout: Duration,
}

pub struct UltraStreamSender {
    key: Vec<u8>,
    frame_id: u32,
    max_payload: usize,
}

impl UltraStreamSender {
    pub fn new(key: Vec<u8>) -> Result<Self, UltraStreamError> {
        if key.len() != 32 {
            return Err(UltraStreamError::InvalidKeyLength);
        }
        Ok(Self {
            key,
            frame_id: 0,
            max_payload: USTR_DEFAULT_MAX_PAYLOAD,
        })
    }

    pub fn new_with_session_keys(keys: &crate::p2p::SessionKeys) -> Result<Self, UltraStreamError> {
        Self::new(keys.send_video_key.clone())
    }

    pub fn set_max_payload(&mut self, max_payload: usize) {
        self.max_payload = max_payload.max(1);
    }

    pub fn max_payload(&self) -> usize {
        self.max_payload
    }

    pub fn encode_frame(
        &mut self,
        codec: UltraStreamCodec,
        width: u16,
        height: u16,
        timestamp_ms: u32,
        data: &[u8],
    ) -> Result<Vec<Vec<u8>>, UltraStreamError> {
        let frame_id = self.frame_id;
        self.frame_id = self.frame_id.wrapping_add(1);

        let base_header = UltraStreamHeader {
            version: USTR_VERSION,
            flags: UltraStreamFlags::from_raw(0),
            codec_raw: codec.to_raw(),
            reserved: 0,
            frame_id,
            timestamp_ms,
            width,
            height,
            chunk_index: 0,
            chunk_count: 0,
            payload_len: 0,
        };
        let aad = base_header.aad_data_for_frame();
        let encrypted = encrypt_payload(data, &aad, &self.key)?;
        let combined = encrypted.to_bytes();

        let total_chunks = if combined.is_empty() {
            1
        } else {
            combined.len().div_ceil(self.max_payload)
        };
        if total_chunks > u16::MAX as usize {
            return Err(UltraStreamError::InvalidPacket(
                "frame too large".to_string(),
            ));
        }

        let mut packets = Vec::with_capacity(total_chunks);
        for idx in 0..total_chunks {
            let start = idx * self.max_payload;
            let end = (start + self.max_payload).min(combined.len());
            let payload = if start < end {
                &combined[start..end]
            } else {
                &[][..]
            };
            let header = UltraStreamHeader {
                version: USTR_VERSION,
                flags: UltraStreamFlags::from_raw(0),
                codec_raw: codec.to_raw(),
                reserved: 0,
                frame_id,
                timestamp_ms,
                width,
                height,
                chunk_index: idx as u16,
                chunk_count: total_chunks as u16,
                payload_len: payload.len() as u32,
            };
            let mut packet = encode_header(&header);
            packet.extend_from_slice(payload);
            packets.push(packet);
        }

        Ok(packets)
    }
}

impl UltraStreamReceiver {
    pub fn new(key: Vec<u8>) -> Result<Self, UltraStreamError> {
        if key.len() != 32 {
            return Err(UltraStreamError::InvalidKeyLength);
        }
        Ok(Self {
            key,
            assemblies: HashMap::new(),
            frame_timestamps: HashMap::new(),
            frame_timeout: Duration::from_secs(5),
        })
    }

    pub fn new_with_session_keys(keys: &crate::p2p::SessionKeys) -> Result<Self, UltraStreamError> {
        Self::new(keys.recv_video_key.clone())
    }

    pub fn handle_packet(
        &mut self,
        packet: &[u8],
    ) -> Result<Option<UltraStreamFrame>, UltraStreamError> {
        self.prune_expired();
        let header = UltraStreamHeader::decode(packet)?;
        if header.flags.is_handshake() {
            return Ok(None);
        }
        let payload = extract_payload(packet, header.payload_len as usize)?;

        {
            let assembly = self
                .assemblies
                .entry(header.frame_id)
                .or_insert_with(|| FrameAssembly::new(&header));
            assembly.insert(header.chunk_index, payload);
            self.frame_timestamps
                .insert(header.frame_id, Instant::now());
        }

        let (frame_meta, combined, aad) = {
            let assembly = self
                .assemblies
                .get(&header.frame_id)
                .ok_or(UltraStreamError::FrameIncomplete)?;
            if !assembly.is_complete() {
                return Ok(None);
            }
            (
                (
                    assembly.codec_raw,
                    assembly.frame_id,
                    assembly.timestamp_ms,
                    assembly.width,
                    assembly.height,
                ),
                assembly.combined()?,
                assembly.aad_data(),
            )
        };

        let decrypted = decrypt_payload(&combined, &aad, &self.key)?;
        let frame = UltraStreamFrame {
            codec: UltraStreamCodec::from_raw(frame_meta.0),
            frame_id: frame_meta.1,
            timestamp_ms: frame_meta.2,
            width: frame_meta.3,
            height: frame_meta.4,
            data: decrypted,
        };

        self.assemblies.remove(&frame_meta.1);
        self.frame_timestamps.remove(&frame_meta.1);
        Ok(Some(frame))
    }

    pub fn handle_packet_with_decoder<D: UltraStreamDecoder + ?Sized>(
        &mut self,
        packet: &[u8],
        decoder: &mut D,
    ) -> Result<Option<UltraStreamDecodedFrame>, UltraStreamError> {
        if let Some(frame) = self.handle_packet(packet)? {
            return Ok(Some(decoder.decode(&frame)?));
        }
        Ok(None)
    }

    fn prune_expired(&mut self) {
        let now = Instant::now();
        let expired: Vec<u32> = self
            .frame_timestamps
            .iter()
            .filter_map(|(id, ts)| {
                if now.duration_since(*ts) > self.frame_timeout {
                    Some(*id)
                } else {
                    None
                }
            })
            .collect();
        for id in expired {
            self.assemblies.remove(&id);
            self.frame_timestamps.remove(&id);
        }
    }
}

pub struct UltraStreamPipeline<D: UltraStreamDecoder, S: UltraStreamSink> {
    receiver: UltraStreamReceiver,
    decoder: D,
    sink: S,
}

impl<D: UltraStreamDecoder, S: UltraStreamSink> UltraStreamPipeline<D, S> {
    pub fn new(receiver: UltraStreamReceiver, decoder: D, sink: S) -> Self {
        Self {
            receiver,
            decoder,
            sink,
        }
    }

    pub fn handle_packet(&mut self, packet: &[u8]) -> Result<(), UltraStreamError> {
        if let Some(frame) = self
            .receiver
            .handle_packet_with_decoder(packet, &mut self.decoder)?
        {
            self.sink.on_frame(frame)?;
        }
        Ok(())
    }
}

pub struct UltraStreamSession {
    receiver: UltraStreamReceiver,
    decoder: Box<dyn UltraStreamDecoder + Send>,
    sink: Box<dyn UltraStreamSink + Send>,
}

impl UltraStreamSession {
    pub fn new(
        receiver: UltraStreamReceiver,
        decoder: Box<dyn UltraStreamDecoder + Send>,
        sink: Box<dyn UltraStreamSink + Send>,
    ) -> Self {
        Self {
            receiver,
            decoder,
            sink,
        }
    }

    pub fn handle_packet(&mut self, packet: &[u8]) -> Result<(), UltraStreamError> {
        if let Some(frame) = self
            .receiver
            .handle_packet_with_decoder(packet, &mut *self.decoder)?
        {
            self.sink.on_frame(frame)?;
        }
        Ok(())
    }
}

struct FrameAssembly {
    version: u8,
    flags_raw: u8,
    frame_id: u32,
    codec_raw: u8,
    reserved: u8,
    timestamp_ms: u32,
    width: u16,
    height: u16,
    total_chunks: u16,
    chunks: HashMap<u16, Vec<u8>>,
}

impl FrameAssembly {
    fn new(header: &UltraStreamHeader) -> Self {
        Self {
            version: header.version,
            flags_raw: header.flags.raw(),
            frame_id: header.frame_id,
            codec_raw: header.codec_raw,
            reserved: header.reserved,
            timestamp_ms: header.timestamp_ms,
            width: header.width,
            height: header.height,
            total_chunks: header.chunk_count,
            chunks: HashMap::new(),
        }
    }

    fn insert(&mut self, idx: u16, data: Vec<u8>) {
        self.chunks.insert(idx, data);
    }

    fn is_complete(&self) -> bool {
        self.chunks.len() == self.total_chunks as usize
    }

    fn combined(&self) -> Result<Vec<u8>, UltraStreamError> {
        if !self.is_complete() {
            return Err(UltraStreamError::FrameIncomplete);
        }
        let mut out = Vec::new();
        for idx in 0..self.total_chunks {
            let chunk = self
                .chunks
                .get(&idx)
                .ok_or(UltraStreamError::FrameIncomplete)?;
            out.extend_from_slice(chunk);
        }
        Ok(out)
    }

    fn aad_data(&self) -> Vec<u8> {
        let header = UltraStreamHeader {
            version: self.version,
            flags: UltraStreamFlags::from_raw(self.flags_raw),
            codec_raw: self.codec_raw,
            reserved: self.reserved,
            frame_id: self.frame_id,
            timestamp_ms: self.timestamp_ms,
            width: self.width,
            height: self.height,
            chunk_index: 0,
            chunk_count: 0,
            payload_len: 0,
        };
        header.aad_data_for_frame()
    }
}

fn decrypt_payload(combined: &[u8], aad: &[u8], key: &[u8]) -> Result<Vec<u8>, UltraStreamError> {
    let encrypted = EncryptedData::from_bytes(combined, USTR_NONCE_LEN)
        .ok_or_else(|| UltraStreamError::InvalidPacket("missing nonce".to_string()))?;
    let provider = AesGcmProvider::new();
    provider
        .decrypt(key, &encrypted, aad)
        .map_err(|e| UltraStreamError::Crypto(e.to_string()))
}

fn encrypt_payload(
    plaintext: &[u8],
    aad: &[u8],
    key: &[u8],
) -> Result<EncryptedData, UltraStreamError> {
    let provider = AesGcmProvider::new();
    provider
        .encrypt(key, plaintext, aad)
        .map_err(|e| UltraStreamError::Crypto(e.to_string()))
}

fn extract_payload(packet: &[u8], payload_len: usize) -> Result<Vec<u8>, UltraStreamError> {
    if packet.len() < USTR_HEADER_LEN + payload_len {
        return Err(UltraStreamError::InvalidPacket(
            "truncated payload".to_string(),
        ));
    }
    Ok(packet[USTR_HEADER_LEN..USTR_HEADER_LEN + payload_len].to_vec())
}

#[cfg(test)]
mod avcc_tests {
    use super::*;

    #[test]
    fn avcc_to_annexb_converts_length_prefixed() {
        // Two fake NAL units: [0x65, 0x01] and [0x41]
        let mut avcc = Vec::new();
        avcc.extend_from_slice(&(2u32.to_be_bytes()));
        avcc.extend_from_slice(&[0x65, 0x01]);
        avcc.extend_from_slice(&(1u32.to_be_bytes()));
        avcc.extend_from_slice(&[0x41]);

        let annexb = avcc_to_annexb(&avcc).unwrap();
        assert_eq!(annexb, vec![0, 0, 0, 1, 0x65, 0x01, 0, 0, 0, 1, 0x41]);
    }

    #[test]
    fn avcc_to_annexb_rejects_trailing_bytes() {
        let mut avcc = Vec::new();
        avcc.extend_from_slice(&(1u32.to_be_bytes()));
        avcc.extend_from_slice(&[0x65]);
        avcc.push(0x00); // trailing garbage
        assert!(avcc_to_annexb(&avcc).is_none());
    }
}

fn read_u16_be(data: &[u8], offset: &mut usize) -> u16 {
    let value = u16::from_be_bytes([data[*offset], data[*offset + 1]]);
    *offset += 2;
    value
}

fn read_u32_be(data: &[u8], offset: &mut usize) -> u32 {
    let value = u32::from_be_bytes([
        data[*offset],
        data[*offset + 1],
        data[*offset + 2],
        data[*offset + 3],
    ]);
    *offset += 4;
    value
}

#[derive(Debug, thiserror::Error)]
pub enum UltraStreamError {
    #[error("invalid packet: {0}")]
    InvalidPacket(String),
    #[error("invalid key length")]
    InvalidKeyLength,
    #[error("crypto error: {0}")]
    Crypto(String),
    #[error("frame incomplete")]
    FrameIncomplete,
    #[error("unsupported codec: {0}")]
    UnsupportedCodec(String),
    #[error("decode error: {0}")]
    Decode(String),
}
