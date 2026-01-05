//
// SecureEnclaveSigningCallbackTests.swift
// SkyBridgeCoreTests
//
// Unit tests for SecureEnclaveSigningCallback and FallbackSigningCallback
// **Feature: p2p-todo-completion, 4.3: 签名回调单元测试**
// **Validates: Requirements 2.3, 2.4**
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class SecureEnclaveSigningCallbackTests: XCTestCase {
    
 // MARK: - Test Fixtures
    
    private var provider: ClassicCryptoProvider!
    private var signingKeyPair: KeyPair!
    
    override func setUp() async throws {
        try await super.setUp()
        provider = ClassicCryptoProvider()
        signingKeyPair = try await provider.generateKeyPair(for: .signing)
    }
    
    override func tearDown() async throws {
        provider = nil
        signingKeyPair = nil
        try await super.tearDown()
    }
    
 // MARK: - SecureEnclaveKeyManager Tests
    
 /// Test that isSecureEnclaveAvailable returns a boolean
 /// Note: On simulator this will return false, on real device it may return true
    func testSecureEnclaveAvailabilityCheck() {
        let isAvailable = SecureEnclaveKeyManager.isSecureEnclaveAvailable()
 // Just verify it returns without crashing
        XCTAssertNotNil(isAvailable)
        
        #if targetEnvironment(simulator)
 // On simulator, Secure Enclave should not be available
        XCTAssertFalse(isAvailable, "Secure Enclave should not be available on simulator")
        #endif
    }
    
 /// Test keyExists returns false for non-existent key
    func testKeyExistsReturnsFalseForNonExistentKey() {
        let nonExistentTag = "com.skybridge.test.nonexistent.\(UUID().uuidString)"
        let exists = SecureEnclaveKeyManager.keyExists(tag: nonExistentTag)
        XCTAssertFalse(exists, "Non-existent key should not exist")
    }
    
 /// Test deleteKey succeeds for non-existent key
    func testDeleteKeySucceedsForNonExistentKey() {
        let nonExistentTag = "com.skybridge.test.nonexistent.\(UUID().uuidString)"
        let result = SecureEnclaveKeyManager.deleteKey(tag: nonExistentTag)
        XCTAssertTrue(result, "Delete should succeed for non-existent key")
    }
    
 // MARK: - SecureEnclaveError Tests
    
 /// Test error descriptions are meaningful
    func testSecureEnclaveErrorDescriptions() {
        let errors: [SecureEnclaveError] = [
            .keyNotFound("test-tag", -25300),
            .invalidKeyReference,
            .algorithmNotSupported("test-algorithm"),
            .signatureFailed("test-reason"),
            .secureEnclaveUnavailable,
            .keyGenerationFailed("test-reason")
        ]
        
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error should have description: \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error description should not be empty")
        }
    }
    
 // MARK: - CryptoProviderSigningCallback Tests
    
 /// Test CryptoProviderSigningCallback signs data correctly
    func testCryptoProviderSigningCallbackSigns() async throws {
        let callback = CryptoProviderSigningCallback(
            provider: provider,
            privateKey: signingKeyPair.privateKey.bytes
        )
        
        let testData = Data("test-data-to-sign".utf8)
        let signature = try await callback.sign(data: testData)
        
 // Verify signature is not empty
        XCTAssertFalse(signature.isEmpty, "Signature should not be empty")
        
 // Verify signature is valid
        let isValid = try await provider.verify(
            data: testData,
            signature: signature,
            publicKey: signingKeyPair.publicKey.bytes
        )
        XCTAssertTrue(isValid, "Signature should be valid")
    }
    
 /// Test CryptoProviderSigningCallback produces different signatures for different data
    func testCryptoProviderSigningCallbackDifferentSignatures() async throws {
        let callback = CryptoProviderSigningCallback(
            provider: provider,
            privateKey: signingKeyPair.privateKey.bytes
        )
        
        let data1 = Data("data-one".utf8)
        let data2 = Data("data-two".utf8)
        
        let sig1 = try await callback.sign(data: data1)
        let sig2 = try await callback.sign(data: data2)
        
 // Signatures should be different for different data
        XCTAssertNotEqual(sig1, sig2, "Different data should produce different signatures")
    }
    
 // MARK: - FallbackSigningCallback Tests
    
 /// Test FallbackSigningCallback falls back to CryptoProvider when Secure Enclave key doesn't exist
    func testFallbackSigningCallbackFallsBackWhenKeyNotFound() async throws {
        let nonExistentTag = "com.skybridge.test.nonexistent.\(UUID().uuidString)"
        
        let callback = FallbackSigningCallback(
            keyTag: nonExistentTag,
            fallbackProvider: provider,
            fallbackPrivateKey: signingKeyPair.privateKey.bytes
        )
        
        let testData = Data("test-fallback-data".utf8)
        
 // Should succeed using fallback
        let signature = try await callback.sign(data: testData)
        XCTAssertFalse(signature.isEmpty, "Fallback should produce signature")
        
 // Verify signature is valid (from CryptoProvider)
        let isValid = try await provider.verify(
            data: testData,
            signature: signature,
            publicKey: signingKeyPair.publicKey.bytes
        )
        XCTAssertTrue(isValid, "Fallback signature should be valid")
    }
    
 /// Test FallbackSigningCallback.create returns appropriate callback
    func testFallbackSigningCallbackCreate() async throws {
        let nonExistentTag = "com.skybridge.test.nonexistent.\(UUID().uuidString)"
        
        let callback = FallbackSigningCallback.create(
            keyTag: nonExistentTag,
            fallbackProvider: provider,
            fallbackPrivateKey: signingKeyPair.privateKey.bytes
        )
        
 // Should be able to sign
        let testData = Data("test-create-data".utf8)
        let signature = try await callback.sign(data: testData)
        XCTAssertFalse(signature.isEmpty, "Created callback should produce signature")
    }
    
 /// Test FallbackSigningCallback resetSecureEnclaveStatus
    func testFallbackSigningCallbackReset() async throws {
        let nonExistentTag = "com.skybridge.test.nonexistent.\(UUID().uuidString)"
        
        let callback = FallbackSigningCallback(
            keyTag: nonExistentTag,
            fallbackProvider: provider,
            fallbackPrivateKey: signingKeyPair.privateKey.bytes
        )
        
 // First sign should trigger fallback and mark SE as unavailable
        let testData = Data("test-reset-data".utf8)
        _ = try await callback.sign(data: testData)
        
 // Reset status
        callback.resetSecureEnclaveStatus()
        
 // Should be able to sign again (will try SE again, then fallback)
        let signature = try await callback.sign(data: testData)
        XCTAssertFalse(signature.isEmpty, "Should still produce signature after reset")
    }
    
 /// Test multiple sequential signs with FallbackSigningCallback
    func testFallbackSigningCallbackMultipleSigns() async throws {
        let nonExistentTag = "com.skybridge.test.nonexistent.\(UUID().uuidString)"
        
        let callback = FallbackSigningCallback(
            keyTag: nonExistentTag,
            fallbackProvider: provider,
            fallbackPrivateKey: signingKeyPair.privateKey.bytes
        )
        
 // Sign multiple times
        for i in 0..<5 {
            let testData = Data("test-data-\(i)".utf8)
            let signature = try await callback.sign(data: testData)
            XCTAssertFalse(signature.isEmpty, "Sign \(i) should produce signature")
            
 // Verify each signature
            let isValid = try await provider.verify(
                data: testData,
                signature: signature,
                publicKey: signingKeyPair.publicKey.bytes
            )
            XCTAssertTrue(isValid, "Signature \(i) should be valid")
        }
    }
    
 // MARK: - Integration with HandshakeDriver Tests
    
 /// Test that FallbackSigningCallback works with HandshakeDriver
    func testFallbackSigningCallbackWithHandshakeDriver() async throws {
        let transport = MockDiscoveryTransportForSigning()
        let nonExistentTag = "com.skybridge.test.nonexistent.\(UUID().uuidString)"
        
        let callback = FallbackSigningCallback(
            keyTag: nonExistentTag,
            fallbackProvider: provider,
            fallbackPrivateKey: signingKeyPair.privateKey.bytes
        )
        
        let driver = try HandshakeDriver(
            transport: transport,
            cryptoProvider: provider,
            protocolSignatureProvider: ClassicSignatureProvider(),
            protocolSigningKeyHandle: .callback(callback),
            sigAAlgorithm: .ed25519,
            identityPublicKey: encodeIdentityPublicKey(signingKeyPair.publicKey.bytes),
            offeredSuites: [.x25519Ed25519]
        )
        
 // Test signData uses the callback
        let testData = Data("handshake-test-data".utf8)
        let signature = try await driver.signData(testData)
        
        XCTAssertFalse(signature.isEmpty, "Driver should produce signature via callback")
    }
}

// MARK: - Mock Transport for Signing Tests

@available(macOS 14.0, iOS 17.0, *)
actor MockDiscoveryTransportForSigning: DiscoveryTransport {
    func send(to peer: PeerIdentifier, data: Data) async throws {
 // No-op for signing tests
    }
}
