use super::*;

#[test]
fn doctor_webrtc_media_rejects_low_visible_render_fps() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-low-visible-render-fps")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION_VISIBLE_FPS_LOW.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION_VISIBLE_FPS_LOW",
                "video_fps": 60.0,
                "nativeVideoHealth": "rtpFlowing",
                "submitted": 180,
                "framesEncoded": 178,
                "framesSent": 177,
                "keyFramesEncoded": 2,
                "packetsSent": 1180,
                "bytesSent": 2_920_000,
                "codec": "video/H264",
                "encoder": "VideoToolbox",
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
                "session_id": "SESSION_VISIBLE_FPS_LOW",
                "source": "receiver-stats",
                "framesReceived": 170,
                "framesDecoded": 168,
                "size": "2056x1330",
                "visibleSize": "2056x1329",
                "codedSize": "2056x1330"
            })
            .to_string(),
            json!({
                "kind": "nativeRenderFrame",
                "session_id": "SESSION_VISIBLE_FPS_LOW",
                "source": "rtc-mtl-video-view",
                "nativeRenderEvidenceSource": "rtc-mtl-video-view",
                "uiSurface": "remoteDesktopView",
                "size": "2056x1329",
                "visibleSize": "2056x1329",
                "codedSize": "2056x1330",
                "nativePromotionState": "visible-render-evidence"
            })
            .to_string(),
            json!({
                "kind": "visibleNativeRenderFPS",
                "session_id": "SESSION_VISIBLE_FPS_LOW",
                "source": "rtc-mtl-video-view",
                "uiSurface": "remoteDesktopView",
                "metricSource": "rtc-mtl-render-frame",
                "renderPipeline": "webrtcNativeVideo",
                "viewerDisplayFPS": 3.0,
                "displayFPS": 3.0,
                "visibleWidth": 2056,
                "visibleHeight": 1329
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report_with_video_requirements(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION_VISIBLE_FPS_LOW".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION_VISIBLE_FPS_LOW",
        2056,
        1329,
        true,
    )?;

    assert!(doctor_check(&report, "video_fps").ok);
    assert!(doctor_check(&report, "visible_native_render").ok);
    assert!(!doctor_check(&report, "visible_render_fps").ok);
    assert!(
        doctor_check(&report, "visible_render_fps")
            .detail
            .contains("below min")
    );
    assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
    Ok(())
}
