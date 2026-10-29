use super::*;

#[test]
fn doctor_webrtc_media_plain_log_reports_media_failures() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-plain")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION1.log"),
        "\
stream-stats session=SESSION1 fps=1.5 screenBuffered=900000 fallbackProducer=cgdisplayEmergency dropReason=backpressure droppedBackpressure=2
audioTxStartup session=SESSION1 audioTxCaptured=0 audioTxEncoded=0 audioTxSent=0
audio-rx session=SESSION1 audioRxRecv=0 audioRxDecoded=0 audioRxPlayed=0
native-video-health session=SESSION1 state=failedNoRTP fallbackMode=main
fallbackProducerSwitch session=SESSION1 producer=cgdisplayEmergency reason=sck-latest-stale-or-missing sckLatestAgeMs=- holdMs=10000
",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION1".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 20.0,
            require_audio: true,
            output: OutputOptions { json: false },
        },
        "SESSION1",
    )?;

    assert!(!doctor_check(&report, "video_fps").ok);
    assert_eq!(doctor_check(&report, "video_fps").severity, "error");
    assert!(!doctor_check(&report, "audio_tx_captured").ok);
    assert!(!doctor_check(&report, "audio_tx_encoded").ok);
    assert!(!doctor_check(&report, "audio_tx_sent").ok);
    assert!(!doctor_check(&report, "audio_rx_recv").ok);
    assert!(!doctor_check(&report, "audio_rx_decoded").ok);
    assert!(!doctor_check(&report, "audio_rx_played").ok);
    assert!(!doctor_check(&report, "native_video_health").ok);
    assert_eq!(report.fault_stage, Some("audio_tx_capture"));
    assert_eq!(
        doctor_check(&report, "native_video_health").severity,
        "error"
    );
    assert!(!doctor_check(&report, "stale_fallback").ok);
    assert!(!doctor_check(&report, "backpressure").ok);
    Ok(())
}
