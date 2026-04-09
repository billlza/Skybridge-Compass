//! Wayland input handler backed by a shared xdg-desktop-portal RemoteDesktop session.

use crate::remote::capture::DisplayServer;
use crate::remote::input::{InputError, InputHandler, KeyEvent, KeyEventType, MouseEvent};
use crate::remote::portal::{
    PortalError, ensure_runtime_portal_session, send_keyboard_event, send_pointer_event,
};

/// Wayland input handler via the shared portal coordinator.
pub struct WaylandInputHandler {
    initialized: bool,
}

impl WaylandInputHandler {
    /// Create a new Wayland input handler.
    pub fn new() -> Self {
        Self { initialized: false }
    }
}

impl Default for WaylandInputHandler {
    fn default() -> Self {
        Self::new()
    }
}

fn map_portal_error(error: PortalError) -> InputError {
    match error {
        PortalError::BootstrapRequired | PortalError::RebootstrapRequired => {
            InputError::Portal(error.to_string())
        }
        PortalError::PermissionDenied => InputError::PermissionDenied,
        PortalError::PersistentOutputLost => InputError::Portal(error.to_string()),
        PortalError::SecretStoreUnavailable(_) => InputError::Portal(error.to_string()),
        PortalError::Portal(_) | PortalError::Io(_) | PortalError::Serde(_) => {
            InputError::Portal(error.to_string())
        }
    }
}

#[async_trait::async_trait]
impl InputHandler for WaylandInputHandler {
    async fn initialize(&mut self) -> Result<(), InputError> {
        if !DisplayServer::detect().is_wayland() {
            return Err(InputError::NotSupported(DisplayServer::Wayland));
        }

        ensure_runtime_portal_session(true)
            .await
            .map_err(map_portal_error)?;
        self.initialized = true;
        Ok(())
    }

    async fn send_mouse(&self, event: &MouseEvent) -> Result<(), InputError> {
        if !self.initialized {
            return Err(InputError::NotInitialized);
        }
        send_pointer_event(event).await.map_err(map_portal_error)
    }

    async fn send_key(&self, event: &KeyEvent) -> Result<(), InputError> {
        if !self.initialized {
            return Err(InputError::NotInitialized);
        }
        send_keyboard_event(event).await.map_err(map_portal_error)
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

    async fn set_clipboard(&self, _text: &str) -> Result<(), InputError> {
        Err(InputError::Portal(
            "Wayland clipboard sync is disabled until portal-native clipboard support lands"
                .to_string(),
        ))
    }

    async fn get_clipboard(&self) -> Result<String, InputError> {
        Err(InputError::Portal(
            "Wayland clipboard sync is disabled until portal-native clipboard support lands"
                .to_string(),
        ))
    }

    fn display_server(&self) -> DisplayServer {
        DisplayServer::Wayland
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_wayland_input_creation() {
        let handler = WaylandInputHandler::new();
        assert!(!handler.initialized);
        assert_eq!(handler.display_server(), DisplayServer::Wayland);
    }
}
