//! VNC Client
//!
//! VNC protocol implementation for remote desktop viewing and control.

use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use thiserror::Error;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

/// VNC errors
#[derive(Debug, Error)]
pub enum VncError {
    /// Connection failed
    #[error("Connection failed: {0}")]
    ConnectionFailed(String),

    /// Authentication failed
    #[error("Authentication failed")]
    AuthenticationFailed,

    /// Protocol error
    #[error("Protocol error: {0}")]
    Protocol(String),

    /// IO error
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    /// Disconnected
    #[error("Disconnected")]
    Disconnected,
}

/// VNC configuration
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VncConfig {
    /// Screen width
    pub width: u32,
    /// Screen height
    pub height: u32,
    /// Bits per pixel
    pub bits_per_pixel: u8,
    /// Color depth
    pub depth: u8,
    /// Enable local cursor
    pub local_cursor: bool,
    /// Enable compression
    pub compression: bool,
    /// Quality level (1-9)
    pub quality: u8,
    /// Frame rate limit
    pub max_fps: u32,
}

impl Default for VncConfig {
    fn default() -> Self {
        Self {
            width: 1920,
            height: 1080,
            bits_per_pixel: 32,
            depth: 24,
            local_cursor: true,
            compression: true,
            quality: 6,
            max_fps: 30,
        }
    }
}

/// VNC events
#[derive(Debug, Clone)]
pub enum VncEvent {
    /// Connected to server
    Connected { width: u32, height: u32 },
    /// Disconnected
    Disconnected,
    /// Frame buffer update
    FrameUpdate {
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        data: Vec<u8>,
    },
    /// Cursor position update
    CursorPosition { x: u16, y: u16 },
    /// Bell notification
    Bell,
    /// Server cut text (clipboard)
    ServerCutText { text: String },
    /// Error occurred
    Error { message: String },
}

/// Mouse button flags
#[allow(dead_code)]
pub mod mouse_button {
    /// Left button
    pub const LEFT: u8 = 0x01;
    /// Middle button
    pub const MIDDLE: u8 = 0x02;
    /// Right button
    pub const RIGHT: u8 = 0x04;
    /// Scroll up
    pub const SCROLL_UP: u8 = 0x08;
    /// Scroll down
    pub const SCROLL_DOWN: u8 = 0x10;
}

/// VNC client state
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VncState {
    /// Disconnected
    Disconnected,
    /// Connecting
    Connecting,
    /// Connected
    Connected,
    /// Error state
    Error,
}

/// VNC Client
pub struct VncClient {
    /// Server address
    address: Option<SocketAddr>,
    /// Configuration
    config: VncConfig,
    /// Current state
    state: VncState,
    /// Event sender
    event_tx: Option<mpsc::Sender<VncEvent>>,
    /// Backing VNC client shared between API calls and event pump
    client: Option<Arc<Mutex<Option<vnc::Client>>>>,
    /// Background event pump task
    event_pump_task: Option<JoinHandle<()>>,
    /// Preferred VNC encodings
    preferred_encodings: Vec<vnc::Encoding>,
    /// Screen dimensions
    screen_width: u32,
    screen_height: u32,
}

impl VncClient {
    fn default_encodings() -> Vec<vnc::Encoding> {
        vec![
            vnc::Encoding::Zrle,
            vnc::Encoding::Raw,
            vnc::Encoding::CopyRect,
            vnc::Encoding::Cursor,
            vnc::Encoding::DesktopSize,
        ]
    }

    fn map_vnc_error(error: vnc::Error) -> VncError {
        match error {
            vnc::Error::Io(inner) => VncError::Io(inner),
            vnc::Error::AuthenticationFailure(_) | vnc::Error::AuthenticationUnavailable => {
                VncError::AuthenticationFailed
            }
            vnc::Error::Disconnected => VncError::Disconnected,
            other => VncError::Protocol(other.to_string()),
        }
    }

    fn password_to_auth_bytes(password: &str) -> [u8; 8] {
        let mut out = [0u8; 8];
        for (idx, byte) in password.as_bytes().iter().copied().take(8).enumerate() {
            out[idx] = byte;
        }
        out
    }

    fn parse_encoding(code: i32) -> vnc::Encoding {
        match code {
            0 => vnc::Encoding::Raw,
            1 => vnc::Encoding::CopyRect,
            2 => vnc::Encoding::Rre,
            5 => vnc::Encoding::Hextile,
            16 => vnc::Encoding::Zrle,
            -239 => vnc::Encoding::Cursor,
            -223 => vnc::Encoding::DesktopSize,
            other => vnc::Encoding::Unknown(other),
        }
    }

    async fn run_client_command<R, F>(&self, command: F) -> Result<R, VncError>
    where
        R: Send + 'static,
        F: FnOnce(&mut vnc::Client) -> Result<R, vnc::Error> + Send + 'static,
    {
        let Some(shared_client) = self.client.as_ref().cloned() else {
            return Err(VncError::Disconnected);
        };
        tokio::task::spawn_blocking(move || {
            let mut guard = shared_client
                .lock()
                .map_err(|_| VncError::Protocol("VNC client lock poisoned".to_string()))?;
            let client = guard.as_mut().ok_or(VncError::Disconnected)?;
            command(client).map_err(Self::map_vnc_error)
        })
        .await
        .map_err(|err| VncError::Protocol(format!("VNC command task failed: {}", err)))?
    }

    /// Create a new VNC client
    pub fn new() -> Self {
        Self {
            address: None,
            config: VncConfig::default(),
            state: VncState::Disconnected,
            event_tx: None,
            client: None,
            event_pump_task: None,
            preferred_encodings: Self::default_encodings(),
            screen_width: 0,
            screen_height: 0,
        }
    }

    /// Create with configuration
    pub fn with_config(config: VncConfig) -> Self {
        Self {
            config,
            ..Self::new()
        }
    }

    /// Get current state
    pub fn state(&self) -> VncState {
        self.state
    }

    /// Update client configuration (applies to new connections)
    pub fn set_config(&mut self, config: VncConfig) {
        self.config = config;
    }

    /// Get screen dimensions
    pub fn screen_size(&self) -> (u32, u32) {
        (self.screen_width, self.screen_height)
    }

    /// Connect to VNC server
    pub async fn connect(
        &mut self,
        address: SocketAddr,
        password: Option<&str>,
    ) -> Result<mpsc::Receiver<VncEvent>, VncError> {
        if self.client.is_some() {
            self.disconnect().await?;
        }

        self.state = VncState::Connecting;
        self.address = Some(address);

        let (tx, rx) = mpsc::channel(100);
        self.event_tx = Some(tx.clone());

        let preferred_encodings = self.preferred_encodings.clone();
        let auth_password = password.map(Self::password_to_auth_bytes);
        let (client, (width, height)) = tokio::task::spawn_blocking(move || {
            let stream = std::net::TcpStream::connect_timeout(&address, Duration::from_secs(10))
                .map_err(|err| VncError::ConnectionFailed(err.to_string()))?;
            let _ = stream.set_nodelay(true);

            let mut client = vnc::Client::from_tcp_stream(stream, true, move |methods| {
                if let Some(password) = auth_password {
                    for method in methods {
                        if matches!(method, vnc::client::AuthMethod::Password) {
                            return Some(vnc::client::AuthChoice::Password(password));
                        }
                    }
                }

                for method in methods {
                    if matches!(method, vnc::client::AuthMethod::None) {
                        return Some(vnc::client::AuthChoice::None);
                    }
                }
                None
            })
            .map_err(Self::map_vnc_error)?;

            client
                .set_encodings(&preferred_encodings)
                .map_err(Self::map_vnc_error)?;

            let size = client.size();
            let framebuffer = vnc::Rect {
                left: 0,
                top: 0,
                width: size.0,
                height: size.1,
            };
            client
                .request_update(framebuffer, false)
                .map_err(Self::map_vnc_error)?;

            Ok::<(vnc::Client, (u16, u16)), VncError>((client, size))
        })
        .await
        .map_err(|err| VncError::ConnectionFailed(format!("VNC connect task failed: {}", err)))??;

        self.screen_width = width as u32;
        self.screen_height = height as u32;
        self.state = VncState::Connected;

        let shared_client = Arc::new(Mutex::new(Some(client)));
        self.client = Some(shared_client.clone());

        let event_tx = tx.clone();
        let event_pump_task = tokio::task::spawn_blocking(move || {
            loop {
                let mut events = Vec::new();
                let mut should_stop = false;

                {
                    let mut guard = match shared_client.lock() {
                        Ok(guard) => guard,
                        Err(_) => {
                            let _ = event_tx.blocking_send(VncEvent::Error {
                                message: "VNC client lock poisoned".to_string(),
                            });
                            break;
                        }
                    };

                    let Some(client) = guard.as_mut() else {
                        break;
                    };

                    while let Some(event) = client.poll_event() {
                        events.push(event);
                    }
                }

                for event in events {
                    match event {
                        vnc::client::Event::Disconnected(error) => {
                            if let Some(error) = error {
                                let _ = event_tx.blocking_send(VncEvent::Error {
                                    message: format!("VNC disconnected: {}", error),
                                });
                            }
                            let _ = event_tx.blocking_send(VncEvent::Disconnected);
                            should_stop = true;
                        }
                        vnc::client::Event::Resize(width, height) => {
                            let _ = event_tx.blocking_send(VncEvent::Connected {
                                width: width as u32,
                                height: height as u32,
                            });
                        }
                        vnc::client::Event::PutPixels(rect, pixels) => {
                            let _ = event_tx.blocking_send(VncEvent::FrameUpdate {
                                x: rect.left,
                                y: rect.top,
                                width: rect.width,
                                height: rect.height,
                                data: pixels,
                            });
                        }
                        vnc::client::Event::SetCursor { hotspot, .. } => {
                            let _ = event_tx.blocking_send(VncEvent::CursorPosition {
                                x: hotspot.0,
                                y: hotspot.1,
                            });
                        }
                        vnc::client::Event::Clipboard(text) => {
                            let _ = event_tx.blocking_send(VncEvent::ServerCutText { text });
                        }
                        vnc::client::Event::Bell => {
                            let _ = event_tx.blocking_send(VncEvent::Bell);
                        }
                        vnc::client::Event::SetColourMap { .. }
                        | vnc::client::Event::CopyPixels { .. }
                        | vnc::client::Event::EndOfFrame => {}
                    }
                }

                if should_stop {
                    if let Ok(mut guard) = shared_client.lock() {
                        *guard = None;
                    }
                    break;
                }

                std::thread::sleep(Duration::from_millis(16));
            }
        });
        self.event_pump_task = Some(event_pump_task);

        let _ = tx
            .send(VncEvent::Connected {
                width: self.screen_width,
                height: self.screen_height,
            })
            .await;

        Ok(rx)
    }

    /// Disconnect from server
    pub async fn disconnect(&mut self) -> Result<(), VncError> {
        if let Some(shared_client) = self.client.take() {
            let _ = tokio::task::spawn_blocking(move || {
                if let Ok(mut guard) = shared_client.lock() {
                    *guard = None;
                }
            })
            .await;
        }

        if let Some(task) = self.event_pump_task.take() {
            let _ = tokio::time::timeout(Duration::from_millis(500), task).await;
        }

        if let Some(tx) = &self.event_tx {
            let _ = tx.send(VncEvent::Disconnected).await;
        }

        self.state = VncState::Disconnected;
        self.address = None;
        self.event_tx = None;

        Ok(())
    }

    /// Send mouse event
    pub async fn send_mouse_event(&self, _x: u16, _y: u16, _buttons: u8) -> Result<(), VncError> {
        self.run_client_command(move |client| client.send_pointer_event(_buttons, _x, _y))
            .await
    }

    /// Send keyboard event
    pub async fn send_key_event(&self, _keysym: u32, _pressed: bool) -> Result<(), VncError> {
        self.run_client_command(move |client| client.send_key_event(_pressed, _keysym))
            .await
    }

    /// Send client cut text (clipboard)
    pub async fn send_cut_text(&self, _text: &str) -> Result<(), VncError> {
        let text = _text.to_string();
        self.run_client_command(move |client| client.update_clipboard(&text))
            .await
    }

    /// Request framebuffer update
    pub async fn request_update(&self, _incremental: bool) -> Result<(), VncError> {
        let width = self.screen_width as u16;
        let height = self.screen_height as u16;
        self.run_client_command(move |client| {
            client.request_update(
                vnc::Rect {
                    left: 0,
                    top: 0,
                    width,
                    height,
                },
                _incremental,
            )
        })
        .await
    }

    /// Set encoding preferences
    pub fn set_encodings(&mut self, encodings: Vec<i32>) {
        self.preferred_encodings = if encodings.is_empty() {
            Self::default_encodings()
        } else {
            encodings.into_iter().map(Self::parse_encoding).collect()
        };
    }
}

impl Default for VncClient {
    fn default() -> Self {
        Self::new()
    }
}
