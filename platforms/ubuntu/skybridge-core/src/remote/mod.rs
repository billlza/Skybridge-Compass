//! Remote Desktop Module
//!
//! Provides remote desktop functionality for Ubuntu 22-25 with support for:
//! - Screen capture via PipeWire (Wayland) or XGetImage (X11)
//! - Input injection via RemoteDesktop portal (Wayland) or XTest (X11)
//! - Hardware-accelerated video encoding (VAAPI/NVENC/OpenH264)
//! - VNC protocol for cross-platform compatibility

#![allow(missing_docs)]

use std::sync::OnceLock;

pub mod capture;
pub mod encoder;
pub mod input;
pub mod mac_remote;
pub mod mac_remote_server;
mod manager;
#[cfg(target_os = "linux")]
pub mod portal;
pub mod ultrastream;
mod vnc;
pub mod vnc_server;

pub use capture::{
    CaptureBackend, CaptureConfig, CaptureError, CaptureRegion, CaptureState, CapturedFrame,
    DisplayServer, PixelFormat, ScreenCapturer, ScreenInfo, WaylandCapture, X11Capture,
};
pub use encoder::{
    EncodedFrame, EncoderConfig, EncoderError, EncoderPreset, EncoderStats, FrameType,
    HardwareEncoder, NvencEncoder, OpenH264Encoder, RateControl, SoftwareEncoder, UnifiedEncoder,
    VaapiEncoder, VideoCodec, VideoEncoder,
};
pub use input::{
    InputError, InputHandler, KeyEvent, KeyEventType, KeyModifiers, MouseButton, MouseEvent,
    MouseEventType, UnifiedInputHandler, WaylandInputHandler, X11InputHandler, keysym,
};
pub use mac_remote::{
    MacRemoteControlClient, MacRemoteControlError, RemoteKeyboardEvent, RemoteMessage,
    RemoteMessageType, RemoteMouseEvent, ScreenData,
};
pub use mac_remote_server::{
    MacRemoteControlServer, MacRemoteControlServerConfig, MacRemoteControlServerError,
};
pub use manager::RemoteDesktopManager;
#[cfg(target_os = "linux")]
pub use portal::{
    PortalCallContext, PortalCaptureContext, PortalError, PortalSessionSnapshot,
    PortalSessionState, active_portal_call_context, active_portal_capture_context,
    bootstrap_portal_session, close_runtime_portal_session, ensure_runtime_portal_session,
};
pub use ultrastream::{
    AutoDecoder, HevcDecoder, NullSink, OpenH264Decoder, PassthroughDecoder, UltraStreamCodec,
    UltraStreamDecodedFrame, UltraStreamDecoder, UltraStreamError, UltraStreamFrame,
    UltraStreamHeader, UltraStreamPipeline, UltraStreamReceiver, UltraStreamSender,
    UltraStreamSession, UltraStreamSink,
};
pub use vnc::{VncClient, VncConfig, VncEvent};
pub use vnc_server::{VncServer, VncServerConfig, VncServerError};

/// Screen-data formats that this build can receive over the Apple-compatible JSON remote wire.
pub fn supported_remote_video_formats() -> Vec<String> {
    static FORMATS: OnceLock<Vec<String>> = OnceLock::new();
    FORMATS
        .get_or_init(|| {
            let mut formats = vec!["jpeg".to_string()];
            if OpenH264Decoder::new().is_ok() {
                formats.push("h264".to_string());
            }
            if HevcDecoder::new().is_ok() {
                formats.push("hevc".to_string());
            }
            formats
        })
        .clone()
}
