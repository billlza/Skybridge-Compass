import XCTest
@testable import SkyBridgeCore

#if HAS_APPLE_PQC_SDK
import CryptoKit
import OQSRAII

/// Apple原生PQC与OQS兼容性测试
/// 验证两种实现可以互操作
@available(macOS 26.0, *)
final class ApplePQCCompatibilityTests: XCTestCase {

    private struct InjectedXWingReconciliationError: Error {}

    private var originalEnablePQC = false
    private var originalPQCSignatureAlgorithm = ""
    private var keychain: PQCKeychainTestContext!

    override func setUp() async throws {
        keychain = PQCKeychainTestContext()
        try? PQCBackendAuthorityStore.deleteForTesting(
            domain: .quantumAdapter,
            scopeSource: keychain.scopeSource
        )
        (
            originalEnablePQC,
            originalPQCSignatureAlgorithm
        ) = await MainActor.run {
            (
                SettingsManager.shared.enablePQC,
                SettingsManager.shared.pqcSignatureAlgorithm
            )
        }
    }

    override func tearDown() async throws {
        try? PQCBackendAuthorityStore.deleteForTesting(
            domain: .quantumAdapter,
            scopeSource: keychain.scopeSource
        )
        let enablePQC = originalEnablePQC
        let signatureAlgorithm = originalPQCSignatureAlgorithm
        await MainActor.run {
            SettingsManager.shared.enablePQC = enablePQC
            SettingsManager.shared.pqcSignatureAlgorithm = signatureAlgorithm
        }
        keychain = nil
    }
    
    // MARK: - 提供者检测测试
    
    func testProviderSelection() throws {
        let provider = try XCTUnwrap(
            PQCProviderFactory.makeProvider(
                scopeSource: keychain.scopeSource
            ) as? ApplePQCProvider,
            "HAS_APPLE_PQC_SDK on macOS 26+ must select the Apple PQC provider"
        )
        XCTAssertEqual(provider.backend, .applePQC)
        
        let currentProvider = PQCProviderFactory.currentProvider(
            scopeSource: keychain.scopeSource
        )
        XCTAssertEqual(currentProvider, "Apple CryptoKit (原生)", "macOS 26.0+应该使用Apple原生PQC")
        
        print("✅ 当前PQC提供者: \(currentProvider)")
    }

    func testApplePQCRepresentationLengthsMatchPersistenceContracts() throws {
        let mldsa65 = try MLDSA65.PrivateKey()
        XCTAssertEqual(mldsa65.publicKey.rawRepresentation.count, 1_952)
        XCTAssertEqual(mldsa65.integrityCheckedRepresentation.count, 64)

        let mldsa87 = try MLDSA87.PrivateKey()
        XCTAssertEqual(mldsa87.publicKey.rawRepresentation.count, 2_592)
        XCTAssertEqual(mldsa87.integrityCheckedRepresentation.count, 64)

        let mlkem768 = try MLKEM768.PrivateKey()
        XCTAssertEqual(mlkem768.publicKey.rawRepresentation.count, 1_184)
        XCTAssertEqual(mlkem768.integrityCheckedRepresentation.count, 96)

        let mlkem1024 = try MLKEM1024.PrivateKey()
        XCTAssertEqual(mlkem1024.publicKey.rawRepresentation.count, 1_568)
        XCTAssertEqual(mlkem1024.integrityCheckedRepresentation.count, 96)

        let xwing = try XWingMLKEM768X25519.PrivateKey.generate()
        XCTAssertEqual(xwing.publicKey.rawRepresentation.count, 1_216)
        XCTAssertEqual(xwing.integrityCheckedRepresentation.count, 64)
    }
    
 // MARK: - ML-DSA签名兼容性测试
    
    func testMLDSA65Compatibility() async throws {
        let appleProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let testMessage = "兼容性测试消息".utf8Data
        let testPeerId = "apple-compat-test"
        try registerKeyPairCleanup(peerId: testPeerId, algorithm: "MLDSA", variant: "65")
        
 // Apple签名
        let appleSignature = try await appleProvider.sign(
            data: testMessage,
            peerId: testPeerId,
            algorithm: "ML-DSA-65"
        )
        
        XCTAssertGreaterThan(appleSignature.count, 0)
        print("✅ Apple ML-DSA-65签名长度: \(appleSignature.count) 字节")
        
 // 远端验签必须先显式注册经认证的公钥。
        let verifier = ApplePQCProvider(scopeSource: keychain.scopeSource)
        _ = try await authenticateLocalSigningKeyForTesting(
            signer: appleProvider,
            verifier: verifier,
            peerId: testPeerId
        )
        let isValid = await verifier.verify(
            data: testMessage,
            signature: appleSignature,
            peerId: testPeerId,
            algorithm: "ML-DSA-65"
        )
        
        XCTAssertTrue(isValid, "Apple签名应该能自验证")
        print("✅ Apple ML-DSA-65认证公钥验签成功")
    }
    
    func testMLDSA87Compatibility() async throws {
        let appleProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let testMessage = "高安全级别测试".utf8Data
        let testPeerId = "apple-compat-test-87"
        try registerKeyPairCleanup(peerId: testPeerId, algorithm: "MLDSA", variant: "87")
        
        let signature = try await appleProvider.sign(
            data: testMessage,
            peerId: testPeerId,
            algorithm: "ML-DSA-87"
        )
        
        XCTAssertGreaterThan(signature.count, 3000)
        print("✅ Apple ML-DSA-87签名长度: \(signature.count) 字节")
        
        let verifier = ApplePQCProvider(scopeSource: keychain.scopeSource)
        _ = try await authenticateLocalSigningKeyForTesting(
            signer: appleProvider,
            verifier: verifier,
            peerId: testPeerId,
            algorithm: "ML-DSA-87"
        )
        let isValid = await verifier.verify(
            data: testMessage,
            signature: signature,
            peerId: testPeerId,
            algorithm: "ML-DSA-87"
        )
        
        XCTAssertTrue(isValid)
        print("✅ Apple ML-DSA-87认证公钥验签成功")
    }

    func testMLDSA65TrustIsInstanceScopedUntilAuthenticatedRegistration() async throws {
        let signerPeerId = "apple-trust-signer-\(UUID().uuidString)"
        let replacementPeerId = "apple-trust-replacement-\(UUID().uuidString)"
        try registerKeyPairCleanup(peerId: signerPeerId, algorithm: "MLDSA", variant: "65")
        try registerKeyPairCleanup(peerId: replacementPeerId, algorithm: "MLDSA", variant: "65")

        let signer = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let replacementSigner = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let verifier = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let message = Data("apple-authenticated-signing-boundary".utf8)
        let signature = try await signer.sign(
            data: message,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )

        let verifiedBeforeRegistration = await verifier.verify(
            data: message,
            signature: signature,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )
        XCTAssertFalse(
            verifiedBeforeRegistration,
            "Persisted local public keys must not become trust in a different provider instance"
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
        let verifiedAfterRegistration = await verifier.verify(
            data: message,
            signature: signature,
            peerId: signerPeerId,
            algorithm: "ML-DSA-65"
        )
        XCTAssertTrue(verifiedAfterRegistration)

        _ = try await replacementSigner.sign(
            data: message,
            peerId: replacementPeerId,
            algorithm: "ML-DSA-65"
        )
        let replacementKey = try await replacementSigner.localSigningPublicKey(
            peerId: replacementPeerId,
            algorithm: "ML-DSA-65"
        )
        do {
            try await verifier.registerAuthenticatedSigningPublicKey(
                replacementKey,
                peerId: signerPeerId,
                algorithm: "ML-DSA-65"
            )
            XCTFail("Replacing an authenticated signing key requires an explicit trust rotation")
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
            "A rejected replacement must preserve the authenticated key"
        )
    }

    func testConcurrentMLDSA65CreatorsReloadOneAtomicWinner() async throws {
        let scopeSource = keychain.scopeSource
        let peerId = "apple-atomic-winner-\(UUID().uuidString)"
        let message = Data("apple-atomic-winner".utf8)
        try registerKeyPairCleanup(peerId: peerId, algorithm: "MLDSA", variant: "65")

        let results = try await withThrowingTaskGroup(
            of: (signature: Data, publicKey: Data).self,
            returning: [(signature: Data, publicKey: Data)].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    let provider = ApplePQCProvider(scopeSource: scopeSource)
                    let signature = try await provider.sign(
                        data: message,
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
            var collected: [(signature: Data, publicKey: Data)] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        XCTAssertEqual(results.count, 8)
        let winnerPublicKey = try XCTUnwrap(results.first?.publicKey)
        XCTAssertTrue(results.allSatisfy { $0.publicKey == winnerPublicKey })
        let verifier = ApplePQCProvider(scopeSource: scopeSource)
        try await verifier.registerAuthenticatedSigningPublicKey(
            winnerPublicKey,
            peerId: peerId,
            algorithm: "ML-DSA-65"
        )
        for result in results {
            let valid = await verifier.verify(
                data: message,
                signature: result.signature,
                peerId: peerId,
                algorithm: "ML-DSA-65"
            )
            XCTAssertTrue(valid, "Every concurrent creator must sign with the persisted winner")
        }
    }

    func testCompleteLegacyMLDSA65PairMigratesToCanonicalRecord() async throws {
        keychain = PQCKeychainTestContext(includeLegacyUnscoped: true)
        let peerId = "apple-legacy-mldsa65-\(UUID().uuidString)"
        let message = Data("apple-legacy-migration".utf8)
        try registerKeyPairCleanup(peerId: peerId, algorithm: "MLDSA", variant: "65")
        let legacyKey = try MLDSA65.PrivateKey()
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: legacyKey.publicKey.rawRepresentation,
                service: PQCKeyTags.service("MLDSA", "65", "Pub"),
                account: peerId
            )
        )
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: legacyKey.integrityCheckedRepresentation,
                service: PQCKeyTags.service("MLDSA", "65", "Mem"),
                account: peerId
            )
        )

        let migratingProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let firstSignature = try await migratingProvider.sign(
            data: message,
            peerId: peerId,
            algorithm: "ML-DSA-65"
        )
        let migratedPublicKey = try await migratingProvider.localSigningPublicKey(
            peerId: peerId,
            algorithm: "ML-DSA-65"
        )
        XCTAssertEqual(
            migratedPublicKey,
            legacyKey.publicKey.rawRepresentation
        )

        try KeychainManager.shared.deleteAPIKey(
            service: PQCKeyTags.service("MLDSA", "65", "Pub"),
            account: peerId
        )
        try KeychainManager.shared.deleteAPIKey(
            service: PQCKeyTags.service("MLDSA", "65", "Mem"),
            account: peerId
        )

        let reloadedProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let secondSignature = try await reloadedProvider.sign(
            data: message,
            peerId: peerId,
            algorithm: "ML-DSA-65"
        )
        let canonicalPublicKey = try await reloadedProvider.localSigningPublicKey(
            peerId: peerId,
            algorithm: "ML-DSA-65"
        )
        XCTAssertEqual(canonicalPublicKey, legacyKey.publicKey.rawRepresentation)

        let verifier = ApplePQCProvider(scopeSource: keychain.scopeSource)
        try await verifier.registerAuthenticatedSigningPublicKey(
            canonicalPublicKey,
            peerId: peerId,
            algorithm: "ML-DSA-65"
        )
        let firstValid = await verifier.verify(
            data: message,
            signature: firstSignature,
            peerId: peerId,
            algorithm: "ML-DSA-65"
        )
        let secondValid = await verifier.verify(
            data: message,
            signature: secondSignature,
            peerId: peerId,
            algorithm: "ML-DSA-65"
        )
        XCTAssertTrue(firstValid)
        XCTAssertTrue(secondValid)
    }

    func testIncompleteOrMismatchedAppleKeyPairsFailClosed() async throws {
        keychain = PQCKeychainTestContext(includeLegacyUnscoped: true)
        let incompleteSigningPeerId = "apple-incomplete-signing-\(UUID().uuidString)"
        let mismatchedSigningPeerId = "apple-mismatched-signing-\(UUID().uuidString)"
        let incompleteKEMPeerId = "apple-incomplete-kem-\(UUID().uuidString)"
        try registerKeyPairCleanup(peerId: incompleteSigningPeerId, algorithm: "MLDSA", variant: "65")
        try registerKeyPairCleanup(peerId: mismatchedSigningPeerId, algorithm: "MLDSA", variant: "65")
        try registerKeyPairCleanup(peerId: incompleteKEMPeerId, algorithm: "MLKEM", variant: "768")

        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: Data(repeating: 0xA5, count: 1_952),
                service: PQCKeyTags.service("MLDSA", "65", "Pub"),
                account: incompleteSigningPeerId
            )
        )
        do {
            _ = try await ApplePQCProvider(scopeSource: keychain.scopeSource).sign(
                data: Data("incomplete-keypair".utf8),
                peerId: incompleteSigningPeerId,
                algorithm: "ML-DSA-65"
            )
            XCTFail("An incomplete signing key pair must not be regenerated")
        } catch let error as PQCSigningTrustError {
            XCTAssertEqual(
                error,
                .corruptLocalKeyPair(peerId: incompleteSigningPeerId, algorithm: "ML-DSA-65")
            )
        }

        let firstLegacySigningKey = try MLDSA65.PrivateKey()
        let secondLegacySigningKey = try MLDSA65.PrivateKey()
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: firstLegacySigningKey.integrityCheckedRepresentation,
                service: PQCKeyTags.service("MLDSA", "65", "Mem"),
                account: mismatchedSigningPeerId
            )
        )
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: secondLegacySigningKey.publicKey.rawRepresentation,
                service: PQCKeyTags.service("MLDSA", "65", "Pub"),
                account: mismatchedSigningPeerId
            )
        )
        do {
            _ = try await ApplePQCProvider(scopeSource: keychain.scopeSource).sign(
                data: Data("mismatched-keypair".utf8),
                peerId: mismatchedSigningPeerId,
                algorithm: "ML-DSA-65"
            )
            XCTFail("A mismatched persisted public key must not be repaired by silent rotation")
        } catch let error as PQCSigningTrustError {
            XCTAssertEqual(
                error,
                .corruptLocalKeyPair(peerId: mismatchedSigningPeerId, algorithm: "ML-DSA-65")
            )
        }

        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: Data(repeating: 0x11, count: 1_184),
                service: PQCKeyTags.service("MLKEM", "768", "Pub"),
                account: incompleteKEMPeerId
            )
        )
        do {
            _ = try await ApplePQCProvider(
                scopeSource: keychain.scopeSource
            ).kemEncapsulate(
                peerId: incompleteKEMPeerId,
                kemVariant: "ML-KEM-768"
            )
            XCTFail("An incomplete KEM key pair must fail before the CryptoKit operation")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "PQC")
            XCTAssertEqual(error.code, -934)
        }
    }
    
 // MARK: - ML-KEM封装兼容性测试
    
    func testMLKEM768Compatibility() async throws {
        let appleProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let testPeerId = "apple-kem-test"
        try registerKeyPairCleanup(peerId: testPeerId, algorithm: "MLKEM", variant: "768")
        
 // 封装
        let (sharedSecret1, ciphertext) = try await appleProvider.kemEncapsulate(
            peerId: testPeerId,
            kemVariant: "ML-KEM-768"
        )
        
        XCTAssertEqual(sharedSecret1.count, 32, "共享密钥应该是32字节")
        XCTAssertEqual(ciphertext.count, 1088, "ML-KEM-768密文应该是1088字节")
        print("✅ Apple ML-KEM-768封装成功")
        
 // 解封装
        let sharedSecret2 = try await appleProvider.kemDecapsulate(
            peerId: testPeerId,
            encapsulated: ciphertext,
            kemVariant: "ML-KEM-768"
        )
        
        XCTAssertEqual(sharedSecret1, sharedSecret2, "封装和解封装的密钥应该相同")
        print("✅ Apple ML-KEM-768解封装成功")
    }
    
    func testMLKEM1024Compatibility() async throws {
        let appleProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let testPeerId = "apple-kem1024-test"
        try registerKeyPairCleanup(peerId: testPeerId, algorithm: "MLKEM", variant: "1024")
        
        let (sharedSecret1, ciphertext) = try await appleProvider.kemEncapsulate(
            peerId: testPeerId,
            kemVariant: "ML-KEM-1024"
        )
        
        XCTAssertEqual(sharedSecret1.count, 32)
        XCTAssertEqual(ciphertext.count, 1568, "ML-KEM-1024密文应该是1568字节")
        print("✅ Apple ML-KEM-1024封装成功")
        
        let sharedSecret2 = try await appleProvider.kemDecapsulate(
            peerId: testPeerId,
            encapsulated: ciphertext,
            kemVariant: "ML-KEM-1024"
        )
        
        XCTAssertEqual(sharedSecret1, sharedSecret2)
        print("✅ Apple ML-KEM-1024解封装成功")
    }
    
 // MARK: - X-Wing HPKE测试

    func testXWingHPKERequiresAuthenticatedRecipientKey() async throws {
        let appleProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let testPeerId = "xwing-missing-\(UUID().uuidString)"

        do {
            _ = try await appleProvider.hpkeSeal(
                recipientPeerId: testPeerId,
                plaintext: "X-Wing缺少认证公钥测试".utf8Data,
                associatedData: Data("关联数据".utf8)
            )
            XCTFail("X-Wing HPKE seal must require a pre-authenticated recipient public key.")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "PQC")
            XCTAssertEqual(error.code, -918)
            XCTAssertFalse(error.localizedDescription.contains(testPeerId))
        }
    }

    func testXWingHPKEOpenMissingPrivateKeyRedactsPeerIdentifier() async throws {
        let appleProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let testPeerId = "xwing-missing-private-\(UUID().uuidString)"
        let recipientPrivateKey = try XWingMLKEM768X25519.PrivateKey.generate()

        try await appleProvider.setAuthenticatedXWingRecipientPublicKey(recipientPrivateKey.publicKey, for: testPeerId)
        let sealed = try await appleProvider.hpkeSeal(
            recipientPeerId: testPeerId,
            plaintext: "X-Wing缺少私钥测试".utf8Data,
            associatedData: Data("关联数据".utf8)
        )

        do {
            _ = try await appleProvider.hpkeOpen(
                recipientPeerId: "missing-private-\(testPeerId)",
                ciphertext: sealed.ciphertext,
                encapsulatedKey: sealed.encapsulatedKey,
                associatedData: Data("关联数据".utf8)
            )
            XCTFail("X-Wing HPKE open must require local private key material.")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "PQC")
            XCTAssertEqual(error.code, -919)
            XCTAssertFalse(error.localizedDescription.contains(testPeerId))
        }
    }
    
    func testXWingHPKE() async throws {
        let appleProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let testMessage = "X-Wing HPKE测试消息".utf8Data
        let testPeerId = "xwing-test-\(UUID().uuidString)"
        let testAAD = Data("关联数据".utf8)
        let localPrivateKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let remotePrivateKey = try XWingMLKEM768X25519.PrivateKey.generate()
        XCTAssertNotEqual(
            localPrivateKey.publicKey.rawRepresentation,
            remotePrivateKey.publicKey.rawRepresentation
        )
        try registerKeyPairCleanup(peerId: testPeerId, algorithm: "XWing", variant: "768")

        try await appleProvider.setAuthenticatedXWingRecipientPublicKey(
            remotePrivateKey.publicKey,
            for: testPeerId
        )
        let remotePublicKeyBeforeLocalImport = try XCTUnwrap(
            KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingRemotePublic,
                account: testPeerId,
                scope: keychain.scope,
                includeLegacyKeychain: false
            )
        )
        XCTAssertEqual(
            remotePublicKeyBeforeLocalImport,
            remotePrivateKey.publicKey.rawRepresentation
        )
        try await appleProvider.setLocalXWingRecipientPrivateKey(
            localPrivateKey,
            for: testPeerId
        )
        let remotePublicKeyAfterLocalImport = try XCTUnwrap(
            KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingRemotePublic,
                account: testPeerId,
                scope: keychain.scope,
                includeLegacyKeychain: false
            )
        )
        XCTAssertEqual(remotePublicKeyAfterLocalImport, remotePublicKeyBeforeLocalImport)
        XCTAssertNil(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingLegacyPublic,
                account: testPeerId
            )
        )

        let suite = HPKE.Ciphersuite
            .XWingMLKEM768X25519_SHA256_AES_GCM_256
        var inboundSender = try HPKE.Sender(
            recipientKey: localPrivateKey.publicKey,
            ciphersuite: suite,
            info: testAAD
        )
        let inboundCiphertext = try inboundSender.seal(
            testMessage,
            authenticating: testAAD
        )
        let reloadedProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let decrypted = try await reloadedProvider.hpkeOpen(
            recipientPeerId: testPeerId,
            ciphertext: inboundCiphertext,
            encapsulatedKey: inboundSender.encapsulatedKey,
            associatedData: testAAD
        )
        XCTAssertEqual(testMessage, decrypted, "解密后的消息应该与原消息相同")

        for _ in 0..<2 {
            let sealed = try await reloadedProvider.hpkeSeal(
                recipientPeerId: testPeerId,
                plaintext: testMessage,
                associatedData: testAAD
            )
            var remoteRecipient = try HPKE.Recipient(
                privateKey: remotePrivateKey,
                ciphersuite: suite,
                info: testAAD,
                encapsulatedKey: sealed.encapsulatedKey
            )
            XCTAssertEqual(
                try remoteRecipient.open(
                    sealed.ciphertext,
                    authenticating: testAAD
                ),
                testMessage
            )
        }
        XCTAssertEqual(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingRemotePublic,
                account: testPeerId,
                scope: keychain.scope,
                includeLegacyKeychain: false
            ),
            remotePrivateKey.publicKey.rawRepresentation
        )
    }

    func testXWingAuthenticatedRemoteCandidateMigratesMatchingLegacyWithoutLocalRecord() async throws {
        keychain = PQCKeychainTestContext(includeLegacyUnscoped: true)
        let localPeerId = "xwing-local-\(UUID().uuidString)"
        let remotePeerId = "xwing-remote-\(UUID().uuidString)"
        let localPrivateKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let remotePrivateKey = try XWingMLKEM768X25519.PrivateKey.generate()
        try registerKeyPairCleanup(
            peerId: localPeerId,
            algorithm: "XWing",
            variant: "768"
        )
        try registerKeyPairCleanup(
            peerId: remotePeerId,
            algorithm: "XWing",
            variant: "768"
        )
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: remotePrivateKey.publicKey.rawRepresentation,
                service: PQCKeyTags.xWingLegacyPublic,
                account: remotePeerId
            )
        )

        let provider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        try await provider.setAuthenticatedXWingRecipientPublicKey(
            remotePrivateKey.publicKey,
            for: remotePeerId
        )

        XCTAssertEqual(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingRemotePublic,
                account: remotePeerId,
                scope: keychain.scope,
                includeLegacyKeychain: false
            ),
            remotePrivateKey.publicKey.rawRepresentation
        )
        XCTAssertNil(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingLegacyPublic,
                account: remotePeerId
            )
        )
        XCTAssertNil(
            try XWingKeyMaterialStore.loadLocalRecord(
                peerId: remotePeerId,
                authority: .active,
                scopeSource: keychain.scopeSource
            )
        )

        try await provider.setLocalXWingRecipientPrivateKey(
            localPrivateKey,
            for: localPeerId
        )
        let message = Data("remote-first-upgrade".utf8)
        let aad = Data("remote-first-upgrade-aad".utf8)
        let sealed = try await provider.hpkeSeal(
            recipientPeerId: remotePeerId,
            plaintext: message,
            associatedData: aad
        )
        var remoteRecipient = try HPKE.Recipient(
            privateKey: remotePrivateKey,
            ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256,
            info: aad,
            encapsulatedKey: sealed.encapsulatedKey
        )
        XCTAssertEqual(
            try remoteRecipient.open(
                sealed.ciphertext,
                authenticating: aad
            ),
            message
        )
    }

    func testXWingAuthenticatedRemoteCandidateRejectsConflictingLegacyBeforeCanonicalWrite() async throws {
        keychain = PQCKeychainTestContext(includeLegacyUnscoped: true)
        let remotePeerId = "xwing-remote-conflict-\(UUID().uuidString)"
        let legacyRemoteKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let authenticatedRemoteKey = try XWingMLKEM768X25519.PrivateKey.generate()
        try registerKeyPairCleanup(
            peerId: remotePeerId,
            algorithm: "XWing",
            variant: "768"
        )
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: legacyRemoteKey.publicKey.rawRepresentation,
                service: PQCKeyTags.xWingLegacyPublic,
                account: remotePeerId
            )
        )

        let provider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        do {
            try await provider.setAuthenticatedXWingRecipientPublicKey(
                authenticatedRemoteKey.publicKey,
                for: remotePeerId
            )
            XCTFail("A conflicting legacy remote key must block canonical insertion")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "PQC")
            XCTAssertEqual(error.code, -920)
        }

        XCTAssertNil(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingRemotePublic,
                account: remotePeerId,
                scope: keychain.scope,
                includeLegacyKeychain: false
            )
        )
        XCTAssertEqual(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingLegacyPublic,
                account: remotePeerId
            ),
            legacyRemoteKey.publicKey.rawRepresentation
        )
    }

    func testXWingLocalIdentityIsCreateOnly() async throws {
        let peerId = "xwing-create-only-\(UUID().uuidString)"
        let firstKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let replacementKey = try XWingMLKEM768X25519.PrivateKey.generate()
        try registerKeyPairCleanup(peerId: peerId, algorithm: "XWing", variant: "768")

        let provider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        try await provider.setLocalXWingRecipientPrivateKey(firstKey, for: peerId)
        do {
            try await provider.setLocalXWingRecipientPrivateKey(replacementKey, for: peerId)
            XCTFail("Replacing an immutable local X-Wing identity must require explicit rotation")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "PQC")
            XCTAssertEqual(error.code, -921)
        }
    }

    func testXWingPrivateOnlyMigrationRetriesRemainingV2Candidate() throws {
        keychain = PQCKeychainTestContext(includeLegacyUnscoped: true)
        let peerId = "xwing-private-only-retry-\(UUID().uuidString)"
        let privateKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let descriptor = xwingActiveDescriptor(peerId: peerId)
        try registerKeyPairCleanup(peerId: peerId, algorithm: "XWing", variant: "768")
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: privateKey.integrityCheckedRepresentation,
                service: PQCKeyTags.xWingLegacyPrivate,
                account: peerId
            )
        )
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: privateKey.integrityCheckedRepresentation,
                service: PQCKeyTags.xWingV2,
                account: peerId
            )
        )
        try PQCKeyPairStore.installSplitDeletionHookForTesting(
            descriptor: descriptor
        ) {
            throw InjectedXWingReconciliationError()
        }

        XCTAssertThrowsError(
            try XWingKeyMaterialStore.loadLocalRecord(
                peerId: peerId,
                authority: .active,
                scopeSource: keychain.scopeSource
            )
        ) { error in
            XCTAssertTrue(error is InjectedXWingReconciliationError)
        }
        XCTAssertNil(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingLegacyPrivate,
                account: peerId
            )
        )
        XCTAssertEqual(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingV2,
                account: peerId
            ),
            privateKey.integrityCheckedRepresentation
        )

        var reloaded = try XCTUnwrap(
            XWingKeyMaterialStore.loadLocalRecord(
                peerId: peerId,
                authority: .active,
                scopeSource: keychain.scopeSource
            )
        )
        defer { PQCKeyPairRecordCodec.wipe(&reloaded.privateKey) }
        XCTAssertEqual(reloaded.publicKey, privateKey.publicKey.rawRepresentation)
        XCTAssertNil(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingV2,
                account: peerId
            )
        )
    }

    func testXWingStagedMaterialCannotEnterOperationalStore() throws {
        let peerId = "xwing-staged-rejected-\(UUID().uuidString)"
        let privateKey = try XWingMLKEM768X25519.PrivateKey.generate()

        XCTAssertThrowsError(
            try XWingKeyMaterialStore.persistLocalPrivateKey(
                privateKey,
                peerId: peerId,
                authority: .staged,
                scopeSource: keychain.scopeSource
            )
        ) { error in
            XCTAssertEqual(
                error as? XWingKeyMaterialStoreError,
                .stagedMaterialIsNotOperational
            )
        }
        XCTAssertNil(
            try PQCKeyPairStore.load(
                descriptor: xwingActiveDescriptor(peerId: peerId),
                publicKeyLength: XWingKeyMaterialStore.publicKeyLength,
                privateKeyLength: XWingKeyMaterialStore.privateKeyLength,
                validatePair: XWingKeyMaterialStore.validateLocalRecord
            )
        )
    }

    func testXWingInvalidIdentityDoesNotClaimOperationalAuthority() throws {
        defer {
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: .xWingHPKE,
                scopeSource: keychain.scopeSource
            )
        }
        let privateKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let invalidPeerIds = [
            " invalid-xwing-peer ",
            "invalid\0xwing-peer",
            String(repeating: "x", count: 257)
        ]

        for invalidPeerId in invalidPeerIds {
            XCTAssertThrowsError(
                try XWingKeyMaterialStore.loadLocalRecord(
                    peerId: invalidPeerId,
                    authority: .active,
                    scopeSource: keychain.scopeSource
                )
            ) { error in
                XCTAssertEqual(
                    error as? XWingKeyMaterialStoreError,
                    .invalidPeerId
                )
            }
            XCTAssertThrowsError(
                try XWingKeyMaterialStore.persistAuthenticatedRemotePublicKey(
                    privateKey.publicKey,
                    peerId: invalidPeerId,
                    authority: .active,
                    scopeSource: keychain.scopeSource
                )
            )
        }
        XCTAssertNil(
            try PQCBackendAuthorityStore.load(
                domain: .xWingHPKE,
                scopeSource: keychain.scopeSource
            )
        )
    }

    func testActiveXWingAuthorityCoexistsWithActiveLiboqsAdapterAuthority() throws {
        let peerId = "xwing-independent-domain-\(UUID().uuidString)"
        let scopeSource = keychain.scopeSource
        try registerKeyPairCleanup(peerId: peerId, algorithm: "XWing", variant: "768")
        addTeardownBlock {
            try PQCBackendAuthorityStore.deleteForTesting(
                domain: .quantumAdapter,
                scopeSource: scopeSource
            )
            try PQCBackendAuthorityStore.deleteForTesting(
                domain: .xWingHPKE,
                scopeSource: scopeSource
            )
        }
        _ = try PQCBackendAuthorityStore.claim(
            .liboqs,
            domain: .quantumAdapter,
            scopeSource: keychain.scopeSource
        )
        let privateKey = try XWingMLKEM768X25519.PrivateKey.generate()
        var record = try XWingKeyMaterialStore.persistLocalPrivateKey(
            privateKey,
            peerId: peerId,
            authority: .active,
            scopeSource: keychain.scopeSource
        )
        defer { PQCKeyPairRecordCodec.wipe(&record.privateKey) }

        XCTAssertEqual(
            try PQCBackendAuthorityStore.load(
                domain: .quantumAdapter,
                scopeSource: keychain.scopeSource
            ),
            .liboqs
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.load(
                domain: .xWingHPKE,
                scopeSource: keychain.scopeSource
            ),
            .appleCryptoKit
        )
    }

    func testXWingPrivateOnlyMigrationRejectsConflictingNamespaces() throws {
        let peerId = "xwing-private-namespace-conflict-\(UUID().uuidString)"
        let firstKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let secondKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let firstScope = isolatedKeychainScope(
            accessGroup: "group.com.skybridge.tests.xwing.first.\(UUID().uuidString)"
        )
        let secondScope = isolatedKeychainScope(
            accessGroup: "group.com.skybridge.tests.xwing.second.\(UUID().uuidString)"
        )
        let descriptor = xwingActiveDescriptor(peerId: peerId)
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: firstKey.integrityCheckedRepresentation,
            service: PQCKeyTags.xWingLegacyPrivate,
            account: peerId,
            scope: firstScope
        )
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: secondKey.integrityCheckedRepresentation,
            service: PQCKeyTags.xWingLegacyPrivate,
            account: peerId,
            scope: secondScope
        )
        defer {
            try? KeychainManager.shared.deleteAPIKey(
                service: PQCKeyTags.xWingLegacyPrivate,
                account: peerId,
                scope: firstScope,
                includeLegacyKeychain: false
            )
            try? KeychainManager.shared.deleteAPIKey(
                service: PQCKeyTags.xWingLegacyPrivate,
                account: peerId,
                scope: secondScope,
                includeLegacyKeychain: false
            )
            try? PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
        }

        XCTAssertThrowsError(
            try XWingKeyMaterialStore.loadLocalRecord(
                peerId: peerId,
                authority: .active,
                scopeSource: keychain.scopeSource
            )
        ) { error in
            guard let storeError = error as? PQCKeyPairStoreError,
                  case .conflictingLegacyKeyPair = storeError else {
                return XCTFail("Expected conflictingLegacyKeyPair, got \(error)")
            }
        }
        XCTAssertNil(
            try PQCKeyPairStore.load(
                descriptor: descriptor,
                publicKeyLength: XWingKeyMaterialStore.publicKeyLength,
                privateKeyLength: XWingKeyMaterialStore.privateKeyLength,
                validatePair: XWingKeyMaterialStore.validateLocalRecord
            )
        )
    }

    func testXWingLegacyRemoteCandidatesMustAgreeBeforeMigration() async throws {
        keychain = PQCKeychainTestContext(includeLegacyUnscoped: true)
        let peerId = "xwing-remote-conflict-\(UUID().uuidString)"
        let localKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let firstRemoteKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let secondRemoteKey = try XWingMLKEM768X25519.PrivateKey.generate()
        try registerKeyPairCleanup(peerId: peerId, algorithm: "XWing", variant: "768")
        let provider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        try await provider.setLocalXWingRecipientPrivateKey(localKey, for: peerId)
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: firstRemoteKey.publicKey.rawRepresentation,
                service: PQCKeyTags.xWingLegacyPublic,
                account: peerId
            )
        )
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: secondRemoteKey.publicKey.rawRepresentation,
                service: PQCKeyTags.xWingV2,
                account: peerId
            )
        )

        do {
            _ = try await provider.hpkeSeal(
                recipientPeerId: peerId,
                plaintext: Data("remote-conflict".utf8),
                associatedData: Data("remote-conflict-aad".utf8)
            )
            XCTFail("Conflicting legacy remote keys must fail closed")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "PQC")
            XCTAssertEqual(error.code, -918)
        }
        XCTAssertNil(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingRemotePublic,
                account: peerId,
                scope: keychain.scope,
                includeLegacyKeychain: false
            )
        )
        XCTAssertEqual(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingLegacyPublic,
                account: peerId
            ),
            firstRemoteKey.publicKey.rawRepresentation
        )
        XCTAssertEqual(
            try KeychainManager.shared.exportKeyStrict(
                service: PQCKeyTags.xWingV2,
                account: peerId
            ),
            secondRemoteKey.publicKey.rawRepresentation
        )
    }
    
 // MARK: - Runtime truth
    
    func testMLDSARuntimeDoesNotExposeUnimplementedSecureEnclaveSetting() async throws {
        let appleProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let testMessage = "software-backed-ML-DSA-test".utf8Data
        let testPeerId = "software-mldsa-\(UUID().uuidString)"
        try registerKeyPairCleanup(peerId: testPeerId, algorithm: "MLDSA", variant: "65")
        
        let signature = try await appleProvider.sign(
            data: testMessage,
            peerId: testPeerId,
            algorithm: "ML-DSA-65"
        )
        
        XCTAssertGreaterThan(signature.count, 0)
        XCTAssertEqual(signature.count, 3_309)

        let settingsSource = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/SkyBridgeCore/Settings/SettingsManager.swift"),
            encoding: .utf8
        )
        let viewSource = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/SkyBridgeCore/Views/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(settingsSource.contains("useSecureEnclaveMLDSA"))
        XCTAssertFalse(viewSource.contains("useSecureEnclaveMLDSA"))
        XCTAssertFalse(settingsSource.contains("useSecureEnclaveMLKEM"))
        XCTAssertFalse(viewSource.contains("useSecureEnclaveMLKEM"))
    }
    
 // MARK: - 性能对比测试
    
    func testAppleVsOQSPerformance() async throws {
        #if canImport(OQSRAII)
        let applePeerId = "perf-test-apple-\(UUID().uuidString)"
        let oqsPeerId = "perf-test-oqs-\(UUID().uuidString)"
        try registerKeyPairCleanup(
            peerId: applePeerId,
            algorithm: "MLDSA",
            variant: "65"
        )
        try registerKeyPairCleanup(
            peerId: oqsPeerId,
            backend: .liboqs,
            algorithm: "MLDSA",
            variant: "65"
        )
        let appleProvider = ApplePQCProvider(scopeSource: keychain.scopeSource)
        let oqsProvider = OQSProvider(scopeSource: keychain.scopeSource)
        let testMessage = "性能对比测试".utf8Data
        
 // Apple性能
        let appleStart = Date()
        _ = try await appleProvider.sign(
            data: testMessage,
            peerId: applePeerId,
            algorithm: "ML-DSA-65"
        )
        let appleTime = Date().timeIntervalSince(appleStart)
        
 // OQS性能
        let oqsStart = Date()
        _ = try await oqsProvider.sign(
            data: testMessage,
            peerId: oqsPeerId,
            algorithm: "ML-DSA-65"
        )
        let oqsTime = Date().timeIntervalSince(oqsStart)
        
        print("📊 性能对比 (ML-DSA-65签名):")
        print("   Apple: \(String(format: "%.3f", appleTime * 1000)) ms")
        print("   OQS:   \(String(format: "%.3f", oqsTime * 1000)) ms")
        print("   提升:  \(String(format: "%.1f", (oqsTime / appleTime - 1) * 100))%")
        
 // Apple应该更快（但这不是硬性要求，因为可能受系统负载影响）
        if appleTime < oqsTime {
            print("✅ Apple实现更快")
        }
        #else
        throw XCTSkip("OQSRAII is not compiled into this test target")
        #endif
    }
    
 // MARK: - 混合签名集成测试
    
    func testHybridSignatureWithApple() async throws {
        _ = try XCTUnwrap(
            PQCProviderFactory.makeProvider(
                scopeSource: keychain.scopeSource
            ) as? ApplePQCProvider,
            "HAS_APPLE_PQC_SDK on macOS 26+ must select the Apple PQC provider"
        )
        
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }
        
        let identityNamespace = "apple-hybrid-identity-\(UUID().uuidString)"
        let identityAccessGroup = "group.com.skybridge.tests.device-identity.\(identityNamespace)"
        let identityScope = KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: identityAccessGroup,
            readAccessGroups: [identityAccessGroup],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
        try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: identityNamespace)
        addTeardownBlock {
            try DeviceIdentityKeyManager.testingResetMLDSAStorage(namespace: identityNamespace)
        }
        let identityManager = DeviceIdentityKeyManager(
            testingStorageNamespace: identityNamespace,
            keychainScope: identityScope
        )
        let crypto = EnhancedPostQuantumCrypto(
            deviceIdentityKeyManager: identityManager
        )
        let testMessage = "混合签名测试".utf8Data
        let testPeerId = "hybrid-test-\(UUID().uuidString)"
        try registerKeyPairCleanup(
            peerId: testPeerId,
            algorithm: "MLDSA",
            variant: "65"
        )
        let protocolPublicKey = try await identityManager.getProtocolSigningPublicKey(
            for: .mlDSA65
        )
        let trust = try await installAuthenticatedMLDSATrustRecordForTesting(
            peerId: testPeerId,
            publicKey: protocolPublicKey
        )
        addTeardownBlock { @MainActor in
            await trust.removeRecordsForTesting(deviceIds: [testPeerId])
            trust.endInMemoryPersistenceForTesting()
        }
        
 // 混合签名（P256 + ML-DSA）
        let (classical, pqc) = try await crypto.hybridSign(testMessage, for: testPeerId)
        
        XCTAssertGreaterThan(classical.count, 0)
        XCTAssertNotNil(pqc)
        print("✅ 混合签名成功 (Apple PQC)")
        print("   P256签名: \(classical.count) 字节")
        print("   ML-DSA签名: \(pqc?.count ?? 0) 字节")
        
 // 验证
        let isValid = try await crypto.verifyHybrid(
            testMessage,
            classicalSignature: classical,
            pqcSignature: pqc,
            peerId: testPeerId
        )
        
        XCTAssertTrue(isValid)
        print("✅ 混合签名验证成功")
    }
    
 // MARK: - 密钥迁移测试
    
    func testAppleRekeyStagingPersistsCanonicalWinnerAndPreservesOQS() async throws {
        keychain = PQCKeychainTestContext(includeLegacyUnscoped: true)
        let testPeerId = "apple-rekey-staging-\(UUID().uuidString)"
        let descriptor = appleStagingDescriptor(peerId: testPeerId)
        let sourceDescriptor = oqsActiveDescriptor(peerId: testPeerId)
        var oqsKeyPair = try makeOQSMLDSA65KeyPair()
        defer { PQCKeyPairRecordCodec.wipe(&oqsKeyPair.privateKey) }
        let oqsPublicService = PQCKeyTags.service("MLDSA", "65", "Pub")
        let oqsPrivateService = PQCKeyTags.service("MLDSA", "65", "Priv")
        try PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
        try PQCKeyPairStore.deleteForTesting(descriptor: sourceDescriptor)
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: oqsKeyPair.publicKey,
                service: oqsPublicService,
                account: testPeerId
            )
        )
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: oqsKeyPair.privateKey,
                service: oqsPrivateService,
                account: testPeerId
            )
        )
        addTeardownBlock {
            try PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            try PQCKeyPairStore.deleteForTesting(descriptor: sourceDescriptor)
            try KeychainManager.shared.deleteAPIKey(
                service: oqsPublicService,
                account: testPeerId
            )
            try KeychainManager.shared.deleteAPIKey(
                service: oqsPrivateService,
                account: testPeerId
            )
        }

        let stagedNotification = expectation(description: "verified Apple re-key staging notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .pqcAppleRekeyStaged,
            object: nil,
            queue: nil
        ) { notification in
            guard notification.userInfo?["peerId"] as? String == testPeerId else { return }
            XCTAssertEqual(notification.userInfo?["algorithm"] as? String, "ML-DSA-65")
            XCTAssertEqual(notification.userInfo?["requiresRePinning"] as? Bool, true)
            XCTAssertEqual(notification.userInfo?["destinationState"] as? String, "staged")
            XCTAssertEqual(notification.userInfo?["activeBackendChanged"] as? Bool, false)
            XCTAssertNotNil(notification.userInfo?["sourcePublicKeyFingerprint"] as? String)
            XCTAssertNotNil(notification.userInfo?["destinationPublicKeyFingerprint"] as? String)
            stagedNotification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await PQCAppleRekeyStaging.stageAppleRekey(
            peerId: testPeerId,
            algorithm: "ML-DSA-65",
            scopeSource: keychain.scopeSource
        )

        await fulfillment(of: [stagedNotification], timeout: 1)
        try await PQCAppleRekeyStaging.validateStagedAppleRekey(
            peerId: testPeerId,
            algorithm: "ML-DSA-65",
            scopeSource: keychain.scopeSource
        )
        XCTAssertNil(
            try KeychainManager.shared.exportKeyStrict(
                service: oqsPublicService,
                account: testPeerId
            )
        )
        XCTAssertNil(
            try KeychainManager.shared.exportKeyStrict(
                service: oqsPrivateService,
                account: testPeerId
            )
        )
        var canonicalSource = try XCTUnwrap(
            PQCKeyPairStore.load(
                descriptor: sourceDescriptor,
                publicKeyLength: oqsKeyPair.publicKey.count,
                privateKeyLength: oqsKeyPair.privateKey.count,
                validatePair: { _ in }
            )
        )
        defer { PQCKeyPairRecordCodec.wipe(&canonicalSource.privateKey) }
        XCTAssertEqual(canonicalSource.publicKey, oqsKeyPair.publicKey)
        XCTAssertEqual(canonicalSource.privateKey, oqsKeyPair.privateKey)
    }

    func testAppleRekeyStagingAcceptsValidatedCanonicalOQSSource() async throws {
        let testPeerId = "apple-rekey-canonical-source-\(UUID().uuidString)"
        let appleDescriptor = appleStagingDescriptor(peerId: testPeerId)
        let oqsDescriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: testPeerId,
            authority: .active,
            storageScope: keychain.storageScope
        )
        let activeAppleDescriptor = PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: testPeerId,
            authority: .active,
            storageScope: keychain.storageScope
        )
        var oqsKeyPair = try makeOQSMLDSA65KeyPair()
        defer { PQCKeyPairRecordCodec.wipe(&oqsKeyPair.privateKey) }
        var sourceRecord = PQCKeyPairRecord(
            algorithmIdentifier: oqsDescriptor.algorithmIdentifier,
            publicKey: oqsKeyPair.publicKey,
            privateKey: oqsKeyPair.privateKey
        )
        defer { PQCKeyPairRecordCodec.wipe(&sourceRecord.privateKey) }
        try PQCKeyPairStore.deleteForTesting(descriptor: appleDescriptor)
        try PQCKeyPairStore.deleteForTesting(descriptor: oqsDescriptor)
        var persistedSource = try PQCKeyPairStore.insertIfAbsent(
            sourceRecord,
            descriptor: oqsDescriptor,
            publicKeyLength: oqsKeyPair.publicKey.count,
            privateKeyLength: oqsKeyPair.privateKey.count,
            validatePair: { _ in }
        )
        defer { PQCKeyPairRecordCodec.wipe(&persistedSource.privateKey) }
        XCTAssertEqual(
            try PQCBackendAuthorityStore.load(
                scopeSource: keychain.scopeSource
            ),
            .liboqs,
            "Persisting the active OQS source must establish liboqs authority"
        )
        XCTAssertNil(
            try PQCKeyPairStore.load(
                descriptor: appleDescriptor,
                publicKeyLength: 1_952,
                privateKeyLength: 64,
                validatePair: { _ in }
            )
        )
        addTeardownBlock {
            try PQCKeyPairStore.deleteForTesting(descriptor: appleDescriptor)
            try PQCKeyPairStore.deleteForTesting(descriptor: oqsDescriptor)
        }

        try await PQCAppleRekeyStaging.stageAppleRekey(
            peerId: testPeerId,
            algorithm: "ML-DSA-65",
            scopeSource: keychain.scopeSource
        )

        try await PQCAppleRekeyStaging.validateStagedAppleRekey(
            peerId: testPeerId,
            algorithm: "ML-DSA-65",
            scopeSource: keychain.scopeSource
        )
        var reloadedSource = try XCTUnwrap(
            PQCKeyPairStore.load(
                descriptor: oqsDescriptor,
                publicKeyLength: oqsKeyPair.publicKey.count,
                privateKeyLength: oqsKeyPair.privateKey.count,
                validatePair: { _ in }
            )
        )
        defer { PQCKeyPairRecordCodec.wipe(&reloadedSource.privateKey) }
        XCTAssertEqual(reloadedSource.publicKey, oqsKeyPair.publicKey)
        XCTAssertEqual(
            try PQCBackendAuthorityStore.installedKeyMaterialEvidence(
                scopeSource: keychain.scopeSource
            ),
            .liboqs,
            "The staged Apple destination must remain outside active backend evidence"
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.load(
                scopeSource: keychain.scopeSource
            ),
            .liboqs
        )
        XCTAssertNil(
            try PQCKeyPairStore.load(
                descriptor: activeAppleDescriptor,
                publicKeyLength: 1_952,
                privateKeyLength: 64,
                validatePair: { _ in }
            ),
            "The staged Apple record must not appear in the active Apple namespace"
        )
        var stagedApple = try XCTUnwrap(
            PQCKeyPairStore.load(
                descriptor: appleDescriptor,
                publicKeyLength: 1_952,
                privateKeyLength: 64,
                validatePair: { _ in }
            )
        )
        PQCKeyPairRecordCodec.wipe(&stagedApple.privateKey)
    }

    func testAppleRekeyStagingRejectsMismatchedOQSSourceWithoutPersistingAppleKey() async throws {
        keychain = PQCKeychainTestContext(includeLegacyUnscoped: true)
        let testPeerId = "apple-rekey-invalid-source-\(UUID().uuidString)"
        let descriptor = appleStagingDescriptor(peerId: testPeerId)
        let oqsPublicService = PQCKeyTags.service("MLDSA", "65", "Pub")
        let oqsPrivateService = PQCKeyTags.service("MLDSA", "65", "Priv")
        var firstKeyPair = try makeOQSMLDSA65KeyPair()
        var secondKeyPair = try makeOQSMLDSA65KeyPair()
        defer {
            PQCKeyPairRecordCodec.wipe(&firstKeyPair.privateKey)
            PQCKeyPairRecordCodec.wipe(&secondKeyPair.privateKey)
        }
        try PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: firstKeyPair.publicKey,
                service: oqsPublicService,
                account: testPeerId
            )
        )
        XCTAssertTrue(
            KeychainManager.shared.importKey(
                data: secondKeyPair.privateKey,
                service: oqsPrivateService,
                account: testPeerId
            )
        )
        addTeardownBlock {
            try PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            try KeychainManager.shared.deleteAPIKey(
                service: oqsPublicService,
                account: testPeerId
            )
            try KeychainManager.shared.deleteAPIKey(
                service: oqsPrivateService,
                account: testPeerId
            )
        }

        do {
            try await PQCAppleRekeyStaging.stageAppleRekey(
                peerId: testPeerId,
                algorithm: "ML-DSA-65",
                scopeSource: keychain.scopeSource
            )
            XCTFail("Mismatched OQS source keys must be rejected")
        } catch let error as PQCAppleRekeyStaging.StagingError {
            XCTAssertEqual(error, .invalidSourceKeyPair)
        }

        let persistedAppleRecord = try PQCKeyPairStore.load(
            descriptor: descriptor,
            publicKeyLength: 1_952,
            privateKeyLength: 64,
            validatePair: { _ in }
        )
        XCTAssertNil(persistedAppleRecord)
    }

    func testAppleRekeyStagingDoesNotJoinOQSHalvesAcrossNamespaces() async throws {
        let peerId = "apple-rekey-cross-namespace-\(UUID().uuidString)"
        let appleDescriptor = appleStagingDescriptor(peerId: peerId)
        let oqsDescriptor = oqsActiveDescriptor(peerId: peerId)
        var keyPair = try makeOQSMLDSA65KeyPair()
        defer { PQCKeyPairRecordCodec.wipe(&keyPair.privateKey) }
        let publicScope = isolatedKeychainScope(
            accessGroup: "group.com.skybridge.tests.oqs.public.\(UUID().uuidString)"
        )
        let privateScope = isolatedKeychainScope(
            accessGroup: "group.com.skybridge.tests.oqs.private.\(UUID().uuidString)"
        )
        let publicService = PQCKeyTags.service("MLDSA", "65", "Pub")
        let privateService = PQCKeyTags.service("MLDSA", "65", "Priv")
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: keyPair.publicKey,
            service: publicService,
            account: peerId,
            scope: publicScope
        )
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: keyPair.privateKey,
            service: privateService,
            account: peerId,
            scope: privateScope
        )
        defer {
            try? KeychainManager.shared.deleteAPIKey(
                service: publicService,
                account: peerId,
                scope: publicScope,
                includeLegacyKeychain: false
            )
            try? KeychainManager.shared.deleteAPIKey(
                service: privateService,
                account: peerId,
                scope: privateScope,
                includeLegacyKeychain: false
            )
            try? PQCKeyPairStore.deleteForTesting(descriptor: oqsDescriptor)
            try? PQCKeyPairStore.deleteForTesting(descriptor: appleDescriptor)
        }

        do {
            try await PQCAppleRekeyStaging.stageAppleRekey(
                peerId: peerId,
                algorithm: "ML-DSA-65",
                scopeSource: keychain.scopeSource
            )
            XCTFail("OQS halves in different namespaces must not be joined")
        } catch let error as PQCAppleRekeyStaging.StagingError {
            XCTAssertEqual(error, .incompleteSourceKeyPair)
        }
        XCTAssertNil(
            try PQCKeyPairStore.load(
                descriptor: oqsDescriptor,
                publicKeyLength: keyPair.publicKey.count,
                privateKeyLength: keyPair.privateKey.count,
                validatePair: { _ in }
            )
        )
        XCTAssertNil(
            try PQCKeyPairStore.load(
                descriptor: appleDescriptor,
                publicKeyLength: 1_952,
                privateKeyLength: 64,
                validatePair: { _ in }
            )
        )
    }

    func testAppleRekeyStagingRejectsNonProductionMLDSA87() async throws {
        do {
            try await PQCAppleRekeyStaging.stageAppleRekey(
                peerId: "apple-rekey-unsupported-\(UUID().uuidString)",
                algorithm: "ML-DSA-87",
                scopeSource: keychain.scopeSource
            )
            XCTFail("ML-DSA-87 is not a production migration algorithm")
        } catch let error as PQCAppleRekeyStaging.StagingError {
            guard case .unsupportedAlgorithm(let algorithm) = error else {
                return XCTFail("Expected unsupportedAlgorithm, got \(error)")
            }
            XCTAssertEqual(algorithm, "ML-DSA-87")
        }
    }

    private func appleStagingDescriptor(peerId: String) -> PQCKeyPairStoreDescriptor {
        PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: peerId,
            authority: .staged,
            storageScope: keychain.storageScope
        )
    }

    private func xwingActiveDescriptor(peerId: String) -> PQCKeyPairStoreDescriptor {
        XWingKeyMaterialStore.descriptor(
            peerId: peerId,
            authority: .active,
            scopeSource: keychain.scopeSource
        )
    }

    private func isolatedKeychainScope(
        accessGroup: String
    ) -> KeychainGenericPasswordScope {
        KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: [accessGroup],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
    }

    private func oqsActiveDescriptor(peerId: String) -> PQCKeyPairStoreDescriptor {
        PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: peerId,
            authority: .active,
            storageScope: keychain.storageScope
        )
    }

    private func makeOQSMLDSA65KeyPair() throws -> (publicKey: Data, privateKey: Data) {
        let publicKeyLength = Int(oqs_raii_mldsa65_public_key_length())
        let privateKeyLength = Int(oqs_raii_mldsa65_secret_key_length())
        var publicKey = [UInt8](repeating: 0, count: publicKeyLength)
        var privateKey = [UInt8](repeating: 0, count: privateKeyLength)
        defer { PQCKeyPairRecordCodec.wipe(&privateKey) }
        guard publicKeyLength > 0,
              privateKeyLength > 0,
              oqs_raii_mldsa65_keypair(
                  &publicKey,
                  publicKeyLength,
                  &privateKey,
                  privateKeyLength
              ) == OQSRAII_SUCCESS else {
            throw PQCAppleRekeyStaging.StagingError.invalidSourceKeyPair
        }
        return (Data(publicKey), Data(privateKey))
    }

    private func registerKeyPairCleanup(
        peerId: String,
        backend: PQCKeyPairStoreBackend = .appleCryptoKit,
        algorithm: String,
        variant: String
    ) throws {
        let keychainScope = keychain.scope
        let descriptor: PQCKeyPairStoreDescriptor
        switch algorithm {
        case "MLDSA":
            descriptor = PQCKeyPairStoreDescriptor(
                backend: backend,
                purpose: .signature,
                algorithm: "ML-DSA-\(variant)",
                identity: peerId,
                authority: .staged,
                storageScope: keychain.storageScope
            )
        case "MLKEM":
            descriptor = PQCKeyPairStoreDescriptor(
                backend: backend,
                purpose: .kem,
                algorithm: "ML-KEM-\(variant)",
                identity: peerId,
                authority: .staged,
                storageScope: keychain.storageScope
            )
        case "XWing":
            descriptor = XWingKeyMaterialStore.descriptor(
                peerId: peerId,
                authority: .active,
                scopeSource: keychain.scopeSource
            )
        default:
            throw NSError(
                domain: "ApplePQCCompatibilityTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported cleanup algorithm: \(algorithm)"]
            )
        }
        addTeardownBlock {
            try PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            for kind in ["Pub", "Mem", "Priv", "RemotePub"] {
                try KeychainManager.shared.deleteAPIKey(
                    service: PQCKeyTags.service(algorithm, variant, kind),
                    account: peerId
                )
            }
            if algorithm == "XWing" {
                try KeychainManager.shared.deleteAPIKey(
                    service: PQCKeyTags.xWingV2,
                    account: peerId
                )
                try KeychainManager.shared.deleteAPIKey(
                    service: PQCKeyTags.xWingRemotePublic,
                    account: peerId,
                    scope: keychainScope,
                    includeLegacyKeychain: true
                )
            }
        }
    }
}
#else
@available(macOS 14.0, *)
final class ApplePQCCompatibilityTests: XCTestCase {
    func testApplePQCSDKBackendNotCompiled() throws {
        throw XCTSkip("HAS_APPLE_PQC_SDK is not enabled for this build")
    }
}
#endif // HAS_APPLE_PQC_SDK
