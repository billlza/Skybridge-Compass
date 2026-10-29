use super::*;

#[test]
fn doctor_webrtc_media_fails_audio_playout_pressure_without_underflow() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-audio-playout-pressure")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION19.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION19",
                "video_fps": 32.0,
                "nativeVideoHealth": "rtpFlowing"
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION19",
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
                "session_id": "SESSION19",
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
                "session_id": "SESSION19",
                "audioRxRecv": 248,
                "audioRxDecoded": 248,
                "audioRxPlayed": 250,
                "recvTotal": 248,
                "decodeTotal": 248,
                "playTotal": 250,
                "renderedFrames": 240000,
                "jitterLate": 0,
                "scheduleLeadMs": 30,
                "audioArrivalP95Ms": 70,
                "audioArrivalMaxMs": 103,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0,
                "jitterEvicted": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION19",
                "audioRxRecv": 248,
                "audioRxDecoded": 242,
                "audioRxPlayed": 247,
                "recvTotal": 496,
                "decodeTotal": 490,
                "playTotal": 497,
                "renderedFrames": 240960,
                "jitterLate": 2,
                "plcFrames": 5,
                "plcRatio": 0.020,
                "scheduleLeadMs": -50,
                "audioArrivalP95Ms": 175.6,
                "audioArrivalMaxMs": 679.2,
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
            session_id: Some("SESSION19".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION19",
    )?;

    assert_eq!(report.fault_stage, Some("audio_rx_playback"));
    assert!(doctor_check(&report, "audio_activity_continuity").ok);
    assert!(!doctor_check(&report, "audio_playback_continuity").ok);
    let detail = &doctor_check(&report, "audio_playback_continuity").detail;
    assert!(detail.contains("playout pressure"));
    assert!(detail.contains("audioArrivalMaxMs=679"));
    assert!(detail.contains("jitterLate=2"));
    assert!(detail.contains("plcFrames=5"));
    Ok(())
}
