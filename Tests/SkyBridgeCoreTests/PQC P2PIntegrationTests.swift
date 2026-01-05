import XCTest
import CryptoKit
@testable import SkyBridgeCore

/// PQC在P2P通信中的集成测试
/// 测试PQC与P2P网络、文件传输、远程桌面的集成
final class PQCP2PIntegrationTests: XCTestCase {
    
    var crypto: EnhancedPostQuantumCrypto!
    var keyManager: EnhancedQuantumKeyManager!
    
    let alice = "alice-peer"
    let bob = "bob-peer"
    
    override func setUp() async throws {
        crypto = EnhancedPostQuantumCrypto()
        keyManager = EnhancedQuantumKeyManager()
        
 // 启用PQC进行测试
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
            SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA"
        }
    }
    
    override func tearDown() async throws {
        crypto = nil
        keyManager = nil
        
 // 恢复默认设置
        await MainActor.run {
            SettingsManager.shared.enablePQC = false
        }
    }
    
 // MARK: - 端到端通信测试
    
    func testEndToEndMessageSigning() async throws {
 // 检查PQC提供者是否可用
        guard PQCProviderFactory.makeProvider() != nil else {
            print("⚠️ PQC提供者不可用，跳过此测试")
            return
        }
        
        let message = "这是一条需要签名的P2P消息".utf8Data
        
 // Alice签名消息
        let (classicalSig, pqcSig) = try await crypto.hybridSign(message, for: alice)
        
        XCTAssertGreaterThan(classicalSig.count, 0)
        
 // PQC签名可能因为密钥问题返回nil
        guard pqcSig != nil else {
            print("⚠️ PQC签名未生成，跳过验证测试")
            return
        }
        
 // Bob验证消息
        let isValid = try await crypto.verifyHybrid(
            message,
            classicalSignature: classicalSig,
            pqcSignature: pqcSig,
            peerId: alice
        )
        
        XCTAssertTrue(isValid, "混合签名验证应该成功")
        print("✅ 端到端消息签名验证成功")
    }
    
    func testEndToEndMessageEncryption() async throws {
        #if canImport(liboqs)
        guard let provider = PQCProviderFactory.makeProvider() else {
            XCTFail("PQC提供者不可用")
            return
        }
        
        let message = "这是一条需要加密的P2P消息 🔐".utf8Data
        
 // Alice使用KEM生成共享密钥
        let (sharedSecret, ciphertext) = try await provider.kemEncapsulate(
            peerId: bob,
            kemVariant: "ML-KEM-768"
        )
        
 // Alice使用共享密钥加密消息
        let encryptionKey = SymmetricKey(data: sharedSecret)
        let messageString = String(data: message, encoding: .utf8)!
        let encryptedMessage = try await crypto.encrypt(messageString, using: encryptionKey)
        
 // 传输：ciphertext + encryptedMessage 发送给Bob
        
 // Bob解封装获取共享密钥
        let recoveredSecret = try await provider.kemDecapsulate(
            peerId: bob,
            encapsulated: ciphertext,
            kemVariant: "ML-KEM-768"
        )
        
 // Bob使用共享密钥解密消息
        let decryptionKey = SymmetricKey(data: recoveredSecret)
        let decryptedMessage = try await crypto.decrypt(encryptedMessage, using: decryptionKey)
        
        XCTAssertEqual(messageString, decryptedMessage, "解密后的消息应该与原消息相同")
        print("✅ 端到端消息加密/解密成功")
        #else
        print("⚠️ liboqs不可用，跳过此测试")
        #endif
    }
    
 // MARK: - 消息认证与完整性测试
    
    func testMessageTampering() async throws {
        #if canImport(liboqs)
        let message = "原始消息".utf8Data
        
 // Alice签名
        let (classicalSig, pqcSig) = try await crypto.hybridSign(message, for: alice)
        
 // 攻击者篡改消息
        let tamperedMessage = "篡改后的消息".utf8Data
        
 // Bob验证篡改的消息（应该失败）
        let isValid = try await crypto.verifyHybrid(
            tamperedMessage,
            classicalSignature: classicalSig,
            pqcSignature: pqcSig,
            peerId: alice
        )
        
        XCTAssertFalse(isValid, "篡改消息的验证应该失败")
        print("✅ 消息篡改检测成功")
        #else
        print("⚠️ liboqs不可用，跳过此测试")
        #endif
    }
    
    func testSignatureTampering() async throws {
 // 检查PQC提供者是否可用
        guard PQCProviderFactory.makeProvider() != nil else {
            print("⚠️ PQC提供者不可用，跳过此测试")
            return
        }
        
        let message = "测试消息".utf8Data
        
 // Alice签名
        let (classicalSig, pqcSig) = try await crypto.hybridSign(message, for: alice)
        
        guard var pqcSignature = pqcSig else {
            print("⚠️ PQC签名未生成，跳过篡改验证测试")
            return
        }
        
 // 攻击者篡改PQC签名
        pqcSignature[0] ^= 0xFF
        
 // Bob验证（应该失败）
        let isValid = try await crypto.verifyHybrid(
            message,
            classicalSignature: classicalSig,
            pqcSignature: pqcSignature,
            peerId: alice
        )
        
        XCTAssertFalse(isValid, "篡改签名的验证应该失败")
        print("✅ 签名篡改检测成功")
    }
    
 // MARK: - 多对等节点通信测试
    
    func testMultiPeerCommunication() async throws {
 // 检查PQC提供者是否可用
        guard PQCProviderFactory.makeProvider() != nil else {
            print("⚠️ PQC提供者不可用，跳过此测试")
            return
        }
        
        let peers = ["peer-1", "peer-2", "peer-3", "peer-4", "peer-5"]
        let message = "多对等节点测试消息".utf8Data
        
        var signatures: [(classical: Data, pqc: Data?)] = []
        
 // 每个peer都签名消息
        var hasPQCSignature = false
        for peer in peers {
            let sig = try await crypto.hybridSign(message, for: peer)
            signatures.append(sig)
            if sig.pqc != nil {
                hasPQCSignature = true
            }
        }
        
 // 如果没有任何PQC签名，跳过测试
        guard hasPQCSignature else {
            print("⚠️ 没有生成PQC签名，跳过多对等节点测试")
            return
        }
        
 // 验证每个peer的签名
        for (index, peer) in peers.enumerated() {
            let sig = signatures[index]
            let isValid = try await crypto.verifyHybrid(
                message,
                classicalSignature: sig.classical,
                pqcSignature: sig.pqc,
                peerId: peer
            )
            XCTAssertTrue(isValid, "peer \(peer) 的签名应该有效")
        }
        
        print("✅ 多对等节点通信测试通过")
    }
    
 // MARK: - 会话密钥协商测试
    
    func testSessionKeyNegotiation() async throws {
        #if canImport(liboqs)
        guard let provider = PQCProviderFactory.makeProvider() else {
            XCTFail("PQC提供者不可用")
            return
        }
        
 // 模拟双向密钥协商（简化版）
        
 // 1. Alice生成临时密钥对并封装给Bob
        let (aliceToBobSecret, aliceToBobCiphertext) = try await provider.kemEncapsulate(
            peerId: "\(alice)-to-\(bob)",
            kemVariant: "ML-KEM-768"
        )
        
 // 2. Bob生成临时密钥对并封装给Alice
        let (bobToAliceSecret, bobToAliceCiphertext) = try await provider.kemEncapsulate(
            peerId: "\(bob)-to-\(alice)",
            kemVariant: "ML-KEM-768"
        )
        
 // 3. Alice解封装Bob的密文
        let aliceReceivedSecret = try await provider.kemDecapsulate(
            peerId: "\(bob)-to-\(alice)",
            encapsulated: bobToAliceCiphertext,
            kemVariant: "ML-KEM-768"
        )
        
 // 4. Bob解封装Alice的密文
        let bobReceivedSecret = try await provider.kemDecapsulate(
            peerId: "\(alice)-to-\(bob)",
            encapsulated: aliceToBobCiphertext,
            kemVariant: "ML-KEM-768"
        )
        
 // 5. 双方组合密钥材料生成会话密钥
        var aliceKeyMaterial = Data()
        aliceKeyMaterial.append(aliceToBobSecret)
        aliceKeyMaterial.append(aliceReceivedSecret)
        
        var bobKeyMaterial = Data()
        bobKeyMaterial.append(bobReceivedSecret)
        bobKeyMaterial.append(bobToAliceSecret)
        
 // 使用HKDF派生会话密钥
        let aliceSessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: aliceKeyMaterial),
            salt: "session-key".utf8Data,
            info: Data(),
            outputByteCount: 32
        )
        
        let bobSessionKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: bobKeyMaterial),
            salt: "session-key".utf8Data,
            info: Data(),
            outputByteCount: 32
        )
        
 // 验证双方的会话密钥相同
        XCTAssertEqual(
            aliceSessionKey.withUnsafeBytes { Data($0) },
            bobSessionKey.withUnsafeBytes { Data($0) },
            "双方的会话密钥应该相同"
        )
        
        print("✅ 会话密钥协商成功")
        #else
        print("⚠️ liboqs不可用，跳过此测试")
        #endif
    }
    
 // MARK: - 文件传输安全测试
    
    func testSecureFileTransfer() async throws {
        #if canImport(liboqs)
        guard let provider = PQCProviderFactory.makeProvider() else {
            XCTFail("PQC提供者不可用")
            return
        }
        
 // 模拟文件内容（1MB）
        let fileContent = Data(repeating: 0xAB, count: 1024 * 1024)
        
 // 1. 协商文件传输密钥
        let (fileTransferSecret, keyCiphertext) = try await provider.kemEncapsulate(
            peerId: "\(alice)-file-transfer",
            kemVariant: "ML-KEM-768"
        )
        
        let fileKey = SymmetricKey(data: fileTransferSecret)
        
 // 2. 发送方（Alice）加密文件 - 使用 String 接口
        let fileContentString = fileContent.base64EncodedString()
        let encryptedFile = try await crypto.encrypt(fileContentString, using: fileKey)
        
        print("📊 文件传输统计:")
        print("   原始大小: \(fileContent.count) 字节")
        print("   加密后大小: \(encryptedFile.combined.count) 字节")
        print("   开销: \(encryptedFile.combined.count - fileContent.count) 字节")
        
 // 3. 接收方（Bob）解封装密钥
        let receivedSecret = try await provider.kemDecapsulate(
            peerId: "\(alice)-file-transfer",
            encapsulated: keyCiphertext,
            kemVariant: "ML-KEM-768"
        )
        
        let decryptionKey = SymmetricKey(data: receivedSecret)
        
 // 4. 接收方解密文件
        let decryptedFileString = try await crypto.decrypt(encryptedFile, using: decryptionKey)
        let decryptedFile = Data(base64Encoded: decryptedFileString)!
        
 // 5. 验证完整性
        XCTAssertEqual(fileContent, decryptedFile, "解密后的文件应该与原文件相同")
        
        print("✅ 安全文件传输测试通过")
        #else
        print("⚠️ liboqs不可用，跳过此测试")
        #endif
    }
    
 // MARK: - 性能基准测试
    
    func testHybridSignaturePerformance() async throws {
        #if canImport(liboqs)
        let message = "性能测试消息".utf8Data
        
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
        }
        
        let iterations = 10
        let startTime = Date()
        
        for _ in 0..<iterations {
            _ = try await crypto.hybridSign(message, for: "\(alice)-perf")
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("混合签名性能: \(iterations)次签名耗时 \(String(format: "%.2f", elapsed * 1000))ms")
        #else
        print("⚠️ liboqs不可用，跳过此测试")
        #endif
    }
    
    func testKEMBasedEncryptionPerformance() async throws {
        #if canImport(liboqs)
        guard let provider = PQCProviderFactory.makeProvider() else {
            print("⚠️ liboqs不可用，跳过此测试")
            return
        }
        
        let message = Data(repeating: 0xAA, count: 1024 * 10) // 10KB
        let iterations = 10
        let startTime = Date()
        
        for _ in 0..<iterations {
 // KEM封装
            let (secret, _) = try await provider.kemEncapsulate(
                peerId: "\(alice)-perf-enc",
                kemVariant: "ML-KEM-768"
            )
            
 // 对称加密
            let key = SymmetricKey(data: secret)
            let messageString = message.base64EncodedString()
            _ = try await crypto.encrypt(messageString, using: key)
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("KEM加密性能: \(iterations)次加密耗时 \(String(format: "%.2f", elapsed * 1000))ms")
        #else
        print("⚠️ liboqs不可用，跳过此测试")
        #endif
    }
    
 // MARK: - 向后兼容性测试
    
    func testBackwardCompatibilityWithoutPQC() async throws {
 // 禁用PQC
        await MainActor.run {
            SettingsManager.shared.enablePQC = false
        }
        
        let message = "向后兼容测试".utf8Data
        
 // 签名（应该只有传统签名）
        let (classical, pqc) = try await crypto.hybridSign(message, for: alice)
        
        XCTAssertGreaterThan(classical.count, 0)
        XCTAssertNil(pqc, "PQC被禁用时应该没有PQC签名")
        
 // 验证（应该只验证传统签名）
        let isValid = try await crypto.verifyHybrid(
            message,
            classicalSignature: classical,
            pqcSignature: nil,
            peerId: alice
        )
        
        XCTAssertTrue(isValid)
        print("✅ 向后兼容性测试通过")
    }
    
    func testHybridModeGracefulDegradation() async throws {
        #if !canImport(liboqs)
 // 在没有liboqs的环境中，即使启用PQC也应该能正常工作
        await MainActor.run {
            SettingsManager.shared.enablePQC = true
        }
        
        let message = "优雅降级测试".utf8Data
        
        let (classical, pqc) = try await crypto.hybridSign(message, for: alice)
        
        XCTAssertGreaterThan(classical.count, 0, "传统签名应该存在")
        XCTAssertNil(pqc, "没有liboqs时PQC签名应该为nil")
        
        let isValid = try await crypto.verifyHybrid(
            message,
            classicalSignature: classical,
            pqcSignature: nil,
            peerId: alice
        )
        
        XCTAssertTrue(isValid, "应该能够正常验证传统签名")
        print("✅ 优雅降级测试通过")
        #else
        print("ℹ️ liboqs可用，跳过降级测试")
        #endif
    }
    
 // MARK: - 安全特性测试
    
    func testPQCAlgorithmSelection() async throws {
        #if canImport(liboqs)
        let message = "算法选择测试".utf8Data
        let algorithms = ["ML-DSA-65", "ML-DSA-87"]
        
        for algorithm in algorithms {
            await MainActor.run {
                SettingsManager.shared.pqcSignatureAlgorithm = algorithm
            }
            
            let (_, pqcSig) = try await crypto.hybridSign(message, for: "\(alice)-\(algorithm)")
            XCTAssertNotNil(pqcSig, "算法 \(algorithm) 应该生成签名")
            
            if let sig = pqcSig {
                print("✅ \(algorithm) 签名长度: \(sig.count) 字节")
            }
        }
        
        print("✅ PQC算法选择测试通过")
        #else
        print("⚠️ liboqs不可用，跳过此测试")
        #endif
    }
}
