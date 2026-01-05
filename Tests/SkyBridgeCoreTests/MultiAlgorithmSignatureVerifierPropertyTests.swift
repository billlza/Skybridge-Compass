//
// MultiAlgorithmSignatureVerifierPropertyTests.swift
// SkyBridgeCoreTests
//
// 7.3: Property test for Backward Compatibility
// **Property 6: Backward Compatibility Verification (with Security Precondition)**
// **Validates: Requirements 5.1, 5.3**
//

import XCTest
import CryptoKit
@testable import SkyBridgeCore

/// Property tests for MultiAlgorithmSignatureVerifier
///
/// **Property 6: Backward Compatibility Verification (with Security Precondition)**
/// *For any* signature verification from a legacy peer:
/// - Legacy P-256 fallback SHALL only be allowed when `TrustRecord.legacyP256PublicKey` is present
/// - First-time connections (no TrustRecord) SHALL NOT allow legacy fallback
/// - Every legacy fallback SHALL emit a `legacySignatureAccepted` event with severity `.warning`
final class MultiAlgorithmSignatureVerifierPropertyTests: XCTestCase {
    
 // MARK: - Test Helpers
    
    private func createTestTrustRecord(
        deviceId: String = "test-device",
        publicKey: Data,
        protocolPublicKey: Data? = nil,
        legacyP256PublicKey: Data? = nil,
        signatureAlgorithm: SignatureAlgorithm? = nil
    ) -> TrustRecord {
        TrustRecord(
            deviceId: deviceId,
            pubKeyFP: SHA256.hash(data: publicKey).compactMap { String(format: "%02x", $0) }.joined(),
            publicKey: publicKey,
            secureEnclavePublicKey: nil,
            protocolPublicKey: protocolPublicKey,
            legacyP256PublicKey: legacyP256PublicKey,
            signatureAlgorithm: signatureAlgorithm,
            kemPublicKeys: nil,
            attestationLevel: .none,
            attestationData: nil,
            capabilities: [],
            createdAt: Date(),
            updatedAt: Date(),
            version: 1,
            signature: Data(repeating: 0, count: 64),
            recordType: .add,
            revokedAt: nil,
            deviceName: "Test Device"
        )
    }
    
 // MARK: - Property 6.1: Legacy fallback only allowed with legacyP256PublicKey
    
    func testLegacyFallbackRequiresLegacyPublicKey() async throws {
 // Generate Ed25519 key pair
        let ed25519Key = Curve25519.Signing.PrivateKey()
        let ed25519PublicKey = ed25519Key.publicKey.rawRepresentation
        
 // Generate P-256 key pair for legacy
        let p256Key = P256.Signing.PrivateKey()
        let p256PublicKey = p256Key.publicKey.x963Representation
        
 // Test data
        let testData = Data("test message".utf8)
        
 // Sign with P-256 (simulating legacy peer) - use raw representation for compatibility
        let p256Signature = try p256Key.signature(for: testData).rawRepresentation
        
 // TrustRecord WITHOUT legacyP256PublicKey - should NOT allow fallback
        let trustRecordNoLegacy = createTestTrustRecord(
            publicKey: ed25519PublicKey,
            protocolPublicKey: ed25519PublicKey,
            legacyP256PublicKey: nil
        )
        
        XCTAssertFalse(trustRecordNoLegacy.allowsLegacyFallback, "Should not allow fallback without legacy key")
        
 // Verify should fail (Ed25519 expected, P-256 signature provided, no fallback allowed)
 // Use a fake Ed25519 signature to avoid format errors
        let fakeEd25519Signature = Data(repeating: 0xAB, count: 64)
        let resultNoFallback = try await MultiAlgorithmSignatureVerifier.verify(
            data: testData,
            signature: fakeEd25519Signature,
            expectedAlgorithm: .ed25519,
            trustRecord: trustRecordNoLegacy
        )
        XCTAssertFalse(resultNoFallback, "Should fail without legacy fallback")
        
 // TrustRecord WITH legacyP256PublicKey - should allow fallback
        let trustRecordWithLegacy = createTestTrustRecord(
            publicKey: ed25519PublicKey,
            protocolPublicKey: ed25519PublicKey,
            legacyP256PublicKey: p256PublicKey
        )
        
        XCTAssertTrue(trustRecordWithLegacy.allowsLegacyFallback, "Should allow fallback with legacy key")

        
 // Verify should succeed with fallback
        let resultWithFallback = try await MultiAlgorithmSignatureVerifier.verify(
            data: testData,
            signature: p256Signature,
            expectedAlgorithm: .ed25519,
            trustRecord: trustRecordWithLegacy
        )
        XCTAssertTrue(resultWithFallback, "Should succeed with legacy fallback")
    }
    
 // MARK: - Property 6.2: First contact does not allow fallback
    
    func testFirstContactNoFallback() async throws {
 // Generate Ed25519 key pair
        let ed25519Key = Curve25519.Signing.PrivateKey()
        let ed25519PublicKey = ed25519Key.publicKey.rawRepresentation
        
 // Test data
        let testData = Data("first contact message".utf8)
        
 // Create a fake signature (wrong format for Ed25519)
        let fakeSignature = Data(repeating: 0xAB, count: 64)
        
 // First contact verification should fail with wrong signature
        let result = try await MultiAlgorithmSignatureVerifier.verifyFirstContact(
            data: testData,
            signature: fakeSignature,
            publicKey: ed25519PublicKey,
            expectedAlgorithm: .ed25519
        )
        XCTAssertFalse(result, "First contact should fail with invalid signature")
    }
    
 // MARK: - Property 6.3: First contact succeeds with correct algorithm
    
    func testFirstContactSucceedsWithCorrectAlgorithm() async throws {
 // Generate Ed25519 key pair
        let ed25519Key = Curve25519.Signing.PrivateKey()
        let ed25519PublicKey = ed25519Key.publicKey.rawRepresentation
        
 // Test data
        let testData = Data("first contact message".utf8)
        
 // Sign with Ed25519 (correct algorithm)
        let ed25519Signature = try ed25519Key.signature(for: testData)
        
 // First contact verification should succeed
        let result = try await MultiAlgorithmSignatureVerifier.verifyFirstContact(
            data: testData,
            signature: Data(ed25519Signature),
            publicKey: ed25519PublicKey,
            expectedAlgorithm: .ed25519
        )
        XCTAssertTrue(result, "First contact should succeed with correct algorithm")
    }
    
 // MARK: - Property 6.4: Verify with TrustRecord succeeds with correct algorithm
    
    func testVerifyWithTrustRecordSucceeds() async throws {
 // Generate Ed25519 key pair
        let ed25519Key = Curve25519.Signing.PrivateKey()
        let ed25519PublicKey = ed25519Key.publicKey.rawRepresentation
        
 // Test data
        let testData = Data("trusted peer message".utf8)
        
 // Sign with Ed25519
        let ed25519Signature = try ed25519Key.signature(for: testData)
        
 // Create TrustRecord with protocol public key
        let trustRecord = createTestTrustRecord(
            publicKey: ed25519PublicKey,
            protocolPublicKey: ed25519PublicKey,
            signatureAlgorithm: .ed25519
        )
        
 // Verify should succeed
        let result = try await MultiAlgorithmSignatureVerifier.verify(
            data: testData,
            signature: Data(ed25519Signature),
            expectedAlgorithm: .ed25519,
            trustRecord: trustRecord
        )
        XCTAssertTrue(result, "Verify with TrustRecord should succeed")
    }
    
 // MARK: - Property 6.5: getVerificationPublicKey returns correct key
    
    func testGetVerificationPublicKeyReturnsCorrectKey() {
        let ed25519Key = Data(repeating: 0x01, count: 32)
        let p256Key = Data(repeating: 0x02, count: 65)
        let legacyKey = Data(repeating: 0x03, count: 65)
        
 // TrustRecord with all keys
        let trustRecord = createTestTrustRecord(
            publicKey: ed25519Key,
            protocolPublicKey: ed25519Key,
            legacyP256PublicKey: legacyKey
        )
        
 // Ed25519 should return protocolPublicKey
        XCTAssertEqual(trustRecord.getVerificationPublicKey(for: .ed25519), ed25519Key)
        
 // ML-DSA-65 should return protocolPublicKey
        XCTAssertEqual(trustRecord.getVerificationPublicKey(for: .mlDSA65), ed25519Key)
        
 // P-256 ECDSA should return legacyP256PublicKey
        XCTAssertEqual(trustRecord.getVerificationPublicKey(for: .p256ECDSA), legacyKey)
    }
    
 // MARK: - Property 6.6: Fallback to publicKey when protocolPublicKey is nil
    
    func testFallbackToPublicKeyWhenProtocolKeyNil() {
        let publicKey = Data(repeating: 0x01, count: 32)
        
 // TrustRecord without protocolPublicKey
        let trustRecord = createTestTrustRecord(
            publicKey: publicKey,
            protocolPublicKey: nil
        )
        
 // Should fall back to publicKey
        XCTAssertEqual(trustRecord.getVerificationPublicKey(for: .ed25519), publicKey)
    }
}
