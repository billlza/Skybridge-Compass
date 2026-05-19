use super::*;

#[test]
fn doctor_webrtc_media_detects_relay_bind_ack_timeout() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-relay-bind-timeout")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION7.jsonl"),
        json!({
            "kind": "audioRxRelayBind",
            "session_id": "SESSION7",
            "stage": "relayBindAckTimedOut",
            "probable": "public-udp-relay-unreachable-or-wrong-port"
        })
        .to_string(),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION7".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 20.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION7",
    )?;

    assert_eq!(report.fault_stage, Some("audio_rx_relay_recv"));
    assert!(!doctor_check(&report, "audio_relay_startup").ok);
    assert!(
        doctor_check(&report, "audio_relay_startup")
            .detail
            .contains("relayBindAckTimedOut")
    );
    Ok(())
}

#[test]
fn doctor_webrtc_media_does_not_mask_sent_audio_with_late_bind_warning() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-tx-sent-after-bind-warning")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION8.log"),
        "\
audioTxRelayBindTimedOut session=SESSION8 leaseSource=viewerEndpoint endpoint=82.156.225.30:3478 token=present
audioTxStartup session=SESSION8 audioTxCaptured=20 audioTxEncoded=20 audioTxSent=20
audio-rx session=SESSION8 audioRxRecv=0 audioRxDecoded=0 audioRxPlayed=0
stream-stats session=SESSION8 fps=21.0
",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION8".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 20.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION8",
    )?;

    assert_eq!(report.fault_stage, Some("audio_tx_relay_bind"));
    assert!(!doctor_check(&report, "audio_relay_startup").ok);
    assert!(
        doctor_check(&report, "audio_relay_startup")
            .detail
            .contains("receiver has no audio")
    );
    Ok(())
}

#[test]
fn doctor_webrtc_media_flags_optimistic_tx_bind_pending_when_rx_is_zero() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-tx-bind-pending-rx-zero")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION18.jsonl"),
        [
            json!({
                "kind": "audioTxRelayBindAckPending",
                "session_id": "SESSION18",
                "probable": "relay-bind-ack-pending-media-optimistic"
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION18",
                "audioTxCaptured": 250,
                "audioTxEncoded": 250,
                "audioTxSent": 250,
                "audioTxCapturedTotal": 250,
                "audioTxEncodedTotal": 250,
                "audioTxSentTotal": 250,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxStartup",
                "session_id": "SESSION18",
                "audioRxDatagrams": 0,
                "audioRxRecv": 0,
                "audioRxDecoded": 0,
                "audioRxPlayed": 0,
                "recvTotal": 0,
                "decodeTotal": 0,
                "playTotal": 0
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION18".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION18",
    )?;

    assert_eq!(report.fault_stage, Some("audio_tx_relay_bind"));
    assert!(!doctor_check(&report, "audio_relay_startup").ok);
    assert!(
        doctor_check(&report, "audio_relay_startup")
            .detail
            .contains("relay bind ACK is still pending")
    );
    Ok(())
}
