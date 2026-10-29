use super::*;

#[test]
fn p2p_remote_signed_kem_refresh_requires_verified_signed_lifecycle_metrics() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    for (line, is_mac, is_ios) in [
        (
            "strictPQC trust preflight failed: missing peer KEM suite=X-Wing",
            false,
            true,
        ),
        (
            "🔐 PIB-1 protocol identity binding request: peer=mac endpoint=mac.local algorithms=ML-DSA-65 lifecycle=identity-oob>request",
            false,
            true,
        ),
        (
            "🔐 PIB-1 protocol identity binding served: requester=ios target=mac fingerprint=abc code=123456 lifecycle=identity-oob>served",
            true,
            false,
        ),
        (
            "🔐 PIB-1 protocol identity binding signature verified: peer=mac fingerprint=abc code=123456 lifecycle=identity-oob>verified",
            false,
            true,
        ),
        (
            "🔐 PIB-1 protocol identity binding pinned: peer=mac deviceId=id:mac fingerprint=abc lifecycle=identity-oob>pinned",
            false,
            true,
        ),
        (
            "🔐 SKR-1 signed LAN KEM refresh request: peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request",
            false,
            true,
        ),
        (
            "🔐 SKR-1 signed LAN KEM refresh served: requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served",
            true,
            false,
        ),
        (
            "🔐 SKR-1 signed LAN KEM refresh verified and imported: peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=82.5 jitterMs=3.0 successRatePct=100.0 applicationLossPct=0 retryCount=0 lifecycle=served>verified",
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
    assert!(check.ok, "{}", check.detail);
}

#[test]
fn p2p_remote_signed_kem_refresh_rejects_unsigned_or_missing_metrics() {
    let mut unsigned = P2pRemotePerformanceEvidence::default();
    for (line, is_mac, is_ios) in [
        (
            "strictPQC trust preflight failed: missing peer KEM suite=X-Wing",
            false,
            true,
        ),
        (
            "SKR-1 signed LAN KEM refresh request suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1",
            false,
            true,
        ),
        (
            "SKR-1 signed LAN KEM refresh verified and imported suites=X-Wing wireId=0x0001 unsigned self-asserted tofu",
            false,
            true,
        ),
        (
            "mac remote established peer=iPhone suite=X-Wing route=lan-direct",
            true,
            false,
        ),
    ] {
        update_p2p_remote_evidence(&mut unsigned, line, is_mac, is_ios);
    }

    let check = check_p2p_remote_signed_kem_refresh(&unsigned);
    assert!(!check.ok, "{}", check.detail);
    assert!(check.detail.contains("unsignedOrTOFU=true"));
    assert!(check.detail.contains("latencyMsMax=None"));
    assert!(check.detail.contains("macServedSeen=false"));
}

#[test]
fn signed_kem_refresh_parser_ignores_empty_unsigned_or_unproven_summary() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    update_p2p_remote_evidence(
        &mut evidence,
        "failed stage=pqc-trust-preflight error=strictPQC trust preflight failed: missing peer KEM suite=X-Wing signedRefreshRequired=1 unsignedOrUnprovenSuites=- 已尝试 signed LAN KEM refresh 但失败 stage=kem_refresh reason=PIB-1 approval timed out",
        false,
        true,
    );

    let check = check_p2p_remote_signed_kem_refresh(&evidence);
    assert!(
        check.detail.contains("unsignedOrTOFU=false"),
        "{}",
        check.detail
    );
}
