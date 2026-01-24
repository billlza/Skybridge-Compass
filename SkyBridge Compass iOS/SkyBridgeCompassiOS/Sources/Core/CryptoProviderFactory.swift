//
// CryptoProviderFactory.swift
// SkyBridgeCompassiOS
//
// Provider 工厂 - 单一事实来源
// 负责能力探测和 Provider 选择
// 与 macOS 版本完全兼容
//

import Foundation

// MARK: - CryptoProviderFactory

/// Provider 工厂 - 单一事实来源
/// 负责能力探测和 Provider 选择
@available(iOS 17.0, *)
public enum CryptoProviderFactory {
    
    // MARK: - SelectionPolicy
    
    /// Provider 选择策略
    public enum SelectionPolicy: String, Sendable {
        /// 优先 PQC（默认）
        case preferPQC = "preferPQC"
        
        /// 强制 PQC（不可用则失败）
        case requirePQC = "requirePQC"
        
        /// 仅经典算法
        case classicOnly = "classicOnly"
    }
    
    // MARK: - Capability
    
    /// 能力探测结果
    public struct Capability: Sendable {
        /// iOS 26+ CryptoKit PQC 是否可用
        public let hasApplePQC: Bool
        
        /// liboqs 是否可用
        public let hasLiboqs: Bool
        
        /// 操作系统版本
        public let osVersion: String
        
        public init(hasApplePQC: Bool, hasLiboqs: Bool, osVersion: String) {
            self.hasApplePQC = hasApplePQC
            self.hasLiboqs = hasLiboqs
            self.osVersion = osVersion
        }
    }
    
    // MARK: - Public API
    
    /// 创建 Provider
    public static func make(
        policy: SelectionPolicy = .preferPQC
    ) -> any CryptoProvider {
        let capability = detectCapability()
        let provider = selectProvider(capability: capability, policy: policy)
        
        // 记录选择事件
        logProviderSelection(
            provider: provider,
            capability: capability,
            policy: policy
        )
        
        return provider
    }
    
    /// 仅探测能力（不创建 Provider）
    public static func detectCapability() -> Capability {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        
        var hasApplePQC = false
        if #available(iOS 26.0, *) {
            hasApplePQC = isApplePQCAvailable()
        }
        
        // TODO: iOS 上的 liboqs 支持需要构建 iOS 架构的 XCFramework
        let hasLiboqs = false
        
        return Capability(
            hasApplePQC: hasApplePQC,
            hasLiboqs: hasLiboqs,
            osVersion: osVersion
        )
    }
    
    /// 检查 Apple PQC API 是否可用
    @available(iOS 26.0, *)
    private static func isApplePQCAvailable() -> Bool {
        #if HAS_APPLE_PQC_SDK
        // 运行时 self-test：如果 CryptoKit PQC 类型可用且能生成密钥，则认为可用
        return ApplePQCCryptoProvider.selfTest()
        #else
        return false
        #endif
    }
    
    // MARK: - Private Methods
    
    /// 选择 Provider
    private static func selectProvider(
        capability: Capability,
        policy: SelectionPolicy
    ) -> any CryptoProvider {
        switch policy {
        case .preferPQC:
            #if HAS_APPLE_PQC_SDK
            if capability.hasApplePQC {
                if #available(iOS 26.0, *) {
                    return ApplePQCCryptoProvider()
                }
            }
            #endif
            // TODO: 当 iOS liboqs 可用时添加 OQSPQCProvider
            return ClassicCryptoProvider()
            
        case .requirePQC:
            #if HAS_APPLE_PQC_SDK
            if capability.hasApplePQC {
                if #available(iOS 26.0, *) {
                    return ApplePQCCryptoProvider()
                }
            }
            #endif
            // 返回一个会抛错的 Provider
            return UnavailablePQCProvider()
            
        case .classicOnly:
            return ClassicCryptoProvider()
        }
    }
    
    /// 记录 Provider 选择事件
    private static func logProviderSelection(
        provider: any CryptoProvider,
        capability: Capability,
        policy: SelectionPolicy
    ) {
        let compiledWithApplePQCSDK: Bool = {
            #if HAS_APPLE_PQC_SDK
            return true
            #else
            return false
            #endif
        }()
        
        let selectedTier = provider.tier
        let fallbackFromPreferred: Bool
        
        switch selectedTier {
        case .nativePQC:
            fallbackFromPreferred = false
        case .liboqsPQC:
            fallbackFromPreferred = policy == .preferPQC && !capability.hasApplePQC
        case .classic:
            fallbackFromPreferred = policy == .preferPQC
        }
        
        let severity: String
        if policy == .requirePQC, provider.providerName == "Unavailable" {
            severity = "error"
        } else {
            severity = fallbackFromPreferred ? "warning" : "info"
        }
        
        SkyBridgeLogger.shared.info(
            "[\(severity)] Crypto provider selected: \(provider.providerName) " +
            "(tier=\(selectedTier.rawValue), fallback=\(fallbackFromPreferred), " +
            "hasApplePQC=\(capability.hasApplePQC), hasLiboqs=\(capability.hasLiboqs), " +
            "compiledHAS_APPLE_PQC_SDK=\(compiledWithApplePQCSDK), policy=\(policy.rawValue))"
        )
    }
}

// MARK: - UnavailablePQCProvider

/// 不可用的 PQC Provider（用于 requirePQC 策略下 PQC 不可用时）
@available(iOS 17.0, *)
internal struct UnavailablePQCProvider: CryptoProvider, Sendable {
    let providerName = "Unavailable"
    let tier: CryptoTier = .classic
    let activeSuite: CryptoSuite = .x25519Ed25519
    
    func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        throw CryptoProviderError.pqcNotAvailable
    }
    
    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: Data, info: Data) async throws -> Data {
        throw CryptoProviderError.pqcNotAvailable
    }
    
    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        throw CryptoProviderError.pqcNotAvailable
    }

    func kemDemSealWithSecret(
        plaintext: Data,
        recipientPublicKey: Data,
        info: Data
    ) async throws -> (sealedBox: HPKESealedBox, sharedSecret: SecureBytes) {
        throw CryptoProviderError.pqcNotAvailable
    }

    func kemDemOpenWithSecret(
        sealedBox: HPKESealedBox,
        privateKey: SecureBytes,
        info: Data
    ) async throws -> (plaintext: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.pqcNotAvailable
    }

    func kemEncapsulate(
        recipientPublicKey: Data
    ) async throws -> (encapsulatedKey: Data, sharedSecret: SecureBytes) {
        throw CryptoProviderError.pqcNotAvailable
    }

    func kemDecapsulate(
        encapsulatedKey: Data,
        privateKey: SecureBytes
    ) async throws -> SecureBytes {
        throw CryptoProviderError.pqcNotAvailable
    }
    
    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw CryptoProviderError.pqcNotAvailable
    }
    
    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        throw CryptoProviderError.pqcNotAvailable
    }
    
    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        throw CryptoProviderError.pqcNotAvailable
    }
}
