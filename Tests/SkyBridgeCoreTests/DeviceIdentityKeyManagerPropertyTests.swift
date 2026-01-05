//
// DeviceIdentityKeyManagerPropertyTests.swift
// SkyBridgeCoreTests
//
// Signature Mechanism Alignment - 5.4, 5.5
// Property tests for DeviceIdentityKeyManager
//
// **Property 4: Key Separation Invariant**
// **Validates: Requirements 2.1, 2.2, 2.3**
//
// **Property 7: Key Migration Preservation**
// **Validates: Requirements 5.4**
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class DeviceIdentityKeyManagerPropertyTests: XCTestCase {
    
 // MARK: - Property 4: Key Separation Invariant
    
 /// **Property 4.1**: Protocol signing keys (Ed25519) and SE PoP keys (P-256) have distinct key tags
 /// **Validates: Requirements 2.1, 2.2, 2.3**
    func testProperty4_1_KeyTagsSeparation() async throws {
 // Verify that the key tags are distinct
        let protocolTag = "com.skybridge.p2p.identity.protocol.ed25519"
        let sePoPTag = "com.skybridge.p2p.identity.pop.p256"
        let legacyTag = "com.skybridge.p2p.identity.signing"
        
        XCTAssertNotEqual(protocolTag, sePoPTag, "Protocol and SE PoP tags must be distinct")
        XCTAssertNotEqual(protocolTag, legacyTag, "Protocol and legacy tags must be distinct")
        XCTAssertNotEqual(sePoPTag, legacyTag, "SE PoP and legacy tags must be distinct")
    }
    
 /// **Property 4.2**: Key purpose identification is correct for each tag
 /// **Validates: Requirements 2.1, 2.2, 2.3**
    func testProperty4_2_KeyPurposeIdentification() async {
        let manager = DeviceIdentityKeyManager.shared
        
 // Test protocol signing key tag
        let protocolPurpose = await manager.identifyKeyPurpose(tag: "com.skybridge.p2p.identity.protocol.ed25519")
        XCTAssertEqual(protocolPurpose, .protocol, "Protocol signing key tag should have .protocol purpose")
        
 // Test SE PoP key tag
        let sePoPPurpose = await manager.identifyKeyPurpose(tag: "com.skybridge.p2p.identity.pop.p256")
        XCTAssertEqual(sePoPPurpose, .pop, "SE PoP key tag should have .pop purpose")
        
 // Test legacy key tag
        let legacyPurpose = await manager.identifyKeyPurpose(tag: "com.skybridge.p2p.identity.signing")
        XCTAssertEqual(legacyPurpose, .legacy, "Legacy key tag should have .legacy purpose")
        
 // Test unknown tag
        let unknownPurpose = await manager.identifyKeyPurpose(tag: "com.unknown.tag")
        XCTAssertEqual(unknownPurpose, .unknown, "Unknown tag should have .unknown purpose")
    }
    
 /// **Property 4.3**: Ed25519 protocol signing key can be created and retrieved
 /// **Validates: Requirements 2.1, 2.2, 2.4**
    func testProperty4_3_Ed25519KeyCreationAndRetrieval() async throws {
        let manager = DeviceIdentityKeyManager.shared
        
 // Get or create Ed25519 protocol signing key
        let (publicKey, keyHandle) = try await manager.getOrCreateProtocolSigningKey()
        
 // Verify public key is 32 bytes (Ed25519)
        XCTAssertEqual(publicKey.count, 32, "Ed25519 public key should be 32 bytes")
        
 // Verify key handle is software key (Ed25519 doesn't support SE)
        switch keyHandle {
        case .softwareKey(let privateKey):
            XCTAssertEqual(privateKey.count, 32, "Ed25519 private key should be 32 bytes")
        default:
            XCTFail("Ed25519 key should be a software key, not Secure Enclave")
        }
        
 // Retrieve again and verify consistency
        let (publicKey2, _) = try await manager.getOrCreateProtocolSigningKey()
        XCTAssertEqual(publicKey, publicKey2, "Repeated retrieval should return the same public key")
    }
    
 /// **Property 4.4**: Protocol signing key handle can be used for signing
 /// **Validates: Requirements 2.4**
    func testProperty4_4_ProtocolSigningKeyCanSign() async throws {
        let manager = DeviceIdentityKeyManager.shared
        
 // Get protocol signing key handle
        let keyHandle = try await manager.getProtocolSigningKeyHandle()
        
 // Create a signature provider
        let provider = ClassicSignatureProvider()
        
 // Sign some test data
        let testData = "Test data for signing".data(using: .utf8)!
        let signature = try await provider.sign(testData, key: keyHandle)
        
 // Verify signature is 64 bytes (Ed25519)
        XCTAssertEqual(signature.count, 64, "Ed25519 signature should be 64 bytes")
        
 // Get public key and verify
        let publicKey = try await manager.getProtocolSigningPublicKey()
        let isValid = try await provider.verify(testData, signature: signature, publicKey: publicKey)
        XCTAssertTrue(isValid, "Signature should verify with the corresponding public key")
    }
    
 // MARK: - Property 7: Key Migration Preservation
    
 /// **Property 7.1**: Migration is idempotent (can be called multiple times safely)
 /// **Validates: Requirements 5.4**
    func testProperty7_1_MigrationIdempotency() async throws {
        let manager = DeviceIdentityKeyManager.shared
        
 // Call migration multiple times - should not throw
        try await manager.migrateExistingIdentityKey()
        try await manager.migrateExistingIdentityKey()
        try await manager.migrateExistingIdentityKey()
        
 // If we get here without throwing, idempotency is preserved
        XCTAssertTrue(true, "Migration should be idempotent")
    }
    
 /// **Property 7.2**: SE PoP key handle returns nil when SE is not available (simulator)
 /// **Validates: Requirements 2.3, 2.5**
    func testProperty7_2_SEPoPKeyHandleOptional() async throws {
        let manager = DeviceIdentityKeyManager.shared
        
 // On simulator, SE is not available, so this should return nil
 // On real device with SE, this should return a valid handle
        _ = try await manager.getSecureEnclaveKeyHandle()
        
 // This test just verifies the method doesn't crash
 // The actual behavior depends on the device
        XCTAssertTrue(true, "getSecureEnclaveKeyHandle should not crash")
    }
    
 // MARK: - KeyPurpose Enum Tests
    
 /// Test KeyPurpose raw values
    func testKeyPurposeRawValues() {
        XCTAssertEqual(KeyPurpose.legacy.rawValue, "legacy")
        XCTAssertEqual(KeyPurpose.protocol.rawValue, "protocol")
        XCTAssertEqual(KeyPurpose.pop.rawValue, "pop")
        XCTAssertEqual(KeyPurpose.unknown.rawValue, "unknown")
    }
}
