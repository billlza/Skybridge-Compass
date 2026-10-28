//
// CryptoProviderFactory.swift
// SkyBridgeCompassiOS
//
// Provider 工厂 - 单一事实来源
// 负责能力探测和 Provider 选择
// 与 macOS 版本完全兼容
//

import Foundation
import SkyBridgeProtocolCore

enum PQCProviderPreferenceStorageKeys {
    static let preferXWingHybrid = "Settings.PreferXWingHybrid"
    static let preferQPeriaptBeta = "Settings.PreferQPeriaptBeta"
}

// MARK: - CryptoProviderFactory

/// Provider 工厂 - 单一事实来源
/// 负责能力探测和 Provider 选择
@available(iOS 17.0, *)
public enum CryptoProviderFactory {

    /// Captures existing, admitted runtime instances for this attempt. No key
    /// absence, network failure, or global preference is a capability oracle.
    @available(iOS 17.0, *)
    public static func captureLANInventory(identityAlgorithm: ProtocolSigningAlgorithm,
                                           policy: PQCModePolicySnapshot) throws -> LANPQCProviderInventory {
        let capability = detectCapability()
        var providers: [UInt16: any CryptoProvider] = [:]
        var profile: String?
        if identityAlgorithm == .mlDSA65, let session = QPeriaptIOSRuntime.currentSession {
            providers[0x0012] = QPeriaptCryptoProvider(session: session)
            profile = session.authProfile
        }
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            if capability.hasAppleXWing { providers[0x0001] = AppleXWingCryptoProvider() }
            if capability.hasApplePQC { providers[0x0101] = ApplePQCCryptoProvider() }
        }
        #endif
        if providers[0x0101] == nil, capability.hasLiboqs { providers[0x0101] = OQSPQCCryptoProvider() }
        let permitted = policy.selection.locallyReadySuites(Array(providers.keys))
        providers = providers.filter { permitted.contains($0.key) }
        if providers[0x0012] == nil { profile = nil }
        try SignedKEMRefreshNegotiation.validateCapabilities(suites: permitted,
            platform: "iOS", osVersion: "iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)", profile: profile,
            allowEmpty: true, requireSorted: false)
        try PQCModePolicyStore.standard.withCurrent(policy) {}
        return LANPQCProviderInventory(policy: policy, providers: providers, qProfile: profile)
    }


    @available(iOS 17.0, *)
    public static func captureLANHandshakePlan(candidates: [String], pinnedFingerprints: Set<String>) async throws -> LANPQCHandshakePlan {
        let policy = try PQCModePolicyStore.standard.snapshot()
        let inventory = try captureLANInventory(identityAlgorithm: try ProtocolSigningIdentityPolicy.requiredConfiguration().algorithm, policy: policy)
        if policy.selection.strictlyMatchSelectedMode {
            return try inventory.selecting([policy.selection.preference.rawValue])
        }
        guard let evidence = await KEMTrustStore.shared.signedRefreshEvidence(forAny: candidates),
              let fingerprint = evidence.protocolIdentityFingerprint, pinnedFingerprints.contains(fingerprint),
              let provenance = evidence.negotiation else { throw PQCModeSelectionError.negotiatedEvidenceRequired }
        let selected = try provenance.select(mode: policy.selection, locallyReadySuites: inventory.suiteWireIds,
            localQProfile: inventory.qProfile)
        guard evidence.suiteWireIds.contains(selected) else { throw PQCModeSelectionError.negotiatedEvidenceRequired }
        return try inventory.selecting([selected])
    }

    // Apple provider path boundary:
    // 1) Apple provider path does not redefine the protocol contract.
    // 2) Apple provider path does not alter the primary evidence base of the paper.
    // 3) Apple provider path is evaluated only as an implementation capability mapping
    //    under the existing negotiation and policy semantics.
    
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

    private enum NativeSuitePreference: String {
        case mlkem
        case xwing
    }

    // Cold-launch guard:
    // cache runtime capability probes so we don't repeatedly run heavy self-tests on startup paths.
    private static let hasApplePQCRuntimeSupport: Bool = {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return ApplePQCCryptoProvider.quickRuntimeProbe()
        }
        #endif
        return false
    }()

    private static let hasAppleXWingRuntimeSupport: Bool = {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleXWingCryptoProvider.quickRuntimeProbe()
        }
        #endif
        return false
    }()

    private static let hasLiboqsRuntimeSupport: Bool = OQSPQCCryptoProvider.quickRuntimeProbe()
    
    // MARK: - Capability
    
    /// 能力探测结果
    public struct Capability: Sendable {
        /// 已验证并激活、且当前 ML-DSA-65 identity 配置允许使用 Q-Periapt
        public let hasQPeriapt: Bool

        /// iOS 26+ CryptoKit PQC 是否可用
        public let hasApplePQC: Bool

        /// Apple CryptoKit X-Wing runtime self-test 是否可用
        public let hasAppleXWing: Bool
        
        /// liboqs 是否可用
        public let hasLiboqs: Bool
        
        /// 操作系统版本
        public let osVersion: String
        
        public init(
            hasApplePQC: Bool,
            hasLiboqs: Bool,
            hasQPeriapt: Bool = false,
            hasAppleXWing: Bool? = nil,
            osVersion: String
        ) {
            self.hasApplePQC = hasApplePQC
            self.hasAppleXWing = hasAppleXWing ?? hasApplePQC
            self.hasLiboqs = hasLiboqs
            self.hasQPeriapt = hasQPeriapt
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
        
        let hasApplePQC = hasApplePQCRuntimeSupport
        let hasLiboqs = hasLiboqsRuntimeSupport
        
        return Capability(
            hasApplePQC: hasApplePQC,
            hasLiboqs: hasLiboqs,
            hasQPeriapt: QPeriaptIOSRuntime.isEnabledForLocalRuntime(),
            hasAppleXWing: hasAppleXWingRuntimeSupport,
            osVersion: osVersion
        )
    }
    
    /// 检查 Apple PQC API 是否可用
    private static func isApplePQCAvailable() -> Bool {
        hasApplePQCRuntimeSupport
    }

    private static func isAppleXWingAvailable() -> Bool {
        hasAppleXWingRuntimeSupport
    }

    private static func nativeSuitePreference() -> NativeSuitePreference {
        if let raw = ProcessInfo.processInfo.environment["SB_PQC_PREFERRED_SUITE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           raw == "xwing" || raw == "hybrid" {
            return .xwing
        }

        if UserDefaults.standard.bool(
            forKey: PQCProviderPreferenceStorageKeys.preferXWingHybrid
        ) {
            return .xwing
        }

        return .mlkem
    }

    private static func makeAppleNativeProvider() -> any CryptoProvider {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            if nativeSuitePreference() == .xwing, isAppleXWingAvailable() {
                return AppleXWingCryptoProvider()
            }
            return ApplePQCCryptoProvider()
        }
        #endif
        return UnavailablePQCProvider()
    }

    private static func makeAppleStrictPQCProvider() -> any CryptoProvider {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            if nativeSuitePreference() == .xwing, isAppleXWingAvailable() {
                return AppleXWingCryptoProvider()
            }
            return ApplePQCCryptoProvider()
        }
        #endif
        return UnavailablePQCProvider()
    }

    public static func makeInboundPQCResponderProvider(
        policy: SelectionPolicy,
        peerSupportedSuites: [CryptoSuite]
    ) -> any CryptoProvider {
        guard !peerSupportedSuites.isEmpty,
              peerSupportedSuites.allSatisfy(\.isNegotiable) else {
            return UnavailablePQCProvider()
        }

        let baseProvider = make(policy: policy)

        if baseProvider.tier == .qperiaptPQC {
            // Preserve the user's single-suite policy. The authenticated
            // handshake rejects peers with no Q intersection.
            return baseProvider
        }

        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *), baseProvider.tier == .nativePQC {
            let peerSupportsXWing = peerSupportedSuites.contains {
                $0.providerCompatibilitySuite.wireId == CryptoSuite.xwing.providerCompatibilitySuite.wireId
            }
            let peerSupportsMLKEM = peerSupportedSuites.contains {
                $0.providerCompatibilitySuite.wireId == CryptoSuite.mlkem768.providerCompatibilitySuite.wireId
            }

            switch (peerSupportsXWing, peerSupportsMLKEM) {
            case (true, false):
                guard isAppleXWingAvailable() else {
                    return UnavailablePQCProvider()
                }
                return AppleXWingCryptoProvider()
            case (false, true):
                return ApplePQCCryptoProvider()
            default:
                return baseProvider
            }
        }
        #endif

        return baseProvider
    }

    public static func handshakeOfferedPQCSuites(using provider: any CryptoProvider) -> [CryptoSuite] {
        provider.supportedSuites.filter { $0.isPQCGroup && $0.isNegotiable }
    }
    
    // MARK: - Private Methods
    
    /// 选择 Provider
    private static func selectProvider(
        capability: Capability,
        policy: SelectionPolicy
    ) -> any CryptoProvider {
        if isQPeriaptSelectionAllowed(for: policy), QPeriaptIOSRuntime.isRequested() {
            guard capability.hasQPeriapt,
                  let provider = QPeriaptIOSRuntime.makeCryptoProvider() else {
                return UnavailablePQCProvider()
            }
            return provider
        }
        return selectStandardProvider(capability: capability, policy: policy)
    }

    static func isQPeriaptSelectionAllowed(for policy: SelectionPolicy) -> Bool {
        policy != .classicOnly
    }

    private static func selectStandardProvider(
        capability: Capability,
        policy: SelectionPolicy
    ) -> any CryptoProvider {
        switch policy {
        case .preferPQC:
            #if HAS_APPLE_PQC_SDK
            if capability.hasApplePQC {
                return makeAppleNativeProvider()
            }
            #endif
            if capability.hasLiboqs {
                return OQSPQCCryptoProvider()
            }
            return ClassicCryptoProvider()
            
        case .requirePQC:
            #if HAS_APPLE_PQC_SDK
            if capability.hasApplePQC {
                // Strict-PQC means "no classic fallback", not "force ML-KEM regardless of user choice".
                // When native PQC is available, honor the user's preferred native suite inside the PQC group.
                return makeAppleStrictPQCProvider()
            }
            #endif
            if capability.hasLiboqs {
                return OQSPQCCryptoProvider()
            }
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
        case .qperiaptPQC:
            fallbackFromPreferred = false
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
            "hasQPeriapt=\(capability.hasQPeriapt), hasApplePQC=\(capability.hasApplePQC), " +
            "hasLiboqs=\(capability.hasLiboqs), " +
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
    let activeSuite: CryptoSuite = .unknown(0xFFFF)
    let supportedSuites: [CryptoSuite] = []

    func supportsSuite(_ suite: CryptoSuite) -> Bool {
        false
    }
    
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

/// A local provider owner, not peer trust. The caller supplies an authenticated
/// SKR intersection (initiator) or verifies MessageA before responder commit.
@available(iOS 17.0, *)
public struct LANPQCProviderInventory: Sendable {
    public let policy: PQCModePolicySnapshot
    fileprivate let providers: [UInt16: any CryptoProvider]
    public let qProfile: String?
    public var suiteWireIds: [UInt16] {
        SignedKEMRefreshNegotiation.preferenceOrder.filter { providers[$0] != nil }
    }
    public func provider(for selected: UInt16) throws -> any CryptoProvider {
        try PQCModePolicyStore.standard.withCurrent(policy) {
            guard let provider = providers[selected],
                  provider.supportedSuites.contains(where: { $0.wireId == selected }) else {
                throw PQCModeSelectionError.unavailableRuntime
            }
            return provider
        }
    }
    public func selecting(_ authenticatedIntersection: [UInt16]) throws -> LANPQCHandshakePlan {
        let selected = try policy.selection.select(fromVerifiedIntersection:
            authenticatedIntersection.filter { providers[$0] != nil })
        return LANPQCHandshakePlan(inventory: self, suiteWireId: selected, provider: try provider(for: selected))
    }
}

@available(iOS 17.0, *)
public struct LANPQCHandshakePlan: Sendable {
    public let inventory: LANPQCProviderInventory
    public let suiteWireId: UInt16
    public let provider: any CryptoProvider
    public func withCurrent<T>(_ publish: () throws -> T) throws -> T {
        try PQCModePolicyStore.standard.withCurrent(inventory.policy, publish)
    }
}
