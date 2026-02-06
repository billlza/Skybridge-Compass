//
// PreNegotiationSignatureSelector.swift
// SkyBridgeCore
//
// Signature Mechanism Alignment - 2.1
// Requirements: 1.1, 1.2, 1.4
//
// Pre-Negotiation 签名选择器：
// 解决 "先有鸡还是先有蛋" 问题 - 在协商 suite 之前，如何选择 sigA 的算法？
//
// **策略**:
// - 如果 offeredSuites 包含任何 PQC/Hybrid suite，使用 ML-DSA-65
// - 如果 offeredSuites 全部是 Classic suite，使用 Ed25519
// - Responder 只允许选择与 sigA 算法一致的 suite
//

import Foundation

// MARK: - PreNegotiationSignatureSelector

/// Pre-Negotiation 签名选择器
///
/// 解决 "先有鸡还是先有蛋" 问题：在协商 suite 之前，如何选择 sigA 的算法？
///
/// **硬规则**:
/// - 如果 MessageA 的 `offeredSuites` 包含任何 PQC/Hybrid suite (wireId 0x00xx 或 0x01xx)，
/// 则 `sigA` **必须**使用 ML-DSA-65
/// - 如果 `offeredSuites` 全部是 Classic suite (wireId 0x10xx)，则 `sigA` 使用 Ed25519
/// - Responder 只允许选择与 `sigA` 算法一致的 suite
///
/// **Requirements: 1.1, 1.2, 1.4**
public struct PreNegotiationSignatureSelector: Sendable {
    
 // MARK: - Selection Result ( 7.3)
    
 /// 签名选择结果
    public enum SelectionResult: Sendable, Equatable {
 /// 成功选择
        case success(algorithm: ProtocolSigningAlgorithm, provider: any ProtocolSignatureProvider)
        
 /// offeredSuites 为空
        case empty
        
        public static func == (lhs: SelectionResult, rhs: SelectionResult) -> Bool {
            switch (lhs, rhs) {
            case (.empty, .empty):
                return true
            case (.success(let lAlg, _), .success(let rAlg, _)):
                return lAlg == rAlg
            default:
                return false
            }
        }
    }
    
 // MARK: - Public Methods
    
 /// 根据 offeredSuites 选择 sigA 的签名算法
 ///
 /// - Parameter offeredSuites: MessageA 中提供的 suite 列表
 /// - Returns: 签名算法
 ///
 /// **规则**:
 /// - 如果 offeredSuites 包含任何 PQC 或 Hybrid suite → ML-DSA-65
 /// - 如果 offeredSuites 全部是 Classic suite → Ed25519
 ///
 /// **Property 1: Pre-Negotiation Signature Algorithm Rule**
 /// **Validates: Requirements 1.1, 1.2, 1.4**
    public static func selectForMessageA(offeredSuites: [CryptoSuite]) -> SignatureAlgorithm {
 // 检查是否包含任何 PQC 或 Hybrid suite
 // isPQCGroup 是唯一分类函数
        let hasPQCOrHybrid = offeredSuites.contains { $0.isPQCGroup }
        
        return hasPQCOrHybrid ? .mlDSA65 : .ed25519
    }
    
 /// 根据 offeredSuites 选择 sigA 的签名算法（返回 SelectionResult）
 ///
 /// - Parameter offeredSuites: MessageA 中提供的 suite 列表
 /// - Returns: SelectionResult
 ///
 /// ** 7.3**: 返回类型改为 SelectionResult enum
 /// - `.empty` → 上抛到 Attempt 层，映射为 `.pqcProviderUnavailable`
 ///
 /// **Requirements: 6.3**
    public static func selectForMessageAResult(offeredSuites: [CryptoSuite]) -> SelectionResult {
        guard !offeredSuites.isEmpty else {
            return .empty
        }
        
        let hasPQCOrHybrid = offeredSuites.contains { $0.isPQCGroup }
        let algorithm: ProtocolSigningAlgorithm = hasPQCOrHybrid ? .mlDSA65 : .ed25519
        let provider = selectProvider(for: algorithm)
        
        return .success(algorithm: algorithm, provider: provider)
    }
    
 /// 验证 selectedSuite 与 sigA 算法的兼容性
 ///
 /// - Parameters:
 /// - selectedSuite: Responder 选择的 suite
 /// - sigAAlgorithm: sigA 使用的签名算法
 /// - Returns: 是否兼容
 ///
 /// **规则**:
 /// - 如果 sigA 是 ML-DSA-65，selectedSuite 必须是 PQC 或 Hybrid
 /// - 如果 sigA 是 Ed25519，selectedSuite 必须是 Classic
 /// - P-256 ECDSA 不用于主协议签名
 ///
 /// **Property 2: Suite-Signature Compatibility Validation**
 /// **Validates: Requirements 1.1, 1.2**
    public static func validateSuiteCompatibility(
        selectedSuite: CryptoSuite,
        sigAAlgorithm: SignatureAlgorithm
    ) -> Bool {
 // isPQC 涵盖 PQC + Hybrid，或者显式检查两者
        let isPQCOrHybrid = selectedSuite.isPQC || selectedSuite.isHybrid
        
        switch sigAAlgorithm {
        case .mlDSA65:
 // sigA 是 ML-DSA-65，selectedSuite 必须是 PQC 或 Hybrid
            return isPQCOrHybrid
            
        case .ed25519:
 // sigA 是 Ed25519，selectedSuite 必须是 Classic
            return !isPQCOrHybrid
            
        case .p256ECDSA:
 // P-256 ECDSA 不用于主协议签名
            return false
        }
    }
    
 /// 根据 sigA 算法选择签名 Provider
 ///
 /// - Parameter algorithm: sigA 使用的签名算法
 /// - Returns: 签名 Provider
 ///
 /// **Property 3: Signature Provider Selection by Algorithm**
 /// **Validates: Requirements 3.1, 3.2, 3.3**
    @available(*, deprecated, message: "请使用 selectProvider(for: ProtocolSigningAlgorithm)。P-256 ECDSA 不允许用于主协议签名（sigA/sigB）。若需要 P-256（legacy 验证 / Secure Enclave PoP），请使用 P256SignatureProvider。")
    public static func selectProvider(for algorithm: SignatureAlgorithm) -> any ProtocolSignatureProvider {
        switch algorithm {
        case .mlDSA65:
 // 优先使用 Apple PQC，回退到 OQS
            return PQCSignatureProvider(backend: .auto)
            
        case .ed25519:
            return ClassicSignatureProvider()
            
        case .p256ECDSA:
 // P-256 ECDSA 不允许用于主协议签名 (sigA/sigB)
            // 使用 Ed25519 作为 fallback（避免 Debug 断言导致测试/运行时崩溃）。
            // 调用方应改用 `ProtocolSigningAlgorithm` 版本；若需要 P-256（legacy 验证 / Secure Enclave PoP），请使用 `P256SignatureProvider`。
            SkyBridgeLogger.p2p.warning("Deprecated selectProvider(for: SignatureAlgorithm) called with P-256 ECDSA (illegal for sigA/sigB). Falling back to ClassicSignatureProvider. Use ProtocolSigningAlgorithm/P256SignatureProvider instead.")
            return ClassicSignatureProvider()
        }
    }
    
 /// 根据协议签名算法选择签名 Provider（类型安全版本）
 ///
 /// - Parameter algorithm: 协议签名算法（类型层面排除 P-256）
 /// - Returns: 签名 Provider
 ///
 /// **Requirements: 1.1, 1.2, 3.4, 3.5**
    public static func selectProvider(for algorithm: ProtocolSigningAlgorithm) -> any ProtocolSignatureProvider {
        switch algorithm {
        case .mlDSA65:
            return PQCSignatureProvider(backend: .auto)
        case .ed25519:
            return ClassicSignatureProvider()
        }
    }
    
 /// 根据 offeredSuites 选择签名算法和 Provider
 ///
 /// - Parameter offeredSuites: MessageA 中提供的 suite 列表
 /// - Returns: (签名算法, 签名 Provider)
 ///
 /// 便捷方法，组合 `selectForMessageA` 和 `selectProvider`
    public static func selectAlgorithmAndProvider(
        offeredSuites: [CryptoSuite]
    ) -> (algorithm: SignatureAlgorithm, provider: any ProtocolSignatureProvider) {
        let algorithm = selectForMessageA(offeredSuites: offeredSuites)
        // `selectForMessageA` 的返回值只可能是 ed25519 / mlDSA65，但这里仍使用类型安全的转换，
        // 避免误用 `.p256ECDSA` 路径（该路径对主协议签名是非法的）。
        if let protocolAlg = ProtocolSigningAlgorithm(from: algorithm) {
            let provider = selectProvider(for: protocolAlg)
            return (algorithm, provider)
        }
        SkyBridgeLogger.p2p.error("Unexpected SignatureAlgorithm for protocol signing: \(algorithm.rawValue). Falling back to ClassicSignatureProvider.")
        return (algorithm, ClassicSignatureProvider())
    }
}

// MARK: - CryptoSuite Extensions for Signature Selection

extension CryptoSuite {
 /// 所有 PQC suites（用于 Two-Attempt Strategy）
    public static var allPQCSuites: [CryptoSuite] {
        [.xwingMLDSA, .mlkem768MLDSA65]
    }
    
 /// 所有 Classic suites（用于 Two-Attempt Strategy）
    public static var allClassicSuites: [CryptoSuite] {
        [.x25519Ed25519, .p256ECDSA]
    }
}

// MARK: - HandshakeOfferedSuites ( 7.2)

/// 握手 offeredSuites 构建器
///
/// **设计原则**: 确保 offeredSuites 同质性，不偷偷变成其他算法
///
/// **Requirements: 9.1**
public struct HandshakeOfferedSuites: Sendable {
    
 /// 构建结果
    public enum BuildResult: Sendable, Equatable {
 /// 成功构建的 suites
        case suites([CryptoSuite])
        
 /// 过滤后为空（策略不可用）
        case empty(HandshakeAttemptStrategy)
    }
    
 /// 根据策略和 CryptoProvider 构建 offeredSuites
 ///
 /// - Parameters:
 /// - strategy: 握手尝试策略
 /// - cryptoProvider: 加密 Provider（数据来源）
 /// - Returns: 构建结果
 ///
 /// ** 7.2**: 数据来源必须是 cryptoProvider.supportedSuites
 /// 不使用静态的 CryptoSuite.allPQCSuites（会 offer 本地不支持的 suite）
 ///
 /// **规则**:
 /// - pqcOnly：只取 `isPQCGroup == true`
 /// - classicOnly：只取 `isPQCGroup == false`
 /// - 过滤后为空：返回 `.empty(strategy)`（不偷偷变成其他算法）
 ///
 /// **Requirements: 9.1**
    public static func build(
        strategy: HandshakeAttemptStrategy,
        cryptoProvider: any CryptoProvider
    ) -> BuildResult {
        let availableSuites = cryptoProvider.supportedSuites
        return build(strategy: strategy, availableSuites: availableSuites)
    }
    
 /// 根据策略构建 offeredSuites（使用提供的 suites 列表）
 ///
 /// - Parameters:
 /// - strategy: 握手尝试策略
 /// - availableSuites: 可用的 suites
 /// - Returns: 构建结果
 ///
 /// **规则**:
 /// - pqcOnly：只取 `isPQCGroup == true`
 /// - classicOnly：只取 `isPQCGroup == false`
 /// - 过滤后为空：返回 `.empty(strategy)`（不偷偷变成其他算法）
    public static func build(
        strategy: HandshakeAttemptStrategy,
        availableSuites: [CryptoSuite]
    ) -> BuildResult {
        let filtered: [CryptoSuite]
        
        switch strategy {
        case .pqcOnly:
            filtered = availableSuites.filter { $0.isPQCGroup }
        case .classicOnly:
            filtered = availableSuites.filter { !$0.isPQCGroup }
        }
        
        guard !filtered.isEmpty else {
            return .empty(strategy)
        }
        
        return .suites(filtered)
    }
    
 /// 根据策略从默认 suites 构建（向后兼容）
 ///
 /// - Parameter strategy: 握手尝试策略
 /// - Returns: 构建结果
 ///
 /// **注意**: 优先使用 `build(strategy:cryptoProvider:)` 版本
    @available(*, deprecated, message: "Use build(strategy:cryptoProvider:) instead")
    public static func buildDefault(strategy: HandshakeAttemptStrategy) -> BuildResult {
        switch strategy {
        case .pqcOnly:
            return .suites(CryptoSuite.allPQCSuites)
        case .classicOnly:
            return .suites(CryptoSuite.allClassicSuites)
        }
    }
}
