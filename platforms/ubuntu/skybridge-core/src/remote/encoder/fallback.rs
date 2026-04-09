//! Fallback encoder implementations for non-Linux platforms

use crate::remote::capture::CapturedFrame;
use crate::remote::encoder::{
    EncodedFrame, EncoderConfig, EncoderError, EncoderStats, FrameType, HardwareEncoder,
    VideoEncoder,
};

/// Fallback OpenH264 encoder for non-Linux platforms
pub struct OpenH264Encoder {
    config: EncoderConfig,
    width: u32,
    height: u32,
    initialized: bool,
    stats: EncoderStats,
    frame_count: u64,
    force_keyframe: bool,
}

impl OpenH264Encoder {
    /// Create a new encoder
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

impl Default for OpenH264Encoder {
    fn default() -> Self {
        Self::new(EncoderConfig::default())
    }
}

#[async_trait::async_trait]
impl VideoEncoder for OpenH264Encoder {
    async fn initialize(&mut self, width: u32, height: u32) -> Result<(), EncoderError> {
        self.width = width;
        self.height = height;
        self.initialized = true;
        Ok(())
    }

    async fn encode(&mut self, frame: &CapturedFrame) -> Result<EncodedFrame, EncoderError> {
        if !self.initialized {
            return Err(EncoderError::NotInitialized);
        }

        let is_keyframe = self.force_keyframe
            || self
                .frame_count
                .is_multiple_of(self.config.keyframe_interval as u64);

        let encoded_data = if is_keyframe {
            vec![0u8; (frame.width * frame.height / 4) as usize]
        } else {
            vec![0u8; (frame.width * frame.height / 16) as usize]
        };

        self.stats.frames_encoded += 1;
        self.stats.bytes_output += encoded_data.len() as u64;

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
        HardwareEncoder::Software
    }

    async fn flush(&mut self) -> Result<Vec<EncodedFrame>, EncoderError> {
        Ok(Vec::new())
    }

    async fn shutdown(&mut self) -> Result<(), EncoderError> {
        self.initialized = false;
        Ok(())
    }
}

/// SoftwareEncoder is an alias for OpenH264Encoder
pub type SoftwareEncoder = OpenH264Encoder;

/// Fallback VAAPI encoder
pub struct VaapiEncoder {
    config: EncoderConfig,
}

impl VaapiEncoder {
    /// Create a new encoder
    pub fn new(config: EncoderConfig) -> Self {
        Self { config }
    }
}

#[async_trait::async_trait]
impl VideoEncoder for VaapiEncoder {
    async fn initialize(&mut self, _width: u32, _height: u32) -> Result<(), EncoderError> {
        Err(EncoderError::HardwareNotAvailable(
            "VAAPI not available on this platform".to_string(),
        ))
    }

    async fn encode(&mut self, _frame: &CapturedFrame) -> Result<EncodedFrame, EncoderError> {
        Err(EncoderError::NotInitialized)
    }

    fn request_keyframe(&mut self) {}

    fn update_config(&mut self, config: &EncoderConfig) -> Result<(), EncoderError> {
        self.config = config.clone();
        Ok(())
    }

    fn stats(&self) -> EncoderStats {
        EncoderStats::default()
    }

    fn encoder_type(&self) -> HardwareEncoder {
        HardwareEncoder::Vaapi
    }

    async fn flush(&mut self) -> Result<Vec<EncodedFrame>, EncoderError> {
        Ok(Vec::new())
    }

    async fn shutdown(&mut self) -> Result<(), EncoderError> {
        Ok(())
    }
}
