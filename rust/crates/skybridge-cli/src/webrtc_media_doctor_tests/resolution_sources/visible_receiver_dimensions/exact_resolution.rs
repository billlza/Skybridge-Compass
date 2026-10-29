use super::*;

#[test]
fn doctor_webrtc_media_accepts_explicit_visible_resolution_with_even_coded_padding() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-visible-crop-resolution")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION9_VISIBLE.log"),
        "\
native-video-health session=SESSION9_VISIBLE state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_VISIBLE state=rtpFlowing submitted=120 framesSent=118 packetsSent=640 bytesSent=755000 codec=video/H264 encoder=VideoToolbox encodeSize=2056x1330
native-receiver-frame session=SESSION9_VISIBLE size=2056x1329 visibleSize=2056x1329 codedSize=2056x1330 evenPadding=1 source=receiver-stats packets=606 bytes=689351 framesReceived=31 framesDecoded=24
visibleNativeRenderFPS session=SESSION9_VISIBLE viewerDisplayFPS=59.8 visibleWidth=2056 visibleHeight=1330 source=rtc-mtl-video-view uiSurface=remoteDesktopView metricSource=rtc-mtl-render-frame renderPipeline=webrtcNativeVideo
remote-video-frame-evidence session=SESSION9_VISIBLE source=receiver-stats type=inbound-rtp packets=900 bytes=900000 framesReceived=80 framesDecoded=80 size=2056x1330
",
    )?;

    let report = build_webrtc_media_doctor_report_with_video_requirements(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION9_VISIBLE".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION9_VISIBLE",
        2056,
        1329,
        true,
    )?;

    assert!(doctor_check(&report, "native_video_receiver").ok);
    assert!(doctor_check(&report, "video_resolution").ok);
    assert!(
        doctor_check(&report, "native_video_receiver")
            .detail
            .contains("codedSize=2056x1330")
    );
    Ok(())
}

#[test]
fn doctor_webrtc_media_rejects_visible_receiver_mismatch_even_when_render_matches() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-visible-receiver-mismatch")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION9_VISIBLE_MISMATCH.log"),
        "\
native-video-health session=SESSION9_VISIBLE_MISMATCH state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_VISIBLE_MISMATCH state=rtpFlowing submitted=120 framesSent=118 packetsSent=640 bytesSent=755000 codec=video/H264 encoder=VideoToolbox encodeSize=2056x1330
native-receiver-frame session=SESSION9_VISIBLE_MISMATCH size=2056x1328 visibleSize=2056x1328 codedSize=2056x1330 evenPadding=1 source=receiver-stats packets=606 bytes=689351 framesReceived=31 framesDecoded=24
visibleNativeRenderFPS session=SESSION9_VISIBLE_MISMATCH viewerDisplayFPS=59.8 visibleWidth=2056 visibleHeight=1329 source=rtc-mtl-video-view uiSurface=remoteDesktopView metricSource=rtc-mtl-render-frame renderPipeline=webrtcNativeVideo
",
    )?;

    let report = build_webrtc_media_doctor_report_with_video_requirements(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION9_VISIBLE_MISMATCH".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION9_VISIBLE_MISMATCH",
        2056,
        1329,
        true,
    )?;

    assert!(!doctor_check(&report, "video_resolution").ok);
    assert!(
        doctor_check(&report, "video_resolution")
            .detail
            .contains("2056x1328 do not match exact target 2056x1329")
    );
    Ok(())
}

#[test]
fn doctor_webrtc_media_rejects_receiver_resolution_below_exact_target() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-exact-resolution-low")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION9_LOW.log"),
        "\
native-video-health session=SESSION9_LOW state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_LOW state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/H264 encoder=VideoToolbox
remote-video-frame-evidence session=SESSION9_LOW source=receiver-stats type=inbound-rtp packets=240 bytes=254291 framesReceived=32 framesDecoded=32 size=2056x1328
",
    )?;

    let report = build_webrtc_media_doctor_report_with_video_requirements(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION9_LOW".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION9_LOW",
        2056,
        1329,
        true,
    )?;

    assert!(!doctor_check(&report, "video_resolution").ok);
    assert!(
        doctor_check(&report, "video_resolution")
            .detail
            .contains("2056x1328 do not match exact target 2056x1329")
    );
    assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
    Ok(())
}
