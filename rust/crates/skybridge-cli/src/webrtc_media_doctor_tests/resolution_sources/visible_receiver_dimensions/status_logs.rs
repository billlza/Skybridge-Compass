use super::*;

#[test]
fn doctor_webrtc_media_accepts_periodic_visible_receiver_dimensions_without_counters() -> Result<()>
{
    let artifact_dir = make_test_dir("doctor-webrtc-media-visible-status-resolution")?;
    std::fs::write(
        artifact_dir.join("ios-real-webrtc.status.log"),
        "\
native-receiver-frame session=SESSION9_VISIBLE_STATUS size=2056x1329 visibleSize=2056x1329 codedSize=2056x1330 evenPadding=1 visibleSource=inferred-even-padding-from-stream-config source=receiver-stats
",
    )?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "\
native-video-health session=SESSION9_VISIBLE_STATUS state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION9_VISIBLE_STATUS state=rtpFlowing submitted=120 framesSent=118 packetsSent=640 bytesSent=755000 codec=video/H264 encoder=VideoToolbox encodeSize=2056x1330
",
    )?;

    let report = build_webrtc_media_doctor_report_with_video_requirements(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION9_VISIBLE_STATUS".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION9_VISIBLE_STATUS",
        2056,
        1329,
        true,
    )?;

    assert!(doctor_check(&report, "native_video_receiver").ok);
    assert!(doctor_check(&report, "video_resolution").ok);
    assert!(
        doctor_check(&report, "native_video_receiver")
            .detail
            .contains("visible dimensions observed")
    );
    Ok(())
}

#[test]
fn doctor_webrtc_media_reads_mac_status_log_for_live_gate_heartbeats() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-mac-status")?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "\
native-video-tx session=SESSION_MAC_STATUS state=rtpFlowing fallbackMode=main submitted=120 framesEncoded=118 framesSent=118 packetsSent=640 bytesSent=755000 codec=video/H264 encoder=VideoToolbox qualityLimit=none encodeSize=2056x1330 encodeFPS=32 targetBitrate=9443000 availableOutgoingBitrate=9443257
native-receiver-frame session=SESSION_MAC_STATUS size=2056x1329 visibleSize=2056x1329 codedSize=2056x1330 evenPadding=1 visibleSource=inferred-even-padding-from-stream source=remote-heartbeat
native-render-frame session=SESSION_MAC_STATUS size=2056x1329 visibleSize=2056x1329 codedSize=2056x1329 source=rtc-mtl-video-view nativeRenderEvidenceSource=rtc-mtl-video-view nativePromotionState=remote-heartbeat
",
    )?;

    let report = build_webrtc_media_doctor_report_for_gate(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION_MAC_STATUS".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION_MAC_STATUS",
        2056,
        1329,
        true,
        true,
        None,
    )?;

    assert!(report.target.contains("mac.status.log"));
    assert!(doctor_check(&report, "video_fps").ok);
    assert!(doctor_check(&report, "native_video_rtc_stats").ok);
    assert!(doctor_check(&report, "native_video_receiver").ok);
    assert!(!doctor_check(&report, "visible_native_render").ok);
    assert!(!doctor_check(&report, "visible_render_fps").ok);
    assert!(doctor_check(&report, "video_resolution").ok);
    assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
    Ok(())
}
