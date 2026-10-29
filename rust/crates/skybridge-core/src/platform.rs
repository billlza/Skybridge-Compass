//! Cross-platform capability boundary (Phase 0 skeleton).
//!
//! The SkyBridge protocol/transport (`pqc_handshake`, `native_webrtc`, `signaling`,
//! `route`, `session`, …) is already portable Rust with no `cfg(target_os)`. What is
//! still platform-specific is only the *shell*: screen capture, input injection and
//! permission handling. On Apple that shell lives in Swift behind the
//! `PlatformAdapter` protocol (`Sources/SkyBridgeCore/Platform/PlatformAdapter.swift`,
//! `RemoteInputEvents.swift`).
//!
//! This module mirrors that contract as a Rust trait so that Windows / Android / Linux
//! ports reuse the portable core and only implement native capture/inject. The types
//! here are **wire-compatible with the Swift `Codable` models**: every enum serializes
//! to the same string the Swift side uses (see the `#[serde(rename = …)]` attributes),
//! so a JSON event produced by Swift decodes here and vice-versa.
//!
//! Status: Phase 0 skeleton. The trait + types are real and tested; the macOS FFI
//! bridge (`ffi`) is a documented C-ABI contract gated behind the `apple-platform-ffi`
//! feature so the default build links cleanly. The native Linux/Android/Windows impls
//! (X11/XTest, MediaProjection/InputDispatcher, Graphics.Capture/SendInput) land in
//! later phases — see `ROADMAP.md`.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use thiserror::Error;

// MARK: - Screen capture types

/// Pixel format. Wire-compatible with Swift `PixelFormat` (rawValue strings).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum PixelFormat {
    #[serde(rename = "BGRA")]
    #[default]
    Bgra,
    #[serde(rename = "RGBA")]
    Rgba,
    #[serde(rename = "NV12")]
    Nv12,
    #[serde(rename = "I420")]
    I420,
}

/// Screen-capture configuration. Mirrors Swift `ScreenCaptureConfig`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScreenCaptureConfig {
    /// Capture width; `None` = native screen width.
    pub width: Option<u32>,
    /// Capture height; `None` = native screen height.
    pub height: Option<u32>,
    /// Target frame rate.
    pub frame_rate: u32,
    /// Pixel format.
    pub pixel_format: PixelFormat,
    /// Whether to render the cursor into captured frames.
    pub shows_cursor: bool,
}

impl Default for ScreenCaptureConfig {
    fn default() -> Self {
        ScreenCaptureConfig {
            width: None,
            height: None,
            frame_rate: 60,
            pixel_format: PixelFormat::Bgra,
            shows_cursor: true,
        }
    }
}

/// A single captured frame. Mirrors Swift `ScreenFrame` (raw pixel buffer, not encoded).
#[derive(Debug, Clone, PartialEq)]
pub struct ScreenFrame {
    pub width: u32,
    pub height: u32,
    pub format: PixelFormat,
    pub data: Vec<u8>,
    /// Capture timestamp, seconds since the Unix epoch.
    pub timestamp_secs: f64,
    pub is_key_frame: bool,
}

// MARK: - Input event types (wire-compatible with SkyBridge protocol)

/// Keyboard modifier state. Mirrors Swift `SBKeyModifiers`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyModifiers {
    pub ctrl: bool,
    /// Alt / Option.
    pub alt: bool,
    pub shift: bool,
    /// Meta / Command / Windows key.
    pub meta: bool,
}

impl KeyModifiers {
    pub fn has_any(&self) -> bool {
        self.ctrl || self.alt || self.shift || self.meta
    }
}

/// Mouse event kind. Wire-compatible with Swift `SBMouseEventType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MouseEventType {
    #[serde(rename = "mouse-move")]
    Move,
    #[serde(rename = "mouse-click")]
    Click,
    #[serde(rename = "mouse-double-click")]
    DoubleClick,
    #[serde(rename = "mouse-down")]
    Down,
    #[serde(rename = "mouse-up")]
    Up,
    #[serde(rename = "mouse-scroll")]
    Scroll,
}

/// Mouse button. Wire-compatible with Swift `SBMouseButton`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MouseButton {
    Left,
    Right,
    Middle,
}

/// Remote mouse event with normalized (0.0–1.0) coordinates. Mirrors `SBRemoteMouseEvent`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RemoteMouseEvent {
    #[serde(rename = "type")]
    pub event_type: MouseEventType,
    /// Normalized X, clamped to [0, 1].
    pub x: f64,
    /// Normalized Y, clamped to [0, 1].
    pub y: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub button: Option<MouseButton>,
    #[serde(rename = "deltaX", default, skip_serializing_if = "Option::is_none")]
    pub delta_x: Option<f64>,
    #[serde(rename = "deltaY", default, skip_serializing_if = "Option::is_none")]
    pub delta_y: Option<f64>,
    #[serde(default)]
    pub modifiers: KeyModifiers,
    pub timestamp: f64,
}

impl RemoteMouseEvent {
    pub fn is_valid_coordinate(&self) -> bool {
        (0.0..=1.0).contains(&self.x) && (0.0..=1.0).contains(&self.y)
    }
}

/// Keyboard event kind. Wire-compatible with Swift `SBKeyboardEventType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum KeyboardEventType {
    #[serde(rename = "key-down")]
    Down,
    #[serde(rename = "key-up")]
    Up,
}

/// Remote keyboard event. Mirrors `SBRemoteKeyboardEvent`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RemoteKeyboardEvent {
    #[serde(rename = "type")]
    pub event_type: KeyboardEventType,
    #[serde(rename = "keyCode")]
    pub key_code: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(default)]
    pub modifiers: KeyModifiers,
    pub timestamp: f64,
}

/// Remote scroll event. Mirrors `SBRemoteScrollEvent`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RemoteScrollEvent {
    #[serde(rename = "deltaX")]
    pub delta_x: f64,
    #[serde(rename = "deltaY")]
    pub delta_y: f64,
    #[serde(default)]
    pub modifiers: KeyModifiers,
    pub timestamp: f64,
}

// MARK: - Permissions

/// Permission kind. Wire-compatible with Swift `SBPermissionType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PermissionType {
    #[serde(rename = "screen_recording")]
    ScreenRecording,
    #[serde(rename = "accessibility")]
    Accessibility,
    #[serde(rename = "local_network")]
    LocalNetwork,
    #[serde(rename = "camera")]
    Camera,
    #[serde(rename = "microphone")]
    Microphone,
}

/// Permission status. Wire-compatible with Swift `SBPermissionStatus`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PermissionStatus {
    #[serde(rename = "not_determined")]
    NotDetermined,
    #[serde(rename = "authorized")]
    Authorized,
    #[serde(rename = "denied")]
    Denied,
    #[serde(rename = "restricted")]
    Restricted,
}

// MARK: - Error

/// Errors surfaced by a `PlatformAdapter`. Mirrors Swift `PlatformAdapterError`.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum PlatformAdapterError {
    #[error("no display available")]
    NoDisplayAvailable,
    #[error("permission denied: {0:?}")]
    PermissionDenied(PermissionType),
    #[error("screen capture not started")]
    CaptureNotStarted,
    #[error("input injection failed: {0}")]
    InputInjectionFailed(String),
    #[error("discovery failed: {0}")]
    DiscoveryFailed(String),
    #[error("unsupported operation: {0}")]
    UnsupportedOperation(String),
}

// MARK: - The trait

/// Cross-platform capability boundary. One implementation per OS shell.
///
/// The portable protocol/transport core depends only on this trait, never on
/// `cfg(target_os)`. Apple bridges to the existing Swift `MacPlatformAdapter` via
/// [`ffi`]; other platforms implement it natively (see `ROADMAP.md`).
#[async_trait]
pub trait PlatformAdapter: Send + Sync {
    // Screen capture
    async fn start_screen_capture(
        &self,
        config: ScreenCaptureConfig,
    ) -> Result<(), PlatformAdapterError>;
    async fn stop_screen_capture(&self);
    async fn get_screen_frame(&self) -> Option<ScreenFrame>;

    // Input injection
    async fn inject_mouse_event(&self, event: RemoteMouseEvent)
    -> Result<(), PlatformAdapterError>;
    async fn inject_keyboard_event(
        &self,
        event: RemoteKeyboardEvent,
    ) -> Result<(), PlatformAdapterError>;
    async fn inject_scroll_event(
        &self,
        event: RemoteScrollEvent,
    ) -> Result<(), PlatformAdapterError>;

    // Permissions
    async fn check_permission(&self, permission: PermissionType) -> PermissionStatus;
    async fn request_permission(&self, permission: PermissionType) -> bool;
    fn open_permission_settings(&self, permission: PermissionType);
}

/// A no-op adapter that reports everything as unsupported. Useful for headless
/// transport-only contexts (CLI handshake/file-transfer that never drives a screen)
/// and as a default in tests before a native shell is wired in.
#[derive(Debug, Default, Clone, Copy)]
pub struct StubPlatformAdapter;

#[async_trait]
impl PlatformAdapter for StubPlatformAdapter {
    async fn start_screen_capture(
        &self,
        _config: ScreenCaptureConfig,
    ) -> Result<(), PlatformAdapterError> {
        Err(PlatformAdapterError::UnsupportedOperation(
            "screen capture".into(),
        ))
    }
    async fn stop_screen_capture(&self) {}
    async fn get_screen_frame(&self) -> Option<ScreenFrame> {
        None
    }
    async fn inject_mouse_event(
        &self,
        _event: RemoteMouseEvent,
    ) -> Result<(), PlatformAdapterError> {
        Err(PlatformAdapterError::UnsupportedOperation(
            "mouse injection".into(),
        ))
    }
    async fn inject_keyboard_event(
        &self,
        _event: RemoteKeyboardEvent,
    ) -> Result<(), PlatformAdapterError> {
        Err(PlatformAdapterError::UnsupportedOperation(
            "keyboard injection".into(),
        ))
    }
    async fn inject_scroll_event(
        &self,
        _event: RemoteScrollEvent,
    ) -> Result<(), PlatformAdapterError> {
        Err(PlatformAdapterError::UnsupportedOperation(
            "scroll injection".into(),
        ))
    }
    async fn check_permission(&self, _permission: PermissionType) -> PermissionStatus {
        PermissionStatus::NotDetermined
    }
    async fn request_permission(&self, _permission: PermissionType) -> bool {
        false
    }
    fn open_permission_settings(&self, _permission: PermissionType) {}
}

/// macOS/iOS FFI bridge (Phase 0). Behind the `apple-platform-ffi` feature so the
/// default build never references the host symbols.
///
/// ## C ABI contract (host implements, Rust calls)
///
/// The Apple host exports these with `@_cdecl`, bridging into the existing Swift
/// `MacPlatformAdapter`. JSON payloads use the wire-compatible models above.
///
/// ```c
/// // returns 0 on success, negative PlatformAdapterError code otherwise
/// int32_t skybridge_platform_start_screen_capture(const uint8_t *cfg_json, uintptr_t len);
/// void    skybridge_platform_stop_screen_capture(void);
/// int32_t skybridge_platform_inject_mouse(const uint8_t *evt_json, uintptr_t len);
/// int32_t skybridge_platform_inject_keyboard(const uint8_t *evt_json, uintptr_t len);
/// int32_t skybridge_platform_inject_scroll(const uint8_t *evt_json, uintptr_t len);
/// int32_t skybridge_platform_check_permission(uint32_t perm);   // PermissionStatus ordinal
/// int32_t skybridge_platform_request_permission(uint32_t perm); // 1 granted / 0 denied
/// void    skybridge_platform_open_permission_settings(uint32_t perm);
/// ```
///
/// Frame delivery (`get_screen_frame`) is intentionally NOT a pull FFI call — Phase 1
/// will register a push callback (host → Rust) so captured frames flow straight into
/// the transport ring buffer without copying across the boundary each poll.
#[cfg(feature = "apple-platform-ffi")]
pub mod ffi {
    use super::*;

    unsafe extern "C" {
        fn skybridge_platform_start_screen_capture(cfg_json: *const u8, len: usize) -> i32;
        fn skybridge_platform_stop_screen_capture();
        fn skybridge_platform_inject_mouse(evt_json: *const u8, len: usize) -> i32;
        fn skybridge_platform_inject_keyboard(evt_json: *const u8, len: usize) -> i32;
        fn skybridge_platform_inject_scroll(evt_json: *const u8, len: usize) -> i32;
        fn skybridge_platform_check_permission(perm: u32) -> i32;
        fn skybridge_platform_request_permission(perm: u32) -> i32;
        fn skybridge_platform_open_permission_settings(perm: u32);
    }

    fn perm_ordinal(p: PermissionType) -> u32 {
        match p {
            PermissionType::ScreenRecording => 0,
            PermissionType::Accessibility => 1,
            PermissionType::LocalNetwork => 2,
            PermissionType::Camera => 3,
            PermissionType::Microphone => 4,
        }
    }

    fn status_from_ordinal(v: i32) -> PermissionStatus {
        match v {
            1 => PermissionStatus::Authorized,
            2 => PermissionStatus::Denied,
            3 => PermissionStatus::Restricted,
            _ => PermissionStatus::NotDetermined,
        }
    }

    fn check_rc(rc: i32, what: &str) -> Result<(), PlatformAdapterError> {
        if rc == 0 {
            Ok(())
        } else {
            Err(PlatformAdapterError::InputInjectionFailed(format!(
                "{what} host returned {rc}"
            )))
        }
    }

    /// Adapter that bridges the trait onto the Apple host's C ABI.
    #[derive(Debug, Default, Clone, Copy)]
    pub struct ApplePlatformAdapter;

    #[async_trait]
    impl PlatformAdapter for ApplePlatformAdapter {
        async fn start_screen_capture(
            &self,
            config: ScreenCaptureConfig,
        ) -> Result<(), PlatformAdapterError> {
            let json = serde_json::to_vec(&config)
                .map_err(|e| PlatformAdapterError::InputInjectionFailed(e.to_string()))?;
            let rc = unsafe { skybridge_platform_start_screen_capture(json.as_ptr(), json.len()) };
            check_rc(rc, "start_screen_capture")
        }
        async fn stop_screen_capture(&self) {
            unsafe { skybridge_platform_stop_screen_capture() }
        }
        async fn get_screen_frame(&self) -> Option<ScreenFrame> {
            // Push-callback delivery lands in Phase 1; pull is intentionally unsupported.
            None
        }
        async fn inject_mouse_event(
            &self,
            event: RemoteMouseEvent,
        ) -> Result<(), PlatformAdapterError> {
            let json = serde_json::to_vec(&event)
                .map_err(|e| PlatformAdapterError::InputInjectionFailed(e.to_string()))?;
            let rc = unsafe { skybridge_platform_inject_mouse(json.as_ptr(), json.len()) };
            check_rc(rc, "inject_mouse")
        }
        async fn inject_keyboard_event(
            &self,
            event: RemoteKeyboardEvent,
        ) -> Result<(), PlatformAdapterError> {
            let json = serde_json::to_vec(&event)
                .map_err(|e| PlatformAdapterError::InputInjectionFailed(e.to_string()))?;
            let rc = unsafe { skybridge_platform_inject_keyboard(json.as_ptr(), json.len()) };
            check_rc(rc, "inject_keyboard")
        }
        async fn inject_scroll_event(
            &self,
            event: RemoteScrollEvent,
        ) -> Result<(), PlatformAdapterError> {
            let json = serde_json::to_vec(&event)
                .map_err(|e| PlatformAdapterError::InputInjectionFailed(e.to_string()))?;
            let rc = unsafe { skybridge_platform_inject_scroll(json.as_ptr(), json.len()) };
            check_rc(rc, "inject_scroll")
        }
        async fn check_permission(&self, permission: PermissionType) -> PermissionStatus {
            let rc = unsafe { skybridge_platform_check_permission(perm_ordinal(permission)) };
            status_from_ordinal(rc)
        }
        async fn request_permission(&self, permission: PermissionType) -> bool {
            unsafe { skybridge_platform_request_permission(perm_ordinal(permission)) == 1 }
        }
        fn open_permission_settings(&self, permission: PermissionType) {
            unsafe { skybridge_platform_open_permission_settings(perm_ordinal(permission)) }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_defaults_match_swift() {
        let c = ScreenCaptureConfig::default();
        assert_eq!(c.frame_rate, 60);
        assert_eq!(c.pixel_format, PixelFormat::Bgra);
        assert!(c.shows_cursor);
        assert!(c.width.is_none());
    }

    #[test]
    fn pixel_format_wire_strings_match_swift() {
        assert_eq!(
            serde_json::to_string(&PixelFormat::Bgra).unwrap(),
            "\"BGRA\""
        );
        assert_eq!(
            serde_json::to_string(&PixelFormat::Nv12).unwrap(),
            "\"NV12\""
        );
    }

    #[test]
    fn mouse_event_decodes_swift_json() {
        // A payload as emitted by the Swift SBRemoteMouseEvent encoder.
        let json = r#"{"type":"mouse-down","x":0.5,"y":0.25,"button":"left",
            "modifiers":{"ctrl":false,"alt":false,"shift":true,"meta":false},
            "timestamp":1750000000.0}"#;
        let evt: RemoteMouseEvent = serde_json::from_str(json).unwrap();
        assert_eq!(evt.event_type, MouseEventType::Down);
        assert_eq!(evt.button, Some(MouseButton::Left));
        assert!(evt.modifiers.shift && !evt.modifiers.ctrl);
        assert!(evt.is_valid_coordinate());
        // Round-trips back to a structurally equal value.
        let reser: RemoteMouseEvent =
            serde_json::from_str(&serde_json::to_string(&evt).unwrap()).unwrap();
        assert_eq!(reser, evt);
    }

    #[test]
    fn keyboard_and_permission_wire_strings() {
        assert_eq!(
            serde_json::to_string(&KeyboardEventType::Down).unwrap(),
            "\"key-down\""
        );
        assert_eq!(
            serde_json::to_string(&PermissionType::ScreenRecording).unwrap(),
            "\"screen_recording\""
        );
        assert_eq!(
            serde_json::to_string(&PermissionStatus::NotDetermined).unwrap(),
            "\"not_determined\""
        );
    }

    #[tokio::test]
    async fn stub_reports_unsupported() {
        let a = StubPlatformAdapter;
        assert!(
            a.start_screen_capture(ScreenCaptureConfig::default())
                .await
                .is_err()
        );
        assert!(a.get_screen_frame().await.is_none());
        assert_eq!(
            a.check_permission(PermissionType::Accessibility).await,
            PermissionStatus::NotDetermined
        );
        assert!(!a.request_permission(PermissionType::Camera).await);
    }
}
