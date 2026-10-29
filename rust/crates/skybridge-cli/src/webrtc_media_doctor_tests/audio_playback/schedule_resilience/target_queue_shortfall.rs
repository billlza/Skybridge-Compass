use super::*;

#[test]
fn doctor_webrtc_media_allows_high_target_queue_schedule_shortfall() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-audio-target-shortfall")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION19B.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION19B",
                "video_fps": 32.0,
                "nativeVideoHealth": "rtpFlowing"
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION19B",
                "audioTxCaptured": 250,
                "audioTxEncoded": 250,
                "audioTxSent": 250,
                "audioTxCapturedTotal": 250,
                "audioTxEncodedTotal": 250,
                "audioTxSentTotal": 250,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION19B",
                "audioTxCaptured": 250,
                "audioTxEncoded": 250,
                "audioTxSent": 250,
                "audioTxCapturedTotal": 500,
                "audioTxEncodedTotal": 500,
                "audioTxSentTotal": 500,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION19B",
                "audioRxRecv": 250,
                "audioRxDecoded": 250,
                "audioRxPlayed": 250,
                "recvTotal": 250,
                "decodeTotal": 250,
                "playTotal": 250,
                "renderedFrames": 240000,
                "jitterLate": 0,
                "plcFrames": 0,
                "plcRatio": 0,
                "audioQueuedMs": 2370.0,
                "audioTargetQueuedMs": 2340.0,
                "scheduleLeadMs": 30.0,
                "audioArrivalP95Ms": 70.0,
                "audioArrivalMaxMs": 103.0,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0,
                "jitterEvicted": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION19B",
                "audioRxRecv": 249,
                "audioRxDecoded": 245,
                "audioRxPlayed": 246,
                "recvTotal": 499,
                "decodeTotal": 495,
                "playTotal": 496,
                "renderedFrames": 240480,
                "jitterLate": 0,
                "plcFrames": 1,
                "plcRatio": 0.004,
                "audioQueuedMs": 2155.0,
                "audioTargetQueuedMs": 2340.0,
                "scheduleLeadMs": -185.0,
                "audioArrivalP95Ms": 56.0,
                "audioArrivalMaxMs": 170.0,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0,
                "jitterEvicted": 0
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION19B".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION19B",
    )?;

    assert!(doctor_check(&report, "audio_playback_continuity").ok);
    assert_ne!(report.fault_stage, Some("audio_rx_playback"));
    Ok(())
}
