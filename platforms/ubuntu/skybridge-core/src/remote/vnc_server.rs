//! VNC (RFB) server for macOS/iOS interoperability.
//!
//! Minimal RFB 3.8 server:
//! - Security: None (type 1)
//! - Encoding: Raw (0)
//! - Pixel format: BGRA 32-bit, little-endian

use std::net::SocketAddr;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use crate::remote::capture::{CaptureConfig, CapturedFrame, PixelFormat, ScreenCapturer};
use crate::remote::input::{KeyEvent, KeyModifiers, MouseButton, MouseEvent, UnifiedInputHandler};

#[derive(Debug, thiserror::Error)]
pub enum VncServerError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Capture error: {0}")]
    Capture(#[from] crate::remote::capture::CaptureError),
    #[error("Input error: {0}")]
    Input(#[from] crate::remote::input::InputError),
    #[error("Protocol error: {0}")]
    Protocol(String),
}

#[derive(Debug, Clone)]
pub struct VncServerConfig {
    pub bind_addr: SocketAddr,
    pub name: String,
    pub target_fps: u32,
    pub capture_cursor: bool,
    pub allow_input: bool,
}

impl Default for VncServerConfig {
    fn default() -> Self {
        Self {
            bind_addr: "0.0.0.0:5900".parse().unwrap(),
            name: "SkyBridge VNC".to_string(),
            target_fps: 30,
            capture_cursor: true,
            allow_input: true,
        }
    }
}

pub struct VncServer {
    config: VncServerConfig,
}

impl VncServer {
    pub fn new(config: VncServerConfig) -> Self {
        Self { config }
    }

    pub async fn serve(&self) -> Result<(), VncServerError> {
        let listener = TcpListener::bind(self.config.bind_addr).await?;
        loop {
            let (stream, _addr) = listener.accept().await?;
            if let Err(err) = self.handle_client(stream).await {
                tracing::warn!("VNC session ended with error: {}", err);
            }
        }
    }

    async fn handle_client(&self, mut stream: tokio::net::TcpStream) -> Result<(), VncServerError> {
        let mut capturer = ScreenCapturer::new()?;
        capturer.initialize().await?;
        let screens = capturer.get_screens().await?;
        let primary = screens
            .iter()
            .find(|s| s.is_primary)
            .or_else(|| screens.first())
            .cloned()
            .ok_or_else(|| VncServerError::Protocol("no screens available".to_string()))?;

        perform_handshake(
            &mut stream,
            primary.width as u16,
            primary.height as u16,
            &self.config.name,
        )
        .await?;

        let mut input = UnifiedInputHandler::new()?;
        input.initialize().await?;

        let capture_config = CaptureConfig {
            target_fps: self.config.target_fps,
            capture_cursor: self.config.capture_cursor,
            ..Default::default()
        };
        let mut frame_rx = capturer.start(&capture_config).await?;

        let mut wants_updates = false;
        let mut last_button_mask: u8 = 0;

        loop {
            tokio::select! {
                frame = frame_rx.recv() => {
                    if let Some(frame) = frame {
                        if wants_updates {
                            send_framebuffer_update(&mut stream, &frame, primary.width, primary.height).await?;
                        }
                    } else {
                        break;
                    }
                }
                msg = read_client_message(&mut stream) => {
                    match msg? {
                        ClientMessage::SetPixelFormat => {},
                        ClientMessage::SetEncodings => {},
                        ClientMessage::FramebufferUpdateRequest { .. } => {
                            wants_updates = true;
                        }
                        ClientMessage::KeyEvent { down, keysym } => {
                            if !self.config.allow_input {
                                continue;
                            }
                            let event = if down {
                                KeyEvent::key_down(keysym, KeyModifiers::default())
                            } else {
                                KeyEvent::key_up(keysym, KeyModifiers::default())
                            };
                            input.send_key(&event).await?;
                        }
                        ClientMessage::PointerEvent { button_mask, x, y } => {
                            if !self.config.allow_input {
                                continue;
                            }
                            handle_pointer_event(&mut input, &mut last_button_mask, button_mask, x, y).await?;
                        }
                        ClientMessage::ClientCutText { text } => {
                            if !self.config.allow_input {
                                continue;
                            }
                            if !text.is_empty() {
                                input.set_clipboard(&text).await?;
                            }
                        }
                        ClientMessage::Disconnected => {
                            break;
                        }
                    }
                }
            }
        }

        capturer.stop().await?;
        Ok(())
    }
}

#[derive(Debug)]
#[allow(dead_code)]
enum ClientMessage {
    SetPixelFormat,
    SetEncodings,
    FramebufferUpdateRequest {
        incremental: bool,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    },
    KeyEvent {
        down: bool,
        keysym: u32,
    },
    PointerEvent {
        button_mask: u8,
        x: u16,
        y: u16,
    },
    ClientCutText {
        text: String,
    },
    Disconnected,
}

async fn perform_handshake(
    stream: &mut tokio::net::TcpStream,
    width: u16,
    height: u16,
    name: &str,
) -> Result<(), VncServerError> {
    // Server protocol version
    stream.write_all(b"RFB 003.008\n").await?;
    // Client protocol version
    let mut client_ver = [0u8; 12];
    stream.read_exact(&mut client_ver).await?;
    if !client_ver.starts_with(b"RFB ") {
        return Err(VncServerError::Protocol(
            "invalid protocol version".to_string(),
        ));
    }

    // Security types: None only
    stream.write_all(&[1u8, 1u8]).await?;
    let mut sec_type = [0u8; 1];
    stream.read_exact(&mut sec_type).await?;
    if sec_type[0] != 1 {
        return Err(VncServerError::Protocol(
            "unsupported security type".to_string(),
        ));
    }
    stream.write_all(&0u32.to_be_bytes()).await?;

    // ClientInit
    let mut _client_init = [0u8; 1];
    stream.read_exact(&mut _client_init).await?;

    // ServerInit
    let mut server_init = Vec::with_capacity(24);
    server_init.extend_from_slice(&width.to_be_bytes());
    server_init.extend_from_slice(&height.to_be_bytes());
    server_init.extend_from_slice(&pixel_format_bgra());
    let name_bytes = name.as_bytes();
    server_init.extend_from_slice(&(name_bytes.len() as u32).to_be_bytes());
    server_init.extend_from_slice(name_bytes);
    stream.write_all(&server_init).await?;
    stream.flush().await?;
    Ok(())
}

async fn read_client_message(
    stream: &mut tokio::net::TcpStream,
) -> Result<ClientMessage, VncServerError> {
    let msg_type = match stream.read_u8().await {
        Ok(t) => t,
        Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => {
            return Ok(ClientMessage::Disconnected);
        }
        Err(err) => return Err(err.into()),
    };

    match msg_type {
        0 => {
            // SetPixelFormat: 3 bytes padding + 16 bytes pixel format
            let mut buf = [0u8; 19];
            stream.read_exact(&mut buf).await?;
            Ok(ClientMessage::SetPixelFormat)
        }
        2 => {
            // SetEncodings: padding + count + encodings
            let mut hdr = [0u8; 3];
            stream.read_exact(&mut hdr).await?;
            let count = u16::from_be_bytes([hdr[1], hdr[2]]) as usize;
            let mut enc_buf = vec![0u8; count * 4];
            if !enc_buf.is_empty() {
                stream.read_exact(&mut enc_buf).await?;
            }
            Ok(ClientMessage::SetEncodings)
        }
        3 => {
            // FramebufferUpdateRequest
            let incremental = stream.read_u8().await? != 0;
            let mut coords = [0u8; 8];
            stream.read_exact(&mut coords).await?;
            let x = u16::from_be_bytes([coords[0], coords[1]]);
            let y = u16::from_be_bytes([coords[2], coords[3]]);
            let width = u16::from_be_bytes([coords[4], coords[5]]);
            let height = u16::from_be_bytes([coords[6], coords[7]]);
            Ok(ClientMessage::FramebufferUpdateRequest {
                incremental,
                x,
                y,
                width,
                height,
            })
        }
        4 => {
            // KeyEvent
            let down = stream.read_u8().await? != 0;
            let mut pad = [0u8; 2];
            stream.read_exact(&mut pad).await?;
            let mut key = [0u8; 4];
            stream.read_exact(&mut key).await?;
            let keysym = u32::from_be_bytes(key);
            Ok(ClientMessage::KeyEvent { down, keysym })
        }
        5 => {
            // PointerEvent
            let button_mask = stream.read_u8().await?;
            let mut coords = [0u8; 4];
            stream.read_exact(&mut coords).await?;
            let x = u16::from_be_bytes([coords[0], coords[1]]);
            let y = u16::from_be_bytes([coords[2], coords[3]]);
            Ok(ClientMessage::PointerEvent { button_mask, x, y })
        }
        6 => {
            // ClientCutText
            let mut hdr = [0u8; 7];
            stream.read_exact(&mut hdr).await?;
            let length = u32::from_be_bytes([hdr[3], hdr[4], hdr[5], hdr[6]]) as usize;
            let mut buf = vec![0u8; length];
            if length > 0 {
                stream.read_exact(&mut buf).await?;
            }
            let text = String::from_utf8_lossy(&buf).to_string();
            Ok(ClientMessage::ClientCutText { text })
        }
        _ => Err(VncServerError::Protocol(format!(
            "unknown client message type {}",
            msg_type
        ))),
    }
}

async fn send_framebuffer_update(
    stream: &mut tokio::net::TcpStream,
    frame: &CapturedFrame,
    width: u32,
    height: u32,
) -> Result<(), VncServerError> {
    if frame.width != width || frame.height != height {
        return Ok(());
    }

    let payload = frame_to_bgra(frame);
    let mut msg = Vec::with_capacity(12 + payload.len());
    msg.push(0); // FramebufferUpdate
    msg.push(0); // padding
    msg.extend_from_slice(&(1u16).to_be_bytes());
    msg.extend_from_slice(&0u16.to_be_bytes());
    msg.extend_from_slice(&0u16.to_be_bytes());
    msg.extend_from_slice(&(width as u16).to_be_bytes());
    msg.extend_from_slice(&(height as u16).to_be_bytes());
    msg.extend_from_slice(&(0i32).to_be_bytes()); // Raw encoding
    msg.extend_from_slice(&payload);
    stream.write_all(&msg).await?;
    stream.flush().await?;
    Ok(())
}

async fn handle_pointer_event(
    input: &mut UnifiedInputHandler,
    last_mask: &mut u8,
    mask: u8,
    x: u16,
    y: u16,
) -> Result<(), VncServerError> {
    let x = x as i32;
    let y = y as i32;
    input.send_mouse(&MouseEvent::move_to(x, y)).await?;

    // Scroll events are encoded as transient bits.
    if mask & 0x08 != 0 {
        input.send_mouse(&MouseEvent::scroll(0, -1, x, y)).await?;
        return Ok(());
    }
    if mask & 0x10 != 0 {
        input.send_mouse(&MouseEvent::scroll(0, 1, x, y)).await?;
        return Ok(());
    }

    let changed = *last_mask ^ mask;
    for (bit, button) in &[
        (0x01, MouseButton::Left),
        (0x02, MouseButton::Middle),
        (0x04, MouseButton::Right),
    ] {
        if changed & bit != 0 {
            if mask & bit != 0 {
                input
                    .send_mouse(&MouseEvent::button_down(*button, x, y))
                    .await?;
            } else {
                input
                    .send_mouse(&MouseEvent::button_up(*button, x, y))
                    .await?;
            }
        }
    }
    *last_mask = mask;
    Ok(())
}

fn pixel_format_bgra() -> [u8; 16] {
    let mut pf = [0u8; 16];
    pf[0] = 32; // bits per pixel
    pf[1] = 24; // depth
    pf[2] = 0; // little endian
    pf[3] = 1; // true color
    pf[4..6].copy_from_slice(&255u16.to_be_bytes()); // red max
    pf[6..8].copy_from_slice(&255u16.to_be_bytes()); // green max
    pf[8..10].copy_from_slice(&255u16.to_be_bytes()); // blue max
    pf[10] = 16; // red shift
    pf[11] = 8; // green shift
    pf[12] = 0; // blue shift
    pf
}

fn frame_to_bgra(frame: &CapturedFrame) -> Vec<u8> {
    match frame.format {
        PixelFormat::Bgra8888 => frame.data.clone(),
        PixelFormat::Rgba8888 => {
            let mut out = Vec::with_capacity(frame.data.len());
            for chunk in frame.data.chunks(4) {
                if chunk.len() == 4 {
                    out.push(chunk[2]);
                    out.push(chunk[1]);
                    out.push(chunk[0]);
                    out.push(chunk[3]);
                }
            }
            out
        }
        PixelFormat::Rgb888 => {
            let mut out = Vec::with_capacity((frame.data.len() / 3) * 4);
            for chunk in frame.data.chunks(3) {
                if chunk.len() == 3 {
                    out.push(chunk[2]);
                    out.push(chunk[1]);
                    out.push(chunk[0]);
                    out.push(255);
                }
            }
            out
        }
        PixelFormat::Bgr888 => {
            let mut out = Vec::with_capacity((frame.data.len() / 3) * 4);
            for chunk in frame.data.chunks(3) {
                if chunk.len() == 3 {
                    out.push(chunk[0]);
                    out.push(chunk[1]);
                    out.push(chunk[2]);
                    out.push(255);
                }
            }
            out
        }
    }
}
