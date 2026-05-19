use super::*;

#[test]
fn p2p_remote_signed_kem_refresh_golden_fixture_passes() -> Result<()> {
    let artifact_dir = fixture_dir(&["p2p-remote", "signed-kem-pass"]);
    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;

    assert_eq!(evidence.file_count, 2);
    let xwing = check_p2p_remote_xwing(&evidence);
    assert!(xwing.ok, "{}", xwing.detail);
    let signed = check_p2p_remote_signed_kem_refresh(&evidence);
    assert!(signed.ok, "{}", signed.detail);
    assert!(signed.detail.contains("latencyMsMax=Some(72.0)"));
    assert!(signed.detail.contains("successRatePctMin=Some(100.0)"));
    Ok(())
}

#[test]
fn p2p_remote_signed_kem_refresh_golden_fixture_rejects_latency_budget() -> Result<()> {
    let artifact_dir = fixture_dir(&["p2p-remote", "signed-kem-fail-latency"]);
    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;

    let signed = check_p2p_remote_signed_kem_refresh(&evidence);
    assert!(!signed.ok, "{}", signed.detail);
    assert!(signed.detail.contains("latencyMsMax=Some(501.0)"));
    assert!(signed.detail.contains("limits=latency<=500.0"));
    Ok(())
}
