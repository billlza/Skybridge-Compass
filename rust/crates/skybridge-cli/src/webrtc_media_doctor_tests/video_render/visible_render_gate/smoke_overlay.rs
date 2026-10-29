use super::*;

#[test]
fn doctor_webrtc_media_rejects_smoke_overlay_render_evidence() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-rejects-smoke-overlay")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION_SMOKE_OVERLAY.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION_SMOKE_OVERLAY",
                "video_fps": 60.0,
                "nativeVideoHealth": "rtpFlowing",
                "submitted": 180,
                "framesEncoded": 178,
                "framesSent": 177,
                "packetsSent": 1180,
                "bytesSent": 2_920_000,
                "codec": "video/H264",
                "encoder": "VideoToolbox",
                "qualityLimit": "none",
                "encodeFPS": 60,
                "targetBitrate": 18_000_000,
                "availableOutgoingBitrate": 28_000_000
            })
            .to_string(),
            json!({
                "kind": "remoteVideoFrameEvidence",
                "session_id": "SESSION_SMOKE_OVERLAY",
                "source": "receiver-stats",
                "framesReceived": 170,
                "framesDecoded": 168,
                "visibleSize": "2056x1329",
                "codedSize": "2056x1330"
            })
            .to_string(),
            json!({
                "kind": "nativeRenderFrame",
                "session_id": "SESSION_SMOKE_OVERLAY",
                "source": "rtc-mtl-video-view",
                "nativeRenderEvidenceSource": "rtc-mtl-video-view",
                "uiSurface": "smokeOverlay",
                "nativePromotionState": "smoke-hold",
                "visibleSize": "2056x1329",
                "codedSize": "2056x1330"
            })
            .to_string(),
            json!({
                "kind": "visibleNativeRenderFPS",
                "session_id": "SESSION_SMOKE_OVERLAY",
                "source": "rtc-mtl-video-view",
                "uiSurface": "smokeOverlay",
                "metricSource": "rtc-mtl-render-frame",
                "renderPipeline": "webrtcNativeVideo",
                "viewerDisplayFPS": 60.0,
                "displayFPS": 60.0
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report_for_gate(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION_SMOKE_OVERLAY".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION_SMOKE_OVERLAY",
        2056,
        1329,
        true,
        true,
        None,
    )?;

    assert!(!doctor_check(&report, "visible_native_render").ok);
    assert!(!doctor_check(&report, "visible_render_fps").ok);
    assert!(ensure_webrtc_media_doctor_passed(&report).is_err());
    Ok(())
}
