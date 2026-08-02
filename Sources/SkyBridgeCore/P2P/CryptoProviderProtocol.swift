//
// CryptoProviderProtocol.swift
// SkyBridgeCore
//
// Tech Debt Cleanup - PQC Provider Architecture Refactoring
// Requirements: 1.1, 1.5, 13.1, 13.2, 13.3
//
// 统一的加密 Provider 协议和类型定义：
// - CryptoProvider 协议：调用方只使用此协议，不关心具体实现
// - CryptoSuite：算法套件（使用 struct 支持前向兼容）
// - CryptoTier：Provider 层级
// - KeyUsage：密钥用途
// - KeyPair/KeyMaterial：类型化密钥材料
// - HPKESealedBox：HPKE 密封盒（含 DoS 防护）
// - CryptoProviderError：错误类型
//

import Foundation
import SkyBridgeProtocolCore

// MARK: - CryptoProvider Protocol

/// 统一的加密 Provider 协议
/// 调用方只使用此协议，不关心具体实现
public protocol CryptoProvider: Sendable {
 /// Provider 标识（用于日志和事件）
    var providerName: String { get }
    
 /// Provider 层级（用于事件，避免字符串判断）
    var tier: CryptoTier { get }
    
 /// 当前使用的算法套件
    var activeSuite: CryptoSuite { get }
    
 /// 支持的所有算法套件（用于 HandshakeOfferedSuites.build）
 ///
 /// ** 7.2**: 数据来源必须是 provider 实际支持的 suites
 /// 不使用静态的 CryptoSuite.allPQCSuites（会 offer 本地不支持的 suite）
    var supportedSuites: [CryptoSuite] { get }

 /// 是否支持指定算法套件
    func supportsSuite(_ suite: CryptoSuite) -> Bool
    
 /// HPKE 封装（KEM）
    func hpkeSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox

 /// KEM-DEM 封装（论文协议的接口）
    func kemDemSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox

 /// KEM-DEM 封装（导出共享密钥）
    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes)
    
 /// HPKE 解封装
    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data
    
 /// HPKE 解封装（SecureBytes 版本，避免 Data 复制）
    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data

 /// KEM-DEM 解封装（论文协议的接口）
    func kemDemOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data

 /// KEM-DEM 解封装（导出共享密钥）
    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes)
    
 /// KEM 封装（仅导出共享密钥与封装结果）
    func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes)
    
 /// KEM 解封装（仅导出共享密钥）
    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes
    
 /// 数字签名
    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data
    
 /// 签名验证
    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool
    
 /// 生成密钥对
    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair
}

/// Explicit extension point for KEMs whose security contract requires a
/// protocol-derived application context. Callers must use these methods rather
/// than the context-free `CryptoProvider` KEM surface.
public protocol ApplicationContextBoundCryptoProvider: CryptoProvider {
    func kemEncapsulate(
        recipientPublicKey: Data,
        applicationContext: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes)

    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes,
        applicationContext: Data
    ) async throws -> SecureBytes
}

// MARK: - SecureBytes Default Implementations

public extension CryptoProvider {
 /// 默认实现：supportedSuites 返回仅包含 activeSuite
    var supportedSuites: [CryptoSuite] {
        if let upgraded = activeSuite.forwardSecureUpgradeSuite,
           upgraded.wireId != activeSuite.wireId {
            return [upgraded, activeSuite]
        }
        return [activeSuite]
    }
    
 /// 默认实现：仅支持当前 activeSuite
    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        suite.providerCompatibilitySuite.wireId == activeSuite.providerCompatibilitySuite.wireId
    }

 /// 默认实现：KEM-DEM 使用现有 HPKE 兼容封装
    func kemDemSeal(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> HPKESealedBox {
        try await hpkeSeal(plaintext: plaintext, recipientPublicKey: recipientPublicKey, info: info)
    }

 /// 默认实现：KEM-DEM 使用现有 HPKE 兼容解封装
    func kemDemOpen(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> Data {
        try await hpkeOpen(sealedBox: sealedBox, privateKey: privateKey, info: info)
    }

 /// 默认实现：不支持共享密钥导出时抛错
    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        throw CryptoProviderError.notImplemented("Shared secret export not supported")
    }

 /// 默认实现：不支持共享密钥导出时抛错
    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.notImplemented("Shared secret export not supported")
    }

 /// 默认实现：不支持 KEM 封装时抛错
    func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.notImplemented("KEM encapsulation not supported")
    }

 /// 默认实现：不支持 KEM 解封装时抛错
    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        throw CryptoProviderError.notImplemented("KEM decapsulation not supported")
    }

 /// 默认实现：将 Data 包装成 SecureBytes 后调用 SecureBytes 版本
    func hpkeOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        let secureKey = SecureBytes(data: privateKey)
        return try await hpkeOpen(sealedBox: sealedBox, privateKey: secureKey, info: info)
    }

 /// 默认实现：将 Data 包装成 SecureBytes 后调用 KEM-DEM 版本
    func kemDemOpen(
        sealedBox: HPKESealedBox,
        privateKey: Data,
        info: Data
    ) async throws -> Data {
        let secureKey = SecureBytes(data: privateKey)
        return try await kemDemOpen(sealedBox: sealedBox, privateKey: secureKey, info: info)
    }
}

// MARK: - KeyPair

public enum KeyPairError: Error, LocalizedError, Sendable, Equatable {
    case suiteMismatch(publicSuite: CryptoSuite, privateSuite: CryptoSuite)
    case usageMismatch(publicUsage: KeyUsage, privateUsage: KeyUsage)

    public var errorDescription: String? {
        switch self {
        case .suiteMismatch(let publicSuite, let privateSuite):
            return "Key-pair suite mismatch: \(publicSuite.rawValue) != \(privateSuite.rawValue)"
        case .usageMismatch(let publicUsage, let privateUsage):
            return "Key-pair usage mismatch: \(publicUsage.rawValue) != \(privateUsage.rawValue)"
        }
    }
}

/// 密钥对（类型化，防止喂错）
///
/// **设计决策**：
/// - 带上 suite + usage，provider 入口先校验
/// - 防止"把 X25519 私钥当成 P-256 私钥传进去"的乌龙
public struct KeyPair: Sendable {
    public let publicKey: KeyMaterial
    public let privateKey: KeyMaterial
    
    public init(publicKey: KeyMaterial, privateKey: KeyMaterial) throws {
        guard publicKey.suite == privateKey.suite else {
            throw KeyPairError.suiteMismatch(
                publicSuite: publicKey.suite,
                privateSuite: privateKey.suite
            )
        }
        guard publicKey.usage == privateKey.usage else {
            throw KeyPairError.usageMismatch(
                publicUsage: publicKey.usage,
                privateUsage: privateKey.usage
            )
        }
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}

// MARK: - KeyMaterial

/// 密钥材料（类型化）
public struct KeyMaterial: Sendable {
    public let suite: CryptoSuite
    public let usage: KeyUsage
    public let bytes: Data
    public let formatVersion: UInt8
    
    public init(suite: CryptoSuite, usage: KeyUsage, bytes: Data, formatVersion: UInt8 = 1) {
        self.suite = suite
        self.usage = usage
        self.bytes = bytes
        self.formatVersion = formatVersion
    }
    
 /// 验证密钥长度是否符合套件要求
    public func validate(isPublic: Bool = true) throws {
        let expectedLength = Self.expectedLength(suite: suite, usage: usage, isPublic: isPublic)
        guard expectedLength > 0 else {
 // 未知套件，跳过长度检查
            return
        }
        guard bytes.count == expectedLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: expectedLength,
                actual: bytes.count,
                suite: suite.rawValue,
                usage: usage
            )
        }
    }
    
 /// 获取预期密钥长度
    private static func expectedLength(suite: CryptoSuite, usage: KeyUsage, isPublic: Bool) -> Int {
        switch (suite.wireId, usage, isPublic) {
 // X25519 + Ed25519
        case (0x1001, .keyExchange, _): return 32
        case (0x1001, .signing, true): return 32
        case (0x1001, .signing, false): return 64
        
 // P-256 + ECDSA
        case (0x1002, .keyExchange, true): return 65  // uncompressed point
        case (0x1002, .keyExchange, false): return 32
        case (0x1002, .signing, true): return 65
        case (0x1002, .signing, false): return 32
        
 // ML-KEM-768 + ML-DSA-65 (Apple CryptoKit uses seed-based compact private keys)
        case (0x0101, .keyExchange, true): return 1184   // ML-KEM-768 公钥
        case (0x0101, .keyExchange, false): return 96    // ML-KEM-768 私钥 (Apple seed format)
        case (0x0101, .signing, true): return 1952       // ML-DSA-65 公钥
        case (0x0101, .signing, false): return 64        // ML-DSA-65 私钥 (Apple seed format)
        case (0x0102, .keyExchange, true): return 1184   // ML-KEM-768-FS 公钥（复用 ML-KEM-768）
        case (0x0102, .keyExchange, false): return 96    // ML-KEM-768-FS 私钥（复用 ML-KEM-768）
        case (0x0102, .signing, true): return 1952       // ML-DSA-65 公钥
        case (0x0102, .signing, false): return 64        // ML-DSA-65 私钥
        
 // X-Wing + ML-DSA-65 (混合)
        case (0x0001, .keyExchange, true): return 1216   // X25519(32) + ML-KEM-768(1184)
        case (0x0001, .keyExchange, false): return 64    // CryptoKit integrity-checked representation
        case (0x0001, .signing, true): return 1952       // ML-DSA-65 公钥
        case (0x0001, .signing, false): return 64        // CryptoKit integrity-checked representation
        
        default: return 0  // 未知套件；调用方必须将缺失的长度契约视为错误
        }
    }
}
