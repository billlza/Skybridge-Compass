import XCTest
import CryptoKit
import Security
@testable import SkyBridgeCore
import SkyBridgeBenchmarkSupport

@available(macOS 14.0, iOS 17.0, *)
final class HandshakeV2PFSTests: XCTestCase {
    func testKEMIdentityLengthContractCoversBenchmarkProviderEncodings() {
        XCTAssertEqual(
            KEMIdentityKeyLengthContract.resolve(
                suite: .mlkem768MLDSA65,
                providerTier: .nativePQC
            )?.publicKeyLength,
            1_184
        )
        XCTAssertEqual(
            KEMIdentityKeyLengthContract.resolve(
                suite: .mlkem768MLDSA65,
                providerTier: .liboqsPQC
            )?.privateKeyLength,
            2_400
        )
        XCTAssertEqual(
            KEMIdentityKeyLengthContract.resolve(
                suite: .xwingMLDSA,
                providerTier: .nativePQC
            )?.privateKeyLength,
            64
        )
        XCTAssertEqual(
            KEMIdentityKeyLengthContract.resolve(
                suite: .mlkem768MLDSA65FS,
                providerTier: .nativePQC
            )?.privateKeyLength,
            96
        )
        XCTAssertNil(
            KEMIdentityKeyLengthContract.resolve(
                suite: .xwingMLDSA,
                providerTier: .liboqsPQC
            )
        )
    }

    func testBenchmarkKEMStoreMapsV2AliasToCanonicalIdentity() async throws {
        let provider = MockPQCProvider(
            supportedSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65]
        )
        let offeredSuites: [CryptoSuite] = [.mlkem768MLDSA65FS, .mlkem768MLDSA65]
        let store = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: offeredSuites,
            provider: provider
        )

        let publicKeys = try store.trustPublicKeys(for: offeredSuites)
        XCTAssertEqual(publicKeys.count, 2)
        XCTAssertEqual(publicKeys[.mlkem768MLDSA65FS], publicKeys[.mlkem768MLDSA65])

        let v2Identity = try await store.getOrCreateKEMIdentityKey(
            for: .mlkem768MLDSA65FS,
            provider: provider
        )
        let v1Identity = try await store.getOrCreateKEMIdentityKey(
            for: .mlkem768MLDSA65,
            provider: provider
        )
        XCTAssertEqual(v2Identity.publicKey, v1Identity.publicKey)
    }

    func testBenchmarkKEMStoreReturnsIndependentSecureBytes() async throws {
        let provider = MockPQCProvider(supportedSuites: [.mlkem768MLDSA65])
        let store = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: [.mlkem768MLDSA65],
            provider: provider
        )

        let first = try await store.getOrCreateKEMIdentityKey(
            for: .mlkem768MLDSA65,
            provider: provider
        )
        let expectedPrivateKey = first.privateKey.data
        first.privateKey.zeroize()

        let second = try await store.getOrCreateKEMIdentityKey(
            for: .mlkem768MLDSA65,
            provider: provider
        )
        XCTAssertFalse(first.privateKey === second.privateKey)
        XCTAssertEqual(second.privateKey.data, expectedPrivateKey)
    }

    func testV2HandshakeBuildsForwardSecureSession() async throws {
        let initiatorProvider = MockPQCProvider(supportedSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65])
        let responderProvider = MockPQCProvider(supportedSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65])
        let signingProvider = ClassicCryptoProvider()

        let responderKEMStore = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: [.mlkem768MLDSA65],
            provider: responderProvider
        )
        let responderKEMPublicKey = try XCTUnwrap(
            responderKEMStore.trustPublicKeys(for: [.mlkem768MLDSA65])[.mlkem768MLDSA65]
        )

        let initiator = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: initiatorProvider,
            peerKEMPublicKeys: [.mlkem768MLDSA65: responderKEMPublicKey]
        )
        let responder = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: responderProvider,
            kemIdentityStore: responderKEMStore
        )

        let initiatorSigning = try await signingProvider.generateKeyPair(for: .signing)
        let responderSigning = try await signingProvider.generateKeyPair(for: .signing)

        let messageA = try await initiator.buildMessageA(
            identityKeyHandle: .softwareKey(initiatorSigning.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(initiatorSigning.publicKey.bytes, algorithm: .ed25519),
            policy: .default,
            offeredSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65]
        )
        XCTAssertEqual(messageA.supportedSuites.first, .mlkem768MLDSA65FS)
        XCTAssertEqual(messageA.initiatorContribution?.count, 32)

        try await responder.processMessageA(messageA, policy: .default)
        let response = try await responder.buildMessageB(
            identityKeyHandle: .softwareKey(responderSigning.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(responderSigning.publicKey.bytes, algorithm: .ed25519),
            policy: .default
        )
        XCTAssertEqual(response.message.selectedSuite, .mlkem768MLDSA65FS)
        XCTAssertEqual(response.message.responderShare.count, 32)

        let initiatorKeys = try await initiator.processMessageB(response.message, policy: .default)
        let responderKeys = try await responder.finalizeResponderSessionKeys(sharedSecret: response.sharedSecret)

        XCTAssertEqual(initiatorKeys.negotiatedSuite, .mlkem768MLDSA65FS)
        XCTAssertEqual(responderKeys.negotiatedSuite, .mlkem768MLDSA65FS)
        XCTAssertEqual(initiatorKeys.sendKey, responderKeys.receiveKey)
        XCTAssertEqual(initiatorKeys.receiveKey, responderKeys.sendKey)

        await initiator.zeroize()
        await responder.zeroize()
    }

    func testStrictPolicyRejectsClassicDowngradeForV2Offer() async throws {
        let initiatorProvider = MockPQCProvider(supportedSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65])
        let signingProvider = ClassicCryptoProvider()
        let responderKEMStore = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: [.mlkem768MLDSA65],
            provider: initiatorProvider
        )
        let responderKEMPublicKey = try XCTUnwrap(
            responderKEMStore.trustPublicKeys(for: [.mlkem768MLDSA65])[.mlkem768MLDSA65]
        )

        let initiator = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: initiatorProvider,
            peerKEMPublicKeys: [.mlkem768MLDSA65: responderKEMPublicKey]
        )
        let initiatorSigning = try await signingProvider.generateKeyPair(for: .signing)
        _ = try await initiator.buildMessageA(
            identityKeyHandle: .softwareKey(initiatorSigning.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(initiatorSigning.publicKey.bytes, algorithm: .ed25519),
            policy: .strictPQC,
            offeredSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65]
        )

        let responderShare = Data(repeating: 0xA5, count: 32)
        let downgradedMessage = HandshakeMessageB(
            selectedSuite: .x25519Ed25519,
            responderShare: responderShare,
            serverNonce: Data(repeating: 0x5C, count: 32),
            encryptedPayload: HPKESealedBox(
                encapsulatedKey: responderShare,
                nonce: Data(repeating: 0x01, count: 12),
                ciphertext: Data(repeating: 0x02, count: 16),
                tag: Data(repeating: 0x03, count: 16)
            ),
            signature: Data(repeating: 0x11, count: 64),
            identityPublicKey: encodeIdentityPublicKey(Data(repeating: 0x22, count: 32), algorithm: .ed25519)
        )

        do {
            _ = try await initiator.processMessageB(downgradedMessage, policy: .strictPQC)
            XCTFail("Expected strict policy to reject classic downgrade")
        } catch let error as HandshakeError {
            guard case .failed(let reason) = error else {
                XCTFail("Expected HandshakeError.failed")
                await initiator.zeroize()
                return
            }
            XCTAssertEqual(reason, .suiteNegotiationFailed)
        }

        await initiator.zeroize()
    }

    func testV2V1BridgeNegotiatesV1WhenResponderLacksV2() async throws {
        let initiatorProvider = MockPQCProvider(supportedSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65])
        let responderProvider = MockPQCProvider(supportedSuites: [.mlkem768MLDSA65])
        let signingProvider = ClassicCryptoProvider()

        let responderKEMStore = try await BenchmarkHandshakeKEMIdentityStore.make(
            offeredSuites: [.mlkem768MLDSA65],
            provider: responderProvider
        )
        let responderKEMPublicKey = try XCTUnwrap(
            responderKEMStore.trustPublicKeys(for: [.mlkem768MLDSA65])[.mlkem768MLDSA65]
        )

        let initiator = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: initiatorProvider,
            peerKEMPublicKeys: [.mlkem768MLDSA65: responderKEMPublicKey]
        )
        let responder = try await HandshakeContext.create(
            role: .responder,
            cryptoProvider: responderProvider,
            kemIdentityStore: responderKEMStore
        )

        let initiatorSigning = try await signingProvider.generateKeyPair(for: .signing)
        let responderSigning = try await signingProvider.generateKeyPair(for: .signing)

        let messageA = try await initiator.buildMessageA(
            identityKeyHandle: .softwareKey(initiatorSigning.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(initiatorSigning.publicKey.bytes, algorithm: .ed25519),
            policy: .default,
            offeredSuites: [.mlkem768MLDSA65FS, .mlkem768MLDSA65]
        )

        try await responder.processMessageA(messageA, policy: .default)
        let response = try await responder.buildMessageB(
            identityKeyHandle: .softwareKey(responderSigning.privateKey.bytes),
            identityPublicKey: encodeIdentityPublicKey(responderSigning.publicKey.bytes, algorithm: .ed25519),
            policy: .default
        )

        XCTAssertEqual(response.message.selectedSuite, .mlkem768MLDSA65)
        XCTAssertTrue(response.message.responderShare.isEmpty)

        let initiatorKeys = try await initiator.processMessageB(response.message, policy: .default)
        let responderKeys = try await responder.finalizeResponderSessionKeys(sharedSecret: response.sharedSecret)

        XCTAssertEqual(initiatorKeys.negotiatedSuite, .mlkem768MLDSA65)
        XCTAssertEqual(responderKeys.negotiatedSuite, .mlkem768MLDSA65)
        XCTAssertEqual(initiatorKeys.sendKey, responderKeys.receiveKey)
        XCTAssertEqual(initiatorKeys.receiveKey, responderKeys.sendKey)

        await initiator.zeroize()
        await responder.zeroize()
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct MockPQCProvider: CryptoProvider, Sendable {
    let providerName = "MockPQCProvider"
    let tier: CryptoTier = .nativePQC
    let activeSuite: CryptoSuite = .mlkem768MLDSA65
    let supportedSuites: [CryptoSuite]

    init(supportedSuites: [CryptoSuite]) {
        self.supportedSuites = supportedSuites
    }

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        supportedSuites.contains(where: { $0.wireId == suite.wireId })
    }

    func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        throw CryptoProviderError.notImplemented("MockPQCProvider.hpkeSeal")
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        throw CryptoProviderError.notImplemented("MockPQCProvider.hpkeOpen")
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        let privateData: Data
        switch keyHandle {
        case .softwareKey(let data):
            privateData = data
        #if canImport(Security)
        case .secureEnclaveRef:
            throw CryptoProviderError.notImplemented("MockPQCProvider.secureEnclaveRef")
        #endif
        case .callback(let callback):
            return try await callback.sign(data: data)
        }

        guard privateData.count >= 32 else {
            throw CryptoProviderError.invalidKeyLength(
                expected: 32,
                actual: privateData.count,
                suite: activeSuite.rawValue,
                usage: .signing
            )
        }
        let seed = privateData.prefix(32)
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return try privateKey.signature(for: data)
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        return key.isValidSignature(signature, for: data)
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        switch usage {
        case .signing:
            let signingKey = Curve25519.Signing.PrivateKey()
            let publicKey = signingKey.publicKey.rawRepresentation
            var privateBytes = Data(signingKey.rawRepresentation)
            privateBytes.append(publicKey)
            return KeyPair(
                publicKey: KeyMaterial(suite: .x25519Ed25519, usage: .signing, bytes: publicKey),
                privateKey: KeyMaterial(suite: .x25519Ed25519, usage: .signing, bytes: privateBytes)
            )
        case .keyExchange:
            let seed = randomData(count: 32)
            let publicKey = deriveKEMPublicKey(fromSeed: seed)
            var privateKey = Data(seed)
            privateKey.append(Data(repeating: 0, count: 96 - privateKey.count))
            return KeyPair(
                publicKey: KeyMaterial(suite: .mlkem768MLDSA65, usage: .keyExchange, bytes: publicKey),
                privateKey: KeyMaterial(suite: .mlkem768MLDSA65, usage: .keyExchange, bytes: privateKey)
            )
        }
    }

    func kemEncapsulate(recipientPublicKey: Data) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        guard recipientPublicKey.count == 1184 else {
            throw CryptoProviderError.invalidKeyLength(
                expected: 1184,
                actual: recipientPublicKey.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        let encapsulatedKey = randomData(count: 1088)
        var mix = Data()
        mix.append(recipientPublicKey)
        mix.append(encapsulatedKey)
        let shared = Data(SHA256.hash(data: mix))
        return (encapsulatedKey: encapsulatedKey, sharedSecret: SecureBytes(data: shared))
    }

    func kemDecapsulate(encapsulatedKey: Data, privateKey: SecureBytes) async throws -> SecureBytes {
        guard encapsulatedKey.count == 1088 else {
            throw CryptoProviderError.decapsulationFailed("ciphertext length mismatch")
        }
        let privateData = privateKey.copyData()
        guard privateData.count >= 32 else {
            throw CryptoProviderError.invalidKeyLength(
                expected: 32,
                actual: privateData.count,
                suite: activeSuite.rawValue,
                usage: .keyExchange
            )
        }
        let seed = Data(privateData.prefix(32))
        let publicKey = deriveKEMPublicKey(fromSeed: seed)
        var mix = Data()
        mix.append(publicKey)
        mix.append(encapsulatedKey)
        let shared = Data(SHA256.hash(data: mix))
        return SecureBytes(data: shared)
    }

    private func deriveKEMPublicKey(fromSeed seed: Data) -> Data {
        let digest = Data(SHA256.hash(data: seed))
        var publicKey = Data()
        publicKey.reserveCapacity(1184)
        while publicKey.count < 1184 {
            publicKey.append(digest)
        }
        return Data(publicKey.prefix(1184))
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
