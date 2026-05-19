use anyhow::Result;
use serde_json::json;

use crate::cli_test_support::spawn_mock_server;

#[tokio::test]
async fn signaling_doctor_mock_server_reports_media_surface() -> Result<()> {
    let base_url = spawn_mock_server(vec![
        (
            "GET",
            "/",
            200,
            json!({
                "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456",
                "stateBackend": "redis",
                "supportsMediaAdmissionRefresh": true,
                "endpoints": ["/api/media/lease", "/api/media/admission/refresh"]
            }),
        ),
        (
            "GET",
            "/health",
            200,
            json!({
                "status": "ok",
                "ready": true,
                "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456",
                "stateBackend": "redis",
                "supportsMediaAdmissionRefresh": true
            }),
        ),
        (
            "GET",
            "/readyz",
            200,
            json!({
                "status": "ready",
                "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456",
                "stateBackend": "redis",
                "supportsMediaAdmissionRefresh": true
            }),
        ),
        (
            "GET",
            "/api/turn/credentials",
            401,
            json!({
                "error": "missing_turn_admission",
                "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456"
            }),
        ),
        (
            "POST",
            "/api/media/lease",
            401,
            json!({
                "error": "missing_media_admission",
                "rejectReason": "missingToken",
                "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456"
            }),
        ),
    ])?;

    let report =
        crate::control_plane_doctor::build_signaling_doctor_report(Some(base_url), Some("redis"))
            .await?;

    assert!(report.checks.iter().all(|check| check.ok));
    assert!(
        report
            .checks
            .iter()
            .any(|check| check.name == "media_diagnostics_supported")
    );
    Ok(())
}

#[tokio::test]
async fn media_lease_doctor_reports_reject_reason_fields() -> Result<()> {
    let base_url = spawn_mock_server(vec![
        (
            "GET",
            "/health",
            200,
            json!({
                "status": "ok",
                "ready": true,
                "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456",
                "stateBackend": "redis",
                "supportsMediaAdmissionRefresh": true
            }),
        ),
        (
            "POST",
            "/api/media/lease",
            401,
            json!({
                "error": "media_admission_token_superseded",
                "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456",
                "mediaTokenState": "revoked",
                "mediaTokenRevokedReason": "remote_kill",
                "mediaTokenSessionRejectReason": "remote_kill",
                "rejectReason": "remote_kill"
            }),
        ),
    ])?;

    let report = crate::control_plane_doctor::build_media_lease_doctor_report(
        Some(base_url),
        Some("SESSION1".to_owned()),
        Some("token".to_owned()),
    )
    .await?;

    let success = report
        .checks
        .iter()
        .find(|check| check.name == "media_lease_success")
        .expect("media lease success check missing");
    assert!(!success.ok);

    let diagnostics = report
        .checks
        .iter()
        .find(|check| check.name == "media_lease_diagnostics")
        .expect("media diagnostics check missing");
    assert!(diagnostics.ok);
    assert_eq!(diagnostics.reject_reason.as_deref(), Some("remote_kill"));
    Ok(())
}
