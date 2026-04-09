//! Video Encoding Module
//!
//! Provides hardware-accelerated video encoding for remote desktop streaming.
//! Supports OpenH264 (software), VAAPI (AMD/Intel), and NVENC (NVIDIA).

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use thiserror::Error;

use super::capture::CapturedFrame;

/// Video encoding errors
#[derive(Debug, Error)]
pub enum EncoderError {
    /// No encoder available
    #[error("No video encoder available")]
    NoEncoder,

    /// Hardware encoder not supported
    #[error("Hardware encoder not available: {0}")]
    HardwareNotAvailable(String),

    /// Encoding error
    #[error("Encoding error: {0}")]
    Encoding(String),

    /// Invalid frame
    #[error("Invalid frame: {0}")]
    InvalidFrame(String),

    /// Not initialized
    #[error("Encoder not initialized")]
    NotInitialized,

    /// Codec error
    #[error("Codec error: {0}")]
    Codec(String),

    /// IO error
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

/// Hardware encoder type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum HardwareEncoder {
    /// NVIDIA NVENC
    Nvenc,
    /// Intel/AMD VAAPI
    Vaapi,
    /// Software (OpenH264)
    Software,
    /// Auto-detect best available
    Auto,
}

impl HardwareEncoder {
    /// Detect available hardware encoder
    pub fn detect() -> Self {
        // Check for NVIDIA
        if Self::is_nvenc_available() {
            return Self::Nvenc;
        }

        // Check for VAAPI (Intel/AMD)
        if Self::is_vaapi_available() {
            return Self::Vaapi;
        }

        // Fallback to software
        Self::Software
    }

    /// Check if NVENC is available
    pub fn is_nvenc_available() -> bool {
        std::process::Command::new("nvidia-smi")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    /// Check if VAAPI is available
    pub fn is_vaapi_available() -> bool {
        PathBuf::from("/dev/dri/renderD128").exists()
            || std::process::Command::new("vainfo")
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false)
    }

    /// Get encoder name for FFmpeg
    pub fn ffmpeg_encoder(&self, codec: VideoCodec) -> &'static str {
        match (self, codec) {
            (_, VideoCodec::Auto) => "auto",
            (Self::Nvenc, VideoCodec::H264) => "h264_nvenc",
            (Self::Nvenc, VideoCodec::H265) => "hevc_nvenc",
            (Self::Nvenc, VideoCodec::Av1) => "av1_nvenc",
            (Self::Vaapi, VideoCodec::H264) => "h264_vaapi",
            (Self::Vaapi, VideoCodec::H265) => "hevc_vaapi",
            (Self::Vaapi, VideoCodec::Av1) => "av1_vaapi",
            (Self::Software | Self::Auto, VideoCodec::H264) => "libopenh264",
            (Self::Software | Self::Auto, VideoCodec::H265) => "libx265",
            (Self::Software | Self::Auto, VideoCodec::Av1) => "libaom-av1",
        }
    }
}

/// Video codec
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum VideoCodec {
    /// Automatically resolve to the safest available production codec.
    Auto,
    /// H.264/AVC
    #[default]
    H264,
    /// H.265/HEVC
    H265,
    /// AV1
    Av1,
}

/// Host-side sender capability probe used to avoid pretending that a decode-only
/// capability is also valid for outbound production streaming.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SenderCapabilityResolver {
    /// Preferred backend for the current host.
    pub encoder: HardwareEncoder,
    /// Host can send H.264.
    pub h264: bool,
    /// Host can send HEVC/H.265.
    pub hevc: bool,
    /// Host can send AV1.
    pub av1: bool,
}

impl SenderCapabilityResolver {
    /// Probe the current host using production-safe heuristics.
    pub fn probe(preferred_hardware: HardwareEncoder) -> Self {
        let encoder = if preferred_hardware == HardwareEncoder::Auto {
            HardwareEncoder::detect()
        } else {
            preferred_hardware
        };

        match encoder {
            HardwareEncoder::Nvenc => Self {
                encoder,
                h264: true,
                hevc: true,
                av1: false,
            },
            HardwareEncoder::Vaapi => Self {
                encoder,
                h264: true,
                hevc: true,
                av1: false,
            },
            HardwareEncoder::Software | HardwareEncoder::Auto => Self {
                encoder: HardwareEncoder::Software,
                h264: true,
                hevc: false,
                av1: false,
            },
        }
    }

    /// Returns true if the host can actually send the requested codec.
    pub fn supports_send(&self, codec: VideoCodec) -> bool {
        match codec {
            VideoCodec::Auto => self.h264 || self.hevc,
            VideoCodec::H264 => self.h264,
            VideoCodec::H265 => self.hevc,
            VideoCodec::Av1 => self.av1,
        }
    }

    /// Resolve a requested codec to a concrete send codec using safe fallbacks.
    pub fn resolve_requested_codec(&self, codec: VideoCodec, low_latency: bool) -> VideoCodec {
        match codec {
            VideoCodec::Auto => {
                if low_latency {
                    if self.h264 {
                        VideoCodec::H264
                    } else if self.hevc {
                        VideoCodec::H265
                    } else {
                        VideoCodec::H264
                    }
                } else if self.hevc {
                    VideoCodec::H265
                } else {
                    VideoCodec::H264
                }
            }
            VideoCodec::H264 if self.h264 => VideoCodec::H264,
            VideoCodec::H265 if self.hevc => VideoCodec::H265,
            VideoCodec::Av1 if self.av1 => VideoCodec::Av1,
            VideoCodec::H265 | VideoCodec::Av1 => {
                if self.h264 {
                    VideoCodec::H264
                } else if self.hevc {
                    VideoCodec::H265
                } else {
                    VideoCodec::H264
                }
            }
            _ => VideoCodec::H264,
        }
    }
}

/// Rate control mode
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum RateControl {
    /// Constant Bitrate
    Cbr,
    /// Variable Bitrate
    Vbr,
    /// Constant Quality (CRF/CQP)
    #[default]
    ConstantQuality,
}

/// Encoder configuration
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EncoderConfig {
    /// Video codec
    pub codec: VideoCodec,
    /// Hardware encoder
    pub hardware: HardwareEncoder,
    /// Target bitrate (bps)
    pub bitrate: u32,
    /// Max bitrate for VBR (bps)
    pub max_bitrate: u32,
    /// Target framerate
    pub framerate: u32,
    /// Keyframe interval (frames)
    pub keyframe_interval: u32,
    /// Rate control mode
    pub rate_control: RateControl,
    /// Quality level (0-51 for H.264, lower = better)
    pub quality: u8,
    /// Encoding preset (speed vs quality tradeoff)
    pub preset: EncoderPreset,
    /// Enable B-frames
    pub b_frames: bool,
    /// Low latency mode
    pub low_latency: bool,
    /// Tune for screen content
    pub tune_screen: bool,
}

impl Default for EncoderConfig {
    fn default() -> Self {
        Self {
            codec: VideoCodec::H264,
            hardware: HardwareEncoder::Auto,
            bitrate: 8_000_000,      // 8 Mbps
            max_bitrate: 12_000_000, // 12 Mbps
            framerate: 30,
            keyframe_interval: 60, // 2 seconds at 30fps
            rate_control: RateControl::ConstantQuality,
            quality: 23, // CRF 23 for H.264
            preset: EncoderPreset::Fast,
            b_frames: false, // Disable for low latency
            low_latency: true,
            tune_screen: true,
        }
    }
}

impl EncoderConfig {
    /// Create config for LAN streaming (high quality, low latency)
    pub fn for_lan() -> Self {
        Self {
            bitrate: 20_000_000, // 20 Mbps
            max_bitrate: 30_000_000,
            framerate: 60,
            quality: 18,
            preset: EncoderPreset::LowLatency,
            ..Default::default()
        }
    }

    /// Create config for WAN streaming (balanced)
    pub fn for_wan() -> Self {
        Self {
            bitrate: 5_000_000, // 5 Mbps
            max_bitrate: 8_000_000,
            framerate: 30,
            quality: 26,
            preset: EncoderPreset::Medium,
            ..Default::default()
        }
    }

    /// Create config for mobile/low bandwidth
    pub fn for_mobile() -> Self {
        Self {
            bitrate: 2_000_000, // 2 Mbps
            max_bitrate: 3_000_000,
            framerate: 24,
            quality: 30,
            preset: EncoderPreset::Fast,
            ..Default::default()
        }
    }
}

/// Encoder preset (speed vs quality tradeoff)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum EncoderPreset {
    /// Fastest encoding, lowest quality
    UltraFast,
    /// Very fast encoding
    VeryFast,
    /// Fast encoding
    #[default]
    Fast,
    /// Medium speed/quality
    Medium,
    /// Slow encoding, better quality
    Slow,
    /// Optimized for low latency streaming
    LowLatency,
}

impl EncoderPreset {
    /// Get x264 preset string
    pub fn x264_preset(&self) -> &'static str {
        match self {
            Self::UltraFast => "ultrafast",
            Self::VeryFast => "veryfast",
            Self::Fast => "fast",
            Self::Medium => "medium",
            Self::Slow => "slow",
            Self::LowLatency => "zerolatency",
        }
    }

    /// Get NVENC preset string
    pub fn nvenc_preset(&self) -> &'static str {
        match self {
            Self::UltraFast => "p1",
            Self::VeryFast => "p2",
            Self::Fast => "p3",
            Self::Medium => "p4",
            Self::Slow => "p6",
            Self::LowLatency => "p1",
        }
    }
}

/// Encoded frame
#[derive(Debug, Clone)]
pub struct EncodedFrame {
    /// Encoded data (NAL units for H.264)
    pub data: Vec<u8>,
    /// Presentation timestamp
    pub pts: u64,
    /// Decode timestamp
    pub dts: u64,
    /// Is this a keyframe
    pub is_keyframe: bool,
    /// Frame type (I, P, B)
    pub frame_type: FrameType,
    /// Original frame width
    pub width: u32,
    /// Original frame height
    pub height: u32,
}

/// Frame type
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameType {
    /// I-frame (keyframe)
    I,
    /// P-frame (predicted)
    P,
    /// B-frame (bi-directional)
    B,
}

/// Encoder statistics
#[derive(Debug, Clone, Default)]
pub struct EncoderStats {
    /// Total frames encoded
    pub frames_encoded: u64,
    /// Total bytes output
    pub bytes_output: u64,
    /// Average encoding time (microseconds)
    pub avg_encode_time_us: u64,
    /// Current bitrate (bps)
    pub current_bitrate: u64,
    /// Dropped frames
    pub dropped_frames: u64,
    /// Keyframes encoded
    pub keyframes: u64,
}

/// Video encoder trait
#[async_trait::async_trait]
pub trait VideoEncoder: Send + Sync {
    /// Initialize the encoder
    async fn initialize(&mut self, width: u32, height: u32) -> Result<(), EncoderError>;

    /// Encode a frame
    async fn encode(&mut self, frame: &CapturedFrame) -> Result<EncodedFrame, EncoderError>;

    /// Force a keyframe on next encode
    fn request_keyframe(&mut self);

    /// Update encoder configuration
    fn update_config(&mut self, config: &EncoderConfig) -> Result<(), EncoderError>;

    /// Get encoder statistics
    fn stats(&self) -> EncoderStats;

    /// Get encoder type
    fn encoder_type(&self) -> HardwareEncoder;

    /// Flush encoder (get remaining frames)
    async fn flush(&mut self) -> Result<Vec<EncodedFrame>, EncoderError>;

    /// Shutdown encoder
    async fn shutdown(&mut self) -> Result<(), EncoderError>;
}

// Platform-specific implementations
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
pub use linux::{OpenH264Encoder, SoftwareEncoder, VaapiEncoder};

// Fallback implementations for non-Linux platforms
#[cfg(not(target_os = "linux"))]
mod fallback;

#[cfg(not(target_os = "linux"))]
pub use fallback::{OpenH264Encoder, SoftwareEncoder, VaapiEncoder};

/// NVENC encoder (stub for now - requires NVIDIA SDK)
pub struct NvencEncoder {
    config: EncoderConfig,
    width: u32,
    height: u32,
    initialized: bool,
    stats: EncoderStats,
    frame_count: u64,
    force_keyframe: bool,
}

impl NvencEncoder {
    /// Create a new NVENC encoder
    pub fn new(config: EncoderConfig) -> Self {
        Self {
            config,
            width: 0,
            height: 0,
            initialized: false,
            stats: EncoderStats::default(),
            frame_count: 0,
            force_keyframe: true,
        }
    }
}

#[async_trait::async_trait]
impl VideoEncoder for NvencEncoder {
    async fn initialize(&mut self, width: u32, height: u32) -> Result<(), EncoderError> {
        if !HardwareEncoder::is_nvenc_available() {
            return Err(EncoderError::HardwareNotAvailable(
                "NVIDIA GPU not found".to_string(),
            ));
        }

        self.width = width;
        self.height = height;
        self.initialized = true;

        tracing::info!(
            "NVENC encoder initialized: {}x{} @ {}fps",
            width,
            height,
            self.config.framerate
        );
        Ok(())
    }

    async fn encode(&mut self, frame: &CapturedFrame) -> Result<EncodedFrame, EncoderError> {
        if !self.initialized {
            return Err(EncoderError::NotInitialized);
        }

        let start = std::time::Instant::now();
        let is_keyframe = self.force_keyframe
            || self
                .frame_count
                .is_multiple_of(self.config.keyframe_interval as u64);

        // Placeholder encoded data
        let encoded_data = if is_keyframe {
            vec![0u8; (frame.width * frame.height / 5) as usize]
        } else {
            vec![0u8; (frame.width * frame.height / 20) as usize]
        };

        let encode_time = start.elapsed().as_micros() as u64;

        self.stats.frames_encoded += 1;
        self.stats.bytes_output += encoded_data.len() as u64;
        self.stats.avg_encode_time_us =
            (self.stats.avg_encode_time_us * (self.stats.frames_encoded - 1) + encode_time)
                / self.stats.frames_encoded;

        if is_keyframe {
            self.stats.keyframes += 1;
            self.force_keyframe = false;
        }

        let pts = self.frame_count;
        self.frame_count += 1;

        Ok(EncodedFrame {
            data: encoded_data,
            pts,
            dts: pts,
            is_keyframe,
            frame_type: if is_keyframe {
                FrameType::I
            } else {
                FrameType::P
            },
            width: frame.width,
            height: frame.height,
        })
    }

    fn request_keyframe(&mut self) {
        self.force_keyframe = true;
    }

    fn update_config(&mut self, config: &EncoderConfig) -> Result<(), EncoderError> {
        self.config = config.clone();
        Ok(())
    }

    fn stats(&self) -> EncoderStats {
        self.stats.clone()
    }

    fn encoder_type(&self) -> HardwareEncoder {
        HardwareEncoder::Nvenc
    }

    async fn flush(&mut self) -> Result<Vec<EncodedFrame>, EncoderError> {
        Ok(Vec::new())
    }

    async fn shutdown(&mut self) -> Result<(), EncoderError> {
        self.initialized = false;
        tracing::info!("NVENC encoder shutdown");
        Ok(())
    }
}

/// Unified video encoder with automatic backend selection
pub struct UnifiedEncoder {
    encoder: Box<dyn VideoEncoder>,
    config: EncoderConfig,
}

impl UnifiedEncoder {
    /// Create a new unified encoder with auto-detected backend
    pub fn new(config: EncoderConfig) -> Result<Self, EncoderError> {
        let capabilities = SenderCapabilityResolver::probe(config.hardware);
        let resolved_codec = capabilities.resolve_requested_codec(config.codec, config.low_latency);
        if !capabilities.supports_send(resolved_codec) {
            return Err(EncoderError::HardwareNotAvailable(format!(
                "Host cannot send {:?} with {:?}",
                resolved_codec, capabilities.encoder
            )));
        }

        let hardware = capabilities.encoder;
        let mut resolved_config = config.clone();
        resolved_config.codec = resolved_codec;
        resolved_config.hardware = hardware;

        let encoder: Box<dyn VideoEncoder> = match hardware {
            HardwareEncoder::Nvenc => Box::new(NvencEncoder::new(resolved_config.clone())),
            HardwareEncoder::Vaapi => Box::new(VaapiEncoder::new(resolved_config.clone())),
            HardwareEncoder::Software | HardwareEncoder::Auto => {
                if resolved_codec != VideoCodec::H264 {
                    return Err(EncoderError::HardwareNotAvailable(format!(
                        "Software fallback does not support {:?} send",
                        resolved_codec
                    )));
                }
                Box::new(SoftwareEncoder::new(resolved_config.clone()))
            }
        };

        tracing::info!(
            "Selected video encoder: {:?}, requested codec={:?}, resolved codec={:?}",
            hardware,
            config.codec,
            resolved_codec
        );

        Ok(Self {
            encoder,
            config: resolved_config,
        })
    }

    /// Create with specific encoder type
    pub fn with_encoder(encoder: Box<dyn VideoEncoder>, config: EncoderConfig) -> Self {
        Self { encoder, config }
    }

    /// Initialize the encoder
    pub async fn initialize(&mut self, width: u32, height: u32) -> Result<(), EncoderError> {
        self.encoder.initialize(width, height).await
    }

    /// Encode a frame
    pub async fn encode(&mut self, frame: &CapturedFrame) -> Result<EncodedFrame, EncoderError> {
        self.encoder.encode(frame).await
    }

    /// Request keyframe
    pub fn request_keyframe(&mut self) {
        self.encoder.request_keyframe();
    }

    /// Update configuration
    pub fn update_config(&mut self, config: &EncoderConfig) -> Result<(), EncoderError> {
        self.config = config.clone();
        self.encoder.update_config(config)
    }

    /// Get statistics
    pub fn stats(&self) -> EncoderStats {
        self.encoder.stats()
    }

    /// Get encoder type
    pub fn encoder_type(&self) -> HardwareEncoder {
        self.encoder.encoder_type()
    }

    /// Flush encoder
    pub async fn flush(&mut self) -> Result<Vec<EncodedFrame>, EncoderError> {
        self.encoder.flush().await
    }

    /// Shutdown encoder
    pub async fn shutdown(&mut self) -> Result<(), EncoderError> {
        self.encoder.shutdown().await
    }

    /// Get configuration
    pub fn config(&self) -> &EncoderConfig {
        &self.config
    }
}

/// Convert frame to YUV420P format for encoding
pub fn frame_to_yuv420p(frame: &CapturedFrame) -> Vec<u8> {
    let width = frame.width as usize;
    let height = frame.height as usize;

    let y_size = width * height;
    let uv_size = y_size / 4;
    let mut yuv = vec![0u8; y_size + uv_size * 2];

    let rgba = frame.to_rgba();

    // Convert RGBA to YUV420P
    for y in 0..height {
        for x in 0..width {
            let rgba_idx = (y * width + x) * 4;
            let r = rgba[rgba_idx] as f32;
            let g = rgba[rgba_idx + 1] as f32;
            let b = rgba[rgba_idx + 2] as f32;

            // Y component
            let y_val = (0.299 * r + 0.587 * g + 0.114 * b).clamp(0.0, 255.0) as u8;
            yuv[y * width + x] = y_val;

            // U and V components (subsampled 2x2)
            if x % 2 == 0 && y % 2 == 0 {
                let u_idx = y_size + (y / 2) * (width / 2) + (x / 2);
                let v_idx = y_size + uv_size + (y / 2) * (width / 2) + (x / 2);

                let u_val = (-0.169 * r - 0.331 * g + 0.500 * b + 128.0).clamp(0.0, 255.0) as u8;
                let v_val = (0.500 * r - 0.419 * g - 0.081 * b + 128.0).clamp(0.0, 255.0) as u8;

                yuv[u_idx] = u_val;
                yuv[v_idx] = v_val;
            }
        }
    }

    yuv
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote::capture::PixelFormat;

    #[test]
    fn test_hardware_detection() {
        let hw = HardwareEncoder::detect();
        println!("Detected hardware encoder: {:?}", hw);
    }

    #[test]
    fn test_encoder_config_presets() {
        let lan = EncoderConfig::for_lan();
        assert_eq!(lan.framerate, 60);
        assert!(lan.bitrate > 10_000_000);

        let wan = EncoderConfig::for_wan();
        assert_eq!(wan.framerate, 30);

        let mobile = EncoderConfig::for_mobile();
        assert!(mobile.bitrate < wan.bitrate);
    }

    #[test]
    fn test_software_probe_never_claims_hevc_send() {
        let probe = SenderCapabilityResolver::probe(HardwareEncoder::Software);
        assert!(probe.h264);
        assert!(!probe.hevc);
        assert_eq!(
            probe.resolve_requested_codec(VideoCodec::H265, false),
            VideoCodec::H264
        );
    }

    #[test]
    fn test_auto_codec_prefers_h264_for_low_latency_on_software() {
        let probe = SenderCapabilityResolver::probe(HardwareEncoder::Software);
        assert_eq!(
            probe.resolve_requested_codec(VideoCodec::Auto, true),
            VideoCodec::H264
        );
    }

    #[test]
    fn test_yuv_conversion() {
        let frame = CapturedFrame {
            width: 4,
            height: 4,
            format: PixelFormat::Rgba8888,
            data: vec![255u8; 4 * 4 * 4], // White pixels
            timestamp: 0,
            frame_number: 0,
            capture_latency_us: 0,
        };

        let yuv = frame_to_yuv420p(&frame);
        assert_eq!(yuv.len(), 24); // 16 + 4 + 4
        assert!(yuv[0] > 200); // Y component for white
    }
}
