use super::*;

#[test]
fn doctor_webrtc_media_classifies_vt_encode_stall_before_rtp_stall() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-vt-encode-stall")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION_VT0.jsonl"),
        [
            json!({
                "kind": "sckTxTelemetry",
                "session_id": "SESSION_VT0",
                "sckCaptured": 60,
                "sckMeaningful": 60,
                "sckEncoded": 0,
                "sckCaptureFPS": 60.0,
                "sckMeaningfulFPS": 60.0,
                "sckEncodedFPS": 0.0,
                "sckEncodeLatencyP50Ms": 18.0,
                "sckEncodeLatencyP95Ms": 42.0,
                "sckEncodeLatencyMaxMs": 47.0,
                "sckEncodeFailures": 3,
                "codec": "h264"
            })
            .to_string(),
            json!({
                "kind": "videoStats",
                "session_id": "SESSION_VT0",
                "video_fps": 1.0
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION_VT0".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 30.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION_VT0",
    )?;

    assert_eq!(report.fault_stage, Some("vt_encode_stalled"));
    assert!(!doctor_check(&report, "sck_vt_encode_latency").ok);
    assert!(
        doctor_check(&report, "sck_vt_encode_latency")
            .detail
            .contains("failures=3")
    );
    Ok(())
}

#[test]
fn performance_webrtc_media_strict_vt_gate_rejects_missing_latency_telemetry() -> Result<()> {
    let artifact_dir = make_test_dir("performance-webrtc-media-vt-latency-missing")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION_VT_MISSING_LATENCY.jsonl"),
        [
            json!({
                "kind": "videoStats",
                "session_id": "SESSION_VT_MISSING_LATENCY",
                "video_fps": 60.0,
                "nativeVideoHealth": "rtpFlowing",
                "submitted": 180,
                "framesEncoded": 180,
                "framesSent": 180,
                "packetsSent": 1180,
                "bytesSent": 2_920_000,
                "codec": "video/H264",
                "encoder": "VideoToolbox",
                "qualityLimit": "none",
                "encodeFPS": 60.0,
                "targetBitrate": 18_000_000,
                "availableOutgoingBitrate": 28_000_000
            })
            .to_string(),
            json!({
                "kind": "sckTxTelemetry",
                "session_id": "SESSION_VT_MISSING_LATENCY",
                "sckCaptured": 180,
                "sckMeaningful": 180,
                "sckEncoded": 180,
                "sckCaptureFPS": 60.0,
                "sckMeaningfulFPS": 60.0,
                "sckEncodedFPS": 60.0,
                "sckEncodeFailures": 0,
                "codec": "h264"
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report_for_gate(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION_VT_MISSING_LATENCY".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 59.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION_VT_MISSING_LATENCY",
        0,
        0,
        false,
        true,
        None,
    )?;

    let vt_check = doctor_check(&report, "sck_vt_encode_latency");
    assert!(!vt_check.ok);
    assert!(
        vt_check
            .detail
            .contains("strict SCK/VT encode latency gate failed")
    );
    assert!(
        vt_check
            .detail
            .contains("VT encode latency fields were not present")
    );
    Ok(())
}

#[test]
fn doctor_webrtc_media_classifies_vt_encode_slow_before_rtp_stall() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-vt-encode-slow")?;
    std::fs::write(
        artifact_dir.join("webrtc-media-SESSION_VT_SLOW.jsonl"),
        [
            json!({
                "kind": "sckTxTelemetry",
                "session_id": "SESSION_VT_SLOW",
                "sckCaptured": 60,
                "sckMeaningful": 60,
                "sckEncoded": 60,
                "sckCaptureFPS": 60.0,
                "sckMeaningfulFPS": 60.0,
                "sckEncodedFPS": 60.0,
                "sckEncodeLatencyP50Ms": 18.0,
                "sckEncodeLatencyP95Ms": 31.0,
                "sckEncodeLatencyMaxMs": 38.0,
                "sckEncodeFailures": 0,
                "codec": "h264"
            })
            .to_string(),
            json!({
                "kind": "videoStats",
                "session_id": "SESSION_VT_SLOW",
                "video_fps": 18.0
            })
            .to_string(),
        ]
        .join("\n"),
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION_VT_SLOW".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 59.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION_VT_SLOW",
    )?;

    assert_eq!(report.fault_stage, Some("vt_encode_slow"));
    assert!(!doctor_check(&report, "sck_vt_encode_latency").ok);
    assert!(
        doctor_check(&report, "sck_vt_encode_latency")
            .detail
            .contains("p95Ms=31.000")
    );
    Ok(())
}
