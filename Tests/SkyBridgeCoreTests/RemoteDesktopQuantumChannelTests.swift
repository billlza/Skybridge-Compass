import XCTest
import CryptoKit
@testable import SkyBridgeCore

/// Remote-control payload crypto adapter tests.
/// These tests do not claim transport-level RemoteDesktopManager coverage;
/// the authenticated channel and media paths have their own integration suites.
@MainActor
final class RemoteDesktopQuantumCryptoAdapterTests: XCTestCase {
    private var originalEnablePQC = false
    private var originalPQCSignatureAlgorithm = ""
    private var deviceIdentity: DeviceIdentityKeychainTestContext?
    private var installedTrustIds = Set<String>()

    var crypto: EnhancedPostQuantumCrypto!
    
    override func setUp() async throws {
        originalEnablePQC = SettingsManager.shared.enablePQC
        originalPQCSignatureAlgorithm = SettingsManager.shared.pqcSignatureAlgorithm
        let deviceIdentity = try DeviceIdentityKeychainTestContext()
        self.deviceIdentity = deviceIdentity
        crypto = EnhancedPostQuantumCrypto(
            deviceIdentityKeyManager: deviceIdentity.manager
        )
        SettingsManager.shared.enablePQC = true
        SettingsManager.shared.pqcSignatureAlgorithm = "ML-DSA-65"
    }
    
    override func tearDown() async throws {
        crypto = nil
        let deviceIdentity = self.deviceIdentity
        self.deviceIdentity = nil
        let trust = TrustSyncService.shared
        await trust.removeRecordsForTesting(deviceIds: Array(installedTrustIds))
        trust.setInMemoryPersistenceForTesting(false)
        installedTrustIds.removeAll()
        SettingsManager.shared.enablePQC = originalEnablePQC
        SettingsManager.shared.pqcSignatureAlgorithm = originalPQCSignatureAlgorithm
        try deviceIdentity?.reset()
    }
    
 // MARK: - PQC adapter contract

    func testRequiredPQCControlPayloadSignatureBindsCanonicalAlgorithm() async throws {
        let command = RemoteControlCommand(type: .mouseMove, x: 100, y: 200)
        let commandData = try JSONEncoder().encode(command)
        let signature = try await crypto.signPQCRequiredWithAlgorithm(
            commandData,
            for: "remote-control-required-signature"
        )

        XCTAssertEqual(signature.algorithm, "ML-DSA-65")
        XCTAssertGreaterThan(signature.bytes.count, 3_000)
    }

    func testPQCFrameKeyAgreementProviderIsAvailable() throws {
        let keychain = PQCKeychainTestContext()
        let provider = try XCTUnwrap(
            PQCProviderFactory.makeProvider(scopeSource: keychain.scopeSource)
        )
        XCTAssertEqual(provider.suite, .pqcMlKemMlDsa)
        XCTAssertNotEqual(provider.backend, .none)
    }
    
 // MARK: - 控制命令签名测试
    
    func testControlCommandSigning() async throws {
        try await installLocalProtocolIdentityTrust(for: "remote-desktop-session")
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
        let pqcSignature = try XCTUnwrap(pqcSig)
        
 // 验证签名
        let isValid = try await crypto.verifyHybrid(
            commandData,
            classicalSignature: classicalSig,
            pqcSignature: pqcSignature,
            peerId: "remote-desktop-session"
        )
        
        XCTAssertTrue(isValid)
    }
    
    func testControlCommandTampering() async throws {
        #if canImport(OQSRAII)
        try await installLocalProtocolIdentityTrust(for: "test-session")
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
        let pqcSignature = try XCTUnwrap(pqcSig)

 // 攻击者篡改命令
        let tamperedCommand = RemoteControlCommand(
            type: .mouseClick,
            x: 100,
            y: 200
        )
        let tamperedData = try JSONEncoder().encode(tamperedCommand)

 // 验证应该失败
        let isValid = try await crypto.verifyHybrid(
            tamperedData,
            classicalSignature: classicalSig,
            pqcSignature: pqcSignature,
            peerId: "test-session"
        )

        XCTAssertFalse(isValid, "篡改的控制命令应该被拒绝")
        #else
        throw XCTSkip("This control-command tampering test requires OQSRAII")
        #endif
    }
    
 // MARK: - 帧数据加密测试
    
    func testFrameDataEncryption() async throws {
        #if canImport(OQSRAII)
        let keychain = PQCKeychainTestContext()
        let provider = try XCTUnwrap(
            PQCProviderFactory.makeProvider(scopeSource: keychain.scopeSource)
        )
 // 模拟一帧数据（实际会更大）
        let frameData = Data(repeating: 0xAB, count: 1024 * 100) // 100KB

 // 使用ML-KEM协商密钥
        let (sharedSecret, ciphertext) = try await provider.kemEncapsulate(
            peerId: "frame-channel",
            kemVariant: "ML-KEM-768"
        )

        let encryptionKey = SymmetricKey(data: sharedSecret)

 // 加密帧数据
        let frameDataString = frameData.base64EncodedString()
        let encryptedFrame = try await crypto.encrypt(frameDataString, using: encryptionKey)

 // 解密
        let decryptionKey = SymmetricKey(data: try await provider.kemDecapsulate(
            peerId: "frame-channel",
            encapsulated: ciphertext,
            kemVariant: "ML-KEM-768"
        ))

        let decryptedFrameString = try await crypto.decrypt(encryptedFrame, using: decryptionKey)
        let decryptedFrame = try XCTUnwrap(Data(base64Encoded: decryptedFrameString))

        XCTAssertEqual(frameData, decryptedFrame)
        #else
        throw XCTSkip("This frame-crypto adapter test requires OQSRAII")
        #endif
    }
    
 // MARK: - 会话密钥轮换测试
    
    func testSessionKeyRotation() async throws {
        #if canImport(OQSRAII)
        let keychain = PQCKeychainTestContext()
        let provider = try XCTUnwrap(
            PQCProviderFactory.makeProvider(scopeSource: keychain.scopeSource)
        )
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
            for j in (i + 1)..<sessionKeys.count {
                XCTAssertNotEqual(sessionKeys[i], sessionKeys[j])
            }
        }

        XCTAssertEqual(sessionKeys.count, 5)
        #else
        throw XCTSkip("This key-rotation adapter test requires OQSRAII")
        #endif
    }
    
 // MARK: - 性能基准测试
    
    func testRepeatedQuantumControlSigningProducesPQCSignatures() async throws {
        let controlCommand = RemoteControlCommand(
            type: .mouseMove,
            x: 100,
            y: 200
        )
        let commandData = try JSONEncoder().encode(controlCommand)
        
        let iterations = 5

        for _ in 0..<iterations {
            let signature = try await crypto.hybridSign(
                commandData,
                for: "perf-test"
            )
            XCTAssertNotNil(signature.pqc)
        }
    }

    private func installLocalProtocolIdentityTrust(for peerId: String) async throws {
        guard installedTrustIds.insert(peerId).inserted else { return }
        let publicKey = try await XCTUnwrap(deviceIdentity).manager
            .getProtocolSigningPublicKey(for: .mlDSA65)
        _ = try await installAuthenticatedMLDSATrustRecordForTesting(
            peerId: peerId,
            publicKey: publicKey
        )
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
