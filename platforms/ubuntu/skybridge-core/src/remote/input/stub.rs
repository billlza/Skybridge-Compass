//! Stub implementations for non-Linux platforms

use crate::remote::capture::DisplayServer;
use crate::remote::input::{InputError, InputHandler, KeyEvent, MouseEvent};

/// Stub Wayland input handler for non-Linux platforms
pub struct WaylandInputHandler;

impl WaylandInputHandler {
    /// Create a new stub handler
    pub fn new() -> Self {
        Self
    }
}

impl Default for WaylandInputHandler {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl InputHandler for WaylandInputHandler {
    async fn initialize(&mut self) -> Result<(), InputError> {
        Err(InputError::Wayland(
            "Wayland input not supported on this platform".to_string(),
        ))
    }

    async fn send_mouse(&self, _event: &MouseEvent) -> Result<(), InputError> {
        Err(InputError::NotInitialized)
    }

    async fn send_key(&self, _event: &KeyEvent) -> Result<(), InputError> {
        Err(InputError::NotInitialized)
    }

    async fn type_text(&self, _text: &str) -> Result<(), InputError> {
        Err(InputError::NotInitialized)
    }

    async fn set_clipboard(&self, _text: &str) -> Result<(), InputError> {
        Err(InputError::NotInitialized)
    }

    async fn get_clipboard(&self) -> Result<String, InputError> {
        Err(InputError::NotInitialized)
    }

    fn display_server(&self) -> DisplayServer {
        DisplayServer::Wayland
    }
}

/// Stub X11 input handler for non-Linux platforms
pub struct X11InputHandler;

impl X11InputHandler {
    /// Create a new stub handler
    pub fn new() -> Self {
        Self
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
        Err(InputError::X11(
            "X11 input not supported on this platform".to_string(),
        ))
    }

    async fn send_mouse(&self, _event: &MouseEvent) -> Result<(), InputError> {
        Err(InputError::NotInitialized)
    }

    async fn send_key(&self, _event: &KeyEvent) -> Result<(), InputError> {
        Err(InputError::NotInitialized)
    }

    async fn type_text(&self, _text: &str) -> Result<(), InputError> {
        Err(InputError::NotInitialized)
    }

    async fn set_clipboard(&self, _text: &str) -> Result<(), InputError> {
        Err(InputError::NotInitialized)
    }

    async fn get_clipboard(&self) -> Result<String, InputError> {
        Err(InputError::NotInitialized)
    }

    fn display_server(&self) -> DisplayServer {
        DisplayServer::X11
    }
}
