use crate::DoctorCheck;
use crate::webrtc_media_doctor::evidence::WebRtcMediaEvidence;

use super::super::{counter_observed_positive, latest_counter_value};

pub(in crate::webrtc_media_doctor) fn webrtc_audio_rx_has_received(
    evidence: &WebRtcMediaEvidence,
) -> bool {
    counter_observed_positive(&evidence.audio_rx_recv)
        || counter_observed_positive(&evidence.audio_rx_recv_total)
}

pub(in crate::webrtc_media_doctor) fn check_webrtc_audio_relay_startup(
    evidence: &WebRtcMediaEvidence,
) -> DoctorCheck {
    if let Some(failure) = evidence.audio_tx_relay_failure.as_ref() {
        if latest_counter_value(&evidence.audio_tx_sent).is_some_and(|value| value > 0) {
            if !webrtc_audio_rx_has_received(evidence) {
                return DoctorCheck {
                    name: "audio_relay_startup",
                    ok: false,
                    severity: "error",
                    detail: format!(
                        "Mac sender reported media sent after relay bind warning ({}), but receiver has no audio; bind evidence {}",
                        failure.value, failure.evidence
                    ),
                    server_build_fingerprint: None,
                    state_backend: None,
                    reject_reason: None,
                };
            }
            return DoctorCheck {
                name: "audio_relay_startup",
                ok: true,
                severity: "info",
                detail: format!(
                    "Mac sender reported media sent after relay bind warning ({}); bind evidence {}; continue diagnosing relay forwarding/RX if receiver stays zero",
                    failure.value, failure.evidence
                ),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            };
        }
        return DoctorCheck {
            name: "audio_relay_startup",
            ok: false,
            severity: "error",
            detail: format!(
                "Mac sender failed to bind/send media relay ({}); evidence {}",
                failure.value, failure.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    if let Some(pending) = evidence.audio_tx_relay_bind_pending.as_ref() {
        if !webrtc_audio_rx_has_received(evidence) {
            return DoctorCheck {
                name: "audio_relay_startup",
                ok: false,
                severity: "error",
                detail: format!(
                    "Mac sender relay bind ACK is still pending and receiver has no audio; bind evidence {}",
                    pending.evidence
                ),
                server_build_fingerprint: None,
                state_backend: None,
                reject_reason: None,
            };
        }
        return DoctorCheck {
            name: "audio_relay_startup",
            ok: true,
            severity: "info",
            detail: format!(
                "Mac sender relay bind ACK was pending, but receiver audio is flowing; bind evidence {}",
                pending.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    if let Some(failure) = evidence.audio_rx_relay_bind_failure.as_ref() {
        return DoctorCheck {
            name: "audio_relay_startup",
            ok: false,
            severity: "error",
            detail: format!(
                "audio relay receiver startup failed at {}; evidence {}",
                failure.value, failure.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    if let Some(missing) = evidence.audio_tx_missing_viewer_endpoint.as_ref() {
        return DoctorCheck {
            name: "audio_relay_startup",
            ok: false,
            severity: "error",
            detail: format!(
                "Mac sender never received viewer media endpoint ({}); evidence {}",
                missing.value, missing.evidence
            ),
            server_build_fingerprint: None,
            state_backend: None,
            reject_reason: None,
        };
    }
    DoctorCheck {
        name: "audio_relay_startup",
        ok: true,
        severity: "info",
        detail: "no audio relay startup/bind failure evidence observed".to_owned(),
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}
