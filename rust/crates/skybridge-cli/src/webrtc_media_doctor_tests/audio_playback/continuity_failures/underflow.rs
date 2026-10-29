use super::*;

#[test]
fn doctor_webrtc_media_fails_audio_underflow_even_with_positive_playback_counters() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-audio-underflow")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION12.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION12",
                "video_fps": 60.0,
                "nativeVideoHealth": "rtpFlowing",
                "droppedBackpressure": 0
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION12",
                "audioTxCaptured": 300,
                "audioTxEncoded": 300,
                "audioTxSent": 300,
                "audioTxCapturedTotal": 300,
                "audioTxEncodedTotal": 300,
                "audioTxSentTotal": 300,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION12",
                "audioTxCaptured": 300,
                "audioTxEncoded": 300,
                "audioTxSent": 300,
                "audioTxCapturedTotal": 600,
                "audioTxEncodedTotal": 600,
                "audioTxSentTotal": 600,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION12",
                "audioRxRecv": 290,
                "audioRxDecoded": 290,
                "audioRxPlayed": 290,
                "recvTotal": 290,
                "decodeTotal": 290,
                "playTotal": 290,
                "renderedFrames": 139200,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION12",
                "audioRxRecv": 290,
                "audioRxDecoded": 290,
                "audioRxPlayed": 290,
                "recvTotal": 580,
                "decodeTotal": 580,
                "playTotal": 580,
                "renderedFrames": 139200,
                "underflow": 2,
                "rebuffer": 1,
                "playbackDrop": 0
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION12".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 55.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION12",
    )?;

    assert_eq!(report.fault_stage, Some("audio_rx_playback"));
    assert!(doctor_check(&report, "audio_rx_played").ok);
    assert!(doctor_check(&report, "audio_rendered_frames").ok);
    assert!(doctor_check(&report, "audio_activity_continuity").ok);
    assert!(!doctor_check(&report, "audio_playback_continuity").ok);
    assert!(
        doctor_check(&report, "audio_playback_continuity")
            .detail
            .contains("underflow=2")
    );
    Ok(())
}
