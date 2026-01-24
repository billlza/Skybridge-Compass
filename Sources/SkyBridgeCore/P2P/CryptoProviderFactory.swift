//
// CryptoProviderFactory.swift
// SkyBridgeCore
//
// Tech Debt Cleanup - PQC Provider Architecture Refactoring
// Requirements: 1.1, 1.2, 1.3, 1.4
//
// Provider 工厂 - 单一事实来源
// 负责能力探测和 Provider 选择
//

import Foundation

// MARK: - CryptoProviderFactory

/// Provider 工厂 - 单一事实来源
/// 负责能力探测和 Provider 选择
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
 /// macOS 26+ CryptoKit PQC 是否可用
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
 /// - Parameters:
 /// - policy: 选择策略
 /// - environment: 运行环境（用于测试注入）
 /// - Returns: 选中的 Provider
 ///
 /// 注意：使用 `any CryptoEnvironment` 和 `any CryptoProvider` 以支持协议类型
    public static func make(
        policy: SelectionPolicy = .preferPQC,
        environment: any CryptoEnvironment = SystemCryptoEnvironment.system
    ) -> any CryptoProvider {
        let capability = detectCapability(environment: environment)
        let provider = selectProvider(capability: capability, policy: policy)

 // 发射选择事件（可观测性）
        emitProviderSelectedEvent(
            provider: provider,
            capability: capability,
            policy: policy
        )

        return provider
    }

 /// 仅探测能力（不创建 Provider）
    public static func detectCapability(
        environment: any CryptoEnvironment = SystemCryptoEnvironment.system
    ) -> Capability {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var hasApplePQC = false
        if #available(iOS 26.0, macOS 26.0, *) {
            hasApplePQC = environment.checkApplePQCAvailable()
        }

        let hasLiboqs = environment.checkLiboqsAvailable()

        return Capability(
            hasApplePQC: hasApplePQC,
            hasLiboqs: hasLiboqs,
            osVersion: osVersion
        )
    }

 // MARK: - Private Methods

 /// 选择 Provider
 ///
 /// **关键**：ApplePQCProvider 引用必须用 #if HAS_APPLE_PQC_SDK 包裹
 /// 否则旧 SDK 编译时符号不存在会直接失败
    private static func selectProvider(
        capability: Capability,
        policy: SelectionPolicy
    ) -> any CryptoProvider {
        switch policy {
        case .preferPQC:
            #if HAS_APPLE_PQC_SDK
            if capability.hasApplePQC {
                if #available(iOS 26.0, macOS 26.0, *) {
                    return ApplePQCCryptoProvider()
                }
            }
            #endif
            if capability.hasLiboqs {
                return OQSPQCProvider()
            }
            return ClassicProvider()

        case .requirePQC:
            #if HAS_APPLE_PQC_SDK
            if capability.hasApplePQC {
                if #available(iOS 26.0, macOS 26.0, *) {
                    return ApplePQCCryptoProvider()
                }
            }
            #endif
            if capability.hasLiboqs {
                return OQSPQCProvider()
            }
 // 返回一个会抛错的 Provider
            return UnavailablePQCProvider()

        case .classicOnly:
            return ClassicProvider()
        }
    }

 /// 发射 Provider 选择事件
    private static func emitProviderSelectedEvent(
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

 // 使用 provider.tier 而非字符串判断
        let selectedTier = provider.tier
        let fallbackFromPreferred: Bool

        switch selectedTier {
        case .nativePQC:
            fallbackFromPreferred = false
        case .liboqsPQC:
 // liboqs 也是 fallback（从 native PQC 角度）
            fallbackFromPreferred = policy == .preferPQC && !capability.hasApplePQC
        case .classic:
            fallbackFromPreferred = policy == .preferPQC
        }

 // 确定 severity
        let severity: SecurityEventSeverity = fallbackFromPreferred ? .warning : .info

 // 创建事件
        let event = SecurityEvent(
            type: .cryptoProviderSelected,
            severity: severity,
            message: "Crypto provider selected: \(provider.providerName)",
            context: [
                "selectedTier": selectedTier.rawValue,
                "fallbackFromPreferred": String(fallbackFromPreferred),
                "providerName": provider.providerName,
                "suite": provider.activeSuite.rawValue,
                "osVersion": capability.osVersion,
                "compiledWithApplePQCSDK": String(compiledWithApplePQCSDK),
                "hasApplePQC": String(capability.hasApplePQC),
                "hasLiboqs": String(capability.hasLiboqs),
                "policy": policy.rawValue
            ]
        )

        SecurityEventEmitter.emitDetached(event)
    }
}

// MARK: - UnavailablePQCProvider

/// 不可用的 PQC Provider（用于 requirePQC 策略下 PQC 不可用时）
internal struct UnavailablePQCProvider: CryptoProvider, Sendable {
    let providerName = "Unavailable"
    let tier: CryptoTier = .classic
    let activeSuite: CryptoSuite = .x25519Ed25519

    func hpkeSeal(plaintext: Data, recipientPublicKey: Data, info: Data) async throws -> HPKESealedBox {
        throw CryptoProviderError.providerNotAvailable(.cryptoKitPQC)
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: Data, info: Data) async throws -> Data {
        throw CryptoProviderError.providerNotAvailable(.cryptoKitPQC)
    }

    func hpkeOpen(sealedBox: HPKESealedBox, privateKey: SecureBytes, info: Data) async throws -> Data {
        throw CryptoProviderError.providerNotAvailable(.cryptoKitPQC)
    }

    func sign(data: Data, using keyHandle: SigningKeyHandle) async throws -> Data {
        throw CryptoProviderError.providerNotAvailable(.cryptoKitPQC)
    }

    func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
        throw CryptoProviderError.providerNotAvailable(.cryptoKitPQC)
    }

    func generateKeyPair(for usage: KeyUsage) async throws -> KeyPair {
        throw CryptoProviderError.providerNotAvailable(.cryptoKitPQC)
    }
}

// MARK: - Provider Type Aliases

/// Classic Provider - 使用 Providers/ClassicProvider.swift 中的实现
@available(macOS 14.0, iOS 17.0, *)
internal typealias ClassicProvider = ClassicCryptoProvider

/// OQS PQC Provider - 使用 Providers/OQSPQCProvider.swift 中的实现
@available(macOS 14.0, iOS 17.0, *)
internal typealias OQSPQCProvider = OQSPQCCryptoProvider

// 注意：ApplePQCCryptoProvider 直接使用，不创建 typealias
// 因为 QuantumSecure/PQCProvider.swift 中已有同名的 ApplePQCProvider actor


// MARK: - CryptoEnvironment Protocol

/// 运行环境抽象（用于测试注入）
public protocol CryptoEnvironment: Sendable {
 /// 检查 Apple PQC 是否可用
    func checkApplePQCAvailable() -> Bool

 /// 检查 liboqs 是否可用
    func checkLiboqsAvailable() -> Bool
}

// MARK: - SystemCryptoEnvironment

/// 系统环境
public struct SystemCryptoEnvironment: CryptoEnvironment, Sendable {
    public static let system = SystemCryptoEnvironment()

    private init() {}

 /// 检查 Apple PQC 是否可用
 ///
 /// **关键设计决策**：
 /// - 仅当 HAS_APPLE_PQC_SDK 编译标志存在时才返回 true
 /// - 这防止在 ApplePQCProvider 未实现时错误选择它
 /// - 执行 self-test 验证 API 实际可用性
 /// Requirements: 4.3
    public func checkApplePQCAvailable() -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
 // 执行轻量 self-test 验证 API 可用
            return ApplePQCCryptoProvider.selfTest()
        }
        #endif
        return false
    }

    public func checkLiboqsAvailable() -> Bool {
        #if canImport(OQSRAII)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Testing Support

#if DEBUG
/// 测试用环境（可注入能力）
public struct MockCryptoEnvironment: CryptoEnvironment, Sendable {
    public let hasApplePQC: Bool
    public let hasLiboqs: Bool

    public init(hasApplePQC: Bool = false, hasLiboqs: Bool = false) {
        self.hasApplePQC = hasApplePQC
        self.hasLiboqs = hasLiboqs
    }

    public func checkApplePQCAvailable() -> Bool {
        hasApplePQC
    }

    public func checkLiboqsAvailable() -> Bool {
        hasLiboqs
    }
}
#endif
