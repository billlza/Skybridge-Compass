//
// SignatureProviderPropertyTests.swift
// SkyBridgeCoreTests
//
// Signature Mechanism Alignment - 1.5
// **Property 3: Signature Provider Selection by Algorithm**
// **Validates: Requirements 3.1, 3.2, 3.3**
//

import Testing
import Foundation
import CryptoKit
@testable import SkyBridgeCore

@Suite("Signature Provider Property Tests")
struct SignatureProviderPropertyTests {
    
 // MARK: - Property 3: Signature Provider Selection by Algorithm
    
    @Test("ClassicSignatureProvider uses Ed25519 algorithm")
    func testClassicSignatureProviderAlgorithm() {
        let provider = ClassicSignatureProvider()
        #expect(provider.signatureAlgorithm == .ed25519)
    }
    
    @Test("PQCSignatureProvider uses ML-DSA-65 algorithm")
    func testPQCSignatureProviderAlgorithm() {
        let provider = PQCSignatureProvider(backend: .auto)
        #expect(provider.signatureAlgorithm == .mlDSA65)
    }
    
    @Test("P256ProtocolSignatureProvider uses P-256 ECDSA algorithm")
    func testP256SignatureProviderAlgorithm() {
        let provider = P256ProtocolSignatureProvider()
        #expect(provider.signatureAlgorithm == .p256ECDSA)
    }
    
 // MARK: - Property: Tier-based Provider Selection
    
    @Test("ProtocolSignatureProviderSelector selects correct provider for tier",
          arguments: [CryptoTier.nativePQC, .liboqsPQC, .classic])
    func testProviderSelectionByTier(tier: CryptoTier) {
        let provider = ProtocolSignatureProviderSelector.select(for: tier)
        
        switch tier {
        case .nativePQC, .liboqsPQC:
            #expect(provider.signatureAlgorithm == .mlDSA65,
                   "PQC tier should select ML-DSA-65 provider")
        case .classic:
            #expect(provider.signatureAlgorithm == .ed25519,
                   "Classic tier should select Ed25519 provider")
        }
    }
    
    @Test("ProtocolSignatureProviderSelector selects correct provider for ProtocolSigningAlgorithm",
          arguments: [ProtocolSigningAlgorithm.ed25519, .mlDSA65])
    func testProviderSelectionByAlgorithm(algorithm: ProtocolSigningAlgorithm) {
        let provider = ProtocolSignatureProviderSelector.select(for: algorithm)
        #expect(provider.signatureAlgorithm == algorithm,
               "Selected provider should match requested algorithm")
    }
    
    @Test("ProtocolSignatureProviderSelector.selectProtocolProvider returns nil for P-256")
    func testSelectProtocolProviderReturnsNilForP256() {
        let provider = ProtocolSignatureProviderSelector.selectProtocolProvider(for: .p256ECDSA)
        #expect(provider == nil, "P-256 should not be allowed for protocol signing")
    }
    
 // MARK: - Property: SignatureAlgorithm.forSuite
    
    @Test("SignatureAlgorithm.forSuite returns Ed25519 for Classic suites")
    func testAlgorithmForClassicSuite() {
        let classicSuites: [CryptoSuite] = [.x25519Ed25519, .p256ECDSA]
        
        for suite in classicSuites {
            let algorithm = SignatureAlgorithm.forSuite(suite)
            #expect(algorithm == .ed25519,
                   "Classic suite \(suite.rawValue) should use Ed25519")
        }
    }
    
    @Test("SignatureAlgorithm.forSuite returns ML-DSA-65 for PQC suites")
    func testAlgorithmForPQCSuite() {
        let pqcSuites: [CryptoSuite] = [.xwingMLDSA, .mlkem768MLDSA65]
        
        for suite in pqcSuites {
            let algorithm = SignatureAlgorithm.forSuite(suite)
            #expect(algorithm == .mlDSA65,
                   "PQC suite \(suite.rawValue) should use ML-DSA-65")
        }
    }
    
 // MARK: - Property: Ed25519 Sign/Verify Round Trip
    
    @Test("Ed25519 sign/verify round trip succeeds", arguments: 0..<20)
    func testEd25519RoundTrip(iteration: Int) async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        
        let provider = ClassicSignatureProvider()
        
 // Generate random test data
        let dataSize = Int.random(in: 1...1024)
        var randomData = [UInt8](repeating: 0, count: dataSize)
        _ = SecRandomCopyBytes(kSecRandomDefault, dataSize, &randomData)
        let data = Data(randomData)
        
 // Generate Ed25519 key pair
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
 // Sign
        let keyHandle = SigningKeyHandle.softwareKey(privateKey.rawRepresentation)
        let signature = try await provider.sign(data, key: keyHandle)
        
 // Verify
        let isValid = try await provider.verify(data, signature: signature, publicKey: publicKey.rawRepresentation)
        #expect(isValid, "Ed25519 signature should verify successfully")
    }
    
    @Test("Ed25519 verification fails for tampered data")
    func testEd25519TamperedData() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        
        let provider = ClassicSignatureProvider()
        
        let originalData = Data("Hello, World!".utf8)
        let tamperedData = Data("Hello, World?".utf8)
        
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let keyHandle = SigningKeyHandle.softwareKey(privateKey.rawRepresentation)
        let signature = try await provider.sign(originalData, key: keyHandle)
        
 // Verify with tampered data should fail
        let isValid = try await provider.verify(tamperedData, signature: signature, publicKey: publicKey.rawRepresentation)
        #expect(!isValid, "Ed25519 signature should fail for tampered data")
    }
    
    @Test("Ed25519 verification fails for wrong public key")
    func testEd25519WrongPublicKey() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        
        let provider = ClassicSignatureProvider()
        
        let data = Data("Test message".utf8)
        
        let privateKey1 = Curve25519.Signing.PrivateKey()
        let privateKey2 = Curve25519.Signing.PrivateKey()
        
        let keyHandle = SigningKeyHandle.softwareKey(privateKey1.rawRepresentation)
        let signature = try await provider.sign(data, key: keyHandle)
        
 // Verify with wrong public key should fail
        let isValid = try await provider.verify(data, signature: signature, publicKey: privateKey2.publicKey.rawRepresentation)
        #expect(!isValid, "Ed25519 signature should fail for wrong public key")
    }
    
 // MARK: - Property: P-256 ECDSA Sign/Verify Round Trip
    
    @Test("P-256 ECDSA sign/verify round trip succeeds", arguments: 0..<20)
    func testP256RoundTrip(iteration: Int) async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        
        let provider = P256ProtocolSignatureProvider()
        
 // Generate random test data
        let dataSize = Int.random(in: 1...1024)
        var randomData = [UInt8](repeating: 0, count: dataSize)
        _ = SecRandomCopyBytes(kSecRandomDefault, dataSize, &randomData)
        let data = Data(randomData)
        
 // Generate P-256 key pair
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
 // Sign
        let keyHandle = SigningKeyHandle.softwareKey(privateKey.rawRepresentation)
        let signature = try await provider.sign(data, key: keyHandle)
        
 // Verify
        let isValid = try await provider.verify(data, signature: signature, publicKey: publicKey.x963Representation)
        #expect(isValid, "P-256 ECDSA signature should verify successfully")
    }
    
    @Test("P-256 ECDSA verification fails for tampered data")
    func testP256TamperedData() async throws {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        
        let provider = P256ProtocolSignatureProvider()
        
        let originalData = Data("Hello, World!".utf8)
        let tamperedData = Data("Hello, World?".utf8)
        
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let keyHandle = SigningKeyHandle.softwareKey(privateKey.rawRepresentation)
        let signature = try await provider.sign(originalData, key: keyHandle)
        
 // Verify with tampered data should fail
        let isValid = try await provider.verify(tamperedData, signature: signature, publicKey: publicKey.x963Representation)
        #expect(!isValid, "P-256 ECDSA signature should fail for tampered data")
    }
    
 // MARK: - Property: Invalid Key Handling
    
    @Test("Ed25519 rejects invalid key length")
    func testEd25519InvalidKeyLength() async {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        
        let provider = ClassicSignatureProvider()
        let data = Data("Test".utf8)
        
 // Invalid key length (should be 32 or 64 bytes)
        let invalidKey = Data(repeating: 0, count: 16)
        let keyHandle = SigningKeyHandle.softwareKey(invalidKey)
        
        await #expect(throws: SignatureProviderError.self) {
            _ = try await provider.sign(data, key: keyHandle)
        }
    }
    
    @Test("Ed25519 rejects invalid public key length for verification")
    func testEd25519InvalidPublicKeyLength() async {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        
        let provider = ClassicSignatureProvider()
        let data = Data("Test".utf8)
        let signature = Data(repeating: 0, count: 64)
        
 // Invalid public key length (should be 32 bytes)
        let invalidPublicKey = Data(repeating: 0, count: 16)
        
        await #expect(throws: SignatureProviderError.self) {
            _ = try await provider.verify(data, signature: signature, publicKey: invalidPublicKey)
        }
    }
    
    @Test("Ed25519 rejects invalid signature length")
    func testEd25519InvalidSignatureLength() async {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        
        let provider = ClassicSignatureProvider()
        let data = Data("Test".utf8)
        
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
 // Invalid signature length (should be 64 bytes)
        let invalidSignature = Data(repeating: 0, count: 32)
        
        await #expect(throws: SignatureProviderError.self) {
            _ = try await provider.verify(data, signature: invalidSignature, publicKey: publicKey.rawRepresentation)
        }
    }
    
    @Test("P-256 rejects invalid key length")
    func testP256InvalidKeyLength() async {
        guard #available(macOS 14.0, iOS 17.0, *) else { return }
        
        let provider = P256ProtocolSignatureProvider()
        let data = Data("Test".utf8)
        
 // Invalid key length (should be 32 bytes)
        let invalidKey = Data(repeating: 0, count: 16)
        let keyHandle = SigningKeyHandle.softwareKey(invalidKey)
        
        await #expect(throws: SignatureProviderError.self) {
            _ = try await provider.sign(data, key: keyHandle)
        }
    }
}
