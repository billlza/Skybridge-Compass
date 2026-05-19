use super::*;

#[test]
fn doctor_webrtc_media_video_only_accepts_native_rtp_without_audio() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-video-only-native")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION9.log"),
        "\
native-video-health session=SESSION9 state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9 state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/VP8 encoder=libvpx
native-receiver-frame session=SESSION9 size=1280x826 source=receiver-stats packets=23 bytes=22298 framesReceived=1 framesDecoded=1
audioTxUnavailable session=SESSION9 reason=missingViewerEndpoint mediaSession=SESSION9
",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION9".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION9",
    )?;

    assert!(doctor_check(&report, "video_fps").ok);
    assert!(
        doctor_check(&report, "video_fps")
            .detail
            .contains("native RTP is flowing")
    );
    assert!(doctor_check(&report, "native_video_health").ok);
    assert!(doctor_check(&report, "native_video_receiver").ok);
    assert!(doctor_check_optional(&report, "audio_relay_startup").is_none());
    assert!(doctor_check_optional(&report, "audio_tx_sent").is_none());
    assert!(doctor_check(&report, "probable_fault_stage").ok);
    assert!(report.fault_stage.is_none());
    Ok(())
}
