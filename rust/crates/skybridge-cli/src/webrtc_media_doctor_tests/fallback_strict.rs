use super::*;

#[test]
fn doctor_webrtc_media_flags_low_fps_fallback_producer() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-low-fps-fallback")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION8.log"),
        "\
stream-stats session=SESSION8 fps=0.8 fallbackProducer=cgdisplayEmergency cgdisplayCaptureFPS=0.4 directEncodedFPS=0.6
fallbackProducerSwitch session=SESSION8 producer=cgdisplayEmergency reason=sck-latest-stale-or-missing sckLatestAgeMs=1200 holdMs=10000
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

    assert_eq!(report.fault_stage, Some("fallback_capture_stalled"));
    assert!(!doctor_check(&report, "video_fps").ok);
    assert!(!doctor_check(&report, "stale_fallback").ok);
    Ok(())
}

#[test]
fn doctor_webrtc_media_fails_strict_media_failure() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-strict-failed")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION19.log"),
        "\
native-video-health session=SESSION19 state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION19 state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/VP8 encoder=libvpx
remote-video-frame-evidence session=SESSION19 source=receiver-stats type=inbound-rtp packets=23 bytes=22298 framesReceived=1 framesDecoded=1 size=1280x826
strict-media-failed session=SESSION19 reason=fallback-screen-frame-received format=jpeg size=1280x826
",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION19".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION19",
    )?;

    assert_eq!(report.fault_stage, Some("strict_media_failure"));
    assert!(!doctor_check(&report, "strict_media_failure").ok);
    assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
    Ok(())
}

#[test]
fn doctor_webrtc_media_fails_structured_strict_media_failure() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-structured-strict-failed")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION20.jsonl"),
        [
            json!({
                "kind": "nativeVideoHealth",
                "session_id": "SESSION20",
                "nativeVideoHealth": "rtpFlowing",
                "submitted": 54,
                "framesSent": 48,
                "packetsSent": 269,
                "bytesSent": 269590
            })
            .to_string(),
            json!({
                "kind": "remoteVideoFrameEvidence",
                "session_id": "SESSION20",
                "source": "receiver-stats",
                "packets": 23,
                "bytes": 22298,
                "framesReceived": 1,
                "framesDecoded": 1,
                "size": "1280x826"
            })
            .to_string(),
            json!({
                "kind": "strictMediaFailure",
                "session_id": "SESSION20",
                "probable": "fallback-screen-frame",
                "validationMode": "strict",
                "failureReason": "fallback-screen-frame-received"
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION20".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION20",
    )?;

    assert_eq!(report.fault_stage, Some("strict_media_failure"));
    assert!(
        doctor_check(&report, "strict_media_failure")
            .detail
            .contains("fallback-screen-frame-received")
    );
    assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
    Ok(())
}
