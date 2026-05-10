import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class CrossNetworkWebRTCHandshakeBootstrapTests: XCTestCase {
    func testInitialWebRTCHandshakeStartsFromOffererOnly() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldInitiateInitialWebRTCHandshake(role: .offerer)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldInitiateInitialWebRTCHandshake(role: .answerer)
        )
    }

    func testInitialWebRTCHandshakeUsesClassicForAuthorityBoundQRAndCodeSessions() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "qr-session",
                authorityBoundBootstrapSessionIds: ["qr-session"],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: nil
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "code-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: "code-session"
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "answerer-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .ed25519,
                activeConnectionCodeSessionID: nil
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "pqc-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .mlDSA65,
                activeConnectionCodeSessionID: nil
            )
        )
    }

    func testStrictInboundInitialAllowsVerifiedAuthorityClassicBootstrapOnly() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: .ed25519
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: nil
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: .mlDSA65
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.mlkem768MLDSA65],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: .ed25519
            )
        )
    }

    func testInitialWebRTCHandshakePeerResolutionPrefersConcreteRemoteDeviceId() {
        let resolution = CrossNetworkConnectionManager.initialWebRTCHandshakePeerResolution(
            expectedRemoteDeviceId: nil,
            learnedRemoteDeviceId: "E0715A9A-D0D3-47E6-B353-DE0A30293E1F",
            endpointDescription: "webrtc:session-1"
        )

        XCTAssertEqual(resolution.resolvedPeerDeviceId, "E0715A9A-D0D3-47E6-B353-DE0A30293E1F")
        XCTAssertEqual(
            resolution.candidateIds,
            ["E0715A9A-D0D3-47E6-B353-DE0A30293E1F", "webrtc:session-1"]
        )
    }

    func testStrictPQCHandshakeWaitsUntilRemoteIdentityAndTrustedKEMAreReady() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldWaitForStrictPQCInitialWebRTCHandshake(
                strictPQCRequested: true,
                resolvedPeerDeviceId: nil,
                hasTrustedPeerKEM: false
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldWaitForStrictPQCInitialWebRTCHandshake(
                strictPQCRequested: true,
                resolvedPeerDeviceId: "peer-1",
                hasTrustedPeerKEM: false
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldWaitForStrictPQCInitialWebRTCHandshake(
                strictPQCRequested: true,
                resolvedPeerDeviceId: "peer-1",
                hasTrustedPeerKEM: true
            )
        )
    }

    func testWebRTCPQCRekeyPlansPreferXWingOnlyWhenPeerHasXWing() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        let mlkemOnlyPlans = CrossNetworkConnectionManager.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: false,
            peerHasXWing: false,
            appleXWingAvailable: true
        )
        XCTAssertEqual(mlkemOnlyPlans.first?.label, "native-pqc")
        XCTAssertEqual(mlkemOnlyPlans.first?.suites, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])

        let xwingPlans = CrossNetworkConnectionManager.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: false,
            peerHasXWing: true,
            appleXWingAvailable: true
        )
        XCTAssertEqual(xwingPlans.first?.label, "native-xwing")
        XCTAssertEqual(xwingPlans.first?.suites, [.xwingMLDSA])
    }

    func testWebRTCPQCRekeyPlansPreferApplePQCBeforeLiboqsForInteropPeers() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: true,
            hasLiboqs: true,
            osVersion: "test"
        )

        let plans = CrossNetworkConnectionManager.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: true,
            peerHasXWing: false,
            appleXWingAvailable: true
        )

        XCTAssertEqual(plans.first?.label, "native-pqc")
        XCTAssertEqual(plans.first?.suites, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])
        XCTAssertEqual(plans.dropFirst().first?.label, "liboqs-fallback")
    }

    func testWebRTCPQCRekeyPlansUseLiboqsWhenApplePQCUnavailable() {
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: false,
            hasLiboqs: true,
            osVersion: "test"
        )

        let plans = CrossNetworkConnectionManager.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: true,
            peerHasXWing: false,
            appleXWingAvailable: false
        )

        XCTAssertEqual(plans.first?.label, "liboqs")
        XCTAssertEqual(plans.first?.suites, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])
    }

    func testWebRTCInboundResponderFallsBackToClassicOnlyWhenPolicyAllowsIt() {
        let fallbackSelection = CrossNetworkConnectionManager.selectWebRTCInboundResponder(
            peerSupportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
            policy: HandshakePolicy(
                requirePQC: false,
                allowClassicFallback: false,
                minimumTier: .classic
            ),
            environment: MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: false)
        )

        XCTAssertNotNil(fallbackSelection)
        XCTAssertEqual(fallbackSelection?.selectionPolicy, .classicOnly)
        XCTAssertEqual(fallbackSelection?.cryptoProvider.tier, .classic)
        XCTAssertEqual(fallbackSelection?.sigAAlgorithm, .ed25519)
        XCTAssertTrue(fallbackSelection?.fellBackToClassic == true)
        XCTAssertTrue(fallbackSelection?.offeredSuites.allSatisfy { !$0.isPQCGroup } == true)
    }

    func testWebRTCInboundResponderRejectsClassicFallbackWhenStrictPQCRequiresLocalPQC() {
        let selection = CrossNetworkConnectionManager.selectWebRTCInboundResponder(
            peerSupportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
            policy: HandshakePolicy(
                requirePQC: true,
                allowClassicFallback: false,
                minimumTier: .nativePQC
            ),
            environment: MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: false)
        )

        XCTAssertNil(selection)
    }

    func testWebRTCInboundResponderUsesLiboqsWhenApplePQCUnavailableButLiboqsAvailable() {
        let selection = CrossNetworkConnectionManager.selectWebRTCInboundResponder(
            peerSupportedSuites: [.mlkem768MLDSA65, .x25519Ed25519],
            policy: HandshakePolicy(
                requirePQC: true,
                allowClassicFallback: false,
                minimumTier: .nativePQC
            ),
            environment: MockCryptoEnvironment(hasApplePQC: false, hasLiboqs: true)
        )

        XCTAssertEqual(selection?.selectionPolicy, .requirePQC)
        XCTAssertEqual(selection?.cryptoProvider.tier, .liboqsPQC)
        XCTAssertEqual(selection?.sigAAlgorithm, .mlDSA65)
        XCTAssertFalse(selection?.fellBackToClassic == true)
        XCTAssertTrue(selection?.offeredSuites.contains(where: { $0.isPQCGroup }) == true)
    }

    func testWebRTCPQCRekeySharedSuitesCanonicalizeMLKEMForwardSecureKeys() {
        let sharedFromBaseKey = CrossNetworkConnectionManager.webRTCPQCRekeySharedSuites(
            localPQCSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65],
            with: [CryptoSuite.mlkem768MLDSA65.wireId: Data([0x99])]
        )
        XCTAssertEqual(sharedFromBaseKey, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])

        let sharedFromFSKey = CrossNetworkConnectionManager.webRTCPQCRekeySharedSuites(
            localPQCSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65],
            with: [CryptoSuite.mlkem768MLDSA65FS.wireId: Data([0x98])]
        )
        XCTAssertEqual(sharedFromFSKey, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])
    }

    func testWebRTCPQCRekeySharedSuitesDoNotTreatXWingAsMLKEM() {
        let shared = CrossNetworkConnectionManager.webRTCPQCRekeySharedSuites(
            localPQCSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65],
            with: [CryptoSuite.xwingMLDSA.wireId: Data([0x42])]
        )
        XCTAssertTrue(shared.isEmpty)
    }

    func testRemoteJoinWakesAuthorityBoundOffererOnlyWhenSessionIsMissing() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldWakeOffererFromRemoteJoin(
                hasLocalSession: false,
                pendingOfferStart: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldWakeOffererFromRemoteJoin(
                hasLocalSession: true,
                pendingOfferStart: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldWakeOffererFromRemoteJoin(
                hasLocalSession: false,
                pendingOfferStart: true,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldWakeOffererFromRemoteJoin(
                hasLocalSession: false,
                pendingOfferStart: false,
                authorityBoundBootstrap: false,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldWakeOffererFromRemoteJoin(
                hasLocalSession: false,
                pendingOfferStart: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: false
            )
        )
    }

    func testRemoteJoinRecoversMissingOfferCacheOnlyForAuthorityBoundOfferer() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: true,
                isOfferer: true,
                hasCachedOffer: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: false,
                isOfferer: true,
                hasCachedOffer: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: true,
                isOfferer: false,
                hasCachedOffer: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: true,
                isOfferer: true,
                hasCachedOffer: true,
                authorityBoundBootstrap: true,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: true,
                isOfferer: true,
                hasCachedOffer: false,
                authorityBoundBootstrap: false,
                hasSignalingToken: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldRecoverMissingOfferCacheFromRemoteJoin(
                hasLocalSession: true,
                isOfferer: true,
                hasCachedOffer: false,
                authorityBoundBootstrap: true,
                hasSignalingToken: false
            )
        )
    }

    func testQRCodeBootstrapUsesLongerStartupWindowsThanRuntimeHeartbeat() {
        XCTAssertGreaterThanOrEqual(
            CrossNetworkConnectionManager.qrCodeGenerationWatchdogTimeoutSeconds,
            30
        )
        XCTAssertGreaterThanOrEqual(
            CrossNetworkConnectionManager.qrCodeScanBootstrapWatchdogTimeoutSeconds,
            90
        )
        XCTAssertGreaterThanOrEqual(
            CrossNetworkConnectionManager.webRTCStartupJoinHeartbeatAttempts,
            60
        )
    }

    func testStrictBootstrapOnlyAcceptsOnlyLivenessControlsBeforeRekey() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let bootstrapFilter = try sourceSlice(
            from: "let messageKind = bootstrapAppMessageKind(msg)",
            to: "case .pairingIdentityExchange(let rawPayload):",
            in: source
        )

        XCTAssertTrue(bootstrapFilter.contains("case .heartbeat(let payload):"))
        XCTAssertTrue(bootstrapFilter.contains("case .ping(let payload):"))
        XCTAssertTrue(bootstrapFilter.contains("case .pong, .peerDisconnecting:"))
        XCTAssertTrue(bootstrapFilter.contains("accepted control app message before PQC rekey"))
        XCTAssertTrue(bootstrapFilter.contains("type=\\(messageKind"))
        XCTAssertFalse(
            bootstrapFilter.contains("startScreenStreamingIfNeeded"),
            "Liveness/control messages may keep bootstrap alive, but must not start the media path before PQC rekey."
        )
    }

    func testActiveWebRTCRekeyFramesBypassBusinessDecryptAndRouteToDriver() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let receiveLoopPrefix = try sourceSlice(
            from: "let trafficUnwrapped = TrafficPadding.unwrapIfNeeded(payload, label: \"rx/webrtc\")",
            to: "if handshakeState.driver == nil {",
            in: source
        )
        let driverGate = try sourceSlice(
            from: "guard let activeDriver = handshakeState.driver else { continue }",
            to: "await activeDriver.handleMessage(frame, from: peer)",
            in: source
        )

        XCTAssertTrue(source.contains("func isActiveHandshakeDriverFrame(_ data: Data) -> Bool"))
        XCTAssertFalse(
            source.contains("frame.count >= 5, frame.first == HandshakeConstants.protocolVersion { return true }"),
            "Active rekey routing must not classify random AES-GCM business frames as handshake frames from a first-byte match alone."
        )
        XCTAssertTrue(
            receiveLoopPrefix.contains("!(handshakeState.driver != nil && isActiveHandshakeDriverFrame(frame))"),
            "Active PQC rekey MessageB/Finished frames must not be attempted as business AES-GCM payloads first."
        )
        XCTAssertTrue(
            driverGate.contains("guard isActiveHandshakeDriverFrame(frame) else"),
            "The active rekey driver should be the final validator for handshake-like control frames."
        )
    }

    func testIOSActiveWebRTCRekeyFramesBypassBusinessDecryptAndRouteToDriver() throws {
        let source = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )
        let receiveLoopPrefix = try sourceSlice(
            from: "let handshakeFrame = HandshakePadding.unwrapIfNeeded(",
            to: "let hasSessionKeys: Bool",
            in: source
        )
        let activeDriverBranch = try sourceSlice(
            from: "if let driver = handshakeDriver {",
            to: "if let messageB = try? HandshakeMessageB.decode(from: frame)",
            in: source
        )

        XCTAssertTrue(source.contains("func isActiveHandshakeDriverFrame(_ data: Data) -> Bool"))
        XCTAssertFalse(
            source.contains("frame.count >= 5, frame.first == HandshakeConstants.protocolVersion { return true }"),
            "iOS active rekey routing must not classify random AES-GCM business frames as handshake frames from a first-byte match alone."
        )
        XCTAssertTrue(
            receiveLoopPrefix.contains("isLikelyCompleteHandshakeControlPacket(handshakeFrame)")
        )
        XCTAssertTrue(
            receiveLoopPrefix.contains("hasActiveDriver && isActiveHandshakeDriverFrame(handshakeFrame)"),
            "Inbound PQC rekey frames on iOS must reach the handshake driver before business AES-GCM decoding."
        )
        XCTAssertTrue(
            activeDriverBranch.contains("guard isActiveHandshakeDriverFrame(frame) else"),
            "The iOS active rekey driver must not consume arbitrary post-bootstrap business frames."
        )
    }

    func testRelayOnlySmokeKeepsContinualICEGathering() throws {
        let macSource = try readSource("Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCSession.swift")
        let iosSource = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Core/RemoteConnection/WebRTC/WebRTCSession.swift"
        )

        for source in [macSource, iosSource] {
            XCTAssertTrue(source.contains("config.continualGatheringPolicy = .gatherContinually"))
            XCTAssertTrue(source.contains("config.iceTransportPolicy = .relay"))
            XCTAssertFalse(
                source.contains("config.continualGatheringPolicy = .gatherOnce"),
                "Relay-only TURN sessions still need continual gathering on mobile/cellular paths."
            )
        }
    }

    func testPairingTrustApprovalCoalescesDuplicatePromptAndPersistsAlwaysAllowByDeviceId() throws {
        let source = try readSource("Sources/SkyBridgeCore/Security/PairingTrustApprovalService.swift")

        XCTAssertTrue(source.contains("isSameTrustRequest(pendingRequest, request)"))
        XCTAssertTrue(source.contains("Pairing request coalesced with pending prompt"))
        XCTAssertTrue(source.contains("continuationByRequestId[pendingRequest.id, default: []].append(cont)"))
        XCTAssertTrue(source.contains("case .alwaysAllow, .reject:"))
        XCTAssertTrue(source.contains("policyByDeviceId[deviceId] = decision.rawValue"))
    }

    func testWebRTCPairingTrustUsesCurrentPathAuthorityBindingKey() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")

        XCTAssertTrue(source.contains("let policyBindingKey = self.currentPathExpectedRemoteAuthorityBySessionId[sessionID].flatMap"))
        XCTAssertTrue(source.contains("PairingTrustApprovalService.policyBindingKey"))
        XCTAssertTrue(source.contains("policyBindingKey: policyBindingKey"))
        XCTAssertTrue(source.contains("PairingTrustApprovalService.shared.updateVerificationCode"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sourceSlice(
        from startMarker: String,
        to endMarker: String,
        in source: String
    ) throws -> String {
        guard let start = source.range(of: startMarker)?.lowerBound,
              let end = source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound else {
            throw XCTSkip("Source marker not found")
        }
        return String(source[start..<end])
    }
}
