use anyhow::Result;

use super::*;

fn report(checks: Vec<DoctorCheck>, fault_stage: Option<&'static str>) -> DoctorProbeReport {
    DoctorProbeReport {
        target: "test-target".to_owned(),
        checks,
        fault_stage,
        latest_diagnostic_at: None,
        latest_video_evidence_at: None,
        latest_receiver_evidence_at: None,
        latest_audio_tx_evidence_at: None,
        latest_audio_rx_evidence_at: None,
    }
}

#[test]
fn simple_doctor_check_defaults_optional_metadata() {
    let check = simple_doctor_check("sample", true, "info", "ok".to_owned());

    assert_eq!(check.name, "sample");
    assert!(check.ok);
    assert_eq!(check.severity, "info");
    assert_eq!(check.detail, "ok");
    assert!(check.server_build_fingerprint.is_none());
    assert!(check.state_backend.is_none());
    assert!(check.reject_reason.is_none());
}

#[test]
fn ensure_probe_report_passed_accepts_clean_report() -> Result<()> {
    let clean = report(
        vec![simple_doctor_check(
            "ready",
            true,
            "info",
            "ready".to_owned(),
        )],
        None,
    );

    ensure_probe_report_passed(&clean, "clean report")
}

#[test]
fn ensure_probe_report_passed_rejects_warning_error_and_fault_stage() {
    let warning = report(
        vec![simple_doctor_check(
            "lease",
            true,
            "warn",
            "missing token".to_owned(),
        )],
        None,
    );
    assert!(
        ensure_probe_report_passed(&warning, "warning report")
            .unwrap_err()
            .to_string()
            .contains("lease (warn)")
    );

    let failed = report(
        vec![simple_doctor_check(
            "ready",
            false,
            "error",
            "not ready".to_owned(),
        )],
        Some("startup"),
    );
    let error = ensure_probe_report_passed(&failed, "failed report").unwrap_err();
    let text = error.to_string();
    assert!(text.contains("probable_fault_stage=startup"));
    assert!(text.contains("ready (error)"));
}

#[test]
fn ensure_webrtc_media_doctor_passed_matches_strict_media_semantics() -> Result<()> {
    let clean = report(
        vec![simple_doctor_check("fps", true, "info", "60fps".to_owned())],
        None,
    );
    ensure_webrtc_media_doctor_passed(&clean)?;

    let warning = report(
        vec![simple_doctor_check(
            "audio",
            true,
            "warning",
            "underflow".to_owned(),
        )],
        Some("audio"),
    );
    let error = ensure_webrtc_media_doctor_passed(&warning).unwrap_err();
    let text = error.to_string();
    assert!(text.contains("WebRTC media doctor failed"));
    assert!(text.contains("probable_fault_stage=audio"));
    assert!(text.contains("audio (warning)"));
    Ok(())
}

#[test]
fn doctor_probe_report_serializes_operator_fields() -> Result<()> {
    let serialized = serde_json::to_value(report(
        vec![DoctorCheck {
            name: "health",
            ok: false,
            severity: "error",
            detail: "bad".to_owned(),
            server_build_fingerprint: Some("build-1".to_owned()),
            state_backend: Some("redis".to_owned()),
            reject_reason: Some("denied".to_owned()),
        }],
        Some("control-plane"),
    ))?;

    assert_eq!(serialized["target"], "test-target");
    assert_eq!(serialized["faultStage"], "control-plane");
    assert_eq!(serialized["checks"][0]["serverBuildFingerprint"], "build-1");
    assert_eq!(serialized["checks"][0]["stateBackend"], "redis");
    assert_eq!(serialized["checks"][0]["rejectReason"], "denied");
    Ok(())
}
