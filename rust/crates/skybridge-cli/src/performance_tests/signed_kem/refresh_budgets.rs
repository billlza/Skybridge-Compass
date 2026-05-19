use super::*;

#[test]
fn p2p_remote_signed_kem_refresh_requires_success_rate_budget() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    for (line, is_mac, is_ios) in [
        (
            "strictPQC trust preflight failed: missing peer KEM suite=X-Wing",
            false,
            true,
        ),
        (
            "SKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request",
            false,
            true,
        ),
        (
            "SKR-1 signed LAN KEM refresh served requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served",
            true,
            false,
        ),
        (
            "SKR-1 signed LAN KEM refresh verified and imported peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=82.5 jitterMs=3.0 successRatePct=98.0 applicationLossPct=0 retryCount=0 lifecycle=served>verified",
            false,
            true,
        ),
        (
            "mac remote established peer=iPhone suite=X-Wing route=lan-direct",
            true,
            false,
        ),
    ] {
        update_p2p_remote_evidence(&mut evidence, line, is_mac, is_ios);
    }

    let check = check_p2p_remote_signed_kem_refresh(&evidence);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("successRatePctMin=Some(98.0)"));
}

#[test]
fn p2p_remote_signed_kem_refresh_rejects_latency_jitter_loss_and_retry_budgets() {
    let run_case = |metrics: &str| {
        let mut evidence = P2pRemotePerformanceEvidence::default();
        for (line, is_mac, is_ios) in [
            (
                "strictPQC trust preflight failed: missing peer KEM suite=X-Wing",
                false,
                true,
            ),
            (
                "SKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request",
                false,
                true,
            ),
            (
                "SKR-1 signed LAN KEM refresh served requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served",
                true,
                false,
            ),
            (
                "mac remote established peer=iPhone suite=X-Wing route=lan-direct",
                true,
                false,
            ),
        ] {
            update_p2p_remote_evidence(&mut evidence, line, is_mac, is_ios);
        }
        let verified = format!(
            "SKR-1 signed LAN KEM refresh verified and imported peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound {metrics} lifecycle=served>verified"
        );
        update_p2p_remote_evidence(&mut evidence, &verified, false, true);
        check_p2p_remote_signed_kem_refresh(&evidence)
    };

    for (metrics, expected_detail) in [
        (
            "latencyMs=501.0 jitterMs=3.0 successRatePct=100.0 applicationLossPct=0 retryCount=0",
            "latencyMsMax=Some(501.0)",
        ),
        (
            "latencyMs=82.5 jitterMs=51.0 successRatePct=100.0 applicationLossPct=0 retryCount=0",
            "jitterMsMax=Some(51.0)",
        ),
        (
            "latencyMs=82.5 jitterMs=3.0 successRatePct=100.0 applicationLossPct=0.6 retryCount=0",
            "applicationLossPctMax=Some(0.6)",
        ),
        (
            "latencyMs=82.5 jitterMs=3.0 successRatePct=100.0 applicationLossPct=0 retryCount=2",
            "retryCountMax=Some(2)",
        ),
    ] {
        let check = run_case(metrics);
        assert!(!check.ok, "{}", check.detail);
        assert!(check.detail.contains(expected_detail), "{}", check.detail);
    }
}
