//! macOS Pro-release compatible remote-control server.
//!
//! Wire format (matches SkyBridge Compass Pro `RemoteControlServer`):
//! - TCP: 5901 (by default)
//! - Frame: u32 length (big-endian) + JSON(RemoteMessage)
//! - RemoteMessage.payload is base64 of inner JSON bytes (Swift `Data` JSON encoding)

use std::net::SocketAddr;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use crate::remote::capture::{CaptureConfig, ScreenCapturer};
use crate::remote::input::{KeyEvent, MouseButton, MouseEvent, UnifiedInputHandler};
use crate::remote::mac_remote::{
    RemoteKeyboardEvent, RemoteMessage, RemoteMessageType, RemoteMouseEvent, ScreenData,
};

const MAX_FRAME_BYTES: usize = 32_000_000;

#[derive(Debug, thiserror::Error)]
pub enum MacRemoteControlServerError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("capture: {0}")]
    Capture(#[from] crate::remote::capture::CaptureError),
    #[error("input: {0}")]
    Input(#[from] crate::remote::input::InputError),
    #[error("jpeg: {0}")]
    Jpeg(String),
    #[error("protocol: {0}")]
    Protocol(String),
}

#[derive(Debug, Clone)]
pub struct MacRemoteControlServerConfig {
    pub bind_addr: SocketAddr,
    pub name: String,
    pub target_fps: u32,
    pub jpeg_quality: u8,
    pub capture_cursor: bool,
    pub allow_input: bool,
}

impl Default for MacRemoteControlServerConfig {
    fn default() -> Self {
        Self {
            bind_addr: "0.0.0.0:5901".parse().unwrap(),
            name: "SkyBridge Remote".to_string(),
            target_fps: 15,
            jpeg_quality: 55,
            capture_cursor: true,
            allow_input: true,
        }
    }
}

pub struct MacRemoteControlServer {
    config: MacRemoteControlServerConfig,
}

impl MacRemoteControlServer {
    pub fn new(config: MacRemoteControlServerConfig) -> Self {
        Self { config }
    }

    pub async fn serve(&self) -> Result<(), MacRemoteControlServerError> {
        let listener = TcpListener::bind(self.config.bind_addr).await?;
        loop {
            let (stream, peer_addr) = listener.accept().await?;
            let cfg = self.config.clone();
            tokio::spawn(async move {
                if let Err(err) = handle_client(stream, cfg).await {
                    tracing::warn!("mac remote session ended ({peer_addr}): {err}");
                }
            });
        }
    }
}

async fn handle_client(
    stream: tokio::net::TcpStream,
    config: MacRemoteControlServerConfig,
) -> Result<(), MacRemoteControlServerError> {
    stream.set_nodelay(true)?;

    let mut capturer = ScreenCapturer::new()?;
    capturer.initialize().await?;
    let capture_config = CaptureConfig {
        target_fps: config.target_fps.max(1),
        capture_cursor: config.capture_cursor,
        ..Default::default()
    };
    let mut frame_rx = capturer.start(&capture_config).await?;

    let mut input = if config.allow_input {
        let mut h = UnifiedInputHandler::new()?;
        h.initialize().await?;
        Some(h)
    } else {
        None
    };

    let (mut rd, mut wr) = stream.into_split();

    loop {
        tokio::select! {
            frame = frame_rx.recv() => {
                let Some(frame) = frame else { break; };
                let jpeg = encode_frame_to_jpeg(&frame.data, frame.width as u16, frame.height as u16, frame.format, config.jpeg_quality)?;

                let sd = ScreenData {
                    width: frame.width as i32,
                    height: frame.height as i32,
                    image_data: jpeg,
                    timestamp: (frame.timestamp as f64) / 1_000_000_000.0,
                    format: Some("jpeg".to_string()),
                };
                let inner = serde_json::to_vec(&sd)?;
                let msg = RemoteMessage {
                    message_type: RemoteMessageType::ScreenData,
                    payload: inner,
                };
                let outer = serde_json::to_vec(&msg)?;
                send_framed(&mut wr, &outer).await?;
            }
            msg = read_next_message(&mut rd) => {
                let Some(msg) = msg? else { break; };
                if let Some(h) = input.as_mut() {
                    handle_inbound_control_message(h, msg).await;
                }
            }
        }
    }

    let _ = capturer.stop().await;
    Ok(())
}

async fn handle_inbound_control_message(handler: &mut UnifiedInputHandler, msg: RemoteMessage) {
    match msg.message_type {
        RemoteMessageType::MouseEvent => {
            if let Ok(evt) = serde_json::from_slice::<RemoteMouseEvent>(&msg.payload) {
                let x = evt.x as i32;
                let y = evt.y as i32;
                match evt.r#type.as_str() {
                    "mouseMoved" => {
                        let _ = handler.send_mouse(&MouseEvent::move_to(x, y)).await;
                    }
                    "leftMouseDown" => {
                        let _ = handler
                            .send_mouse(&MouseEvent::button_down(MouseButton::Left, x, y))
                            .await;
                    }
                    "leftMouseUp" => {
                        let _ = handler
                            .send_mouse(&MouseEvent::button_up(MouseButton::Left, x, y))
                            .await;
                    }
                    "rightMouseDown" => {
                        let _ = handler
                            .send_mouse(&MouseEvent::button_down(MouseButton::Right, x, y))
                            .await;
                    }
                    "rightMouseUp" => {
                        let _ = handler
                            .send_mouse(&MouseEvent::button_up(MouseButton::Right, x, y))
                            .await;
                    }
                    "scrollUp" => {
                        let _ = handler.send_mouse(&MouseEvent::scroll(0, -1, x, y)).await;
                    }
                    "scrollDown" => {
                        let _ = handler.send_mouse(&MouseEvent::scroll(0, 1, x, y)).await;
                    }
                    _ => {}
                }
            }
        }
        RemoteMessageType::KeyboardEvent => {
            if let Ok(evt) = serde_json::from_slice::<RemoteKeyboardEvent>(&msg.payload) {
                let keysym = evt.key_code.max(0) as u32;
                let ev = match evt.r#type.as_str() {
                    "keyDown" => KeyEvent::key_down(keysym, Default::default()),
                    "keyUp" => KeyEvent::key_up(keysym, Default::default()),
                    _ => return,
                };
                let _ = handler.send_key(&ev).await;
            }
        }
        RemoteMessageType::ScreenData => {}
    }
}

fn encode_frame_to_jpeg(
    data: &[u8],
    width: u16,
    height: u16,
    format: crate::remote::capture::PixelFormat,
    quality: u8,
) -> Result<Vec<u8>, MacRemoteControlServerError> {
    use jpeg_encoder::{ColorType, Encoder};

    let rgb = match format {
        crate::remote::capture::PixelFormat::Rgb888 => data.to_vec(),
        crate::remote::capture::PixelFormat::Bgr888 => {
            let mut out = Vec::with_capacity(data.len());
            for chunk in data.chunks_exact(3) {
                out.push(chunk[2]);
                out.push(chunk[1]);
                out.push(chunk[0]);
            }
            out
        }
        crate::remote::capture::PixelFormat::Rgba8888 => {
            let mut out = Vec::with_capacity((data.len() / 4) * 3);
            for chunk in data.chunks_exact(4) {
                out.push(chunk[0]);
                out.push(chunk[1]);
                out.push(chunk[2]);
            }
            out
        }
        crate::remote::capture::PixelFormat::Bgra8888 => {
            let mut out = Vec::with_capacity((data.len() / 4) * 3);
            for chunk in data.chunks_exact(4) {
                out.push(chunk[2]);
                out.push(chunk[1]);
                out.push(chunk[0]);
            }
            out
        }
    };

    let mut out = Vec::new();
    let enc = Encoder::new(&mut out, quality.clamp(1, 100));
    enc.encode(&rgb, width, height, ColorType::Rgb)
        .map_err(|e| MacRemoteControlServerError::Jpeg(format!("{e}")))?;
    Ok(out)
}

async fn send_framed(
    wr: &mut tokio::net::tcp::OwnedWriteHalf,
    payload: &[u8],
) -> Result<(), MacRemoteControlServerError> {
    if payload.is_empty() {
        return Err(MacRemoteControlServerError::Protocol(
            "empty frame payload".to_string(),
        ));
    }
    if payload.len() > MAX_FRAME_BYTES {
        return Err(MacRemoteControlServerError::Protocol(format!(
            "frame too large: {}",
            payload.len()
        )));
    }
    let len = (payload.len() as u32).to_be_bytes();
    wr.write_all(&len).await?;
    wr.write_all(payload).await?;
    wr.flush().await?;
    Ok(())
}

async fn read_next_message(
    rd: &mut tokio::net::tcp::OwnedReadHalf,
) -> Result<Option<RemoteMessage>, MacRemoteControlServerError> {
    let mut len_buf = [0u8; 4];
    match rd.read_exact(&mut len_buf).await {
        Ok(_) => {}
        Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(err.into()),
    }
    let len = u32::from_be_bytes(len_buf) as usize;
    if len == 0 || len > MAX_FRAME_BYTES {
        return Err(MacRemoteControlServerError::Protocol(format!(
            "invalid frame length: {len}"
        )));
    }
    let mut payload = vec![0u8; len];
    match rd.read_exact(&mut payload).await {
        Ok(_) => {}
        Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(err.into()),
    }
    Ok(Some(serde_json::from_slice(&payload)?))
}
