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
import SkyBridgeProtocolCore

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

@available(macOS 14.0, iOS 17.0, *)
private struct UnavailableKEMProvider: KEMProvider, Sendable {
    let algorithmName: String
    let isPQC: Bool
    let error: CryptoProviderError

    func generateKeyPair() async throws -> (publicKey: Data, privateKey: Data) {
        throw error
    }

    func encapsulate(publicKey: Data) async throws -> (sharedSecret: Data, encapsulated: Data) {
        throw error
    }

    func decapsulate(encapsulated: Data, privateKey: Data) async throws -> Data {
        throw error
    }
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
            // 低版本：仅当 liboqs 可用时才认为 PQC 可用
            if #unavailable(iOS 26.0, macOS 26.0) {
                return await isLiboqsAvailable
            }

            // iOS 26+/macOS 26+：PQC 也必须满足“编译期类型可用 + 运行时 self-test 通过”
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                if ApplePQCCryptoProvider.selfTest() {
                    return true
                }
            }
            #endif

            // 兜底：如果本机存在 liboqs（例如 macOS 14–15 或特殊构建），依然可以提供 PQC
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
        case .qPeriapt:
            #if canImport(CQPeriapt)
            if isQPeriaptBetaEnabled() {
                return QPeriaptKEMProvider()
            }
            #endif
            return UnavailableKEMProvider(
                algorithmName: P2PCryptoAlgorithm.qperiaptContextBound.rawValue,
                isPQC: true,
                error: CryptoProviderError.providerNotAvailable(.qPeriapt)
            )

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

 /// 按协商出的套件名称获取 KEM Provider（可加性新增）。
 ///
 /// 当协商结果为 "Q-Periapt-ContextBound" 时必须返回 Q provider；若本机 Q-Periapt
 /// admission 未通过，显式抛错，禁止回退到 X25519/其它 provider 掩盖协商漂移。
 /// - Parameter negotiatedSuiteName: 协商得到的 KEM 套件名（`P2PCryptoAlgorithm.rawValue`）
    public func getKEMProvider(forNegotiatedSuite negotiatedSuiteName: String) async throws -> any KEMProvider {
        guard negotiatedSuiteName == P2PCryptoAlgorithm.qperiaptContextBound.rawValue else {
            return await getKEMProvider()
        }
        #if canImport(CQPeriapt)
        if isQPeriaptBetaEnabled() {
            return QPeriaptKEMProvider()
        }
        #endif
        throw CryptoProviderError.providerNotAvailable(.qPeriapt)
    }

 /// 获取签名 Provider
    public func getSignatureProvider() async -> any SignatureProvider {
        let providerType = await bestAvailableProvider

        switch providerType {
        case .qPeriapt:
            return P256SignatureProvider()

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
        case .qPeriapt:
            supportedKEM = [
                P2PCryptoAlgorithm.qperiaptContextBound.rawValue
            ]
            supportedSignature = [
                P2PCryptoAlgorithm.mlDSA65.rawValue,
                P2PCryptoAlgorithm.p256.rawValue
            ]
            supportedAuthProfiles = [
                QPeriaptPlatformPolicy.authProfile,
                AuthProfile.hybrid.displayName,
                AuthProfile.pqc.displayName
            ]

        case .cryptoKitPQC:
            // IMPORTANT:
            // Only advertise X-Wing when the Hybrid provider is actually available at runtime.
            // Otherwise peers may negotiate to X-Wing and then fail, triggering Classic downgrade.
            let xwingAvailable = isAppleXWingAvailable()
            let preferXWingHybrid = prefersXWingHybridSuite()
            supportedKEM = []
            if xwingAvailable && preferXWingHybrid {
                supportedKEM.append(P2PCryptoAlgorithm.xWing.rawValue)
            }
            supportedKEM.append(P2PCryptoAlgorithm.mlKEM768.rawValue)
            if xwingAvailable && !preferXWingHybrid {
                supportedKEM.append(P2PCryptoAlgorithm.xWing.rawValue)
            }
            supportedKEM.append(P2PCryptoAlgorithm.x25519.rawValue)
            // 兼容性要点：
            // - “supportedSignature” 在此语义下表示身份/认证层可用的签名算法集合。
            // - 即使启用 PQC/hybrid，也必须保留 P-256 以兼容 classic-only peer（否则协商无交集会落入错误兜底）。
            supportedSignature = [
                P2PCryptoAlgorithm.mlDSA65.rawValue,
                P2PCryptoAlgorithm.p256.rawValue
            ]
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
            // 同上：保留 P-256 以兼容 classic-only peer 的身份签名协商。
            supportedSignature = [
                P2PCryptoAlgorithm.mlDSA65.rawValue,
                P2PCryptoAlgorithm.p256.rawValue
            ]
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

        // Q-Periapt ContextBound (beta) 通告：可加性、默认 OFF。
        // 只有显式请求且本机 macOS/iOS 26+ CQPeriapt self-test 通过才通告。
        // 开启时把 "Q-Periapt-ContextBound" 前置到 supportedKEM，使其在 KEM 协商中
        // 优先于既有 PQC 套件被选中；关闭时此分支不执行，通告与今天逐字节一致。
        #if canImport(CQPeriapt)
        if isQPeriaptBetaEnabled(),
           !supportedKEM.contains(P2PCryptoAlgorithm.qperiaptContextBound.rawValue) {
            supportedKEM.insert(P2PCryptoAlgorithm.qperiaptContextBound.rawValue, at: 0)
            if !supportedAuthProfiles.contains(QPeriaptPlatformPolicy.authProfile) {
                supportedAuthProfiles.insert(QPeriaptPlatformPolicy.authProfile, at: 0)
            }
        }
        #endif

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

    private func isAppleXWingAvailable() -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleXWingCryptoProvider.selfTest()
        }
        #endif
        return false
    }

    private func prefersXWingHybridSuite() -> Bool {
        if let raw = ProcessInfo.processInfo.environment["SB_PQC_PREFERRED_SUITE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           raw == "xwing" || raw == "hybrid" {
            return true
        }

        return UserDefaults.standard.bool(forKey: SettingsStorageKeys.preferXWingHybrid)
    }

    /// Q-Periapt ContextBound (beta) 是否启用。
    ///
    /// 默认 OFF：未启用时，本机能力通告与 provider 选择与今天完全一致（逐字节不变）。
    /// 启用条件（任一）：
    /// - 环境变量 `SB_ENABLE_QPERIAPT` 为真值（1/true/yes/on）；
    /// - UserDefaults 中 `SettingsStorageKeys.preferQPeriaptBeta` 为 true。
    ///
    /// 仅当本机 macOS/iOS 26+、CQPeriapt 模块可导入、且 runtime self-test 通过时才可能为真。
    private func isQPeriaptBetaEnabled() -> Bool {
        QPeriaptPlatformPolicy.isEnabledForLocalRuntime()
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
