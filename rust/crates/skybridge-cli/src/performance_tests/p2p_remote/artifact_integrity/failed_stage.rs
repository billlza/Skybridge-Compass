use super::*;

#[test]
fn p2p_remote_artifact_rejects_failed_stage_before_or_after_success() -> Result<()> {
    let artifact_dir = make_test_dir("p2p-remote-failed-stage")?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "mac-stream-config codec=hevc fps=60 fallback=fail-fast\nsmoke-final result=success validated=1 route=lan-direct fps=59 frame=2056x1329\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-p2p-remote-TEST.status.log"),
        "remote-desktop-pass fps=60.0 rxFps=60.0 frame=2056x1329\nsmoke-final result=success validated=1 route=lan-direct fps=59 frame=2056x1329\n",
    )?;
    let args = PerformanceCheckArgs {
        kind: PerformanceKindArg::P2pRemote,
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

    let report = build_p2p_remote_performance_report(&args)?;
    assert!(doctor_check(&report, "p2p_remote_complete_artifact").ok);
    assert!(doctor_check(&report, "p2p_remote_no_hidden_failure").ok);

    std::fs::write(
        artifact_dir.join("ios-p2p-remote-TEST.status.log"),
        "remote-desktop-pass fps=60.0 rxFps=60.0 frame=2056x1329\nsmoke-final result=success validated=1 route=lan-direct fps=59 frame=2056x1329\nfailed stage=remote-desktop error=cadence-timeout\n",
    )?;
    let report = build_p2p_remote_performance_report(&args)?;
    let hidden_failure = doctor_check(&report, "p2p_remote_no_hidden_failure");
    assert!(!hidden_failure.ok, "{}", hidden_failure.detail);
    assert!(hidden_failure.detail.contains("failedStageCount=1"));
    assert!(hidden_failure.detail.contains("missingPhaseCount=1"));
    assert_eq!(report.fault_stage, Some("p2p_remote_failed_stage"));

    std::fs::write(
        artifact_dir.join("ios-p2p-remote-TEST.status.log"),
        "remote-desktop-pass fps=60.0 rxFps=60.0 frame=2056x1329\nsmoke-final result=success validated=1 route=lan-direct fps=59 frame=2056x1329\nfailed stage=remote-desktop phase=unknown reason=network-aborted\n",
    )?;
    let report = build_p2p_remote_performance_report(&args)?;
    let unknown_phase = doctor_check(&report, "p2p_remote_no_hidden_failure");
    assert!(!unknown_phase.ok, "{}", unknown_phase.detail);
    assert!(unknown_phase.detail.contains("unknownPhaseCount=1"));
    assert_eq!(report.fault_stage, Some("p2p_remote_failed_stage"));
    Ok(())
}
