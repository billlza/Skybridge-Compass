use anyhow::Result;

use crate::DoctorCheck;

use super::checks::{check_probe_reachable, first_bool, first_string, probe_body, value_string};
use super::{control_plane_report, signal_server_client};

pub(crate) async fn build_media_lease_doctor_report(
    base_url: Option<String>,
    allow_insecure_loopback: bool,
    expected_session_id: Option<String>,
    media_admission_token: Option<String>,
) -> Result<crate::DoctorProbeReport> {
    let signal_server = signal_server_client(base_url, allow_insecure_loopback)?;
    let target = signal_server.base_url.clone();
    let health = signal_server.probe_json_endpoint("/health").await;
    let mut checks = vec![check_probe_reachable("health", &health, "/health")];

    let supports_media = first_bool(&[probe_body(&health)], "supportsMediaAdmissionRefresh");
    checks.push(DoctorCheck {
        name: "media_endpoint_advertised",
        ok: supports_media == Some(true),
        severity: if supports_media == Some(true) {
            "info"
        } else {
            "error"
        },
        detail: "health should advertise supportsMediaAdmissionRefresh=true".to_owned(),
        server_build_fingerprint: first_string(&[probe_body(&health)], "serverBuildFingerprint"),
        state_backend: first_string(&[probe_body(&health)], "stateBackend"),
        reject_reason: None,
    });

    let Some(token) = media_admission_token.filter(|value| !value.trim().is_empty()) else {
        checks.push(DoctorCheck {
            name: "media_admission_token",
            ok: false,
            severity: "warn",
            detail: "media lease was not probed; pass --media-admission-token or SKYBRIDGE_MEDIA_ADMISSION_TOKEN".to_owned(),
            server_build_fingerprint: first_string(
                &[probe_body(&health)],
                "serverBuildFingerprint",
            ),
            state_backend: first_string(&[probe_body(&health)], "stateBackend"),
            reject_reason: None,
        });
        return Ok(control_plane_report(target, checks));
    };

    let lease = signal_server.probe_media_lease(&token).await;
    let lease_body = probe_body(&lease);
    let lease_success = lease.as_ref().is_ok_and(|probe| probe.success);
    let response_session_id = lease_body.and_then(|body| value_string(body, "sessionId"));
    let expected_session_matches = match expected_session_id.as_deref() {
        Some(expected) if lease_success => response_session_id
            .as_deref()
            .is_some_and(|actual| actual == expected),
        Some(_) if !lease_success => false,
        _ => true,
    };
    checks.push(DoctorCheck {
        name: "media_lease_success",
        ok: lease_success && expected_session_matches,
        severity: if lease_success && expected_session_matches {
            "info"
        } else {
            "error"
        },
        detail: match (&lease, expected_session_id.as_deref()) {
            (Ok(probe), Some(expected)) if probe.success && expected_session_matches => {
                format!(
                    "/api/media/lease returned HTTP {} for session {expected}",
                    probe.status_code
                )
            }
            (Ok(probe), Some(expected)) if probe.success => format!(
                "/api/media/lease returned session {}; expected {expected}",
                response_session_id.as_deref().unwrap_or("<missing>")
            ),
            (Ok(probe), _) => format!(
                "/api/media/lease rejected request with HTTP {}",
                probe.status_code
            ),
            (Err(error), _) => format!("/api/media/lease probe failed: {error}"),
        },
        server_build_fingerprint: lease_body
            .and_then(|body| value_string(body, "serverBuildFingerprint"))
            .or_else(|| first_string(&[probe_body(&health)], "serverBuildFingerprint")),
        state_backend: first_string(&[probe_body(&health)], "stateBackend"),
        reject_reason: lease_body.and_then(|body| value_string(body, "rejectReason")),
    });
    let diagnostic_fields_present = lease_body.is_some_and(|body| {
        body.get("rejectReason").is_some()
            || body.get("mediaTokenRevokedReason").is_some()
            || body.get("mediaTokenSessionRejectReason").is_some()
            || body.get("mediaTokenRequestGeneration").is_some()
            || body.get("mediaTokenSessionPresent").is_some()
    });
    checks.push(DoctorCheck {
        name: "media_lease_diagnostics",
        ok: lease_success || diagnostic_fields_present,
        severity: if lease_success || diagnostic_fields_present {
            "info"
        } else {
            "error"
        },
        detail: if lease_success {
            "media lease succeeded; no rejection diagnostics were needed".to_owned()
        } else if diagnostic_fields_present {
            "rejected media lease included structured token/session diagnostics".to_owned()
        } else {
            "rejected media lease did not include structured diagnostics".to_owned()
        },
        server_build_fingerprint: lease_body
            .and_then(|body| value_string(body, "serverBuildFingerprint"))
            .or_else(|| first_string(&[probe_body(&health)], "serverBuildFingerprint")),
        state_backend: first_string(&[probe_body(&health)], "stateBackend"),
        reject_reason: lease_body.and_then(|body| value_string(body, "rejectReason")),
    });

    Ok(control_plane_report(target, checks))
}
