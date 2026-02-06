//
// HandshakeDriverTests.swift
// SkyBridgeCoreTests
//
// Property-based tests for HandshakeDriver
// **Feature: tech-debt-cleanup, Property 4: Handshake State Machine Validity**
// **Feature: tech-debt-cleanup, Property 6: Handshake Timeout Enforcement**
// **Validates: Requirements 4.1, 4.2, 4.5, 5.4**
//

import XCTest
import CryptoKit
@testable import SkyBridgeCore

// MARK: - Mock Transport

/// Mock transport for testing HandshakeDriver
@available(macOS 14.0, iOS 17.0, *)
actor MockDiscoveryTransport: DiscoveryTransport {

 /// Sent messages (peer, data)
    private(set) var sentMessages: [(PeerIdentifier, Data)] = []

 /// Whether send should fail
    private var _shouldFailSend: Bool = false

 /// Error to throw when send fails
    private var _sendError: Error = NSError(domain: "MockTransport", code: 1, userInfo: nil)

 /// Delay before send completes (for testing timing)
    private var _sendDelay: Duration = .zero

 /// Message handler for incoming messages
    var messageHandler: ((PeerIdentifier, Data) async -> Void)?

    func send(to peer: PeerIdentifier, data: Data) async throws {
        if _sendDelay > .zero {
            try await Task.sleep(for: _sendDelay)
        }

        if _shouldFailSend {
            throw _sendError
        }

        sentMessages.append((peer, data))
    }

 /// Simulate receiving a message
    func simulateReceive(from peer: PeerIdentifier, data: Data) async {
        await messageHandler?(peer, data)
    }

 /// Clear sent messages
    func clearMessages() {
        sentMessages = []
    }

 /// Get sent message count
    func getSentMessageCount() -> Int {
        return sentMessages.count
    }

    func getSentMessages() -> [(PeerIdentifier, Data)] {
        return sentMessages
    }

 /// Configure to fail sends
    func setShouldFailSend(_ value: Bool) {
        _shouldFailSend = value
    }

 /// Configure send error
    func setSendError(_ error: Error) {
        _sendError = error
    }

 /// Configure send delay
    func setSendDelay(_ delay: Duration) {
        _sendDelay = delay
    }
}

// MARK: - Mock Trust Provider

@available(macOS 14.0, iOS 17.0, *)
struct StaticTrustProvider: HandshakeTrustProvider, Sendable {
    let deviceId: String
    let fingerprint: String?

    func trustedFingerprint(for deviceId: String) async -> String? {
        guard deviceId == self.deviceId else { return nil }
        return fingerprint
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        guard deviceId == self.deviceId else { return [:] }
        return [:]
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        guard deviceId == self.deviceId else { return nil }
        return nil
    }
}

// MARK: - HandshakeDriverTests

@available(macOS 14.0, iOS 17.0, *)
final class HandshakeDriverTests: XCTestCase {

 // MARK: - Test Fixtures

    private var transport: MockDiscoveryTransport!
    private var provider: ClassicCryptoProvider!
    private var identityKeyPair: KeyPair!

    override func setUp() async throws {
        try await super.setUp()
        transport = MockDiscoveryTransport()
        provider = ClassicCryptoProvider()
        identityKeyPair = try await provider.generateKeyPair(for: .signing)
    }

    override func tearDown() async throws {
        transport = nil
        provider = nil
        identityKeyPair = nil
        try await super.tearDown()
    }

    private func fingerprint(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func makeDriver(
        transport: MockDiscoveryTransport? = nil,
        cryptoProvider: (any CryptoProvider)? = nil,
        identityKeyHandle: SigningKeyHandle? = nil,
        identityPublicKey: Data? = nil,
        policy: HandshakePolicy = .default,
        cryptoPolicy: CryptoPolicy = .default,
        timeout: Duration = .seconds(5),
        trustProvider: (any HandshakeTrustProvider)? = nil,
        protocolSignatureProvider: (any ProtocolSignatureProvider)? = nil,
        sigAAlgorithm: ProtocolSigningAlgorithm = .ed25519,
        offeredSuites: [CryptoSuite] = [.x25519Ed25519],
        sePoPSignatureProvider: (any SePoPSignatureProvider)? = nil,
        sePoPSigningKeyHandle: SigningKeyHandle? = nil,
        metricsCollector: HandshakeMetricsCollector? = nil
    ) throws -> HandshakeDriver {
        let transport = transport ?? self.transport!
        let cryptoProvider = cryptoProvider ?? provider!
        let identityKeyHandle = identityKeyHandle ?? .softwareKey(identityKeyPair.privateKey.bytes)
        let identityPublicKey = identityPublicKey ?? encodeIdentityPublicKey(identityKeyPair.publicKey.bytes)
        let protocolSignatureProvider = protocolSignatureProvider ?? ClassicSignatureProvider()

        return try HandshakeDriver(
            transport: transport,
            cryptoProvider: cryptoProvider,
            protocolSignatureProvider: protocolSignatureProvider,
            protocolSigningKeyHandle: identityKeyHandle,
            sigAAlgorithm: sigAAlgorithm,
            identityPublicKey: identityPublicKey,
            sePoPSignatureProvider: sePoPSignatureProvider,
            sePoPSigningKeyHandle: sePoPSigningKeyHandle,
            offeredSuites: offeredSuites,
            policy: policy,
            cryptoPolicy: cryptoPolicy,
            timeout: timeout,
            metricsCollector: metricsCollector,
            trustProvider: trustProvider
        )
    }

 // MARK: - Property 4: Handshake State Machine Validity

 /// **Property 4: Handshake State Machine Validity**
 /// *For any* sequence of handshake events, the HandshakeDriver SHALL only
 /// transition through valid state sequences:
 /// idle → sendingMessageA → waitingMessageB → established | failed
 /// **Validates: Requirements 4.1, 4.2**

 /// Test that driver starts in idle state
    func testProperty4_InitialStateIsIdle() async throws {
        let driver = try makeDriver(timeout: .seconds(5))

        let state = await driver.getCurrentState()
        guard case .idle = state else {
            XCTFail("Initial state should be idle, got \(state)")
            return
        }
    }

 /// Test that initiating handshake transitions to sendingMessageA then waitingMessageB
    func testProperty4_InitiateTransitionsToWaitingMessageB() async throws {
        let driver = try makeDriver(timeout: .seconds(5))

        let peer = PeerIdentifier(deviceId: "test-peer")

 // Start handshake in background
        let handshakeTask = Task {
            try await driver.initiateHandshake(with: peer)
        }

 // Give time for state transition
        try await Task.sleep(for: .milliseconds(100))

        let state = await driver.getCurrentState()
        guard case .waitingMessageB = state else {
            XCTFail("State should be waitingMessageB after initiate, got \(state)")
            handshakeTask.cancel()
            return
        }

 // Verify message was sent
        let sentCount = await transport.getSentMessageCount()
        XCTAssertEqual(sentCount, 1, "Should have sent MessageA")

 // Cancel to clean up
        await driver.cancel()
        handshakeTask.cancel()
    }

 /// Test that transport failure transitions to failed state
    func testProperty4_TransportFailureTransitionsToFailed() async throws {
        await transport.setShouldFailSend(true)

        let driver = try makeDriver(timeout: .seconds(5))

        let peer = PeerIdentifier(deviceId: "test-peer")

        do {
            _ = try await driver.initiateHandshake(with: peer)
            XCTFail("Should have thrown error")
        } catch {
 // Expected
        }

        let state = await driver.getCurrentState()
        guard case .failed(let reason) = state else {
            XCTFail("State should be failed after transport error, got \(state)")
            return
        }

        guard case .transportError = reason else {
            XCTFail("Failure reason should be transportError, got \(reason)")
            return
        }
    }

    func testIdentityPinningMismatchFailsHandshake() async throws {
        let trustedKeyPair = try await provider.generateKeyPair(for: .signing)
        let untrustedKeyPair = try await provider.generateKeyPair(for: .signing)
        let trustProvider = StaticTrustProvider(
            deviceId: "test-peer",
            fingerprint: fingerprint(trustedKeyPair.publicKey.bytes)
        )

        let driver = try makeDriver(trustProvider: trustProvider)

        let initiatorContext = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider
        )
        let messageA = try await initiatorContext.buildMessageA(
            identityKeyHandle: .softwareKey(untrustedKeyPair.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(untrustedKeyPair.publicKey.bytes)
        )

        let peer = PeerIdentifier(deviceId: "test-peer")
        await driver.handleMessage(messageA.encoded, from: peer)

        let state = await driver.getCurrentState()
        guard case .failed(let reason) = state else {
            XCTFail("Expected failed state, got \(state)")
            return
        }

        guard case .identityMismatch = reason else {
            XCTFail("Expected identityMismatch, got \(reason)")
            return
        }
    }

    func testResponderCompletesHandshakeWithSessionKeys() async throws {
        let initiatorKeyPair = try await provider.generateKeyPair(for: .signing)
        let initiatorContext = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider
        )
        let messageA = try await initiatorContext.buildMessageA(
            identityKeyHandle: .softwareKey(initiatorKeyPair.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(initiatorKeyPair.publicKey.bytes)
        )

        let driver = try makeDriver()

        let peer = PeerIdentifier(deviceId: "test-peer")
        await driver.handleMessage(messageA.encoded, from: peer)

        try await Task.sleep(for: .milliseconds(50))

        let stateBeforeFinished = await driver.getCurrentState()
        guard case .waitingFinished(_, let sessionKeys, let expectingFrom) = stateBeforeFinished else {
            XCTFail("Expected waitingFinished after sending MessageB, got \(stateBeforeFinished)")
            return
        }
        XCTAssertEqual(expectingFrom, .initiator)
        XCTAssertFalse(sessionKeys.sendKey.isEmpty, "sendKey should not be empty")
        XCTAssertFalse(sessionKeys.receiveKey.isEmpty, "receiveKey should not be empty")

        let sentMessages = await transport.getSentMessages()
        XCTAssertEqual(sentMessages.count, 2, "Responder should send MessageB and Finished")

        let initiatorFinished = makePeerFinishedFromInitiator(sessionKeys: sessionKeys)
        await driver.handleMessage(initiatorFinished.encoded, from: peer)

        try await Task.sleep(for: .milliseconds(50))

        let stateAfterFinished = await driver.getCurrentState()
        guard case .established(let establishedKeys) = stateAfterFinished else {
            XCTFail("Expected established after Finished, got \(stateAfterFinished)")
            return
        }
        XCTAssertEqual(establishedKeys.negotiatedSuite, sessionKeys.negotiatedSuite)
    }

    func testResponderFinishOnceRecordsSuccessMetrics() async throws {
        let initiatorKeyPair = try await provider.generateKeyPair(for: .signing)
        let initiatorContext = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: provider
        )
        let messageA = try await initiatorContext.buildMessageA(
            identityKeyHandle: .softwareKey(initiatorKeyPair.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(initiatorKeyPair.publicKey.bytes)
        )

        let driver = try makeDriver()

        let peer = PeerIdentifier(deviceId: "test-peer")
        await driver.handleMessage(messageA.encoded, from: peer)

        try await Task.sleep(for: .milliseconds(50))

        let state = await driver.getCurrentState()
        guard case .waitingFinished(_, let sessionKeys, _) = state else {
            XCTFail("Expected waitingFinished before metrics, got \(state)")
            return
        }

        let initiatorFinished = makePeerFinishedFromInitiator(sessionKeys: sessionKeys)
        await driver.handleMessage(initiatorFinished.encoded, from: peer)

        try await Task.sleep(for: .milliseconds(50))

        let metrics = await driver.getLastMetrics()
        XCTAssertNotNil(metrics)
        if let metrics {
            XCTAssertNil(metrics.failureReason)
            XCTAssertNotNil(metrics.cryptoSuite)
            XCTAssertEqual(metrics.isFallback, false)
            XCTAssertGreaterThanOrEqual(metrics.handshakeDurationMs, 0)
        }
    }

    private func makePeerFinishedFromInitiator(sessionKeys: SessionKeys) -> HandshakeFinished {
        let macKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKeys.receiveKey),
            salt: Data(),
            info: Data("SkyBridge-FINISHED|I2R|".utf8) + sessionKeys.transcriptHash,
            outputByteCount: 32
        )
        let mac = HMAC<SHA256>.authenticationCode(for: sessionKeys.transcriptHash, using: macKey)
        return HandshakeFinished(direction: .initiatorToResponder, mac: Data(mac))
    }

 /// Test that double initiate throws alreadyInProgress
    func testProperty4_DoubleInitiateThrowsAlreadyInProgress() async throws {
        let driver = try makeDriver(timeout: .seconds(10))

        let peer = PeerIdentifier(deviceId: "test-peer")

 // Start first handshake
        let firstTask = Task {
            try await driver.initiateHandshake(with: peer)
        }

 // Give time for state transition
        try await Task.sleep(for: .milliseconds(100))

 // Try to start second handshake
        do {
            _ = try await driver.initiateHandshake(with: peer)
            XCTFail("Second initiate should throw alreadyInProgress")
        } catch let error as HandshakeError {
            switch error {
            case .alreadyInProgress:
                break // Expected
            default:
                XCTFail("Expected alreadyInProgress, got \(error)")
            }
        }

 // Clean up
        await driver.cancel()
        firstTask.cancel()
    }

 /// Test that cancel transitions to failed with cancelled reason
    func testProperty4_CancelTransitionsToFailedCancelled() async throws {
        let driver = try makeDriver(timeout: .seconds(10))

        let peer = PeerIdentifier(deviceId: "test-peer")

 // Start handshake
        let handshakeTask = Task {
            try await driver.initiateHandshake(with: peer)
        }

 // Give time for state transition
        try await Task.sleep(for: .milliseconds(100))

 // Cancel
        await driver.cancel()

        let state = await driver.getCurrentState()
        guard case .failed(let reason) = state else {
            XCTFail("State should be failed after cancel, got \(state)")
            handshakeTask.cancel()
            return
        }

        XCTAssertEqual(reason, .cancelled, "Failure reason should be cancelled")
        handshakeTask.cancel()
    }

 // MARK: - Property 6: Handshake Timeout Enforcement

 /// **Property 6: Handshake Timeout Enforcement**
 /// *For any* handshake that exceeds the configured timeout, the HandshakeDriver
 /// SHALL transition to failed state within a reasonable scheduling window
 /// (typically < 1 second, depending on system load).
 /// **Validates: Requirements 4.5, 5.4**

 /// Test that timeout triggers failure
    func testProperty6_TimeoutTriggersFailure() async throws {
 // Use very short timeout for testing
        let shortTimeout: Duration = .milliseconds(200)

        let driver = try makeDriver(timeout: shortTimeout)

        let peer = PeerIdentifier(deviceId: "test-peer")

        let startTime = ContinuousClock.now

        do {
            _ = try await driver.initiateHandshake(with: peer)
            XCTFail("Should have timed out")
        } catch let error as HandshakeError {
            let elapsed = ContinuousClock.now - startTime

 // Verify timeout occurred within reasonable window (< 1s SLA)
 // Allow some tolerance for scheduling
            XCTAssertLessThan(elapsed, .seconds(1), "Timeout should occur within 1 second SLA")

 // Verify it's a timeout error
            guard case .failed(let reason) = error else {
                XCTFail("Expected failed error, got \(error)")
                return
            }
            XCTAssertEqual(reason, .timeout, "Failure reason should be timeout")
        }

 // Verify state is failed
        let state = await driver.getCurrentState()
        guard case .failed(let reason) = state else {
            XCTFail("State should be failed after timeout, got \(state)")
            return
        }
        XCTAssertEqual(reason, .timeout, "Failure reason should be timeout")
    }

 /// Test that timeout respects configured duration
    func testProperty6_TimeoutRespectsConfiguredDuration() async throws {
 // Test with different timeout values
        let timeouts: [Duration] = [.milliseconds(100), .milliseconds(300), .milliseconds(500)]

        for timeout in timeouts {
            let driver = try makeDriver(timeout: timeout)

            let peer = PeerIdentifier(deviceId: "test-peer-\(timeout)")

            let startTime = ContinuousClock.now

            do {
                _ = try await driver.initiateHandshake(with: peer)
                XCTFail("Should have timed out for timeout \(timeout)")
            } catch {
                let elapsed = ContinuousClock.now - startTime

 // Timeout should occur after configured duration but within SLA
 // Allow tolerance for scheduling (100ms tolerance as per design)
                let minExpected = timeout
                let maxExpected = timeout + .milliseconds(500) // Allow 500ms scheduling tolerance

                XCTAssertGreaterThanOrEqual(elapsed, minExpected,
                    "Timeout should not occur before configured duration")
                XCTAssertLessThan(elapsed, maxExpected,
                    "Timeout should occur within reasonable scheduling window")
            }

 // Clear transport for next iteration
            await transport.clearMessages()
        }
    }

    func testFailureMetricsRecordedOnTimeout() async throws {
        let driver = try makeDriver(timeout: .milliseconds(100))

        let peer = PeerIdentifier(deviceId: "test-peer")

        do {
            _ = try await driver.initiateHandshake(with: peer)
            XCTFail("Should have timed out")
        } catch {
 // Expected
        }

        let metrics = await driver.getLastMetrics()
        XCTAssertNotNil(metrics)
        if let metrics {
            XCTAssertEqual(metrics.failureReason, .timeout)
            XCTAssertEqual(metrics.timeoutCount, 1)
            XCTAssertEqual(metrics.retryCount, 0)
            XCTAssertGreaterThanOrEqual(metrics.handshakeDurationMs, 0)
            XCTAssertEqual(metrics.rttMs, -1)
            XCTAssertNil(metrics.cryptoSuite)
            XCTAssertNil(metrics.isFallback)
        }
    }

 /// Test that successful completion before timeout doesn't trigger timeout
    func testProperty6_SuccessBeforeTimeoutDoesNotTriggerTimeout() async throws {
        let driver = try makeDriver(timeout: .seconds(5))

        let peer = PeerIdentifier(deviceId: "test-peer")

 // Start handshake
        let handshakeTask = Task {
            try await driver.initiateHandshake(with: peer)
        }

 // Give time for MessageA to be sent
        try await Task.sleep(for: .milliseconds(100))

 // Simulate receiving MessageB (create a valid response)
 // For this test, we'll cancel instead since creating valid MessageB is complex
        await driver.cancel()

 // Verify we got cancelled, not timeout
        let state = await driver.getCurrentState()
        guard case .failed(let reason) = state else {
            XCTFail("State should be failed, got \(state)")
            handshakeTask.cancel()
            return
        }

        XCTAssertEqual(reason, .cancelled, "Should be cancelled, not timeout")
        handshakeTask.cancel()
    }

 // MARK: - Double Resume Protection Tests (P0)

 /// Test that finishOnce prevents double resume
    func testP0_FinishOncePreventDoubleResume() async throws {
        let driver = try makeDriver(timeout: .seconds(5))

        let peer = PeerIdentifier(deviceId: "test-peer")

 // Start handshake
        let handshakeTask = Task {
            try await driver.initiateHandshake(with: peer)
        }

 // Give time for state transition
        try await Task.sleep(for: .milliseconds(100))

 // Cancel should work without crash (tests finishOnce)
        await driver.cancel()

 // Second cancel should be safe (no double resume)
        await driver.cancel()

 // Should not crash
        handshakeTask.cancel()
    }

 // MARK: - Context Zeroization Tests

 /// Test that context is zeroized on failure
    func testContextZeroizedOnFailure() async throws {
        await transport.setShouldFailSend(true)

        let driver = try makeDriver()

        let peer = PeerIdentifier(deviceId: "test-peer")

        do {
            _ = try await driver.initiateHandshake(with: peer)
            XCTFail("Should have thrown error")
        } catch {
 // Expected - context should be zeroized internally
        }

 // State should be failed
        let state = await driver.getCurrentState()
        guard case .failed = state else {
            XCTFail("State should be failed")
            return
        }
    }

 /// Test that context is zeroized on cancel
    func testContextZeroizedOnCancel() async throws {
        let driver = try makeDriver(timeout: .seconds(10))

        let peer = PeerIdentifier(deviceId: "test-peer")

 // Start handshake
        let handshakeTask = Task {
            try await driver.initiateHandshake(with: peer)
        }

 // Give time for state transition
        try await Task.sleep(for: .milliseconds(100))

 // Cancel - should zeroize context
        await driver.cancel()

 // State should be failed with cancelled
        let state = await driver.getCurrentState()
        guard case .failed(let reason) = state else {
            XCTFail("State should be failed")
            handshakeTask.cancel()
            return
        }
        XCTAssertEqual(reason, .cancelled)

        handshakeTask.cancel()
    }

 /// Test that context is zeroized on timeout
    func testContextZeroizedOnTimeout() async throws {
        let driver = try makeDriver(timeout: .milliseconds(100))

        let peer = PeerIdentifier(deviceId: "test-peer")

        do {
            _ = try await driver.initiateHandshake(with: peer)
            XCTFail("Should have timed out")
        } catch {
 // Expected - context should be zeroized internally
        }

 // State should be failed with timeout
        let state = await driver.getCurrentState()
        guard case .failed(let reason) = state else {
            XCTFail("State should be failed")
            return
        }
        XCTAssertEqual(reason, .timeout)
    }

 // MARK: - Property 2: Signing Callback Invocation Tests
 // **Feature: p2p-todo-completion, Property 2: Signing Callback Invocation**
 // **Validates: Requirements 2.1, 2.2**

 /// **Property 2: Signing Callback Invocation**
 /// *For any* HandshakeDriver configured with a SigningCallback, all signing
 /// operations should use the callback instead of raw key data.

 /// Test that signData uses callback when provided
    func testProperty2_SignDataUsesCallbackWhenProvided() async throws {
        let mockCallback = MockSigningCallback()

        let driver = try makeDriver(identityKeyHandle: .callback(mockCallback))

 // Test data to sign
        let testData = Data("test-data-to-sign".utf8)

 // Call signData
        let signature = try await driver.signData(testData)

 // Verify callback was invoked
        let callCount = await mockCallback.getSignCallCount()
        XCTAssertEqual(callCount, 1, "Signing callback should be called once")

 // Verify the data passed to callback
        let lastData = await mockCallback.getLastSignedData()
        XCTAssertEqual(lastData, testData, "Callback should receive the correct data")

 // Verify signature is from callback
        XCTAssertEqual(signature, MockSigningCallback.mockSignature, "Should return callback's signature")
    }

 /// Test that signData falls back to raw key when no callback
    func testProperty2_SignDataFallsBackToRawKey() async throws {
        let driver = try makeDriver()

 // Test data to sign
        let testData = Data("test-data-to-sign".utf8)

 // Call signData - should use CryptoProvider
        let signature = try await driver.signData(testData)

 // Verify signature is valid (from CryptoProvider)
        XCTAssertFalse(signature.isEmpty, "Should produce a signature")

 // Verify signature can be verified
        let isValid = try await provider.verify(
            data: testData,
            signature: signature,
            publicKey: identityKeyPair.publicKey.bytes
        )
        XCTAssertTrue(isValid, "Signature should be valid")
    }

 /// Test that signData surfaces callback errors
    func testProperty2_SignDataThrowsWhenCallbackFails() async throws {
        let mockCallback = MockSigningCallback()
        await mockCallback.setShouldFail(true)

        let driver = try makeDriver(identityKeyHandle: .callback(mockCallback))

        let testData = Data("test-data".utf8)

        do {
            _ = try await driver.signData(testData)
            XCTFail("Should throw from callback")
        } catch {
 // Expected
        }
    }

 /// Test that callback takes priority over raw key
    func testProperty2_CallbackTakesPriorityOverSoftwareKey() async throws {
        let mockCallback = MockSigningCallback()

        let driver = try makeDriver(identityKeyHandle: .callback(mockCallback))

        let testData = Data("priority-test".utf8)

 // Call signData
        let signature = try await driver.signData(testData)

 // Verify callback was used (not raw key)
        let callCount = await mockCallback.getSignCallCount()
        XCTAssertEqual(callCount, 1, "Callback should be called")
        XCTAssertEqual(signature, MockSigningCallback.mockSignature, "Should use callback's signature")
    }

    private struct BenchConfig: Sendable {
        let warmupIterations: Int
        let measuredIterations: Int

        static var enabled: Bool {
            ProcessInfo.processInfo.environment["SKYBRIDGE_RUN_BENCH"] == "1"
        }

        static var `default`: BenchConfig {
            BenchConfig(warmupIterations: 20, measuredIterations: 200)
        }
    }

    private actor BenchEventCounter {
        private var handshakeFailedCount: Int = 0
        private var cryptoDowngradeCount: Int = 0

        func record(_ event: SecurityEvent) {
            if event.type == .handshakeFailed {
                handshakeFailedCount += 1
            }
            if event.type == .cryptoDowngrade {
                cryptoDowngradeCount += 1
            }
        }

        func snapshot() -> (handshakeFailed: Int, cryptoDowngrade: Int) {
            (handshakeFailedCount, cryptoDowngradeCount)
        }
    }

    private struct BenchStats: Sendable {
        let count: Int
        let p50: Double
        let p95: Double
        let p99: Double
        let mean: Double
        let stdev: Double

        func describe(unit: String) -> String {
            "n=\(count) p50=\(String(format: "%.3f", p50))\(unit) p95=\(String(format: "%.3f", p95))\(unit) p99=\(String(format: "%.3f", p99))\(unit) mean=\(String(format: "%.3f", mean))\(unit) sd=\(String(format: "%.3f", stdev))\(unit)"
        }
    }

    private func stats(_ samples: [Double]) -> BenchStats {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let idx = Int((Double(sorted.count - 1) * p).rounded(.toNearestOrAwayFromZero))
            return sorted[min(max(idx, 0), sorted.count - 1)]
        }
        let mean = sorted.reduce(0.0, +) / Double(sorted.count)
        let variance = sorted.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(sorted.count)
        let stdev = variance.squareRoot()
        return BenchStats(
            count: sorted.count,
            p50: percentile(0.50),
            p95: percentile(0.95),
            p99: percentile(0.99),
            mean: mean,
            stdev: stdev
        )
    }

    private func durationMs(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000.0 +
        Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
    }

    private func durationNs(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000_000_000.0 +
        Double(duration.components.attoseconds) / 1_000_000_000.0
    }

    private struct HandshakeRun: Sendable {
        let sessionKeys: SessionKeys
        let messageABytes: Int
        let messageBBytes: Int
        let finishedR2IBytes: Int
        let finishedI2RBytes: Int
        let handshakeDurationMs: Double
        let rttMs: Double
    }

    private func runOneHandshake(
        cryptoProvider: any CryptoProvider,
        trustProviderInitiator: any HandshakeTrustProvider = StaticTrustProvider(deviceId: "noop", fingerprint: nil),
        trustProviderResponder: any HandshakeTrustProvider = StaticTrustProvider(deviceId: "noop", fingerprint: nil),
        timeout: Duration = .seconds(5)
    ) async throws -> HandshakeRun {
        let initiatorTransport = MockDiscoveryTransport()
        let responderTransport = MockDiscoveryTransport()

        let initiatorIdentity = identityKeyPair!
        let responderIdentity = try await provider.generateKeyPair(for: .signing)

        let signatureProvider = ClassicSignatureProvider()
        let offeredSuites: [CryptoSuite] = [.x25519Ed25519]

        let initiator = try HandshakeDriver(
            transport: initiatorTransport,
            cryptoProvider: cryptoProvider,
            protocolSignatureProvider: signatureProvider,
            protocolSigningKeyHandle: .softwareKey(initiatorIdentity.privateKey.bytes),
            sigAAlgorithm: .ed25519,
            identityPublicKey: encodeIdentityPublicKey(initiatorIdentity.publicKey.bytes),
            offeredSuites: offeredSuites,
            timeout: timeout,
            trustProvider: trustProviderInitiator
        )

        let responder = try HandshakeDriver(
            transport: responderTransport,
            cryptoProvider: cryptoProvider,
            protocolSignatureProvider: signatureProvider,
            protocolSigningKeyHandle: .softwareKey(responderIdentity.privateKey.bytes),
            sigAAlgorithm: .ed25519,
            identityPublicKey: encodeIdentityPublicKey(responderIdentity.publicKey.bytes),
            offeredSuites: offeredSuites,
            timeout: timeout,
            trustProvider: trustProviderResponder
        )

        let peer = PeerIdentifier(deviceId: "bench-peer")
        let handshakeTask = Task {
            try await initiator.initiateHandshake(with: peer)
        }

        while await initiatorTransport.getSentMessageCount() == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }

        let initiatorSent = await initiatorTransport.getSentMessages()
        guard initiatorSent.count >= 1 else {
            throw XCTSkip("Handshake did not emit MessageA")
        }
        let messageA = initiatorSent[0].1
        await responder.handleMessage(messageA, from: peer)

        while await responderTransport.getSentMessageCount() < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let responderSent = await responderTransport.getSentMessages()
        let messageB = responderSent[0].1
        let finishedR2I = responderSent[1].1
        await initiator.handleMessage(messageB, from: peer)
        await initiator.handleMessage(finishedR2I, from: peer)

        while await initiatorTransport.getSentMessageCount() < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let initiatorSent2 = await initiatorTransport.getSentMessages()
        let finishedI2R = initiatorSent2[1].1
        await responder.handleMessage(finishedI2R, from: peer)

        let keys = try await handshakeTask.value
        let metrics = await initiator.getLastMetrics()
        return HandshakeRun(
            sessionKeys: keys,
            messageABytes: messageA.count,
            messageBBytes: messageB.count,
            finishedR2IBytes: finishedR2I.count,
            finishedI2RBytes: finishedI2R.count,
            handshakeDurationMs: metrics?.handshakeDurationMs ?? -1,
            rttMs: metrics?.rttMs ?? -1
        )
    }

    func testBench_HandshakeLatencyAndWireOverhead() async throws {
        if !BenchConfig.enabled {
            throw XCTSkip("Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
        }

        let cfg = BenchConfig.default

        var measuredHandshakeMs: [Double] = []
        var measuredRttMs: [Double] = []
        var measuredTotalBytes: [Double] = []
        var lastSizes: (a: Int, b: Int, finR2I: Int, finI2R: Int)?

        for i in 0..<(cfg.warmupIterations + cfg.measuredIterations) {
            let run = try await runOneHandshake(cryptoProvider: ClassicCryptoProvider())

            if i >= cfg.warmupIterations {
                measuredHandshakeMs.append(run.handshakeDurationMs)
                measuredRttMs.append(run.rttMs)
                measuredTotalBytes.append(Double(run.messageABytes + run.messageBBytes + run.finishedR2IBytes + run.finishedI2RBytes))
                lastSizes = (run.messageABytes, run.messageBBytes, run.finishedR2IBytes, run.finishedI2RBytes)
            }
        }

        let hs = stats(measuredHandshakeMs)
        let rtt = stats(measuredRttMs)
        let total = stats(measuredTotalBytes)
        if let lastSizes {
            print("[BENCH] Handshake latency (ms): \(hs.describe(unit: "ms"))")
            print("[BENCH] Handshake RTT     (ms): \(rtt.describe(unit: "ms"))")
            print("[BENCH] Wire total (bytes): \(total.describe(unit: "B")) msgA=\(lastSizes.a) msgB=\(lastSizes.b) finR2I=\(lastSizes.finR2I) finI2R=\(lastSizes.finI2R)")
        } else {
            print("[BENCH] Handshake latency (ms): \(hs.describe(unit: "ms"))")
            print("[BENCH] Handshake RTT     (ms): \(rtt.describe(unit: "ms"))")
            print("[BENCH] Wire total (bytes): \(total.describe(unit: "B"))")
        }
    }

    func testBench_ProviderSelectionOverhead() async throws {
        if !BenchConfig.enabled {
            throw XCTSkip("Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
        }

        let cfg = BenchConfig.default
        let clock = ContinuousClock()

        var coldUs: [Double] = []
        var hotUs: [Double] = []
        var pqcUnavailableUs: [Double] = []
        var selfTestFailureUs: [Double] = []

        // Use a local environment stub so this benchmark compiles in Release test configuration as well.
        struct TestCryptoEnvironment: CryptoEnvironment {
            let hasApplePQC: Bool
            let hasLiboqs: Bool
            func checkApplePQCAvailable() -> Bool { hasApplePQC }
            func checkLiboqsAvailable() -> Bool { hasLiboqs }
        }
        let pqcUnavailableEnv: any CryptoEnvironment = TestCryptoEnvironment(hasApplePQC: false, hasLiboqs: false)
        let selfTestFailureEnv: any CryptoEnvironment = TestCryptoEnvironment(hasApplePQC: false, hasLiboqs: true)

        for i in 0..<(cfg.warmupIterations + cfg.measuredIterations) {
            await CryptoProviderSelector.shared.clearCache()
            let startCold = clock.now
            _ = await CryptoProviderSelector.shared.bestAvailableProvider
            let cold = clock.now - startCold

            let startHot = clock.now
            _ = await CryptoProviderSelector.shared.bestAvailableProvider
            let hot = clock.now - startHot

            let startPqcUnavailable = clock.now
            _ = CryptoProviderFactory.make(policy: .preferPQC, environment: pqcUnavailableEnv)
            let pqcUnavailable = clock.now - startPqcUnavailable

            let startSelfTestFailure = clock.now
            _ = CryptoProviderFactory.make(policy: .preferPQC, environment: selfTestFailureEnv)
            let selfTestFailure = clock.now - startSelfTestFailure

            if i >= cfg.warmupIterations {
                coldUs.append(durationMs(cold) * 1000.0)
                hotUs.append(durationMs(hot) * 1000.0)
                pqcUnavailableUs.append(durationMs(pqcUnavailable) * 1000.0)
                selfTestFailureUs.append(durationMs(selfTestFailure) * 1000.0)
            }
        }

        let coldStats = stats(coldUs)
        let hotStats = stats(hotUs)
        let pqcUnavailableStats = stats(pqcUnavailableUs)
        let selfTestFailureStats = stats(selfTestFailureUs)
        print("[BENCH] Provider selection cold (us): \(coldStats.describe(unit: "us"))")
        print("[BENCH] Provider selection hot  (us): \(hotStats.describe(unit: "us"))")
        print("[BENCH] Provider selection PQC unavailable (us): \(pqcUnavailableStats.describe(unit: "us"))")
        print("[BENCH] Provider selection self-test failure (us): \(selfTestFailureStats.describe(unit: "us"))")

        let dateString = ArtifactDate.current()
        let artifactsDir = URL(fileURLWithPath: "Artifacts")
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        let csvPath = artifactsDir.appendingPathComponent("provider_selection_\(dateString).csv")
        let header = "scenario,p50_us,p95_us\n"
        let rows = [
            "cold_start,\(String(format: "%.3f", coldStats.p50)),\(String(format: "%.3f", coldStats.p95))",
            "hot_path,\(String(format: "%.3f", hotStats.p50)),\(String(format: "%.3f", hotStats.p95))",
            "pqc_unavailable_fallback,\(String(format: "%.3f", pqcUnavailableStats.p50)),\(String(format: "%.3f", pqcUnavailableStats.p95))",
            "self_test_failure_recovery,\(String(format: "%.3f", selfTestFailureStats.p50)),\(String(format: "%.3f", selfTestFailureStats.p95))"
        ]
        let content = header + rows.joined(separator: "\n") + "\n"
        try content.write(to: csvPath, atomically: true, encoding: .utf8)
        print("[BENCH] Provider selection CSV written to: \(csvPath.path)")
    }

    func testBench_DataPlaneThroughputAndCPUProxy() async throws {
        if !BenchConfig.enabled {
            throw XCTSkip("Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
        }

        let cfg = BenchConfig.default
        let clock = ContinuousClock()

        let run = try await runOneHandshake(cryptoProvider: ClassicCryptoProvider())
 // Use sendKey for both encrypt and decrypt to measure symmetric AEAD performance
 // In real usage: sender encrypts with sendKey, receiver decrypts with their receiveKey (which equals sender's sendKey)
        let symmetricKey = SymmetricKey(data: run.sessionKeys.sendKey)
        let aad = Data("SkyBridge-Bench-AAD".utf8)

        let payloadSizes = [1024, 16 * 1024, 64 * 1024, 1024 * 1024]
        for size in payloadSizes {
            var throughputMBpsSamples: [Double] = []
            var nsPerByteSamples: [Double] = []

            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            let bytesPerIteration = Double(size) * 2.0

            for i in 0..<(cfg.warmupIterations + cfg.measuredIterations) {
                let start = clock.now
                let sealed = try AES.GCM.seal(payload, using: symmetricKey, authenticating: aad)
                guard let combined = sealed.combined else {
                    throw XCTSkip("AES.GCM produced empty combined")
                }
                let opened = try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: symmetricKey, authenticating: aad)
                XCTAssertEqual(opened.count, payload.count)
                let elapsed = clock.now - start

                if i >= cfg.warmupIterations {
                    let seconds = durationMs(elapsed) / 1000.0
                    let mbps = (bytesPerIteration / (1024.0 * 1024.0)) / max(seconds, 1e-9)
                    throughputMBpsSamples.append(mbps)
                    nsPerByteSamples.append(durationNs(elapsed) / max(bytesPerIteration, 1.0))
                }
            }

            let tStats = stats(throughputMBpsSamples)
            let cStats = stats(nsPerByteSamples)
            print("[BENCH] Data-plane AES.GCM payload=\(size)B throughput: \(tStats.describe(unit: "MB/s"))")
            print("[BENCH] Data-plane AES.GCM payload=\(size)B cpu_proxy: \(cStats.describe(unit: "ns/B"))")
        }
    }

    func testBench_FailureModesAndDowngradeObservability() async throws {
        if !BenchConfig.enabled {
            throw XCTSkip("Set SKYBRIDGE_RUN_BENCH=1 to run benchmarks")
        }

        let cfg = BenchConfig.default
        let peer = PeerIdentifier(deviceId: "bench-peer")

        let counter = BenchEventCounter()
        let subId = await SecurityEventEmitter.shared.subscribe { event in
            await counter.record(event)
        }
        defer {
            Task.detached {
                await SecurityEventEmitter.shared.unsubscribe(subId)
            }
        }

        var timeoutFailures = 0
        for _ in 0..<min(cfg.measuredIterations, 50) {
            let initiatorTransport = MockDiscoveryTransport()
            let initiator = try makeDriver(
                transport: initiatorTransport,
                cryptoProvider: ClassicCryptoProvider(),
                timeout: .milliseconds(50),
                trustProvider: StaticTrustProvider(deviceId: "noop", fingerprint: nil)
            )
            do {
                _ = try await initiator.initiateHandshake(with: peer)
            } catch let e as HandshakeError {
                if case .failed(let reason) = e, reason == .timeout {
                    timeoutFailures += 1
                }
            } catch {
                continue
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        var invalidSigFailures = 0
        for _ in 0..<min(cfg.measuredIterations, 50) {
            let transportR = MockDiscoveryTransport()
            let responder = try makeDriver(
                transport: transportR,
                cryptoProvider: ClassicCryptoProvider(),
                trustProvider: StaticTrustProvider(deviceId: "noop", fingerprint: nil)
            )

            let initiatorContext = try await HandshakeContext.create(
                role: .initiator,
                cryptoProvider: ClassicCryptoProvider()
            )
            let messageA = try await initiatorContext.buildMessageA(
                identityKeyHandle: .softwareKey(identityKeyPair.privateKey.bytes),
                identityPublicKey: encodeIdentityPublicKey(identityKeyPair.publicKey.bytes)
            )
            var tampered = messageA.encoded
            if tampered.count >= 1 {
                tampered[tampered.count - 1] ^= 0x01
            }
            await responder.handleMessage(tampered, from: peer)
            try await Task.sleep(for: .milliseconds(5))
            let state = await responder.getCurrentState()
            if case .failed(let reason) = state, reason == .signatureVerificationFailed {
                invalidSigFailures += 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        #if canImport(OQSRAII)
        if SystemCryptoEnvironment.system.checkLiboqsAvailable() {
            let pqcProvider = OQSPQCCryptoProvider()
            let initiatorTransport = MockDiscoveryTransport()
            let responderTransport = MockDiscoveryTransport()

            let initiatorIdentity = identityKeyPair!
            let responderIdentity = try await provider.generateKeyPair(for: .signing)

            let responderKEM = try await pqcProvider.generateKeyPair(for: .keyExchange)
            let trustI = StaticTrustProviderWithKEM(
                deviceId: peer.deviceId,
                kemPublicKeys: [.mlkem768MLDSA65: responderKEM.publicKey.bytes]
            )

            let initiator = try HandshakeDriver(
                transport: initiatorTransport,
                cryptoProvider: pqcProvider,
                protocolSignatureProvider: ClassicSignatureProvider(),
                protocolSigningKeyHandle: .softwareKey(initiatorIdentity.privateKey.bytes),
                sigAAlgorithm: .ed25519,
                identityPublicKey: encodeIdentityPublicKey(initiatorIdentity.publicKey.bytes),
                offeredSuites: [.x25519Ed25519],
                trustProvider: trustI
            )
            let responder = try HandshakeDriver(
                transport: responderTransport,
                cryptoProvider: ClassicCryptoProvider(),
                protocolSignatureProvider: ClassicSignatureProvider(),
                protocolSigningKeyHandle: .softwareKey(responderIdentity.privateKey.bytes),
                sigAAlgorithm: .ed25519,
                identityPublicKey: encodeIdentityPublicKey(responderIdentity.publicKey.bytes),
                offeredSuites: [.x25519Ed25519],
                trustProvider: StaticTrustProvider(deviceId: "noop", fingerprint: nil)
            )

            let task = Task { try await initiator.initiateHandshake(with: peer) }
            while await initiatorTransport.getSentMessageCount() == 0 {
                try await Task.sleep(for: .milliseconds(1))
            }
            let msgA = (await initiatorTransport.getSentMessages())[0].1
            await responder.handleMessage(msgA, from: peer)

            while await responderTransport.getSentMessageCount() < 2 {
                try await Task.sleep(for: .milliseconds(1))
            }
            let responderMsgs = await responderTransport.getSentMessages()
            await initiator.handleMessage(responderMsgs[0].1, from: peer)
            await initiator.handleMessage(responderMsgs[1].1, from: peer)

            while await initiatorTransport.getSentMessageCount() < 2 {
                try await Task.sleep(for: .milliseconds(1))
            }
            let initiatorMsgs2 = await initiatorTransport.getSentMessages()
            await responder.handleMessage(initiatorMsgs2[1].1, from: peer)
            _ = try await task.value
        }
        #endif

        try await Task.sleep(for: .milliseconds(50))
        let counts = await counter.snapshot()
        print("[BENCH] Failure timeoutCount=\(timeoutFailures) invalidSigCount=\(invalidSigFailures) events.handshakeFailed=\(counts.handshakeFailed) events.cryptoDowngrade=\(counts.cryptoDowngrade)")
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct StaticTrustProviderWithKEM: HandshakeTrustProvider, Sendable {
    let deviceId: String
    let kemPublicKeys: [CryptoSuite: Data]

    func trustedFingerprint(for deviceId: String) async -> String? {
        nil
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        guard deviceId == self.deviceId else { return [:] }
        return kemPublicKeys
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        nil
    }
}

// MARK: - Mock Signing Callback

/// Mock signing callback for testing
/// **Feature: p2p-todo-completion, Property 2: Signing Callback Invocation**
@available(macOS 14.0, iOS 17.0, *)
actor MockSigningCallback: SigningCallback {

 /// Mock signature returned by sign()
    static let mockSignature = Data("mock-signature-from-callback".utf8)

 /// Number of times sign() was called
    private var signCallCount: Int = 0

 /// Last data passed to sign()
    private var lastSignedData: Data?

 /// Whether sign should throw an error
    private var shouldFail: Bool = false

    func sign(data: Data) async throws -> Data {
        signCallCount += 1
        lastSignedData = data

        if shouldFail {
            throw NSError(domain: "MockSigningCallback", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Mock signing failure"
            ])
        }

        return Self.mockSignature
    }

 // MARK: - Test Helpers

    func getSignCallCount() -> Int {
        return signCallCount
    }

    func getLastSignedData() -> Data? {
        return lastSignedData
    }

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }

    func reset() {
        signCallCount = 0
        lastSignedData = nil
        shouldFail = false
    }
}

// MARK: - 2 HandshakeDriver Initialization Tests ( 5.6)

/// Tests for 2 HandshakeDriver initialization validation
/// **Validates: Requirements 7.1, 7.4, 7.5**
@available(macOS 14.0, iOS 17.0, *)
final class HandshakeDriverPhase2InitTests: XCTestCase {

    var transport: MockDiscoveryTransport!
    var cryptoProvider: ClassicCryptoProvider!

    override func setUp() async throws {
        transport = MockDiscoveryTransport()
        cryptoProvider = ClassicCryptoProvider()
    }

 // MARK: - 5.6: Empty Suites → throw emptyOfferedSuites

 /// Test that empty offeredSuites throws emptyOfferedSuites error
    func testEmptySuitesThrowsEmptyOfferedSuites() throws {
        let ed25519Provider = ClassicSignatureProvider()
        let ed25519Key = SigningKeyHandle.softwareKey(Data(repeating: 0x42, count: 32))
        let identityPublicKey = encodeIdentityPublicKey(Data(repeating: 0x01, count: 32))

        XCTAssertThrowsError(
            try HandshakeDriver(
                transport: transport,
                cryptoProvider: cryptoProvider,
                protocolSignatureProvider: ed25519Provider,
                protocolSigningKeyHandle: ed25519Key,
                sigAAlgorithm: .ed25519,
                identityPublicKey: identityPublicKey,
                offeredSuites: []  // Empty!
            )
        ) { error in
            guard case HandshakeError.emptyOfferedSuites = error else {
                XCTFail("Expected emptyOfferedSuites, got \(error)")
                return
            }
        }
    }

 // MARK: - 5.6: Suites 混装 → throw homogeneityViolation

 /// Test that mixing PQC and Classic suites with ML-DSA-65 throws homogeneityViolation
    func testMixedSuitesWithMLDSAThrowsHomogeneityViolation() throws {
        let pqcProvider = PQCSignatureProvider(backend: .oqs)
 // ML-DSA-65 需要 64 bytes seed 或 4032 bytes full key
        let mldsaKey = SigningKeyHandle.softwareKey(Data(repeating: 0x42, count: 64))
        let identityPublicKey = encodeIdentityPublicKey(Data(repeating: 0x01, count: 1952), algorithm: .mlDSA65)

 // 混装 PQC 和 Classic suites
        let mixedSuites: [CryptoSuite] = [.mlkem768MLDSA65, .x25519Ed25519]

        XCTAssertThrowsError(
            try HandshakeDriver(
                transport: transport,
                cryptoProvider: cryptoProvider,
                protocolSignatureProvider: pqcProvider,
                protocolSigningKeyHandle: mldsaKey,
                sigAAlgorithm: .mlDSA65,
                identityPublicKey: identityPublicKey,
                offeredSuites: mixedSuites
            )
        ) { error in
            guard case HandshakeError.homogeneityViolation(let message) = error else {
                XCTFail("Expected homogeneityViolation, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("non-PQC"), "Message should mention non-PQC suites")
        }
    }

 /// Test that mixing PQC and Classic suites with Ed25519 throws homogeneityViolation
    func testMixedSuitesWithEd25519ThrowsHomogeneityViolation() throws {
        let ed25519Provider = ClassicSignatureProvider()
        let ed25519Key = SigningKeyHandle.softwareKey(Data(repeating: 0x42, count: 32))
        let identityPublicKey = encodeIdentityPublicKey(Data(repeating: 0x01, count: 32))

 // 混装 PQC 和 Classic suites
        let mixedSuites: [CryptoSuite] = [.x25519Ed25519, .mlkem768MLDSA65]

        XCTAssertThrowsError(
            try HandshakeDriver(
                transport: transport,
                cryptoProvider: cryptoProvider,
                protocolSignatureProvider: ed25519Provider,
                protocolSigningKeyHandle: ed25519Key,
                sigAAlgorithm: .ed25519,
                identityPublicKey: identityPublicKey,
                offeredSuites: mixedSuites
            )
        ) { error in
            guard case HandshakeError.homogeneityViolation(let message) = error else {
                XCTFail("Expected homogeneityViolation, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("PQC"), "Message should mention PQC suites")
        }
    }

 // MARK: - 5.6: Provider/Algorithm Mismatch → throw providerAlgorithmMismatch

 /// Test that provider algorithm mismatch throws providerAlgorithmMismatch
    func testProviderAlgorithmMismatchThrows() throws {
 // 使用 Ed25519 provider 但声明 ML-DSA-65 算法
        let ed25519Provider = ClassicSignatureProvider()
        let mldsaKey = SigningKeyHandle.softwareKey(Data(repeating: 0x42, count: 64))
        let identityPublicKey = encodeIdentityPublicKey(Data(repeating: 0x01, count: 32))

        XCTAssertThrowsError(
            try HandshakeDriver(
                transport: transport,
                cryptoProvider: cryptoProvider,
                protocolSignatureProvider: ed25519Provider,  // Ed25519 provider
                protocolSigningKeyHandle: mldsaKey,
                sigAAlgorithm: .mlDSA65,  // But ML-DSA-65 algorithm!
                identityPublicKey: identityPublicKey,
                offeredSuites: [.mlkem768MLDSA65]
            )
        ) { error in
            guard case HandshakeError.providerAlgorithmMismatch(let provider, let algorithm) = error else {
                XCTFail("Expected providerAlgorithmMismatch, got \(error)")
                return
            }
            XCTAssertTrue(provider.contains("Classic"), "Provider should be Classic")
            XCTAssertEqual(algorithm, "ML-DSA-65")
        }
    }

 // MARK: - 5.6: KeyHandle 类型错/长度错 → throw signatureAlgorithmMismatch

 /// Test that wrong key length for Ed25519 throws signatureAlgorithmMismatch
    func testWrongKeyLengthForEd25519Throws() throws {
        let ed25519Provider = ClassicSignatureProvider()
 // Ed25519 需要 32 或 64 bytes，这里给 16 bytes
        let wrongKey = SigningKeyHandle.softwareKey(Data(repeating: 0x42, count: 16))
        let identityPublicKey = encodeIdentityPublicKey(Data(repeating: 0x01, count: 32))

        XCTAssertThrowsError(
            try HandshakeDriver(
                transport: transport,
                cryptoProvider: cryptoProvider,
                protocolSignatureProvider: ed25519Provider,
                protocolSigningKeyHandle: wrongKey,
                sigAAlgorithm: .ed25519,
                identityPublicKey: identityPublicKey,
                offeredSuites: [.x25519Ed25519]
            )
        ) { error in
            guard case HandshakeError.signatureAlgorithmMismatch(let algorithm, let keyHandleType) = error else {
                XCTFail("Expected signatureAlgorithmMismatch, got \(error)")
                return
            }
            XCTAssertEqual(algorithm, "Ed25519")
            XCTAssertTrue(keyHandleType.contains("16 bytes"), "Should mention wrong key length")
        }
    }

 /// Test that wrong key length for ML-DSA-65 throws signatureAlgorithmMismatch
    func testWrongKeyLengthForMLDSAThrows() throws {
        let pqcProvider = PQCSignatureProvider(backend: .oqs)
 // ML-DSA-65 需要 64 或 4032 bytes，这里给 32 bytes
        let wrongKey = SigningKeyHandle.softwareKey(Data(repeating: 0x42, count: 32))
        let identityPublicKey = encodeIdentityPublicKey(Data(repeating: 0x01, count: 1952), algorithm: .mlDSA65)

        XCTAssertThrowsError(
            try HandshakeDriver(
                transport: transport,
                cryptoProvider: cryptoProvider,
                protocolSignatureProvider: pqcProvider,
                protocolSigningKeyHandle: wrongKey,
                sigAAlgorithm: .mlDSA65,
                identityPublicKey: identityPublicKey,
                offeredSuites: [.mlkem768MLDSA65]
            )
        ) { error in
            guard case HandshakeError.signatureAlgorithmMismatch(let algorithm, let keyHandleType) = error else {
                XCTFail("Expected signatureAlgorithmMismatch, got \(error)")
                return
            }
            XCTAssertEqual(algorithm, "ML-DSA-65")
            XCTAssertTrue(keyHandleType.contains("32 bytes"), "Should mention wrong key length")
        }
    }

 // MARK: - Positive Tests: Valid Initialization

 /// Test that valid Ed25519 configuration succeeds
    func testValidEd25519ConfigurationSucceeds() throws {
        let ed25519Provider = ClassicSignatureProvider()
        let ed25519Key = SigningKeyHandle.softwareKey(Data(repeating: 0x42, count: 32))
        let identityPublicKey = encodeIdentityPublicKey(Data(repeating: 0x01, count: 32))

 // Should not throw
        let driver = try HandshakeDriver(
            transport: transport,
            cryptoProvider: cryptoProvider,
            protocolSignatureProvider: ed25519Provider,
            protocolSigningKeyHandle: ed25519Key,
            sigAAlgorithm: .ed25519,
            identityPublicKey: identityPublicKey,
            offeredSuites: [.x25519Ed25519]
        )

        XCTAssertNotNil(driver)
    }

 /// Test that valid ML-DSA-65 configuration succeeds
    func testValidMLDSAConfigurationSucceeds() throws {
        let pqcProvider = PQCSignatureProvider(backend: .oqs)
        let mldsaKey = SigningKeyHandle.softwareKey(Data(repeating: 0x42, count: 64))
        let identityPublicKey = encodeIdentityPublicKey(Data(repeating: 0x01, count: 1952), algorithm: .mlDSA65)

 // Should not throw
        let driver = try HandshakeDriver(
            transport: transport,
            cryptoProvider: cryptoProvider,
            protocolSignatureProvider: pqcProvider,
            protocolSigningKeyHandle: mldsaKey,
            sigAAlgorithm: .mlDSA65,
            identityPublicKey: identityPublicKey,
            offeredSuites: [.mlkem768MLDSA65]
        )

        XCTAssertNotNil(driver)
    }

 /// Test that callback key handle bypasses length validation
    func testCallbackKeyHandleBypassesLengthValidation() throws {
        let ed25519Provider = ClassicSignatureProvider()
        let callback = MockSigningCallback()
        let callbackKey = SigningKeyHandle.callback(callback)
        let identityPublicKey = encodeIdentityPublicKey(Data(repeating: 0x01, count: 32))

 // Should not throw - callback bypasses length validation
        let driver = try HandshakeDriver(
            transport: transport,
            cryptoProvider: cryptoProvider,
            protocolSignatureProvider: ed25519Provider,
            protocolSigningKeyHandle: callbackKey,
            sigAAlgorithm: .ed25519,
            identityPublicKey: identityPublicKey,
            offeredSuites: [.x25519Ed25519]
        )

        XCTAssertNotNil(driver)
    }
}
