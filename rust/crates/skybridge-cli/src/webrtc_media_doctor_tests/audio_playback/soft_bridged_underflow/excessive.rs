use super::*;

#[test]
fn doctor_webrtc_media_fails_excessive_soft_bridged_underflow_without_rebuffer() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-soft-bridged-underflow")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION13.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION13",
                "video_fps": 60.0,
                "nativeVideoHealth": "rtpFlowing"
            })
            .to_string(),
            json!({
                "kind": "remoteVideoFrameEvidence",
                "session_id": "SESSION13",
                "source": "receiver-stats",
                "size": "960x620",
                "packets": 23,
                "bytes": 22298,
                "framesReceived": 1,
                "framesDecoded": 1
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION13",
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
                "session_id": "SESSION13",
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
                "session_id": "SESSION13",
                "audioRxRecv": 230,
                "audioRxDecoded": 227,
                "audioRxPlayed": 250,
                "recvTotal": 230,
                "decodeTotal": 227,
                "playTotal": 250,
                "renderedFrames": 240240,
                "underflow": 0,
                "bridgedUnderflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION13",
                "audioRxRecv": 222,
                "audioRxDecoded": 202,
                "audioRxPlayed": 228,
                "recvTotal": 452,
                "decodeTotal": 429,
                "playTotal": 478,
                "renderedFrames": 223680,
                "underflow": 72,
                "bridgedUnderflow": 17280,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION13".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 55.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION13",
    )?;

    assert_eq!(report.fault_stage, Some("audio_rx_playback"));
    assert!(doctor_check(&report, "audio_rx_played").ok);
    assert!(doctor_check(&report, "audio_rendered_frames").ok);
    assert!(doctor_check(&report, "audio_activity_continuity").ok);
    assert!(!doctor_check(&report, "audio_playback_continuity").ok);
    assert!(
        doctor_check(&report, "audio_playback_continuity")
            .detail
            .contains("underflow=72")
    );
    Ok(())
}
