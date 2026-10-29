use super::*;

#[test]
fn file_transfer_artifact_classifies_ios_launch_signing_rejection() -> Result<()> {
    let artifact_dir = make_test_dir("file-transfer-ios-launch-signing")?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\nidentity ready device=mac\nready discovery=_skybridge._tcp transfer=8080\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-launch.json"),
        r#"{"info":{"outcome":"failed"},"error":{"userInfo":{"NSUnderlyingError":{"error":{"userInfo":{"NSLocalizedFailureReason":{"string":"Unable to launch com.skybridge.compass.ios because it has an invalid code signature, inadequate entitlements or its profile has not been explicitly trusted by the user."},"BSErrorCodeDescription":{"string":"Security"}}}}}}}"#,
    )?;
    let args = PerformanceCheckArgs {
        kind: PerformanceKindArg::FileTransfer,
        session_id: None,
        latest: false,
        artifact_dir: Some(artifact_dir),
        log_file: None,
        since_seconds: 1,
        min_fps: 59.0,
        min_width: 0,
        min_height: 0,
        exact_video_size: false,
        require_audio: true,
        strict_fps_floor: true,
        min_pass_window_seconds: P2P_REMOTE_STRICT_MIN_PASS_WINDOW_SECONDS,
        manual_artifact: false,
        output: OutputOptions { json: false },
    };
    let report = build_file_transfer_performance_report(&args)?;
    assert_eq!(report.fault_stage, Some("ios_launch_signing_rejected"));
    let sources = doctor_check(&report, "file_transfer_sources");
    assert!(sources.detail.contains("iosLaunchSigningRejected=true"));
    Ok(())
}
