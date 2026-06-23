use serde::Deserialize;
use std::net::{IpAddr, Ipv4Addr};
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;

use crate::transport::{SkyBridgeTransportKind, TransportAuditReason, TransportBindingMaterial};

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
    pub transport_secret_fingerprint: [u8; 32],
    pub capability_digest: [u8; 32],
    pub captured_at_unix_ms: i64,
    pub proof_age_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedWebRtcSessionLaunch {
    pub proof: VerifiedWebRtcProofSummary,
    pub transport_binding_digest: [u8; 32],
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
    #[error("WebRTC proof {0} is not a routable helper endpoint.")]
    InvalidEndpoint(&'static str),
    #[error("WebRTC proof selected candidate pair is missing real ICE material.")]
    InvalidCandidatePair,
    #[error("WebRTC proof {0} must be 64 lowercase hex characters.")]
    InvalidHex(&'static str),
    #[error("WebRTC proof requires a non-zero timestamp window.")]
    InvalidTimestampWindow,
    #[error("WebRTC proof requires capturedAtUnixMs.")]
    MissingCapturedAt,
    #[error("WebRTC proof is stale or from the future.")]
    StaleOrFuture,
    #[error("WebRTC session launch requires Core WebRtcDataChannel transport.")]
    UnsupportedTransport,
    #[error("WebRTC session launch requires Core WebRtcInterop transport audit.")]
    UnsupportedTransportAudit,
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

pub fn verify_webrtc_session_launch_json(
    json: &str,
    expected_device_id: &str,
    expected_fingerprint: &str,
    max_age_ms: u64,
    transport: SkyBridgeTransportKind,
    transport_audit: TransportAuditReason,
) -> Result<VerifiedWebRtcSessionLaunch, WebRtcProofError> {
    let now_unix_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| WebRtcProofError::StaleOrFuture)?
        .as_millis() as i64;
    verify_webrtc_session_launch_json_at(
        json,
        expected_device_id,
        expected_fingerprint,
        max_age_ms,
        transport,
        transport_audit,
        now_unix_ms,
    )
}

pub fn verify_webrtc_session_launch_json_at(
    json: &str,
    expected_device_id: &str,
    expected_fingerprint: &str,
    max_age_ms: u64,
    transport: SkyBridgeTransportKind,
    transport_audit: TransportAuditReason,
    now_unix_ms: i64,
) -> Result<VerifiedWebRtcSessionLaunch, WebRtcProofError> {
    if transport != SkyBridgeTransportKind::WebRtcDataChannel {
        return Err(WebRtcProofError::UnsupportedTransport);
    }
    if transport_audit != TransportAuditReason::WebRtcInterop {
        return Err(WebRtcProofError::UnsupportedTransportAudit);
    }

    let proof = validate_webrtc_proof_json_at(
        json,
        expected_device_id,
        expected_fingerprint,
        max_age_ms,
        now_unix_ms,
    )?;
    let binding = TransportBindingMaterial {
        transport_kind: SkyBridgeTransportKind::WebRtcDataChannel,
        local_endpoint: proof.local_endpoint.clone(),
        remote_endpoint: proof.remote_endpoint.clone(),
        selected_candidate_pair: proof.selected_candidate_pair.clone(),
        transport_secret_fingerprint: proof.transport_secret_fingerprint.to_vec(),
        relay_id: proof.relay_id.clone(),
        timestamp_window_ms: proof.timestamp_window_ms,
        capability_digest: proof.capability_digest.to_vec(),
    };

    Ok(VerifiedWebRtcSessionLaunch {
        proof,
        transport_binding_digest: binding.transcript_digest(),
    })
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
    let local_endpoint = require_endpoint(proof.local_endpoint, "local endpoint")?;
    let remote_endpoint = require_endpoint(proof.remote_endpoint, "remote endpoint")?;
    let selected_candidate_pair = require_candidate_pair(proof.selected_candidate_pair)?;
    let transport_secret_fingerprint = parse_lower_hex_32(
        proof.transport_secret_fingerprint_hex.as_deref(),
        "transport secret fingerprint",
    )?;
    let capability_digest =
        parse_lower_hex_32(proof.capability_digest_hex.as_deref(), "capability digest")?;

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
        transport_secret_fingerprint,
        capability_digest,
        captured_at_unix_ms,
        proof_age_ms: age as u64,
    })
}

fn require_text(value: Option<String>, label: &'static str) -> Result<String, WebRtcProofError> {
    value
        .and_then(non_empty_trimmed)
        .ok_or(WebRtcProofError::MissingText(label))
}

fn require_endpoint(
    value: Option<String>,
    label: &'static str,
) -> Result<String, WebRtcProofError> {
    let value = require_text(value, label)?;
    let (host, port) =
        parse_endpoint_host_port(&value).ok_or(WebRtcProofError::InvalidEndpoint(label))?;
    if port == 0 || is_rejected_endpoint_host(host) {
        return Err(WebRtcProofError::InvalidEndpoint(label));
    }
    Ok(value)
}

fn require_candidate_pair(value: Option<String>) -> Result<String, WebRtcProofError> {
    let value = require_text(value, "selected candidate pair")?;
    let normalized = value.trim().to_ascii_lowercase();
    if is_placeholder_text(&normalized)
        || normalized.contains("127.0.0.1:0")
        || normalized.contains("localhost:0")
        || normalized.contains("no-fingerprint")
    {
        return Err(WebRtcProofError::InvalidCandidatePair);
    }
    Ok(value)
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

fn parse_endpoint_host_port(value: &str) -> Option<(&str, u16)> {
    let value = value.trim();
    if let Some(rest) = value.strip_prefix('[') {
        let closing = rest.find(']')?;
        let host = &rest[..closing];
        let suffix = &rest[closing + 1..];
        let port = suffix.strip_prefix(':')?.parse::<u16>().ok()?;
        if host.trim().is_empty() {
            return None;
        }
        return Some((host, port));
    }

    let (host, port) = value.rsplit_once(':')?;
    if host.trim().is_empty()
        || port.is_empty()
        || host.contains('/')
        || host.contains('\\')
        || host.contains(':')
        || !port.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }

    Some((host, port.parse::<u16>().ok()?))
}

fn is_rejected_endpoint_host(host: &str) -> bool {
    let normalized = host.trim().trim_end_matches('.').to_ascii_lowercase();
    if normalized.is_empty()
        || normalized == "localhost"
        || normalized == "localhost.localdomain"
        || is_placeholder_text(&normalized)
    {
        return true;
    }

    let host_without_zone = normalized
        .split_once('%')
        .map(|(host, _)| host)
        .unwrap_or(normalized.as_str());
    match host_without_zone.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => {
            ip.is_unspecified()
                || ip.is_loopback()
                || ip.is_multicast()
                || ip == Ipv4Addr::new(255, 255, 255, 255)
        }
        Ok(IpAddr::V6(ip)) => ip.is_unspecified() || ip.is_loopback() || ip.is_multicast(),
        Err(_) => false,
    }
}

fn is_placeholder_text(value: &str) -> bool {
    matches!(
        value,
        "placeholder"
            | "unknown"
            | "none"
            | "null"
            | "n/a"
            | "no-endpoint"
            | "no-candidate"
            | "no-candidate-pair"
            | "missing"
    )
}

fn parse_lower_hex_32(
    value: Option<&str>,
    label: &'static str,
) -> Result<[u8; 32], WebRtcProofError> {
    let value = value.ok_or(WebRtcProofError::InvalidHex(label))?;
    if !is_lower_hex_64(value) {
        return Err(WebRtcProofError::InvalidHex(label));
    }

    let mut bytes = [0u8; 32];
    for (index, slot) in bytes.iter_mut().enumerate() {
        let high = from_lower_hex(value.as_bytes()[index * 2], label)?;
        let low = from_lower_hex(value.as_bytes()[index * 2 + 1], label)?;
        *slot = (high << 4) | low;
    }
    Ok(bytes)
}

fn from_lower_hex(value: u8, label: &'static str) -> Result<u8, WebRtcProofError> {
    match value {
        b'0'..=b'9' => Ok(value - b'0'),
        b'a'..=b'f' => Ok(value - b'a' + 10),
        _ => Err(WebRtcProofError::InvalidHex(label)),
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
    use crate::transport::{SkyBridgeTransportKind, TransportAuditReason};

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
        assert_eq!(summary.transport_secret_fingerprint, [0x66; 32]);
        assert_eq!(summary.capability_digest, [0x77; 32]);
        assert_eq!(summary.proof_age_ms, 1_000);
    }

    #[test]
    fn builds_core_owned_session_launch_binding() {
        let launch = verify_webrtc_session_launch_json_at(
            &proof_json(""),
            "mac-1",
            FINGERPRINT,
            60_000,
            SkyBridgeTransportKind::WebRtcDataChannel,
            TransportAuditReason::WebRtcInterop,
            101_000,
        )
        .expect("session launch proof should validate");

        let material = TransportBindingMaterial {
            transport_kind: SkyBridgeTransportKind::WebRtcDataChannel,
            local_endpoint: "windows.lan:5443".to_string(),
            remote_endpoint: "mac.lan:5443".to_string(),
            selected_candidate_pair: "webrtc/dtls/sctp/helper-selected".to_string(),
            transport_secret_fingerprint: vec![0x66; 32],
            relay_id: Some("relay-helper".to_string()),
            timestamp_window_ms: 15_000,
            capability_digest: vec![0x77; 32],
        };

        assert_eq!(
            launch.transport_binding_digest,
            material.transcript_digest()
        );
    }

    #[test]
    fn rejects_non_webrtc_session_launch_transport() {
        let err = verify_webrtc_session_launch_json_at(
            &proof_json(""),
            "mac-1",
            FINGERPRINT,
            60_000,
            SkyBridgeTransportKind::AppleNative,
            TransportAuditReason::WebRtcInterop,
            101_000,
        )
        .unwrap_err();
        assert_eq!(err, WebRtcProofError::UnsupportedTransport);

        let audit_err = verify_webrtc_session_launch_json_at(
            &proof_json(""),
            "mac-1",
            FINGERPRINT,
            60_000,
            SkyBridgeTransportKind::WebRtcDataChannel,
            TransportAuditReason::AppleNativeDefault,
            101_000,
        )
        .unwrap_err();
        assert_eq!(audit_err, WebRtcProofError::UnsupportedTransportAudit);
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

    #[test]
    fn rejects_placeholder_endpoint_and_candidate_material() {
        let placeholder_local = proof_json("").replace(
            r#""localEndpoint": "windows.lan:5443""#,
            r#""localEndpoint": "127.0.0.1:0""#,
        );
        let endpoint_err = validate_webrtc_proof_json_at(
            &placeholder_local,
            "mac-1",
            FINGERPRINT,
            60_000,
            101_000,
        )
        .unwrap_err();
        assert_eq!(
            endpoint_err,
            WebRtcProofError::InvalidEndpoint("local endpoint")
        );

        let missing_candidate = proof_json("").replace(
            r#""selectedCandidatePair": "webrtc/dtls/sctp/helper-selected""#,
            r#""selectedCandidatePair": "no-candidate-pair""#,
        );
        let candidate_err = validate_webrtc_proof_json_at(
            &missing_candidate,
            "mac-1",
            FINGERPRINT,
            60_000,
            101_000,
        )
        .unwrap_err();
        assert_eq!(candidate_err, WebRtcProofError::InvalidCandidatePair);
    }
}
