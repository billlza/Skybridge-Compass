//! OpenH264 Software Encoder
//!
//! Uses the OpenH264 library for H.264 encoding.

use openh264::OpenH264API;
use openh264::encoder::{
    BitRate, Encoder, EncoderConfig as H264Config, FrameRate, RateControlMode, UsageType,
};
use openh264::formats::YUVBuffer;

use crate::remote::capture::CapturedFrame;
use crate::remote::encoder::{
    EncodedFrame, EncoderConfig, EncoderError, EncoderStats, FrameType, HardwareEncoder,
    VideoEncoder, frame_to_yuv420p,
};

/// OpenH264 software encoder
pub struct OpenH264Encoder {
    config: EncoderConfig,
    encoder: Option<Encoder>,
    width: u32,
    height: u32,
    initialized: bool,
    stats: EncoderStats,
    frame_count: u64,
    force_keyframe: bool,
}

impl OpenH264Encoder {
    /// Create a new OpenH264 encoder
    pub fn new(config: EncoderConfig) -> Self {
        Self {
            config,
            encoder: None,
            width: 0,
            height: 0,
            initialized: false,
            stats: EncoderStats::default(),
            frame_count: 0,
            force_keyframe: true,
        }
    }

    fn build_encoder(&self) -> Result<Encoder, EncoderError> {
        let tune_for_screen = self.config.tune_screen;
        let h264_config = H264Config::new()
            .bitrate(BitRate::from_bps(self.config.bitrate))
            .max_frame_rate(FrameRate::from_hz(self.config.framerate as f32))
            .rate_control_mode(RateControlMode::Bitrate)
            .usage_type(if self.config.tune_screen {
                UsageType::ScreenContentRealTime
            } else {
                UsageType::CameraVideoRealTime
            })
            .adaptive_quantization(!tune_for_screen)
            .background_detection(!tune_for_screen);

        Encoder::with_api_config(OpenH264API::from_source(), h264_config)
            .map_err(|e| EncoderError::Codec(format!("Failed to create OpenH264 encoder: {}", e)))
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

        let encoder = self.build_encoder()?;

        self.encoder = Some(encoder);
        self.initialized = true;

        tracing::info!(
            "OpenH264 encoder initialized: {}x{} @ {}fps, {}kbps",
            width,
            height,
            self.config.framerate,
            self.config.bitrate / 1000
        );
        Ok(())
    }

    async fn encode(&mut self, frame: &CapturedFrame) -> Result<EncodedFrame, EncoderError> {
        if !self.initialized {
            return Err(EncoderError::NotInitialized);
        }

        let encoder = self.encoder.as_mut().ok_or(EncoderError::NotInitialized)?;

        if frame.width != self.width || frame.height != self.height {
            return Err(EncoderError::InvalidFrame(format!(
                "Frame size mismatch: expected {}x{}, got {}x{}",
                self.width, self.height, frame.width, frame.height
            )));
        }

        let start = std::time::Instant::now();

        // Convert frame to YUV420P
        let yuv_data = frame_to_yuv420p(frame);

        // Create YUV buffer
        let yuv_buffer = YUVBuffer::from_vec(yuv_data, self.width as usize, self.height as usize);

        // Request keyframe if needed
        if self.force_keyframe {
            encoder.force_intra_frame();
        }

        // Encode frame
        let bitstream = encoder
            .encode(&yuv_buffer)
            .map_err(|e| EncoderError::Encoding(e.to_string()))?;

        let encode_time = start.elapsed().as_micros() as u64;

        // Get encoded data
        let encoded_data = bitstream.to_vec();

        // Determine frame type
        let is_keyframe = self.force_keyframe
            || self
                .frame_count
                .is_multiple_of(self.config.keyframe_interval as u64);

        // Update stats
        self.stats.frames_encoded += 1;
        self.stats.bytes_output += encoded_data.len() as u64;
        self.stats.avg_encode_time_us = if self.stats.frames_encoded == 1 {
            encode_time
        } else {
            (self.stats.avg_encode_time_us * (self.stats.frames_encoded - 1) + encode_time)
                / self.stats.frames_encoded
        };

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

        if self.initialized {
            self.encoder = Some(self.build_encoder()?);
            self.force_keyframe = true;
        }

        Ok(())
    }

    fn stats(&self) -> EncoderStats {
        self.stats.clone()
    }

    fn encoder_type(&self) -> HardwareEncoder {
        HardwareEncoder::Software
    }

    async fn flush(&mut self) -> Result<Vec<EncodedFrame>, EncoderError> {
        // OpenH264 doesn't have a flush mechanism like other encoders
        Ok(Vec::new())
    }

    async fn shutdown(&mut self) -> Result<(), EncoderError> {
        self.encoder = None;
        self.initialized = false;
        tracing::info!("OpenH264 encoder shutdown");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote::capture::PixelFormat;

    #[tokio::test]
    async fn test_openh264_encoder_init() {
        let mut encoder = OpenH264Encoder::new(EncoderConfig::default());
        let result = encoder.initialize(640, 480).await;
        assert!(result.is_ok());
        assert!(encoder.initialized);
    }

    #[tokio::test]
    async fn test_openh264_encode_frame() {
        let mut encoder = OpenH264Encoder::new(EncoderConfig::default());
        encoder.initialize(320, 240).await.unwrap();

        let frame = CapturedFrame {
            width: 320,
            height: 240,
            format: PixelFormat::Rgba8888,
            data: vec![128u8; 320 * 240 * 4], // Gray pixels
            timestamp: 0,
            frame_number: 0,
            capture_latency_us: 0,
        };

        let encoded = encoder.encode(&frame).await;
        assert!(encoded.is_ok());

        let encoded = encoded.unwrap();
        assert!(encoded.is_keyframe); // First frame should be keyframe
        assert!(!encoded.data.is_empty());
    }
}
