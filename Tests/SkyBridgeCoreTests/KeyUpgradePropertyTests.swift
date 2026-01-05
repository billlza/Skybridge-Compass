//
// KeyUpgradePropertyTests.swift
// SkyBridgeCoreTests
//
// 13.2: Property test for Key Upgrade Security
// **Property 8: Key Upgrade Security (Dual-Signature Binding)**
// **Validates: Requirements 5.4**
//

import XCTest
import CryptoKit
@testable import SkyBridgeCore

/// Property tests for Key Upgrade (Dual-Signature Binding)
///
/// **Property 8: Key Upgrade Security (Dual-Signature Binding)**
/// *For any* key upgrade request from a legacy peer:
/// - The upgrade MUST include dual signatures (old key signs new, new key signs old)
/// - Both signatures MUST verify successfully before updating TrustRecord
/// - The upgrade request MUST be sent within an established encrypted channel
@available(macOS 14.0, iOS 17.0, *)
final class KeyUpgradePropertyTests: XCTestCase {
    
 // MARK: - Helpers
    
 /// Convert P-256 raw representation (64 bytes) to uncompressed format (65 bytes with 0x04 prefix)
    private func toUncompressedP256PublicKey(_ rawRepresentation: Data) -> Data {
        var uncompressed = Data([0x04])
        uncompressed.append(rawRepresentation)
        return uncompressed
    }
    
 // MARK: - Property 8.1: Valid dual signatures pass verification
    
    func testValidDualSignaturesPassVerification() async throws {
 // Generate key pairs
        let oldP256Key = P256.Signing.PrivateKey()
        let newEd25519Key = Curve25519.Signing.PrivateKey()
        
        let oldP256PublicKey = toUncompressedP256PublicKey(oldP256Key.publicKey.rawRepresentation)
        let newEd25519PublicKey = newEd25519Key.publicKey.rawRepresentation
        
 // Create dual signatures
 // Old key signs new public key
        let oldKeySignature = try oldP256Key.signature(for: newEd25519PublicKey)
        
 // New key signs old public key
        let newKeySignature = try newEd25519Key.signature(for: oldP256PublicKey)
        
 // Verify key upgrade
        let result = try await MultiAlgorithmSignatureVerifier.verifyKeyUpgrade(
            oldP256PublicKey: oldP256PublicKey,
            newEd25519PublicKey: newEd25519PublicKey,
            oldKeySignature: oldKeySignature.rawRepresentation,
            newKeySignature: newKeySignature
        )
        
        XCTAssertTrue(result, "Valid dual signatures should pass verification")
    }
    
 // MARK: - Property 8.2: Invalid old key signature fails verification
    
    func testInvalidOldKeySignatureFails() async throws {
 // Generate key pairs
        let oldP256Key = P256.Signing.PrivateKey()
        let newEd25519Key = Curve25519.Signing.PrivateKey()
        let wrongP256Key = P256.Signing.PrivateKey() // Wrong key
        
        let oldP256PublicKey = toUncompressedP256PublicKey(oldP256Key.publicKey.rawRepresentation)
        let newEd25519PublicKey = newEd25519Key.publicKey.rawRepresentation
        
 // Create signatures with wrong old key
        let wrongOldKeySignature = try wrongP256Key.signature(for: newEd25519PublicKey)
        let newKeySignature = try newEd25519Key.signature(for: oldP256PublicKey)
        
 // Verify key upgrade should fail
        do {
            _ = try await MultiAlgorithmSignatureVerifier.verifyKeyUpgrade(
                oldP256PublicKey: oldP256PublicKey,
                newEd25519PublicKey: newEd25519PublicKey,
                oldKeySignature: wrongOldKeySignature.rawRepresentation,
                newKeySignature: newKeySignature
            )
            XCTFail("Should have thrown migrationFailed error")
        } catch let error as SignatureAlignmentError {
            if case .migrationFailed(let reason) = error {
                XCTAssertTrue(reason.contains("Old key"), "Error should mention old key")
            } else {
                XCTFail("Expected migrationFailed error")
            }
        }
    }
    
 // MARK: - Property 8.3: Invalid new key signature fails verification
    
    func testInvalidNewKeySignatureFails() async throws {
 // Generate key pairs
        let oldP256Key = P256.Signing.PrivateKey()
        let newEd25519Key = Curve25519.Signing.PrivateKey()
        let wrongEd25519Key = Curve25519.Signing.PrivateKey() // Wrong key
        
        let oldP256PublicKey = toUncompressedP256PublicKey(oldP256Key.publicKey.rawRepresentation)
        let newEd25519PublicKey = newEd25519Key.publicKey.rawRepresentation
        
 // Create signatures with wrong new key
        let oldKeySignature = try oldP256Key.signature(for: newEd25519PublicKey)
        let wrongNewKeySignature = try wrongEd25519Key.signature(for: oldP256PublicKey)
        
 // Verify key upgrade should fail
        do {
            _ = try await MultiAlgorithmSignatureVerifier.verifyKeyUpgrade(
                oldP256PublicKey: oldP256PublicKey,
                newEd25519PublicKey: newEd25519PublicKey,
                oldKeySignature: oldKeySignature.rawRepresentation,
                newKeySignature: wrongNewKeySignature
            )
            XCTFail("Should have thrown migrationFailed error")
        } catch let error as SignatureAlignmentError {
            if case .migrationFailed(let reason) = error {
                XCTAssertTrue(reason.contains("New key"), "Error should mention new key")
            } else {
                XCTFail("Expected migrationFailed error")
            }
        }
    }
    
 // MARK: - Property 8.4: Swapped signatures fail verification
    
    func testSwappedSignaturesFail() async throws {
 // Generate key pairs
        let oldP256Key = P256.Signing.PrivateKey()
        let newEd25519Key = Curve25519.Signing.PrivateKey()
        
        let oldP256PublicKey = toUncompressedP256PublicKey(oldP256Key.publicKey.rawRepresentation)
        let newEd25519PublicKey = newEd25519Key.publicKey.rawRepresentation
        
 // Create correct signatures
        let oldKeySignature = try oldP256Key.signature(for: newEd25519PublicKey)
        let newKeySignature = try newEd25519Key.signature(for: oldP256PublicKey)
        
 // Swap signatures (should fail)
        do {
            _ = try await MultiAlgorithmSignatureVerifier.verifyKeyUpgrade(
                oldP256PublicKey: oldP256PublicKey,
                newEd25519PublicKey: newEd25519PublicKey,
                oldKeySignature: newKeySignature, // Swapped (Ed25519 sig where P-256 expected)
                newKeySignature: oldKeySignature.rawRepresentation // Swapped (P-256 sig where Ed25519 expected)
            )
            XCTFail("Swapped signatures should fail verification")
        } catch {
 // Expected to fail - either SignatureAlignmentError or other crypto error
 // The important thing is that it fails
        }
    }
    
 // MARK: - Property 8.5: Tampered public key fails verification
    
    func testTamperedPublicKeyFails() async throws {
 // Generate key pairs
        let oldP256Key = P256.Signing.PrivateKey()
        let newEd25519Key = Curve25519.Signing.PrivateKey()
        
        let oldP256PublicKey = toUncompressedP256PublicKey(oldP256Key.publicKey.rawRepresentation)
        let newEd25519PublicKey = newEd25519Key.publicKey.rawRepresentation
        
 // Create valid signatures
        let oldKeySignature = try oldP256Key.signature(for: newEd25519PublicKey)
        let newKeySignature = try newEd25519Key.signature(for: oldP256PublicKey)
        
 // Tamper with new public key
        var tamperedNewPublicKey = newEd25519PublicKey
        tamperedNewPublicKey[0] ^= 0xFF
        
 // Verify with tampered key should fail
        do {
            _ = try await MultiAlgorithmSignatureVerifier.verifyKeyUpgrade(
                oldP256PublicKey: oldP256PublicKey,
                newEd25519PublicKey: tamperedNewPublicKey,
                oldKeySignature: oldKeySignature.rawRepresentation,
                newKeySignature: newKeySignature
            )
            XCTFail("Tampered public key should fail verification")
        } catch {
 // Expected to fail - either SignatureAlignmentError or other crypto error
 // The important thing is that it fails
        }
    }
}
