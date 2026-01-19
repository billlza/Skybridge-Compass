//
// TwoAttemptHandshakeManagerTests.swift
// SkyBridgeCoreTests
//
// 9.6: Deterministic unit tests for Attempt 驱动
// Requirements: 9.1, 9.2, 9.3, 9.4, 12.1, 12.4
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class TwoAttemptHandshakeManagerTests: XCTestCase {
    
 // MARK: - Mock CryptoProvider
    
 /// Mock CryptoProvider for testing
    private class MockCryptoProvider: CryptoProvider, @unchecked Sendable {
        let providerName: String = "MockProvider"
        let tier: CryptoTier = .classic
        let activeSuite: CryptoSuite = .x25519Ed25519
        private let _supportedSuites: [CryptoSuite]
        
        var supportedSuites: [CryptoSuite] { _supportedSuites }
        
        init(supportedSuites: [CryptoSuite]) {
            self._supportedSuites = supportedSuites
        }
        
        func supportsSuite(_ suite: CryptoSuite) -> Bool {
            _supportedSuites.contains { $0.wireId == suite.wireId }
        }
        
        func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
            throw CryptoProviderError.notImplemented("Mock")
        }
        
        func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
            throw CryptoProviderError.notImplemented("Mock")
        }
        
        func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
            throw CryptoProviderError.notImplemented("Mock")
        }
        
        func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
            throw CryptoProviderError.notImplemented("Mock")
        }
        
        func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
            throw CryptoProviderError.notImplemented("Mock")
        }
    }
    
 // MARK: - Test Data
    
    private let pqcSuites: [CryptoSuite] = [.xwingMLDSA, .mlkem768MLDSA65]
    private let classicSuites: [CryptoSuite] = [.x25519Ed25519, .p256ECDSA]
    private var allSuites: [CryptoSuite] { pqcSuites + classicSuites }
    
 // MARK: - 9.1: prepareAttempt Tests
    
 /// Test pqc attempt: sigAAlgorithm=ML-DSA-65, suites 全 PQCGroup
    func testPrepareAttempt_PQCOnly_Success() throws {
        let provider = MockCryptoProvider(supportedSuites: allSuites)
        
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )
        
 // Verify sigAAlgorithm is ML-DSA-65
        XCTAssertEqual(preparation.sigAAlgorithm, .mlDSA65, "PQC attempt should use ML-DSA-65")
        
 // Verify all suites are PQC group
        for suite in preparation.offeredSuites {
            XCTAssertTrue(suite.isPQCGroup, "All suites should be PQC group")
        }
        
 // Verify strategy
        XCTAssertEqual(preparation.strategy, .pqcOnly)
    }
    
 /// Test classic attempt: sigAAlgorithm=Ed25519, suites 全 ClassicGroup
    func testPrepareAttempt_ClassicOnly_Success() throws {
        let provider = MockCryptoProvider(supportedSuites: allSuites)
        
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .classicOnly,
            cryptoProvider: provider
        )
        
 // Verify sigAAlgorithm is Ed25519
        XCTAssertEqual(preparation.sigAAlgorithm, .ed25519, "Classic attempt should use Ed25519")
        
 // Verify all suites are Classic group
        for suite in preparation.offeredSuites {
            XCTAssertFalse(suite.isPQCGroup, "All suites should be Classic group")
        }
        
 // Verify strategy
        XCTAssertEqual(preparation.strategy, .classicOnly)
    }
    
 /// Test pqcOnly with no PQC suites → throws pqcProviderUnavailable
    func testPrepareAttempt_PQCOnly_NoPQCSuites_Throws() {
        let provider = MockCryptoProvider(supportedSuites: classicSuites)
        
        XCTAssertThrowsError(try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )) { error in
            guard case AttemptPreparationError.pqcProviderUnavailable = error else {
                XCTFail("Expected pqcProviderUnavailable error")
                return
            }
        }
    }
    
    /// Test classicOnly with no classic suites in the selected cryptoProvider
    /// falls back to the built-in Classic provider.
    func testPrepareAttempt_ClassicOnly_NoClassicSuites_FallsBackToClassicProvider() throws {
        let provider = MockCryptoProvider(supportedSuites: pqcSuites)
        
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .classicOnly,
            cryptoProvider: provider
        )
        
        XCTAssertEqual(preparation.strategy, .classicOnly)
        XCTAssertEqual(preparation.sigAAlgorithm, .ed25519)
        XCTAssertEqual(preparation.offeredSuites, [.x25519Ed25519])
    }
    
 // MARK: - 9.2: Fallback Whitelist/Blacklist Tests
    
 /// Test timeout does NOT trigger fallback
    func testIsPQCUnavailableError_Timeout_ReturnsFalse() {
        let result = TwoAttemptHandshakeManager.isPQCUnavailableError(.timeout)
        XCTAssertFalse(result, "Timeout should NOT trigger fallback")
    }
    
 /// Test suiteSignatureMismatch does NOT trigger fallback
    func testIsPQCUnavailableError_SuiteSignatureMismatch_ReturnsFalse() {
        let result = TwoAttemptHandshakeManager.isPQCUnavailableError(
            .suiteSignatureMismatch(selectedSuite: "X25519", sigAAlgorithm: "ML-DSA-65")
        )
        XCTAssertFalse(result, "suiteSignatureMismatch should NOT trigger fallback")
    }
    
 /// Test signatureVerificationFailed does NOT trigger fallback
    func testIsPQCUnavailableError_SignatureVerificationFailed_ReturnsFalse() {
        let result = TwoAttemptHandshakeManager.isPQCUnavailableError(.signatureVerificationFailed)
        XCTAssertFalse(result, "signatureVerificationFailed should NOT trigger fallback")
    }
    
 /// Test pqcProviderUnavailable DOES trigger fallback
    func testIsPQCUnavailableError_PQCProviderUnavailable_ReturnsTrue() {
        let result = TwoAttemptHandshakeManager.isPQCUnavailableError(.pqcProviderUnavailable)
        XCTAssertTrue(result, "pqcProviderUnavailable should trigger fallback")
    }
    
 /// Test suiteNotSupported DOES trigger fallback
    func testIsPQCUnavailableError_SuiteNotSupported_ReturnsTrue() {
        let result = TwoAttemptHandshakeManager.isPQCUnavailableError(.suiteNotSupported)
        XCTAssertTrue(result, "suiteNotSupported should trigger fallback")
    }
    
 /// Test suiteNegotiationFailed DOES trigger fallback
    func testIsPQCUnavailableError_SuiteNegotiationFailed_ReturnsTrue() {
        let result = TwoAttemptHandshakeManager.isPQCUnavailableError(.suiteNegotiationFailed)
        XCTAssertTrue(result, "suiteNegotiationFailed should trigger fallback")
    }
    
 // MARK: - Homogeneity Verification Tests
    
 /// Verify PQC attempt produces homogeneous suites
    func testPQCAttempt_ProducesHomogeneousSuites() throws {
        let provider = MockCryptoProvider(supportedSuites: allSuites)
        
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .pqcOnly,
            cryptoProvider: provider
        )
        
 // All suites must be PQC group (homogeneous)
        let allPQCGroup = preparation.offeredSuites.allSatisfy { $0.isPQCGroup }
        XCTAssertTrue(allPQCGroup, "PQC attempt must produce homogeneous PQC suites")
        
 // sigAAlgorithm must match
        XCTAssertEqual(preparation.sigAAlgorithm, .mlDSA65, "sigAAlgorithm must be ML-DSA-65 for PQC suites")
    }
    
 /// Verify Classic attempt produces homogeneous suites
    func testClassicAttempt_ProducesHomogeneousSuites() throws {
        let provider = MockCryptoProvider(supportedSuites: allSuites)
        
        let preparation = try TwoAttemptHandshakeManager.prepareAttempt(
            strategy: .classicOnly,
            cryptoProvider: provider
        )
        
 // All suites must be Classic group (homogeneous)
        let allClassic = preparation.offeredSuites.allSatisfy { !$0.isPQCGroup }
        XCTAssertTrue(allClassic, "Classic attempt must produce homogeneous Classic suites")
        
 // sigAAlgorithm must match
        XCTAssertEqual(preparation.sigAAlgorithm, .ed25519, "sigAAlgorithm must be Ed25519 for Classic suites")
    }
    
 // MARK: - AttemptPreparation Struct Tests
    
 /// Test AttemptPreparation initialization
    func testAttemptPreparation_Initialization() {
        let provider = ClassicSignatureProvider()
        let preparation = AttemptPreparation(
            strategy: .classicOnly,
            offeredSuites: classicSuites,
            sigAAlgorithm: .ed25519,
            signatureProvider: provider
        )
        
        XCTAssertEqual(preparation.strategy, .classicOnly)
        XCTAssertEqual(preparation.offeredSuites.count, classicSuites.count)
        XCTAssertEqual(preparation.sigAAlgorithm, .ed25519)
        XCTAssertEqual(preparation.signatureProvider.signatureAlgorithm, .ed25519)
    }
}
