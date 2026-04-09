//! Screen Capture Module
//!
//! Provides screen capture functionality for Ubuntu 22-25 with support for:
//! - Wayland via PipeWire and xdg-desktop-portal
//! - X11 via XGetImage with shared memory (MIT-SHM)
//!
//! The module automatically detects the display server and uses the appropriate backend.

use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::sync::mpsc;

/// Screen capture errors
#[derive(Debug, Error)]
pub enum CaptureError {
    /// No display server available
    #[error("No display server available")]
    NoDisplayServer,

    /// Wayland capture error
    #[error("Wayland capture error: {0}")]
    Wayland(String),

    /// X11 capture error
    #[error("X11 capture error: {0}")]
    X11(String),

    /// Permission denied
    #[error("Permission denied - user did not grant screen capture access")]
    PermissionDenied,

    /// Portal error
    #[error("Desktop portal error: {0}")]
    Portal(String),

    /// Encoding error
    #[error("Frame encoding error: {0}")]
    Encoding(String),

    /// Not initialized
    #[error("Screen capture not initialized")]
    NotInitialized,

    /// Already capturing
    #[error("Screen capture already running")]
    AlreadyCapturing,

    /// IO error
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

/// Display server type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DisplayServer {
    /// Wayland display server
    Wayland,
    /// X11 display server
    X11,
    /// Unknown or no display server
    Unknown,
}

impl DisplayServer {
    /// Detect the current display server
    pub fn detect() -> Self {
        // Check WAYLAND_DISPLAY first (preferred)
        if std::env::var("WAYLAND_DISPLAY").is_ok() {
            return Self::Wayland;
        }

        // Check XDG_SESSION_TYPE
        if let Ok(session_type) = std::env::var("XDG_SESSION_TYPE") {
            match session_type.to_lowercase().as_str() {
                "wayland" => return Self::Wayland,
                "x11" => return Self::X11,
                _ => {}
            }
        }

        // Check DISPLAY for X11
        if std::env::var("DISPLAY").is_ok() {
            return Self::X11;
        }

        Self::Unknown
    }

    /// Check if this is Wayland
    pub fn is_wayland(&self) -> bool {
        matches!(self, Self::Wayland)
    }

    /// Check if this is X11
    pub fn is_x11(&self) -> bool {
        matches!(self, Self::X11)
    }
}

/// Screen/monitor information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScreenInfo {
    /// Screen ID
    pub id: u32,
    /// Screen name
    pub name: String,
    /// Width in pixels
    pub width: u32,
    /// Height in pixels
    pub height: u32,
    /// X position (for multi-monitor)
    pub x: i32,
    /// Y position (for multi-monitor)
    pub y: i32,
    /// Refresh rate in Hz
    pub refresh_rate: f32,
    /// Scale factor
    pub scale: f32,
    /// Is primary screen
    pub is_primary: bool,
}

/// Pixel format
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PixelFormat {
    /// BGRA 32-bit (common on X11)
    Bgra8888,
    /// RGBA 32-bit
    Rgba8888,
    /// RGB 24-bit
    Rgb888,
    /// BGR 24-bit
    Bgr888,
}

impl PixelFormat {
    /// Get bytes per pixel
    pub fn bytes_per_pixel(&self) -> usize {
        match self {
            Self::Bgra8888 | Self::Rgba8888 => 4,
            Self::Rgb888 | Self::Bgr888 => 3,
        }
    }
}

/// A captured frame
#[derive(Debug, Clone)]
pub struct CapturedFrame {
    /// Frame width
    pub width: u32,
    /// Frame height
    pub height: u32,
    /// Pixel format
    pub format: PixelFormat,
    /// Raw pixel data
    pub data: Vec<u8>,
    /// Timestamp (nanoseconds since epoch)
    pub timestamp: u64,
    /// Frame number
    pub frame_number: u64,
    /// Capture latency in microseconds
    pub capture_latency_us: u64,
}

impl CapturedFrame {
    /// Get stride (bytes per row)
    pub fn stride(&self) -> usize {
        self.width as usize * self.format.bytes_per_pixel()
    }

    /// Get total data size
    pub fn data_size(&self) -> usize {
        self.stride() * self.height as usize
    }

    /// Convert to RGBA format
    pub fn to_rgba(&self) -> Vec<u8> {
        match self.format {
            PixelFormat::Rgba8888 => self.data.clone(),
            PixelFormat::Bgra8888 => {
                let mut rgba = Vec::with_capacity(self.data.len());
                for chunk in self.data.chunks(4) {
                    if chunk.len() == 4 {
                        rgba.push(chunk[2]); // R
                        rgba.push(chunk[1]); // G
                        rgba.push(chunk[0]); // B
                        rgba.push(chunk[3]); // A
                    }
                }
                rgba
            }
            PixelFormat::Rgb888 => {
                let mut rgba = Vec::with_capacity((self.data.len() / 3) * 4);
                for chunk in self.data.chunks(3) {
                    if chunk.len() == 3 {
                        rgba.push(chunk[0]); // R
                        rgba.push(chunk[1]); // G
                        rgba.push(chunk[2]); // B
                        rgba.push(255); // A
                    }
                }
                rgba
            }
            PixelFormat::Bgr888 => {
                let mut rgba = Vec::with_capacity((self.data.len() / 3) * 4);
                for chunk in self.data.chunks(3) {
                    if chunk.len() == 3 {
                        rgba.push(chunk[2]); // R
                        rgba.push(chunk[1]); // G
                        rgba.push(chunk[0]); // B
                        rgba.push(255); // A
                    }
                }
                rgba
            }
        }
    }
}

/// Capture configuration
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CaptureConfig {
    /// Target frame rate
    pub target_fps: u32,
    /// Capture cursor
    pub capture_cursor: bool,
    /// Screen region (None = full screen)
    pub region: Option<CaptureRegion>,
    /// Preferred pixel format
    pub pixel_format: PixelFormat,
    /// Use hardware acceleration if available
    pub hardware_accel: bool,
    /// Screen ID to capture (None = primary)
    pub screen_id: Option<u32>,
}

impl Default for CaptureConfig {
    fn default() -> Self {
        Self {
            target_fps: 30,
            capture_cursor: true,
            region: None,
            pixel_format: PixelFormat::Bgra8888,
            hardware_accel: true,
            screen_id: None,
        }
    }
}

/// Capture region
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct CaptureRegion {
    /// X position
    pub x: i32,
    /// Y position
    pub y: i32,
    /// Width
    pub width: u32,
    /// Height
    pub height: u32,
}

/// Screen capture state
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureState {
    /// Not initialized
    Uninitialized,
    /// Ready to capture
    Ready,
    /// Currently capturing
    Capturing,
    /// Paused
    Paused,
    /// Stopped
    Stopped,
    /// Error state
    Error,
}

/// Screen capture backend trait
#[async_trait::async_trait]
pub trait CaptureBackend: Send + Sync {
    /// Initialize the backend
    async fn initialize(&mut self) -> Result<(), CaptureError>;

    /// Get available screens
    async fn get_screens(&self) -> Result<Vec<ScreenInfo>, CaptureError>;

    /// Start capturing
    async fn start(
        &mut self,
        config: &CaptureConfig,
    ) -> Result<mpsc::Receiver<CapturedFrame>, CaptureError>;

    /// Stop capturing
    async fn stop(&mut self) -> Result<(), CaptureError>;

    /// Pause capturing
    async fn pause(&mut self) -> Result<(), CaptureError>;

    /// Resume capturing
    async fn resume(&mut self) -> Result<(), CaptureError>;

    /// Get current state
    fn state(&self) -> CaptureState;

    /// Get display server type
    fn display_server(&self) -> DisplayServer;
}

// Platform-specific implementations
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
pub use linux::{WaylandCapture, X11Capture};

// Stub implementations for non-Linux platforms
#[cfg(not(target_os = "linux"))]
mod stub;

#[cfg(not(target_os = "linux"))]
pub use stub::{WaylandCapture, X11Capture};

/// Unified screen capturer that auto-selects backend
pub struct ScreenCapturer {
    backend: Box<dyn CaptureBackend>,
    display_server: DisplayServer,
}

impl ScreenCapturer {
    /// Create a new screen capturer with auto-detected backend
    pub fn new() -> Result<Self, CaptureError> {
        let display_server = DisplayServer::detect();

        let backend: Box<dyn CaptureBackend> = match display_server {
            DisplayServer::Wayland => Box::new(WaylandCapture::new()),
            DisplayServer::X11 => Box::new(X11Capture::new()),
            DisplayServer::Unknown => {
                // Try X11 as fallback
                if std::env::var("DISPLAY").is_ok() {
                    Box::new(X11Capture::new())
                } else {
                    return Err(CaptureError::NoDisplayServer);
                }
            }
        };

        Ok(Self {
            backend,
            display_server,
        })
    }

    /// Create with specific backend
    pub fn with_backend(backend: Box<dyn CaptureBackend>) -> Self {
        let display_server = backend.display_server();
        Self {
            backend,
            display_server,
        }
    }

    /// Get the detected display server
    pub fn display_server(&self) -> DisplayServer {
        self.display_server
    }

    /// Initialize the capturer
    pub async fn initialize(&mut self) -> Result<(), CaptureError> {
        self.backend.initialize().await
    }

    /// Get available screens
    pub async fn get_screens(&self) -> Result<Vec<ScreenInfo>, CaptureError> {
        self.backend.get_screens().await
    }

    /// Start capturing with configuration
    pub async fn start(
        &mut self,
        config: &CaptureConfig,
    ) -> Result<mpsc::Receiver<CapturedFrame>, CaptureError> {
        self.backend.start(config).await
    }

    /// Stop capturing
    pub async fn stop(&mut self) -> Result<(), CaptureError> {
        self.backend.stop().await
    }

    /// Pause capturing
    pub async fn pause(&mut self) -> Result<(), CaptureError> {
        self.backend.pause().await
    }

    /// Resume capturing
    pub async fn resume(&mut self) -> Result<(), CaptureError> {
        self.backend.resume().await
    }

    /// Get current state
    pub fn state(&self) -> CaptureState {
        self.backend.state()
    }
}

impl Default for ScreenCapturer {
    fn default() -> Self {
        Self::new().expect("Failed to create screen capturer")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_display_server_detection() {
        let ds = DisplayServer::detect();
        // Should detect something on a desktop system
        println!("Detected display server: {:?}", ds);
    }

    #[test]
    fn test_pixel_format_conversion() {
        let frame = CapturedFrame {
            width: 2,
            height: 2,
            format: PixelFormat::Bgra8888,
            data: vec![
                0, 0, 255, 255, // Red (BGRA)
                0, 255, 0, 255, // Green
                255, 0, 0, 255, // Blue
                255, 255, 255, 255, // White
            ],
            timestamp: 0,
            frame_number: 0,
            capture_latency_us: 0,
        };

        let rgba = frame.to_rgba();
        assert_eq!(rgba.len(), 16);
        // First pixel should be red in RGBA
        assert_eq!(rgba[0], 255); // R
        assert_eq!(rgba[1], 0); // G
        assert_eq!(rgba[2], 0); // B
        assert_eq!(rgba[3], 255); // A
    }

    #[test]
    fn test_capture_config_default() {
        let config = CaptureConfig::default();
        assert_eq!(config.target_fps, 30);
        assert!(config.capture_cursor);
        assert!(config.hardware_accel);
    }
}
