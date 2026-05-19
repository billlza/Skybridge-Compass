import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class CrossNetworkWebRTCHandshakeBootstrapTests: XCTestCase {
    func testInitialWebRTCHandshakeStartsFromOffererOnly() {
        XCTAssertTrue(
            WebRTCPQCHandshakePolicy.shouldInitiateInitialWebRTCHandshake(role: .offerer)
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldInitiateInitialWebRTCHandshake(role: .answerer)
        )
    }

    func testInitialWebRTCHandshakeUsesClassicForAuthorityBoundQRAndCodeSessions() {
        XCTAssertTrue(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "qr-session",
                authorityBoundBootstrapSessionIds: ["qr-session"],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: nil
            )
        )
        XCTAssertTrue(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "code-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: "code-session"
            )
        )
        XCTAssertTrue(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "answerer-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .ed25519,
                activeConnectionCodeSessionID: nil
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "pqc-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .mlDSA65,
                activeConnectionCodeSessionID: nil
            )
        )
    }

    func testStrictPQCInitialWebRTCHandshakeDoesNotUseClassicAuthorityBootstrap() {
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "qr-session",
                authorityBoundBootstrapSessionIds: ["qr-session"],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: nil,
                strictPQCRequested: true
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "code-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: "code-session",
                strictPQCRequested: true
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "answerer-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .ed25519,
                activeConnectionCodeSessionID: nil,
                strictPQCRequested: true
            )
        )
    }

    func testStrictInboundInitialRejectsClassicAuthorityBootstrap() {
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: .ed25519
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: nil
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.x25519Ed25519],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: .mlDSA65
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldAllowClassicAuthorityBootstrapForInboundInitialWebRTCHandshake(
                supportedSuites: [.mlkem768MLDSA65],
                strictPQCRequested: true,
                expectedRemoteAuthorityAlgorithm: .ed25519
            )
        )
    }

    func testInitialWebRTCHandshakePeerResolutionPrefersConcreteRemoteDeviceId() {
        let resolution = WebRTCPQCHandshakePolicy.initialWebRTCHandshakePeerResolution(
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
            WebRTCPQCHandshakePolicy.shouldWaitForStrictPQCInitialWebRTCHandshake(
                strictPQCRequested: true,
                resolvedPeerDeviceId: nil,
                hasTrustedPeerKEM: false
            )
        )
        XCTAssertTrue(
            WebRTCPQCHandshakePolicy.shouldWaitForStrictPQCInitialWebRTCHandshake(
                strictPQCRequested: true,
                resolvedPeerDeviceId: "peer-1",
                hasTrustedPeerKEM: false
            )
        )
        XCTAssertFalse(
            WebRTCPQCHandshakePolicy.shouldWaitForStrictPQCInitialWebRTCHandshake(
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

        let mlkemOnlyPlans = WebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
            capability: capability,
            prefersLiboqsForPeer: false,
            peerHasXWing: false,
            appleXWingAvailable: true
        )
        XCTAssertEqual(mlkemOnlyPlans.first?.label, "native-pqc")
        XCTAssertEqual(mlkemOnlyPlans.first?.suites, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])

        let xwingPlans = WebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
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

        let plans = WebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
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

        let plans = WebRTCPQCHandshakePolicy.webRTCPQCRekeyProviderPlans(
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
        let sharedFromBaseKey = WebRTCPQCHandshakePolicy.webRTCPQCRekeySharedSuites(
            localPQCSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65],
            with: [CryptoSuite.mlkem768MLDSA65.wireId: Data([0x99])]
        )
        XCTAssertEqual(sharedFromBaseKey, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])

        let sharedFromFSKey = WebRTCPQCHandshakePolicy.webRTCPQCRekeySharedSuites(
            localPQCSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65],
            with: [CryptoSuite.mlkem768MLDSA65FS.wireId: Data([0x98])]
        )
        XCTAssertEqual(sharedFromFSKey, [.mlkem768MLDSA65FS, .mlkem768MLDSA65])
    }

    func testWebRTCPQCRekeySharedSuitesDoNotTreatXWingAsMLKEM() {
        let shared = WebRTCPQCHandshakePolicy.webRTCPQCRekeySharedSuites(
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

    func testLocalP2PKEMBootstrapQRCodePathIsRemoved() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let harness = try readSource("Sources/SkyBridgeCompassApp/LocalP2PFileTransferSmokeHarness.swift")

        XCTAssertFalse(
            source.contains("generateSignedP2PKEMBootstrapQRCode"),
            "P2P KEM recovery must not expose an offline QR generator; stale KEM repair must use SKR-1."
        )
        XCTAssertTrue(source.contains("isP2PKEMBootstrapCapability"))
        XCTAssertTrue(source.contains("P2P KEM QR bootstrap has been removed"))
        XCTAssertTrue(
            source.contains("logVerifiedQRCodeKEMIgnored"),
            "Verified QR material may support route setup, but it must not be persisted as P2P KEM trust."
        )
        XCTAssertTrue(source.contains("不会导入 KEM trust"))
        XCTAssertFalse(
            source.contains("persistVerifiedQRCodeKEMTrust"),
            "A verified QR must not write KEM trust; stale KEM repair must use signed LAN refresh evidence."
        )
        XCTAssertFalse(
            harness.contains("qr-connect-link mode=offline-p2p-kem"),
            "The local file-transfer smoke host must not emit an offline P2P KEM QR link."
        )
        XCTAssertFalse(
            harness.contains("SKYBRIDGE_SMOKE_QR_CONNECT_LINK_FILE"),
            "The smoke host must not accept a QR output path for KEM recovery."
        )
    }

    func testMacFileTransferSmokeRequiresSignedKEMRefreshInsteadOfQRCode() throws {
        let scriptSource = try readSource("Scripts/run_real_device_file_transfer_smoke.sh")
        XCTAssertTrue(
            scriptSource.contains("SKYBRIDGE_SMOKE_REQUIRE_SIGNED_KEM_REFRESH"),
            "The real-device smoke script must require signed KEM refresh evidence instead of relying on QR bootstrap."
        )
        XCTAssertTrue(
            scriptSource.contains("SKR-1 signed LAN KEM refresh served"),
            "The real-device smoke script must wait for Mac-side SKR-1 served evidence."
        )
        XCTAssertTrue(
            scriptSource.contains("SKR-1 signed LAN KEM refresh verified and imported"),
            "The real-device smoke script must wait for iOS-side SKR-1 verified import evidence."
        )
        XCTAssertTrue(
            scriptSource.contains("SKYBRIDGE_SMOKE_USE_OOB_QR_BOOTSTRAP has been removed"),
            "Smoke must reject legacy QR KEM bootstrap so a QR path cannot mask KEM recovery."
        )
        XCTAssertFalse(
            scriptSource.contains("qr-connect-link mode=offline-p2p-kem file="),
            "Smoke must not wait for an offline P2P KEM QR link."
        )
        XCTAssertTrue(
            scriptSource.contains("SKYBRIDGE_SMOKE_PIB_APPROVAL_TIMEOUT_SECONDS:-$SMOKE_TIMEOUT_SECONDS"),
            "The real-device smoke script must fail PIB-1 approval as its own stage before the outer smoke timeout hides the cause."
        )
        XCTAssertTrue(
            scriptSource.contains("approve on Mac first if prompted, then approve on iOS within ${PIB_APPROVAL_TIMEOUT_SECONDS}s"),
            "The operator prompt must report the actual bounded PIB-1 approval window and both approval sides."
        )
        XCTAssertTrue(
            scriptSource.contains("requester protocol identity pinned"),
            "The real-device smoke script must wait for Mac-side requester pinning before SKR-1."
        )

        let p2pSource = try [
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift",
            "Sources/SkyBridgeCore/P2P/P2PDiscoveryService+BootstrapControl.swift"
        ].map { path in
            try readSource(path)
        }.joined(separator: "\n")
        XCTAssertTrue(p2pSource.contains("makeBootstrapControlResponse"))
        XCTAssertTrue(p2pSource.contains("RemoteControlSmokeStatusWriter.append(controlResponse.statusLine)"))

        let legacyDiscoverySource = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DeviceDiscoveryManager.swift")
        XCTAssertTrue(
            legacyDiscoverySource.contains("handlePreHandshakePlaintextControl"),
            "LocalLanInteropHost uses DeviceDiscoveryManager, so its inbound control channel must serve SKR-1 before the handshake."
        )
        XCTAssertTrue(legacyDiscoverySource.contains("P2PDiscoveryService.makeBootstrapControlResponse"))
        XCTAssertTrue(legacyDiscoverySource.contains("RemoteControlSmokeStatusWriter.append(controlResponse.statusLine)"))

        let localHostSource = try readSource("Sources/LocalLanInteropHost/main.swift")
        XCTAssertTrue(localHostSource.contains("timer.schedule(deadline: .now(), repeating: .milliseconds(8)"))
        XCTAssertTrue(localHostSource.contains("import QuartzCore"))
        XCTAssertTrue(localHostSource.contains("private let accentLayer = CALayer()"))
        XCTAssertTrue(localHostSource.contains("CATransaction.setDisableActions(true)"))
        XCTAssertTrue(localHostSource.contains("CATransaction.flush()"))
        XCTAssertTrue(localHostSource.contains("let window = NSPanel("))
        XCTAssertTrue(localHostSource.contains("window.hidesOnDeactivate = false"))
        XCTAssertTrue(localHostSource.contains("window.level = .floating"))
        XCTAssertTrue(localHostSource.contains("window.displayIfNeeded()"))
        XCTAssertTrue(localHostSource.contains("application.updateWindows()"))
        XCTAssertTrue(localHostSource.contains("let mainDisplayID = CGMainDisplayID()"))
        XCTAssertTrue(localHostSource.contains("Self.screen(for: mainDisplayID)"))
        XCTAssertTrue(localHostSource.contains("displayID=\\(displayID)"))
        XCTAssertTrue(localHostSource.contains("windowVisible=\\(visible)"))
        XCTAssertTrue(localHostSource.contains("windowOcclusionVisible=\\(occlusionVisible)"))
        XCTAssertTrue(localHostSource.contains("windowLevel=\\(level)"))
        XCTAssertTrue(localHostSource.contains("windowFrame=\\(Int(windowFrame.origin.x))"))
        XCTAssertFalse(
            localHostSource.contains("window.level = .screenSaver"),
            "The smoke source must stay in a capture-compatible app window level; screen-saver level can be invisible to display capture."
        )
        XCTAssertFalse(
            localHostSource.contains("MTKView"),
            "The smoke capture source must use deterministic Core Animation updates, not a throttled MTKView display link."
        )

        let remoteSmokeSource = try readSource("Scripts/run_real_device_p2p_remote_smoke.sh")
        XCTAssertTrue(remoteSmokeSource.contains("verify_mac_smoke_capture_source_visible()"))
        XCTAssertTrue(remoteSmokeSource.contains("screencapture -x \"$first\""))
        XCTAssertTrue(remoteSmokeSource.contains("changedRatio"))
        XCTAssertTrue(remoteSmokeSource.contains("smoke-capture-source captureVerified=1"))
        XCTAssertTrue(remoteSmokeSource.contains("verify_mac_smoke_capture_source_visible\nwait_for_file_pattern \"$HOST_PQC_REPORT\""))
    }

    func testBonjourDiscoveryDoesNotImportKEMPublicKeysFromTXT() throws {
        let discoverySource = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let identitySlice = try sourceSlice(
            from: "private func extractStrongIdentity(from result: NWBrowser.Result)",
            to: "private func extractSOAFlag(from result: NWBrowser.Result)",
            in: discoverySource
        )
        XCTAssertFalse(identitySlice.localizedCaseInsensitiveContains("kem"))
        XCTAssertFalse(identitySlice.contains("KEMTrustStore"))
        XCTAssertFalse(identitySlice.contains("PeerKEMBootstrapStore"))

        let txtParserSource = try readSource("Sources/SkyBridgeCore/P2P/P2PDeviceDiscovery.swift")
        let createDeviceSlice = try sourceSlice(
            from: "public static func createDevice(",
            to: "public static func validate(_ txtRecord: [String: String])",
            in: txtParserSource
        )
        XCTAssertFalse(createDeviceSlice.localizedCaseInsensitiveContains("kemPublic"))
        XCTAssertFalse(createDeviceSlice.contains("KEMPublicKeyInfo"))

        let advertiserSource = try readSource("Sources/SkyBridgeCore/DeviceDiscovery/DiscoveryOrchestrator.swift")
        XCTAssertTrue(advertiserSource.contains("record[\"kemRefreshVersion\"] = \"1\""))
        XCTAssertTrue(advertiserSource.contains("record[\"kemKeyDigest\"] = kemKeyDigest"))
        XCTAssertTrue(advertiserSource.contains("record[\"identityFingerprint\"] = snap.pubKeyFP"))
        XCTAssertFalse(advertiserSource.contains("record[\"kemPublicKey\"]"))
        XCTAssertFalse(advertiserSource.contains("record[\"kemPublicKeys\"]"))
    }

    func testStrictBootstrapOnlyAcceptsOnlyBootstrapSecurityAndLivenessBeforeRekey() {
        let kemKey = KEMPublicKeyInfo(
            suiteWireId: CryptoSuite.xwingMLDSA.wireId,
            publicKey: Data(repeating: 0x42, count: 1_216)
        )
        let pairing = AppMessage.PairingIdentityExchangePayload(
            deviceId: "device-a",
            kemPublicKeys: [kemKey]
        )
        let kemRefreshRequest = AppMessage.KEMRefreshRequestPayload(
            requesterDeviceId: "device-a",
            targetDeviceId: "device-b",
            requestedSuiteWireIds: [CryptoSuite.xwingMLDSA.wireId],
            nonce: Data(repeating: 0x01, count: 16)
        )
        let signedKEMRefresh = AppMessage.SignedKEMRefreshPayload(
            deviceId: "device-a",
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.mlDSA65.rawValue,
            protocolIdentityPublicKey: Data([0x02]),
            protocolIdentityFingerprint: "fingerprint-a",
            kemPublicKeys: [kemKey],
            keyId: "key-a",
            generation: 1,
            expiresAt: Date(timeIntervalSince1970: 2_000),
            requestNonce: Data(repeating: 0x03, count: 16),
            signature: Data([0x04])
        )
        let kemRefreshFailure = AppMessage.KEMRefreshFailurePayload(
            requesterDeviceId: "device-a",
            targetDeviceId: "device-b",
            stage: "test",
            reasonCode: "test_reason",
            reason: "test"
        )
        let bindingRequest = AppMessage.ProtocolIdentityBindingRequestPayload(
            requesterDeviceId: "device-a",
            targetDeviceId: "device-b",
            requestedProtocolSigningAlgorithms: [ProtocolSigningAlgorithm.ed25519.rawValue],
            nonce: Data(repeating: 0x05, count: 16)
        )
        let signedBinding = AppMessage.SignedProtocolIdentityBindingPayload(
            deviceId: "device-a",
            protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
            protocolIdentityPublicKey: Data([0x06]),
            protocolIdentityFingerprint: "fingerprint-b",
            expiresAt: Date(timeIntervalSince1970: 2_000),
            requestNonce: Data(repeating: 0x07, count: 16),
            signature: Data([0x08])
        )

        let bootstrapSecurityMessages: [AppMessage] = [
            .pairingIdentityExchange(pairing),
            .kemRefreshRequest(kemRefreshRequest),
            .signedKEMRefresh(signedKEMRefresh),
            .kemRefreshFailure(kemRefreshFailure),
            .protocolIdentityBindingRequest(bindingRequest),
            .signedProtocolIdentityBinding(signedBinding)
        ]
        for message in bootstrapSecurityMessages {
            XCTAssertEqual(
                WebRTCBootstrapAppMessagePolicy.admission(for: message),
                .continueBootstrapSecurityFlow
            )
        }

        let livenessMessages: [AppMessage] = [
            .heartbeat(.init(deviceId: "device-a")),
            .ping(.init(id: 1)),
            .pong(.init(id: 1)),
            .peerDisconnecting(.init(deviceId: "device-a"))
        ]
        for message in livenessMessages {
            XCTAssertEqual(
                WebRTCBootstrapAppMessagePolicy.admission(for: message),
                .consumeLivenessLocally
            )
        }

        XCTAssertEqual(
            WebRTCBootstrapAppMessagePolicy.admission(
                for: .clipboard(.init(mimeType: "text/plain", dataBase64: "dGVzdA=="))
            ),
            .dropUntilPQCRekey,
            "Business payloads must not start the media/control path before PQC rekey."
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

    func testSignedAppSmokeHasAppLevelPairingApprovalSurface() throws {
        let appSource = try readSource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let scriptSource = try readSource("Scripts/run_real_device_file_transfer_smoke.sh")

        let windowGroupPrefix = try sourceSlice(
            from: "WindowGroup(localizationManager.localizedString(\"app.name\"))",
            to: ".task {",
            in: appSource
        )
        let rootContainerSource = try sourceSlice(
            from: "private struct RootContainerView: View",
            to: "@available(macOS 14.0, *)\nprivate struct SupabasePasswordResetSheet",
            in: appSource
        )

        XCTAssertTrue(
            windowGroupPrefix.contains("PairingTrustApprovalSheet"),
            "PIB-1/SKR-1 approval must be app-level so signed-app smoke, startup, and unauthenticated states can present it."
        )
        XCTAssertFalse(
            rootContainerSource.contains("PairingTrustApprovalSheet"),
            "Approval must not be trapped behind Dashboard/RootContainer startup state."
        )
        XCTAssertTrue(
            scriptSource.contains("foregrounding signed app so PIB-1 requester approval is visible"),
            "User-realistic signed-app smoke must launch foreground when operator approval is required."
        )
        XCTAssertTrue(
            scriptSource.contains("OPEN_ARGS=(-n --stdout \"$HOST_STDOUT\" --stderr \"$HOST_STDERR\")")
        )
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
