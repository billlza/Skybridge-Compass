//
// HandshakeContext.swift
// SkyBridgeCore
//
// Tech Debt Cleanup - 10A: HandshakeContext 实现
// Requirements: 4.3, 4.4
//
// 握手上下文 Actor：
// - 管理握手过程中的敏感数据（临时私钥、transcript hash）
// - 提供 actor 隔离保护
// - 实现 zeroize() 方法清理敏感数据
//

import Foundation
import CryptoKit

// MARK: - HandshakeContext

/// 握手上下文 Actor
///
/// **关键设计**：
/// - 使用 actor 隔离保护敏感数据
/// - 临时私钥使用 SecureBytes 存储
/// - zeroize() 方法确保敏感数据被清理
/// - isZeroized 标志防止重复使用已清理的上下文
@available(macOS 14.0, iOS 17.0, *)
public actor HandshakeContext {

 // MARK: - Properties

 /// 握手角色
    public let role: HandshakeRole

 /// 使用的加密 Provider
    private let cryptoProvider: any CryptoProvider

 /// Hybrid Provider（例如 X-Wing），可选
    private let hybridProvider: (any CryptoProvider)?

 /// 签名 Provider（用于身份签名，旧版本兼容）
    private let signatureProvider: any CryptoProvider

 /// 协议签名 Provider（ 5.3: sigA/sigB 专用）
 /// **Requirements: 7.2, 7.3**
    private let protocolSignatureProvider: (any ProtocolSignatureProvider)?

 /// SE PoP 签名 Provider（ 5.3: seSigA/seSigB 专用）
 /// **Requirements: 7.2, 7.3**
    private let sePoPSignatureProvider: (any SePoPSignatureProvider)?

 /// 经典兜底 Provider（用于 classic fallback）
    private let classicProvider: any CryptoProvider

    private let cryptoPolicy: CryptoPolicy

 /// 对端 KEM 身份公钥（按套件）
    private let peerKEMPublicKeys: [CryptoSuite: Data]

 /// 临时私钥（按套件存储）
    private var keyExchangePrivateKeys: [CryptoSuite: SecureBytes] = [:]

 /// 临时公钥（按套件存储）
    public private(set) var keyExchangePublicKeys: [CryptoSuite: Data] = [:]

 /// MessageA transcript hash（用于 MessageB 绑定）
    private var transcriptHashA: SecureBytes?

 /// MessageB transcript hash（用于会话密钥派生）
    private var transcriptHashB: SecureBytes?

 /// 随机 nonce
    private var nonce: SecureBytes?

 /// 握手共享密钥（用于会话密钥派生）

 /// 对端 nonce（用于 replay 检测）
    private var peerNonce: SecureBytes?

 /// 是否已被清理
    public private(set) var isZeroized: Bool = false

 /// 对端 KeyShare（收到后设置）
    public private(set) var peerKeyShares: [CryptoSuite: Data] = [:]

 /// KEM 共享密钥（按套件保存）
    private var kemSharedSecrets: [CryptoSuite: SecureBytes] = [:]

 /// 协商的套件
    public private(set) var negotiatedSuite: CryptoSuite?

 /// 本地能力
    public let localCapabilities: CryptoCapabilities

 /// 已发送的 supportedSuites（发起方用于校验）
    private var sentSupportedSuites: [CryptoSuite] = []

 /// 已发送的 keyShares（发起方用于校验）
    private var sentKeyShares: [CryptoSuite: Data] = [:]

 // MARK: - Initialization

    private init(
        role: HandshakeRole,
        cryptoProvider: any CryptoProvider,
        hybridProvider: (any CryptoProvider)?,
        signatureProvider: any CryptoProvider,
        protocolSignatureProvider: (any ProtocolSignatureProvider)?,
        sePoPSignatureProvider: (any SePoPSignatureProvider)?,
        classicProvider: any CryptoProvider,
        cryptoPolicy: CryptoPolicy,
        localCapabilities: CryptoCapabilities,
        peerKEMPublicKeys: [CryptoSuite: Data]
    ) {
        self.role = role
        self.cryptoProvider = cryptoProvider
        self.hybridProvider = hybridProvider
        self.signatureProvider = signatureProvider
        self.protocolSignatureProvider = protocolSignatureProvider
        self.sePoPSignatureProvider = sePoPSignatureProvider
        self.classicProvider = classicProvider
        self.cryptoPolicy = cryptoPolicy
        self.localCapabilities = localCapabilities
        self.peerKEMPublicKeys = peerKEMPublicKeys
    }

 // MARK: - Factory Method

 /// 创建握手上下文
 /// - Parameters:
 /// - role: 握手角色
 /// - cryptoProvider: 加密 Provider
 /// - signatureProvider: 签名 Provider（旧版本兼容）
 /// - protocolSignatureProvider: 协议签名 Provider（ 5.3: sigA/sigB 专用）
 /// - sePoPSignatureProvider: SE PoP 签名 Provider（ 5.3: seSigA/seSigB 专用）
 /// - cryptoPolicy: 加密策略
 /// - peerKEMPublicKeys: 对端 KEM 公钥
 /// - Returns: 初始化的握手上下文
 ///
 /// **Requirements: 7.2, 7.3**
    public static func create(
        role: HandshakeRole,
        cryptoProvider: any CryptoProvider,
        signatureProvider: (any CryptoProvider)? = nil,
        protocolSignatureProvider: (any ProtocolSignatureProvider)? = nil,
        sePoPSignatureProvider: (any SePoPSignatureProvider)? = nil,
        cryptoPolicy: CryptoPolicy = .default,
        peerKEMPublicKeys: [CryptoSuite: Data] = [:]
    ) async throws -> HandshakeContext {
 // 获取本地能力
 // 注：CryptoProviderSelector.shared 是 static let，无需 await
        let selector = CryptoProviderSelector.shared
        let localCapabilities = await selector.getLocalCapabilities()
        let signatureProvider = signatureProvider ?? ClassicProvider()
        let classicProvider = ClassicProvider()

        let hybridProvider: (any CryptoProvider)?
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            if cryptoProvider.tier == .nativePQC {
                hybridProvider = AppleXWingCryptoProvider()
            } else {
                hybridProvider = nil
            }
        } else {
            hybridProvider = nil
        }
        #else
        hybridProvider = nil
        #endif

        let context = HandshakeContext(
            role: role,
            cryptoProvider: cryptoProvider,
            hybridProvider: hybridProvider,
            signatureProvider: signatureProvider,
            protocolSignatureProvider: protocolSignatureProvider,
            sePoPSignatureProvider: sePoPSignatureProvider,
            classicProvider: classicProvider,
            cryptoPolicy: cryptoPolicy,
            localCapabilities: localCapabilities,
            peerKEMPublicKeys: peerKEMPublicKeys
        )

 // 生成 nonce
        try await context.generateNonce()

        return context
    }

 // MARK: - Key Generation

 /// 生成临时密钥对
    private func generateEphemeralKeyPair(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        if keyExchangePrivateKeys[suite] != nil {
            return
        }

        let keyPair = try await provider.generateKeyPair(for: .keyExchange)

 // 使用 SecureBytes 存储私钥
        keyExchangePrivateKeys[suite] = SecureBytes(data: keyPair.privateKey.bytes)
        keyExchangePublicKeys[suite] = keyPair.publicKey.bytes
    }

 /// 生成随机 nonce
    private func generateNonce() throws {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        var nonceBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard status == errSecSuccess else {
            throw HandshakeError.failed(.cryptoError("Failed to generate nonce"))
        }

        nonce = SecureBytes(data: Data(nonceBytes))
    }

 // MARK: - Message Building

 /// 构建 MessageA（发起方调用）
 /// - Parameter identityKeyHandle: 身份密钥句柄（用于签名）
 /// - Parameter identityPublicKey: 身份公钥
 /// - Parameter policy: 握手策略（用于降级攻击防护）
 /// - Returns: HandshakeMessageA
 ///
 /// 14.2: 签名必须覆盖整个 transcript（suite + 双方 ephemeral + nonce）
 /// Requirement 14.2: 签名必须覆盖完整 transcript 包括 suite negotiation
    public func buildMessageA(
        identityKeyHandle: SigningKeyHandle?,
        identityPublicKey: Data,
        policy: HandshakePolicy = .default,
        secureEnclaveKeyHandle: SigningKeyHandle? = nil,
        offeredSuites: [CryptoSuite]? = nil
    ) async throws -> HandshakeMessageA {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        guard role == .initiator else {
            throw HandshakeError.invalidState("Only initiator can build MessageA")
        }

        guard let nonceData = nonce?.data else {
            throw HandshakeError.invalidState("Nonce not generated")
        }

        let supportedSuites: [CryptoSuite]
        if let offeredSuites {
            supportedSuites = try resolveSupportedSuites(offeredSuites: offeredSuites, policy: policy)
        } else {
            supportedSuites = try resolveSupportedSuites(policy: policy)
        }
        var keyShares: [HandshakeKeyShare] = []
        var sentKeyShares: [CryptoSuite: Data] = [:]

        for suite in supportedSuites {
            guard let provider = providerForSuite(suite) else {
                continue
            }
            if suite.isPQC {
                guard let peerKEMPublicKey = peerKEMPublicKeys[suite] else {
                    continue
                }
                let encapsResult = try await provider.kemEncapsulate(recipientPublicKey: peerKEMPublicKey)
                keyShares.append(HandshakeKeyShare(suite: suite, shareBytes: encapsResult.encapsulatedKey))
                sentKeyShares[suite] = encapsResult.encapsulatedKey
                kemSharedSecrets[suite] = encapsResult.sharedSecret
            } else {
                try await generateEphemeralKeyPair(for: suite, provider: provider)
                guard let share = keyExchangePublicKeys[suite] else {
                    throw HandshakeError.invalidState("Missing keyShare for suite \(suite.rawValue)")
                }
                keyShares.append(HandshakeKeyShare(suite: suite, shareBytes: share))
                sentKeyShares[suite] = share
            }
        }

        guard !keyShares.isEmpty else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }

        let messageA = HandshakeMessageA(
            version: HandshakeConstants.protocolVersion,
            supportedSuites: supportedSuites,
            keyShares: keyShares,
            clientNonce: nonceData,
            policy: policy,
            capabilities: localCapabilities,
            signature: Data(),
            identityPublicKey: identityPublicKey
        )

 // 14.2: 构建待签名数据（包含域分离前缀）
        let dataToSign = messageA.signaturePreimage

 // 计算 transcriptA
        let transcriptA = SHA256.hash(data: messageA.transcriptBytes)
        transcriptHashA = SecureBytes(data: Data(transcriptA))

 // 签名
        let signature = try await signHandshakeData(dataToSign, identityKeyHandle: identityKeyHandle)
        let seSigPreimage = messageA.secureEnclaveSignaturePreimage
        var seSignature: Data?
        if policy.requireSecureEnclavePoP, secureEnclaveKeyHandle == nil {
            throw HandshakeError.failed(.secureEnclavePoPRequired)
        }
        do {
            seSignature = try await signSecureEnclaveData(seSigPreimage, secureEnclaveKeyHandle: secureEnclaveKeyHandle)
            if policy.requireSecureEnclavePoP, seSignature == nil {
                throw HandshakeError.failed(.secureEnclavePoPRequired)
            }
        } catch {
            if policy.requireSecureEnclavePoP {
                throw HandshakeError.failed(.secureEnclaveSignatureInvalid)
            }
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .secureEnclaveSignatureInvalid,
                severity: .warning,
                message: "Secure Enclave signing failed (MessageA)",
                context: [
                    "reason": "se_sign_failed_a",
                    "error": error.localizedDescription
                ]
            ))
            seSignature = nil
        }

        self.sentSupportedSuites = supportedSuites
        self.sentKeyShares = sentKeyShares

        return HandshakeMessageA(
            version: messageA.version,
            supportedSuites: messageA.supportedSuites,
            keyShares: messageA.keyShares,
            clientNonce: messageA.clientNonce,
            policy: messageA.policy,
            capabilities: messageA.capabilities,
            signature: signature,
            identityPublicKey: messageA.identityPublicKey,
            secureEnclaveSignature: seSignature
        )
    }

 /// 处理 MessageA（响应方调用）
 /// - Parameter messageA: 收到的 MessageA
 /// - Parameter policy: 本地握手策略（用于降级攻击防护）
 /// - Returns: 验证是否成功
 ///
 /// 14.2: 验证时检查 transcript 一致性
 /// Requirement 14.2: 签名必须覆盖完整 transcript 包括 suite negotiation
    public func processMessageA(
        _ messageA: HandshakeMessageA,
        policy: HandshakePolicy = .default,
        postSignatureValidation: (@Sendable (Data) async throws -> Void)? = nil,
        secureEnclavePublicKey: Data? = nil
    ) async throws {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        guard role == .responder else {
            throw HandshakeError.invalidState("Only responder can process MessageA")
        }

        let identityKeys: IdentityPublicKeys
        do {
            identityKeys = try messageA.decodedIdentityPublicKeys()
        } catch {
            throw HandshakeError.failed(.invalidMessageFormat("IdentityPublicKeys decode failed: \(error.localizedDescription)"))
        }

 // 验证签名
        let isValid = try await verifyHandshakeData(
            messageA.signaturePreimage,
            signature: messageA.signature,
            publicKey: identityKeys.protocolPublicKey
        )

        guard isValid else {
            throw HandshakeError.failed(.signatureVerificationFailed)
        }

        if let postSignatureValidation {
            try await postSignatureValidation(identityKeys.protocolPublicKey)
        }

        if policy.requireSecureEnclavePoP, messageA.secureEnclaveSignature == nil {
            throw HandshakeError.failed(.secureEnclavePoPRequired)
        }

        if policy.requireSecureEnclavePoP, secureEnclavePublicKey == nil {
            throw HandshakeError.failed(.secureEnclavePoPRequired)
        }

        if let seSig = messageA.secureEnclaveSignature {
            let sePreimage = messageA.secureEnclaveSignaturePreimage
            if let sePublicKey = secureEnclavePublicKey {
                let seValid = (try? await classicProvider.verify(
                    data: sePreimage,
                    signature: seSig,
                    publicKey: sePublicKey
                )) ?? false

                if !seValid {
                    if policy.requireSecureEnclavePoP {
                        throw HandshakeError.failed(.secureEnclaveSignatureInvalid)
                    }
                    SecurityEventEmitter.emitDetached(SecurityEvent(
                        type: .secureEnclaveSignatureInvalid,
                        severity: .warning,
                        message: "Secure Enclave signature verification failed (MessageA)",
                        context: [
                            "reason": "invalid_se_sig_a",
                            "deviceId": "unknown"
                        ]
                    ))
                }
            } else {
                SecurityEventEmitter.emitDetached(SecurityEvent(
                    type: .secureEnclaveSignatureInvalid,
                    severity: .info,
                    message: "Secure Enclave signature provided but no SE public key available (MessageA)",
                    context: [
                        "reason": "missing_se_public_key_a"
                    ]
                ))
            }
        }

 // 保存对端 KeyShare
        peerKeyShares = Dictionary(uniqueKeysWithValues: messageA.keyShares.map { ($0.suite, $0.shareBytes) })
        peerNonce = SecureBytes(data: messageA.clientNonce)

 // 保存对端能力（用于降级攻击检测）
        peerCapabilities = messageA.capabilities

        let selectedSuite = try selectSuite(
            from: messageA,
            localPolicy: policy
        )
        negotiatedSuite = selectedSuite

        if selectedSuite.isPQC {
            guard let provider = providerForSuite(selectedSuite),
                  let encapsulatedKey = peerKeyShares[selectedSuite] else {
                throw HandshakeError.invalidState("Missing KEM key share for \(selectedSuite.rawValue)")
            }

            let keyManager = DeviceIdentityKeyManager.shared
            let localKEM = try await keyManager.getOrCreateKEMIdentityKey(
                for: selectedSuite,
                provider: provider
            )
            let sharedSecret = try await provider.kemDecapsulate(
                encapsulatedKey: encapsulatedKey,
                privateKey: localKEM.privateKey
            )
            kemSharedSecrets[selectedSuite] = sharedSecret
        }

        try await ensureNotReplay(for: selectedSuite, replayTag: .messageA)

 // 更新 transcriptA
        let transcriptA = SHA256.hash(data: messageA.transcriptBytes)
        transcriptHashA = SecureBytes(data: Data(transcriptA))
    }

 /// 对端能力（收到后设置）
    public private(set) var peerCapabilities: CryptoCapabilities?

 /// 构建 MessageB（响应方调用）
 /// - Parameter identityKeyHandle: 身份密钥句柄（用于签名）
 /// - Parameter identityPublicKey: 身份公钥
 /// - Parameter policy: 握手策略（用于降级攻击防护）
 /// - Returns: HandshakeMessageB
 ///
 /// 14.2: 签名必须覆盖整个 transcript（suite + 双方 ephemeral + nonce）
 /// Requirement 14.2: 签名必须覆盖完整 transcript 包括 suite negotiation
    public func buildMessageB(
        identityKeyHandle: SigningKeyHandle?,
        identityPublicKey: Data,
        policy: HandshakePolicy = .default,
        secureEnclaveKeyHandle: SigningKeyHandle? = nil
    ) async throws -> (message: HandshakeMessageB, sharedSecret: SecureBytes) {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        guard role == .responder else {
            throw HandshakeError.invalidState("Only responder can build MessageB")
        }

        guard let nonceData = nonce?.data,
              let suite = negotiatedSuite,
              let peerShare = peerKeyShares[suite],
              let provider = providerForSuite(suite) else {
            throw HandshakeError.invalidState("Missing required data for MessageB")
        }

        guard let transcriptHashA = transcriptHashA?.noCopyData() else {
            throw HandshakeError.invalidState("Missing transcript hash for MessageA")
        }

        let responderShare: Data
        let sealedBox: HPKESealedBox
        let sharedSecretForSession: SecureBytes

        if suite.isPQC {
            guard let sharedSecret = kemSharedSecrets[suite] else {
                throw HandshakeError.invalidState("Missing KEM shared secret for \(suite.rawValue)")
            }

            let payloadData = (try? localCapabilities.deterministicEncode()) ?? Data()
            sealedBox = try sealPayloadWithSharedSecret(
                sharedSecret,
                plaintext: payloadData,
                info: Data("handshake-payload".utf8),
                encapsulatedKey: Data()
            )
            responderShare = Data()
            sharedSecretForSession = sharedSecret
            kemSharedSecrets.removeValue(forKey: suite)
        } else {
            let payloadData = (try? localCapabilities.deterministicEncode()) ?? Data()
            let sealResult = try await provider.kemDemSealWithSecret(
                plaintext: payloadData,
                recipientPublicKey: peerShare,
                info: Data("handshake-payload".utf8)
            )
            sealedBox = sealResult.sealedBox
            sharedSecretForSession = sealResult.sharedSecret
            responderShare = sealedBox.encapsulatedKey
        }

        let messageB = HandshakeMessageB(
            version: HandshakeConstants.protocolVersion,
            selectedSuite: suite,
            responderShare: responderShare,
            serverNonce: nonceData,
            encryptedPayload: sealedBox,
            signature: Data(),
            identityPublicKey: identityPublicKey
        )

 // 14.2: 构建待签名数据（包含 transcriptA）
        let dataToSign = messageB.signaturePreimage(transcriptHashA: transcriptHashA)

 // 更新 transcriptB
        let transcriptB = SHA256.hash(data: messageB.transcriptBytes)
        transcriptHashB = SecureBytes(data: Data(transcriptB))

 // 签名
        let signature = try await signHandshakeData(dataToSign, identityKeyHandle: identityKeyHandle)
        let seSigPreimage = messageB.secureEnclaveSignaturePreimage(transcriptHashA: transcriptHashA)
        var seSignature: Data?
        if policy.requireSecureEnclavePoP, secureEnclaveKeyHandle == nil {
            throw HandshakeError.failed(.secureEnclavePoPRequired)
        }
        do {
            seSignature = try await signSecureEnclaveData(seSigPreimage, secureEnclaveKeyHandle: secureEnclaveKeyHandle)
            if policy.requireSecureEnclavePoP, seSignature == nil {
                throw HandshakeError.failed(.secureEnclavePoPRequired)
            }
        } catch {
            if policy.requireSecureEnclavePoP {
                throw HandshakeError.failed(.secureEnclaveSignatureInvalid)
            }
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .secureEnclaveSignatureInvalid,
                severity: .warning,
                message: "Secure Enclave signing failed (MessageB)",
                context: [
                    "reason": "se_sign_failed_b",
                    "error": error.localizedDescription
                ]
            ))
            seSignature = nil
        }

        let signedMessage = HandshakeMessageB(
            version: messageB.version,
            selectedSuite: messageB.selectedSuite,
            responderShare: messageB.responderShare,
            serverNonce: messageB.serverNonce,
            encryptedPayload: messageB.encryptedPayload,
            signature: signature,
            identityPublicKey: messageB.identityPublicKey,
            secureEnclaveSignature: seSignature
        )
        return (message: signedMessage, sharedSecret: sharedSecretForSession)
    }

 /// 处理 MessageB（发起方调用）
 /// - Parameter messageB: 收到的 MessageB
 /// - Parameter policy: 本地握手策略（用于降级攻击防护）
 /// - Returns: 会话密钥
 ///
 /// 14.2: 验证时检查 transcript 一致性
 /// 14.3: classic fallback 时发射 SecurityEvent(.cryptoDowngrade)
 /// Requirement 14.2, 14.3, 14.4
    public func processMessageB(
        _ messageB: HandshakeMessageB,
        policy: HandshakePolicy = .default,
        postSignatureValidation: (@Sendable (Data) async throws -> Void)? = nil,
        secureEnclavePublicKey: Data? = nil
    ) async throws -> SessionKeys {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        guard role == .initiator else {
            throw HandshakeError.invalidState("Only initiator can process MessageB")
        }

 // 14.4: 检查 requirePQC 策略
 // Requirement 14.4: requirePQC 策略下 PQC 不可用时直接失败
        if policy.requirePQC && !messageB.selectedSuite.isPQC {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }

        guard let transcriptHashA = transcriptHashA?.noCopyData() else {
            throw HandshakeError.invalidState("Missing transcript hash for MessageA")
        }

        let signaturePreimage = messageB.signaturePreimage(transcriptHashA: transcriptHashA)

        let identityKeys: IdentityPublicKeys
        do {
            identityKeys = try messageB.decodedIdentityPublicKeys()
        } catch {
            throw HandshakeError.failed(.invalidMessageFormat("IdentityPublicKeys decode failed: \(error.localizedDescription)"))
        }

 // 验证签名
        let isValid = try await verifyHandshakeData(
            signaturePreimage,
            signature: messageB.signature,
            publicKey: identityKeys.protocolPublicKey
        )

        guard isValid else {
            throw HandshakeError.failed(.signatureVerificationFailed)
        }

        if let postSignatureValidation {
            try await postSignatureValidation(identityKeys.protocolPublicKey)
        }

        if policy.requireSecureEnclavePoP, messageB.secureEnclaveSignature == nil {
            throw HandshakeError.failed(.secureEnclavePoPRequired)
        }

        if policy.requireSecureEnclavePoP, secureEnclavePublicKey == nil {
            throw HandshakeError.failed(.secureEnclavePoPRequired)
        }

        if let seSig = messageB.secureEnclaveSignature {
            let sePreimage = messageB.secureEnclaveSignaturePreimage(transcriptHashA: transcriptHashA)
            if let sePublicKey = secureEnclavePublicKey {
                let seValid = (try? await classicProvider.verify(
                    data: sePreimage,
                    signature: seSig,
                    publicKey: sePublicKey
                )) ?? false

                if !seValid {
                    if policy.requireSecureEnclavePoP {
                        throw HandshakeError.failed(.secureEnclaveSignatureInvalid)
                    }
                    SecurityEventEmitter.emitDetached(SecurityEvent(
                        type: .secureEnclaveSignatureInvalid,
                        severity: .warning,
                        message: "Secure Enclave signature verification failed (MessageB)",
                        context: [
                            "reason": "invalid_se_sig_b",
                            "deviceId": "unknown"
                        ]
                    ))
                }
            } else {
                SecurityEventEmitter.emitDetached(SecurityEvent(
                    type: .secureEnclaveSignatureInvalid,
                    severity: .info,
                    message: "Secure Enclave signature provided but no SE public key available (MessageB)",
                    context: [
                        "reason": "missing_se_public_key_b"
                    ]
                ))
            }
        }

 // 更新 transcriptB
        let transcriptB = SHA256.hash(data: messageB.transcriptBytes)
        transcriptHashB = SecureBytes(data: Data(transcriptB))

 // 检查 suite 是否在 supportedSuites 且有 keyShare
        let selectedSuite = messageB.selectedSuite
        guard sentSupportedSuites.contains(selectedSuite),
              sentKeyShares[selectedSuite] != nil else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }

        guard messageB.responderShare == messageB.encryptedPayload.encapsulatedKey else {
            throw HandshakeError.failed(.invalidMessageFormat("Responder share mismatch"))
        }

 // 保存对端 KeyShare
        peerKeyShares[selectedSuite] = messageB.responderShare
        peerNonce = SecureBytes(data: messageB.serverNonce)
        negotiatedSuite = selectedSuite

        try await ensureNotReplay(for: selectedSuite, replayTag: .messageB)

 // 14.3: 检测降级并发射事件
 // Requirement 14.3: suite 降级时发射 SecurityEvent(.cryptoDowngrade)
        let proposedSuite = sentSupportedSuites.first ?? cryptoProvider.activeSuite
        if selectedSuite != proposedSuite {
            let selectedIndex = sentSupportedSuites.firstIndex(of: selectedSuite) ?? -1
            let downgradeReason = proposedSuite.isPQC && !selectedSuite.isPQC ? "pqc_to_classic" : "lower_priority_selected"
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .cryptoDowngrade,
                severity: .warning,
                message: "Suite downgrade accepted by responder",
                context: [
                    // Paper terminology alignment:
                    "downgradeResistance": "policy_gate+no_timeout_fallback+rate_limited",
                    "policyInTranscript": "1",
                    "transcriptBinding": "1",
                    "reason": downgradeReason,
                    "proposedSuite": proposedSuite.rawValue,
                    "selectedSuite": selectedSuite.rawValue,
                    "proposedWireId": String(proposedSuite.wireId),
                    "selectedWireId": String(selectedSuite.wireId),
                    "preferredIndex": "0",
                    "selectedIndex": String(selectedIndex),
                    "policyRequirePQC": policy.requirePQC ? "1" : "0",
                    "policyAllowClassicFallback": policy.allowClassicFallback ? "1" : "0",
                    "policyMinimumTier": policy.minimumTier.rawValue,
                    "policyRequireSecureEnclavePoP": policy.requireSecureEnclavePoP ? "1" : "0"
                ]
            ))
        }

        if cryptoPolicy.allowExperimentalHybrid,
           cryptoPolicy.requireHybridIfAvailable,
           let advertisedHybrid = sentSupportedSuites.first(where: { $0.isHybrid }),
           peerKEMPublicKeys[advertisedHybrid] != nil,
           selectedSuite != advertisedHybrid {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }

        if selectedSuite.isPQC {
            guard let payloadSecret = kemSharedSecrets[selectedSuite] else {
                throw HandshakeError.invalidState("Missing KEM shared secret for \(selectedSuite.rawValue)")
            }

            _ = try openPayloadWithSharedSecret(
                messageB.encryptedPayload,
                sharedSecret: payloadSecret,
                info: Data("handshake-payload".utf8)
            )
            kemSharedSecrets.removeValue(forKey: selectedSuite)
            return try deriveSessionKeys(sharedSecret: payloadSecret)
        }

 // 解密 payload（经典 DH 套件）
        guard let provider = providerForSuite(selectedSuite),
              let ephPrivKey = keyExchangePrivateKeys[selectedSuite] else {
            throw HandshakeError.invalidState("Ephemeral private key not available")
        }

        let openResult = try await provider.kemDemOpenWithSecret(
            sealedBox: messageB.encryptedPayload,
            privateKey: ephPrivKey,
            info: Data("handshake-payload".utf8)
        )

 // 派生会话密钥
        return try deriveSessionKeys(sharedSecret: openResult.sharedSecret)
    }

 /// 响应方在发送 MessageB 后派生会话密钥
    public func finalizeResponderSessionKeys(sharedSecret: SecureBytes) throws -> SessionKeys {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        guard role == .responder else {
            throw HandshakeError.invalidState("Only responder can finalize session keys")
        }

        return try deriveSessionKeys(sharedSecret: sharedSecret)
    }

 // MARK: - KEM Payload Helpers

    private func sealPayloadWithSharedSecret(
        _ sharedSecret: SecureBytes,
        plaintext: Data,
        info: Data,
        encapsulatedKey: Data
    ) throws -> HPKESealedBox {
        let inputKey = SymmetricKey(data: sharedSecret)
        let salt = transcriptHashA?.noCopyData() ?? Data()
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

        let sealedBox = try AES.GCM.seal(plaintext, using: derivedKey, nonce: nonce)
        return HPKESealedBox(
            encapsulatedKey: encapsulatedKey,
            nonce: Data(nonceBytes),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
    }

    private func openPayloadWithSharedSecret(
        _ sealedBox: HPKESealedBox,
        sharedSecret: SecureBytes,
        info: Data
    ) throws -> Data {
        let inputKey = SymmetricKey(data: sharedSecret)
        let salt = transcriptHashA?.noCopyData() ?? Data()
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )

        let nonce = try AES.GCM.Nonce(data: sealedBox.nonce)
        let gcmSealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
        return try AES.GCM.open(gcmSealedBox, using: derivedKey)
    }

 // MARK: - Key Derivation

 /// 派生会话密钥
    private func deriveSessionKeys(sharedSecret: SecureBytes) throws -> SessionKeys {
        guard let transcriptA = transcriptHashA?.noCopyData(),
              let transcriptB = transcriptHashB?.noCopyData(),
              let suite = negotiatedSuite,
              let localNonce = nonce?.data,
              let remoteNonce = peerNonce?.data else {
            throw HandshakeError.invalidState("Missing transcript, suite, nonces, or shared secret")
        }

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

        let inputKey = SymmetricKey(data: sharedSecret)
        var saltInput = Data("SkyBridge-KDF-Salt-v1|".utf8)
        saltInput.append(kdfInfo)
        let salt = Data(SHA256.hash(data: saltInput))

 // Key derivation uses direction-based labels for symmetric key agreement:
 // - Both sides derive the same key for initiator→responder direction
 // - Both sides derive the same key for responder→initiator direction
 // Initiator: sendKey = I2R, receiveKey = R2I
 // Responder: sendKey = R2I, receiveKey = I2R
        let i2rInfo = kdfInfo + Data("handshake|initiator_to_responder".utf8)
        let r2iInfo = kdfInfo + Data("handshake|responder_to_initiator".utf8)

        let sendKeyData = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: role == .initiator ? i2rInfo : r2iInfo,
            outputByteCount: 32
        )

        let receiveKeyData = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: role == .initiator ? r2iInfo : i2rInfo,
            outputByteCount: 32
        )

        var transcriptDigestInput = Data()
        transcriptDigestInput.append(transcriptA)
        transcriptDigestInput.append(transcriptB)
        let fullTranscriptHash = SHA256.hash(data: transcriptDigestInput)
        let sessionKeys = SessionKeys(
            sendKey: sendKeyData.withUnsafeBytes { Data($0) },
            receiveKey: receiveKeyData.withUnsafeBytes { Data($0) },
            negotiatedSuite: suite,
            role: role,
            transcriptHash: Data(fullTranscriptHash)
        )

        kemSharedSecrets[suite]?.zeroize()
        kemSharedSecrets.removeValue(forKey: suite)
        sharedSecret.zeroize()
        return sessionKeys
    }

 // MARK: - Zeroization

 /// 清理敏感数据
 ///
 /// **关键**：必须在握手完成或失败后调用
    public func zeroize() {
        guard !isZeroized else { return }

 // SecureBytes 的 deinit 会自动擦除内存
        keyExchangePrivateKeys.removeAll()
        for (_, secret) in kemSharedSecrets {
            secret.zeroize()
        }
        kemSharedSecrets.removeAll()
        transcriptHashA = nil
        transcriptHashB = nil
        nonce = nil
        peerNonce = nil

 // 清除公钥（非敏感但也清理）
        keyExchangePublicKeys.removeAll()
        peerKeyShares.removeAll()
        sentSupportedSuites.removeAll()
        sentKeyShares.removeAll()

        isZeroized = true
    }
}

// MARK: - Replay Detection

@available(macOS 14.0, iOS 17.0, *)
extension HandshakeContext {
    private enum ReplayTag: UInt8 {
        case messageA = 0xA1
        case messageB = 0xB1
    }

    private func ensureNotReplay(for suite: CryptoSuite, replayTag: ReplayTag) async throws {
        let handshakeId = try computeHandshakeId(for: suite, replayTag: replayTag)
        let isNew = await HandshakeReplayCache.shared.registerIfNew(handshakeId)
        guard isNew else {
            throw HandshakeError.failed(.replayDetected)
        }
    }

    private func computeHandshakeId(for suite: CryptoSuite, replayTag: ReplayTag) throws -> Data {
        guard let localNonce = nonce?.data,
              let remoteNonce = peerNonce?.data else {
            throw HandshakeError.invalidState("Missing nonces for handshakeId")
        }

        let initiatorNonce: Data
        let responderNonce: Data
        if role == .initiator {
            initiatorNonce = localNonce
            responderNonce = remoteNonce
        } else {
            initiatorNonce = remoteNonce
            responderNonce = localNonce
        }

        var data = Data()
        data.reserveCapacity(1 + initiatorNonce.count + responderNonce.count + MemoryLayout<UInt16>.size)
        var tag = replayTag.rawValue
        data.append(&tag, count: 1)
        data.append(initiatorNonce)
        data.append(responderNonce)
        var wireId = suite.wireId.littleEndian
        data.append(Data(bytes: &wireId, count: MemoryLayout<UInt16>.size))

        let digest = SHA256.hash(data: data)
        return Data(digest)
    }
}

// MARK: - Suite Negotiation Helpers

@available(macOS 14.0, iOS 17.0, *)
extension HandshakeContext {
    private func providerForSuite(_ suite: CryptoSuite) -> (any CryptoProvider)? {
 // 显式按能力路由，避免 provider 同时支持多套件时的隐含假设
        if let hybridProvider, hybridProvider.supportsSuite(suite) {
            return hybridProvider
        }
        if cryptoProvider.supportsSuite(suite) {
            return cryptoProvider
        }
        if classicProvider.supportsSuite(suite) {
            return classicProvider
        }
        return nil
    }

    private func resolveSupportedSuites(offeredSuites: [CryptoSuite], policy: HandshakePolicy) throws -> [CryptoSuite] {
        guard !offeredSuites.isEmpty else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }

        var suites: [CryptoSuite] = []
        suites.reserveCapacity(min(2, offeredSuites.count))

        for suite in offeredSuites {
            guard suiteMeetsHandshakePolicy(suite, policy: policy),
                  suiteMeetsLocalCryptoPolicy(suite),
                  providerForSuite(suite) != nil else {
                continue
            }

            // IMPORTANT:
            // - For initiator, PQC KEM requires the peer's KEM *public key* to encapsulate.
            // - For responder, PQC KEM does NOT require peer KEM public keys; it decapsulates using *local* KEM private key + encapsulatedKey from MessageA.
            if role == .initiator, suite.isPQC, peerKEMPublicKeys[suite] == nil {
                continue
            }

            suites.append(suite)
            if suites.count == 2 {
                break
            }
        }

        if suites.isEmpty {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }

        return suites
    }

    private func resolveSupportedSuites(policy: HandshakePolicy) throws -> [CryptoSuite] {
        var suites: [CryptoSuite] = []

        if let hybridProvider, cryptoPolicy.allowExperimentalHybrid, cryptoPolicy.advertiseHybrid {
            let hybridSuite = hybridProvider.activeSuite
            if suiteMeetsHandshakePolicy(hybridSuite, policy: policy),
               suiteMeetsLocalCryptoPolicy(hybridSuite),
               hybridSuite.isHybrid,
               (role == .responder || peerKEMPublicKeys[hybridSuite] != nil) {
                if cryptoPolicy.minimumSecurityTier == .hybridPreferred {
                    suites.append(hybridSuite)
                }
            }
        }

        let primarySuite = cryptoProvider.activeSuite
        if suites.isEmpty {
            guard suiteMeetsHandshakePolicy(primarySuite, policy: policy),
                  suiteMeetsLocalCryptoPolicy(primarySuite) else {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
        }

        if role == .initiator, primarySuite.isPQC && peerKEMPublicKeys[primarySuite] == nil {
            if policy.requirePQC && suites.isEmpty {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
        } else if suiteMeetsHandshakePolicy(primarySuite, policy: policy),
                  suiteMeetsLocalCryptoPolicy(primarySuite) {
            suites.append(primarySuite)
        }

        if suites.isEmpty {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }

        let reserveSecondSlotForHybrid = cryptoPolicy.allowExperimentalHybrid && cryptoPolicy.advertiseHybrid && hybridProvider != nil
        if suites.count < 2, policy.allowClassicFallback, suites.first?.isPQC == true, !reserveSecondSlotForHybrid {
            if suiteMeetsHandshakePolicy(.x25519Ed25519, policy: policy),
               suiteMeetsLocalCryptoPolicy(.x25519Ed25519),
               providerForSuite(.x25519Ed25519) != nil {
                suites.append(.x25519Ed25519)
            }
        }

        if cryptoPolicy.minimumSecurityTier != .hybridPreferred,
           suites.count < 2,
           cryptoPolicy.allowExperimentalHybrid,
           cryptoPolicy.advertiseHybrid,
           let hybridProvider {
            let hybridSuite = hybridProvider.activeSuite
            if !suites.contains(hybridSuite),
               suiteMeetsHandshakePolicy(hybridSuite, policy: policy),
               suiteMeetsLocalCryptoPolicy(hybridSuite),
               hybridSuite.isHybrid,
               (role == .responder || peerKEMPublicKeys[hybridSuite] != nil) {
                suites.append(hybridSuite)
            }
        }

        if suites.count > 2 {
            suites = Array(suites.prefix(2))
        }

        return suites
    }

    private func suiteMeetsHandshakePolicy(_ suite: CryptoSuite, policy: HandshakePolicy) -> Bool {
        if policy.requirePQC && !suite.isPQC {
            return false
        }
        // NOTE:
        // `allowClassicFallback` is about whether we *may* append / negotiate a classic suite as a fallback
        // when PQC is otherwise available. It must NOT forbid classic-only handshakes (e.g. legacy bootstrap)
        // where `requirePQC == false` and `minimumTier == .classic`.
        //
        // The "no classic" property is already enforced by `requirePQC == true` (strictPQC).
        if policy.minimumTier != .classic && !suite.isPQC {
            return false
        }

        return true
    }

    private func suiteMeetsLocalCryptoPolicy(_ suite: CryptoSuite) -> Bool {
        if suite.isHybrid && !cryptoPolicy.allowExperimentalHybrid {
            return false
        }

        switch cryptoPolicy.minimumSecurityTier {
        case .classicOnly:
            return !suite.isPQC
        case .pqcOnly:
            return suite.isPQC && !suite.isHybrid
        case .pqcPreferred:
            return true
        case .hybridPreferred:
            return true
        }
    }

    private func selectSuite(
        from messageA: HandshakeMessageA,
        localPolicy: HandshakePolicy
    ) throws -> CryptoSuite {
        var skipped: [String] = []

        if cryptoPolicy.allowExperimentalHybrid,
           cryptoPolicy.requireHybridIfAvailable {
            if let forcedHybrid = messageA.supportedSuites.first(where: { suite in
                guard suite.isHybrid else { return false }
                if providerForSuite(suite) == nil { return false }
                if !suiteMeetsHandshakePolicy(suite, policy: localPolicy) { return false }
                if !suiteMeetsLocalCryptoPolicy(suite) { return false }
                if !suiteMeetsHandshakePolicy(suite, policy: messageA.policy) { return false }
                if role == .initiator, peerKEMPublicKeys[suite] == nil { return false }
                if !messageA.keyShares.contains(where: { $0.suite == suite }) { return false }
                return true
            }) {
                return forcedHybrid
            }
        }

        for (index, suite) in messageA.supportedSuites.enumerated() {
            let reason: String?
            if providerForSuite(suite) == nil {
                reason = "provider_unavailable"
            } else if !suiteMeetsHandshakePolicy(suite, policy: localPolicy) || !suiteMeetsLocalCryptoPolicy(suite) {
                reason = "local_policy_rejected"
            } else if !suiteMeetsHandshakePolicy(suite, policy: messageA.policy) {
                reason = "peer_policy_rejected"
            } else if role == .initiator, suite.isPQC && peerKEMPublicKeys[suite] == nil {
                reason = "missing_peer_kem_key"
            } else if !messageA.keyShares.contains(where: { $0.suite == suite }) {
                reason = "missing_keyshare"
            } else {
                reason = nil
            }

            if let reason {
                skipped.append("\(suite.rawValue)=\(reason)")
                continue
            }

            if index != 0, let preferredSuite = messageA.supportedSuites.first {
                SecurityEventEmitter.emitDetached(SecurityEvent(
                    type: .cryptoDowngrade,
                    severity: .warning,
                    message: "Suite downgrade during negotiation",
                    context: [
                        "reason": "lower_priority_selected",
                        "preferredSuite": preferredSuite.rawValue,
                        "selectedSuite": suite.rawValue,
                        "preferredIndex": "0",
                        "selectedIndex": String(index),
                        "skipped": skipped.joined(separator: ",")
                    ]
                ))
            }

            return suite
        }

        throw HandshakeError.failed(.suiteNegotiationFailed)
    }
}

// MARK: - Signing Helpers

@available(macOS 14.0, iOS 17.0, *)
extension HandshakeContext {
 /// 签名握手数据（sigA/sigB）
 ///
 /// ** 5.3: Driver 内部彻底分流**
 /// - 优先使用 `protocolSignatureProvider`（新版本）
 /// - 回退到 `signatureProvider`（旧版本兼容）
 ///
 /// **Requirements: 7.2, 7.3**
    private func signHandshakeData(_ data: Data, identityKeyHandle: SigningKeyHandle?) async throws -> Data {
        guard let identityKeyHandle = identityKeyHandle else {
            throw HandshakeError.noSigningCapability
        }

 // 5.3: 优先使用 protocolSignatureProvider
        if let protocolProvider = protocolSignatureProvider {
            return try await protocolProvider.sign(data, key: identityKeyHandle)
        }

 // 旧版本兼容：使用 signatureProvider
        return try await signatureProvider.sign(data: data, using: identityKeyHandle)
    }

    private func verifyHandshakeData(
        _ data: Data,
        signature: Data,
        publicKey: Data
    ) async throws -> Bool {
 // 5.3: 优先使用 protocolSignatureProvider
        if let protocolProvider = protocolSignatureProvider {
            return try await protocolProvider.verify(data, signature: signature, publicKey: publicKey)
        }

 // 旧版本兼容：使用 signatureProvider
        return try await signatureProvider.verify(
            data: data,
            signature: signature,
            publicKey: publicKey
        )
    }

 /// 签名 Secure Enclave 数据（seSigA/seSigB）
 ///
 /// ** 5.3: Driver 内部彻底分流**
 /// - 优先使用 `sePoPSignatureProvider`（新版本）
 /// - 回退到 `classicProvider`（旧版本兼容）
 ///
 /// **Requirements: 7.2, 7.3**
    private func signSecureEnclaveData(
        _ data: Data,
        secureEnclaveKeyHandle: SigningKeyHandle?
    ) async throws -> Data? {
        guard let secureEnclaveKeyHandle else {
            return nil
        }
        switch secureEnclaveKeyHandle {
        case .softwareKey:
            return nil
        #if canImport(Security)
        case .secureEnclaveRef:
 // 5.3: 优先使用 sePoPSignatureProvider
            if let sePoPProvider = sePoPSignatureProvider {
                return try await sePoPProvider.sign(data, key: secureEnclaveKeyHandle)
            }
 // 旧版本兼容
            return try await classicProvider.sign(data: data, using: secureEnclaveKeyHandle)
        #endif
        case .callback:
 // 5.3: 优先使用 sePoPSignatureProvider
            if let sePoPProvider = sePoPSignatureProvider {
                return try await sePoPProvider.sign(data, key: secureEnclaveKeyHandle)
            }
 // 旧版本兼容
            return try await classicProvider.sign(data: data, using: secureEnclaveKeyHandle)
        }
    }
}
