use super::*;

#[test]
fn doctor_webrtc_media_detects_missing_viewer_audio_endpoint() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-missing-endpoint")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION6.log"),
        "\
stream-stats session=SESSION6 fps=21.0
streamConfigReceived session=SESSION6 audioRequested=true audioEndpoint=missing audioRelayToken=missing
audioTxUnavailable session=SESSION6 reason=missingViewerEndpoint mediaSession=-
native-video-health session=SESSION6 state=active
",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION6".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 20.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION6",
    )?;

    assert_eq!(report.fault_stage, Some("audio_tx_relay_send"));
    assert!(!doctor_check(&report, "audio_relay_startup").ok);
    assert!(
        doctor_check(&report, "audio_relay_startup")
            .detail
            .contains("missingViewerEndpoint")
    );
    Ok(())
}

#[test]
fn doctor_webrtc_media_detects_mac_tx_relay_bind_timeout_and_lease_limit() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-tx-relay-failure")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-W3MCEDC2X999ZKTU.log"),
        "\
audioTxEndpointReady session=W3MCEDC2X999ZKTU leaseSource=viewerEndpoint endpoint=82.156.225.30:3478 token=present mediaSession=W3MCEDC2X999ZKTU
audioTxUnavailable session=W3MCEDC2X999ZKTU reason=relayUnavailable error=media relay bind timed out
audioTxUnavailable session=W3MCEDC2X999ZKTU reason=leaseLimit error=信令服务器拒绝请求 (429): {\"error\":\"media_admission_token_lease_limit\"}
stream-stats session=W3MCEDC2X999ZKTU fps=0.8 fallbackProducer=sckLatest cgdisplayCaptureFPS=0.4 directEncodedFPS=0.6
",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("W3MCEDC2X999ZKTU".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 20.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "W3MCEDC2X999ZKTU",
    )?;

    assert_eq!(report.fault_stage, Some("audio_tx_relay_send"));
    assert!(!doctor_check(&report, "audio_relay_startup").ok);
    assert!(
        doctor_check(&report, "audio_relay_startup")
            .detail
            .contains("Mac sender failed to bind/send media relay")
    );
    Ok(())
}

#[test]
fn doctor_webrtc_media_prefers_latest_tx_relay_failure_over_missing_endpoint() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-tx-relay-priority")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-W3MCEDC2X999ZKTU.log"),
        "\
audioTxUnavailable session=W3MCEDC2X999ZKTU reason=missingViewerEndpoint mediaSession=-
audioTxEndpointReady session=W3MCEDC2X999ZKTU leaseSource=viewerEndpoint endpoint=82.156.225.30:3478 token=present mediaSession=W3MCEDC2X999ZKTU
audioTxUnavailable session=W3MCEDC2X999ZKTU reason=relayUnavailable error=media relay bind timed out
",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("W3MCEDC2X999ZKTU".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 20.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "W3MCEDC2X999ZKTU",
    )?;

    assert_eq!(report.fault_stage, Some("audio_tx_relay_send"));
    assert!(!doctor_check(&report, "audio_relay_startup").ok);
    assert!(
        doctor_check(&report, "audio_relay_startup")
            .detail
            .contains("relayBindTimedOut")
    );
    Ok(())
}
