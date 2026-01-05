//
// iOSHandshakeEntryAlignmentPropertyTests.swift
// SkyBridgeCoreTests
//
// iOS Handshake Entry Point Alignment - 5
// Property tests for iOS handshake entry alignment
//
// **Property 1: Protocol Signing Key Algorithm Consistency**
// **Validates: Requirements 1.1, 1.4**
//
// **Property 2: Identity Public Keys Wire Round-Trip**
// **Validates: Requirements 2.1, 2.3**
//
// **Property 3: Legacy Fallback Safety**
// **Validates: Requirements 2.4, 5.4**
//
// **Property 4: Fallback Whitelist/Blacklist**
// **Validates: Requirements 4.3, 4.4, 4.5**
//

import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class iOSHandshakeEntryAlignmentPropertyTests: XCTestCase {
    
 // MARK: - Test Configuration
    
 /// Minimum iterations for property tests
    private static let minIterations = 100
    
 // MARK: - Property 1: Protocol Signing Key Algorithm Consistency
    
 /// **Feature: iOS Handshake Entry Alignment, Property 1: Protocol Signing Key Algorithm Consistency**
 ///
 /// For any `ProtocolSigningAlgorithm`:
 /// - `getProtocolSigningKeyHandle(for:)` returns handle with correct type/size
 /// - Ed25519: softwareKey, 32/64 bytes
 /// - ML-DSA-65: softwareKey, 64/4032 bytes
 ///
 /// **Validates: Requirements 1.1, 1.4**
    func testProperty1_ProtocolSigningKeyAlgorithmConsistency() async throws {
        let manager = DeviceIdentityKeyManager.shared
        let algorithms: [ProtocolSigningAlgorithm] = [.ed25519, .mlDSA65]
        
        for iteration in 0..<Self.minIterations {
 // Pick algorithm based on iteration (alternating)
            let algorithm = algorithms[iteration % algorithms.count]
            
 // Get key handle for the algorithm
            let keyHandle = try await manager.getProtocolSigningKeyHandle(for: algorithm)
            
 // Verify key handle type and size
            switch algorithm {
            case .ed25519:
                switch keyHandle {
                case .softwareKey(let privateKey):
 // Ed25519 private key: 32 bytes (seed) or 64 bytes (seed + public)
                    XCTAssertTrue(
                        privateKey.count == 32 || privateKey.count == 64,
                        "Ed25519 key should be 32 or 64 bytes, got \(privateKey.count) at iteration \(iteration)"
                    )
                #if canImport(Security)
                case .secureEnclaveRef:
                    XCTFail("Ed25519 should not use Secure Enclave at iteration \(iteration)")
                #endif
                case .callback:
 // Callback is acceptable for Ed25519
                    break
                }
                
            case .mlDSA65:
                switch keyHandle {
                case .softwareKey(let privateKey):
 // ML-DSA-65 private key: 64 bytes (seed) or 4032 bytes (full key)
                    XCTAssertTrue(
                        privateKey.count == 64 || privateKey.count == 4032,
                        "ML-DSA-65 key should be 64 or 4032 bytes, got \(privateKey.count) at iteration \(iteration)"
                    )
                #if canImport(Security)
                case .secureEnclaveRef:
                    XCTFail("ML-DSA-65 should not use Secure Enclave at iteration \(iteration)")
                #endif
                case .callback:
 // Callback is acceptable for ML-DSA-65
                    break
                }
            }
        }
    }
    
 /// **Feature: iOS Handshake Entry Alignment, Property 1.2: Key Handle Can Sign**
 ///
 /// For any `ProtocolSigningAlgorithm`:
 /// - The key handle can produce a valid signature
 /// - The signature verifies with the corresponding public key
 ///
 /// **Validates: Requirements 1.1, 1.4**
    func testProperty1_2_KeyHandleCanSign() async throws {
        let manager = DeviceIdentityKeyManager.shared
        let algorithms: [ProtocolSigningAlgorithm] = [.ed25519, .mlDSA65]
        
        for iteration in 0..<Self.minIterations {
            let algorithm = algorithms[iteration % algorithms.count]
            
 // Get key handle and public key
            let keyHandle = try await manager.getProtocolSigningKeyHandle(for: algorithm)
            let publicKey = try await manager.getProtocolSigningPublicKey(for: algorithm)
            
 // Get signature provider
            let provider = PreNegotiationSignatureSelector.selectProvider(for: algorithm)
            
 // Generate random test data
            var testData = Data(count: 32)
            _ = testData.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            
 // Sign the data
            let signature = try await provider.sign(testData, key: keyHandle)
            
 // Verify the signature
            let isValid = try await provider.verify(testData, signature: signature, publicKey: publicKey)
            XCTAssertTrue(isValid, "Signature should verify at iteration \(iteration) for \(algorithm)")
        }
    }

    
 // MARK: - Property 2: Identity Public Keys Wire Round-Trip
    
 /// **Feature: iOS Handshake Entry Alignment, Property 2: Identity Public Keys Wire Round-Trip**
 ///
 /// For any `ProtocolIdentityPublicKeys`:
 /// - `asWire().encoded` can be decoded by `decodeWithLegacyFallback`
 /// - Decoded fields match original
 ///
 /// **Validates: Requirements 2.1, 2.3**
    func testProperty2_IdentityPublicKeysWireRoundTrip() async throws {
        let algorithms: [ProtocolSigningAlgorithm] = [.ed25519, .mlDSA65]
        
        for iteration in 0..<Self.minIterations {
            let algorithm = algorithms[iteration % algorithms.count]
            
 // Generate random protocol public key with appropriate size
            let protocolPublicKeySize: Int
            switch algorithm {
            case .ed25519:
                protocolPublicKeySize = 32
            case .mlDSA65:
                protocolPublicKeySize = 1952
            }
            
            var protocolPublicKey = Data(count: protocolPublicKeySize)
            _ = protocolPublicKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, protocolPublicKeySize, $0.baseAddress!) }
            
 // Optionally generate SE PoP public key (50% chance)
            let sePoPPublicKey: Data?
            if iteration % 2 == 0 {
                var seKey = Data(count: 65) // P-256 uncompressed
                _ = seKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 65, $0.baseAddress!) }
                sePoPPublicKey = seKey
            } else {
                sePoPPublicKey = nil
            }
            
 // Create ProtocolIdentityPublicKeys
            let original = ProtocolIdentityPublicKeys(
                protocolPublicKey: protocolPublicKey,
                protocolAlgorithm: algorithm,
                sePoPPublicKey: sePoPPublicKey
            )
            
 // Convert to wire format and encode
            let wire = original.asWire()
            let encoded = wire.encoded
            
 // Decode with legacy fallback
            let decoded = try IdentityPublicKeys.decodeWithLegacyFallback(from: encoded)
            
 // Verify fields match
            XCTAssertEqual(
                decoded.protocolPublicKey, protocolPublicKey,
                "Protocol public key mismatch at iteration \(iteration)"
            )
            XCTAssertEqual(
                decoded.protocolAlgorithm, algorithm.wire,
                "Protocol algorithm mismatch at iteration \(iteration)"
            )
            XCTAssertEqual(
                decoded.secureEnclavePublicKey, sePoPPublicKey,
                "SE PoP public key mismatch at iteration \(iteration)"
            )
        }
    }
    
 /// **Feature: iOS Handshake Entry Alignment, Property 2.2: Wire Encoding is Canonical**
 ///
 /// Same semantic input produces same encoded bytes.
 ///
 /// **Validates: Requirements 2.1, 2.3**
    func testProperty2_2_WireEncodingIsCanonical() async throws {
        for iteration in 0..<Self.minIterations {
 // Generate random data
            var protocolPublicKey = Data(count: 32)
            _ = protocolPublicKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            
            let sePoPPublicKey: Data? = iteration % 2 == 0 ? Data(repeating: UInt8(iteration % 256), count: 65) : nil
            
 // Create two identical instances
            let keys1 = ProtocolIdentityPublicKeys(
                protocolPublicKey: protocolPublicKey,
                protocolAlgorithm: .ed25519,
                sePoPPublicKey: sePoPPublicKey
            )
            let keys2 = ProtocolIdentityPublicKeys(
                protocolPublicKey: protocolPublicKey,
                protocolAlgorithm: .ed25519,
                sePoPPublicKey: sePoPPublicKey
            )
            
 // Encode both
            let encoded1 = keys1.asWire().encoded
            let encoded2 = keys2.asWire().encoded
            
 // Verify canonical encoding
            XCTAssertEqual(encoded1, encoded2, "Encoding should be canonical at iteration \(iteration)")
        }
    }

    
 // MARK: - Property 3: Legacy Fallback Safety
    
 /// **Feature: iOS Handshake Entry Alignment, Property 3: Legacy Fallback Safety**
 ///
 /// For legacy P-256 uncompressed public key data:
 /// - `decodeWithLegacyFallback` produces `.p256ECDSA`
 /// - `asProtocolIdentityKeys()` rejects P-256
 ///
 /// **Validates: Requirements 2.4, 5.4**
    func testProperty3_LegacyFallbackSafety() async throws {
        for iteration in 0..<Self.minIterations {
 // Legacy format: standard uncompressed P-256 public key (0x04 + 64 bytes)
            var rawPublicKey = Data(count: 65)
            _ = rawPublicKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 65, $0.baseAddress!) }
            rawPublicKey[0] = 0x04
            
 // Decode with legacy fallback
            let decoded = try IdentityPublicKeys.decodeWithLegacyFallback(from: rawPublicKey)
            
 // Verify it's marked as P-256 ECDSA (legacy)
            XCTAssertEqual(
                decoded.protocolAlgorithm, .p256ECDSA,
                "Legacy data should be marked as P-256 ECDSA at iteration \(iteration)"
            )
            
 // Verify asProtocolIdentityKeys() rejects P-256
            do {
                _ = try decoded.asProtocolIdentityKeys()
                XCTFail("asProtocolIdentityKeys() should reject P-256 at iteration \(iteration)")
            } catch let error as SignatureAlignmentError {
 // Expected: P-256 is rejected
                if case .invalidAlgorithmForProtocolSigning(let algorithm) = error {
                    XCTAssertEqual(algorithm, .p256ECDSA, "Error should indicate P-256 ECDSA")
                } else {
                    XCTFail("Unexpected error type: \(error)")
                }
            }
        }
    }
    
 /// **Feature: iOS Handshake Entry Alignment, Property 3.2: New Format Not Misidentified as Legacy**
 ///
 /// Valid new format data should not be treated as legacy.
 ///
 /// **Validates: Requirements 2.4, 5.4**
    func testProperty3_2_NewFormatNotMisidentifiedAsLegacy() async throws {
        let algorithms: [ProtocolSigningAlgorithm] = [.ed25519, .mlDSA65]
        
        for iteration in 0..<Self.minIterations {
            let algorithm = algorithms[iteration % algorithms.count]
            
 // Generate valid new format data
            let keySize = algorithm == .ed25519 ? 32 : 1952
            var protocolPublicKey = Data(count: keySize)
            _ = protocolPublicKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, keySize, $0.baseAddress!) }
            
            let original = ProtocolIdentityPublicKeys(
                protocolPublicKey: protocolPublicKey,
                protocolAlgorithm: algorithm,
                sePoPPublicKey: nil
            )
            
            let encoded = original.asWire().encoded
            
 // Decode with legacy fallback
            let decoded = try IdentityPublicKeys.decodeWithLegacyFallback(from: encoded)
            
 // Verify it's NOT marked as P-256 (not legacy)
            XCTAssertNotEqual(
                decoded.protocolAlgorithm, .p256ECDSA,
                "New format should not be marked as P-256 at iteration \(iteration)"
            )
            XCTAssertEqual(
                decoded.protocolAlgorithm, algorithm.wire,
                "Algorithm should match original at iteration \(iteration)"
            )
            
 // Verify asProtocolIdentityKeys() succeeds
            let protocolKeys = try decoded.asProtocolIdentityKeys()
            XCTAssertEqual(protocolKeys.protocolAlgorithm, algorithm)
        }
    }

    
 // MARK: - Property 4: Fallback Whitelist/Blacklist
    
 /// **Feature: iOS Handshake Entry Alignment, Property 4: Fallback Whitelist/Blacklist**
 ///
 /// - Whitelist errors allow fallback: pqcProviderUnavailable, suiteNotSupported, suiteNegotiationFailed
 /// - Blacklist errors forbid fallback: timeout, invalidMessageFormat, signatureVerificationFailed
 ///
 /// **Validates: Requirements 4.3, 4.4, 4.5**
    func testProperty4_FallbackWhitelistBlacklist() async throws {
 // Whitelist errors (should allow fallback)
        let whitelistErrors: [HandshakeFailureReason] = [
            .pqcProviderUnavailable,
            .suiteNotSupported,
            .suiteNegotiationFailed
        ]
        
 // Blacklist errors (should NOT allow fallback)
        let blacklistErrors: [HandshakeFailureReason] = [
            .timeout,
            .invalidMessageFormat("test"),
            .signatureVerificationFailed,
            .keyConfirmationFailed,
            .replayDetected,
            .identityMismatch(expected: "device-a", actual: "device-b"),
            .suiteSignatureMismatch(selectedSuite: "X25519-Ed25519", sigAAlgorithm: "ML-DSA-65"),
            .cancelled,
            .peerRejected(message: "test"),
            .cryptoError("test"),
            .transportError("test"),
            .versionMismatch(local: 1, remote: 2),
            .secureEnclavePoPRequired,
            .secureEnclaveSignatureInvalid
        ]
        
 // Test whitelist errors
        for iteration in 0..<Self.minIterations {
            let error = whitelistErrors[iteration % whitelistErrors.count]
            let shouldFallback = TwoAttemptHandshakeManager.isPQCUnavailableError(error)
            XCTAssertTrue(
                shouldFallback,
                "Whitelist error \(error) should allow fallback at iteration \(iteration)"
            )
        }
        
 // Test blacklist errors
        for iteration in 0..<Self.minIterations {
            let error = blacklistErrors[iteration % blacklistErrors.count]
            let shouldFallback = TwoAttemptHandshakeManager.isPQCUnavailableError(error)
            XCTAssertFalse(
                shouldFallback,
                "Blacklist error \(error) should NOT allow fallback at iteration \(iteration)"
            )
        }
    }
    
 /// **Feature: iOS Handshake Entry Alignment, Property 4.2: Fallback Actually Occurs for Whitelist**
 ///
 /// When first attempt fails with whitelist error, second attempt is made.
 ///
 /// **Validates: Requirements 4.3, 4.4, 4.5**
    func testProperty4_2_FallbackOccursForWhitelist() async throws {
        let whitelistErrors: [HandshakeFailureReason] = [
            .pqcProviderUnavailable,
            .suiteNotSupported,
            .suiteNegotiationFailed
        ]
        
        for iteration in 0..<min(Self.minIterations, 30) { // Limit iterations for performance
            let errorToThrow = whitelistErrors[iteration % whitelistErrors.count]
            let tracker = FallbackAttemptTracker()
            
            _ = try await TwoAttemptHandshakeManager.performHandshake(
                deviceId: "test-device-\(iteration)",
                preferPQC: true
            ) { strategy, sigAAlgorithm in
                let count = await tracker.recordAttempt()
                
                if count == 1 {
 // First attempt fails with whitelist error
                    throw HandshakeError.failed(errorToThrow)
                }
                
 // Second attempt succeeds
                return SessionKeys(
                    sendKey: Data(repeating: 0x01, count: 32),
                    receiveKey: Data(repeating: 0x02, count: 32),
                    negotiatedSuite: .x25519Ed25519,
                    role: .initiator,
                    transcriptHash: Data(repeating: 0x03, count: 32)
                )
            }
            
            let finalCount = await tracker.getCount()
            XCTAssertEqual(
                finalCount, 2,
                "Should have 2 attempts for whitelist error \(errorToThrow) at iteration \(iteration)"
            )
        }
    }
    
 /// **Feature: iOS Handshake Entry Alignment, Property 4.3: No Fallback for Blacklist**
 ///
 /// When first attempt fails with blacklist error, no second attempt is made.
 ///
 /// **Validates: Requirements 4.3, 4.4, 4.5**
    func testProperty4_3_NoFallbackForBlacklist() async throws {
        let blacklistErrors: [HandshakeFailureReason] = [
            .timeout,
            .signatureVerificationFailed,
            .keyConfirmationFailed,
            .replayDetected
        ]
        
        for iteration in 0..<min(Self.minIterations, 30) { // Limit iterations for performance
            let errorToThrow = blacklistErrors[iteration % blacklistErrors.count]
            let tracker = FallbackAttemptTracker()
            
            do {
                _ = try await TwoAttemptHandshakeManager.performHandshake(
                    deviceId: "test-device-blacklist-\(iteration)",
                    preferPQC: true
                ) { strategy, sigAAlgorithm in
                    _ = await tracker.recordAttempt()
                    throw HandshakeError.failed(errorToThrow)
                }
                XCTFail("Should have thrown error for blacklist error \(errorToThrow)")
            } catch {
 // Expected
            }
            
            let finalCount = await tracker.getCount()
            XCTAssertEqual(
                finalCount, 1,
                "Should have only 1 attempt for blacklist error \(errorToThrow) at iteration \(iteration)"
            )
        }
    }
}

// MARK: - Helper Actor

/// Thread-safe counter for tracking attempts in concurrent closures
private actor FallbackAttemptTracker {
    private var attemptCount = 0
    
    func recordAttempt() -> Int {
        attemptCount += 1
        return attemptCount
    }
    
    func getCount() -> Int {
        return attemptCount
    }
}
