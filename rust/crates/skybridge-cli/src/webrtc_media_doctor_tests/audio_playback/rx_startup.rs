use super::*;

#[test]
fn doctor_webrtc_media_detects_zero_rx_after_playback() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-zero-rx")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION4.log"),
        "\
stream-stats session=SESSION4 fps=21.0
audio event session=SESSION4 audioTxCaptured=20 audioTxEncoded=20 audioTxSent=20 audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10
audio-rx session=SESSION4 audioRxRecv=0 audioRxDecoded=0 audioRxPlayed=0
native-video-health session=SESSION4 state=active
",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION4".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 20.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION4",
    )?;

    assert_eq!(report.fault_stage, Some("audio_rx_relay_recv"));
    assert!(!doctor_check(&report, "audio_rx_recv").ok);
    Ok(())
}

#[test]
fn doctor_webrtc_media_ignores_audio_rx_no_positive_heartbeat_placeholder() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-rx-placeholder")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION4B.log"),
        "\
stream-stats session=SESSION4B fps=31.0
native-video-health session=SESSION4B state=rtpFlowing submitted=120 framesSent=120 packetsSent=240 bytesSent=4096
native-receiver-frame session=SESSION4B size=2056x1329 visibleSize=2056x1329 codedSize=2056x1329 source=receiver-stats
	native-render-frame session=SESSION4B size=2056x1329 visibleSize=2056x1329 codedSize=2056x1329 source=rtc-mtl-video-view nativeRenderEvidenceSource=rtc-mtl-video-view nativePromotionState=visible-render-evidence uiSurface=remoteDesktopView
audio event session=SESSION4B audioTxCaptured=20 audioTxEncoded=20 audioTxSent=20 audioRxRecv=10 audioRxDecoded=10 audioRxPlayed=10 recvTotal=10 decodeTotal=10 playTotal=10 renderedFrames=9600
audio-rx session=SESSION4B source=remote-heartbeat audioRxDatagrams=0 audioRxRecv=0 audioRxDecoded=0 audioRxPlayed=0 recvTotal=0 decodeTotal=0 playTotal=0 rejected=0 jitterEvicted=0 playbackDrop=0 renderedFrames=- underflow=- rebuffer=- probable=audio-rx-no-positive-evidence
audio event session=SESSION4B audioTxCaptured=20 audioTxEncoded=20 audioTxSent=20 audioRxRecv=12 audioRxDecoded=12 audioRxPlayed=12 recvTotal=22 decodeTotal=22 playTotal=22 renderedFrames=19200
",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION4B".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION4B",
    )?;

    assert!(doctor_check(&report, "audio_rx_recv").ok);
    assert!(doctor_check(&report, "audio_rx_decoded").ok);
    assert!(doctor_check(&report, "audio_rx_played").ok);
    assert!(doctor_check(&report, "audio_playback_continuity").ok);
    assert_eq!(report.fault_stage, None);
    ensure_webrtc_media_doctor_passed(&report)?;
    Ok(())
}
