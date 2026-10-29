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

    @Test("PQCSignatureProvider preserves the exact ML-DSA-87 algorithm")
    func testPQCSignatureProviderMLDSA87Algorithm() {
        let provider = PQCSignatureProvider(algorithm: .mlDSA87, backend: .auto)
        #expect(provider.signatureAlgorithm == .mlDSA87)
    }
    
    @Test("P256SePoPProvider can be instantiated")
    func testP256SignatureProviderAlgorithm() {
        let provider = P256SePoPProvider()
        #expect(String(describing: type(of: provider)) == "P256SePoPProvider")
    }
    
 // MARK: - Property: Tier-based Provider Selection
    
    @Test("ProtocolSignatureProviderSelector selects correct provider for tier",
          arguments: [CryptoTier.qperiaptPQC, .nativePQC, .liboqsPQC, .classic])
    func testProviderSelectionByTier(tier: CryptoTier) {
        let provider = ProtocolSignatureProviderSelector.select(for: tier)
        
        switch tier {
        case .qperiaptPQC, .nativePQC, .liboqsPQC:
            #expect(provider.signatureAlgorithm == .mlDSA65,
                   "PQC tier should select ML-DSA-65 provider")
        case .classic:
            #expect(provider.signatureAlgorithm == .ed25519,
                   "Classic tier should select Ed25519 provider")
        }
    }
    
    @Test("ProtocolSignatureProviderSelector selects correct provider for ProtocolSigningAlgorithm",
          arguments: [ProtocolSigningAlgorithm.ed25519, .mlDSA65, .mlDSA87])
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

    @Test("Apple ML-DSA-87 software key signs and verifies with exact lengths")
    func testAppleMLDSA87ProviderRoundTrip() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(macOS 26.0, iOS 26.0, *) else { return }

        let privateKey = try MLDSA87.PrivateKey()
        let provider = PQCSignatureProvider(algorithm: .mlDSA87, backend: .applePQC)
        let message = Data("provider-mldsa87-roundtrip".utf8)
        let signature = try await provider.sign(
            message,
            key: .softwareKey(privateKey.integrityCheckedRepresentation)
        )

        #expect(signature.count == 4_627)
        #expect(privateKey.publicKey.rawRepresentation.count == 2_592)
        #expect(try await provider.verify(
            message,
            signature: signature,
            publicKey: privateKey.publicKey.rawRepresentation
        ))
        #endif
    }

    @Test("OQSBridge verifies an exact ML-DSA-87 Apple signature")
    func testOQSBridgeVerifiesMLDSA87AppleSignature() async throws {
        #if HAS_APPLE_PQC_SDK && canImport(liboqs)
        guard #available(macOS 26.0, iOS 26.0, *) else { return }

        let privateKey = try MLDSA87.PrivateKey()
        let signer = PQCSignatureProvider(algorithm: .mlDSA87, backend: .applePQC)
        let verifier = PQCSignatureProvider(algorithm: .mlDSA87, backend: .oqs)
        let message = Data("provider-mldsa87-apple-oqs".utf8)
        let signature = try await signer.sign(
            message,
            key: .softwareKey(privateKey.integrityCheckedRepresentation)
        )

        #expect(try await verifier.verify(
            message,
            signature: signature,
            publicKey: privateKey.publicKey.rawRepresentation
        ))
        #endif
    }

    @Test("Apple ML-DSA-65 software key keeps its exact provider contract")
    func testAppleMLDSA65ProviderRoundTrip() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(macOS 26.0, iOS 26.0, *) else { return }

        let privateKey = try MLDSA65.PrivateKey()
        let provider = PQCSignatureProvider(algorithm: .mlDSA65, backend: .applePQC)
        let message = Data("provider-mldsa65-roundtrip".utf8)
        let signature = try await provider.sign(
            message,
            key: .softwareKey(privateKey.integrityCheckedRepresentation)
        )

        #expect(signature.count == 3_309)
        #expect(privateKey.publicKey.rawRepresentation.count == 1_952)
        #expect(try await provider.verify(
            message,
            signature: signature,
            publicKey: privateKey.publicKey.rawRepresentation
        ))
        #endif
    }

    @Test("ML-DSA-87 callback output is exact-length checked without fallback")
    func testMLDSA87CallbackOutputIsExactLengthChecked() async throws {
        struct FixedSignatureCallback: SigningCallback {
            let signature: Data

            func sign(data: Data) async throws -> Data {
                signature
            }
        }

        let provider = PQCSignatureProvider(algorithm: .mlDSA87, backend: .auto)
        let message = Data("provider-mldsa87-callback".utf8)
        let validLength = try await provider.sign(
            message,
            key: .callback(FixedSignatureCallback(signature: Data(count: 4_627)))
        )
        #expect(validLength.count == 4_627)

        await #expect(throws: SignatureProviderError.self) {
            _ = try await provider.sign(
                message,
                key: .callback(FixedSignatureCallback(signature: Data(count: 4_626)))
            )
        }
    }

    @Test("ML-DSA-87 callback errors are propagated without backend retry")
    func testMLDSA87CallbackFailureIsNotRetried() async {
        struct CallbackFailure: Error {}
        struct FailingCallback: SigningCallback {
            func sign(data: Data) async throws -> Data {
                throw CallbackFailure()
            }
        }

        let provider = PQCSignatureProvider(algorithm: .mlDSA87, backend: .auto)
        await #expect(throws: CallbackFailure.self) {
            _ = try await provider.sign(
                Data("provider-mldsa87-callback-failure".utf8),
                key: .callback(FailingCallback())
            )
        }
    }

    @Test("ML-DSA-87 OQS raw private key fails explicitly")
    func testMLDSA87OQSRawKeyIsExplicitlyUnavailable() async {
        let provider = PQCSignatureProvider(algorithm: .mlDSA87, backend: .oqs)
        await #expect(throws: SignatureProviderError.self) {
            _ = try await provider.sign(
                Data("provider-mldsa87-oqs".utf8),
                key: .softwareKey(Data(count: 4_896))
            )
        }
    }

    @Test("ML-DSA-87 verify rejects non-exact public key and signature lengths")
    func testMLDSA87VerifyRejectsInvalidLengths() async {
        let provider = PQCSignatureProvider(algorithm: .mlDSA87, backend: .applePQC)

        await #expect(throws: SignatureProviderError.self) {
            _ = try await provider.verify(
                Data("provider-mldsa87-length".utf8),
                signature: Data(count: 4_627),
                publicKey: Data(count: 2_591)
            )
        }
        await #expect(throws: SignatureProviderError.self) {
            _ = try await provider.verify(
                Data("provider-mldsa87-length".utf8),
                signature: Data(count: 4_626),
                publicKey: Data(count: 2_592)
            )
        }
    }

    @Test("Secure Enclave ML-DSA record validation is algorithm exact")
    func testSecureEnclaveMLDSARecordValidationIsAlgorithmExact() throws {
        let record = SecureEnclaveMLDSAIdentityRecord(
            algorithm: .mlDSA87,
            publicKey: Data(repeating: 0x87, count: 2_592),
            opaqueKeyRepresentation: Data(repeating: 0xA5, count: 64)
        )
        #expect(try record.validated(for: .mlDSA87) == record)
        #expect(throws: DeviceIdentityKeyError.self) {
            _ = try record.validated(for: .mlDSA65)
        }

        let truncated = SecureEnclaveMLDSAIdentityRecord(
            algorithm: .mlDSA87,
            publicKey: Data(repeating: 0x87, count: 2_591),
            opaqueKeyRepresentation: Data(repeating: 0xA5, count: 64)
        )
        #expect(throws: DeviceIdentityKeyError.self) {
            _ = try truncated.validated(for: .mlDSA87)
        }
    }

    @Test("Secure Enclave ML-DSA-65 and 87 create restore sign and verify")
    func testSecureEnclaveMLDSAIdentityRoundTrips() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(macOS 26.0, iOS 26.0, *),
              SecureEnclave.isAvailable else { return }

        for algorithm in [ProtocolSigningAlgorithm.mlDSA65, .mlDSA87] {
            let material = try await SecureEnclaveMLDSAIdentityFactory.create(
                algorithm: algorithm
            )
            let restored = try await SecureEnclaveMLDSAIdentityFactory.restore(
                algorithm: algorithm,
                publicKey: material.publicKey,
                opaqueKeyRepresentation: material.opaqueKeyRepresentation
            )
            let message = Data("secure-enclave-protocol-identity-roundtrip".utf8)
            let signature = try await restored.signingCallback.sign(data: message)
            let provider = PQCSignatureProvider(
                algorithm: algorithm,
                backend: .applePQC
            )

            #expect(restored.publicKey == material.publicKey)
            #expect(signature.count == (algorithm == .mlDSA65 ? 3_309 : 4_627))
            #expect(try await provider.verify(
                message,
                signature: signature,
                publicKey: restored.publicKey
            ))
        }
        #endif
    }

    @Test("Secure Enclave ML-DSA restore rejects a substituted public key")
    func testSecureEnclaveMLDSARestoreRejectsSubstitutedPublicKey() async throws {
        #if HAS_APPLE_PQC_SDK
        guard #available(macOS 26.0, iOS 26.0, *),
              SecureEnclave.isAvailable else { return }

        let material = try await SecureEnclaveMLDSAIdentityFactory.create(
            algorithm: .mlDSA87
        )
        var substitutedPublicKey = material.publicKey
        substitutedPublicKey[0] ^= 0x01
        await #expect(throws: SecureEnclaveMLDSAIdentityError.self) {
            _ = try await SecureEnclaveMLDSAIdentityFactory.restore(
                algorithm: .mlDSA87,
                publicKey: substitutedPublicKey,
                opaqueKeyRepresentation: material.opaqueKeyRepresentation
            )
        }
        #endif
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
        
        let provider = P256SePoPProvider()
        
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
        
        let provider = P256SePoPProvider()
        
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
        
        let provider = P256SePoPProvider()
        let data = Data("Test".utf8)
        
 // Invalid key length (should be 32 bytes)
        let invalidKey = Data(repeating: 0, count: 16)
        let keyHandle = SigningKeyHandle.softwareKey(invalidKey)
        
        await #expect(throws: SignatureProviderError.self) {
            _ = try await provider.sign(data, key: keyHandle)
        }
    }
}
