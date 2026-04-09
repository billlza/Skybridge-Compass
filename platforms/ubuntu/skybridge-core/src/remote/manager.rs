//! Remote Desktop Manager
//!
//! Manages remote desktop sessions.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};
use tracing::{debug, info, warn};

use super::capture::CaptureConfig;
use super::encoder::EncoderConfig;
use super::mac_remote::{MacRemoteControlClient, RemoteKeyboardEvent, RemoteMouseEvent};
use super::vnc::{VncClient, VncConfig, VncError};
use crate::discovery::{DeviceCapability, DiscoveredDevice, Platform};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RemoteTransport {
    Vnc,
    MacJson,
}

/// Remote session state
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    /// Session is connecting
    Connecting,
    /// Session is active
    Active,
    /// Session is paused
    Paused,
    /// Session is disconnected
    Disconnected,
    /// Session encountered an error
    Error,
}

/// A remote desktop session
pub struct RemoteSession {
    /// Session ID
    pub id: String,
    /// Remote device ID
    pub device_id: String,
    /// Session state
    pub state: SessionState,
    /// Selected remote transport
    transport: RemoteTransport,
    /// VNC client backend
    vnc_client: Option<VncClient>,
    /// macOS/iOS JSON remote-control backend
    mac_client: Option<Arc<Mutex<MacRemoteControlClient>>>,
    /// Previous mouse button mask for event edge generation on Mac transport
    last_mouse_buttons: Arc<Mutex<u8>>,
    /// Is view only
    pub view_only: bool,
}

impl RemoteSession {
    /// Create a new remote session
    fn new(
        id: String,
        device_id: String,
        config: VncConfig,
        view_only: bool,
        transport: RemoteTransport,
    ) -> Self {
        Self {
            id,
            device_id,
            state: SessionState::Disconnected,
            transport,
            vnc_client: match transport {
                RemoteTransport::Vnc => Some(VncClient::with_config(config)),
                RemoteTransport::MacJson => None,
            },
            mac_client: None,
            last_mouse_buttons: Arc::new(Mutex::new(0)),
            view_only,
        }
    }

    fn map_mac_remote_error(error: super::mac_remote::MacRemoteControlError) -> VncError {
        use super::mac_remote::MacRemoteControlError;
        match error {
            MacRemoteControlError::Io(io_error) => VncError::Io(io_error),
            MacRemoteControlError::ConnectionClosed => VncError::Disconnected,
            MacRemoteControlError::InvalidFrameLength(length) => {
                VncError::Protocol(format!("Invalid remote frame length: {}", length))
            }
            MacRemoteControlError::UnexpectedMessageType(message_type) => {
                VncError::Protocol(format!("Unexpected remote message type: {}", message_type))
            }
            MacRemoteControlError::Json(json_error) => {
                VncError::Protocol(format!("Remote JSON error: {}", json_error))
            }
        }
    }

    fn remote_timestamp_seconds() -> f64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs_f64())
            .unwrap_or_default()
    }

    /// Get screen size
    pub fn screen_size(&self) -> (u32, u32) {
        self.vnc_client
            .as_ref()
            .map(VncClient::screen_size)
            .unwrap_or((0, 0))
    }

    /// Connect session client
    pub async fn connect(&mut self, address: std::net::SocketAddr) -> Result<(), VncError> {
        self.state = SessionState::Connecting;
        match self.transport {
            RemoteTransport::Vnc => {
                let Some(client) = self.vnc_client.as_mut() else {
                    self.state = SessionState::Error;
                    return Err(VncError::Protocol("Missing VNC client backend".to_string()));
                };
                match client.connect(address, None).await {
                    Ok(_events) => {
                        self.state = SessionState::Active;
                        Ok(())
                    }
                    Err(error) => {
                        self.state = SessionState::Error;
                        Err(error)
                    }
                }
            }
            RemoteTransport::MacJson => match MacRemoteControlClient::connect(address).await {
                Ok(client) => {
                    self.mac_client = Some(Arc::new(Mutex::new(client)));
                    self.state = SessionState::Active;
                    Ok(())
                }
                Err(error) => {
                    self.state = SessionState::Error;
                    Err(Self::map_mac_remote_error(error))
                }
            },
        }
    }

    /// Disconnect session client
    pub async fn disconnect(&mut self) -> Result<(), VncError> {
        match self.transport {
            RemoteTransport::Vnc => {
                if let Some(client) = self.vnc_client.as_mut() {
                    client.disconnect().await?;
                }
            }
            RemoteTransport::MacJson => {
                self.mac_client = None;
            }
        }
        *self.last_mouse_buttons.lock().await = 0;
        self.state = SessionState::Disconnected;
        Ok(())
    }

    /// Send mouse event
    pub async fn send_mouse(&self, x: u16, y: u16, buttons: u8) -> Result<(), VncError> {
        if self.view_only {
            return Ok(());
        }
        match self.transport {
            RemoteTransport::Vnc => {
                let Some(client) = self.vnc_client.as_ref() else {
                    return Err(VncError::Disconnected);
                };
                client.send_mouse_event(x, y, buttons).await
            }
            RemoteTransport::MacJson => {
                let Some(client) = self.mac_client.as_ref() else {
                    return Err(VncError::Disconnected);
                };
                let previous_buttons = *self.last_mouse_buttons.lock().await;
                let current_buttons =
                    buttons & (super::vnc::mouse_button::LEFT | super::vnc::mouse_button::RIGHT);
                let mut generated_edge = false;

                let changed = previous_buttons ^ current_buttons;
                if changed & super::vnc::mouse_button::LEFT != 0 {
                    generated_edge = true;
                    let event_type = if current_buttons & super::vnc::mouse_button::LEFT != 0 {
                        "leftMouseDown"
                    } else {
                        "leftMouseUp"
                    };
                    let event = RemoteMouseEvent {
                        r#type: event_type.to_string(),
                        x: x as f64,
                        y: y as f64,
                        timestamp: Self::remote_timestamp_seconds(),
                    };
                    let mut guard = client.lock().await;
                    guard
                        .send_mouse_event(&event)
                        .await
                        .map_err(Self::map_mac_remote_error)?;
                }
                if changed & super::vnc::mouse_button::RIGHT != 0 {
                    generated_edge = true;
                    let event_type = if current_buttons & super::vnc::mouse_button::RIGHT != 0 {
                        "rightMouseDown"
                    } else {
                        "rightMouseUp"
                    };
                    let event = RemoteMouseEvent {
                        r#type: event_type.to_string(),
                        x: x as f64,
                        y: y as f64,
                        timestamp: Self::remote_timestamp_seconds(),
                    };
                    let mut guard = client.lock().await;
                    guard
                        .send_mouse_event(&event)
                        .await
                        .map_err(Self::map_mac_remote_error)?;
                }

                if buttons & super::vnc::mouse_button::SCROLL_UP != 0 {
                    let event = RemoteMouseEvent {
                        r#type: "scrollUp".to_string(),
                        x: x as f64,
                        y: y as f64,
                        timestamp: Self::remote_timestamp_seconds(),
                    };
                    let mut guard = client.lock().await;
                    guard
                        .send_mouse_event(&event)
                        .await
                        .map_err(Self::map_mac_remote_error)?;
                    generated_edge = true;
                }
                if buttons & super::vnc::mouse_button::SCROLL_DOWN != 0 {
                    let event = RemoteMouseEvent {
                        r#type: "scrollDown".to_string(),
                        x: x as f64,
                        y: y as f64,
                        timestamp: Self::remote_timestamp_seconds(),
                    };
                    let mut guard = client.lock().await;
                    guard
                        .send_mouse_event(&event)
                        .await
                        .map_err(Self::map_mac_remote_error)?;
                    generated_edge = true;
                }

                if !generated_edge {
                    let event = RemoteMouseEvent {
                        r#type: "mouseMoved".to_string(),
                        x: x as f64,
                        y: y as f64,
                        timestamp: Self::remote_timestamp_seconds(),
                    };
                    let mut guard = client.lock().await;
                    guard
                        .send_mouse_event(&event)
                        .await
                        .map_err(Self::map_mac_remote_error)?;
                }

                *self.last_mouse_buttons.lock().await = current_buttons;
                Ok(())
            }
        }
    }

    /// Send key event
    pub async fn send_key(&self, keysym: u32, pressed: bool) -> Result<(), VncError> {
        if self.view_only {
            return Ok(());
        }
        match self.transport {
            RemoteTransport::Vnc => {
                let Some(client) = self.vnc_client.as_ref() else {
                    return Err(VncError::Disconnected);
                };
                client.send_key_event(keysym, pressed).await
            }
            RemoteTransport::MacJson => {
                let Some(client) = self.mac_client.as_ref() else {
                    return Err(VncError::Disconnected);
                };
                let event = RemoteKeyboardEvent {
                    r#type: if pressed {
                        "keyDown".to_string()
                    } else {
                        "keyUp".to_string()
                    },
                    key_code: keysym.min(i32::MAX as u32) as i32,
                    timestamp: Self::remote_timestamp_seconds(),
                };
                let mut guard = client.lock().await;
                guard
                    .send_keyboard_event(&event)
                    .await
                    .map_err(Self::map_mac_remote_error)
            }
        }
    }

    /// Send clipboard text
    pub async fn send_clipboard(&self, text: &str) -> Result<(), VncError> {
        match self.transport {
            RemoteTransport::Vnc => {
                let Some(client) = self.vnc_client.as_ref() else {
                    return Err(VncError::Disconnected);
                };
                client.send_cut_text(text).await
            }
            RemoteTransport::MacJson => {
                debug!("Remote clipboard passthrough is not supported on Mac JSON transport yet");
                Ok(())
            }
        }
    }
}

/// Remote desktop manager
pub struct RemoteDesktopManager {
    /// Active sessions
    sessions: Arc<RwLock<HashMap<String, Arc<RwLock<RemoteSession>>>>>,
    /// Default configuration
    default_config: Arc<RwLock<VncConfig>>,
    /// Default encoder configuration (for streaming)
    encoder_config: Arc<RwLock<EncoderConfig>>,
    /// Default capture configuration (for streaming)
    capture_config: Arc<RwLock<CaptureConfig>>,
}

impl RemoteDesktopManager {
    fn select_remote_transport(device: &DiscoveredDevice) -> RemoteTransport {
        let has_remote_capability = device.has_capability(DeviceCapability::RemoteDesktopView)
            || device.has_capability(DeviceCapability::RemoteDesktopControl);
        let is_apple_platform = matches!(
            device.platform,
            Platform::MacOS | Platform::IOS | Platform::IPadOS
        );

        if has_remote_capability && (is_apple_platform || !device.remote_addresses.is_empty()) {
            RemoteTransport::MacJson
        } else {
            RemoteTransport::Vnc
        }
    }

    /// Create a new remote desktop manager
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
            default_config: Arc::new(RwLock::new(VncConfig::default())),
            encoder_config: Arc::new(RwLock::new(EncoderConfig::default())),
            capture_config: Arc::new(RwLock::new(CaptureConfig::default())),
        }
    }

    /// Create with configuration
    pub fn with_config(config: VncConfig) -> Self {
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
            default_config: Arc::new(RwLock::new(config)),
            encoder_config: Arc::new(RwLock::new(EncoderConfig::default())),
            capture_config: Arc::new(RwLock::new(CaptureConfig::default())),
        }
    }

    /// Update default configuration and apply to existing sessions
    pub async fn update_default_config(&self, config: VncConfig) {
        {
            let mut guard = self.default_config.write().await;
            *guard = config.clone();
        }

        let sessions = self.sessions.read().await;
        for session in sessions.values() {
            let mut session = session.write().await;
            if let Some(client) = session.vnc_client.as_mut() {
                client.set_config(config.clone());
            }
        }
    }

    /// Update streaming encoder/capture defaults
    pub async fn update_streaming_config(&self, encoder: EncoderConfig, capture: CaptureConfig) {
        {
            let mut guard = self.encoder_config.write().await;
            *guard = encoder;
        }
        {
            let mut guard = self.capture_config.write().await;
            *guard = capture;
        }
    }

    /// Get streaming encoder/capture defaults
    pub async fn streaming_config(&self) -> (EncoderConfig, CaptureConfig) {
        let encoder = self.encoder_config.read().await.clone();
        let capture = self.capture_config.read().await.clone();
        (encoder, capture)
    }

    /// Connect to a device
    pub async fn connect(
        &self,
        device: &DiscoveredDevice,
        view_only: bool,
    ) -> Result<String, VncError> {
        let preferred_address = device
            .best_remote_address()
            .copied()
            .or_else(|| device.best_address().copied())
            .ok_or_else(|| VncError::ConnectionFailed("Device has no reachable address".into()))?;
        let session_id = uuid::Uuid::new_v4().to_string();
        let config = { self.default_config.read().await.clone() };
        let preferred_transport = Self::select_remote_transport(device);

        let mut session = RemoteSession::new(
            session_id.clone(),
            device.device_id.clone(),
            config.clone(),
            view_only,
            preferred_transport,
        );
        let connect_result = session.connect(preferred_address).await;

        if connect_result.is_err() && preferred_transport == RemoteTransport::MacJson {
            warn!(
                "Mac JSON remote connect failed for device {}, falling back to VNC at {}",
                device.device_id, preferred_address
            );
            let mut fallback_session = RemoteSession::new(
                session_id.clone(),
                device.device_id.clone(),
                config,
                view_only,
                RemoteTransport::Vnc,
            );
            fallback_session.connect(preferred_address).await?;
            session = fallback_session;
        } else {
            connect_result?;
        }

        let mut sessions = self.sessions.write().await;
        sessions.insert(session_id.clone(), Arc::new(RwLock::new(session)));

        info!(
            "Connected remote session {} for device {} at {}",
            session_id, device.device_id, preferred_address
        );

        Ok(session_id)
    }

    /// Disconnect a session
    pub async fn disconnect(&self, session_id: &str) -> Result<(), VncError> {
        let mut sessions = self.sessions.write().await;

        if let Some(session) = sessions.remove(session_id) {
            let mut session = session.write().await;
            session.disconnect().await?;
            info!("Disconnected session {}", session_id);
        }

        Ok(())
    }

    /// Get a session
    pub async fn get_session(&self, session_id: &str) -> Option<Arc<RwLock<RemoteSession>>> {
        let sessions = self.sessions.read().await;
        sessions.get(session_id).cloned()
    }

    /// Get all session IDs
    pub async fn session_ids(&self) -> Vec<String> {
        let sessions = self.sessions.read().await;
        sessions.keys().cloned().collect()
    }

    /// Disconnect all sessions
    pub async fn disconnect_all(&self) -> Result<(), VncError> {
        let session_ids: Vec<String> = {
            let sessions = self.sessions.read().await;
            sessions.keys().cloned().collect()
        };

        for session_id in session_ids {
            self.disconnect(&session_id).await?;
        }

        Ok(())
    }
}

impl Default for RemoteDesktopManager {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for RemoteDesktopManager {
    fn drop(&mut self) {
        // Sessions will be cleaned up when dropped
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::discovery::{DeviceCapability, Platform};

    fn make_device(platform: Platform, with_remote_addr: bool) -> DiscoveredDevice {
        let mut device = DiscoveredDevice::new(
            "peer-1".to_string(),
            "Peer".to_string(),
            "abc".to_string(),
            platform,
        );
        device
            .capabilities
            .push(DeviceCapability::RemoteDesktopView);
        if with_remote_addr {
            device
                .remote_addresses
                .push("127.0.0.1:5901".parse().expect("socket addr"));
        } else {
            device
                .addresses
                .push("127.0.0.1:5900".parse().expect("socket addr"));
        }
        device
    }

    #[test]
    fn select_transport_prefers_mac_json_for_apple_peers() {
        let device = make_device(Platform::MacOS, true);
        assert_eq!(
            RemoteDesktopManager::select_remote_transport(&device),
            RemoteTransport::MacJson
        );
    }

    #[test]
    fn select_transport_uses_vnc_for_non_apple_without_remote_service() {
        let device = make_device(Platform::Ubuntu, false);
        assert_eq!(
            RemoteDesktopManager::select_remote_transport(&device),
            RemoteTransport::Vnc
        );
    }
}
