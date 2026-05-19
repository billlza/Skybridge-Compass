use super::*;

#[test]
fn file_transfer_signed_kem_refresh_golden_fixture_passes() -> Result<()> {
    let artifact_dir = fixture_dir(&["file-transfer", "signed-kem-pass"]);
    let args = performance_artifact_args(PerformanceKindArg::FileTransfer, artifact_dir);
    let report = build_file_transfer_performance_report(&args)?;

    for check_name in [
        "file_transfer_sources",
        "file_transfer_no_hidden_failure",
        "file_transfer_xwing",
        "file_transfer_protocol_identity_binding",
        "file_transfer_signed_kem_refresh",
        "file_transfer_skr_direct_route",
        "file_transfer_bidirectional",
        "file_transfer_success",
        "file_transfer_route_evidence",
        "performance_check_surface",
    ] {
        let check = doctor_check(&report, check_name);
        assert!(check.ok, "{check_name}: {}", check.detail);
    }
    let signed = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(signed.detail.contains("latencyMsMax=Some(72.0)"));
    assert!(signed.detail.contains("selectedEndpointDirect=true"));
    assert!(doctor_check(&report, "file_transfer_skr_direct_route").ok);
    assert!(signed.detail.contains("qrConnectLinkSeen=false"));
    assert!(signed.detail.contains("pqcPreseedSeen=false"));
    Ok(())
}

#[test]
fn file_transfer_qr_only_golden_fixture_fails_signed_kem_gate() -> Result<()> {
    let artifact_dir = fixture_dir(&["file-transfer", "qr-only-fails"]);
    let args = performance_artifact_args(PerformanceKindArg::FileTransfer, artifact_dir);
    let report = build_file_transfer_performance_report(&args)?;

    assert!(doctor_check(&report, "file_transfer_sources").ok);
    assert!(doctor_check(&report, "file_transfer_bidirectional").ok);
    assert!(doctor_check(&report, "file_transfer_success").ok);
    assert!(doctor_check(&report, "file_transfer_route_evidence").ok);
    assert!(doctor_check(&report, "performance_check_surface").ok);
    let signed = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(!signed.ok, "{}", signed.detail);
    assert!(signed.detail.contains("requestSeen=false"));
    assert!(signed.detail.contains("qrConnectLinkSeen=true"));
    Ok(())
}

#[test]
fn file_transfer_pib_oob_then_skr1_golden_fixture_passes() -> Result<()> {
    let artifact_dir = fixture_dir(&["file-transfer", "pib-oob-signed-kem-pass"]);
    let args = performance_artifact_args(PerformanceKindArg::FileTransfer, artifact_dir);
    let report = build_file_transfer_performance_report(&args)?;

    let binding = doctor_check(&report, "file_transfer_protocol_identity_binding");
    assert!(binding.ok, "{}", binding.detail);
    assert!(binding.detail.contains("pibPinnedSeen=true"));
    let signed = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(signed.ok, "{}", signed.detail);
    assert!(doctor_check(&report, "file_transfer_skr_direct_route").ok);
    assert!(doctor_check(&report, "file_transfer_success").ok);
    Ok(())
}

#[test]
fn file_transfer_skr_direct_route_rejects_bonjour_selected_endpoint() -> Result<()> {
    let artifact_dir = make_test_dir("file-transfer-bonjour-skr-route")?;
    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "[2026-05-16T01:00:00.000Z] strictPQC trust preflight failed: missing peer KEM suite=X-Wing reason=missing_pinned_identity_requires_oob\n[2026-05-16T01:00:00.010Z] PIB-1 protocol identity binding request: peer=mac lifecycle=identity-oob>request\n[2026-05-16T01:00:00.200Z] PIB-1 protocol identity binding signature verified: peer=mac fingerprint=abc code=123456 lifecycle=identity-oob>verified\n[2026-05-16T01:00:00.240Z] PIB-1 protocol identity binding pinned: peer=mac deviceId=id:mac fingerprint=abc lifecycle=identity-oob>pinned\n[2026-05-16T01:00:00.260Z] SKR-1 signed LAN KEM refresh request peer=mac endpoint=Mac._skybridge._tcp.local. selectedEndpointClass=bonjour-service selectedEndpointDirect=0 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request\n[2026-05-16T01:00:00.520Z] SKR-1 signed LAN KEM refresh verified and imported peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=72.0 jitterMs=2.0 successRatePct=100.0 applicationLossPct=0 retryCount=0 lifecycle=served>verified\n[2026-05-16T01:00:00.600Z] file-transfer outbound-complete name=ios-smoke-RUN.txt\n[2026-05-16T01:00:00.610Z] file-transfer inbound-complete name=mac-smoke-RUN.txt\n[2026-05-16T01:00:00.620Z] success suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-16T01:00:00.005Z] boot role=mac-p2p-host\n[2026-05-16T01:00:00.100Z] PIB-1 protocol identity binding served: requester=ios target=mac fingerprint=abc code=123456 lifecycle=identity-oob>served\n[2026-05-16T01:00:00.420Z] SKR-1 signed LAN KEM refresh served requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served\n[2026-05-16T01:00:00.550Z] suite peer=id:peer suite=X-Wing\n[2026-05-16T01:00:00.560Z] file-transfer inbound-complete name=ios-smoke-RUN.txt\n[2026-05-16T01:00:00.570Z] file-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\n[2026-05-16T01:00:00.580Z] file-transfer outbound-complete name=mac-smoke-RUN.txt\n[2026-05-16T01:00:00.630Z] success peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;

    let args = performance_artifact_args(PerformanceKindArg::FileTransfer, artifact_dir);
    let report = build_file_transfer_performance_report(&args)?;
    assert!(doctor_check(&report, "file_transfer_signed_kem_refresh").ok);
    let route = doctor_check(&report, "file_transfer_skr_direct_route");
    assert!(!route.ok, "{}", route.detail);
    assert!(route.detail.contains("selectedEndpointDirect=false"));
    Ok(())
}

#[test]
fn file_transfer_pib_verified_not_pinned_golden_fixture_fails() -> Result<()> {
    let artifact_dir = fixture_dir(&["file-transfer", "pib-verified-not-pinned-fails"]);
    let args = performance_artifact_args(PerformanceKindArg::FileTransfer, artifact_dir);
    let report = build_file_transfer_performance_report(&args)?;

    let binding = doctor_check(&report, "file_transfer_protocol_identity_binding");
    assert!(!binding.ok, "{}", binding.detail);
    assert!(binding.detail.contains("pibVerifiedSeen=true"));
    assert!(binding.detail.contains("pibPinnedSeen=false"));
    assert_eq!(
        report.fault_stage,
        Some("protocol_identity_binding_approval_missing")
    );
    let signed = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(!signed.ok, "{}", signed.detail);
    Ok(())
}

#[test]
fn file_transfer_signed_kem_refresh_metric_budget_golden_fixtures_fail() -> Result<()> {
    for (fixture, expected_detail) in [
        ("signed-kem-fail-latency", "latencyMsMax=Some(501.0)"),
        ("signed-kem-fail-jitter", "jitterMsMax=Some(51.0)"),
        ("signed-kem-fail-loss", "applicationLossPctMax=Some(0.6)"),
        ("signed-kem-fail-retry", "retryCountMax=Some(2)"),
    ] {
        let artifact_dir = fixture_dir(&["file-transfer", fixture]);
        let args = performance_artifact_args(PerformanceKindArg::FileTransfer, artifact_dir);
        let report = build_file_transfer_performance_report(&args)?;

        assert!(doctor_check(&report, "file_transfer_sources").ok);
        assert!(doctor_check(&report, "file_transfer_bidirectional").ok);
        assert!(doctor_check(&report, "file_transfer_success").ok);
        let signed = doctor_check(&report, "file_transfer_signed_kem_refresh");
        assert!(!signed.ok, "{fixture}: {}", signed.detail);
        assert!(
            signed.detail.contains(expected_detail),
            "{fixture}: {}",
            signed.detail
        );
    }
    Ok(())
}
