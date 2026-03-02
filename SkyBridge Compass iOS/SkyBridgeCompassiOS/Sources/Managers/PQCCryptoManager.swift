//
// PQCCryptoManager.swift
// SkyBridgeCompassiOS
//
// PQC 加密管理器 - 后量子密码学加密管理
// 使用 CryptoProvider 架构，与 macOS 完全兼容
//

import Foundation
import CryptoKit
import Security

/// PQC 加密管理器 - 后量子密码学加密管理
/// 使用 ML-KEM-768 (Kyber) 和 ML-DSA-65 (Dilithium) 算法
@available(iOS 17.0, *)
@MainActor
public class PQCCryptoManager: ObservableObject {
    public static let instance = PQCCryptoManager()
    
    // MARK: - Published Properties
    
    @Published public var hasKeyPair: Bool = false
    @Published public var keyGenerationDate: Date?
    @Published public var enforcePQCHandshake: Bool = true {
        didSet {
            // "Enforce PQC" is defined as strictPQC in the paper (no classic fallback).
            // Keep the UI + behavior consistent: turning this on force-disables classic fallback.
            if enforcePQCHandshake {
                allowClassicFallbackForCompatibility = false
            }
        }
    }
    /// 兼容旧设备：允许在 PQC 握手失败时回退 classic（不推荐；论文/26.2 默认关闭）
    @Published public var allowClassicFallbackForCompatibility: Bool = false {
        didSet { UserDefaults.standard.set(allowClassicFallbackForCompatibility, forKey: "pqc_allow_classic_fallback") }
    }
    @Published public var autoKeyRotation: Bool = false
    @Published public var keyRotationDays: Int = 30
    @Published public private(set) var currentTier: CryptoTier = .classic
    @Published public private(set) var currentSuite: CryptoSuite = .x25519Ed25519
    
    // MARK: - Private Properties
    
    /// 当前使用的 CryptoProvider
    private var cryptoProvider: any CryptoProvider
    
    /// KEM 密钥对
    private var kemPrivateKey: SecureBytes?
    private var kemPublicKey: Data?
    
    /// 签名密钥对
    private var signingPrivateKey: SecureBytes?
    private var signingPublicKey: Data?
    
    // Keychain 存储（统一使用 Core/Security/KeychainManager.swift）
    
    private let keychainManager = KeychainManager.shared
    
    private init() {
        // 初始化 CryptoProvider
        self.cryptoProvider = CryptoProviderFactory.make(policy: Self.selectionPolicy(enforcePQC: true, allowClassicFallbackForCompatibility: false))
        self.currentTier = cryptoProvider.tier
        self.currentSuite = cryptoProvider.activeSuite
        
        loadKeysFromKeychain()
        allowClassicFallbackForCompatibility = UserDefaults.standard.bool(forKey: "pqc_allow_classic_fallback")
    }
    
    // MARK: - Public Methods
    
    /// 初始化 PQC 系统
    public func initialize() async throws {
        // 重新检测能力并选择最佳 Provider
        self.cryptoProvider = CryptoProviderFactory.make(policy: Self.selectionPolicy(
            enforcePQC: enforcePQCHandshake,
            allowClassicFallbackForCompatibility: allowClassicFallbackForCompatibility
        ))
        self.currentTier = cryptoProvider.tier
        self.currentSuite = cryptoProvider.activeSuite
        
        if !hasKeyPair {
            try await generateKeyPair()
        }
        
        SkyBridgeLogger.shared.info("✅ PQC 加密系统已初始化 (Tier: \(currentTier.rawValue), Suite: \(currentSuite.rawValue))")
    }

    private static func selectionPolicy(
        enforcePQC: Bool,
        allowClassicFallbackForCompatibility: Bool
    ) -> CryptoProviderFactory.SelectionPolicy {
        guard enforcePQC else { return .classicOnly }
        // 26.2 默认严格：requirePQC（禁降级）。若用户启用兼容开关，则改为 preferPQC。
        if #available(iOS 26.0, *) {
            return allowClassicFallbackForCompatibility ? .preferPQC : .requirePQC
        }
        return .preferPQC
    }
    
    /// 生成密钥对
    public func generateKeyPair() async throws {
        SkyBridgeLogger.shared.info("🔑 正在生成密钥对 (Suite: \(currentSuite.rawValue))...")

        // 冷启动性能：将重型密钥生成放到后台线程，避免阻塞主线程/UI。
        let provider = cryptoProvider
        let (kemKeyPair, sigKeyPair) = try await Task.detached(priority: .userInitiated) {
            let kem = try await provider.generateKeyPair(for: .keyExchange)
            let sig = try await provider.generateKeyPair(for: .signing)
            return (kem, sig)
        }.value

        kemPrivateKey = SecureBytes(data: kemKeyPair.privateKey.bytes)
        kemPublicKey = kemKeyPair.publicKey.bytes
        signingPrivateKey = SecureBytes(data: sigKeyPair.privateKey.bytes)
        signingPublicKey = sigKeyPair.publicKey.bytes

        // 保存到 Keychain
        try keychainManager.savePrivateKey(kemKeyPair.privateKey.bytes, identifier: "pqc.kem.private.\(currentSuite.wireId)")
        try keychainManager.savePublicKey(kemKeyPair.publicKey.bytes, identifier: "pqc.kem.public.\(currentSuite.wireId)")
        try keychainManager.savePrivateKey(sigKeyPair.privateKey.bytes, identifier: "pqc.sig.private.\(currentSuite.wireId)")
        try keychainManager.savePublicKey(sigKeyPair.publicKey.bytes, identifier: "pqc.sig.public.\(currentSuite.wireId)")

        hasKeyPair = true
        keyGenerationDate = Date()

        SkyBridgeLogger.shared.info("✅ 密钥对生成完成 (KEM Public: \(kemPublicKey?.count ?? 0) bytes, Signing Public: \(signingPublicKey?.count ?? 0) bytes)")
    }
    
    /// 重新生成密钥对
    public func regenerateKeyPair() async throws {
        // 清零旧密钥
        kemPrivateKey?.zeroize()
        signingPrivateKey?.zeroize()
        
        // 删除旧密钥
        keychainManager.deleteKey(identifier: "pqc.kem.private.\(currentSuite.wireId)")
        keychainManager.deleteKey(identifier: "pqc.kem.public.\(currentSuite.wireId)")
        keychainManager.deleteKey(identifier: "pqc.sig.private.\(currentSuite.wireId)")
        keychainManager.deleteKey(identifier: "pqc.sig.public.\(currentSuite.wireId)")
        
        hasKeyPair = false
        
        // 生成新密钥
        try await generateKeyPair()
    }
    
    /// 获取 KEM 公钥
    public func getKEMPublicKey() async throws -> Data {
        guard let publicKey = kemPublicKey else {
            throw PQCError.noPublicKey
        }
        return publicKey
    }
    
    /// 获取签名公钥
    public func getSigningPublicKey() async throws -> Data {
        guard let publicKey = signingPublicKey else {
            throw PQCError.noPublicKey
        }
        return publicKey
    }
    
    /// 执行 KEM 封装（用于建立共享密钥）
    public func kemEncapsulate(remotePublicKey: Data) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        SkyBridgeLogger.shared.info("🔐 执行 KEM 封装 (Suite: \(currentSuite.rawValue))...")
        
        let result = try await cryptoProvider.kemEncapsulate(recipientPublicKey: remotePublicKey)
        
        SkyBridgeLogger.shared.info("✅ KEM 封装完成")
        return result
    }
    
    /// 执行 KEM 解封装
    public func kemDecapsulate(encapsulatedKey: Data) async throws -> SecureBytes {
        guard let privateKey = kemPrivateKey else {
            throw PQCError.noPrivateKey
        }
        
        SkyBridgeLogger.shared.info("🔐 执行 KEM 解封装...")
        
        let sharedSecret = try await cryptoProvider.kemDecapsulate(
            encapsulatedKey: encapsulatedKey,
            privateKey: privateKey
        )
        
        SkyBridgeLogger.shared.info("✅ KEM 解封装完成")
        return sharedSecret
    }
    
    /// 签名数据
    public func sign(data: Data) async throws -> Data {
        guard let privateKey = signingPrivateKey else {
            throw PQCError.noPrivateKey
        }
        
        let keyHandle = SigningKeyHandle.softwareKey(privateKey.copyData())
        return try await cryptoProvider.sign(data: data, using: keyHandle)
    }
    
    /// 验证签名
    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        return try await cryptoProvider.verify(data: data, signature: signature, publicKey: publicKey)
    }
    
    /// HPKE 封装（完整的 KEM-DEM）
    public func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        return try await cryptoProvider.hpkeSeal(
            plaintext: plaintext,
            recipientPublicKey: recipientPublicKey,
            info: info
        )
    }
    
    /// HPKE 解封装
    public func hpkeOpen(sealedBox: HPKESealedBox, info: Data) async throws -> Data {
        guard let privateKey = kemPrivateKey else {
            throw PQCError.noPrivateKey
        }
        
        return try await cryptoProvider.hpkeOpen(
            sealedBox: sealedBox,
            privateKey: privateKey,
            info: info
        )
    }
    
    /// 验证设备
    public func verifyDevice(_ device: DiscoveredDevice, code: String) async throws {
        // 验证 6 位数字码
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            throw PQCError.invalidCode
        }

        // 1) 要求存在已建立的会话（验证码与握手 transcriptHash 绑定）
        guard let suite = P2PConnectionManager.instance.negotiatedSuiteByDeviceId[device.id] else {
            throw PQCError.verificationFailed
        }

        // 2) 严格模式：要求已切换到 PQC/Hybrid suite（论文 strictPQC）
        if enforcePQCHandshake, !suite.isPQCGroup {
            throw PQCError.verificationFailed
        }

        // 3) 生成期望验证码并比对
        guard let expected = P2PConnectionManager.instance.pairingVerificationCode(for: device.id) else {
            throw PQCError.verificationFailed
        }
        guard expected == code else {
            SkyBridgeLogger.shared.warning("❌ 设备验证码不匹配: device=\(device.name) expected=\(expected) got=\(code)")
            throw PQCError.verificationFailed
        }

        // 先落一个“可信设备持久化”闭环：验证成功即加入可信列表（设置页可见、可撤销）
        TrustedDeviceStore.shared.trust(device)
        
        SkyBridgeLogger.shared.info("✅ 设备验证成功: \(device.name)")
    }
    
    /// 获取当前 Provider 信息
    public var providerInfo: String {
        "\(cryptoProvider.providerName) (\(currentTier.rawValue))"
    }
    
    /// 是否使用 PQC
    public var isPQCActive: Bool {
        currentTier == .nativePQC || currentTier == .liboqsPQC
    }
    
    // MARK: - Private Methods
    
    private func loadKeysFromKeychain() {
        // 尝试加载当前 suite 的密钥
        if let kemPrivateData = try? keychainManager.loadPrivateKey(identifier: "pqc.kem.private.\(currentSuite.wireId)"),
           let kemPublicData = try? keychainManager.loadPublicKey(identifier: "pqc.kem.public.\(currentSuite.wireId)"),
           let sigPrivateData = try? keychainManager.loadPrivateKey(identifier: "pqc.sig.private.\(currentSuite.wireId)"),
           let sigPublicData = try? keychainManager.loadPublicKey(identifier: "pqc.sig.public.\(currentSuite.wireId)") {
            
            kemPrivateKey = SecureBytes(data: kemPrivateData)
            kemPublicKey = kemPublicData
            signingPrivateKey = SecureBytes(data: sigPrivateData)
            signingPublicKey = sigPublicData
            hasKeyPair = true
            
            // 从 Keychain attributes 读取创建时间（若不可用则保持 nil）
            keyGenerationDate = keychainItemCreationDate(account: "pqc.kem.private.\(currentSuite.wireId)")
            
            SkyBridgeLogger.shared.info("✅ 从 Keychain 加载密钥成功")
        }
    }

    private func keychainItemCreationDate(account: String) -> Date? {
        // In-memory keychain（单元测试模式）不支持属性查询
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let attrs = result as? [String: Any] else {
            return nil
        }
        return attrs[kSecAttrCreationDate as String] as? Date
    }
}

// MARK: - PQC Error

public enum PQCError: Error, LocalizedError {
    case noPublicKey
    case noPrivateKey
    case keyGenerationFailed
    case invalidCode
    case verificationFailed
    case providerNotAvailable
    
    public var errorDescription: String? {
        switch self {
        case .noPublicKey: return "没有公钥"
        case .noPrivateKey: return "没有私钥"
        case .keyGenerationFailed: return "密钥生成失败"
        case .invalidCode: return "验证码无效"
        case .verificationFailed: return "验证失败"
        case .providerNotAvailable: return "PQC Provider 不可用"
        }
    }
}
