//
// TwoAttemptHandshakeManager.swift
// SkyBridgeCore
//
// 11.1: Two-Attempt Strategy
// Requirements: 1.4, 5.1, 9.1, 9.2, 9.3, 9.4, 9.5, 9.6
//
// 两次尝试握手管理器：
// - 解决 "preferPQC 但允许回退 classic" 的互操作问题
// - 第一次尝试 PQC-only，失败后回退到 Classic-only
// - 超时不触发自动 fallback（防止攻击者用丢包强制降级）
//

import Foundation

/// 握手尝试策略
public enum HandshakeAttemptStrategy: String, Sendable {
 /// 仅 PQC (offeredSuites 只包含 PQC/Hybrid)
    case pqcOnly = "pqc_only"
    
 /// 仅 Classic (offeredSuites 只包含 Classic)
    case classicOnly = "classic_only"
}

/// Attempt 准备结果
///
/// ** 9.1**: Attempt 内部必须先 build suites，再选算法，再取 key/provider
public struct AttemptPreparation: Sendable {
    public let strategy: HandshakeAttemptStrategy
    public let offeredSuites: [CryptoSuite]
    public let sigAAlgorithm: ProtocolSigningAlgorithm
    public let signatureProvider: any ProtocolSignatureProvider
    
    public init(
        strategy: HandshakeAttemptStrategy,
        offeredSuites: [CryptoSuite],
        sigAAlgorithm: ProtocolSigningAlgorithm,
        signatureProvider: any ProtocolSignatureProvider
    ) {
        self.strategy = strategy
        self.offeredSuites = offeredSuites
        self.sigAAlgorithm = sigAAlgorithm
        self.signatureProvider = signatureProvider
    }
}

/// Attempt 准备错误
public enum AttemptPreparationError: Error, Sendable {
 /// PQC Provider 不可用（pqcOnly 策略但没有 PQC suites）
    case pqcProviderUnavailable
    
 /// Classic Provider 不可用（classicOnly 策略但没有 classic suites）
    case classicProviderUnavailable
    
 /// Fallback 被限流
    case fallbackRateLimited(deviceId: String, cooldownSeconds: Int)
}

/// 两次尝试握手管理器
///
/// **关键设计**: 解决 "preferPQC 但允许回退 classic" 的互操作问题
///
/// 由于硬规则要求 `sigA` 算法与 `selectedSuite` 兼容，我们不能在同一轮握手中同时 offer classic + PQC。
/// 为了保留 fallback 连接能力，采用两次尝试策略：
///
/// 1. `preferPQC = true`: 先发 PQC-only MessageA (sigA=ML-DSA-65)，失败后再发 Classic-only MessageA (sigA=Ed25519)
/// 2. `preferPQC = false`: 直接发 Classic-only MessageA
/// 3. 每次 fallback 都发射 `cryptoDowngrade` event
/// 4. 硬规则仍然成立：每轮握手中 sigA 算法与 selectedSuite 必须兼容
///
/// **Requirements: 1.4, 5.1, 9.1, 9.2, 9.3, 9.4, 9.5, 9.6**
@available(macOS 14.0, iOS 17.0, *)
public struct TwoAttemptHandshakeManager: Sendable {
    
 // MARK: - Fallback Rate Limiting ( 9.3)

    private static let fallbackCooldownSeconds: Int = 300
    
 /// Per-peer fallback 限流 actor
    private actor FallbackRateLimiter {
        private let clock = ContinuousClock()

 /// 上次 fallback 时间记录（使用单调时钟，避免系统时间回拨影响限流）
        private var lastFallbackTimes: [String: ContinuousClock.Instant] = [:]
        
 /// 检查是否允许 fallback
        func canFallback(deviceId: String) -> Bool {
            guard let lastTime = lastFallbackTimes[deviceId] else {
                return true
            }
            let elapsed = lastTime.duration(to: clock.now)
            return elapsed >= .seconds(TwoAttemptHandshakeManager.fallbackCooldownSeconds)
        }
        
 /// 记录 fallback
        func recordFallback(deviceId: String) {
            lastFallbackTimes[deviceId] = clock.now
        }
        
 /// 获取剩余冷却时间
        func remainingCooldown(deviceId: String) -> Int {
            guard let lastTime = lastFallbackTimes[deviceId] else {
                return 0
            }
            let elapsed = lastTime.duration(to: clock.now)
            let elapsedSeconds = Int(elapsed.components.seconds)
            let remaining = TwoAttemptHandshakeManager.fallbackCooldownSeconds - elapsedSeconds
            return max(0, remaining)
        }
    }
    
 /// 全局限流器实例
    private static let rateLimiter = FallbackRateLimiter()
    
 // MARK: - Fallback Whitelist/Blacklist ( 9.2)
    
 /// 判断是否允许 fallback
 ///
 /// ** 9.2**: 实现 fallback 条件白名单/黑名单
 /// - 允许原因白名单：pqcProviderUnavailable, suiteNotSupported, suiteNegotiationFailed
 /// - 禁止原因黑名单：timeout, suiteSignatureMismatch, signatureVerificationFailed, 认证失败
    private static func shouldAllowFallback(_ reason: HandshakeFailureReason) -> Bool {
 // 白名单：明确的 PQC 不支持错误
        switch reason {
        case .pqcProviderUnavailable, .suiteNotSupported, .suiteNegotiationFailed:
            return true
 // 黑名单：安全相关错误，不允许降级
        case .timeout, .signatureVerificationFailed,
             .replayDetected, .keyConfirmationFailed:
            return false
        case .suiteSignatureMismatch:
            return false
        case .identityMismatch:
            return false
 // 其他错误也不允许降级
        case .cancelled, .cryptoError, .transportError,
             .versionMismatch, .invalidMessageFormat, .secureEnclavePoPRequired,
             .secureEnclaveSignatureInvalid, .peerRejected:
            return false
        }
    }
    
 // MARK: - Attempt Preparation ( 9.1)
    
 /// 准备 Attempt（先 build suites，再选算法，再取 provider）
 ///
 /// - Parameters:
 /// - strategy: 握手尝试策略
 /// - cryptoProvider: 加密 Provider
 /// - Returns: Attempt 准备结果
 /// - Throws: AttemptPreparationError
 ///
 /// ** 9.1**: Attempt 内部必须先 build suites，再选算法，再取 key/provider
 /// pqcOnly suites 为空 → 直接按 `.pqcProviderUnavailable` 处理
    public static func prepareAttempt(
        strategy: HandshakeAttemptStrategy,
        cryptoProvider: any CryptoProvider
    ) throws -> AttemptPreparation {
 // 1. 先 build suites
        let buildResult: HandshakeOfferedSuites.BuildResult
        switch strategy {
        case .pqcOnly:
            buildResult = HandshakeOfferedSuites.build(strategy: strategy, cryptoProvider: cryptoProvider)
        case .classicOnly:
            var availableSuites = cryptoProvider.supportedSuites
            let classicSuites = ClassicCryptoProvider().supportedSuites
            for suite in classicSuites where !availableSuites.contains(where: { $0.wireId == suite.wireId }) {
                availableSuites.append(suite)
            }
            buildResult = HandshakeOfferedSuites.build(strategy: strategy, availableSuites: availableSuites)
        }
        
 // 2. 检查是否为空
        let offeredSuites: [CryptoSuite]
        switch buildResult {
        case .suites(let suites):
            offeredSuites = suites
        case .empty(let emptyStrategy):
            switch emptyStrategy {
            case .pqcOnly:
                throw AttemptPreparationError.pqcProviderUnavailable
            case .classicOnly:
                throw AttemptPreparationError.classicProviderUnavailable
            }
        }
        
 // 3. 选算法
        let selectionResult = PreNegotiationSignatureSelector.selectForMessageAResult(offeredSuites: offeredSuites)
        let sigAAlgorithm: ProtocolSigningAlgorithm
        switch selectionResult {
        case .success(let algorithm, _):
            sigAAlgorithm = algorithm
        case .empty:
 // 不应该到这里，因为 offeredSuites 已经非空
            switch strategy {
            case .pqcOnly:
                throw AttemptPreparationError.pqcProviderUnavailable
            case .classicOnly:
                throw AttemptPreparationError.classicProviderUnavailable
            }
        }
        
 // 4. 取 provider
        let signatureProvider = PreNegotiationSignatureSelector.selectProvider(for: sigAAlgorithm)
        
        return AttemptPreparation(
            strategy: strategy,
            offeredSuites: offeredSuites,
            sigAAlgorithm: sigAAlgorithm,
            signatureProvider: signatureProvider
        )
    }
    
 /// 握手执行器类型
    public typealias HandshakeExecutor = @Sendable (
        _ strategy: HandshakeAttemptStrategy,
        _ sigAAlgorithm: SignatureAlgorithm
    ) async throws -> SessionKeys
    
 /// 握手执行器类型（使用 AttemptPreparation）
    public typealias PreparedHandshakeExecutor = @Sendable (
        _ preparation: AttemptPreparation
    ) async throws -> SessionKeys
    
 /// 执行握手（带自动回退，使用 AttemptPreparation）
 ///
 /// - Parameters:
 /// - deviceId: 目标设备 ID（用于日志和限流）
 /// - preferPQC: 是否优先尝试 PQC
 /// - policy: 握手策略（控制是否允许 classic 回退）
 /// - cryptoProvider: 加密 Provider
 /// - executor: 握手执行器
 /// - Returns: 会话密钥
 /// - Throws: HandshakeError 或 AttemptPreparationError
 ///
 /// ** 9.1**: Attempt 内部必须先 build suites，再选算法，再取 key/provider
    public static func performHandshakeWithPreparation(
        deviceId: String,
        preferPQC: Bool = true,
        policy: HandshakePolicy = .default,
        cryptoProvider: any CryptoProvider,
        executor: PreparedHandshakeExecutor
    ) async throws -> SessionKeys {
        if policy.requirePQC, !preferPQC {
            throw HandshakeError.failed(.pqcProviderUnavailable)
        }

        if preferPQC {
 // 第一次尝试: PQC-only
            do {
                let preparation = try prepareAttempt(strategy: .pqcOnly, cryptoProvider: cryptoProvider)
                return try await executor(preparation)
            } catch let error as AttemptPreparationError {
 // PQC 准备失败，尝试 fallback
                if case .pqcProviderUnavailable = error {
                    guard policy.allowClassicFallback else {
                        throw error
                    }
                    return try await attemptFallback(
                        deviceId: deviceId,
                        reason: .pqcProviderUnavailable,
                        policy: policy,
                        cryptoProvider: cryptoProvider,
                        executor: executor
                    )
                }
                throw error
            } catch let error as HandshakeError {
 // 检查是否允许 fallback
                if case .failed(let reason) = error,
                   shouldAllowFallback(reason) {
                    guard policy.allowClassicFallback else {
                        throw error
                    }
                    return try await attemptFallback(
                        deviceId: deviceId,
                        reason: reason,
                        policy: policy,
                        cryptoProvider: cryptoProvider,
                        executor: executor
                    )
                }
                throw error
            }
        } else {
 // 直接使用 Classic
            let preparation = try prepareAttempt(strategy: .classicOnly, cryptoProvider: cryptoProvider)
            return try await executor(preparation)
        }
    }
    
 /// 尝试 fallback（带限流和事件发射）
    private static func attemptFallback(
        deviceId: String,
        reason: HandshakeFailureReason,
        policy: HandshakePolicy,
        cryptoProvider: any CryptoProvider,
        executor: PreparedHandshakeExecutor
    ) async throws -> SessionKeys {
        guard policy.allowClassicFallback else {
            throw HandshakeError.failed(reason)
        }
 // 9.3: 检查限流
        let canFallback = await rateLimiter.canFallback(deviceId: deviceId)
        guard canFallback else {
            let cooldown = await rateLimiter.remainingCooldown(deviceId: deviceId)
            throw AttemptPreparationError.fallbackRateLimited(deviceId: deviceId, cooldownSeconds: cooldown)
        }
        
 // 记录 fallback
        await rateLimiter.recordFallback(deviceId: deviceId)
        
 // 9.4: 发射 fallback 事件
        let cooldownSeconds = TwoAttemptHandshakeManager.fallbackCooldownSeconds
        SecurityEventEmitter.emitDetached(SecurityEvent(
            type: .cryptoDowngrade,
            severity: .warning,
            message: "PQC handshake failed, falling back to Classic",
            context: [
                "reason": String(describing: reason),
                "deviceId": deviceId,
                "cooldownSeconds": String(cooldownSeconds),
                "cooldownRemainingSeconds": String(cooldownSeconds),
                "policyRequirePQC": policy.requirePQC ? "1" : "0",
                "policyAllowClassicFallback": policy.allowClassicFallback ? "1" : "0",
                "policyMinimumTier": policy.minimumTier.rawValue,
                "policyRequireSecureEnclavePoP": policy.requireSecureEnclavePoP ? "1" : "0",
                "fromStrategy": HandshakeAttemptStrategy.pqcOnly.rawValue,
                "toStrategy": HandshakeAttemptStrategy.classicOnly.rawValue,
                "strategy": HandshakeAttemptStrategy.classicOnly.rawValue
            ]
        ))
        
 // 第二次尝试: Classic-only
        let preparation = try prepareAttempt(strategy: .classicOnly, cryptoProvider: cryptoProvider)
        return try await executor(preparation)
    }
    
 /// 执行握手（带自动回退）- 向后兼容版本
 ///
 /// - Parameters:
 /// - deviceId: 目标设备 ID（用于日志）
 /// - preferPQC: 是否优先尝试 PQC
 /// - policy: 握手策略（控制是否允许 classic 回退）
 /// - executor: 握手执行器
 /// - Returns: 会话密钥
 /// - Throws: HandshakeError
    public static func performHandshake(
        deviceId: String,
        preferPQC: Bool = true,
        policy: HandshakePolicy = .default,
        executor: HandshakeExecutor
    ) async throws -> SessionKeys {
        if policy.requirePQC, !preferPQC {
            throw HandshakeError.failed(.pqcProviderUnavailable)
        }

        if preferPQC {
 // 第一次尝试: PQC-only
            do {
                let sigAAlgorithm = SignatureAlgorithm.mlDSA65
                return try await executor(.pqcOnly, sigAAlgorithm)
            } catch let error as HandshakeError {
 // 检查是否是 PQC 不支持的错误
                if case .failed(let reason) = error,
                   isPQCUnavailableError(reason) {
                    guard policy.allowClassicFallback else {
                        throw error
                    }
 // 发射 fallback event
                    SecurityEventEmitter.emitDetached(SecurityEvent(
                        type: .cryptoDowngrade,
                        severity: .warning,
                        message: "PQC handshake failed, falling back to Classic",
                        context: [
                            "reason": String(describing: reason),
                            "deviceId": deviceId,
                            "cooldownSeconds": String(TwoAttemptHandshakeManager.fallbackCooldownSeconds),
                            "cooldownRemainingSeconds": String(TwoAttemptHandshakeManager.fallbackCooldownSeconds),
                            "policyRequirePQC": policy.requirePQC ? "1" : "0",
                            "policyAllowClassicFallback": policy.allowClassicFallback ? "1" : "0",
                            "policyMinimumTier": policy.minimumTier.rawValue,
                            "policyRequireSecureEnclavePoP": policy.requireSecureEnclavePoP ? "1" : "0",
                            "fromStrategy": HandshakeAttemptStrategy.pqcOnly.rawValue,
                            "toStrategy": HandshakeAttemptStrategy.classicOnly.rawValue,
                            "strategy": HandshakeAttemptStrategy.classicOnly.rawValue
                        ]
                    ))

                    
 // 第二次尝试: Classic-only
                    let sigAAlgorithm = SignatureAlgorithm.ed25519
                    return try await executor(.classicOnly, sigAAlgorithm)
                }
                throw error
            }
        } else {
 // 直接使用 Classic
            let sigAAlgorithm = SignatureAlgorithm.ed25519
            return try await executor(.classicOnly, sigAAlgorithm)
        }
    }
    
 /// 判断是否是 PQC 不可用错误
 ///
 /// **安全设计**: 不把 .timeout 当成"PQC 不支持"
 /// 只有明确的 PQC 不可用错误才允许降级，避免攻击者用丢包/延迟强制降级
 ///
 /// - Parameter reason: 握手失败原因
 /// - Returns: 是否是 PQC 不可用错误
    public static func isPQCUnavailableError(_ reason: HandshakeFailureReason) -> Bool {
        switch reason {
        case .pqcProviderUnavailable, .suiteNotSupported, .suiteNegotiationFailed:
 // 明确的 PQC 不支持错误，允许降级
            return true
        case .timeout:
 // 超时不允许降级（防止攻击者用丢包强制降级）
            return false
        case .cancelled, .peerRejected, .cryptoError, .transportError,
             .versionMismatch, .signatureVerificationFailed, .invalidMessageFormat,
             .identityMismatch, .replayDetected, .secureEnclavePoPRequired,
             .secureEnclaveSignatureInvalid, .keyConfirmationFailed, .suiteSignatureMismatch:
 // 其他错误不允许降级
            return false
        }
    }
    
 /// 根据策略获取 offeredSuites（使用 CryptoProvider）
 ///
 /// - Parameters:
 /// - strategy: 握手尝试策略
 /// - cryptoProvider: 加密 Provider
 /// - Returns: 构建结果
 ///
 /// ** 7.2**: 数据来源必须是 cryptoProvider.supportedSuites
    public static func getSuites(
        for strategy: HandshakeAttemptStrategy,
        cryptoProvider: any CryptoProvider
    ) -> HandshakeOfferedSuites.BuildResult {
        switch strategy {
        case .pqcOnly:
            return HandshakeOfferedSuites.build(strategy: strategy, cryptoProvider: cryptoProvider)
        case .classicOnly:
            var availableSuites = cryptoProvider.supportedSuites
            let classicSuites = ClassicCryptoProvider().supportedSuites
            for suite in classicSuites where !availableSuites.contains(where: { $0.wireId == suite.wireId }) {
                availableSuites.append(suite)
            }
            return HandshakeOfferedSuites.build(strategy: strategy, availableSuites: availableSuites)
        }
    }
    
 /// 根据策略获取 offeredSuites（向后兼容，使用静态列表）
 ///
 /// - Parameter strategy: 握手尝试策略
 /// - Returns: 支持的 suite 列表
 ///
 /// **注意**: 优先使用 `getSuites(for:cryptoProvider:)` 版本
    @available(*, deprecated, message: "Use getSuites(for:cryptoProvider:) instead")
    public static func getSuites(for strategy: HandshakeAttemptStrategy) -> [CryptoSuite] {
        switch strategy {
        case .pqcOnly:
            return CryptoSuite.allPQCSuites
        case .classicOnly:
            return CryptoSuite.allClassicSuites
        }
    }
}

// MARK: - CryptoSuite Extensions
// Note: allPQCSuites and allClassicSuites are defined in PreNegotiationSignatureSelector.swift
