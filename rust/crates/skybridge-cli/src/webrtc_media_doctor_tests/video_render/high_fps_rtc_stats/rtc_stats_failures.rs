use super::*;

#[test]
fn doctor_webrtc_media_high_fps_rejects_missing_native_rtc_stats() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-high-fps-missing-rtc")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION60_MISSING.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION60_MISSING",
                "video_fps": 60.0,
                "nativeVideoHealth": "rtpFlowing",
                "submitted": 120,
                "framesSent": 117,
                "packetsSent": 820,
                "bytesSent": 1_920_000
            })
            .to_string(),
            json!({
                "kind": "remoteVideoFrameEvidence",
                "session_id": "SESSION60_MISSING",
                "source": "receiver-stats",
                "packets": 790,
                "bytes": 1_810_000,
                "framesReceived": 110,
                "framesDecoded": 108,
                "size": "2056x1330",
                "visibleSize": "2056x1329",
                "codedSize": "2056x1330"
            })
            .to_string(),
            json!({
                "kind": "nativeRenderFrame",
                "session_id": "SESSION60_MISSING",
                "source": "rtc-mtl-video-view",
                "nativeRenderEvidenceSource": "rtc-mtl-video-view",
                "uiSurface": "remoteDesktopView",
                "nativePromotionState": "visible-render-evidence",
                "size": "2056x1330",
                "visibleSize": "2056x1329",
                "codedSize": "2056x1330"
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report_with_video_requirements(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION60_MISSING".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 59.01,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION60_MISSING",
        2056,
        1329,
        true,
    )?;

    assert!(doctor_check(&report, "video_fps").ok);
    assert!(doctor_check(&report, "native_video_health").ok);
    assert!(!doctor_check(&report, "native_video_rtc_stats").ok);
    assert!(
        doctor_check(&report, "native_video_rtc_stats")
            .detail
            .contains("high-fps missing codec,encoder,targetBitrate/availableOutgoingBitrate,encoded/sent/rtp counters")
    );
    assert!(doctor_check(&report, "native_video_receiver").ok);
    assert!(doctor_check(&report, "visible_native_render").ok);
    assert!(doctor_check(&report, "video_resolution").ok);
    assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
    Ok(())
}

#[test]
fn doctor_webrtc_media_high_fps_rejects_non_hardware_encoder() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-high-fps-software-encoder")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION60_SOFTWARE.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION60_SOFTWARE",
                "video_fps": 60.0,
                "nativeVideoHealth": "rtpFlowing",
                "submitted": 120,
                "framesEncoded": 118,
                "framesSent": 117,
                "keyFramesEncoded": 2,
                "packetsSent": 820,
                "bytesSent": 1_920_000,
                "codec": "video/H264",
                "encoder": "libx264",
                "qualityLimit": "none",
                "encodeWidth": 2056,
                "encodeHeight": 1330,
                "encodeFPS": 60,
                "targetBitrate": 18_000_000,
                "availableOutgoingBitrate": 28_000_000
            })
            .to_string(),
            json!({
                "kind": "remoteVideoFrameEvidence",
                "session_id": "SESSION60_SOFTWARE",
                "source": "receiver-stats",
                "packets": 790,
                "bytes": 1_810_000,
                "framesReceived": 110,
                "framesDecoded": 108,
                "size": "2056x1330",
                "visibleSize": "2056x1329",
                "codedSize": "2056x1330"
            })
            .to_string(),
            json!({
                "kind": "nativeRenderFrame",
                "session_id": "SESSION60_SOFTWARE",
                "source": "rtc-mtl-video-view",
                "nativeRenderEvidenceSource": "rtc-mtl-video-view",
                "uiSurface": "remoteDesktopView",
                "nativePromotionState": "visible-render-evidence",
                "size": "2056x1330",
                "visibleSize": "2056x1329",
                "codedSize": "2056x1330"
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report_with_video_requirements(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION60_SOFTWARE".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 59.01,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION60_SOFTWARE",
        2056,
        1329,
        true,
    )?;

    assert!(doctor_check(&report, "video_fps").ok);
    assert!(doctor_check(&report, "native_video_health").ok);
    assert!(!doctor_check(&report, "native_video_rtc_stats").ok);
    assert!(
        doctor_check(&report, "native_video_rtc_stats")
            .detail
            .contains("high-fps missing hardwareEncoder")
    );
    assert!(doctor_check(&report, "native_video_receiver").ok);
    assert!(doctor_check(&report, "visible_native_render").ok);
    assert!(doctor_check(&report, "video_resolution").ok);
    assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
    Ok(())
}
