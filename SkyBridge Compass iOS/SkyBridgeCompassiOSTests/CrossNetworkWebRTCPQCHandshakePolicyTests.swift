import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class CrossNetworkWebRTCPQCHandshakePolicyTests: XCTestCase {
    func testStrictPQCRequestIsNotWeakenedByCompatibilityMode() {
        XCTAssertTrue(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldRequestStrictPQC(
                compatibilityModeEnabled: false
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldRequestStrictPQC(
                compatibilityModeEnabled: true
            )
        )
    }

    func testClassicBootstrapRetryOnlyCoversCryptoFailures() {
        XCTAssertTrue(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldRetryClassicBootstrap(
                after: HandshakeError.failed(.cryptoError("stale KEM"))
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldRetryClassicBootstrap(
                after: HandshakeError.emptyOfferedSuites
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldRetryClassicBootstrap(
                after: HandshakeError.failed(.timeout)
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldRetryClassicBootstrap(
                after: NSError(
                    domain: "CryptoKit.CryptoKitError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "CryptoKit.CryptoKitError error 3"]
                )
            ),
            "WebRTC classic retry must be based on typed HandshakeError failures, not localizedDescription string matching."
        )
        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.describeHandshakeError(
                HandshakeError.providerAlgorithmMismatch(provider: "native", algorithm: "mlkem")
            ),
            "providerAlgorithmMismatch(provider=native, algorithm=mlkem)"
        )
    }

    func testRekeyElectionCanonicalizesIdsAndRejectsPlaceholders() {
        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.canonicalPQCRekeyElectionDeviceId("  DEVICE-A  "),
            "device-a"
        )
        XCTAssertNil(CrossNetworkWebRTCPQCHandshakePolicy.canonicalPQCRekeyElectionDeviceId("webrtc-session"))
        XCTAssertNil(CrossNetworkWebRTCPQCHandshakePolicy.canonicalPQCRekeyElectionDeviceId("   "))
        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldInitiatePQCRekey(
                localDeviceId: "device-a",
                remoteDeviceId: "device-b"
            ),
            true
        )
        XCTAssertNil(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldInitiatePQCRekey(
                localDeviceId: "device-a",
                remoteDeviceId: "device-a"
            )
        )
    }

    func testTrustedKEMCoverageCanonicalizesForwardSecureMLKEMOnly() {
        let mlkemCoverage = CrossNetworkWebRTCPQCHandshakePolicy.resolveTrustedPeerKEMCoverage(
            requiredSuites: [.mlkem768fs, .mlkem768],
            trustedPeerKEM: [.mlkem768: Data([0x99])]
        )
        XCTAssertEqual(mlkemCoverage.availableSuites, [.mlkem768fs, .mlkem768])
        XCTAssertTrue(mlkemCoverage.missingSuites.isEmpty)

        let xwingCoverage = CrossNetworkWebRTCPQCHandshakePolicy.resolveTrustedPeerKEMCoverage(
            requiredSuites: [.mlkem768fs, .mlkem768],
            trustedPeerKEM: [.xwing: Data([0x42])]
        )
        XCTAssertTrue(xwingCoverage.availableSuites.isEmpty)
        XCTAssertEqual(xwingCoverage.missingSuites, [.mlkem768fs, .mlkem768])
    }

    func testStrictRekeyCandidatesKeepInteropSuitesAroundXWing() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.strictPQCRekeyCandidateSuites(
                capability: capability,
                selectedProviderSuites: [.xwing, .mlkem768fs],
                selectedProviderTier: .nativePQC,
                appleXWingAvailable: true
            ),
            [.xwing, .mlkem768fs, .mlkem768]
        )
        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.strictPQCRekeyCandidateSuites(
                capability: .init(hasApplePQC: false, hasLiboqs: true, osVersion: "test"),
                selectedProviderSuites: [.mlkem768fs, .mlkem768],
                selectedProviderTier: .liboqsPQC,
                appleXWingAvailable: false
            ),
            [.mlkem768fs, .mlkem768]
        )
    }

    func testRekeyProviderPlansPreferNativePQCBeforeFallbacks() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        let xwingPlans = CrossNetworkWebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: false,
            peerHasXWing: true,
            appleXWingAvailable: true
        )
        XCTAssertEqual(xwingPlans.map(\.label), ["native-xwing", "native-pqc", "liboqs-fallback"])

        let liboqsOnlyPlans = CrossNetworkWebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
            capability: .init(hasApplePQC: false, hasLiboqs: true, osVersion: "test"),
            prefersLiboqsForPeer: true,
            peerHasXWing: false,
            appleXWingAvailable: false
        )
        XCTAssertEqual(liboqsOnlyPlans.map(\.label), ["liboqs"])
    }

    func testInboundSelectionAndNegotiatedSuiteGatesRejectClassicAuthorityBootstrapInStrictPQC() {
        XCTAssertNil(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundPQCRekeySelectionPolicy(
                supportedSuites: [.qperiaptContextBound],
                strictPQCRequested: false,
                localPQCAvailable: true
            )
        )
        XCTAssertNil(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundInitialHandshakeSelectionPolicy(
                supportedSuites: [.qperiaptContextBound, .mlkem768],
                strictPQCRequested: false,
                localPQCAvailable: true,
                expectedRemoteAuthorityAlgorithm: .mlDSA65
            )
        )
        XCTAssertNil(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundPQCRekeySelectionPolicy(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: true
            )
        )
        XCTAssertNil(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundInitialHandshakeSelectionPolicy(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: true,
                expectedRemoteAuthorityAlgorithm: .ed25519
            )
        )
        XCTAssertNil(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundInitialHandshakeSelectionPolicy(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: true,
                expectedRemoteAuthorityAlgorithm: nil
            )
        )
        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundPQCRekeySelectionPolicy(
                supportedSuites: [.mlkem768, .x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: true
            ),
            .requirePQC
        )
        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundInitialHandshakeSelectionPolicy(
                supportedSuites: [.mlkem768, .x25519Ed25519],
                strictPQCRequested: true,
                localPQCAvailable: true,
                expectedRemoteAuthorityAlgorithm: .ed25519
            ),
            .requirePQC
        )
        XCTAssertFalse(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundInitialHandshakeNegotiatedSuiteAllowed(
                .x25519Ed25519,
                strictPQCRequested: true,
                allowsClassicAuthorityBootstrap: true
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundInitialHandshakeNegotiatedSuiteAllowed(
                .x25519Ed25519,
                strictPQCRequested: true,
                allowsClassicAuthorityBootstrap: false
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundPQCRekeyNegotiatedSuiteAllowed(
                .mlkem768,
                strictPQCRequested: true
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundPQCRekeyNegotiatedSuiteAllowed(
                .qperiaptContextBound,
                strictPQCRequested: false
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCPQCHandshakePolicy.inboundInitialHandshakeNegotiatedSuiteAllowed(
                .qperiaptContextBound,
                strictPQCRequested: false,
                allowsClassicAuthorityBootstrap: true
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: .ed25519
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: false,
                expectedRemoteAuthorityAlgorithm: .ed25519
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.qperiaptContextBound],
                strictPQCRequested: false,
                expectedRemoteAuthorityAlgorithm: .ed25519
            )
        )
    }

    func testInitialHandshakeRoleAndAuthorityBootstrapPolicy() {
        XCTAssertTrue(CrossNetworkWebRTCPQCHandshakePolicy.shouldInitiateInitialWebRTCHandshake(role: .offerer))
        XCTAssertFalse(CrossNetworkWebRTCPQCHandshakePolicy.shouldInitiateInitialWebRTCHandshake(role: .answerer))
        XCTAssertTrue(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionId: "qr-session",
                authorityBoundBootstrapSessionIds: ["qr-session"],
                expectedRemoteAuthorityAlgorithm: nil,
                localConnectionSessionId: nil
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionId: "code-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: nil,
                localConnectionSessionId: "code-session"
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionId: "pqc-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .mlDSA65,
                localConnectionSessionId: nil
            )
        )
    }

    func testInitialHandshakeBootstrapDecisionPreservesClassicAuthorityAndTrustedKEMModes() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: false,
                hasTrustedPeerKEMKey: true,
                capability: capability,
                useClassicAuthorityBootstrap: true,
                peerDeviceId: "peer-a"
            ),
            .proceed(.init(
                selection: .classicOnly,
                bootstrapMode: "classic_authority_bootstrap",
                usesClassicAuthorityBootstrap: true
            ))
        )
        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: false,
                hasTrustedPeerKEMKey: false,
                capability: capability,
                useClassicAuthorityBootstrap: false,
                peerDeviceId: "peer-a"
            ),
            .proceed(.init(
                selection: .classicOnly,
                bootstrapMode: "classic_bootstrap",
                usesClassicAuthorityBootstrap: false
            ))
        )
        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: false,
                hasTrustedPeerKEMKey: true,
                capability: capability,
                useClassicAuthorityBootstrap: false,
                peerDeviceId: "peer-a"
            ),
            .proceed(.init(
                selection: .requirePQC,
                bootstrapMode: "trusted_kem",
                usesClassicAuthorityBootstrap: false
            ))
        )
    }

    func testInitialHandshakeBootstrapDecisionRejectsStrictPQCWithoutTrustOrProvider() {
        let noProviderCapability = CryptoProviderFactory.Capability(
            hasApplePQC: false,
            hasLiboqs: false,
            osVersion: "test"
        )

        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: true,
                hasTrustedPeerKEMKey: false,
                capability: noProviderCapability,
                useClassicAuthorityBootstrap: false,
                peerDeviceId: "peer-b"
            ),
            .reject(.init(
                code: 41,
                message: "严格 PQC 已启用，但跨网对端缺少已信任的 KEM 公钥；当前已拒绝 classic bootstrap。peer=peer-b",
                includeProviderAvailabilityInLog: false
            ))
        )
        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: true,
                hasTrustedPeerKEMKey: true,
                capability: noProviderCapability,
                useClassicAuthorityBootstrap: false,
                peerDeviceId: "peer-b"
            ),
            .reject(.init(
                code: 42,
                message: "严格 PQC 已启用，但当前设备没有可用的 PQC Provider；跨网路径不会再降级到 Classic/PreferPQC。",
                includeProviderAvailabilityInLog: true
            ))
        )
    }

    func testInitialHandshakeBootstrapDecisionFallsBackToClassicWhenNonStrictHasNoLocalPQCProvider() {
        let noProviderCapability = CryptoProviderFactory.Capability(
            hasApplePQC: false,
            hasLiboqs: false,
            osVersion: "test"
        )

        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: false,
                hasTrustedPeerKEMKey: true,
                capability: noProviderCapability,
                useClassicAuthorityBootstrap: false,
                peerDeviceId: "peer-b"
            ),
            .proceed(.init(
                selection: .classicOnly,
                bootstrapMode: "classic_bootstrap_no_local_pqc_provider",
                usesClassicAuthorityBootstrap: false
            ))
        )
    }

    func testInitialHandshakeBootstrapDecisionRejectsStrictPQCClassicAuthorityBootstrap() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        XCTAssertEqual(
            CrossNetworkWebRTCPQCHandshakePolicy.initialWebRTCHandshakeBootstrapDecision(
                strictPQCRequested: true,
                hasTrustedPeerKEMKey: true,
                capability: capability,
                useClassicAuthorityBootstrap: true,
                peerDeviceId: "peer-c"
            ),
            .reject(.init(
                code: 43,
                message: "严格 PQC 已启用，但 WebRTC 初始握手请求 classic authority bootstrap；当前已拒绝 classic bootstrap。peer=peer-c",
                includeProviderAvailabilityInLog: false
            ))
        )
    }
}
