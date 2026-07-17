//
// TwoAttemptHandshakeManager.swift
// SkyBridgeCompassiOS
//
// 两次尝试握手管理器 - 与 macOS SkyBridgeCore 完全兼容
// 解决 "preferPQC 但允许回退 classic" 的互操作问题
//

import Foundation

// MARK: - HandshakeAttemptStrategy

/// 握手尝试策略
public enum HandshakeAttemptStrategy: String, Sendable {
    /// 仅 PQC (offeredSuites 只包含 PQC/Hybrid)
    case pqcOnly = "pqc_only"
    
    /// 仅 Classic (offeredSuites 只包含 Classic)
    case classicOnly = "classic_only"
}

// MARK: - AttemptPreparation

/// Attempt 准备结果
public struct AttemptPreparation: Sendable {
    public let strategy: HandshakeAttemptStrategy
    public let offeredSuites: [CryptoSuite]
    public let cryptoPolicy: CryptoPolicy
    /// Crypto provider for this attempt (PQC attempt may use ApplePQC/OQS; classic attempt uses Classic provider).
    /// iOS handshake context is single-suite; provider MUST match offeredSuites[0].
    public let cryptoProvider: any CryptoProvider
    public let sigAAlgorithm: ProtocolSigningAlgorithm
    public let signatureProvider: any ProtocolSignatureProvider
    
    public init(
        strategy: HandshakeAttemptStrategy,
        offeredSuites: [CryptoSuite],
        cryptoPolicy: CryptoPolicy,
        cryptoProvider: any CryptoProvider,
        sigAAlgorithm: ProtocolSigningAlgorithm,
        signatureProvider: any ProtocolSignatureProvider
    ) {
        self.strategy = strategy
        self.offeredSuites = offeredSuites
        self.cryptoPolicy = cryptoPolicy
        self.cryptoProvider = cryptoProvider
        self.sigAAlgorithm = sigAAlgorithm
        self.signatureProvider = signatureProvider
    }
}

// MARK: - AttemptPreparationError

/// Attempt 准备错误
public enum AttemptPreparationError: Error, Sendable {
    /// PQC Provider 不可用
    case pqcProviderUnavailable
    
    /// Classic Provider 不可用
    case classicProviderUnavailable
    
    /// Fallback 被限流
    case fallbackRateLimited(deviceId: String, cooldownSeconds: Int)
}

public enum PQCOfferMode: Sendable {
    case preferredSingle
    case compatRetry
}

// MARK: - TwoAttemptHandshakeManager

/// 两次尝试握手管理器
///
/// **关键设计**: 解决 "preferPQC 但允许回退 classic" 的互操作问题
///
/// 1. `preferPQC = true`: 先发 PQC-only MessageA，失败后再发 Classic-only MessageA
/// 2. `preferPQC = false`: 直接发 Classic-only MessageA
/// 3. downgrade resistance：不允许 timeout-triggered fallback（防丢包降级）+ policy gate + per-peer rate limiting
/// 4. 事件审计：每次 fallback 都发射 `cryptoDowngrade`（与论文 downgrade/audit 叙述一致）
@available(iOS 17.0, *)
public struct TwoAttemptHandshakeManager: Sendable {
    
    // MARK: - Fallback Rate Limiting
    
    private static let fallbackCooldownSeconds: Int = 300
    
    /// Per-peer fallback 限流 actor
    private actor FallbackRateLimiter {
        private let clock = ContinuousClock()
        
        /// 上次 fallback 时间记录
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
    
    // MARK: - Fallback Whitelist/Blacklist
    
    /// 判断是否允许 fallback
    private static func shouldAllowFallback(_ reason: HandshakeFailureReason) -> Bool {
        switch reason {
        // Paper whitelist (Fig. downgrade-matrix / Sec.G):
        // Only provider unavailability or suite negotiation errors may fallback.
        case .pqcProviderUnavailable, .suiteNegotiationFailed:
            return true
        case .suiteNotSupported:
            // Unknown/unsupported wire suites are security-relevant and must not
            // become a downgrade trigger.
            return false
        case .missingPeerKEMPublicKey:
            // Not a downgrade edge in the paper whitelist. Treat as provisioning/bootstrap signal.
            return false
        case .unknownSuite:
            // Unknown suite must fail closed and never become a downgrade trigger.
            return false
        case .supersededByConcurrentAttempt:
            return false
        case .timeout, .signatureVerificationFailed,
             .replayDetected, .keyConfirmationFailed,
             .suiteSignatureMismatch, .identityMismatch,
             .cancelled, .cryptoError, .transportError,
             .versionMismatch, .invalidMessageFormat, .secureEnclavePoPRequired,
             .secureEnclaveSignatureInvalid, .peerRejected:
            return false
        }
    }
    
    // MARK: - Attempt Preparation
    
    /// 准备 Attempt
    public static func prepareAttempt(
        strategy: HandshakeAttemptStrategy,
        cryptoProvider: any CryptoProvider,
        pqcOfferMode: PQCOfferMode = .preferredSingle
    ) throws -> AttemptPreparation {
        let attemptProvider: any CryptoProvider
        let offeredSuites: [CryptoSuite]
        switch strategy {
        case .pqcOnly:
            let pqcSuites = offeredPQCSuites(using: cryptoProvider, mode: pqcOfferMode)
            guard !pqcSuites.isEmpty else {
                throw AttemptPreparationError.pqcProviderUnavailable
            }
            attemptProvider = cryptoProvider
            offeredSuites = pqcSuites
        case .classicOnly:
            // Always use Classic provider for classic attempt to avoid "strategy=classic_only but activeSuite=PQC" mismatches.
            let classicProvider = ClassicCryptoProvider()
            guard let classicFirst = classicProvider.supportedSuites.first else {
                throw AttemptPreparationError.classicProviderUnavailable
            }
            attemptProvider = classicProvider
            offeredSuites = [classicFirst]
        }
        
        // 2. 选择签名算法
        let sigAAlgorithm: ProtocolSigningAlgorithm
        switch strategy {
        case .pqcOnly:
            sigAAlgorithm = .mlDSA65
        case .classicOnly:
            sigAAlgorithm = .ed25519
        }
        
        // 3. 获取签名 Provider
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: sigAAlgorithm)
        
        return AttemptPreparation(
            strategy: strategy,
            offeredSuites: offeredSuites,
            cryptoPolicy: HandshakeCryptoPolicyResolver.policy(for: offeredSuites),
            cryptoProvider: attemptProvider,
            sigAAlgorithm: sigAAlgorithm,
            signatureProvider: signatureProvider
        )
    }

    private static func offeredPQCSuites(
        using cryptoProvider: any CryptoProvider,
        mode: PQCOfferMode
    ) -> [CryptoSuite] {
        let pqcSuites = availableSuitesForNegotiation(using: cryptoProvider).filter {
            $0.isPQCGroup && $0.isNegotiable
        }
        guard !pqcSuites.isEmpty else { return [] }

        switch mode {
        case .preferredSingle:
            return [pqcSuites[0]]
        case .compatRetry:
            if let purePQC = pqcSuites.first(where: { !$0.isHybrid }) {
                return [purePQC]
            }
            return [pqcSuites[0]]
        }
    }

    private static func availableSuitesForNegotiation(
        using cryptoProvider: any CryptoProvider
    ) -> [CryptoSuite] {
        var suites = cryptoProvider.supportedSuites.filter(\.isNegotiable)
        let explicitXWingPreference = explicitlyPrefersXWingHybridSuite()
        guard cryptoProvider.tier == .nativePQC else {
            if explicitXWingPreference {
                return []
            }
            return deduplicatedSuitesByWire(suites)
        }

        let preferXWing = cryptoProvider.activeSuite == .xwing || prefersXWingHybridSuite()
        let xwingAvailable = isAppleXWingAvailable()

        suites.removeAll { suite in
            suite.wireId == CryptoSuite.xwing.wireId ||
            suite.wireId == CryptoSuite.mlkem768.wireId
        }

        if preferXWing {
            guard xwingAvailable else {
                if explicitXWingPreference {
                    return []
                }
                suites.insert(.mlkem768, at: 0)
                return deduplicatedSuitesByWire(suites)
            }
            suites.insert(.xwing, at: 0)
            suites.insert(.mlkem768, at: 1)
        } else {
            suites.insert(.mlkem768, at: 0)
            if xwingAvailable {
                suites.insert(.xwing, at: 1)
            }
        }

        return deduplicatedSuitesByWire(suites)
    }

    private static func deduplicatedSuitesByWire(_ suites: [CryptoSuite]) -> [CryptoSuite] {
        var seen = Set<UInt16>()
        var result: [CryptoSuite] = []
        result.reserveCapacity(suites.count)
        for suite in suites where seen.insert(suite.wireId).inserted {
            result.append(suite)
        }
        return result
    }

    private static func prefersXWingHybridSuite() -> Bool {
        if explicitlyPrefersXWingHybridSuite() {
            return true
        }

        return UserDefaults.standard.bool(forKey: "Settings.PreferXWingHybrid")
    }

    private static func explicitlyPrefersXWingHybridSuite() -> Bool {
        if let raw = ProcessInfo.processInfo.environment["SB_PQC_PREFERRED_SUITE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           raw == "xwing" || raw == "hybrid" {
            return true
        }

        return false
    }

    private static func isAppleXWingAvailable() -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleXWingCryptoProvider.selfTest()
        }
        #endif
        return false
    }
    
    /// 握手执行器类型（使用 AttemptPreparation）
    public typealias PreparedHandshakeExecutor = @Sendable (
        _ preparation: AttemptPreparation
    ) async throws -> SessionKeys
    
    /// 执行握手（带自动回退，使用 AttemptPreparation）
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
                let preparation = try prepareAttempt(
                    strategy: .pqcOnly,
                    cryptoProvider: cryptoProvider,
                    pqcOfferMode: .preferredSingle
                )
                return try await executor(preparation)
            } catch let error as AttemptPreparationError {
                // PQC 准备失败，尝试 fallback
                if case .pqcProviderUnavailable = error {
                    if !policy.requirePQC,
                       let bridged = try await attemptPQCCompatibilityRetry(
                        deviceId: deviceId,
                        reason: .pqcProviderUnavailable,
                        policy: policy,
                        cryptoProvider: cryptoProvider,
                        executor: executor
                    ) {
                        return bridged
                    }
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
                if case .failed(let reason) = error {
                    if !policy.requirePQC,
                       let bridged = try await attemptPQCCompatibilityRetry(
                        deviceId: deviceId,
                        reason: reason,
                        policy: policy,
                        cryptoProvider: cryptoProvider,
                        executor: executor
                    ) {
                        return bridged
                    }
                    if shouldAllowFallback(reason) {
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
                }
                throw error
            }
        } else {
            // 直接使用 Classic
            let preparation = try prepareAttempt(strategy: .classicOnly, cryptoProvider: cryptoProvider)
            return try await executor(preparation)
        }
    }

    private static func shouldAttemptPQCCompatibilityRetry(_ reason: HandshakeFailureReason) -> Bool {
        switch reason {
        case .pqcProviderUnavailable, .suiteNegotiationFailed:
            return true
        case .missingPeerKEMPublicKey:
            // Missing peer KEM is a trust/provisioning failure, not a suite compatibility signal.
            // Retrying with another PQC suite hides the real connect-stage defect.
            return false
        case .suiteNotSupported,
             .unknownSuite,
             .timeout,
             .cancelled,
             .peerRejected,
             .cryptoError,
             .transportError,
             .versionMismatch,
             .signatureVerificationFailed,
             .invalidMessageFormat,
             .identityMismatch,
             .replayDetected,
             .secureEnclavePoPRequired,
             .secureEnclaveSignatureInvalid,
             .keyConfirmationFailed,
             .suiteSignatureMismatch,
             .supersededByConcurrentAttempt:
            return false
        }
    }

    private static func attemptPQCCompatibilityRetry(
        deviceId: String,
        reason: HandshakeFailureReason,
        policy: HandshakePolicy,
        cryptoProvider: any CryptoProvider,
        executor: PreparedHandshakeExecutor
    ) async throws -> SessionKeys? {
        guard shouldAttemptPQCCompatibilityRetry(reason) else {
            return nil
        }

        let bridgePreparation: AttemptPreparation
        do {
            bridgePreparation = try prepareAttempt(
                strategy: .pqcOnly,
                cryptoProvider: cryptoProvider,
                pqcOfferMode: .compatRetry
            )
        } catch {
            return nil
        }

        guard bridgePreparation.offeredSuites.allSatisfy({ !$0.isHybrid }) else {
            return nil
        }

        SecurityEventEmitter.emitDetached(SecurityEvent(
            type: .handshakeFailed,
            severity: .info,
            message: "Retrying PQC handshake with pure-PQC compatibility suite",
            context: [
                "deviceId": HandshakeDiagnosticRedaction.stableIdentifierLabel(deviceId),
                "reason": reason.diagnosticReasonCode,
                "strategy": HandshakeAttemptStrategy.pqcOnly.rawValue,
                "bridgeMode": "pure_pqc_compat_retry",
                "policyRequirePQC": policy.requirePQC ? "1" : "0"
            ]
        ))

        return try await executor(bridgePreparation)
    }
    
    /// 尝试 fallback（带限流）
    private static func attemptFallback(
        deviceId: String,
        reason: HandshakeFailureReason,
        policy: HandshakePolicy,
        cryptoProvider: any CryptoProvider,
        executor: PreparedHandshakeExecutor
    ) async throws -> SessionKeys {
        // Defense-in-depth: strict PQC forbids all fallback edges (paper semantics).
        if policy.requirePQC {
            throw HandshakeError.failed(reason)
        }
        guard policy.allowClassicFallback else {
            throw HandshakeError.failed(reason)
        }

        // Paper D2 / "identity-verified peer" gate:
        // Only allow downgrade fallback if the peer already has a local trust record.
        guard isPeerTrusted(deviceId: deviceId) else {
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .handshakeFailed,
                severity: .warning,
                message: "Fallback blocked: peer not trusted (identity gate)",
                context: [
                    "reason": "untrusted_peer_fallback_blocked",
                    "deviceId": HandshakeDiagnosticRedaction.stableIdentifierLabel(deviceId),
                    "originalFailure": reason.diagnosticReasonCode,
                    "downgradeResistance": "policy_gate+no_timeout_fallback+rate_limited",
                    "policyInTranscript": "1",
                    "transcriptBinding": "1",
                    "policyRequirePQC": policy.requirePQC ? "1" : "0",
                    "policyAllowClassicFallback": policy.allowClassicFallback ? "1" : "0",
                    "policyMinimumTier": policy.minimumTier.rawValue,
                    "policyRequireSecureEnclavePoP": policy.requireSecureEnclavePoP ? "1" : "0"
                ]
            ))
            throw HandshakeError.failed(reason)
        }
        
        // 检查限流
        let canFallback = await rateLimiter.canFallback(deviceId: deviceId)
        guard canFallback else {
            let cooldown = await rateLimiter.remainingCooldown(deviceId: deviceId)
            throw AttemptPreparationError.fallbackRateLimited(deviceId: deviceId, cooldownSeconds: cooldown)
        }
        
        // 记录 fallback
        await rateLimiter.recordFallback(deviceId: deviceId)
        
        // 发射 fallback 事件（结构化字段与 macOS core 对齐）
        let cooldownSeconds = TwoAttemptHandshakeManager.fallbackCooldownSeconds
        SecurityEventEmitter.emitDetached(SecurityEvent(
            type: .cryptoDowngrade,
            severity: .warning,
            message: "PQC handshake failed, falling back to Classic",
            context: [
                "downgradeResistance": "policy_gate+no_timeout_fallback+rate_limited",
                "policyInTranscript": "1",
                "transcriptBinding": "1",
                "reason": reason.diagnosticReasonCode,
                "deviceId": HandshakeDiagnosticRedaction.stableIdentifierLabel(deviceId),
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
    
    /// 判断是否是 PQC 不可用错误
    public static func isPQCUnavailableError(_ reason: HandshakeFailureReason) -> Bool {
        switch reason {
        // Paper whitelist (Sec.G): treat only these as local PQC-unavailability / negotiation failures.
        case .pqcProviderUnavailable, .suiteNegotiationFailed:
            return true
        case .suiteNotSupported:
            // Unknown/unsupported wire suites fail closed; falling back here can
            // turn protocol confusion into a classic downgrade.
            return false
        case .missingPeerKEMPublicKey:
            // Distinguish from "pqc unavailable": it's "missing peer provisioning".
            return false
        case .unknownSuite:
            return false
        case .supersededByConcurrentAttempt:
            return false
        case .timeout, .cancelled, .peerRejected, .cryptoError, .transportError,
             .versionMismatch, .signatureVerificationFailed, .invalidMessageFormat,
             .identityMismatch, .replayDetected, .secureEnclavePoPRequired,
             .secureEnclaveSignatureInvalid, .keyConfirmationFailed, .suiteSignatureMismatch:
            return false
        }
    }

    // MARK: - Trust Gate Helper

    /// Non-actor trust check used by the fallback gate.
    ///
    /// We intentionally avoid calling `TrustedDeviceStore.shared` here, because it is `@MainActor`.
    /// The underlying trust record is persisted in UserDefaults under `trusted_devices.v1`.
    private static func isPeerTrusted(deviceId: String) -> Bool {
        guard !deviceId.isEmpty else { return false }
        let storageKey = "trusted_devices.v1"
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return false }
        struct Stored: Codable { let id: String }
        let list = (try? JSONDecoder().decode([Stored].self, from: data)) ?? []
        return list.contains(where: { $0.id == deviceId })
    }
}
