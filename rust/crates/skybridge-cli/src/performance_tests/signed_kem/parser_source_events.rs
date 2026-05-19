use super::*;

#[test]
fn signed_kem_refresh_parser_requires_distinct_source_events() {
    let mut evidence = SignedKEMRefreshEvidence::default();

    let ios_verified = "SKR-1 signed LAN KEM refresh verified and imported suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=72 jitterMs=2 applicationLossPct=0 retryCount=0 lifecycle=served>verified";
    update_signed_kem_refresh_evidence(
        &mut evidence,
        ios_verified,
        &ios_verified.to_ascii_lowercase(),
        false,
        true,
        None,
    );
    assert!(evidence.verified_imported_seen);
    assert!(evidence.ios_verified_imported_seen);
    assert!(!evidence.served_seen);
    assert!(!evidence.mac_served_seen);
    assert!(!evidence.request_seen);

    let mac_request = "SKR-1 signed LAN KEM refresh request suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request";
    update_signed_kem_refresh_evidence(
        &mut evidence,
        mac_request,
        &mac_request.to_ascii_lowercase(),
        true,
        false,
        None,
    );
    assert!(!evidence.request_seen);
    assert!(!evidence.ios_request_seen);

    let mac_served = "SKR-1 signed LAN KEM refresh served requester=ios target=mac suites=0x0001 wireId=0x0001 lifecycle=request>served";
    update_signed_kem_refresh_evidence(
        &mut evidence,
        mac_served,
        &mac_served.to_ascii_lowercase(),
        true,
        false,
        None,
    );
    assert!(evidence.served_seen);
    assert!(evidence.mac_served_seen);
}
