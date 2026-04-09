//! Post-handshake business payloads (macOS/iOS compatible).
//!
//! This module provides:
//! - `AppMessage`: JSON (externally-tagged enum) encrypted with `SessionKeys` control key.
//! - `BusinessEnvelope`: binary envelope ("SBE1") for high-rate binary payloads.

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use serde::{Deserialize, Serialize};

/// Swift `Date` default JSONEncoder representation (`.deferredToDate`):
/// seconds since 2001-01-01 00:00:00 UTC.
///
/// We use this for cross-platform compatibility with the macOS/iOS Pro release
/// which encodes `Date` fields in `AppMessage` with the default strategy.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd)]
pub struct SwiftDateSeconds(pub f64);

impl SwiftDateSeconds {
    /// Unix epoch seconds for 2001-01-01 00:00:00 UTC.
    const SWIFT_REF_UNIX_SECONDS: f64 = 978_307_200.0;

    pub fn now() -> Self {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let unix = now.as_secs() as f64 + (now.subsec_nanos() as f64 / 1_000_000_000.0);
        SwiftDateSeconds(unix - Self::SWIFT_REF_UNIX_SECONDS)
    }

    #[allow(dead_code)]
    pub fn to_unix_seconds(self) -> f64 {
        self.0 + Self::SWIFT_REF_UNIX_SECONDS
    }
}

impl Serialize for SwiftDateSeconds {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_f64(self.0)
    }
}

impl<'de> Deserialize<'de> for SwiftDateSeconds {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct Visitor;
        impl serde::de::Visitor<'_> for Visitor {
            type Value = SwiftDateSeconds;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("Swift Date seconds since 2001-01-01 (number)")
            }

            fn visit_f64<E>(self, v: f64) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(SwiftDateSeconds(v))
            }

            fn visit_i64<E>(self, v: i64) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(SwiftDateSeconds(v as f64))
            }

            fn visit_u64<E>(self, v: u64) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(SwiftDateSeconds(v as f64))
            }
        }
        deserializer.deserialize_any(Visitor)
    }
}

mod serde_base64 {
    use super::*;

    pub fn serialize<S>(bytes: &Vec<u8>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let encoded = BASE64_STANDARD.encode(bytes);
        serializer.serialize_str(&encoded)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        BASE64_STANDARD
            .decode(s.as_bytes())
            .map_err(serde::de::Error::custom)
    }
}

/// App-level encrypted message sent over an established P2P session (after handshake).
///
/// Current Apple `AppMessage` encoding is a plain externally-tagged payload:
/// `{"pairingIdentityExchange":{...}}`, `{"ping":{"id":1}}`, etc.
///
/// Some intermediate compatibility builds emitted a `_0` wrapper for single
/// associated values. We continue to accept both on decode, but we serialize to
/// the current Apple release shape to keep macOS/iOS mainline parsing on the
/// fast path.
#[derive(Debug, Clone, PartialEq)]
pub enum AppMessage {
    Clipboard(ClipboardPayload),
    PairingIdentityExchange(PairingIdentityExchangePayload),
    Heartbeat(HeartbeatPayload),
    Ping(PingPayload),
    Pong(PongPayload),
}

#[derive(Deserialize)]
struct SwiftAssociatedValueOwned<T> {
    #[serde(rename = "_0")]
    value: T,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SwiftAppEnvelope {
    clipboard: Option<SwiftAssociatedValueOwned<ClipboardPayload>>,
    pairing_identity_exchange: Option<SwiftAssociatedValueOwned<PairingIdentityExchangePayload>>,
    heartbeat: Option<SwiftAssociatedValueOwned<HeartbeatPayload>>,
    ping: Option<SwiftAssociatedValueOwned<PingPayload>>,
    pong: Option<SwiftAssociatedValueOwned<PongPayload>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyAppEnvelope {
    clipboard: Option<ClipboardPayload>,
    pairing_identity_exchange: Option<PairingIdentityExchangePayload>,
    heartbeat: Option<HeartbeatPayload>,
    ping: Option<PingPayload>,
    pong: Option<PongPayload>,
}

impl AppMessage {
    fn from_swift_envelope(envelope: SwiftAppEnvelope) -> Option<Self> {
        if let Some(payload) = envelope.clipboard {
            return Some(Self::Clipboard(payload.value));
        }
        if let Some(payload) = envelope.pairing_identity_exchange {
            return Some(Self::PairingIdentityExchange(payload.value));
        }
        if let Some(payload) = envelope.heartbeat {
            return Some(Self::Heartbeat(payload.value));
        }
        if let Some(payload) = envelope.ping {
            return Some(Self::Ping(payload.value));
        }
        if let Some(payload) = envelope.pong {
            return Some(Self::Pong(payload.value));
        }
        None
    }

    fn from_legacy_envelope(envelope: LegacyAppEnvelope) -> Option<Self> {
        if let Some(payload) = envelope.clipboard {
            return Some(Self::Clipboard(payload));
        }
        if let Some(payload) = envelope.pairing_identity_exchange {
            return Some(Self::PairingIdentityExchange(payload));
        }
        if let Some(payload) = envelope.heartbeat {
            return Some(Self::Heartbeat(payload));
        }
        if let Some(payload) = envelope.ping {
            return Some(Self::Ping(payload));
        }
        if let Some(payload) = envelope.pong {
            return Some(Self::Pong(payload));
        }
        None
    }
}

impl Serialize for AppMessage {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        use serde::ser::SerializeMap;

        let mut map = serializer.serialize_map(Some(1))?;
        match self {
            Self::Clipboard(payload) => {
                map.serialize_entry("clipboard", payload)?;
            }
            Self::PairingIdentityExchange(payload) => {
                map.serialize_entry("pairingIdentityExchange", payload)?;
            }
            Self::Heartbeat(payload) => {
                map.serialize_entry("heartbeat", payload)?;
            }
            Self::Ping(payload) => {
                map.serialize_entry("ping", payload)?;
            }
            Self::Pong(payload) => {
                map.serialize_entry("pong", payload)?;
            }
        }
        map.end()
    }
}

impl<'de> Deserialize<'de> for AppMessage {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = serde_json::Value::deserialize(deserializer)?;

        if let Ok(envelope) = serde_json::from_value::<SwiftAppEnvelope>(value.clone())
            && let Some(message) = Self::from_swift_envelope(envelope)
        {
            return Ok(message);
        }

        if let Ok(envelope) = serde_json::from_value::<LegacyAppEnvelope>(value)
            && let Some(message) = Self::from_legacy_envelope(envelope)
        {
            return Ok(message);
        }

        Err(serde::de::Error::custom("invalid AppMessage envelope"))
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardPayload {
    pub mime_type: String,
    pub data_base64: String,
    pub sent_at: SwiftDateSeconds,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KemPublicKeyInfo {
    pub suite_wire_id: u16,
    #[serde(with = "serde_base64")]
    pub public_key: Vec<u8>,
}

/// Minimal identity bundle used to bootstrap PQC handshake:
/// - provides peer KEM identity public keys (suiteWireId -> publicKey)
/// - provides stable deviceId for trust store indexing
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingIdentityExchangePayload {
    pub device_id: String,
    pub kem_public_keys: Vec<KemPublicKeyInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_video_formats: Option<Vec<String>>,
    pub sent_at: SwiftDateSeconds,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeartbeatPayload {
    pub sent_at: SwiftDateSeconds,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_video_formats: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PingPayload {
    pub id: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PongPayload {
    pub id: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum BusinessEnvelopeKind {
    RemoteDesktopFrame = 1,
}

impl BusinessEnvelopeKind {
    fn from_raw(raw: u8) -> Option<Self> {
        match raw {
            1 => Some(Self::RemoteDesktopFrame),
            _ => None,
        }
    }
}

/// Encrypted business payload envelope (v1).
///
/// Wire format (matches Swift):
/// - magic: "SBE1" (4)
/// - kind: u8 (1)
/// - timestampNs: u64 big-endian (8)
/// - payload: remaining bytes
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BusinessEnvelope {
    pub kind: BusinessEnvelopeKind,
    pub timestamp_ns: u64,
    pub payload: Vec<u8>,
}

impl BusinessEnvelope {
    const MAGIC: [u8; 4] = [0x53, 0x42, 0x45, 0x31]; // "SBE1"
    const HEADER_LEN: usize = 4 + 1 + 8;

    pub fn remote_desktop_frame(timestamp_ns: u64, payload: Vec<u8>) -> Self {
        Self {
            kind: BusinessEnvelopeKind::RemoteDesktopFrame,
            timestamp_ns,
            payload,
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(Self::HEADER_LEN + self.payload.len());
        out.extend_from_slice(&Self::MAGIC);
        out.push(self.kind as u8);
        out.extend_from_slice(&self.timestamp_ns.to_be_bytes());
        out.extend_from_slice(&self.payload);
        out
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.len() < Self::HEADER_LEN {
            return None;
        }
        if data[0..4] != Self::MAGIC {
            return None;
        }
        let kind = BusinessEnvelopeKind::from_raw(data[4])?;
        let mut ts: u64 = 0;
        for b in &data[5..13] {
            ts = (ts << 8) | (*b as u64);
        }
        let payload = data[13..].to_vec();
        Some(Self {
            kind,
            timestamp_ns: ts,
            payload,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn app_message_json_shape_matches_swift_external_tag() {
        let msg = AppMessage::Ping(PingPayload { id: 42 });
        let value = serde_json::to_value(&msg).unwrap();
        assert_eq!(value, json!({"ping": {"id": 42}}));
    }

    #[test]
    fn pairing_identity_exchange_omits_optional_nil_fields() {
        let msg = AppMessage::PairingIdentityExchange(PairingIdentityExchangePayload {
            device_id: "dev1".to_string(),
            kem_public_keys: vec![KemPublicKeyInfo {
                suite_wire_id: 1,
                public_key: vec![1, 2, 3],
            }],
            device_name: None,
            model_name: None,
            platform: None,
            os_version: None,
            chip: None,
            remote_video_formats: None,
            sent_at: SwiftDateSeconds(0.0),
        });
        let value = serde_json::to_value(&msg).unwrap();
        assert_eq!(
            value,
            json!({
                "pairingIdentityExchange": {
                    "deviceId": "dev1",
                    "kemPublicKeys": [{
                        "suiteWireId": 1,
                        "publicKey": "AQID"
                    }],
                    "sentAt": 0.0
                }
            })
        );
    }

    #[test]
    fn pairing_identity_exchange_serializes_remote_video_formats_when_present() {
        let msg = AppMessage::PairingIdentityExchange(PairingIdentityExchangePayload {
            device_id: "dev1".to_string(),
            kem_public_keys: Vec::new(),
            device_name: None,
            model_name: None,
            platform: None,
            os_version: None,
            chip: None,
            remote_video_formats: Some(vec!["jpeg".to_string(), "h264".to_string()]),
            sent_at: SwiftDateSeconds(0.0),
        });

        let value = serde_json::to_value(&msg).unwrap();
        assert_eq!(
            value,
            json!({
                "pairingIdentityExchange": {
                    "deviceId": "dev1",
                    "kemPublicKeys": [],
                    "remoteVideoFormats": ["jpeg", "h264"],
                    "sentAt": 0.0
                }
            })
        );
    }

    #[test]
    fn app_message_deserializes_swift_associated_value_shape() {
        let value = json!({
            "heartbeat": {
                "_0": {
                    "sentAt": 0.0,
                    "remoteVideoFormats": ["jpeg"]
                }
            }
        });

        let decoded: AppMessage = serde_json::from_value(value).unwrap();
        assert_eq!(
            decoded,
            AppMessage::Heartbeat(HeartbeatPayload {
                sent_at: SwiftDateSeconds(0.0),
                device_id: None,
                device_name: None,
                model_name: None,
                platform: None,
                os_version: None,
                chip: None,
                remote_video_formats: Some(vec!["jpeg".to_string()]),
            })
        );
    }

    #[test]
    fn app_message_deserializes_legacy_plain_shape() {
        let value = json!({
            "pairingIdentityExchange": {
                "deviceId": "dev1",
                "kemPublicKeys": [],
                "sentAt": 0.0
            }
        });

        let decoded: AppMessage = serde_json::from_value(value).unwrap();
        assert_eq!(
            decoded,
            AppMessage::PairingIdentityExchange(PairingIdentityExchangePayload {
                device_id: "dev1".to_string(),
                kem_public_keys: Vec::new(),
                device_name: None,
                model_name: None,
                platform: None,
                os_version: None,
                chip: None,
                remote_video_formats: None,
                sent_at: SwiftDateSeconds(0.0),
            })
        );
    }

    #[test]
    fn business_envelope_roundtrip() {
        let env = BusinessEnvelope::remote_desktop_frame(123, b"hello".to_vec());
        let encoded = env.encode();
        let decoded = BusinessEnvelope::decode(&encoded).unwrap();
        assert_eq!(decoded, env);
    }
}
