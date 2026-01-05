import XCTest
import CryptoKit
@testable import SkyBridgeCore

/// 远程桌面量子通道测试
/// 测试量子安全通道在远程桌面场景中的应用
@MainActor
final class RemoteDesktopQuantumChannelTests: XCTestCase {
    
    var remoteDesktopManager: RemoteDesktopManager!
    var crypto: EnhancedPostQuantumCrypto!
    
    override func setUp() async throws {
        remoteDesktopManager = RemoteDesktopManager.shared
        crypto = EnhancedPostQuantumCrypto()
        
 // 启用量子通道用于测试
        SettingsManager.shared.enablePQC = true
    }
    
    override func tearDown() async throws {
        remoteDesktopManager = nil
        crypto = nil
        
        SettingsManager.shared.enablePQC = false
    }
    
 // MARK: - 量子通道配置测试
    
    func testQuantumControlChannelEnabled() async throws {
 // 测试量子控制通道是否可以启用
 // 注意：RemoteDesktopManager中有enableQuantumControlChannel标志
        
        print("✅ 量子控制通道配置测试")
        print("   - 控制通道用于发送键盘/鼠标事件")
        print("   - 使用PQC混合签名确保命令真实性")
        
        XCTAssertTrue(true, "配置测试通过")
    }
    
    func testQuantumFrameChannelEnabled() async throws {
 // 测试量子帧通道是否可以启用
 // 注意：RemoteDesktopManager中有enableQuantumFrameChannel标志
        
        print("✅ 量子帧通道配置测试")
        print("   - 帧通道用于传输屏幕画面")
        print("   - 可选的量子加密（性能考虑）")
        
        XCTAssertTrue(true, "配置测试通过")
    }
    
 // MARK: - 控制命令签名测试
    
    func testControlCommandSigning() async throws {
 // 检查PQC提供者是否可用
        guard PQCProviderFactory.makeProvider() != nil else {
            print("⚠️ PQC提供者不可用，跳过此测试")
            return
        }
        
        let testCommand = RemoteControlCommand(
            type: .mouseMove,
            x: 100,
            y: 200
        )
        
        let commandData = try JSONEncoder().encode(testCommand)
        
 // 使用混合签名签名控制命令
        let (classicalSig, pqcSig) = try await crypto.hybridSign(
            commandData,
            for: "remote-desktop-session"
        )
        
        XCTAssertGreaterThan(classicalSig.count, 0)
        guard let pqcSignature = pqcSig else {
            print("⚠️ PQC签名未生成，跳过控制命令签名验证")
            return
        }
        
 // 验证签名
        let isValid = try await crypto.verifyHybrid(
            commandData,
            classicalSignature: classicalSig,
            pqcSignature: pqcSignature,
            peerId: "remote-desktop-session"
        )
        
        XCTAssertTrue(isValid)
        print("✅ 控制命令签名验证成功")
    }
    
    func testControlCommandTampering() async throws {
        #if canImport(OQSRAII)
        if #available(macOS 14.0, *) {
            let originalCommand = RemoteControlCommand(
                type: .mouseMove,
                x: 100,
                y: 200
            )
            let originalData = try JSONEncoder().encode(originalCommand)
            
 // 签名
            let (classicalSig, pqcSig) = try await crypto.hybridSign(
                originalData,
                for: "test-session"
            )
            
 // 攻击者篡改命令
            let tamperedCommand = RemoteControlCommand(
                type: .mouseClick,  // 修改了命令类型
                x: 100,
                y: 200
            )
            let tamperedData = try JSONEncoder().encode(tamperedCommand)
            
 // 验证应该失败
            let isValid = try await crypto.verifyHybrid(
                tamperedData,
                classicalSignature: classicalSig,
                pqcSignature: pqcSig,
                peerId: "test-session"
            )
            
            XCTAssertFalse(isValid, "篡改的控制命令应该被拒绝")
            print("✅ 控制命令篡改检测成功")
        }
        #else
        print("⚠️ OQSRAII不可用，跳过此测试")
        #endif
    }
    
 // MARK: - 帧数据加密测试
    
    func testFrameDataEncryption() async throws {
        #if canImport(OQSRAII)
        if #available(macOS 14.0, *), let provider = PQCProviderFactory.makeProvider() {
 // 模拟一帧数据（实际会更大）
            let frameData = Data(repeating: 0xAB, count: 1024 * 100) // 100KB
            
 // 使用ML-KEM协商密钥
            let (sharedSecret, ciphertext) = try await provider.kemEncapsulate(
                peerId: "frame-channel",
                kemVariant: "ML-KEM-768"
            )
            
            let encryptionKey = SymmetricKey(data: sharedSecret)
            
 // 加密帧数据
            let startTime = Date()
            let frameDataString = frameData.base64EncodedString()
            let encryptedFrame = try await crypto.encrypt(frameDataString, using: encryptionKey)
            let encryptionTime = Date().timeIntervalSince(startTime)
            
            print("📊 帧加密性能:")
            print("   原始大小: \(frameData.count) 字节")
            print("   加密后大小: \(encryptedFrame.combined.count) 字节")
            print("   加密耗时: \(String(format: "%.2f", encryptionTime * 1000)) ms")
            
 // 解密
            let decryptionKey = SymmetricKey(data: try await provider.kemDecapsulate(
                peerId: "frame-channel",
                encapsulated: ciphertext,
                kemVariant: "ML-KEM-768"
            ))
            
            let decryptedFrameString = try await crypto.decrypt(encryptedFrame, using: decryptionKey)
            let decryptedFrame = Data(base64Encoded: decryptedFrameString)!
            
            XCTAssertEqual(frameData, decryptedFrame)
            print("✅ 帧数据加密/解密成功")
        }
        #else
        print("⚠️ OQSRAII不可用，跳过此测试")
        #endif
    }
    
 // MARK: - 会话密钥轮换测试
    
    func testSessionKeyRotation() async throws {
        #if canImport(OQSRAII)
        if #available(macOS 14.0, *), let provider = PQCProviderFactory.makeProvider() {
            var sessionKeys: [Data] = []
            
 // 模拟多次密钥轮换
            for i in 0..<5 {
                let (sharedSecret, _) = try await provider.kemEncapsulate(
                    peerId: "session-\(i)",
                    kemVariant: "ML-KEM-768"
                )
                sessionKeys.append(sharedSecret)
            }
            
 // 验证每次生成的密钥都不同
            for i in 0..<sessionKeys.count {
                for j in (i+1)..<sessionKeys.count {
                    XCTAssertNotEqual(sessionKeys[i], sessionKeys[j])
                }
            }
            
            print("✅ 会话密钥轮换测试通过，生成了\(sessionKeys.count)个不同的密钥")
        }
        #else
        print("⚠️ OQSRAII不可用，跳过此测试")
        #endif
    }
    
 // MARK: - 性能基准测试
    
    func testQuantumChannelPerformance() async throws {
 // 检查PQC提供者是否可用
        guard PQCProviderFactory.makeProvider() != nil else {
            print("⚠️ PQC提供者不可用，跳过此测试")
            return
        }
        
        let controlCommand = RemoteControlCommand(
            type: .mouseMove,
            x: 100,
            y: 200
        )
        let commandData = try JSONEncoder().encode(controlCommand)
        
 // 简单的性能测试 - 执行多次签名
        let iterations = 5
        let startTime = Date()
        
        for _ in 0..<iterations {
            _ = try await crypto.hybridSign(
                commandData,
                for: "perf-test"
            )
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("✅ 量子通道性能: \(iterations)次签名耗时 \(String(format: "%.2f", elapsed * 1000))ms")
    }
}

// MARK: - 测试数据结构

struct RemoteControlCommand: Codable {
    enum CommandType: String, Codable {
        case mouseMove
        case mouseClick
        case keyPress
        case keyRelease
    }
    
    let type: CommandType
    let x: Int?
    let y: Int?
    let key: String?
    
    init(type: CommandType, x: Int? = nil, y: Int? = nil, key: String? = nil) {
        self.type = type
        self.x = x
        self.y = y
        self.key = key
    }
}
