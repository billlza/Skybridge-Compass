import XCTest
@testable import SkyBridgeCore

final class OQSProviderSigningTrustBoundaryTests: XCTestCase {
    private let message = Data("authenticated-pqc-signing-boundary".utf8)

    func testMLDSA65LocalKeyIsInstanceScopedUntilAuthenticatedRemoteRegistration() async throws {
        let keychain = PQCKeychainTestContext()
        let signerPeerId = "oqs-signer-65-\(UUID().uuidString)"
        try registerSigningKeyCleanup(
            peerId: signerPeerId,
            variant: "65",
            keychain: keychain
        )

        let signer = OQSProvider(scopeSource: keychain.scopeSource)
        let verifier = OQSProvider(scopeSource: keychain.scopeSource)
        let signature = try await signer.sign(
            data: message,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )

        let signerVerified = await signer.verify(
            data: message,
            signature: signature,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )
        let unrelatedVerified = await verifier.verify(
            data: message,
            signature: signature,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )
        XCTAssertFalse(
            signerVerified,
            "Remote verification must not reflect a local signing key, even in the same provider instance"
        )
        XCTAssertFalse(
            unrelatedVerified,
            "A persisted local public key must not become remote trust in another provider instance"
        )

        let publicKey = try await signer.localSigningPublicKey(
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )
        try await verifier.registerAuthenticatedSigningPublicKey(
            publicKey,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )

        let authenticatedVerified = await verifier.verify(
            data: message,
            signature: signature,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )
        XCTAssertTrue(authenticatedVerified)
        XCTAssertNil(
            KeychainManager.shared.exportKey(
                service: PQCKeyTags.service("MLDSA", "65", "RemotePub"),
                account: signerPeerId
            ),
            "Authenticated remote keys are instance caches rebuilt from the canonical trust store"
        )
    }

    #if canImport(liboqs)
    func testMLDSA87LocalKeyIsInstanceScopedUntilAuthenticatedRemoteRegistration() async throws {
        let keychain = PQCKeychainTestContext()
        let signerPeerId = "oqs-signer-87-\(UUID().uuidString)"
        try registerSigningKeyCleanup(
            peerId: signerPeerId,
            variant: "87",
            keychain: keychain
        )

        let signer = OQSProvider(scopeSource: keychain.scopeSource)
        let verifier = OQSProvider(scopeSource: keychain.scopeSource)
        let signature = try await signer.sign(
            data: message,
            peerId: signerPeerId,
            algorithm: "ML-DSA-87"
        )
        let signerVerified = await signer.verify(
            data: message,
            signature: signature,
            peerId: signerPeerId,
            algorithm: "ML-DSA-87"
        )
        let unrelatedVerified = await verifier.verify(
            data: message,
            signature: signature,
            peerId: signerPeerId,
            algorithm: "ML-DSA-87"
        )
        XCTAssertFalse(signerVerified)
        XCTAssertFalse(unrelatedVerified)

        let publicKey = try await signer.localSigningPublicKey(
            peerId: signerPeerId,
            algorithm: "ML-DSA-87"
        )
        try await verifier.registerAuthenticatedSigningPublicKey(
            publicKey,
            peerId: signerPeerId,
            algorithm: "ML-DSA-87"
        )
        let authenticatedVerified = await verifier.verify(
            data: message,
            signature: signature,
            peerId: signerPeerId,
            algorithm: "ML-DSA-87"
        )
        XCTAssertTrue(authenticatedVerified)
    }
    #endif

    func testAuthenticatedRemoteKeyRegistrationValidatesBeforeCommitAndRejectsReplacement() async throws {
        let keychain = PQCKeychainTestContext()
        let signerPeerId = "oqs-register-\(UUID().uuidString)"
        let replacementPeerId = "oqs-replacement-\(UUID().uuidString)"
        try registerSigningKeyCleanup(
            peerId: signerPeerId,
            variant: "65",
            keychain: keychain
        )
        try registerSigningKeyCleanup(
            peerId: replacementPeerId,
            variant: "65",
            keychain: keychain
        )

        let signer = OQSProvider(scopeSource: keychain.scopeSource)
        let replacementSigner = OQSProvider(scopeSource: keychain.scopeSource)
        let verifier = OQSProvider(scopeSource: keychain.scopeSource)
        let signature = try await signer.sign(
            data: message,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )
        _ = try await replacementSigner.sign(
            data: message,
            peerId: replacementPeerId,
            algorithm: "ML-DSA-65"
        )
        let publicKey = try await signer.localSigningPublicKey(
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )
        let replacementKey = try await replacementSigner.localSigningPublicKey(
            peerId: replacementPeerId,
            algorithm: "ML-DSA-65"
        )

        for malformed in [Data(publicKey.dropLast()), publicKey + Data([0])] {
            do {
                try await verifier.registerAuthenticatedSigningPublicKey(
                    malformed,
                    peerId: signerPeerId,
                    algorithm: "ML-DSA-65"
                )
                XCTFail("Malformed authenticated public keys must be rejected before commit")
            } catch let error as PQCSigningTrustError {
                XCTAssertEqual(
                    error,
                    .invalidPublicKeyLength(
                        algorithm: "ML-DSA-65",
                        expected: 1_952,
                        actual: malformed.count
                    )
                )
            }
        }
        let verifiedBeforeRegistration = await verifier.verify(
            data: message,
            signature: signature,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )
        XCTAssertFalse(verifiedBeforeRegistration)

        try await verifier.registerAuthenticatedSigningPublicKey(
            publicKey,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )
        try await verifier.registerAuthenticatedSigningPublicKey(
            publicKey,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )

        do {
            try await verifier.registerAuthenticatedSigningPublicKey(
                replacementKey,
                peerId: signerPeerId,
                algorithm: "ML-DSA-65"
            )
            XCTFail("Replacing an authenticated key requires a separate trust rotation transaction")
        } catch let error as PQCSigningTrustError {
            XCTAssertEqual(
                error,
                .authenticatedKeyConflict(peerId: signerPeerId, algorithm: "ML-DSA-65")
            )
        }

        let verifiedAfterRejectedReplacement = await verifier.verify(
            data: message,
            signature: signature,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )
        XCTAssertTrue(
            verifiedAfterRejectedReplacement,
            "A rejected replacement must leave the existing authenticated key intact"
        )
    }

    func testCorruptOrIncompleteLocalSigningKeyPairFailsBeforeNativeFFI() async throws {
        let keychain = PQCKeychainTestContext()
        let peerId = "oqs-corrupt-\(UUID().uuidString)"
        try registerSigningKeyCleanup(
            peerId: peerId,
            variant: "65",
            keychain: keychain
        )
        XCTAssertEqual(
            try KeychainManager.shared.insertKeyIfAbsent(
                data: Data(repeating: 0xA5, count: 1_952),
                service: PQCKeyTags.service("MLDSA", "65", "Pub"),
                account: peerId,
                scope: keychain.scope
            ),
            .inserted
        )

        do {
            _ = try await OQSProvider(scopeSource: keychain.scopeSource).sign(
                data: message,
                peerId: peerId,
                algorithm: "ML-DSA-65"
            )
            XCTFail("An incomplete key pair must not be regenerated or passed to native FFI")
        } catch let error as PQCSigningTrustError {
            XCTAssertEqual(
                error,
                .corruptLocalKeyPair(peerId: peerId, algorithm: "ML-DSA-65")
            )
        }
    }

    func testConcurrentProviderCreationConvergesOnOneAtomicSigningIdentity() async throws {
        let keychain = PQCKeychainTestContext()
        let peerId = "oqs-concurrent-\(UUID().uuidString)"
        try registerSigningKeyCleanup(
            peerId: peerId,
            variant: "65",
            keychain: keychain
        )
        let providers = (0..<12).map { _ in
            OQSProvider(scopeSource: keychain.scopeSource)
        }
        let signedMessage = message
        let results = try await withThrowingTaskGroup(
            of: (signature: Data, publicKey: Data).self
        ) { group in
            for provider in providers {
                group.addTask {
                    let signature = try await provider.sign(
                        data: signedMessage,
                        peerId: peerId,
                        algorithm: "ML-DSA-65"
                    )
                    let publicKey = try await provider.localSigningPublicKey(
                        peerId: peerId,
                        algorithm: "ML-DSA-65"
                    )
                    return (signature, publicKey)
                }
            }
            var values: [(signature: Data, publicKey: Data)] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(results.count, providers.count)
        XCTAssertEqual(
            Set(results.map(\.publicKey)),
            Set([try XCTUnwrap(results.first?.publicKey)])
        )

        let verifier = OQSProvider(scopeSource: keychain.scopeSource)
        let canonicalPublicKey = try XCTUnwrap(results.first?.publicKey)
        try await verifier.registerAuthenticatedSigningPublicKey(
            canonicalPublicKey,
            peerId: peerId,
            algorithm: "ML-DSA-65"
        )
        for result in results {
            let isValid = await verifier.verify(
                data: message,
                signature: result.signature,
                peerId: peerId,
                algorithm: "ML-DSA-65"
            )
            XCTAssertTrue(isValid)
        }
    }

    func testExistingAppleCanonicalIdentityBlocksImplicitOQSRotation() async throws {
        let keychain = PQCKeychainTestContext()
        let peerId = "oqs-backend-conflict-\(UUID().uuidString)"
        let authorityDomain = PQCBackendAuthorityDomain.testing(UUID().uuidString)
        let appleDescriptor = PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: peerId,
            authority: .active,
            authorityDomain: authorityDomain,
            storageScope: keychain.storageScope
        )
        let oqsDescriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: peerId,
            authority: .active,
            authorityDomain: authorityDomain,
            storageScope: keychain.storageScope
        )
        addTeardownBlock {
            try PQCKeyPairStore.deleteForTesting(descriptor: appleDescriptor)
            try PQCKeyPairStore.deleteForTesting(descriptor: oqsDescriptor)
            try PQCBackendAuthorityStore.deleteForTesting(
                domain: authorityDomain,
                scopeSource: keychain.scopeSource
            )
        }
        var appleMarker = PQCKeyPairRecord(
            algorithmIdentifier: appleDescriptor.algorithmIdentifier,
            publicKey: Data(repeating: 0x31, count: 1_952),
            privateKey: Data(repeating: 0x42, count: 64)
        )
        defer { PQCKeyPairRecordCodec.wipe(&appleMarker.privateKey) }
        _ = try PQCKeyPairStore.insertIfAbsent(
            appleMarker,
            descriptor: appleDescriptor,
            publicKeyLength: 1_952,
            privateKeyLength: 64,
            validatePair: { _ in }
        )

        let oqsMarker = PQCKeyPairRecord(
            algorithmIdentifier: oqsDescriptor.algorithmIdentifier,
            publicKey: Data(repeating: 0x51, count: 1_952),
            privateKey: Data(repeating: 0x62, count: 64)
        )
        do {
            _ = try PQCKeyPairStore.insertIfAbsent(
                oqsMarker,
                descriptor: oqsDescriptor,
                publicKeyLength: 1_952,
                privateKeyLength: 64,
                validatePair: { _ in }
            )
            XCTFail("A backend change must require an explicit identity migration")
        } catch let error as PQCKeyPairStoreError {
            guard case .conflictingBackendIdentity(
                algorithm: "ML-DSA-65",
                existing: .appleCryptoKit,
                requested: .liboqs
            ) = error else {
                return XCTFail("Unexpected backend-conflict error: \(error)")
            }
        }
    }

    private func registerSigningKeyCleanup(
        peerId: String,
        variant: String,
        keychain: PQCKeychainTestContext
    ) throws {
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: "ML-DSA-\(variant)",
            identity: peerId,
            storageScope: keychain.storageScope
        )
        addTeardownBlock {
            try PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            for kind in ["Pub", "Priv", "RemotePub"] {
                try KeychainManager.shared.deleteAPIKey(
                    service: PQCKeyTags.service("MLDSA", variant, kind),
                    account: peerId,
                    scope: keychain.scope,
                    includeLegacyKeychain: true
                )
            }
        }
    }
}
