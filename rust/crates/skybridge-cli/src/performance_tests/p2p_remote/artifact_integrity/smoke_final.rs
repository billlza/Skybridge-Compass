use super::*;

#[test]
fn p2p_remote_artifact_requires_smoke_final_success_sentinel() {
    let mut evidence = P2pRemotePerformanceEvidence {
        has_mac_log: true,
        has_ios_log: true,
        ..Default::default()
    };

    let missing = check_p2p_remote_complete_artifact(&evidence);
    assert!(!missing.ok, "{}", missing.detail);

    update_p2p_remote_evidence(
        &mut evidence,
        "smoke-final result=success validated=1 route=lan-direct fps=59 frame=2056x1329",
        true,
        false,
    );
    let missing_capture = check_p2p_remote_complete_artifact(&evidence);
    assert!(!missing_capture.ok, "{}", missing_capture.detail);
    assert!(missing_capture.detail.contains("captureVerified=false"));

    update_p2p_remote_evidence(
        &mut evidence,
        "smoke-capture-source captureVerified=1 changedRatio=0.500 meanDelta=12.0",
        true,
        false,
    );
    let missing_remote_desktop_pass = check_p2p_remote_complete_artifact(&evidence);
    assert!(
        !missing_remote_desktop_pass.ok,
        "{}",
        missing_remote_desktop_pass.detail
    );
    assert!(
        missing_remote_desktop_pass
            .detail
            .contains("remoteDesktopPass=false")
    );

    update_p2p_remote_evidence(
        &mut evidence,
        "remote-desktop-pass seconds=8 requestedSeconds=8 fps=60.0 rxFps=60.0 frame=2056x1329 renderOrientation=normal",
        false,
        true,
    );
    let complete = check_p2p_remote_complete_artifact(&evidence);
    assert!(complete.ok, "{}", complete.detail);
    assert!(complete.detail.contains("captureVerified=true"));
    assert!(complete.detail.contains("remoteDesktopPass=true"));

    update_p2p_remote_evidence(
        &mut evidence,
        "failed stage=mac-host phase=process-exited label=macOS_P2P_handshake",
        true,
        false,
    );
    let host_exited = check_p2p_remote_complete_artifact(&evidence);
    assert!(!host_exited.ok, "{}", host_exited.detail);
    assert!(host_exited.detail.contains("hostProcessExited=true"));
}

#[test]
fn p2p_remote_manual_artifact_accepts_remote_desktop_pass_without_smoke_final() {
    let mut evidence = P2pRemotePerformanceEvidence {
        has_mac_log: true,
        has_ios_log: true,
        remote_desktop_pass: true,
        ..Default::default()
    };

    let strict = check_p2p_remote_complete_artifact(&evidence);
    assert!(!strict.ok, "{}", strict.detail);

    let manual = check_p2p_remote_complete_artifact_for_mode(&evidence, true);
    assert!(!manual.ok, "{}", manual.detail);
    assert!(manual.detail.contains("captureVerified=false"));

    evidence.smoke_capture_source_verified = true;
    let manual = check_p2p_remote_complete_artifact_for_mode(&evidence, true);
    assert!(manual.ok, "{}", manual.detail);
    assert!(manual.detail.contains("manualArtifact=true"));
    assert!(manual.detail.contains("remoteDesktopPass=true"));

    evidence.host_process_exited = true;
    let host_exited = check_p2p_remote_complete_artifact_for_mode(&evidence, true);
    assert!(!host_exited.ok, "{}", host_exited.detail);
    assert!(host_exited.detail.contains("hostProcessExited=true"));
}
