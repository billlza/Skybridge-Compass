use super::*;

#[test]
fn p2p_remote_protocol_identity_binding_requires_full_order_before_skr1() {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    for (line, is_mac, is_ios) in [
        (
            "strictPQC trust preflight failed: missing peer KEM suite=X-Wing reason=missing_pinned_identity_requires_oob",
            false,
            true,
        ),
        (
            "SKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request",
            false,
            true,
        ),
        (
            "SKR-1 signed LAN KEM refresh rejected requester=ios target=mac reasonCode=pinned_protocol_identity_mismatch_requires_oob lifecycle=request>rejected",
            true,
            false,
        ),
        (
            "PIB-1 protocol identity binding request: peer=mac endpoint=mac.local algorithms=ML-DSA-65 lifecycle=identity-oob>request",
            false,
            true,
        ),
        (
            "PIB-1 protocol identity binding served: requester=ios target=mac fingerprint=abc code=123456 lifecycle=identity-oob>served",
            true,
            false,
        ),
        (
            "PIB-1 protocol identity binding signature verified: peer=mac fingerprint=abc code=123456 lifecycle=identity-oob>verified",
            false,
            true,
        ),
        (
            "PIB-1 protocol identity binding pinned: peer=mac deviceId=id:mac fingerprint=abc lifecycle=identity-oob>pinned",
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
            "SKR-1 signed LAN KEM refresh verified and imported peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=82.5 jitterMs=3.0 successRatePct=100.0 applicationLossPct=0 retryCount=0 lifecycle=served>verified",
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

    let binding = check_p2p_remote_protocol_identity_binding(&evidence);
    assert!(binding.ok, "{}", binding.detail);
    assert!(binding.detail.contains("pibPinnedSeen=true"));
    let signed = check_p2p_remote_signed_kem_refresh(&evidence);
    assert!(!signed.ok, "{}", signed.detail);
    assert!(signed.detail.contains("rejectedSeen=true"));

    let mut missing_pin = P2pRemotePerformanceEvidence::default();
    for (line, is_mac, is_ios) in [
        (
            "strictPQC trust preflight failed: missing peer KEM suite=X-Wing reason=missing_pinned_identity_requires_oob",
            false,
            true,
        ),
        (
            "PIB-1 protocol identity binding request: peer=mac lifecycle=identity-oob>request",
            false,
            true,
        ),
        (
            "PIB-1 protocol identity binding served: requester=ios target=mac fingerprint=abc lifecycle=identity-oob>served",
            true,
            false,
        ),
        (
            "PIB-1 protocol identity binding signature verified: peer=mac fingerprint=abc lifecycle=identity-oob>verified",
            false,
            true,
        ),
        (
            "SKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request",
            false,
            true,
        ),
    ] {
        update_p2p_remote_evidence(&mut missing_pin, line, is_mac, is_ios);
    }

    let binding = check_p2p_remote_protocol_identity_binding(&missing_pin);
    assert!(!binding.ok, "{}", binding.detail);
    assert!(binding.detail.contains("pibPinnedSeen=false"));
    let signed = check_p2p_remote_signed_kem_refresh(&missing_pin);
    assert!(!signed.ok, "{}", signed.detail);
}
