use super::*;

#[test]
fn doctor_webrtc_media_jsonl_reads_structured_diagnostics() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-jsonl")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION2.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION2",
                "video_fps": 18.5,
                "droppedBackpressure": 0
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "sessionId": "SESSION2",
                "audioTxCaptured": 12,
                "audioTxEncoded": 11,
                "audioTxSent": 10,
                "audioTxCapturedTotal": 12,
                "audioTxEncodedTotal": 11,
                "audioTxSentTotal": 10,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "sessionId": "SESSION2",
                "audioTxCaptured": 13,
                "audioTxEncoded": 13,
                "audioTxSent": 13,
                "audioTxCapturedTotal": 25,
                "audioTxEncodedTotal": 24,
                "audioTxSentTotal": 23,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "sessionId": "SESSION2",
                "audioRxRecv": 8,
                "audioRxDecoded": 8,
                "audioRxPlayed": 7,
                "recvTotal": 8,
                "decodeTotal": 8,
                "playTotal": 7,
                "renderedFrames": 3360,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "sessionId": "SESSION2",
                "audioRxRecv": 9,
                "audioRxDecoded": 9,
                "audioRxPlayed": 9,
                "recvTotal": 17,
                "decodeTotal": 17,
                "playTotal": 16,
                "renderedFrames": 4320,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
            json!({
                "event": "native-video-tx",
                "sessionId": "SESSION2",
                "nativeVideoHealth": "active"
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION2".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 20.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION2",
    )?;

    assert!(!doctor_check(&report, "video_fps").ok);
    assert_eq!(doctor_check(&report, "video_fps").severity, "warn");
    assert!(doctor_check(&report, "audio_tx_captured").ok);
    assert!(doctor_check(&report, "audio_tx_encoded").ok);
    assert!(doctor_check(&report, "audio_tx_sent").ok);
    assert!(doctor_check(&report, "audio_rx_recv").ok);
    assert!(doctor_check(&report, "audio_rx_decoded").ok);
    assert!(doctor_check(&report, "audio_rx_played").ok);
    assert!(doctor_check(&report, "audio_rendered_frames").ok);
    assert!(doctor_check(&report, "audio_activity_continuity").ok);
    assert!(doctor_check(&report, "audio_playback_continuity").ok);
    assert!(doctor_check(&report, "native_video_health").ok);
    assert!(doctor_check(&report, "stale_fallback").ok);
    assert!(doctor_check(&report, "backpressure").ok);
    assert!(report.fault_stage.is_none());
    Ok(())
}
