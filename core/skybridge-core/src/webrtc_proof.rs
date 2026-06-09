use serde::Deserialize;
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedWebRtcProofSummary {
    pub peer_device_id: String,
    pub peer_public_key_fingerprint: String,
    pub helper_name: String,
    pub adapter_binding: String,
    pub local_endpoint: String,
    pub remote_endpoint: String,
    pub selected_candidate_pair: String,
    pub relay_id: Option<String>,
    pub timestamp_window_ms: u64,
    pub captured_at_unix_ms: i64,
    pub proof_age_ms: u64,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum WebRtcProofError {
    #[error("WebRTC proof JSON parse failed: {0}")]
    Json(String),
    #[error("WebRTC proof expected device id is required.")]
    MissingExpectedDeviceId,
    #[error("WebRTC proof expected fingerprint must be 64 lowercase hex characters.")]
    InvalidExpectedFingerprint,
    #[error("WebRTC proof max age must be greater than zero.")]
    InvalidMaxAge,
    #[error("WebRTC proof peer does not match pairing material.")]
    PeerMismatch,
    #[error("WebRTC proof fingerprint does not match pairing material.")]
    FingerprintMismatch,
    #[error("WebRTC proof must confirm the DataChannel opened.")]
    DataChannelNotOpen,
    #[error("WebRTC proof must confirm an SBF1 echo frame.")]
    MissingSbf1Echo,
    #[error("WebRTC proof must carry SBF1 frame magic.")]
    InvalidSbf1Magic,
    #[error("WebRTC proof requires a {0}.")]
    MissingText(&'static str),
    #[error("WebRTC proof {0} must be 64 lowercase hex characters.")]
    InvalidHex(&'static str),
    #[error("WebRTC proof requires a non-zero timestamp window.")]
    InvalidTimestampWindow,
    #[error("WebRTC proof requires capturedAtUnixMs.")]
    MissingCapturedAt,
    #[error("WebRTC proof is stale or from the future.")]
    StaleOrFuture,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WebRtcProofDocument {
    helper_name: Option<String>,
    peer_device_id: Option<String>,
    peer_public_key_fingerprint: Option<String>,
    data_channel_open: Option<bool>,
    sbf1_echo_verified: Option<bool>,
    sbf1_frame_magic: Option<String>,
    adapter_binding: Option<String>,
    local_endpoint: Option<String>,
    remote_endpoint: Option<String>,
    selected_candidate_pair: Option<String>,
    transport_secret_fingerprint_hex: Option<String>,
    capability_digest_hex: Option<String>,
    relay_id: Option<String>,
    timestamp_window_ms: Option<u64>,
    captured_at_unix_ms: Option<i64>,
}

pub fn validate_webrtc_proof_json(
    json: &str,
    expected_device_id: &str,
    expected_fingerprint: &str,
    max_age_ms: u64,
) -> Result<VerifiedWebRtcProofSummary, WebRtcProofError> {
    let now_unix_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| WebRtcProofError::StaleOrFuture)?
        .as_millis() as i64;
    validate_webrtc_proof_json_at(
        json,
        expected_device_id,
        expected_fingerprint,
        max_age_ms,
        now_unix_ms,
    )
}

pub fn validate_webrtc_proof_json_at(
    json: &str,
    expected_device_id: &str,
    expected_fingerprint: &str,
    max_age_ms: u64,
    now_unix_ms: i64,
) -> Result<VerifiedWebRtcProofSummary, WebRtcProofError> {
    if expected_device_id.trim().is_empty() {
        return Err(WebRtcProofError::MissingExpectedDeviceId);
    }
    if !is_lower_hex_64(expected_fingerprint) {
        return Err(WebRtcProofError::InvalidExpectedFingerprint);
    }
    if max_age_ms == 0 {
        return Err(WebRtcProofError::InvalidMaxAge);
    }

    let proof: WebRtcProofDocument =
        serde_json::from_str(json).map_err(|err| WebRtcProofError::Json(err.to_string()))?;
    let peer_device_id = require_raw_text(proof.peer_device_id, "peer device id")?;
    let peer_fingerprint = require_raw_text(
        proof.peer_public_key_fingerprint,
        "peer public key fingerprint",
    )?;
    if peer_device_id != expected_device_id {
        return Err(WebRtcProofError::PeerMismatch);
    }
    if peer_fingerprint != expected_fingerprint {
        return Err(WebRtcProofError::FingerprintMismatch);
    }
    if proof.data_channel_open != Some(true) {
        return Err(WebRtcProofError::DataChannelNotOpen);
    }
    if proof.sbf1_echo_verified != Some(true) {
        return Err(WebRtcProofError::MissingSbf1Echo);
    }
    if proof.sbf1_frame_magic.as_deref() != Some("SBF1") {
        return Err(WebRtcProofError::InvalidSbf1Magic);
    }

    let adapter_binding = require_text(proof.adapter_binding, "adapter binding")?;
    let local_endpoint = require_text(proof.local_endpoint, "local endpoint")?;
    let remote_endpoint = require_text(proof.remote_endpoint, "remote endpoint")?;
    let selected_candidate_pair =
        require_text(proof.selected_candidate_pair, "selected candidate pair")?;
    require_lower_hex_64(
        proof.transport_secret_fingerprint_hex.as_deref(),
        "transport secret fingerprint",
    )?;
    require_lower_hex_64(proof.capability_digest_hex.as_deref(), "capability digest")?;

    let timestamp_window_ms = proof
        .timestamp_window_ms
        .ok_or(WebRtcProofError::InvalidTimestampWindow)?;
    if timestamp_window_ms == 0 {
        return Err(WebRtcProofError::InvalidTimestampWindow);
    }

    let captured_at_unix_ms = proof
        .captured_at_unix_ms
        .ok_or(WebRtcProofError::MissingCapturedAt)?;
    if captured_at_unix_ms <= 0 {
        return Err(WebRtcProofError::MissingCapturedAt);
    }
    let age = now_unix_ms - captured_at_unix_ms;
    if age < 0 || age as u64 > max_age_ms {
        return Err(WebRtcProofError::StaleOrFuture);
    }

    Ok(VerifiedWebRtcProofSummary {
        peer_device_id,
        peer_public_key_fingerprint: peer_fingerprint,
        helper_name: proof
            .helper_name
            .and_then(non_empty_trimmed)
            .unwrap_or_else(|| "webrtc-helper".to_string()),
        adapter_binding,
        local_endpoint,
        remote_endpoint,
        selected_candidate_pair,
        relay_id: proof.relay_id.and_then(non_empty_trimmed),
        timestamp_window_ms,
        captured_at_unix_ms,
        proof_age_ms: age as u64,
    })
}

fn require_text(value: Option<String>, label: &'static str) -> Result<String, WebRtcProofError> {
    value
        .and_then(non_empty_trimmed)
        .ok_or(WebRtcProofError::MissingText(label))
}

fn require_raw_text(
    value: Option<String>,
    label: &'static str,
) -> Result<String, WebRtcProofError> {
    let value = value.ok_or(WebRtcProofError::MissingText(label))?;
    if value.trim().is_empty() {
        Err(WebRtcProofError::MissingText(label))
    } else {
        Ok(value)
    }
}

fn non_empty_trimmed(value: String) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn require_lower_hex_64(value: Option<&str>, label: &'static str) -> Result<(), WebRtcProofError> {
    if value.is_some_and(is_lower_hex_64) {
        Ok(())
    } else {
        Err(WebRtcProofError::InvalidHex(label))
    }
}

fn is_lower_hex_64(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

#[cfg(test)]
mod tests {
    use super::*;

    const FINGERPRINT: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    fn proof_json(overrides: &str) -> String {
        let body = if overrides.is_empty() {
            String::new()
        } else {
            format!(",{overrides}")
        };
        format!(
            r#"{{
  "helperName": "schema-smoke-webrtc-helper",
  "peerDeviceId": "mac-1",
  "peerPublicKeyFingerprint": "{FINGERPRINT}",
  "dataChannelOpen": true,
  "sbf1EchoVerified": true,
  "sbf1FrameMagic": "SBF1",
  "adapterBinding": "verified webrtc datachannel helper",
  "localEndpoint": "windows.lan:5443",
  "remoteEndpoint": "mac.lan:5443",
  "selectedCandidatePair": "webrtc/dtls/sctp/helper-selected",
  "transportSecretFingerprintHex": "6666666666666666666666666666666666666666666666666666666666666666",
  "capabilityDigestHex": "7777777777777777777777777777777777777777777777777777777777777777",
  "relayId": "relay-helper",
  "timestampWindowMs": 15000,
  "capturedAtUnixMs": 100000
  {body}
}}"#
        )
    }

    #[test]
    fn validates_schema_proof() {
        let summary =
            validate_webrtc_proof_json_at(&proof_json(""), "mac-1", FINGERPRINT, 60_000, 101_000)
                .expect("proof should validate");

        assert_eq!(summary.peer_device_id, "mac-1");
        assert_eq!(summary.helper_name, "schema-smoke-webrtc-helper");
        assert_eq!(summary.relay_id.as_deref(), Some("relay-helper"));
        assert_eq!(summary.timestamp_window_ms, 15_000);
        assert_eq!(summary.proof_age_ms, 1_000);
    }

    #[test]
    fn rejects_mismatched_identity_and_missing_echo() {
        let peer_err =
            validate_webrtc_proof_json_at(&proof_json(""), "mac-2", FINGERPRINT, 60_000, 101_000)
                .unwrap_err();
        assert_eq!(peer_err, WebRtcProofError::PeerMismatch);

        let no_echo = proof_json("").replace(
            r#""sbf1EchoVerified": true"#,
            r#""sbf1EchoVerified": false"#,
        );
        let echo_err =
            validate_webrtc_proof_json_at(&no_echo, "mac-1", FINGERPRINT, 60_000, 101_000)
                .unwrap_err();
        assert_eq!(echo_err, WebRtcProofError::MissingSbf1Echo);
    }

    #[test]
    fn rejects_stale_or_invalid_hex() {
        let stale =
            validate_webrtc_proof_json_at(&proof_json(""), "mac-1", FINGERPRINT, 999, 101_000)
                .unwrap_err();
        assert_eq!(stale, WebRtcProofError::StaleOrFuture);

        let invalid_hex = validate_webrtc_proof_json_at(
            &proof_json(""),
            "mac-1",
            "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
            60_000,
            101_000,
        )
        .unwrap_err();
        assert_eq!(invalid_hex, WebRtcProofError::InvalidExpectedFingerprint);
    }
}
