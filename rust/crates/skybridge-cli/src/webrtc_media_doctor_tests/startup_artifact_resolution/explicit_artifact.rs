use super::*;

#[test]
fn doctor_webrtc_media_prefers_explicit_artifact_over_home_logs() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-home")?;
    let home_dir = make_test_dir("doctor-webrtc-media-home-root")?;
    let home_logs = home_dir.join("Library").join("Logs").join("SkyBridge");
    std::fs::create_dir_all(&home_logs)?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION3.log"),
        "stream-stats session=SESSION3 fps=21.0\n",
    )?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION3.jsonl"),
        [
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION3",
                "audioTxCaptured": 5,
                "audioTxEncoded": 5,
                "audioTxSent": 5,
                "audioTxCapturedTotal": 5,
                "audioTxEncodedTotal": 5,
                "audioTxSentTotal": 5,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION3",
                "audioTxCaptured": 6,
                "audioTxEncoded": 6,
                "audioTxSent": 6,
                "audioTxCapturedTotal": 11,
                "audioTxEncodedTotal": 11,
                "audioTxSentTotal": 11,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION3",
                "audioRxRecv": 5,
                "audioRxDecoded": 5,
                "audioRxPlayed": 5,
                "recvTotal": 5,
                "decodeTotal": 5,
                "playTotal": 5,
                "renderedFrames": 2400,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION3",
                "audioRxRecv": 6,
                "audioRxDecoded": 6,
                "audioRxPlayed": 6,
                "recvTotal": 11,
                "decodeTotal": 11,
                "playTotal": 11,
                "renderedFrames": 2880,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
        ]
        .join("\n"),
    )?;
    std::fs::write(
        home_logs.join("webrtc-media-SESSION3.jsonl"),
        [
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION3",
                "audioTxCaptured": 5,
                "audioTxEncoded": 5,
                "audioTxSent": 5,
                "audioTxCapturedTotal": 5,
                "audioTxEncodedTotal": 5,
                "audioTxSentTotal": 5,
                "audioDrops": 0,
                "audioDropsTotal": 0,
                "nativeVideoHealth": "active"
            })
            .to_string(),
            json!({
                "kind": "audioTxRolling",
                "session_id": "SESSION3",
                "audioTxCaptured": 6,
                "audioTxEncoded": 6,
                "audioTxSent": 6,
                "audioTxCapturedTotal": 11,
                "audioTxEncodedTotal": 11,
                "audioTxSentTotal": 11,
                "audioDrops": 0,
                "audioDropsTotal": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION3",
                "audioRxRecv": 5,
                "audioRxDecoded": 5,
                "audioRxPlayed": 5,
                "recvTotal": 5,
                "decodeTotal": 5,
                "playTotal": 5,
                "renderedFrames": 2400,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
            json!({
                "kind": "audioRxRolling",
                "session_id": "SESSION3",
                "audioRxRecv": 6,
                "audioRxDecoded": 6,
                "audioRxPlayed": 6,
                "recvTotal": 11,
                "decodeTotal": 11,
                "playTotal": 11,
                "renderedFrames": 2880,
                "underflow": 0,
                "rebuffer": 0,
                "playbackDrop": 0
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let _home_guard = set_env_var_for_test("HOME", &home_dir);
    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION3".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 20.0,
            require_audio: true,
            output: OutputOptions { json: true },
        },
        "SESSION3",
    );
    let report = report?;

    assert!(doctor_check(&report, "video_fps").ok);
    assert!(doctor_check(&report, "audio_rx_played").ok);
    assert!(doctor_check(&report, "audio_rendered_frames").ok);
    assert!(doctor_check(&report, "audio_activity_continuity").ok);
    assert!(doctor_check(&report, "audio_playback_continuity").ok);
    assert!(report.target.contains("webrtc-media-SESSION3.jsonl"));
    assert!(!report.target.contains(&home_logs.display().to_string()));
    Ok(())
}
