use super::*;

#[test]
fn doctor_webrtc_media_rejects_receiver_resolution_below_strict_target() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-strict-resolution")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION9_SIZE.log"),
        "\
native-video-health session=SESSION9_SIZE state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_SIZE state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/H264 encoder=VideoToolbox
remote-video-frame-evidence session=SESSION9_SIZE source=receiver-stats type=inbound-rtp packets=240 bytes=254291 framesReceived=32 framesDecoded=32 size=960x620
",
    )?;

    let report = build_webrtc_media_doctor_report_with_video_requirements(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION9_SIZE".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION9_SIZE",
        2056,
        1329,
        false,
    )?;

    assert!(!doctor_check(&report, "video_resolution").ok);
    assert!(
        doctor_check(&report, "video_resolution")
            .detail
            .contains("960x620 below minimum 2056x1329")
    );
    assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
    Ok(())
}

#[test]
fn doctor_webrtc_media_rejects_receiver_resolution_above_exact_target() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-exact-resolution")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION9_EXACT.log"),
        "\
native-video-health session=SESSION9_EXACT state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_EXACT state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/H264 encoder=VideoToolbox
remote-video-frame-evidence session=SESSION9_EXACT source=receiver-stats type=inbound-rtp packets=240 bytes=254291 framesReceived=32 framesDecoded=32 size=2056x1330
",
    )?;

    let report = build_webrtc_media_doctor_report_with_video_requirements(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION9_EXACT".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION9_EXACT",
        2056,
        1329,
        true,
    )?;

    assert!(!doctor_check(&report, "video_resolution").ok);
    assert!(
        doctor_check(&report, "video_resolution")
            .detail
            .contains("2056x1330 do not match exact target 2056x1329")
    );
    assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
    Ok(())
}

#[test]
fn doctor_webrtc_media_rejects_exact_size_without_explicit_visible_evidence() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-exact-size-not-visible")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION9_SIZE_ONLY.log"),
        "\
native-video-health session=SESSION9_SIZE_ONLY state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_SIZE_ONLY state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/H264 encoder=VideoToolbox
remote-video-frame-evidence session=SESSION9_SIZE_ONLY source=receiver-stats type=inbound-rtp packets=240 bytes=254291 framesReceived=32 framesDecoded=32 size=2056x1329
",
    )?;

    let report = build_webrtc_media_doctor_report_with_video_requirements(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION9_SIZE_ONLY".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION9_SIZE_ONLY",
        2056,
        1329,
        true,
    )?;

    assert!(!doctor_check(&report, "video_resolution").ok);
    assert!(
        doctor_check(&report, "video_resolution")
            .detail
            .contains("not reported as explicit visible dimensions")
    );
    assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
    Ok(())
}
