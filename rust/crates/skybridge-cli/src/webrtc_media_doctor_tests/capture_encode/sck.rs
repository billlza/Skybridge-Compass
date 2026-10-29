use super::*;

#[test]
fn doctor_webrtc_media_classifies_sck_capture_stall_before_rtp_stall() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-sck-capture-stall")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION_SCK0.jsonl"),
        [
            json!({
                "kind": "sckTxTelemetry",
                "session_id": "SESSION_SCK0",
                "sckCaptured": 60,
                "sckMeaningful": 0,
                "sckEncoded": 0,
                "sckCaptureFPS": 60.0,
                "sckMeaningfulFPS": 0.0,
                "sckEncodedFPS": 0.0,
                "codec": "h264"
            })
            .to_string(),
            json!({
                "kind": "videoStats",
                "session_id": "SESSION_SCK0",
                "video_fps": 1.0
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION_SCK0".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION_SCK0",
    )?;

    assert_eq!(report.fault_stage, Some("sck_capture_stalled"));
    Ok(())
}
