//
// CryptoProviderSelector.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Crypto Provider Selection
// Requirements: 4.2, 9.1
//
// Tech Debt Cleanup - 6.2: 使用 CryptoProviderFactory
// - 委托给 CryptoProviderFactory 进行 Provider 选择
// - 保持现有 public API 不变
//
// 多 Provider 加密选择器，根据平台版本选择最佳加密实现。
// - macOS 26+: CryptoKit PQC (X-Wing, ML-KEM, ML-DSA)
// - 低版本: liboqs fallback 或经典加密
//

import Foundation
import CryptoKit

// MARK: - Crypto Provider Type

/// 加密 Provider 类型
public enum CryptoProviderType: String, Codable, Sendable, CaseIterable {
 /// iOS 26+/macOS 26+: CryptoKit PQC
    case cryptoKitPQC = "CryptoKit-PQC"
    
 /// 低版本 PQC fallback (liboqs)
    case liboqs = "liboqs"
    
 /// Swift Crypto (经典)
    case swiftCrypto = "SwiftCrypto"
    
 /// CryptoKit 经典 (P-256/X25519)
    case classic = "CryptoKit-Classic"
    
 /// 是否支持 PQC
    public var supportsPQC: Bool {
        switch self {
        case .cryptoKitPQC, .liboqs:
            return true
        case .swiftCrypto, .classic:
            return false
        }
    }
    
 /// 显示名称
    public var displayName: String {
        switch self {
        case .cryptoKitPQC: return "CryptoKit PQC (iOS 26+)"
        case .liboqs: return "liboqs (Fallback)"
        case .swiftCrypto: return "Swift Crypto"
        case .classic: return "CryptoKit Classic"
        }
    }
    
 /// 安全等级描述
    public var securityLevel: String {
        switch self {
        case .cryptoKitPQC: return "量子安全 (原生)"
        case .liboqs: return "量子安全 (第三方)"
        case .swiftCrypto, .classic: return "经典安全"
        }
    }
}

// MARK: - KEM Provider Protocol

/// KEM (Key Encapsulation Mechanism) Provider 协议
public protocol KEMProvider: Sendable {
 /// 算法名称
    var algorithmName: String { get }
    
 /// 是否为 PQC 算法
    var isPQC: Bool { get }
    
 /// 生成密钥对
 /// - Returns: (publicKey, privateKey)
    func generateKeyPair() async throws -> (publicKey: Data, privateKey: Data)
    
 /// 封装（使用对方公钥生成共享密钥）
 /// - Parameter publicKey: 对方公钥
 /// - Returns: (sharedSecret, encapsulatedKey)
    func encapsulate(publicKey: Data) async throws -> (sharedSecret: Data, encapsulated: Data)
    
 /// 解封装（使用私钥恢复共享密钥）
 /// - Parameters:
 /// - encapsulated: 封装的密钥
 /// - privateKey: 本方私钥
 /// - Returns: 共享密钥
    func decapsulate(encapsulated: Data, privateKey: Data) async throws -> Data
}

// MARK: - Signature Provider Protocol

/// 签名 Provider 协议
public protocol SignatureProvider: Sendable {
 /// 算法名称
    var algorithmName: String { get }
    
 /// 是否为 PQC 算法
    var isPQC: Bool { get }
    
 /// 生成签名密钥对
 /// - Returns: (publicKey, privateKey)
    func generateKeyPair() async throws -> (publicKey: Data, privateKey: Data)
    
 /// 签名
 /// - Parameters:
 /// - data: 待签名数据
 /// - privateKey: 私钥
 /// - Returns: 签名
    func sign(data: Data, privateKey: Data) async throws -> Data
    
 /// 验证签名
 /// - Parameters:
 /// - data: 原始数据
 /// - signature: 签名
 /// - publicKey: 公钥
 /// - Returns: 是否验证通过
    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool
}

// MARK: - Crypto Capabilities

/// 加密能力声明
public struct CryptoCapabilities: Codable, Sendable, Equatable, TranscriptEncodable {
 /// 支持的 KEM 算法
    public let supportedKEM: [String]
    
 /// 支持的签名算法（身份签名；长期 P-256，独立于 KEM/套件）
    public let supportedSignature: [String]
    
 /// 支持的认证配置（Classic/PQC/Hybrid）
    public let supportedAuthProfiles: [String]
    
 /// 支持的 AEAD 算法
    public let supportedAEAD: [String]
    
 /// PQC 是否可用
    public let pqcAvailable: Bool
    
 /// 平台版本
    public let platformVersion: String
    
 /// Provider 类型
    public let providerType: CryptoProviderType
    
    public init(
        supportedKEM: [String],
        supportedSignature: [String],
        supportedAuthProfiles: [String],
        supportedAEAD: [String],
        pqcAvailable: Bool,
        platformVersion: String,
        providerType: CryptoProviderType
    ) {
        self.supportedKEM = supportedKEM
        self.supportedSignature = supportedSignature
        self.supportedAuthProfiles = supportedAuthProfiles
        self.supportedAEAD = supportedAEAD
        self.pqcAvailable = pqcAvailable
        self.platformVersion = platformVersion
        self.providerType = providerType
    }
    
 /// 确定性编码（用于 Transcript）
    public func deterministicEncode() throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(supportedKEM)
        encoder.encode(supportedSignature)
        encoder.encode(supportedAuthProfiles)
        encoder.encode(supportedAEAD)
        encoder.encode(pqcAvailable)
        encoder.encode(platformVersion)
        encoder.encode(providerType.rawValue)
        return encoder.finalize()
    }
}

// MARK: - Negotiated Crypto Profile

/// 协商后的加密配置
public struct NegotiatedCryptoProfile: Codable, Sendable, Equatable, TranscriptEncodable {
 /// 协商的 KEM 算法
    public let kemAlgorithm: String
    
 /// 协商的认证配置（Classic/PQC/Hybrid）
    public let authProfile: String
    
 /// 协商的签名算法（兼容字段）
    public let signatureAlgorithm: String
    
 /// 握手阶段使用的 AEAD/密封模式描述
    public let handshakeAeadAlgorithm: String?
    
 /// 协商的 AEAD 算法
    public let aeadAlgorithm: String
    
 /// QUIC Datagram 是否启用
    public let quicDatagramEnabled: Bool
    
 /// PQC 是否启用
    public let pqcEnabled: Bool
    
 /// 协商时间戳
    public let negotiatedAt: Date
    
    public init(
        kemAlgorithm: String,
        authProfile: String,
        signatureAlgorithm: String,
        aeadAlgorithm: String,
        quicDatagramEnabled: Bool,
        pqcEnabled: Bool,
        handshakeAeadAlgorithm: String? = nil,
        negotiatedAt: Date = Date()
    ) {
        self.kemAlgorithm = kemAlgorithm
        self.authProfile = authProfile
        self.signatureAlgorithm = signatureAlgorithm
        self.handshakeAeadAlgorithm = handshakeAeadAlgorithm
        self.aeadAlgorithm = aeadAlgorithm
        self.quicDatagramEnabled = quicDatagramEnabled
        self.pqcEnabled = pqcEnabled
        self.negotiatedAt = negotiatedAt
    }
    
 /// 确定性编码（用于 Transcript）
    public func deterministicEncode() throws -> Data {
        var encoder = DeterministicEncoder()
        encoder.encode(kemAlgorithm)
        encoder.encode(authProfile)
        encoder.encode(signatureAlgorithm)
        encoder.encode(handshakeAeadAlgorithm ?? "")
        encoder.encode(aeadAlgorithm)
        encoder.encode(quicDatagramEnabled)
        encoder.encode(pqcEnabled)
        encoder.encode(negotiatedAt)
        return encoder.finalize()
    }
}

// MARK: - Crypto Provider Selector

/// 加密 Provider 选择器
/// 根据平台版本和运行时能力选择最佳加密实现
@available(macOS 14.0, iOS 17.0, *)
public actor CryptoProviderSelector {
    
 // MARK: - Singleton
    
 /// 共享实例
    public static let shared = CryptoProviderSelector()
    
 // MARK: - Properties
    
 /// liboqs 是否可用（运行时检测）
    private var _liboqsAvailable: Bool?
    
 /// 缓存的最佳 Provider
    private var _cachedBestProvider: CryptoProviderType?
    
 /// 缓存的本机能力
    private var _cachedCapabilities: CryptoCapabilities?
    
 // MARK: - Initialization
    
    private init() {}
    
 // MARK: - Public Properties
    
 /// 当前可用的最佳 Provider
    public var bestAvailableProvider: CryptoProviderType {
        get async {
            if let cached = _cachedBestProvider {
                return cached
            }
            let provider = await detectBestProvider()
            _cachedBestProvider = provider
            return provider
        }
    }
    
 /// 检查 PQC 是否可用
    public var isPQCAvailable: Bool {
        get async {
 // iOS 26+/macOS 26+: CryptoKit PQC
            if #available(iOS 26.0, macOS 26.0, *) {
                return true
            }
 // 低版本检查 liboqs
            return await isLiboqsAvailable
        }
    }
    
 /// liboqs 是否可用
    public var isLiboqsAvailable: Bool {
        get async {
            if let cached = _liboqsAvailable {
                return cached
            }
            let available = await detectLiboqsAvailability()
            _liboqsAvailable = available
            return available
        }
    }
    
 // MARK: - Provider Access
    
 /// 获取 KEM Provider
    public func getKEMProvider() async -> any KEMProvider {
        let providerType = await bestAvailableProvider
        
        switch providerType {
        case .cryptoKitPQC:
 // iOS 26+ 使用 CryptoKit PQC
            if #available(iOS 26.0, macOS 26.0, *) {
                return CryptoKitPQCKEMProvider()
            }
 // Fallback
            return X25519KEMProvider()
            
        case .liboqs:
 // 使用 liboqs 实现
            return LiboqsKEMProvider()
            
        case .swiftCrypto, .classic:
 // 经典 X25519
            return X25519KEMProvider()
        }
    }
    
 /// 获取签名 Provider
    public func getSignatureProvider() async -> any SignatureProvider {
        let providerType = await bestAvailableProvider
        
        switch providerType {
        case .cryptoKitPQC:
 // iOS 26+ 使用 CryptoKit PQC
            if #available(iOS 26.0, macOS 26.0, *) {
                return CryptoKitPQCSignatureProvider()
            }
 // Fallback
            return P256SignatureProvider()
            
        case .liboqs:
 // 使用 liboqs 实现
            return LiboqsSignatureProvider()
            
        case .swiftCrypto, .classic:
 // 经典 P-256
            return P256SignatureProvider()
        }
    }
    
 // MARK: - Capability Negotiation
    
 /// 获取本机加密能力
    public func getLocalCapabilities() async -> CryptoCapabilities {
        if let cached = _cachedCapabilities {
            return cached
        }
        
        let providerType = await bestAvailableProvider
        let pqcAvailable = await isPQCAvailable
        
        var supportedKEM: [String] = []
        var supportedSignature: [String] = []
        var supportedAuthProfiles: [String] = []
        let supportedAEAD: [String] = [
            P2PCryptoAlgorithm.aes256GCM.rawValue,
            P2PCryptoAlgorithm.chaCha20Poly1305.rawValue
        ]
        
 // 根据 Provider 类型确定支持的算法
        switch providerType {
        case .cryptoKitPQC:
            supportedKEM = [
                P2PCryptoAlgorithm.xWing.rawValue,
                P2PCryptoAlgorithm.mlKEM768.rawValue,
                P2PCryptoAlgorithm.x25519.rawValue
            ]
            supportedSignature = [P2PCryptoAlgorithm.p256.rawValue]
            supportedAuthProfiles = [
                AuthProfile.hybrid.displayName,
                AuthProfile.pqc.displayName,
                AuthProfile.classic.displayName
            ]
            
        case .liboqs:
            supportedKEM = [
                P2PCryptoAlgorithm.mlKEM768.rawValue,
                P2PCryptoAlgorithm.x25519.rawValue
            ]
            supportedSignature = [P2PCryptoAlgorithm.p256.rawValue]
            supportedAuthProfiles = [
                AuthProfile.hybrid.displayName,
                AuthProfile.pqc.displayName,
                AuthProfile.classic.displayName
            ]
            
        case .swiftCrypto, .classic:
            supportedKEM = [P2PCryptoAlgorithm.x25519.rawValue]
            supportedSignature = [P2PCryptoAlgorithm.p256.rawValue]
            supportedAuthProfiles = [AuthProfile.classic.displayName]
        }
        
        let capabilities = CryptoCapabilities(
            supportedKEM: supportedKEM,
            supportedSignature: supportedSignature,
            supportedAuthProfiles: supportedAuthProfiles,
            supportedAEAD: supportedAEAD,
            pqcAvailable: pqcAvailable,
            platformVersion: getPlatformVersion(),
            providerType: providerType
        )
        
        _cachedCapabilities = capabilities
        return capabilities
    }
    
 /// 运行时能力协商
 /// - Parameter peerCapabilities: 对端能力
 /// - Returns: 协商后的加密配置
    public func negotiateCapabilities(
        with peerCapabilities: CryptoCapabilities
    ) async -> NegotiatedCryptoProfile {
        let localCapabilities = await getLocalCapabilities()
        
 // KEM 算法协商（优先 PQC）
        let kemAlgorithm = negotiateAlgorithm(
            local: localCapabilities.supportedKEM,
            remote: peerCapabilities.supportedKEM,
            preferPQC: true
        )
        
 // 签名算法协商（身份签名，独立于 KEM/套件）
        let signatureAlgorithm = negotiateAlgorithm(
            local: localCapabilities.supportedSignature,
            remote: peerCapabilities.supportedSignature,
            preferPQC: false
        )
        
 // 认证配置协商（优先 Hybrid）
        let authProfile = negotiateAuthProfile(
            local: localCapabilities.supportedAuthProfiles,
            remote: peerCapabilities.supportedAuthProfiles
        )
        
 // AEAD 算法协商（优先 AES-256-GCM）
        let aeadAlgorithm = negotiateAlgorithm(
            local: localCapabilities.supportedAEAD,
            remote: peerCapabilities.supportedAEAD,
            preferPQC: false
        )
        
        let handshakeAeadAlgorithm: String
        if kemAlgorithm == "X25519" {
            handshakeAeadAlgorithm = "HPKE-ChaCha20-Poly1305"
        } else {
            handshakeAeadAlgorithm = "AES-256-GCM"
        }
        
 // 判断是否启用 PQC
        let pqcEnabled = P2PCryptoAlgorithm(rawValue: kemAlgorithm)?.isPQC ?? false
        
        return NegotiatedCryptoProfile(
            kemAlgorithm: kemAlgorithm,
            authProfile: authProfile,
            signatureAlgorithm: signatureAlgorithm,
            aeadAlgorithm: aeadAlgorithm,
            quicDatagramEnabled: true, // QUIC Datagram 在 iOS 16+/macOS 13+ 可用
            pqcEnabled: pqcEnabled,
            handshakeAeadAlgorithm: handshakeAeadAlgorithm
        )
    }

    private func negotiateAuthProfile(local: [String], remote: [String]) -> String {
        let remoteSet = Set(remote)
        for profile in local where remoteSet.contains(profile) {
            return profile
        }
        return AuthProfile.classic.displayName
    }
    
 /// 清除缓存（用于测试或重新检测）
    public func clearCache() {
        _cachedBestProvider = nil
        _cachedCapabilities = nil
        _liboqsAvailable = nil
    }
    
 // MARK: - Private Methods
    
 /// 检测最佳 Provider
 /// **Tech Debt Cleanup - 6.2**: 委托给 CryptoProviderFactory
    private func detectBestProvider() async -> CryptoProviderType {
 // 使用 CryptoProviderFactory 检测能力
        let environment = SystemCryptoEnvironment.system
        let capability = CryptoProviderFactory.Capability(
            hasApplePQC: environment.checkApplePQCAvailable(),
            hasLiboqs: environment.checkLiboqsAvailable(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        
 // 根据能力映射到 CryptoProviderType
        if capability.hasApplePQC {
            return .cryptoKitPQC
        } else if capability.hasLiboqs {
            return .liboqs
        } else {
            return .classic
        }
    }
    
 /// 检测 liboqs 可用性
 /// **Tech Debt Cleanup - 6.2**: 委托给 SystemCryptoEnvironment
    private func detectLiboqsAvailability() async -> Bool {
        return SystemCryptoEnvironment.system.checkLiboqsAvailable()
    }
    
 /// 获取平台版本字符串
    private func getPlatformVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        return "macOS \(version.majorVersion).\(version.minorVersion)"
        #elseif os(iOS)
        return "iOS \(version.majorVersion).\(version.minorVersion)"
        #else
        return "Unknown \(version.majorVersion).\(version.minorVersion)"
        #endif
    }
    
 /// 算法协商
 /// - Parameters:
 /// - local: 本地支持的算法
 /// - remote: 远端支持的算法
 /// - preferPQC: 是否优先 PQC
 /// - Returns: 协商结果
    private func negotiateAlgorithm(
        local: [String],
        remote: [String],
        preferPQC: Bool
    ) -> String {
 // 找出双方都支持的算法
        let common = local.filter { remote.contains($0) }
        
        guard !common.isEmpty else {
 // 没有共同支持的算法，返回本地第一个（会导致协商失败）
            return local.first ?? ""
        }
        
        if preferPQC {
 // 优先选择 PQC 算法
            let pqcAlgorithms = common.filter {
                P2PCryptoAlgorithm(rawValue: $0)?.isPQC ?? false
            }
            if let pqc = pqcAlgorithms.first {
                return pqc
            }
        }
        
 // 返回第一个共同支持的算法
        return common.first ?? local.first ?? ""
    }
}

// MARK: - Crypto Provider Error

/// 加密 Provider 错误
public enum CryptoProviderError: Error, LocalizedError, Sendable {
    case unsupportedAlgorithm(String)
    case keyGenerationFailed(String)
    case encapsulationFailed(String)
    case decapsulationFailed(String)
    case signatureFailed(String)
    case verificationFailed(String)
    case invalidKeyFormat
    case providerNotAvailable(CryptoProviderType)
    case notImplemented(String)
    
 // HPKESealedBox 解析错误 ( 7: DoS 防护)
    case invalidSealedBox(String)
    case invalidMagic
    case unsupportedVersion(UInt8)
    case lengthExceeded(String, Int, Int)  // field, actual, max
    case invalidNonceLength(Int)
    case invalidTagLength(Int)
    case lengthOverflow
    case lengthMismatch(expected: Int, actual: Int)
    
 // 密钥材料错误 ( 8: 类型安全)
    case invalidKeyLength(expected: Int, actual: Int, suite: String, usage: KeyUsage)
    case keyUsageMismatch(expected: KeyUsage, actual: KeyUsage)
    
 // 通用操作错误 ( 4: OQSPQCProvider)
    case operationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .unsupportedAlgorithm(let alg):
            return "Unsupported algorithm: \(alg)"
        case .keyGenerationFailed(let reason):
            return "Key generation failed: \(reason)"
        case .encapsulationFailed(let reason):
            return "Encapsulation failed: \(reason)"
        case .decapsulationFailed(let reason):
            return "Decapsulation failed: \(reason)"
        case .signatureFailed(let reason):
            return "Signature failed: \(reason)"
        case .verificationFailed(let reason):
            return "Verification failed: \(reason)"
        case .invalidKeyFormat:
            return "Invalid key format"
        case .providerNotAvailable(let type):
            return "Crypto provider not available: \(type.rawValue)"
        case .notImplemented(let msg):
            return "Not implemented: \(msg)"
        case .invalidSealedBox(let reason):
            return "Invalid sealed box: \(reason)"
        case .invalidMagic:
            return "Invalid HPKE magic bytes"
        case .unsupportedVersion(let v):
            return "Unsupported HPKE version: \(v)"
        case .lengthExceeded(let field, let actual, let max):
            return "Length exceeded for \(field): \(actual) > \(max)"
        case .invalidNonceLength(let len):
            return "Invalid nonce length: \(len) (expected 12)"
        case .invalidTagLength(let len):
            return "Invalid tag length: \(len) (expected 16)"
        case .lengthOverflow:
            return "Length field overflow detected"
        case .lengthMismatch(let expected, let actual):
            return "Length mismatch: expected \(expected), got \(actual)"
        case .invalidKeyLength(let expected, let actual, let suite, let usage):
            return "Invalid key length for \(suite)/\(usage.rawValue): expected \(expected), got \(actual)"
        case .keyUsageMismatch(let expected, let actual):
            return "Key usage mismatch: expected \(expected.rawValue), got \(actual.rawValue)"
        case .operationFailed(let reason):
            return "Crypto operation failed: \(reason)"
        }
    }
}
