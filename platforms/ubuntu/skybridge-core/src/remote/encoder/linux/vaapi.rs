//! VAAPI Hardware Encoder
//!
//! Uses VA-API for hardware-accelerated H.264 encoding on Intel/AMD GPUs.
//! Note: Full VAAPI implementation requires libva bindings.

use std::path::PathBuf;

use crate::remote::capture::CapturedFrame;
use crate::remote::encoder::{
    EncodedFrame, EncoderConfig, EncoderError, EncoderStats, FrameType, HardwareEncoder,
    VideoEncoder, frame_to_yuv420p,
};

/// VAAPI hardware encoder
pub struct VaapiEncoder {
    config: EncoderConfig,
    device_path: PathBuf,
    width: u32,
    height: u32,
    initialized: bool,
    stats: EncoderStats,
    frame_count: u64,
    force_keyframe: bool,
}

impl VaapiEncoder {
    /// Create a new VAAPI encoder
    pub fn new(config: EncoderConfig) -> Self {
        Self {
            config,
            device_path: PathBuf::from("/dev/dri/renderD128"),
            width: 0,
            height: 0,
            initialized: false,
            stats: EncoderStats::default(),
            frame_count: 0,
            force_keyframe: true,
        }
    }

    /// Set the DRI device path
    pub fn with_device(mut self, path: PathBuf) -> Self {
        self.device_path = path;
        self
    }

    /// Check if VAAPI is available
    fn check_vaapi(&self) -> Result<(), EncoderError> {
        if !self.device_path.exists() {
            return Err(EncoderError::HardwareNotAvailable(format!(
                "VAAPI device not found: {:?}",
                self.device_path
            )));
        }

        // Check if vainfo is available to verify VAAPI support
        let output = std::process::Command::new("vainfo")
            .arg("--display")
            .arg("drm")
            .arg("--device")
            .arg(&self.device_path)
            .output();

        match output {
            Ok(out) if out.status.success() => {
                let stdout = String::from_utf8_lossy(&out.stdout);
                if stdout.contains("VAEntrypointEncSlice") {
                    Ok(())
                } else {
                    Err(EncoderError::HardwareNotAvailable(
                        "VAAPI encoding not supported on this device".to_string(),
                    ))
                }
            }
            _ => Err(EncoderError::HardwareNotAvailable(
                "Failed to query VAAPI capabilities".to_string(),
            )),
        }
    }
}

impl Default for VaapiEncoder {
    fn default() -> Self {
        Self::new(EncoderConfig::default())
    }
}

#[async_trait::async_trait]
impl VideoEncoder for VaapiEncoder {
    async fn initialize(&mut self, width: u32, height: u32) -> Result<(), EncoderError> {
        // Verify VAAPI is available
        self.check_vaapi()?;

        self.width = width;
        self.height = height;

        // Note: Full VAAPI initialization requires:
        // 1. vaGetDisplayDRM() to get VA display
        // 2. vaInitialize() to init connection
        // 3. vaCreateConfig() with VAProfileH264Main and VAEntrypointEncSlice
        // 4. vaCreateContext() for encoding
        // 5. vaCreateSurfaces() for input surfaces
        //
        // For now, we simulate encoding as the full implementation
        // requires unsafe FFI bindings to libva.

        self.initialized = true;

        tracing::info!(
            "VAAPI encoder initialized: {}x{} @ {}fps using {:?}",
            width,
            height,
            self.config.framerate,
            self.device_path
        );
        Ok(())
    }

    async fn encode(&mut self, frame: &CapturedFrame) -> Result<EncodedFrame, EncoderError> {
        if !self.initialized {
            return Err(EncoderError::NotInitialized);
        }

        if frame.width != self.width || frame.height != self.height {
            return Err(EncoderError::InvalidFrame(format!(
                "Frame size mismatch: expected {}x{}, got {}x{}",
                self.width, self.height, frame.width, frame.height
            )));
        }

        let start = std::time::Instant::now();

        // Convert frame to YUV for encoding
        let _yuv_data = frame_to_yuv420p(frame);

        // Note: Full VAAPI encoding requires:
        // 1. vaMapBuffer() to get surface memory
        // 2. Copy YUV data to surface
        // 3. vaUnmapBuffer()
        // 4. vaBeginPicture()
        // 5. vaRenderPicture() with slice parameters
        // 6. vaEndPicture()
        // 7. vaSyncSurface() to wait for encoding
        // 8. vaMapBuffer() to get encoded output
        //
        // For now, generate simulated H.264 NAL units

        let is_keyframe = self.force_keyframe
            || self
                .frame_count
                .is_multiple_of(self.config.keyframe_interval as u64);

        // Simulated encoded data (proper implementation would return real NAL units)
        let encoded_data = if is_keyframe {
            // I-frame: SPS + PPS + IDR slice (simulated)
            let mut data = Vec::with_capacity(frame.width as usize * frame.height as usize / 4);
            // NAL start code
            data.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
            // SPS NAL (simulated)
            data.extend_from_slice(&[0x67, 0x42, 0x00, 0x1e, 0x95, 0xa8, 0x28, 0x28]);
            // NAL start code
            data.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
            // PPS NAL (simulated)
            data.extend_from_slice(&[0x68, 0xce, 0x38, 0x80]);
            // NAL start code
            data.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
            // IDR slice header (simulated)
            data.extend_from_slice(&[0x65]);
            // Simulated slice data
            data.resize(frame.width as usize * frame.height as usize / 4, 0x00);
            data
        } else {
            // P-frame: Non-IDR slice (simulated)
            let mut data = Vec::with_capacity(frame.width as usize * frame.height as usize / 16);
            // NAL start code
            data.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
            // P-slice NAL (simulated)
            data.extend_from_slice(&[0x41]);
            // Simulated slice data
            data.resize(frame.width as usize * frame.height as usize / 16, 0x00);
            data
        };

        let encode_time = start.elapsed().as_micros() as u64;

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
        // Note: Dynamic bitrate update would use vaCreateBuffer() with VAEncMiscParameterBufferType
        Ok(())
    }

    fn stats(&self) -> EncoderStats {
        self.stats.clone()
    }

    fn encoder_type(&self) -> HardwareEncoder {
        HardwareEncoder::Vaapi
    }

    async fn flush(&mut self) -> Result<Vec<EncodedFrame>, EncoderError> {
        // Note: Full implementation would call vaSyncSurface() for pending frames
        Ok(Vec::new())
    }

    async fn shutdown(&mut self) -> Result<(), EncoderError> {
        // Note: Full implementation would call:
        // vaDestroyContext()
        // vaDestroySurfaces()
        // vaDestroyConfig()
        // vaTerminate()

        self.initialized = false;
        tracing::info!("VAAPI encoder shutdown");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vaapi_encoder_creation() {
        let encoder = VaapiEncoder::new(EncoderConfig::default());
        assert!(!encoder.initialized);
        assert_eq!(encoder.encoder_type(), HardwareEncoder::Vaapi);
    }

    #[test]
    fn test_vaapi_device_path() {
        let encoder = VaapiEncoder::new(EncoderConfig::default())
            .with_device(PathBuf::from("/dev/dri/renderD129"));
        assert_eq!(encoder.device_path, PathBuf::from("/dev/dri/renderD129"));
    }
}
