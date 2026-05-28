use super::*;

#[test]
fn file_transfer_artifact_requires_matching_payload_sha256() -> Result<()> {
    let artifact_dir = make_test_dir("file-transfer-payload-integrity")?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\nsuite peer=id:peer suite=X-Wing\nfile-transfer inbound-complete name=ios-smoke-RUN.txt sha256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\nfile-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\nfile-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "boot role=ios-p2p-client target=mac\nfile-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let args = PerformanceCheckArgs {
        kind: PerformanceKindArg::FileTransfer,
        session_id: None,
        latest: false,
        artifact_dir: Some(artifact_dir.clone()),
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
    let payload = doctor_check(&report, "file_transfer_payload_integrity");
    assert!(!payload.ok, "{}", payload.detail);
    assert!(payload.detail.contains("mismatchedNames=ios-smoke-RUN.txt"));
    assert!(doctor_check(&report, "performance_check_surface").ok);

    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\nsuite peer=id:peer suite=X-Wing\nfile-transfer inbound-complete name=ios-smoke-RUN.txt\nfile-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\nfile-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let missing_hash = doctor_check(&report, "file_transfer_payload_integrity");
    assert!(!missing_hash.ok, "{}", missing_hash.detail);
    assert!(
        missing_hash
            .detail
            .contains("missingReceiverNames=ios-smoke-RUN.txt")
    );

    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\nsuite peer=id:peer suite=X-Wing\nfile-transfer inbound-complete name=ios-smoke-RUN-A.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\nfile-transfer outbound-complete name=mac-smoke-RUN-B.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "boot role=ios-p2p-client target=mac\nfile-transfer outbound-complete name=ios-smoke-RUN-A.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer inbound-complete name=mac-smoke-RUN-B.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let mixed_run_ids = doctor_check(&report, "file_transfer_payload_integrity");
    assert!(!mixed_run_ids.ok, "{}", mixed_run_ids.detail);
    assert!(mixed_run_ids.detail.contains("bidirectionalRunIds=-"));

    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\nsuite peer=id:peer suite=X-Wing\nfile-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\nfile-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nmac-reconnect outbound-complete name=mac-reconnect-smoke-OTHER.txt sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\nsuccess peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=1 macInitiatedTransfer=1\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "boot role=ios-p2p-client target=mac\nfile-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nmac-reconnect inbound-complete name=mac-reconnect-smoke-OTHER.txt sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\nsuccess suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=1 macInitiatedTransfer=1\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let wrong_reconnect_run = doctor_check(&report, "file_transfer_payload_integrity");
    assert!(!wrong_reconnect_run.ok, "{}", wrong_reconnect_run.detail);
    assert!(
        wrong_reconnect_run
            .detail
            .contains("reconnectDigestOk=false")
    );

    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\nsuite peer=id:peer suite=X-Wing\nfile-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\nfile-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nfile-transfer outbound-complete name=mac-smoke-RUN.txt sha256=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\nsuccess peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let conflicting_hash = doctor_check(&report, "file_transfer_payload_integrity");
    assert!(!conflicting_hash.ok, "{}", conflicting_hash.detail);
    assert!(
        conflicting_hash
            .detail
            .contains("conflictingNames=mac-smoke-RUN.txt")
    );
    Ok(())
}
