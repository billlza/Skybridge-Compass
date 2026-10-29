use super::*;

#[test]
fn doctor_webrtc_media_accepts_optimistic_sender_bind_pending_with_rx_flow() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-optimistic-tx-bind-pending")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION17.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION17",
                "video_fps": 32.0,
                "nativeVideoHealth": "rtpFlowing",
                "fallbackProducer": "initial",
                "droppedBackpressure": 0
            })
            .to_string(),
            json!({
                "kind": "audioTxRelayBindSent",
                "session_id": "SESSION17",
                "probable": "relay-bind-sent"
            })
            .to_string(),
            json!({
                "kind": "audioTxRelayBindAckPending",
                "session_id": "SESSION17",
                "probable": "relay-bind-ack-pending-media-optimistic"
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION17",
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
                "session_id": "SESSION17",
                "audioTxCaptured": 251,
                "audioTxEncoded": 251,
                "audioTxSent": 251,
                "audioTxCapturedTotal": 501,
                "audioTxEncodedTotal": 501,
                "audioTxSentTotal": 501,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION17",
                "audioRxRecv": 248,
                "audioRxDecoded": 248,
                "audioRxPlayed": 250,
                "recvTotal": 248,
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
                "session_id": "SESSION17",
                "audioRxRecv": 249,
                "audioRxDecoded": 249,
                "audioRxPlayed": 251,
                "recvTotal": 497,
                "decodeTotal": 497,
                "playTotal": 501,
                "renderedFrames": 240960,
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
            session_id: Some("SESSION17".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION17",
    )?;

    assert!(doctor_check(&report, "audio_activity_continuity").ok);
    assert!(doctor_check(&report, "audio_playback_continuity").ok);
    assert!(doctor_check(&report, "audio_relay_startup").ok);
    assert!(doctor_check(&report, "probable_fault_stage").ok);
    assert!(report.fault_stage.is_none());
    Ok(())
}
