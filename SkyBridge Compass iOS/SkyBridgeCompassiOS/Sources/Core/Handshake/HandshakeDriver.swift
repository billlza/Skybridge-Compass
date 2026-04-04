//
// HandshakeDriver.swift
// SkyBridgeCompassiOS
//
// 握手驱动器 Actor - 与 macOS SkyBridgeCore 完全兼容
// 管理握手状态机，实现竞态防护和取消语义
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

/// Identity pinning provider for handshake trust checks
@available(iOS 17.0, *)
public protocol HandshakeTrustProvider: Sendable {
    /// Returns the canonical protocol identity fingerprint for `deviceId`.
    ///
    /// Implementations must use the same construction as
    /// `IdentityPublicKeys.authoritativeProtocolFingerprint()`: lowercase hex
    /// over the protocol signing algorithm tag plus the raw protocol public key
    /// bytes. Do not return a raw SHA-256 of the wire blob or bare public key.
    func trustedFingerprint(for deviceId: String) async -> String?
    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data]
    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data?
}

@available(iOS 17.0, *)
struct DefaultHandshakeTrustProvider: HandshakeTrustProvider, Sendable {
    func trustedFingerprint(for deviceId: String) async -> String? { nil }
    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        await KEMTrustStore.shared.kemPublicKeys(for: deviceId)
    }
    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? { nil }
}

// MARK: - SOA Metadata / Arbiter

@available(iOS 17.0, *)
public struct HandshakeSOAMetadata: Sendable, Equatable {
    public let initiatorPeerId: Data // 32 bytes
    public let targetPeerId: Data // 32 bytes
    public let attemptId: Data // 16 bytes

    public init(initiatorPeerId: Data, targetPeerId: Data, attemptId: Data) throws {
        guard initiatorPeerId.count == HandshakeSOAExtension.initiatorPeerIdLength else {
            throw HandshakeError.failed(.invalidMessageFormat("SOA initiatorPeerId must be 32 bytes"))
        }
        guard targetPeerId.count == HandshakeSOAExtension.targetPeerIdLength else {
            throw HandshakeError.failed(.invalidMessageFormat("SOA targetPeerId must be 32 bytes"))
        }
        guard attemptId.count == HandshakeSOAExtension.attemptIdLength else {
            throw HandshakeError.failed(.invalidMessageFormat("SOA attemptId must be 16 bytes"))
        }
        self.initiatorPeerId = initiatorPeerId
        self.targetPeerId = targetPeerId
        self.attemptId = attemptId
    }

    public var extensionRaw: Data {
        (try? HandshakeSOAExtension(
            initiatorPeerId: initiatorPeerId,
            targetPeerId: targetPeerId,
            attemptId: attemptId
        ).encodedTLV) ?? Data()
    }
}

@available(iOS 17.0, *)
public actor PeerSessionArbiter {
    public static let shared = PeerSessionArbiter()

    public enum RegisterDecision: Sendable {
        case accepted
        case alreadyConnected
        case alreadyInProgress
    }

    public enum IncomingDecision: Sendable {
        case accept
        case rejectAlreadyConnected
        case rejectBinding
        case rejectRateLimited
        case rejectLocalWinner
        case acceptAndSupersedeLocal(winnerPeerId: Data, winnerAttemptId: Data)
    }

    public struct OutgoingAttempt: Sendable {
        public let pairKey: Data
        public let initiatorPeerId: Data
        public let attemptId: Data
        public let startedAt: Date
        public let onSuperseded: @Sendable (Data, Data) async -> Void
    }

    private let pendingWindowSeconds: TimeInterval = 10
    private let supersedeRateLimit: Int = 3
    private let supersedeRateWindowSeconds: TimeInterval = 60

    private var outgoingByPair: [Data: OutgoingAttempt] = [:]
    private var establishedPairs: Set<Data> = []
    private var supersedeTimestampsByPair: [Data: [Date]] = [:]

    public func registerOutgoing(_ attempt: OutgoingAttempt) -> RegisterDecision {
        if establishedPairs.contains(attempt.pairKey) {
            return .alreadyConnected
        }
        if let existing = outgoingByPair[attempt.pairKey],
           Date().timeIntervalSince(existing.startedAt) <= pendingWindowSeconds {
            return .alreadyInProgress
        }
        outgoingByPair[attempt.pairKey] = attempt
        return .accepted
    }

    public func clearOutgoing(pairKey: Data, attemptId: Data?) {
        guard let existing = outgoingByPair[pairKey] else { return }
        if let attemptId, existing.attemptId != attemptId { return }
        outgoingByPair.removeValue(forKey: pairKey)
    }

    public func markEstablished(pairKey: Data) {
        establishedPairs.insert(pairKey)
        outgoingByPair.removeValue(forKey: pairKey)
    }

    public func clearEstablished(pairKey: Data) {
        establishedPairs.remove(pairKey)
    }

    public func evaluateIncoming(
        pairKey: Data,
        remoteInitiatorPeerId: Data,
        remoteAttemptId: Data,
        targetPeerId: Data,
        expectedRemotePeerId: Data,
        localPeerId: Data
    ) -> IncomingDecision {
        if establishedPairs.contains(pairKey) {
            return .rejectAlreadyConnected
        }
        guard targetPeerId == localPeerId, remoteInitiatorPeerId == expectedRemotePeerId else {
            return .rejectBinding
        }

        guard let local = outgoingByPair[pairKey] else {
            return .accept
        }

        if Date().timeIntervalSince(local.startedAt) > pendingWindowSeconds {
            outgoingByPair.removeValue(forKey: pairKey)
            return .accept
        }

        if !canSupersede(pairKey: pairKey) {
            return .rejectRateLimited
        }

        let remoteWins = isRemoteWinner(
            localInitiatorPeerId: local.initiatorPeerId,
            localAttemptId: local.attemptId,
            remoteInitiatorPeerId: remoteInitiatorPeerId,
            remoteAttemptId: remoteAttemptId
        )

        if remoteWins {
            recordSupersede(pairKey: pairKey)
            outgoingByPair.removeValue(forKey: pairKey)
            Task { await local.onSuperseded(remoteInitiatorPeerId, remoteAttemptId) }
            return .acceptAndSupersedeLocal(winnerPeerId: remoteInitiatorPeerId, winnerAttemptId: remoteAttemptId)
        }

        return .rejectLocalWinner
    }

    public nonisolated static func pairKey(localPeerId: Data, remotePeerId: Data) -> Data {
        if localPeerId.lexicographicallyPrecedes(remotePeerId) {
            return localPeerId + remotePeerId
        }
        return remotePeerId + localPeerId
    }

    private func isRemoteWinner(
        localInitiatorPeerId: Data,
        localAttemptId: Data,
        remoteInitiatorPeerId: Data,
        remoteAttemptId: Data
    ) -> Bool {
        if remoteInitiatorPeerId == localInitiatorPeerId {
            return remoteAttemptId.lexicographicallyPrecedes(localAttemptId)
        }
        return remoteInitiatorPeerId.lexicographicallyPrecedes(localInitiatorPeerId)
    }

    private func canSupersede(pairKey: Data) -> Bool {
        let now = Date()
        let recent = (supersedeTimestampsByPair[pairKey] ?? []).filter {
            now.timeIntervalSince($0) <= supersedeRateWindowSeconds
        }
        supersedeTimestampsByPair[pairKey] = recent
        return recent.count < supersedeRateLimit
    }

    private func recordSupersede(pairKey: Data) {
        let now = Date()
        let recent = (supersedeTimestampsByPair[pairKey] ?? []).filter {
            now.timeIntervalSince($0) <= supersedeRateWindowSeconds
        }
        supersedeTimestampsByPair[pairKey] = recent + [now]
    }
}

// MARK: - HandshakeDriver

/// 握手驱动器 Actor
///
/// **关键设计：竞态与取消语义**
/// - 双 resume 防护：使用 finishOnce() 统一收敛成功/失败
/// - MessageB 早到防护：pendingResult 暂存早到的结果
/// - 取消语义：调用方取消时 zeroize + emit event
@available(iOS 17.0, *)
public actor HandshakeDriver {
    
    // MARK: - Properties
    
    /// 当前状态
    private var state: HandshakeState = .idle
    
    /// 传输层
    private let transport: any DiscoveryTransport
    
    /// 加密 Provider
    private let cryptoProvider: any CryptoProvider
    
    /// 协议签名 Provider
    private let protocolSignatureProvider: any ProtocolSignatureProvider
    
    /// 身份密钥句柄
    private let identityKeyHandle: SigningKeyHandle?
    
    /// 身份公钥
    private let identityPublicKey: Data
    
    /// 超时时间
    private let timeout: Duration
    
    /// 握手策略
    private let policy: HandshakePolicy

    /// 本地 crypto suite 准入策略（用于避免 iOS / macOS 在 hybrid/X-Wing 上分叉）
    private let cryptoPolicy: CryptoPolicy

    /// 发起方本次尝试准备好的 suites。
    /// iOS 本地实现仍按 single-suite 发包，但这里必须以调用方准备结果为准，
    /// 不能再偷偷退回 provider.activeSuite。
    private let offeredSuites: [CryptoSuite]?
    
    /// 等待中的 continuation
    private var pendingContinuation: CheckedContinuation<SessionKeys, Error>?
    
    /// 超时任务
    private var timeoutTask: Task<Void, Never>?
    
    /// 早到的结果
    private var pendingResult: Result<SessionKeys, Error>?
    
    /// 对端标识
    private var currentPeer: PeerIdentifier?
    
    /// 信任提供方
    private let trustProvider: any HandshakeTrustProvider
    
    /// 握手上下文
    private var context: HandshakeContext?
    
    /// MessageB 处理 epoch（防重入）
    private var messageBEpoch: UInt64 = 0
    
    /// sigA 使用的签名算法
    private let sigAAlgorithm: ProtocolSigningAlgorithm

    /// 可选 SOA 元数据（initiator）
    private let soaMetadata: HandshakeSOAMetadata?

    /// 本地 SOA peer id（32B）
    private let localSOAPeerId: Data?

    /// 期望远端 SOA peer id（32B）
    private let expectedRemoteSOAPeerId: Data?

    /// 会话仲裁器
    private let sessionArbiter: PeerSessionArbiter

    /// 当前尝试 pair key
    private var soaPairKey: Data?

    /// 当前尝试 attempt id
    private var soaAttemptId: Data?
    
    // MARK: - Initialization
    
    /// 初始化握手驱动器
    public init(
        transport: any DiscoveryTransport,
        cryptoProvider: any CryptoProvider,
        protocolSignatureProvider: any ProtocolSignatureProvider,
        identityKeyHandle: SigningKeyHandle?,
        sigAAlgorithm: ProtocolSigningAlgorithm,
        identityPublicKey: Data,
        policy: HandshakePolicy = .default,
        cryptoPolicy: CryptoPolicy = .default,
        offeredSuites: [CryptoSuite]? = nil,
        timeout: Duration = HandshakeConstants.defaultTimeout,
        trustProvider: (any HandshakeTrustProvider)? = nil,
        soaMetadata: HandshakeSOAMetadata? = nil,
        localSOAPeerId: Data? = nil,
        expectedRemoteSOAPeerId: Data? = nil,
        sessionArbiter: PeerSessionArbiter = .shared
    ) {
        self.transport = transport
        self.cryptoProvider = cryptoProvider
        self.protocolSignatureProvider = protocolSignatureProvider
        self.identityKeyHandle = identityKeyHandle
        self.sigAAlgorithm = sigAAlgorithm
        self.identityPublicKey = identityPublicKey
        self.policy = policy
        self.cryptoPolicy = cryptoPolicy
        self.offeredSuites = offeredSuites
        self.timeout = timeout
        self.trustProvider = trustProvider ?? DefaultHandshakeTrustProvider()
        self.soaMetadata = soaMetadata
        self.localSOAPeerId = localSOAPeerId
        self.expectedRemoteSOAPeerId = expectedRemoteSOAPeerId
        self.sessionArbiter = sessionArbiter
    }
    
    // MARK: - Public API
    
    /// 发起握手（发起方调用）
    public func initiateHandshake(with peer: PeerIdentifier) async throws -> SessionKeys {
        guard case .idle = state else {
            throw HandshakeError.alreadyInProgress
        }
        
        currentPeer = peer

        let outboundSOA = resolveOutboundSOAMetadata(for: peer)
        if let outboundSOA {
            let pairKey = PeerSessionArbiter.pairKey(
                localPeerId: outboundSOA.initiatorPeerId,
                remotePeerId: outboundSOA.targetPeerId
            )
            let decision = await sessionArbiter.registerOutgoing(.init(
                pairKey: pairKey,
                initiatorPeerId: outboundSOA.initiatorPeerId,
                attemptId: outboundSOA.attemptId,
                startedAt: Date(),
                onSuperseded: { [weak self] winnerPeerId, winnerAttemptId in
                    await self?.handleSupersededByConcurrentAttempt(
                        winnerPeerId: winnerPeerId,
                        winnerAttemptId: winnerAttemptId
                    )
                }
            ))
            switch decision {
            case .accepted:
                soaPairKey = pairKey
                soaAttemptId = outboundSOA.attemptId
            case .alreadyConnected:
                throw HandshakeError.failed(.peerRejected("already_connected"))
            case .alreadyInProgress:
                throw HandshakeError.alreadyInProgress
            }
        } else {
            soaPairKey = nil
            soaAttemptId = nil
        }
        
        // 创建握手上下文
        let peerKEMPublicKeys = await trustProvider.trustedKEMPublicKeys(for: peer.deviceId)
        let ctx = HandshakeContext(
            role: .initiator,
            cryptoProvider: cryptoProvider,
            protocolSignatureProvider: protocolSignatureProvider,
            identityKeyHandle: identityKeyHandle,
            identityPublicKey: identityPublicKey,
            policy: policy,
            cryptoPolicy: cryptoPolicy,
            offeredSuites: offeredSuites,
            peerKEMPublicKeys: peerKEMPublicKeys
        )
        context = ctx
        
        // 构建 MessageA
        let messageA: HandshakeMessageA
        do {
            messageA = try await ctx.buildMessageA(
                extensionsRaw: outboundSOA?.extensionRaw ?? Data()
            )
        } catch {
            await ctx.zeroize()
            context = nil
            if let pairKey = soaPairKey {
                await sessionArbiter.clearOutgoing(pairKey: pairKey, attemptId: soaAttemptId)
            }
            throw error
        }
        
        // 更新状态
        state = .sendingMessageA
        
        // 发送 MessageA
        do {
            // 关键调试：确认 iOS 端正在发送“新 deterministic 编码”（UInt32 LE）
            let capBytes = (try? messageA.capabilities.deterministicEncode()) ?? Data()
            let policyBytes = messageA.policy.deterministicEncode()
            SkyBridgeLogger.shared.info("📤 Handshake MessageA: total=\(messageA.encoded.count) bytes, cap=\(capBytes.count) bytes, policy=\(policyBytes.count) bytes")
            let padded = HandshakePadding.wrapIfEnabled(messageA.encoded, label: "MessageA")
            // Handshake frames MUST NOT apply SBP2 (TrafficPadding). Keep parity with macOS core.
            try await transport.send(to: peer, data: padded)
        } catch {
            await ctx.zeroize()
            context = nil
            if let pairKey = soaPairKey {
                await sessionArbiter.clearOutgoing(pairKey: pairKey, attemptId: soaAttemptId)
            }
            await transitionToFailed(.transportError(error.localizedDescription))
            throw HandshakeError.failed(.transportError(error.localizedDescription))
        }
        
        // 等待 MessageB（带超时）
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        state = .waitingMessageB(deadline: deadline)
        
        return try await withCheckedThrowingContinuation { continuation in
            // 检查是否有早到的结果
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
            
            // 设置超时任务
            self.timeoutTask = Task {
                do {
                    try await Task.sleep(
                        until: clock.now + self.timeout,
                        tolerance: HandshakeConstants.timeoutTolerance,
                        clock: clock
                    )
                    await self.handleTimeout()
                } catch {
                    // 取消/中断时忽略
                }
            }
        }
    }
    
    /// 处理收到的消息
    public func handleMessage(_ data: Data, from peer: PeerIdentifier) async {
        // Compatibility: older iOS builds mistakenly applied SBP2 (TrafficPadding) to handshake frames.
        // Unwrap SBP2 first if present, then unwrap SBP1 (HandshakePadding).
        let untraffic = TrafficPadding.unwrapIfNeeded(data, label: "HS/rx")
        // Phase C1: unwrap padded handshake frames (SBP1).
        let unwrapped = HandshakePadding.unwrapIfNeeded(untraffic, label: "rx")

        // 检查是否是 Finished 消息
        if isFinishedMessage(unwrapped) {
            if let finished = try? HandshakeFinished.decode(from: unwrapped) {
                await handleFinished(finished, from: peer)
                return
            }
        }

        // Rekey hardening (Classic -> PQC):
        // During in-band rekey, ciphertext from the previous session can arrive interleaved with handshake frames.
        // Those bytes must NOT fail the handshake parser (e.g. versionMismatch 1 vs 135).
        let isHandshakeControl = (unwrapped.first == HandshakeConstants.protocolVersion)
        
        switch state {
        case .sendingMessageA, .waitingMessageB:
            if !isHandshakeControl { return }
            await handleMessageB(unwrapped)
        case .idle:
            // 作为响应方处理 MessageA
            await handleMessageA(unwrapped, from: peer)
        case .waitingFinished:
            if let finished = try? HandshakeFinished.decode(from: unwrapped) {
                await handleFinished(finished, from: peer)
            }
        default:
            break
        }
    }
    
    /// 取消握手
    public func cancel() async {
        guard case .idle = state else {
            // 清理上下文
            if let ctx = context {
                await ctx.zeroize()
                context = nil
            }
            
            // 取消超时任务
            timeoutTask?.cancel()
            timeoutTask = nil

            if let pairKey = soaPairKey {
                await sessionArbiter.clearOutgoing(pairKey: pairKey, attemptId: soaAttemptId)
            }
            
            finishOnce(with: .failure(HandshakeError.failed(.cancelled)))
            
            state = .failed(reason: .cancelled)
            return
        }
    }
    
    /// 获取当前状态
    public func getCurrentState() -> HandshakeState {
        return state
    }
    
    // MARK: - Private Methods
    
    /// 处理 MessageA（响应方）
    private func handleMessageA(_ data: Data, from peer: PeerIdentifier) async {
        currentPeer = peer
        
        do {
            let messageA = try HandshakeMessageA.decode(from: data)
            
            // 创建响应方上下文
            let ctx = HandshakeContext(
                role: .responder,
                cryptoProvider: cryptoProvider,
                protocolSignatureProvider: protocolSignatureProvider,
                identityKeyHandle: identityKeyHandle,
                identityPublicKey: identityPublicKey,
                policy: policy,
                cryptoPolicy: cryptoPolicy,
                offeredSuites: offeredSuites
            )
            context = ctx
            
            state = .processingMessageA
            
            // 处理 MessageA
            do {
                try await ctx.processMessageA(messageA)
                try await enforceIdentityPinning(
                    deviceId: peer.deviceId,
                    identityPublicKey: messageA.identityPublicKey
                )
            } catch {
                await handleHandshakeError(error, context: ctx)
                return
            }

            if let soa = messageA.soaExtension,
               let localPeerId = localSOAPeerId {
                // SOA binding must be driven by authenticated MessageA fields.
                // If caller did not pre-bind a remote peer id, bind to initiatorPeerId after signature verification.
                let expectedRemotePeerId = expectedRemoteSOAPeerId ?? soa.initiatorPeerId
                let pairKey = PeerSessionArbiter.pairKey(
                    localPeerId: localPeerId,
                    remotePeerId: soa.initiatorPeerId
                )
                let decision = await sessionArbiter.evaluateIncoming(
                    pairKey: pairKey,
                    remoteInitiatorPeerId: soa.initiatorPeerId,
                    remoteAttemptId: soa.attemptId,
                    targetPeerId: soa.targetPeerId,
                    expectedRemotePeerId: expectedRemotePeerId,
                    localPeerId: localPeerId
                )
                switch decision {
                case .accept:
                    soaPairKey = pairKey
                case .acceptAndSupersedeLocal:
                    soaPairKey = pairKey
                case .rejectAlreadyConnected:
                    await transitionToFailed(.peerRejected("already_connected"))
                    return
                case .rejectBinding:
                    await transitionToFailed(.invalidMessageFormat("SOA binding check failed"))
                    return
                case .rejectRateLimited:
                    await transitionToFailed(.peerRejected("soa_rate_limited"))
                    return
                case .rejectLocalWinner:
                    let winnerPeer = hexString(localPeerId)
                    let winnerAttempt = hexString(soaAttemptId ?? Data())
                    await transitionToFailed(.supersededByConcurrentAttempt(
                        winnerPeerId: winnerPeer,
                        winnerAttemptId: winnerAttempt
                    ))
                    return
                }
            }
            
            // 构建 MessageB
            state = .sendingMessageB
            let messageB: HandshakeMessageB
            let sharedSecret: SecureBytes
            do {
                let result = try await ctx.buildMessageB()
                messageB = result.message
                sharedSecret = result.sharedSecret
            } catch {
                await handleHandshakeError(error, context: ctx)
                return
            }
            
            // 发送 MessageB
            do {
                let padded = HandshakePadding.wrapIfEnabled(messageB.encoded, label: "MessageB")
                // Handshake frames MUST NOT apply SBP2 (TrafficPadding). Keep parity with macOS core.
                try await transport.send(to: peer, data: padded)
            } catch {
                await handleHandshakeError(HandshakeError.failed(.transportError(error.localizedDescription)), context: ctx)
                return
            }
            
            // 派生会话密钥
            let sessionKeys: SessionKeys
            do {
                sessionKeys = try await ctx.finalizeResponderSessionKeys(sharedSecret: sharedSecret)
            } catch {
                await handleHandshakeError(error, context: ctx)
                return
            }
            
            // 清理敏感数据
            await ctx.zeroize()
            context = nil
            
            // 等待 Finished
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            state = .waitingFinished(deadline: deadline, sessionKeys: sessionKeys, expectingFrom: .initiator)
            
            // 发送 Finished
            do {
                let finished = try makeFinished(direction: .responderToInitiator, sessionKeys: sessionKeys)
                let padded = HandshakePadding.wrapIfEnabled(finished.encoded, label: "Finished")
                // Handshake frames MUST NOT apply SBP2 (TrafficPadding). Keep parity with macOS core.
                try await transport.send(to: peer, data: padded)
            } catch {
                await transitionToFailed(.transportError(error.localizedDescription), negotiatedSuite: sessionKeys.negotiatedSuite)
                return
            }
            
            // 设置超时
            timeoutTask?.cancel()
            timeoutTask = Task {
                do {
                    try await Task.sleep(until: clock.now + self.timeout, tolerance: HandshakeConstants.timeoutTolerance, clock: clock)
                    await self.handleTimeout()
                } catch {
                    // 取消/中断时忽略
                }
            }
            
        } catch {
            await transitionToFailed(.invalidMessageFormat(error.localizedDescription))
        }
    }
    
    /// 处理 MessageB（发起方）
    private func handleMessageB(_ data: Data) async {
        guard let ctx = context else {
            await transitionToFailed(.invalidMessageFormat("No context available"))
            return
        }
        
        let epoch = messageBEpoch &+ 1
        messageBEpoch = epoch
        state = .processingMessageB(epoch: epoch)
        
        do {
            let messageB = try HandshakeMessageB.decode(from: data)
            
            // 处理 MessageB
            let sessionKeys = try await ctx.processMessageB(messageB)
            if let pinnedDeviceId = currentPeer?.deviceId {
                try await enforceIdentityPinning(
                    deviceId: pinnedDeviceId,
                    identityPublicKey: messageB.identityPublicKey
                )
            }
            
            guard case .processingMessageB(let currentEpoch) = state, currentEpoch == epoch else {
                await ctx.zeroize()
                context = nil
                return
            }
            
            await ctx.zeroize()
            context = nil
            
            // 等待 Finished
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            state = .waitingFinished(deadline: deadline, sessionKeys: sessionKeys, expectingFrom: .responder)
            
            timeoutTask?.cancel()
            timeoutTask = Task {
                do {
                    try await Task.sleep(until: clock.now + self.timeout, tolerance: HandshakeConstants.timeoutTolerance, clock: clock)
                    await self.handleTimeout()
                } catch {
                    // 取消/中断时忽略
                }
            }
            
        } catch {
            await handleHandshakeError(error, context: ctx)
        }
    }
    
    /// 处理超时
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
        
        if let ctx = context {
            await ctx.zeroize()
            context = nil
        }
        
        await transitionToFailed(.timeout, negotiatedSuite: suite)
    }

    private func enforceIdentityPinning(deviceId: String, identityPublicKey: Data) async throws {
        guard let expectedFingerprint = await trustProvider.trustedFingerprint(for: deviceId)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !expectedFingerprint.isEmpty else {
            return
        }
        let actualFingerprint = try authoritativeFingerprint(for: identityPublicKey)
        guard expectedFingerprint == actualFingerprint else {
            throw HandshakeError.failed(.identityMismatch(
                expected: expectedFingerprint,
                actual: actualFingerprint
            ))
        }
    }

    private func authoritativeFingerprint(for identityPublicKey: Data) throws -> String {
        let identityKeys = try IdentityPublicKeys.decodeWithLegacyFallback(from: identityPublicKey)
        return try identityKeys.authoritativeProtocolFingerprint()
    }
    
    private nonisolated func isFinishedMessage(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.prefix(4).elementsEqual([0x46, 0x49, 0x4E, 0x31])
    }
    
    private func makeFinished(direction: HandshakeFinished.Direction, sessionKeys: SessionKeys) throws -> HandshakeFinished {
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
        case .waitingFinished(_, let sessionKeys, let expectingFrom):
            guard verifyFinished(finished, sessionKeys: sessionKeys, expectingFrom: expectingFrom) else {
                await transitionToFailed(.keyConfirmationFailed, negotiatedSuite: sessionKeys.negotiatedSuite)
                return
            }
            
            if expectingFrom == .responder {
                do {
                    let clientFinished = try makeFinished(direction: .initiatorToResponder, sessionKeys: sessionKeys)
                    let padded = HandshakePadding.wrapIfEnabled(clientFinished.encoded, label: "Finished")
                    // Handshake frames MUST NOT apply SBP2 (TrafficPadding). Keep parity with macOS core.
                    try await transport.send(to: peer, data: padded)
                } catch {
                    await transitionToFailed(.transportError(error.localizedDescription), negotiatedSuite: sessionKeys.negotiatedSuite)
                    return
                }
            }
            
            state = .established(sessionKeys: sessionKeys)
            if let pairKey = soaPairKey {
                await sessionArbiter.markEstablished(pairKey: pairKey)
            }
            finishOnce(with: .success(sessionKeys))
            
        default:
            break
        }
    }
    
    private func transitionToFailed(_ reason: HandshakeFailureReason, negotiatedSuite: CryptoSuite? = nil) async {
        if let pairKey = soaPairKey {
            await sessionArbiter.clearOutgoing(pairKey: pairKey, attemptId: soaAttemptId)
        }
        state = .failed(reason: reason)
        finishOnce(with: .failure(HandshakeError.failed(reason)))
    }
    
    private func finishOnce(with result: Result<SessionKeys, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        
        guard let continuation = pendingContinuation else {
            pendingResult = result
            return
        }
        pendingContinuation = nil
        
        switch result {
        case .success(let keys):
            continuation.resume(returning: keys)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
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

    private func resolveOutboundSOAMetadata(for _: PeerIdentifier) -> HandshakeSOAMetadata? {
        if let soaMetadata {
            return soaMetadata
        }
        guard let localSOAPeerId,
              localSOAPeerId.count == HandshakeSOAExtension.initiatorPeerIdLength,
              let expectedRemoteSOAPeerId,
              expectedRemoteSOAPeerId.count == HandshakeSOAExtension.targetPeerIdLength else {
            return nil
        }
        let attemptId = Self.randomAttemptId()
        return try? HandshakeSOAMetadata(
            initiatorPeerId: localSOAPeerId,
            targetPeerId: expectedRemoteSOAPeerId,
            attemptId: attemptId
        )
    }

    private func handleSupersededByConcurrentAttempt(
        winnerPeerId: Data,
        winnerAttemptId: Data
    ) async {
        guard case .idle = state else {
            if let ctx = context {
                await ctx.zeroize()
                context = nil
            }
            timeoutTask?.cancel()
            timeoutTask = nil
            let reason = HandshakeFailureReason.supersededByConcurrentAttempt(
                winnerPeerId: hexString(winnerPeerId),
                winnerAttemptId: hexString(winnerAttemptId)
            )
            state = .failed(reason: reason)
            finishOnce(with: .failure(HandshakeError.failed(reason)))
            return
        }
    }

    private nonisolated static func randomAttemptId() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for idx in bytes.indices {
                bytes[idx] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        return Data(bytes)
    }

    private nonisolated func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - HandshakeContext

/// 握手上下文 Actor
@available(iOS 17.0, *)
public actor HandshakeContext {
    
    // MARK: - Properties
    
    public let role: HandshakeRole
    private let cryptoProvider: any CryptoProvider
    private let pqcProvider: (any CryptoProvider)?
    private let hybridProvider: (any CryptoProvider)?
    private let protocolSignatureProvider: any ProtocolSignatureProvider
    private let identityKeyHandle: SigningKeyHandle?
    private let identityPublicKey: Data
    private let policy: HandshakePolicy
    private let cryptoPolicy: CryptoPolicy
    private let offeredSuites: [CryptoSuite]?
    
    /// 临时密钥对
    private var ephemeralPrivateKey: SecureBytes?
    private var ephemeralPublicKey: Data?

    /// v2 发起方临时贡献私钥（X25519）
    private var v2InitiatorContributionPrivateKey: SecureBytes?

    /// v2 响应方缓存的发起方临时贡献公钥（X25519）
    private var v2PeerInitiatorContribution: Data?

    /// 对端 keyShares（按套件）
    private var peerKeyShares: [CryptoSuite: Data] = [:]
    
    /// 对端 KEM 身份公钥（仅 PQC suites 需要，initiator encapsulate 用）
    private let peerKEMPublicKeys: [CryptoSuite: Data]

    /// KEM 共享密钥（PQC suites：initiator 侧在 MessageA 时生成；responder 侧在 MessageA 时解封装）
    private var kemSharedSecrets: [CryptoSuite: SecureBytes] = [:]

    /// 发起方已发送的 supportedSuites / keyShares（用于 Anti-Downgrade 校验）
    private var sentSupportedSuites: [CryptoSuite] = []
    private var sentKeyShares: [CryptoSuite: Data] = [:]
    
    /// Transcript hash
    private var transcriptHashA: Data?
    private var transcriptHashB: Data?
    
    /// 协商的套件
    public private(set) var negotiatedSuite: CryptoSuite?
    
    /// Nonce
    private var localNonce: Data?
    private var peerNonce: Data?
    
    /// 是否已被清理
    public private(set) var isZeroized: Bool = false
    
    // MARK: - Initialization
    
    public init(
        role: HandshakeRole,
        cryptoProvider: any CryptoProvider,
        protocolSignatureProvider: any ProtocolSignatureProvider,
        identityKeyHandle: SigningKeyHandle?,
        identityPublicKey: Data,
        policy: HandshakePolicy,
        cryptoPolicy: CryptoPolicy = .default,
        offeredSuites: [CryptoSuite]? = nil,
        peerKEMPublicKeys: [CryptoSuite: Data] = [:]
    ) {
        self.role = role
        self.cryptoProvider = cryptoProvider
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *), cryptoProvider.tier == .nativePQC {
            self.pqcProvider = ApplePQCCryptoProvider()
            self.hybridProvider = AppleXWingCryptoProvider()
        } else {
            self.pqcProvider = nil
            self.hybridProvider = nil
        }
        #else
        self.pqcProvider = nil
        self.hybridProvider = nil
        #endif
        self.protocolSignatureProvider = protocolSignatureProvider
        self.identityKeyHandle = identityKeyHandle
        self.identityPublicKey = identityPublicKey
        self.policy = policy
        self.cryptoPolicy = cryptoPolicy
        self.offeredSuites = offeredSuites
        self.peerKEMPublicKeys = peerKEMPublicKeys
    }

    private func provider(for suite: CryptoSuite) -> (any CryptoProvider)? {
        if let hybridProvider, hybridProvider.supportsSuite(suite) {
            return hybridProvider
        }
        if let pqcProvider, pqcProvider.supportsSuite(suite) {
            return pqcProvider
        }
        if cryptoProvider.supportsSuite(suite) {
            return cryptoProvider
        }
        return nil
    }

    nonisolated static func suiteMeetsHandshakePolicy(
        _ suite: CryptoSuite,
        policy: HandshakePolicy
    ) -> Bool {
        if policy.requirePQC && !suite.isPQCGroup {
            return false
        }
        if policy.minimumTier != .classic && !suite.isPQCGroup {
            return false
        }
        return true
    }

    nonisolated static func suiteMeetsLocalCryptoPolicy(
        _ suite: CryptoSuite,
        cryptoPolicy: CryptoPolicy,
        forAdvertising: Bool = false
    ) -> Bool {
        if suite.isHybrid {
            guard cryptoPolicy.allowExperimentalHybrid else {
                return false
            }
            if forAdvertising && !cryptoPolicy.advertiseHybrid {
                return false
            }
        }

        switch cryptoPolicy.minimumSecurityTier {
        case .classicOnly:
            return !suite.isPQCGroup
        case .pqcPreferred:
            return true
        case .hybridPreferred:
            return true
        case .pqcOnly:
            return suite.isPQCGroup && !suite.isHybrid
        }
    }

    private func localSupportsHybrid() -> Bool {
        if let hybridProvider, hybridProvider.supportsSuite(.xwing) {
            return true
        }
        if let pqcProvider, pqcProvider.supportsSuite(.xwing) {
            return true
        }
        return cryptoProvider.supportsSuite(.xwing)
    }

    private func suiteIsLocallyNegotiable(
        _ suite: CryptoSuite,
        candidateSuites: [CryptoSuite],
        peerPolicy: HandshakePolicy? = nil,
        forAdvertising: Bool = false
    ) -> Bool {
        guard Self.suiteMeetsHandshakePolicy(suite, policy: policy),
              Self.suiteMeetsLocalCryptoPolicy(
                suite,
                cryptoPolicy: cryptoPolicy,
                forAdvertising: forAdvertising
              ) else {
            return false
        }

        if let peerPolicy,
           !Self.suiteMeetsHandshakePolicy(suite, policy: peerPolicy) {
            return false
        }

        if cryptoPolicy.requireHybridIfAvailable,
           localSupportsHybrid(),
           candidateSuites.contains(where: \.isHybrid),
           !suite.isHybrid {
            return false
        }

        return true
    }

    private func selectInitiatorSuite() throws -> CryptoSuite {
        let candidates = (offeredSuites?.isEmpty == false ? offeredSuites : nil) ?? [cryptoProvider.activeSuite]

        for suite in candidates {
            guard suite.isKnown else {
                emitUnknownSuiteRejected(wireId: suite.wireId, stage: "buildMessageA.activeSuite")
                throw HandshakeError.failed(.unknownSuite(wireId: suite.wireId))
            }
            guard provider(for: suite) != nil else { continue }
            guard suiteIsLocallyNegotiable(
                suite,
                candidateSuites: candidates,
                forAdvertising: true
            ) else { continue }
            if suite.isPQC, peerKEMPublicKey(for: suite) == nil {
                continue
            }
            return suite
        }

        if let missingPeerKEMSuite = candidates.first(where: { $0.isPQC && peerKEMPublicKey(for: $0) == nil }) {
            throw HandshakeError.failed(.missingPeerKEMPublicKey(suite: missingPeerKEMSuite.rawValue))
        }
        throw HandshakeError.failed(.suiteNegotiationFailed)
    }

    internal func selectResponderSuite(for messageA: HandshakeMessageA) throws -> CryptoSuite {
        let advertisedKeyShareSuites = Set(messageA.keyShares.map(\.suite))
        for suite in messageA.supportedSuites {
            guard provider(for: suite) != nil else { continue }
            guard suiteIsLocallyNegotiable(
                suite,
                candidateSuites: messageA.supportedSuites,
                peerPolicy: messageA.policy
            ) else { continue }
            guard advertisedKeyShareSuites.contains(suite) else { continue }
            if suite.requiresV2EphemeralContribution,
               messageA.initiatorContribution == nil {
                continue
            }
            return suite
        }

        throw HandshakeError.failed(.suiteNegotiationFailed)
    }

    private func peerKEMPublicKey(for suite: CryptoSuite) -> Data? {
        if let direct = peerKEMPublicKeys[suite] {
            return direct
        }
        let canonical = suite.canonicalKEMSuite
        if canonical.wireId != suite.wireId,
           let canonicalKey = peerKEMPublicKeys[canonical] {
            return canonicalKey
        }
        if canonical.wireId == CryptoSuite.mlkem768.wireId,
           let upgraded = peerKEMPublicKeys[.mlkem768fs] {
            return upgraded
        }
        return nil
    }
    
    // MARK: - MessageA Building (Initiator)
    
    public func buildMessageA(extensionsRaw: Data = Data()) async throws -> HandshakeMessageA {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }
        
        // 生成 nonce
        var nonceBytes = [UInt8](repeating: 0, count: HandshakeConstants.nonceSize)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
            throw HandshakeError.failed(.cryptoError("Failed to generate nonce"))
        }
        let nonce = Data(nonceBytes)
        localNonce = nonce
        
        // iOS 本地栈必须使用调用方为本次尝试准备好的 suite，而不是无条件回退到 activeSuite。
        let suite = try selectInitiatorSuite()
        let supportedSuites = [suite]
        negotiatedSuite = suite
        
        // 创建 KeyShare（与 supportedSuites 绑定）
        let keyShares: [HandshakeKeyShare]
        if suite.isPQC {
            guard let peerKEM = peerKEMPublicKey(for: suite) else {
                throw HandshakeError.failed(.missingPeerKEMPublicKey(suite: suite.rawValue))
            }
            guard let kemProvider = provider(for: suite) else {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            let encaps = try await kemProvider.kemEncapsulate(recipientPublicKey: peerKEM)
            kemSharedSecrets[suite] = encaps.sharedSecret
            keyShares = [HandshakeKeyShare(suite: suite, shareBytes: encaps.encapsulatedKey)]
        } else {
            guard let suiteProvider = provider(for: suite) else {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            let keyPair = try await suiteProvider.generateKeyPair(for: .ephemeral)
            ephemeralPrivateKey = SecureBytes(data: keyPair.privateKey.bytes)
            ephemeralPublicKey = keyPair.publicKey.bytes
            keyShares = [HandshakeKeyShare(suite: suite, shareBytes: keyPair.publicKey.bytes)]
        }

        let initiatorContribution: Data?
        if supportedSuites.contains(where: { $0.requiresV2EphemeralContribution }) {
            initiatorContribution = try generateV2InitiatorContribution()
        } else {
            v2InitiatorContributionPrivateKey?.zeroize()
            v2InitiatorContributionPrivateKey = nil
            initiatorContribution = nil
        }

        self.sentSupportedSuites = supportedSuites
        self.sentKeyShares = Dictionary(uniqueKeysWithValues: keyShares.map { ($0.suite, $0.shareBytes) })
        
        // 创建能力声明
        let capabilities = CryptoCapabilities.fromProvider(cryptoProvider)
        
        // 创建身份公钥结构
        let identityKeys = IdentityPublicKeys(
            protocolPublicKey: identityPublicKey,
            protocolAlgorithm: protocolSignatureProvider.signatureAlgorithm.wire,
            secureEnclavePublicKey: nil
        )
        
        // 构建未签名消息（以 HandshakeMessageA 的 deterministic wire bytes 为准）
        let unsigned = HandshakeMessageA(
            version: HandshakeConstants.protocolVersion,
            supportedSuites: supportedSuites,
            keyShares: keyShares,
            clientNonce: nonce,
            policy: policy,
            capabilities: capabilities,
            signature: Data(),
            identityPublicKeys: identityKeys,
            extensionsRaw: extensionsRaw,
            initiatorContribution: initiatorContribution
        )
        
        // 计算 transcriptA（与 macOS 一致：SHA256(MessageA.transcriptBytes)）
        transcriptHashA = Data(SHA256.hash(data: unsigned.transcriptBytes))
        
        // 签名（preimage 自带域分离前缀 + encodedWithoutSignature）
        let signaturePreimage = unsigned.signaturePreimage
        let signature: Data
        if let keyHandle = identityKeyHandle {
            signature = try await protocolSignatureProvider.sign(signaturePreimage, key: keyHandle)
        } else {
            throw HandshakeError.noSigningCapability
        }
        
        return HandshakeMessageA(
            version: unsigned.version,
            supportedSuites: unsigned.supportedSuites,
            keyShares: unsigned.keyShares,
            clientNonce: unsigned.clientNonce,
            policy: unsigned.policy,
            capabilities: unsigned.capabilities,
            signature: signature,
            identityPublicKeys: identityKeys,
            extensionsRaw: unsigned.extensionsRaw,
            initiatorContribution: unsigned.initiatorContribution
        )
    }
    
    // MARK: - MessageA Processing (Responder)
    
    public func processMessageA(_ messageA: HandshakeMessageA) async throws {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }
        
        // 验证版本
        guard messageA.version == HandshakeConstants.protocolVersion else {
            throw HandshakeError.failed(.versionMismatch(
                local: HandshakeConstants.protocolVersion,
                remote: messageA.version
            ))
        }
        
        // 解析身份公钥
        let identityKeys = try messageA.decodedIdentityPublicKeys()
        
        // 验证签名
        let isValid = try await protocolSignatureProvider.verify(
            messageA.signaturePreimage,
            signature: messageA.signature,
            publicKey: identityKeys.protocolPublicKey
        )
        guard isValid else {
            throw HandshakeError.failed(.signatureVerificationFailed)
        }
        
        // 保存 nonce / keyShares
        peerNonce = messageA.clientNonce
        peerKeyShares = Dictionary(uniqueKeysWithValues: messageA.keyShares.map { ($0.suite, $0.shareBytes) })
        
        // 选择套件：按发起方优先级，从 offered 列表中选择本端支持的首个套件
        if let unknown = messageA.supportedSuites.first(where: { !$0.isKnown }) {
            emitUnknownSuiteRejected(wireId: unknown.wireId, stage: "processMessageA.supportedSuites")
            throw HandshakeError.failed(.unknownSuite(wireId: unknown.wireId))
        }
        if let unknownKeyShare = messageA.keyShares.first(where: { !$0.suite.isKnown }) {
            emitUnknownSuiteRejected(wireId: unknownKeyShare.suite.wireId, stage: "processMessageA.keyShares")
            throw HandshakeError.failed(.unknownSuite(wireId: unknownKeyShare.suite.wireId))
        }
        let suite = try selectResponderSuite(for: messageA)
        
        // Anti-Downgrade: selectedSuite 必须有对应 keyShare
        guard peerKeyShares[suite] != nil else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }
        if suite.requiresV2EphemeralContribution {
            guard let contribution = messageA.initiatorContribution else {
                throw HandshakeError.failed(.invalidMessageFormat("Missing v2 initiator contribution"))
            }
            v2PeerInitiatorContribution = contribution
        } else {
            v2PeerInitiatorContribution = nil
        }
        negotiatedSuite = suite
        
        // 保存 transcript hash
        transcriptHashA = Data(SHA256.hash(data: messageA.transcriptBytes))

        // PQC suites：responder 需要使用本地长期 KEM 身份私钥解封装 initiator 的 encapsulatedKey
        if suite.isPQC {
            guard let encapsulatedKey = peerKeyShares[suite] else {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            guard let suiteProvider = provider(for: suite) else {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            let local = try await P2PKEMIdentityKeyStore.shared.getOrCreateIdentityKey(
                for: suite.canonicalKEMSuite,
                provider: suiteProvider
            )
            let sharedSecret = try await suiteProvider.kemDecapsulate(
                encapsulatedKey: encapsulatedKey,
                privateKey: local.privateKey
            )
            kemSharedSecrets[suite] = sharedSecret
        }
    }
    
    // MARK: - MessageB Building (Responder)
    
    public func buildMessageB() async throws -> (message: HandshakeMessageB, sharedSecret: SecureBytes) {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }
        guard let suite = negotiatedSuite else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }
        
        // 生成 nonce
        var nonceBytes = [UInt8](repeating: 0, count: HandshakeConstants.nonceSize)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
            throw HandshakeError.failed(.cryptoError("Failed to generate nonce"))
        }
        let nonce = Data(nonceBytes)
        localNonce = nonce
        
        let encryptedPayload: HPKESealedBox
        let sharedSecret: SecureBytes
        let responderShare: Data

        if suite.isPQC {
            guard let staticSecret = kemSharedSecrets[suite] else {
                throw HandshakeError.failed(.cryptoError("Missing KEM shared secret for \(suite.rawValue) (responder)"))
            }
            let payloadSecret: SecureBytes
            if suite.requiresV2EphemeralContribution {
                guard let initiatorContribution = v2PeerInitiatorContribution else {
                    throw HandshakeError.failed(.invalidMessageFormat("Missing v2 initiator contribution"))
                }
                let responderContribution = try deriveResponderV2Contribution(
                    initiatorContribution: initiatorContribution
                )
                responderShare = responderContribution.publicKey
                payloadSecret = try composeV2SharedSecret(
                    staticSecret: staticSecret,
                    ephemeralSecret: responderContribution.sharedSecret,
                    suite: suite
                )
                responderContribution.sharedSecret.zeroize()
                staticSecret.zeroize()
            } else {
                responderShare = Data()
                payloadSecret = staticSecret
            }
            let payloadPlaintext = try CryptoCapabilities.fromProvider(provider(for: suite) ?? cryptoProvider).deterministicEncode()
            encryptedPayload = try sealPayloadWithSharedSecret(
                payloadSecret,
                plaintext: payloadPlaintext,
                info: Data("handshake-payload".utf8),
                encapsulatedKey: Data()
            )
            sharedSecret = payloadSecret
            kemSharedSecrets.removeValue(forKey: suite)
            v2PeerInitiatorContribution = nil
        } else {
            guard let peerShare = peerKeyShares[suite] else {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            guard let suiteProvider = provider(for: suite) else {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            let payloadPlaintext = try CryptoCapabilities.fromProvider(suiteProvider).deterministicEncode()
            let sealResult = try await suiteProvider.kemDemSealWithSecret(
                plaintext: payloadPlaintext,
                recipientPublicKey: peerShare,
                info: Data("handshake-payload".utf8)
            )
            encryptedPayload = sealResult.sealedBox
            sharedSecret = sealResult.sharedSecret
            responderShare = encryptedPayload.encapsulatedKey
        }
        
        // 创建身份公钥结构
        let identityKeys = IdentityPublicKeys(
            protocolPublicKey: identityPublicKey,
            protocolAlgorithm: protocolSignatureProvider.signatureAlgorithm.wire,
            secureEnclavePublicKey: nil
        )
        
        guard let transcriptHashA else {
            throw HandshakeError.failed(.cryptoError("Missing transcript hash A"))
        }

        // 构建签名 preimage
        var signatureData = Data("SkyBridge-B".utf8)
        signatureData.append(transcriptHashA)
        HandshakeEncoding.appendUInt16LE(suite.wireId, to: &signatureData)
        HandshakeEncoding.appendUInt16LE(UInt16(responderShare.count), to: &signatureData)
        signatureData.append(responderShare)
        signatureData.append(nonce)
        let payloadHash = SHA256.hash(data: encryptedPayload.combinedWithHeader(suite: suite))
        signatureData.append(contentsOf: payloadHash)
        HandshakeEncoding.appendUInt16LE(UInt16(identityKeys.encoded.count), to: &signatureData)
        signatureData.append(identityKeys.encoded)
        
        // 签名
        let signature: Data
        if let keyHandle = identityKeyHandle {
            signature = try await protocolSignatureProvider.sign(signatureData, key: keyHandle)
        } else {
            throw HandshakeError.noSigningCapability
        }
        
        // 计算 transcript hash B
        let messageB = HandshakeMessageB(
            selectedSuite: suite,
            responderShare: responderShare,
            serverNonce: nonce,
            encryptedPayload: encryptedPayload,
            signature: signature,
            identityPublicKeys: identityKeys
        )
        transcriptHashB = Data(SHA256.hash(data: messageB.transcriptBytes))
        
        return (messageB, sharedSecret)
    }
    
    // MARK: - MessageB Processing (Initiator)
    
    public func processMessageB(_ messageB: HandshakeMessageB) async throws -> SessionKeys {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }
        
        // 验证版本
        guard messageB.version == HandshakeConstants.protocolVersion else {
            throw HandshakeError.failed(.versionMismatch(
                local: HandshakeConstants.protocolVersion,
                remote: messageB.version
            ))
        }
        
        // 解析身份公钥
        let identityKeys = try messageB.decodedIdentityPublicKeys()
        
        guard let transcriptHashA else {
            throw HandshakeError.failed(.cryptoError("Missing transcript hash A"))
        }

        // 验证签名
        let isValid = try await protocolSignatureProvider.verify(
            messageB.signaturePreimage(transcriptHashA: transcriptHashA),
            signature: messageB.signature,
            publicKey: identityKeys.protocolPublicKey
        )
        guard isValid else {
            throw HandshakeError.failed(.signatureVerificationFailed)
        }
        
        // Anti-Downgrade: 必须是我们在 MessageA 里发过的 suite
        guard messageB.selectedSuite.isKnown else {
            emitUnknownSuiteRejected(wireId: messageB.selectedSuite.wireId, stage: "processMessageB.selectedSuite")
            throw HandshakeError.failed(.unknownSuite(wireId: messageB.selectedSuite.wireId))
        }
        guard sentSupportedSuites.contains(where: { $0.wireId == messageB.selectedSuite.wireId }) else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }
        guard suiteIsLocallyNegotiable(
            messageB.selectedSuite,
            candidateSuites: sentSupportedSuites
        ) else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }
        // 并且必须有对应 keyShare（我们持有该 suite 的私钥）
        guard sentKeyShares[messageB.selectedSuite] != nil else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }
        if messageB.selectedSuite.requiresV2EphemeralContribution {
            guard messageB.responderShare.count == 32 else {
                throw HandshakeError.failed(.invalidMessageFormat("v2 responder contribution missing"))
            }
        } else {
            // responderShare 必须与 sealedBox.encapsulatedKey 一致（避免不一致输入）
            guard messageB.responderShare == messageB.encryptedPayload.encapsulatedKey else {
                throw HandshakeError.failed(.invalidMessageFormat("Responder share mismatch"))
            }
        }
        
        negotiatedSuite = messageB.selectedSuite
        peerNonce = messageB.serverNonce

        // 计算 transcriptB（与 macOS 一致：SHA256(MessageB.transcriptBytes)）
        transcriptHashB = Data(SHA256.hash(data: messageB.transcriptBytes))
        
        if messageB.selectedSuite.isPQC {
            guard let payloadSecret = kemSharedSecrets[messageB.selectedSuite] else {
                throw HandshakeError.failed(.cryptoError("Missing KEM shared secret for \(messageB.selectedSuite.rawValue) (initiator)"))
            }
            let sessionSecret: SecureBytes
            if messageB.selectedSuite.requiresV2EphemeralContribution {
                let ephemeralSecret = try deriveInitiatorV2SharedSecret(
                    responderContribution: messageB.responderShare
                )
                sessionSecret = try composeV2SharedSecret(
                    staticSecret: payloadSecret,
                    ephemeralSecret: ephemeralSecret,
                    suite: messageB.selectedSuite
                )
                ephemeralSecret.zeroize()
                payloadSecret.zeroize()
                v2InitiatorContributionPrivateKey?.zeroize()
                v2InitiatorContributionPrivateKey = nil
            } else {
                sessionSecret = payloadSecret
                v2InitiatorContributionPrivateKey?.zeroize()
                v2InitiatorContributionPrivateKey = nil
            }
            _ = try openPayloadWithSharedSecret(
                messageB.encryptedPayload,
                sharedSecret: sessionSecret,
                info: Data("handshake-payload".utf8)
            )
            kemSharedSecrets.removeValue(forKey: messageB.selectedSuite)
            defer { sessionSecret.zeroize() }
            return try deriveSessionKeys(sharedSecret: sessionSecret)
        }

        v2InitiatorContributionPrivateKey?.zeroize()
        v2InitiatorContributionPrivateKey = nil
        
        guard let privateKey = ephemeralPrivateKey else {
            throw HandshakeError.failed(.cryptoError("Missing initiator ephemeral private key"))
        }

        guard let suiteProvider = provider(for: messageB.selectedSuite) else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }

        let openResult = try await suiteProvider.kemDemOpenWithSecret(
            sealedBox: messageB.encryptedPayload,
            privateKey: privateKey,
            info: Data("handshake-payload".utf8)
        )
        // plaintext=openResult.plaintext 可用于更新 peerCapabilities（此处先忽略）
        let sharedSecret = openResult.sharedSecret
        defer { sharedSecret.zeroize() }
        
        return try deriveSessionKeys(sharedSecret: sharedSecret)
    }

    private func generateV2InitiatorContribution() throws -> Data {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        v2InitiatorContributionPrivateKey = SecureBytes(data: privateKey.rawRepresentation)
        return privateKey.publicKey.rawRepresentation
    }

    private func deriveResponderV2Contribution(
        initiatorContribution: Data
    ) throws -> (publicKey: Data, sharedSecret: SecureBytes) {
        guard initiatorContribution.count == 32 else {
            throw HandshakeError.failed(.invalidMessageFormat("Invalid v2 initiator contribution length"))
        }
        let initiatorPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: initiatorContribution)
        let responderPrivate = Curve25519.KeyAgreement.PrivateKey()
        let shared = try responderPrivate.sharedSecretFromKeyAgreement(with: initiatorPublic)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        return (publicKey: responderPrivate.publicKey.rawRepresentation, sharedSecret: SecureBytes(data: sharedData))
    }

    private func deriveInitiatorV2SharedSecret(
        responderContribution: Data
    ) throws -> SecureBytes {
        guard responderContribution.count == 32 else {
            throw HandshakeError.failed(.invalidMessageFormat("Invalid v2 responder contribution length"))
        }
        guard let privateKeyData = v2InitiatorContributionPrivateKey?.noCopyData() else {
            throw HandshakeError.failed(.cryptoError("Missing v2 initiator private contribution"))
        }
        let initiatorPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        let responderPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: responderContribution)
        let shared = try initiatorPrivate.sharedSecretFromKeyAgreement(with: responderPublic)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        return SecureBytes(data: sharedData)
    }

    private func composeV2SharedSecret(
        staticSecret: SecureBytes,
        ephemeralSecret: SecureBytes,
        suite: CryptoSuite
    ) throws -> SecureBytes {
        var ikm = Data("SkyBridge-v2-compose|".utf8)
        ikm.append(staticSecret.noCopyData())
        ikm.append(ephemeralSecret.noCopyData())
        let inputKey = SymmetricKey(data: ikm)
        let salt = transcriptHashA ?? Data("SkyBridge-v2-salt".utf8)
        var info = Data("SkyBridge-v2-static+ephemeral".utf8)
        var wireId = suite.wireId.littleEndian
        info.append(Data(bytes: &wireId, count: MemoryLayout<UInt16>.size))
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return SecureBytes(data: derived.withUnsafeBytes { Data($0) })
    }

    // MARK: - KEM Payload Helpers (PQC suites)

    private func sealPayloadWithSharedSecret(
        _ sharedSecret: SecureBytes,
        plaintext: Data,
        info: Data,
        encapsulatedKey: Data
    ) throws -> HPKESealedBox {
        guard let transcriptHashA else {
            throw HandshakeError.failed(.cryptoError("Missing transcript hash A"))
        }

        let inputKey = SymmetricKey(data: sharedSecret.noCopyData())
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: transcriptHashA,
            info: info,
            outputByteCount: 32
        )

        var nonceBytes = [UInt8](repeating: 0, count: 12)
        let status = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard status == errSecSuccess else {
            throw HandshakeError.failed(.cryptoError("Failed to generate payload nonce"))
        }
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))

        let sealed = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)
        return HPKESealedBox(
            encapsulatedKey: encapsulatedKey,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            nonce: Data(nonceBytes)
        )
    }

    private func openPayloadWithSharedSecret(
        _ sealedBox: HPKESealedBox,
        sharedSecret: SecureBytes,
        info: Data
    ) throws -> Data {
        guard let transcriptHashA else {
            throw HandshakeError.failed(.cryptoError("Missing transcript hash A"))
        }

        let inputKey = SymmetricKey(data: sharedSecret.noCopyData())
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: transcriptHashA,
            info: info,
            outputByteCount: 32
        )

        let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
        let gcmBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: sealedBox.ciphertext, tag: sealedBox.tag)
        return try AES.GCM.open(gcmBox, using: derivedKey)
    }
    
    // MARK: - Session Key Derivation
    
    public func finalizeResponderSessionKeys(sharedSecret: SecureBytes) async throws -> SessionKeys {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }
        defer { sharedSecret.zeroize() }
        return try deriveSessionKeys(sharedSecret: sharedSecret)
    }
    
    private func deriveSessionKeys(sharedSecret: SecureBytes) throws -> SessionKeys {
        guard let transcriptA = transcriptHashA,
              let transcriptB = transcriptHashB,
              let suite = negotiatedSuite,
              let localNonce = localNonce,
              let remoteNonce = peerNonce else {
            throw HandshakeError.failed(.cryptoError("Missing transcript, suite, nonces, or shared secret"))
        }
        
        // role 决定 clientNonce/serverNonce 的归属（与 macOS 保持一致）
        let clientNonce: Data
        let serverNonce: Data
        if role == .initiator {
            clientNonce = localNonce
            serverNonce = remoteNonce
        } else {
            clientNonce = remoteNonce
            serverNonce = localNonce
        }
        
        var kdfInfo = Data("SkyBridge-KDF".utf8)
        kdfInfo.append(0x01)
        var suiteWireId = suite.wireId.littleEndian
        kdfInfo.append(Data(bytes: &suiteWireId, count: MemoryLayout<UInt16>.size))
        kdfInfo.append(Data(suite.kdfCompositionLabel.utf8))
        kdfInfo.append(transcriptA)
        kdfInfo.append(transcriptB)
        kdfInfo.append(clientNonce)
        kdfInfo.append(serverNonce)
        
        var saltInput = Data("SkyBridge-KDF-Salt-v1|".utf8)
        saltInput.append(kdfInfo)
        let salt = Data(SHA256.hash(data: saltInput))
        
        let i2rInfo = kdfInfo + Data("handshake|initiator_to_responder".utf8)
        let r2iInfo = kdfInfo + Data("handshake|responder_to_initiator".utf8)
        
        let inputKey = SymmetricKey(data: sharedSecret)
        let sendKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: role == .initiator ? i2rInfo : r2iInfo,
            outputByteCount: 32
        )
        let receiveKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: role == .initiator ? r2iInfo : i2rInfo,
            outputByteCount: 32
        )
        
        let fullTranscriptHash = Data(SHA256.hash(data: transcriptA + transcriptB))
        return SessionKeys(
            sendKey: sendKey.withUnsafeBytes { Data($0) },
            receiveKey: receiveKey.withUnsafeBytes { Data($0) },
            negotiatedSuite: suite,
            transcriptHash: fullTranscriptHash
        )
    }
    
    // MARK: - Cleanup
    
    public func zeroize() async {
        ephemeralPrivateKey?.zeroize()
        ephemeralPrivateKey = nil
        ephemeralPublicKey = nil
        for (_, secret) in kemSharedSecrets {
            secret.zeroize()
        }
        kemSharedSecrets.removeAll()
        v2InitiatorContributionPrivateKey?.zeroize()
        v2InitiatorContributionPrivateKey = nil
        v2PeerInitiatorContribution = nil
        peerKeyShares.removeAll()
        sentSupportedSuites.removeAll()
        sentKeyShares.removeAll()
        transcriptHashA = nil
        transcriptHashB = nil
        localNonce = nil
        peerNonce = nil
        isZeroized = true
    }

    private nonisolated func emitUnknownSuiteRejected(wireId: UInt16, stage: String) {
        let wireHex = String(format: "0x%04X", wireId)
        SecurityEventEmitter.emitDetached(SecurityEvent(
            type: .handshakeFailed,
            severity: .warning,
            message: "suite_rejected_unknown",
            context: [
                "reason": "suite_rejected_unknown",
                "wireId": wireHex,
                "stage": stage,
                "fallbackEligible": "0"
            ]
        ))
    }
}
