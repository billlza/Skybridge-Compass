use anyhow::Result;

use crate::OutputOptions;
use crate::cli_test_support::{make_test_dir, spawn_mock_server};

#[tokio::test]
async fn doctor_wrappers_cover_control_plane_and_webrtc_entrypoints() -> Result<()> {
    let base_url = spawn_mock_server(vec![
        (
            "GET",
            "/",
            200,
            serde_json::json!({
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
            serde_json::json!({
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
            serde_json::json!({
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
            serde_json::json!({
                "error": "missing_turn_admission",
                "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456"
            }),
        ),
        (
            "POST",
            "/api/media/lease",
            401,
            serde_json::json!({
                "error": "missing_media_admission",
                "rejectReason": "missingToken",
                "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456"
            }),
        ),
    ])?;

    crate::doctor_commands::doctor_signaling(crate::SignalingDoctorArgs {
        base_url: Some(base_url),
        allow_insecure_loopback: true,
        expected_backend: Some("redis".to_owned()),
        output: OutputOptions { json: true },
    })
    .await?;

    let lease_url = spawn_mock_server(vec![
        (
            "GET",
            "/health",
            200,
            serde_json::json!({
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
            serde_json::json!({
                "error": "media_admission_token_superseded",
                "serverBuildFingerprint": "skybridge-signaling/20260501164000-abcdef123456",
                "mediaTokenState": "revoked",
                "mediaTokenRevokedReason": "remote_kill",
                "mediaTokenSessionRejectReason": "remote_kill",
                "rejectReason": "remote_kill"
            }),
        ),
    ])?;
    crate::doctor_commands::doctor_media_lease(crate::MediaLeaseDoctorArgs {
        base_url: Some(lease_url),
        allow_insecure_loopback: true,
        session_id: Some("SESSION1".to_owned()),
        media_admission_token: Some("token".to_owned()),
        output: OutputOptions { json: true },
    })
    .await?;

    let artifact_dir = make_test_dir("main-webrtc-wrapper")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION9.log"),
        "\
native-video-health session=SESSION9 state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9 state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/VP8 encoder=libvpx
native-receiver-frame session=SESSION9 size=1280x826 source=receiver-stats packets=23 bytes=22298 framesReceived=1 framesDecoded=1
audioTxUnavailable session=SESSION9 reason=missingViewerEndpoint mediaSession=SESSION9
",
    )?;
    let doctor_args = crate::WebRtcMediaDoctorArgs {
        session_id: Some("SESSION9".to_owned()),
        latest: false,
        artifact_dir: Some(artifact_dir.clone()),
        log_file: None,
        since_seconds: 120,
        min_fps: 1.0,
        require_audio: false,
        output: OutputOptions { json: true },
    };
    crate::doctor_commands::doctor_webrtc_media(doctor_args).await?;
    crate::doctor_commands::diagnose_webrtc_media(crate::WebRtcMediaDiagnoseArgs {
        session_id: Some("SESSION9".to_owned()),
        latest: false,
        artifact_dir: Some(artifact_dir),
        log_file: None,
        since_seconds: 120,
        min_fps: 1.0,
        require_audio: false,
        output: OutputOptions { json: true },
    })
    .await?;

    Ok(())
}
