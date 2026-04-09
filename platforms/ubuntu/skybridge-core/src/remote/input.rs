//! Input Handling Module
//!
//! Provides cross-platform input injection for remote desktop control.
//! Supports keyboard, mouse, and clipboard operations on both Wayland and X11.

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::capture::DisplayServer;

/// Input handling errors
#[derive(Debug, Error)]
pub enum InputError {
    /// Not supported on this display server
    #[error("Input injection not supported on {0:?}")]
    NotSupported(DisplayServer),

    /// Permission denied
    #[error("Permission denied for input injection")]
    PermissionDenied,

    /// X11 error
    #[error("X11 input error: {0}")]
    X11(String),

    /// Wayland error
    #[error("Wayland input error: {0}")]
    Wayland(String),

    /// Portal error
    #[error("Portal error: {0}")]
    Portal(String),

    /// Not initialized
    #[error("Input handler not initialized")]
    NotInitialized,
}

/// Mouse button
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MouseButton {
    /// Left button
    Left,
    /// Middle button
    Middle,
    /// Right button
    Right,
    /// Scroll up
    ScrollUp,
    /// Scroll down
    ScrollDown,
    /// Scroll left
    ScrollLeft,
    /// Scroll right
    ScrollRight,
    /// Extra button 1 (back)
    Button4,
    /// Extra button 2 (forward)
    Button5,
}

impl MouseButton {
    /// Convert to VNC button mask
    pub fn to_vnc_mask(&self) -> u8 {
        match self {
            Self::Left => 0x01,
            Self::Middle => 0x02,
            Self::Right => 0x04,
            Self::ScrollUp => 0x08,
            Self::ScrollDown => 0x10,
            Self::ScrollLeft => 0x20,
            Self::ScrollRight => 0x40,
            Self::Button4 => 0x80,
            Self::Button5 => 0x80,
        }
    }

    /// Convert to X11 button code
    pub fn to_x11_button(&self) -> u8 {
        match self {
            Self::Left => 1,
            Self::Middle => 2,
            Self::Right => 3,
            Self::ScrollUp => 4,
            Self::ScrollDown => 5,
            Self::ScrollLeft => 6,
            Self::ScrollRight => 7,
            Self::Button4 => 8,
            Self::Button5 => 9,
        }
    }
}

/// Mouse event type
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum MouseEventType {
    /// Mouse moved
    Move {
        /// X coordinate
        x: i32,
        /// Y coordinate
        y: i32,
    },
    /// Button pressed
    ButtonDown {
        /// Button pressed
        button: MouseButton,
    },
    /// Button released
    ButtonUp {
        /// Button released
        button: MouseButton,
    },
    /// Button clicked (down + up)
    Click {
        /// Button clicked
        button: MouseButton,
    },
    /// Button double-clicked
    DoubleClick {
        /// Button double-clicked
        button: MouseButton,
    },
    /// Scroll event
    Scroll {
        /// Horizontal delta
        dx: i32,
        /// Vertical delta
        dy: i32,
    },
}

/// Mouse event
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MouseEvent {
    /// Event type
    pub event_type: MouseEventType,
    /// Current X position
    pub x: i32,
    /// Current Y position
    pub y: i32,
    /// Timestamp
    pub timestamp: u64,
}

impl MouseEvent {
    /// Create a move event
    pub fn move_to(x: i32, y: i32) -> Self {
        Self {
            event_type: MouseEventType::Move { x, y },
            x,
            y,
            timestamp: Self::now(),
        }
    }

    /// Create a button down event
    pub fn button_down(button: MouseButton, x: i32, y: i32) -> Self {
        Self {
            event_type: MouseEventType::ButtonDown { button },
            x,
            y,
            timestamp: Self::now(),
        }
    }

    /// Create a button up event
    pub fn button_up(button: MouseButton, x: i32, y: i32) -> Self {
        Self {
            event_type: MouseEventType::ButtonUp { button },
            x,
            y,
            timestamp: Self::now(),
        }
    }

    /// Create a click event
    pub fn click(button: MouseButton, x: i32, y: i32) -> Self {
        Self {
            event_type: MouseEventType::Click { button },
            x,
            y,
            timestamp: Self::now(),
        }
    }

    /// Create a scroll event
    pub fn scroll(dx: i32, dy: i32, x: i32, y: i32) -> Self {
        Self {
            event_type: MouseEventType::Scroll { dx, dy },
            x,
            y,
            timestamp: Self::now(),
        }
    }

    fn now() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64
    }
}

/// Key modifier flags
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct KeyModifiers {
    /// Shift pressed
    pub shift: bool,
    /// Control pressed
    pub ctrl: bool,
    /// Alt pressed
    pub alt: bool,
    /// Super/Windows key pressed
    pub super_key: bool,
    /// Caps lock active
    pub caps_lock: bool,
    /// Num lock active
    pub num_lock: bool,
}

impl KeyModifiers {
    /// Convert to X11 modifier mask
    pub fn to_x11_mask(&self) -> u32 {
        let mut mask = 0u32;
        if self.shift {
            mask |= 1 << 0;
        }
        if self.caps_lock {
            mask |= 1 << 1;
        }
        if self.ctrl {
            mask |= 1 << 2;
        }
        if self.alt {
            mask |= 1 << 3;
        }
        if self.num_lock {
            mask |= 1 << 4;
        }
        if self.super_key {
            mask |= 1 << 6;
        }
        mask
    }
}

/// Key event type
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum KeyEventType {
    /// Key pressed
    KeyDown,
    /// Key released
    KeyUp,
    /// Key typed (for text input)
    KeyTyped,
}

/// Keyboard event
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyEvent {
    /// Event type
    pub event_type: KeyEventType,
    /// Key code (platform-specific)
    pub keycode: u32,
    /// X11 keysym
    pub keysym: u32,
    /// Unicode character (if applicable)
    pub unicode: Option<char>,
    /// Current modifiers
    pub modifiers: KeyModifiers,
    /// Timestamp
    pub timestamp: u64,
}

impl KeyEvent {
    /// Create a key down event
    pub fn key_down(keysym: u32, modifiers: KeyModifiers) -> Self {
        Self {
            event_type: KeyEventType::KeyDown,
            keycode: 0,
            keysym,
            unicode: None,
            modifiers,
            timestamp: Self::now(),
        }
    }

    /// Create a key up event
    pub fn key_up(keysym: u32, modifiers: KeyModifiers) -> Self {
        Self {
            event_type: KeyEventType::KeyUp,
            keycode: 0,
            keysym,
            unicode: None,
            modifiers,
            timestamp: Self::now(),
        }
    }

    /// Create from Unicode character
    pub fn from_char(c: char, event_type: KeyEventType) -> Self {
        Self {
            event_type,
            keycode: 0,
            keysym: c as u32,
            unicode: Some(c),
            modifiers: KeyModifiers::default(),
            timestamp: Self::now(),
        }
    }

    fn now() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64
    }
}

/// Common X11 keysyms
pub mod keysym {
    /// Backspace key
    pub const BACKSPACE: u32 = 0xff08;
    /// Tab key
    pub const TAB: u32 = 0xff09;
    /// Return/Enter key
    pub const RETURN: u32 = 0xff0d;
    /// Escape key
    pub const ESCAPE: u32 = 0xff1b;
    /// Delete key
    pub const DELETE: u32 = 0xffff;

    /// Home key
    pub const HOME: u32 = 0xff50;
    /// Left arrow
    pub const LEFT: u32 = 0xff51;
    /// Up arrow
    pub const UP: u32 = 0xff52;
    /// Right arrow
    pub const RIGHT: u32 = 0xff53;
    /// Down arrow
    pub const DOWN: u32 = 0xff54;
    /// Page Up key
    pub const PAGE_UP: u32 = 0xff55;
    /// Page Down key
    pub const PAGE_DOWN: u32 = 0xff56;
    /// End key
    pub const END: u32 = 0xff57;

    /// Left Shift
    pub const SHIFT_L: u32 = 0xffe1;
    /// Right Shift
    pub const SHIFT_R: u32 = 0xffe2;
    /// Left Control
    pub const CONTROL_L: u32 = 0xffe3;
    /// Right Control
    pub const CONTROL_R: u32 = 0xffe4;
    /// Caps Lock
    pub const CAPS_LOCK: u32 = 0xffe5;
    /// Left Alt
    pub const ALT_L: u32 = 0xffe9;
    /// Right Alt
    pub const ALT_R: u32 = 0xffea;
    /// Left Super/Windows
    pub const SUPER_L: u32 = 0xffeb;
    /// Right Super/Windows
    pub const SUPER_R: u32 = 0xffec;

    /// F1 key
    pub const F1: u32 = 0xffbe;
    /// F2 key
    pub const F2: u32 = 0xffbf;
    /// F3 key
    pub const F3: u32 = 0xffc0;
    /// F4 key
    pub const F4: u32 = 0xffc1;
    /// F5 key
    pub const F5: u32 = 0xffc2;
    /// F6 key
    pub const F6: u32 = 0xffc3;
    /// F7 key
    pub const F7: u32 = 0xffc4;
    /// F8 key
    pub const F8: u32 = 0xffc5;
    /// F9 key
    pub const F9: u32 = 0xffc6;
    /// F10 key
    pub const F10: u32 = 0xffc7;
    /// F11 key
    pub const F11: u32 = 0xffc8;
    /// F12 key
    pub const F12: u32 = 0xffc9;

    /// Insert key
    pub const INSERT: u32 = 0xff63;
    /// Print Screen key
    pub const PRINT: u32 = 0xff61;
    /// Scroll Lock key
    pub const SCROLL_LOCK: u32 = 0xff14;
    /// Pause key
    pub const PAUSE: u32 = 0xff13;
    /// Num Lock key
    pub const NUM_LOCK: u32 = 0xff7f;
}

/// Input handler trait
#[async_trait::async_trait]
pub trait InputHandler: Send + Sync {
    /// Initialize the input handler
    async fn initialize(&mut self) -> Result<(), InputError>;

    /// Send mouse event
    async fn send_mouse(&self, event: &MouseEvent) -> Result<(), InputError>;

    /// Send keyboard event
    async fn send_key(&self, event: &KeyEvent) -> Result<(), InputError>;

    /// Type text (sends key events for each character)
    async fn type_text(&self, text: &str) -> Result<(), InputError>;

    /// Set clipboard text
    async fn set_clipboard(&self, text: &str) -> Result<(), InputError>;

    /// Get clipboard text
    async fn get_clipboard(&self) -> Result<String, InputError>;

    /// Get display server type
    fn display_server(&self) -> DisplayServer;
}

// Platform-specific implementations
#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
pub use linux::{WaylandInputHandler, X11InputHandler};

// Stub implementations for non-Linux platforms
#[cfg(not(target_os = "linux"))]
mod stub;

#[cfg(not(target_os = "linux"))]
pub use stub::{WaylandInputHandler, X11InputHandler};

/// Unified input handler that auto-selects backend
pub struct UnifiedInputHandler {
    handler: Box<dyn InputHandler>,
}

impl UnifiedInputHandler {
    /// Create a new unified input handler with auto-detected backend
    pub fn new() -> Result<Self, InputError> {
        let display_server = DisplayServer::detect();

        let handler: Box<dyn InputHandler> = match display_server {
            DisplayServer::Wayland => Box::new(WaylandInputHandler::new()),
            DisplayServer::X11 => Box::new(X11InputHandler::new()),
            DisplayServer::Unknown => {
                // Try X11 as fallback
                if std::env::var("DISPLAY").is_ok() {
                    Box::new(X11InputHandler::new())
                } else {
                    return Err(InputError::NotSupported(DisplayServer::Unknown));
                }
            }
        };

        Ok(Self { handler })
    }

    /// Initialize the handler
    pub async fn initialize(&mut self) -> Result<(), InputError> {
        self.handler.initialize().await
    }

    /// Send mouse event
    pub async fn send_mouse(&self, event: &MouseEvent) -> Result<(), InputError> {
        self.handler.send_mouse(event).await
    }

    /// Send keyboard event
    pub async fn send_key(&self, event: &KeyEvent) -> Result<(), InputError> {
        self.handler.send_key(event).await
    }

    /// Type text
    pub async fn type_text(&self, text: &str) -> Result<(), InputError> {
        self.handler.type_text(text).await
    }

    /// Set clipboard
    pub async fn set_clipboard(&self, text: &str) -> Result<(), InputError> {
        self.handler.set_clipboard(text).await
    }

    /// Get clipboard
    pub async fn get_clipboard(&self) -> Result<String, InputError> {
        self.handler.get_clipboard().await
    }

    /// Get display server
    pub fn display_server(&self) -> DisplayServer {
        self.handler.display_server()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mouse_button_conversion() {
        assert_eq!(MouseButton::Left.to_vnc_mask(), 0x01);
        assert_eq!(MouseButton::Right.to_vnc_mask(), 0x04);
        assert_eq!(MouseButton::Left.to_x11_button(), 1);
        assert_eq!(MouseButton::Right.to_x11_button(), 3);
    }

    #[test]
    fn test_key_modifiers() {
        let mods = KeyModifiers {
            shift: true,
            ctrl: true,
            ..Default::default()
        };
        let mask = mods.to_x11_mask();
        assert!(mask & (1 << 0) != 0); // Shift
        assert!(mask & (1 << 2) != 0); // Ctrl
    }

    #[test]
    fn test_mouse_event_creation() {
        let event = MouseEvent::click(MouseButton::Left, 100, 200);
        assert_eq!(event.x, 100);
        assert_eq!(event.y, 200);
        match event.event_type {
            MouseEventType::Click { button } => assert_eq!(button, MouseButton::Left),
            _ => panic!("Wrong event type"),
        }
    }
}
