//! macOS Pro-release compatible remote-control client.
//!
//! Wire format (matches SkyBridge Compass Pro `RemoteControlServer`):
//! - TCP: 5901 (by default)
//! - Frame: u32 length (big-endian) + JSON(RemoteMessage)
//! - RemoteMessage.payload is base64 of inner JSON bytes (Swift `Data` JSON encoding)

use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use thiserror::Error;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

const MAX_FRAME_BYTES: usize = 32_000_000;

mod serde_base64 {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    use serde::Deserialize;

    pub fn serialize<S>(bytes: &Vec<u8>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let encoded = STANDARD.encode(bytes);
        serializer.serialize_str(&encoded)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        STANDARD
            .decode(s.as_bytes())
            .map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Error)]
pub enum MacRemoteControlError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("connection closed")]
    ConnectionClosed,
    #[error("invalid frame length: {0}")]
    InvalidFrameLength(usize),
    #[error("unexpected remote message type: {0}")]
    UnexpectedMessageType(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteMessageType {
    ScreenData,
    MouseEvent,
    KeyboardEvent,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteMessage {
    #[serde(rename = "type")]
    pub message_type: RemoteMessageType,
    #[serde(with = "serde_base64")]
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenData {
    pub width: i32,
    pub height: i32,
    #[serde(with = "serde_base64")]
    pub image_data: Vec<u8>,
    pub timestamp: f64,
    pub format: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteMouseEvent {
    pub r#type: String,
    pub x: f64,
    pub y: f64,
    pub timestamp: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteKeyboardEvent {
    pub r#type: String,
    pub key_code: i32,
    pub timestamp: f64,
}

pub struct MacRemoteControlClient {
    stream: TcpStream,
}

impl MacRemoteControlClient {
    pub async fn connect(addr: SocketAddr) -> Result<Self, MacRemoteControlError> {
        let stream = TcpStream::connect(addr).await?;
        stream.set_nodelay(true)?;
        Ok(Self { stream })
    }

    pub fn into_inner(self) -> TcpStream {
        self.stream
    }

    pub async fn read_message(&mut self) -> Result<RemoteMessage, MacRemoteControlError> {
        let mut len_buf = [0u8; 4];
        self.stream.read_exact(&mut len_buf).await?;
        let len = u32::from_be_bytes(len_buf) as usize;
        if len == 0 {
            return Err(MacRemoteControlError::InvalidFrameLength(len));
        }
        if len > MAX_FRAME_BYTES {
            return Err(MacRemoteControlError::InvalidFrameLength(len));
        }

        let mut payload = vec![0u8; len];
        match self.stream.read_exact(&mut payload).await {
            Ok(_) => {}
            Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => {
                return Err(MacRemoteControlError::ConnectionClosed);
            }
            Err(err) => return Err(err.into()),
        }

        Ok(serde_json::from_slice(&payload)?)
    }

    pub async fn read_next_screen_data(&mut self) -> Result<ScreenData, MacRemoteControlError> {
        let msg = self.read_message().await?;
        match msg.message_type {
            RemoteMessageType::ScreenData => {
                let screen: ScreenData = serde_json::from_slice(&msg.payload)?;
                Ok(screen)
            }
            other => Err(MacRemoteControlError::UnexpectedMessageType(format!(
                "{other:?}"
            ))),
        }
    }

    pub async fn send_mouse_event(
        &mut self,
        event: &RemoteMouseEvent,
    ) -> Result<(), MacRemoteControlError> {
        let event_bytes = serde_json::to_vec(event)?;
        let msg = RemoteMessage {
            message_type: RemoteMessageType::MouseEvent,
            payload: event_bytes,
        };
        self.send_message(&msg).await
    }

    pub async fn send_keyboard_event(
        &mut self,
        event: &RemoteKeyboardEvent,
    ) -> Result<(), MacRemoteControlError> {
        let event_bytes = serde_json::to_vec(event)?;
        let msg = RemoteMessage {
            message_type: RemoteMessageType::KeyboardEvent,
            payload: event_bytes,
        };
        self.send_message(&msg).await
    }

    pub async fn send_message(&mut self, msg: &RemoteMessage) -> Result<(), MacRemoteControlError> {
        let json = serde_json::to_vec(msg)?;
        self.send_raw_frame(&json).await
    }

    pub async fn send_raw_frame(&mut self, payload: &[u8]) -> Result<(), MacRemoteControlError> {
        if payload.is_empty() {
            return Err(MacRemoteControlError::InvalidFrameLength(0));
        }
        let len = payload.len();
        if len > MAX_FRAME_BYTES {
            return Err(MacRemoteControlError::InvalidFrameLength(len));
        }

        let mut header = (len as u32).to_be_bytes().to_vec();
        header.extend_from_slice(payload);
        self.stream.write_all(&header).await?;
        self.stream.flush().await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_message_payload_is_base64_in_json() {
        let msg = RemoteMessage {
            message_type: RemoteMessageType::MouseEvent,
            payload: vec![0x01, 0x02, 0x03],
        };
        let json = serde_json::to_string(&msg).expect("json");
        assert!(json.contains("\"payload\":\"AQID\""));
        assert!(json.contains("\"type\":\"mouseEvent\""));
    }

    #[test]
    fn screen_data_payload_roundtrip() {
        let screen = ScreenData {
            width: 10,
            height: 20,
            image_data: vec![0xFF, 0xD8, 0xFF],
            timestamp: 1.0,
            format: Some("jpeg".to_string()),
        };
        let inner = serde_json::to_vec(&screen).expect("inner json");
        let msg = RemoteMessage {
            message_type: RemoteMessageType::ScreenData,
            payload: inner,
        };

        let outer = serde_json::to_vec(&msg).expect("outer json");
        let decoded: RemoteMessage = serde_json::from_slice(&outer).expect("decode outer");
        assert_eq!(decoded.message_type, RemoteMessageType::ScreenData);

        let decoded_screen: ScreenData =
            serde_json::from_slice(&decoded.payload).expect("decode inner");
        assert_eq!(decoded_screen.width, 10);
        assert_eq!(decoded_screen.height, 20);
        assert_eq!(decoded_screen.format.as_deref(), Some("jpeg"));
        assert_eq!(decoded_screen.image_data, vec![0xFF, 0xD8, 0xFF]);
    }
}
