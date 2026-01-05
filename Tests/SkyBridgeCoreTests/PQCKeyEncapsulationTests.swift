import XCTest
import CryptoKit
@testable import SkyBridgeCore

/// PQC密钥封装（ML-KEM）测试
/// 测试后量子密钥封装机制
final class PQCKeyEncapsulationTests: XCTestCase {
    
    let testPeerId = "test-peer-kem"
    
    override func setUp() async throws {
 // 测试前准备
    }
    
    override func tearDown() async throws {
 // 测试后清理
    }
    
 // MARK: - ML-KEM-768测试
    
    func testMLKEM768Encapsulation() async throws {
        #if canImport(OQSRAII)
        if #available(macOS 14.0, *) {
            guard let provider = PQCProviderFactory.makeProvider() else {
                print("⚠️ PQC提供者不可用，跳过此测试")
                return
            }
            
 // 执行密钥封装
            let (sharedSecret1, ciphertext) = try await provider.kemEncapsulate(
                peerId: testPeerId,
                kemVariant: "ML-KEM-768"
            )
            
            XCTAssertGreaterThan(ciphertext.count, 0, "密文不应为空")
            XCTAssertGreaterThan(sharedSecret1.count, 0, "共享密钥不应为空")
            
 // ML-KEM-768密文长度应该是1088字节
            XCTAssertEqual(ciphertext.count, 1088, "ML-KEM-768密文长度应该是1088字节")
            
 // 共享密钥长度应该是32字节
            XCTAssertEqual(sharedSecret1.count, 32, "共享密钥长度应该是32字节")
            
            print("✅ ML-KEM-768封装成功")
            print("   密文长度: \(ciphertext.count) 字节")
            print("   共享密钥长度: \(sharedSecret1.count) 字节")
            
 // 执行密钥解封装
            let sharedSecret2 = try await provider.kemDecapsulate(
                peerId: testPeerId,
                encapsulated: ciphertext,
                kemVariant: "ML-KEM-768"
            )
            
            XCTAssertEqual(sharedSecret1, sharedSecret2, "封装和解封装的共享密钥应该相同")
            print("✅ ML-KEM-768解封装成功，密钥匹配")
        }
        #else
        print("⚠️ OQSRAII不可用，跳过此测试")
        #endif
    }
    
    func testMLKEM1024Encapsulation() async throws {
        #if canImport(OQSRAII)
        if #available(macOS 14.0, *) {
            guard let provider = PQCProviderFactory.makeProvider() else {
                print("⚠️ PQC提供者不可用，跳过此测试")
                return
            }
            
            let (sharedSecret1, ciphertext) = try await provider.kemEncapsulate(
                peerId: testPeerId + "-1024",
                kemVariant: "ML-KEM-1024"
            )
            
            XCTAssertGreaterThan(ciphertext.count, 0)
            XCTAssertGreaterThan(sharedSecret1.count, 0)
            
 // ML-KEM-1024密文长度应该是1568字节
            XCTAssertEqual(ciphertext.count, 1568, "ML-KEM-1024密文长度应该是1568字节")
            XCTAssertEqual(sharedSecret1.count, 32, "共享密钥长度应该是32字节")
            
            print("✅ ML-KEM-1024封装成功")
            print("   密文长度: \(ciphertext.count) 字节")
            print("   共享密钥长度: \(sharedSecret1.count) 字节")
            
            let sharedSecret2 = try await provider.kemDecapsulate(
                peerId: testPeerId + "-1024",
                encapsulated: ciphertext,
                kemVariant: "ML-KEM-1024"
            )
            
            XCTAssertEqual(sharedSecret1, sharedSecret2)
            print("✅ ML-KEM-1024解封装成功，密钥匹配")
        }
        #else
        print("⚠️ OQSRAII不可用，跳过此测试")
        #endif
    }
    
 // MARK: - 错误处理测试
    
    func testDecapsulateWithWrongCiphertext() async throws {
        #if canImport(OQSRAII)
        if #available(macOS 14.0, *) {
            guard let provider = PQCProviderFactory.makeProvider() else {
                print("⚠️ PQC提供者不可用，跳过此测试")
                return
            }
            
            let (_, ciphertext) = try await provider.kemEncapsulate(
                peerId: testPeerId,
                kemVariant: "ML-KEM-768"
            )
            
 // 修改密文
            var wrongCiphertext = ciphertext
            wrongCiphertext[0] ^= 0xFF
            
            do {
                let _ = try await provider.kemDecapsulate(
                    peerId: testPeerId,
                    encapsulated: wrongCiphertext,
                    kemVariant: "ML-KEM-768"
                )
                
 // 注意：某些KEM实现可能不会失败，而是返回一个随机的共享密钥（用于防止侧信道攻击）
 // 这是符合ML-KEM规范的行为
                print("⚠️ 解封装没有失败（可能是隐式拒绝实现）")
            } catch {
 // 显式拒绝实现
                print("✅ 错误密文被正确拒绝")
            }
        }
        #else
        print("⚠️ OQSRAII不可用，跳过此测试")
        #endif
    }
    
 // MARK: - 多次封装测试
    
    func testMultipleEncapsulations() async throws {
        #if canImport(OQSRAII)
        if #available(macOS 14.0, *) {
            guard let provider = PQCProviderFactory.makeProvider() else {
                print("⚠️ PQC提供者不可用，跳过此测试")
                return
            }
            
            var secrets: [Data] = []
            var ciphertexts: [Data] = []
            
 // 执行多次封装
            for i in 0..<5 {
                let (secret, ciphertext) = try await provider.kemEncapsulate(
                    peerId: "\(testPeerId)-multi-\(i)",
                    kemVariant: "ML-KEM-768"
                )
                secrets.append(secret)
                ciphertexts.append(ciphertext)
            }
            
 // 验证所有密钥都不相同（概率上）
            for i in 0..<secrets.count {
                for j in (i+1)..<secrets.count {
                    XCTAssertNotEqual(secrets[i], secrets[j], "每次封装应该生成不同的密钥")
                }
            }
            
 // 验证所有密文都不相同
            for i in 0..<ciphertexts.count {
                for j in (i+1)..<ciphertexts.count {
                    XCTAssertNotEqual(ciphertexts[i], ciphertexts[j], "每次封装应该生成不同的密文")
                }
            }
            
            print("✅ 多次封装测试通过，所有密钥和密文都不相同")
        }
        #else
        print("⚠️ OQSRAII不可用，跳过此测试")
        #endif
    }
    
 // MARK: - 集成测试：使用KEM密钥进行对称加密
    
    func testKEMWithSymmetricEncryption() async throws {
        #if canImport(OQSRAII)
        if #available(macOS 14.0, *) {
            guard let provider = PQCProviderFactory.makeProvider() else {
                print("⚠️ PQC提供者不可用，跳过此测试")
                return
            }
            
            let crypto = EnhancedPostQuantumCrypto()
            let testMessage = "这是一条使用KEM密钥加密的消息"
            
 // 1. 执行密钥封装
            let (sharedSecret, ciphertext) = try await provider.kemEncapsulate(
                peerId: testPeerId,
                kemVariant: "ML-KEM-768"
            )
            
 // 2. 使用共享密钥作为对称密钥
            let symmetricKey = SymmetricKey(data: sharedSecret)
            
 // 3. 加密消息
            let encryptedMessage = try await crypto.encrypt(testMessage, using: symmetricKey)
            
 // 4. 解封装密钥
            let recoveredSecret = try await provider.kemDecapsulate(
                peerId: testPeerId,
                encapsulated: ciphertext,
                kemVariant: "ML-KEM-768"
            )
            
 // 5. 使用解封装的密钥解密
            let recoveredKey = SymmetricKey(data: recoveredSecret)
            let decryptedMessage = try await crypto.decrypt(encryptedMessage, using: recoveredKey)
            
            XCTAssertEqual(testMessage, decryptedMessage, "解密后的消息应该与原消息相同")
            print("✅ KEM + 对称加密集成测试通过")
        }
        #else
        print("⚠️ OQSRAII不可用，跳过此测试")
        #endif
    }
}
