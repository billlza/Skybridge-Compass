import CFNetwork
import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class WebRTCSignalingFaultInjectionTests: XCTestCase {
    func testInboundFrameParserReassemblesValidFragmentedPayload() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 1024)
        let payload = Data("hello-webrtc".utf8)
        let framed = framedPayload(payload)

        parser.append(Data(framed.prefix(3)))
        XCTAssertFalse(parser.canProbeDirectCompatibility)
        XCTAssertNil(parser.nextPayload(sessionId: "S1", logLabel: "test"))

        parser.append(Data(framed.dropFirst(3)))
        XCTAssertEqual(parser.nextPayload(sessionId: "S1", logLabel: "test"), payload)
        XCTAssertTrue(parser.canProbeDirectCompatibility)
    }

    func testInboundFrameParserClearsBufferAfterInvalidLengthPrefix() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 1024)
        parser.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))

        XCTAssertNil(parser.nextPayload(sessionId: "S2", logLabel: "test"))
        XCTAssertTrue(parser.canProbeDirectCompatibility)

        let payload = Data("recovered".utf8)
        parser.append(framedPayload(payload))
        XCTAssertEqual(parser.nextPayload(sessionId: "S2", logLabel: "test"), payload)
    }

    func testInboundFrameParserAcceptsExactMaxFrameAndStickyNextFrame() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 8192)
        let exactMaxPayload = Data((0..<8192).map { UInt8($0 % 251) })
        let nextPayload = Data("next".utf8)
        var combined = framedPayload(exactMaxPayload)
        combined.append(framedPayload(nextPayload))

        parser.append(Data(combined.prefix(2)))
        XCTAssertNil(parser.nextPayload(sessionId: "S2-exact", logLabel: "test"))

        parser.append(Data(combined.dropFirst(2)))
        XCTAssertEqual(parser.nextPayload(sessionId: "S2-exact", logLabel: "test"), exactMaxPayload)
        XCTAssertEqual(parser.nextPayload(sessionId: "S2-exact", logLabel: "test"), nextPayload)

        var oversizedParser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 8192)
        oversizedParser.append(framedPayload(Data(repeating: 0xA5, count: 8193)))
        XCTAssertNil(oversizedParser.nextPayload(sessionId: "S2-oversized", logLabel: "test"))
        XCTAssertTrue(oversizedParser.canProbeDirectCompatibility)
    }

    func testInboundFrameParserOnlyAllowsDirectProbeWhenNoPartialFrameIsBuffered() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 1024)
        let payload = Data("frame".utf8)
        let framed = framedPayload(payload)

        XCTAssertTrue(parser.canProbeDirectCompatibility)
        parser.append(Data(framed.prefix(2)))
        XCTAssertFalse(parser.canProbeDirectCompatibility)
        XCTAssertNil(parser.nextPayload(sessionId: "S3", logLabel: "test"))
    }

    func testInboundFrameParserDropsSBP2WithoutInterpretingItAsLength() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 1024)
        let directSBP2 = Data([0x53, 0x42, 0x50, 0x32, 0x00, 0x00, 0x00, 0x10])

        parser.append(directSBP2)
        XCTAssertNil(parser.nextPayload(sessionId: "S4", logLabel: "test"))
        XCTAssertTrue(parser.canProbeDirectCompatibility)

        let payload = Data("recovered".utf8)
        parser.append(framedPayload(payload))
        XCTAssertEqual(parser.nextPayload(sessionId: "S4", logLabel: "test"), payload)
    }

    func testInboundFrameParserDropsSBC2WrongChannelWithoutInterpretingItAsLength() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 1024)
        let sbc2ChunkOnControlChannel = Data([0x53, 0x42, 0x43, 0x32, 0x00, 0x00, 0x00, 0x01])

        parser.append(sbc2ChunkOnControlChannel)
        XCTAssertNil(parser.nextPayload(sessionId: "S5", logLabel: "test"))
        XCTAssertTrue(parser.canProbeDirectCompatibility)

        let payload = Data("recovered-after-sbc2".utf8)
        parser.append(framedPayload(payload))
        XCTAssertEqual(parser.nextPayload(sessionId: "S5", logLabel: "test"), payload)
    }

    func testInvalidWebSocketURLFailsFastWithoutRetry() async {
        await Task { @MainActor in
            let probe = RetryProbe()
            let controller = SignalingRetryController(
                retryDelay: .milliseconds(10),
                attemptTimeout: .seconds(1),
                sleep: { duration in
                    await probe.recordSleep(duration)
                }
            )

            XCTAssertNil(SignalingRetryController.validatedWebSocketURL("http://example.com/ws"))
            XCTAssertNil(SignalingRetryController.validatedWebSocketURL("wss://"))
            XCTAssertNotNil(SignalingRetryController.validatedWebSocketURL("wss://example.com/ws"))

            do {
                try await controller.sendWithRetry(
                    retries: 3,
                    reconnectIfNeeded: {
                        await probe.recordReconnect()
                    },
                    send: {
                        throw SignalingRetryControllerError.invalidWebSocketURL("wss://")
                    }
                )
                XCTFail("Expected invalid URL error")
            } catch let error as SignalingRetryControllerError {
                XCTAssertEqual(error, .invalidWebSocketURL("wss://"))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            let reconnectCount = await probe.reconnectCount()
            let sleepCount = await probe.sleepCount()
            XCTAssertEqual(reconnectCount, 0)
            XCTAssertEqual(sleepCount, 0)
        }.value
    }

    func testReconnectBackoffAfterNotConnectedThenSuccess() async throws {
        try await Task { @MainActor in
            let probe = RetryProbe()
            let controller = SignalingRetryController(
                retryDelay: .milliseconds(10),
                attemptTimeout: .seconds(1),
                sleep: { duration in
                    await probe.recordSleep(duration)
                }
            )

            try await controller.sendWithRetry(
                retries: 2,
                reconnectIfNeeded: {
                    await probe.recordReconnect()
                },
                send: {
                    let attempt = await probe.nextAttempt()
                    if attempt == 1 {
                        throw WebSocketSignalingClient.SignalingError.notConnected
                    }
                }
            )

            let attemptCount = await probe.attemptCount()
            let reconnectCount = await probe.reconnectCount()
            let sleepCount = await probe.sleepCount()
            XCTAssertEqual(attemptCount, 2)
            XCTAssertEqual(reconnectCount, 1)
            XCTAssertEqual(sleepCount, 1)
        }.value
    }

    func testTimeoutCancelsHangingSendAttempt() async {
        await Task { @MainActor in
            let cancelFlag = CancellationFlag()
            let controller = SignalingRetryController(
                retryDelay: .milliseconds(10),
                attemptTimeout: .milliseconds(40),
                sleep: { _ in }
            )

            do {
                try await controller.sendWithRetry(
                    retries: 0,
                    reconnectIfNeeded: {},
                    send: {
                        try await withTaskCancellationHandler {
                            try await Task.sleep(for: .seconds(2))
                        } onCancel: {
                            cancelFlag.markCancelled()
                        }
                    }
                )
                XCTFail("Expected timeout error")
            } catch let error as SignalingRetryControllerError {
                XCTAssertEqual(error, .attemptTimedOut)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            try? await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(cancelFlag.isCancelled)
        }.value
    }

    func testQRCodeBootstrapUsesLongerNetworkStartupTimeouts() async {
        await Task { @MainActor in
            XCTAssertGreaterThanOrEqual(
                CrossNetworkWebRTCManager.testOnlyCurrentPathRequestTimeoutSeconds(),
                30
            )
            XCTAssertGreaterThanOrEqual(
                CrossNetworkWebRTCManager.testOnlyWebRTCStartupJoinHeartbeatAttempts(),
                60
            )
            XCTAssertGreaterThanOrEqual(
                SignalingRetryController.testOnlyDefaultAttemptTimeoutSeconds(),
                15
            )
            XCTAssertGreaterThanOrEqual(
                WebSocketSignalingClient.testOnlyDefaultConnectionTimeoutSeconds(),
                15
            )
        }.value
    }

    func testSignalingFailureClassificationStaysInPolicy() {
        XCTAssertEqual(
            CrossNetworkWebRTCManager.classifySignalingFailureReason("token expired"),
            .tokenExpired
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.classifySignalingFailureReason("socket is not connected"),
            .transientNetwork
        )
        XCTAssertEqual(
            CrossNetworkWebRTCManager.classifySignalingFailureReason("malformed signaling payload"),
            .protocolViolation
        )
        XCTAssertTrue(CrossNetworkWebRTCManager.isFatalPreTransportFailure(.authBindRejected))
        XCTAssertTrue(CrossNetworkWebRTCManager.isFatalPostTransportFailure(.protocolViolation))
        XCTAssertFalse(CrossNetworkWebRTCManager.isFatalPreTransportFailure(.tokenExpired))
        XCTAssertFalse(CrossNetworkWebRTCManager.isFatalPostTransportFailure(.transientNetwork))
    }

    func testWebSocketSignalingClientParsesServerFramesAndRedactsTokenizedURL() async {
        await Task { @MainActor in
            let raw = #"{"type":"bound","sessionId":"ROOM1234","role":"initiator","clientId":"client-1"}"#
            let parsed = WebSocketSignalingClient.parseInboundText(raw)

            switch parsed {
            case .serverFrame(let frame):
                XCTAssertEqual(frame.type, "bound")
                XCTAssertEqual(frame.sessionId, "ROOM1234")
                XCTAssertFalse(frame.isError)
            default:
                XCTFail("Expected server frame, got \(parsed)")
            }

            let url = URL(string: "wss://api.example.com/ws?shard=ROOM1234&st=secret-token&cv=1.0&pv=1")!
            let redacted = WebSocketSignalingClient.redactedURLString(url)
            XCTAssertFalse(redacted.contains("secret-token"))
            XCTAssertTrue(redacted.contains("st=%3Credacted%3E") || redacted.contains("st=<redacted>"))
        }.value
    }

    func testWebSocketSignalingClientAllocatesDistinctHandleGenerationsPerAttempt() async {
        await Task { @MainActor in
            let client = WebSocketSignalingClient(
                url: URL(string: "wss://signal.example.com/ws")!,
                sessionId: "ROOM1234",
                generation: 41
            )

            let first = await client.testOnlyReserveNextHandleId(for: .urlSession)
            let second = await client.testOnlyReserveNextHandleId(for: .urlSession)

            XCTAssertEqual(first.generation, 41)
            XCTAssertEqual(second.generation, 42)
            XCTAssertNotEqual(first, second)
        }.value
    }

    func testNoProxyConfigurationDisablesSystemProxyMechanisms() {
        let dictionary = WebSocketSignalingClient.testOnlyNoProxyConnectionProxyDictionary()

        XCTAssertEqual(dictionary[kCFProxyTypeKey as String] as? String, kCFProxyTypeNone as String)
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPEnable as String] as? Bool, false)
        XCTAssertEqual(dictionary["HTTPSEnable"] as? Bool, false)
        XCTAssertEqual(dictionary["SOCKSEnable"] as? Bool, false)
        XCTAssertEqual(dictionary["ProxyAutoConfigEnable"] as? Bool, false)
        XCTAssertEqual(dictionary["ProxyAutoDiscoveryEnable"] as? Bool, false)
    }

    func testAutoPolicyUsesNativeProxyBypassBeforeURLSessionFallback() async {
        await Task { @MainActor in
            let client = WebSocketSignalingClient(
                url: URL(string: "wss://signal.example.com/ws")!,
                sessionId: "ROOM1234",
                generation: 1
            )

            let labels = await client.testOnlyTransportAttemptLabels()

            XCTAssertEqual(labels, [
                "native-proxy-bypass",
                "urlsession-proxy-bypass",
                "native",
                "urlsession",
            ])
        }.value
    }

    func testNativeWebSocketParametersHonorPreferNoProxies() {
        let directParameters = NativeWebSocketClient.testOnlyBuildParameters(
            tls: true,
            pingInterval: 30,
            preferNoProxies: true
        )
        XCTAssertTrue(directParameters.preferNoProxies)

        let defaultParameters = NativeWebSocketClient.testOnlyBuildParameters(
            tls: true,
            pingInterval: 30,
            preferNoProxies: false
        )
        XCTAssertFalse(defaultParameters.preferNoProxies)
    }

    @MainActor
    func testConnectingSessionCanScheduleSignalingRecoveryBeforeTransportReady() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: false,
                isSessionConnecting: true,
                suppressRecovery: false
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: true,
                isSessionConnecting: false,
                suppressRecovery: false
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: false,
                isSessionConnecting: false,
                suppressRecovery: false
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: true,
                isSessionConnecting: true,
                suppressRecovery: true
            )
        )
    }

    func testInitialWebRTCHandshakeStartsFromOffererOnly() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyShouldInitiateInitialWebRTCHandshake(role: .offerer)
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyShouldInitiateInitialWebRTCHandshake(role: .answerer)
        )
    }

    func testInitialWebRTCHandshakeUsesClassicForAuthorityBoundQRAndCodeSessions() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyShouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionId: "qr-session",
                authorityBoundBootstrapSessionIds: ["qr-session"],
                expectedRemoteAuthorityAlgorithm: nil,
                localConnectionSessionId: nil
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyShouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionId: "local-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: nil,
                localConnectionSessionId: "local-session"
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyShouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionId: "answerer-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .ed25519,
                localConnectionSessionId: nil
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyShouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionId: "pqc-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .mlDSA65,
                localConnectionSessionId: nil
            )
        )
    }

    @MainActor
    func testRedeemedQRSessionArtifactsReuseRequiresMatchingOriginAndAuthority() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyShouldReuseRedeemedQRSessionArtifacts(
                canonicalQRSignalingOrigin: "https://signal.example.com",
                qrDeviceId: "device-a",
                qrProtocolSigningAlgorithm: .ed25519,
                qrProtocolPublicKeyFingerprint: "fingerprint-a",
                qrProtocolPublicKeyBytes: Data([0xAA, 0xBB]),
                signalingToken: " session-token ",
                turnAdmissionToken: " turn-token ",
                cachedSignalingOrigin: "https://signal.example.com",
                cachedAuthorityDeviceId: "device-a",
                cachedAuthorityProtocolSigningAlgorithm: .ed25519,
                cachedAuthorityProtocolPublicKeyFingerprint: "fingerprint-a",
                cachedAuthorityProtocolPublicKeyBytes: Data([0xAA, 0xBB])
            )
        )

        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyShouldReuseRedeemedQRSessionArtifacts(
                canonicalQRSignalingOrigin: "https://signal.example.com",
                qrDeviceId: "device-a",
                qrProtocolSigningAlgorithm: .ed25519,
                qrProtocolPublicKeyFingerprint: "fingerprint-a",
                qrProtocolPublicKeyBytes: Data([0xAA, 0xBB]),
                signalingToken: "session-token",
                turnAdmissionToken: "turn-token",
                cachedSignalingOrigin: "https://other.example.com",
                cachedAuthorityDeviceId: "device-a",
                cachedAuthorityProtocolSigningAlgorithm: .ed25519,
                cachedAuthorityProtocolPublicKeyFingerprint: "fingerprint-a",
                cachedAuthorityProtocolPublicKeyBytes: Data([0xAA, 0xBB])
            )
        )

        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyShouldReuseRedeemedQRSessionArtifacts(
                canonicalQRSignalingOrigin: "https://signal.example.com",
                qrDeviceId: "device-a",
                qrProtocolSigningAlgorithm: .ed25519,
                qrProtocolPublicKeyFingerprint: "fingerprint-a",
                qrProtocolPublicKeyBytes: Data([0xAA, 0xBB]),
                signalingToken: "session-token",
                turnAdmissionToken: "turn-token",
                cachedSignalingOrigin: "https://signal.example.com",
                cachedAuthorityDeviceId: "device-a",
                cachedAuthorityProtocolSigningAlgorithm: .ed25519,
                cachedAuthorityProtocolPublicKeyFingerprint: "fingerprint-b",
                cachedAuthorityProtocolPublicKeyBytes: Data([0xAA, 0xBB])
            )
        )
    }

    @MainActor
    func testActualNativeRenderEvidenceRequiresRendererCallback() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("rtc-mtl-video-view")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("heartbeat-renderer")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("fallback-screen-data-confirmed")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("receiver-stats")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence(
                "receiver-packet-confirmed:fallback-screen-data-confirmed"
            )
        )
    }

    @MainActor
    func testSessionScopedSignalingURLFollowsCurrentPathEndpoint() {
        let resolved = CrossNetworkWebRTCManager.resolvedSignalingWebSocketURLString(
            signalingOrigin: "https://signal.example.com:8443",
            signalingWebSocketPath: "/tenant/ws"
        )
        XCTAssertEqual(resolved, "wss://signal.example.com:8443/tenant/ws")
    }

    @MainActor
    func testSessionScopedSignalingURLFailsClosedForInvalidOrigin() {
        let resolved = CrossNetworkWebRTCManager.resolvedSignalingWebSocketURLString(
            signalingOrigin: "not a url",
            signalingWebSocketPath: "/tenant/ws"
        )
        XCTAssertNil(resolved)
    }

    @MainActor
    func testSessionScopedSignalingURLFailsClosedForInvalidWebSocketPath() {
        let resolved = CrossNetworkWebRTCManager.resolvedSignalingWebSocketURLString(
            signalingOrigin: "https://signal.example.com:8443",
            signalingWebSocketPath: "tenant/ws?fallback=/ws"
        )
        XCTAssertNil(resolved)
    }

    @MainActor
    func testCurrentPathWebSocketPathValidationDistinguishesMissingFromInvalid() {
        XCTAssertThrowsError(
            try CrossNetworkWebRTCManager.instance.validateCurrentPathWebSocketPath(nil)
        ) { error in
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "missing current-path signaling websocket path"
            )
        }

        XCTAssertThrowsError(
            try CrossNetworkWebRTCManager.instance.validateCurrentPathWebSocketPath("tenant/ws")
        ) { error in
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                "invalid current-path signaling websocket path"
            )
        }
    }

    func testCurrentPathArtifactsValidateEndpointBeforeCachingTokens() throws {
        let source = try repositorySource(
            "SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager.swift"
        )

        assertEndpointValidationPrecedesTokenCaching(
            in: source,
            sectionStart: "public func connect(withCode rawCode: String)",
            sectionEnd: "public func generateConnectionCode()",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: lookup.signalingServerOrigin,\n                wsPath: lookup.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[lookup.sessionID] = lookup.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: source,
            sectionStart: "public func generateConnectionCode()",
            sectionEnd: "private func scheduleConnectionCodeLeaseInvalidation",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: lease.signalingServerOrigin,\n                wsPath: lease.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: source,
            sectionStart: "public func generateConnectLink",
            sectionEnd: "public func disconnect",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n                origin: lease.signalingServerOrigin,\n                wsPath: lease.wsPath\n            )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[lease.sessionID] = lease.sessionToken"
        )
        assertEndpointValidationPrecedesTokenCaching(
            in: source,
            sectionStart: "private func parseSkybridgeConnectLink",
            sectionEnd: "nonisolated private static func normalizedNonEmptyToken",
            endpointVariable: "let signalingEndpoint = try validatedCurrentPathSignalingEndpoint(\n            origin: redeemed.signalingServerOrigin,\n            wsPath: redeemed.wsPath\n        )",
            tokenWrite: "webrtcSignalingAuthTokenBySessionId[qr.sessionID] = redeemed.sessionToken"
        )
        XCTAssertFalse(source.contains("cacheCurrentPathSignalingEndpoint("))
    }

    func testCurrentPathLeaseDecodingPreservesSignalingWebSocketPath() throws {
        let registerData = try JSONSerialization.data(
            withJSONObject: [
                "sessionId": "SESSION123",
                "sessionToken": "session-token",
                "qrBootstrapToken": "qr-token",
                "turnAdmissionToken": "turn-token",
                "mediaAdmissionToken": "media-token",
                "expiresIn": 300,
                "signalingServerOrigin": "https://signal.example.com",
                "wsPath": "/tenant/ws"
            ],
            options: [.sortedKeys]
        )
        let sessionLease = try SignalServerClientCompat.testOnlyDecodeRegisterSessionResponse(registerData)
        XCTAssertEqual(sessionLease.signalingServerOrigin, "https://signal.example.com")
        XCTAssertEqual(sessionLease.wsPath, "/tenant/ws")

        let lookupData = try JSONSerialization.data(
            withJSONObject: [
                "found": true,
                "sessionId": "SESSION123",
                "sessionToken": "responder-token",
                "turnAdmissionToken": "turn-token",
                "mediaAdmissionToken": "media-token",
                "expiresIn": 300,
                "signalingServerOrigin": "https://signal.example.com",
                "wsPath": "/tenant/ws",
                "initiatorDeviceId": "device-123",
                "initiatorProtocolSigningAlgorithm": ProtocolSigningAlgorithm.ed25519.rawValue,
                "initiatorProtocolPublicKeyFingerprint": "fingerprint-123",
                "initiatorDeviceName": "SkyBridge Mac"
            ],
            options: [.sortedKeys]
        )
        let lookup = try SignalServerClientCompat.testOnlyDecodeLookupConnectionCodeResponse(lookupData)
        XCTAssertEqual(lookup.signalingServerOrigin, "https://signal.example.com")
        XCTAssertEqual(lookup.wsPath, "/tenant/ws")
    }

    func testCurrentPathSessionRefreshRequiresSignalingWebSocketPath() throws {
        let validRefreshData = try JSONSerialization.data(
            withJSONObject: [
                "sessionId": "SESSION123",
                "role": "responder",
                "sessionToken": "session-token",
                "turnAdmissionToken": "turn-token",
                "mediaAdmissionToken": "media-token",
                "expiresIn": 300,
                "signalingServerOrigin": "https://signal.example.com",
                "wsPath": "/tenant/ws",
                "serverBuildFingerprint": "test-build",
                "sessionTokenGeneration": "session-generation",
                "mediaTokenGeneration": "media-generation"
            ],
            options: [.sortedKeys]
        )
        let refresh = try SignalServerClientCompat.testOnlyDecodeSessionRefreshResponse(
            validRefreshData,
            sessionId: "SESSION123",
            role: "responder"
        )
        XCTAssertEqual(refresh.signalingServerOrigin, "https://signal.example.com")
        XCTAssertEqual(refresh.wsPath, "/tenant/ws")

        let missingPathData = try JSONSerialization.data(
            withJSONObject: [
                "sessionId": "SESSION123",
                "role": "responder",
                "sessionToken": "session-token",
                "turnAdmissionToken": "turn-token",
                "mediaAdmissionToken": "media-token",
                "expiresIn": 300,
                "signalingServerOrigin": "https://signal.example.com"
            ],
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try SignalServerClientCompat.testOnlyDecodeSessionRefreshResponse(
                missingPathData,
                sessionId: "SESSION123",
                role: "responder"
            )
        )
    }

    @MainActor
    func testSignalingRecoveryIsSuppressedDuringLocalTeardown() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: true,
                isSessionConnecting: false,
                suppressRecovery: false
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: true,
                isSessionConnecting: false,
                suppressRecovery: true
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: false,
                isSessionConnecting: false,
                suppressRecovery: false
            )
        )
    }

    @MainActor
    func testPostTransportICEFailuresDeferToSharedRecovery() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                suppressRecovery: false,
                messageType: .iceCandidate
            )
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                suppressRecovery: false,
                messageType: .offer
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                suppressRecovery: false,
                messageType: .leave
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                suppressRecovery: true,
                messageType: .iceCandidate
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: false,
                suppressRecovery: false,
                messageType: .iceCandidate
            )
        )
    }
}

@available(iOS 17.0, *)
private func framedPayload(_ payload: Data) -> Data {
    var framed = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
    framed.append(payload)
    return framed
}

@available(iOS 17.0, *)
private func repositorySource(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = root.appendingPathComponent(relativePath)
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

@available(iOS 17.0, *)
private func assertEndpointValidationPrecedesTokenCaching(
    in source: String,
    sectionStart: String,
    sectionEnd: String,
    endpointVariable: String,
    tokenWrite: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard let startRange = source.range(of: sectionStart),
          let endRange = source.range(of: sectionEnd, range: startRange.upperBound..<source.endIndex) else {
        XCTFail("Missing source section \(sectionStart)", file: file, line: line)
        return
    }
    let section = source[startRange.lowerBound..<endRange.lowerBound]
    guard let endpointRange = section.range(of: endpointVariable),
          let tokenRange = section.range(of: tokenWrite) else {
        XCTFail("Missing endpoint validation or token write in \(sectionStart)", file: file, line: line)
        return
    }
    XCTAssertLessThan(endpointRange.lowerBound, tokenRange.lowerBound, file: file, line: line)
}

@available(iOS 17.0, *)
private actor RetryProbe {
    private var attempts: Int = 0
    private var reconnects: Int = 0
    private var sleeps: Int = 0

    func nextAttempt() -> Int {
        attempts += 1
        return attempts
    }

    func recordReconnect() {
        reconnects += 1
    }

    func recordSleep(_ duration: Duration) {
        _ = duration
        sleeps += 1
    }

    func attemptCount() -> Int { attempts }
    func reconnectCount() -> Int { reconnects }
    func sleepCount() -> Int { sleeps }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled: Bool = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
