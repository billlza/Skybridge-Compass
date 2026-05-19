use super::*;

#[test]
fn doctor_webrtc_media_rejects_rx_startup_native_fallback_resilience() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-startup-resilience")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION5.jsonl"),
        [
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION5",
                "audioRxRecv": 1,
                "audioRxDecoded": 0,
                "audioRxPlayed": 0,
                "recvTotal": 1,
                "decodeTotal": 0,
                "playTotal": 0,
                "renderedFrames": 0,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION5",
                "audioRxRecv": 246,
                "audioRxDecoded": 237,
                "audioRxPlayed": 237,
                "recvTotal": 247,
                "decodeTotal": 237,
                "playTotal": 237,
                "renderedFrames": 113760,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION5",
                "audioRxRecv": 250,
                "audioRxDecoded": 250,
                "audioRxPlayed": 250,
                "recvTotal": 497,
                "decodeTotal": 487,
                "playTotal": 487,
                "renderedFrames": 120000,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION5",
                "audioTxCaptured": 327,
                "audioTxEncoded": 179,
                "audioTxSent": 179,
                "audioTxCapturedTotal": 327,
                "audioTxEncodedTotal": 179,
                "audioTxSentTotal": 179,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION5",
                "audioTxCaptured": 250,
                "audioTxEncoded": 250,
                "audioTxSent": 250,
                "audioTxCapturedTotal": 577,
                "audioTxEncodedTotal": 429,
                "audioTxSentTotal": 429,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "nativeVideoRetry",
                "session_id": "SESSION5",
                "nativeVideoHealth": "failedNoRTP",
                "fallbackProducer": "sckLatest",
                "probable": "native-video-stalled-fast-retry"
            })
            .to_string(),
            json!({
                "kind": "videoStats",
                "session_id": "SESSION5",
                "video_fps": 20.2,
                "fallbackProducer": "sckLatest",
                "nativeVideoHealth": "recovering",
                "droppedBackpressure": 0
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION5".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 20.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION5",
    )?;

    assert!(doctor_check(&report, "video_fps").ok);
    assert!(doctor_check(&report, "audio_rx_decoded").ok);
    assert!(doctor_check(&report, "audio_rx_played").ok);
    assert!(doctor_check(&report, "audio_rendered_frames").ok);
    assert!(doctor_check(&report, "audio_activity_continuity").ok);
    assert!(doctor_check(&report, "audio_playback_continuity").ok);
    assert!(!doctor_check(&report, "native_video_health").ok);
    assert!(!doctor_check(&report, "stale_fallback").ok);
    assert!(!doctor_check(&report, "probable_fault_stage").ok);
    assert!(report.fault_stage.is_some());
    Ok(())
}
