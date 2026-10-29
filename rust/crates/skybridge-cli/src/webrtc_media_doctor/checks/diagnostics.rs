use super::super::evidence::WebRtcMediaEvidence;
use crate::DoctorCheck;

pub(in crate::webrtc_media_doctor) fn check_webrtc_media_sources(
    evidence: &WebRtcMediaEvidence,
) -> DoctorCheck {
    let ok = !evidence.read_sources.is_empty() && evidence.read_errors.is_empty();
    let severity = if evidence.read_sources.is_empty() {
        "error"
    } else if evidence.read_errors.is_empty() {
        "info"
    } else {
        "warn"
    };
    DoctorCheck {
        name: "diagnostic_sources",
        ok,
        severity,
        detail: if evidence.read_errors.is_empty() {
            format!("read {} diagnostic source(s)", evidence.read_sources.len())
        } else {
            format!(
                "read {} diagnostic source(s); {} source/read error(s): {}",
                evidence.read_sources.len(),
                evidence.read_errors.len(),
                evidence.read_errors.join("; ")
            )
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}

pub(in crate::webrtc_media_doctor) fn check_webrtc_media_samples(
    evidence: &WebRtcMediaEvidence,
    session_id: &str,
    since_seconds: u64,
) -> DoctorCheck {
    let ok = evidence.matched_lines > 0;
    DoctorCheck {
        name: "diagnostic_samples",
        ok,
        severity: if ok { "info" } else { "warn" },
        detail: if ok {
            match evidence.latest_at {
                Some(timestamp) => format!(
                    "matched {} diagnostics for session {session_id}; latest timestamp {timestamp}",
                    evidence.matched_lines
                ),
                None => format!(
                    "matched {} diagnostics for session {session_id}; lines had no parseable timestamp",
                    evidence.matched_lines
                ),
            }
        } else {
            format!("no diagnostics matched session {session_id} within the last {since_seconds}s")
        },
        server_build_fingerprint: None,
        state_backend: None,
        reject_reason: None,
    }
}
