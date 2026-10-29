use super::*;

#[test]
fn file_transfer_artifact_requires_signed_kem_refresh() -> Result<()> {
    let artifact_dir = make_test_dir("file-transfer-signed-kem-refresh")?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\nsuite peer=id:peer suite=X-Wing\nfile-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\nfile-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "boot role=ios-p2p-client target=mac\nfile-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let args = PerformanceCheckArgs {
        kind: PerformanceKindArg::FileTransfer,
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
    let report = build_file_transfer_performance_report(&args)?;
    let signed = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(!signed.ok, "{}", signed.detail);
    assert!(signed.detail.contains("requestSeen=false"));
    assert!(signed.detail.contains("verifiedImported=false"));

    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\npairingIdentityExchange peer=ios keys=1\nsuite peer=id:peer suite=X-Wing\nfile-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\nfile-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "boot role=ios-p2p-client target=mac\npairingIdentityExchange peer=mac keys=1\nfile-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let pairing_only = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(!pairing_only.ok, "{}", pairing_only.detail);
    assert!(pairing_only.detail.contains("requestSeen=false"));
    assert!(pairing_only.detail.contains("verifiedImported=false"));

    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "[2026-05-16T01:00:00.000Z] strictPQC trust preflight failed: missing peer KEM suite=X-Wing\n[2026-05-16T01:00:00.010Z] SKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request\n[2026-05-16T01:00:00.020Z] boot role=ios-p2p-client target=mac\n[2026-05-16T01:00:00.200Z] SKR-1 signed LAN KEM refresh verified and imported peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=72.0 jitterMs=2.0 successRatePct=100.0 applicationLossPct=0 retryCount=0 lifecycle=served>verified\n[2026-05-16T01:00:00.300Z] file-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:00:00.310Z] file-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:00:00.320Z] success suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-16T01:00:00.005Z] boot role=mac-p2p-host\n[2026-05-16T01:00:00.100Z] SKR-1 signed LAN KEM refresh served requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served\n[2026-05-16T01:00:00.250Z] suite peer=id:peer suite=X-Wing\n[2026-05-16T01:00:00.260Z] file-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:00:00.270Z] file-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\n[2026-05-16T01:00:00.280Z] file-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:00:00.330Z] success peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let signed = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(!signed.ok, "{}", signed.detail);
    assert!(signed.detail.contains("signatureVerified=true"));
    assert!(signed.detail.contains("pibRequiredOk=false"));
    assert!(signed.detail.contains("pibSatisfiedBySKR=false"));
    assert!(signed.detail.contains("pibRequestSeen=false"));

    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "[2026-05-16T01:00:00.000Z] strictPQC trust preflight failed: missing peer KEM suite=X-Wing reason=missing_pinned_identity_requires_oob\n[2026-05-16T01:00:00.010Z] PIB-1 protocol identity binding request: peer=mac lifecycle=identity-oob>request\n[2026-05-16T01:00:00.200Z] PIB-1 protocol identity binding signature verified: peer=mac fingerprint=abc code=123456 lifecycle=identity-oob>verified\n[2026-05-16T01:00:00.240Z] PIB-1 protocol identity binding pinned: peer=mac deviceId=id:mac fingerprint=abc lifecycle=identity-oob>pinned\n[2026-05-16T01:00:00.260Z] SKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request\n[2026-05-16T01:00:00.360Z] boot role=ios-p2p-client target=mac\n[2026-05-16T01:00:00.520Z] SKR-1 signed LAN KEM refresh verified and imported peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=72.0 jitterMs=2.0 successRatePct=100.0 applicationLossPct=0 retryCount=0 lifecycle=served>verified\n[2026-05-16T01:00:00.600Z] file-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:00:00.610Z] file-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:00:00.620Z] success suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-16T01:00:00.005Z] boot role=mac-p2p-host\n[2026-05-16T01:00:00.100Z] PIB-1 protocol identity binding served: requester=ios target=mac fingerprint=abc code=123456 lifecycle=identity-oob>served\n[2026-05-16T01:00:00.420Z] SKR-1 signed LAN KEM refresh served requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served\n[2026-05-16T01:00:00.550Z] suite peer=id:peer suite=X-Wing\n[2026-05-16T01:00:00.560Z] file-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:00:00.570Z] file-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\n[2026-05-16T01:00:00.580Z] file-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:00:00.630Z] success peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let binding = doctor_check(&report, "file_transfer_protocol_identity_binding");
    assert!(binding.ok, "{}", binding.detail);
    assert!(binding.detail.contains("pibPinnedSeen=true"));
    let signed = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(signed.ok, "{}", signed.detail);

    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "[2026-05-16T01:00:00.000Z] boot role=ios-p2p-client target=mac\n[2026-05-16T01:00:00.005Z] strictPQC trust preflight failed: missing peer KEM suite=X-Wing reason=missing_pinned_identity_requires_oob\n[2026-05-16T01:00:00.010Z] SKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 requesterProtocolIdentity=ios suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 missingPeerKEM=1 lifecycle=missing-kem>request\n[2026-05-16T01:00:00.050Z] SKR-1 signed LAN KEM refresh verified and imported peer=mac protocolIdentityFingerprint=abc suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=72.0 jitterMs=2.0 successRatePct=100.0 applicationLossPct=0 retryCount=0 lifecycle=served>verified\n[2026-05-16T01:00:00.060Z] SKR-1 signed LAN KEM refresh smoke-evidence: peer=mac source=signed_lan_kem_refresh signingFingerprint=abc suites=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound strictXWingEstablished=1 lifecycle=verified>smoke-proof\n[2026-05-16T01:00:00.600Z] file-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:00:00.610Z] file-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:00:00.620Z] success suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-16T01:00:00.001Z] boot role=mac-p2p-host\n[2026-05-16T01:00:00.020Z] PIB-1 requester protocol identity pinned: requester=ios fingerprint=requester-abc code=123456 operator=smoke-auto-approve lifecycle=identity-oob>requester-pinned\n[2026-05-16T01:00:00.030Z] PIB-1 protocol identity binding served: requester=ios target=mac fingerprint=abc code=123456 lifecycle=identity-oob>served\n[2026-05-16T01:00:00.040Z] SKR-1 signed LAN KEM refresh served requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served\n[2026-05-16T01:00:00.550Z] suite peer=id:peer suite=X-Wing\n[2026-05-16T01:00:00.560Z] file-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:00:00.570Z] file-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\n[2026-05-16T01:00:00.580Z] file-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:00:00.630Z] success peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let binding = doctor_check(&report, "file_transfer_protocol_identity_binding");
    assert!(binding.ok, "{}", binding.detail);
    assert!(binding.detail.contains("pibRequesterPinnedSeen=true"));
    assert!(binding.detail.contains("pibVerifiedSeen=false"));
    assert!(binding.detail.contains("pibPinnedSeen=false"));
    assert!(binding.detail.contains("pibSatisfiedBySKR=true"));
    let signed = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(signed.ok, "{}", signed.detail);

    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "[2026-05-16T01:00:00.000Z] strictPQC trust preflight failed: missing peer KEM suite=X-Wing reason=missing_pinned_identity_requires_oob\n[2026-05-16T01:00:00.010Z] PIB-1 protocol identity binding request: peer=evil lifecycle=identity-oob>request\n[2026-05-16T01:00:00.200Z] PIB-1 protocol identity binding signature verified: peer=evil fingerprint=abc code=123456 lifecycle=identity-oob>verified\n[2026-05-16T01:00:00.240Z] PIB-1 protocol identity binding pinned: peer=evil deviceId=id:evil fingerprint=abc lifecycle=identity-oob>pinned\n[2026-05-16T01:00:00.260Z] SKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request\n[2026-05-16T01:00:00.360Z] boot role=ios-p2p-client target=mac\n[2026-05-16T01:00:00.520Z] SKR-1 signed LAN KEM refresh verified and imported peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=72.0 jitterMs=2.0 successRatePct=100.0 applicationLossPct=0 retryCount=0 lifecycle=served>verified\n[2026-05-16T01:00:00.600Z] file-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:00:00.610Z] file-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:00:00.620Z] success suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-16T01:00:00.005Z] boot role=mac-p2p-host\n[2026-05-16T01:00:00.100Z] PIB-1 protocol identity binding served: requester=ios target=evil fingerprint=abc code=123456 lifecycle=identity-oob>served\n[2026-05-16T01:00:00.420Z] SKR-1 signed LAN KEM refresh served requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served\n[2026-05-16T01:00:00.550Z] suite peer=id:peer suite=X-Wing\n[2026-05-16T01:00:00.560Z] file-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:00:00.570Z] file-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\n[2026-05-16T01:00:00.580Z] file-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:00:00.630Z] success peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let binding = doctor_check(&report, "file_transfer_protocol_identity_binding");
    assert!(!binding.ok, "{}", binding.detail);
    let signed = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(!signed.ok, "{}", signed.detail);
    assert!(signed.detail.contains("pibSkrIdentityBound=false"));

    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "[2026-05-16T01:00:00.000Z] strictPQC trust preflight failed: missing peer KEM suite=X-Wing reason=missing_pinned_identity_requires_oob\n[2026-05-16T01:00:00.010Z] PIB-1 protocol identity binding request: peer=mac lifecycle=identity-oob>request\n[2026-05-16T01:00:00.200Z] PIB-1 protocol identity binding signature verified: peer=mac fingerprint=abc code=123456 lifecycle=identity-oob>verified\n[2026-05-16T01:02:00.000Z] failed stage=timeout error=ios_local_p2p_smoke_timeout\n",
    )?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-16T01:00:00.005Z] boot role=mac-p2p-host\n[2026-05-16T01:00:00.100Z] PIB-1 protocol identity binding served: requester=ios target=mac fingerprint=abc code=123456 lifecycle=identity-oob>served\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let binding = doctor_check(&report, "file_transfer_protocol_identity_binding");
    assert!(!binding.ok, "{}", binding.detail);
    assert!(binding.detail.contains("pibVerifiedSeen=true"));
    assert!(binding.detail.contains("pibPinnedSeen=false"));
    assert_eq!(
        report.fault_stage,
        Some("protocol_identity_binding_approval_missing")
    );

    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "[2026-05-16T01:01:00.000Z] strictPQC trust preflight failed: missing peer KEM suite=X-Wing reason=missing_pinned_identity_requires_oob\n[2026-05-16T01:01:00.002Z] PIB-1 protocol identity binding request: peer=mac lifecycle=identity-oob>request\n[2026-05-16T01:01:00.006Z] PIB-1 protocol identity binding signature verified: peer=mac fingerprint=abc code=123456 lifecycle=identity-oob>verified\n[2026-05-16T01:01:00.008Z] PIB-1 protocol identity binding pinned: peer=mac deviceId=id:mac fingerprint=abc lifecycle=identity-oob>pinned\n[2026-05-16T01:01:00.010Z] SKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request\n[2026-05-16T01:01:00.020Z] boot role=ios-p2p-client target=mac\n[2026-05-16T01:01:00.100Z] SKR-1 signed LAN KEM refresh verified and imported peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=72.0 jitterMs=2.0 applicationLossPct=0 retryCount=0 lifecycle=served>verified\n[2026-05-16T01:01:00.200Z] file-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:01:00.210Z] file-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:01:00.220Z] success suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-16T01:01:00.001Z] boot role=mac-p2p-host\n[2026-05-16T01:01:00.004Z] PIB-1 protocol identity binding served: requester=ios target=mac fingerprint=abc code=123456 lifecycle=identity-oob>served\n[2026-05-16T01:01:00.800Z] SKR-1 signed LAN KEM refresh served requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served\n[2026-05-16T01:01:00.810Z] suite peer=id:peer suite=X-Wing\n[2026-05-16T01:01:00.820Z] file-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:01:00.830Z] file-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\n[2026-05-16T01:01:00.840Z] file-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:01:00.850Z] success peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let skewed_served = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(!skewed_served.ok, "{}", skewed_served.detail);
    assert!(skewed_served.detail.contains("servedSeq=Some"));
    assert!(skewed_served.detail.contains("verifiedSeq=Some"));

    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "[2026-05-16T01:01:00Z] strictPQC trust preflight failed: missing peer KEM suite=X-Wing reason=missing_pinned_identity_requires_oob\n[2026-05-16T01:01:00Z] PIB-1 protocol identity binding request: peer=mac lifecycle=identity-oob>request\n[2026-05-16T01:01:00Z] PIB-1 protocol identity binding signature verified: peer=mac fingerprint=abc code=123456 lifecycle=identity-oob>verified\n[2026-05-16T01:01:00Z] PIB-1 protocol identity binding pinned: peer=mac deviceId=id:mac fingerprint=abc lifecycle=identity-oob>pinned\n[2026-05-16T01:01:00Z] SKR-1 signed LAN KEM refresh request peer=mac endpoint=192.168.0.2:51234 selectedEndpointClass=direct-host selectedEndpointDirect=1 directHostCandidate=1 suites=X-Wing suiteWireIds=0x0001 pinnedProtocolIdentity=1 lifecycle=missing-kem>request\n[2026-05-16T01:01:00Z] boot role=ios-p2p-client target=mac\n[2026-05-16T01:01:00Z] SKR-1 signed LAN KEM refresh verified and imported peer=mac suites=X-Wing wireId=0x0001 pinnedProtocolIdentity=1 signature=verified requestHash=bound latencyMs=72.0 jitterMs=2.0 applicationLossPct=0 retryCount=0 lifecycle=served>verified\n[2026-05-16T01:01:00.500Z] file-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:01:00.510Z] file-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:01:00.520Z] success suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-16T01:01:00.005Z] boot role=mac-p2p-host\n[2026-05-16T01:01:00.006Z] PIB-1 protocol identity binding served: requester=ios target=mac fingerprint=abc code=123456 lifecycle=identity-oob>served\n[2026-05-16T01:01:00.300Z] SKR-1 signed LAN KEM refresh served requester=ios target=mac keyId=skr1 generation=100 suites=0x0001 wireId=0x0001 lifecycle=request>served\n[2026-05-16T01:01:00.310Z] suite peer=id:peer suite=X-Wing\n[2026-05-16T01:01:00.320Z] file-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:01:00.330Z] file-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\n[2026-05-16T01:01:00.340Z] file-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:01:00.530Z] success peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let coarse_ios_verified = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(coarse_ios_verified.ok, "{}", coarse_ios_verified.detail);

    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "[2026-05-16T01:01:00.005Z] boot role=mac-p2p-host\n[2026-05-16T01:01:00.006Z] PIB-1 protocol identity binding served: requester=ios target=mac fingerprint=abc code=123456 lifecycle=identity-oob>served\n[2026-05-16T01:01:00.310Z] suite peer=id:peer suite=X-Wing\n[2026-05-16T01:01:00.320Z] file-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[2026-05-16T01:01:00.330Z] file-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\n[2026-05-16T01:01:00.340Z] file-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n[2026-05-16T01:01:00.350Z] success peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let missing_served = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(!missing_served.ok, "{}", missing_served.detail);
    assert!(missing_served.detail.contains("macServedSeen=false"));

    std::fs::write(
        artifact_dir.join("mac.status.log"),
        "boot role=mac-p2p-host\nqr-connect-link mode=offline-p2p-kem suites=0x0001\nsuite peer=id:peer suite=X-Wing\nfile-transfer inbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer outbound-route-probe source=bonjour-transfer host=mac.local. port=8080\nfile-transfer outbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess peer=id:peer suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    std::fs::write(
        artifact_dir.join("ios-real-device-RUN.status.log"),
        "boot role=ios-p2p-client target=mac\nfile-transfer outbound-complete name=ios-smoke-RUN.txt sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nfile-transfer inbound-complete name=mac-smoke-RUN.txt sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsuccess suite=X-Wing handshakeOnly=1 fileTransfer=1 macReconnect=0\n",
    )?;
    let report = build_file_transfer_performance_report(&args)?;
    let qr = doctor_check(&report, "file_transfer_signed_kem_refresh");
    assert!(!qr.ok, "{}", qr.detail);
    assert!(qr.detail.contains("qrConnectLinkSeen=true"));
    Ok(())
}
