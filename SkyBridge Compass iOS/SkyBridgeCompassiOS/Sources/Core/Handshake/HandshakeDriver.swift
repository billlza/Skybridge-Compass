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
        timeout: Duration = HandshakeConstants.defaultTimeout,
        trustProvider: (any HandshakeTrustProvider)? = nil
    ) {
        self.transport = transport
        self.cryptoProvider = cryptoProvider
        self.protocolSignatureProvider = protocolSignatureProvider
        self.identityKeyHandle = identityKeyHandle
        self.sigAAlgorithm = sigAAlgorithm
        self.identityPublicKey = identityPublicKey
        self.policy = policy
        self.timeout = timeout
        self.trustProvider = trustProvider ?? DefaultHandshakeTrustProvider()
    }
    
    // MARK: - Public API
    
    /// 发起握手（发起方调用）
    public func initiateHandshake(with peer: PeerIdentifier) async throws -> SessionKeys {
        guard case .idle = state else {
            throw HandshakeError.alreadyInProgress
        }
        
        currentPeer = peer
        
        // 创建握手上下文
        let peerKEMPublicKeys = await trustProvider.trustedKEMPublicKeys(for: peer.deviceId)
        let ctx = HandshakeContext(
            role: .initiator,
            cryptoProvider: cryptoProvider,
            protocolSignatureProvider: protocolSignatureProvider,
            identityKeyHandle: identityKeyHandle,
            identityPublicKey: identityPublicKey,
            policy: policy,
            peerKEMPublicKeys: peerKEMPublicKeys
        )
        context = ctx
        
        // 构建 MessageA
        let messageA: HandshakeMessageA
        do {
            messageA = try await ctx.buildMessageA()
        } catch {
            await ctx.zeroize()
            context = nil
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
            try await transport.send(to: peer, data: TrafficPadding.wrapIfEnabled(padded, label: "HS/MessageA"))
        } catch {
            await ctx.zeroize()
            context = nil
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
        // Phase C1: unwrap padded handshake frames (traffic-analysis mitigation).
        let unwrapped = HandshakePadding.unwrapIfNeeded(data, label: "rx")

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
                policy: policy
            )
            context = ctx
            
            state = .processingMessageA
            
            // 处理 MessageA
            do {
                try await ctx.processMessageA(messageA)
            } catch {
                await handleHandshakeError(error, context: ctx)
                return
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
                try await transport.send(to: peer, data: TrafficPadding.wrapIfEnabled(padded, label: "HS/MessageB"))
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
                try await transport.send(to: peer, data: TrafficPadding.wrapIfEnabled(padded, label: "HS/Finished"))
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
                    try await transport.send(to: peer, data: TrafficPadding.wrapIfEnabled(padded, label: "HS/Finished"))
                } catch {
                    await transitionToFailed(.transportError(error.localizedDescription), negotiatedSuite: sessionKeys.negotiatedSuite)
                    return
                }
            }
            
            state = .established(sessionKeys: sessionKeys)
            finishOnce(with: .success(sessionKeys))
            
        default:
            break
        }
    }
    
    private func transitionToFailed(_ reason: HandshakeFailureReason, negotiatedSuite: CryptoSuite? = nil) async {
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
}

// MARK: - HandshakeContext

/// 握手上下文 Actor
@available(iOS 17.0, *)
public actor HandshakeContext {
    
    // MARK: - Properties
    
    public let role: HandshakeRole
    private let cryptoProvider: any CryptoProvider
    private let protocolSignatureProvider: any ProtocolSignatureProvider
    private let identityKeyHandle: SigningKeyHandle?
    private let identityPublicKey: Data
    private let policy: HandshakePolicy
    
    /// 临时密钥对
    private var ephemeralPrivateKey: SecureBytes?
    private var ephemeralPublicKey: Data?

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
        peerKEMPublicKeys: [CryptoSuite: Data] = [:]
    ) {
        self.role = role
        self.cryptoProvider = cryptoProvider
        self.protocolSignatureProvider = protocolSignatureProvider
        self.identityKeyHandle = identityKeyHandle
        self.identityPublicKey = identityPublicKey
        self.policy = policy
        self.peerKEMPublicKeys = peerKEMPublicKeys
    }
    
    // MARK: - MessageA Building (Initiator)
    
    public func buildMessageA() async throws -> HandshakeMessageA {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }
        
        // 生成 nonce
        var nonceBytes = [UInt8](repeating: 0, count: HandshakeConstants.nonceSize)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
            throw HandshakeError.failed(.cryptoError("Failed to generate nonce"))
        }
        localNonce = Data(nonceBytes)
        
        // 确定支持的套件（v1: 先按当前 provider 的 activeSuite；TwoAttemptHandshakeManager 会控制优先级）
        let suite = cryptoProvider.activeSuite
        let supportedSuites = [suite]
        negotiatedSuite = suite
        
        // 创建 KeyShare（与 supportedSuites 绑定）
        let keyShares: [HandshakeKeyShare]
        if suite.isPQC {
            guard let peerKEM = peerKEMPublicKeys[suite] else {
                throw HandshakeError.failed(.missingPeerKEMPublicKey(suite: suite.rawValue))
            }
            let encaps = try await cryptoProvider.kemEncapsulate(recipientPublicKey: peerKEM)
            kemSharedSecrets[suite] = encaps.sharedSecret
            keyShares = [HandshakeKeyShare(suite: suite, shareBytes: encaps.encapsulatedKey)]
        } else {
            let keyPair = try await cryptoProvider.generateKeyPair(for: .ephemeral)
            ephemeralPrivateKey = SecureBytes(data: keyPair.privateKey.bytes)
            ephemeralPublicKey = keyPair.publicKey.bytes
            keyShares = [HandshakeKeyShare(suite: suite, shareBytes: keyPair.publicKey.bytes)]
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
            clientNonce: localNonce!,
            policy: policy,
            capabilities: capabilities,
            signature: Data(),
            identityPublicKeys: identityKeys
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
            identityPublicKeys: identityKeys
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
        
        // 选择套件（简化：选择第一个共同支持的）
        var selectedSuite: CryptoSuite?
        for suite in messageA.supportedSuites {
            if cryptoProvider.supportsSuite(suite) {
                selectedSuite = suite
                break
            }
        }
        guard let suite = selectedSuite else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }
        
        // Anti-Downgrade: selectedSuite 必须有对应 keyShare
        guard peerKeyShares[suite] != nil else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }
        negotiatedSuite = suite
        
        // 保存 transcript hash
        transcriptHashA = Data(SHA256.hash(data: messageA.transcriptBytes))

        // PQC suites：responder 需要使用本地长期 KEM 身份私钥解封装 initiator 的 encapsulatedKey
        if suite.isPQC {
            guard let encapsulatedKey = peerKeyShares[suite] else {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            let local = try await P2PKEMIdentityKeyStore.shared.getOrCreateIdentityKey(for: suite, provider: cryptoProvider)
            let sharedSecret = try await cryptoProvider.kemDecapsulate(
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
        localNonce = Data(nonceBytes)
        
        let encryptedPayload: HPKESealedBox
        let sharedSecret: SecureBytes

        if suite.isPQC {
            guard let payloadSecret = kemSharedSecrets[suite] else {
                throw HandshakeError.failed(.cryptoError("Missing KEM shared secret for \(suite.rawValue) (responder)"))
            }
            let payloadPlaintext = try CryptoCapabilities.fromProvider(cryptoProvider).deterministicEncode()
            encryptedPayload = try sealPayloadWithSharedSecret(
                payloadSecret,
                plaintext: payloadPlaintext,
                info: Data("handshake-payload".utf8),
                encapsulatedKey: Data()
            )
            sharedSecret = payloadSecret
            kemSharedSecrets.removeValue(forKey: suite)
        } else {
            guard let peerShare = peerKeyShares[suite] else {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
            let payloadPlaintext = try CryptoCapabilities.fromProvider(cryptoProvider).deterministicEncode()
            let sealResult = try await cryptoProvider.kemDemSealWithSecret(
                plaintext: payloadPlaintext,
                recipientPublicKey: peerShare,
                info: Data("handshake-payload".utf8)
            )
            encryptedPayload = sealResult.sealedBox
            sharedSecret = sealResult.sharedSecret
        }
        
        // 创建身份公钥结构
        let identityKeys = IdentityPublicKeys(
            protocolPublicKey: identityPublicKey,
            protocolAlgorithm: protocolSignatureProvider.signatureAlgorithm.wire,
            secureEnclavePublicKey: nil
        )
        
        // 构建签名 preimage
        var signatureData = Data("SkyBridge-B".utf8)
        signatureData.append(transcriptHashA ?? Data())
        HandshakeEncoding.appendUInt16LE(suite.wireId, to: &signatureData)
        let responderShare = encryptedPayload.encapsulatedKey
        HandshakeEncoding.appendUInt16LE(UInt16(responderShare.count), to: &signatureData)
        signatureData.append(responderShare)
        signatureData.append(localNonce!)
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
            serverNonce: localNonce!,
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
        
        // 验证签名
        let isValid = try await protocolSignatureProvider.verify(
            messageB.signaturePreimage(transcriptHashA: transcriptHashA ?? Data()),
            signature: messageB.signature,
            publicKey: identityKeys.protocolPublicKey
        )
        guard isValid else {
            throw HandshakeError.failed(.signatureVerificationFailed)
        }
        
        // Anti-Downgrade: 必须是我们在 MessageA 里发过的 suite
        guard sentSupportedSuites.contains(where: { $0.wireId == messageB.selectedSuite.wireId }) else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }
        // 并且必须有对应 keyShare（我们持有该 suite 的私钥）
        guard sentKeyShares[messageB.selectedSuite] != nil else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }
        
        negotiatedSuite = messageB.selectedSuite
        peerNonce = messageB.serverNonce

        // 计算 transcriptB（与 macOS 一致：SHA256(MessageB.transcriptBytes)）
        transcriptHashB = Data(SHA256.hash(data: messageB.transcriptBytes))
        
        if messageB.selectedSuite.isPQC {
            guard let payloadSecret = kemSharedSecrets[messageB.selectedSuite] else {
                throw HandshakeError.failed(.cryptoError("Missing KEM shared secret for \(messageB.selectedSuite.rawValue) (initiator)"))
            }
            _ = try openPayloadWithSharedSecret(
                messageB.encryptedPayload,
                sharedSecret: payloadSecret,
                info: Data("handshake-payload".utf8)
            )
            kemSharedSecrets.removeValue(forKey: messageB.selectedSuite)
            return try deriveSessionKeys(sharedSecret: payloadSecret)
        }
        
        // responderShare 必须与 sealedBox.encapsulatedKey 一致（避免不一致输入）
        guard messageB.responderShare == messageB.encryptedPayload.encapsulatedKey else {
            throw HandshakeError.failed(.invalidMessageFormat("Responder share mismatch"))
        }
        
        guard let privateKey = ephemeralPrivateKey else {
            throw HandshakeError.failed(.cryptoError("Missing initiator ephemeral private key"))
        }
        
        let openResult = try await cryptoProvider.kemDemOpenWithSecret(
            sealedBox: messageB.encryptedPayload,
            privateKey: privateKey,
            info: Data("handshake-payload".utf8)
        )
        // plaintext=openResult.plaintext 可用于更新 peerCapabilities（此处先忽略）
        let sharedSecret = openResult.sharedSecret
        defer { sharedSecret.zeroize() }
        
        return try deriveSessionKeys(sharedSecret: sharedSecret)
    }

    // MARK: - KEM Payload Helpers (PQC suites)

    private func sealPayloadWithSharedSecret(
        _ sharedSecret: SecureBytes,
        plaintext: Data,
        info: Data,
        encapsulatedKey: Data
    ) throws -> HPKESealedBox {
        let inputKey = SymmetricKey(data: sharedSecret.noCopyData())
        let salt = transcriptHashA ?? Data()
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
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
        let inputKey = SymmetricKey(data: sharedSecret.noCopyData())
        let salt = transcriptHashA ?? Data()
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
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
        var suiteWireId = suite.wireId.littleEndian
        kdfInfo.append(Data(bytes: &suiteWireId, count: MemoryLayout<UInt16>.size))
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
        peerKeyShares.removeAll()
        sentSupportedSuites.removeAll()
        sentKeyShares.removeAll()
        transcriptHashA = nil
        transcriptHashB = nil
        localNonce = nil
        peerNonce = nil
        isZeroized = true
    }
}

