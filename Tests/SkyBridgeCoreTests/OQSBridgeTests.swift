import XCTest
@testable import SkyBridgeCore

#if canImport(liboqs)
final class OQSBridgeTests: XCTestCase {
    func testMLDSA65SignVerify() async throws {
        let keychain = PQCKeychainTestContext()
        let peer = "test-peer-\(UUID().uuidString)"
        try registerCleanup(
            peerId: peer,
            algorithm: "MLDSA",
            variant: "65",
            keychain: keychain
        )
        let msg = Data("hello-oqs".utf8)
        let result = try await OQSBridge.sign(
            msg,
            peerId: peer,
            algorithm: .mldsa65,
            authority: .staged,
            scopeSource: keychain.scopeSource
        )
        let ok = await OQSBridge.verify(
            msg,
            signature: result.signature,
            publicKey: result.publicKey,
            algorithm: .mldsa65
        )
        XCTAssertTrue(ok)
    }
    func testMLKEM768EncDec() async throws {
        let keychain = PQCKeychainTestContext()
        let peer = "test-peer-\(UUID().uuidString)"
        try registerCleanup(
            peerId: peer,
            algorithm: "MLKEM",
            variant: "768",
            keychain: keychain
        )
        let r = try await OQSBridge.kemEncapsulate(
            peerId: peer,
            algorithm: .mlkem768,
            authority: .staged,
            scopeSource: keychain.scopeSource
        )
        let ss = try await OQSBridge.kemDecapsulate(
            r.encapsulated,
            peerId: peer,
            algorithm: .mlkem768,
            authority: .staged,
            scopeSource: keychain.scopeSource
        )
        XCTAssertEqual(r.shared, ss)

        do {
            _ = try await OQSBridge.kemDecapsulate(
                Data(r.encapsulated.dropLast()),
                peerId: peer,
                algorithm: .mlkem768,
                authority: .staged,
                scopeSource: keychain.scopeSource
            )
            XCTFail("A malformed KEM ciphertext must fail before liboqs")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "PQC")
            XCTAssertEqual(error.code, -322)
        }
    }

    func testSignatureVerificationRejectsMalformedFixedLengths() async throws {
        let keychain = PQCKeychainTestContext()
        let peer = "test-signature-length-\(UUID().uuidString)"
        try registerCleanup(
            peerId: peer,
            algorithm: "MLDSA",
            variant: "65",
            keychain: keychain
        )
        let message = Data("fixed-length-admission".utf8)
        let result = try await OQSBridge.sign(
            message,
            peerId: peer,
            algorithm: .mldsa65,
            authority: .staged,
            scopeSource: keychain.scopeSource
        )

        let shortSignatureAccepted = await OQSBridge.verify(
            message,
            signature: Data(result.signature.dropLast()),
            publicKey: result.publicKey,
            algorithm: .mldsa65
        )
        let shortPublicKeyAccepted = await OQSBridge.verify(
            message,
            signature: result.signature,
            publicKey: Data(result.publicKey.dropLast()),
            algorithm: .mldsa65
        )
        XCTAssertFalse(shortSignatureAccepted)
        XCTAssertFalse(shortPublicKeyAccepted)
    }

    private func registerCleanup(
        peerId: String,
        algorithm: String,
        variant: String,
        keychain: PQCKeychainTestContext
    ) throws {
        let normalizedAlgorithm: String
        let purpose: PQCKeyPairStorePurpose
        switch algorithm {
        case "MLDSA":
            normalizedAlgorithm = "ML-DSA-\(variant)"
            purpose = .signature
        case "MLKEM":
            normalizedAlgorithm = "ML-KEM-\(variant)"
            purpose = .kem
        default:
            throw NSError(
                domain: "OQSBridgeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported cleanup algorithm"]
            )
        }
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: purpose,
            algorithm: normalizedAlgorithm,
            identity: peerId,
            storageScope: keychain.storageScope
        )
        addTeardownBlock {
            try PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            for kind in ["Pub", "Priv"] {
                try KeychainManager.shared.deleteAPIKey(
                    service: PQCKeyTags.service(algorithm, variant, kind),
                    account: peerId,
                    scope: keychain.scope,
                    includeLegacyKeychain: true
                )
            }
        }
    }
}
#endif
