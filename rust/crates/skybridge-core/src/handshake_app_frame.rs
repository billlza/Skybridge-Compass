use anyhow::{Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;

pub(crate) const HEARTBEAT_PLATFORM: &str = std::env::consts::OS;
const REFERENCE_UNIX_SECONDS: i64 = 978_307_200;
const MAX_APP_CONTROL_PLAINTEXT_BYTES: usize = 64 * 1024;
const MAX_HEARTBEAT_STRING_BYTES: usize = 4 * 1024;
const MAX_HEARTBEAT_LIST_ITEMS: usize = 64;
const MAX_HEARTBEAT_LIST_ITEM_BYTES: usize = 256;

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HeartbeatPayload {
    #[serde(rename = "sentAt")]
    pub sent_at: f64,
    #[serde(rename = "deviceId", skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(rename = "deviceName", skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    #[serde(rename = "modelName", skip_serializing_if = "Option::is_none")]
    pub model_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    #[serde(rename = "osVersion", skip_serializing_if = "Option::is_none")]
    pub os_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chip: Option<String>,
    #[serde(rename = "accountDisplayName", skip_serializing_if = "Option::is_none")]
    pub account_display_name: Option<String>,
    #[serde(rename = "nebulaId", skip_serializing_if = "Option::is_none")]
    pub nebula_id: Option<String>,
    #[serde(rename = "remoteVideoFormats", skip_serializing_if = "Option::is_none")]
    pub remote_video_formats: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<String>>,
    #[serde(rename = "fileTransferPort", skip_serializing_if = "Option::is_none")]
    pub file_transfer_port: Option<u16>,
    #[serde(rename = "remoteControlPort", skip_serializing_if = "Option::is_none")]
    pub remote_control_port: Option<u16>,
    #[serde(rename = "webrtcMedia", skip_serializing_if = "Option::is_none")]
    pub webrtc_media: Option<WebRtcMediaHeartbeatDiagnostics>,
}

impl std::fmt::Debug for HeartbeatPayload {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("HeartbeatPayload")
            .field("sent_at", &self.sent_at)
            .field("device_id", &"<redacted>")
            .field("device_name_present", &self.device_name.is_some())
            .field("model_name_present", &self.model_name.is_some())
            .field("platform", &self.platform)
            .field("os_version_present", &self.os_version.is_some())
            .field(
                "account_display_name_present",
                &self.account_display_name.is_some(),
            )
            .field("nebula_id_present", &self.nebula_id.is_some())
            .field("remote_video_formats", &self.remote_video_formats)
            .field("capabilities_present", &self.capabilities.is_some())
            .field("file_transfer_port", &self.file_transfer_port)
            .field("remote_control_port", &self.remote_control_port)
            .field("webrtc_media_present", &self.webrtc_media.is_some())
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WebRtcMediaHeartbeatDiagnostics {
    #[serde(rename = "nativeVideoRendered")]
    pub native_video_rendered: bool,
    #[serde(rename = "nativeVideoWidth")]
    pub native_video_width: Option<i64>,
    #[serde(rename = "nativeVideoHeight")]
    pub native_video_height: Option<i64>,
    #[serde(rename = "audioRxDatagrams")]
    pub audio_rx_datagrams: Option<u64>,
    #[serde(rename = "audioRxRecv")]
    pub audio_rx_recv: Option<u64>,
    #[serde(rename = "audioRxDecoded")]
    pub audio_rx_decoded: Option<u64>,
    #[serde(rename = "audioRxPlayed")]
    pub audio_rx_played: Option<u64>,
    #[serde(rename = "audioRxRejected")]
    pub audio_rx_rejected: Option<u64>,
    #[serde(rename = "audioRxAuthRejected")]
    pub audio_rx_auth_rejected: Option<u64>,
    #[serde(rename = "audioRxSessionHashRejected")]
    pub audio_rx_session_hash_rejected: Option<u64>,
    #[serde(rename = "audioRxReplayRejected")]
    pub audio_rx_replay_rejected: Option<u64>,
    #[serde(rename = "audioRxJitterEvicted")]
    pub audio_rx_jitter_evicted: Option<u64>,
    #[serde(rename = "audioRxPlaybackDropped")]
    pub audio_rx_playback_dropped: Option<u64>,
    #[serde(rename = "audioRenderedFrames")]
    pub audio_rendered_frames: Option<u64>,
    #[serde(rename = "audioUnderflow")]
    pub audio_underflow: Option<u64>,
    #[serde(rename = "audioRebuffer")]
    pub audio_rebuffer: Option<u64>,
    #[serde(rename = "audioStartupSilenceFrames")]
    pub audio_startup_silence_frames: Option<u64>,
    #[serde(rename = "audioEngineRunning")]
    pub audio_engine_running: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum AppControlMessage {
    Heartbeat(Box<HeartbeatPayload>),
    Ping(LivenessPayload),
    Pong(LivenessPayload),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct LivenessPayload {
    pub(crate) id: u64,
}

#[cfg(test)]
pub(crate) fn build_heartbeat_plaintext(
    device_id: &str,
    device_name: Option<&str>,
) -> Result<Vec<u8>> {
    build_heartbeat_plaintext_with_advertisement(device_id, device_name, None, None, None)
}

pub(crate) fn build_heartbeat_plaintext_with_advertisement(
    device_id: &str,
    device_name: Option<&str>,
    capabilities: Option<&[String]>,
    file_transfer_port: Option<u16>,
    remote_control_port: Option<u16>,
) -> Result<Vec<u8>> {
    encode_app_control_message(&AppControlMessage::Heartbeat(Box::new(HeartbeatPayload {
        sent_at: apple_reference_seconds_now(),
        device_id: Some(device_id.to_owned()),
        device_name: device_name.map(str::to_owned),
        model_name: None,
        platform: Some(HEARTBEAT_PLATFORM.to_owned()),
        os_version: None,
        chip: None,
        account_display_name: None,
        nebula_id: None,
        remote_video_formats: None,
        capabilities: capabilities.map(<[String]>::to_vec),
        file_transfer_port,
        remote_control_port,
        webrtc_media: None,
    })))
}

pub(crate) fn build_ping_plaintext(id: u64) -> Result<Vec<u8>> {
    encode_app_control_message(&AppControlMessage::Ping(LivenessPayload { id }))
}

pub(crate) fn build_pong_plaintext(id: u64) -> Result<Vec<u8>> {
    encode_app_control_message(&AppControlMessage::Pong(LivenessPayload { id }))
}

pub(crate) fn decode_app_control_message(plaintext: &[u8]) -> Result<AppControlMessage> {
    if plaintext.len() > MAX_APP_CONTROL_PLAINTEXT_BYTES {
        bail!(
            "authenticated appControl plaintext exceeds byte limit: {} > {MAX_APP_CONTROL_PLAINTEXT_BYTES}",
            plaintext.len()
        );
    }
    let message: AppControlMessage = serde_json::from_slice(plaintext)
        .map_err(|_| anyhow!("invalid authenticated appControl message"))?;
    if let AppControlMessage::Heartbeat(heartbeat) = &message {
        validate_heartbeat(heartbeat)?;
    }
    Ok(message)
}

fn encode_app_control_message(message: &AppControlMessage) -> Result<Vec<u8>> {
    if let AppControlMessage::Heartbeat(heartbeat) = message {
        validate_heartbeat(heartbeat)?;
    }
    let plaintext = serde_json::to_vec(message)?;
    if plaintext.len() > MAX_APP_CONTROL_PLAINTEXT_BYTES {
        bail!(
            "appControl plaintext exceeds byte limit: {} > {MAX_APP_CONTROL_PLAINTEXT_BYTES}",
            plaintext.len()
        );
    }
    Ok(plaintext)
}

fn validate_heartbeat(heartbeat: &HeartbeatPayload) -> Result<()> {
    if !heartbeat.sent_at.is_finite() {
        bail!("heartbeat sentAt must be finite");
    }
    for (name, value) in [
        ("deviceId", heartbeat.device_id.as_deref()),
        ("deviceName", heartbeat.device_name.as_deref()),
        ("modelName", heartbeat.model_name.as_deref()),
        ("platform", heartbeat.platform.as_deref()),
        ("osVersion", heartbeat.os_version.as_deref()),
        ("chip", heartbeat.chip.as_deref()),
        (
            "accountDisplayName",
            heartbeat.account_display_name.as_deref(),
        ),
        ("nebulaId", heartbeat.nebula_id.as_deref()),
    ] {
        if let Some(value) = value {
            if value.is_empty() {
                bail!("heartbeat {name} must not be empty");
            }
            if value.len() > MAX_HEARTBEAT_STRING_BYTES {
                bail!("heartbeat {name} exceeds byte limit");
            }
            if value.chars().any(char::is_control) {
                bail!("heartbeat {name} contains control characters");
            }
        }
    }
    for (name, values) in [
        (
            "remoteVideoFormats",
            heartbeat.remote_video_formats.as_deref(),
        ),
        ("capabilities", heartbeat.capabilities.as_deref()),
    ] {
        if let Some(values) = values {
            if values.len() > MAX_HEARTBEAT_LIST_ITEMS {
                bail!("heartbeat {name} exceeds item limit");
            }
            for value in values {
                if value.is_empty() {
                    bail!("heartbeat {name} item must not be empty");
                }
                if value.len() > MAX_HEARTBEAT_LIST_ITEM_BYTES {
                    bail!("heartbeat {name} item exceeds byte limit");
                }
                if value.chars().any(char::is_control) {
                    bail!("heartbeat {name} item contains control characters");
                }
            }
        }
    }
    if let Some(capabilities) = heartbeat.capabilities.as_deref() {
        let mut observed = std::collections::BTreeSet::new();
        for capability in capabilities {
            let valid_format = capability.len() <= 64
                && capability
                    .bytes()
                    .enumerate()
                    .all(|(index, byte)| match byte {
                        b'a'..=b'z' | b'0'..=b'9' => true,
                        b'_' | b'-' | b'.' => index > 0,
                        _ => false,
                    });
            if !valid_format {
                bail!("heartbeat capability token has invalid format");
            }
            if !observed.insert(capability.as_str()) {
                bail!("heartbeat capability token is duplicated");
            }
        }
    }
    Ok(())
}

pub(crate) fn apple_reference_seconds_now() -> f64 {
    let now = OffsetDateTime::now_utc().unix_timestamp_nanos() as f64 / 1_000_000_000.0;
    now - REFERENCE_UNIX_SECONDS as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strict_app_control_enum_round_trips_all_supported_variants() {
        let heartbeat = build_heartbeat_plaintext("device-1", Some("Device One")).expect("build");
        assert!(matches!(
            decode_app_control_message(&heartbeat).expect("heartbeat decode"),
            AppControlMessage::Heartbeat(_)
        ));

        let ping = build_ping_plaintext(7).expect("ping build");
        assert_eq!(
            decode_app_control_message(&ping).expect("ping decode"),
            AppControlMessage::Ping(LivenessPayload { id: 7 })
        );
        let pong = build_pong_plaintext(8).expect("pong build");
        assert_eq!(
            decode_app_control_message(&pong).expect("pong decode"),
            AppControlMessage::Pong(LivenessPayload { id: 8 })
        );
    }

    #[test]
    fn null_unknown_ambiguous_and_malformed_authenticated_messages_fail_closed() {
        for malformed in [
            br#"{"heartbeat":null}"#.as_slice(),
            br#"{"unsupported":true}"#.as_slice(),
            br#"{"ping":{"id":1},"pong":{"id":1}}"#.as_slice(),
            br#"{"ping":{"id":1,"unknown":true}}"#.as_slice(),
            br#"not-json"#.as_slice(),
        ] {
            assert!(decode_app_control_message(malformed).is_err());
        }
    }

    #[test]
    fn heartbeat_debug_redacts_device_identity() {
        let heartbeat = HeartbeatPayload {
            sent_at: 0.0,
            device_id: Some("device-identity-secret".to_owned()),
            device_name: Some("device-name-secret".to_owned()),
            model_name: None,
            platform: Some("test".to_owned()),
            os_version: None,
            chip: None,
            account_display_name: None,
            nebula_id: None,
            remote_video_formats: Some(vec!["bgra".to_owned()]),
            capabilities: None,
            file_transfer_port: None,
            remote_control_port: None,
            webrtc_media: None,
        };
        let debug = format!("{heartbeat:?}");
        assert!(!debug.contains("device-identity-secret"));
        assert!(!debug.contains("device-name-secret"));
    }
}
