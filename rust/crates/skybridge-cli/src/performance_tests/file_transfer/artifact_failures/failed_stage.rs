use super::*;

#[test]
fn file_transfer_artifact_rejects_failed_stage_before_or_after_success() -> Result<()> {
    let artifact_dir = make_test_dir("file-transfer-failed-stage")?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\nqr-connect-link mode=offline-p2p-kem suites=0x0001\nsuite peer=id:peer suite=X-Wing\nfile-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\nfile-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
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
    assert!(doctor_check(&report, "file_transfer_no_hidden_failure").ok);
    assert!(doctor_check(&report, "file_transfer_bidirectional").ok);

    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "boot role=ios-p2p-client target=mac\nfile-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\nfailed stage=file-transfer phase=unknown reason=network-aborted\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let hidden_failure = doctor_check(&report, "file_transfer_no_hidden_failure");
    assert!(!hidden_failure.ok, "{}", hidden_failure.detail);
    assert!(hidden_failure.detail.contains("unknownPhaseCount=1"));
    assert_eq!(report.fault_stage, Some("file_transfer_failed_stage"));

    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "boot role=ios-p2p-client target=mac\nfile-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\nfailed stage=file-transfer error=network-aborted\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let missing_phase = doctor_check(&report, "file_transfer_no_hidden_failure");
    assert!(!missing_phase.ok, "{}", missing_phase.detail);
    assert!(missing_phase.detail.contains("missingPhaseCount=1"));
    assert_eq!(report.fault_stage, Some("file_transfer_failed_stage"));
    Ok(())
}

#[test]
fn file_transfer_artifact_classifies_named_signed_kem_evidence_failure() -> Result<()> {
    let artifact_dir = make_test_dir("file-transfer-signed-kem-evidence-missing")?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\nSKR-1 signed LAN KEM refresh served requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served\nsuite peer=id:peer suite=X-Wing\nfile-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\nfile-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "boot role=ios-p2p-client target=mac\nSKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request\nSKR-1 signed LAN KEM refresh verified and imported peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=72.0 jitterMs=2.0 applicationLossPct=0 retryCount=0 lifecycle=served>verified\nfile-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nfailed stage=file-transfer phase=signed_kem_refresh_evidence_missing error=required signed LAN KEM refresh evidence is missing\n",
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
    assert_eq!(
        report.fault_stage,
        Some("signed_kem_refresh_evidence_missing")
    );
    Ok(())
}
