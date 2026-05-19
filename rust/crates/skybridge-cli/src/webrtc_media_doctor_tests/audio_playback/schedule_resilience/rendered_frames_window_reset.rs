use super::*;

#[test]
fn doctor_webrtc_media_allows_rendered_frames_window_reset() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-rendered-window-reset")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION19C.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION19C",
                "video_fps": 32.0,
                "nativeVideoHealth": "rtpFlowing"
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION19C",
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
                "session_id": "SESSION19C",
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
                "session_id": "SESSION19C",
                "audioRxRecv": 250,
                "audioRxDecoded": 250,
                "audioRxPlayed": 250,
                "recvTotal": 250,
                "decodeTotal": 250,
                "playTotal": 250,
                "renderedFrames": 240000,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0,
                "jitterEvicted": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION19C",
                "audioRxRecv": 250,
                "audioRxDecoded": 250,
                "audioRxPlayed": 250,
                "recvTotal": 500,
                "decodeTotal": 500,
                "playTotal": 500,
                "renderedFrames": 0,
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
            session_id: Some("SESSION19C".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION19C",
    )?;

    assert!(doctor_check(&report, "audio_rendered_frames").ok);
    assert!(doctor_check(&report, "audio_activity_continuity").ok);
    assert_ne!(report.fault_stage, Some("audio_rx_playback"));
    Ok(())
}
