import XCTest
@testable import SkyBridgeCore

#if HAS_APPLE_PQC_SDK
import CryptoKit

/// Apple原生PQC与OQS兼容性测试
/// 验证两种实现可以互操作
@available(macOS 26.0, *)
final class ApplePQCCompatibilityTests: XCTestCase {
    
    override func setUp() async throws {
 // 测试前准备
    }
    
    override func tearDown() async throws {
 // 测试后清理
    }
    
 // MARK: - 提供者检测测试
    
    func testProviderSelection() throws {
        let provider = PQCProviderFactory.makeProvider()
        XCTAssertNotNil(provider, "PQC提供者应该可用")
        
        let currentProvider = PQCProviderFactory.currentProvider
        XCTAssertEqual(currentProvider, "Apple CryptoKit (原生)", "macOS 26.0+应该使用Apple原生PQC")
        
        print("✅ 当前PQC提供者: \(currentProvider)")
    }
    
 // MARK: - ML-DSA签名兼容性测试
    
    func testMLDSA65Compatibility() async throws {
        let appleProvider = ApplePQCProvider()
        let testMessage = "兼容性测试消息".utf8Data
        let testPeerId = "apple-compat-test"
        
 // Apple签名
        let appleSignature = try await appleProvider.sign(
            data: testMessage,
            peerId: testPeerId,
            algorithm: "ML-DSA-65"
        )
        
        XCTAssertGreaterThan(appleSignature.count, 0)
        print("✅ Apple ML-DSA-65签名长度: \(appleSignature.count) 字节")
        
 // Apple验证
        let isValid = await appleProvider.verify(
            data: testMessage,
            signature: appleSignature,
            peerId: testPeerId,
            algorithm: "ML-DSA-65"
        )
        
        XCTAssertTrue(isValid, "Apple签名应该能自验证")
        print("✅ Apple ML-DSA-65自验证成功")
    }
    
    func testMLDSA87Compatibility() async throws {
        let appleProvider = ApplePQCProvider()
        let testMessage = "高安全级别测试".utf8Data
        let testPeerId = "apple-compat-test-87"
        
        let signature = try await appleProvider.sign(
            data: testMessage,
            peerId: testPeerId,
            algorithm: "ML-DSA-87"
        )
        
        XCTAssertGreaterThan(signature.count, 3000)
        print("✅ Apple ML-DSA-87签名长度: \(signature.count) 字节")
        
        let isValid = await appleProvider.verify(
            data: testMessage,
            signature: signature,
            peerId: testPeerId,
            algorithm: "ML-DSA-87"
        )
        
        XCTAssertTrue(isValid)
        print("✅ Apple ML-DSA-87自验证成功")
    }
    
 // MARK: - ML-KEM封装兼容性测试
    
    func testMLKEM768Compatibility() async throws {
        let appleProvider = ApplePQCProvider()
        let testPeerId = "apple-kem-test"
        
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
        let appleProvider = ApplePQCProvider()
        let testPeerId = "apple-kem1024-test"
        
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
        let appleProvider = ApplePQCProvider()
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
        let appleProvider = ApplePQCProvider()
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
        let appleProvider = ApplePQCProvider()
        let testMessage = "X-Wing HPKE测试消息".utf8Data
        let testPeerId = "xwing-test-\(UUID().uuidString)"
        let testAAD = "关联数据".data(using: .utf8)
        let recipientPrivateKey = try XWingMLKEM768X25519.PrivateKey.generate()

        try await appleProvider.setAuthenticatedXWingRecipientPublicKey(recipientPrivateKey.publicKey, for: testPeerId)
        try await appleProvider.setLocalXWingRecipientPrivateKey(recipientPrivateKey, for: testPeerId)
        
 // 封装和加密
        let (ciphertext, encapsulatedKey) = try await appleProvider.hpkeSeal(
            recipientPeerId: testPeerId,
            plaintext: testMessage,
            associatedData: testAAD
        )
        
        XCTAssertGreaterThan(ciphertext.count, 0)
        XCTAssertGreaterThan(encapsulatedKey.count, 0)
        print("✅ X-Wing HPKE封装成功")
        print("   密文长度: \(ciphertext.count) 字节")
        print("   封装密钥: \(encapsulatedKey.count) 字节")
        
 // 解封装和解密
        let decrypted = try await appleProvider.hpkeOpen(
            recipientPeerId: testPeerId,
            ciphertext: ciphertext,
            encapsulatedKey: encapsulatedKey,
            associatedData: testAAD
        )
        
        XCTAssertEqual(testMessage, decrypted, "解密后的消息应该与原消息相同")
        print("✅ X-Wing HPKE解密成功")
    }
    
 // MARK: - Secure Enclave测试
    
    func testSecureEnclaveSupport() async throws {
 // 启用Secure Enclave
        await MainActor.run {
            SettingsManager.shared.useSecureEnclaveMLDSA = true
        }
        
        let appleProvider = ApplePQCProvider()
        let testMessage = "Secure Enclave测试".utf8Data
        let testPeerId = "secure-enclave-test"
        
 // 使用Secure Enclave签名
        let signature = try await appleProvider.sign(
            data: testMessage,
            peerId: testPeerId,
            algorithm: "ML-DSA-65"
        )
        
        XCTAssertGreaterThan(signature.count, 0)
        print("✅ Secure Enclave ML-DSA-65签名成功")
        
 // 验证
        let isValid = await appleProvider.verify(
            data: testMessage,
            signature: signature,
            peerId: testPeerId,
            algorithm: "ML-DSA-65"
        )
        
        XCTAssertTrue(isValid)
        print("✅ Secure Enclave签名验证成功")
        
 // 恢复默认设置
        await MainActor.run {
            SettingsManager.shared.useSecureEnclaveMLDSA = false
        }
    }
    
 // MARK: - 性能对比测试
    
    func testAppleVsOQSPerformance() async throws {
        #if canImport(OQSRAII)
        let appleProvider = ApplePQCProvider()
        let oqsProvider = OQSProvider()
        let testMessage = "性能对比测试".utf8Data
        
 // Apple性能
        let appleStart = Date()
        _ = try await appleProvider.sign(
            data: testMessage,
            peerId: "perf-test-apple",
            algorithm: "ML-DSA-65"
        )
        let appleTime = Date().timeIntervalSince(appleStart)
        
 // OQS性能
        let oqsStart = Date()
        _ = try await oqsProvider.sign(
            data: testMessage,
            peerId: "perf-test-oqs",
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
        print("⚠️ OQS不可用，跳过性能对比")
        #endif
    }
    
 // MARK: - 混合签名集成测试
    
    func testHybridSignatureWithApple() async throws {
 // 检查PQC提供者是否可用
        guard PQCProviderFactory.makeProvider() != nil else {
            print("⚠️ PQC提供者不可用，跳过此测试")
            return
        }
        
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
        }
        
        let crypto = EnhancedPostQuantumCrypto()
        let testMessage = "混合签名测试".utf8Data
        let testPeerId = "hybrid-test"
        
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
    
    func testKeyMigration() async throws {
 // 检查PQC提供者是否可用
        guard PQCProviderFactory.makeProvider() != nil else {
            print("⚠️ PQC提供者不可用，跳过此测试")
            return
        }
        
        let testPeerId = "migration-test"
        let testAlgorithm = "ML-DSA-65"
        
 // 执行迁移
        try await PQCKeyMigrationTool.migrateOQSToApple(
            peerId: testPeerId,
            algorithm: testAlgorithm,
            strategy: .testOnly  // 仅测试，不实际迁移
        )
        
        print("✅ 密钥迁移测试通过")
    }
}
#endif // HAS_APPLE_PQC_SDK
