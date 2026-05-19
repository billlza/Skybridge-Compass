use super::*;

#[test]
fn doctor_webrtc_media_video_only_requires_native_receiver_evidence() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-video-only-missing-rx")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION10.log"),
        "\
native-video-health session=SESSION10 state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION10 state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/VP8 encoder=libvpx
",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION10".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION10",
    )?;

    assert!(doctor_check(&report, "video_fps").ok);
    assert!(!doctor_check(&report, "native_video_receiver").ok);
    Ok(())
}

#[test]
fn doctor_webrtc_media_rejects_size_only_native_receiver_evidence() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-size-only-rx")?;
    std::fs::write(
        artifact_dir.join("webrtc-session-SESSION10_SIZE.log"),
        "\
native-video-health session=SESSION10_SIZE state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION10_SIZE state=rtpFlowing submitted=54 framesSent=48 packetsSent=269 bytesSent=269590 codec=video/VP8 encoder=libvpx
native-receiver-frame session=SESSION10_SIZE size=1280x826 source=receiver-stats
",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION10_SIZE".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION10_SIZE",
    )?;

    assert!(!doctor_check(&report, "native_video_receiver").ok);
    Ok(())
}

#[test]
fn doctor_webrtc_media_reads_round_status_logs_for_native_video() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-round-status")?;
    std::fs::write(
        artifact_dir.join("mac_round_1.status.log"),
        "\
native-video-health session=SESSION11 state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION11 state=rtpFlowing submitted=7 framesSent=6 packetsSent=18 bytesSent=24000 codec=video/VP8 encoder=libvpx
",
    )?;
    std::fs::write(
        artifact_dir.join("ios_round_1.status.log.trace.log"),
        "remote-video-frame-evidence session=SESSION11 source=receiver-stats type=inbound-rtp packets=23 bytes=22298 framesReceived=1 framesDecoded=1 size=1280x826\n",
    )?;

    let report = build_webrtc_media_doctor_report(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION11".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION11",
    )?;

    assert!(doctor_check(&report, "video_fps").ok);
    assert!(doctor_check(&report, "native_video_receiver").ok);
    assert!(report.target.contains("mac_round_1.status.log"));
    assert!(report.target.contains("ios_round_1.status.log.trace.log"));
    assert!(report.fault_stage.is_none());
    Ok(())
}

#[test]
fn doctor_webrtc_media_reads_ios_trace_when_artifact_dir_has_many_files() -> Result<()> {
    let artifact_dir = make_test_dir("doctor-webrtc-media-many-artifacts")?;
    for index in 0..160 {
        std::fs::write(
            artifact_dir.join(format!("aaa_noise_{index:03}.log")),
            "unrelated session=NOPE\n",
        )?;
    }
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "\
native-video-health session=SESSION11_MANY state=rtpFlowing fallbackMode=main
native-video-tx session=SESSION11_MANY state=rtpFlowing submitted=7 framesSent=6 packetsSent=18 bytesSent=24000 codec=video/H264 encoder=VideoToolbox
",
    )?;
    std::fs::write(
        artifact_dir.join("ios-real-webrtc.status.log.trace.log"),
        "remote-video-frame-evidence session=SESSION11_MANY source=receiver-stats type=inbound-rtp packets=23 bytes=22298 framesReceived=1 framesDecoded=1 size=2056x1330 visibleSize=2056x1329 codedSize=2056x1330\n",
    )?;

    let report = build_webrtc_media_doctor_report_with_video_requirements(
        &WebRtcMediaDoctorArgs {
            session_id: Some("SESSION11_MANY".to_owned()),
            latest: false,
            artifact_dir: Some(artifact_dir),
            log_file: None,
            since_seconds: 120,
            min_fps: 1.0,
            require_audio: false,
            output: OutputOptions { json: true },
        },
        "SESSION11_MANY",
        2056,
        1329,
        true,
    )?;

    assert!(doctor_check(&report, "native_video_receiver").ok);
    assert!(doctor_check(&report, "video_resolution").ok);
    assert!(
        report
            .target
            .contains("ios-real-webrtc.status.log.trace.log")
    );
    Ok(())
}
