//! X11 Input Handler Implementation
//!
//! Uses XTest extension for input injection on X11.

use std::sync::Arc;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{self, ConnectionExt, Keycode};
use x11rb::protocol::xtest::ConnectionExt as XTestExt;
use x11rb::rust_connection::RustConnection;

use crate::remote::capture::DisplayServer;
use crate::remote::input::{
    InputError, InputHandler, KeyEvent, KeyEventType, MouseButton, MouseEvent, MouseEventType,
};

/// X11 input handler using XTest extension
pub struct X11InputHandler {
    connection: Option<Arc<RustConnection>>,
    root_window: u32,
    initialized: bool,
}

impl X11InputHandler {
    /// Create a new X11 input handler
    pub fn new() -> Self {
        Self {
            connection: None,
            root_window: 0,
            initialized: false,
        }
    }

    /// Convert keysym to keycode
    fn keysym_to_keycode(&self, keysym: u32) -> Option<Keycode> {
        let conn = self.connection.as_ref()?;
        let setup = conn.setup();
        let min_keycode = setup.min_keycode;
        let max_keycode = setup.max_keycode;

        // Get keyboard mapping
        if let Ok(mapping) = conn.get_keyboard_mapping(min_keycode, max_keycode - min_keycode + 1)
            && let Ok(reply) = mapping.reply()
        {
            let keysyms_per_keycode = reply.keysyms_per_keycode as usize;
            for (idx, chunk) in reply.keysyms.chunks(keysyms_per_keycode).enumerate() {
                for ks in chunk {
                    if *ks == keysym {
                        return Some((min_keycode + idx as u8) as Keycode);
                    }
                }
            }
        }

        // For ASCII characters, try direct mapping
        if (0x20..=0x7e).contains(&keysym) {
            // Simple ASCII mapping - lookup from keyboard
            return Some((keysym as u8 + 8) as Keycode);
        }

        None
    }
}

impl Default for X11InputHandler {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl InputHandler for X11InputHandler {
    async fn initialize(&mut self) -> Result<(), InputError> {
        if std::env::var("DISPLAY").is_err() {
            return Err(InputError::X11("DISPLAY not set".to_string()));
        }

        let (conn, screen_num) =
            RustConnection::connect(None).map_err(|e| InputError::X11(e.to_string()))?;

        // Check XTest extension
        let xtest_query = conn
            .xtest_get_version(2, 2)
            .map_err(|e| InputError::X11(e.to_string()))?;
        let xtest_version = xtest_query
            .reply()
            .map_err(|e| InputError::X11(e.to_string()))?;

        tracing::info!(
            "XTest extension version: {}.{}",
            xtest_version.major_version,
            xtest_version.minor_version
        );

        let setup = conn.setup();
        let screen = &setup.roots[screen_num];
        self.root_window = screen.root;
        self.connection = Some(Arc::new(conn));
        self.initialized = true;

        tracing::info!("X11 input handler initialized via XTest");
        Ok(())
    }

    async fn send_mouse(&self, event: &MouseEvent) -> Result<(), InputError> {
        if !self.initialized {
            return Err(InputError::NotInitialized);
        }

        let conn = self.connection.as_ref().ok_or(InputError::NotInitialized)?;

        match &event.event_type {
            MouseEventType::Move { x, y } => {
                // XTestFakeMotionEvent
                conn.xtest_fake_input(
                    xproto::MOTION_NOTIFY_EVENT,
                    0, // detail (unused for motion)
                    x11rb::CURRENT_TIME,
                    self.root_window,
                    *x as i16,
                    *y as i16,
                    0,
                )
                .map_err(|e| InputError::X11(e.to_string()))?;
            }
            MouseEventType::ButtonDown { button } => {
                let button_code = button.to_x11_button();
                conn.xtest_fake_input(
                    xproto::BUTTON_PRESS_EVENT,
                    button_code,
                    x11rb::CURRENT_TIME,
                    self.root_window,
                    0,
                    0,
                    0,
                )
                .map_err(|e| InputError::X11(e.to_string()))?;
            }
            MouseEventType::ButtonUp { button } => {
                let button_code = button.to_x11_button();
                conn.xtest_fake_input(
                    xproto::BUTTON_RELEASE_EVENT,
                    button_code,
                    x11rb::CURRENT_TIME,
                    self.root_window,
                    0,
                    0,
                    0,
                )
                .map_err(|e| InputError::X11(e.to_string()))?;
            }
            MouseEventType::Click { button } => {
                let button_code = button.to_x11_button();
                // Press
                conn.xtest_fake_input(
                    xproto::BUTTON_PRESS_EVENT,
                    button_code,
                    x11rb::CURRENT_TIME,
                    self.root_window,
                    0,
                    0,
                    0,
                )
                .map_err(|e| InputError::X11(e.to_string()))?;
                // Release
                conn.xtest_fake_input(
                    xproto::BUTTON_RELEASE_EVENT,
                    button_code,
                    x11rb::CURRENT_TIME,
                    self.root_window,
                    0,
                    0,
                    0,
                )
                .map_err(|e| InputError::X11(e.to_string()))?;
            }
            MouseEventType::DoubleClick { button } => {
                let button_code = button.to_x11_button();
                for _ in 0..2 {
                    conn.xtest_fake_input(
                        xproto::BUTTON_PRESS_EVENT,
                        button_code,
                        x11rb::CURRENT_TIME,
                        self.root_window,
                        0,
                        0,
                        0,
                    )
                    .map_err(|e| InputError::X11(e.to_string()))?;
                    conn.xtest_fake_input(
                        xproto::BUTTON_RELEASE_EVENT,
                        button_code,
                        x11rb::CURRENT_TIME,
                        self.root_window,
                        0,
                        0,
                        0,
                    )
                    .map_err(|e| InputError::X11(e.to_string()))?;
                }
            }
            MouseEventType::Scroll { dx, dy } => {
                // Scroll using button 4/5 (vertical) and 6/7 (horizontal)
                if *dy != 0 {
                    let button = if *dy > 0 {
                        MouseButton::ScrollUp.to_x11_button()
                    } else {
                        MouseButton::ScrollDown.to_x11_button()
                    };
                    let count = dy.abs();
                    for _ in 0..count {
                        conn.xtest_fake_input(
                            xproto::BUTTON_PRESS_EVENT,
                            button,
                            x11rb::CURRENT_TIME,
                            self.root_window,
                            0,
                            0,
                            0,
                        )
                        .map_err(|e| InputError::X11(e.to_string()))?;
                        conn.xtest_fake_input(
                            xproto::BUTTON_RELEASE_EVENT,
                            button,
                            x11rb::CURRENT_TIME,
                            self.root_window,
                            0,
                            0,
                            0,
                        )
                        .map_err(|e| InputError::X11(e.to_string()))?;
                    }
                }
                if *dx != 0 {
                    let button = if *dx > 0 {
                        MouseButton::ScrollRight.to_x11_button()
                    } else {
                        MouseButton::ScrollLeft.to_x11_button()
                    };
                    let count = dx.abs();
                    for _ in 0..count {
                        conn.xtest_fake_input(
                            xproto::BUTTON_PRESS_EVENT,
                            button,
                            x11rb::CURRENT_TIME,
                            self.root_window,
                            0,
                            0,
                            0,
                        )
                        .map_err(|e| InputError::X11(e.to_string()))?;
                        conn.xtest_fake_input(
                            xproto::BUTTON_RELEASE_EVENT,
                            button,
                            x11rb::CURRENT_TIME,
                            self.root_window,
                            0,
                            0,
                            0,
                        )
                        .map_err(|e| InputError::X11(e.to_string()))?;
                    }
                }
            }
        }

        conn.flush().map_err(|e| InputError::X11(e.to_string()))?;
        Ok(())
    }

    async fn send_key(&self, event: &KeyEvent) -> Result<(), InputError> {
        if !self.initialized {
            return Err(InputError::NotInitialized);
        }

        let conn = self.connection.as_ref().ok_or(InputError::NotInitialized)?;

        // Convert keysym to keycode
        let keycode = self
            .keysym_to_keycode(event.keysym)
            .unwrap_or(event.keysym as u8);

        let event_type = match event.event_type {
            KeyEventType::KeyDown => xproto::KEY_PRESS_EVENT,
            KeyEventType::KeyUp => xproto::KEY_RELEASE_EVENT,
            KeyEventType::KeyTyped => {
                // Send both press and release
                conn.xtest_fake_input(
                    xproto::KEY_PRESS_EVENT,
                    keycode,
                    x11rb::CURRENT_TIME,
                    self.root_window,
                    0,
                    0,
                    0,
                )
                .map_err(|e| InputError::X11(e.to_string()))?;
                xproto::KEY_RELEASE_EVENT
            }
        };

        conn.xtest_fake_input(
            event_type,
            keycode,
            x11rb::CURRENT_TIME,
            self.root_window,
            0,
            0,
            0,
        )
        .map_err(|e| InputError::X11(e.to_string()))?;

        conn.flush().map_err(|e| InputError::X11(e.to_string()))?;
        Ok(())
    }

    async fn type_text(&self, text: &str) -> Result<(), InputError> {
        if !self.initialized {
            return Err(InputError::NotInitialized);
        }

        for c in text.chars() {
            let down = KeyEvent::from_char(c, KeyEventType::KeyDown);
            let up = KeyEvent::from_char(c, KeyEventType::KeyUp);
            self.send_key(&down).await?;
            self.send_key(&up).await?;
        }
        Ok(())
    }

    async fn set_clipboard(&self, text: &str) -> Result<(), InputError> {
        if !self.initialized {
            return Err(InputError::NotInitialized);
        }

        // Use xclip or xsel for clipboard
        let output = std::process::Command::new("xclip")
            .arg("-selection")
            .arg("clipboard")
            .stdin(std::process::Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                use std::io::Write;
                if let Some(ref mut stdin) = child.stdin {
                    stdin.write_all(text.as_bytes())?;
                }
                child.wait()
            });

        match output {
            Ok(status) if status.success() => Ok(()),
            _ => {
                // Fallback to xsel
                let output = std::process::Command::new("xsel")
                    .arg("--clipboard")
                    .arg("--input")
                    .stdin(std::process::Stdio::piped())
                    .spawn()
                    .and_then(|mut child| {
                        use std::io::Write;
                        if let Some(ref mut stdin) = child.stdin {
                            stdin.write_all(text.as_bytes())?;
                        }
                        child.wait()
                    });

                match output {
                    Ok(status) if status.success() => Ok(()),
                    _ => Err(InputError::X11(
                        "Failed to set clipboard (xclip/xsel not available)".to_string(),
                    )),
                }
            }
        }
    }

    async fn get_clipboard(&self) -> Result<String, InputError> {
        if !self.initialized {
            return Err(InputError::NotInitialized);
        }

        // Use xclip or xsel for clipboard
        let output = std::process::Command::new("xclip")
            .arg("-selection")
            .arg("clipboard")
            .arg("-o")
            .output();

        match output {
            Ok(out) if out.status.success() => Ok(String::from_utf8_lossy(&out.stdout).to_string()),
            _ => {
                // Fallback to xsel
                let output = std::process::Command::new("xsel")
                    .arg("--clipboard")
                    .arg("--output")
                    .output();

                match output {
                    Ok(out) if out.status.success() => {
                        Ok(String::from_utf8_lossy(&out.stdout).to_string())
                    }
                    _ => Err(InputError::X11(
                        "Failed to get clipboard (xclip/xsel not available)".to_string(),
                    )),
                }
            }
        }
    }

    fn display_server(&self) -> DisplayServer {
        DisplayServer::X11
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_x11_input_creation() {
        let handler = X11InputHandler::new();
        assert!(!handler.initialized);
        assert_eq!(handler.display_server(), DisplayServer::X11);
    }
}
