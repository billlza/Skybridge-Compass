use super::*;
use std::time::{SystemTime, UNIX_EPOCH};

fn make_test_dir(name: &str) -> Result<PathBuf> {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let dir = std::env::temp_dir().join(format!(
        "skybridge-cli-connection-code-{name}-{}-{stamp}",
        std::process::id()
    ));
    if dir.exists() {
        let _ = fs::remove_dir_all(&dir);
    }
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

#[test]
fn code_current_reads_nonexpired_snapshot() -> Result<()> {
    let artifact_dir = make_test_dir("valid")?;
    let path = artifact_dir.join("connection-code-latest.json");
    let expires_at = (OffsetDateTime::now_utc() + time::Duration::minutes(5))
        .format(&time::format_description::well_known::Rfc3339)?;
    fs::write(
        &path,
        serde_json::to_string(&json!({
            "schemaVersion": 1,
            "code": "SB-TEST-CODE",
            "sessionId": "SESSION-CODE",
            "expiresAt": expires_at,
            "leaseMode": "cross-network",
            "deviceId": "DEVICE-1",
            "protocolPublicKeyFingerprint": "fp-test",
            "generatedAt": OffsetDateTime::now_utc()
                .format(&time::format_description::well_known::Rfc3339)?,
        }))?,
    )?;

    let snapshot = read_connection_code_snapshot(&path)?;

    assert_eq!(snapshot.code, "SB-TEST-CODE");
    assert_eq!(snapshot.session_id, "SESSION-CODE");
    assert_eq!(snapshot.lease_mode.as_deref(), Some("cross-network"));
    Ok(())
}

#[test]
fn code_current_formats_text_and_json_snapshot_outputs() -> Result<()> {
    let artifact_dir = make_test_dir("format")?;
    let path = artifact_dir.join("connection-code-latest.json");
    let expires_at = (OffsetDateTime::now_utc() + time::Duration::minutes(5))
        .format(&time::format_description::well_known::Rfc3339)?;
    fs::write(
        &path,
        serde_json::to_string(&json!({
            "schemaVersion": 1,
            "code": "SB-FORMAT-CODE",
            "sessionId": "SESSION-FORMAT",
            "expiresAt": expires_at,
            "leaseMode": "cross-network",
            "deviceId": "DEVICE-FORMAT",
            "protocolPublicKeyFingerprint": "fp-format",
            "generatedAt": OffsetDateTime::now_utc()
                .format(&time::format_description::well_known::Rfc3339)?,
        }))?,
    )?;
    let snapshot = read_connection_code_snapshot(&path)?;

    let text = format_connection_code_snapshot_text(&snapshot, &path);
    assert!(text.contains("Code: SB-FORMAT-CODE"));
    assert!(text.contains("Session ID: SESSION-FORMAT"));
    assert!(text.contains("Expires At:"));
    assert!(text.contains(&path.display().to_string()));

    let output = connection_code_snapshot_json(&snapshot, &path);
    assert_eq!(output["code"], "SB-FORMAT-CODE");
    assert_eq!(output["session_id"], "SESSION-FORMAT");
    assert_eq!(output["device_id"], "DEVICE-FORMAT");
    assert_eq!(output["protocol_public_key_fingerprint"], "fp-format");
    assert_eq!(output["snapshot"], path.display().to_string());
    Ok(())
}

#[test]
fn code_current_rejects_expired_snapshot() -> Result<()> {
    let artifact_dir = make_test_dir("expired")?;
    let path = artifact_dir.join("connection-code-latest.json");
    let expires_at = (OffsetDateTime::now_utc() - time::Duration::minutes(5))
        .format(&time::format_description::well_known::Rfc3339)?;
    fs::write(
        &path,
        serde_json::to_string(&json!({
            "schemaVersion": 1,
            "code": "SB-OLD-CODE",
            "sessionId": "SESSION-OLD",
            "expiresAt": expires_at,
        }))?,
    )?;

    let error = read_connection_code_snapshot(&path).unwrap_err();

    assert!(error.to_string().contains("expired"));
    Ok(())
}

#[test]
fn code_current_rejects_missing_incomplete_and_invalid_snapshot() -> Result<()> {
    let artifact_dir = make_test_dir("invalid")?;
    let missing = artifact_dir.join("missing.json");
    let missing_error = read_connection_code_snapshot(&missing).unwrap_err();
    assert!(missing_error.to_string().contains("unavailable"));

    let incomplete = artifact_dir.join("incomplete.json");
    fs::write(
        &incomplete,
        serde_json::to_string(&json!({
            "schemaVersion": 1,
            "code": "",
            "sessionId": "SESSION-INCOMPLETE",
        }))?,
    )?;
    let incomplete_error = read_connection_code_snapshot(&incomplete).unwrap_err();
    assert!(incomplete_error.to_string().contains("incomplete"));

    let malformed = artifact_dir.join("malformed.json");
    fs::write(&malformed, "{not-json")?;
    let malformed_error = read_connection_code_snapshot(&malformed).unwrap_err();
    assert!(malformed_error.to_string().contains("malformed"));

    let invalid_expiry = artifact_dir.join("invalid-expiry.json");
    fs::write(
        &invalid_expiry,
        serde_json::to_string(&json!({
            "schemaVersion": 1,
            "code": "SB-INVALID-EXPIRY",
            "sessionId": "SESSION-INVALID-EXPIRY",
            "expiresAt": "not-rfc3339",
        }))?,
    )?;
    let invalid_expiry_error = read_connection_code_snapshot(&invalid_expiry).unwrap_err();
    assert!(
        invalid_expiry_error
            .to_string()
            .contains("invalid expires_at")
    );
    Ok(())
}
