use super::*;

#[test]
fn file_transfer_artifact_requires_bidirectional_success() -> Result<()> {
    let artifact_dir = make_test_dir("file-transfer-bidirectional")?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\nsuite peer=id:peer suite=X-Wing\nfile-transfer inbound-complete name=ios-smoke-RUN.txt\nfile-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\nfile-transfer outbound-complete name=mac-smoke-RUN.txt\nsuccess peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "boot role=ios-p2p-client target=mac\nfile-transfer outbound-complete name=ios-smoke-RUN.txt\nsuccess suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
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
    let bidirectional = doctor_check(&report, "file_transfer_bidirectional");
    assert!(!bidirectional.ok, "{}", bidirectional.detail);
    assert!(bidirectional.detail.contains("iosInboundComplete=false"));
    assert!(doctor_check(&report, "performance_check_surface").ok);
    Ok(())
}
