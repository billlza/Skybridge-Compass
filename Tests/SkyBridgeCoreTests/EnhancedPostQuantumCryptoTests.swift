import XCTest
import CryptoKit
@testable import SkyBridgeCore

/// EnhancedPostQuantumCrypto集成测试
/// 测试传统加密、PQC签名以及混合模式
final class EnhancedPostQuantumCryptoTests: XCTestCase {
    
    var crypto: EnhancedPostQuantumCrypto!
    let testPeerId = "test-peer-123"
    let testString = "Hello, Quantum World! 你好，量子世界！"
    var testData: Data { testString.utf8Data }
    private var originalEnablePQC = true
    private var originalPQCSignatureAlgorithm = "ML-DSA-65"
    private var deviceIdentity: DeviceIdentityKeychainTestContext?
    
    override func setUp() async throws {
        (originalEnablePQC, originalPQCSignatureAlgorithm) = await MainActor.run {
            (
                SettingsManager.shared.enablePQC,
                SettingsManager.shared.pqcSignatureAlgorithm
            )
        }
        let deviceIdentity = try DeviceIdentityKeychainTestContext()
        self.deviceIdentity = deviceIdentity
        let identity = try await deviceIdentity.manager.getProtocolSigningIdentity(
            for: .mlDSA65,
            protection: .softwareKeychain
        )
        let snapshot = CommittedLocalProtocolIdentitySnapshot(
            algorithm: .mlDSA65,
            protection: .softwareKeychain,
            publicKey: identity.publicKey,
            keyHandle: identity.keyHandle
        )
        crypto = EnhancedPostQuantumCrypto(
            deviceIdentityKeyManager: deviceIdentity.manager,
            committedLocalIdentityLoader: { snapshot }
        )
    }
    
    override func tearDown() async throws {
        let enablePQC = originalEnablePQC
        let algorithm = originalPQCSignatureAlgorithm
        await MainActor.run {
            SettingsManager.shared.enablePQC = enablePQC
            SettingsManager.shared.pqcSignatureAlgorithm = algorithm
        }
        crypto = nil
        let deviceIdentity = self.deviceIdentity
        self.deviceIdentity = nil
        try deviceIdentity?.reset()
    }
    
 // MARK: - 传统加密/解密测试
    
    func testSymmetricEncryptionDecryption() async throws {
        let key = SymmetricKey(size: .bits256)
        
 // 加密
        let encryptedData = try await crypto.encrypt(testString, using: key)
        XCTAssertNotNil(encryptedData)
        XCTAssertGreaterThan(encryptedData.combined.count, testData.count)
        
 // 解密
        let decryptedString = try await crypto.decrypt(encryptedData, using: key)
        XCTAssertEqual(decryptedString, testString)
    }
    
    func testEncryptionWithWrongKey() async throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        
        let encryptedData = try await crypto.encrypt(testString, using: key1)
        
        do {
            _ = try await crypto.decrypt(encryptedData, using: key2)
            XCTFail("应该抛出解密错误")
        } catch {
            XCTAssertFalse((error as NSError).localizedDescription.isEmpty)
        }
    }
    
 // MARK: - 传统签名/验证测试
    
    func testP256SignatureVerification() async throws {
 // 禁用PQC以确保使用P256签名
        await MainActor.run {
            SettingsManager.shared.enablePQC = false
        }
        
 // 签名
        let signature = try await crypto.sign(testData, for: testPeerId)
        XCTAssertGreaterThan(signature.count, 0)
        
 // 获取公钥
        guard let publicKey = crypto.getPublicKey(for: testPeerId) else {
            XCTFail("未能获取公钥")
            return
        }
        
 // 验证
        let isValid = try await crypto.verify(testData, signature: signature, publicKey: publicKey)
        XCTAssertTrue(isValid)
    }
    
    func testP256SignatureWithWrongData() async throws {
 // 禁用PQC以确保使用P256签名
        await MainActor.run {
            SettingsManager.shared.enablePQC = false
        }
        
        let signature = try await crypto.sign(testData, for: testPeerId)
        let wrongData = "Wrong data".utf8Data
        
        guard let publicKey = crypto.getPublicKey(for: testPeerId) else {
            XCTFail("未能获取公钥")
            return
        }
        
        let isValid = try await crypto.verify(wrongData, signature: signature, publicKey: publicKey)
        XCTAssertFalse(isValid)
    }
    
 // MARK: - PQC混合签名测试
    
    func testHybridSignatureWithPQCDisabled() async throws {
 // 确保PQC被禁用
        await MainActor.run {
            SettingsManager.shared.enablePQC = false
        }
        
        let (classical, pqc) = try await crypto.hybridSign(testData, for: testPeerId)
        
        XCTAssertGreaterThan(classical.count, 0)
        XCTAssertNil(pqc, "PQC被禁用时应该返回nil")
    }
    
    func testHybridSignatureWithPQCEnabled() async throws {
 // 启用PQC
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }
        
        let (classical, pqc) = try await crypto.hybridSign(testData, for: testPeerId)
        let pqcSignature = try XCTUnwrap(pqc)

        XCTAssertGreaterThan(classical.count, 0)
        XCTAssertGreaterThan(pqcSignature.count, 0)
    }
    
    func testHybridVerificationWithPQCEnabled() async throws {
 // 启用PQC
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }
        
        try await installLocalProtocolIdentityTrust(for: testPeerId)

 // 签名
        let (classical, pqc) = try await crypto.hybridSign(testData, for: testPeerId)
        let pqcSignature = try XCTUnwrap(pqc)
        
 // 验证
        let isValid = try await crypto.verifyHybrid(
            testData,
            classicalSignature: classical,
            pqcSignature: pqcSignature,
            peerId: testPeerId
        )
        
        XCTAssertTrue(isValid, "混合签名验证应该成功")
    }
    
    func testHybridVerificationWithWrongData() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }
        
        try await installLocalProtocolIdentityTrust(for: testPeerId)
        let (classical, pqc) = try await crypto.hybridSign(testData, for: testPeerId)
        let pqcSignature = try XCTUnwrap(pqc)
        let wrongData = "Wrong data".utf8Data
        
        let isValid = try await crypto.verifyHybrid(
            wrongData,
            classicalSignature: classical,
            pqcSignature: pqcSignature,
            peerId: testPeerId
        )
        
        XCTAssertFalse(isValid, "错误数据的签名验证应该失败")
    }

    func testHybridVerificationRequiresPQCSignatureWhenEnabled() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }

        let (classical, pqc) = try await crypto.hybridSign(testData, for: testPeerId)
        XCTAssertNotNil(pqc)

        do {
            _ = try await crypto.verifyHybrid(
                testData,
                classicalSignature: classical,
                pqcSignature: nil,
                peerId: testPeerId
            )
            XCTFail("PQC-enabled verification must reject a missing PQC signature")
        } catch let error as EnhancedPostQuantumCryptoError {
            XCTAssertEqual(error, .pqcSignatureRequired)
        }
    }

    func testHybridVerificationRejectsTamperedPQCSignatureWithValidClassicalSignature() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }

        try await installLocalProtocolIdentityTrust(for: testPeerId)
        let (classical, pqc) = try await crypto.hybridSign(testData, for: testPeerId)
        var tamperedPQC = try XCTUnwrap(pqc)
        tamperedPQC[tamperedPQC.startIndex] ^= 0x01

        let isValid = try await crypto.verifyHybrid(
            testData,
            classicalSignature: classical,
            pqcSignature: tamperedPQC,
            peerId: testPeerId
        )
        XCTAssertFalse(isValid)
    }

    func testPQCAlgorithmValidatorRejectsUnknownPQCAlgorithm() throws {
        XCTAssertThrowsError(
            try EnhancedPostQuantumCrypto.requiredPQCSignatureAlgorithm("ML-DSA-unknown")
        ) { error in
            XCTAssertEqual(
                error as? EnhancedPostQuantumCryptoError,
                .invalidPQCSignatureAlgorithm("ML-DSA-unknown")
            )
        }
    }

    func testRequiredPQCSignatureBindsCanonicalAlgorithmAndRejectsTampering() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA"
        }

        let peerId = "strict-pqc-peer-\(UUID().uuidString)"
        let publicKey = try await XCTUnwrap(deviceIdentity).manager
            .getProtocolSigningPublicKey(for: .mlDSA65)
        let trust = try await installAuthenticatedMLDSATrustRecordForTesting(
            peerId: peerId,
            publicKey: publicKey
        )
        addTeardownBlock { @MainActor [trust] in
            await trust.removeRecordsForTesting(deviceIds: [peerId])
            trust.setInMemoryPersistenceForTesting(false)
        }

        let required = try await crypto.signPQCRequiredWithAlgorithm(testData, for: peerId)
        XCTAssertEqual(required.algorithm, "ML-DSA-65")
        XCTAssertGreaterThan(required.bytes.count, 3_000)
        let verified = try await crypto.verifyPQCRequired(
            testData,
            signature: required.bytes,
            for: peerId,
            algorithm: required.algorithm
        )
        XCTAssertTrue(verified)

        var tampered = required.bytes
        tampered[tampered.startIndex] ^= 0x01
        let tamperedVerified = try await crypto.verifyPQCRequired(
            testData,
            signature: tampered,
            for: peerId,
            algorithm: required.algorithm
        )
        XCTAssertFalse(tamperedVerified)
    }

    @MainActor
    func testRequiredPQCSignatureUsesCommittedMLDSA87SoftwareIdentityAndExactRemoteBinding() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
        }
        let manager = try XCTUnwrap(deviceIdentity).manager
        let identity = try await manager.getProtocolSigningIdentity(
            for: .mlDSA87,
            protection: .softwareKeychain
        )
        let snapshot = CommittedLocalProtocolIdentitySnapshot(
            algorithm: .mlDSA87,
            protection: .softwareKeychain,
            publicKey: identity.publicKey,
            keyHandle: identity.keyHandle
        )
        let signer = EnhancedPostQuantumCrypto(
            deviceIdentityKeyManager: manager,
            committedLocalIdentityLoader: { snapshot }
        )
        let peerId = "strict-pqc-87-peer-\(UUID().uuidString)"
        let required = try await signer.signPQCRequiredWithAlgorithm(testData, for: peerId)
        XCTAssertEqual(required.algorithm, ProtocolSigningAlgorithm.mlDSA87.rawValue)
        XCTAssertEqual(required.bytes.count, 4_627)

        let fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .mlDSA87,
            publicKeyBytes: identity.publicKey
        )
        let record = try XCTUnwrap(
            TrustSyncService.resolvedAuthenticatedRemoteAuthorityRecord(
                existingRecords: [],
                deviceId: peerId,
                preferredCurrentDeviceId: peerId,
                protocolSigningAlgorithm: .mlDSA87,
                protocolPublicKeyFingerprint: fingerprint,
                authenticatedProtocolPublicKey: identity.publicKey,
                pinSource: .authenticatedHandshake
            )
        )
        let trust = TrustSyncService.shared
        trust.setInMemoryPersistenceForTesting(true)
        await trust.removeRecordsForTesting(deviceIds: [peerId])
        _ = try await trust.addTrustRecord(record)

        do {
            let verified = try await signer.verifyPQCRequired(
                testData,
                signature: required.bytes,
                for: peerId,
                algorithm: required.algorithm
            )
            XCTAssertTrue(verified)
        } catch {
            await trust.removeRecordsForTesting(deviceIds: [peerId])
            trust.setInMemoryPersistenceForTesting(false)
            throw error
        }
        await trust.removeRecordsForTesting(deviceIds: [peerId])
        trust.setInMemoryPersistenceForTesting(false)
    }

    func testRequiredPQCSignatureUsesMLDSA87SecureEnclaveCallbackHandle() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
        }
        let manager = try XCTUnwrap(deviceIdentity).manager
        let expectedSignature = Data(repeating: 0x5A, count: 4_627)
        let snapshot = CommittedLocalProtocolIdentitySnapshot(
            algorithm: .mlDSA87,
            protection: .secureEnclaveRequired,
            publicKey: Data(repeating: 0x87, count: 2_592),
            keyHandle: .callback(FixedMLDSA87SigningCallback(signature: expectedSignature))
        )
        let signer = EnhancedPostQuantumCrypto(
            deviceIdentityKeyManager: manager,
            committedLocalIdentityLoader: { snapshot }
        )

        let required = try await signer.signPQCRequiredWithAlgorithm(testData, for: "se-callback")
        XCTAssertEqual(required.algorithm, ProtocolSigningAlgorithm.mlDSA87.rawValue)
        XCTAssertEqual(required.bytes, expectedSignature)
    }

    func testRequiredPQCVerificationRejectsUnknownAlgorithm() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }
        let required = try await crypto.signPQCRequiredWithAlgorithm(testData, for: testPeerId)

        do {
            _ = try await crypto.verifyPQCRequired(
                testData,
                signature: required.bytes,
                for: testPeerId,
                algorithm: "ML-DSA-unknown"
            )
            XCTFail("Unknown metadata algorithms must fail closed")
        } catch let error as EnhancedPostQuantumCryptoError {
            XCTAssertEqual(error, .invalidPQCSignatureAlgorithm("ML-DSA-unknown"))
        }
    }

    func testRequiredPQCVerificationAcceptsMLDSA87MetadataButRequiresExactRemoteRawKey() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }

        do {
            _ = try await crypto.verifyPQCRequired(
                testData,
                signature: Data(),
                for: testPeerId,
                algorithm: "ML-DSA-87"
            )
            XCTFail("ML-DSA-87 metadata without an exact remote raw-key authority must fail closed")
        } catch let error as EnhancedPostQuantumCryptoError {
            XCTAssertEqual(error, .authenticatedRemoteSigningKeyUnavailable)
        }
    }

    func testFileTransferMetadataUsesTheAlgorithmBoundToItsPQCSignature() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engineSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/SkyBridgeCore/FileTransfer/FileTransferEngine.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(engineSource.contains("let requiredSignature = try await pqCrypto.signPQCRequiredWithAlgorithm("))
        XCTAssertTrue(engineSource.contains("fileSignature: requiredSignature.bytes"))
        XCTAssertTrue(engineSource.contains("signatureAlgorithm: requiredSignature.algorithm"))
        XCTAssertFalse(engineSource.contains("let pqcAlgo = await MainActor.run"))
    }

    func testLegacyQuantumNetworkPacketBindsTheEmittedSignatureAlgorithm() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SkyBridgeCore/QuantumSecure/QuantumSecureP2PNetwork.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".signPQCRequiredWithAlgorithm(encrypted.combined, for: peerId)"))
        XCTAssertTrue(source.contains("signatureAlgorithm: requiredSignature.algorithm"))
        XCTAssertTrue(source.contains("guard let signatureAlgorithm = packet.signatureAlgorithm"))
        XCTAssertFalse(source.contains("let signatureAlgorithm = SettingsManager.shared.pqcSignatureAlgorithm"))
    }

    func testStrictPQCVerificationRequiresCanonicalAuthenticatedRemoteKey() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }

        let peerId = "provider-isolation-\(UUID().uuidString)"
        let identityManager = try XCTUnwrap(deviceIdentity).manager
        let localIdentity = try await identityManager.getProtocolSigningIdentity(
            for: .mlDSA65,
            protection: .softwareKeychain
        )
        let localSnapshot = CommittedLocalProtocolIdentitySnapshot(
            algorithm: .mlDSA65,
            protection: .softwareKeychain,
            publicKey: localIdentity.publicKey,
            keyHandle: localIdentity.keyHandle
        )
        let signer = EnhancedPostQuantumCrypto(
            deviceIdentityKeyManager: identityManager,
            committedLocalIdentityLoader: { localSnapshot }
        )
        let signature = try await signer.signPQCRequiredWithAlgorithm(testData, for: peerId)
        let unrelatedVerifier = EnhancedPostQuantumCrypto(
            deviceIdentityKeyManager: identityManager
        )

        do {
            _ = try await unrelatedVerifier.verifyPQCRequired(
                testData,
                signature: signature.bytes,
                for: peerId,
                algorithm: signature.algorithm
            )
            XCTFail("Strict verification must not infer remote trust from locally persisted keys")
        } catch let error as EnhancedPostQuantumCryptoError {
            XCTAssertEqual(error, .authenticatedRemoteSigningKeyUnavailable)
        }
    }
    
 // MARK: - PQC算法测试
    
    func testMLDSA65Algorithm() async throws {
        let peerId = "test-peer-mldsa65"
        
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }
        
        try await installLocalProtocolIdentityTrust(for: peerId)
        let (classical, pqc) = try await crypto.hybridSign(testData, for: peerId)
        let pqcSignature = try XCTUnwrap(pqc)
        
 // ML-DSA-65的签名长度应该在合理范围内（约3293字节）
        XCTAssertGreaterThan(pqcSignature.count, 3000)
        XCTAssertLessThan(pqcSignature.count, 3500)
        print("✅ ML-DSA-65签名长度: \(pqcSignature.count) 字节")
        
        let isValid = try await crypto.verifyHybrid(
            testData,
            classicalSignature: classical,
            pqcSignature: pqc,
            peerId: peerId
        )
        XCTAssertTrue(isValid)
    }
    
    func testMLDSA87Algorithm() async throws {
        let peerId = "test-peer-mldsa87-\(UUID().uuidString)"
        let keychain = PQCKeychainTestContext()
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: "ML-DSA-87",
            identity: peerId,
            storageScope: keychain.storageScope
        )
        addTeardownBlock {
            try PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            try PQCBackendAuthorityStore.deleteForTesting(
                domain: .quantumAdapter,
                scopeSource: keychain.scopeSource
            )
        }
        let provider = OQSProvider(scopeSource: keychain.scopeSource)
        let pqcSignature = try await provider.sign(
            data: testData,
            peerId: peerId,
            algorithm: "ML-DSA-87"
        )
        
 // ML-DSA-87的签名长度应该大于ML-DSA-65（约4595字节）
        XCTAssertGreaterThan(pqcSignature.count, 4000)
        XCTAssertLessThan(pqcSignature.count, 5000)
        print("✅ ML-DSA-87签名长度: \(pqcSignature.count) 字节")
        
        let verifier = OQSProvider(scopeSource: keychain.scopeSource)
        _ = try await authenticateLocalSigningKeyForTesting(
            signer: provider,
            verifier: verifier,
            peerId: peerId,
            algorithm: "ML-DSA-87"
        )
        let isValid = await verifier.verify(
            data: testData,
            signature: pqcSignature,
            peerId: peerId,
            algorithm: "ML-DSA-87"
        )
        XCTAssertTrue(isValid)
    }
    
 // MARK: - 性能测试
    
    func testP256SignaturePerformance() async throws {
 // 简单的性能测试 - 执行多次签名
        let iterations = 10
        let startTime = Date()
        
        for _ in 0..<iterations {
            _ = try await crypto.sign(testData, for: testPeerId)
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("P256签名性能: \(iterations)次签名耗时 \(String(format: "%.2f", elapsed * 1000))ms")
    }
    
    func testPQCSignaturePerformance() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }
        
 // 简单的性能测试 - 执行多次签名
        let iterations = 10
        let startTime = Date()
        
        for _ in 0..<iterations {
            _ = try await crypto.hybridSign(testData, for: testPeerId)
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("PQC签名性能: \(iterations)次签名耗时 \(String(format: "%.2f", elapsed * 1000))ms")
    }
    
 // MARK: - 边界测试
    
    func testEmptyDataSignature() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = false
        }
        let emptyData = Data()

        let signature = try await crypto.sign(emptyData, for: testPeerId)
        XCTAssertGreaterThan(signature.count, 0, "空数据也应该能够签名")
        let publicKey = try XCTUnwrap(crypto.getPublicKey(for: testPeerId))
        let isValid = try await crypto.verify(emptyData, signature: signature, publicKey: publicKey)
        XCTAssertTrue(isValid)
    }
    
    func testLargeDataSignature() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = false
        }
 // 创建1MB的测试数据
        let largeData = Data(repeating: 0xFF, count: 1024 * 1024)
        
        let signature = try await crypto.sign(largeData, for: testPeerId)
        XCTAssertGreaterThan(signature.count, 0)
        let publicKey = try XCTUnwrap(crypto.getPublicKey(for: testPeerId))
        let isValid = try await crypto.verify(largeData, signature: signature, publicKey: publicKey)
        XCTAssertTrue(isValid)
    }
    
    func testLargeDataEncryption() async throws {
 // 创建1MB的测试数据
        let largeData = Data(repeating: 0xAB, count: 1024 * 1024)
        let largeDataString = largeData.base64EncodedString()
        let key = SymmetricKey(size: .bits256)
        
        let encrypted = try await crypto.encrypt(largeDataString, using: key)
        let decryptedString = try await crypto.decrypt(encrypted, using: key)
        let decrypted = Data(base64Encoded: decryptedString)!
        
        XCTAssertEqual(decrypted, largeData)
    }

    private func installLocalProtocolIdentityTrust(for peerId: String) async throws {
        let publicKey = try await XCTUnwrap(deviceIdentity).manager.getProtocolSigningPublicKey(
            for: .mlDSA65
        )
        let trust = try await installAuthenticatedMLDSATrustRecordForTesting(
            peerId: peerId,
            publicKey: publicKey
        )
        addTeardownBlock { @MainActor in
            await trust.removeRecordsForTesting(deviceIds: [peerId])
            trust.setInMemoryPersistenceForTesting(false)
        }
    }
}

private struct FixedMLDSA87SigningCallback: SigningCallback, Sendable {
    let signature: Data

    func sign(data: Data) async throws -> Data {
        _ = data
        return signature
    }
}
