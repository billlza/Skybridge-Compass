import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class CrossNetworkWebRTCHandshakeBootstrapTests: XCTestCase {
    func testCrossNetworkPresenceUsesStableDeviceIdWhenAvailable() {
        XCTAssertEqual(
            CrossNetworkConnectionManager.crossNetworkPresencePeerID(
                sessionID: "session-route-1",
                deviceId: "remote-device-alpha"
            ),
            "id:remote-device-alpha"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.crossNetworkPresencePeerID(
                sessionID: "session-route-1",
                deviceId: "id:REMOTE-DEVICE-ALPHA"
            ),
            "id:remote-device-alpha"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.crossNetworkPresencePeerID(
                sessionID: "session-route-1",
                deviceId: "cross-network:session-route-2"
            ),
            "cross-network:session-route-1"
        )
        XCTAssertEqual(
            CrossNetworkConnectionManager.crossNetworkPresencePeerID(
                sessionID: "session-route-1",
                deviceId: nil
            ),
            "cross-network:session-route-1"
        )
    }

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
        XCTAssertTrue(localHostSource.contains("ready remote=_skybridge-remote._tcp"))
        XCTAssertTrue(localHostSource.contains("NSApplication.shared.run()"))
        XCTAssertTrue(localHostSource.contains("LocalLanInteropHostLifetime.coordinator = coordinator"))
        XCTAssertFalse(localHostSource.contains("SmokeCaptureAnimationSource"))
        XCTAssertFalse(localHostSource.contains("SmokeCaptureAnimationView"))
        XCTAssertFalse(localHostSource.contains("SmokeCaptureMetalRenderer"))
        XCTAssertFalse(localHostSource.contains("SKYBRIDGE_SMOKE_REMOTE_ANIMATION"))
        XCTAssertFalse(localHostSource.contains("import MetalKit"))
        XCTAssertFalse(localHostSource.contains("private let accentLayer = CALayer()"))
        XCTAssertFalse(localHostSource.contains("CATransaction.setDisableActions(true)"))

        let smokeSourceHost = try readSource("Sources/LocalLanSmokeSourceHost/main.swift")
        XCTAssertTrue(smokeSourceHost.contains("beginActivity("))
        XCTAssertTrue(smokeSourceHost.contains(".userInitiatedAllowingIdleSystemSleep"))
        XCTAssertTrue(smokeSourceHost.contains(".latencyCritical"))
        XCTAssertTrue(smokeSourceHost.contains(".suddenTerminationDisabled"))
        XCTAssertTrue(smokeSourceHost.contains(".automaticTerminationDisabled"))
        XCTAssertTrue(smokeSourceHost.contains("appNapDisabled=1"))
        XCTAssertTrue(smokeSourceHost.contains("applyUserInteractiveMainThreadQoS()"))
        XCTAssertTrue(smokeSourceHost.contains("pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE"))
        XCTAssertTrue(smokeSourceHost.contains("mainThreadQOS=userInteractive"))
        XCTAssertTrue(smokeSourceHost.contains("fileprivate static let targetCaptureFramesPerSecond = 60"))
        XCTAssertTrue(smokeSourceHost.contains("private static func renderFramesPerSecond(for _: NSScreen?) -> Int"))
        XCTAssertTrue(smokeSourceHost.contains("targetCaptureFramesPerSecond"))
        XCTAssertTrue(smokeSourceHost.contains("private static let statusReportIntervalSeconds: TimeInterval = 1"))
        XCTAssertTrue(smokeSourceHost.contains("private static let staleRenderRepairThresholdMilliseconds = 100.0"))
        XCTAssertTrue(smokeSourceHost.contains("process=helper"))
        XCTAssertTrue(smokeSourceHost.contains("DispatchSource.makeTimerSource(queue: .main)"))
        XCTAssertTrue(smokeSourceHost.contains("import MetalKit"))
        XCTAssertTrue(smokeSourceHost.contains("MTLCreateSystemDefaultDevice()"))
        XCTAssertTrue(smokeSourceHost.contains("SmokeCaptureAnimationView: MTKView"))
        XCTAssertTrue(smokeSourceHost.contains("SmokeCaptureMetalRenderer: NSObject, MTKViewDelegate"))
        XCTAssertTrue(smokeSourceHost.contains("setRenderingFrameRate(targetRenderFramesPerSecond)"))
        XCTAssertTrue(smokeSourceHost.contains("preferredFramesPerSecond = framesPerSecond"))
        XCTAssertTrue(smokeSourceHost.contains("targetRenderFPS="))
        XCTAssertTrue(smokeSourceHost.contains("screenMaxFPS="))
        XCTAssertTrue(smokeSourceHost.contains("SmokeCaptureVertex"))
        XCTAssertTrue(smokeSourceHost.contains("makeLibrary(source: Self.shaderSource"))
        XCTAssertTrue(smokeSourceHost.contains("smoke_vertex"))
        XCTAssertTrue(smokeSourceHost.contains("smoke_fragment"))
        XCTAssertTrue(smokeSourceHost.contains("makeDynamicFrameVertices(for: frame)"))
        XCTAssertTrue(smokeSourceHost.contains("encoder.drawPrimitives(type: .triangle"))
        XCTAssertTrue(smokeSourceHost.contains("lastSnapshotFrameCount"))
        XCTAssertTrue(smokeSourceHost.contains("maxFrameGapMilliseconds = 0"))
        XCTAssertTrue(smokeSourceHost.contains("mode=metal-vsync"))
        XCTAssertTrue(smokeSourceHost.contains("sourceCadenceDriver=mtkview-display-link"))
        XCTAssertTrue(smokeSourceHost.contains("statusWriter=background-serial"))
        XCTAssertTrue(smokeSourceHost.contains(".withFractionalSeconds"))
        XCTAssertTrue(smokeSourceHost.contains("visibilityRepair=conditional"))
        XCTAssertTrue(smokeSourceHost.contains("renderGapMaxMs="))
        XCTAssertTrue(smokeSourceHost.contains("reason=metal_unavailable"))
        XCTAssertTrue(smokeSourceHost.contains("reason=metal_renderer_unavailable"))
        XCTAssertTrue(smokeSourceHost.contains("MainActor.assumeIsolated"))
        XCTAssertTrue(smokeSourceHost.contains("private func repairCaptureWindowIfNeeded()"))
        XCTAssertTrue(smokeSourceHost.contains("renderIsStale"))
        XCTAssertTrue(smokeSourceHost.contains("visibilityRepair=1"))
        XCTAssertTrue(smokeSourceHost.contains("window?.orderFrontRegardless()"))
        XCTAssertTrue(smokeSourceHost.contains("application.setActivationPolicy(.regular)"))
        XCTAssertTrue(smokeSourceHost.contains("NSRunningApplication.current.activate(options: [.activateAllWindows])"))
        XCTAssertFalse(smokeSourceHost.contains(".activateIgnoringOtherApps"))
        XCTAssertFalse(smokeSourceHost.contains("private let accentLayer = CALayer()"))
        XCTAssertFalse(smokeSourceHost.contains("CATransaction.setDisableActions(true)"))
        XCTAssertTrue(smokeSourceHost.contains("let window = NSWindow("))
        XCTAssertTrue(smokeSourceHost.contains("styleMask: [.titled, .closable, .miniaturizable]"))
        XCTAssertTrue(smokeSourceHost.contains("window.hidesOnDeactivate = false"))
        XCTAssertTrue(smokeSourceHost.contains("window.level = .floating"))
        XCTAssertTrue(smokeSourceHost.contains("window.collectionBehavior = [.moveToActiveSpace]"))
        XCTAssertTrue(smokeSourceHost.contains("window.displayIfNeeded()"))
        XCTAssertTrue(smokeSourceHost.contains("application.updateWindows()"))
        XCTAssertTrue(smokeSourceHost.contains("NSApplication.shared.run()"))
        XCTAssertTrue(smokeSourceHost.contains("let mainDisplayID = CGMainDisplayID()"))
        XCTAssertTrue(smokeSourceHost.contains("Self.screen(for: mainDisplayID)"))
        XCTAssertTrue(smokeSourceHost.contains("displayID=\\(displayID)"))
        XCTAssertTrue(smokeSourceHost.contains("windowVisible=\\(visible)"))
        XCTAssertTrue(smokeSourceHost.contains("windowOcclusionVisible=\\(occlusionVisible)"))
        XCTAssertTrue(smokeSourceHost.contains("windowLevel=\\(level)"))
        XCTAssertTrue(smokeSourceHost.contains("windowFrame=\\(Int(windowFrame.origin.x))"))
        let heartbeatBody = try sourceSlice(
            from: "private func heartbeat()",
            to: "private func repairCaptureWindowIfNeeded()",
            in: smokeSourceHost
        )
        XCTAssertFalse(heartbeatBody.contains("orderFrontRegardless()"))
        XCTAssertFalse(heartbeatBody.contains("displayIfNeeded()"))
        XCTAssertFalse(heartbeatBody.contains("SmokeStatusFileAppender.append"))
        let statusReporterBody = try sourceSlice(
            from: "private final class SmokeStatusReporter",
            to: "private func writeProtectedData",
            in: smokeSourceHost
        )
        XCTAssertTrue(statusReporterBody.contains("DispatchQueue("))
        XCTAssertTrue(statusReporterBody.contains("label: \"com.skybridge.smoke.status-writer\""))
        XCTAssertTrue(statusReporterBody.contains("qos: .utility"))
        XCTAssertTrue(statusReporterBody.contains("queue.async"))
        XCTAssertTrue(statusReporterBody.contains("appendAndWait"))
        XCTAssertTrue(statusReporterBody.contains("SmokeStatusFileAppender.append"))
        XCTAssertFalse(
            smokeSourceHost.contains("window.level = .screenSaver"),
            "The smoke source must stay in a capture-compatible app window level; screen-saver level can be invisible to display capture."
        )
        XCTAssertTrue(
            smokeSourceHost.contains("MTKView"),
            "The smoke capture source must be backed by a real Metal drawable, not a main-queue layer timer."
        )

        let remoteControlSource = try readSource("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift")
        let remoteControlInitBody = try sourceSlice(
            from: "public init() {",
            to: "private func configureViewingRenderersIfNeeded()",
            in: remoteControlSource
        )
        XCTAssertTrue(remoteControlSource.contains("private func configureViewingRenderersIfNeeded()"))
        XCTAssertTrue(remoteControlSource.contains("configureViewingRenderersIfNeeded()\n\n        if let fmt"))
        XCTAssertFalse(
            remoteControlInitBody.contains("fluidRenderer.frameHandler") ||
            remoteControlInitBody.contains("referenceRenderer.frameHandler"),
            "The smoke host is a remote-control server and must not force viewer Metal/resource renderers during startup."
        )

        let remoteSmokeSource = try readSource("Scripts/run_real_device_p2p_remote_smoke.sh")
        XCTAssertTrue(remoteSmokeSource.contains("MAC_APP_BUNDLE=\"$ARTIFACT_DIR/LocalLanInteropHost.app\""))
        XCTAssertTrue(remoteSmokeSource.contains("prepare_macos_smoke_host_app_bundle()"))
        XCTAssertTrue(remoteSmokeSource.contains("start_macos_smoke_host()"))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_HOST_LAUNCH_MODE=\"${SKYBRIDGE_SMOKE_MAC_HOST_LAUNCH_MODE:-direct}\""))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_DIRECT_BIN=\"$ROOT_DIR/.build/debug/LocalLanInteropHost\""))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_SOURCE_DIRECT_BIN=\"$ROOT_DIR/.build/debug/LocalLanSmokeSourceHost\""))
        XCTAssertTrue(remoteSmokeSource.contains("swift build --product LocalLanSmokeSourceHost"))
        XCTAssertTrue(remoteSmokeSource.contains("start_macos_smoke_source_host()"))
        XCTAssertTrue(remoteSmokeSource.contains("SKYBRIDGE_SMOKE_ROLE=mac-smoke-source"))
        XCTAssertTrue(remoteSmokeSource.contains("role=mac-smoke-source"))
        XCTAssertTrue(remoteSmokeSource.contains("fail_if_smoke_source_exited"))
        XCTAssertTrue(remoteSmokeSource.contains("fail_if_smoke_source_stale"))
        XCTAssertTrue(remoteSmokeSource.contains("phase=heartbeat-stale"))
        XCTAssertTrue(remoteSmokeSource.contains("if [[ \"$MAC_HOST_LAUNCH_MODE\" == \"direct\" ]]"))
        XCTAssertTrue(remoteSmokeSource.contains("\"$MAC_DIRECT_BIN\" >\"$HOST_STDOUT\" 2>&1 &"))
        XCTAssertTrue(remoteSmokeSource.contains("launch method=direct-app-binary pid=$HOST_PID mode=direct binary=swiftpm-build-product"))
        XCTAssertFalse(remoteSmokeSource.contains("fallbackFrom=open-app-bundle"))
        XCTAssertTrue(remoteSmokeSource.contains("verify_mac_control_port_reachable \"$MAC_CONTROL_HOST\" \"$MAC_CONTROL_PORT\""))
        XCTAssertTrue(remoteSmokeSource.contains("mac-control-port reachable=1 host=$host port=$port source=pre-ios-probe"))
        XCTAssertTrue(remoteSmokeSource.contains("failed stage=mac-host phase=control-port-probe reason=tcp-unreachable"))
        XCTAssertTrue(remoteSmokeSource.contains("/usr/bin/open"))
        XCTAssertTrue(remoteSmokeSource.contains("register_macos_smoke_host_app_bundle()"))
        XCTAssertTrue(remoteSmokeSource.contains("LocalLanInteropHostSmoke.${RUN_ID}"))
        XCTAssertTrue(remoteSmokeSource.contains("fallback=direct-app-binary"))
        XCTAssertFalse(remoteSmokeSource.contains("SKYBRIDGE_SMOKE_REMOTE_ANIMATION=1"))
        XCTAssertTrue(remoteSmokeSource.contains("launch method=open-app-bundle"))
        XCTAssertTrue(remoteSmokeSource.contains("windowOcclusionVisible=1"))
        XCTAssertTrue(remoteSmokeSource.contains("local source_webrtc_framework=\"$ROOT_DIR/.build/debug/WebRTC.framework\""))
        XCTAssertTrue(remoteSmokeSource.contains("cp -R \"$source_webrtc_framework\" \"$macos_dir/WebRTC.framework\""))
        XCTAssertTrue(remoteSmokeSource.contains("/usr/bin/codesign --force --deep --sign - \"$MAC_APP_BUNDLE\""))
        XCTAssertTrue(remoteSmokeSource.contains("-c 'Add :CFBundlePackageType string APPL'"))
        XCTAssertTrue(remoteSmokeSource.contains("-c 'Add :NSPrincipalClass string NSApplication'"))
        XCTAssertTrue(remoteSmokeSource.contains("-c 'Add :NSLocalNetworkUsageDescription string SkyBridge Compass uses the local network"))
        XCTAssertTrue(remoteSmokeSource.contains("-c 'Add :NSBonjourServices:0 string _skybridge._tcp'"))
        XCTAssertFalse(remoteSmokeSource.contains("-c 'Add :LSUIElement bool true'"))
        XCTAssertFalse(remoteSmokeSource.contains("*.bundle"))
        XCTAssertTrue(remoteSmokeSource.contains("MAC_APP_BIN=\"$macos_dir/LocalLanInteropHost\""))
        XCTAssertTrue(remoteSmokeSource.contains("detect_macos_loginwindow_occlusion()"))
        XCTAssertTrue(remoteSmokeSource.contains("CGWindowListCopyWindowInfo"))
        XCTAssertTrue(remoteSmokeSource.contains("reason=screen-locked-loginwindow-occlusion"))
        XCTAssertTrue(remoteSmokeSource.contains("detect_macos_loginwindow_occlusion\nwait_for_file_pattern \"$HOST_STATUS\" 'smoke-capture-source active=1 .*windowOcclusionVisible=1'"))
        XCTAssertTrue(remoteSmokeSource.contains("verify_mac_smoke_capture_source_visible()"))
        XCTAssertTrue(remoteSmokeSource.contains("detect_macos_loginwindow_occlusion\n\n  if ! command -v screencapture"))
        XCTAssertTrue(remoteSmokeSource.contains("minimum_source_samples"))
        XCTAssertFalse(remoteSmokeSource.contains("Mac smoke source aggregate renderFPS below live-source budget"))
        XCTAssertTrue(remoteSmokeSource.contains("source_frame_delta = source_frame_end - source_frame_start"))
        XCTAssertTrue(remoteSmokeSource.contains("macSourceRenderProgressFPS="))
        XCTAssertTrue(remoteSmokeSource.contains("Mac smoke source render gap exceeded live-source budget"))
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

    func testP2PDiscoverySettingsRebuildRuntimeBrowserSet() throws {
        let discoverySource = try readSource("Sources/SkyBridgeCore/P2P/P2PDiscoveryService.swift")
        let settingsSource = try readSource("Sources/SkyBridgeCore/Settings/SettingsManager.swift")

        XCTAssertTrue(discoverySource.contains("activeBrowserServiceTypes"))
        XCTAssertTrue(discoverySource.contains("public func applyDiscoverySettings("))
        XCTAssertTrue(discoverySource.contains("browsers.forEach { $0.cancel() }"))
        XCTAssertTrue(discoverySource.contains("startBrowsers(for: desired.sorted())"))
        XCTAssertTrue(settingsSource.contains(".combineLatest($enableCompanionLink)"))
        XCTAssertTrue(settingsSource.contains("P2PDiscoveryService.shared.applyDiscoverySettings"))
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

    func testStrictWebRTCInitialHandshakeRequiresPinnedCurrentPathAuthorityBeforeTrustedKEM() throws {
        let source = try readSource("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift")
        let guardBody = try sourceSlice(
            from: "if peerIdCandidates.isEmpty {",
            to: "var trustedPeerKEMKeys: [CryptoSuite: Data] = [:]",
            in: source
        )

        XCTAssertTrue(guardBody.contains("if strictPQCRequested,"))
        XCTAssertTrue(guardBody.contains("currentPathExpectedRemoteAuthorityBySessionId[sessionId] == nil"))
        XCTAssertTrue(guardBody.contains("requires pinned current-path protocol identity"))
        XCTAssertTrue(guardBody.contains("throw NSError("))
    }

    func testSignedAppSmokeHasAppLevelPairingApprovalSurface() throws {
        let appSource = try readSource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let scriptSource = try readSource("Scripts/run_real_device_file_transfer_smoke.sh")
        let releaseReadiness = try readSource("Scripts/check_macos_release_readiness.sh")

        let windowGroupPrefix = try sourceSlice(
            from: "WindowGroup(localizationManager.localizedString(\"app.name\"), id: \"main\")",
            to: ".task {",
            in: appSource
        )
        let rootContainerSource = try sourceSlice(
            from: "private struct RootContainerView: View",
            to: "private struct SupabasePasswordResetSheet: View",
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
        XCTAssertTrue(
            releaseReadiness.contains("--package-integrity-only"),
            "Release readiness should expose a narrow package-integrity verifier for smoke preflight without weakening the full release gate."
        )
        XCTAssertTrue(
            releaseReadiness.contains("Package integrity-only validation complete"),
            "The package-integrity mode must exit only after package signing, stapling, and Gatekeeper checks."
        )
        XCTAssertTrue(
            scriptSource.contains("--package-integrity-only"),
            "User-realistic file-transfer smoke should preflight the signed release package without requiring unrelated artifacts before the smoke produces them."
        )
    }

    func testMacOnlineSmokeBootMarkerRunsBeforeHeavyAppStateObjects() throws {
        let appSource = try readSource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")

        guard let bootMarker = appSource.range(of: "private let macOnlineSmokeBootMarker"),
              let firstStateObject = appSource.range(of: "@StateObject private var appModel") else {
            XCTFail("Expected mac-online boot marker and first StateObject in SkyBridgeCompassApp.")
            return
        }

        XCTAssertLessThan(
            bootMarker.lowerBound,
            firstStateObject.lowerBound,
            "The packaged LaunchServices smoke marker must run before heavy SwiftUI/App model initialization can block evidence emission."
        )
        XCTAssertTrue(appSource.contains("MacOnlineIPadSmokeBootMarker.appendIfNeeded(uiRole: \"app-init-pre-state\")"))
        XCTAssertTrue(
            appSource.contains("MacOnlineIPadSmokeHarness.isEnabledForCurrentEnvironment || startupCoordinator.isLaunchSettled"),
            "The mac-online packaged-app smoke must render the device-management root before the normal startup gate can block OnlineDeviceCard evidence."
        )
        XCTAssertTrue(appSource.contains("SKYBRIDGE_SMOKE_ROLE"))
        XCTAssertTrue(appSource.contains("SKYBRIDGE_SMOKE_STATUS_FILE"))
        XCTAssertTrue(appSource.contains("SmokeStatusFileAppender.append(data, to: URL(fileURLWithPath: rawStatusPath))"))
    }

    func testMacOnlineStartupAvoidsBundleMainResourceResolutionBeforeRootViewCanRender() throws {
        let dashboardSource = try readSource("Sources/SkyBridgeCompassApp/DashboardViewModel.swift")
        let localizationSource = try readSource("Sources/SkyBridgeCore/Localization/LocalizationManager.swift")
        let appSource = try readSource("Sources/SkyBridgeCompassApp/SkyBridgeCompassApp.swift")
        let startupCoordinatorSource = try readSource("Sources/SkyBridgeCompassApp/Core/StartupCoordinator.swift")
        let appInfoPlist = try readSource("Sources/SkyBridgeCompassApp/Info.plist")
        let xcodeInfoPlist = try readSource("XcodeSupport/SkyBridgeCompassMac/Info.plist")
        let projectYAML = try readSource("project.yml")
        let brandIconSource = try readSource("Sources/SkyBridgeCompassApp/SVGEmbeddedImageView.swift")
        let menuBarControllerSource = try readSource("Sources/SkyBridgeUI/MenuBar/MenuBarController.swift")
        let menuBarIconGeneratorSource = try readSource("Sources/SkyBridgeUI/MenuBar/MenuBarIconGenerator.swift")
        let dashboardStoredProperties = try sourceSlice(
            from: "final class DashboardViewModel: ObservableObject",
            to: "// MARK: - 初始化",
            in: dashboardSource
        )
        let brandIconLoaderSource = try sourceSlice(
            from: "private enum BrandIconAssetLoader",
            to: "private extension View",
            in: brandIconSource
        )
        let iconSource = try sourceSlice(
            from: "private static func applyAppIconIfAvailable() -> Bool",
            to: "func resolveDevelopmentIconURL() -> URL?",
            in: appSource
        )
        let appIconFallbackSource = try sourceSlice(
            from: "guard let url = resolveDevelopmentIconURL() else",
            to: "guard let icon = NSImage(contentsOf: url) else",
            in: appSource
        )
        let notificationSource = try sourceSlice(
            from: "private static func configureNotificationsUnified()",
            to: "/// 设置菜单栏通知处理器",
            in: appSource
        )
        let rootServicesContainerSource = try sourceSlice(
            from: "private struct RootAppServicesContainer: View",
            to: "private struct PreferencesSceneContent: View",
            in: appSource
        )

        XCTAssertFalse(
            dashboardStoredProperties.contains("LocalizationManager.shared.localizedString"),
            "DashboardViewModel stored property initialization must not synchronously resolve localization bundles before the smoke root view can render."
        )
        XCTAssertTrue(
            dashboardStoredProperties.contains("statusText: ConnectionStatus.disconnected.displayName"),
            "The pre-render disconnected label should come from the non-resource connection status until live presentation bindings install localized labels."
        )
        XCTAssertTrue(
            dashboardStoredProperties.contains("private lazy var discoveryService = DeviceDiscoveryService.shared"),
            "DashboardViewModel must not construct the discovery service while SwiftUI is still creating App-level StateObjects."
        )
        XCTAssertTrue(
            dashboardStoredProperties.contains("private lazy var unifiedDeviceManager = UnifiedOnlineDeviceManager.shared"),
            "The unified online manager starts path monitors, timers, and persisted-device loading; keep it out of App StateObject initialization."
        )
        XCTAssertFalse(
            dashboardStoredProperties.contains("private let unifiedDeviceManager = UnifiedOnlineDeviceManager.shared"),
            "Do not eagerly construct the unified online manager before the startup progress view can render."
        )
        guard let coordinatedLaunch = appSource.range(of: "await startupCoordinator.startCoordinatedLaunch()"),
              let connectionBindings = appSource.range(of: "appModel.bootstrapConnectionPresentationBindings()") else {
            XCTFail("Expected coordinated launch and deferred dashboard bindings in SkyBridgeCompassApp.")
            return
        }
        XCTAssertLessThan(
            coordinatedLaunch.lowerBound,
            connectionBindings.lowerBound,
            "Dashboard presentation bindings subscribe to device/presence managers and must install after coordinated launch settles."
        )
        guard let rootServiceSettledGate = rootServicesContainerSource.range(
            of: "await StartupCoordinator.shared.waitUntilLaunchSettled()"
        ),
              let rootServiceBindings = rootServicesContainerSource.range(
                of: "appModel.bootstrapConnectionPresentationBindings()"
              ) else {
            XCTFail("Expected RootAppServicesContainer to gate service bootstrapping on launch settled.")
            return
        }
        XCTAssertLessThan(
            rootServiceSettledGate.lowerBound,
            rootServiceBindings.lowerBound,
            "Root service bootstrapping must wait for the startup progress stable period before subscribing to device managers."
        )
        XCTAssertTrue(
            startupCoordinatorSource.contains("prepareDeferredServiceLaunch()"),
            "StartupCoordinator should show progress for the launch plan without starting Bonjour/P2P/USB listeners before the first interactive frame."
        )
        XCTAssertFalse(
            startupCoordinatorSource.contains("LocalPeerServiceCoordinator.shared.ensureHealthy()"),
            "Local peer listeners must start from the post-first-frame service queue, not the blocking launch coordinator."
        )
        XCTAssertFalse(
            startupCoordinatorSource.contains("P2PNetworkManager.shared.start()"),
            "P2P/Bonjour listener startup can create identity TXT and network listeners; keep it out of the startup progress gate."
        )
        XCTAssertFalse(
            startupCoordinatorSource.contains("UnifiedOnlineDeviceManager.shared.startDiscovery"),
            "USB/Bonjour discovery must not be started by StartupCoordinator before the root view can render."
        )
        XCTAssertFalse(
            startupCoordinatorSource.contains("try MetalPerformanceOptimizer()"),
            "Metal performance optimizer construction is heavyweight and must not run before first frame."
        )
        XCTAssertTrue(localizationSource.contains("LocalizationBundleLookupCache"))
        XCTAssertFalse(
            localizationSource.contains("bundle.path(forResource:"),
            "Localization lookup must use cached direct resource-directory resolution instead of synchronous CFBundle pathForResource scans on the startup path."
        )
        XCTAssertFalse(
            localizationSource.contains("bundle.urls(forResourcesWithExtension:"),
            "Localization lookup must avoid repeated all-resource Bundle URL enumeration on the startup path."
        )
        XCTAssertTrue(localizationSource.contains("defaultResourceSearchBaseURLs()"))
        XCTAssertTrue(appSource.contains("private static func packagedContentsURL() -> URL?"))
        XCTAssertFalse(iconSource.contains("Bundle.main.bundleURL"))
        XCTAssertFalse(iconSource.contains("Bundle.main.url(forResource"))
        XCTAssertFalse(
            iconSource.contains("NSApplication.shared.applicationIconImage ="),
            "Packaged app startup must not overwrite the Info.plist-declared app icon with a raw PNG or ICNS."
        )
        XCTAssertFalse(
            appSource.contains("resolvePackagedIconURL"),
            "Packaged app icon resolution must stay under Info.plist + LaunchServices ownership."
        )
        XCTAssertTrue(
            iconSource.contains("if isRunningFromPackagedApp"),
            "Packaged app startup should return after confirming LaunchServices owns the app icon."
        )
        XCTAssertTrue(
            appIconFallbackSource.contains("resolveDevelopmentIconURL()")
        )
        XCTAssertFalse(
            appSource.contains("resolveIconURL(named: \"AppIconDock\")"),
            "Debug fallback should not silently switch to the alternate Dock icon resource."
        )
        XCTAssertFalse(
            appSource.contains("withExtension: \"icns\""),
            "Runtime icon setup must not fall back to legacy ICNS resources."
        )
        XCTAssertTrue(appInfoPlist.contains("<key>CFBundleIconFile</key>"))
        XCTAssertTrue(appInfoPlist.contains("<string>AppIcon.icns</string>"))
        XCTAssertTrue(xcodeInfoPlist.contains("<key>CFBundleIconFile</key>"))
        XCTAssertTrue(xcodeInfoPlist.contains("<string>AppIcon.icns</string>"))
        XCTAssertFalse(appInfoPlist.contains("CFBundleIconName"))
        XCTAssertFalse(xcodeInfoPlist.contains("CFBundleIconName"))
        XCTAssertTrue(projectYAML.contains("Scripts/compile_xcode_icon_composer_assets.sh"))
        XCTAssertTrue(projectYAML.contains("inputFiles:"))
        XCTAssertTrue(projectYAML.contains("outputFiles:"))
        XCTAssertTrue(projectYAML.contains("Resources/AppIcon.icon/**"))
        XCTAssertTrue(projectYAML.contains("Resources/Assets.xcassets/**"))
        XCTAssertTrue(
            brandIconLoaderSource.contains("loadImageResource(named: preferredResourceName, withExtension: \"png\", bundle: .main)"),
            "Sidebar brand UI must be able to request the small-size optimized SidebarBrandIcon.png from the main bundle."
        )
        XCTAssertTrue(
            brandIconLoaderSource.contains("loadImageResource(named: \"BrandIcon\", withExtension: \"png\", bundle: .main)"),
            "Packaged in-app brand UI must read the canonical BrandIcon.png so sidebar/header icons do not drift through AppIcon.icns representation selection."
        )
        XCTAssertTrue(
            brandIconLoaderSource.contains("loadImageResource(named: \"AppIcon\", withExtension: \"png\", bundle: .module)"),
            "Non-packaged development runs must read the single canonical AppIcon.png resource."
        )
        XCTAssertFalse(
            brandIconLoaderSource.contains("NSApplication.shared.applicationIconImage"),
            "Brand UI must not read the mutable/cached applicationIconImage as a visual source of truth."
        )
        XCTAssertTrue(brandIconLoaderSource.contains("return nil"))
        XCTAssertFalse(
            brandIconLoaderSource.contains("image(forResource"),
            "Brand icon startup must not use AppKit Bundle image lookup because it can synchronously initialize the main CoreUI catalog before the root device view renders."
        )
        XCTAssertFalse(
            brandIconLoaderSource.contains("packagedResourceIconURLs"),
            "Packaged brand icon loading must not scan legacy resource lists."
        )
        XCTAssertFalse(
            brandIconLoaderSource.contains("\"AppIconDock\""),
            "Brand icon loading must not consult the alternate Dock icon resource."
        )
        XCTAssertFalse(
            brandIconLoaderSource.contains("\"app_icon\""),
            "Brand icon loading must not consult stale snake-case icon aliases."
        )
        XCTAssertTrue(
            menuBarControllerSource.contains("MenuBarCanonicalAppIconLoader.load()"),
            "Menu bar status icons must derive from the same canonical AppIcon loader as the rest of the brand UI."
        )
        XCTAssertTrue(
            menuBarControllerSource.contains("Bundle.main.url(forResource: \"AppIcon\", withExtension: \"icns\")"),
            "Packaged menu bar icons must read bundled AppIcon.icns directly."
        )
        XCTAssertFalse(
            menuBarControllerSource.contains("NSImage(named: \"MenuBarIcon\")"),
            "Menu bar status icons must not consult alternate named icon resources."
        )
        XCTAssertFalse(
            menuBarControllerSource.contains("systemSymbolName:"),
            "Menu bar status icons must not hide a missing canonical AppIcon behind an SF Symbol fallback."
        )
        XCTAssertFalse(
            menuBarControllerSource.contains("createCompassMenuBarIcon"),
            "Menu bar status icons must not redraw a separate compass glyph instead of using the canonical AppIcon."
        )
        XCTAssertTrue(
            menuBarIconGeneratorSource.contains("Bundle.main.url(forResource: \"AppIcon\", withExtension: \"icns\")"),
            "The legacy menu bar icon generator API must also render from the bundled canonical AppIcon.icns."
        )
        XCTAssertFalse(
            menuBarIconGeneratorSource.contains("NSColor.black.setStroke()"),
            "The legacy menu bar icon generator API must not draw an alternate monochrome signal glyph."
        )
        XCTAssertFalse(
            menuBarIconGeneratorSource.contains("isTemplate = true"),
            "The legacy menu bar icon generator API must not convert the canonical brand icon into a template replacement."
        )
        XCTAssertFalse(
            notificationSource.contains("Bundle.main"),
            "Startup notification setup must not touch Bundle.main before the root view can render."
        )
    }

    func testIOSAppIconPipelineDerivesFromCanonicalAppIcon() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let regenerateScript = try readSource("Scripts/regenerate_app_icons.sh")
        let iosProject = try readSource("SkyBridge Compass iOS/SkyBridgeCompass-iOS.xcodeproj/project.pbxproj")
        let iosAppIconContents = try readSource(
            "SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
        )

        let canonicalAppIcon = try Data(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCompassApp/Resources/AppIcon.png")
        )
        let iconComposerAppIcon = try Data(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCompassApp/Resources/AppIcon.icon/Assets/Image.png")
        )
        let iosBrandIcon = try Data(
            contentsOf: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Resources/Assets.xcassets/BrandIcon.imageset/BrandIcon.png"
            )
        )
        let sidebarBrandIcon = try Data(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCompassApp/Resources/SidebarBrandIcon.png")
        )

        XCTAssertEqual(
            iconComposerAppIcon,
            canonicalAppIcon,
            "Icon Composer must use the same canonical AppIcon.png as the runtime brand icon source."
        )
        XCTAssertEqual(
            iosBrandIcon,
            canonicalAppIcon,
            "iOS in-app BrandIcon must not drift from the canonical blue compass AppIcon.png."
        )
        XCTAssertNotEqual(
            sidebarBrandIcon,
            canonicalAppIcon,
            "SidebarBrandIcon.png must stay as a small-size optimized derivative instead of drifting back to the regular icon."
        )
        XCTAssertTrue(regenerateScript.contains("MASTER_PNG=\"$RES_DIR/AppIconMaster.png\""))
        XCTAssertTrue(regenerateScript.contains("SidebarBrandIcon.png"))
        XCTAssertTrue(
            regenerateScript.contains("sidebar_safe_area_padding = 64"),
            "SidebarBrandIcon.png needs an optical safe area so the sidebar icon does not touch the 44pt grid edge."
        )
        XCTAssertFalse(regenerateScript.contains("rsvg-convert"))
        XCTAssertTrue(
            regenerateScript.contains("def ios_app_icon_rgb(image):")
        )
        XCTAssertTrue(
            regenerateScript.contains("cropped = image.crop(alpha_bbox)") &&
                regenerateScript.contains("ImageOps.fit(") &&
                regenerateScript.contains("ios_base = ios_app_icon_rgb(img)"),
            "iOS AppIcon.appiconset must crop away the Mac transparent pre-rounded padding and produce a full-square opaque icon."
        )
        XCTAssertTrue(iosProject.contains("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"))
        XCTAssertTrue(iosAppIconContents.contains("\"filename\" : \"AppIcon-1024.png\""))
    }

    func testWebRTCInboundControlLoopIgnoresDuplicateMessageAWithoutResettingSessionState() throws {
        let source = try readSource("Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager.swift")
        let loopBody = try sourceSlice(
            from: "let maxInboundFrameBytes = 8_000_000",
            to: "private func establishP2PConnectionWithCode",
            in: source
        )
        let duplicateMessageABody = try sourceSlice(
            from: "if let activeDriver = handshakeState.driver {",
            to: "if let keys = handshakeState.sessionKeys",
            in: loopBody
        )

        XCTAssertTrue(loopBody.contains("guard totalLen > 0 && totalLen <= maxInboundFrameBytes"))
        XCTAssertTrue(loopBody.contains("var lastInboundFrameLength = 0"))
        XCTAssertTrue(loopBody.contains("var lastDecodedFrameLength = 0"))
        XCTAssertTrue(loopBody.contains("var lastHandshakeDriverState = \"none\""))
        XCTAssertTrue(loopBody.contains("var lastControlLoopEvent = \"start\""))
        XCTAssertTrue(duplicateMessageABody.contains("duplicate_message_a_while_waiting_finished"))
        XCTAssertTrue(duplicateMessageABody.contains("ignored duplicate fresh MessageA while waiting for Finished"))
        XCTAssertTrue(duplicateMessageABody.contains("frameBytes=\\(frame.count"))
        XCTAssertTrue(duplicateMessageABody.contains("continue"))
        XCTAssertFalse(duplicateMessageABody.contains("responder restarting unfinished handshake from fresh MessageA"))
        XCTAssertFalse(duplicateMessageABody.contains("handshakeState.driver = nil"))
        XCTAssertFalse(duplicateMessageABody.contains("self.webrtcSessionKeysBySessionId.removeValue(forKey: sessionID)"))
        XCTAssertTrue(loopBody.contains("lastFrameLen=\\(lastInboundFrameLength"))
        XCTAssertTrue(loopBody.contains("decodedFrameLen=\\(lastDecodedFrameLength"))
        XCTAssertTrue(loopBody.contains("driverState=\\(lastHandshakeDriverState"))
        XCTAssertTrue(loopBody.contains("lastEvent=\\(lastControlLoopEvent"))
        XCTAssertTrue(loopBody.contains("lastRekey=\\(self.lastRekeyEvent ?? \"-\""))
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
            throw SourceMarkerError(startMarker: startMarker, endMarker: endMarker)
        }
        return String(source[start..<end])
    }

    private struct SourceMarkerError: Error, CustomStringConvertible {
        let startMarker: String
        let endMarker: String

        var description: String {
            "Source marker not found from '\(startMarker)' to '\(endMarker)'"
        }
    }
}
