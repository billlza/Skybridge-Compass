use super::*;

#[test]
fn doctor_webrtc_media_rejects_single_positive_audio_sample() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-single-audio-sample")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION13.jsonl"),
        json!({
            "kind": "audio",
            "session_id": "SESSION13",
            "video_fps": 60.0,
            "nativeVideoHealth": "rtpFlowing",
            "droppedBackpressure": 0,
            "audioTxCaptured": 300,
            "audioTxEncoded": 300,
            "audioTxSent": 300,
            "audioRxRecv": 290,
            "audioRxDecoded": 290,
            "audioRxPlayed": 290,
            "renderedFrames": 139200,
            "underflow": 0,
            "rebuffer": 0,
            "playbackDrop": 0
        })
        .to_string(),
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

    assert_eq!(report.fault_stage, Some("audio_tx_capture"));
    assert!(doctor_check(&report, "audio_tx_sent").ok);
    assert!(!doctor_check(&report, "audio_activity_continuity").ok);
    assert!(
        doctor_check(&report, "audio_activity_continuity")
            .detail
            .contains("at least two positive rolling samples")
    );
    Ok(())
}

#[test]
fn doctor_webrtc_media_rejects_audio_tx_drops() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-audio-tx-drops")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION14.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION14",
                "video_fps": 60.0,
                "nativeVideoHealth": "rtpFlowing",
                "droppedBackpressure": 0
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION14",
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
                "session_id": "SESSION14",
                "audioTxCaptured": 300,
                "audioTxEncoded": 300,
                "audioTxSent": 299,
                "audioTxCapturedTotal": 600,
                "audioTxEncodedTotal": 600,
                "audioTxSentTotal": 599,
                "audioDrops": 1,
                "audioDropsTotal": 1
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION14",
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
                "session_id": "SESSION14",
                "audioRxRecv": 290,
                "audioRxDecoded": 290,
                "audioRxPlayed": 290,
                "recvTotal": 580,
                "decodeTotal": 580,
                "playTotal": 580,
                "renderedFrames": 139200,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
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

    assert_eq!(report.fault_stage, Some("audio_tx_relay_send"));
    assert!(!doctor_check(&report, "audio_activity_continuity").ok);
    assert!(
        doctor_check(&report, "audio_activity_continuity")
            .detail
            .contains("audioDrops=1")
    );
    Ok(())
}
