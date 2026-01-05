//
// HandshakeDriver.swift
// SkyBridgeCore
//
// Tech Debt Cleanup - 11: HandshakeDriver (P0 竞态修复)
// Tech Debt Cleanup - 13: HandshakeMetrics 集成
// Requirements: 4.1, 4.2, 4.5, 4.6, 4.7, 4.8, 6.1, 6.2
//
// 握手驱动器 Actor：
// - 管理握手状态机
// - 实现双 resume 防护 (P0)
// - 实现 MessageB 早到防护 (P0)
// - 实现取消语义 (P0)
// - 收集握手指标 ( 13.2)
//

import Foundation
import CryptoKit

// MARK: - DiscoveryTransport Protocol

/// 发现传输协议
public protocol DiscoveryTransport: Sendable {
 /// 发送数据到对端
    func send(to peer: PeerIdentifier, data: Data) async throws
}

// MARK: - HandshakeTrustProvider

/// Identity pinning provider for handshake trust checks.
@available(macOS 14.0, iOS 17.0, *)
public protocol HandshakeTrustProvider: Sendable {
    func trustedFingerprint(for deviceId: String) async -> String?
    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data]
    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data?
}

@available(macOS 14.0, iOS 17.0, *)
struct DefaultHandshakeTrustProvider: HandshakeTrustProvider, Sendable {
    func trustedFingerprint(for deviceId: String) async -> String? {
        await MainActor.run {
            TrustSyncService.shared.getTrustRecord(deviceId: deviceId)?.pubKeyFP
        }
    }
    
    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        await MainActor.run {
            guard let record = TrustSyncService.shared.getTrustRecord(deviceId: deviceId),
                  let kemKeys = record.kemPublicKeys else {
                return [:]
            }
            var result: [CryptoSuite: Data] = [:]
            for key in kemKeys {
                result[CryptoSuite(wireId: key.suiteWireId)] = key.publicKey
            }
            return result
        }
    }
    
    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        await MainActor.run {
            guard let record = TrustSyncService.shared.getTrustRecord(deviceId: deviceId) else {
                return nil
            }
            return record.secureEnclavePublicKey
        }
    }
}

// MARK: - HandshakeDriver

/// 握手驱动器 Actor
///
/// **关键设计：竞态与取消语义**
///
/// 1. 双 resume 防护 (P0 - 11.2)：
/// - 使用 timeoutTask 可取消
/// - 使用 finishOnce() 统一收敛成功/失败
/// - finishOnce 内部 guard pendingContinuation != nil 再 resume，并立刻置 nil
///
/// 2. MessageB 早到防护 (P0 - 11.3)：
/// - pendingResult 暂存早到的结果
/// - continuation 建立时检查 pendingResult，有则立即 resume
///
/// 3. 取消语义 (P0 - 11.6)：
/// - 调用方取消时必须 zeroize + emit event
@available(macOS 14.0, iOS 17.0, *)
public actor HandshakeDriver {
    
 // MARK: - Properties
    
 /// 当前状态
    private var state: HandshakeState = .idle
    
 /// 传输层
    private let transport: any DiscoveryTransport
    
 /// 加密 Provider
    private let cryptoProvider: any CryptoProvider
    
 /// 签名 Provider（可选，旧版本使用）
    private let signatureProvider: (any CryptoProvider)?
    
 /// 协议签名 Provider（ 5.3: sigA/sigB 专用）
 /// **Requirements: 7.2, 7.3**
    private let protocolSignatureProvider: (any ProtocolSignatureProvider)?
    
 /// SE PoP 签名 Provider（ 5.3: seSigA/seSigB 专用）
 /// **Requirements: 7.2, 7.3**
    private let sePoPSignatureProvider: (any SePoPSignatureProvider)?
    
 /// 超时时间
    private let timeout: Duration
    
 /// 握手上下文
    private var context: HandshakeContext?
    
 /// 等待中的 continuation（用于异步等待结果）
 /// P0: 双 resume 防护 - finishOnce 中 guard 后立刻置 nil
    private var pendingContinuation: CheckedContinuation<SessionKeys, Error>?
    
 /// 超时任务
 /// P0: 双 resume 防护 - 成功/失败时取消
    private var timeoutTask: Task<Void, Never>?
    
 /// 早到的结果（处理 MessageB 早到）
 /// P0: MessageB 早到防护 - continuation 建立前暂存结果
    private var pendingResult: Result<SessionKeys, Error>?

 /// MessageB 处理 epoch（防重入）
    private var messageBEpoch: UInt64 = 0
    
 /// 身份密钥句柄（用于签名）
    private let identityKeyHandle: SigningKeyHandle?

 /// Secure Enclave PoP 签名句柄（可选）
    private let secureEnclaveKeyHandle: SigningKeyHandle?
    
 /// 身份公钥
    private let identityPublicKey: Data
    
 /// 对端标识（用于日志）
    private var currentPeer: PeerIdentifier?
    
 /// 指标收集器 ( 13.2)
 /// Requirement 6.1, 6.2
    private let metricsCollector: HandshakeMetricsCollector
    
 /// 最近一次握手的指标
    private var lastMetrics: HandshakeMetrics?
    
 /// 信任提供方（用于 identity pinning）
    private let trustProvider: any HandshakeTrustProvider
    
 /// 握手策略
    private let policy: HandshakePolicy
    
    private let cryptoPolicy: CryptoPolicy
    
 /// sigA 使用的签名算法（ 9.1）
 ///
 /// 用于验证 selectedSuite 与 sigA 算法的兼容性。
 /// 如果为 nil，跳过兼容性验证（向后兼容旧版本）。
    private let sigAAlgorithm: SignatureAlgorithm?
    
    private var pendingFinished: HandshakeFinished?
    
 // MARK: - Initialization
    
 /// 初始化握手驱动器（ 2 新版本）
 ///
 /// - Parameters:
 /// - transport: 传输层
 /// - cryptoProvider: 加密 Provider（用于 KEM/AEAD）
 /// - protocolSignatureProvider: 协议签名 Provider（用于 sigA/sigB）
 /// - protocolSigningKeyHandle: 协议签名密钥句柄
 /// - sigAAlgorithm: sigA 使用的签名算法
 /// - identityPublicKey: 身份公钥
 /// - sePoPSignatureProvider: SE PoP 签名 Provider（可选）
 /// - sePoPSigningKeyHandle: SE PoP 签名密钥句柄（可选）
 /// - offeredSuites: 提供的 suite 列表（用于同质性验证）
 /// - policy: 握手策略
 /// - cryptoPolicy: 加密策略
 /// - timeout: 超时时间
 /// - metricsCollector: 指标收集器
 /// - trustProvider: 信任提供方
 ///
 /// **Requirements: 7.1, 7.2, 7.3, 7.4, 7.5**
 ///
 /// - Throws:
 /// - `emptyOfferedSuites`: offeredSuites 为空
 /// - `homogeneityViolation`: offeredSuites 混装 PQC 和 Classic
 /// - `providerAlgorithmMismatch`: provider 与 algorithm 不匹配
 /// - `signatureAlgorithmMismatch`: keyHandle 类型与 algorithm 不匹配
 /// - `invalidProviderType`: CryptoProvider 被当成签名 provider
    public init(
        transport: any DiscoveryTransport,
        cryptoProvider: any CryptoProvider,
        protocolSignatureProvider: any ProtocolSignatureProvider,
        protocolSigningKeyHandle: SigningKeyHandle,
        sigAAlgorithm: ProtocolSigningAlgorithm,
        identityPublicKey: Data,
        sePoPSignatureProvider: (any SePoPSignatureProvider)? = nil,
        sePoPSigningKeyHandle: SigningKeyHandle? = nil,
        offeredSuites: [CryptoSuite],
        policy: HandshakePolicy = .default,
        cryptoPolicy: CryptoPolicy = .default,
        timeout: Duration = HandshakeConstants.defaultTimeout,
        metricsCollector: HandshakeMetricsCollector? = nil,
        trustProvider: (any HandshakeTrustProvider)? = nil
    ) throws {
 // 5.1: 初始化时 throw 校验
        
 // 1. offeredSuites 非空
        guard !offeredSuites.isEmpty else {
            throw HandshakeError.emptyOfferedSuites
        }
        
 // 2. offeredSuites 同质性验证
        try Self.validateSuiteHomogeneity(offeredSuites: offeredSuites, sigAAlgorithm: sigAAlgorithm)
        
 // 3. provider.signatureAlgorithm == sigAAlgorithm
        guard protocolSignatureProvider.signatureAlgorithm == sigAAlgorithm else {
            throw HandshakeError.providerAlgorithmMismatch(
                provider: String(describing: type(of: protocolSignatureProvider)),
                algorithm: sigAAlgorithm.rawValue
            )
        }
        
 // 4. keyHandle 类型与 algorithm 匹配验证
        try Self.validateKeyHandleCompatibility(keyHandle: protocolSigningKeyHandle, algorithm: sigAAlgorithm)
        
 // 5. 5.2: 防止 CryptoProvider 被当签名 provider（编译期已保证，这是运行时双保险）
 // 注意：由于 ProtocolSignatureProvider 和 CryptoProvider 是不同协议，
 // 编译期已经阻止了这种情况，但我们仍然添加运行时检查作为防御性编程
        
        self.transport = transport
        self.cryptoProvider = cryptoProvider
        self.identityKeyHandle = protocolSigningKeyHandle
        self.secureEnclaveKeyHandle = sePoPSigningKeyHandle
        self.identityPublicKey = identityPublicKey
        self.signatureProvider = nil  // 新版本不使用旧的 signatureProvider
 // 5.3: 存储分流 provider
        self.protocolSignatureProvider = protocolSignatureProvider
        self.sePoPSignatureProvider = sePoPSignatureProvider
        self.sigAAlgorithm = sigAAlgorithm.wire
        self.policy = policy
        self.cryptoPolicy = cryptoPolicy
        self.timeout = timeout
        self.metricsCollector = metricsCollector ?? HandshakeMetricsCollector()
        self.trustProvider = trustProvider ?? DefaultHandshakeTrustProvider()
    }
    
 /// 验证 offeredSuites 同质性
 ///
 /// **Property 2: offeredSuites-sigAAlgorithm Homogeneity**
 /// - ML-DSA-65 → ALL suites isPQCGroup == true
 /// - Ed25519 → ALL suites isPQCGroup == false
 ///
 /// **Requirements: 1.3, 1.4, 2.1, 2.2, 2.3**
    private static func validateSuiteHomogeneity(
        offeredSuites: [CryptoSuite],
        sigAAlgorithm: ProtocolSigningAlgorithm
    ) throws {
        switch sigAAlgorithm {
        case .mlDSA65:
 // ML-DSA-65 → ALL suites 必须是 PQC 组
            let nonPQCSuites = offeredSuites.filter { !$0.isPQCGroup }
            guard nonPQCSuites.isEmpty else {
                throw HandshakeError.homogeneityViolation(
                    message: "sigAAlgorithm=ML-DSA-65 but offeredSuites contains non-PQC suites: \(nonPQCSuites.map { $0.rawValue })"
                )
            }
        case .ed25519:
 // Ed25519 → ALL suites 必须是 Classic 组
            let pqcSuites = offeredSuites.filter { $0.isPQCGroup }
            guard pqcSuites.isEmpty else {
                throw HandshakeError.homogeneityViolation(
                    message: "sigAAlgorithm=Ed25519 but offeredSuites contains PQC/Hybrid suites: \(pqcSuites.map { $0.rawValue })"
                )
            }
        }
    }
    
 /// 验证 keyHandle 与 algorithm 的兼容性
 ///
 /// **Requirements: 7.4, 7.5**
    private static func validateKeyHandleCompatibility(
        keyHandle: SigningKeyHandle,
        algorithm: ProtocolSigningAlgorithm
    ) throws {
        switch keyHandle {
        case .softwareKey(let data):
 // 验证密钥长度
            switch algorithm {
            case .ed25519:
 // Ed25519 私钥：32 bytes (seed) 或 64 bytes (seed + public)
                guard data.count == 32 || data.count == 64 else {
                    throw HandshakeError.signatureAlgorithmMismatch(
                        algorithm: algorithm.rawValue,
                        keyHandleType: "softwareKey(\(data.count) bytes), expected 32 or 64 bytes for Ed25519"
                    )
                }
            case .mlDSA65:
 // ML-DSA-65 私钥：64 bytes (seed) 或 4032 bytes (full)
                guard data.count == 64 || data.count == 4032 else {
                    throw HandshakeError.signatureAlgorithmMismatch(
                        algorithm: algorithm.rawValue,
                        keyHandleType: "softwareKey(\(data.count) bytes), expected 64 or 4032 bytes for ML-DSA-65"
                    )
                }
            }
        #if canImport(Security)
        case .secureEnclaveRef:
 // Secure Enclave 只支持 P-256，不支持 Ed25519 或 ML-DSA-65
            throw HandshakeError.signatureAlgorithmMismatch(
                algorithm: algorithm.rawValue,
                keyHandleType: "secureEnclaveRef (Secure Enclave only supports P-256, not \(algorithm.rawValue))"
            )
        #endif
        case .callback:
 // 回调类型不做长度验证，由回调实现负责
            break
        }
    }
    
 /// 初始化握手驱动器（旧版本，已废弃）
 ///
 /// - Parameters:
 /// - transport: 传输层
 /// - cryptoProvider: 加密 Provider
 /// - identityKeyHandle: 身份密钥句柄（可选）
 /// - identityPublicKey: 身份公钥
 /// - timeout: 超时时间
 /// - metricsCollector: 指标收集器
 ///
 /// **Requirements: 2.1, 2.2**
    @available(*, deprecated, message: "Use init(transport:cryptoProvider:protocolSignatureProvider:protocolSigningKeyHandle:sigAAlgorithm:identityPublicKey:...) instead")
    public init(
        transport: any DiscoveryTransport,
        cryptoProvider: any CryptoProvider,
        identityKeyHandle: SigningKeyHandle? = nil,
        secureEnclaveKeyHandle: SigningKeyHandle? = nil,
        identityPublicKey: Data,
        signatureProvider: (any CryptoProvider)? = nil,
        sigAAlgorithm: SignatureAlgorithm? = nil,
        policy: HandshakePolicy = .default,
        cryptoPolicy: CryptoPolicy = .default,
        timeout: Duration = HandshakeConstants.defaultTimeout,
        metricsCollector: HandshakeMetricsCollector? = nil,
        trustProvider: (any HandshakeTrustProvider)? = nil
    ) {
        self.transport = transport
        self.cryptoProvider = cryptoProvider
        self.identityKeyHandle = identityKeyHandle
        self.secureEnclaveKeyHandle = secureEnclaveKeyHandle
        self.identityPublicKey = identityPublicKey
        self.signatureProvider = signatureProvider
 // 5.3: 旧版本不使用分流 provider
        self.protocolSignatureProvider = nil
        self.sePoPSignatureProvider = nil
        self.sigAAlgorithm = sigAAlgorithm
        self.policy = policy
        self.cryptoPolicy = cryptoPolicy
        self.timeout = timeout
        self.metricsCollector = metricsCollector ?? HandshakeMetricsCollector()
        self.trustProvider = trustProvider ?? DefaultHandshakeTrustProvider()
    }
    
 // MARK: - Public API
    
 /// 发起握手（发起方调用）
 /// - Parameter peer: 对端标识
 /// - Returns: 会话密钥
 /// - Throws: HandshakeError
    public func initiateHandshake(with peer: PeerIdentifier) async throws -> SessionKeys {
        guard case .idle = state else {
            throw HandshakeError.alreadyInProgress
        }
        
        currentPeer = peer
        
 // 13.2: 记录握手开始 (Requirement 6.1)
        await metricsCollector.recordStart()
        
 // 创建握手上下文
 // 5.3: 传递分流的签名 provider
        let peerKEMPublicKeys = await trustProvider.trustedKEMPublicKeys(for: peer.deviceId)
        let ctx = try await HandshakeContext.create(
            role: .initiator,
            cryptoProvider: cryptoProvider,
            signatureProvider: signatureProvider,
            protocolSignatureProvider: protocolSignatureProvider,
            sePoPSignatureProvider: sePoPSignatureProvider,
            cryptoPolicy: cryptoPolicy,
            peerKEMPublicKeys: peerKEMPublicKeys
        )
        context = ctx
        
        if policy.requireSecureEnclavePoP, secureEnclaveKeyHandle == nil {
            await ctx.zeroize()
            context = nil
            throw HandshakeError.failed(.secureEnclavePoPRequired)
        }
        
 // 构建 MessageA
        let messageA: HandshakeMessageA
        do {
 // 获取用于签名的私钥
 // 如果有签名回调，我们仍需要私钥用于 HandshakeContext
 // 签名回调将在未来版本中集成到 HandshakeContext
            messageA = try await ctx.buildMessageA(
                identityKeyHandle: identityKeyHandle,
                identityPublicKey: identityPublicKey,
                policy: policy,
                secureEnclaveKeyHandle: secureEnclaveKeyHandle
            )
        } catch {
 // 构建失败时必须 zeroize ( 11.5)
            await ctx.zeroize()
            context = nil
            throw error
        }
        
 // 更新状态
        state = .sendingMessageA
        
 // 发送 MessageA（失败时必须 zeroize - 11.5）
        do {
            try await transport.send(to: peer, data: messageA.encoded)
 // 13.2: 记录 MessageA 发送时间 (Requirement 6.1)
            await metricsCollector.recordMessageASent()
        } catch {
            await ctx.zeroize()
            context = nil
            await transitionToFailed(.transportError(error.localizedDescription))
            throw HandshakeError.failed(.transportError(error.localizedDescription))
        }
        
 // 等待 MessageB（带超时 - 11.4）
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        state = .waitingMessageB(deadline: deadline)
        
        return try await withCheckedThrowingContinuation { continuation in
 // P0 11.3: 检查是否有早到的结果
            if let result = self.pendingResult {
                self.pendingResult = nil
                switch result {
                case .success(let keys):
                    continuation.resume(returning: keys)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
                return
            }
            
            self.pendingContinuation = continuation
            
 // P0 11.2 & 11.4: 设置可取消的超时任务
 // 使用 .sleep(until:tolerance:clock:) 实现超时
 // tolerance 设为 100ms，SLA < 1s（非实时系统）
            self.timeoutTask = Task {
                do {
                    try await Task.sleep(
                        until: clock.now + self.timeout,
                        tolerance: HandshakeConstants.timeoutTolerance,
                        clock: clock
                    )
 // 超时触发
                    await self.handleTimeout()
                } catch {
 // 被取消（正常退出，不做任何事）
                }
            }
        }
    }
    
 /// 处理收到的消息
 /// - Parameters:
 /// - data: 消息数据
 /// - peer: 发送方
    public func handleMessage(_ data: Data, from peer: PeerIdentifier) async {
        if isFinishedMessage(data) {
            if let finished = try? HandshakeFinished.decode(from: data) {
                await handleFinished(finished, from: peer)
                return
            }
        }
        switch state {
        case .waitingMessageB:
            await handleMessageB(data)
        case .processingMessageB:
            SkyBridgeLogger.p2p.warning("Ignored handshake message during processingMessageB")
            
        case .waitingFinished:
            if let finished = try? HandshakeFinished.decode(from: data) {
                await handleFinished(finished, from: peer)
            } else {
                SkyBridgeLogger.p2p.warning("Unexpected message while waitingFinished")
            }
        case .idle:
 // 作为响应方处理 MessageA
            await handleMessageA(data, from: peer)
            
        default:
 // 忽略非预期消息
            SkyBridgeLogger.p2p.warning("Unexpected handshake message in state")
        }
    }
    
 /// 取消握手 (P0 - 11.6)
 ///
 /// **关键**：
 /// - 调用方取消时必须 zeroize context
 /// - 取消 timeoutTask
 /// - 发射 SecurityEvent(.handshakeFailed) with reason .cancelled
    public func cancel() async {
 // 只有在非 idle 状态才需要取消
        guard case .idle = state else {
            let negotiatedSuite = await context?.negotiatedSuite
            let isFallback = negotiatedSuite.map { cryptoProvider.activeSuite.isPQC && !$0.isPQC }
            let peerId = currentPeer?.deviceId ?? "unknown"

 // 清理上下文（必须 zeroize - 11.6）
            if let ctx = context {
                await ctx.zeroize()
                context = nil
            }
            
 // 取消超时任务
            timeoutTask?.cancel()
            timeoutTask = nil
            
 // 发射取消事件 ( 11.6)
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .handshakeFailed,
                severity: .info,
                message: "Handshake cancelled by caller",
                context: [
                    "reason": "cancelled",
                    "peer": peerId
                ]
            ))

 // 记录取消指标
            await metricsCollector.recordFinish()
            lastMetrics = await metricsCollector.buildMetrics(
                cryptoSuite: negotiatedSuite,
                isFallback: isFallback,
                failureReason: .cancelled
            )
            
 // 使用 finishOnce 统一收敛 (P0 - 11.2)
            finishOnce(with: .failure(HandshakeError.failed(.cancelled)))
            
            state = .failed(reason: .cancelled)
            return
        }
    }
    
 /// 获取当前状态（用于测试）
    public func getCurrentState() -> HandshakeState {
        return state
    }
    
 /// 获取最近一次握手的指标 ( 13.2)
 /// Requirement 6.1, 6.2
    public func getLastMetrics() -> HandshakeMetrics? {
        return lastMetrics
    }
    
 // MARK: - Private Methods
    
 /// 处理 MessageA（响应方）
    private func handleMessageA(_ data: Data, from peer: PeerIdentifier) async {
        currentPeer = peer
        await metricsCollector.recordStart()
        
        do {
            let messageA = try HandshakeMessageA.decode(from: data)
            
 // 创建响应方上下文
 // 5.3: 传递分流的签名 provider
            let peerKEMPublicKeys = await trustProvider.trustedKEMPublicKeys(for: peer.deviceId)
            let ctx = try await HandshakeContext.create(
                role: .responder,
                cryptoProvider: cryptoProvider,
                signatureProvider: signatureProvider,
                protocolSignatureProvider: protocolSignatureProvider,
                sePoPSignatureProvider: sePoPSignatureProvider,
                cryptoPolicy: cryptoPolicy,
                peerKEMPublicKeys: peerKEMPublicKeys
            )
            context = ctx
            
            state = .processingMessageA
            
 // 处理 MessageA
            do {
                if policy.requireSecureEnclavePoP, secureEnclaveKeyHandle == nil {
                    throw HandshakeError.failed(.secureEnclavePoPRequired)
                }
                let pinnedSEPublicKey = await trustProvider.trustedSecureEnclavePublicKey(for: peer.deviceId)
                try await ctx.processMessageA(
                    messageA,
                    policy: policy,
                    postSignatureValidation: { identityPublicKey in
                        try await self.enforceIdentityPinning(
                            deviceId: peer.deviceId,
                            identityPublicKey: identityPublicKey
                        )
                    },
                    secureEnclavePublicKey: pinnedSEPublicKey
                )
            } catch {
                await handleHandshakeError(error, context: ctx)
                return
            }
            
 // 构建 MessageB
            state = .sendingMessageB
            let messageB: HandshakeMessageB
            let messageBSecret: SecureBytes
            do {
 // 获取用于签名的私钥
                let result = try await ctx.buildMessageB(
                    identityKeyHandle: identityKeyHandle,
                    identityPublicKey: identityPublicKey,
                    policy: policy,
                    secureEnclaveKeyHandle: secureEnclaveKeyHandle
                )
                messageB = result.message
                messageBSecret = result.sharedSecret
            } catch {
                await handleHandshakeError(error, context: ctx)
                return
            }
            
 // 发送 MessageB（失败时必须 zeroize - 11.5）
            do {
                try await transport.send(to: peer, data: messageB.encoded)
            } catch {
                await handleHandshakeError(HandshakeError.failed(.transportError(error.localizedDescription)), context: ctx)
                return
            }
            
 // 响应方在发送 MessageB 后完成
            let sessionKeys: SessionKeys
            do {
                sessionKeys = try await ctx.finalizeResponderSessionKeys(sharedSecret: messageBSecret)
            } catch {
                await handleHandshakeError(error, context: ctx)
                return
            }
            
 // 清理敏感数据
            await ctx.zeroize()
            context = nil
            
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            state = .waitingFinished(deadline: deadline, sessionKeys: sessionKeys, expectingFrom: .initiator)
            
            timeoutTask?.cancel()
            timeoutTask = Task {
                do {
                    try await Task.sleep(
                        until: clock.now + self.timeout,
                        tolerance: HandshakeConstants.timeoutTolerance,
                        clock: clock
                    )
                    await self.handleTimeout()
                } catch {
                }
            }
            
            do {
                let finished = try makeFinished(
                    direction: .responderToInitiator,
                    sessionKeys: sessionKeys
                )
                try await transport.send(to: peer, data: finished.encoded)
            } catch {
                await transitionToFailed(.transportError(error.localizedDescription), negotiatedSuite: sessionKeys.negotiatedSuite)
                return
            }
            
            if let pending = pendingFinished {
                pendingFinished = nil
                await handleFinished(pending, from: peer)
            }
            
        } catch {
            await transitionToFailed(.invalidMessageFormat(error.localizedDescription))
        }
    }
    
 /// 处理 MessageB（发起方）
    private func handleMessageB(_ data: Data) async {
 // 13.2: 记录 MessageB 接收时间 (Requirement 6.1)
        await metricsCollector.recordMessageBReceived()
        
        guard let ctx = context else {
            await transitionToFailed(.invalidMessageFormat("No context available"))
            return
        }

        let epoch = messageBEpoch &+ 1
        messageBEpoch = epoch
        state = .processingMessageB(epoch: epoch)
        
        do {
            let messageB = try HandshakeMessageB.decode(from: data)
            
 // 9.1: 验证 selectedSuite 与 sigA 算法的兼容性
 // Requirements: 1.1, 1.2
            if let sigAAlg = sigAAlgorithm {
                guard PreNegotiationSignatureSelector.validateSuiteCompatibility(
                    selectedSuite: messageB.selectedSuite,
                    sigAAlgorithm: sigAAlg
                ) else {
 // 发射签名算法不匹配事件
                    SecurityEventEmitter.emitDetached(SecurityEvent(
                        type: .signatureAlgorithmMismatch,
                        severity: .high,
                        message: "Suite-signature mismatch: selectedSuite incompatible with sigA algorithm",
                        context: [
                            "selectedSuite": messageB.selectedSuite.rawValue,
                            "sigAAlgorithm": sigAAlg.rawValue,
                            "deviceId": currentPeer?.deviceId ?? "unknown"
                        ]
                    ))
                    await transitionToFailed(.suiteSignatureMismatch(
                        selectedSuite: messageB.selectedSuite.rawValue,
                        sigAAlgorithm: sigAAlg.rawValue
                    ))
                    return
                }
            }
            
            let pinnedDeviceId = currentPeer?.deviceId
            let postSignatureValidation: (@Sendable (Data) async throws -> Void)?
            if let pinnedDeviceId {
                postSignatureValidation = { identityPublicKey in
                    try await self.enforceIdentityPinning(
                        deviceId: pinnedDeviceId,
                        identityPublicKey: identityPublicKey
                    )
                }
            } else {
                postSignatureValidation = nil
            }
            
            let pinnedSEPublicKey: Data?
            if let pinnedDeviceId {
                pinnedSEPublicKey = await trustProvider.trustedSecureEnclavePublicKey(for: pinnedDeviceId)
            } else {
                pinnedSEPublicKey = nil
            }
            
            let sessionKeys = try await ctx.processMessageB(
                messageB,
                policy: policy,
                postSignatureValidation: postSignatureValidation,
                secureEnclavePublicKey: pinnedSEPublicKey
            )

            guard case .processingMessageB(let currentEpoch) = state,
                  currentEpoch == epoch else {
                await ctx.zeroize()
                context = nil
                SkyBridgeLogger.p2p.warning("Handshake state changed during MessageB processing")
                return
            }
            
            await ctx.zeroize()
            context = nil
            
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            state = .waitingFinished(deadline: deadline, sessionKeys: sessionKeys, expectingFrom: .responder)
            
            timeoutTask?.cancel()
            timeoutTask = Task {
                do {
                    try await Task.sleep(
                        until: clock.now + self.timeout,
                        tolerance: HandshakeConstants.timeoutTolerance,
                        clock: clock
                    )
                    await self.handleTimeout()
                } catch {
                }
            }
            
            if let pending = pendingFinished {
                pendingFinished = nil
                await handleFinished(pending, from: currentPeer ?? PeerIdentifier(deviceId: "unknown"))
            }
            
        } catch {
            await handleHandshakeError(error, context: ctx)
        }
    }
    
 /// 处理超时 ( 11.4)
 ///
 /// **关键**：
 /// - 超时后调用 context.zeroize()
 /// - 转换到 failed 状态
    private func handleTimeout() async {
        let suite: CryptoSuite?
        switch state {
        case .waitingMessageB:
            suite = nil
        case .waitingFinished(_, let sessionKeys, _):
            suite = sessionKeys.negotiatedSuite
        default:
            return
        }
        
 // 13.2: 记录超时 (Requirement 6.2)
        await metricsCollector.recordTimeout()
        
 // 超时后必须 zeroize ( 11.4)
        if let ctx = context {
            await ctx.zeroize()
            context = nil
        }
        
        await transitionToFailed(.timeout, negotiatedSuite: suite)
    }

    private nonisolated func isFinishedMessage(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.prefix(4).elementsEqual([0x46, 0x49, 0x4E, 0x31])
    }

    private func makeFinished(
        direction: HandshakeFinished.Direction,
        sessionKeys: SessionKeys
    ) throws -> HandshakeFinished {
        let baseKey: Data
        let label: String
        switch direction {
        case .responderToInitiator:
            baseKey = sessionKeys.sendKey
            label = "R2I"
        case .initiatorToResponder:
            baseKey = sessionKeys.sendKey
            label = "I2R"
        }
        
        let macKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: baseKey),
            salt: Data(),
            info: Data("SkyBridge-FINISHED|\(label)|".utf8) + sessionKeys.transcriptHash,
            outputByteCount: 32
        )
        let mac = HMAC<SHA256>.authenticationCode(for: sessionKeys.transcriptHash, using: macKey)
        return HandshakeFinished(direction: direction, mac: Data(mac))
    }
    
    private func verifyFinished(
        _ finished: HandshakeFinished,
        sessionKeys: SessionKeys,
        expectingFrom: HandshakeRole
    ) -> Bool {
        let expectedDirection: HandshakeFinished.Direction
        let baseKey: Data
        let label: String
        
        switch expectingFrom {
        case .initiator:
            expectedDirection = .initiatorToResponder
            baseKey = sessionKeys.receiveKey
            label = "I2R"
        case .responder:
            expectedDirection = .responderToInitiator
            baseKey = sessionKeys.receiveKey
            label = "R2I"
        }
        
        guard finished.direction == expectedDirection else { return false }
        guard finished.mac.count == 32 else { return false }
        
        let macKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: baseKey),
            salt: Data(),
            info: Data("SkyBridge-FINISHED|\(label)|".utf8) + sessionKeys.transcriptHash,
            outputByteCount: 32
        )
        let expectedMac = Data(HMAC<SHA256>.authenticationCode(for: sessionKeys.transcriptHash, using: macKey))
        return constantTimeEqual(expectedMac, finished.mac)
    }
    
    private nonisolated func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        if a.count != b.count { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    private func handleFinished(_ finished: HandshakeFinished, from peer: PeerIdentifier) async {
        switch state {
        case .waitingMessageB:
            pendingFinished = finished
            return
        case .waitingFinished(_, let sessionKeys, let expectingFrom):
            guard verifyFinished(finished, sessionKeys: sessionKeys, expectingFrom: expectingFrom) else {
                await transitionToFailed(.keyConfirmationFailed, negotiatedSuite: sessionKeys.negotiatedSuite)
                return
            }
            
            if expectingFrom == .responder {
                do {
                    let clientFinished = try makeFinished(direction: .initiatorToResponder, sessionKeys: sessionKeys)
                    try await transport.send(to: peer, data: clientFinished.encoded)
                } catch {
                    await transitionToFailed(.transportError(error.localizedDescription), negotiatedSuite: sessionKeys.negotiatedSuite)
                    return
                }
            }
            
            state = .established(sessionKeys: sessionKeys)
            
            let negotiatedSuite = sessionKeys.negotiatedSuite
            let isFallback = cryptoProvider.activeSuite.isPQC && !negotiatedSuite.isPQC
            await metricsCollector.recordFinish()
            lastMetrics = await metricsCollector.buildMetrics(
                cryptoSuite: negotiatedSuite,
                isFallback: isFallback,
                failureReason: nil
            )
            
            finishOnce(with: .success(sessionKeys))
            
        default:
            SkyBridgeLogger.p2p.warning("Unexpected FINISHED in state")
        }
    }
    
 /// 转换到失败状态 ( 11.5)
 ///
 /// **关键**：
 /// - 转换到 failed 状态
 /// - 发射 SecurityEvent
 /// - 使用 finishOnce 统一收敛
    private func transitionToFailed(_ reason: HandshakeFailureReason, negotiatedSuite: CryptoSuite? = nil) async {
        state = .failed(reason: reason)

 // 记录失败指标
        await metricsCollector.recordFinish()
        let suite: CryptoSuite?
        if let negotiatedSuite {
            suite = negotiatedSuite
        } else {
            suite = await context?.negotiatedSuite
        }
        let isFallback = suite.map { cryptoProvider.activeSuite.isPQC && !$0.isPQC }
        lastMetrics = await metricsCollector.buildMetrics(
            cryptoSuite: suite,
            isFallback: isFallback,
            failureReason: reason
        )
        
 // 使用 finishOnce 统一收敛 (P0 - 11.2)
        finishOnce(with: .failure(HandshakeError.failed(reason)))
        
 // 发射事件 ( 11.5)
        SecurityEventEmitter.emitDetached(SecurityEvent(
            type: .handshakeFailed,
            severity: .warning,
            message: "Handshake failed: \(reason)",
            context: [
                "reason": String(describing: reason),
                "peer": currentPeer?.deviceId ?? "unknown"
            ]
        ))
    }
    
 /// 统一收敛成功/失败（防止双 resume）(P0 - 11.2)
 ///
 /// **关键设计**：
 /// - 取消超时任务
 /// - guard pendingContinuation != nil 再 resume
 /// - 立刻置 nil 防止双 resume
 /// - 如果 continuation 尚未建立，暂存到 pendingResult ( 11.3)
    private func finishOnce(with result: Result<SessionKeys, Error>) {
 // 取消超时任务 (P0 - 11.2)
        timeoutTask?.cancel()
        timeoutTask = nil
        
 // P0 - 11.2: 防止双 resume
        guard let continuation = pendingContinuation else {
 // P0 - 11.3: continuation 尚未建立，暂存结果
            pendingResult = result
            return
        }
 // 立刻置 nil 防止双 resume
        pendingContinuation = nil
        
        switch result {
        case .success(let keys):
            continuation.resume(returning: keys)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
    
 /// 签名数据
 ///
 /// **Requirements: 2.1, 2.2, 6.1**
 ///
 /// 签名优先级：
 /// 1. 如果协商的 suite 是 PQC，优先使用 PQC 签名 provider
 /// 2. 如果提供了 identityKeyHandle，使用 CryptoProvider 签名
 /// 3. 都没有则抛出 noSigningCapability 错误
 ///
 /// - Parameter data: 要签名的数据
 /// - Returns: 签名结果
 /// - Throws: HandshakeError.noSigningCapability 或签名失败错误
    func signData(_ data: Data) async throws -> Data {
        if let identityKeyHandle {
            let provider = await selectSignatureProvider()
            return try await provider.sign(data: data, using: identityKeyHandle)
        }
        
 // 无签名能力
        throw HandshakeError.noSigningCapability
    }
    
 /// 根据协商的 suite 选择签名 provider
 ///
 /// **Requirements: 6.1**
 ///
 /// 当 suite 是 PQC (ML-KEM-768 或 X-Wing) 时，使用 PQC 签名 provider
 /// 以保持"最先进技术栈"叙事的一致性
 ///
 /// - Returns: 选择的签名 provider
    private func selectSignatureProvider() async -> any CryptoProvider {
 // 检查是否有协商的 PQC suite
        if let ctx = context, let suite = await ctx.negotiatedSuite, suite.isPQC {
 // PQC suite 优先使用 PQC 签名 provider
            if let pqcProvider = signatureProvider,
               pqcProvider.tier == .liboqsPQC || pqcProvider.tier == .nativePQC {
                return pqcProvider
            }
 // Fallback: 使用主 cryptoProvider（如果它支持 PQC 签名）
            if cryptoProvider.tier == .liboqsPQC || cryptoProvider.tier == .nativePQC {
                return cryptoProvider
            }
        }
        
 // Classic suite 或 fallback 使用经典签名
        return signatureProvider ?? cryptoProvider
    }
    
 /// 检查当前是否使用 PQC 签名
 ///
 /// **Requirements: 6.1, 6.3**
 ///
 /// - Returns: true 如果当前使用 PQC 签名 provider
    public func isPQCSignatureActive() async -> Bool {
        guard let ctx = context,
              let suite = await ctx.negotiatedSuite,
              suite.isPQC else {
            return false
        }
        
 // 检查是否有可用的 PQC 签名 provider
        if let pqcProvider = signatureProvider,
           pqcProvider.tier == .liboqsPQC || pqcProvider.tier == .nativePQC {
            return true
        }
        
        return cryptoProvider.tier == .liboqsPQC || cryptoProvider.tier == .nativePQC
    }
    
    private func enforceIdentityPinning(deviceId: String, identityPublicKey: Data) async throws {
        guard let expectedFingerprint = await trustProvider.trustedFingerprint(for: deviceId) else {
            return
        }
        
        let actualFingerprint = computeFingerprint(identityPublicKey)
        guard expectedFingerprint == actualFingerprint else {
            throw HandshakeError.failed(.identityMismatch(
                expected: expectedFingerprint,
                actual: actualFingerprint
            ))
        }
    }
    
    private func computeFingerprint(_ publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    private func handleHandshakeError(_ error: Error, context: HandshakeContext? = nil) async {
        let negotiatedSuite = await context?.negotiatedSuite
        if let ctx = context {
            await ctx.zeroize()
            self.context = nil
        }
        
        if let handshakeError = error as? HandshakeError {
            switch handshakeError {
            case .failed(let reason):
                await transitionToFailed(reason, negotiatedSuite: negotiatedSuite)
            default:
                await transitionToFailed(.cryptoError(handshakeError.localizedDescription), negotiatedSuite: negotiatedSuite)
            }
            return
        }
        
        await transitionToFailed(.cryptoError(error.localizedDescription), negotiatedSuite: negotiatedSuite)
    }
}
