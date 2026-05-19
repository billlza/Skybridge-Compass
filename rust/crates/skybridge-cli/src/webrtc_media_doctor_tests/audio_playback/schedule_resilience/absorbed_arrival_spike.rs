use super::*;

#[test]
fn doctor_webrtc_media_allows_absorbed_arrival_spike() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-absorbed-arrival-spike")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION19D.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION19D",
                "video_fps": 32.0,
                "nativeVideoHealth": "rtpFlowing"
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION19D",
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
                "session_id": "SESSION19D",
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
                "session_id": "SESSION19D",
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
                "audioQueuedMs": 2380.0,
                "audioTargetQueuedMs": 2340.0,
                "scheduleLeadMs": 40.0,
                "audioArrivalP95Ms": 75.0,
                "audioArrivalMaxMs": 672.0,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0,
                "jitterEvicted": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION19D",
                "audioRxRecv": 250,
                "audioRxDecoded": 250,
                "audioRxPlayed": 250,
                "recvTotal": 500,
                "decodeTotal": 500,
                "playTotal": 500,
                "renderedFrames": 240000,
                "jitterLate": 0,
                "plcFrames": 0,
                "plcRatio": 0,
                "audioQueuedMs": 2380.0,
                "audioTargetQueuedMs": 2340.0,
                "scheduleLeadMs": 40.0,
                "audioArrivalP95Ms": 80.0,
                "audioArrivalMaxMs": 136.0,
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
            session_id: Some("SESSION19D".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION19D",
    )?;

    assert!(doctor_check(&report, "audio_playback_continuity").ok);
    assert!(doctor_check(&report, "audio_activity_continuity").ok);
    assert_ne!(report.fault_stage, Some("audio_rx_playback"));
    Ok(())
}
