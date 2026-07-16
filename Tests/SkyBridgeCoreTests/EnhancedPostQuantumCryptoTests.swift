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
    
    override func setUp() async throws {
        (originalEnablePQC, originalPQCSignatureAlgorithm) = await MainActor.run {
            (
                SettingsManager.shared.enablePQC,
                SettingsManager.shared.pqcSignatureAlgorithm
            )
        }
        crypto = EnhancedPostQuantumCrypto()
    }
    
    override func tearDown() async throws {
        let enablePQC = originalEnablePQC
        let algorithm = originalPQCSignatureAlgorithm
        await MainActor.run {
            SettingsManager.shared.enablePQC = enablePQC
            SettingsManager.shared.pqcSignatureAlgorithm = algorithm
        }
        crypto = nil
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

    func testHybridSigningRejectsUnknownPQCAlgorithm() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-unknown"
        }

        do {
            _ = try await crypto.hybridSign(testData, for: testPeerId)
            XCTFail("Unknown PQC algorithms must fail before provider dispatch")
        } catch let error as EnhancedPostQuantumCryptoError {
            XCTAssertEqual(error, .invalidPQCSignatureAlgorithm("ML-DSA-unknown"))
        }
    }

    func testRequiredPQCSignatureBindsCanonicalAlgorithmAndRejectsTampering() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA"
        }

        let required = try await crypto.signPQCRequiredWithAlgorithm(testData, for: testPeerId)
        XCTAssertEqual(required.algorithm, "ML-DSA-65")
        XCTAssertGreaterThan(required.bytes.count, 3_000)
        let verified = try await crypto.verifyPQCRequired(
            testData,
            signature: required.bytes,
            for: testPeerId,
            algorithm: required.algorithm
        )
        XCTAssertTrue(verified)

        var tampered = required.bytes
        tampered[tampered.startIndex] ^= 0x01
        let tamperedVerified = try await crypto.verifyPQCRequired(
            testData,
            signature: tampered,
            for: testPeerId,
            algorithm: required.algorithm
        )
        XCTAssertFalse(tamperedVerified)
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

    func testLocalPQCProviderStateIsScopedToCryptoInstance() async throws {
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }

        let peerId = "provider-isolation-\(UUID().uuidString)"
        let signer = EnhancedPostQuantumCrypto()
        let signature = try await signer.signPQCRequiredWithAlgorithm(testData, for: peerId)
        let unrelatedVerifier = EnhancedPostQuantumCrypto()

        let verified = try await unrelatedVerifier.verifyPQCRequired(
            testData,
            signature: signature.bytes,
            for: peerId,
            algorithm: signature.algorithm
        )
        XCTAssertFalse(verified, "Local loopback key state must never become a process-global trust source")
    }
    
 // MARK: - PQC算法测试
    
    func testMLDSA65Algorithm() async throws {
        let peerId = "test-peer-mldsa65"
        
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }
        
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
        let peerId = "test-peer-mldsa87"
        
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-87"
        }
        
        let (classical, pqc) = try await crypto.hybridSign(testData, for: peerId)
        let pqcSignature = try XCTUnwrap(pqc)
        
 // ML-DSA-87的签名长度应该大于ML-DSA-65（约4595字节）
        XCTAssertGreaterThan(pqcSignature.count, 4000)
        XCTAssertLessThan(pqcSignature.count, 5000)
        print("✅ ML-DSA-87签名长度: \(pqcSignature.count) 字节")
        
        let isValid = try await crypto.verifyHybrid(
            testData,
            classicalSignature: classical,
            pqcSignature: pqc,
            peerId: peerId
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
}
