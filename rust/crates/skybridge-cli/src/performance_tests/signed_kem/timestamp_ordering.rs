use super::*;

#[test]
fn p2p_remote_signed_kem_refresh_orders_ios_local_console_timestamps() -> Result<()> {
    let artifact_dir = make_test_dir("p2p-remote-local-console-skr-order")?;
    let anchor = OffsetDateTime::parse(
        "2026-05-16T19:11:57.596Z",
        &time::format_description::well_known::Rfc3339,
    )?;
    let offset = UtcOffset::current_local_offset().unwrap_or(UtcOffset::UTC);
    let local_stamp = |millis: i64| {
        let local = (OffsetDateTime::parse(
            "2026-05-16T19:11:19.800Z",
            &time::format_description::well_known::Rfc3339,
        )
        .expect("base timestamp")
            + time::Duration::milliseconds(millis))
        .to_offset(offset)
        .time();
        format!(
            "[{:02}:{:02}:{:02}.{:03}]",
            local.hour(),
            local.minute(),
            local.second(),
            local.millisecond()
        )
    };
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-16T19:11:19.875Z] PIB-1 protocol identity binding served: requester=ios target=mac fingerprint=abc code=123456 lifecycle=identity-oob>served\n\
         [2026-05-16T19:11:19.909Z] SKR-1 signed LAN KEM refresh served: requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served\n\
         [2026-05-16T19:11:20.471Z] mac remote established peer=iPhone suite=X-Wing route=lan-direct\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-p2p-remote-LOCAL.status.log"),
        format!(
            "{} strictPQC trust preflight failed: missing peer KEM suite=X-Wing reason=missing_pinned_identity_requires_oob\n\
             {} SKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request\n\
             {} PIB-1 protocol identity binding request: peer=mac endpoint=mac.local algorithms=ML-DSA-65 lifecycle=identity-oob>request\n\
             {} PIB-1 protocol identity binding signature verified: peer=mac fingerprint=abc code=123456 lifecycle=identity-oob>verified\n\
             {} PIB-1 protocol identity binding pinned: peer=mac deviceId=id:mac fingerprint=abc lifecycle=identity-oob>pinned\n\
             {} SKR-1 signed LAN KEM refresh request: peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request\n\
             {} SKR-1 signed LAN KEM refresh verified and imported: peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=32.4 jitterMs=0.0 successRatePct=100.0 applicationLossPct=0.0 retryCount=0 lifecycle=served>verified\n\
             [{}] remote-desktop-pass seconds=10 requestedSeconds=10 fps=60.0 rxFps=60.0 windowSeconds=10.0 windowFPS=60.0 windowRxFps=60.0 windowDisplayedFrames=600 windowReceivedFrames=600 min2sDisplayFrames=118 min2sRxFrames=118 twoSecondRequiredFrames=118 rollingCadencePass=1 frame=2056x1329\n",
            local_stamp(67),
            local_stamp(108),
            local_stamp(85),
            local_stamp(95),
            local_stamp(97),
            local_stamp(108),
            local_stamp(131),
            anchor.format(&time::format_description::well_known::Rfc3339)?
        ),
    )?;

    let evidence = read_p2p_remote_performance_evidence(&artifact_dir)?;
    let binding = check_p2p_remote_protocol_identity_binding(&evidence);
    assert!(binding.ok, "{}", binding.detail);
    let signed = check_p2p_remote_signed_kem_refresh(&evidence);
    assert!(signed.ok, "{}", signed.detail);
    assert!(signed.detail.contains("latestRequestSeq=Some"));
    Ok(())
}

#[test]
fn signed_kem_refresh_allows_small_cross_device_clock_skew_only() -> Result<()> {
    let mut evidence = P2pRemotePerformanceEvidence::default();
    for (line, is_mac, is_ios) in [
        (
            "strictPQC trust preflight failed: missing peer KEM suite=X-Wing",
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
            "SKR-1 signed LAN KEM refresh verified and imported peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=30.9 jitterMs=0.0 successRatePct=100.0 applicationLossPct=0.0 retryCount=0 lifecycle=served>verified",
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

    let verified_at = OffsetDateTime::parse(
        "2026-05-16T19:56:23.602Z",
        &time::format_description::well_known::Rfc3339,
    )?;
    evidence.signed_kem_refresh.verified_imported_observed_at = Some(verified_at);
    evidence.signed_kem_refresh.served_observed_at =
        Some(verified_at + time::Duration::milliseconds(33));
    evidence
        .signed_kem_refresh
        .verified_imported_timestamp_has_fractional_seconds = true;
    evidence
        .signed_kem_refresh
        .served_timestamp_has_fractional_seconds = true;

    let signed = check_p2p_remote_signed_kem_refresh(&evidence);
    assert!(signed.ok, "{}", signed.detail);

    evidence.signed_kem_refresh.served_observed_at =
        Some(verified_at + time::Duration::milliseconds(700));
    let signed = check_p2p_remote_signed_kem_refresh(&evidence);
    assert!(!signed.ok, "{}", signed.detail);
    Ok(())
}
