use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use anyhow::{Result, anyhow};
use getrandom::fill as fill_random;
use serde::Serialize;
use serde_json::Value;
use time::OffsetDateTime;

use crate::classic_handshake::{ClassicHandleResult, ClassicSessionKeys};

pub(crate) const HEARTBEAT_PLATFORM: &str = std::env::consts::OS;
const HEARTBEAT_REMOTE_VIDEO_FORMAT: &str = "bgra";
const REFERENCE_UNIX_SECONDS: i64 = 978_307_200;

#[derive(Debug, Clone, Serialize)]
pub struct HeartbeatPayload {
    #[serde(rename = "sentAt")]
    pub sent_at: f64,
    #[serde(rename = "deviceId", skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(rename = "deviceName", skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    #[serde(rename = "platform")]
    pub platform: String,
    #[serde(rename = "remoteVideoFormats")]
    pub remote_video_formats: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
struct HeartbeatEnvelope {
    heartbeat: HeartbeatPayload,
}

#[derive(Debug, Clone, Serialize)]
struct PongEnvelope {
    pong: PongPayload,
}

#[derive(Debug, Clone, Serialize)]
struct PingEnvelope {
    ping: PingPayload,
}

#[derive(Debug, Clone, Serialize)]
struct PingPayload {
    id: u64,
}

#[derive(Debug, Clone, Serialize)]
struct PongPayload {
    id: u64,
}

pub(crate) fn build_heartbeat_frame(
    session_keys: &ClassicSessionKeys,
    device_id: &str,
    device_name: Option<&str>,
) -> Result<Vec<u8>> {
    let payload = HeartbeatEnvelope {
        heartbeat: HeartbeatPayload {
            sent_at: apple_reference_seconds_now(),
            device_id: Some(device_id.to_owned()),
            device_name: device_name.map(str::to_owned),
            platform: HEARTBEAT_PLATFORM.to_owned(),
            remote_video_formats: vec![HEARTBEAT_REMOTE_VIDEO_FORMAT.to_owned()],
        },
    };
    build_encrypted_app_frame(session_keys, &payload)
}

pub(crate) fn build_pong_frame(session_keys: &ClassicSessionKeys, id: u64) -> Result<Vec<u8>> {
    build_encrypted_app_frame(
        session_keys,
        &PongEnvelope {
            pong: PongPayload { id },
        },
    )
}

pub(crate) fn build_ping_frame(session_keys: &ClassicSessionKeys, id: u64) -> Result<Vec<u8>> {
    build_encrypted_app_frame(
        session_keys,
        &PingEnvelope {
            ping: PingPayload { id },
        },
    )
}

pub(crate) fn try_handle_encrypted_app_message(
    frame: &[u8],
    session_keys: &ClassicSessionKeys,
) -> Result<Option<ClassicHandleResult>> {
    if frame.len() < 12 + 16 {
        return Ok(None);
    }
    let cipher = Aes256Gcm::new_from_slice(&session_keys.receive_key)
        .map_err(|error| anyhow!("invalid AES-256 key: {error}"))?;
    let plaintext = match cipher.decrypt(Nonce::from_slice(&frame[..12]), &frame[12..]) {
        Ok(plaintext) => plaintext,
        Err(_) => return Ok(None),
    };
    // Binary file frames and JSON keepalive frames share this encrypted stream.
    // They are disjoint on the first plaintext byte (file = 0x53 'S', JSON =
    // 0x7B '{'), so we branch deterministically. A malformed file frame fails
    // closed rather than being silently treated as a non-event.
    if crate::file_transfer_frame::is_file_app_frame(&plaintext) {
        let inbound_file_frame = crate::file_transfer_frame::decode_file_app_frame(&plaintext)?;
        return Ok(Some(ClassicHandleResult {
            inbound_file_frame: Some(inbound_file_frame),
            ..ClassicHandleResult::default()
        }));
    }
    let value: Value = match serde_json::from_slice(&plaintext) {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };
    let pong_id = value
        .get("ping")
        .and_then(|ping| ping.get("id"))
        .and_then(Value::as_u64);
    let observed_pong_id = value
        .get("pong")
        .and_then(|pong| pong.get("id"))
        .and_then(Value::as_u64);
    Ok(Some(ClassicHandleResult {
        outbound_frames: Vec::new(),
        established: None,
        heartbeat_requested: value.get("heartbeat").is_some(),
        pong_id,
        observed_pong_id,
        observed_heartbeat: value.get("heartbeat").is_some(),
        inbound_file_frame: None,
    }))
}

/// Encrypt arbitrary application plaintext bytes into an AES-256-GCM app frame
/// using the per-frame random-nonce construction. Used for binary file frames;
/// JSON frames go through [`build_encrypted_app_frame`].
pub(crate) fn build_encrypted_app_frame_bytes(
    session_keys: &ClassicSessionKeys,
    plaintext: &[u8],
) -> Result<Vec<u8>> {
    let cipher = Aes256Gcm::new_from_slice(&session_keys.send_key)
        .map_err(|error| anyhow!("invalid AES-256 key: {error}"))?;
    let mut nonce_bytes = [0u8; 12];
    fill_random(&mut nonce_bytes)?;
    let ciphertext_and_tag = cipher
        .encrypt(Nonce::from_slice(&nonce_bytes), plaintext)
        .map_err(|error| anyhow!("failed to encrypt app payload: {error}"))?;
    let mut combined = nonce_bytes.to_vec();
    combined.extend_from_slice(&ciphertext_and_tag);
    Ok(combined)
}

fn build_encrypted_app_frame<T: Serialize>(
    session_keys: &ClassicSessionKeys,
    payload: &T,
) -> Result<Vec<u8>> {
    let plaintext = serde_json::to_vec(payload)?;
    build_encrypted_app_frame_bytes(session_keys, &plaintext)
}

pub(crate) fn apple_reference_seconds_now() -> f64 {
    let now = OffsetDateTime::now_utc().unix_timestamp_nanos() as f64 / 1_000_000_000.0;
    now - REFERENCE_UNIX_SECONDS as f64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::file_transfer_frame::{FileAppFrame, encode_chunk};

    fn loopback_keys() -> ClassicSessionKeys {
        // send_key == receive_key so a frame built with send_key decrypts with
        // receive_key in the same test (the real protocol uses distinct keys).
        ClassicSessionKeys {
            send_key: vec![7u8; 32],
            receive_key: vec![7u8; 32],
            negotiated_suite: "test".to_owned(),
            transcript_hash: vec![0u8; 32],
        }
    }

    #[test]
    fn binary_file_frame_round_trips_through_app_message_parser() {
        let keys = loopback_keys();
        let plaintext = encode_chunk(&[1u8; 16], 3, &[9u8; 128]).expect("encode chunk");
        let frame = build_encrypted_app_frame_bytes(&keys, &plaintext).expect("encrypt");
        let result = try_handle_encrypted_app_message(&frame, &keys)
            .expect("decrypt ok")
            .expect("frame recognized");
        match result.inbound_file_frame {
            Some(FileAppFrame::Chunk { sequence, .. }) => assert_eq!(sequence, 3),
            other => panic!("expected inbound chunk frame, got {other:?}"),
        }
        assert!(!result.observed_heartbeat);
    }

    #[test]
    fn heartbeat_frame_still_parses_as_keepalive() {
        let keys = loopback_keys();
        let frame = build_heartbeat_frame(&keys, "device-1", Some("Device One")).expect("build");
        let result = try_handle_encrypted_app_message(&frame, &keys)
            .expect("decrypt ok")
            .expect("frame recognized");
        assert!(result.observed_heartbeat);
        assert!(result.inbound_file_frame.is_none());
    }

    #[test]
    fn corrupt_file_frame_fails_closed() {
        let keys = loopback_keys();
        // Valid magic but truncated body -> decode must error (fail closed),
        // not be silently dropped.
        let mut plaintext = crate::file_transfer_frame::FILE_FRAME_MAGIC.to_vec();
        plaintext.push(crate::file_transfer_frame::FILE_FRAME_VERSION);
        plaintext.push(0x02); // CHUNK type, but nothing follows
        let frame = build_encrypted_app_frame_bytes(&keys, &plaintext).expect("encrypt");
        assert!(try_handle_encrypted_app_message(&frame, &keys).is_err());
    }
}
