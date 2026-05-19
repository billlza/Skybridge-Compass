use super::*;

#[test]
fn p2p_remote_artifact_rejects_unknown_suite_rejection_even_with_xwing_success() -> Result<()> {
    let artifact_dir = make_test_dir("p2p-remote-unknown-suite")?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-15T00:00:01Z] SecurityEvent suite_rejected_unknown stage=decode.messageA.supportedSuites wireId=0x0000\n\
         [2026-05-15T00:00:02Z] mac remote established peer=iPhone suite=X-Wing route=lan-direct\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-p2p-remote-TEST.status.log"),
        "[2026-05-15T00:00:03Z] remote-desktop-pass fps=60.0 rxFps=60.0 frame=2056x1329\n",
    )?;

    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;
    assert!(evidence.unknown_suite_rejected);
    assert!(evidence.xwing_established);

    let xwing = check_p2p_remote_xwing(&evidence);
    assert!(!xwing.ok, "{}", xwing.detail);
    assert!(xwing.detail.contains("unknownSuiteRejected=true"));

    let fallback = check_p2p_remote_no_fallback(&evidence);
    assert!(!fallback.ok, "{}", fallback.detail);
    assert!(fallback.detail.contains("unknownSuiteRejected=true"));
    Ok(())
}

#[test]
fn p2p_remote_artifact_rejects_plain_unknown_suite_line_even_with_xwing_success() -> Result<()> {
    let artifact_dir = make_test_dir("p2p-remote-plain-unknown-suite")?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-15T00:00:01Z] SecurityEvent unknown suite stage=decode.messageA.supportedSuites wireId=0x9999\n\
         [2026-05-15T00:00:02Z] mac remote established peer=iPhone suite=X-Wing route=lan-direct\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-p2p-remote-TEST.status.log"),
        "[2026-05-15T00:00:03Z] remote-desktop-pass fps=60.0 rxFps=60.0 frame=2056x1329\n",
    )?;

    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;
    assert!(evidence.unknown_suite_rejected);
    assert!(evidence.xwing_established);

    let xwing = check_p2p_remote_xwing(&evidence);
    assert!(!xwing.ok, "{}", xwing.detail);
    assert!(xwing.detail.contains("unknownSuiteRejected=true"));
    Ok(())
}
