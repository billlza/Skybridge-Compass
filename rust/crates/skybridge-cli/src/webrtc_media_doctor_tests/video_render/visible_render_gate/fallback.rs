use super::*;

#[test]
fn doctor_webrtc_media_rejects_fallback_visible_fps_and_screen_frames() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-rejects-fallback-visible-fps")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION_FALLBACK_FORBIDDEN.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION_FALLBACK_FORBIDDEN",
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
                "kind": "nativeRenderFrame",
                "session_id": "SESSION_FALLBACK_FORBIDDEN",
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
                "session_id": "SESSION_FALLBACK_FORBIDDEN",
                "source": "rtc-mtl-video-view",
                "renderPipeline": "sampleBufferDisplayLayer",
                "viewerDisplayFPS": 60.0,
                "displayFPS": 60.0,
                "visibleWidth": 2056,
                "visibleHeight": 1329
            })
            .to_string(),
            "stream-format session=SESSION_FALLBACK_FORBIDDEN format=jpeg channel=screen"
                .to_owned(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report_for_gate(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION_FALLBACK_FORBIDDEN".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION_FALLBACK_FORBIDDEN",
        2056,
        1329,
        true,
        true,
        None,
    )?;

    assert!(doctor_check(&report, "video_fps").ok);
    assert!(doctor_check(&report, "visible_native_render").ok);
    assert!(!doctor_check(&report, "visible_render_fps").ok);
    assert!(!doctor_check(&report, "stale_fallback").ok);
    assert!(
        doctor_check(&report, "stale_fallback")
            .detail
            .contains("forbidden WebRTC fallback")
    );
    Ok(())
}
