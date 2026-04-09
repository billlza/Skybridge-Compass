use serde::{Deserialize, Serialize};

/// Remote desktop/control message wrapper (JSON).
///
/// Mirrors the macOS/iOS "RemoteMessageWire" shape:
/// - `type` string enum
/// - `payload` is `Data` (base64 in JSON)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteMessageWire {
    #[serde(rename = "type")]
    pub msg_type: RemoteMessageTypeWire,
    #[serde(with = "super::serde_bytes_flex::bytes")]
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RemoteMessageTypeWire {
    ScreenData,
    MouseEvent,
    KeyboardEvent,
    Clipboard,
    StreamConfiguration,
    DamageReport,
    CursorUpdate,
    OverlayUpdate,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenDataWire {
    pub width: i32,
    pub height: i32,
    #[serde(with = "super::serde_bytes_flex::bytes")]
    pub image_data: Vec<u8>,
    pub timestamp: f64,
    pub format: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MouseEventTypeWire {
    LeftMouseDown,
    LeftMouseUp,
    RightMouseDown,
    RightMouseUp,
    MouseMoved,
    ScrollUp,
    ScrollDown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MouseEventWire {
    #[serde(rename = "type")]
    pub event_type: MouseEventTypeWire,
    pub x: f64,
    pub y: f64,
    pub timestamp: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeyboardEventTypeWire {
    KeyDown,
    KeyUp,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyboardEventWire {
    #[serde(rename = "type")]
    pub event_type: KeyboardEventTypeWire,
    pub key_code: i32,
    pub timestamp: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_payload_serializes_as_base64_string() {
        let msg = RemoteMessageWire {
            msg_type: RemoteMessageTypeWire::MouseEvent,
            payload: vec![0x01, 0x02, 0x03],
        };
        let json = serde_json::to_string(&msg).expect("json");
        assert!(json.contains("\"payload\":\"AQID\""));
        assert!(json.contains("\"type\":\"mouseEvent\""));
    }

    #[test]
    fn remote_payload_deserializes_from_array_or_base64() {
        let array_json = r#"{"type":"mouseEvent","payload":[1,2,3]}"#;
        let msg: RemoteMessageWire = serde_json::from_str(array_json).expect("array decode");
        assert_eq!(msg.payload, vec![1, 2, 3]);

        let b64_json = r#"{"type":"mouseEvent","payload":"AQID"}"#;
        let msg: RemoteMessageWire = serde_json::from_str(b64_json).expect("b64 decode");
        assert_eq!(msg.payload, vec![1, 2, 3]);
    }

    #[test]
    fn remote_payload_accepts_extended_apple_message_types() {
        for raw in [
            r#"{"type":"clipboard","payload":"AQID"}"#,
            r#"{"type":"streamConfiguration","payload":"AQID"}"#,
            r#"{"type":"damageReport","payload":"AQID"}"#,
            r#"{"type":"cursorUpdate","payload":"AQID"}"#,
            r#"{"type":"overlayUpdate","payload":"AQID"}"#,
        ] {
            let msg: RemoteMessageWire = serde_json::from_str(raw).expect("decode");
            assert_eq!(msg.payload, vec![1, 2, 3]);
        }
    }

    #[test]
    fn screen_data_image_data_is_base64() {
        let sd = ScreenDataWire {
            width: 10,
            height: 20,
            image_data: vec![0xFF, 0xD8, 0xFF],
            timestamp: 1.0,
            format: Some("jpeg".to_string()),
        };
        let json = serde_json::to_string(&sd).expect("json");
        assert!(json.contains("\"imageData\":\"/9j/\""));
    }
}
