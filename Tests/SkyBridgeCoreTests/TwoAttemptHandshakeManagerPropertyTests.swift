//
// TwoAttemptHandshakeManagerPropertyTests.swift
// SkyBridgeCoreTests
//
// 11.2: Property test for Two-Attempt Strategy
// **Property 2.1: Two-Attempt Strategy for Interoperability**
// **Validates: Requirements 1.4, 5.1**
//

import XCTest
@testable import SkyBridgeCore

/// Thread-safe counter for tracking attempts in concurrent closures
private actor AttemptTracker {
    var attemptCount = 0
    var strategies: [HandshakeAttemptStrategy] = []
    var algorithms: [SignatureAlgorithm] = []
    
    func recordAttempt(strategy: HandshakeAttemptStrategy, algorithm: SignatureAlgorithm) -> Int {
        attemptCount += 1
        strategies.append(strategy)
        algorithms.append(algorithm)
        return attemptCount
    }
    
    func getCount() -> Int { attemptCount }
    func getStrategies() -> [HandshakeAttemptStrategy] { strategies }
    func getAlgorithms() -> [SignatureAlgorithm] { algorithms }
}

/// Property tests for TwoAttemptHandshakeManager
///
/// **Property 2.1: Two-Attempt Strategy for Interoperability**
/// *For any* handshake with `preferPQC = true`:
/// - First attempt SHALL use PQC-only `offeredSuites` (sigA = ML-DSA-65)
/// - If first attempt fails with PQC unavailability error, second attempt SHALL use Classic-only `offeredSuites` (sigA = Ed25519)
/// - Each fallback SHALL emit a `cryptoDowngrade` event
///
/// **硬断言**: 当 first attempt 失败原因是 `.timeout` 时，不得自动 fallback
@available(macOS 14.0, iOS 17.0, *)
final class TwoAttemptHandshakeManagerPropertyTests: XCTestCase {
    
 // MARK: - Policy normalization
    
    func testRequirePQCForcesNoClassicFallback() {
        let policy = HandshakePolicy(requirePQC: true, allowClassicFallback: true, minimumTier: .classic)
        XCTAssertTrue(policy.requirePQC)
        XCTAssertFalse(policy.allowClassicFallback, "requirePQC=true must force allowClassicFallback=false")
    }
    
 // MARK: - Property 2.1.1: Timeout does NOT trigger fallback
    
    func testTimeoutDoesNotTriggerFallback() async throws {
        let tracker = AttemptTracker()
        
        do {
            _ = try await TwoAttemptHandshakeManager.performHandshake(
                deviceId: "test-device",
                preferPQC: true
            ) { strategy, sigAAlgorithm in
                _ = await tracker.recordAttempt(strategy: strategy, algorithm: sigAAlgorithm)
 // First attempt fails with timeout
                throw HandshakeError.failed(.timeout)
            }
            XCTFail("Should have thrown timeout error")
        } catch let error as HandshakeError {
 // Verify only one attempt was made (no fallback)
            let count = await tracker.getCount()
            XCTAssertEqual(count, 1, "Timeout should NOT trigger fallback - only 1 attempt expected")
            
 // Verify the error is timeout
            if case .failed(let reason) = error {
                XCTAssertEqual(reason, .timeout, "Error should be timeout")
            } else {
                XCTFail("Expected .failed(.timeout)")
            }
        }
    }
    
 // MARK: - Property 2.1.2: PQC unavailable DOES trigger fallback
    
    func testPQCUnavailableTriggersFallback() async throws {
        let tracker = AttemptTracker()
        
        _ = try await TwoAttemptHandshakeManager.performHandshake(
            deviceId: "test-device",
            preferPQC: true
        ) { strategy, sigAAlgorithm in
            let count = await tracker.recordAttempt(strategy: strategy, algorithm: sigAAlgorithm)
            
            if count == 1 {
 // First attempt fails with PQC unavailable
                throw HandshakeError.failed(.pqcProviderUnavailable)
            }
            
 // Second attempt succeeds
            return Self.createMockSessionKeys()
        }
        
 // Verify two attempts were made
        let count = await tracker.getCount()
        let strategies = await tracker.getStrategies()
        let algorithms = await tracker.getAlgorithms()
        
        XCTAssertEqual(count, 2, "PQC unavailable should trigger fallback - 2 attempts expected")
        
 // Verify first attempt was PQC-only with ML-DSA-65
        XCTAssertEqual(strategies[0], .pqcOnly, "First attempt should be PQC-only")
        XCTAssertEqual(algorithms[0], .mlDSA65, "First attempt should use ML-DSA-65")
        
 // Verify second attempt was Classic-only with Ed25519
        XCTAssertEqual(strategies[1], .classicOnly, "Second attempt should be Classic-only")
        XCTAssertEqual(algorithms[1], .ed25519, "Second attempt should use Ed25519")
    }
    
 // MARK: - Property 2.1.3: Suite not supported DOES trigger fallback
    
    func testSuiteNotSupportedTriggersFallback() async throws {
        let tracker = AttemptTracker()
        
        _ = try await TwoAttemptHandshakeManager.performHandshake(
            deviceId: "test-device",
            preferPQC: true
        ) { strategy, sigAAlgorithm in
            let count = await tracker.recordAttempt(strategy: strategy, algorithm: sigAAlgorithm)
            
            if count == 1 {
                throw HandshakeError.failed(.suiteNotSupported)
            }
            
            return Self.createMockSessionKeys()
        }
        
        let count = await tracker.getCount()
        XCTAssertEqual(count, 2, "Suite not supported should trigger fallback")
    }
    
 // MARK: - Property 2.1.4: preferPQC=false skips PQC attempt
    
    func testPreferPQCFalseSkipsPQCAttempt() async throws {
        let tracker = AttemptTracker()
        
        _ = try await TwoAttemptHandshakeManager.performHandshake(
            deviceId: "test-device",
            preferPQC: false
        ) { strategy, sigAAlgorithm in
            _ = await tracker.recordAttempt(strategy: strategy, algorithm: sigAAlgorithm)
            return Self.createMockSessionKeys()
        }
        
 // Verify only one attempt was made
        let count = await tracker.getCount()
        let strategies = await tracker.getStrategies()
        let algorithms = await tracker.getAlgorithms()
        
        XCTAssertEqual(count, 1, "preferPQC=false should make only 1 attempt")
        
 // Verify it was Classic-only with Ed25519
        XCTAssertEqual(strategies[0], .classicOnly, "Should be Classic-only")
        XCTAssertEqual(algorithms[0], .ed25519, "Should use Ed25519")
    }

 // MARK: - Policy: strictPQC must block fallback
    
    func testStrictPQCBlocksClassicFallbackOnPQCFailure() async throws {
        let tracker = AttemptTracker()
        let deviceId = "test-device-strict-\(UUID().uuidString)"
        let noFallbackEvent = expectation(description: "No fallback event should be emitted")
        noFallbackEvent.isInverted = true
        
        let subscriptionId = await SecurityEventEmitter.shared.subscribe { event in
            // Filter strictly to this test's deviceId to avoid cross-test event interference
            // from detached emissions in other suites.
            if event.type == .cryptoDowngrade, event.context["deviceId"] == deviceId {
                noFallbackEvent.fulfill()
            }
        }
        
        defer {
            Task { await SecurityEventEmitter.shared.unsubscribe(subscriptionId) }
        }
        
        do {
            _ = try await TwoAttemptHandshakeManager.performHandshake(
                deviceId: deviceId,
                preferPQC: true,
                policy: .strictPQC
            ) { strategy, sigAAlgorithm in
                _ = await tracker.recordAttempt(strategy: strategy, algorithm: sigAAlgorithm)
                throw HandshakeError.failed(.suiteNotSupported)
            }
            XCTFail("Should have thrown with strictPQC policy")
        } catch {
            let count = await tracker.getCount()
            XCTAssertEqual(count, 1, "strictPQC must not allow classic fallback")
        }
        
        await fulfillment(of: [noFallbackEvent], timeout: 0.2)
    }
    
 // MARK: - Policy: default should fallback and emit event
    
    func testDefaultPolicyAllowsFallbackAndEmitsEvent() async throws {
        let tracker = AttemptTracker()
        let deviceId = "test-device-default-\(UUID().uuidString)"
        let fallbackEvent = expectation(description: "Fallback event should be emitted")
        
        let subscriptionId = await SecurityEventEmitter.shared.subscribe { event in
            // Filter strictly to this test's deviceId to avoid cross-test event interference.
            if event.type == .cryptoDowngrade, event.context["deviceId"] == deviceId {
                fallbackEvent.fulfill()
            }
        }
        
        defer {
            Task { await SecurityEventEmitter.shared.unsubscribe(subscriptionId) }
        }
        
        _ = try await TwoAttemptHandshakeManager.performHandshake(
            deviceId: deviceId,
            preferPQC: true,
            policy: .default
        ) { strategy, sigAAlgorithm in
            let count = await tracker.recordAttempt(strategy: strategy, algorithm: sigAAlgorithm)
            if count == 1 {
                throw HandshakeError.failed(.suiteNotSupported)
            }
            return Self.createMockSessionKeys()
        }
        
        let count = await tracker.getCount()
        XCTAssertEqual(count, 2, "default policy should allow classic fallback")
        
        await fulfillment(of: [fallbackEvent], timeout: 0.5)
    }
    
 // MARK: - Property 2.1.5: isPQCUnavailableError classification
    
    func testIsPQCUnavailableErrorClassification() {
 // Errors that SHOULD trigger fallback
        XCTAssertTrue(TwoAttemptHandshakeManager.isPQCUnavailableError(.pqcProviderUnavailable))
        XCTAssertTrue(TwoAttemptHandshakeManager.isPQCUnavailableError(.suiteNotSupported))
        XCTAssertTrue(TwoAttemptHandshakeManager.isPQCUnavailableError(.suiteNegotiationFailed))
        
 // Errors that should NOT trigger fallback
        XCTAssertFalse(TwoAttemptHandshakeManager.isPQCUnavailableError(.timeout))
        XCTAssertFalse(TwoAttemptHandshakeManager.isPQCUnavailableError(.cancelled))
        XCTAssertFalse(TwoAttemptHandshakeManager.isPQCUnavailableError(.signatureVerificationFailed))
        XCTAssertFalse(TwoAttemptHandshakeManager.isPQCUnavailableError(.keyConfirmationFailed))
        XCTAssertFalse(TwoAttemptHandshakeManager.isPQCUnavailableError(.replayDetected))
    }
    
 // MARK: - Property 2.1.6: getSuites returns correct suites
    
    func testGetSuitesReturnsCorrectSuites() {
        let provider = ClassicCryptoProvider()
        let pqcSuites = extractSuites(
            TwoAttemptHandshakeManager.getSuites(for: .pqcOnly, cryptoProvider: provider)
        )
        let classicSuites = extractSuites(
            TwoAttemptHandshakeManager.getSuites(for: .classicOnly, cryptoProvider: provider)
        )
        
 // PQC suites should all be PQC or Hybrid
        for suite in pqcSuites {
            XCTAssertTrue(suite.isPQC || suite.isHybrid, "\(suite.rawValue) should be PQC or Hybrid")
        }
        
 // Classic suites should all be Classic
        for suite in classicSuites {
            XCTAssertFalse(suite.isPQC, "\(suite.rawValue) should not be PQC")
            XCTAssertFalse(suite.isHybrid, "\(suite.rawValue) should not be Hybrid")
        }
    }
    
 // MARK: - Helpers
    
    private static func createMockSessionKeys() -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x01, count: 32),
            receiveKey: Data(repeating: 0x02, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .initiator,
            transcriptHash: Data(repeating: 0x03, count: 32)
        )
    }
    
    private func extractSuites(_ result: HandshakeOfferedSuites.BuildResult) -> [CryptoSuite] {
        switch result {
        case .suites(let suites):
            return suites
        case .empty:
            return []
        }
    }
}
