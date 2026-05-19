use super::*;

#[test]
fn doctor_webrtc_media_fails_audio_jitter_eviction_without_rebuffer() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-audio-jitter-evicted")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION14.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION14",
                "video_fps": 60.0,
                "nativeVideoHealth": "rtpFlowing"
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION14",
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
                "session_id": "SESSION14",
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
                "session_id": "SESSION14",
                "audioRxRecv": 250,
                "audioRxDecoded": 248,
                "audioRxPlayed": 250,
                "recvTotal": 250,
                "decodeTotal": 248,
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
                "session_id": "SESSION14",
                "audioRxRecv": 250,
                "audioRxDecoded": 220,
                "audioRxPlayed": 230,
                "recvTotal": 500,
                "decodeTotal": 468,
                "playTotal": 480,
                "renderedFrames": 240000,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0,
                "jitterEvicted": 26
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION14".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 55.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION14",
    )?;

    assert_eq!(report.fault_stage, Some("audio_rx_playback"));
    assert!(!doctor_check(&report, "audio_playback_continuity").ok);
    assert!(
        doctor_check(&report, "audio_playback_continuity")
            .detail
            .contains("jitterEvicted=26")
    );
    Ok(())
}
