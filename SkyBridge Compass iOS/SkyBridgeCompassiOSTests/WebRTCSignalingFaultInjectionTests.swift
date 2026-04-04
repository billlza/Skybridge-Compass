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

    func testInboundFrameParserOnlyAllowsDirectProbeWhenNoPartialFrameIsBuffered() {
        var parser = CrossNetworkWebRTCManager.InboundFrameParser(maxInboundFrameBytes: 1024)
        let payload = Data("frame".utf8)
        let framed = framedPayload(payload)

        XCTAssertTrue(parser.canProbeDirectCompatibility)
        parser.append(Data(framed.prefix(2)))
        XCTAssertFalse(parser.canProbeDirectCompatibility)
        XCTAssertNil(parser.nextPayload(sessionId: "S3", logLabel: "test"))
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
    func testActualNativeRenderEvidenceRequiresRendererOrReceiverStats() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("heartbeat-renderer")
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("rtc-mtl-video-view")
        )
        XCTAssertTrue(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("receiver-stats")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence("fallback-screen-data-confirmed")
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.testOnlyIsActualNativeRenderEvidence(
                "receiver-packet-confirmed:fallback-screen-data-confirmed"
            )
        )
    }

    @MainActor
    func testSessionScopedSignalingURLPrefersCurrentPathOrigin() {
        let resolved = CrossNetworkWebRTCManager.resolvedSignalingWebSocketURLString(
            signalingOrigin: "https://signal.example.com:8443",
            fallbackWebSocketURL: "wss://fallback.example.com/ws"
        )
        XCTAssertEqual(resolved, "wss://signal.example.com:8443/ws")
    }

    @MainActor
    func testSessionScopedSignalingURLFallsBackForInvalidOrigin() {
        let fallback = "wss://fallback.example.com/ws"
        let resolved = CrossNetworkWebRTCManager.resolvedSignalingWebSocketURLString(
            signalingOrigin: "not a url",
            fallbackWebSocketURL: fallback
        )
        XCTAssertEqual(resolved, fallback)
    }

    @MainActor
    func testSignalingRecoveryIsSuppressedDuringLocalTeardown() {
        XCTAssertTrue(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: true,
                suppressRecovery: false
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: true,
                suppressRecovery: true
            )
        )
        XCTAssertFalse(
            CrossNetworkWebRTCManager.shouldScheduleSignalingRecovery(
                isTransportEstablished: false,
                suppressRecovery: false
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
